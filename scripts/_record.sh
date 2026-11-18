#!/usr/bin/env bash
# _record.sh -- shared lerobot-record helpers for launch_teleop.sh record / record-only.
# Source, do not execute. Requires SCRIPT_DIR + MODULE_ROOT set, _env.sh + _teleop.sh already
# sourced (reuses VEGA_SSH / SSH_OPTS / CONDA_SH_REMOTE and the stop/sensor helpers), and
# record.env + any dataset env already loaded. One record code path for both targets. See
# .docs/RECORD.md.

# --- Record configuration (env / record.env / dataset env win; these are last resort) -------
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
LEROBOT_VENV_PATH="$(_expand_home "${LEROBOT_VENV_PATH:-${VENV_PATH:-$HOME/venvs/dexmate}}")"

# How episodes advance: fixed (auto-advance on timers) / interactive (TTY n/r/q) / joycon
# (exo JoyCon over zenoh, headless). Maps to lerobot's EPISODE_CONTROL + the ssh/TTY path.
RECORD_MODE="${RECORD_MODE:-joycon}"
EPISODE_BTN_NEXT="${EPISODE_BTN_NEXT:-left_right}"
EPISODE_BTN_RERECORD="${EPISODE_BTN_RERECORD:-left_left}"
EPISODE_BTN_STOP="${EPISODE_BTN_STOP:-right_left}"

# Jetson-side dataset cache (where local-target lerobot-record writes). Used by the auto-suffix
# disk scan and the rsync hint.
JETSON_DATASET_CACHE="${JETSON_DATASET_CACHE:-~/.cache/huggingface/lerobot}"
MJ_DATASET_CACHE="${MJ_DATASET_CACHE:-$HOME/.cache/huggingface/lerobot}"

RECORD_STALE_PATTERN="lerobot-record"

case "$RECORD_MODE" in fixed|interactive|joycon) ;; *)
    echo "-> ERROR: RECORD_MODE='$RECORD_MODE' (expected fixed|interactive|joycon)." >&2; exit 1 ;;
esac
if [[ "$RESUME" == "true" && "$CHUNK_EPISODES" == "true" ]]; then
    echo "-> ERROR: RESUME=true and CHUNK_EPISODES=true are mutually exclusive." >&2
    echo "   Resuming appends to ONE existing dataset; chunking creates a fresh _sNN series." >&2
    echo "   Set one of them false (record.env or the dataset env)." >&2
    exit 1
fi

# EPISODE_CONTROL for lerobot: joycon stays joycon; fixed/interactive both use lerobot's
# keyboard listener (fixed just auto-advances on the timer, keys still work).
_episode_control() { [[ "$RECORD_MODE" == "joycon" ]] && echo "joycon" || echo "tty"; }

# Record sensor set (base cams + lidars, robot-prefixed). Record always needs the base cameras,
# even on remote whose teleop default is the singular base_camera.
record_sensor_args() {
    echo "--robot $ROBOT_NAME --sensor base_back_camera --sensor base_front_camera --sensor lidar_3d_front --sensor lidar_3d_back"
}

# Echo one lerobot-record invocation. $1=repo_id $2=num_episodes $3=resume. The EPISODE_*
# assignments are prepended because gnome-terminal / the ssh shell don't inherit our env.
_build_record_cmd() {
    local repo_id="$1" nepi="$2" resume="$3"
    cat <<CMD
EPISODE_CONTROL=$(_episode_control) \
  EPISODE_BTN_NEXT=$EPISODE_BTN_NEXT \
  EPISODE_BTN_RERECORD=$EPISODE_BTN_RERECORD \
  EPISODE_BTN_STOP=$EPISODE_BTN_STOP \
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
  --resume=$resume \
  --dataset.push_to_hub=$PUSH_TO_HUB \
  --dataset.streaming_encoding=$STREAMING_ENCODING \
  --dataset.encoder_threads=$ENCODER_THREADS \
  --dataset.num_image_writer_processes=$NUM_IMAGE_WRITER_PROCS \
  --dataset.rgb_encoder.vcodec=$RGB_VCODEC
CMD
}

