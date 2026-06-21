#!/usr/bin/env python3
"""Validate browser ownership assignments."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any


REPO_ROOT = Path(__file__).resolve().parents[2]
BENCH_ROOT = REPO_ROOT / "bench"
for _path_entry in (str(REPO_ROOT), str(BENCH_ROOT)):
    if _path_entry not in sys.path:
        sys.path.insert(0, _path_entry)

from bench.lib.bench_utils import load_json_object as load_json


REQUIRED_AREAS = {
    "browser_runtime_integration",
    "browser_compatibility",
    "browser_performance_methodology",
}
REQUIRED_TEXT_FIELDS = (
    "runtimeIntegrationOwner",
    "qualityOwner",
    "benchmarkMethodologyOwner",
    "promotedAt",
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--ownership", required=True, help="Browser ownership JSON.")
    parser.add_argument("--json", action="store_true", dest="emit_json")
    return parser.parse_args()


def failure(code: str, path: str, message: str) -> dict[str, str]:
    return {"code": code, "path": path, "message": message}


def _text(value: Any) -> str:
    return value.strip() if isinstance(value, str) else ""


def check_ownership(payload: dict[str, Any]) -> list[dict[str, str]]:
    failures: list[dict[str, str]] = []
    if payload.get("schemaVersion") != 1:
        failures.append(
            failure("invalid_schema_version", "schemaVersion", "schemaVersion must be 1")
        )

    areas = payload.get("areas")
    if not isinstance(areas, dict):
        return failures + [
            failure("missing_areas", "areas", "areas must be an object")
        ]

    for area in sorted(REQUIRED_AREAS):
        row = areas.get(area)
        if not isinstance(row, dict):
            failures.append(
                failure("missing_area", f"areas.{area}", f"missing area {area}")
            )
            continue
        for field in REQUIRED_TEXT_FIELDS:
            if not _text(row.get(field)):
                failures.append(
                    failure(
                        "missing_ownership_field",
                        f"areas.{area}.{field}",
                        f"{area} requires non-empty {field}",
                    )
                )
        if row.get("nurseryExitApproved") is not True:
            failures.append(
                failure(
                    "nursery_exit_not_approved",
                    f"areas.{area}.nurseryExitApproved",
                    f"{area} nurseryExitApproved must be true",
                )
            )

    return failures


def main() -> int:
    args = parse_args()
    ownership_path = Path(args.ownership)
    failures = check_ownership(load_json(ownership_path))
    report = {
        "schemaVersion": 1,
        "artifactKind": "browser_ownership_check",
        "ownershipPath": str(ownership_path),
        "status": "fail" if failures else "pass",
        "failures": failures,
    }
    if args.emit_json:
        print(json.dumps(report, indent=2))
    elif failures:
        print("FAIL: browser ownership")
        for item in failures:
            print(f"- {item['code']}: {item['path']}: {item['message']}")
    else:
        print("PASS: browser ownership")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
