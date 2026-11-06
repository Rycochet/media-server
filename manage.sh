#!/bin/bash

# Sets up and looks after this stack: makes your own settings files from the
# examples, turns services on and off, and runs the extra scripts that service
# folders can have. Run it without a command for a menu.
#
# Service folders can have their own scripts, found by their names:
#   manage.enable.sh    Run after the service is turned on
#   manage.disable.sh   Run after the service is turned off
#   manage.<name>.sh    A tool for the service, the first comment describes it
#
# Tools are only offered while their service is turned on. To show one for
# other services instead, add a comment near the top naming them - it shows
# when any of them are on:
#   # Show when on: sonarr radarr
#
# They are run with bash from the repository folder, with SERVICE (the folder
# name) set. To use the helpers in here (ask, need_tool, env_get, env_set...)
# they can run: source "$MANAGE_SH"
#
# Template files are copied into place when a service is turned on, with "__"
# used for "/" in the name - "config__folder__my_file.ext.template" is copied
# to "config/folder/my_file.ext" if that doesn't exist yet.
#
# Values in .env.example of "<random>" are filled with a random string, and
# "<insert ...>" are asked for, when the service they're in is turned on.
#
# Everything lives in functions and main is called from the very last line, as
# bash reads scripts while running them and an update can replace this file.

ENV_FILE=.env
ENV_EXAMPLE=.env.example
OVERRIDE=compose.override.yaml
OVERRIDE_TEMPLATE=compose.override.yaml.template
AUTO_YES=${AUTO_YES:-0}
IN_MENU=0
TMP_FILE=""
SCREEN_ACTIVE=0

# Where the arrow key grid is, and how it was last drawn
CURSOR=0
TOP=0
GRID_ROWS=1
GRID_VISIBLE=1
GRID_DRAWN=0
declare -gA BACKED_UP=()

# Every include line in the override template, and what is known about them
declare -ga ITEMS=()
declare -gA ITEM_NAME=() ITEM_PATH=() ITEM_PROFILE=() ITEM_DESC=() ENABLED=() PENDING=()

usage() {
    cat <<EOF
Usage: $(basename "$0") [-y] [command]

  install               First time setup, safe to run again
  services              Choose which services to run
  on <service...>       Turn services on
  off <service...>      Turn services off
  info <service>        Show what a service does
  tools [service]       List the extra scripts for services
  run <service> <tool>  Run one of those scripts
  start                 Start everything that is turned on
  update [options]      Get the latest version (see update.sh -h)

  -y    Don't ask, use the default answers

With no command a menu is shown.
EOF
}

warn() {
    echo "WARNING: $*" >&2
}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

on_exit() {
    [ -n "$TMP_FILE" ] && rm -f "$TMP_FILE"
    leave_screen
}

# Ask a yes / no question, the second argument is the default answer
ask() {
    local answer default=${2:-y} hint="[Y/n]"
    [ "$default" = y ] || hint="[y/N]"
    if [ "$AUTO_YES" -eq 1 ]; then
        [ "$default" = y ]
        return
    fi
    while true; do
        read -r -p "$1 $hint " answer || answer=""
        case "${answer:-$default}" in
        y | Y | yes) return 0 ;;
        n | N | no) return 1 ;;
        esac
    done
}

# Print the answer to a question, or the default when nothing is typed
ask_value() {
    local answer
    if [ "$AUTO_YES" -eq 1 ]; then
        echo "$2"
        return
    fi
    read -r -p "$1${2:+ [$2]}: " answer || answer=""
    echo "${answer:-$2}"
}

as_root() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    elif command -v sudo >/dev/null; then
        sudo "$@"
    else
        warn "This needs to run as root, and sudo isn't installed: $*"
        return 1
    fi
}

package_install() {
    if command -v apt-get >/dev/null; then
        as_root apt-get update -qq && as_root apt-get install -y "$@"
    elif command -v dnf >/dev/null; then
        as_root dnf install -y "$@"
    elif command -v yum >/dev/null; then
        as_root yum install -y "$@"
    elif command -v pacman >/dev/null; then
        as_root pacman -S --needed --noconfirm "$@"
    elif command -v zypper >/dev/null; then
        as_root zypper --non-interactive install "$@"
    elif command -v apk >/dev/null; then
        as_root apk add "$@"
    else
        warn "Couldn't find a package manager, please install this yourself: $*"
        return 1
    fi
}

# Make sure a command exists, offering to install it if it doesn't
# need_tool <command> <what it's needed for> [package name]
need_tool() {
    command -v "$1" >/dev/null && return 0
    echo "\"$1\" is needed $2, but it isn't installed."
    ask "Install it now?" || return 1
    package_install "${3:-$1}" && command -v "$1" >/dev/null
}

docker_ready() {
    command -v docker >/dev/null && docker compose version >/dev/null 2>&1 && docker info >/dev/null 2>&1
}

