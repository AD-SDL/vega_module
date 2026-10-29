#!/usr/bin/env bash
#
# _common.sh -- shared library for the vega_module launch scripts.
#
# Sourced (never executed) by every entrypoint AFTER it sets SCRIPT_DIR and
# MODULE_ROOT:
#
#     SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#     MODULE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
#     source "$SCRIPT_DIR/_common.sh"
#
# This file consolidates logic that was copy-pasted (and had DRIFTED) across
# lab_connect.sh, jetson_connect.sh, launch_exo_{teleop,lerobot,rollout}.sh,
# launch_jetson_{teleop,rollout}.sh and _jetson_record_common.sh:
#   * the env-file loader                (was 5 naive copies + 1 correct one)
#   * stop_* / teardown helpers          (TERM->wait->KILL, ordered shutdown)
#   * the sensor-launch block            (drifted: single base_camera vs back+front)
#   * ROBOT_NAME resolution              (sed'd out of lab_connect.sh in 5 places)
#   * the hands-disabled flag set        (4x --with_*_hand=false, pasted everywhere)
#
# IMPORTANT: this file must be `set -u`-clean. The jetson entrypoints run under
# `set -uo pipefail`; the mj entrypoints do not. Every parameter expansion here
# uses `${x:-}` so sourcing is safe under both. This file does NOT itself enable
# `set -u` (that would change the mj scripts' behavior).

# Guard against double-sourcing (an entrypoint may source this and then source
# _jetson_record_common.sh, which also sources this).
if [[ -n "${_VEGA_COMMON_SOURCED:-}" ]]; then
    return 0 2>/dev/null || true
fi
_VEGA_COMMON_SOURCED=1

# ---------------------------------------------------------------------------------
# Shared SSH options
# ---------------------------------------------------------------------------------
# Nano hop (via the Jetson): a first-time or stale host-key entry makes ssh refuse
# password auth, so skip known_hosts entirely.
NANO_SSH_OPTS="${NANO_SSH_OPTS:--o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null}"
# Connect timeout for reaching the robot/Jetson over ssh. Standardized at 10s
# (the jetson scripts' value; the mj scripts previously used 8s -- the only
# behavioral delta of the consolidation, and it only affects the unreachable-robot
# path, where both 8 and 10 fail anyway).
SSH_OPTS="${SSH_OPTS:--o ConnectTimeout=10}"

# ---------------------------------------------------------------------------------
# Process-match patterns -- kept as SEPARATE named constants on purpose.
# Merging them would silently change the scope of a `stop`, so each role keeps its
# own pattern exactly as the original script defined it.
# ---------------------------------------------------------------------------------
# mj-side teleop stack INCLUDING the MCAP recorder (launch_exo_teleop.sh).
TELEOP_STALE_PATTERN="joycon_reader\.py|arm_reader\.py|command_processor\.py|robot_controller\.py|mcap_recorder\.py|telemetry_viewer\.py"
# mj-side LeRobot recording stack: same drivers but lerobot-record instead of mcap
# (launch_exo_lerobot.sh).
LEROBOT_STALE_PATTERN="joycon_reader\.py|arm_reader\.py|command_processor\.py|robot_controller\.py|telemetry_viewer\.py|lerobot-record"
# Just the mj joycon reader (the split-stack scripts kill only this locally).
MJ_STALE_PATTERN="joycon_reader\.py"
# The driving stack that runs ON the Jetson in the split-stack scripts.
JETSON_STALE_PATTERN="omni-arm|omni-cmd|omni-robot|omni-telemetry|arm_reader\.py|command_processor\.py|robot_controller\.py|telemetry_viewer\.py"
# The LeRobot recorder process (matched for both stop and stale cleanup).
RECORD_STALE_PATTERN="lerobot-record"
# The LeRobot rollout process.
ROLLOUT_STALE_PATTERN="lerobot-rollout"
# Any hardware WRITER whose presence makes a rollout/record a dangerous second
# writer -- the dual-writer guard list (launch_exo_rollout.sh).
OMNITELEOP_WRITER_PATTERN="joycon_reader\.py|arm_reader\.py|command_processor\.py|robot_controller\.py|lerobot-record"

