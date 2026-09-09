#!/usr/bin/env bash
#
# Launch (or stop) the exoskeleton teleop stack with LeRobot as the recorder.
#
# Same stack as launch_exo_teleop.sh, minus mcap_recorder.py: omniteleop still drives
# the robot (robot_controller.py, 100 Hz, ruckig + Butterworth + safety validator +
# JoyCon e-stop), while `lerobot-record` records a native LeRobot dataset directly.
# The LeRobot follower runs with use_external_commands=true, so it observes and records
# but never commands -- there is exactly one writer to the hardware, as before.
#
# This replaces the MCAP -> dexdata -> flatten_lerobot_features.py pipeline: the dataset
# comes out policy-trainable in one step. Note the joint layout is the follower's
# VEGA_JOINTS order (left_arm, right_arm, head, torso, left_hand, right_hand), which
# differs from POSITION_GROUPS in flatten_lerobot_features.py -- episodes recorded here
# are NOT layout-compatible with previously exported ones.
#
#   ./launch_exo_lerobot.sh          # launch each component in its own window
#   ./launch_exo_lerobot.sh stop     # kill all teleop processes and sensors
#
# Optional env vars (or set them in ../.env):
#   DATASET_REPO_ID           dataset to write             (default local/vega_exo)
#   DATASET_TASK              task description string      (default "teleoperation")
#   NUM_EPISODES              episodes to record           (default 10)
#   EPISODE_TIME_S            seconds per episode          (default 60)
#   RESET_TIME_S              seconds between episodes     (default 15)
#   FPS                       record rate                  (default 20, = command_rate)
#   PUSH_TO_HUB               push the dataset to HF Hub   (default false)
#   LEROBOT_VENV_PATH         venv holding BOTH lerobot and dexcontrol (default VENV_PATH)
#   EXO_DEV_PORT              serial port for the exo      (default /dev/ttyUSB0)
#   VENV_PATH                 python venv to activate      (default ~/venvs/dexmate)
#   LAUNCH_SENSORS            true to launch sensors       (default true)
#   LAUNCH_TELEMETRY_VIEWER   true to open the viewer      (default false)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ssh options for the Nano hop (via the Jetson): a first-time or stale host-key
# entry makes ssh refuse password auth, so skip known_hosts entirely.
NANO_SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

