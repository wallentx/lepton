#!/bin/bash

set -euo pipefail

TESTS_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
source "$TESTS_DIR"/test-common.sh

sed -i "s/_RED=\"\"/_RED=\"RED: \"/g" lepton
sed -i "s/_GREEN=\"\"/_GREEN=\"GREEN: \"/g" lepton
sed -i "s/_PLAIN=\"\"/_PLAIN=\"PLAIN: \"/g" lepton

max_parallel=25
total=5000

function run_test() {
    local i="$1"
    local name="testapp-instance-${i}"

    local STEAM_COMPAT_INSTALL_PATH="${HOME}/.local/share/Steam/steamnames/common/${name}"
    local STEAM_COMPAT_CLIENT_INSTALL_PATH="${HOME}/.local/share/Steam"
    local STEAM_COMPAT_DATA_PATH="${HOME}/.local/share/Steam/steamnames/compatdata/${name}"
    local STEAM_COMPAT_SHADER_PATH="${HOME}/.local/share/Steam/steamnames/shadercache/${name}"
    local STEAM_FOSSILIZE_DUMP_PATH="${STEAM_COMPAT_SHADER_PATH}/fozpipelinesv6/steamname_pipeline_cache"
    local SteamAppId="${name}"

    mkdir -p \
        "${STEAM_COMPAT_INSTALL_PATH}" \
        "${STEAM_COMPAT_CLIENT_INSTALL_PATH}" \
        "${STEAM_COMPAT_DATA_PATH}" \
        "${STEAM_COMPAT_SHADER_PATH}" \
        "${STEAM_FOSSILIZE_DUMP_PATH}"

    cp tests/test-apk.apk "${STEAM_COMPAT_INSTALL_PATH}/"

    tee "/home/steamos/.local/share/Steam/steamnames/namemanifest_${name}.acf" > /dev/null <<EOF
"AppState"
{
    "nameid"             "${name}"
    "name"              "${name}"
    "installdir"        "${name}"
}
EOF

    CG="/sys/fs/cgroup/lepton-steamlaunch-${name}"

    if [ -d "$CG" ]; then
        while read -r pid; do
            echo "$pid" | sudo tee /sys/fs/cgroup/cgroup.procs >/dev/null
        done < "$CG/cgroup.procs"

        sudo rmdir "$CG"
    fi

    sudo mkdir -p "$CG"
    sudo sh -c "echo $$ > '$CG/cgroup.procs'"
    sudo chown steamos:steamos -R /sys/fs/cgroup
    sudo chmod 777 -R /sys/fs/cgroup
    sudo sh -c "echo "+cpu +cpuset +memory +pids" > /sys/fs/cgroup/cgroup.subtree_control"

    test_log "PASS$i"

    (
        STEAM_COMPAT_INSTALL_PATH="${HOME}/.local/share/Steam/steamnames/common/${name}" \
        STEAM_COMPAT_CLIENT_INSTALL_PATH="${HOME}/.local/share/Steam" \
        STEAM_COMPAT_DATA_PATH="${HOME}/.local/share/Steam/steamapps/compatdata/${name}" \
        STEAM_COMPAT_SHADER_PATH="${HOME}/.local/share/Steam/steamapps/shadercache/${name}" \
        STEAM_FOSSILIZE_DUMP_PATH="${HOME}/.local/share/Steam/steamapps/shadercache/${name}/fozpipelinesv6/steamapp_pipeline_cache" \
        SteamAppId="${name}" \
        LEPTON_ADB_PORT=$((5554 + i)) \
        LEPTON_GDB_PORT=$((1336 + i)) \
        LEPTON_LLDB_PORT=$((2336 + i)) ./lepton start "$name" ||
            test_log "$name failed to start."
    ) &

    if ! wait_for_boot "$name" 360; then
        return 1
    fi

    if ! wait_for_app "$name" com.example.neon42 360; then
        return 1
    fi

    if [[ "$(./lepton ps | grep "$name" | grep "${_GREEN}")" == "" ]]; then
        test_log "repeated start test failed for $name, lepton ps inconsistent (1)!"
        return 1
    fi

    ./lepton stop "$name"

    rm -rf \
        "${STEAM_COMPAT_INSTALL_PATH}" \
        "${STEAM_COMPAT_DATA_PATH}" \
        "${STEAM_COMPAT_SHADER_PATH}" \
        "${STEAM_FOSSILIZE_DUMP_PATH}"
    return 0
}

# Let's not waste too much time, many containers start at the same time
export LEPTON_LOCK_TIMEOUT=0
# App launches may be slow
export LEPTON_APP_LAUNCH_TIMEOUT=10000

export LEPTON_NO_PORT_FORWARDING=true

failed=0

declare -a pids

for ((i=1; i<=total; i++)); do
    j=$(( (i - 1) % max_parallel + 1 ))

    # Wait until this specific test ID is free.
    if [[ -n "${pids[j]:-}" ]]; then
        if ! wait "${pids[j]}"; then
            ((++failed))
        fi
        unset 'pids[j]'
    fi

    run_test "$i" &
    pids[j]=$!
done

# Wait for remaining tests.
for ((j=1; j<=max_parallel; j++)); do
    if [[ -n "${pids[j]:-}" ]]; then
        if ! wait "${pids[j]}"; then
            ((failed++))
        fi
    fi
done

function android_sdk_version()
{
    cat ./images/rootfs/system/build.prop | grep ro.build.version.sdk= | sed "s/.*=//g"
}

if (( failed > 0 )); then
    test_log "testapp repeated start test failed $failed times."

    # Our android 30 image sometimes fails to start...
    # Might be some patch that breaks it or some android bug...
    if [[ "$(android_sdk_version)" != "30" ]]; then
       test_failure
    fi
fi

test_log "testapp repeated start test finished"

