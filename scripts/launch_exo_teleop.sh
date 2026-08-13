#!/usr/bin/env bash

# set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)" # adjust ".." to match actual script depth

ENV_FILE="$MODULE_ROOT/.env"
if [[ -f "$ENV_FILE" ]]; then
    echo "-> Loading environment from $ENV_FILE"
    while IFS='=' read -r key value; do
        [[ -z "$key" || "$key" == \#* ]] && continue
        if [[ -z "${!key+x}" ]]; then
            export "$key=$value"
        fi
    done < "$ENV_FILE"
fi

# find_repo_root() {
#     local dir="$1"
#     while [[ "$dir" != "/" ]]; do
#         if [[ -d "$dir/.git" || -f "$dir/pyproject.toml" || -f "$dir/setup.py" ]]; then
#             echo "$dir"
#             return 0
#         fi
#         dir="$(dirname "$dir")"
#     done
#     return 1
# }

# PKG_FILE="$(python -c "import omniteleop, os; print(os.path.abspath(omniteleop.__file__))" 2>/dev/null)" || {
#     echo "Error: could not import 'omniteleop'. Is it installed in the active environment (pip install -e .)?" >&2
#     exit 1
# }

# OMNITELEOP_ROOT="$(find_repo_root "$(dirname "$PKG_FILE")")" || {
#     echo "Error: found omniteleop at $PKG_FILE but couldn't locate a repo root (.git/pyproject.toml/setup.py) above it." >&2
#     exit 1
# }

# echo "-> omniteleop repo root: $OMNITELEOP_ROOT"

find_repo_root() {
    local dir="$1"
    while [[ "$dir" != "/" ]]; do
        if [[ -d "$dir/.git" || -f "$dir/pyproject.toml" || -f "$dir/setup.py" ]]; then
            echo "$dir"
            return 0
        fi
        dir="$(dirname "$dir")"
    done
    return 1
}

PYTHON_BIN="${PYTHON_BIN:-python}"

echo "-> Checking omniteleop import with: $PYTHON_BIN"
set +e
"$PYTHON_BIN" - <<'PYDEBUG' 2>&1
import os, sys, traceback
print(f"python_executable={sys.executable}")
print(f"cwd={os.getcwd()}")
print("sys.path:")
for p in sys.path:
    print(f"  {p}")
try:
    import omniteleop
    print(f"omniteleop_file={os.path.abspath(omniteleop.__file__)}")
except Exception as e:
    print(f"IMPORT_ERROR={type(e).__name__}: {e}")
    traceback.print_exc()
PYDEBUG
set -e

PKG_FILE="$("$PYTHON_BIN" -c "import omniteleop, os; print(os.path.abspath(omniteleop.__file__))" 2>/dev/null || true)"
if [[ -n "$PKG_FILE" ]]; then
    OMNITELEOP_ROOT="$(find_repo_root "$(dirname "$PKG_FILE")" || true)"
else
    OMNITELEOP_ROOT=""
fi

if [[ -z "$OMNITELEOP_ROOT" ]]; then
    echo "-> omniteleop import failed; probing likely repo locations..." >&2
    for candidate in "$MODULE_ROOT" "$MODULE_ROOT/.." "$HOME/humanoids" /home/rpl/humanoids "$HOME"; do
        if [[ -d "$candidate" ]]; then
            found="$(find_repo_root "$candidate" || true)"
            if [[ -n "$found" ]]; then
                echo "-> candidate repo root: $found"
                OMNITELEOP_ROOT="$found"
                break
            fi
        fi
    done
fi

if [[ -z "$OMNITELEOP_ROOT" ]]; then
    OMNITELEOP_ROOT="$(cd "$MODULE_ROOT/.." && pwd)"
    echo "-> WARNING: omniteleop repo root could not be resolved automatically; using fallback: $OMNITELEOP_ROOT" >&2
fi

echo "-> omniteleop repo root: $OMNITELEOP_ROOT"

EXO_DEV_PORT="${EXO_DEV_PORT:-/dev/ttyUSB0}"
VENV_PATH="${VENV_PATH:-$HOME/venvs/dexmate}"
if [[ "$VENV_PATH" == *"/bin/activate" ]]; then
    VENV_PATH="${VENV_PATH%/bin/activate}"
fi
LAUNCH_SENSORS="${LAUNCH_SENSORS:-false}"
LAUNCH_TELEMETRY_VIEWER="${LAUNCH_TELEMETRY_VIEWER:-false}"

VEGA_SSH="${VEGA_USER}@${VEGA_HOST}"
NANO_SSH="${NANO_USER}@${NANO_HOST}"
if [[ -z "${NANO_PWD:-}" ]]; then
    echo "-> WARNING: NANO_PWD is unset; sensor launch will be skipped unless you set it."
fi

LAB_CONNECT_SCRIPT="$SCRIPT_DIR/lab_connect.sh"

# Requires a passwordless sudoers rule for this exact chmod command, e.g.:
#   sudo visudo
#   <your_username> ALL=(ALL) NOPASSWD: /usr/bin/chmod 666 /dev/ttyUSB0
CMD1="sudo chmod 666 $EXO_DEV_PORT"
CMD2="source \"$VENV_PATH/bin/activate\""
CMD3="source \"$LAB_CONNECT_SCRIPT\""
CMD4="cd \"$OMNITELEOP_ROOT\""

BASE_SENSOR_CMD="ssh -t $VEGA_SSH \"conda activate dexcontrol && dexsensor launch --sensor base_camera --sensor lidar_3d_front --sensor lidar_3d_back\""
HEAD_SENSOR_CMD="ssh -t $VEGA_SSH \"sshpass -p '$NANO_PWD' ssh -t $NANO_SSH 'dexsensor launch --sensor head_camera'\""

SENSOR_ARGS=()
TELEOP_ARGS=()

launch_teleop_tab() {
    local title="$1"
    local cmd="$2"
    TELEOP_ARGS+=(--tab --title="$title" -- bash -c "$cmd")
}

launch_sensor_tab() {
    local title="$1"
    local cmd="$2"
    SENSOR_ARGS+=(--tab --title="$title" -- bash -c "$cmd")
}

if [[ "$LAUNCH_SENSORS" == "true" ]]; then
    launch_sensor_tab "base_sensors" "$BASE_SENSOR_CMD"
    launch_sensor_tab "head_camera" "$HEAD_SENSOR_CMD"

    echo "-> Launching sensors on the Jetson and Nano..."
    gnome-terminal "${SENSOR_ARGS[@]}"
    read -rp "-> Check first that sensors are running successfully, then press Enter to launch OmniTeleop..."
fi

OMNITELEOP_CMDS=(
    "python src/omniteleop/leader/joycon_reader.py --debug"
    "python src/omniteleop/leader/arm_reader.py --debug"
    "python src/omniteleop/follower/command_processor.py --debug"
    "python src/omniteleop/follower/robot_controller.py --debug --interpolation-method linear"
    "python src/omniteleop/record/mcap_recorder.py --debug"
)

for cmd in "${OMNITELEOP_CMDS[@]}"; do
    title="$(basename "$(echo "$cmd" | awk '{print $2}')")"
    launch_teleop_tab "$title" "$CMD1 && $CMD2 && $CMD3 && $CMD4 && $cmd; exec bash"
done

if [[ "$LAUNCH_TELEMETRY_VIEWER" == "true" ]]; then
    launch_teleop_tab "telemetry_viewer" "$CMD1 && $CMD2 && $CMD3 && $CMD4 && python src/omniteleop/tools/telemetry_viewer.py; exec bash"
fi

STALE_PATTERN="joycon_reader\.py|arm_reader\.py|robot_controller\.py|command_processor\.py|paddle_leader\.py|omniteleop\.record\.((mcap|mdp)_recorder|replay_record)"
STALE_PIDS=$(pgrep -af "$STALE_PATTERN" | awk '{print $1}' || true)
if [[ -n "$STALE_PIDS" ]]; then
  echo "-> Killing stale teleop processes: $STALE_PIDS"
  # shellcheck disable=SC2086
  kill -TERM $STALE_PIDS 2>/dev/null || true
  for _ in $(seq 1 10); do
    pgrep -af "$STALE_PATTERN" >/dev/null || break
    sleep 0.5
  done
  REMAINING=$(pgrep -af "$STALE_PATTERN" | awk '{print $1}' || true)
  if [[ -n "$REMAINING" ]]; then
    echo "-> Force-killing leftovers: $REMAINING"
    # shellcheck disable=SC2086
    kill -KILL $REMAINING 2>/dev/null || true
  fi
fi

read -rp "-> Get into default position to calibrate exoskeleton, then press Enter to launch..."

gnome-terminal "${TELEOP_ARGS[@]}"
exec bash
