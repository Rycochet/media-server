#!/bin/bash

# Uses overlay to create a *-sync folder and a shared .overlay/* folder for
# sharing within docker (or elsewhere).

# Given that this is likely on a running system where the 2nd layer is often
# being edited it is worth having this as a cron job every hour

# 0 * * * * /bin/bash /path/to/overlay.sh refresh 2>&1 | /usr/bin/logger -t overlay

# Make sure we have the right .env file path relative to this script
OPT_ENV="$(dirname "$(realpath $0)")/.env"
OPT_FORCE=

declare -a arr=()

declare FSTAB_CHANGED=0
declare MOUNT_CHANGED=0

up () {
    for i in "${arr[@]}"; do
        declare ROOT=$(dirname "$i")
        declare BASENAME=$(basename "$i")
        declare LOWERDIR=${ROOT}/${BASENAME%/}
        declare UPPERDIR=${ROOT}/${BASENAME%/}-sync
        declare WORKDIR=${ROOT}/.overlay/${BASENAME%/}-work
        declare MERGED=${ROOT}/.overlay/${BASENAME%/}
        declare OPTIONS="lowerdir=${LOWERDIR// /\\040},upperdir=${UPPERDIR// /\\040},workdir=${WORKDIR// /\\040},redirect_dir=off,metacopy=off,index=off,xino=off,nofail,noauto,x-systemd.automount"

        mkdir -p "${LOWERDIR}" "${UPPERDIR}" "${WORKDIR}" "${MERGED}"

        if ! grep -q "overlay ${MERGED// /\\040} " /etc/fstab; then
            echo "# Overlay ${BASENAME%/}" | sudo tee -a /etc/fstab
            echo "overlay ${MERGED// /\\040} overlay ${OPTIONS} 0 2" | sudo tee -a /etc/fstab
            echo "Add mount for $BASENAME"
            FSTAB_CHANGED=1
        elif grep -q "^# overlay ${MERGED// /\\040} " /etc/fstab; then
            sudo sed -i "s|^# \(overlay ${MERGED// /\\040} .*\)$|\\1|" /etc/fstab
            echo "Enable mount for $BASENAME"
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
            echo "Mount $BASENAME"
            sudo mount $OPT_FORCE "${MERGED}"
            MOUNT_CHANGED=1
        fi
    done
}

down () {
    for i in "${arr[@]}"; do
        declare ROOT=$(dirname "$i")
        declare BASENAME=$(basename "$i")
        declare MERGED=${ROOT}/.overlay/${BASENAME%/}

        if grep -qs "overlay ${MERGED// /\\040} " /proc/mounts; then
            echo "Unmount $BASENAME"
            sudo umount $OPT_FORCE "${MERGED}"
            MOUNT_CHANGED=1
        fi
    done

    for i in "${arr[@]}"; do
        declare ROOT=$(dirname "$i")
        declare BASENAME=$(basename "$i")
        declare MERGED=${ROOT}/.overlay/${BASENAME%/}

        if grep -q "^overlay ${MERGED// /\\040} " /etc/fstab; then
            sudo sed -i "s|^\(overlay ${MERGED// /\\040} .*\)$|# \\1|" /etc/fstab
            echo "Disable mount for $BASENAME"
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
            echo "Refresh $BASENAME"
            sudo mount $OPT_FORCE -o remount "${MERGED}"
            MOUNT_CHANGED=1
        fi
    done
    sudo sh -c "sync; echo 3 > /proc/sys/vm/drop_caches"
}

diff () {
    if ! [ -x "$(command -v overlay)" ]; then
        echo "Error: overlayfs-tools is not installed. See https://github.com/kmxz/overlayfs-tools" >&2
        exit 1
    fi
    for i in "${arr[@]}"; do
        declare ROOT=$(dirname "$i")
        declare BASENAME=$(basename "$i")
        declare LOWERDIR=${ROOT}/${BASENAME%/}
        declare UPPERDIR=${ROOT}/${BASENAME%/}-sync

        echo "Diff for $BASENAME..."
        echo ""
        sudo overlay diff --ignore-mounted -l "${LOWERDIR}" -u "${UPPERDIR}"
        echo ""
    done
}

merge () {
    if ! [ -x "$(command -v overlay)" ]; then
        echo "Error: overlayfs-tools is not installed. See https://github.com/kmxz/overlayfs-tools" >&2
        exit 1
    fi
    for i in "${arr[@]}"; do
        declare ROOT=$(dirname "$i")
        declare BASENAME=$(basename "$i")
        declare LOWERDIR=${ROOT}/${BASENAME%/}
        declare UPPERDIR=${ROOT}/${BASENAME%/}-sync

        echo "Merge for $BASENAME..."
        echo ""
        sudo overlay merge $OPT_FORCE --ignore-mounted -l "${LOWERDIR}" -u "${UPPERDIR}"
        if [ "$OPT_FORCE" = "-f" ]; then
            refresh
        else
            echo "Run \"$0 refresh\" when completed"
        fi
        echo ""
    done
}

nothing () {
    if [ "$FSTAB_CHANGED" = "0" ] && [ "$MOUNT_CHANGED" = "0" ]; then
        echo "Nothing to do!"
    fi
}

help () {
    echo "Usage: $(basename $0) [OPTIONS] COMMAND"
    echo ""
    echo "Manage overlay mounts for media folders to keep original media safe from accidental writes."
    echo "This updates /etc/fstab so the current state persists at boot time"
    echo "The default paths come from the following env vars: PATH_AUDIOBOOKS, PATH_MOVIES, PATH_MUSIC, PATH_TV"
    echo ""
    echo "The *new* folder is at \"<path>/.overlay/<name>\", with any new files from there at \"<path>/<name>-sync\""
    echo ""
    echo "NOTE: This needs root permission to run and will ask for it if not run under sudo"
    echo ""
    echo "Commands:"
    echo "  diff      Show a diff of all mountpoints"
    echo "  down      Unmount and disable all mountpoints"
    echo "  merge     Merge the sync data into the original folder"
    echo "  refresh   Update data on mounts without needing to unmount them"
    echo "  up        Create and mount all mountpoints"
    echo ""
    echo "Options:"
    echo "  -e, --env file      Path to the .env file to load for default paths, it will use one next to this script if not specified"
    echo "  -f, --force         Pass '--force' to the mount / umount commands"
    echo "  -p, --path folder   Add folder to list of overlays, you can pass this option multiple times"
    echo "                      NOTE: This will prevent the default paths from being used"
}

while [[ $# -gt 0 ]]; do
    case $1 in
        -e|--env)
            shift # argument
            OPT_ENV="$1"
            shift # value
            ;;
        -f|--force)
            OPT_FORCE=-f
            shift # argument
            ;;
        -p|--path)
            shift # argument
            arr+=("$1")
            shift # value
            ;;
        --help)
            help
            exit 0
            ;;
        -*|--*)
            echo "Unknown option $1"
            exit 1
            ;;
        *)
            if [ ${#arr[@]} -eq 0 ]; then
                source $OPT_ENV

                arr+=("$PATH_AUDIOBOOKS")
                arr+=("$PATH_MOVIES")
                arr+=("$PATH_MUSIC")
                arr+=("$PATH_TV")
            fi
            case $1 in
                up)      up ;;
                down)    down ;;
                refresh) refresh ;;
                diff)    diff ; exit 0 ;;
                merge)    merge ; exit 0 ;;
                *)
                    echo "Unknown command $1"
                    exit 1
                    ;;
            esac
            nothing
            exit 0
        ;;
    esac
done

help
