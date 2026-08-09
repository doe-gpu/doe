#!/usr/bin/env python3
"""Block malformed or incoherently promoted ecosystem registry entries."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from bench.lib.ecosystem_registry import evaluate_registry, load_json_object


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", default=str(REPO_ROOT))
    parser.add_argument("--registry", default="config/ecosystem-registry.json")
    parser.add_argument(
        "--policy", default="config/ecosystem-scoring-policy.json"
    )
    parser.add_argument(
        "--promotion-policy",
        default="config/external-project-promotion-policy.json",
    )
    parser.add_argument("--claim-index", default="reports/claim-index.json")
    parser.add_argument("--json", action="store_true", dest="emit_json")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    root = Path(args.root).resolve()
    try:
        registry = load_json_object(root / args.registry)
        policy = load_json_object(root / args.policy)
        promotion_policy = load_json_object(root / args.promotion_policy)
        claim_index = load_json_object(root / args.claim_index)
        result = evaluate_registry(
            registry,
            policy,
            root,
            claim_index,
            promotion_policy,
        )
    except (OSError, UnicodeError, json.JSONDecodeError, ValueError) as exc:
        print(f"FAIL: ecosystem registry input error: {exc}")
        return 1

    if args.emit_json:
        print(json.dumps(result, indent=2, sort_keys=True))
    elif result["ok"]:
        print(
            "PASS: ecosystem registry "
            f"({result['summary']['actorCount']} actors)"
        )
    else:
        for item in result["failures"]:
            print(
                f"FAIL [{item['code']}] {item['path']}: {item['message']}"
            )
    return 0 if result["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
