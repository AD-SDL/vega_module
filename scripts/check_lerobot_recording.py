#!/usr/bin/env python
"""Verify what LeRobot observes and records from the Vega, without writing anything.

Bring-up check for `launch_exo_lerobot.sh`. Connects `Vega1PFollower`, polls
`get_observation()` for a few seconds, and assembles the dataset frames `lerobot-record`
would write -- confirming column names, shapes, dtypes and rate -- but creates no dataset
and no files.

Nothing is commanded. The follower is built with use_external_commands=True, so
`send_action` returns its input without reaching the hardware, which lets the action path
be exercised as safely as the observation one.

Run it with the robot on and its sensors publishing, but with no teleop stack needed:

    source scripts/lab_connect.sh
    python scripts/check_lerobot_recording.py

Exits non-zero on any mismatch, so it also works as a pre-flight gate.
"""

from __future__ import annotations

import argparse
import math
import sys
import time

import numpy as np
from _vega_checks import RateMeter, Report, describe_value, key_diff, load_module_env, pace
from lerobot.robots.vega_1p_follower import Vega1PFollower, Vega1PFollowerConfig
from lerobot.robots.vega_1p_follower.vega_1p_follower import VEGA_CAMERAS, VEGA_JOINTS
from lerobot.utils.constants import ACTION, DEFAULT_FEATURES, OBS_STR
from lerobot.utils.feature_utils import (
    build_dataset_frame,
    combine_feature_dicts,
    hw_to_dataset_features,
)

# How many per-frame problems to print before summarising the rest.
MAX_REPORTED_PROBLEMS = 10


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("--seconds", type=float, default=5.0, help="How long to sample.")
    parser.add_argument("--fps", type=float, default=20.0, help="Polling rate.")
    parser.add_argument(
        "--without",
        action="append",
        default=[],
        metavar="NAME",
        choices=sorted(VEGA_JOINTS) + sorted(VEGA_CAMERAS) + ["head_imu"],
        help="Disable a component, camera or head_imu. Repeatable.",
    )
    parser.add_argument(
        "--no-video",
        action="store_true",
        help="Describe cameras as image rather than video columns, matching --dataset.video=false.",
    )
    return parser.parse_args()


def build_config(disabled: list[str]) -> Vega1PFollowerConfig:
    """Follower config with the requested with_* flags turned off.

    use_external_commands is forced on: this check must never reach the hardware.
    """
    overrides = {f"with_{name}": False for name in disabled}
    return Vega1PFollowerConfig(id="recording_check", use_external_commands=True, **overrides)


def dataset_schema(follower: Vega1PFollower, use_video: bool) -> dict[str, dict]:
    """The feature dict `lerobot-record` would create for this robot.

    `lerobot_record` routes both sides through `aggregate_pipeline_dataset_features`, but
    its default pipelines are identity, so calling `hw_to_dataset_features` directly gives
    the same result with far less machinery.
    """
    return combine_feature_dicts(
        hw_to_dataset_features(follower.action_features, ACTION, use_video),
        hw_to_dataset_features(follower.observation_features, OBS_STR, use_video),
        follower.extra_dataset_features,
    )


def print_surface(follower: Vega1PFollower, features: dict[str, dict]) -> None:
    print("\nComponents")
    for comp, joints in follower.components.items():
        print(f"  {comp:<12} {len(joints):>2} joints   {joints[0]} .. {joints[-1]}")
    if not follower.components:
        print("  (none enabled)")

    print("\nCameras")
    for key, shape in follower.camera_features.items():
        print(f"  {key:<26} {shape}")
    if not follower.cameras:
        print("  (none enabled)")

    print("\nExtra columns")
    for key, spec in follower.extra_dataset_features.items():
        print(f"  {key:<26} {spec['shape']}  ({len(spec['names'])} names)")
    if not follower.extra_dataset_features:
        print("  (none)")

    print("\nDataset columns lerobot-record would create")
    for key, spec in features.items():
        width = spec["shape"] if spec["dtype"] != "float32" else f"({spec['shape'][0]},)"
        print(f"  {key:<38} {spec['dtype']:<8} {width}")


