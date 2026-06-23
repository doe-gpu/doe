#!/usr/bin/env python3
"""Validate browser claim policy semantics."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any


try:
    from bench.tools._repo_import import ensure_repo_root
except ModuleNotFoundError:
    from _repo_import import ensure_repo_root

REPO_ROOT = ensure_repo_root(__file__)
from bench.lib.bench_utils import load_json_object as load_json


VALID_MODES = {"local", "release"}
VALID_PERCENTILES = {"p50Percent", "p95Percent", "p99Percent"}
REQUIRED_MODES = ["dawn", "doe"]
REQUIRED_CLAIM_SCOPE = "l1_strict_candidate"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--policy", required=True, help="Browser claim policy JSON.")
    parser.add_argument("--json", action="store_true", dest="emit_json")
    return parser.parse_args()


def failure(code: str, path: str, message: str) -> dict[str, str]:
    return {"code": code, "path": path, "message": message}


def check_policy(payload: dict[str, Any]) -> list[dict[str, str]]:
    failures: list[dict[str, str]] = []
    mode = payload.get("mode")
    if payload.get("schemaVersion") != 1:
        failures.append(
            failure("invalid_schema_version", "schemaVersion", "schemaVersion must be 1")
        )
    if mode not in VALID_MODES:
        failures.append(
            failure("invalid_mode", "mode", "mode must be local or release")
        )

    min_windows = payload.get("minWindows")
    if not isinstance(min_windows, int) or min_windows <= 0:
        failures.append(
            failure("invalid_min_windows", "minWindows", "minWindows must be > 0")
        )

    percentiles = payload.get("requiredPositivePercentiles")
    if not isinstance(percentiles, list) or not percentiles:
        failures.append(
            failure(
                "missing_required_percentiles",
                "requiredPositivePercentiles",
                "requiredPositivePercentiles must be non-empty",
            )
        )
    else:
        percentile_set = set(percentiles)
        invalid = sorted(percentile_set - VALID_PERCENTILES)
        for item in invalid:
            failures.append(
                failure(
                    "invalid_required_percentile",
                    "requiredPositivePercentiles",
                    f"invalid percentile {item}",
                )
            )
        for item in ("p50Percent", "p95Percent"):
            if item not in percentile_set:
                failures.append(
                    failure(
                        "missing_required_percentile",
                        "requiredPositivePercentiles",
                        f"missing required percentile {item}",
                    )
                )
        if mode == "release" and "p99Percent" not in percentile_set:
            failures.append(
                failure(
                    "release_missing_p99",
                    "requiredPositivePercentiles",
                    "release browser claim policy must require p99Percent",
                )
            )

    require_modes = payload.get("requireModes")
    if not isinstance(require_modes, list) or sorted(require_modes) != REQUIRED_MODES:
        failures.append(
            failure(
                "invalid_require_modes",
                "requireModes",
                "requireModes must be exactly dawn and doe",
            )
        )

    require_claim_scopes = payload.get("requireClaimScopes")
    if (
        not isinstance(require_claim_scopes, list)
        or REQUIRED_CLAIM_SCOPE not in require_claim_scopes
    ):
        failures.append(
            failure(
                "missing_claim_scope",
                "requireClaimScopes",
                f"requireClaimScopes must include {REQUIRED_CLAIM_SCOPE}",
            )
        )

    expected_rows = payload.get("expectedStrictCandidateRows")
    if not isinstance(expected_rows, int) or expected_rows <= 0:
        failures.append(
            failure(
                "invalid_expected_rows",
                "expectedStrictCandidateRows",
                "expectedStrictCandidateRows must be > 0",
            )
        )

    required_true_fields = (
        "promotionApprovalsRequired",
        "requireStrictRun",
        "requireHeadless",
    )
    for field in required_true_fields:
        if payload.get(field) is not True:
            failures.append(
                failure(
                    "required_policy_flag_disabled",
                    field,
                    f"{field} must be true",
                )
            )

    if payload.get("allowDataUrlFallback") is not False:
        failures.append(
            failure(
                "data_url_fallback_allowed",
                "allowDataUrlFallback",
                "data URL fallback must be disabled",
            )
        )

    max_flake = payload.get("maxFlakePercent")
    if not isinstance(max_flake, (int, float)) or max_flake < 0 or max_flake > 100:
        failures.append(
            failure(
                "invalid_max_flake_percent",
                "maxFlakePercent",
                "maxFlakePercent must be between 0 and 100",
            )
        )

    promoted_at = payload.get("promotedAt")
    if not isinstance(promoted_at, str) or not promoted_at.strip():
        failures.append(
            failure("missing_promoted_at", "promotedAt", "promotedAt must be non-empty")
        )

    return failures


def main() -> int:
    args = parse_args()
    policy_path = Path(args.policy)
    failures = check_policy(load_json(policy_path))
    report = {
        "schemaVersion": 1,
        "artifactKind": "browser_claim_policy_check",
        "policyPath": str(policy_path),
        "status": "fail" if failures else "pass",
        "failures": failures,
    }
    if args.emit_json:
        print(json.dumps(report, indent=2))
    elif failures:
        print("FAIL: browser claim policy")
        for item in failures:
            print(f"- {item['code']}: {item['path']}: {item['message']}")
    else:
        print("PASS: browser claim policy")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
