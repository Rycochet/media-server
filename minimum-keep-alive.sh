#!/bin/bash

# This script should be called every minute from cron - this ensures that the minimum
# routing exists, even if no servers are running:

# * * * * * /bin/bash /path/to/minimum-keep-alive.sh 2>&1 | /usr/bin/logger -t minimum-keep-alive

if [ ! -n "$(docker ps --filter "name=traefik" --filter "status=running" --quiet)" ]; then
    # Make sure we have the right compose file path relative to this script
    cd "$(dirname "$(realpath $0)")"
    docker compose up -d traefik
fi
