#!/usr/bin/env python
"""Aggregate per-session LeRobot datasets into one big dataset.

Workflow this supports: record each teleop session to its own repo_id with a
common base and a session suffix, e.g.

    DATASET_REPO_ID=local/vega_exo_box_pickup_s01 ... ./launch_exo_lerobot.sh
    DATASET_REPO_ID=local/vega_exo_box_pickup_s02 ... ./launch_exo_lerobot.sh
    ...

then merge the good ones into a single trainable dataset:

    python scripts/aggregate_sessions.py --base local/vega_exo_box_pickup

By default it discovers every `<base>_*` dataset on disk (except the output
itself), prints a table of episode counts, and aggregates them into `<base>`.
`lerobot.datasets.aggregate.aggregate_datasets` validates that all sessions share
the same fps / robot_type / features, so a stray depth-on vs depth-off session
(or a hand-enabled one) fails loudly instead of corrupting the merge.

Run with the venv that has lerobot importable (the dexmate teleop venv):

    ~/venvs/dexmate/bin/python scripts/aggregate_sessions.py --base local/vega_exo_box_pickup --dry-run

Examples:
    # Preview what would be merged, newest naming scheme <base>_sNN
    aggregate_sessions.py --base local/vega_exo_box_pickup --dry-run

    # Merge specific sessions into an explicit output id
    aggregate_sessions.py --sessions local/box_s01 local/box_s03 --out local/box_all

    # Re-merge, replacing an existing output dataset
    aggregate_sessions.py --base local/vega_exo_box_pickup --force
"""

from __future__ import annotations

import argparse
import shutil
import sys
from pathlib import Path

from lerobot.utils.constants import HF_LEROBOT_HOME
from lerobot.datasets.aggregate import aggregate_datasets
from lerobot.datasets.dataset_metadata import LeRobotDatasetMetadata


def _dataset_dir(repo_id: str) -> Path:
    """Local on-disk directory for a repo_id (namespace/name)."""
    return HF_LEROBOT_HOME / repo_id


def _is_dataset(path: Path) -> bool:
    """A valid LeRobot dataset dir has meta/info.json."""
    return (path / "meta" / "info.json").is_file()


def discover_sessions(base: str, out: str) -> list[str]:
    """Find every `<base>_*` dataset on disk, excluding the output repo_id."""
    base_path = _dataset_dir(base)
    parent = base_path.parent  # HF_LEROBOT_HOME/<namespace>
    namespace = str(Path(base).parent)  # e.g. "local"
    found = []
    for child in sorted(parent.glob(f"{base_path.name}_*")):
        if not child.is_dir() or not _is_dataset(child):
            continue
        repo_id = f"{namespace}/{child.name}" if namespace != "." else child.name
        if repo_id == out:
            continue
        found.append(repo_id)
    return found


def describe(repo_id: str) -> tuple[int, float, str]:
    """Return (num_episodes, fps, robot_type) for a local dataset."""
    meta = LeRobotDatasetMetadata(repo_id)
    n = getattr(meta, "total_episodes", None)
    if n is None:
        n = getattr(meta, "num_episodes", -1)
    return int(n), float(getattr(meta, "fps", 0.0)), str(getattr(meta, "robot_type", "?"))


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--base", help="Common base repo_id; discovers <base>_* sessions (e.g. local/vega_exo_box_pickup).")
    ap.add_argument("--sessions", nargs="+", help="Explicit list of session repo_ids to merge (overrides --base discovery).")
    ap.add_argument("--out", help="Output repo_id for the merged dataset (default: --base).")
    ap.add_argument("--dry-run", action="store_true", help="List what would be merged and exit.")
    ap.add_argument("--force", action="store_true", help="Delete the output dataset first if it already exists.")
    args = ap.parse_args()

    if not args.base and not args.sessions:
        ap.error("give --base (to auto-discover <base>_* sessions) or --sessions")

    out = args.out or args.base
    if not out:
        ap.error("--out is required when using --sessions without --base")

    if args.sessions:
        sessions = args.sessions
    else:
        sessions = discover_sessions(args.base, out)

    if not sessions:
        print(f"No session datasets found to merge (looked for '{args.base}_*' under {HF_LEROBOT_HOME}).")
        return 1

    # Report what we found, and fail early on anything unreadable.
    print(f"Datasets root: {HF_LEROBOT_HOME}")
    print(f"Merging {len(sessions)} session(s) -> {out}\n")
    print(f"  {'repo_id':<45} {'episodes':>8}  {'fps':>5}  robot_type")
    print(f"  {'-'*45} {'-'*8}  {'-'*5}  {'-'*10}")
    total = 0
    problems = []
    for rid in sessions:
        try:
            n, fps, robot = describe(rid)
        except Exception as e:  # noqa: BLE001 - report and skip
            problems.append((rid, str(e)))
            print(f"  {rid:<45} {'ERROR':>8}  {'':>5}  {e}")
            continue
        total += n
        print(f"  {rid:<45} {n:>8}  {fps:>5.0f}  {robot}")
    print(f"  {'-'*45} {'-'*8}")
    print(f"  {'TOTAL':<45} {total:>8}\n")

    if problems:
        print("Refusing to merge: some datasets could not be read:")
        for rid, err in problems:
            print(f"  - {rid}: {err}")
        return 2

    out_path = _dataset_dir(out)
    if out_path.exists():
        if not args.force:
            print(f"Output '{out}' already exists at {out_path}.")
            print("Re-run with --force to replace it, or pass a different --out.")
            return 3
        if not args.dry_run:
            print(f"--force: removing existing output {out_path}")
            shutil.rmtree(out_path)

    if args.dry_run:
        print("Dry run - nothing written.")
        return 0

    aggregate_datasets(repo_ids=sessions, aggr_repo_id=out)

    n_out, fps_out, robot_out = describe(out)
    print(f"\nDone. '{out}' now has {n_out} episodes at {fps_out:.0f} fps ({robot_out}).")
    print(f"Location: {out_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
