#!/bin/bash

# Set up Sonarr, Radarr, Lidarr, Chaptarr or Whisparr to use the login in
# front of it (tinyauth), and save its API key in .env for the homepage widget
#
# This is run by the manage.enable.sh and manage.setup.sh scripts in each of
# their folders, with SERVICE set to the app. Run it again with:
#   ./manage.sh run <app> setup
#
# The app only makes its config.xml the first time it starts, so if there
# isn't one yet it is started once and stopped when the file is there. Then
# the authentication method is set to "External", the API key is copied to
# <APP>_API in .env, and the app is started again. If homepage is running it
# is restarted too, as it only reads the API key when it is created.

# shellcheck source=/dev/null
source "$MANAGE_SH"
cd "$(dirname "$MANAGE_SH")" || die "Could not find the repository."

APPS=(sonarr radarr lidarr chaptarr whisparr)
APP=${1:-${SERVICE:-}}
[[ " ${APPS[*]} " == *" $APP "* ]] || die "\"$APP\" can't be set up with this, choose from: ${APPS[*]}"
CONFIG=$APP/config/config.xml
KEY_NAME=${APP^^}_API

[ -f "$ENV_FILE" ] || die "There is no $ENV_FILE file, run \"./manage.sh install\" first."

later() {
    echo "$1, so $APP hasn't been set up yet."
    echo "Run \"./manage.sh run $APP setup\" once it is, to turn on external authentication and save its API key."
    exit 0
}

docker_ready || later "Docker isn't running"
docker compose config --services 2>/dev/null | grep -qx "$APP" || later "$APP isn't turned on in docker compose"

xml_value() {
    sed -n "s:.*<$1>\(.*\)</$1>.*:\1:p" "$CONFIG" | tr -d '\r' | head -n 1
}

running() {
    [ -n "$(docker compose ps -q --status running "$1" 2>/dev/null)" ]
}

# Set AuthenticationMethod to External, adding it if it isn't there
set_external_auth() {
    awk -v BINMODE=3 '
    { eol = sub(/\r$/, "") ? "\r" : "" }
    /<AuthenticationMethod>/ {
        if (!done) print "  <AuthenticationMethod>External</AuthenticationMethod>" eol
        done = 1
        next
    }
    /<\/Config>/ && !done { print "  <AuthenticationMethod>External</AuthenticationMethod>" eol; done = 1 }
    { print $0 eol }
    ' "$1"
}

if [ ! -f "$CONFIG" ] || [ -z "$(xml_value ApiKey)" ]; then
    echo "Starting $APP once so it makes its settings..."
    docker compose up -d "$APP" || die "Could not start $APP."
    echo "Waiting for $APP to make $CONFIG..."
    for _ in $(seq 100); do
        [ -f "$CONFIG" ] && [ -n "$(xml_value ApiKey)" ] && break
        sleep 3
    done
    [ -f "$CONFIG" ] && [ -n "$(xml_value ApiKey)" ] || die "$APP didn't make $CONFIG, see: docker compose logs $APP"
    # Give it a moment to finish writing the rest of the file
    sleep 5
fi

echo "Stopping $APP to change its settings..."
docker compose stop "$APP" >/dev/null || die "Could not stop $APP."

if [ "$(xml_value AuthenticationMethod)" = External ]; then
    echo "$APP already uses external authentication."
else
    rewrite "$CONFIG" set_external_auth "$CONFIG"
    echo "Set $APP to use external authentication."
fi

key=$(xml_value ApiKey)
if [ "$(env_get "$KEY_NAME")" = "$key" ]; then
    echo "$KEY_NAME in $ENV_FILE already has the API key."
else
    env_set "$KEY_NAME" "$key"
    echo "Saved the API key as $KEY_NAME in $ENV_FILE."
fi

echo "Starting $APP again..."
docker compose up -d "$APP" || die "Could not start $APP."

# The key reaches homepage as a secret, which is only read when it is created
if running homepage; then
    echo "Restarting homepage so it uses the API key..."
    docker compose up -d --no-deps --force-recreate homepage || warn "Could not restart homepage."
fi
