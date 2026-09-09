#!/usr/bin/env python
"""Move one Vega joint a small amount, down either control path, and report what happened.

Bring-up check that answers "can we command this robot at all". Reads the current pose,
drives a single joint through one small sinusoid, and returns it to where it started --
reporting how far it actually travelled, how well it tracked, and whether anything clamped.

Two paths, chosen with --via:

  lerobot      Vega1PFollower.send_action() commands the hardware directly through
               dexcontrol. LeRobot is the only writer, so omniteleop must be stopped.
               Exercises the clamp in `max_relative_target`.

  omniteleop   Publishes onto 'robot/safe_commands' and lets robot_controller.py execute
               with its ruckig interpolation and safety validator. LeRobot is not involved.
               Requires robot_controller.py up and command_processor.py down -- the latter
               publishes the same topic, and two publishers fight over the robot.

THIS SCRIPT MOVES THE ROBOT. Defaults are deliberately small: one head joint, 0.05 rad,
one 4-second cycle. Keep a hand on the e-stop.

    source scripts/lab_connect.sh
    python scripts/check_lerobot_motion.py --via lerobot --dry-run   # print, move nothing
    python scripts/check_lerobot_motion.py --via lerobot

Exits non-zero if the preflight fails, the operator declines, or the robot did not move.
"""

from __future__ import annotations

import argparse
import math
import sys
import threading
import time
from typing import Any

from _vega_checks import Report, confirm, load_module_env, pace, processes_running
from lerobot.robots.vega_1p_follower.vega_1p_follower import VEGA_CAMERAS, VEGA_JOINTS

# Zenoh topics, matching the `topics:` block of the active omniteleop config
# (src/omniteleop/configs/<ROBOT_CONFIG>.yaml). dexcomm applies the ROBOT_NAME namespace.
COMMANDS_TOPIC = "robot/safe_commands"
JOINTS_TOPIC = "robot/joints"

# Refuse a larger swing without --force. Well inside every joint's range from a neutral
# pose, but this check has no joint-limit model of its own, so it stays timid.
MAX_UNFORCED_AMPLITUDE = 0.3

# Seconds spent ramping back to the start pose when the run ends or is interrupted.
RETURN_S = 1.5


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument(
        "--via",
        choices=["lerobot", "omniteleop"],
        required=True,
        help="Which control path to drive the joint through.",
    )
    parser.add_argument(
        "--component", choices=sorted(VEGA_JOINTS), default="head", help="Component to move."
    )
    parser.add_argument(
        "--joint", help="Joint name within the component. Default: its first joint."
    )
    parser.add_argument(
        "--all-joints", action="store_true", help="Move every joint of the component together."
    )
    parser.add_argument("--amplitude", type=float, default=0.05, help="Peak displacement, radians.")
    parser.add_argument("--period", type=float, default=4.0, help="Seconds per cycle.")
    parser.add_argument("--cycles", type=float, default=1.0, help="Number of cycles.")
    parser.add_argument("--fps", type=float, default=20.0, help="Command rate.")
    parser.add_argument(
        "--clamp",
        type=float,
        default=0.05,
        help="max_relative_target for the lerobot path (radians per step).",
    )
    parser.add_argument(
        "--namespace", default="", help="Extra dexcomm namespace (omniteleop path)."
    )
    parser.add_argument(
        "--timeout", type=float, default=15.0, help="Wait for the first joint feedback message."
    )
    parser.add_argument("--dry-run", action="store_true", help="Print the trajectory and exit.")
    parser.add_argument("--yes", action="store_true", help="Skip the confirmation prompt.")
    parser.add_argument(
        "--force",
        action="store_true",
        help=f"Allow an amplitude above {MAX_UNFORCED_AMPLITUDE} rad.",
    )
    return parser.parse_args()


def resolve_joints(
    component: str, joint: str | None, all_joints: bool
) -> tuple[list[str], list[str]]:
    """Every joint of the component, and the subset this run will actually displace."""
    joints = VEGA_JOINTS[component]
    if all_joints:
        return joints, list(joints)
    if joint is None:
        return joints, [joints[0]]
    if joint not in joints:
        raise SystemExit(f"'{joint}' is not a joint of '{component}'. Choose from: {joints}")
    return joints, [joint]


