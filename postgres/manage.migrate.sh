#!/bin/bash

# Move Sonarr, Radarr, Lidarr, Chaptarr and Whisparr from SQLite to Postgres
# Show when on: sonarr radarr lidarr chaptarr whisparr
#
# Run with: ./manage.sh run postgres migrate [app...]
#
# This follows https://wiki.servarr.com/radarr/postgres-setup - each app makes
# its own tables in Postgres first, then only the data is copied in with
# pgloader, so the table names keep their exact case (like "Series").
#
# The app is stopped and its SQLite files and config.xml are copied into a
# "config/pre-postgres-<date>" folder first. If anything goes wrong, or you
# say it doesn't look right at the end, everything is put back how it was.
# Apps already using Postgres are skipped, so it's safe to run again.
#
# Only the main database is copied, the log (and Chaptarr's cache) database
# starts empty. The old SQLite files are kept, renamed to end in ".sqlite-old".

set -e
# shellcheck source=/dev/null
source "$MANAGE_SH"
cd "$(dirname "$MANAGE_SH")" || die "Could not find the repository."

APPS=(sonarr radarr lidarr chaptarr whisparr)
# A table and the API address that lists it, to check the app can see its data
declare -A CHECK_TABLE=([sonarr]=Series [radarr]=Movies [lidarr]=Artists [chaptarr]=Authors [whisparr]=Movies)
declare -A CHECK_API=([sonarr]=api/v3/series [radarr]=api/v3/movie [lidarr]=api/v1/artist [chaptarr]=api/v1/author [whisparr]=api/v3/movie)
# Any other databases an app needs in Postgres, these start empty
declare -A EXTRA_DBS=([chaptarr]="cache")

SERVICES=""
CHOSEN=()
MOVED=0

# What has been done to the app being moved, so it can be undone
IN_PROGRESS=0
APP="" MAIN_DB="" CONFIG_DIR="" BACKUP_DIR="" BACKUP_DONE=0 WAS_RUNNING=0 MADE_ROLE=0 LOAD_FILE="" WORK_DB=""
MADE_DBS=()
# The SQLite file being read, which is a trimmed copy when columns are left out
DB_FILE=""

migration() {
    MIGRATE_DIR="$PWD/${CONFIG_DIR:-.}" docker compose --project-directory . -f "$SERVICE/compose.migration.yaml" "$@"
}

# Run sql as the Postgres admin, in the given database
psql_admin() {
    local db=$1
    shift
    docker compose exec -T postgres psql -U postgres -d "$db" -v ON_ERROR_STOP=1 -qAt "$@"
}

# Run sql against the app's SQLite database
sqlite() {
    migration run --rm -T sqlite "/migrate/$DB_FILE" "$@"
}

xml_value() {
    sed -n "s:.*<$1>\(.*\)</$1>.*:\1:p" "$CONFIG_DIR/config.xml" | head -n 1
}

# The app's main SQLite file, Whisparr v3 calls it whisparr3.db
main_db() {
    if [ "$1" = whisparr ] && [ -f whisparr/config/whisparr3.db ]; then
        echo whisparr3.db
    else
        echo "$1.db"
    fi
}

# Print why an app can't be moved, or nothing if it can
app_status() {
    if ! grep -qx "$1" <<<"$SERVICES"; then
        echo "not turned on"
    elif [ ! -f "$1/config/config.xml" ]; then
        echo "not set up yet"
    elif grep -q "<PostgresHost>" "$1/config/config.xml"; then
        echo "already on Postgres"
    elif [ ! -f "$1/config/$(main_db "$1")" ]; then
        echo "no SQLite database found"
    fi
}

container_state() {
    local id
    id=$(docker compose ps -q "$1" 2>/dev/null) || true
    [ -n "$id" ] || return 0
    docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$id"
}

# Wait up to 5 minutes for a service to say it's healthy
wait_healthy() {
    local i
    for i in $(seq 100); do
        case "$(container_state "$1")" in
        healthy | running) return 0 ;;
        exited | dead) break ;;
        esac
        sleep 3
    done
    die "$1 didn't start properly, see: docker compose logs $1"
}

