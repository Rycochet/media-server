#!/bin/bash

# Make the APP_KEY when it is turned on, if there isn't one yet
#
# Laravel needs "base64:" followed by exactly 32 random bytes, which the
# "<random>" values in .env.example can't make. Changing it logs everyone out,
# so an existing key is always kept.

# shellcheck source=/dev/null
source "$MANAGE_SH"
cd "$(dirname "$MANAGE_SH")" || die "Could not find the repository."

[ -f "$ENV_FILE" ] || die "There is no $ENV_FILE file, run \"./manage.sh install\" first."

if [ -n "$(env_get SPEEDTEST_TRACKER_APP_KEY)" ]; then
    echo "SPEEDTEST_TRACKER_APP_KEY is already set in $ENV_FILE."
    exit 0
fi

key=$(head -c 32 /dev/urandom | base64 | tr -d '\n') || die "Could not make an APP_KEY."
env_set SPEEDTEST_TRACKER_APP_KEY "base64:$key"
echo "Saved a new APP_KEY as SPEEDTEST_TRACKER_APP_KEY in $ENV_FILE."
