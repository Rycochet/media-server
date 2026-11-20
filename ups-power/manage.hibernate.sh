#!/bin/bash

# Set up hibernation to a swap file, so ups-power can hibernate the server
# Show when on: nutcase
#
# Run with: ./manage.sh run ups-power hibernate [show|apply]
#
# Hibernation saves memory to swap, and the kernel needs to be told where that
# is to resume from it. "show" (the default) only prints what it would change.
# "apply" writes it and rebuilds the boot files - it never reboots, the
# settings take effect after the next reboot.
#
# For Ubuntu and Debian with GRUB and initramfs-tools, hibernating to a swap
# file on ext4. If the swap file is ever recreated or moved its offset changes,
# so run this again afterwards.

set -e
# shellcheck source=/dev/null
source "$MANAGE_SH"
cd "$(dirname "$MANAGE_SH")" || die "Could not find the repository."

GRUB_FILE=/etc/default/grub.d/ups-power-resume.cfg
RESUME_FILE=/etc/initramfs-tools/conf.d/resume

grep -qw disk /sys/power/state 2>/dev/null || die "This kernel can't hibernate (no \"disk\" in /sys/power/state)."
if grep -q '\[\(integrity\|confidentiality\)\]' /sys/kernel/security/lockdown 2>/dev/null; then
    die "Kernel lockdown is on (usually Secure Boot), which blocks hibernation."
fi
command -v update-initramfs >/dev/null && command -v update-grub >/dev/null ||
    die "This only knows GRUB with initramfs-tools (Ubuntu, Debian)."

# The biggest swap file, as hibernating to a partition needs no offset
swap=$(awk 'NR > 1 && $2 == "file" { print $3, $1 }' /proc/swaps | sort -rn | awk 'NR == 1 { print $2 }')
[ -n "$swap" ] || die "There's no swap file. A swap partition only needs resume=UUID=<its uuid>, set that by hand."
fstype=$(findmnt -no FSTYPE -T "$swap")
[ "$fstype" = ext4 ] || [ "$fstype" = xfs ] || die "$swap is on $fstype, hibernating to a swap file needs ext4 or xfs."
uuid=$(findmnt -no UUID -T "$swap")
[ -n "$uuid" ] || die "Could not find the UUID of the filesystem holding $swap."
offset=$(as_root filefrag -v "$swap" | awk '$1 == "0:" { sub(/\.\.$/, "", $4); print $4; exit }')
[[ "$offset" =~ ^[0-9]+$ ]] || die "Could not find where $swap starts on the disk."

swap_kb=$(awk -v f="$swap" '$1 == f { print $3 }' /proc/swaps)
used_kb=$(awk '/^MemTotal:/ { t = $2 } /^MemAvailable:/ { a = $2 } END { print t - a }' /proc/meminfo)
params="resume=UUID=$uuid resume_offset=$offset"

echo "Swap file:   $swap ($((swap_kb / 1024 / 1024)) GB, on $fstype)"
echo "Memory used: $((used_kb / 1024 / 1024)) GB, which has to fit in swap's free space when hibernating"
echo "Kernel:      $params"
echo
echo "$GRUB_FILE would hold:"
echo "  GRUB_CMDLINE_LINUX_DEFAULT=\"\$GRUB_CMDLINE_LINUX_DEFAULT $params\""
echo "$RESUME_FILE would hold:"
echo "  RESUME=UUID=$uuid resume_offset=$offset"
if grep -q "resume_offset=$offset" /proc/cmdline; then
    echo
    echo "The running kernel already has these settings."
fi

[ "${1:-show}" = apply ] || {
    echo
    echo "Nothing changed. Run with \"apply\" to write these."
    exit 0
}

ask "Write these and rebuild the initramfs and GRUB config?" || exit 0
as_root mkdir -p "$(dirname "$GRUB_FILE")"
echo "GRUB_CMDLINE_LINUX_DEFAULT=\"\$GRUB_CMDLINE_LINUX_DEFAULT $params\"" | as_root tee "$GRUB_FILE" >/dev/null
echo "RESUME=UUID=$uuid resume_offset=$offset" | as_root tee "$RESUME_FILE" >/dev/null
as_root update-initramfs -u
as_root update-grub
echo
echo "Done. Hibernation will work after the next reboot - nothing has been rebooted."
echo "To undo: sudo rm $GRUB_FILE $RESUME_FILE && sudo update-initramfs -u && sudo update-grub"
