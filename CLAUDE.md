# Vega Module

Dexmate Vega 1 Pro module

## Project Structure

```
├── src/
│   ├── vega_rest_node.py       # MADSci REST node server
│   ├── vega_interface.py       # Real hardware interface
│   ├── vega_fake_interface.py  # Fake interface for testing
│   ├── vega_types.py           # Type definitions and config
│   └── drivers/                             # Instrument drivers
│       └── private/                         # Proprietary drivers (gitignored)
├── tests/
│   └── test_vega_interface.py
├── notebooks/
│   ├── interface_testing.ipynb              # Direct interface testing
│   └── node_testing.ipynb                   # REST node testing
├── docs/
│   ├── README.md                            # Module documentation
│   └── private/                             # Private docs (gitignored)
├── pyproject.toml
├── Dockerfile
├── docker-compose.yaml
└── README.md
```

## Development Commands

```bash
# Run the node (real hardware)
python src/vega_rest_node.py

# Run on a different port (shorthand for --node_url)
python src/vega_rest_node.py --port 2005

# See all options, including MADSci node settings
python src/vega_rest_node.py --help

# Run tests (no hardware needed - the interface is stubbed)
PYTHONPATH=src:. pytest tests/

# Lint and format
ruff check . --fix
ruff format .
```

## Bring-up Checks (real hardware)

Pre-flight gates for `scripts/launch_exo_lerobot.sh`. Each exits non-zero on failure, and
each needs the lab environment sourced first: `source scripts/lab_connect.sh`.

```bash
# Contract only - no robot, no connection. Needs the teleop stack publishing.
python scripts/check_exo_lerobot_contract.py

# Observations, action keys and dataset schema. Moves nothing, writes nothing.
python scripts/check_lerobot_recording.py

# Moves one joint a small amount. --dry-run prints the trajectory and exits.
python scripts/check_lerobot_motion.py --via lerobot      # omniteleop must be stopped
python scripts/check_lerobot_motion.py --via omniteleop   # robot_controller up, command_processor down

# The passive loop lerobot-record runs, minus the dataset. Full stack up, exo in hand.
python scripts/check_lerobot_teleop.py
```

## Recording (`scripts/launch_exo_lerobot.sh`)

- Datasets land in `~/.cache/huggingface/lerobot/<repo_id>` — the launch script pins
  `--dataset.no_stamp=true` (`NO_STAMP` env var), so the folder is EXACTLY `DATASET_REPO_ID`
  with no `_<timestamp>` suffix. This is required for the per-session naming scheme that
  `scripts/aggregate_sessions.py` discovers (`local/<base>_s01`, `_s02`, ...). Trade-off:
  give a UNIQUE `DATASET_REPO_ID` per session — reusing one errors (`LeRobotDataset.create`
  refuses an existing dir). To append instead, run `lerobot-record --resume=true` against
  that repo_id by hand (not wired into the launch script). Set `NO_STAMP=false` to restore
  lerobot's default auto-timestamping (`stamp_repo_id()` at dataset creation).
- Episode control is keyboard-driven in the `lerobot-record` window: `→` end early,
  `←` re-record last, `Esc` stop. Auto-advances after `EPISODE_TIME_S` then a
  `RESET_TIME_S` pause. This replaces the old JoyCon-button MCAP flow.
- Shutdown order: `Esc` the recorder and let it finish saving BEFORE stopping the
  omniteleop stack (its `Robot.shutdown()` stops hardware `robot_controller` still drives).
- **Recorder crashes with `DeviceNotConnectedError: VegaExoJoycon is not connected`
  mid-episode**: `VegaExoJoycon.is_connected` is a freshness check on `robot/safe_commands`;
  under CPU starvation a gap > `max_command_age_s` (0.5s lib default) flips it false and
  `get_action()` raises, killing the whole session while omniteleop keeps running. Fix is
  two levers, both now defaulted in the launch script: raise `MAX_COMMAND_AGE_S` (2.0), and
  un-starve the loop (`STREAMING_ENCODING=false` + `NUM_IMAGE_WRITER_PROCS=4`; drop depth if
  still slow). A ~10 Hz `Record loop is running slower` warning is the starvation tell.