check_docker() {
    local installer
    if ! command -v docker >/dev/null; then
        echo "Docker isn't installed, and everything here runs inside it."
        ask "Install it now with the official script from get.docker.com?" || die "Docker is needed, see https://docs.docker.com/engine/install/"
        need_tool curl "to download the Docker installer" || die "Could not install curl."
        installer=$(mktemp) || die "Could not create a temporary file."
        TMP_FILE=$installer
        curl -fsSL https://get.docker.com -o "$installer" || die "Could not download the Docker installer."
        as_root sh "$installer" || die "Docker did not install correctly."
        rm -f "$installer"
        TMP_FILE=""
    fi
    docker compose version >/dev/null 2>&1 || die "The docker compose plugin is missing, see https://docs.docker.com/compose/install/linux/"
    docker info >/dev/null 2>&1 && return 0

    if docker info 2>&1 | grep -qi "permission denied"; then
        echo "Your user isn't allowed to use Docker yet."
        if ask "Add \"$(id -un)\" to the docker group?"; then
            as_root usermod -aG docker "$(id -un)" || die "Could not add you to the docker group."
            echo "Done, log out and back in for it to work, then run this again."
        fi
        exit 1
    fi
    die "Docker doesn't seem to be running, try: sudo systemctl start docker"
}

backup_once() {
    if [ -z "${BACKED_UP[$1]:-}" ]; then
        cp -p "$1" "$1.bak" || die "Could not back up $1."
        BACKED_UP[$1]=1
    fi
}

# Replace a file from the output of the given command, keeping its permissions
rewrite() {
    local file=$1
    shift
    TMP_FILE=$(mktemp "$file.XXXXXX") || die "Could not create a temporary file for $file."
    cp -p "$file" "$TMP_FILE" || die "Could not copy $file."
    "$@" >"$TMP_FILE" || die "Could not update $file."
    backup_once "$file"
    mv "$TMP_FILE" "$file" || die "Could not replace $file."
    TMP_FILE=""
}

# Print a value from the .env file (or another), without quotes around it
env_get() {
    awk -v key="$1" '
    { sub(/\r$/, "") }
    index($0, key "=") == 1 { value = substr($0, length(key) + 2); found = 1 }
    END {
        if (value ~ /^".*"$/ || value ~ /^\047.*\047$/) value = substr(value, 2, length(value) - 2)
        if (found) print value
        exit !found
    }
    ' "${2:-$ENV_FILE}" 2>/dev/null
}

awk_env_set() {
    KEY="$2" VALUE="$3" awk -v BINMODE=3 '
    BEGIN { key = ENVIRON["KEY"]; line = key "=\"" ENVIRON["VALUE"] "\"" }
    {
        eol = sub(/\r$/, "") ? "\r" : ""
        if (index($0, key "=") == 1) { $0 = line; done = 1 }
        print $0 eol
    }
    END { if (!done) print line eol }
    ' "$1"
}