def build_trajectory(
    amplitude: float, period: float, cycles: float, fps: float
) -> list[tuple[float, float]]:
    """(t, offset) samples of a sinusoid that both starts and ends at zero displacement."""
    steps = max(int(round(period * cycles * fps)), 1)
    out = []
    for i in range(steps + 1):
        t = i / fps
        out.append((t, amplitude * math.sin(2 * math.pi * t / period)))
    return out


class LeRobotDriver:
    """LeRobot commands the hardware itself, through Vega1PFollower.send_action()."""

    label = "lerobot (Vega1PFollower.send_action -> dexcontrol)"

    def __init__(self, component: str, joints: list[str], clamp: float) -> None:
        from lerobot.robots.vega_1p_follower import Vega1PFollower, Vega1PFollowerConfig

        # Only the target component is enabled, and every sensor is off: this check needs
        # no camera or IMU stack, and connect() refuses when a declared sensor is silent.
        flags: dict[str, Any] = {f"with_{name}": name == component for name in VEGA_JOINTS}
        flags.update({f"with_{name}": False for name in VEGA_CAMERAS})
        self.follower = Vega1PFollower(
            Vega1PFollowerConfig(
                id="motion_check",
                use_external_commands=False,
                max_relative_target=clamp,
                with_head_imu=False,
                **flags,
            )
        )
        self.joints = joints
        self.clamp = clamp
        self.max_clamped = 0.0
        self.max_tracking_error = 0.0

    def connect(self) -> None:
        self.follower.connect()

    def send(self, targets: dict[str, float]) -> dict[str, float]:
        sent = self.follower.send_action({f"{j}.pos": v for j, v in targets.items()})
        accepted = {j: float(sent[f"{j}.pos"]) for j in targets}
        self.max_clamped = max(
            [self.max_clamped] + [abs(accepted[j] - targets[j]) for j in targets]
        )
        return accepted

    def measure(self) -> dict[str, float]:
        state = self.follower.get_observation()
        return {j: float(state[f"{j}.pos"]) for j in self.joints}

    def summarize(self, report: Report) -> None:
        report.check(
            self.max_clamped < 1e-6,
            f"max_relative_target={self.clamp:g} never engaged; every step went out as requested",
            f"max_relative_target={self.clamp:g} clamped a step by up to "
            f"{self.max_clamped:.4f} rad. Not a fault -- lower --amplitude or --fps, or raise "
            f"--clamp, to command the full swing",
        )
        report.check(
            self.max_tracking_error < 0.2,
            f"The robot followed the setpoint to within {self.max_tracking_error:.4f} rad",
            f"Tracking error reached {self.max_tracking_error:.4f} rad against a direct position "
            f"command. The joint is lagging badly or resisting -- check for a fault or a load",
        )

    def close(self) -> None:
        self.follower.disconnect()