- **Encoder crash `avcodec_open2(h264_nvenc): Operation not permitted`**: `RGB_VCODEC=auto`
  picks the NVENC hardware encoder, which has no usable session on this box. Default is
  pinned to `h264` (software H.264 via libx264). Only switch RGB back to `h264_nvenc` once GPU
  encode works here. NOTE: lerobot's valid `vcodec` names are `h264`/`hevc`/`libsvtav1`/
  `libaom-av1`/`auto`/`<hw>` — passing `libx264` raises `ValueError`; use `h264`.
- **Record loop sawtooth (2-16 Hz) with `add_frame` high**: `dataset.add_frame` blocks the
  (single-threaded, synchronous) record loop. TWO distinct causes, in the order we hit them:
  1. **`STREAMING_ENCODING=true`** (the real one): the encoder runs INSIDE the loop process in
     per-camera threads, and each frame does PIL->YUV + full-frame stats holding the GIL, so
     the threads + loop contend for one GIL and `add_frame` blocks ~100ms/camera on a full
     queue. **Changing the codec does NOT fix this** (only the C `encode()` releases the GIL).
     Fix = `STREAMING_ENCODING=false` (now the default) + `NUM_IMAGE_WRITER_PROCS=4`: frames go
     to AsyncImageWriter subprocesses and each episode is batch-encoded in parallel at its end
     (during the reset pause), auto-cleaning its temp PNGs. `NUM_IMAGE_WRITER_PROCS` only
     matters when streaming is off.
  2. **`RGB_VCODEC=libsvtav1`** (software AV1, an OFFLINE codec): too slow for live capture even
     without cause 1. Default is now `h264`; do NOT use `libsvtav1`. (Valid vcodec names:
     `h264`/`hevc`/`libsvtav1`/`libaom-av1`/`auto`/`<hw>`; `libx264` raises ValueError.)

  To tell them apart, `lerobot_record.py`'s slow-loop warning prints `obs=/act=/add_frame=` ms:
  `obs` high = camera/zenoh acquisition; `add_frame` high = encoder backpressure (the above).
  Depth (`WITH_HEAD_DEPTH`) is a separate, additive encode load, not the primary cause.
- **Episode 1+ shows `Record loop is running slower (2-3 Hz)` on the FIRST frame only,
  with `obs~=400ms act=0ms add_frame~=1ms`**: this is NOT the encoder (add_frame is
  ~1ms). dexcontrol idle-pauses every subscriber after 5s of no reads; the minutes-long
  reset/encode pause between episodes trips that, so episode N>0's first frame resumes
  all ~7 subscribers at once (each blocks up to 3s polling for a fresh frame). It
  self-recovers to ~20 Hz within a frame or two -- do NOT press `→` on this one warning
  or you skip a would-be-fine episode. Now suppressed at the source: `Vega1PFollower.connect()`
  pins `set_subscription_policy("always_on")` (uncommitted lerobot edit; reverts on
  reinstall) so subscribers stay warm across resets. Distinct from the sustained
  `add_frame`-high slowdown above.
- **Nothing to run after recording**: with streaming off, encoding is per-episode and
  automatic (`save_episode` batch-encodes + deletes temp PNG dirs). Just let the recorder
  finish each episode's encode pause before stopping the stack; killing mid-encode loses only
  that in-progress episode.

## Key Classes

- `VegaInterface` — Real hardware interface (`src/vega_interface.py`)
- `VegaFakeInterface` — Simulated interface for testing (`src/vega_fake_interface.py`)
- `VegaNodeConfig` — Node configuration (`src/vega_types.py`)

## Resources

- [MADSci Documentation](https://ad-sdl.github.io/MADSci/)
