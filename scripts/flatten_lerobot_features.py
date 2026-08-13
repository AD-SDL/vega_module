#!/usr/bin/env python
"""Flatten dexdata-exported LeRobot datasets into policy-trainable form.

The dexdata exporter (`dexdata.exporters.lerobot`) writes one column per robot
group, e.g. `observation.state.left_arm.abs_qpos` / `action.right_hand.abs_qpos`.
LeRobot policies (ACT, diffusion, pi0, ...) instead require exactly two flat
vectors named `observation.state` and `action` -- `PreTrainedConfig.action_feature`
matches the key `action` exactly, so a split dataset yields `action_feature=None`
and the policy fails to build.

This script concatenates the per-group columns into those two vectors, drops the
split columns, and recomputes normalization stats.

Usage:
    python scripts/flatten_lerobot_features.py \
        --repo-id=acleary/vega_1_p \
        --output-repo-id=acleary/vega_1_p_flat
"""

from __future__ import annotations

import argparse
import logging
from pathlib import Path

import numpy as np
import pandas as pd
from lerobot.datasets.dataset_tools import modify_features, recompute_stats
from lerobot.datasets.lerobot_dataset import LeRobotDataset

# Groups concatenated into `observation.state` / `action`, in this order. Both
# vectors use the same joint layout so relative-action tricks stay meaningful.
POSITION_GROUPS = [
    ("left_arm.abs_qpos", 7),
    ("right_arm.abs_qpos", 7),
    ("left_hand.abs_qpos", 6),
    ("right_hand.abs_qpos", 6),
    ("head.abs_qpos", 3),
    ("torso.abs_qpos", 3),
]

# State-only extras, appended after the position groups when enabled.
QVEL_GROUPS = [("left_arm.qvel", 7), ("right_arm.qvel", 7)]
WRENCH_GROUPS = [
    ("left_wrist_wrench.force", 3),
    ("left_wrist_wrench.torque", 3),
    ("right_wrist_wrench.force", 3),
    ("right_wrist_wrench.torque", 3),
]


def resolve_groups(features: dict, prefix: str, groups: list[tuple[str, int]]) -> list[str]:
    """Return the dataset keys for `groups`, erroring on missing/mis-shaped ones."""
    keys = []
    for suffix, expected_dim in groups:
        key = f"{prefix}.{suffix}"
        if key not in features:
            raise KeyError(f"{key} not found in dataset features")
        shape = tuple(features[key]["shape"])
        if shape != (expected_dim,):
            raise ValueError(f"{key} has shape {shape}, expected ({expected_dim},)")
        keys.append(key)
    return keys


def concat_columns(dataset: LeRobotDataset, keys: list[str]) -> np.ndarray:
    """Build the (total_frames, dim) concatenation of `keys` over the whole dataset.

    `modify_features` drops the removed columns before evaluating any add-feature
    callback, so the values have to be materialized up front. Frames are ordered by
    the same sorted parquet glob that `modify_features` walks, which is the order it
    slices these arrays with.
    """
    parquet_files = sorted((dataset.root / "data").glob("*/*.parquet"))
    if not parquet_files:
        raise FileNotFoundError(f"No parquet files under {dataset.root / 'data'}")

    per_file = []
    for path in parquet_files:
        df = pd.read_parquet(path, columns=keys)
        per_file.append(
            np.concatenate(
                [np.stack(df[k].to_numpy()).astype(np.float32).reshape(len(df), -1) for k in keys],
                axis=1,
            )
        )
    return np.concatenate(per_file, axis=0)


def feature_info(keys: list[str], features: dict) -> dict:
    names = []
    for key in keys:
        group = key.split(".", 1)[1] if key.startswith("action") else key.split(".", 2)[2]
        names.extend(f"{group}.{i}" for i in range(features[key]["shape"][0]))
    return {"dtype": "float32", "shape": [len(names)], "names": names}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo-id", required=True, help="Source dataset repo id.")
    parser.add_argument("--root", default=None, help="Source dataset root (defaults to the lerobot cache).")
    parser.add_argument("--output-repo-id", default=None, help="Defaults to <repo-id>_flat.")
    parser.add_argument("--output-dir", default=None, help="Defaults to $HF_LEROBOT_HOME/<output-repo-id>.")
    parser.add_argument("--include-qvel", action="store_true", help="Append arm velocities to the state.")
    parser.add_argument("--include-wrench", action="store_true", help="Append wrist wrenches to the state.")
    args = parser.parse_args()

    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")

    dataset = LeRobotDataset(args.repo_id, root=args.root)
    features = dataset.meta.features

    state_groups = list(POSITION_GROUPS)
    if args.include_qvel:
        state_groups += QVEL_GROUPS
    if args.include_wrench:
        state_groups += WRENCH_GROUPS

    state_keys = resolve_groups(features, "observation.state", state_groups)
    action_keys = resolve_groups(features, "action", POSITION_GROUPS)

    state_info = feature_info(state_keys, features)
    action_info = feature_info(action_keys, features)
    logging.info("observation.state <- %s (dim %d)", state_keys, state_info["shape"][0])
    logging.info("action <- %s (dim %d)", action_keys, action_info["shape"][0])

    # Every split column goes away, including the state extras left out above --
    # leftovers would be picked up as additional STATE/ACTION policy features.
    split_keys = [
        key
        for key in features
        if key.startswith(("observation.state.", "action."))
    ]

    output_repo_id = args.output_repo_id or f"{args.repo_id}_flat"
    output_dir = Path(args.output_dir) if args.output_dir else None

    flat = modify_features(
        dataset,
        add_features={
            "observation.state": (concat_columns(dataset, state_keys), state_info),
            "action": (concat_columns(dataset, action_keys), action_info),
        },
        remove_features=split_keys,
        output_dir=output_dir,
        repo_id=output_repo_id,
    )

    recompute_stats(flat)
    logging.info("Wrote flattened dataset to %s", flat.root)
    logging.info("Train with: lerobot-train --dataset.repo_id=%s ...", output_repo_id)


if __name__ == "__main__":
    main()
