#!/usr/bin/env python3
"""Read-only teleop latency probe for the Vega-1 Pro exo stack.

Subscribes (never publishes) to the two timestamped teleop topics and reports,
per topic: inter-arrival rate + jitter, and message age (now - timestamp_ns) as
median / p95 / max. Run it on the Jetson AND from mj (over the tunnel) to A/B
what moving the stack on-robot bought you.

    exo_joycon          joycon_reader (on mj) -> Zenoh.  Age measured here = transit
                        from mj + CLOCK SKEW between the two hosts (see --skew-ns).
    robot/safe_commands command_processor output.  When this probe runs ON the
                        Jetson, the stamp and the receipt share one clock, so the
                        age is a clean command-staleness number (no skew term).

Single-writer safe: subscribe-only. It cannot touch the control path.

Usage (on the Jetson, robot env sourced):
    source ~/humanoids/vega_module/scripts/jetson_connect.sh
    python ~/humanoids/vega_module/scripts/latency_probe.py --duration 30

Usage (from mj, tunnel up, for the A/B):
    source ~/humanoids/vega_module/scripts/lab_connect.sh
    python ~/humanoids/vega_module/scripts/latency_probe.py --duration 30

Drive the exo (release the e-stop) while it runs, or exo_joycon/safe_commands
stay idle and you measure nothing useful.
"""

import statistics
import sys
import time
from collections import defaultdict
from dataclasses import dataclass, field
from typing import Dict, List

import tyro

from dexcomm import Node
from dexcomm.codecs import DictDataCodec
from omniteleop.common import get_config


@dataclass
class Stats:
    """Per-topic rolling samples (ms)."""

    ages_ms: List[float] = field(default_factory=list)      # now - timestamp_ns
    gaps_ms: List[float] = field(default_factory=list)      # inter-arrival on the wire
    _last_recv_ns: int = 0

    def add(self, stamp_ns: int, recv_ns: int) -> None:
        self.ages_ms.append((recv_ns - stamp_ns) / 1e6)
        if self._last_recv_ns:
            self.gaps_ms.append((recv_ns - self._last_recv_ns) / 1e6)
        self._last_recv_ns = recv_ns


def _pct(xs: List[float], p: float) -> float:
    if not xs:
        return float("nan")
    s = sorted(xs)
    k = min(len(s) - 1, int(round(p / 100.0 * (len(s) - 1))))
    return s[k]


def _fmt(xs: List[float]) -> str:
    if not xs:
        return "no samples"
    return (
        f"n={len(xs):>5}  median={statistics.median(xs):7.2f}  "
        f"p95={_pct(xs, 95):7.2f}  max={max(xs):7.2f}  "
        f"mean={statistics.fmean(xs):7.2f}  stdev={statistics.pstdev(xs):6.2f}"
    )


def main(
    duration: float = 30.0,
    skew_ns: int = 0,
    exo_joycon_only: bool = False,
) -> None:
    """Measure teleop topic latency/jitter for `duration` seconds.

    Args:
        duration: seconds to collect before printing the report.
        skew_ns: clock offset (other_host - this_host) in ns, SUBTRACTED from the
            exo_joycon age so cross-machine transit isn't polluted by clock skew.
            Measure it with: on the Jetson `date +%s%N`, on mj `date +%s%N` run as
            close together as possible (or chrony/ntp offset); positive if the
            publisher's clock is ahead of this host's. Only affects exo_joycon.
        exo_joycon_only: skip the robot/safe_commands subscription.
    """
    config = get_config()
    topics = {"exo_joycon": config.get_topic("exo_joycon")}
    if not exo_joycon_only:
        topics["robot_commands"] = config.get_topic("robot_commands")

    node = Node(name="latency_probe")
    stats: Dict[str, Stats] = defaultdict(Stats)

    def make_cb(key: str):
        apply_skew = key == "exo_joycon"

        def _cb(data: Dict) -> None:
            recv_ns = time.time_ns()
            stamp_ns = data.get("timestamp_ns")
            if not isinstance(stamp_ns, int):
                return
            if apply_skew:
                stamp_ns += skew_ns
            stats[key].add(stamp_ns, recv_ns)

        return _cb

    for key, topic in topics.items():
        node.create_subscriber(
            topic,
            callback=make_cb(key),
            decoder=DictDataCodec.decode,
            buffer_size=50,
        )
        print(f"-> subscribed: {key:16s} <- {node.resolve_topic(topic)}", file=sys.stderr)

    print(
        f"-> collecting for {duration:.0f}s. DRIVE THE EXO now "
        "(e-stop released) so the topics are active.",
        file=sys.stderr,
    )
    node.spin_in_background()
    try:
        time.sleep(duration)
    except KeyboardInterrupt:
        print("\n-> interrupted; reporting what we have.", file=sys.stderr)
    finally:
        node.shutdown()

    print("\n" + "=" * 78)
    print(f"Latency report  (duration {duration:.0f}s, skew_ns={skew_ns})")
    print("=" * 78)
    for key in topics:
        st = stats[key]
        note = ""
        if key == "exo_joycon" and skew_ns == 0:
            note = "   [age includes mj<->this clock skew; set --skew-ns]"
        print(f"\n[{key}]{note}")
        print(f"  age  ms : {_fmt(st.ages_ms)}")
        print(f"  gap  ms : {_fmt(st.gaps_ms)}", end="")
        if st.gaps_ms:
            hz = 1000.0 / statistics.median(st.gaps_ms)
            print(f"   (~{hz:.1f} Hz)")
        else:
            print()
        if not st.ages_ms:
            print("  WARNING: no messages. Is the exo being driven / e-stop released?")
    print()


if __name__ == "__main__":
    tyro.cli(main)
