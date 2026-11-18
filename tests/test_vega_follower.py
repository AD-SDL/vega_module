#!/usr/bin/env python
"""Smoke test for the vega_1p_follower LeRobot robot: `read` (read-only) / `command` (MOVES it).

    source ~/humanoids/venvs/dexmate/bin/activate
    source ~/humanoids/vega_module/scripts/connect.sh remote
    python tests/test_vega_follower.py read [--cameras]
    python tests/test_vega_follower.py command

See .docs/SCRIPTS.md.
"""

from __future__ import annotations

import argparse
import sys
import time

from lerobot.robots.vega_1p_follower.config_vega_1p_follower import Vega1PFollowerConfig
from lerobot.robots.vega_1p_follower.vega_1p_follower import Vega1PFollower


def build_config(with_sensors: bool, external_commands: bool) -> Vega1PFollowerConfig:
    """Config with cameras/IMU optionally off (connect() refuses a non-streaming sensor)."""
    return Vega1PFollowerConfig(
        with_head_camera_left_rgb=with_sensors,
        with_head_camera_right_rgb=with_sensors,
        with_head_camera_depth=with_sensors,
        with_head_imu=with_sensors,
        use_external_commands=external_commands,
    )


def run_read(with_cameras: bool) -> None:
    robot = Vega1PFollower(build_config(with_sensors=with_cameras, external_commands=True))
    print(f"-> Connecting (cameras/IMU {'on' if with_cameras else 'off'})...")
    robot.connect()
    print(f"-> Connected: {robot.is_connected}")
    try:
        obs = robot.get_observation()
        # Images are array-valued; joints are ".pos" scalars; everything else is a scalar.
        images = {k: v for k, v in obs.items() if hasattr(v, "shape")}
        joints = {k: v for k, v in obs.items() if k.endswith(".pos") and k not in images}
        others = {k: v for k, v in obs.items() if k not in images and k not in joints}
        print(
            f"-> Observation: {len(obs)} keys "
            f"({len(joints)} joints, {len(images)} image streams, {len(others)} other scalars)"
        )
        for k in list(joints)[:6]:
            print(f"     {k} = {joints[k]:.4f}")
        for k, v in images.items():
            print(f"     {k}: shape {v.shape}")
        for k in others:
            print(f"     {k} (scalar)")
    finally:
        robot.disconnect()
    print("-> Read test OK.")


# Head + arms come up disabled and ignore setpoints until enabled (head/arms use different
# APIs); torso and hands have no such gate and accept the no-op echo as-is.
def _enable_position_components(dex_robot) -> list[str]:  # noqa: ANN001 -- dexcontrol Robot
    """Enable position control on head + both arms. Returns the ones enabled."""
    enabled: list[str] = []
    dex_robot.head.set_mode("enable")
    enabled.append("head")
    for arm in ("left_arm", "right_arm"):
        getattr(dex_robot, arm).set_modes(["position"] * 7)
        enabled.append(arm)
    print(f"-> Enabled for position control: {enabled}")
    return enabled


def _disable_position_component(dex_robot, comp: str) -> None:  # noqa: ANN001
    """Return one component to its disabled state."""
    if comp == "head":
        dex_robot.head.set_mode("disable")
    else:
        getattr(dex_robot, comp).set_modes(["disable"] * 7)


def run_command(assume_yes: bool) -> None:
    if not assume_yes:
        print(
            "!! This releases the software E-Stop, ENABLES the head and both arms, and commands "
            "the robot. Keep the workspace clear."
        )
        if input("   Continue? [y/N] ").strip().lower() not in ("y", "yes"):
            print("-> Aborted.")
            return

    robot = Vega1PFollower(build_config(with_sensors=False, external_commands=False))
    print("-> Connecting (cameras/IMU off)...")
    robot.connect()
    estop_released = False
    enabled_components: list[str] = []
    try:
        # Release the software e-stop so setpoints take effect; refuse the physical button.
        estop = robot.robot.estop
        if estop.is_button_pressed():
            raise RuntimeError(
                "Physical E-Stop button is pressed -- release it on the robot before commanding."
            )
        if estop.is_software_estop_enabled():
            print("-> Releasing software E-Stop...")
            estop.deactivate()
            time.sleep(1.0)  # let the release propagate before we command
            if estop.is_software_estop_enabled():
                raise RuntimeError("Software E-Stop did not release; aborting before commanding.")
        estop_released = True
        print(f"-> Software E-Stop released: {not estop.is_software_estop_enabled()}")

        # Enable position components (after the e-stop release; the head refuses before it).
        enabled_components = _enable_position_components(robot.robot)
        time.sleep(0.5)

        obs = robot.get_observation()
        # Echo current positions back: a no-op setpoint; max_relative_target still clamps.
        action = {k: v for k, v in obs.items() if k.endswith(".pos")}
        sent = robot.send_action(action)
        print(f"-> Commanded {len(sent)} joints with their current positions (no motion expected).")
    finally:
        # Disable what we enabled, then re-arm the e-stop, so the robot is never left live.
        for comp in enabled_components:
            try:
                _disable_position_component(robot.robot, comp)
            except Exception as err:  # noqa: BLE001 -- teardown must not raise
                print(f"-> Warning: could not disable {comp}: {err}")
        if estop_released:
            print("-> Re-activating software E-Stop...")
            robot.robot.estop.activate()
        robot.disconnect()
    print("-> Command test OK.")


def main() -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    sub = parser.add_subparsers(dest="tier", required=True)

    read = sub.add_parser("read", help="connect + read one observation (read-only)")
    read.add_argument(
        "--cameras", action="store_true", help="also enable and validate camera/IMU streams"
    )

    command = sub.add_parser(
        "command", help="connect + echo current pose as a setpoint (MOVES the robot)"
    )
    command.add_argument("-y", "--yes", action="store_true", help="skip the confirmation prompt")

    args = parser.parse_args()

    try:
        if args.tier == "read":
            run_read(with_cameras=args.cameras)
        else:
            run_command(assume_yes=args.yes)
    except Exception as err:  # surface the failure without a full traceback wall
        print(f"-> FAILED: {type(err).__name__}: {err}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
