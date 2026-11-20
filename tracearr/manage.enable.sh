#!/bin/bash

# Offer a fresh database when it is turned on, if the old one is broken
#
# Tracearr makes its own database when the folder is empty. If it finds secrets
# from an earlier install but a database folder that isn't a database, it
# stops rather than risk deleting data, as that's usually a volume that didn't
# mount. This checks for that, and if asked starts it once with
# FORCE_DB_REINIT=true to delete the folder and make a new database, then
# starts it again without it.

# shellcheck source=/dev/null
source "$MANAGE_SH"
cd "$(dirname "$MANAGE_SH")" || die "Could not find the repository."

later() {
    echo "$1, so Tracearr's database hasn't been checked."
    echo "Turn it off and on again once it is, to check it."
    exit 0
}

docker_ready || later "Docker isn't running"
docker compose config --services 2>/dev/null | grep -qx tracearr || later "Tracearr isn't turned on in docker compose"

# The database folder belongs to the container's postgres user, so look at it
# from inside a container with the same volumes
state=$(docker compose run --rm --no-deps -T --entrypoint sh tracearr -c '
    if [ -f /data/postgres/PG_VERSION ] || [ -f /data/postgres/global/pg_control ]; then
        echo ok
    elif [ -z "$(ls -A /data/postgres 2>/dev/null)" ]; then
        echo ok
    elif [ -f /data/tracearr/.jwt_secret ] || [ -f /data/tracearr/.cookie_secret ]; then
        echo broken
    else
        echo ok
    fi' 2>/dev/null | tr -d '\r' | tail -n 1)

case "$state" in
ok) exit 0 ;;
broken) ;;
*)
    warn "Couldn't look at Tracearr's database folder, so it hasn't been checked."
    exit 0
    ;;
esac

echo "tracearr/config/postgres has files in it but isn't a working database, and there"
echo "are secrets from an earlier install, so Tracearr won't start. If its volume is"
echo "mounted from somewhere else, fix that instead of answering yes."
ask "Delete the database folder and start Tracearr with a new, empty database?" n || exit 0

echo "Starting Tracearr once with FORCE_DB_REINIT=true..."
TRACEARR_FORCE_DB_REINIT=true docker compose up -d --no-deps --force-recreate tracearr || die "Could not start Tracearr."
echo "Waiting for the new database..."
for _ in $(seq 100); do
    docker exec tracearr test -f /data/postgres/PG_VERSION 2>/dev/null && break
    sleep 3
done
docker exec tracearr test -f /data/postgres/PG_VERSION 2>/dev/null ||
    die "Tracearr didn't make a new database, see: docker compose logs tracearr"

echo "Starting Tracearr again without FORCE_DB_REINIT..."
docker compose up -d --no-deps --force-recreate tracearr || die "Could not restart Tracearr."