# --- Load environment from ../.env (does not override already-set vars) ---------
# Loaded before the `stop` command so it has the robot/Nano credentials needed
# to reach and kill the remote sensors.
ENV_FILE="$MODULE_ROOT/.env"
if [[ -f "$ENV_FILE" ]]; then
    echo "-> Loading environment from $ENV_FILE"
    # `|| [[ -n "$key" ]]` processes a final line that has no trailing newline
    # (otherwise the last var in .env is silently dropped).
    while IFS='=' read -r key value || [[ -n "$key" ]]; do
        [[ -z "$key" || "$key" == \#* ]] && continue
        [[ -z "${!key+x}" ]] && export "$key=$value"
    done < "$ENV_FILE"
fi

# The processes this script launches (matched by their .py filenames, plus the LeRobot
# CLI); used for both the `stop` command and the pre-launch stale cleanup.
STALE_PATTERN="joycon_reader\.py|arm_reader\.py|command_processor\.py|robot_controller\.py|telemetry_viewer\.py|lerobot-record"

stop_teleop() {
    local pids
    pids=$(pgrep -f "$STALE_PATTERN" || true)
    if [[ -z "$pids" ]]; then
        echo "-> No teleop processes running."
        return
    fi
    echo "-> Stopping teleop processes: $pids"
    # shellcheck disable=SC2086
    kill -TERM $pids 2>/dev/null || true
    for _ in $(seq 1 10); do
        pgrep -f "$STALE_PATTERN" >/dev/null || break
        sleep 0.5
    done
    pids=$(pgrep -f "$STALE_PATTERN" || true)
    if [[ -n "$pids" ]]; then
        echo "-> Force-killing leftovers: $pids"
        # shellcheck disable=SC2086
        kill -KILL $pids 2>/dev/null || true
    fi
}

# Kill the sensors: the dexsensor binaries on the Jetson and the Nano, plus the
# local ssh terminals that launched them. `pkill -x dexsensor` matches the binary
# by name (not the ssh wrapper, whose command line also contains "dexsensor").
stop_sensors() {
    echo "-> Stopping sensors..."
    if [[ -n "${VEGA_USER:-}" && -n "${VEGA_HOST:-}" ]]; then
        local vega="$VEGA_USER@$VEGA_HOST"
        ssh -o ConnectTimeout=8 "$vega" 'pkill -x dexsensor' 2>/dev/null || true
        if [[ -n "${NANO_USER:-}" && -n "${NANO_HOST:-}" && -n "${NANO_PWD:-}" ]]; then
            ssh -o ConnectTimeout=8 "$vega" \
                "sshpass -p '$NANO_PWD' ssh $NANO_SSH_OPTS $NANO_USER@$NANO_HOST 'pkill -x dexsensor'" \
                2>/dev/null || true
        fi
    fi
    # Close the local sensor terminals (their command line contains "dexsensor launch").
    pkill -f 'dexsensor launch' 2>/dev/null || true
}

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

# LeRobot needs dexcontrol (for observations) and dexcomm (for the teleoperator's zenoh
# subscription) in the same interpreter, so by default it shares the teleop venv. Point
# this elsewhere only if that venv also has lerobot installed from the vega_1p branch.
LEROBOT_VENV_PATH="${LEROBOT_VENV_PATH:-$VENV_PATH}"

DATASET_REPO_ID="${DATASET_REPO_ID:-local/vega_exo}"
DATASET_TASK="${DATASET_TASK:-teleoperation}"
NUM_EPISODES="${NUM_EPISODES:-10}"
EPISODE_TIME_S="${EPISODE_TIME_S:-60}"
RESET_TIME_S="${RESET_TIME_S:-15}"
# 20 Hz matches omniteleop's rates.command_rate -- recording faster only duplicates
# frames, since command_processor publishes no more often than that.
FPS="${FPS:-20}"
# lerobot-record pushes to the HF Hub by default, which fails for a local repo_id.
PUSH_TO_HUB="${PUSH_TO_HUB:-false}"

# --- Resolve the omniteleop repo root -----------------------------------------
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

# Prefer the installed omniteleop location (editable install in the venv), since
# that is the code the components actually run. Fall back to probing on disk.
OMNITELEOP_ROOT=""
PKG_DIR="$("$VENV_PATH/bin/python" -c "import omniteleop, os; print(os.path.realpath(os.path.dirname(omniteleop.__file__)))" 2>/dev/null || true)"
[[ -n "$PKG_DIR" ]] && OMNITELEOP_ROOT="$(find_repo_root "$PKG_DIR" || true)"

if [[ -z "$OMNITELEOP_ROOT" || ! -d "$OMNITELEOP_ROOT/src/omniteleop" ]]; then
    OMNITELEOP_ROOT=""
    for candidate in /home/rpl/humanoids/omniteleop "$MODULE_ROOT/../omniteleop" "$MODULE_ROOT/../Vega/omniteleop"; do
        [[ -d "$candidate/src/omniteleop" ]] && { OMNITELEOP_ROOT="$(cd "$candidate" && pwd)"; break; }
    done
fi

if [[ -z "$OMNITELEOP_ROOT" ]]; then
    echo "-> ERROR: could not locate the omniteleop repo (no src/omniteleop found)." >&2
    exit 1
fi
echo "-> omniteleop repo root: $OMNITELEOP_ROOT"

LAB_CONNECT_SCRIPT="$SCRIPT_DIR/lab_connect.sh"

# Fail early rather than after the operator has aligned the exoskeleton: a LeRobot
# without dexcontrol, or a lerobot too old to know the Vega, wastes a whole setup cycle.
if ! "$LEROBOT_VENV_PATH/bin/python" -c "import lerobot, dexcontrol, dexcomm" 2>/dev/null; then
    echo "-> ERROR: $LEROBOT_VENV_PATH must have lerobot, dexcontrol and dexcomm importable." >&2
    echo "   Install the vega_1p branch of lerobot into the teleop venv:" >&2
    echo "     source $VENV_PATH/bin/activate && uv pip install -e /path/to/lerobot" >&2
    exit 1
fi
if ! "$LEROBOT_VENV_PATH/bin/python" -c "from lerobot.teleoperators.vega_exo_joycon import VegaExoJoycon" 2>/dev/null; then
    echo "-> ERROR: this lerobot has no vega_exo_joycon teleoperator (wrong branch?)." >&2
    exit 1
fi

# Robot namespace prefix for all Zenoh topics. dexcomm nodes prefix topics with
# this (falling back to the ROBOT_NAME env var); the teleoperator subscribes under
# it, so any remote sensor publisher must use the same value or its topics are
# invisible. Sourced from lab_connect.sh to avoid duplicating the robot name.
ROBOT_NAME="${ROBOT_NAME:-$(sed -n 's/^export ROBOT_NAME="\?\([^"]*\)"\?.*/\1/p' "$LAB_CONNECT_SCRIPT" | head -1)}"

# Requires a passwordless sudoers rule for this exact chmod command, e.g.:
#   <your_username> ALL=(ALL) NOPASSWD: /usr/bin/chmod 666 /dev/ttyUSB0
SETUP="sudo chmod 666 $EXO_DEV_PORT && source \"$VENV_PATH/bin/activate\" && source \"$LAB_CONNECT_SCRIPT\" && cd \"$OMNITELEOP_ROOT\""
# LeRobot needs the same robot env (ROBOT_NAME, ZENOH_CONFIG, the tunnel) but not the
# exo serial port or the omniteleop working directory.
LEROBOT_SETUP="source \"$LEROBOT_VENV_PATH/bin/activate\" && source \"$LAB_CONNECT_SCRIPT\""

# --- Optionally launch sensors (Jetson + Nano) --------------------------------
if [[ "$LAUNCH_SENSORS" == "true" ]]; then
    VEGA_SSH="${VEGA_USER}@${VEGA_HOST}"
    NANO_SSH="${NANO_USER}@${NANO_HOST}"
    # Non-interactive ssh doesn't source ~/.bashrc, so conda must be initialized
    # explicitly before activating the dexcontrol env on the Jetson.
    BASE_SENSOR_CMD="ssh -t $VEGA_SSH \"source ~/miniconda3/etc/profile.d/conda.sh && conda activate dexcontrol && dexsensor launch --sensor base_camera --sensor lidar_3d_front --sensor lidar_3d_back\""
    # Head camera is on the Nano, reached via the Jetson. The Nano has no
    # ROBOT_NAME env, so dexsensor would publish under the "default" namespace and
    # the follower (which subscribes under $ROBOT_NAME) never sees it; --robot
    # forces the right namespace.
    HEAD_SENSOR_CMD="ssh -t $VEGA_SSH \"sshpass -p '$NANO_PWD' ssh -t $NANO_SSH_OPTS $NANO_SSH 'dexsensor launch --robot $ROBOT_NAME --sensor head_camera'\""

    echo "-> Launching sensors on the Jetson and Nano..."
    gnome-terminal --window --title="base_sensors" -- bash -c "$BASE_SENSOR_CMD; exec bash"
    gnome-terminal --window --title="head_camera" -- bash -c "$HEAD_SENSOR_CMD; exec bash"
    read -rp "-> Check sensors are running, then press Enter to continue..."
fi

# --- Build the teleop component list ------------------------------------------
# mcap_recorder.py is deliberately absent: lerobot-record is the recorder here.
OMNITELEOP_CMDS=(
    "python src/omniteleop/leader/joycon_reader.py"
    "python src/omniteleop/leader/arm_reader.py"
    "python src/omniteleop/follower/command_processor.py"
    "python src/omniteleop/follower/robot_controller.py --interpolation-method linear"
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

# --- LeRobot recorder ---------------------------------------------------------
# use_external_commands=true: robot_controller owns the hardware, so send_action()
# records the exo target without issuing a competing setpoint.
# max_relative_target=null: the clamp only shapes commands we are not sending.
LEROBOT_CMD="lerobot-record \
  --robot.type=vega_1p_follower \
  --robot.id=vega_1p \
  --robot.use_external_commands=true \
  --robot.max_relative_target=null \
  --teleop.type=vega_exo_joycon \
  --teleop.id=exo \
  --dataset.repo_id=$DATASET_REPO_ID \
  --dataset.single_task=\"$DATASET_TASK\" \
  --dataset.num_episodes=$NUM_EPISODES \
  --dataset.episode_time_s=$EPISODE_TIME_S \
  --dataset.reset_time_s=$RESET_TIME_S \
  --dataset.fps=$FPS \
  --dataset.push_to_hub=$PUSH_TO_HUB"

echo "-> Waiting for the teleop stack to come up before starting the recorder..."
echo "   The teleoperator blocks until command_processor publishes, which needs the exo"
echo "   aligned with the robot and the JoyCon e-stop released."
read -rp "-> Press Enter to start lerobot-record (writing to $DATASET_REPO_ID)..."

gnome-terminal --window --title="lerobot-record" -- bash -c "$LEROBOT_SETUP && $LEROBOT_CMD; exec bash"

echo "-> Launched. Stop with: $0 stop"
echo "   Stop LeRobot before the omniteleop stack: its dexcontrol.Robot.shutdown()"
echo "   issues component stop() calls on hardware that robot_controller is still driving."
