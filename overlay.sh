#!/bin/bash

# Uses overlay to create a *-sync folder and a shared .overlay/* folder for
# sharing within docker (or elsewhere).

source .env

declare -a arr=("$PATH_AUDIOBOOKS" "$PATH_MOVIES" "$PATH_MUSIC" "$PATH_TV")

declare FSTAB_CHANGED=0
declare MOUNT_CHANGED=0

mount () {
    for i in "${arr[@]}"; do
        declare ROOT=$(dirname "$i")
        declare BASENAME=$(basename "$i")
        declare LOWERDIR=${ROOT}/${BASENAME%/}
        declare UPPERDIR=${ROOT}/${BASENAME%/}-sync
        declare WORKDIR=${ROOT}/.overlay/${BASENAME%/}-work
        declare MERGED=${ROOT}/.overlay/${BASENAME%/}
        declare OPTIONS="lowerdir=${LOWERDIR// /\\040},upperdir=${UPPERDIR// /\\040},workdir=${WORKDIR// /\\040},redirect_dir=off,metacopy=off,index=off,xino=off"

        mkdir -p "${LOWERDIR}" "${UPPERDIR}" "${WORKDIR}" "${MERGED}"

        if ! grep -q "overlay ${MERGED// /\\040} " /etc/fstab; then
            echo "# Overlay ${BASENAME%/}" | sudo tee -a /etc/fstab
            echo "overlay ${MERGED// /\\040} overlay ${OPTIONS} 0 2" | sudo tee -a /etc/fstab
            echo "Add mount for $MERGED"
            FSTAB_CHANGED=1
        elif grep -q "^# overlay ${MERGED// /\\040} " /etc/fstab; then
            sudo sed -i "s|^# \(overlay ${MERGED// /\\040} .*\)$|\\1|" /etc/fstab
            echo "Enable mount for $MERGED"
            FSTAB_CHANGED=1
        fi
    done

    if [ "$FSTAB_CHANGED" = "1" ]; then
        sudo systemctl daemon-reload
    fi

    for i in "${arr[@]}"; do
        declare ROOT=$(dirname "$i")
        declare BASENAME=$(basename "$i")
        declare MERGED=${ROOT}/.overlay/${BASENAME%/}

        if ! grep -qs "overlay ${MERGED// /\\040} " /proc/mounts; then
            echo "Mount $MERGED"
            sudo mount "${MERGED}"
            MOUNT_CHANGED=1
        fi
    done
}

unmount () {
    for i in "${arr[@]}"; do
        declare ROOT=$(dirname "$i")
        declare BASENAME=$(basename "$i")
        declare MERGED=${ROOT}/.overlay/${BASENAME%/}

        if grep -qs "overlay ${MERGED// /\\040} " /proc/mounts; then
            echo "Unmount $MERGED"
            sudo umount "${MERGED}"
            MOUNT_CHANGED=1
        fi
    done

    for i in "${arr[@]}"; do
        declare ROOT=$(dirname "$i")
        declare BASENAME=$(basename "$i")
        declare MERGED=${ROOT}/.overlay/${BASENAME%/}

        if grep -q "^overlay ${MERGED// /\\040} " /etc/fstab; then
            sudo sed -i "s|^\(overlay ${MERGED// /\\040} .*\)$|# \\1|" /etc/fstab
            echo "Disable mount for $MERGED"
            FSTAB_CHANGED=1
        fi
    done

    if [ "$FSTAB_CHANGED" = "1" ]; then
        sudo systemctl daemon-reload
    fi
}

refresh () {
    for i in "${arr[@]}"; do
        declare ROOT=$(dirname "$i")
        declare BASENAME=$(basename "$i")
        declare MERGED=${ROOT}/.overlay/${BASENAME%/}

        if grep -qs "overlay ${MERGED// /\\040} " /proc/mounts; then
            echo "Refresh $MERGED"
            sudo mount -o remount "${MERGED}"
            MOUNT_CHANGED=1
        fi
    done
    sudo sh -c "sync; echo 3 > /proc/sys/vm/drop_caches"
}

nothing () {
    if [ "$FSTAB_CHANGED" = "0" ] && [ "$MOUNT_CHANGED" = "0" ]; then
        echo "Nothing to do!"
    fi
}

if [ "$1" == "up" ]; then
    mount
    nothing
elif [ "$1" == "down" ]; then
    unmount
    nothing
elif [ "$1" == "refresh" ]; then
    refresh
    nothing
else
    echo "Usage:"
    echo "$(basename $0) up|down|refresh"
    echo ""
    echo "This will update /etc/fstab with the correct mountpoints to auto-mount"
    echo "at boot, and comment out if disabled."
fi
