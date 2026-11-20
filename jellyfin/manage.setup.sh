#!/bin/bash

# Trust Traefik's forwarded addresses and match hardware acceleration to USE_GPU
#
# This is run by manage.enable.sh when Jellyfin is turned on. Run it again
# after changing USE_GPU with:
#   ./manage.sh run jellyfin setup
#
# Jellyfin only makes its settings files the first time it starts, so if they
# aren't there yet it is started once and stopped when they are. Then:
#   - The "internal" docker network is added to Known Proxies, so Jellyfin
#     sees the address Traefik forwards instead of Traefik's own. The whole
#     network is used as Traefik's address changes when it is recreated.
#   - Hardware acceleration is set from USE_GPU in .env: nvidia uses NVENC,
#     intel uses QSV (or VAAPI if that is already chosen), amd uses VAAPI, and
#     none turns it off.
# Jellyfin only reads these when it starts, so it is stopped while they are
# changed and started again afterwards.

# shellcheck source=/dev/null
source "$MANAGE_SH"
cd "$(dirname "$MANAGE_SH")" || die "Could not find the repository."

NETWORK_XML=jellyfin/config/network.xml
ENCODING_XML=jellyfin/config/encoding.xml
DOCKER_NETWORK=internal

[ -f "$ENV_FILE" ] || die "There is no $ENV_FILE file, run \"./manage.sh install\" first."

later() {
    echo "$1, so Jellyfin hasn't been set up yet."
    echo "Run \"./manage.sh run jellyfin setup\" once it is, to set Known Proxies and hardware acceleration."
    exit 0
}

docker_ready || later "Docker isn't running"
docker compose config --services 2>/dev/null | grep -qx jellyfin || later "Jellyfin isn't turned on in docker compose"

# Print the value of an element, which is empty for "<Name />"
xml_value() {
    sed -n "s:.*<$2>\(.*\)</$2>.*:\1:p" "$1" | tr -d '\r' | head -n 1
}

# Print each <string> in a list element, one per line
xml_list() {
    awk -v name="$2" '
    { sub(/\r$/, "") }
    $0 ~ "<" name " */>" { exit }
    $0 ~ "<" name ">" { inside = 1 }
    inside {
        line = $0
        while (match(line, /<string>[^<]*<\/string>/)) {
            print substr(line, RSTART + 8, RLENGTH - 17)
            line = substr(line, RSTART + RLENGTH)
        }
    }
    $0 ~ "</" name ">" { exit }
    ' "$1"
}

# Replace an element with the given lines, or add them before the root closes
awk_set_xml() {
    awk -v BINMODE=3 -v name="$2" -v lines="$3" '
    function put() {
        if (!done) printf "%s", lines
        done = 1
    }
    { eol = sub(/\r$/, "") ? "\r" : "" }
    skip {
        if ($0 ~ "</" name ">") skip = 0
        next
    }
    $0 ~ "<" name "( */>|>.*</" name ">)" { gsub(/\n/, eol "\n", lines); put(); next }
    $0 ~ "<" name ">" { gsub(/\n/, eol "\n", lines); put(); skip = 1; next }
    /^<\/[A-Za-z]+>/ { gsub(/\n/, eol "\n", lines); put() }
    { print $0 eol }
    ' "$1"
}

set_value() {
    rewrite "$1" awk_set_xml "$1" "$2" "  <$2>$3</$2>"$'\n'
}

set_list() {
    local file=$1 name=$2 item lines="  <$2>"$'\n'
    shift 2
    for item in "$@"; do
        lines+="    <string>$item</string>"$'\n'
    done
    rewrite "$file" awk_set_xml "$file" "$name" "$lines  </$name>"$'\n'
}

network_subnets() {
    docker network inspect "$DOCKER_NETWORK" --format '{{range .IPAM.Config}}{{.Subnet}} {{end}}' 2>/dev/null
}

