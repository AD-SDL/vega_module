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
source "$SCRIPT_DIR/_common.sh"

# NANO_SSH_OPTS / SSH_OPTS come from _common.sh (SSH_OPTS=ConnectTimeout=10, same as before).

# --- Load ../.env (does not override already-set vars) -------------------------
_load_env_file "$MODULE_ROOT/.env"

# --- Configuration ------------------------------------------------------------
VENV_PATH="${VENV_PATH:-$HOME/venvs/dexmate}"
JETSON_ENV="${JETSON_ENV:-rollout}"
EXO_DEV_PORT="${EXO_DEV_PORT:-/dev/ttyUSB0}"
LAUNCH_SENSORS="${LAUNCH_SENSORS:-true}"
LAUNCH_TELEMETRY_VIEWER="${LAUNCH_TELEMETRY_VIEWER:-false}"

LAB_CONNECT_SCRIPT="$SCRIPT_DIR/lab_connect.sh"
CONDA_SH_REMOTE="~/miniconda3/etc/profile.d/conda.sh"
# vega_module path ON THE JETSON (dexmate: ~/vega_module, no 'humanoids' parent). Override
# JETSON_VEGA_DIR if the Jetson's layout differs.
JETSON_VEGA_DIR="${JETSON_VEGA_DIR:-~/vega_module}"
JETSON_CONNECT_REMOTE="$JETSON_VEGA_DIR/scripts/jetson_connect.sh"   # Jetson-local robot env (no tunnel)

# Export VEGA_USER/VEGA_HOST (not just VEGA_SSH) so _common.sh's stop_sensors guard fires.
export VEGA_USER="${VEGA_USER:-dexmate}"
export VEGA_HOST="${VEGA_HOST:-146.137.240.51}"
VEGA_SSH="$VEGA_USER@$VEGA_HOST"

# mj joycon and the Jetson stack must share one ROBOT_NAME (the Zenoh prefix).
resolve_robot_name "$LAB_CONNECT_SCRIPT"

# JETSON_STALE_PATTERN / MJ_STALE_PATTERN come from _common.sh.

# --- stop helpers -------------------------------------------------------------
# stop_mj kept local to preserve its exact labels ("Stopping mj joycon:" / "No mj joycon
# process running.") -- stop_local's single label can't reproduce both.
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

# This script's teardown message is "Jetson teleop stack" (the record-common variant says
# "driving stack"), so keep it local rather than use stop_remote_stack's generic message.
stop_jetson() {
    echo "-> Stopping Jetson teleop stack over ssh..."
    ssh $SSH_OPTS "$VEGA_SSH" "pkill -TERM -f '$JETSON_STALE_PATTERN'" 2>/dev/null || true
    sleep 2
    ssh $SSH_OPTS "$VEGA_SSH" "pkill -KILL -f '$JETSON_STALE_PATTERN'" 2>/dev/null || true
    pkill -f "$JETSON_STALE_PATTERN" 2>/dev/null || true   # close the local ssh -t gnome-terminals too
}

# stop_sensors comes from _common.sh (unified).

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
    launch_sensors "$CONDA_SH_REMOTE"
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