# List "<base>_<label>NN" dirs in the target's dataset cache, echo the next free index
# (%02d, default 01). $1=target. Makes _sNN numbering continue across sessions, not restart.
_next_session_index() {
    local target="$1" prefix listing max=0 nn
    prefix="$(basename "$DATASET_REPO_ID")_${SESSION_LABEL}"
    if [[ "$target" == "local" ]]; then
        local cache="${JETSON_DATASET_CACHE/#\~/.}"  # ls runs in the Jetson $HOME
        listing="$(ssh $SSH_OPTS "$VEGA_SSH" "ls -1 $cache/$(dirname "$DATASET_REPO_ID") 2>/dev/null" || true)"
    else
        listing="$(ls -1 "$MJ_DATASET_CACHE/$(dirname "$DATASET_REPO_ID")" 2>/dev/null || true)"
    fi
    while IFS= read -r name; do
        [[ "$name" =~ ^${prefix}([0-9]+)$ ]] || continue
        nn=$((10#${BASH_REMATCH[1]}))
        (( nn > max )) && max=$nn
    done <<< "$listing"
    printf '%02d' $(( max + 1 ))
}

# Resolve (repo_id, episode-count) list for this session into CHUNK_REPOS[] / CHUNK_SIZES[],
# honoring chunking and disk-scan auto-iteration. $1=target.
_plan_chunks() {
    local target="$1"
    CHUNK_REPOS=(); CHUNK_SIZES=()
    if [[ "$CHUNK_EPISODES" != "true" ]]; then
        CHUNK_REPOS=("$DATASET_REPO_ID"); CHUNK_SIZES=("$NUM_EPISODES"); return
    fi
    local remaining="$NUM_EPISODES" idx
    idx=$(( 10#$(_next_session_index "$target") ))
    while (( remaining > 0 )); do
        local n=$(( remaining < EPISODES_PER_CHUNK ? remaining : EPISODES_PER_CHUNK ))
        CHUNK_REPOS+=("$(printf '%s_%s%02d' "$DATASET_REPO_ID" "$SESSION_LABEL" "$idx")")
        CHUNK_SIZES+=("$n")
        remaining=$(( remaining - n )); idx=$(( idx + 1 ))
    done
}

# Verify the target can RECORD. $1=target. remote: mj venv imports; local: over-ssh schema/dep
# check (the exact gaps a stock Jetson has). Exits non-zero on failure.
record_preflight() {
    local target="$1"
    if [[ "$target" == "remote" ]]; then
        "$LEROBOT_VENV_PATH/bin/python" - <<'PY' 2>/dev/null || {
import lerobot, dexcontrol, dexcomm  # noqa
from lerobot.teleoperators.vega_exo_joycon.vega_exo_joycon import VegaExoJoycon  # noqa
PY
            echo "-> ERROR: mj venv $LEROBOT_VENV_PATH cannot import lerobot/dexcontrol/dexcomm/VegaExoJoycon." >&2
            echo "   See .docs/RECORD.md." >&2; exit 1; }
        echo "   mj venv ready to record."
        return
    fi
    echo "-> Preflight: checking the Jetson ($VEGA_SSH) can record..."
    ssh $SSH_OPTS "$VEGA_SSH" true 2>/dev/null || {
        echo "-> ERROR: cannot ssh to $VEGA_SSH. Robot on? key authorized?" >&2; exit 1; }
    local remote_check
    remote_check="source $CONDA_SH_REMOTE && conda activate $JETSON_ENV && test -e $EXO_DEV_PORT && python - <<'PY'
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
        echo "   Sync the repos to match mj -- see .docs/RECORD.md / .docs/JETSON_RECORDING.md." >&2
        exit 1
    fi
    "$VENV_PATH/bin/python" -c "import omniteleop" 2>/dev/null || {
        echo "-> ERROR: mj venv $VENV_PATH has no omniteleop (needed for joycon_reader)." >&2; exit 1; }
    echo "   Jetson ready to record; exo at $EXO_DEV_PORT; mj joycon OK."
}

# Guard the record-only path (attach a recorder to an already-running stack). $1=target.
record_only_guard() {
    local target="$1" running
    if [[ "$target" == "local" ]]; then
        running="$(ssh $SSH_OPTS "$VEGA_SSH" "pgrep -f '$RECORD_STALE_PATTERN'" 2>/dev/null || true)"
    else
        running="$(pgrep -f "$RECORD_STALE_PATTERN" || true)"
    fi
    [[ -n "$running" ]] && {
        echo "-> ERROR: a lerobot-record is already running. Stop it first." >&2; exit 1; }
    if [[ "$target" == "local" ]]; then
        ssh $SSH_OPTS "$VEGA_SSH" "pgrep -f 'command_processor\.py|robot_controller\.py' >/dev/null" 2>/dev/null || \
            echo "-> WARNING: no command_processor/robot_controller detected on the Jetson. Is the stack up?" >&2
    else
        pgrep -f 'command_processor\.py|robot_controller\.py' >/dev/null || \
            echo "-> WARNING: no command_processor/robot_controller detected on mj. Is the stack up?" >&2
    fi
}

# Loop over chunks and run each lerobot-record. $1=target, $2=mode.
#   remote: local gnome-terminal (interactive/joycon) or foreground (fixed), mj venv + connect remote.
#   local : ssh -t (interactive) or plain ssh (fixed/joycon), conda $JETSON_ENV + connect local.
run_record_session() {
    local target="$1" mode="$2"
    _plan_chunks "$target"
    echo "-> Session plan: ${#CHUNK_REPOS[@]} chunk(s), $NUM_EPISODES episode(s) total" \
         "($EPISODE_TIME_S s/ep, reset $RESET_TIME_S s, fps $FPS, mode $mode)."
    [[ "$CHUNK_EPISODES" == "true" ]] && \
        echo "   Failsafe ON: each chunk finalizes independently (<= EPISODES_PER_CHUNK=$EPISODES_PER_CHUNK)."

    local setup
    if [[ "$target" == "local" ]]; then
        setup="source $CONDA_SH_REMOTE && conda activate $JETSON_ENV && source $CONNECT_SCRIPT_REMOTE local"
    else
        setup="source \"$LEROBOT_VENV_PATH/bin/activate\" && source \"$CONNECT_SCRIPT\" remote"
    fi

    local i
    for i in "${!CHUNK_REPOS[@]}"; do
        local repo="${CHUNK_REPOS[$i]}" nepi="${CHUNK_SIZES[$i]}"
        local rcmd; rcmd="$(_build_record_cmd "$repo" "$nepi" "$RESUME")"
        echo
        echo "=== Chunk $((i+1))/${#CHUNK_REPOS[@]}: $repo  ($nepi episode(s)) ==="

        local rc=0
        if [[ "$target" == "remote" ]]; then
            if [[ "$mode" == "fixed" ]]; then
                echo "-> Fixed-time: recording on mj (foreground). Ctrl-C stops it."
                bash -c "$setup && $rcmd" || rc=$?
            else
                [[ "$mode" == "interactive" ]] && echo "-> Interactive: focus the record window. Keys: n/r/q."
                gnome-terminal --window --title="lerobot-record ($repo)" -- \
                    bash -c "$setup && $rcmd; exec bash"
                read -rp "-> Recording in the record window. Press Enter here once this chunk finished..."
            fi
        else
            if [[ "$mode" == "interactive" ]]; then
                echo "-> Interactive: focus this terminal. Keys: n=next  r=re-record  q=quit/stop."
                ssh -t $SSH_OPTS "$VEGA_SSH" "$setup && $rcmd" || rc=$?
            else
                echo "-> ${mode^}: recording headless on the Jetson (output streams here). Ctrl-C stops it."
                ssh $SSH_OPTS "$VEGA_SSH" "$setup && $rcmd" || rc=$?
            fi
        fi

        if (( rc != 0 )); then
            echo "-> WARNING: chunk $((i+1)) ($repo) exited non-zero (rc=$rc)." >&2
            echo "   Earlier finalized chunks are safe. Investigate before continuing; re-run with" >&2
            echo "   '$target record-only' to retry remaining chunks against the live stack." >&2
            return "$rc"
        fi
        echo "-> Chunk $((i+1)) finished (finalized)."
    done
}

# Pull hint: only local writes on the Jetson; remote writes straight to the mj cache.
print_rsync_hint() {
    [[ "$1" == "local" ]] || return 0
    cat <<EOF

-> Datasets were written on the JETSON under $JETSON_DATASET_CACHE/<repo_id>.
   Pull them back to mj (for aggregate_sessions.py) with rsync, e.g.:

     rsync -avP $VEGA_SSH:$JETSON_DATASET_CACHE/${DATASET_REPO_ID}_${SESSION_LABEL}'*' \\
           ~/.cache/huggingface/lerobot/

   (or pull a single chunk by naming it exactly, e.g. ${DATASET_REPO_ID}_${SESSION_LABEL}01)
   Then on mj:  python scripts/tools/aggregate_sessions.py  (discovers the _${SESSION_LABEL}NN series).
EOF
}
