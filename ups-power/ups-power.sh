#!/bin/bash

# Pauses the hungry containers when the UPS is on battery, hibernates the
# server before the battery runs out, and unpauses once the power has been back
# for a while. Run on the docker host by ups-power.service (see manage.install.sh).
#
#   ups-power.sh [run]          Watch the UPS, as UPS_POWER_MODE says (the default)
#   ups-power.sh status         Show the UPS reading and what is paused
#   ups-power.sh pause          Pause the containers now, as on battery
#   ups-power.sh unpause        Unpause what was paused
#   ups-power.sh hibernate-test Pause, hibernate, and on waking unpause and show the times
#
# UPS_POWER_MODE in .env:
#   monitor   Only log - every reading while on battery goes to logs/<outage>.csv
#   dry-run   Also log what it would pause, hibernate and unpause
#   run       Do it
#
# Containers with the label "ups-power.pause=true" are paused, after the
# watchdogs (UPS_POWER_WATCHDOGS, "deunhealth watchtower") so they can't restart
# or replace a paused container. Unpausing is the other way round, and only
# touches containers this paused.
#
# It hibernates on the UPS "LB" (low battery) flag, or when any of the
# UPS_POWER_HIBERNATE_* limits is reached. Losing the UPS while on battery
# counts too, as whatever is between here and the UPS may be running out.
#
# A hibernated server can't see the power come back, so something else has to
# wake it - like ups-wake.sh on the machine with the UPS attached.

set -uo pipefail

DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(dirname "$DIR")
ENV_FILE=${UPS_POWER_ENV:-$REPO/.env}
STATE_DIR=${UPS_POWER_STATE:-/run/ups-power}
LOG_DIR=${UPS_POWER_LOGS:-$DIR/logs}

# A setting from the environment, then .env, then the default
setting() {
    local name=$1 value
    if [ -n "${!name+x}" ]; then
        printf '%s' "${!name}"
        return
    fi
    value=$(awk -v key="$name" '
        { sub(/\r$/, "") }
        index($0, key "=") == 1 {
            v = substr($0, length(key) + 2)
            if (v ~ /^".*"$/ || v ~ /^\047.*\047$/) v = substr(v, 2, length(v) - 2)
            found = v
        }
        END { print found }
    ' "$ENV_FILE" 2>/dev/null)
    printf '%s' "${value:-$2}"
}

UPS=$(setting UPS_POWER_UPS ups@localhost)
MODE=$(setting UPS_POWER_MODE monitor)
INTERVAL=$(setting UPS_POWER_INTERVAL 10)
PAUSE_AFTER=$(setting UPS_POWER_PAUSE_AFTER 30)
RESUME_AFTER=$(setting UPS_POWER_RESUME_AFTER 300)
LOST_AFTER=$(setting UPS_POWER_LOST_AFTER 60)
HIBERNATE_VOLTAGE=$(setting UPS_POWER_HIBERNATE_VOLTAGE "")
HIBERNATE_CHARGE=$(setting UPS_POWER_HIBERNATE_CHARGE "")
HIBERNATE_TIME=$(setting UPS_POWER_HIBERNATE_TIME "")
WATCHDOGS=$(setting UPS_POWER_WATCHDOGS "deunhealth watchtower")
HEALTHY_WAIT=$(setting UPS_POWER_HEALTHY_WAIT 300)
FALLBACK=$(setting UPS_POWER_FALLBACK shutdown)
HIBERNATE_RETRY=$(setting UPS_POWER_HIBERNATE_RETRY 120)
# For testing: read memory from this file instead of /proc/meminfo
MEMINFO=$(setting UPS_POWER_MEMINFO /proc/meminfo)
LABEL=$(setting UPS_POWER_LABEL ups-power.pause)
# For testing: read the UPS from this file instead of upsc ("unreachable" in it = no answer)
FAKE=$(setting UPS_POWER_FAKE "")

PAUSED_FILE="$STATE_DIR/paused"

log() {
    echo "$(date '+%F %T') $*"
}

die() {
    log "ERROR: $*" >&2
    exit 1
}

check_settings() {
    local name value bad=0
    case "$MODE" in
    monitor | dry-run | run) ;;
    *) log "ERROR: UPS_POWER_MODE must be monitor, dry-run or run, not \"$MODE\"" && bad=1 ;;
    esac
    case "$FALLBACK" in
    shutdown | none) ;;
    *) log "ERROR: UPS_POWER_FALLBACK must be shutdown or none, not \"$FALLBACK\"" && bad=1 ;;
    esac
    for name in INTERVAL PAUSE_AFTER RESUME_AFTER LOST_AFTER HEALTHY_WAIT HIBERNATE_RETRY HIBERNATE_TIME; do
        value=${!name}
        [ -z "$value" ] && [ "$name" = HIBERNATE_TIME ] && continue
        [[ "$value" =~ ^[0-9]+$ ]] || { log "ERROR: UPS_POWER_$name must be a whole number of seconds, not \"$value\"" && bad=1; }
    done
    for name in HIBERNATE_VOLTAGE HIBERNATE_CHARGE; do
        value=${!name}
        [ -z "$value" ] || [[ "$value" =~ ^[0-9]+(\.[0-9]+)?$ ]] ||
            { log "ERROR: UPS_POWER_$name must be a number, not \"$value\"" && bad=1; }
    done
    [ "${INTERVAL:-0}" != 0 ] || { log "ERROR: UPS_POWER_INTERVAL can't be 0" && bad=1; }
    [ "$bad" -eq 0 ] || exit 1
}

