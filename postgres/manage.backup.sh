#!/bin/bash

# Back up Postgres now, list or test the backups, or restore one
#
# Run with: ./manage.sh run postgres backup [now|list|test [set]|restore [set]]
#
# Needs postgres/compose.backup.yaml turned on. Backups are made and tested by
# the postgres-backup container, see postgres/backup.sh for how.
#
# Restoring stops Postgres, moves its data folder to "postgres/data.before-<date>",
# starts an empty Postgres and restores everything into it - the users with their
# passwords, and every database - then checks it all matches the backup. If
# anything goes wrong the old data folder is put back. Apps using Postgres
# should be restarted afterwards.

set -e
# shellcheck source=/dev/null
source "$MANAGE_SH"
cd "$(dirname "$MANAGE_SH")" || die "Could not find the repository."

check_docker

# Run the backup script, in the running container if there is one
in_backup() {
    if [ -n "$(docker compose ps --status running -q postgres-backup 2>/dev/null)" ]; then
        docker compose exec postgres-backup /bin/bash /usr/local/bin/postgres-backup "$@"
    else
        docker compose run --rm --no-deps postgres-backup "$@"
    fi
}

restore() {
    local set=$1 stamp old data=postgres/data was_running
    if [ -z "$set" ]; then
        in_backup list
        read -r -p "Which backup to restore (empty for the newest)? " set || set=""
    fi
    echo "This stops Postgres, moves $data aside and restores ${set:-the newest backup} into an empty Postgres."
    ask "Restore Postgres from ${set:-the newest backup}?" n || return 0

    stamp=$(date +%Y-%m-%d_%H%M%S)
    old="postgres/data.before-$stamp"
    was_running=$(docker compose ps --status running -q postgres-backup 2>/dev/null)
    docker compose stop postgres-backup postgres
    mv "$data" "$old" || die "Could not move $data to $old."
    mkdir -p "$data" && touch "$data/.gitkeep"
    echo "Moved the old data to $old"

    if docker compose up -d --wait postgres &&
        docker compose run --rm --no-deps postgres-backup restore "$set"; then
        echo "Restored Postgres. The old data is still in $old, delete it once you're happy."
        [ -z "$was_running" ] || docker compose up -d postgres-backup
        echo "Restart the apps that use Postgres so they connect again."
        return 0
    fi

    warn "The restore failed, putting the old data back."
    docker compose stop postgres
    rm -rf "${data:?}"
    mv "$old" "$data" || die "Could not move $old back to $data, do it by hand."
    docker compose up -d postgres
    [ -z "$was_running" ] || docker compose up -d postgres-backup
    die "Postgres is back as it was."
}

case "${1:-}" in
now | "") in_backup now ;;
list) in_backup list ;;
test) in_backup test "${2:-}" ;;
restore) restore "${2:-}" ;;
*) die "Use one of: now, list, test [set], restore [set]" ;;
esac
