"""Shared helpers for the `check_lerobot_*.py` bring-up checks.

Imported as a plain sibling module (`from _vega_checks import ...`), which works because
Python puts a script's own directory on `sys.path`. Nothing here imports lerobot, dexcomm
or dexcontrol, so `--help` and `--dry-run` stay usable off the robot.
"""

from __future__ import annotations

import os
import subprocess
import time
from collections.abc import Iterable
from pathlib import Path
from typing import Any

import numpy as np

MODULE_ROOT = Path(__file__).resolve().parent.parent


def load_module_env(path: Path | None = None) -> None:
    """Read `../.env` into the environment without overriding variables already set.

    Same precedence the launch scripts use, so running a check by hand behaves like
    running it from `launch_exo_lerobot.sh`.
    """
    env_file = path or MODULE_ROOT / ".env"
    if not env_file.is_file():
        return
    for raw in env_file.read_text().splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        os.environ.setdefault(key.strip(), value.strip())


def processes_running(pattern: str) -> list[int]:
    """PIDs whose full command line matches `pattern`, as `pgrep -f` reports them.

    Our own PID is filtered out: a check invoked with the pattern in its argv would
    otherwise find itself.
    """
    result = subprocess.run(["pgrep", "-f", pattern], capture_output=True, text=True, check=False)
    return [pid for pid in (int(p) for p in result.stdout.split()) if pid != os.getpid()]


def pace(loop_start: float, period: float) -> float:
    """Sleep out the rest of a fixed-rate iteration; returns the overrun in seconds."""
    remaining = period - (time.perf_counter() - loop_start)
    if remaining > 0:
        time.sleep(remaining)
        return 0.0
    return -remaining


def confirm(prompt: str, assume_yes: bool = False) -> bool:
    """Require the operator to type 'yes'. `assume_yes` prints the prompt and proceeds."""
    if assume_yes:
        print(f"{prompt} [--yes]")
        return True
    try:
        return input(f"{prompt}\nType 'yes' to continue: ").strip().lower() == "yes"
    except EOFError:
        return False


def describe_value(value: Any) -> str:
    """One-line rendering of an observation value for the summary tables."""
    if isinstance(value, np.ndarray):
        return f"{value.dtype} {tuple(value.shape)}"
    if isinstance(value, (list, tuple)):
        return f"{type(value).__name__}[{len(value)}]"
    if isinstance(value, float):
        return f"{value:+.4f}"
    return repr(value)


def key_diff(actual: Iterable[str], expected: Iterable[str]) -> str:
    """How two key sets differ, phrased for an error line."""
    actual_set, expected_set = set(actual), set(expected)
    parts = []
    if extra := sorted(actual_set - expected_set):
        parts.append(f"unexpected {extra}")
    if missing := sorted(expected_set - actual_set):
        parts.append(f"missing {missing}")
    return "; ".join(parts) or "same keys but different order"


class RateMeter:
    """Counts ticks and reports the rate over the interval it has been running."""

    def __init__(self) -> None:
        self._start = time.monotonic()
        self.count = 0

    def tick(self) -> None:
        self.count += 1

    @property
    def elapsed(self) -> float:
        return max(time.monotonic() - self._start, 1e-9)

    @property
    def hz(self) -> float:
        return self.count / self.elapsed


class Report:
    """Collects pass/fail lines so every check prints and exits the same way."""

    def __init__(self, title: str) -> None:
        self.title = title
        self._lines: list[tuple[bool, str]] = []

    def ok(self, message: str) -> None:
        self._lines.append((True, message))

    def fail(self, message: str) -> None:
        self._lines.append((False, message))

    def check(self, condition: bool, passed: str, failed: str) -> bool:
        self._lines.append((bool(condition), passed if condition else failed))
        return bool(condition)

    @property
    def failures(self) -> int:
        return sum(1 for passed, _ in self._lines if not passed)

    def finish(self) -> int:
        """Print the collected lines and return the process exit code."""
        print(f"\n=== {self.title} ===")
        for passed, message in self._lines:
            print(f"  {'PASS' if passed else 'FAIL'}  {message}")
        if self.failures:
            print(f"\n{self.failures} of {len(self._lines)} checks failed.")
            return 1
        print(f"\nAll {len(self._lines)} checks passed.")
        return 0
