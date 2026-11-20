#!/bin/bash

# Turn on Wake-on-LAN, so a hibernated server can be woken after a power cut
# Show when on: nutcase
#
# Run with: ./manage.sh run ups-power wakeonlan [show|apply] [interface]
#
# "show" (the default) says whether the network card can wake the server and
# what it is set to now. "apply" turns it on straight away with ethtool, which
# doesn't drop the connection, and saves it for the next boot through
# NetworkManager. The BIOS has to allow waking by LAN too (often "Wake on LAN",
# "Power on by PCI-E", with "ErP" turned off), including from hibernation (S4).

set -e
# shellcheck source=/dev/null
source "$MANAGE_SH"
cd "$(dirname "$MANAGE_SH")" || die "Could not find the repository."

action=${1:-show}
iface=${2:-$(ip route show default 2>/dev/null | awk '{ for (i = 1; i < NF; i++) if ($i == "dev") { print $(i + 1); exit } }')}
[ -n "$iface" ] && [ -e "/sys/class/net/$iface" ] || die "Couldn't find the network interface, name it like: ./manage.sh run ups-power wakeonlan show enp6s0"
need_tool ethtool "to check Wake-on-LAN" || die "ethtool is needed."

info=$(as_root ethtool "$iface" 2>/dev/null | grep -i 'wake-on') || die "ethtool couldn't read $iface."
supports=$(awk -F': *' '/Supports Wake-on/ { print $2 }' <<<"$info")
current=$(awk -F': *' '/^[[:space:]]*Wake-on/ { print $2 }' <<<"$info")
echo "Interface: $iface ($(cat "/sys/class/net/$iface/address"))"
echo "Supports:  ${supports:-unknown} (g = magic packet)"
echo "Now:       ${current:-unknown}"
[[ "$supports" == *g* ]] || die "$iface can't be woken by a magic packet."

connection=""
if command -v nmcli >/dev/null && nmcli -t -f RUNNING general 2>/dev/null | grep -q running; then
    connection=$(nmcli -g NAME,DEVICE connection show --active | awk -F: -v d="$iface" '$2 == d { print $1; exit }')
    [ -z "$connection" ] || echo "Saved by:  NetworkManager \"$connection\", wake-on-lan $(nmcli -g 802-3-ethernet.wake-on-lan connection show "$connection")"
fi

[ "$action" = apply ] || {
    echo
    echo "Nothing changed. Run with \"apply\" to turn it on."
    exit 0
}

ask "Turn on Wake-on-LAN for $iface?" || exit 0
as_root ethtool -s "$iface" wol g
echo "On now."
if [ -n "$connection" ]; then
    # Saved for the next time the connection starts, without restarting it now
    as_root nmcli connection modify "$connection" 802-3-ethernet.wake-on-lan magic
    echo "Saved in NetworkManager for the next boot."
else
    warn "Not using NetworkManager, so it isn't saved for the next boot. With netplan add \"wakeonlan: true\" to $iface, or with systemd-networkd set WakeOnLan=magic in its .link file."
fi
