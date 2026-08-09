"""Render useful views from the canonical Doe ecosystem registry."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from bench.lib.ecosystem_registry import (
    load_json_object,
    registry_rows,
    render_markdown,
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", default=str(REPO_ROOT))
    parser.add_argument("--registry", default="config/ecosystem-registry.json")
    parser.add_argument(
        "--policy", default="config/ecosystem-scoring-policy.json"
    )
    parser.add_argument("--format", choices=("markdown", "json"), default="markdown")
    parser.add_argument("--out", default="")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    root = Path(args.root).resolve()
    try:
        registry = load_json_object(root / args.registry)
        policy = load_json_object(root / args.policy)
        if args.format == "json":
            output = json.dumps(registry_rows(registry, policy), indent=2) + "\n"
        else:
            output = render_markdown(registry, policy)
    except (OSError, UnicodeError, json.JSONDecodeError, TypeError, ValueError) as exc:
        print(f"FAIL: ecosystem registry render error: {exc}")
        return 1

    if args.out:
        output_path = Path(args.out)
        output_path.parent.mkdir(parents=True, exist_ok=True)
        output_path.write_text(output, encoding="utf-8")
    else:
        print(output, end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
