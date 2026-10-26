#!/usr/bin/env bash
#
# launch_jetson_teleop.sh -- exo TELEOP stack with the driving components ON the Jetson
# (arm/cmd/robot + sensors), joycon_reader on mj. Teleop-only counterpart to
# launch_jetson_lerobot_*.sh. See .docs/JETSON_RECORDING.md for the full rationale.
#
#   ./launch_jetson_teleop.sh          # launch the full split stack
#   ./launch_jetson_teleop.sh stop     # kill everything (mj joycon + Jetson stack + sensors)
#
# Config via env or ../.env: VENV_PATH, JETSON_ENV, EXO_DEV_PORT, LAUNCH_SENSORS,
# LAUNCH_TELEMETRY_VIEWER, VEGA_USER/HOST, NANO_USER/HOST/PWD.
#
# SAFETY: robot_controller is the sole hardware writer. `stop` tears down the Jetson
# stack (stops motion) AFTER the mj joycon, so the e-stop path outlives the motion
# source. Keep the e-stop in hand whenever the robot can move.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

NANO_SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
SSH_OPTS="-o ConnectTimeout=10"

# --- Load ../.env (does not override already-set vars) -------------------------
ENV_FILE="$MODULE_ROOT/.env"
if [[ -f "$ENV_FILE" ]]; then
    echo "-> Loading environment from $ENV_FILE"
    while IFS='=' read -r key value || [[ -n "$key" ]]; do
        [[ -z "$key" || "$key" == \#* ]] && continue
        [[ -z "${!key+x}" ]] && export "$key=$value"
    done < "$ENV_FILE"
fi

# --- Configuration ------------------------------------------------------------
VENV_PATH="${VENV_PATH:-$HOME/venvs/dexmate}"
JETSON_ENV="${JETSON_ENV:-rollout}"
EXO_DEV_PORT="${EXO_DEV_PORT:-/dev/ttyUSB0}"
LAUNCH_SENSORS="${LAUNCH_SENSORS:-true}"
LAUNCH_TELEMETRY_VIEWER="${LAUNCH_TELEMETRY_VIEWER:-false}"

LAB_CONNECT_SCRIPT="$SCRIPT_DIR/lab_connect.sh"
CONDA_SH_REMOTE="~/miniconda3/etc/profile.d/conda.sh"
JETSON_CONNECT_REMOTE="~/humanoids/vega_module/scripts/jetson_connect.sh"   # Jetson-local robot env (no tunnel)

VEGA_SSH="${VEGA_USER:-dexmate}@${VEGA_HOST:-146.137.240.51}"

# mj joycon and the Jetson stack must share one ROBOT_NAME (the Zenoh prefix).
ROBOT_NAME="${ROBOT_NAME:-$(sed -n 's/^export ROBOT_NAME="\?\([^"]*\)"\?.*/\1/p' "$LAB_CONNECT_SCRIPT" | head -1)}"

JETSON_STALE_PATTERN="omni-arm|omni-cmd|omni-robot|omni-telemetry|arm_reader\.py|command_processor\.py|robot_controller\.py|telemetry_viewer\.py"
MJ_STALE_PATTERN="joycon_reader\.py"

# --- stop helpers -------------------------------------------------------------
stop_mj() {
    local pids
    pids=$(pgrep -f "$MJ_STALE_PATTERN" || true)
    [[ -z "$pids" ]] && { echo "-> No mj joycon process running."; return; }
    echo "-> Stopping mj joycon: $pids"
    # shellcheck disable=SC2086
    kill -TERM $pids 2>/dev/null || true
    for _ in $(seq 1 10); do pgrep -f "$MJ_STALE_PATTERN" >/dev/null || break; sleep 0.5; done
    pids=$(pgrep -f "$MJ_STALE_PATTERN" || true)
    # shellcheck disable=SC2086
    [[ -n "$pids" ]] && kill -KILL $pids 2>/dev/null || true
}

stop_jetson() {
    echo "-> Stopping Jetson teleop stack over ssh..."
    ssh $SSH_OPTS "$VEGA_SSH" "pkill -TERM -f '$JETSON_STALE_PATTERN'" 2>/dev/null || true
    sleep 2
    ssh $SSH_OPTS "$VEGA_SSH" "pkill -KILL -f '$JETSON_STALE_PATTERN'" 2>/dev/null || true
    pkill -f "$JETSON_STALE_PATTERN" 2>/dev/null || true   # close the local ssh -t gnome-terminals too
}

stop_sensors() {
    echo "-> Stopping sensors..."
    ssh $SSH_OPTS "$VEGA_SSH" 'pkill -x dexsensor' 2>/dev/null || true
    if [[ -n "${NANO_USER:-}" && -n "${NANO_HOST:-}" && -n "${NANO_PWD:-}" ]]; then
        ssh $SSH_OPTS "$VEGA_SSH" \
            "sshpass -p '$NANO_PWD' ssh $NANO_SSH_OPTS $NANO_USER@$NANO_HOST 'pkill -x dexsensor'" \
            2>/dev/null || true
    fi
    pkill -f 'dexsensor launch' 2>/dev/null || true
}

if [[ "${1:-}" == "stop" ]]; then
    stop_mj
    stop_jetson
    stop_sensors
    exit 0
fi

# --- Preflight: reach the Jetson and verify the driving stack can run there ----
# The import/port checks are the exact gaps a stock Jetson has (see .docs/JETSON_RECORDING.md).
echo "-> Preflight: checking the Jetson ($VEGA_SSH)..."
if ! ssh $SSH_OPTS "$VEGA_SSH" true 2>/dev/null; then
    echo "-> ERROR: cannot ssh to $VEGA_SSH. Is the robot on and the key authorized?" >&2
    exit 1
fi
PREFLIGHT_REMOTE="source $CONDA_SH_REMOTE && conda activate $JETSON_ENV && \
python -c 'import omniteleop, dexcontrol, dexcomm, dynamixel_sdk' && \
test -e $EXO_DEV_PORT"
if ! ssh $SSH_OPTS "$VEGA_SSH" "$PREFLIGHT_REMOTE" 2>/dev/null; then
    echo "-> ERROR: Jetson env '$JETSON_ENV' is not ready. It needs omniteleop, dexcontrol," >&2
    echo "   dexcomm and dynamixel_sdk importable, and the exo plugged in at $EXO_DEV_PORT." >&2
    echo "   See .docs/JETSON_RECORDING.md (Jetson setup) to sync/install these." >&2
    exit 1
fi
# joycon_reader runs on mj -> mj venv must have omniteleop.
if ! "$VENV_PATH/bin/python" -c "import omniteleop" 2>/dev/null; then
    echo "-> ERROR: mj venv $VENV_PATH has no omniteleop (needed for joycon_reader)." >&2
    exit 1
fi
echo "   Jetson stack OK; exo at $EXO_DEV_PORT; mj joycon OK."

# --- Remote command builder ---------------------------------------------------
# Each Jetson component runs in a local gnome-terminal holding an `ssh -t` session (the
# TTY lets closing the window kill the remote). The chmod needs a passwordless sudoers
# rule ON THE JETSON:  dexmate ALL=(ALL) NOPASSWD: /usr/bin/chmod 666 /dev/ttyUSB0
REMOTE_SETUP="source $CONDA_SH_REMOTE && conda activate $JETSON_ENV && source $JETSON_CONNECT_REMOTE && sudo chmod 666 $EXO_DEV_PORT"

jetson_term() {   # $1 = window title, $2 = remote command (run in the Jetson env)
    local title="$1" rcmd="$2"
    gnome-terminal --window --title="$title" -- \
        bash -c "ssh -t $SSH_OPTS $VEGA_SSH '$REMOTE_SETUP && $rcmd'; exec bash"
}

# --- Sensors (same as the mj launcher: Jetson base cams/lidar + Nano head) -----
if [[ "$LAUNCH_SENSORS" == "true" ]]; then
    NANO_SSH="${NANO_USER}@${NANO_HOST}"
    BASE_SENSOR_CMD="ssh -t $VEGA_SSH \"source $CONDA_SH_REMOTE && conda activate dexcontrol && dexsensor launch --robot $ROBOT_NAME --sensor base_back_camera --sensor base_front_camera --sensor lidar_3d_front --sensor lidar_3d_back\""
    HEAD_SENSOR_CMD="ssh -t $VEGA_SSH \"sshpass -p '$NANO_PWD' ssh -t $NANO_SSH_OPTS $NANO_SSH 'dexsensor launch --robot $ROBOT_NAME --sensor head_camera'\""
    echo "-> Launching sensors on the Jetson and Nano..."
    gnome-terminal --window --title="base_sensors" -- bash -c "$BASE_SENSOR_CMD; exec bash"
    gnome-terminal --window --title="head_camera" -- bash -c "$HEAD_SENSOR_CMD; exec bash"
    read -rp "-> Check sensors are running, then press Enter to continue..."
fi

# --- Clean stale processes, then calibrate + launch ---------------------------
stop_mj
stop_jetson
read -rp "-> Get into default position to calibrate exoskeleton, then press Enter to launch..."

# mj: joycon_reader (publishes exo_joycon over the tunnel)
MJ_SETUP="source \"$VENV_PATH/bin/activate\" && source \"$LAB_CONNECT_SCRIPT\""
gnome-terminal --window --title="joycon_reader (mj)" -- \
    bash -c "$MJ_SETUP && omni-joycon; exec bash"

# Jetson: the driving stack, each in its own ssh -t window on mj.
jetson_term "arm_reader (jetson)"        "omni-arm"
jetson_term "command_processor (jetson)" "omni-cmd"
jetson_term "robot_controller (jetson)"  "omni-robot --interpolation-method linear"
if [[ "$LAUNCH_TELEMETRY_VIEWER" == "true" ]]; then
    jetson_term "telemetry (jetson)"     "omni-telemetry"
fi

cat <<EOF
-> Launched the split teleop stack:
     mj      : joycon_reader (JoyCons over Bluetooth -> exo_joycon over the tunnel)
     Jetson  : arm_reader + command_processor + robot_controller (+ sensors)
   The exo must be plugged into the JETSON's USB ($EXO_DEV_PORT).

   Align the exo + release the JoyCon e-stop to start motion.
   Stop everything with:  $0 stop
   (Shutdown tears down the Jetson motion stack after the mj JoyCon e-stop path.)
EOF