# Set a value in the .env file, changing every line that has it
env_set() {
    local value=$2
    value=${value//\\/\\\\}
    value=${value//\"/\\\"}
    [ -f "${3:-$ENV_FILE}" ] || die "There is no ${3:-$ENV_FILE} file to change."
    rewrite "${3:-$ENV_FILE}" awk_env_set "${3:-$ENV_FILE}" "$1" "$value"
}

# Print the lines in an env file that come under "##### name #####"
env_section() {
    awk -v name="$1" '
    { sub(/\r$/, "") }
    /^#####/ {
        title = $0
        sub(/^#+[ \t]+/, "", title)
        sub(/[ \t]+#+[ \t]*$/, "", title)
        inside = (title == name)
        next
    }
    inside { print }
    ' "$2" 2>/dev/null
}

random_secret() {
    LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c "${1:-48}"
}

# Fill in "<random>" and "<insert ...>" values for a service
fill_placeholders() {
    local line key value pattern='^([A-Za-z_][A-Za-z0-9_]*)="?(<[^>]*>)"?$'
    [ -f "$ENV_FILE" ] || return 0
    # The list is read from another file descriptor, so the questions can read from the user
    while IFS= read -r line <&3; do
        [[ "$line" =~ $pattern ]] || continue
        key=${BASH_REMATCH[1]}
        value=${BASH_REMATCH[2]}
        if [ "$value" = "<random>" ]; then
            env_set "$key" "$(random_secret)"
            echo "Set $key to a random value."
        elif [ "$AUTO_YES" -eq 0 ]; then
            echo "$key needs a value (${value:1:-1})."
            if [[ "$key" == *PASSWORD* ]]; then
                read -r -s -p "Type it here, or leave it empty to do it later: " value || value=""
                echo
            else
                read -r -p "Type it here, or leave it empty to do it later: " value || value=""
            fi
            [ -z "$value" ] || env_set "$key" "$value"
        fi
    done 3< <(env_section "$1" "$ENV_FILE")
}

# Copy a service's templates into place, if they aren't there already
copy_templates() {
    local template name target
    for template in "$1"/*.template; do
        [ -f "$template" ] || continue
        name=$(basename "$template" .template)
        target="$1/${name//__//}"
        [ ! -e "$target" ] || continue
        mkdir -p "$(dirname "$target")" && cp "$template" "$target" || die "Could not create $target."
        echo "Created $target"
    done
}

# Run a script from a service folder, if it exists
run_script() {
    local script="$1/manage.$2.sh"
    [ -f "$script" ] || return 0
    echo "Running $script..."
    AUTO_YES=$AUTO_YES MANAGE_SH="$PWD/manage.sh" SERVICE=$1 bash "$script" "${@:3}"
}

# Print the active entries in the top level include block
active_includes() {
    awk '
    { sub(/\r$/, "") }
    /^include:/ { inc = 1; next }
    /^[^ \t#]/ { inc = 0 }
    inc && /^[ \t]*-[ \t]+/ {
        sub(/^[ \t]*-[ \t]+/, "")
        sub(/^path:[ \t]*/, "")
        sub(/[ \t].*$/, "")
        gsub(/["\047]/, "")
        print
    }
    ' "$1" 2>/dev/null
}

# Turn an include on or off, adding it to the end of the block if it's missing
awk_set_include() {
    awk -v BINMODE=3 -v target="$2" -v mode="$3" '
    function pathof(s) {
        if (s !~ /^[ \t]*(#[ \t]*)?-[ \t]+/) return ""
        sub(/^[ \t]*(#[ \t]*)?-[ \t]+/, "", s)
        sub(/^path:[ \t]*/, "", s)
        sub(/[ \t].*$/, "", s)
        gsub(/["\047]/, "", s)
        return s
    }
    {
        eol[NR] = sub(/\r$/, "") ? "\r" : ""
        line[NR] = $0
        if ($0 ~ /^include:/) { inc = 1; last = NR; next }
        if ($0 ~ /^[^ \t#]/) inc = 0
        if (!inc) next
        if ($0 !~ /^[ \t]*$/) last = NR
        if (pathof($0) != target) next
        found = 1
        if (mode == "on") { if (line[NR] ~ /^[ \t]*#/) sub(/#[ \t]*-/, "-", line[NR]) }
        else if (line[NR] !~ /^[ \t]*#/) sub(/-/, "# -", line[NR])
    }
    END {
        for (i = 1; i <= NR; i++) {
            print line[i] eol[i]
            if (i == last && !found && mode == "on") print "  - " target eol[i]
        }
        if (!last && mode == "on") print "include:\n  - " target
    }
    ' "$1"
}

# "emby/compose.yaml" is called "emby", and "emby/compose.gatus.yaml" is "emby+gatus"
item_name() {
    local dir=${1%%/*} file=${1#*/}
    file=${file#compose}
    file=${file%.yaml}
    file=${file%.yml}
    file=${file#.}
    echo "$dir${file:++$file}"
}

load_items() {
    local path profile desc name
    ITEMS=()
    ITEM_NAME=()
    ITEM_PATH=()
    ITEM_PROFILE=()
    ITEM_DESC=()
    ENABLED=()
    PENDING=()
    while IFS='|' read -r path profile desc; do
        name=$(item_name "$path")
        ITEMS+=("$path")
        ITEM_NAME[$path]=$name
        ITEM_PATH[$name]=$path
        ITEM_PROFILE[$path]=$profile
        ITEM_DESC[$path]=$desc
    done < <(awk '
    function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
    { sub(/\r$/, "") }
    /^include:/ { inc = 1; next }
    /^[^ \t#]/ { inc = 0 }
    inc && /^[ \t]*(#[ \t]*)?-[ \t]+[^ \t]+\.ya?ml/ {
        line = $0
        sub(/^[ \t]*(#[ \t]*)?-[ \t]+/, "", line)
        path = line
        sub(/[ \t].*$/, "", path)
        gsub(/["\047]/, "", path)
        n = split(line, cols, "|")
        print path "|" (n >= 3 ? trim(cols[2]) : "") "|" (n >= 3 ? trim(cols[3]) : "")
    }
    ' "$OVERRIDE_TEMPLATE")
    while read -r path; do
        [ -z "${ITEM_NAME[$path]:-}" ] || ENABLED[$path]=1
    done < <(active_includes "$OVERRIDE")
    for path in "${!ENABLED[@]}"; do
        PENDING[$path]=1
    done
}

# Find an item from its name, number or path
find_item() {
    local word=$1
    [ -n "$word" ] || return 1
    if [[ "$word" =~ ^[0-9]+$ ]] && [ "$word" -ge 1 ] && [ "$word" -le "${#ITEMS[@]}" ]; then
        echo "${ITEMS[word - 1]}"
    elif [ -n "${ITEM_PATH[$word]:-}" ]; then
        echo "${ITEM_PATH[$word]}"
    elif [ -n "${ITEM_NAME[$word]:-}" ]; then
        echo "$word"
    else
        return 1
    fi
}

core_services() {
    active_includes compose.yaml | sed 's|/.*||' | sort -u
}

# Print the services that a compose file depends on
compose_depends() {
    awk '
    { sub(/\r$/, "") }
    /^[ \t]*(#|$)/ { next }
    {
        match($0, /^[ \t]*/)
        indent = RLENGTH
        if (deps && indent <= base) deps = 0
        if (deps) {
            if (!child) child = indent
            if (indent == child) {
                name = $0
                sub(/^[ \t]*(-[ \t]+)?/, "", name)
                sub(/:.*$/, "", name)
                gsub(/["\047]/, "", name)
                print name
            }
        }
        if ($0 ~ /^[ \t]*depends_on:[ \t]*$/) { deps = 1; base = indent; child = 0 }
    }
    ' "$1" 2>/dev/null | sort -u
}

# Print the other items that an item can't run without
item_needs() {
    local path=$1 dir=${1%%/*} name extra dep
    name=${ITEM_NAME[$path]}
    if [ "$name" != "$dir" ]; then
        [ -z "${ITEM_PATH[$dir]:-}" ] || echo "${ITEM_PATH[$dir]}"
        extra=${name#*+}
        [ -z "${ITEM_PATH[$extra]:-}" ] || echo "${ITEM_PATH[$extra]}"
    fi
    while read -r dep; do
        [ -n "$dep" ] && [ "$dep" != "$dir" ] && [ -n "${ITEM_PATH[$dep]:-}" ] && echo "${ITEM_PATH[$dep]}"
    done < <(compose_depends "$path")
}

turn_on() {
    local need
    [ -z "${PENDING[$1]:-}" ] || return 0
    PENDING[$1]=1
    while read -r need <&3; do
        [ -z "${PENDING[$need]:-}" ] || continue
        if ask "${ITEM_NAME[$1]} needs ${ITEM_NAME[$need]}, turn that on too?"; then
            turn_on "$need"
        fi
    done 3< <(item_needs "$1")
}

turn_off() {
    local path
    [ -n "${PENDING[$1]:-}" ] || return 0
    unset "PENDING[$1]"
    for path in "${!PENDING[@]}"; do
        item_needs "$path" | grep -qxF "$1" || continue
        if ask "${ITEM_NAME[$path]} needs ${ITEM_NAME[$1]}, turn that off too?"; then
            turn_off "$path"
        fi
    done
}

has_changes() {
    local path
    for path in "${ITEMS[@]}"; do
        [ "${PENDING[$path]:-}" = "${ENABLED[$path]:-}" ] || return 0
    done
    return 1
}

show_grid() {
    local count=${#ITEMS[@]} longest=0 width cols rows row col index path mark line cell
    for path in "${ITEMS[@]}"; do
        [ "${#ITEM_NAME[$path]}" -le "$longest" ] || longest=${#ITEM_NAME[$path]}
    done
    width=$(tput cols 2>/dev/null) || width=80
    cols=$((width / (longest + 10)))
    [ "$cols" -ge 1 ] || cols=1
    rows=$(((count + cols - 1) / cols))
    for ((row = 0; row < rows; row++)); do
        line=""
        for ((col = 0; col < cols; col++)); do
            index=$((col * rows + row))
            [ "$index" -lt "$count" ] || continue
            path=${ITEMS[index]}
            mark="[ ]"
            [ -z "${PENDING[$path]:-}" ] || mark="[*]"
            printf -v cell "%3d %s %-*s" $((index + 1)) "$mark" $((longest + 2)) "${ITEM_NAME[$path]}"
            line+=$cell
        done
        echo "${line%"${line##*[! ]}"}"
    done
}

item_summary() {
    local dir=${1%%/*} name=${ITEM_NAME[$1]}
    if [ "$name" = "$dir" ]; then
        echo "$name - ${ITEM_DESC[$1]:-no description}"
    else
        echo "$name - lets $dir work with ${name#*+}"
    fi
}

# Print the terminal's height and width
term_size() {
    local size
    size=$(stty size 2>/dev/null </dev/tty) || size=""
    [[ "$size" =~ ^[1-9][0-9]*\ [1-9][0-9]*$ ]] || size="24 80"
    echo "$size"
}

# Draw the grid with the cursor highlighted, scrolled so that it can be seen
draw_grid() {
    local count=${#ITEMS[@]} longest=0 height width cols rows row col index path mark cell line frame text
    for path in "${ITEMS[@]}"; do
        [ "${#ITEM_NAME[$path]}" -le "$longest" ] || longest=${#ITEM_NAME[$path]}
    done
    read -r height width < <(term_size)
    cols=$((width / (longest + 7)))
    [ "$cols" -ge 1 ] || cols=1
    rows=$(((count + cols - 1) / cols))
    GRID_ROWS=$rows
    # Four lines are kept below the grid for the details and questions
    GRID_VISIBLE=$((height - 4))
    [ "$GRID_VISIBLE" -ge 1 ] || GRID_VISIBLE=1
    row=$((CURSOR % rows))
    [ "$row" -ge "$TOP" ] || TOP=$row
    [ "$row" -lt $((TOP + GRID_VISIBLE)) ] || TOP=$((row - GRID_VISIBLE + 1))
    [ $((TOP + GRID_VISIBLE)) -le "$rows" ] || TOP=$((rows - GRID_VISIBLE))
    [ "$TOP" -ge 0 ] || TOP=0

    frame=$'\e[H'
    GRID_DRAWN=0
    for ((row = TOP; row < rows && row < TOP + GRID_VISIBLE; row++)); do
        line=""
        for ((col = 0; col < cols; col++)); do
            index=$((col * rows + row))
            [ "$index" -lt "$count" ] || continue
            path=${ITEMS[index]}
            mark="[ ]"
            [ -z "${PENDING[$path]:-}" ] || mark="[*]"
            printf -v cell "%s %-*s" "$mark" "$longest" "${ITEM_NAME[$path]}"
            if [ "$index" -eq "$CURSOR" ]; then
                line+=$' \e[7m'$cell$'\e[0m  '
            else
                line+=" $cell  "
            fi
        done
        frame+=$line$'\e[K\n'
        GRID_DRAWN=$((GRID_DRAWN + 1))
    done

    text=$(item_summary "${ITEMS[CURSOR]}")
    frame+=$'\e[J\n'${text:0:width}$'\n'
    text="Arrows move, space turns on/off, ? shows info, s saves, q quits"
    frame+=${text:0:width}$'\n'
    text=$1
    if [ -z "$text" ] && [ "$rows" -gt "$GRID_VISIBLE" ]; then
        text="Showing rows $((TOP + 1))-$((TOP + GRID_DRAWN)) of $rows"
    fi
    ! has_changes || text="${text:+$text, }changes not saved yet"
    frame+=${text:0:width}
    printf '%s' "$frame"
}

move_cursor() {
    local count=${#ITEMS[@]} next=$CURSOR
    case "$1" in
    up) next=$((CURSOR - 1)) ;;
    down) next=$((CURSOR + 1)) ;;
    left) next=$((CURSOR - GRID_ROWS)) ;;
    right)
        next=$((CURSOR + GRID_ROWS))
        # The last column can be shorter, so go to the end of it
        if [ "$next" -ge "$count" ] && [ $(((count - 1) / GRID_ROWS)) -gt $((CURSOR / GRID_ROWS)) ]; then
            next=$((count - 1))
        fi
        ;;
    pageup) next=$((CURSOR - GRID_VISIBLE)) && [ "$next" -ge 0 ] || next=0 ;;
    pagedown) next=$((CURSOR + GRID_VISIBLE)) && [ "$next" -lt "$count" ] || next=$((count - 1)) ;;
    home) next=0 ;;
    end) next=$((count - 1)) ;;
    esac
    [ "$next" -lt 0 ] || [ "$next" -ge "$count" ] || CURSOR=$next
}

# Move below the grid and show the cursor, so that a question can be asked
screen_prompt() {
    printf '\e[%d;1H\e[J\e[?25h' $((GRID_DRAWN + 2))
}

leave_screen() {
    [ "$SCREEN_ACTIVE" -eq 1 ] || return 0
    SCREEN_ACTIVE=0
    trap - INT WINCH
    printf '\e[?25h\e[?1049l'
}

toggle_item() {
    if [ -n "${PENDING[$1]:-}" ]; then
        turn_off "$1"
    else
        turn_on "$1"
    fi
}

# Choose services with the arrow keys, drawn on the terminal's alternate screen
# so that the screen is put back afterwards
choose_services_keys() {
    local key rest more status message=""
    CURSOR=0
    TOP=0
    SCREEN_ACTIVE=1
    trap 'exit 130' INT
    # Interrupts the read below, so the grid is drawn again at the new size
    trap ':' WINCH
    printf '\e[?1049h\e[?25l\e[H\e[J'
    while true; do
        draw_grid "$message"
        message=""
        IFS= read -rsn1 key
        status=$?
        [ "$status" -le 128 ] || continue
        if [ "$status" -ne 0 ]; then
            leave_screen
            load_items
            return 0
        fi
        # Special keys send an escape followed by a short code
        if [ "$key" = $'\e' ]; then
            rest=""
            more=""
            IFS= read -rsn2 -t 0.05 rest || true
            if [[ "$rest" =~ ^\[[0-9]$ ]]; then
                IFS= read -rsn1 -t 0.05 more || true
            fi
            key+=$rest$more
        fi
        case "$key" in
        $'\e[A' | $'\eOA') move_cursor up ;;
        $'\e[B' | $'\eOB') move_cursor down ;;
        $'\e[C' | $'\eOC') move_cursor right ;;
        $'\e[D' | $'\eOD') move_cursor left ;;
        $'\e[5~') move_cursor pageup ;;
        $'\e[6~') move_cursor pagedown ;;
        $'\e[H' | $'\eOH' | $'\e[1~') move_cursor home ;;
        $'\e[F' | $'\eOF' | $'\e[4~') move_cursor end ;;
        " " | "")
            screen_prompt
            toggle_item "${ITEMS[CURSOR]}"
            printf '\e[?25l'
            ;;
        "?")
            printf '\e[H\e[J\e[?25h'
            show_info "${ITEMS[CURSOR]}"
            IFS= read -rsn1 -p "Press any key to go back to the list." || true
            printf '\e[?25l\e[H\e[J'
            ;;
        s | S)
            leave_screen
            if save_items; then
                offer_start
            else
                echo "Nothing changed."
            fi
            return 0
            ;;
        q | Q | $'\e')
            if has_changes; then
                screen_prompt
                if ! ask "Quit without saving your changes?" n; then
                    printf '\e[?25l'
                    continue
                fi
            fi
            leave_screen
            load_items
            return 0
            ;;
        *) message="Unknown key, use the arrows, space, ?, s or q" ;;
        esac
    done
}

choose_services() {
    load_items
    if [ -t 0 ] && [ -t 1 ] && [ "$AUTO_YES" -eq 0 ]; then
        choose_services_keys
    else
        choose_services_typed
    fi
}

# Show where a service can be reached, using the table in README.md
show_address() {
    local dir=$1 row port sub domain
    row=$(grep -m1 "^| \`$dir\` " README.md 2>/dev/null) || return 0
    port=$(echo "$row" | awk -F'|' '{ gsub(/^[ \t]+|[ \t]+$/, "", $5); print $5 }')
    sub=$(echo "$row" | awk -F'|' '{ gsub(/^[ \t]+|[ \t]+$/, "", $6); gsub(/`/, "", $6); print $6 }')
    domain=$(env_get DOMAIN)
    domain=${domain:-<your domain>}
    case "$sub" in
    *✔*) sub=$(env_get "$(echo "${dir}_SUBDOMAIN" | tr 'a-z-' 'A-Z_')") || true; sub=${sub:-$dir} ;;
    *root*) sub="" ;;
    *❌* | "") sub="-" ;;
    esac
    [ "$port" = "*n/a*" ] || echo "  Port:       ${port//\`/}"
    if [ "$sub" = "-" ]; then
        echo "  Web page:   none"
    else
        echo "  Web page:   https://${sub:+$sub.}$domain/"
    fi
}

show_info() {
    local path=$1 dir=${1%%/*} name image tool item needs="" extras="" template target notes
    name=${ITEM_NAME[$path]}
    echo
    item_summary "$path"
    echo "  Turned:     $([ -n "${PENDING[$path]:-}" ] && echo on || echo off)"
    [ -z "${ITEM_PROFILE[$path]}" ] || echo "  Group:      ${ITEM_PROFILE[$path]}"
    if [ "$name" = "$dir" ]; then
        image=$(grep -m1 "^[ \t]*image:" "$path" | sed -E 's/^[ \t]*image:[ \t]*//; s/\$\{[A-Za-z0-9_]+:-([^}]*)\}/\1/g; s/["\047]//g')
        [ -z "$image" ] || echo "  Image:      $image"
        show_address "$dir"
        for item in "${ITEMS[@]}"; do
            [ "${item%%/*}" != "$dir" ] || [ "$item" = "$path" ] || extras+=" ${ITEM_NAME[$item]}"
        done
        [ -z "$extras" ] || echo "  Extras:    $extras"
    fi
    while read -r item; do
        needs+=" ${ITEM_NAME[$item]}"
    done < <(item_needs "$path")
    [ -z "$needs" ] || echo "  Needs:     $needs"
    while read -r item; do
        echo "  Tool:       $item - $(tool_description "$dir" "$item")"
    done < <(service_tools "$dir")
    for template in "$dir"/*.template; do
        [ -f "$template" ] || continue
        target=$(basename "$template" .template)
        target="$dir/${target//__//}"
        echo "  Template:   $target $([ -e "$target" ] && echo "(exists)" || echo "(made when turned on)")"
    done
    if [ "$name" = "$dir" ]; then
        notes=$(env_section "$dir" "$ENV_EXAMPLE" | grep '^#' | sed 's/^#[ \t]*/  /')
        [ -z "$notes" ] || printf "Notes from .env.example:\n%s\n" "$notes"
    fi
    echo
}

# Print the names of the tools a service folder has
service_tools() {
    local script name
    for script in "$1"/manage.*.sh; do
        [ -f "$script" ] || continue
        name=${script##*/manage.}
        name=${name%.sh}
        case "$name" in
        enable | disable) ;;
        *) echo "$name" ;;
        esac
    done
}

tool_description() {
    awk '/^#!/ { next } /^#/ { sub(/^#[ \t]*/, ""); print; exit } /^[^#]/ { exit }' "$1/manage.$2.sh"
}

# Print the services a tool is for, from a "# Show when on:" line in its first
# comments, or else the folder it is in
tool_services() {
    local services
    services=$(awk '
    /^#!/ { next }
    /^[^#]/ { exit }
    sub(/^#[ \t]*Show when on:[ \t]*/, "") { print; exit }
    ' "$1/manage.$2.sh")
    echo "${services:-$1}"
}

# Print the tools for services that are turned on
all_tools() {
    local dir tool path service
    local -A on=()
    while read -r path; do
        [ "${path#*/}" != compose.yaml ] || on[${path%%/*}]=1
    done < <(active_includes compose.yaml; active_includes "$OVERRIDE")
    for dir in */; do
        dir=${dir%/}
        while read -r tool; do
            for service in $(tool_services "$dir" "$tool"); do
                if [ -n "${on[$service]:-}" ]; then
                    echo "$dir $tool"
                    break
                fi
            done
        done < <(service_tools "$dir")
    done
}

check_compose() {
    docker_ready || return 0
    docker compose config --quiet >/dev/null 2>&1 && return 0
    warn "The docker compose settings have a problem:"
    docker compose config --quiet
    return 1
}

offer_start() {
    check_compose || return 1
    if ask "Start the services with the new settings now?"; then
        check_docker
        docker compose up -d --remove-orphans
    else
        echo "Run \"./manage.sh start\" when you're ready."
    fi
}

# Write the chosen services to compose.override.yaml, then prepare them
save_items() {
    local path dir changed=0
    [ -f "$OVERRIDE" ] || die "There is no $OVERRIDE file, run \"./manage.sh install\" first."
    for path in "${ITEMS[@]}"; do
        [ "${PENDING[$path]:-}" != "${ENABLED[$path]:-}" ] || continue
        dir=${path%%/*}
        changed=1
        if [ -n "${PENDING[$path]:-}" ]; then
            rewrite "$OVERRIDE" awk_set_include "$OVERRIDE" "$path" on
            echo "Turned on ${ITEM_NAME[$path]}"
            copy_templates "$dir"
            if [ "$path" = "$dir/compose.yaml" ]; then
                fill_placeholders "$dir"
                run_script "$dir" enable || warn "$dir/manage.enable.sh did not finish correctly."
            fi
        else
            rewrite "$OVERRIDE" awk_set_include "$OVERRIDE" "$path" off
            echo "Turned off ${ITEM_NAME[$path]}"
            if [ "$path" = "$dir/compose.yaml" ]; then
                run_script "$dir" disable || warn "$dir/manage.disable.sh did not finish correctly."
            fi
        fi
    done
    load_items
    [ "$changed" -eq 1 ]
}

# Choose services by typing their numbers or names, for when there's no terminal
choose_services_typed() {
    local answer word path first last i
    while true; do
        echo
        show_grid
        echo
        echo "Type numbers or names to turn them on or off (like \"3 7 plex\" or \"10-12\")."
        echo "Type ? and a number or name to see what it does (like \"?3\")."
        echo "Type s to save, or q to quit without saving."
        read -r -p "> " answer || return 0
        case "$answer" in
        s | S)
            save_items && offer_start
            return 0
            ;;
        q | Q)
            if has_changes && ! ask "Quit without saving your changes?" n; then
                continue
            fi
            load_items
            return 0
            ;;
        \?*)
            answer=${answer#\?}
            path=$(find_item "${answer// /}") && show_info "$path" || echo "Couldn't find \"${answer// /}\"."
            [ "$AUTO_YES" -eq 1 ] || read -r -p "Press enter to go back to the list. " || true
            continue
            ;;
        esac
        for word in $answer; do
            if [[ "$word" =~ ^([0-9]+)-([0-9]+)$ ]]; then
                first=${BASH_REMATCH[1]}
                last=${BASH_REMATCH[2]}
            elif path=$(find_item "$word"); then
                first=0
                last=0
            else
                echo "Couldn't find \"$word\"."
                continue
            fi
            for ((i = first; i <= last; i++)); do
                [ "$i" -eq 0 ] || path=$(find_item "$i") || continue
                toggle_item "$path"
            done
        done
    done
}

# Turn services on or off from the command line
set_services() {
    local mode=$1 word path
    shift
    [ "$#" -gt 0 ] || die "Say which services, like: ./manage.sh $mode plex"
    load_items
    for word in "$@"; do
        path=$(find_item "$word") || die "Couldn't find \"$word\", see \"./manage.sh services\" for the list."
        if [ "$mode" = on ]; then
            turn_on "$path"
        else
            turn_off "$path"
        fi
    done
    if save_items; then
        check_compose
    else
        echo "Nothing changed."
    fi
}

detect_timezone() {
    local zone
    zone=$(timedatectl show --property=Timezone --value 2>/dev/null) ||
        zone=$(cat /etc/timezone 2>/dev/null) ||
        zone=$(readlink /etc/localtime 2>/dev/null | sed 's|.*/zoneinfo/||')
    echo "${zone:-Europe/London}"
}

# Ask for one of the basic settings, keeping what's there as the default
set_basic() {
    local current value
    current=$(env_get "$1") || current=""
    value=$(ask_value "$2" "${current:-$3}")
    [ "$value" = "$current" ] || env_set "$1" "$value"
}

setup_basics() {
    local gid
    echo
    echo "A few basic settings, press enter to keep what's in [brackets]:"
    set_basic DOMAIN "Your domain name (like example.com)"
    set_basic EMAIL "Your email address"
    set_basic TINYAUTH_WHITELIST "Emails allowed to log in (comma separated)" "$(env_get EMAIL)"
    set_basic TZ "Your timezone" "$(detect_timezone)"
    set_basic PUID "User id to own the files" "$(id -u)"
    set_basic PGID "Group id to own the files" "$(id -g)"
    if [ -S /var/run/docker.sock ]; then
        gid=$(stat -c %g /var/run/docker.sock)
        if [ "$(env_get DOCKER_GID)" != "$gid" ]; then
            env_set DOCKER_GID "$gid"
            echo "Set DOCKER_GID to $gid"
        fi
    fi
}

setup() {
    local dir path
    check_docker
    if [ ! -f "$ENV_FILE" ] && ask "You don't have a .env settings file yet. Make one from .env.example?"; then
        cp "$ENV_EXAMPLE" "$ENV_FILE" || die "Could not create $ENV_FILE."
        echo "Created $ENV_FILE"
    fi
    if [ ! -f "$OVERRIDE" ] && ask "You don't have a $OVERRIDE file yet, it's where you choose extra services. Make one from the template?"; then
        cp "$OVERRIDE_TEMPLATE" "$OVERRIDE" || die "Could not create $OVERRIDE."
        echo "Created $OVERRIDE"
    fi
    [ ! -f "$ENV_FILE" ] || setup_basics

    # Anything already turned on might be missing its files too
    load_items
    while read -r dir <&3; do
        copy_templates "$dir"
        fill_placeholders "$dir"
    done 3< <(core_services; for path in "${!ENABLED[@]}"; do echo "${path%%/*}"; done | sort -u)

    if [ -f "$OVERRIDE" ] && ask "Choose which extra services to run now?"; then
        choose_services
    else
        offer_start
    fi
    echo
    echo "Everything else is set in the $ENV_FILE file, see README.md for what to put there."
}

run_tool() {
    local dir=$1 tool=$2
    [ -n "$dir" ] && [ -n "$tool" ] || die "Say which service and tool, like: ./manage.sh run onlyfans login"
    [ -f "$dir/manage.$tool.sh" ] || die "$dir doesn't have a \"$tool\" tool."
    run_script "$dir" "$tool" "${@:3}"
}

list_tools() {
    local dir tool count=0
    while read -r dir tool; do
        [ -z "${1:-}" ] || [ "$dir" = "$1" ] || continue
        count=$((count + 1))
        printf "  %-20s %-12s %s\n" "$dir" "$tool" "$(tool_description "$dir" "$tool")"
    done < <(all_tools)
    [ "$count" -gt 0 ] || echo "No tools${1:+ for $1}, they only show when the service they're for is turned on."
}

tools_menu() {
    local -a tools
    local answer i
    mapfile -t tools < <(all_tools)
    if [ "${#tools[@]}" -eq 0 ]; then
        echo "No tools, they only show when the service they're for is turned on."
        return
    fi
    echo
    for i in "${!tools[@]}"; do
        printf "%3d) %-30s %s\n" $((i + 1)) "${tools[i]/ / - }" "$(tool_description ${tools[i]})"
    done
    read -r -p "Which one? (enter to go back) " answer || answer=""
    [[ "$answer" =~ ^[0-9]+$ ]] && [ "$answer" -ge 1 ] && [ "$answer" -le "${#tools[@]}" ] || return 0
    run_tool ${tools[answer - 1]}
}

update() {
    need_tool git "to get the latest version" || die "git is needed to update."
    bash update.sh "$@" || return
    # The update may have changed this script, so the menu starts again from the new one
    [ "$IN_MENU" -eq 0 ] || exec bash manage.sh
}

start() {
    check_docker
    check_compose || exit 1
    docker compose up -d --remove-orphans
}

menu() {
    local answer
    IN_MENU=1
    if [ ! -f "$ENV_FILE" ] || [ ! -f "$OVERRIDE" ]; then
        echo "This looks like a new install."
        ! ask "Install it now?" || setup
    fi
    # Letters rather than numbers, so they stay the same when the menu changes
    while true; do
        echo
        echo "What would you like to do?"
        echo "  s) Services"
        echo "  r) Run services"
        echo "  u) Update"
        echo "  t) Tools"
        if [ -f "$ENV_FILE" ] && [ -f "$OVERRIDE" ]; then
            echo "  i) Install again"
        else
            echo "  i) Install"
        fi
        echo "  q) Quit"
        read -r -p "> " answer || return 0
        case "$answer" in
        s | S) choose_services ;;
        r | R) start ;;
        u | U) update ;;
        t | T) tools_menu ;;
        i | I) setup ;;
        q | Q) return 0 ;;
        *) echo "Type one of the letters above." ;;
        esac
    done
}

main() {
    local option command path
    while getopts "yh" option; do
        case "$option" in
        y) AUTO_YES=1 ;;
        h)
            usage
            exit 0
            ;;
        *)
            usage >&2
            exit 2
            ;;
        esac
    done
    shift $((OPTIND - 1))

    [ "${BASH_VERSINFO[0]}" -ge 4 ] || die "This needs bash 4 or newer."
    cd "$(dirname "${BASH_SOURCE[0]}")" || die "Could not find the repository."
    trap on_exit EXIT

    command=${1:-}
    [ "$#" -eq 0 ] || shift
    case "$command" in
    "") menu ;;
    install | setup) setup ;;
    services) choose_services ;;
    on | off) set_services "$command" "$@" ;;
    info)
        load_items
        path=$(find_item "${1:-}") || die "Couldn't find \"${1:-}\"."
        show_info "$path"
        ;;
    tools) list_tools "$@" ;;
    run) run_tool "$@" ;;
    start) start ;;
    update) update "$@" ;;
    help) usage ;;
    *)
        usage >&2
        exit 2
        ;;
    esac
}

# Only run when called directly, so service scripts can source the helpers
[ "${BASH_SOURCE[0]}" != "$0" ] || { main "$@"; exit $?; }
