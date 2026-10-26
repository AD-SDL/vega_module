#!/usr/bin/env bash
#
# _jetson_record_common.sh -- shared library sourced by launch_jetson_lerobot_fixed.sh
# and launch_jetson_lerobot_interactive.sh. Brings up the split stack (joycon on mj;
# arm/cmd/robot + sensors on the Jetson) and drives lerobot-record on the Jetson with
# optional chunking. The variants differ only in the run_record_session arg (fixed vs
# interactive). See .docs/JETSON_RECORDING.md.
#
# Requires: SCRIPT_DIR and MODULE_ROOT set by the caller before sourcing.

NANO_SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
SSH_OPTS="-o ConnectTimeout=10"

# --- Load ../.env then jetson_record.env (neither overrides already-set vars) ---
_load_env_file() {
    local f="$1"
    [[ -f "$f" ]] || return 0
    echo "-> Loading $f"
    # jetson_record.env uses inline comments (KEY="value"  # why), so strip the comment
    # + surrounding quotes, or the whole comment would ride into the ssh command line.
    while IFS='=' read -r key value || [[ -n "$key" ]]; do
        key="${key%"${key##*[![:space:]]}"}"   # rtrim key (allow "KEY =" style)
        [[ -z "$key" || "$key" == \#* ]] && continue
        if [[ "$value" == \"* ]]; then
            value="${value#\"}"; value="${value%%\"*}"   # quoted: take inside the first "..."
        else
            value="${value%%#*}"                          # unquoted: drop trailing # comment
            value="${value#"${value%%[![:space:]]*}"}"    # ltrim
            value="${value%"${value##*[![:space:]]}"}"    # rtrim
        fi
        [[ -z "${!key+x}" ]] && export "$key=$value"
    done < "$f"
}
_load_env_file "$MODULE_ROOT/.env"
_load_env_file "$SCRIPT_DIR/jetson_record.env"

# --- Configuration (env/.env/jetson_record.env win; these are last-resort defaults) --
VENV_PATH="${VENV_PATH:-$HOME/venvs/dexmate}"
JETSON_ENV="${JETSON_ENV:-rollout}"
EXO_DEV_PORT="${EXO_DEV_PORT:-/dev/ttyUSB0}"
LAUNCH_SENSORS="${LAUNCH_SENSORS:-true}"

DATASET_REPO_ID="${DATASET_REPO_ID:-local/vega_exo_base}"
DATASET_TASK="${DATASET_TASK:-teleoperation}"
SESSION_LABEL="${SESSION_LABEL:-s}"
NO_STAMP="${NO_STAMP:-true}"
RESUME="${RESUME:-false}"
CHUNK_EPISODES="${CHUNK_EPISODES:-true}"
EPISODES_PER_CHUNK="${EPISODES_PER_CHUNK:-5}"
NUM_EPISODES="${NUM_EPISODES:-10}"
EPISODE_TIME_S="${EPISODE_TIME_S:-60}"
RESET_TIME_S="${RESET_TIME_S:-15}"
FPS="${FPS:-20}"
WITH_CHASSIS="${WITH_CHASSIS:-true}"
WITH_BASE_BACK_CAMERA="${WITH_BASE_BACK_CAMERA:-true}"
WITH_BASE_FRONT_CAMERA="${WITH_BASE_FRONT_CAMERA:-true}"
WITH_HEAD_DEPTH="${WITH_HEAD_DEPTH:-true}"
MAX_COMMAND_AGE_S="${MAX_COMMAND_AGE_S:-2.0}"
STREAMING_ENCODING="${STREAMING_ENCODING:-false}"
ENCODER_THREADS="${ENCODER_THREADS:-2}"
NUM_IMAGE_WRITER_PROCS="${NUM_IMAGE_WRITER_PROCS:-4}"
RGB_VCODEC="${RGB_VCODEC:-h264}"
PUSH_TO_HUB="${PUSH_TO_HUB:-false}"

LAB_CONNECT_SCRIPT="$SCRIPT_DIR/lab_connect.sh"
CONDA_SH_REMOTE="~/miniconda3/etc/profile.d/conda.sh"
JETSON_CONNECT_REMOTE="~/humanoids/vega_module/scripts/jetson_connect.sh"
VEGA_SSH="${VEGA_USER:-dexmate}@${VEGA_HOST:-146.137.240.51}"
ROBOT_NAME="${ROBOT_NAME:-$(sed -n 's/^export ROBOT_NAME="\?\([^"]*\)"\?.*/\1/p' "$LAB_CONNECT_SCRIPT" | head -1)}"

# Jetson-side dataset cache (where lerobot-record writes). Used by the rsync hint.
JETSON_DATASET_CACHE="~/.cache/huggingface/lerobot"

# Validate mutually-exclusive options up front.
if [[ "$RESUME" == "true" && "$CHUNK_EPISODES" == "true" ]]; then
    echo "-> ERROR: RESUME=true and CHUNK_EPISODES=true are mutually exclusive." >&2
    echo "   Resuming appends to ONE existing dataset; chunking creates a fresh _sNN series." >&2
    echo "   Set one of them false in jetson_record.env." >&2
    exit 1
fi

# --- Process-match patterns ---------------------------------------------------
JETSON_STALE_PATTERN="omni-arm|omni-cmd|omni-robot|omni-telemetry|arm_reader\.py|command_processor\.py|robot_controller\.py|telemetry_viewer\.py"
MJ_STALE_PATTERN="joycon_reader\.py"
RECORD_STALE_PATTERN="lerobot-record"

# --- stop helpers -------------------------------------------------------------
stop_mj() {
    local pids; pids=$(pgrep -f "$MJ_STALE_PATTERN" || true)
    [[ -z "$pids" ]] && { echo "-> No mj joycon process running."; return; }
    echo "-> Stopping mj joycon: $pids"
    # shellcheck disable=SC2086
    kill -TERM $pids 2>/dev/null || true
    for _ in $(seq 1 10); do pgrep -f "$MJ_STALE_PATTERN" >/dev/null || break; sleep 0.5; done
    pids=$(pgrep -f "$MJ_STALE_PATTERN" || true)
    # shellcheck disable=SC2086
    [[ -n "$pids" ]] && kill -KILL $pids 2>/dev/null || true
}

stop_jetson_record() {
    echo "-> Stopping lerobot-record on the Jetson..."
    ssh $SSH_OPTS "$VEGA_SSH" "pkill -TERM -f '$RECORD_STALE_PATTERN'" 2>/dev/null || true
}

stop_jetson_stack() {
    echo "-> Stopping Jetson driving stack over ssh..."
    ssh $SSH_OPTS "$VEGA_SSH" "pkill -TERM -f '$JETSON_STALE_PATTERN'" 2>/dev/null || true
    sleep 2
    ssh $SSH_OPTS "$VEGA_SSH" "pkill -KILL -f '$JETSON_STALE_PATTERN'" 2>/dev/null || true
    pkill -f "$JETSON_STALE_PATTERN" 2>/dev/null || true
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

# Shutdown order matters: stop the RECORDER first (lerobot's finally: finalizes the
# in-progress chunk + disconnects its dexcontrol.Robot), THEN the driving stack, THEN
# the mj joycon last so the e-stop path outlives hardware motion.
stop_all() {
    stop_jetson_record
    sleep 1
    stop_jetson_stack
    stop_mj
    stop_sensors
}

# --- Preflight ----------------------------------------------------------------
# Verifies the Jetson can RECORD: driving-stack deps + exo port + the recording-specific
# deps (vega teleop/follower with chassis+base cams, the dexbot-utils fork's base
# cameras). These are the exact gaps a stock Jetson has -- see .docs/JETSON_RECORDING.md.
jetson_record_preflight() {
    echo "-> Preflight: checking the Jetson ($VEGA_SSH)..."
    ssh $SSH_OPTS "$VEGA_SSH" true 2>/dev/null || {
        echo "-> ERROR: cannot ssh to $VEGA_SSH. Robot on? key authorized?" >&2; exit 1; }

    local remote_check
    remote_check="source $CONDA_SH_REMOTE && conda activate $JETSON_ENV && test -e $EXO_DEV_PORT && python - <<'PY'
import sys
import omniteleop, dexcontrol, dexcomm, dynamixel_sdk, lerobot  # noqa
from lerobot.teleoperators.vega_exo_joycon.config_vega_exo_joycon import VegaExoJoyconConfig
from lerobot.robots.vega_1p_follower.config_vega_1p_follower import Vega1PFollowerConfig
tf = VegaExoJoyconConfig().__dataclass_fields__
ff = Vega1PFollowerConfig().__dataclass_fields__
assert 'with_chassis' in tf, 'teleop lacks with_chassis (lerobot on Jetson is older than mj)'
assert any('base' in k and 'camera' in k for k in ff), 'follower lacks base-camera flags (old lerobot)'
from dexbot_utils.robot_info import RobotInfo
s = RobotInfo.get_default_config('vega_1p').sensors
assert any(k.startswith('base_') for k in s), 'dexbot_utils has no base cameras (install the base-cameras fork)'
PY"
    if ! ssh $SSH_OPTS "$VEGA_SSH" "$remote_check" 2>/tmp/jetson_preflight.err; then
        echo "-> ERROR: the Jetson env '$JETSON_ENV' is not ready to RECORD. Details:" >&2
        sed 's/^/     /' /tmp/jetson_preflight.err >&2 2>/dev/null || true
        echo "   Sync the 4 repos to match mj and install omniteleop -- see" >&2
        echo "   .docs/JETSON_RECORDING.md (Jetson setup)." >&2
        exit 1
    fi
    "$VENV_PATH/bin/python" -c "import omniteleop" 2>/dev/null || {
        echo "-> ERROR: mj venv $VENV_PATH has no omniteleop (needed for joycon_reader)." >&2; exit 1; }
    echo "   Jetson ready to record; exo at $EXO_DEV_PORT; mj joycon OK."
}

# --- Bring up the split stack (same as launch_jetson_teleop.sh) ----------------
bring_up_split_stack() {
    local REMOTE_SETUP="source $CONDA_SH_REMOTE && conda activate $JETSON_ENV && source $JETSON_CONNECT_REMOTE && sudo chmod 666 $EXO_DEV_PORT"
    local MJ_SETUP="source \"$VENV_PATH/bin/activate\" && source \"$LAB_CONNECT_SCRIPT\""

    if [[ "$LAUNCH_SENSORS" == "true" ]]; then
        local NANO_SSH="${NANO_USER}@${NANO_HOST}"
        local BASE_SENSOR_CMD="ssh -t $VEGA_SSH \"source $CONDA_SH_REMOTE && conda activate dexcontrol && dexsensor launch --robot $ROBOT_NAME --sensor base_back_camera --sensor base_front_camera --sensor lidar_3d_front --sensor lidar_3d_back\""
        local HEAD_SENSOR_CMD="ssh -t $VEGA_SSH \"sshpass -p '$NANO_PWD' ssh -t $NANO_SSH_OPTS $NANO_SSH 'dexsensor launch --robot $ROBOT_NAME --sensor head_camera'\""
        echo "-> Launching sensors on the Jetson and Nano..."
        gnome-terminal --window --title="base_sensors" -- bash -c "$BASE_SENSOR_CMD; exec bash"
        gnome-terminal --window --title="head_camera"  -- bash -c "$HEAD_SENSOR_CMD; exec bash"
        read -rp "-> Check sensors are running, then press Enter to continue..."
    fi

    stop_mj
    stop_jetson_stack
    read -rp "-> Get into default position to calibrate exoskeleton, then press Enter to launch..."

    # mj: joycon_reader (publishes exo_joycon over the tunnel)
    gnome-terminal --window --title="joycon_reader (mj)" -- \
        bash -c "$MJ_SETUP && omni-joycon; exec bash"
    # Jetson: driving stack, each an ssh -t window on mj
    gnome-terminal --window --title="arm_reader (jetson)" -- \
        bash -c "ssh -t $SSH_OPTS $VEGA_SSH '$REMOTE_SETUP && omni-arm'; exec bash"
    gnome-terminal --window --title="command_processor (jetson)" -- \
        bash -c "ssh -t $SSH_OPTS $VEGA_SSH '$REMOTE_SETUP && omni-cmd'; exec bash"
    gnome-terminal --window --title="robot_controller (jetson)" -- \
        bash -c "ssh -t $SSH_OPTS $VEGA_SSH '$REMOTE_SETUP && omni-robot --interpolation-method linear'; exec bash"

    echo "-> Split stack up (mj joycon + Jetson arm/cmd/robot). Align the exo + release the"
    echo "   JoyCon e-stop before recording motion begins."
    read -rp "-> Press Enter once the stack is up and the exo is aligned, to start recording..."
}

# --- Build one lerobot-record invocation --------------------------------------
# $1 = repo_id, $2 = num_episodes, $3 = resume(true/false). Echoes the command string
# (runs ON the Jetson; env already activated by the caller's remote setup).
_build_record_cmd() {
    local repo_id="$1" nepi="$2" resume="$3"
    cat <<CMD
lerobot-record \
  --robot.type=vega_1p_follower \
  --robot.id=vega_1p \
  --robot.use_external_commands=true \
  --robot.with_left_hand=false \
  --robot.with_right_hand=false \
  --robot.max_relative_target=null \
  --robot.with_head_camera_depth=$WITH_HEAD_DEPTH \
  --robot.with_chassis=$WITH_CHASSIS \
  --robot.with_base_back_camera=$WITH_BASE_BACK_CAMERA \
  --robot.with_base_front_camera=$WITH_BASE_FRONT_CAMERA \
  --teleop.type=vega_exo_joycon \
  --teleop.id=exo \
  --teleop.with_left_hand=false \
  --teleop.with_right_hand=false \
  --teleop.with_chassis=$WITH_CHASSIS \
  --teleop.max_command_age_s=$MAX_COMMAND_AGE_S \
  --dataset.repo_id=$repo_id \
  --dataset.no_stamp=$NO_STAMP \
  --dataset.single_task="$DATASET_TASK" \
  --dataset.num_episodes=$nepi \
  --dataset.episode_time_s=$EPISODE_TIME_S \
  --dataset.reset_time_s=$RESET_TIME_S \
  --dataset.fps=$FPS \
  --dataset.resume=$resume \
  --dataset.push_to_hub=$PUSH_TO_HUB \
  --dataset.streaming_encoding=$STREAMING_ENCODING \
  --dataset.encoder_threads=$ENCODER_THREADS \
  --dataset.num_image_writer_processes=$NUM_IMAGE_WRITER_PROCS \
  --dataset.rgb_encoder.vcodec=$RGB_VCODEC
CMD
}

# Resolve the (repo_id, episode-count) list for this session, honoring chunking.
# Populates the globals CHUNK_REPOS[] and CHUNK_SIZES[].
_plan_chunks() {
    CHUNK_REPOS=(); CHUNK_SIZES=()
    if [[ "$CHUNK_EPISODES" != "true" ]]; then
        CHUNK_REPOS=("$DATASET_REPO_ID"); CHUNK_SIZES=("$NUM_EPISODES"); return
    fi
    local remaining="$NUM_EPISODES" idx=1
    while (( remaining > 0 )); do
        local n=$(( remaining < EPISODES_PER_CHUNK ? remaining : EPISODES_PER_CHUNK ))
        # Zero-padded index: local/<base>_<SESSION_LABEL>01, _s02, ... (aggregate_sessions scheme)
        CHUNK_REPOS+=("$(printf '%s_%s%02d' "$DATASET_REPO_ID" "$SESSION_LABEL" "$idx")")
        CHUNK_SIZES+=("$n")
        remaining=$(( remaining - n )); idx=$(( idx + 1 ))
    done
}

# --- Run the recording session ------------------------------------------------
# $1 = mode: "fixed" (background + auto-advance, logs tailed) or "interactive"
# (foreground ssh -t TTY with n/r/q). Loops over chunks either way.
run_record_session() {
    local mode="$1"
    _plan_chunks
    echo "-> Session plan: ${#CHUNK_REPOS[@]} chunk(s), $NUM_EPISODES episode(s) total" \
         "($EPISODE_TIME_S s/ep, reset $RESET_TIME_S s, fps $FPS)."
    [[ "$CHUNK_EPISODES" == "true" ]] && echo "   Failsafe ON: each chunk finalizes independently (<= EPISODES_PER_CHUNK=$EPISODES_PER_CHUNK)."

    local REMOTE_RECORD_SETUP="source $CONDA_SH_REMOTE && conda activate $JETSON_ENV && source $JETSON_CONNECT_REMOTE"
    local i
    for i in "${!CHUNK_REPOS[@]}"; do
        local repo="${CHUNK_REPOS[$i]}" nepi="${CHUNK_SIZES[$i]}"
        local rcmd; rcmd="$(_build_record_cmd "$repo" "$nepi" "$RESUME")"
        echo
        echo "=== Chunk $((i+1))/${#CHUNK_REPOS[@]}: $repo  ($nepi episode(s)) ==="

        local rc=0
        if [[ "$mode" == "interactive" ]]; then
            # Foreground ssh -t: the TTY is what makes lerobot's TerminalKeyListener work.
            echo "-> Interactive: focus this terminal. Keys: n=next  r=re-record  q=quit/stop."
            ssh -t $SSH_OPTS "$VEGA_SSH" "$REMOTE_RECORD_SETUP && $rcmd" || rc=$?
        else
            # Fixed-time: foreground plain (non-TTY) ssh. Blocks until finalize() returns;
            # Ctrl-C propagates and lerobot's finally: finalizes what it has.
            echo "-> Fixed-time: recording headless on the Jetson (streaming output here). Ctrl-C stops it."
            ssh $SSH_OPTS "$VEGA_SSH" "$REMOTE_RECORD_SETUP && $rcmd" || rc=$?
        fi

        if (( rc != 0 )); then
            echo "-> WARNING: chunk $((i+1)) ($repo) exited non-zero (rc=$rc)." >&2
            echo "   Earlier finalized chunks are safe on the Jetson. Investigate before continuing;" >&2
            echo "   re-run with 'record' to retry remaining chunks against the live stack." >&2
            return "$rc"
        fi
        echo "-> Chunk $((i+1)) finished (finalized on the Jetson)."
    done
}

print_rsync_hint() {
    local jetson_root remote="${JETSON_DATASET_CACHE/#\~/\$HOME}"
    cat <<EOF

-> Datasets were written on the JETSON under $JETSON_DATASET_CACHE/<repo_id>.
   Pull them back to mj (for aggregate_sessions.py) with rsync, e.g.:

     rsync -avP $VEGA_SSH:$JETSON_DATASET_CACHE/${DATASET_REPO_ID}_${SESSION_LABEL}'*' \\
           ~/.cache/huggingface/lerobot/

   (or pull a single chunk by naming it exactly, e.g. ${DATASET_REPO_ID}_${SESSION_LABEL}01)
   Then on mj:  python scripts/aggregate_sessions.py  (discovers the _${SESSION_LABEL}NN series).
EOF
}
