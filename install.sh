#! /bin/bash

if [ ! -f .env ]; then
    cp .env.example .env
    echo "You must populate the .env file correctly, read the README.md file!"

    docker compose pull
fi

source .env

if [ -z "$NORDLYNX_PRIVATE_KEY" ]; then
    if [ -z "$$NORDVPN_TOKEN" ]; then
        echo "You must provide a value for \$NORDVPN_TOKEN in the .env file"
        exit 1
    else
        echo "Settings up NordVPN for NordLynx support..."
        NORDLYNX_PRIVATE_KEY=$(curl -s -u token:$NORDVPN_TOKEN https://api.nordvpn.com/v1/users/services/credentials | grep -Po '(?<="nordlynx_private_key":").*?(?=")')
        sed -i~ '/^NORDLYNX_PRIVATE_KEY=/s/=.*/="$NORDLYNX_PRIVATE_KEY"/' .env
        echo "...done"
        # docker run -ti --cap-add=NET_ADMIN --cap-add=NET_RAW --name vpn -e TOKEN={TOKEN} -e TECHNOLOGY=NordLynx -d ghcr.io/bubuntux/nordvpn
    fi
fi

if [ -z "$RADARR_API" ]; then
    if [ ! -e "radarr/config/config.xml" ]; then
    fi

    timeout 30 docker compose up radarr

    RADARR_API=$(grep -Po '(?<=<ApiKey>).*?(?=<)')
    sed -i~ '/^RADARR_API=/s/=.*/="$RADARR_API"/' .env
fi

# sonarr key
# radarr key
# prowlarr key
# lidarr key

# i2p i2p\config\clients.config.d\00-net.i2p.router.web.RouterConsoleRunner-clients.config
# "clientApp.0.args=" -> "clientApp.0.args=7657 0.0.0.0 ./webapps/"