start_postgres() {
    local i
    grep -qx postgres <<<"$SERVICES" || die "Postgres isn't turned on yet, run: ./manage.sh on postgres"
    docker compose up -d postgres >/dev/null
    for i in $(seq 30); do
        docker compose exec -T postgres pg_isready -q -U postgres 2>/dev/null && return 0
        sleep 2
    done
    die "Postgres didn't start, see: docker compose logs postgres"
}

pick_apps() {
    local i status answer
    echo "Which apps should be moved to Postgres?"
    for i in "${!APPS[@]}"; do
        status=$(app_status "${APPS[i]}")
        printf "  %d) %-10s %s\n" $((i + 1)) "${APPS[i]}" "${status:-ready to move}"
    done
    answer=$(ask_value "Numbers, separated by spaces (enter to cancel)" "")
    for i in $answer; do
        [[ "$i" =~ ^[0-9]+$ ]] && [ "$i" -ge 1 ] && [ "$i" -le "${#APPS[@]}" ] || die "\"$i\" isn't one of the choices."
        CHOSEN+=("${APPS[i - 1]}")
    done
}

# Add the Postgres settings to the end of config.xml, replacing any old ones
add_postgres_settings() {
    awk -v BINMODE=3 -v app="$APP" -v password="$2" '
    { eol = sub(/\r$/, "") ? "\r" : "" }
    /<Postgres[A-Za-z]*>/ { next }
    /<\/Config>/ {
        print "  <PostgresHost>postgres.internal</PostgresHost>" eol
        print "  <PostgresPort>5432</PostgresPort>" eol
        print "  <PostgresUser>" app "</PostgresUser>" eol
        print "  <PostgresPassword>" password "</PostgresPassword>" eol
        print "  <PostgresMainDb>" app "-main</PostgresMainDb>" eol
        print "  <PostgresLogDb>" app "-log</PostgresLogDb>" eol
    }
    { print $0 eol }
    ' "$1"
}

# A query that counts the rows in each table, with "table|count" on each line
count_query() {
    local table sql=""
    for table in "$@"; do
        sql+="${sql:+ UNION ALL }SELECT '$table', count(*) FROM \"$table\""
    done
    echo "$sql;"
}

