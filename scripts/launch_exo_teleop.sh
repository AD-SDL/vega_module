#!/usr/bin/env bash
#
# Launch (or stop) the exoskeleton teleop stack.
#
#   ./launch_exo_teleop.sh          # launch each component in its own window
#   ./launch_exo_teleop.sh stop     # kill all teleop processes and sensors
#
# Optional env vars (or set them in ../.env):
#   EXO_DEV_PORT              serial port for the exo   (default /dev/ttyUSB0)
#   VENV_PATH                 python venv to activate   (default ~/venvs/dexmate)
#   LAUNCH_SENSORS            true to launch sensors    (default true)
#   LAUNCH_TELEMETRY_VIEWER   true to open the viewer   (default false)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/_common.sh"

# NANO_SSH_OPTS / SSH_OPTS come from _common.sh.

# --- Load environment from ../.env (does not override already-set vars) ---------
# Loaded before the `stop` command so it has the robot/Nano credentials needed
# to reach and kill the remote sensors.
_load_env_file "$MODULE_ROOT/.env"

# The teleop processes this script launches (matched by their .py filenames);
# used for both the `stop` command and the pre-launch stale cleanup.
# TELEOP_STALE_PATTERN is defined in _common.sh (identical value).
STALE_PATTERN="$TELEOP_STALE_PATTERN"

# stop_teleop: its labels ("Stopping teleop processes: " / "No teleop processes
# running." / "Force-killing leftovers: ") match the _common.sh core exactly, so route
# through stop_local with the "teleop processes" label.
stop_teleop() { stop_local "$STALE_PATTERN" "teleop processes"; }

# stop_sensors comes from _common.sh (unified; ConnectTimeout 8->10, the one accepted delta).

if [[ "${1:-}" == "stop" ]]; then
    stop_teleop
    stop_sensors
    exit 0
fi

# --- Configuration ------------------------------------------------------------
EXO_DEV_PORT="${EXO_DEV_PORT:-/dev/ttyUSB0}"
VENV_PATH="${VENV_PATH:-$HOME/venvs/dexmate}"
LAUNCH_SENSORS="${LAUNCH_SENSORS:-true}"
LAUNCH_TELEMETRY_VIEWER="${LAUNCH_TELEMETRY_VIEWER:-false}"

# --- Resolve the omniteleop repo root -----------------------------------------
# resolve_omniteleop_root (in _common.sh) prefers the installed editable location, else
# probes on disk.
OMNITELEOP_ROOT="$(resolve_omniteleop_root)"
if [[ -z "$OMNITELEOP_ROOT" ]]; then
    echo "-> ERROR: could not locate the omniteleop repo (no src/omniteleop found)." >&2
    exit 1
fi
echo "-> omniteleop repo root: $OMNITELEOP_ROOT"

LAB_CONNECT_SCRIPT="$SCRIPT_DIR/lab_connect.sh"

# Robot namespace prefix for all Zenoh topics. dexcomm nodes prefix topics with
# this (falling back to the ROBOT_NAME env var); the recorder subscribes under
# it, so any remote sensor publisher must use the same value or its topics are
# invisible. Sourced from lab_connect.sh to avoid duplicating the robot name.
resolve_robot_name "$LAB_CONNECT_SCRIPT"

# Requires a passwordless sudoers rule for this exact chmod command, e.g.:
#   <your_username> ALL=(ALL) NOPASSWD: /usr/bin/chmod 666 /dev/ttyUSB0
SETUP="sudo chmod 666 $EXO_DEV_PORT && source \"$VENV_PATH/bin/activate\" && source \"$LAB_CONNECT_SCRIPT\" && cd \"$OMNITELEOP_ROOT\""

# --- Optionally launch sensors (Jetson + Nano) --------------------------------
# launch_sensors (in _common.sh) is the canonical block: base_back + base_front cameras
# + lidars on the Jetson and head_camera on the Nano, each with --robot $ROBOT_NAME. This
# REPLACES this script's former single `--sensor base_camera` (no --robot) -- the drift-#1
# fix (see /tmp parity ACCEPTED_DELTAS / .docs). Needs VEGA_USER/VEGA_HOST exported.
if [[ "$LAUNCH_SENSORS" == "true" ]]; then
    launch_sensors
fi

# --- Build the teleop component list ------------------------------------------
OMNITELEOP_CMDS=(
    "python src/omniteleop/leader/joycon_reader.py"
    "python src/omniteleop/leader/arm_reader.py"
    "python src/omniteleop/follower/command_processor.py"
    "python src/omniteleop/follower/robot_controller.py --interpolation-method linear"
    "python src/omniteleop/record/mcap_recorder.py"
)
if [[ "$LAUNCH_TELEMETRY_VIEWER" == "true" ]]; then
    OMNITELEOP_CMDS+=("python src/omniteleop/tools/telemetry_viewer.py")
fi

# --- Clean up any stale processes, then launch --------------------------------
# Each component opens in its own window.
stop_teleop
read -rp "-> Get into default position to calibrate exoskeleton, then press Enter to launch..."

for cmd in "${OMNITELEOP_CMDS[@]}"; do
    title="$(basename "$(echo "$cmd" | awk '{print $2}')")"
    gnome-terminal --window --title="$title" -- bash -c "$SETUP && $cmd; exec bash"
done
