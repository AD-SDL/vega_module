#!/usr/bin/env python3
"""Read-only teleop latency probe: per-topic rate, jitter, and message age (subscribe-only).

Run on the Jetson (source connect.sh local) and from mj (source connect.sh remote) to
A/B the on-robot win. Cross-machine exo_joycon age includes clock skew -> --skew-ns
(from clock_skew.sh); robot/safe_commands is skew-free only on the Jetson. Drive the exo
(e-stop released) while it runs.

    python scripts/probes/latency_probe.py --duration 30

See .docs/SCRIPTS.md.
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

    ages_ms: List[float] = field(default_factory=list)  # now - timestamp_ns
    gaps_ms: List[float] = field(default_factory=list)  # inter-arrival on the wire
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
        skew_ns: clock offset (publisher - this host) in ns, subtracted from the
            exo_joycon age; from clock_skew.sh. Only affects exo_joycon.
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
