#!/bin/bash

# Helpers for the OwnTone manage scripts, checking what the host can do rather
# than which Linux it is

# avahi-daemon can only be controlled here when systemd is running and has it
avahi_controllable() {
    command -v systemctl >/dev/null &&
        systemctl show-environment >/dev/null 2>&1 &&
        systemctl cat avahi-daemon.service >/dev/null 2>&1
}

avahi_running() {
    avahi_controllable &&
        { systemctl is-active --quiet avahi-daemon.service || systemctl is-active --quiet avahi-daemon.socket; }
}

# Whether something is listening on UDP port 5353, when that can be checked
port_in_use() {
    command -v ss >/dev/null && [ -n "$(ss -Hlun 'sport = :5353' 2>/dev/null)" ]
}
