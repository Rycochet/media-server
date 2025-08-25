#!/bin/bash

# Uses overlayfs to create a *-sync folder and a shared .overlay/* folder for
# sharing within docker (or elsewhere).

source .env

declare -a arr=("$PATH_AUDIOBOOKS" "$PATH_MOVIES" "$PATH_MUSIC" "$PATH_TV")

mount () {
    for i in "${arr[@]}"; do
        declare ROOT=$(dirname "$i")
        declare BASENAME=$(basename "$i")
        declare LOWERDIR=${ROOT}/${BASENAME%/}
        declare UPPERDIR=${ROOT}/${BASENAME%/}-sync
        declare WORKDIR=${ROOT}/.overlay/${BASENAME%/}-work
        declare MERGED=${ROOT}/.overlay/${BASENAME%/}

        mkdir -p ${LOWERDIR} ${UPPERDIR} ${WORKDIR} ${MERGED}

        echo sudo mount -t overlay overlay -o"lowerdir=${LOWERDIR},upperdir=${UPPERDIR},workdir=${WORKDIR},redirect_dir=off,metacopy=off,index=off,xino=off" "${MERGED}"
        sudo mount -t overlay overlay -o"lowerdir=${LOWERDIR},upperdir=${UPPERDIR},workdir=${WORKDIR},redirect_dir=off,metacopy=off,index=off,xino=off" "${MERGED}"
    done
}

unmount () {
    for i in "${arr[@]}"; do
        declare ROOT=$(dirname "$i")
        declare BASENAME=$(basename "$i")
        declare MERGED=${ROOT}/.overlay/${BASENAME%/}

        echo sudo umount ${MERGED}
        sudo umount ${MERGED}
    done
}

if [ "$1" == "up" ]; then
    mount
elif [ "$1" == "down" ]; then
    unmount
else
    echo "Usage:"
    echo "$(basename $0) up|down"
fi