def sample(
    follower: Vega1PFollower, seconds: float, fps: float
) -> tuple[RateMeter, list[str], dict]:
    """Poll get_observation() and collect every per-frame problem seen."""
    declared = follower.observation_features
    cameras = follower.camera_features
    joint_keys = list(follower.action_features)

    meter = RateMeter()
    period = 1.0 / fps
    deadline = time.monotonic() + seconds
    problems: list[str] = []
    obs: dict = {}

    while time.monotonic() < deadline:
        loop_start = time.perf_counter()
        obs = follower.get_observation()
        meter.tick()
        n = meter.count

        if missing := sorted(set(declared) - set(obs)):
            problems.append(f"frame {n}: observation is missing {missing}")

        for key, shape in cameras.items():
            frame = obs.get(key)
            if not isinstance(frame, np.ndarray):
                problems.append(f"frame {n}: '{key}' is {type(frame).__name__}, not an ndarray")
            elif frame.shape != shape:
                problems.append(f"frame {n}: '{key}' has shape {frame.shape}, declared {shape}")

        for key in joint_keys:
            value = obs.get(key)
            if isinstance(value, (int, float)) and not math.isfinite(value):
                problems.append(f"frame {n}: '{key}' is {value}")

        pace(loop_start, period)

    return meter, problems, obs


def main() -> int:
    args = parse_args()
    load_module_env()

    follower = Vega1PFollower(build_config(args.without))
    report = Report("observation / action recording")

    print("Connecting (this also checks every enabled sensor is live and at the declared size)...")
    follower.connect()

    try:
        features = dataset_schema(follower, use_video=not args.no_video)
        print_surface(follower, features)

        print(f"\nSampling get_observation() for {args.seconds:g}s at {args.fps:g} Hz...")
        meter, problems, obs = sample(follower, args.seconds, args.fps)
        print(f"  {meter.count} observations  ->  {meter.hz:.1f} Hz")

        report.check(
            meter.count > 0,
            f"get_observation() returned {meter.count} frames",
            "get_observation() never returned within the sampling window",
        )
        if not obs:
            return report.finish()

        report.check(
            meter.hz >= args.fps * 0.5,
            f"Observation rate {meter.hz:.1f} Hz sustains "
            f"--dataset.fps={int(min(args.fps, meter.hz))}",
            f"Observation rate {meter.hz:.1f} Hz is under half the requested {args.fps:g} Hz; "
            f"recording at that fps would stall the loop",
        )

        if problems:
            for line in problems[:MAX_REPORTED_PROBLEMS]:
                print(f"  {line}")
            if len(problems) > MAX_REPORTED_PROBLEMS:
                print(f"  ... and {len(problems) - MAX_REPORTED_PROBLEMS} more")
        report.check(
            not problems,
            f"Every frame carried all {len(follower.observation_features)} declared keys, "
            f"at the declared shapes, with finite joint values",
            f"{len(problems)} per-frame problems (listed above)",
        )

        print("\nLast observation")
        for key in list(follower.action_features)[:3]:
            print(f"  {key:<26} {describe_value(obs.get(key))}")
        print(f"  ... {len(follower.action_features)} joint values")
        for key in follower.camera_features:
            print(f"  {key:<26} {describe_value(obs.get(key))}")

        # A recorded action is the teleoperator's target. With no teleop attached the
        # current state stands in: this step is about column names and dtypes, not values.
        action = {key: float(obs[key]) for key in follower.action_features}

        obs_frame = build_dataset_frame(features, obs, prefix=OBS_STR)
        action_frame = build_dataset_frame(features, action, prefix=ACTION)
        built = set(obs_frame) | set(action_frame)
        expected = set(features) - set(DEFAULT_FEATURES)
        report.check(
            built == expected,
            f"build_dataset_frame assembled all {len(expected)} dataset columns",
            f"Assembled frame does not match the schema: {key_diff(built, expected)}",
        )

        bad_dtype = [
            key
            for key, value in {**obs_frame, **action_frame}.items()
            if features[key]["dtype"] == "float32" and value.dtype != np.float32
        ]
        report.check(
            not bad_dtype,
            "Every float32 column assembled as float32",
            f"Columns assembled with the wrong dtype: {sorted(bad_dtype)}",
        )

        sent = follower.send_action(action)
        report.check(
            list(sent) == list(follower.action_features),
            f"send_action round-tripped all {len(sent)} action keys",
            f"send_action returned different keys: {key_diff(sent, follower.action_features)}",
        )

        return report.finish()
    finally:
        follower.disconnect()


if __name__ == "__main__":
    sys.exit(main())
