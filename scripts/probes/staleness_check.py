#!/usr/bin/env python3
"""Plain-language command-staleness check: age/wobble/rate of robot/safe_commands.

The subset of latency_probe.py with no skew math (stamp + receipt on one machine).
Run on the Jetson for an exact number; from mj it also carries the inter-machine clock
skew (use latency_probe.py --skew-ns for a corrected mj figure). Drive the exo (e-stop
released) while it runs. Subscribe-only.

    python scripts/probes/staleness_check.py

See .docs/SCRIPTS.md.
"""

import statistics
import sys
import time

import tyro
from dexcomm import Node
from dexcomm.codecs import DictDataCodec
from omniteleop.common import get_config


def main(duration: float = 30.0) -> None:
    """Collect command staleness for `duration` seconds, then print a report.

    Args:
        duration: seconds to listen before reporting.
    """
    topic = get_config().get_topic("robot_commands")  # robot/safe_commands

    ages_ms: list[float] = []   # age = now - command_timestamp
    gaps_ms: list[float] = []   # time between consecutive commands (-> rate)
    last_recv_ns = 0

    def _cb(data: dict) -> None:
        nonlocal last_recv_ns
        recv_ns = time.time_ns()
        stamp_ns = data.get("timestamp_ns")
        if not isinstance(stamp_ns, int):
            return
        ages_ms.append((recv_ns - stamp_ns) / 1e6)
        if last_recv_ns:
            gaps_ms.append((recv_ns - last_recv_ns) / 1e6)
        last_recv_ns = recv_ns

    node = Node(name="staleness_check")
    node.create_subscriber(topic, callback=_cb, decoder=DictDataCodec.decode, buffer_size=50)
    print(f"-> listening to {node.resolve_topic(topic)}", file=sys.stderr)
    print(f"-> collecting for {duration:.0f}s. DRIVE THE EXO now (e-stop released).",
          file=sys.stderr)

    node.spin_in_background()
    try:
        time.sleep(duration)
    except KeyboardInterrupt:
        print("\n-> interrupted; reporting what we have.", file=sys.stderr)
    finally:
        node.shutdown()

    print("\n" + "=" * 60)
    if not ages_ms:
        print("No commands seen. Is the exo being driven / e-stop released?")
        print("=" * 60)
        return

    typical = statistics.median(ages_ms)
    wobble = statistics.pstdev(ages_ms)
    worst = max(ages_ms)
    rate = 1000.0 / statistics.median(gaps_ms) if gaps_ms else float("nan")

    print("Command staleness  (how old a command is when the robot uses it)")
    print("=" * 60)
    print(f"   typical : {typical:7.2f} ms   <- the lag you feel")
    print(f"   wobble  : {wobble:7.2f} ms   <- how much it varies (lower = smoother)")
    print(f"   worst   : {worst:7.2f} ms   <- slowest command seen")
    print(f"   rate    : {rate:7.1f} Hz   <- how often commands arrive")
    print(f"   (from {len(ages_ms)} commands over {duration:.0f}s)")
    print("=" * 60)


if __name__ == "__main__":
    tyro.cli(main)
