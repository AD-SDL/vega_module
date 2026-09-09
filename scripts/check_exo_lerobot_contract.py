#!/usr/bin/env python
"""Verify the omniteleop -> LeRobot teleoperator contract before recording.

Bring-up check for `launch_exo_lerobot.sh`. Confirms that what omniteleop publishes on
`robot/safe_commands` reshapes cleanly into the action dict `Vega1PFollower` expects --
component names, DOF counts, key parity and publish rate -- without touching the robot
or writing a dataset.

Run it with the teleop stack up (joycon_reader + arm_reader + command_processor at
minimum) and the lab environment sourced:

    source scripts/lab_connect.sh
    python scripts/check_exo_lerobot_contract.py

Exits non-zero on any mismatch, so it also works as a pre-flight gate.
"""

from __future__ import annotations

import argparse
import sys
import time

from lerobot.robots.vega_1p_follower import Vega1PFollower, Vega1PFollowerConfig
from lerobot.teleoperators.vega_exo_joycon import VegaExoJoycon, VegaExoJoyconConfig


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--seconds", type=float, default=5.0, help="How long to sample.")
    parser.add_argument("--timeout", type=float, default=120.0, help="Wait for the first command.")
    args = parser.parse_args()

    # The follower is only constructed, never connected: action_features is declared from
    # config, so this needs no robot and no dexcontrol session.
    follower = Vega1PFollower(Vega1PFollowerConfig(id="contract_check"))
    teleop = VegaExoJoycon(VegaExoJoyconConfig(id="contract_check", connect_timeout_s=args.timeout))

    print(f"Subscribing to '{teleop.config.commands_topic}' (namespace from ROBOT_NAME)...")
    teleop.connect()

    try:
        command = teleop._command or {}
        components = command.get("components", {})
        print(f"\nComponents present: {sorted(components)}")
        for name in sorted(components):
            payload = components[name]
            shape = {k: (len(v) if isinstance(v, list) else v) for k, v in payload.items()}
            expected = len(teleop.components.get(name, []))
            note = "" if name not in teleop.components else f"  (teleop expects {expected} joints)"
            print(f"  {name:<11} {shape}{note}")

        missing = set(teleop.components) - set(components)
        if missing:
            print(
                f"\nNot in this command, will backfill from "
                f"'{teleop.config.joints_topic}': {sorted(missing)}"
            )

        action = teleop.get_action()
        teleop_keys, robot_keys = list(action), list(follower.action_features)

        print(
            f"\nAction keys: {len(teleop_keys)} from teleop, {len(robot_keys)} declared by follower"
        )
        if teleop_keys != robot_keys:
            print("MISMATCH -- build_dataset_frame will KeyError on the first frame.")
            print(f"  only in teleop  : {sorted(set(teleop_keys) - set(robot_keys))}")
            print(f"  only in follower: {sorted(set(robot_keys) - set(teleop_keys))}")
            return 1
        print("Keys match exactly, including order.")

        # Rate check: command_rate is 20 Hz, so --dataset.fps above that just duplicates.
        print(f"\nSampling for {args.seconds:g}s...")
        seen, deadline = 0, time.monotonic() + args.seconds
        last_stamp = None
        while time.monotonic() < deadline:
            stamp = (teleop._command or {}).get("timestamp_ns")
            if stamp is not None and stamp != last_stamp:
                last_stamp = stamp
                seen += 1
            time.sleep(0.005)
        rate = seen / args.seconds
        print(f"  {seen} commands  ->  {rate:.1f} Hz")
        if rate < 1.0:
            print("  Too slow to record against. Is command_processor still publishing?")
            return 1
        print(f"  Record at --dataset.fps={min(20, int(rate))} or lower.")

        print("\nContract OK.")
        return 0
    finally:
        teleop.disconnect()


if __name__ == "__main__":
    sys.exit(main())
