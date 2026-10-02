#!/usr/bin/env bash
#
# Launch (or stop) an autonomous policy ROLLOUT on the Vega-1 Pro with LeRobot.
#
# This is the deployment counterpart to launch_exo_lerobot.sh. Where the recorder
# runs the omniteleop stack as the hardware writer and the LeRobot follower merely
# OBSERVES (use_external_commands=true, send_action a no-op), a rollout inverts that:
#
#   * There is NO omniteleop stack and NO exoskeleton teleoperator. The trained
#     policy produces the actions.
#   * The LeRobot follower becomes the SOLE hardware writer
#     (use_external_commands=false), so send_action() actually calls set_joint_pos()
#     on the robot (see vega_1p_follower.py:391 -- the no-op branch is skipped).
#   * omniteleop MUST NOT be running at the same time. Two writers fighting over the
#     same joints is dangerous, so this script refuses to launch if it detects the
#     omniteleop stack up (stop it first: ./launch_exo_lerobot.sh stop).
#
# >>> SAFETY: this drives a full-size humanoid autonomously from a freshly trained,
#     unproven policy. Keep the e-stop joycon in hand and ready. Clear the workspace
#     of people. Start the robot near the pose your episodes began in (ACT
#     extrapolates badly from out-of-distribution starts). MAX_RELATIVE_TARGET below
#     clamps per-step joint motion -- keep it SMALL until you trust the policy.
#
#   ./launch_exo_rollout.sh          # bring up sensors + run the policy rollout
#   ./launch_exo_rollout.sh stop     # kill the rollout and the sensors
#
# Optional env vars (or set them in ../.env):
#   POLICY_PATH               HF repo id or local checkpoint dir of the trained
#                             policy's pretrained_model    (default acleary/act_box_pickup)
#   ROLLOUT_TASK              task string handed to the policy (default "pick up the box")
#   FPS                       control rate                 (default 20, = training/command rate)
#   DURATION                  seconds to run, 0 = until stopped (default 0)
#   DEVICE                    inference device             (default cpu; mj has no NVIDIA GPU)
#   MAX_RELATIVE_TARGET       per-step joint motion clamp  (default 0.1; SAFETY -- keep small)
#   WITH_HEAD_DEPTH           feed head depth to the policy (default false; MUST match the
#                             feature set the policy was TRAINED on, or rollout errors)
#   RETURN_TO_INITIAL         interpolate back to the startup pose on clean stop (default true)
#   DISPLAY_DATA              open a rerun viewer of observations (default false)
#   LEROBOT_VENV_PATH         venv holding lerobot + dexcontrol (default VENV_PATH)
#   VENV_PATH                 python venv to activate      (default ~/venvs/dexmate)
#   LAUNCH_SENSORS            true to launch sensors       (default true)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ssh options for the Nano hop (via the Jetson): a first-time or stale host-key
# entry makes ssh refuse password auth, so skip known_hosts entirely.
NANO_SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

