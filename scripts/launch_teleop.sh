#!/usr/bin/env bash
#
# launch_teleop.sh -- launch (or stop) the exo teleop stack, optionally with lerobot-record.
#
#   ./launch_teleop.sh remote                  # teleop stack, all components local (the MJ PC)
#   ./launch_teleop.sh local                   # teleop stack, driving on the Jetson, joycon on mj
#   ./launch_teleop.sh remote record           # full stack then record
#   ./launch_teleop.sh local  record-only      # attach a recorder to an already-running stack
#   ./launch_teleop.sh [target] stop           # kill everything (incl. any recorder)
#
# Default target remote, default action teleop. Record settings come from record.env, a dataset
# env (DATASET=<name> -> record-datasets/<name>.env), or the shell/CLI. Config lives in
# connect.env / record.env / ../.env. See .docs/TELEOP.md and .docs/RECORD.md.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONNECT_SCRIPT="$SCRIPT_DIR/connect.sh"

# Snapshot env vars set on the CLI/shell BEFORE any file load, so an explicitly-selected
# dataset env can override global defaults without stepping on a genuine command-line override.
PRESET_KEYS="$(compgen -v)"

source "$SCRIPT_DIR/_env.sh"
_load_env_file "$MODULE_ROOT/.env"
_load_env_file "$SCRIPT_DIR/connect.env"
source "$SCRIPT_DIR/_teleop.sh"

TARGET="${1:-remote}"
[[ "$TARGET" == "stop" ]] && { echo "usage: $0 <remote|local> [teleop|record|record-only] [stop]" >&2; exit 1; }
case "$TARGET" in remote|local) ;; *)
    echo "launch_teleop.sh: unknown target '$TARGET' (expected 'remote' or 'local')" >&2; exit 1 ;;
esac

# Second arg is either an action or 'stop' (stop with no action = stop the teleop stack).
ACTION="${2:-teleop}"
STOP=""
case "$ACTION" in
    stop) STOP="stop"; ACTION="teleop" ;;
    teleop|record|record-only) STOP="${3:-}" ;;
    *) echo "launch_teleop.sh: unknown action '$ACTION' (expected teleop|record|record-only|stop)" >&2; exit 1 ;;
esac
[[ -n "$STOP" && "$STOP" != "stop" ]] && { echo "usage: $0 <remote|local> [teleop|record|record-only] [stop]" >&2; exit 1; }

VENV_PATH="$(_expand_home "${VENV_PATH:-$HOME/venvs/dexmate}")"
JETSON_ENV="${JETSON_ENV:-rollout}"
JETSON_VEGA_DIR="${JETSON_VEGA_DIR:-~/vega_module}"
EXO_DEV_PORT="${EXO_DEV_PORT:-/dev/ttyUSB0}"
LAUNCH_SENSORS="${LAUNCH_SENSORS:-true}"
LAUNCH_TELEMETRY_VIEWER="${LAUNCH_TELEMETRY_VIEWER:-false}"
ROBOT_NAME="${ROBOT_NAME:-$(robot_name_from_env "$SCRIPT_DIR/connect.env")}"
CONNECT_SCRIPT_REMOTE="$JETSON_VEGA_DIR/scripts/connect.sh"

REMOTE_STALE="joycon_reader\.py|arm_reader\.py|command_processor\.py|robot_controller\.py|telemetry_viewer\.py|lerobot-record"
LOCAL_JETSON_STALE="omni-arm|omni-cmd|omni-robot|omni-telemetry|arm_reader\.py|command_processor\.py|robot_controller\.py|telemetry_viewer\.py"
LOCAL_MJ_STALE="joycon_reader\.py"

