#!/usr/bin/env python3
"""Read-only JoyCon button/stick probe: raw published exo/joycon state (subscribe-only).

Run on mj (joycon_reader runs on mj even when the rest of the stack is on the Jetson), to
diagnose "why won't the gripper move" upstream of all mode logic.

    source scripts/connect.sh remote
    python scripts/probes/joycon_probe.py

See .docs/SCRIPTS.md for what each column tells you.
"""

import sys
import time
from typing import Optional

import tyro
from dexcomm import Node
from dexcomm.codecs import DictDataCodec
from omniteleop.common import get_config

# Button key order per side, matching joycon_reader's published dict.
L_BTNS = ["up", "down", "left", "right", "l", "zl", "minus", "capture", "stick"]
R_BTNS = ["a", "b", "x", "y", "r", "zr", "plus", "home", "stick"]


def main(
    topic: Optional[str] = None,
    rate: float = 10.0,
    stale_after: float = 0.5,
) -> int:
    """Print live JoyCon button/stick state.

    Args:
        topic: Override the exo_joycon topic (defaults to config value).
        rate: Print rate in Hz.
        stale_after: Flag the line STALE if the last message is older than this
            many seconds (joycon_reader publishes at input_rate, ~20-40 Hz).
    """
    config = get_config()
    topic = topic or config.get_topic("exo_joycon")

    latest = {"d": None, "t": 0.0}

    def _cb(data: dict) -> None:
        latest["d"] = data
        latest["t"] = time.monotonic()

    node = Node(name="joycon_probe", namespace="")
    node.create_subscriber(topic, callback=_cb, decoder=DictDataCodec.decode)
    resolved = node.resolve_topic(topic)
    print(f"[joycon_probe] subscribed to '{resolved}' (subscribe-only).")
    print("[joycon_probe] press LEFT/RIGHT buttons, move sticks. Ctrl-C to stop.\n")

    try:
        while True:
            d = latest["d"]
            age = time.monotonic() - latest["t"] if latest["t"] else 999.0
            if d is None:
                print(f"<no msg yet> (waiting on '{resolved}')")
            else:
                lb = d.get("left", {}).get("buttons", {}) or {}
                rb = d.get("right", {}).get("buttons", {}) or {}
                ls = d.get("left", {}).get("stick", {}) or {}
                rs = d.get("right", {}).get("stick", {}) or {}
                lp = [k for k in L_BTNS if lb.get(k)]
                rp = [k for k in R_BTNS if rb.get(k)]
                lp_s = ",".join(lp) if lp else "-"
                rp_s = ",".join(rp) if rp else "-"
                stale = f"   <-- STALE ({age * 1000:.0f}ms)" if age > stale_after else ""
                print(
                    f"L[{lp_s:<28}] stick({ls.get('x', 0.0):+.2f},{ls.get('y', 0.0):+.2f})  "
                    f"R[{rp_s:<20}] stick({rs.get('x', 0.0):+.2f},{rs.get('y', 0.0):+.2f})"
                    f"{stale}"
                )
            time.sleep(1.0 / rate if rate > 0 else 0.1)
    except KeyboardInterrupt:
        print("\n[joycon_probe] stopped.")
    finally:
        node.shutdown()
    return 0


if __name__ == "__main__":
    sys.exit(tyro.cli(main))
