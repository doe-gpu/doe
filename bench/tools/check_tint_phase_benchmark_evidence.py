#!/usr/bin/env python3
"""Check Tint benchmark-scope phase timing evidence."""

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

ensure_repo_root(__file__)


VALID_TARGETS = {"msl", "spirv", "dxil", "hlsl"}
REQUIRED_BENCHMARK_SCOPES = ("parseWgsl", "validateIr", "generateBackend")
DEFAULT_EXACT_PHASES = ("parse", "sema", "lower", "emit")
NON_EXACT_PHASES = {"total"}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--evidence", required=True, help="Tint compiler evidence report.")
    parser.add_argument(
        "--required-target",
        action="append",
        dest="required_targets",
        required=True,
        choices=sorted(VALID_TARGETS),
        help="Backend target that must have Tint benchmark-scope phase evidence.",
    )
    parser.add_argument("--out", default="", help="Optional output receipt path.")
    parser.add_argument("--json", action="store_true", dest="emit_json")
    return parser.parse_args()


def load_json(path: Path) -> dict[str, Any]:
    payload = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(payload, dict):
        raise ValueError(f"expected JSON object: {path}")
    return payload


def failure(code: str, path: str, message: str) -> dict[str, str]:
    return {"code": code, "path": path, "message": message}


def normalize_required_targets(required_targets: list[str]) -> tuple[list[str], list[dict[str, str]]]:
    normalized: list[str] = []
    failures: list[dict[str, str]] = []
    for index, target in enumerate(required_targets):
        if target not in VALID_TARGETS:
            failures.append(
                failure(
                    "invalid_required_target",
                    f"requiredTargets[{index}]",
                    f"unsupported backend target: {target}",
                )
            )
            continue
        if target not in normalized:
            normalized.append(target)
    if not normalized:
        failures.append(
            failure(
                "missing_required_targets",
                "requiredTargets",
                "at least one backend target is required",
            )
        )
    return normalized, failures


def positive_integer_mapping(value: Any) -> dict[str, int]:
    if not isinstance(value, dict):
        return {}
    timings: dict[str, int] = {}
    for key, item in value.items():
        if isinstance(key, str) and isinstance(item, int) and item > 0:
            timings[key] = item
    return timings


def required_exact_phases(evidence: dict[str, Any]) -> list[str]:
    phase_model = evidence.get("phaseModel")
    if not isinstance(phase_model, dict):
        return list(DEFAULT_EXACT_PHASES)
    phases = phase_model.get("requiredPhases")
    if not isinstance(phases, list):
        return list(DEFAULT_EXACT_PHASES)
    exact_phases = [
        phase
        for phase in phases
        if isinstance(phase, str) and phase and phase not in NON_EXACT_PHASES
    ]
    return exact_phases or list(DEFAULT_EXACT_PHASES)


def tint_status(result: Any) -> str:
    if not isinstance(result, dict):
        return "missing"
    status = result.get("status")
    if status in {"ok", "failed", "unsupported"}:
        return str(status)
    return "missing"


def check_row(
    *,
    row: dict[str, Any],
    row_index: int,
    exact_phases: list[str],
    failures: list[dict[str, str]],
) -> dict[str, Any]:
    row_path = f"rows[{row_index}]"
    shader_id = row.get("shaderId")
    if not isinstance(shader_id, str) or not shader_id:
        shader_id = row_path
    target = row.get("target")
    if not isinstance(target, str):
        target = ""

    tint = row.get("tint")
    status = tint_status(tint)
    if status != "ok":
        return {
            "shaderId": shader_id,
            "target": target,
            "tintStatus": status,
            "phaseBenchmarkStatus": "not_applicable",
            "exactPhaseStatus": "not_applicable",
            "phaseBenchmarkTimingsNs": {},
            "missingPhaseBenchmarkScopes": [],
            "missingExactPhases": [],
        }

    if not isinstance(tint, dict):
        tint = {}
    benchmark_timings = positive_integer_mapping(tint.get("phaseBenchmarkTimingsNs"))
    missing_scopes = [
        scope for scope in REQUIRED_BENCHMARK_SCOPES if scope not in benchmark_timings
    ]
    if missing_scopes:
        failures.append(
            failure(
                "phase_benchmark_scope_missing",
                f"{row_path}.tint.phaseBenchmarkTimingsNs",
                "Tint benchmark-scope timings missing or zero for: "
                + ", ".join(missing_scopes),
            )
        )

    exact_timings = positive_integer_mapping(tint.get("phaseTimingsNs"))
    missing_exact_phases = [
        phase for phase in exact_phases if phase not in exact_timings
    ]
    return {
        "shaderId": shader_id,
        "target": target,
        "tintStatus": status,
        "phaseBenchmarkStatus": "missing" if missing_scopes else "covered",
        "exactPhaseStatus": "missing" if missing_exact_phases else "complete",
        "phaseBenchmarkTimingsNs": {
            scope: benchmark_timings[scope]
            for scope in REQUIRED_BENCHMARK_SCOPES
            if scope in benchmark_timings
        },
        "missingPhaseBenchmarkScopes": missing_scopes,
        "missingExactPhases": missing_exact_phases,
    }


