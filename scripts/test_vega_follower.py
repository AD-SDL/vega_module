#!/usr/bin/env python
"""Quick smoke test for the vega_1p_follower LeRobot robot.

Two tiers, run separately:

    read     connect + read one observation (read-only, no motion)
    command  connect + send the current pose back as a setpoint (MOVES the robot)

Prerequisites (in the same shell):
    source /home/rpl/humanoids/venvs/dexmate/bin/activate
    source /home/rpl/humanoids/vega_module/scripts/lab_connect.sh   # tunnel + ROBOT_NAME

Examples:
    python test_vega_follower.py read              # motors only, cameras/IMU off
    python test_vega_follower.py read --cameras    # also validate camera streams
    python test_vega_follower.py command           # requires the E-stop released
"""

from __future__ import annotations

import argparse
import sys
import time

from lerobot.robots.vega_1p_follower.config_vega_1p_follower import Vega1PFollowerConfig
from lerobot.robots.vega_1p_follower.vega_1p_follower import Vega1PFollower


def build_config(with_sensors: bool, external_commands: bool) -> Vega1PFollowerConfig:
    """Config with the camera/IMU sensors optionally disabled.

    connect() requires every enabled sensor to already be streaming, so leaving
    them off lets us test the dexcontrol link and joint reads on their own.
    """
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
        # Images are the array-valued entries; joints are ".pos" scalars; anything
        # else (e.g. the 10 head_imu quaternion/gyro/accel floats) is a scalar too.
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


def run_command(assume_yes: bool) -> None:
    if not assume_yes:
        print("!! This releases the software E-Stop and commands the robot. Keep the workspace clear.")
        if input("   Continue? [y/N] ").strip().lower() not in ("y", "yes"):
            print("-> Aborted.")
            return

    robot = Vega1PFollower(build_config(with_sensors=False, external_commands=False))
    print("-> Connecting (cameras/IMU off)...")
    robot.connect()
    estop_released = False
    try:
        # The software E-Stop blocks control features, so a setpoint sent while it is
        # active is silently a no-op. Release it here so this tier actually exercises
        # commanding. The physical button cannot be cleared in software.
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

        obs = robot.get_observation()
        # Echo the current joint positions back: a no-op setpoint. max_relative_target
        # on the config still clamps each joint, so nothing can jump.
        action = {k: v for k, v in obs.items() if k.endswith(".pos")}
        sent = robot.send_action(action)
        print(f"-> Commanded {len(sent)} joints with their current positions (no motion expected).")
    finally:
        # Re-arm the software E-Stop before dropping the link, so we never leave the
        # robot live after the test -- even if commanding raised above.
        if estop_released:
            print("-> Re-activating software E-Stop...")
            robot.robot.estop.activate()
        robot.disconnect()
    print("-> Command test OK.")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="tier", required=True)

    read = sub.add_parser("read", help="connect + read one observation (read-only)")
    read.add_argument("--cameras", action="store_true", help="also enable and validate camera/IMU streams")

    command = sub.add_parser("command", help="connect + echo current pose as a setpoint (MOVES the robot)")
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