# Read the UPS into STATUS, VOLTAGE, CHARGE and LOAD. Fails if it can't be reached.
read_ups() {
    local out
    if [ -n "$FAKE" ]; then
        out=$(cat "$FAKE" 2>/dev/null) || return 1
        ! grep -qx unreachable <<<"$out" || return 1
    else
        out=$(upsc "$UPS" 2>/dev/null) || return 1
    fi
    STATUS=$(sed -n 's/^ups\.status: //p' <<<"$out")
    VOLTAGE=$(sed -n 's/^battery\.voltage: //p' <<<"$out")
    CHARGE=$(sed -n 's/^battery\.charge: //p' <<<"$out")
    LOAD=$(sed -n 's/^ups\.load: //p' <<<"$out")
    [ -n "$STATUS" ]
}

has_flag() {
    [[ " $STATUS " == *" $1 "* ]]
}

# Exit 0 if a is at or below b, for decimals
at_or_below() {
    awk -v a="$1" -v b="$2" 'BEGIN { exit !(a + 0 <= b + 0) }'
}

# --- Pausing ---------------------------------------------------------------

running() {
    [ "$(docker inspect -f '{{.State.Running}} {{.State.Paused}}' "$1" 2>/dev/null)" = "true false" ]
}

# The containers to pause, in order: the watchdogs, then the labelled ones
pause_list() {
    local name
    for name in $WATCHDOGS; do
        running "$name" && echo "$name"
    done
    docker ps --filter "label=$LABEL=true" --filter status=running --format '{{.Names}}' | sort
}

pause_all() {
    local name done=0
    mkdir -p "$STATE_DIR"
    touch "$PAUSED_FILE"
    while read -r name; do
        [ -n "$name" ] || continue
        grep -qxF "$name" "$PAUSED_FILE" && continue
        if [ "$MODE" = run ]; then
            if docker pause "$name" >/dev/null; then
                echo "$name" >>"$PAUSED_FILE"
                done=$((done + 1))
            else
                log "Could not pause $name"
            fi
        else
            log "Would pause $name"
            echo "$name" >>"$PAUSED_FILE"
        fi
    done < <(pause_list)
    [ "$MODE" != run ] || log "Paused $done containers: $(tr '\n' ' ' <"$PAUSED_FILE")"
}

is_watchdog() {
    [[ " $WATCHDOGS " == *" $1 "* ]]
}

