#!/usr/bin/env python
"""Verify the omniteleop -> LeRobot teleoperator contract (no robot, no dataset).

    source scripts/connect.sh remote        # teleop stack must be publishing
    python scripts/checks/check_exo_lerobot_contract.py

Exits non-zero on any mismatch. See .docs/SCRIPTS.md.
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
    parser.add_argument(
        "--with-chassis",
        default=True,
        action=argparse.BooleanOptionalAction,
        help="Include the mobile-base action keys (base.vx/vy/wz) in the parity check. "
        "Must match the record WITH_CHASSIS (default true; see record.env). Use --no-with-chassis "
        "to check the stationary schema.",
    )
    args = parser.parse_args()

    # Constructed, never connected: action_features is declared from config.
    follower = Vega1PFollower(
        Vega1PFollowerConfig(id="contract_check", with_chassis=args.with_chassis)
    )
    teleop = VegaExoJoycon(
        VegaExoJoyconConfig(
            id="contract_check", connect_timeout_s=args.timeout, with_chassis=args.with_chassis
        )
    )

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