# --- Load environment from ../.env (does not override already-set vars) ---------
ENV_FILE="$MODULE_ROOT/.env"
if [[ -f "$ENV_FILE" ]]; then
    echo "-> Loading environment from $ENV_FILE"
    while IFS='=' read -r key value || [[ -n "$key" ]]; do
        [[ -z "$key" || "$key" == \#* ]] && continue
        [[ -z "${!key+x}" ]] && export "$key=$value"
    done < "$ENV_FILE"
fi

# The rollout process (the LeRobot CLI). Matched for both `stop` and stale cleanup.
STALE_PATTERN="lerobot-rollout"
# The omniteleop hardware writers -- if ANY of these are up, a rollout would be a
# second writer to the same joints. We refuse to launch while they run.
OMNITELEOP_PATTERN="joycon_reader\.py|arm_reader\.py|command_processor\.py|robot_controller\.py|lerobot-record"

stop_rollout() {
    local pids
    pids=$(pgrep -f "$STALE_PATTERN" || true)
    if [[ -z "$pids" ]]; then
        echo "-> No rollout process running."
        return
    fi
    echo "-> Stopping rollout: $pids"
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
# local ssh terminals that launched them.
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
    pkill -f 'dexsensor launch' 2>/dev/null || true
}

if [[ "${1:-}" == "stop" ]]; then
    stop_rollout
    stop_sensors
    exit 0
fi

# --- Configuration ------------------------------------------------------------
VENV_PATH="${VENV_PATH:-$HOME/venvs/dexmate}"
LAUNCH_SENSORS="${LAUNCH_SENSORS:-true}"
LEROBOT_VENV_PATH="${LEROBOT_VENV_PATH:-$VENV_PATH}"

POLICY_PATH="${POLICY_PATH:-acleary/act_box_pickup}"
ROLLOUT_TASK="${ROLLOUT_TASK:-pick up the box}"
FPS="${FPS:-20}"
DURATION="${DURATION:-0}"
# mj (the machine on the robot's Zenoh tunnel) has no NVIDIA GPU, so inference runs
# on CPU. ACT is small enough to keep up at 20 Hz; lower FPS if it can't.
DEVICE="${DEVICE:-cpu}"
# SAFETY clamp: send_action() -> ensure_safe_goal_position() limits |goal - present|
# per joint per tick to this value. Small = the robot can only inch per step, so a
# bad policy output can't fling a joint. Raise only once the policy behaves. Do NOT
# set this to null for deployment (null removes the clamp -- that was only safe for
# recording, where send_action wrote nothing).
MAX_RELATIVE_TARGET="${MAX_RELATIVE_TARGET:-0.1}"
# MUST match the observation features the policy was TRAINED on. If your recorded
# dataset included observation.images.head_camera_depth, set this true; otherwise the
# policy's expected inputs won't match the robot's observation and rollout errors.
WITH_HEAD_DEPTH="${WITH_HEAD_DEPTH:-false}"
RETURN_TO_INITIAL="${RETURN_TO_INITIAL:-true}"
DISPLAY_DATA="${DISPLAY_DATA:-false}"

LAB_CONNECT_SCRIPT="$SCRIPT_DIR/lab_connect.sh"

# --- Preflight: env, imports, and the no-dual-writer guard ---------------------
if ! "$LEROBOT_VENV_PATH/bin/python" -c "import lerobot, dexcontrol, dexcomm" 2>/dev/null; then
    echo "-> ERROR: $LEROBOT_VENV_PATH must have lerobot, dexcontrol and dexcomm importable." >&2
    exit 1
fi
if ! "$LEROBOT_VENV_PATH/bin/python" -c "from lerobot.scripts.lerobot_rollout import main" 2>/dev/null; then
    echo "-> ERROR: this lerobot has no lerobot-rollout (wrong branch?)." >&2
    exit 1
fi

# Refuse to run alongside omniteleop -- two writers to the same joints is unsafe.
if pgrep -f "$OMNITELEOP_PATTERN" >/dev/null; then
    echo "-> ERROR: omniteleop / lerobot-record is still running. A rollout would be a" >&2
    echo "   SECOND writer to the robot. Stop it first:" >&2
    echo "     $SCRIPT_DIR/launch_exo_lerobot.sh stop" >&2
    exit 1
fi

# Robot namespace prefix for all Zenoh topics (sourced from lab_connect.sh).
ROBOT_NAME="${ROBOT_NAME:-$(sed -n 's/^export ROBOT_NAME="\?\([^"]*\)"\?.*/\1/p' "$LAB_CONNECT_SCRIPT" | head -1)}"

# LeRobot needs the robot env (ROBOT_NAME, ZENOH_CONFIG, the tunnel). No exo serial
# port and no omniteleop working directory -- the policy is the driver.
LEROBOT_SETUP="source \"$LEROBOT_VENV_PATH/bin/activate\" && source \"$LAB_CONNECT_SCRIPT\""

# --- Optionally launch sensors (Jetson + Nano) --------------------------------
if [[ "$LAUNCH_SENSORS" == "true" ]]; then
    VEGA_SSH="${VEGA_USER}@${VEGA_HOST}"
    NANO_SSH="${NANO_USER}@${NANO_HOST}"
    BASE_SENSOR_CMD="ssh -t $VEGA_SSH \"source ~/miniconda3/etc/profile.d/conda.sh && conda activate dexcontrol && dexsensor launch --sensor base_camera --sensor lidar_3d_front --sensor lidar_3d_back\""
    # Head camera is on the Nano, reached via the Jetson; --robot forces the right
    # namespace or the follower (subscribing under $ROBOT_NAME) never sees it.
    HEAD_SENSOR_CMD="ssh -t $VEGA_SSH \"sshpass -p '$NANO_PWD' ssh -t $NANO_SSH_OPTS $NANO_SSH 'dexsensor launch --robot $ROBOT_NAME --sensor head_camera'\""

    echo "-> Launching sensors on the Jetson and Nano..."
    gnome-terminal --window --title="base_sensors" -- bash -c "$BASE_SENSOR_CMD; exec bash"
    gnome-terminal --window --title="head_camera" -- bash -c "$HEAD_SENSOR_CMD; exec bash"
    read -rp "-> Check sensors are running, then press Enter to continue..."
fi

# --- Clean up any stale rollout, then build the command -----------------------
stop_rollout

# >>> HANDS DISABLED (2026-09-22): F5D6 hands undetected, dropped from the follower's
# controllable-component map. The policy was trained without hand columns, so keep the
# hands off here too. See HANDS_DISABLED.md. (No --teleop.* flags: a rollout has no
# teleoperator -- the policy produces the actions.)
ROLLOUT_CMD="lerobot-rollout \
  --policy.path=$POLICY_PATH \
  --robot.type=vega_1p_follower \
  --robot.id=vega_1p \
  --robot.use_external_commands=false \
  --robot.with_left_hand=false \
  --robot.with_right_hand=false \
  --robot.max_relative_target=$MAX_RELATIVE_TARGET \
  --robot.with_head_camera_depth=$WITH_HEAD_DEPTH \
  --device=$DEVICE \
  --fps=$FPS \
  --duration=$DURATION \
  --task=\"$ROLLOUT_TASK\" \
  --return_to_initial_position=$RETURN_TO_INITIAL \
  --display_data=$DISPLAY_DATA"

cat <<EOF
-> READY TO DEPLOY POLICY
     policy      : $POLICY_PATH
     task        : "$ROLLOUT_TASK"
     device      : $DEVICE     fps: $FPS     duration: $DURATION (0 = until stopped)
     step clamp  : max_relative_target=$MAX_RELATIVE_TARGET
     head depth  : $WITH_HEAD_DEPTH  (must match the policy's training features)

   *** SAFETY CHECK before you continue ***
     - e-stop joycon in hand and READY
     - workspace clear of people
     - robot in a pose close to your episodes' start pose
     - keep the step clamp small for the first runs
EOF
read -rp "-> Press Enter to START the autonomous rollout (Ctrl-C in its window to stop)..."

gnome-terminal --window --title="lerobot-rollout" -- bash -c "$LEROBOT_SETUP && $ROLLOUT_CMD; exec bash"

echo "-> Launched. Stop with: $0 stop"
echo "   The follower is now the sole hardware writer -- do NOT start omniteleop while this runs."