def build_report(
    *,
    evidence: dict[str, Any],
    evidence_path: str,
    required_targets: list[str],
) -> dict[str, Any]:
    targets, failures = normalize_required_targets(required_targets)
    if evidence.get("artifactKind") != "tint-compiler-evidence":
        failures.append(
            failure(
                "invalid_artifact_kind",
                "artifactKind",
                "artifactKind must be tint-compiler-evidence",
            )
        )

    rows = evidence.get("rows", [])
    if not isinstance(rows, list):
        failures.append(failure("invalid_rows", "rows", "rows must be an array"))
        rows = []

    exact_phases = required_exact_phases(evidence)
    checked_rows: list[dict[str, Any]] = []
    target_coverage: list[dict[str, Any]] = []
    for target in targets:
        matching_rows = [
            (index, row)
            for index, row in enumerate(rows)
            if isinstance(row, dict) and row.get("target") == target
        ]
        if not matching_rows:
            failures.append(
                failure(
                    "missing_required_target",
                    f"requiredTargets.{target}",
                    f"no compiler evidence rows found for target {target}",
                )
            )

        target_rows: list[dict[str, Any]] = []
        shader_ids: list[str] = []
        for index, row in matching_rows:
            shader_id = row.get("shaderId")
            if isinstance(shader_id, str) and shader_id:
                shader_ids.append(shader_id)
            checked = check_row(
                row=row,
                row_index=index,
                exact_phases=exact_phases,
                failures=failures,
            )
            target_rows.append(checked)
            checked_rows.append(checked)
        target_coverage.append(
            {
                "target": target,
                "rowCount": len(target_rows),
                "tintOkRows": sum(1 for row in target_rows if row["tintStatus"] == "ok"),
                "phaseBenchmarkCoveredRows": sum(
                    1 for row in target_rows if row["phaseBenchmarkStatus"] == "covered"
                ),
                "shaderIds": shader_ids,
            }
        )

    covered_targets = sum(1 for item in target_coverage if item["rowCount"] > 0)
    report = {
        "schemaVersion": 1,
        "artifactKind": "tint_phase_benchmark_evidence",
        "evidencePath": evidence_path,
        "requiredTargets": targets,
        "requiredBenchmarkScopes": list(REQUIRED_BENCHMARK_SCOPES),
        "requiredExactPhases": exact_phases,
        "status": "fail" if failures else "pass",
        "targetCoverage": target_coverage,
        "rows": checked_rows,
        "failures": failures,
        "summary": {
            "targetCount": len(targets),
            "coveredTargetCount": covered_targets,
            "rowCount": len(checked_rows),
            "tintOkRows": sum(1 for row in checked_rows if row["tintStatus"] == "ok"),
            "phaseBenchmarkCoveredRows": sum(
                1 for row in checked_rows if row["phaseBenchmarkStatus"] == "covered"
            ),
            "phaseBenchmarkMissingRows": sum(
                1 for row in checked_rows if row["phaseBenchmarkStatus"] == "missing"
            ),
            "exactPhaseCompleteRows": sum(
                1 for row in checked_rows if row["exactPhaseStatus"] == "complete"
            ),
            "exactPhaseMissingRows": sum(
                1 for row in checked_rows if row["exactPhaseStatus"] == "missing"
            ),
            "notApplicableRows": sum(
                1 for row in checked_rows if row["phaseBenchmarkStatus"] == "not_applicable"
            ),
            "failureCount": len(failures),
        },
    }
    return report


def main() -> int:
    args = parse_args()
    report = build_report(
        evidence=load_json(Path(args.evidence)),
        evidence_path=args.evidence,
        required_targets=list(args.required_targets),
    )
    if args.out:
        out_path = Path(args.out)
        out_path.parent.mkdir(parents=True, exist_ok=True)
        out_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    if args.emit_json:
        print(json.dumps(report, indent=2))
    elif report["failures"]:
        print("FAIL: Tint phase benchmark evidence")
        for item in report["failures"]:
            print(f"- {item['code']}: {item['path']}: {item['message']}")
    else:
        print("PASS: Tint phase benchmark evidence")
    return 1 if report["failures"] else 0


if __name__ == "__main__":
    sys.exit(main())
