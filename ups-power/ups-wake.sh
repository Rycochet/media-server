#!/bin/bash

# Wakes the server with Wake-on-LAN once the power is back after an outage.
# Runs on the machine the UPS is plugged into (like a Raspberry Pi running the
# NUT server), which has to stay up when the server hibernates - see
# ups-wake.service for how to install it.
#
# Settings, in /etc/default/ups-wake or the environment:
#   UPS_WAKE_MAC       The server's network card, like 08:bf:b8:04:ff:b0 (needed)
#   UPS_WAKE_HOST      The server's address, to see if it is awake (needed)
#   UPS_WAKE_UPS       The UPS to read (default ups@localhost)
#   UPS_WAKE_AFTER     Seconds of mains power before waking it (default 300)
#   UPS_WAKE_RETRY     Seconds between wakes while it doesn't answer (default 60)
#   UPS_WAKE_INTERVAL  Seconds between UPS readings (default 10)
#   UPS_WAKE_BROADCAST Where to send the packet (default 255.255.255.255)
#
# It only wakes the server after an outage (the UPS was on battery since the
# server was last seen), so a server shut down on purpose stays off. The
# network may take a while to come back too, so it keeps trying until the
# server answers ping.

set -uo pipefail

[ ! -f /etc/default/ups-wake ] || . /etc/default/ups-wake

MAC=${UPS_WAKE_MAC:-}
HOST=${UPS_WAKE_HOST:-}
UPS=${UPS_WAKE_UPS:-ups@localhost}
AFTER=${UPS_WAKE_AFTER:-300}
RETRY=${UPS_WAKE_RETRY:-60}
INTERVAL=${UPS_WAKE_INTERVAL:-10}
BROADCAST=${UPS_WAKE_BROADCAST:-255.255.255.255}
STATE=${UPS_WAKE_STATE:-/var/lib/ups-wake}

log() {
    echo "$(date '+%F %T') $*"
}

[[ "$MAC" =~ ^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$ ]] || { log "ERROR: UPS_WAKE_MAC must be a MAC address like 08:bf:b8:04:ff:b0" && exit 1; }
[ -n "$HOST" ] || { log "ERROR: UPS_WAKE_HOST must be the server's address" && exit 1; }
for name in AFTER RETRY INTERVAL; do
    [[ "${!name}" =~ ^[1-9][0-9]*$ ]] || { log "ERROR: UPS_WAKE_$name must be a whole number of seconds" && exit 1; }
done

awake() {
    ping -c 1 -W 2 "$HOST" >/dev/null 2>&1
}

# The magic packet: 6 x FF then the MAC 16 times, by whatever tool there is
send_wake() {
    if command -v wakeonlan >/dev/null; then
        wakeonlan -i "$BROADCAST" "$MAC" >/dev/null
    elif command -v etherwake >/dev/null; then
        etherwake "$MAC"
    elif command -v python3 >/dev/null; then
        python3 - "$MAC" "$BROADCAST" <<'EOF'
import socket, sys
mac = bytes.fromhex(sys.argv[1].replace(':', ''))
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
s.sendto(b'\xff' * 6 + mac * 16, (sys.argv[2], 9))
EOF
    else
        log "ERROR: install wakeonlan, etherwake or python3 to send the wake packet"
        return 1
    fi
}

# Kept on disk, so it still knows about the outage if it restarts
mkdir -p "$STATE"
outage() { [ -f "$STATE/outage" ]; }

trap 'log "Stopping"; exit 0' TERM INT
log "Watching $UPS, waking $HOST ($MAC) after ${AFTER}s of mains following an outage"
mains_since=0
last_wake=0
while true; do
    now=$(date +%s)
    status=$(upsc "$UPS" ups.status 2>/dev/null)
    if [[ " $status " == *" OB "* ]]; then
        outage || log "On battery, the server will be woken once the power is back"
        touch "$STATE/outage"
        mains_since=0
    elif [[ " $status " == *" OL "* ]]; then
        [ "$mains_since" -gt 0 ] || mains_since=$now
        if outage && [ $((now - mains_since)) -ge "$AFTER" ]; then
            if awake; then
                log "$HOST is awake"
                rm -f "$STATE/outage"
            elif [ $((now - last_wake)) -ge "$RETRY" ]; then
                log "On mains for $((now - mains_since))s, waking $HOST"
                send_wake
                last_wake=$now
            fi
        fi
    elif [ -z "$status" ]; then
        log "Can't read $UPS"
    fi
    sleep "$INTERVAL" &
    wait $!
done