# Jellyfin makes network.xml when it first starts, and starting it also makes
# the docker network if the stack hasn't been started yet
if [ ! -f "$NETWORK_XML" ] || [ -z "$(network_subnets)" ]; then
    echo "Starting Jellyfin once so it makes its settings..."
    docker compose up -d jellyfin || die "Could not start Jellyfin."
    echo "Waiting for Jellyfin to make $NETWORK_XML..."
    for _ in $(seq 100); do
        [ -f "$NETWORK_XML" ] && break
        sleep 3
    done
    [ -f "$NETWORK_XML" ] || die "Jellyfin didn't make $NETWORK_XML, see: docker compose logs jellyfin"
    # Give it a moment to finish writing its other files
    sleep 5
fi

echo "Stopping Jellyfin to change its settings..."
docker compose stop jellyfin >/dev/null || die "Could not stop Jellyfin."

# Known Proxies - keep whatever is there and add the network Traefik is on
read -r -a subnets <<<"$(network_subnets)"
if [ "${#subnets[@]}" -eq 0 ]; then
    warn "Could not find the \"$DOCKER_NETWORK\" docker network, so Known Proxies wasn't changed."
else
    mapfile -t proxies < <(xml_list "$NETWORK_XML" KnownProxies)
    added=0
    for subnet in "${subnets[@]}"; do
        printf '%s\n' "${proxies[@]}" | grep -qxF "$subnet" && continue
        proxies+=("$subnet")
        added=1
    done
    if [ "$added" -eq 1 ]; then
        set_list "$NETWORK_XML" KnownProxies "${proxies[@]}"
        echo "Added ${subnets[*]} to Jellyfin's Known Proxies."
    else
        echo "Jellyfin's Known Proxies already has ${subnets[*]}."
    fi
fi

# Hardware acceleration - Jellyfin doesn't always make encoding.xml on its first
# start, and fills in anything missing from it with the defaults
if [ ! -f "$ENCODING_XML" ]; then
    printf '%s\n' '<?xml version="1.0" encoding="utf-8"?>' \
        '<EncodingOptions xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:xsd="http://www.w3.org/2001/XMLSchema">' \
        '</EncodingOptions>' >"$ENCODING_XML" || die "Could not create $ENCODING_XML."
fi

gpu=$(env_get USE_GPU) || gpu=""
current=$(xml_value "$ENCODING_XML" HardwareAccelerationType)
case "${gpu:-none}" in
nvidia) accel=nvenc ;;
intel) [ "$current" = vaapi ] && accel=vaapi || accel=qsv ;;
amd) accel=vaapi ;;
none) accel=none ;;
*)
    warn "USE_GPU is \"$gpu\", which isn't none, amd, intel or nvidia, so hardware acceleration wasn't changed."
    accel=""
    ;;
esac

if [ -n "$accel" ]; then
    if [ "$current" = "$accel" ]; then
        echo "Jellyfin's hardware acceleration is already $accel."
    else
        set_value "$ENCODING_XML" HardwareAccelerationType "$accel"
        echo "Set Jellyfin's hardware acceleration to $accel (it was ${current:-not set})."
    fi
    if [ "$accel" != none ] && [ "$(xml_value "$ENCODING_XML" EnableHardwareEncoding)" != true ]; then
        set_value "$ENCODING_XML" EnableHardwareEncoding true
        echo "Turned on hardware encoding."
    fi
    if [ "$accel" != none ]; then
        echo "Check which codecs your GPU can decode in Dashboard -> Playback -> Transcoding, and untick the rest."
    fi
fi

# Jellyfin runs as PUID:PGID, which needs to be allowed to use the GPU device
# for VAAPI and QSV (the nvidia runtime handles this itself)
if [ "$accel" = vaapi ] || [ "$accel" = qsv ]; then
    device=/dev/dri/renderD128
    pgid=$(env_get PGID) || pgid=1000
    if [ ! -e "$device" ]; then
        warn "There is no $device, so Jellyfin can't use the GPU."
    elif gid=$(stat -c %g "$device") && [ "$gid" != "${pgid:-1000}" ]; then
        warn "$device belongs to group $gid, which Jellyfin isn't in. Add this to jellyfin in $OVERRIDE:"
        echo "    group_add:"
        echo "      - \"$gid\""
    fi
fi

echo "Starting Jellyfin again..."
docker compose up -d jellyfin || die "Could not start Jellyfin."
