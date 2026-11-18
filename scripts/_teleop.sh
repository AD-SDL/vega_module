#!/usr/bin/env bash
# _teleop.sh -- shared teleop helpers for launch_teleop.sh. Source, do not execute.
# Requires SCRIPT_DIR + MODULE_ROOT set and _env.sh already sourced. See .docs/TELEOP.md.

NANO_SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
SSH_OPTS="-o ConnectTimeout=10"
CONDA_SH_REMOTE="~/miniconda3/etc/profile.d/conda.sh"

VEGA_SSH="${VEGA_USER:-dexmate}@${VEGA_HOST:-146.137.240.51}"

# TERM, wait up to 5s, then KILL every process matching $1 (locally).
stop_pattern() {
    local pat="$1" label="${2:-processes}" pids
    pids=$(pgrep -f "$pat" || true)
    [[ -z "$pids" ]] && { echo "-> No $label running."; return; }
    echo "-> Stopping $label: $pids"
    # shellcheck disable=SC2086
    kill -TERM $pids 2>/dev/null || true
    for _ in $(seq 1 10); do pgrep -f "$pat" >/dev/null || break; sleep 0.5; done
    pids=$(pgrep -f "$pat" || true)
    # shellcheck disable=SC2086
    [[ -n "$pids" ]] && kill -KILL $pids 2>/dev/null || true
}

# TERM then KILL a pattern on the Jetson over ssh, and close the local ssh -t windows.
stop_pattern_remote() {
    local pat="$1" label="${2:-remote processes}"
    echo "-> Stopping $label over ssh..."
    ssh $SSH_OPTS "$VEGA_SSH" "pkill -TERM -f '$pat'" 2>/dev/null || true
    sleep 2
    ssh $SSH_OPTS "$VEGA_SSH" "pkill -KILL -f '$pat'" 2>/dev/null || true
    pkill -f "$pat" 2>/dev/null || true
}

stop_sensors() {
    echo "-> Stopping sensors..."
    if [[ -n "${VEGA_USER:-}" && -n "${VEGA_HOST:-}" ]]; then
        ssh $SSH_OPTS "$VEGA_SSH" 'pkill -x dexsensor' 2>/dev/null || true
        if [[ -n "${NANO_USER:-}" && -n "${NANO_HOST:-}" && -n "${NANO_PWD:-}" ]]; then
            ssh $SSH_OPTS "$VEGA_SSH" \
                "sshpass -p '$NANO_PWD' ssh $NANO_SSH_OPTS $NANO_USER@$NANO_HOST 'pkill -x dexsensor'" \
                2>/dev/null || true
        fi
    fi
    pkill -f 'dexsensor launch' 2>/dev/null || true
}

# Launch base (Jetson) + head (Nano) sensors, each in its own window. $1 = base sensor
# args (the set differs per target); head camera is always the Nano via the Jetson hop.
launch_sensors() {
    local base_sensors="$1"
    local nano_ssh="${NANO_USER}@${NANO_HOST}"
    local base_cmd head_cmd
    base_cmd="ssh -t $VEGA_SSH \"source $CONDA_SH_REMOTE && conda activate dexcontrol && dexsensor launch $base_sensors\""
    head_cmd="ssh -t $VEGA_SSH \"sshpass -p '$NANO_PWD' ssh -t $NANO_SSH_OPTS $nano_ssh 'dexsensor launch --robot $ROBOT_NAME --sensor head_camera'\""
    echo "-> Launching sensors on the Jetson and Nano..."
    gnome-terminal --window --title="base_sensors" -- bash -c "$base_cmd; exec bash"
    gnome-terminal --window --title="head_camera" -- bash -c "$head_cmd; exec bash"
    read -rp "-> Check sensors are running, then press Enter to continue..."
}

calibrate_prompt() {
    read -rp "-> Get into default position to calibrate exoskeleton, then press Enter to launch..."
}

# Walk up from $1 looking for a repo root marker.
find_repo_root() {
    local dir="$1"
    while [[ "$dir" != "/" ]]; do
        [[ -d "$dir/.git" || -f "$dir/pyproject.toml" || -f "$dir/setup.py" ]] && { echo "$dir"; return 0; }
        dir="$(dirname "$dir")"
    done
    return 1
}

# Resolve the omniteleop repo root (editable install first, then known on-disk spots).
resolve_omniteleop_root() {
    local root="" pkg
    pkg="$("$VENV_PATH/bin/python" -c "import omniteleop, os; print(os.path.realpath(os.path.dirname(omniteleop.__file__)))" 2>/dev/null || true)"
    [[ -n "$pkg" ]] && root="$(find_repo_root "$pkg" || true)"
    if [[ -z "$root" || ! -d "$root/src/omniteleop" ]]; then
        local c
        for c in /home/rpl/humanoids/omniteleop "$MODULE_ROOT/../omniteleop"; do
            [[ -d "$c/src/omniteleop" ]] && { root="$(cd "$c" && pwd)"; break; }
        done
    fi
    [[ -n "$root" ]] || { echo "-> ERROR: could not locate the omniteleop repo (no src/omniteleop found)." >&2; return 1; }
    echo "$root"
}
