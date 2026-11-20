#!/bin/bash

# Install, remove or check the ups-power service that pauses and hibernates on UPS battery
# Show when on: nutcase
#
# Run with: ./manage.sh run ups-power install [install|uninstall|status]
#
# It runs ups-power.sh from this folder as root, so changes here are picked up
# with "sudo systemctl restart ups-power". Set it up in .env first (the
# UPS_POWER_* settings); it starts in monitor mode, which only logs.

set -e
# shellcheck source=/dev/null
source "$MANAGE_SH"
cd "$(dirname "$MANAGE_SH")" || die "Could not find the repository."

DIR="$PWD/ups-power"
UNIT=/etc/systemd/system/ups-power.service

install_service() {
    command -v systemctl >/dev/null || die "This needs systemd."
    need_tool upsc "to read the UPS" nut-client || die "upsc is needed, install nut-client."
    command -v docker >/dev/null || die "Docker isn't installed."
    echo "Checking the UPS..."
    bash "$DIR/ups-power.sh" status || true
    echo
    ask "Install the ups-power service, running $DIR/ups-power.sh as root?" || return 0
    sed "s|@DIR@|$DIR|g" "$DIR/ups-power.service" | as_root tee "$UNIT" >/dev/null || die "Could not write $UNIT."
    as_root systemctl daemon-reload
    as_root systemctl enable --now ups-power.service
    as_root systemctl restart ups-power.service
    echo "Installed. Follow it with: journalctl -u ups-power -f"
}

uninstall_service() {
    [ -f "$UNIT" ] || {
        echo "ups-power isn't installed."
        return 0
    }
    ask "Stop and remove the ups-power service? Anything it paused is unpaused first." || return 0
    as_root bash "$DIR/ups-power.sh" unpause || true
    as_root systemctl disable --now ups-power.service
    as_root rm -f "$UNIT"
    as_root systemctl daemon-reload
    echo "Removed."
}

case "${1:-install}" in
install) install_service ;;
uninstall) uninstall_service ;;
status)
    systemctl status ups-power --no-pager || true
    bash "$DIR/ups-power.sh" status
    ;;
*) die "Use one of: install, uninstall, status" ;;
esac