class OmniteleopDriver:
    """robot_controller.py executes; this script only publishes onto its input topic."""

    label = f"omniteleop ('{COMMANDS_TOPIC}' -> robot_controller.py)"

    def __init__(self, component: str, joints: list[str], namespace: str, timeout: float) -> None:
        self.component = component
        self.joints = joints
        self.namespace = namespace
        self.timeout = timeout
        self.node: Any | None = None
        self.publisher: Any | None = None
        # Written from a zenoh callback thread, read by measure().
        self._lock = threading.Lock()
        self._joints: dict[str, list[float]] = {}
        self.max_tracking_error = 0.0

    def connect(self) -> None:
        from dexcomm import Node
        from dexcomm.codecs import DictDataCodec

        self.node = Node(name="lerobot_vega_motion_check", namespace=self.namespace)
        self.node.create_subscriber(
            JOINTS_TOPIC, callback=self._on_joints, decoder=DictDataCodec.decode
        )
        self.publisher = self.node.create_publisher(COMMANDS_TOPIC, encoder=DictDataCodec.encode)

        deadline = time.monotonic() + self.timeout
        while self._latest() is None:
            if time.monotonic() >= deadline:
                raise TimeoutError(
                    f"No '{self.component}' data on '{JOINTS_TOPIC}' within {self.timeout:g}s. "
                    f"robot_controller.py publishes it once connected to the robot -- check it "
                    f"is running and that ROBOT_NAME matches."
                )
            time.sleep(0.05)

        measured = self._latest()
        assert measured is not None
        if len(measured) != len(self.joints):
            raise ValueError(
                f"'{JOINTS_TOPIC}' reports {len(measured)} values for '{self.component}' but "
                f"VEGA_JOINTS declares {len(self.joints)} ({self.joints}). The omniteleop "
                f"ROBOT_CONFIG and this lerobot describe different hardware."
            )

    def _on_joints(self, data: dict[str, Any]) -> None:
        joints = data.get("joints")
        if isinstance(joints, dict):
            with self._lock:
                self._joints = joints

    def _latest(self) -> list[float] | None:
        with self._lock:
            return self._joints.get(self.component)

    def send(self, targets: dict[str, float]) -> dict[str, float]:
        assert self.publisher is not None
        # The whole component vector goes out every step: robot_controller applies the pos
        # array it is handed, so a short array would be interpreted positionally.
        self.publisher.publish(
            {
                "timestamp_ns": time.time_ns(),
                "components": {self.component: {"pos": [targets[j] for j in self.joints]}},
                "safety_flags": {"emergency_stop": False, "exit_requested": False},
            }
        )
        return dict(targets)

    def measure(self) -> dict[str, float]:
        measured = self._latest()
        if measured is None:
            return {}
        return {j: float(v) for j, v in zip(self.joints, measured)}

    def summarize(self, report: Report) -> None:
        report.check(
            self.max_tracking_error < 0.5,
            f"robot_controller tracked the command to within {self.max_tracking_error:.4f} rad",
            f"Tracking error reached {self.max_tracking_error:.4f} rad. The controller is "
            f"interpolating, so some lag is expected, but this much suggests it rejected or "
            f"heavily reshaped the command -- check its window for safety-validator output",
        )

    def close(self) -> None:
        # The dexcomm session is process-local; dropping our references is enough, and the
        # node must not be torn down in a way that disturbs robot_controller's own session.
        self.publisher = None
        self.node = None


def preflight(via: str) -> str | None:
    """Reject a process layout that would put two writers on the hardware."""
    controller = processes_running(r"robot_controller\.py")
    processor = processes_running(r"command_processor\.py")

    if via == "lerobot":
        if controller:
            return (
                f"robot_controller.py is running (pid {controller}) and drives the robot at "
                f"100 Hz. LeRobot commanding the same joints would give the hardware two "
                f"writers. Stop the teleop stack first:\n"
                f"    ./scripts/launch_exo_teleop.sh stop"
            )
        return None

    if not controller:
        return (
            "robot_controller.py is not running, so nothing would execute the published "
            "commands. Start the teleop stack first:\n"
            "    ./scripts/launch_exo_teleop.sh"
        )
    if processor:
        return (
            f"command_processor.py is running (pid {processor}). It publishes the same "
            f"'{COMMANDS_TOPIC}' topic this check does, so the robot would alternate between "
            f"the exoskeleton's targets and this script's. Stop that one process:\n"
            f"    pkill -f command_processor.py"
        )
    return None


def return_to_start(
    driver: LeRobotDriver | OmniteleopDriver,
    start: dict[str, float],
    moving: list[str],
    from_offset: float,
    fps: float,
) -> None:
    """Ramp the displacement back to zero so an interrupted run still parks at the start."""
    steps = max(int(RETURN_S * fps), 1)
    try:
        for i in range(1, steps + 1):
            loop_start = time.perf_counter()
            offset = from_offset * (1.0 - i / steps)
            driver.send({j: start[j] + (offset if j in moving else 0.0) for j in start})
            pace(loop_start, 1.0 / fps)
    except KeyboardInterrupt:
        print(
            f"\nInterrupted while returning to the start pose. The joint is left "
            f"{abs(from_offset):.3f} rad from where it began -- move it back before recording."
        )


