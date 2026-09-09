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

## Key Classes

- `VegaInterface` — Real hardware interface (`src/vega_interface.py`)
- `VegaFakeInterface` — Simulated interface for testing (`src/vega_fake_interface.py`)
- `VegaNodeConfig` — Node configuration (`src/vega_types.py`)

## Resources

- [MADSci Documentation](https://ad-sdl.github.io/MADSci/)
