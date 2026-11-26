#!/bin/bash

_RED="RED: "
_GREEN="GREEN: "
_PLAIN="PLAIN: "

sed -i "s/_RED=\".*\"/_RED=\"RED: \"/g" lepton
sed -i "s/_GREEN=\".*\"/_GREEN=\"GREEN: \"/g" lepton
sed -i "s/_PLAIN=\".*\"/_PLAIN=\"PLAIN: \"/g" lepton

function test_log()
{
    echo "${TEST_PREFIX}$*"
    echo "${TEST_PREFIX}$*" >> "${TEST_LOGFILE}"
}

function monitor_logcat()
{
    while true; do
        sleep 1
        ./lepton logcat "$1" --full | sed "s/^/[$1] /" | while IFS= read -r line; do
                echo "${line}" >> "${TEST_LOGFILE}"
            done
    done || true
}

function test_failure()
{
    ./lepton ps >> "${TEST_LOGFILE}"
    ps fax >> "${TEST_LOGFILE}"
    dmesg >> "${TEST_LOGFILE}"
    test_log "TEST FAILED, CHECK ARTIFACTS FOR DETAILED LOGS!"
    exit 1
}

function print_screen()
{
    ./lepton run "$1" screencap -p > screen.png
    test_log "$(chafa -s 640 --symbols all screen.png)"
}

function container_state()
{
    local s="" n pid
    for n in "lepton-$1" "lepton-steamlaunch-$1"; do
        s="$(podman container inspect -f '{{.State.Status}}|{{index .Config.Labels "lepton_pid"}}' "$n" 2>/dev/null || true)"
        [[ -n "$s" ]] && break
    done

    pid="${s#*|}"
    s="${s%%|*}"

    # Same rule as lepton ps: Created only counts while its lepton process is alive
    if [[ "$s" == created && ! ( -n "$pid" && -d "/proc/$pid" ) ]]; then
        s="dead"
    fi

    case "$s" in
        running|created) echo green ;;
        "")              ;;            # neither exists: not created yet / gone
        *)               echo red ;;
    esac
}

function wait_for_start()
{
    local max_time="${2:-30}"
    local end=$((SECONDS + max_time))
    while [[ "$(container_state "$1")" != "green" ]]; do
        if (( SECONDS >= end )); then
            test_log "container $1 failed to spin up within ${max_time} seconds."
            return 1
        fi
        test_log "Waiting for container $1 to start"
        sleep 1
    done
    return 0
}

function wait_for_boot()
{
    local name="$1" max_time="${2:-30}"
    local end=$((SECONDS + max_time))

    until [[ "$(container_state "$name")" == "green" ]]; do
        if (( SECONDS >= end )); then
            test_log "container $name failed to spin up within ${max_time} seconds."
            return 1
        fi
        sleep 0.2
    done

    local left=$(( end - SECONDS )); (( left < 1 )) && left=1
    if ! timeout -k 5 "$left" ./lepton run "$name" sh -c \
        'until [ "$(getprop sys.boot_completed)" = 1 ]; do sleep 0.2; done' 2>/dev/null; then
        test_log "container $name failed to reach boot complete within ${max_time} seconds."
        return 1
    fi
}

function wait_for_app()
{
    local container="$1" app="$2" max_time="${3:-30}"
    local end=$((SECONDS + max_time))
    local pids state

    while :; do
        pids="$(./lepton run "$container" pidof "$app" 2>/dev/null || true)"
        pids="${pids//$'\r'/}"
        # Only accept real PIDs, not error text that ended up on stdout.
        if grep -qE '^[[:space:]]*[0-9]+([[:space:]]+[0-9]+)*[[:space:]]*$' <<< "$pids"; then
            return 0
        fi

        if (( SECONDS >= end )); then
            test_log "app ${app} failed to start in ${container} within ${max_time} seconds."
            state="$(container_state "$container")"
            if [[ "$state" == "green" ]]; then
                ./lepton run "$container" getprop 2>&1 || true
                ./lepton run "$container" dumpsys 2>&1 || true
            else
                test_log "container ${container} is no longer running (state: ${state:-gone})"
            fi
            print_screen "$container" || true
            return 1
        fi

        if [[ "$(container_state "$container")" == "red" ]]; then
            test_log "container ${container} died while waiting for app ${app}."
            return 1
        fi

        test_log "Waiting for app ${app} in ${container}"
        sleep 1
    done
}

function get_ns_pids()
{
    awk '/^NSpid:/ {for (i=2; i<=NF; i++) print $i}' /proc/$(pidof "$1")/status
}