# ---------------------------------------------------------------------------------
# Hands-disabled flags (2026-09-22). The F5D6 hands are not detected by the
# controller (query_hand_type() -> UNKNOWN), so dexcontrol disables the hand
# components. The hand flags exist on BOTH the follower (--robot.*) and the
# teleoperator (--teleop.*) and MUST mirror each other: if only one side is
# disabled, the other still declares the hands and the first record loop tick
# raises (follower connect() ConnectionError, or teleop get_action()
# DeviceNotConnectedError). A rollout has no teleoperator, so it uses only the
# --robot.* pair.
#
# The PRIMARY source of truth for the omniteleop/drive side is ~/.bashrc (it pins
# ROBOT_CONFIG=vega_1p, which wins over lab_connect.sh's ${ROBOT_CONFIG:-vega_1p}).
# lab_connect.sh is secondary. See .docs/HANDS_DISABLED.md.
#
# TO RE-ENABLE once the hands are detected again: blank these two arrays (the
# dataclass defaults are already True) and restore ROBOT_CONFIG=vega_1p_f5d6 in
# ~/.bashrc and lab_connect.sh.
HANDS_ROBOT_FLAGS=(--robot.with_left_hand=false --robot.with_right_hand=false)
HANDS_TELEOP_FLAGS=(--teleop.with_left_hand=false --teleop.with_right_hand=false)

