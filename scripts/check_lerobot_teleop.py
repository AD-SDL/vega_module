#!/usr/bin/env python
"""Run the exact teleop loop `lerobot-record` runs, without recording anything.

Bring-up check for `launch_exo_lerobot.sh`. Connects the exoskeleton teleoperator and the
follower in the passive configuration the recorder uses -- omniteleop's robot_controller.py
keeps driving the robot at 100 Hz, LeRobot only observes -- then runs
get_observation() -> get_action() -> send_action() at the record rate and reports whether
the action, observation and dataset-frame paths hold together live.

This script cannot move the robot. use_external_commands is forced on, which makes
`send_action` return its input without touching hardware, and the script aborts if that
flag is ever false.

Run it with the full teleop stack up and the exoskeleton in hand:

    source scripts/lab_connect.sh
    ./scripts/launch_exo_teleop.sh
    python scripts/check_lerobot_teleop.py

Exits non-zero on a key mismatch, a stale command stream, or a run in which no joint moved.
"""

from __future__ import annotations

import argparse
import sys
import time

from _vega_checks import (
    RateMeter,
    Report,
    key_diff,
    load_module_env,
    pace,
    processes_running,
)
from lerobot.robots.vega_1p_follower import Vega1PFollower, Vega1PFollowerConfig
from lerobot.robots.vega_1p_follower.vega_1p_follower import VEGA_CAMERAS
from lerobot.teleoperators.vega_exo_joycon import VegaExoJoycon, VegaExoJoyconConfig
from lerobot.utils.constants import ACTION, DEFAULT_FEATURES, OBS_STR
from lerobot.utils.feature_utils import (
    build_dataset_frame,
    combine_feature_dicts,
    hw_to_dataset_features,
)

# A joint that never moves this far over the whole run is treated as not exercised.
MOVED_RAD = 1e-3

MAX_REPORTED_PROBLEMS = 10


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("--seconds", type=float, default=15.0, help="How long to run the loop.")
    parser.add_argument(
        "--fps", type=float, default=20.0, help="Loop rate; 20 matches command_rate."
    )
    parser.add_argument(
        "--timeout", type=float, default=120.0, help="Wait for the teleoperator's first command."
    )
    parser.add_argument(
        "--no-cameras",
        action="store_true",
        help="Skip the camera streams, to check the action path without the sensor stack.",
    )
    parser.add_argument(
        "--no-video",
        action="store_true",
        help="Describe cameras as image rather than video columns, matching --dataset.video=false.",
    )
    return parser.parse_args()


def build_configs(args: argparse.Namespace) -> tuple[Vega1PFollowerConfig, VegaExoJoyconConfig]:
    """Follower and teleoperator configs with matching with_* flags.

    The two key sets have to agree exactly or `build_dataset_frame` raises on the first
    frame, so the teleoperator mirrors whatever the follower is configured for.
    """
    cameras = {f"with_{name}": False for name in VEGA_CAMERAS} if args.no_cameras else {}
    follower = Vega1PFollowerConfig(
        id="teleop_check",
        use_external_commands=True,
        with_head_imu=not args.no_cameras,
        **cameras,
    )
    teleop = VegaExoJoyconConfig(
        id="teleop_check",
        connect_timeout_s=args.timeout,
        **{
            f"with_{name}": getattr(follower, f"with_{name}")
            for name in ("left_arm", "right_arm", "left_hand", "right_hand", "head", "torso")
        },
    )
    return follower, teleop