unpause_one() {
    if [ "$MODE" = run ]; then
        docker unpause "$1" >/dev/null 2>&1 || log "Could not unpause $1, it may have been restarted"
    else
        log "Would unpause $1"
    fi
}

# Docker marks a paused container unhealthy straight away, and it stays that
# way until its next check passes. Wait for that, so a watchdog unpaused after
# doesn't restart it.
wait_healthy() {
    local name health waited=0 waiting
    [ "$MODE" = run ] || return 0
    while [ "$waited" -lt "$HEALTHY_WAIT" ]; do
        waiting=""
        for name in "$@"; do
            health=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$name" 2>/dev/null)
            [ "$health" != unhealthy ] || waiting+=" $name"
        done
        [ -n "$waiting" ] || return 0
        sleep 5
        waited=$((waited + 5))
    done
    log "Still unhealthy after ${HEALTHY_WAIT}s:$waiting"
}

# Unpause in the reverse order, the watchdogs last once the rest are healthy
unpause_all() {
    local name
    local -a others=() dogs=()
    [ -s "$PAUSED_FILE" ] || return 0
    while read -r name; do
        [ -n "$name" ] || continue
        if is_watchdog "$name"; then
            dogs+=("$name")
        else
            others+=("$name")
        fi
    done < <(tac "$PAUSED_FILE")
    for name in "${others[@]}"; do
        unpause_one "$name"
    done
    [ "${#others[@]}" -eq 0 ] || wait_healthy "${others[@]}"
    for name in "${dogs[@]}"; do
        unpause_one "$name"
    done
    [ "$MODE" != run ] || log "Unpaused: ${others[*]} ${dogs[*]}"
    rm -f "$PAUSED_FILE"
}

is_paused() {
    [ -s "$PAUSED_FILE" ]
}

# --- Hibernating -----------------------------------------------------------

# Prints why it should hibernate now, if it should
hibernate_reason() {
    local on_battery=$1 lost=$2
    if [ "$lost" -ge "$LOST_AFTER" ]; then
        echo "the UPS hasn't answered for ${lost}s while on battery"
    elif has_flag LB; then
        echo "the UPS says the battery is low"
    elif [ -n "$HIBERNATE_VOLTAGE" ] && [ -n "$VOLTAGE" ] && at_or_below "$VOLTAGE" "$HIBERNATE_VOLTAGE"; then
        echo "the battery is at ${VOLTAGE}V (limit ${HIBERNATE_VOLTAGE}V)"
    elif [ -n "$HIBERNATE_CHARGE" ] && [ -n "$CHARGE" ] && at_or_below "$CHARGE" "$HIBERNATE_CHARGE"; then
        echo "the battery is at ${CHARGE}% (limit ${HIBERNATE_CHARGE}%)"
    elif [ -n "$HIBERNATE_TIME" ] && [ "$on_battery" -ge "$HIBERNATE_TIME" ]; then
        echo "it has been on battery for ${on_battery}s (limit ${HIBERNATE_TIME}s)"
    fi
}

# Prints why hibernating can't work now, if it can't. Memory in use has to fit
# in the swap that is free, with some room to spare.
swap_problem() {
    awk '
        /^AnonPages:/ { anon = $2 } /^Shmem:/ { shmem = $2 } /^SwapFree:/ { free = $2 }
        END {
            need = (anon + shmem) * 1.1 + 2 * 1024 * 1024
            if (free < need) printf "only %.0fGB of swap is free and about %.0fGB is needed", free / 1048576, need / 1048576
        }
    ' "$MEMINFO"
}

# Start hibernating. Fails with the reason in PROBLEM when it can't.
hibernate() {
    PROBLEM=$(swap_problem)
    [ -z "$PROBLEM" ] || return 1
    log "Hibernating: $1"
    [ "$MODE" = run ] || return 0
    sync
    systemctl hibernate >/dev/null 2>&1 || {
        PROBLEM="systemctl hibernate was refused"
        return 1
    }
}