# Recording actions load record config + the shared record lib, and pick the record sensor set.
RECORDING=""
[[ "$ACTION" == "record" || "$ACTION" == "record-only" ]] && RECORDING="true"
if [[ -n "$RECORDING" ]]; then
    # An explicitly-selected dataset env overrides global defaults (incl. ../.env), but not a
    # var the operator set on the command line. record.env fills the rest (non-clobbering).
    if [[ -n "${DATASET:-}" ]]; then
        if [[ -f "$DATASET" ]]; then DATASET_ENV="$DATASET"
        elif [[ -f "$SCRIPT_DIR/record-datasets/$DATASET.env" ]]; then DATASET_ENV="$SCRIPT_DIR/record-datasets/$DATASET.env"
        else echo "-> ERROR: dataset env for DATASET='$DATASET' not found (looked for a path and record-datasets/$DATASET.env)." >&2; exit 1; fi
        # shellcheck disable=SC2086
        _load_env_file_force "$DATASET_ENV" $PRESET_KEYS
    fi
    _load_env_file "$SCRIPT_DIR/record.env"
    source "$SCRIPT_DIR/_record.sh"
fi

# --- stop --------------------------------------------------------------------
if [[ "$STOP" == "stop" ]]; then
    if [[ "$TARGET" == "remote" ]]; then
        stop_pattern "$REMOTE_STALE" "teleop processes"
    else
        ssh $SSH_OPTS "$VEGA_SSH" "pkill -TERM -f 'lerobot-record'" 2>/dev/null || true
        stop_pattern_remote "$LOCAL_JETSON_STALE" "Jetson teleop stack"
        stop_pattern "$LOCAL_MJ_STALE" "mj joycon"
    fi
    stop_sensors
    exit 0
fi

# --- bring up the stack (skipped for record-only) ----------------------------
# Sensor args: recording needs the base cameras; plain teleop uses its lighter set.
if [[ -n "$RECORDING" ]]; then
    REMOTE_SENSOR_ARGS="$(record_sensor_args)"
else
    REMOTE_SENSOR_ARGS="--sensor base_camera --sensor lidar_3d_front --sensor lidar_3d_back"
fi
LOCAL_SENSOR_ARGS="--robot $ROBOT_NAME --sensor base_back_camera --sensor base_front_camera --sensor lidar_3d_front --sensor lidar_3d_back"

bring_up_remote() {
    OMNITELEOP_ROOT="$(resolve_omniteleop_root)" || exit 1
    echo "-> omniteleop repo root: $OMNITELEOP_ROOT"
    # Passwordless sudoers rule needed: NOPASSWD: /usr/bin/chmod 666 $EXO_DEV_PORT
    local SETUP="sudo chmod 666 $EXO_DEV_PORT && source \"$VENV_PATH/bin/activate\" && source \"$CONNECT_SCRIPT\" remote && cd \"$OMNITELEOP_ROOT\""

    [[ "$LAUNCH_SENSORS" == "true" ]] && launch_sensors "$REMOTE_SENSOR_ARGS"

    local CMDS=(
        "python src/omniteleop/leader/joycon_reader.py"
        "python src/omniteleop/leader/arm_reader.py"
        "python src/omniteleop/follower/command_processor.py"
        "python src/omniteleop/follower/robot_controller.py --interpolation-method linear"
    )
    [[ "$LAUNCH_TELEMETRY_VIEWER" == "true" ]] && CMDS+=("python src/omniteleop/tools/telemetry_viewer.py")

    stop_pattern "$REMOTE_STALE" "teleop processes"
    calibrate_prompt
    for cmd in "${CMDS[@]}"; do
        local title; title="$(basename "$(echo "$cmd" | awk '{print $2}')")"
        gnome-terminal --window --title="$title" -- bash -c "$SETUP && $cmd; exec bash"
    done
}

