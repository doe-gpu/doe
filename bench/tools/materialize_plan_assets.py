#!/usr/bin/env python3
"""Warm deterministic synthetic benchmark assets for plan-backed workloads."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path


try:
    from bench.tools._repo_import import ensure_repo_root
except ModuleNotFoundError:
    from _repo_import import ensure_repo_root

REPO_ROOT = ensure_repo_root(__file__)
from bench.lib import synthetic_assets


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--plan",
        action="append",
        required=True,
        help="Normalized plan path. Repeat for multiple plans.",
    )
    parser.add_argument(
        "--describe-only",
        action="store_true",
        help="Print asset descriptors without writing cache files.",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    plans = [Path(path) for path in args.plan]
    if args.describe_only:
        payload = {
            "schemaVersion": 1,
            "cacheRoot": str(synthetic_assets.resolve_cache_root()),
            "plans": [
                {
                    "planPath": str(plan),
                    "assets": synthetic_assets.describe_plan_assets(plan),
                }
                for plan in plans
            ],
        }
        print(json.dumps(payload, indent=2))
        return 0

    warmed: list[dict[str, object]] = []
    for plan in plans:
        assets = synthetic_assets.ensure_plan_assets(plan)
        warmed.append(
            {
                "planPath": str(plan),
                "assetCount": len(assets),
            }
        )

    print(
        json.dumps(
            {
                "schemaVersion": 1,
                "cacheRoot": str(synthetic_assets.resolve_cache_root()),
                "plans": warmed,
            },
            indent=2,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