def main() -> int:
    args = parse_args()
    load_module_env()

    follower_config, teleop_config = build_configs(args)
    if not follower_config.use_external_commands:
        print(
            "Refusing to run: use_external_commands is off, so this loop would command the "
            "robot while robot_controller.py is also driving it.",
            file=sys.stderr,
        )
        return 1

    if not processes_running(r"robot_controller\.py"):
        print(
            "Warning: robot_controller.py is not running, so nothing is driving the robot. The "
            "exoskeleton will still produce actions, but no joint will move and the travel "
            "check below will fail.\n"
        )

    follower = Vega1PFollower(follower_config)
    teleop = VegaExoJoycon(teleop_config)
    report = Report("passive teleop loop")

    print(
        f"Waiting for the first command on '{teleop_config.commands_topic}' "
        f"(up to {args.timeout:g}s -- align the exoskeleton and release the JoyCon e-stop)..."
    )
    teleop.connect()

    try:
        print("Connecting the follower...")
        follower.connect()

        try:
            features = combine_feature_dicts(
                hw_to_dataset_features(follower.action_features, ACTION, not args.no_video),
                hw_to_dataset_features(follower.observation_features, OBS_STR, not args.no_video),
                follower.extra_dataset_features,
            )
            expected_columns = set(features) - set(DEFAULT_FEATURES)
            action_keys = list(follower.action_features)

            report.check(
                list(teleop.action_features) == action_keys,
                f"Teleoperator and follower agree on all {len(action_keys)} action keys",
                f"Teleoperator and follower disagree: "
                f"{key_diff(teleop.action_features, action_keys)}",
            )

            meter = RateMeter()
            period = 1.0 / args.fps
            deadline = time.monotonic() + args.seconds
            problems: list[str] = []
            stale = 0
            overruns = 0
            first: dict[str, float] = {}
            travel = dict.fromkeys(action_keys, 0.0)

            print(
                f"\nRunning the loop for {args.seconds:g}s at {args.fps:g} Hz. Move the "
                f"exoskeleton through the joints you intend to record."
            )
            try:
                while time.monotonic() < deadline:
                    loop_start = time.perf_counter()

                    if teleop._command_age() > teleop_config.max_command_age_s:
                        stale += 1

                    obs = follower.get_observation()
                    action = teleop.get_action()
                    sent = follower.send_action(action)
                    meter.tick()
                    n = meter.count

                    if list(action) != action_keys:
                        problems.append(
                            f"step {n}: action keys wrong -- {key_diff(action, action_keys)}"
                        )
                    if sent != action:
                        problems.append(
                            f"step {n}: send_action altered the action despite "
                            f"use_external_commands, so something did reach the hardware"
                        )

                    try:
                        frame = {
                            **build_dataset_frame(features, obs, prefix=OBS_STR),
                            **build_dataset_frame(features, action, prefix=ACTION),
                        }
                    except KeyError as err:
                        problems.append(f"step {n}: dataset frame is missing {err}")
                    else:
                        if set(frame) != expected_columns:
                            diff = key_diff(frame, expected_columns)
                            problems.append(f"step {n}: frame columns wrong -- {diff}")

                    if not first:
                        first = {k: float(v) for k, v in action.items()}
                    for key, value in action.items():
                        travel[key] = max(travel[key], abs(float(value) - first[key]))

                    if pace(loop_start, period) > 0:
                        overruns += 1
            except KeyboardInterrupt:
                print("\nInterrupted.")

            print(f"\n  {meter.count} iterations  ->  {meter.hz:.1f} Hz")

            if not report.check(
                meter.count > 0,
                f"Completed {meter.count} loop iterations",
                "The loop never completed an iteration",
            ):
                return report.finish()

            if problems:
                for line in problems[:MAX_REPORTED_PROBLEMS]:
                    print(f"  {line}")
                if len(problems) > MAX_REPORTED_PROBLEMS:
                    print(f"  ... and {len(problems) - MAX_REPORTED_PROBLEMS} more")
            report.check(
                not problems,
                f"All {meter.count} iterations produced a complete, correctly keyed dataset frame",
                f"{len(problems)} per-iteration problems (listed above)",
            )

            report.check(
                meter.hz >= args.fps * 0.5,
                f"Loop held {meter.hz:.1f} Hz, enough for "
                f"--dataset.fps={int(min(args.fps, meter.hz))}",
                f"Loop managed only {meter.hz:.1f} Hz against {args.fps:g} requested "
                f"({overruns} steps ran long); recording at that fps would drop frames",
            )

            report.check(
                stale == 0,
                f"The command stream stayed fresh for all {meter.count} iterations",
                f"The last command was older than {teleop_config.max_command_age_s:g}s on {stale} "
                f"of {meter.count} iterations. command_processor is publishing intermittently, so "
                f"recorded actions would repeat -- check its window and the JoyCon e-stop",
            )

            active = {k: v for k, v in travel.items() if v > MOVED_RAD}
            print(f"\nTravel: {len(active)} of {len(travel)} action columns moved")
            for key, amount in sorted(active.items(), key=lambda kv: -kv[1])[:10]:
                print(f"  {key:<26} {amount:.4f} rad")
            if idle := sorted(set(travel) - set(active)):
                shown = ", ".join(idle[:6])
                more = f", +{len(idle) - 6} more" if len(idle) > 6 else ""
                print(f"  constant: {shown}{more}")

            report.check(
                bool(active),
                f"{len(active)} action columns varied during the run",
                "No action column changed. The exoskeleton is not reaching the action dict, so "
                "a recording would be a constant -- check arm_reader.py and command_processor.py",
            )

            return report.finish()
        finally:
            # The follower first: its dexcontrol.Robot.shutdown() issues component stop()
            # calls on hardware robot_controller is still driving, so it must not outlive
            # the loop while the teleoperator holds the session open.
            follower.disconnect()
    finally:
        teleop.disconnect()


if __name__ == "__main__":
    sys.exit(main())