def main() -> int:
    args = parse_args()
    joints, moving = resolve_joints(args.component, args.joint, args.all_joints)
    trajectory = build_trajectory(args.amplitude, args.period, args.cycles, args.fps)

    print(f"Path      : {args.via}")
    print(f"Component : {args.component}  ({len(joints)} joints)")
    print(f"Moving    : {', '.join(moving)}")
    print(
        f"Motion    : {args.amplitude:+.3f} rad peak, {args.period:g}s per cycle, "
        f"{args.cycles:g} cycles, {args.fps:g} Hz  ({len(trajectory)} commands, "
        f"{trajectory[-1][0]:.1f}s)"
    )

    # Ahead of --dry-run: an amplitude this check will not execute should be rejected when
    # the operator first asks about it, not after they have read the trajectory and re-run.
    if args.amplitude > MAX_UNFORCED_AMPLITUDE and not args.force:
        print(
            f"\nRefusing --amplitude {args.amplitude:g}: above the {MAX_UNFORCED_AMPLITUDE:g} rad "
            f"ceiling this check enforces. Pass --force if you have confirmed the joint has room.",
            file=sys.stderr,
        )
        return 1

    if args.dry_run:
        print("\nTrajectory (dry run, nothing is sent)")
        print(f"  {'t (s)':>7}  {'offset (rad)':>13}")
        for t, offset in trajectory:
            print(f"  {t:>7.2f}  {offset:>+13.4f}")
        return 0

    if problem := preflight(args.via):
        print(f"\nPreflight failed.\n{problem}", file=sys.stderr)
        return 1

    if not confirm(
        f"\nThis will move {args.component} joint(s) {', '.join(moving)} by up to "
        f"{args.amplitude:+.3f} rad. Keep a hand on the e-stop.",
        args.yes,
    ):
        print("Aborted.")
        return 1

    load_module_env()
    report = Report(f"motion via {args.via}")

    if args.via == "lerobot":
        driver: LeRobotDriver | OmniteleopDriver = LeRobotDriver(args.component, joints, args.clamp)
    else:
        driver = OmniteleopDriver(args.component, joints, args.namespace, args.timeout)

    print(f"\nConnecting: {driver.label}")
    driver.connect()

    try:
        start = driver.measure()
        if not start:
            print("No joint feedback available to read the start pose.", file=sys.stderr)
            return 1
        print("\nStart pose")
        for j in joints:
            mark = " <- moving" if j in moving else ""
            print(f"  {j:<12} {start[j]:+.4f}{mark}")

        period = 1.0 / args.fps
        travel = dict.fromkeys(joints, 0.0)
        overruns = 0
        last_offset = 0.0

        print(f"\nRunning {len(trajectory)} commands...")
        try:
            for _, offset in trajectory:
                loop_start = time.perf_counter()
                last_offset = offset

                targets = {j: start[j] + (offset if j in moving else 0.0) for j in joints}
                accepted = driver.send(targets)
                measured = driver.measure()

                for j, value in measured.items():
                    travel[j] = max(travel[j], abs(value - start[j]))
                    if j in accepted:
                        driver.max_tracking_error = max(
                            driver.max_tracking_error, abs(value - accepted[j])
                        )

                if pace(loop_start, period) > 0:
                    overruns += 1
        except KeyboardInterrupt:
            print("\nInterrupted. Returning to the start pose...")
        finally:
            return_to_start(driver, start, moving, last_offset, args.fps)

        print("\nTravel (max displacement from the start pose)")
        for j in joints:
            mark = " <- moving" if j in moving else ""
            print(f"  {j:<12} {travel[j]:.4f} rad{mark}")

        moved = max(travel[j] for j in moving)
        report.check(
            moved > args.amplitude * 0.25,
            f"The commanded joint(s) moved {moved:.4f} rad, against {args.amplitude:.4f} commanded",
            f"The commanded joint(s) moved only {moved:.4f} rad against {args.amplitude:.4f} "
            f"commanded. The command path is not reaching the hardware -- check the e-stop, "
            f"and that this component is enabled and not in an idle or fault state",
        )

        still = [j for j in joints if j not in moving and travel[j] > args.amplitude * 0.5]
        report.check(
            not still,
            "No unaddressed joint of the component moved",
            f"Joints that should have held still moved instead: {still}. The joint ordering "
            f"in VEGA_JOINTS likely disagrees with the hardware",
        )

        report.check(
            overruns < len(trajectory) * 0.2,
            f"Held {args.fps:g} Hz ({overruns} of {len(trajectory)} steps ran long)",
            f"{overruns} of {len(trajectory)} steps overran the {args.fps:g} Hz budget; the "
            f"commanded profile was slower than requested",
        )

        driver.summarize(report)
        return report.finish()
    finally:
        driver.close()


if __name__ == "__main__":
    sys.exit(main())
