# Hands temporarily disabled (2026-09-22)

The F5D6 dexterous hands are **not detected by the robot controller**
(`query_hand_type()` returns `UNKNOWN` for both sides), so dexcontrol disables
the `left_hand` / `right_hand` components. This broke teleop and recording:

- **omniteleop** (`robot_controller.py`) set `hand_type="f5d6"` from `ROBOT_CONFIG`
  and called `robot.left_hand.open_hand()`, raising `ComponentNotAvailableError`.
- **lerobot** (`vega_1p_follower`) declared the hands as controllable components,
  so `connect()` raised `ConnectionError` because the robot did not report them.

To keep **arms / torso / head / chassis** teleoperation and recording working,
the hands were disabled in two places. This is a temporary workaround — see
"How to re-enable" below.

## Changes made (revert these when the hands work again)

0. **`~/.bashrc`** (line ~149) — THE REAL SOURCE OF TRUTH
   - Changed `export ROBOT_CONFIG=vega_1p_f5d6` to `vega_1p`.
   - This env var is pinned in the shell profile, so it wins over
     `lab_connect.sh`'s `${ROBOT_CONFIG:-vega_1p}` default (which only applies
     when the var is unset). Without this change the hands are NOT disabled on
     the omniteleop/drive side.
   - **Revert:** `export ROBOT_CONFIG=vega_1p_f5d6` (then open a new shell).

1. **`scripts/lab_connect.sh`** (~line 31)
   - Changed the omniteleop/dexcontrol variant from `vega_1p_f5d6` to `vega_1p`
     (the no-hands variant).
   - `ROBOT_CONFIG=vega_1p` makes `command_processor.py` skip building the
     `HandProcessor` (gated on `robot_info.has_component("left_hand")`) and makes
     `robot_controller.py` set `hand_type=None` (all hand calls are gated on
     `hand_type is not None`).
   - **Revert:** `export ROBOT_CONFIG="${ROBOT_CONFIG:-vega_1p_f5d6}"`

2. **`scripts/launch_exo_lerobot.sh`** (in the `lerobot-record` command)
   - Added **all four** flags: `--robot.with_left_hand=false`,
     `--robot.with_right_hand=false`, `--teleop.with_left_hand=false`,
     `--teleop.with_right_hand=false`.
   - The hand flags exist on BOTH sides and must mirror each other (see the
     comment on `VegaExoJoyconConfig.with_left_hand`). If only the follower
     (`--robot.*`) is disabled, the teleoperator still declares the hands and
     `get_action()` raises `DeviceNotConnectedError: Component 'left_hand' is
     missing from both 'robot/safe_commands' and 'robot/joints', and has never
     been seen` on the first record loop tick. Disabling both sides drops the
     hand joints from the recorded feature vector so recording works.
   - **Revert:** delete all four `--robot.with_*_hand=false` /
     `--teleop.with_*_hand=false` lines (the dataclass defaults in
     `config_vega_1p_follower.py` and `config_vega_exo_joycon.py` are already
     `True`).
   - NOTE: `check_lerobot_recording.py` does NOT exercise the teleoperator's
     `get_action()`, so it will pass even if the `--teleop.*` flags are missing;
     the failure only shows up in a real `lerobot-record` run.

No source files in `omniteleop/` or `lerobot/` were modified — only these two
launch/env scripts in `vega_module/`.

## Data-format warning

Datasets recorded while hands are disabled have **no `left_hand` / `right_hand`
columns** and are **NOT layout-compatible** with hand-enabled episodes. Keep them
in a separate `DATASET_REPO_ID`, or re-record after the hands are fixed.

## How to verify the hands are back (before reverting)

```bash
python vega_module/scripts/start_hands.py          # detect + clear-error + report
# or:
dextop firmware info                                # look for a 'hand' row
dextop topic list | grep -i hand                    # hand state topics present?
```

`start_hands.py` prints each side's detected type. When both report a known type
(`HandF5D6_V2` / `HandF5D6_V1`), revert the two changes above.

## Root cause (not fixed here)

`UNKNOWN` is decided by the **controller**, not the client — it means no known
end-effector is enumerated on the wrist bus. Likely a physical connection /
power / firmware-enumeration issue. Reseat the wrist connectors, confirm hand
power, then power-cycle / reboot the controller so it re-enumerates. A client
script cannot force a hand the controller cannot see.
