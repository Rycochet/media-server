#!/bin/bash

# Tested backups of everything in Postgres, run inside the postgres-backup
# container (see compose.backup.yaml and manage.backup.sh).
#
#   postgres-backup [schedule]    Back up whenever BACKUP_SCHEDULE says (the default)
#   postgres-backup now           Back up and test it straight away
#   postgres-backup test [set]    Test restoring a backup again, the newest by default
#   postgres-backup restore <set> Restore a backup into an empty Postgres at PGHOST
#   postgres-backup list          Show the backups
#   postgres-backup health        Healthy if the newest tested backup is recent enough
#
# Each backup is one .tar file named after when it started, like
# 2026-11-19_040000.tar, holding:
#   globals.sql         Every user, with their passwords, and tablespaces
#   databases/*.dump    Every database, with its owner, settings and permissions
#   config/             postgresql.conf, pg_hba.conf and postgresql.auto.conf
#   manifest/           Users, databases and the row count of every table
#   info.txt            Versions, counts and how long it took
#
# The dumps are already compressed with zstd, so the .tar isn't compressed
# again. backups.log has a line for each tested backup with its checksum, which
# is checked before every test or restore.
#
# Each database is dumped and counted from the same snapshot, so the counts are
# exact even while apps are writing to it. The finished .tar is unpacked into
# BACKUP_TEST_DIR and restored into a throwaway Postgres the same way a real
# restore would, then the users, databases and counts must match the manifest.
# Only backups that pass get their final name; a failed one is kept as
# "<set>-failed.tar" until the next one fails.

set -uo pipefail

BACKUP_DIR=${BACKUP_DIR:-/backup}
SCHEDULE=${BACKUP_SCHEDULE:-0 4 * * *}
KEEP_DAILY=${BACKUP_KEEP_DAILY:-7}
KEEP_WEEKLY=${BACKUP_KEEP_WEEKLY:-4}
KEEP_MONTHLY=${BACKUP_KEEP_MONTHLY:-6}
MAX_AGE=${BACKUP_MAX_AGE:-26}
TEST_DIR=${BACKUP_TEST_DIR:-/tmp}
PGDATA_COPY=${BACKUP_PGDATA:-/pgdata}
GATUS_URL=${BACKUP_GATUS_URL:-}
GATUS_KEY=${BACKUP_GATUS_KEY:-backup_postgres}
GATUS_TOKEN=${BACKUP_GATUS_TOKEN:-}

export PGHOST=${PGHOST:-postgres} PGUSER=${PGUSER:-postgres} PGDATABASE=postgres
if [ -z "${PGPASSWORD:-}" ] && [ -r /run/secrets/postgres_password ]; then
    PGPASSWORD=$(cat /run/secrets/postgres_password)
fi
export PGPASSWORD=${PGPASSWORD:-}
if [ -z "$GATUS_TOKEN" ] && [ -r /run/secrets/postgres_backup_gatus_token ]; then
    GATUS_TOKEN=$(cat /run/secrets/postgres_backup_gatus_token)
fi

SET_PATTERN='[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]_[0-9][0-9][0-9][0-9][0-9][0-9]'
LOCK_FILE=/tmp/postgres-backup.lock
STATUS_FILE="$BACKUP_DIR/status.json"
LAST_FILE="$BACKUP_DIR/.last-tested"
LOG_FILE="$BACKUP_DIR/backups.log"

# Every table in the current database with its exact row count, sorted
COUNT_SQL="SELECT format('%I.%I', n.nspname, c.relname) || E'\t' ||
    (xpath('/row/c/text()', query_to_xml(format('SELECT count(*) AS c FROM %I.%I', n.nspname, c.relname), false, true, '')))[1]::text
FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE c.relkind IN ('r', 'p') AND n.nspname <> 'information_schema' AND n.nspname !~ '^pg_'
ORDER BY 1"

log() {
    echo "$(date '+%F %T') $*"
}

# Stops the current backup (which runs in a subshell) with a reason
die() {
    log "ERROR: $*" >&2
    [ -z "${ERROR_FILE:-}" ] || printf '%s' "$*" >"$ERROR_FILE"
    exit 1
}

sql() {
    psql -X -q -A -t -v ON_ERROR_STOP=1 "$@"
}

# The names of the tested backups, without ".tar"
list_sets() {
    local file
    for file in "$BACKUP_DIR"/$SET_PATTERN.tar; do
        [ ! -f "$file" ] || basename "$file" .tar
    done
}