# ---------------------------------------------------------------------------------
# Env-file loading (comment-aware). Replaces the 5 naive loaders. A var is set
# only if currently unset, so load order == precedence (earliest wins): shell env
# first, then whatever files the caller loads, then in-script ${X:-default}.
# ---------------------------------------------------------------------------------
_load_env_file() {
    local f="$1"
    [[ -f "$f" ]] || return 0
    # "Loading environment from" is the phrasing 9 of the 11 original loaders used; the two
    # record-common loaders said just "Loading" -- standardized here (cosmetic only; the
    # parse behavior is the canonical comment-aware one).
    echo "-> Loading environment from $f"
    # Files may use inline comments (KEY="value"  # why), so strip the comment and
    # surrounding quotes, or the whole comment would ride into the command line.
    # The `|| [[ -n "$key" ]]` processes a final line with no trailing newline
    # (otherwise the last var is silently dropped).
    local key value
    while IFS='=' read -r key value || [[ -n "$key" ]]; do
        key="${key%"${key##*[![:space:]]}"}"   # rtrim key (allow "KEY =" style)
        [[ -z "$key" || "$key" == \#* ]] && continue
        if [[ "$value" == \"* ]]; then
            value="${value#\"}"; value="${value%%\"*}"   # quoted: inside the first "..."
        else
            value="${value%%#*}"                          # unquoted: drop trailing # comment
            value="${value#"${value%%[![:space:]]*}"}"    # ltrim
            value="${value%"${value##*[![:space:]]}"}"    # rtrim
        fi
        [[ -z "${!key+x}" ]] && export "$key=$value"
    done < "$f"
}

# load_config [extra_env_file ...]
# Precedence chain (earliest wins, because _load_env_file only sets-if-unset):
#   1. shell env (already present, untouched)
#   2. $MODULE_ROOT/.env            (core creds + paths)
#   3. settings/host.$HOST_NAME.env (per-machine facts, if present)
#   4. each extra file passed in    (e.g. settings/record.<profile>.env)
#   5. the entrypoint's ${X:-default} config block (runs after this returns)
# With an empty settings/ and no extra files, this is exactly the old behavior
# (load $MODULE_ROOT/.env, then defaults).
load_config() {
    _load_env_file "$MODULE_ROOT/.env"
    if [[ -n "${HOST_NAME:-}" ]]; then
        _load_env_file "$MODULE_ROOT/settings/host.${HOST_NAME}.env"
    fi
    local extra
    for extra in "$@"; do
        _load_env_file "$extra"
    done
}

# ---------------------------------------------------------------------------------
# ROBOT_NAME resolution. The Zenoh topic namespace prefix. Honor an already-set
# value (shell/.env/a sourced connect script), else sed it out of lab_connect.sh
# so the robot name is defined in exactly one place.
# ---------------------------------------------------------------------------------
resolve_robot_name() {
    local lab_connect="${1:-$SCRIPT_DIR/lab_connect.sh}"
    if [[ -z "${ROBOT_NAME:-}" ]]; then
        ROBOT_NAME="$(sed -n 's/^export ROBOT_NAME="\?\([^"]*\)"\?.*/\1/p' "$lab_connect" | head -1)"
    fi
    export ROBOT_NAME
}

# ---------------------------------------------------------------------------------
# Stop / teardown helpers.
# ---------------------------------------------------------------------------------
# _stop_by_pattern <pattern> <label>
# Local TERM -> up to 10x0.5s wait -> KILL. The shared body of the per-script
# stop_teleop/stop_rollout/stop_mj functions.
_stop_by_pattern() {
    local pattern="$1" label="${2:-processes}"
    local pids
    pids=$(pgrep -f "$pattern" || true)
    if [[ -z "$pids" ]]; then
        echo "-> No $label running."
        return
    fi
    echo "-> Stopping $label: $pids"
    # shellcheck disable=SC2086
    kill -TERM $pids 2>/dev/null || true
    for _ in $(seq 1 10); do
        pgrep -f "$pattern" >/dev/null || break
        sleep 0.5
    done
    pids=$(pgrep -f "$pattern" || true)
    if [[ -n "$pids" ]]; then
        echo "-> Force-killing leftovers: $pids"
        # shellcheck disable=SC2086
        kill -KILL $pids 2>/dev/null || true
    fi
}

# stop_local <pattern> <label> -- alias for local process teardown.
stop_local() { _stop_by_pattern "$@"; }

# stop_remote_stack <pattern> -- kill a process group ON the Jetson over ssh
# (TERM, 2s, KILL), then close the local ssh -t gnome-terminals that held them.
stop_remote_stack() {
    local pattern="$1" vega_ssh="${2:-${VEGA_SSH:-}}"
    echo "-> Stopping remote stack over ssh..."
    ssh $SSH_OPTS "$vega_ssh" "pkill -TERM -f '$pattern'" 2>/dev/null || true
    sleep 2
    ssh $SSH_OPTS "$vega_ssh" "pkill -KILL -f '$pattern'" 2>/dev/null || true
    pkill -f "$pattern" 2>/dev/null || true
}

# stop_remote_record -- TERM the recorder ON the Jetson (it finalizes in its
# finally: block). TERM only, no KILL, so finalize() can run.
stop_remote_record() {
    local vega_ssh="${1:-${VEGA_SSH:-}}"
    echo "-> Stopping lerobot-record on the Jetson..."
    ssh $SSH_OPTS "$vega_ssh" "pkill -TERM -f '$RECORD_STALE_PATTERN'" 2>/dev/null || true
}

# stop_sensors -- kill the dexsensor binaries on the Jetson and the Nano, plus the
# local ssh terminals that launched them. `pkill -x dexsensor` matches the binary
# by name (not the ssh wrapper, whose command line also contains "dexsensor").
# The Vega block is guarded on VEGA_USER/VEGA_HOST being set (the mj scripts relied
# on this guard; the jetson scripts always have them from defaults).
stop_sensors() {
    echo "-> Stopping sensors..."
    if [[ -n "${VEGA_USER:-}" && -n "${VEGA_HOST:-}" ]]; then
        local vega="$VEGA_USER@$VEGA_HOST"
        ssh $SSH_OPTS "$vega" 'pkill -x dexsensor' 2>/dev/null || true
        if [[ -n "${NANO_USER:-}" && -n "${NANO_HOST:-}" && -n "${NANO_PWD:-}" ]]; then
            ssh $SSH_OPTS "$vega" \
                "sshpass -p '$NANO_PWD' ssh $NANO_SSH_OPTS $NANO_USER@$NANO_HOST 'pkill -x dexsensor'" \
                2>/dev/null || true
        fi
    fi
    # Close the local sensor terminals (their command line contains "dexsensor launch").
    pkill -f 'dexsensor launch' 2>/dev/null || true
}

# ---------------------------------------------------------------------------------
# Stack / recorder detection (for record.sh auto-detect of an already-up stack).
# ---------------------------------------------------------------------------------
# is_stack_up [where] -- true if the driving stack (command_processor +
# robot_controller) is running. Local checks BOTH controllers (guards against a
# zombie match); jetson checks $JETSON_STALE_PATTERN over ssh. An ssh failure is
# reported as unknown (return 2), never a silent "down".
is_stack_up() {
    local where="${1:-${WHERE:-local}}"
    if [[ "$where" == "jetson" ]]; then
        local vega_ssh="${VEGA_SSH:-}"
        ssh $SSH_OPTS "$vega_ssh" true 2>/dev/null || return 2
        ssh $SSH_OPTS "$vega_ssh" "pgrep -f '$JETSON_STALE_PATTERN' >/dev/null" 2>/dev/null
        return
    fi
    pgrep -f "command_processor\.py" >/dev/null && pgrep -f "robot_controller\.py" >/dev/null
}

# is_recorder_up [where] -- true if a lerobot-record is already running.
is_recorder_up() {
    local where="${1:-${WHERE:-local}}"
    if [[ "$where" == "jetson" ]]; then
        local vega_ssh="${VEGA_SSH:-}"
        ssh $SSH_OPTS "$vega_ssh" true 2>/dev/null || return 2
        ssh $SSH_OPTS "$vega_ssh" "pgrep -f '$RECORD_STALE_PATTERN' >/dev/null" 2>/dev/null
        return
    fi
    pgrep -f "$RECORD_STALE_PATTERN" >/dev/null
}

# ---------------------------------------------------------------------------------
# omniteleop repo-root resolution. Prefer the installed (editable) location, since
# that is the code the components actually run; fall back to probing on disk.
# ---------------------------------------------------------------------------------
find_repo_root() {
    local dir="$1"
    while [[ "$dir" != "/" ]]; do
        if [[ -d "$dir/.git" || -f "$dir/pyproject.toml" || -f "$dir/setup.py" ]]; then
            echo "$dir"; return 0
        fi
        dir="$(dirname "$dir")"
    done
    return 1
}

# resolve_omniteleop_root -- echoes the omniteleop repo root, or empty if not
# found. Uses $VENV_PATH's python to locate the installed package first.
resolve_omniteleop_root() {
    local root="" pkg_dir
    pkg_dir="$("$VENV_PATH/bin/python" -c "import omniteleop, os; print(os.path.realpath(os.path.dirname(omniteleop.__file__)))" 2>/dev/null || true)"
    [[ -n "$pkg_dir" ]] && root="$(find_repo_root "$pkg_dir" || true)"
    if [[ -z "$root" || ! -d "$root/src/omniteleop" ]]; then
        root=""
        local candidate
        for candidate in /home/rpl/humanoids/omniteleop "$MODULE_ROOT/../omniteleop" "$MODULE_ROOT/../Vega/omniteleop"; do
            [[ -d "$candidate/src/omniteleop" ]] && { root="$(cd "$candidate" && pwd)"; break; }
        done
    fi
    echo "$root"
}

# ---------------------------------------------------------------------------------
# Sensor launch (canonical). Uses the base_back + base_front cameras and always
# passes --robot $ROBOT_NAME to dexsensor (the non-interactive conda shell on the
# Jetson has no ROBOT_NAME env, so without --robot it would publish under the
# "default" namespace and the follower -- subscribing under $ROBOT_NAME -- would
# see zero frames and abort at connect()). The head camera is on the Nano, reached
# via the Jetson, and also needs --robot for the same reason.
#
# This unifies the sensor block across all launchers and fixes the drift where
# launch_exo_teleop.sh / launch_exo_rollout.sh launched the OLD single
# `--sensor base_camera` with no --robot namespace.
#
# Args: none. Reads VEGA_USER/VEGA_HOST/NANO_USER/NANO_HOST/NANO_PWD, ROBOT_NAME,
# and (for the jetson path) CONDA_SH_REMOTE. $1 optionally selects the conda.sh
# path on the Jetson (defaults to the mj spelling ~/miniconda3/...).
launch_sensors() {
    local conda_sh_remote="${1:-${CONDA_SH_REMOTE:-~/miniconda3/etc/profile.d/conda.sh}}"
    local vega_ssh="${VEGA_USER}@${VEGA_HOST}"
    local nano_ssh="${NANO_USER}@${NANO_HOST}"

    # /etc/dexmate periodically resets to 0700 root:root (a dexmate update/reinstall
    # re-tightens it), which silently makes dexsensor see "0 sensors / Available:
    # (none)" because the dexmate user can't traverse in to read the configs. Catch
    # it with a clear message instead of a cryptic "--sensor matched no configured
    # sensors". (Jetson-side guard; harmless on the mj path since it tests the robot.)
    if ! ssh $SSH_OPTS "$vega_ssh" 'test -x /etc/dexmate' 2>/dev/null; then
        echo "-> ERROR: /etc/dexmate is not traversable by dexmate -> dexsensor will see 0 sensors." >&2
        echo "   Fix on the Jetson:  ssh $vega_ssh 'sudo chmod 711 /etc/dexmate'" >&2
        echo "   (711 = traverse without listing; recurs after dexmate updates. See dexsensor-etc-perms.)" >&2
        exit 1
    fi

    local base_sensor_cmd head_sensor_cmd
    base_sensor_cmd="ssh -t $vega_ssh \"source $conda_sh_remote && conda activate dexcontrol && dexsensor launch --robot $ROBOT_NAME --sensor base_back_camera --sensor base_front_camera --sensor lidar_3d_front --sensor lidar_3d_back\""
    head_sensor_cmd="ssh -t $vega_ssh \"sshpass -p '$NANO_PWD' ssh -t $NANO_SSH_OPTS $nano_ssh 'dexsensor launch --robot $ROBOT_NAME --sensor head_camera'\""

    echo "-> Launching sensors on the Jetson and Nano..."
    gnome-terminal --window --title="base_sensors" -- bash -c "$base_sensor_cmd; exec bash"
    gnome-terminal --window --title="head_camera"  -- bash -c "$head_sensor_cmd; exec bash"
    read -rp "-> Check sensors are running, then press Enter to continue..."
}

# ---------------------------------------------------------------------------------
# Component launch helpers.
# ---------------------------------------------------------------------------------
# run_component <title> <setup> <cmd> -- open a local gnome-terminal that runs
# "$setup && $cmd" and keeps the window open afterward (exec bash).
run_component() {
    local title="$1" setup="$2" cmd="$3"
    gnome-terminal --window --title="$title" -- bash -c "$setup && $cmd; exec bash"
}

# run_component_remote <title> <remote_setup> <cmd> -- open a local gnome-terminal
# holding an `ssh -t` session that runs "$remote_setup && $cmd" on the Jetson. The
# TTY lets closing the window kill the remote.
run_component_remote() {
    local title="$1" remote_setup="$2" cmd="$3" vega_ssh="${4:-${VEGA_SSH:-}}"
    gnome-terminal --window --title="$title" -- \
        bash -c "ssh -t $SSH_OPTS $vega_ssh '$remote_setup && $cmd'; exec bash"
}