# The last resort when hibernating hasn't worked: shut down cleanly, rather
# than lose power with everything running
fall_back() {
    local name
    log "Can't hibernate: $1"
    if [ "$FALLBACK" != shutdown ]; then
        log "UPS_POWER_FALLBACK is $FALLBACK, so carrying on"
        return 0
    fi
    if [ "$MODE" != run ]; then
        log "Would shut down instead"
        return 0
    fi
    log "Shutting down instead"
    # Paused containers can't stop cleanly, so let them go first. The watchdogs
    # stay paused so they can't restart anything on the way down.
    if [ -s "$PAUSED_FILE" ]; then
        while read -r name; do
            is_watchdog "$name" || docker unpause "$name" >/dev/null 2>&1
        done <"$PAUSED_FILE"
    fi
    sync
    systemctl poweroff
}

# --- Logging the battery -----------------------------------------------------

csv_row() {
    printf '%s,%s,%s,"%s",%s,%s,%s\n' "$(date -Iseconds)" "$1" "$2" "$STATUS" "$VOLTAGE" "$CHARGE" "$LOAD" >>"$CSV"
}

# --- Watching ----------------------------------------------------------------

watch_ups() {
    local now last=0 on_battery_since=0 mains_since=0 lost_since=0 last_seen=""
    local tried_at=0 tries=0 fell_back=0
    local on_battery lost reason seen
    CSV=""
    check_settings
    # dry-run keeps its own list of what it would have paused, so it never
    # takes over containers paused for real (like by hibernate-test)
    [ "$MODE" != dry-run ] || PAUSED_FILE="$STATE_DIR/dry-run-paused"
    trap 'log "Stopping"; exit 0' TERM INT
    log "Watching $UPS every ${INTERVAL}s in $MODE mode, pausing after ${PAUSE_AFTER}s on battery, unpausing after ${RESUME_AFTER}s back on mains"
    log "Hibernate limits: LB flag, voltage ${HIBERNATE_VOLTAGE:-off}, charge ${HIBERNATE_CHARGE:-off}, time ${HIBERNATE_TIME:-off}, UPS lost for ${LOST_AFTER}s"
    [ "$MODE" = monitor ] || ! is_paused || log "Already paused: $(tr '\n' ' ' <"$PAUSED_FILE")"
    while true; do
        now=$(date +%s)
        # A jump in time is the server waking from hibernation
        if [ "$last" -gt 0 ] && [ $((now - last)) -gt $((INTERVAL * 6)) ]; then
            log "Woke up after $((now - last))s"
            mains_since=0
            lost_since=0
            # Woken while still on battery, so it can try once more
            tried_at=0
        fi
        last=$now

        if read_ups; then
            seen=mains
            has_flag OB && seen=battery
            lost_since=0
        else
            seen=lost
            [ "$lost_since" -gt 0 ] || {
                lost_since=$now
                log "Can't read $UPS"
            }
        fi

        if [ "$seen" = battery ] || { [ "$seen" = lost ] && [ "$last_seen" = battery ]; }; then
            # On battery, or lost while on battery
            if [ "$on_battery_since" -eq 0 ]; then
                on_battery_since=$now
                CSV="$LOG_DIR/$(date +%Y-%m-%d_%H%M%S).csv"
                mkdir -p "$LOG_DIR" && echo "time,seconds,event,status,voltage,charge,load" >"$CSV"
                log "On battery: ${VOLTAGE:-?}V, ${CHARGE:-?}%, load ${LOAD:-?}%"
            fi
            mains_since=0
            on_battery=$((now - on_battery_since))
            lost=0
            [ "$seen" = lost ] && lost=$((now - lost_since))
            [ "$seen" = lost ] || csv_row "$on_battery" reading
            if [ "$MODE" != monitor ]; then
                if [ "$on_battery" -ge "$PAUSE_AFTER" ] && ! is_paused; then
                    csv_row "$on_battery" pause
                    pause_all
                fi
                reason=$(hibernate_reason "$on_battery" "$lost")
                if [ -n "$reason" ] && [ "$fell_back" -eq 0 ]; then
                    if [ "$tries" -ge 2 ]; then
                        fall_back "it has been tried twice, and $reason"
                        fell_back=1
                    elif [ "$tried_at" -eq 0 ]; then
                        is_paused || pause_all
                        csv_row "$on_battery" hibernate
                        tried_at=$now
                        tries=$((tries + 1))
                        if ! hibernate "$reason"; then
                            csv_row "$on_battery" fall-back
                            fall_back "$PROBLEM"
                            fell_back=1
                        fi
                    elif [ $((now - tried_at)) -ge "$HIBERNATE_RETRY" ]; then
                        # Still here and still on battery, so it didn't work
                        csv_row "$on_battery" fall-back
                        fall_back "still running $((now - tried_at))s after starting to hibernate, and $reason"
                        fell_back=1
                    fi
                fi
            elif has_flag LB; then
                csv_row "$on_battery" low-battery
            fi
        elif [ "$seen" = mains ]; then
            if [ "$on_battery_since" -gt 0 ]; then
                log "Back on mains after $((now - on_battery_since))s: ${VOLTAGE:-?}V, ${CHARGE:-?}%"
                csv_row $((now - on_battery_since)) mains
                on_battery_since=0
            fi
            tried_at=0 tries=0 fell_back=0
            [ "$mains_since" -gt 0 ] || mains_since=$now
            if [ "$MODE" != monitor ] && is_paused && [ $((now - mains_since)) -ge "$RESUME_AFTER" ]; then
                log "On mains for $((now - mains_since))s, unpausing"
                unpause_all
            fi
        elif [ "$lost_since" -eq "$now" ]; then
            log "Not on battery as far as is known, so only warning"
        fi
        [ "$seen" = lost ] || last_seen=$seen

        sleep "$INTERVAL" &
        wait $!
    done
}

