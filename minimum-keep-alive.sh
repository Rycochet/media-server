#!/bin/bash

# This script should be called every minute from cron - this ensures that the minimum
# routing exists, even if no servers are running:

# * * * * * /bin/bash /path/to/minimum-keep-alive.sh 2>&1 | /usr/bin/logger -t minimum-keep-alive

# Make sure we have the right compose file path relative to this script
cd "$(dirname "$(realpath $0)")"

if [ -f .env.keep-alive ]; then
    source .env.keep-alive
fi

if [[ -v KEEP_ALIVE ]] || [[ "$(declare -p KEEP_ALIVE)" =~ "declare -a" ]] || [ "${#KEEP_ALIVE[@]}" = "0" ]; then
    KEEP_ALIVE=("socket-proxy" "tinyauth" "error-pages" "traefik")
fi

for i in "${KEEP_ALIVE[@]}"; do
    if [ ! -n "$(docker ps --filter "name=$i" --filter "status=running" --quiet)" ]; then
        docker compose up -d $i
    fi
done
