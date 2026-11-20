#!/bin/bash

# Offer to stop avahi-daemon on the host, as OwnTone needs its mDNS port
#
# OwnTone publishes UDP port 5353 so that remotes and speakers can find it,
# and only one thing on the host can have that port. That's usually
# avahi-daemon, which this offers to stop and disable when it runs under
# systemd. Anything else using the port has to be stopped by hand.

# shellcheck source=/dev/null
source "$MANAGE_SH"
source "$(dirname "${BASH_SOURCE[0]}")/avahi.sh"

if avahi_running; then
    echo "avahi-daemon is running on this computer and uses port 5353, which OwnTone needs."
    if ask "Stop and disable avahi-daemon?" n; then
        as_root systemctl disable --now avahi-daemon.socket avahi-daemon.service ||
            warn "Could not stop avahi-daemon."
    fi
fi

if port_in_use; then
    warn "Something on this computer is using UDP port 5353, so OwnTone won't start until it is stopped."
fi
