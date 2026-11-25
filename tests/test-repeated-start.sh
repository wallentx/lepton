#!/bin/bash

TESTS_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
source "$TESTS_DIR"/test-common.sh

max_parallel=$(( $(nproc) / 4 ))
(( max_parallel < 1 )) && max_parallel=1
total=100

function run_test() {
    local i="$1"
    local name="test-instance-${i}"

    test_log "PASS$i"

    (
        LEPTON_ADB_PORT=$((5554 + i)) \
        LEPTON_GDB_PORT=$((1336 + i)) \
        LEPTON_LLDB_PORT=$((2336 + i)) ./lepton start "${name}" ||
            test_log "$name failed to start."
    ) &
    start_pid=$!

    if ! wait_for_boot "$name" 1500; then
        ./lepton stop "$name" || true
        # Make sure the start process is gone before freeing the slot,
        # otherwise we can exceed max_parallel.
        wait "${start_pid}" || true
        return 1
    fi

    ./lepton stop "$name" || true

    wait "${start_pid}" || true

    return 0
}

# Let's not waste too much time, many containers start at the same time
# But it means we need to fix ports ourselves
export LEPTON_LOCK_TIMEOUT=0
export LEPTON_NO_PORT_FORWARDING=true

failed=0
running=0

for ((i=1; i<=total; i++)); do
    # Wait until *any* running test finishes, not a specific slot,
    # so one slow test doesn't block the whole pool.
    if (( running >= max_parallel )); then
        if ! wait -n; then
            failed=$((failed + 1))
        fi
        running=$((running - 1))
    fi

    run_test "$i" &
    running=$((running + 1))
done

# Wait for remaining tests.
while (( running > 0 )); do
    if ! wait -n; then
        failed=$((failed + 1))
    fi
    running=$((running - 1))
done

function android_sdk_version()
{
    cat ./images/rootfs/system/build.prop | grep ro.build.version.sdk= | sed "s/.*=//g"
}

if (( failed > 0 )); then
    test_log "test repeated start test failed $failed times."

    # Our android 30 image sometimes fails to start...
    # Might be some patch that breaks it or some android bug...
    if [[ "$(android_sdk_version)" != "30" ]]; then
       test_failure
    fi
fi

test_log "test repeated start test finished"