bring_up_local() {
    echo "-> Preflight: checking the Jetson ($VEGA_SSH)..."
    ssh $SSH_OPTS "$VEGA_SSH" true 2>/dev/null || {
        echo "-> ERROR: cannot ssh to $VEGA_SSH. Is the robot on and the key authorized?" >&2; exit 1; }
    local PREFLIGHT="source $CONDA_SH_REMOTE && conda activate $JETSON_ENV && \
python -c 'import omniteleop, dexcontrol, dexcomm, dynamixel_sdk' && test -e $EXO_DEV_PORT"
    if ! ssh $SSH_OPTS "$VEGA_SSH" "$PREFLIGHT" 2>/dev/null; then
        echo "-> ERROR: Jetson env '$JETSON_ENV' is not ready. It needs omniteleop, dexcontrol," >&2
        echo "   dexcomm and dynamixel_sdk importable, and the exo plugged in at $EXO_DEV_PORT." >&2
        echo "   See .docs/JETSON_RECORDING.md (Jetson setup) to sync/install these." >&2
        exit 1
    fi
    "$VENV_PATH/bin/python" -c "import omniteleop" 2>/dev/null || {
        echo "-> ERROR: mj venv $VENV_PATH has no omniteleop (needed for joycon_reader)." >&2; exit 1; }
    echo "   Jetson stack OK; exo at $EXO_DEV_PORT; mj joycon OK."

    # Passwordless sudoers rule needed ON THE JETSON: NOPASSWD: /usr/bin/chmod 666 $EXO_DEV_PORT
    local REMOTE_SETUP="source $CONDA_SH_REMOTE && conda activate $JETSON_ENV && source $CONNECT_SCRIPT_REMOTE local && sudo chmod 666 $EXO_DEV_PORT"
    jetson_term() {
        gnome-terminal --window --title="$1" -- \
            bash -c "ssh -t $SSH_OPTS $VEGA_SSH '$REMOTE_SETUP && $2'; exec bash"
    }

    if [[ "$LAUNCH_SENSORS" == "true" ]]; then
        if ! ssh $SSH_OPTS "$VEGA_SSH" 'test -x /etc/dexmate' 2>/dev/null; then
            echo "-> ERROR: /etc/dexmate is not traversable by dexmate -> dexsensor will see 0 sensors." >&2
            echo "   Fix on the Jetson:  ssh $VEGA_SSH 'sudo chmod 711 /etc/dexmate'" >&2
            echo "   (711 = traverse without listing; recurs after dexmate updates. See dexsensor-etc-perms.)" >&2
            exit 1
        fi
        launch_sensors "$LOCAL_SENSOR_ARGS"
    fi

    stop_pattern "$LOCAL_MJ_STALE" "mj joycon"
    stop_pattern_remote "$LOCAL_JETSON_STALE" "Jetson teleop stack"
    calibrate_prompt

    local MJ_SETUP="source \"$VENV_PATH/bin/activate\" && source \"$CONNECT_SCRIPT\" remote"
    gnome-terminal --window --title="joycon_reader (mj)" -- bash -c "$MJ_SETUP && omni-joycon; exec bash"
    jetson_term "arm_reader (jetson)"        "omni-arm"
    jetson_term "command_processor (jetson)" "omni-cmd"
    jetson_term "robot_controller (jetson)"  "omni-robot --interpolation-method linear"
    [[ "$LAUNCH_TELEMETRY_VIEWER" == "true" ]] && jetson_term "telemetry (jetson)" "omni-telemetry"

    cat <<EOF
-> Launched the split teleop stack:
     mj      : joycon_reader (JoyCons over Bluetooth -> exo_joycon over the tunnel)
     Jetson  : arm_reader + command_processor + robot_controller (+ sensors)
   The exo must be plugged into the JETSON's USB ($EXO_DEV_PORT).
   Align the exo + release the JoyCon e-stop to start motion.
EOF
}

if [[ "$ACTION" != "record-only" ]]; then
    if [[ "$TARGET" == "remote" ]]; then bring_up_remote; else bring_up_local; fi
fi

# --- teleop-only: done -------------------------------------------------------
if [[ "$ACTION" == "teleop" ]]; then
    echo "   Stop everything with:  $0 $TARGET stop"
    exit 0
fi

# --- record / record-only ----------------------------------------------------
[[ "$ACTION" == "record-only" ]] && record_only_guard "$TARGET"
record_preflight "$TARGET"
if [[ "$ACTION" == "record" && "$TARGET" == "local" ]]; then
    read -rp "-> Press Enter once the stack is up and the exo is aligned, to start recording..."
fi
run_record_session "$TARGET" "$RECORD_MODE"
print_rsync_hint "$TARGET"
echo "   Stop everything with:  $0 $TARGET stop"
