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

- Datasets land in `~/.cache/huggingface/lerobot/<repo_id>_<timestamp>` — the repo_id is
  timestamped per run (`stamp_repo_id()`), so each run is a NEW dataset. Appending needs a
  manual `lerobot-record --resume=true` against the full stamped repo_id (not wired here).
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
  un-starve the loop (`STREAMING_ENCODING`, `NUM_IMAGE_WRITER_PROCS`; drop depth if still
  slow). A ~10 Hz `Record loop is running slower` warning is the starvation tell.

## Key Classes

- `VegaInterface` — Real hardware interface (`src/vega_interface.py`)
- `VegaFakeInterface` — Simulated interface for testing (`src/vega_fake_interface.py`)
- `VegaNodeConfig` — Node configuration (`src/vega_types.py`)

## Resources

- [MADSci Documentation](https://ad-sdl.github.io/MADSci/)