# A database name as a safe file name
safe_name() {
    printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'
}

urlencode() {
    local s=$1 c i out=""
    for ((i = 0; i < ${#s}; i++)); do
        c=${s:i:1}
        case $c in
        [A-Za-z0-9._~-]) out+=$c ;;
        *) printf -v c '%%%02X' "'$c" && out+=$c ;;
        esac
    done
    printf '%s' "$out"
}

# Tell Gatus how the backup went: success (true/false), error, seconds
push_status() {
    local url
    [ -n "$GATUS_URL" ] && [ -n "$GATUS_TOKEN" ] || return 0
    url="$GATUS_URL/api/v1/endpoints/$GATUS_KEY/external?success=$1&duration=${3}s"
    [ -z "$2" ] || url+="&error=$(urlencode "${2:0:200}")"
    wget -q -O /dev/null -T 30 --header "Authorization: Bearer $GATUS_TOKEN" --post-data "" "$url" ||
        log "Could not send the status to Gatus at $GATUS_URL"
}

write_status() {
    local tmp="$STATUS_FILE.tmp"
    printf '{"time":"%s","success":%s,"set":"%s","seconds":%s,"databases":%s,"tables":%s,"rows":%s,"size":"%s","error":"%s"}\n' \
        "$(date -Iseconds)" "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$(printf '%s' "$8" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr '\n\t' '  ')" \
        >"$tmp" && mv -f "$tmp" "$STATUS_FILE"
}

# Write the users, memberships, databases and per-database settings of the
# server at PGHOST into a manifest folder
describe_server() {
    local out=$1
    mkdir -p "$out" || die "Could not create $out"
    sql -o "$out/roles.txt" -c "SELECT r.rolname || E'\t' || r.rolsuper || E'\t' || r.rolinherit || E'\t' || r.rolcreaterole
        || E'\t' || r.rolcreatedb || E'\t' || r.rolcanlogin || E'\t' || r.rolreplication || E'\t' || r.rolbypassrls
        || E'\t' || r.rolconnlimit || E'\t' || coalesce(r.rolvaliduntil::text, '') || E'\t' || coalesce(array_to_string(r.rolconfig, ','), '')
        || E'\t' || md5(coalesce(a.rolpassword, ''))
        FROM pg_roles r JOIN pg_authid a ON a.oid = r.oid WHERE r.rolname !~ '^pg_' ORDER BY 1" || die "Could not list the users"
    sql -o "$out/members.txt" -c "SELECT r.rolname || E'\t' || m.rolname || E'\t' || am.admin_option
        FROM pg_auth_members am JOIN pg_roles r ON r.oid = am.roleid JOIN pg_roles m ON m.oid = am.member
        WHERE m.rolname !~ '^pg_' ORDER BY 1" || die "Could not list the user memberships"
    sql -o "$out/databases.txt" -c "SELECT datname || E'\t' || pg_get_userbyid(datdba) || E'\t' || pg_encoding_to_char(encoding)
        || E'\t' || datcollate || E'\t' || datctype || E'\t' || coalesce(datacl::text, '')
        FROM pg_database WHERE datallowconn AND NOT datistemplate ORDER BY 1" || die "Could not list the databases"
    sql -o "$out/settings.txt" -c "SELECT coalesce(d.datname, '*') || E'\t' || coalesce(r.rolname, '*') || E'\t' || array_to_string(s.setconfig, ',')
        FROM pg_db_role_setting s LEFT JOIN pg_database d ON d.oid = s.setdatabase LEFT JOIN pg_roles r ON r.oid = s.setrole
        ORDER BY 1" || die "Could not list the database settings"
}

# The databases named in a manifest
manifest_databases() {
    cut -f1 "$1/databases.txt"
}

# Dump one database and count its rows from the same snapshot
dump_database() {
    local db=$1 set=$2 name snap="" line="" pid i
    name=$(safe_name "$db")
    [ ! -e "$set/databases/$name.dump" ] || die "Two databases have the same file name: $name"
    # The snapshot only lasts while this session's transaction is open
    coproc SNAP { psql -X -q -A -t -v ON_ERROR_STOP=1 -d "$db" 2>&1; }
    pid=$SNAP_PID
    printf '%s\n' "BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY;" "SELECT pg_export_snapshot();" >&"${SNAP[1]}"
    for i in 1 2 3; do
        read -r -t 60 line <&"${SNAP[0]}" || break
        if [[ "$line" =~ ^[0-9A-F]+-[0-9A-F]+-[0-9]+$ ]]; then
            snap=$line
            break
        fi
    done
    [ -n "$snap" ] || die "Could not start a snapshot of $db: $line"
    pg_dump -Fc --compress=zstd --create --snapshot="$snap" -d "$db" -f "$set/databases/$name.dump" ||
        die "Could not dump $db"
    printf '%s;\n\\echo __END__\n' "$COUNT_SQL" >&"${SNAP[1]}"
    : >"$set/manifest/counts/$name.txt"
    while read -r line <&"${SNAP[0]}"; do
        [ "$line" != __END__ ] || break
        printf '%s\n' "$line" >>"$set/manifest/counts/$name.txt"
    done
    [ "$line" = __END__ ] || die "Could not count the rows in $db"
    printf 'COMMIT;\n\\q\n' >&"${SNAP[1]}"
    wait "$pid" 2>/dev/null
}

count_database() {
    sql -d "$1" -c "$COUNT_SQL"
}

# Restore an unpacked backup into the server at PGHOST, the same way for a
# test or for real
restore_set() {
    local set=$1 dump err
    err=$(psql -X -q -v ON_ERROR_STOP=0 -d postgres -f "$set/globals.sql" 2>&1 >/dev/null |
        grep 'ERROR' | grep -v 'role "postgres" already exists')
    [ -z "$err" ] || die "Could not restore the users: $err"
    for dump in "$set"/databases/*.dump; do
        [ -f "$dump" ] || continue
        # Connected to template1, so even the "postgres" database can be replaced
        pg_restore --create --clean --if-exists --exit-on-error -d template1 "$dump" ||
            die "Could not restore $(basename "$dump" .dump)"
    done
}

# Check the server at PGHOST matches an unpacked backup's manifest
compare_set() {
    local set=$1 out=$2 db name diffs
    describe_server "$out"
    mkdir -p "$out/counts"
    while read -r db; do
        name=$(safe_name "$db")
        count_database "$db" >"$out/counts/$name.txt" || die "Could not count the rows in the restored $db"
    done < <(manifest_databases "$set/manifest")
    diffs=$(diff -r "$set/manifest" "$out" | head -20)
    [ -z "$diffs" ] || die "The restored copy doesn't match the backup: $diffs"
}

# Unpack a backup's .tar into a folder, checking it against backups.log first
unpack() {
    local tar=$1 out=$2 name sum
    name=$(basename "$tar" .tar)
    name=${name#.partial-}
    sum=$(awk -F'\t' -v n="$name" '$1 == n { s = $2 } END { print s }' "$LOG_FILE" 2>/dev/null)
    if [ -n "$sum" ] && [ "$(sha256sum "$tar" | cut -d' ' -f1)" != "$sum" ]; then
        die "$name.tar doesn't match its checksum in backups.log, it has been changed or damaged"
    fi
    mkdir -p "$out" && tar -xf "$tar" -C "$out" || die "Could not unpack $name.tar"
    [ -f "$out/manifest/databases.txt" ] || die "$name.tar isn't a backup made by this script"
}

# Unpack a backup's .tar, restore it into a throwaway Postgres and check it matches
test_set() {
    local tar=$1 tmp name
    tmp=$(mktemp -d "$TEST_DIR/postgres-test.XXXXXX") || die "Could not make a folder in $TEST_DIR"
    # shellcheck disable=SC2064
    trap "pg_ctl -D '$tmp/data' -m immediate stop >/dev/null 2>&1; rm -rf '$tmp'" EXIT
    name=$(basename "$tar" .tar)
    name=${name#.partial-}
    log "Testing $name.tar in a throwaway Postgres..."
    unpack "$tar" "$tmp/set"
    initdb -D "$tmp/data" -U postgres -A trust --no-sync >"$tmp/initdb.log" 2>&1 ||
        die "Could not create the test Postgres: $(tail -3 "$tmp/initdb.log")"
    pg_ctl -D "$tmp/data" -l "$tmp/postgres.log" -w -t 120 \
        -o "-c listen_addresses='' -c unix_socket_directories='$tmp' -c fsync=off -c full_page_writes=off -c synchronous_commit=off" \
        start >/dev/null || die "Could not start the test Postgres: $(tail -3 "$tmp/postgres.log")"
    (
        export PGHOST=$tmp PGPASSWORD=""
        restore_set "$tmp/set"
        compare_set "$tmp/set" "$tmp/manifest"
    ) || exit 1
    log "Restored and matched $name.tar"
}

# Dump everything into a folder, pack it into a .tar and test that. Run in a
# subshell so die only stops this backup.
make_backup() {
    local dir=$1 tar=$2 start=$3 server client db config
    server=$(sql -c "SHOW server_version_num") || die "Could not connect to Postgres at $PGHOST"
    client=$(pg_dump --version | sed -E 's/.* ([0-9]+)\.?([0-9]*).*/\1/')
    [ "$client" -ge "$((server / 10000))" ] ||
        die "pg_dump $client is older than Postgres $((server / 10000)), use the same image for both"
    mkdir -p "$dir/databases" "$dir/manifest/counts" "$dir/config" || die "Could not create $dir"

    log "Saving the users and databases..."
    describe_server "$dir/manifest"
    pg_dumpall --globals-only -f "$dir/globals.sql" || die "Could not dump the users"
    while read -r db; do
        log "Dumping $db..."
        dump_database "$db" "$dir"
    done < <(manifest_databases "$dir/manifest")

    config=$(find "$PGDATA_COPY" -maxdepth 3 -name postgresql.conf 2>/dev/null | head -1)
    if [ -n "$config" ]; then
        cp "$(dirname "$config")"/{postgresql.conf,pg_hba.conf,pg_ident.conf,postgresql.auto.conf} "$dir/config/" 2>/dev/null
    else
        log "Postgres's data folder isn't at $PGDATA_COPY, so its config files aren't saved"
    fi

    {
        echo "time: $(date -Iseconds)"
        echo "dump seconds: $(($(date +%s) - start))"
        echo "server: $(sql -c "SHOW server_version" 2>/dev/null)"
        echo "client: $(pg_dump --version)"
        echo "databases: $(wc -l <"$dir/manifest/databases.txt")"
        echo "tables: $(cat "$dir"/manifest/counts/*.txt | wc -l)"
        echo "rows: $(cat "$dir"/manifest/counts/*.txt | awk -F'\t' '{ s += $2 } END { print s + 0 }')"
    } >"$dir/info.txt"

    log "Packing into one file..."
    tar -cf "$tar" -C "$dir" . || die "Could not write $tar"
    rm -rf "$dir"
    test_set "$tar"
}

backup() {
    local stamp dir tar start seconds error="" dbs=0 tables=0 rows=0 size="" sum info rc
    exec 9>"$LOCK_FILE"
    flock -n 9 || {
        log "A backup is already running"
        return 1
    }
    mkdir -p "$BACKUP_DIR" || return 1
    stamp=$(date +%Y-%m-%d_%H%M%S)
    dir="$BACKUP_DIR/.partial-$stamp"
    tar="$dir.tar"
    start=$(date +%s)
    log "Backing up Postgres at $PGHOST to $stamp.tar"
    (
        ERROR_FILE="$dir.error"
        make_backup "$dir" "$tar" "$start"
    )
    rc=$?
    seconds=$(($(date +%s) - start))
    if [ "$rc" -eq 0 ]; then
        info=$(tar -xOf "$tar" ./info.txt 2>/dev/null)
        dbs=$(sed -n 's/^databases: //p' <<<"$info")
        tables=$(sed -n 's/^tables: //p' <<<"$info")
        rows=$(sed -n 's/^rows: //p' <<<"$info")
        size=$(du -h "$tar" | cut -f1)
        sum=$(sha256sum "$tar" | cut -d' ' -f1)
        mv "$tar" "$BACKUP_DIR/$stamp.tar" || rc=1
    fi
    if [ "$rc" -eq 0 ]; then
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%ss\n' "$stamp" "$sum" "$size" "$dbs" "$tables" "$rows" "$seconds" >>"$LOG_FILE"
        echo "$stamp" >"$LAST_FILE"
        log "Backup $stamp.tar is tested and saved ($dbs databases, $tables tables, $rows rows, $size, ${seconds}s)"
        write_status true "$stamp" "$seconds" "$dbs" "$tables" "$rows" "$size" ""
        push_status true "" "$seconds"
        prune
    else
        error=$(cat "$dir.error" 2>/dev/null)
        error=${error:-The backup failed, see the container log}
        rm -f "$dir.error" "$BACKUP_DIR"/$SET_PATTERN-failed.tar
        # Keep what there is as one file, to look at
        [ -f "$tar" ] || [ ! -d "$dir" ] || tar -cf "$tar" -C "$dir" . 2>/dev/null
        rm -rf "$dir"
        [ ! -f "$tar" ] || mv "$tar" "$BACKUP_DIR/$stamp-failed.tar"
        log "Backup $stamp FAILED: $error"
        write_status false "$stamp" "$seconds" 0 0 0 "" "$error"
        push_status false "$error" "$seconds"
    fi
    flock -u 9
    return "$rc"
}

# Keep the newest backup of each of the last KEEP_DAILY days, KEEP_WEEKLY weeks
# and KEEP_MONTHLY months, and always the newest one
prune() {
    local set day week month nd=0 nw=0 nm=0 newest=1
    local -A keep=() days=() weeks=() months=()
    while read -r set; do
        [ -n "$set" ] || continue
        day=${set:0:10}
        week=$(date -d "$day 00:00:00" +%G-%V 2>/dev/null || echo "$day")
        month=${set:0:7}
        [ "$newest" -eq 0 ] || keep[$set]=1
        newest=0
        if [ -z "${days[$day]:-}" ]; then
            days[$day]=1
            [ "$nd" -ge "$KEEP_DAILY" ] || keep[$set]=1
            nd=$((nd + 1))
        fi
        if [ -z "${weeks[$week]:-}" ]; then
            weeks[$week]=1
            [ "$nw" -ge "$KEEP_WEEKLY" ] || keep[$set]=1
            nw=$((nw + 1))
        fi
        if [ -z "${months[$month]:-}" ]; then
            months[$month]=1
            [ "$nm" -ge "$KEEP_MONTHLY" ] || keep[$set]=1
            nm=$((nm + 1))
        fi
    done < <(list_sets | sort -r)
    while read -r set; do
        [ -n "$set" ] && [ -z "${keep[$set]:-}" ] || continue
        log "Removing old backup $set.tar"
        rm -f "${BACKUP_DIR:?}/$set.tar"
    done < <(list_sets)
}

# Exit 0 if a cron line ("minute hour day month weekday") matches this minute
cron_match() {
    awk -v spec="$1" -v now="$(date '+%M %H %d %m %w')" '
    function field(f, v, lo, hi,   parts, n, i, p, step, a, b) {
        n = split(f, parts, ",")
        for (i = 1; i <= n; i++) {
            p = parts[i]
            step = 1
            if (index(p, "/")) { step = substr(p, index(p, "/") + 1) + 0; p = substr(p, 1, index(p, "/") - 1) }
            if (p == "*") { a = lo; b = hi }
            else if (index(p, "-")) { a = substr(p, 1, index(p, "-") - 1) + 0; b = substr(p, index(p, "-") + 1) + 0 }
            else { a = p + 0; b = (step > 1 ? hi : a) }
            if (step > 0 && v >= a && v <= b && (v - a) % step == 0) return 1
        }
        return 0
    }
    BEGIN {
        sub(/^[ \t]+/, "", spec)
        if (split(spec, s, /[ \t]+/) != 5) exit 2
        split(now, t, " ")
        for (i = 1; i <= 5; i++) t[i] += 0
        ok = field(s[1], t[1], 0, 59) && field(s[2], t[2], 0, 23) && field(s[4], t[4], 1, 12)
        dom = field(s[3], t[3], 1, 31)
        dow = field(s[5], t[5], 0, 7) || (t[5] == 0 && field(s[5], 7, 0, 7))
        day = (s[3] != "*" && s[5] != "*") ? (dom || dow) : (dom && dow)
        exit !(ok && day)
    }'
}

# Exit 0 if the newest tested backup is younger than MAX_AGE hours
recent() {
    local last
    [ -f "$LAST_FILE" ] || return 1
    last=$(stat -c %Y "$LAST_FILE") || return 1
    [ $(($(date +%s) - last)) -lt $((MAX_AGE * 3600)) ]
}

# Stop with a clear error if a setting isn't usable, rather than misbehaving later
check_settings() {
    local name value bad=0
    for name in KEEP_DAILY KEEP_WEEKLY KEEP_MONTHLY MAX_AGE; do
        value=${!name}
        if ! [[ "$value" =~ ^[0-9]+$ ]] || { [ "$name" = MAX_AGE ] && [ "$((10#$value))" -lt 1 ]; }; then
            log "ERROR: BACKUP_$name must be a whole number$([ "$name" != MAX_AGE ] || echo " of 1 or more"), not \"$value\""
            bad=1
        fi
    done
    cron_match "$SCHEDULE"
    if [ $? -eq 2 ]; then
        log "ERROR: BACKUP_SCHEDULE must be a cron line like \"0 4 * * *\", not \"$SCHEDULE\""
        bad=1
    fi
    [ "$bad" -eq 0 ] || exit 1
    # Leading zeros would otherwise be read as octal
    KEEP_DAILY=$((10#$KEEP_DAILY)) KEEP_WEEKLY=$((10#$KEEP_WEEKLY))
    KEEP_MONTHLY=$((10#$KEEP_MONTHLY)) MAX_AGE=$((10#$MAX_AGE))
}

schedule() {
    trap 'log "Stopping"; exit 0' TERM INT
    # Left over from a backup that was stopped part way
    rm -rf "$BACKUP_DIR"/.partial-* "$TEST_DIR"/postgres-test.*
    log "Backing up on \"$SCHEDULE\" to $BACKUP_DIR, keeping $KEEP_DAILY daily, $KEEP_WEEKLY weekly and $KEEP_MONTHLY monthly"
    # Only one when starting up, so restarts don't each make another
    # Not "grep -q", which stops reading early and fails the pipe with pipefail
    if [ -z "$(list_sets | grep "^$(date +%Y-%m-%d)_")" ]; then
        log "No tested backup for today yet, so backing up now"
        backup
    fi
    while true; do
        sleep $((60 - 10#$(date +%S))) &
        wait $!
        if cron_match "$SCHEDULE"; then
            backup
        fi
    done
}

# The path of a backup's .tar from its name, the newest by default
find_set() {
    local set=${1:-}
    [ -n "$set" ] || set=$(list_sets | sort | tail -1)
    [ -n "$set" ] || die "There are no tested backups in $BACKUP_DIR"
    set=${set##*/}
    set=${set%.tar}
    [ -f "$BACKUP_DIR/$set.tar" ] || die "There isn't a backup called $set.tar in $BACKUP_DIR"
    echo "$BACKUP_DIR/$set.tar"
}

restore() {
    local tar count config file tmp
    tar=$(find_set "${1:-}") || exit 1
    count=$(sql -c "SELECT count(*) FROM pg_database WHERE datallowconn AND NOT datistemplate AND datname <> 'postgres'") ||
        die "Could not connect to Postgres at $PGHOST"
    [ "$count" -eq 0 ] || [ "${2:-}" = --force ] ||
        die "Postgres at $PGHOST already has $count databases, restore into an empty one (or add --force)"
    tmp=$(mktemp -d "$TEST_DIR/postgres-restore.XXXXXX") || die "Could not make a folder in $TEST_DIR"
    # shellcheck disable=SC2064
    trap "rm -rf '$tmp'" EXIT
    log "Restoring $(basename "$tar") into Postgres at $PGHOST..."
    unpack "$tar" "$tmp/set"
    restore_set "$tmp/set"
    compare_set "$tmp/set" "$tmp/manifest"
    log "Restored and matched $(basename "$tar")"
    config=$(find "$PGDATA_COPY" -maxdepth 3 -name postgresql.conf 2>/dev/null | head -1)
    if [ -n "$config" ]; then
        for file in "$tmp"/set/config/*; do
            [ -f "$file" ] || continue
            cmp -s "$file" "$(dirname "$config")/$(basename "$file")" ||
                log "NOTE: $(basename "$file") is different to the backup, it is in config/ in $(basename "$tar") if you need it"
        done
    fi
}

list() {
    local set line
    while read -r set; do
        [ -n "$set" ] || continue
        line=$(awk -F'\t' -v n="$set" '$1 == n { l = $3 "  " $4 " databases  " $6 " rows" } END { print l }' "$LOG_FILE" 2>/dev/null)
        printf '%s  %s\n' "$set" "${line:-$(du -h "$BACKUP_DIR/$set.tar" | cut -f1)}"
    done < <(list_sets | sort)
    [ ! -f "$STATUS_FILE" ] || echo "Last run: $(cat "$STATUS_FILE")"
}

main() {
    local command=${1:-schedule} tar
    shift || true
    check_settings
    case "$command" in
    schedule) schedule ;;
    now) backup ;;
    test)
        tar=$(find_set "${1:-}") || exit 1
        (test_set "$tar")
        ;;
    restore) restore "$@" ;;
    list) list ;;
    health)
        recent || {
            echo "No tested backup in the last ${MAX_AGE}h"
            exit 1
        }
        ;;
    *)
        sed -n '3,11p' "$0" | sed 's/^# \{0,1\}//'
        exit 2
        ;;
    esac
}

main "$@"
