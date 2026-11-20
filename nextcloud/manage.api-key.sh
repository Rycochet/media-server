#!/bin/bash

# Set the API key (NC-Token) the homepage widget uses
#
# Run with: ./manage.sh run nextcloud api-key [key]
#
# The key is saved as NEXTCLOUD_API in .env, and if Nextcloud is running it is
# also set in Nextcloud itself (Administration settings -> System -> NC-Token),
# then homepage is restarted so it picks up the new key. If Nextcloud isn't
# running yet, run this again once it has finished its first start.

# shellcheck source=/dev/null
source "$MANAGE_SH"
cd "$(dirname "$MANAGE_SH")" || die "Could not find the repository."

[ -f "$ENV_FILE" ] || die "There is no $ENV_FILE file, run \"./manage.sh install\" first."

# "-" is what .env.example has, so it doesn't count as a key
current=$(env_get NEXTCLOUD_API) || current=""
case "$current" in
- | "<"*">") current="" ;;
esac

key=${1:-}
if [ -z "$key" ]; then
    if [ -n "$current" ] && ask "There is already a Nextcloud API key, keep it?"; then
        key=$current
    else
        key=$(ask_value "Type an API key, or press enter to make a random one" "")
        [ -n "$key" ] || key=$(random_secret 32)
    fi
fi

if [ "$key" != "$current" ]; then
    env_set NEXTCLOUD_API "$key"
    echo "Saved the Nextcloud API key as NEXTCLOUD_API in $ENV_FILE."
fi

container_running() {
    [ -n "$(docker ps -q --filter "name=^$1\$" --filter status=running 2>/dev/null)" ]
}

occ() {
    docker exec -u www-data nextcloud php occ "$@"
}

if ! docker_ready || ! container_running nextcloud; then
    echo "Nextcloud isn't running, so the key is only saved for now."
    echo "Run \"./manage.sh run nextcloud api-key\" again once it has started to set it in Nextcloud too,"
    echo "or paste it into Administration settings -> System -> NC-Token yourself."
    exit 0
fi

if ! occ status 2>/dev/null | grep -q "installed: true"; then
    echo "Nextcloud is still installing, so the key is only saved for now."
    echo "Run \"./manage.sh run nextcloud api-key\" again once it has finished."
    exit 0
fi

occ app:enable serverinfo >/dev/null 2>&1 || true
occ config:app:set serverinfo token --value="$key" >/dev/null || die "Could not set the key in Nextcloud."
echo "Set the key in Nextcloud."

# The key reaches homepage as a secret, which is only read when it is created
if container_running homepage && ask "Restart homepage so it uses the new key?"; then
    docker compose up -d --no-deps --force-recreate homepage || warn "Could not restart homepage."
fi