status() {
    if read_ups; then
        echo "UPS $UPS: $STATUS, ${VOLTAGE:-?}V, ${CHARGE:-?}%, load ${LOAD:-?}%"
    else
        echo "UPS $UPS: can't be read"
    fi
    echo "Mode: $MODE"
    echo "Would pause: $(pause_list | tr '\n' ' ')"
    if is_paused; then
        echo "Paused now: $(tr '\n' ' ' <"$PAUSED_FILE")"
    else
        echo "Paused now: nothing"
    fi
}

hibernate_test() {
    local start prev now answer
    [ "$(id -u)" -eq 0 ] || die "Run this as root, it hibernates the server"
    MODE=run
    read -r -p "This pauses the containers and hibernates the server now. Wake it with the power button. Go ahead? [y/N] " answer
    [[ "$answer" =~ ^[Yy] ]] || exit 0
    pause_all
    sync
    start=$(date +%s)
    log "Hibernating..."
    systemctl hibernate || die "systemctl hibernate failed"
    # That returns straight away. Waking shows up as a jump in the clock.
    prev=$start
    while true; do
        sleep 1
        now=$(date +%s)
        [ $((now - prev)) -le 5 ] || break
        prev=$now
        [ $((now - start)) -lt 300 ] || die "It didn't hibernate within 5 minutes, the containers are still paused"
    done
    log "Stopped about $((prev - start))s after starting, and was asleep for $((now - prev))s"
    journalctl -b --since "@$start" --no-pager 2>/dev/null |
        grep -iE 'PM: |hibernat|image' | tail -20
    unpause_all
}

main() {
    local command=${1:-run}
    case "$command" in
    run) watch_ups ;;
    status) status ;;
    pause) MODE=run && pause_all ;;
    unpause) MODE=run && unpause_all ;;
    hibernate-test) hibernate_test ;;
    *)
        sed -n '7,11p' "$0" | sed 's/^# \{0,1\}//'
        exit 2
        ;;
    esac
}

main "$@"
