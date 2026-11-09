#!/bin/bash

# Offer to turn avahi-daemon back on, after it was stopped for OwnTone

# shellcheck source=/dev/null
source "$MANAGE_SH"
source "$(dirname "${BASH_SOURCE[0]}")/avahi.sh"

avahi_controllable || exit 0
avahi_running && exit 0

echo "avahi-daemon isn't running, it may have been stopped when OwnTone was turned on."
ask "Turn avahi-daemon back on?" || exit 0

# OwnTone still has the port until it is stopped
if docker_ready && [ -n "$(docker ps -q --filter name=^owntone\$ --filter status=running 2>/dev/null)" ]; then
    echo "Stopping OwnTone first, as it is using port 5353..."
    docker stop owntone >/dev/null || warn "Could not stop OwnTone."
fi

as_root systemctl enable --now avahi-daemon.socket avahi-daemon.service ||
    warn "Could not start avahi-daemon."