# Ask the running app for one of its main items, to be sure it can see the
# copied data - asking for just one is quick, even with a big library
check_api() {
    local table=${CHECK_TABLE[$APP]} expected id key port base url body start
    if ! expected=$(psql_admin "$APP-main" -c "SELECT count(*) FROM \"$table\"" 2>/dev/null); then
        warn "There is no \"$table\" table, so skipping the check that $APP can see its data."
        return 0
    fi
    if [ "$expected" -eq 0 ]; then
        echo "$APP doesn't have any ${table,,} yet, so there's nothing to check."
        return 0
    fi
    echo "Checking $APP can see its ${table,,}..."
    id=$(psql_admin "$APP-main" -c "SELECT min(\"Id\") FROM \"$table\"")
    key=$(xml_value ApiKey)
    port=$(xml_value Port)
    base=$(xml_value UrlBase)
    url="http://127.0.0.1:${port}${base:+/${base#/}}/${CHECK_API[$APP]}/$id"
    body=$(docker compose exec -T "$APP" sh -c \
        'curl -fsS -H "X-Api-Key: $1" "$2" 2>/dev/null || wget -qO- --header "X-Api-Key: $1" "$2"' sh "$key" "$url") ||
        die "$APP couldn't find any of its ${table,,}, but there are $expected in the database."
    start=${body:0:20}
    start=${start//[[:space:]]/}
    [ "${start:0:1}" = "{" ] || die "$APP gave an unexpected answer when asked for its ${table,,}."
    echo "$APP can see its data ($expected ${table,,})."
}

remove_work_db() {
    [ -n "$WORK_DB" ] || return 0
    rm -f "$CONFIG_DIR/$WORK_DB" "$CONFIG_DIR/$WORK_DB-wal" "$CONFIG_DIR/$WORK_DB-shm"
    WORK_DB=""
}

# Put the app back how it was before it was touched
undo() {
    local db
    trap - INT TERM
    set +e
    echo
    echo "Putting $APP back how it was..."
    docker compose stop "$APP" >/dev/null 2>&1
    [ -z "$LOAD_FILE" ] || rm -f "$LOAD_FILE"
    remove_work_db
    for db in "${MADE_DBS[@]}"; do
        psql_admin postgres -c "DROP DATABASE IF EXISTS \"$db\" WITH (FORCE)" >/dev/null
    done
    if [ "$MADE_ROLE" = 1 ]; then
        psql_admin postgres -c "DROP ROLE IF EXISTS \"$APP\"" >/dev/null
    fi
    if [ "$BACKUP_DONE" = 1 ]; then
        cp -p "$BACKUP_DIR"/* "$CONFIG_DIR/" || warn "Could not copy the files back, they are in $BACKUP_DIR"
    fi
    if [ "$WAS_RUNNING" = 1 ]; then
        docker compose up -d --no-deps "$APP" >/dev/null 2>&1 || warn "Could not start $APP again."
    fi
    echo "$APP is back on SQLite.${BACKUP_DIR:+ The backup is still in $BACKUP_DIR}"
}

on_exit_migrate() {
    local code=$?
    if [ "$IN_PROGRESS" = 1 ] && [ "$code" -ne 0 ]; then
        undo
    fi
}

migrate_app() {
    local status password db table column names sql sqlite_counts pg_counts file
    local -a tables pg_tables copy missing columns pg_columns extra
    local -A in_pg=() copying=() pg_has=()

    APP=$1 CONFIG_DIR=$1/config BACKUP_DIR="" BACKUP_DONE=0 WAS_RUNNING=0 MADE_ROLE=0 LOAD_FILE="" WORK_DB=""
    MADE_DBS=()
    MAIN_DB=$(main_db "$APP")
    DB_FILE=$MAIN_DB
    status=$(app_status "$APP")
    if [ -n "$status" ]; then
        echo "Skipping $APP, it's $status."
        return 0
    fi
    echo
    echo "===== $APP ====="
    [ -z "$(docker compose ps -q --status running "$APP" 2>/dev/null)" ] || WAS_RUNNING=1
    IN_PROGRESS=1

    echo "Stopping $APP..."
    docker compose stop "$APP" >/dev/null

    echo "Checking the SQLite database..."
    [ "$(sqlite "PRAGMA quick_check;")" = ok ] || die "The SQLite database for $APP is damaged, that needs fixing first."
    # Write anything still in the -wal file into the main database file
    sqlite "PRAGMA wal_checkpoint(TRUNCATE);" >/dev/null

    BACKUP_DIR="$CONFIG_DIR/pre-postgres-$(date +%Y%m%d-%H%M%S)"
    echo "Backing up to $BACKUP_DIR..."
    mkdir "$BACKUP_DIR"
    cp -p "$CONFIG_DIR/config.xml" "$CONFIG_DIR"/*.db* "$BACKUP_DIR/"
    BACKUP_DONE=1

    echo "Making the $APP user and databases in Postgres..."
    password=$(random_secret 32)
    if [ "$(psql_admin postgres -c "SELECT 1 FROM pg_roles WHERE rolname = '$APP'")" = 1 ]; then
        psql_admin postgres -c "ALTER ROLE \"$APP\" WITH LOGIN PASSWORD '$password'"
    else
        psql_admin postgres -c "CREATE ROLE \"$APP\" WITH LOGIN PASSWORD '$password'"
        MADE_ROLE=1
    fi
    for db in main log ${EXTRA_DBS[$APP]:-}; do
        db="$APP-$db"
        if [ "$(psql_admin postgres -c "SELECT 1 FROM pg_database WHERE datname = '$db'")" = 1 ]; then
            echo "There is already a \"$db\" database, probably left from an earlier try."
            ask "Delete it and start again?" || die "Leaving $APP on SQLite."
            psql_admin postgres -c "DROP DATABASE \"$db\" WITH (FORCE)"
        fi
        psql_admin postgres -c "CREATE DATABASE \"$db\" OWNER \"$APP\""
        MADE_DBS+=("$db")
    done

    echo "Starting $APP on Postgres so it makes its own tables..."
    rewrite "$CONFIG_DIR/config.xml" add_postgres_settings "$CONFIG_DIR/config.xml" "$password"
    docker compose up -d --no-deps "$APP" >/dev/null
    echo "Waiting for $APP to finish starting..."
    wait_healthy "$APP"
    docker compose stop "$APP" >/dev/null

    # Only copy tables that the app made with exactly the same name. Search
    # indexes (virtual and shadow tables) only exist in SQLite, so skip those.
    mapfile -t tables < <(sqlite "SELECT name FROM pragma_table_list WHERE schema = 'main' AND type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name;")
    mapfile -t pg_tables < <(psql_admin "$APP-main" -c "SELECT tablename FROM pg_tables WHERE schemaname = 'public'")
    [ "${#tables[@]}" -gt 0 ] || die "Couldn't find any tables in the SQLite database."
    [ "${#pg_tables[@]}" -gt 0 ] || die "$APP started but didn't make any tables in Postgres."
    for table in "${pg_tables[@]}"; do
        in_pg[$table]=1
    done
    for table in "${tables[@]}"; do
        if [ -n "${in_pg[$table]:-}" ]; then
            copy+=("$table")
            copying[$table]=1
        else
            missing+=("$table")
        fi
    done
    if [ "${#missing[@]}" -gt 0 ]; then
        echo "These SQLite tables aren't in Postgres, so they can't be copied: ${missing[*]}"
        ask "Carry on without them?" n || die "Stopped before copying anything."
    fi

    # Columns the app didn't make in Postgres can't be copied either, so those
    # are taken out of a spare copy of the SQLite file, and that is copied
    mapfile -t columns < <(sqlite "SELECT t.name || '|' || c.name FROM pragma_table_list t, pragma_table_info(t.name) c WHERE t.schema = 'main' AND t.type = 'table' ORDER BY 1;")
    mapfile -t pg_columns < <(psql_admin "$APP-main" -c "SELECT table_name || '|' || column_name FROM information_schema.columns WHERE table_schema = 'public'")
    for column in "${pg_columns[@]}"; do
        pg_has[$column]=1
    done
    for column in "${columns[@]}"; do
        if [ -n "${copying[${column%%|*}]:-}" ] && [ -z "${pg_has[$column]:-}" ]; then
            extra+=("$column")
        fi
    done
    if [ "${#extra[@]}" -gt 0 ]; then
        echo "These SQLite columns aren't in Postgres, so they can't be copied (they stay in the backup):"
        printf '  %s\n' "${extra[@]/|/.}"
        ask "Carry on without them?" || die "Stopped before copying anything."
        echo "Making a copy of the SQLite database without them..."
        WORK_DB="$APP.migrate.db"
        cp "$CONFIG_DIR/$MAIN_DB" "$CONFIG_DIR/$WORK_DB"
        DB_FILE=$WORK_DB
        # Indexes, triggers and views can stop a column being dropped, and
        # pgloader doesn't need them
        sql=$(sqlite "SELECT 'DROP ' || type || ' \"' || name || '\";' FROM sqlite_master WHERE type IN ('index', 'trigger', 'view') AND sql IS NOT NULL;")
        for column in "${extra[@]}"; do
            sql+=$'\n'"ALTER TABLE \"${column%%|*}\" DROP COLUMN \"${column#*|}\";"
        done
        sqlite "$sql" || die "Couldn't take those columns out of the copy."
    fi

    echo "Emptying the new tables, so only your data is in them..."
    names=$(printf '"%s", ' "${copy[@]}")
    psql_admin "$APP-main" -c "TRUNCATE ${names%, } RESTART IDENTITY CASCADE"

    echo "Copying ${#copy[@]} tables with pgloader, this can take a while..."
    LOAD_FILE="$CONFIG_DIR/pgloader.load"
    names=$(printf "'%s', " "${copy[@]}")
    cat >"$LOAD_FILE" <<EOF
LOAD DATABASE
    FROM sqlite:///migrate/$DB_FILE
    INTO postgresql://$APP:$password@postgres.internal:5432/$APP-main
    WITH data only, quote identifiers, reset no sequences, prefetch rows = 100, batch size = 1MB
    INCLUDING ONLY TABLE NAMES LIKE ${names%, }
;
EOF
    migration run --rm -T pgloader pgloader --on-error-stop /migrate/pgloader.load ||
        die "pgloader couldn't copy the data, see the messages above."
    rm -f "$LOAD_FILE"
    LOAD_FILE=""

    # Make new rows carry on from the highest copied id
    psql_admin "$APP-main" -c "
    DO \$\$
    DECLARE r record;
    BEGIN
        FOR r IN
            SELECT table_name, column_name,
                pg_get_serial_sequence(format('public.%I', table_name), column_name) AS seq
            FROM information_schema.columns
            WHERE table_schema = 'public'
        LOOP
            CONTINUE WHEN r.seq IS NULL;
            EXECUTE format('SELECT setval(%L, COALESCE((SELECT max(%I) FROM public.%I), 0) + 1, false)',
                r.seq, r.column_name, r.table_name);
        END LOOP;
    END
    \$\$" >/dev/null

    echo "Checking every table has the same number of rows..."
    sql=$(count_query "${copy[@]}")
    sqlite_counts=$(sqlite "$sql" | sort)
    pg_counts=$(psql_admin "$APP-main" -c "$sql" | sort)
    if [ "$sqlite_counts" != "$pg_counts" ]; then
        awk -F'|' 'NR == FNR { rows[$1] = $2; next } rows[$1] != $2 { printf "  %-30s SQLite %s, Postgres %s\n", $1, $2, rows[$1] == "" ? "none" : rows[$1] }' \
            <(echo "$pg_counts") <(echo "$sqlite_counts")
        die "Not everything was copied."
    fi
    echo "All $(awk -F'|' '{ total += $2 } END { print total + 0 }' <<<"$pg_counts") rows were copied."
    remove_work_db
    DB_FILE=$MAIN_DB

    echo "Starting $APP on Postgres..."
    docker compose up -d --no-deps "$APP" >/dev/null
    echo "Waiting for $APP to finish starting..."
    wait_healthy "$APP"
    check_api

    echo "Open $APP in your browser and have a look around."
    ask "Does everything look right?" || die "Not kept, as you said it doesn't look right."

    for file in "$MAIN_DB" "$MAIN_DB-wal" "$MAIN_DB-shm" logs.db logs.db-wal logs.db-shm; do
        if [ -f "$CONFIG_DIR/$file" ]; then
            mv "$CONFIG_DIR/$file" "$CONFIG_DIR/$file.sqlite-old"
        fi
    done
    IN_PROGRESS=0
    MOVED=$((MOVED + 1))
    echo "$APP is now using Postgres. The old SQLite files end in .sqlite-old, and a backup is in $BACKUP_DIR"
}

main_migrate() {
    local app
    [ -n "${SERVICE:-}" ] || die "Run this with: ./manage.sh run postgres migrate"
    check_docker
    SERVICES=$(docker compose config --services 2>/dev/null) || die "Docker compose can't read the stack, check with: docker compose config"
    start_postgres

    if [ "$#" -gt 0 ]; then
        for app in "$@"; do
            [[ " ${APPS[*]} " == *" $app "* ]] || die "\"$app\" can't be moved, choose from: ${APPS[*]}"
        done
        CHOSEN=("$@")
    else
        pick_apps
    fi
    [ "${#CHOSEN[@]}" -gt 0 ] || return 0

    echo
    echo "**********************************************************************"
    echo "*                                                                    *"
    echo "*   This can take a long time, especially with a big library.        *"
    echo "*   If anything goes wrong it puts everything back how it was, so    *"
    echo "*   please let it finish - don't stop it or close this window!       *"
    echo "*                                                                    *"
    echo "**********************************************************************"
    echo
    echo "Getting the migration tools ready..."
    migration pull -q

    trap on_exit_migrate EXIT
    trap 'exit 130' INT TERM
    for app in "${CHOSEN[@]}"; do
        migrate_app "$app"
    done

    if [ "$MOVED" -gt 0 ] && [ "$(env_get USE_POSTGRES)" != true ]; then
        echo
        if ask "Make the *arr apps wait for Postgres when they start (USE_POSTGRES=true in .env)?"; then
            env_set USE_POSTGRES true
            echo "Done, it's used the next time you run: ./manage.sh start"
        fi
    fi
}

main_migrate "$@"
