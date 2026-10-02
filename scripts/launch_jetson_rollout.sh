#!/usr/bin/env bash
#
# launch_jetson_rollout.sh
#
# Run an autonomous policy ROLLOUT for the Vega-1 Pro DIRECTLY ON its onboard Thor
# Jetson (dexmate@146.137.240.51). This is the counterpart to launch_exo_rollout.sh
# (which runs from mj / a laptop over an SSH tunnel). Running on the Jetson means:
#
#   * Observations are LOCAL -- head camera comes from the Nano over the robot's
#     internal network, joint state/IMU are on-box. No external tunnel, so the obs
#     acquisition that throttled the tunnelled rollout to ~0.3 Hz is gone.
#   * Inference runs on the Thor GPU (DEVICE defaults to cuda).
#
# Differs from launch_exo_rollout.sh:
#   * Activates the `rollout` CONDA env (not a venv).
#   * Sources jetson_connect.sh (NO SSH tunnel; ROBOT_IP=127.0.0.1 is the local router).
#   * Headless: the rollout runs in the FOREGROUND of this terminal. Ctrl-C stops it
#     (and triggers return-to-initial if RETURN_TO_INITIAL=true). No gnome-terminal.
#   * This policy (acleary/act_box_pickup) consumes only head_camera RGB + state + IMU,
#     so the ONLY sensor needed is the Nano head camera. No base_camera / lidar.
#
# >>> SAFETY: this drives a full-size humanoid autonomously. Keep the e-stop in hand,
#     clear the workspace, start near the episodes' initial pose, keep the step clamp
#     (MAX_RELATIVE_TARGET) small until you trust the policy. Only ONE writer may drive
#     the joints: make sure omniteleop / lerobot-record is STOPPED on mj
#     (mj:  ./scripts/launch_exo_lerobot.sh stop) before you start this.
#
#   ./launch_jetson_rollout.sh          # run the policy rollout (foreground)
#   ./launch_jetson_rollout.sh stop     # kill a background/other rollout process
#
# Optional env vars (or set in ../.env):
#   POLICY_PATH          HF repo id or local checkpoint dir   (default acleary/act_box_pickup)
#   ROLLOUT_TASK         task string handed to the policy      (default "pick up the box")
#   FPS                  control rate                          (default 20)
#   DURATION             seconds to run, 0 = until Ctrl-C      (default 0)
#   DEVICE               inference device                      (default cuda)
#   MAX_RELATIVE_TARGET  per-step joint motion clamp (SAFETY)  (default 0.1; keep small)
#   WITH_HEAD_DEPTH      feed head depth to the policy         (default false; MUST match training)
#   RETURN_TO_INITIAL    glide back to startup pose on stop    (default true)
#   DISPLAY_DATA         open a rerun viewer                   (default false; headless -> keep false)
#   ROLLOUT_ENV          conda env to activate                 (default rollout)
#   LAUNCH_HEAD_CAMERA   true to start the Nano head camera    (default false; see note below)

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# --- Load ../.env (does not override already-set vars) -------------------------
ENV_FILE="$MODULE_ROOT/.env"
if [[ -f "$ENV_FILE" ]]; then
    echo "-> Loading environment from $ENV_FILE"
    while IFS='=' read -r key value || [[ -n "$key" ]]; do
        [[ -z "$key" || "$key" == \#* ]] && continue
        [[ -z "${!key+x}" ]] && export "$key=$value"
    done < "$ENV_FILE"
fi

STALE_PATTERN="lerobot-rollout"
# Local writers that would fight the rollout for the joints. (omniteleop normally
# runs on mj, not here -- that is why the warning below also points at mj.)
OMNITELEOP_PATTERN="joycon_reader\.py|arm_reader\.py|command_processor\.py|robot_controller\.py|lerobot-record"

# Nano (head camera host) -- reached directly from the Jetson over the robot net.
NANO_USER="${NANO_USER:-dexmate-nano}"
NANO_HOST="${NANO_HOST:-192.168.50.22}"
NANO_PWD="${NANO_PWD:-hello-dex}"
NANO_SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

stop_rollout() {
    local pids
    pids=$(pgrep -f "$STALE_PATTERN" || true)
    if [[ -z "$pids" ]]; then echo "-> No rollout process running."; return; fi
    echo "-> Stopping rollout: $pids"
    # shellcheck disable=SC2086
    kill -TERM $pids 2>/dev/null || true
    for _ in $(seq 1 10); do pgrep -f "$STALE_PATTERN" >/dev/null || break; sleep 0.5; done
    pids=$(pgrep -f "$STALE_PATTERN" || true)
    if [[ -n "$pids" ]]; then
        echo "-> Force-killing leftovers: $pids"
        # shellcheck disable=SC2086
        kill -KILL $pids 2>/dev/null || true
    fi
}

if [[ "${1:-}" == "stop" ]]; then
    stop_rollout
    exit 0
fi

# --- Configuration ------------------------------------------------------------
ROLLOUT_ENV="${ROLLOUT_ENV:-rollout}"
POLICY_PATH="${POLICY_PATH:-acleary/act_box_pickup}"
ROLLOUT_TASK="${ROLLOUT_TASK:-pick up the box}"
FPS="${FPS:-20}"
DURATION="${DURATION:-0}"
DEVICE="${DEVICE:-cuda}"
MAX_RELATIVE_TARGET="${MAX_RELATIVE_TARGET:-0.1}"
WITH_HEAD_DEPTH="${WITH_HEAD_DEPTH:-false}"
RETURN_TO_INITIAL="${RETURN_TO_INITIAL:-true}"
DISPLAY_DATA="${DISPLAY_DATA:-false}"
LAUNCH_HEAD_CAMERA="${LAUNCH_HEAD_CAMERA:-false}"

JETSON_CONNECT="$SCRIPT_DIR/jetson_connect.sh"
CONDA_SH="$HOME/miniconda3/etc/profile.d/conda.sh"

# --- Activate conda env -------------------------------------------------------
if [[ ! -f "$CONDA_SH" ]]; then
    echo "-> ERROR: conda not found at $CONDA_SH" >&2; exit 1
fi
# shellcheck disable=SC1090
source "$CONDA_SH"
if ! conda activate "$ROLLOUT_ENV" 2>/dev/null; then
    echo "-> ERROR: conda env '$ROLLOUT_ENV' not found. Create it per the setup notes." >&2; exit 1
fi

# --- Preflight: imports, rollout entrypoint, GPU, dual-writer guard ------------
if ! python -c "import lerobot, dexcontrol, dexcomm" 2>/dev/null; then
    echo "-> ERROR: env '$ROLLOUT_ENV' must have lerobot, dexcontrol, dexcomm importable." >&2; exit 1
fi
if ! python -c "from lerobot.scripts.lerobot_rollout import main" 2>/dev/null; then
    echo "-> ERROR: this lerobot has no lerobot-rollout (src not installed / wrong copy)." >&2; exit 1
fi
if [[ "$DEVICE" == "cuda" ]]; then
    if ! python -c "import torch,sys; sys.exit(0 if torch.cuda.is_available() else 1)" 2>/dev/null; then
        echo "-> ERROR: DEVICE=cuda but torch.cuda.is_available() is False in '$ROLLOUT_ENV'." >&2; exit 1
    fi
fi
if pgrep -f "$OMNITELEOP_PATTERN" >/dev/null; then
    echo "-> ERROR: a local writer (omniteleop / lerobot-record) is running on the Jetson." >&2
    echo "   A rollout would be a SECOND writer to the robot. Stop it first." >&2
    exit 1
fi

# --- Jetson-local robot env (NO tunnel) ---------------------------------------
# shellcheck disable=SC1090
source "$JETSON_CONNECT"

# --- Head camera (Nano) -------------------------------------------------------
# The policy needs head_camera RGB + IMU, published by the Nano. Joint state is
# on-box via dexcontrol (no sensor process needed). base_camera / lidar are NOT
# used by this policy, so we do not launch them.
if [[ "$LAUNCH_HEAD_CAMERA" == "true" ]]; then
    echo "-> Starting head camera on the Nano ($NANO_USER@$NANO_HOST) in the background..."
    if ! command -v sshpass >/dev/null 2>&1; then
        echo "   WARNING: sshpass not installed on the Jetson; cannot auto-launch the Nano camera." >&2
        echo "   Start it by hand in another terminal (see the note below), or install sshpass." >&2
    else
        # shellcheck disable=SC2086
        nohup sshpass -p "$NANO_PWD" ssh $NANO_SSH_OPTS "$NANO_USER@$NANO_HOST" \
            "dexsensor launch --robot $ROBOT_NAME --sensor head_camera" \
            >/tmp/head_camera.log 2>&1 &
        echo "   head camera launching (log: /tmp/head_camera.log). Give it a few seconds."
        sleep 5
    fi
else
    cat <<NOTE
-> LAUNCH_HEAD_CAMERA=false: assuming the Nano head camera is ALREADY publishing.
   If the rollout stalls waiting for observations, start it (separate terminal):
     sshpass -p '$NANO_PWD' ssh $NANO_SSH_OPTS $NANO_USER@$NANO_HOST \\
       'dexsensor launch --robot $ROBOT_NAME --sensor head_camera'
   (or re-run this script with LAUNCH_HEAD_CAMERA=true)
NOTE
fi

stop_rollout

# >>> HANDS DISABLED: F5D6 undetected; policy trained without hand columns. No
# --teleop.* flags: a rollout has no teleoperator -- the policy produces actions.
ROLLOUT_CMD=(lerobot-rollout
  --policy.path="$POLICY_PATH"
  --robot.type=vega_1p_follower
  --robot.id=vega_1p
  --robot.use_external_commands=false
  --robot.with_left_hand=false
  --robot.with_right_hand=false
  --robot.max_relative_target="$MAX_RELATIVE_TARGET"
  --robot.with_head_camera_depth="$WITH_HEAD_DEPTH"
  --device="$DEVICE"
  --fps="$FPS"
  --duration="$DURATION"
  --task="$ROLLOUT_TASK"
  --return_to_initial_position="$RETURN_TO_INITIAL"
  --display_data="$DISPLAY_DATA")

cat <<EOF
-> READY TO DEPLOY POLICY (on the Jetson, GPU)
     policy      : $POLICY_PATH
     task        : "$ROLLOUT_TASK"
     device      : $DEVICE     fps: $FPS     duration: $DURATION (0 = until Ctrl-C)
     step clamp  : max_relative_target=$MAX_RELATIVE_TARGET
     head depth  : $WITH_HEAD_DEPTH  (must match the policy's training features)

   *** SAFETY CHECK ***
     - e-stop in hand and READY
     - workspace clear of people
     - robot near the pose your episodes began in
     - omniteleop / lerobot-record STOPPED on mj (mj: ./scripts/launch_exo_lerobot.sh stop)
     - step clamp small for the first runs
EOF
read -rp "-> Press Enter to START the autonomous rollout (Ctrl-C to stop)..."

echo "-> Running rollout in the foreground. Ctrl-C to stop."
exec "${ROLLOUT_CMD[@]}"
