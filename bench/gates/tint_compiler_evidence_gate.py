#!/usr/bin/env python3
"""Gate Doe-vs-Tint compiler evidence before it can support compiler claims."""

from __future__ import annotations

import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
BENCH_ROOT = REPO_ROOT / "bench"
for _path_entry in (str(REPO_ROOT), str(BENCH_ROOT)):
    if _path_entry not in sys.path:
        sys.path.insert(0, _path_entry)

import argparse
import json
from typing import Any

import jsonschema

from bench.lib.bench_utils import unsafe_repo_path_reason

VALID_HEX = set("0123456789abcdef")
SIDE_KEYS = ("doe", "tint")
CLAIMABLE_REQUIRED_PHASES = ("parse", "sema", "lower", "emit", "total")
CLAIMABLE_ROW_FIELDS = (
    "sourcePath",
    "corpusCategory",
    "expectedValidity",
    "expectedBackendTargets",
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--report",
        default="bench/out/tint-compiler-evidence.json",
        help="Doe-vs-Tint compiler evidence report.",
    )
    parser.add_argument(
        "--schema",
        default="config/tint-compiler-evidence.schema.json",
        help="JSON Schema for compiler evidence reports.",
    )
    parser.add_argument(
        "--require-claimable",
        action="store_true",
        help="Require comparisonStatus=comparable and claimStatus=claimable.",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        dest="emit_json",
        help="Emit a machine-readable gate report.",
    )
    return parser.parse_args()


def load_json(path: Path) -> dict[str, Any]:
    payload = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(payload, dict):
        raise ValueError(f"invalid JSON object: {path}")
    return payload


def schema_errors(payload: dict[str, Any], schema: dict[str, Any]) -> list[str]:
    validator = jsonschema.Draft202012Validator(schema)
    errors = sorted(
        validator.iter_errors(payload),
        key=lambda error: tuple(str(part) for part in error.absolute_path),
    )
    return [f"{format_schema_path(error)}: {error.message}" for error in errors]


def format_schema_path(error: jsonschema.ValidationError) -> str:
    if not error.absolute_path:
        return "<root>"
    return ".".join(str(part) for part in error.absolute_path)


def is_sha256(value: Any) -> bool:
    return (
        isinstance(value, str)
        and len(value) == 64
        and all(char in VALID_HEX for char in value)
    )


def is_non_empty_string(value: Any) -> bool:
    return isinstance(value, str) and bool(value.strip())


def repo_path_failures(path: str, value: Any) -> list[str]:
    reason = unsafe_repo_path_reason(value)
    return [f"{path}: {reason}"] if reason else []


def phase_timings_complete(result: dict[str, Any], required_phases: list[str]) -> list[str]:
    failures: list[str] = []
    timings = result.get("phaseTimingsNs")
    if not isinstance(timings, dict):
        return ["missing phaseTimingsNs object"]

    for phase in required_phases:
        value = timings.get(phase)
        if isinstance(value, bool) or not isinstance(value, int):
            failures.append(f"missing integer phase timing: {phase}")
        elif value <= 0:
            failures.append(f"phase timing must be positive: {phase}")

    total = timings.get("total")
    if isinstance(total, int) and not isinstance(total, bool):
        child_sum = sum(
            timings.get(phase, 0)
            for phase in required_phases
            if phase != "total" and isinstance(timings.get(phase), int)
        )
        if child_sum > 0 and total < child_sum:
            failures.append("total phase timing is lower than named phase sum")
    return failures


def validate_side_result(
    row_id: str,
    side: str,
    result: dict[str, Any],
    required_phases: list[str],
) -> tuple[list[str], list[str]]:
    failures: list[str] = []
    blockers: list[str] = []
    status = result.get("status")

    if status == "ok":
        if not is_sha256(result.get("outputSha256")):
            failures.append(f"{row_id}:{side}: ok result requires outputSha256")
        if result.get("validationStatus") != "passed":
            blockers.append(f"{row_id}:{side}: ok result requires validationStatus=passed")
        if not is_non_empty_string(result.get("validationTool")):
            blockers.append(f"{row_id}:{side}: ok result requires validationTool")
        for item in phase_timings_complete(result, required_phases):
            blockers.append(f"{row_id}:{side}: {item}")
        receipt_path = result.get("receiptPath")
        if not is_non_empty_string(receipt_path):
            blockers.append(f"{row_id}:{side}: ok result requires receiptPath")
        else:
            failures.extend(repo_path_failures(f"{row_id}:{side}.receiptPath", receipt_path))
    else:
        if result.get("validationStatus") == "passed":
            failures.append(f"{row_id}:{side}: non-ok result cannot have validationStatus=passed")
        if result.get("outputSha256") is not None:
            failures.append(f"{row_id}:{side}: non-ok result cannot carry outputSha256")
    return failures, blockers


def toolchain_artifact_blockers(
    toolchains: Any,
    names: tuple[str, ...],
) -> list[str]:
    blockers: list[str] = []
    if not isinstance(toolchains, dict):
        return ["toolchains must be object"]

    for name in names:
        toolchain = toolchains.get(name)
        if not isinstance(toolchain, dict):
            blockers.append(f"toolchains.{name} must be object")
            continue
        if not is_non_empty_string(toolchain.get("artifactPath")):
            blockers.append(f"toolchains.{name}.artifactPath must be non-empty")
        else:
            blockers.extend(
                repo_path_failures(
                    f"toolchains.{name}.artifactPath",
                    toolchain.get("artifactPath"),
                )
            )
        if not is_sha256(toolchain.get("artifactSha256")):
            blockers.append(f"toolchains.{name}.artifactSha256 must be sha256 hex")
    return blockers


def row_blockers(row: dict[str, Any], required_phases: list[str]) -> tuple[list[str], bool]:
    row_id = str(row.get("shaderId") or "unknown")
    failures: list[str] = []
    claimable = True

    if not is_sha256(row.get("sourceSha256")):
        failures.append(f"{row_id}: sourceSha256 must be a lowercase sha256")
        claimable = False
    failures.extend(repo_path_failures(f"{row_id}.sourcePath", row.get("sourcePath", "")))

    for side in SIDE_KEYS:
        result = row.get(side)
        if not isinstance(result, dict):
            failures.append(f"{row_id}:{side}: missing compiler result")
            claimable = False
            continue
        side_failures, side_blockers = validate_side_result(
            row_id,
            side,
            result,
            required_phases,
        )
        failures.extend(side_failures)
        failures.extend(side_blockers)
        if side_failures or side_blockers or result.get("status") != "ok":
            claimable = False

    comparability = row.get("comparability")
    if not isinstance(comparability, dict):
        failures.append(f"{row_id}: missing comparability object")
        return failures, False

    status = comparability.get("status")
    reasons = comparability.get("reasons")
    if status == "comparable":
        if reasons:
            failures.append(f"{row_id}: comparable row must not carry comparability reasons")
            claimable = False
        if not claimable:
            failures.append(f"{row_id}: comparable row has blocking compiler evidence gaps")
    else:
        claimable = False
        if not isinstance(reasons, list) or not reasons:
            failures.append(f"{row_id}: diagnostic row requires comparability reasons")

    claimability = row.get("claimability")
    if not isinstance(claimability, dict):
        failures.append(f"{row_id}: missing claimability object")
        return failures, False

    claim_status = claimability.get("status")
    claim_reasons = claimability.get("reasons")
    if claim_status == "claimable":
        if claim_reasons:
            failures.append(f"{row_id}: claimable row must not carry claimability reasons")
            claimable = False
        for field in CLAIMABLE_ROW_FIELDS:
            value = row.get(field)
            if field == "expectedBackendTargets":
                if not isinstance(value, list) or not value:
                    failures.append(f"{row_id}: claimable row requires expectedBackendTargets")
                    claimable = False
            elif not is_non_empty_string(value):
                failures.append(f"{row_id}: claimable row requires {field}")
                claimable = False
        doe_result = row.get("doe")
        if not isinstance(doe_result, dict) or not is_sha256(doe_result.get("irSha256")):
            failures.append(f"{row_id}: claimable row requires doe.irSha256")
            claimable = False
        if not claimable or status != "comparable":
            failures.append(f"{row_id}: claimable row has blocking evidence gaps")
    else:
        claimable = False
        if not isinstance(claim_reasons, list) or not claim_reasons:
            failures.append(f"{row_id}: diagnostic claimability requires reasons")

    return failures, claimable and status == "comparable" and claim_status == "claimable"


def evaluate_report(payload: dict[str, Any], require_claimable: bool = False) -> dict[str, Any]:
    failures: list[str] = []
    claim_blockers: list[str] = []
    row_ids: set[str] = set()
    comparable_rows = 0
    claimable_rows = 0

    phase_model = payload.get("phaseModel")
    required_phases = []
    if isinstance(phase_model, dict):
        raw_phases = phase_model.get("requiredPhases")
        if isinstance(raw_phases, list):
            required_phases = [str(item) for item in raw_phases if isinstance(item, str)]

    if "total" not in required_phases:
        failures.append("phaseModel.requiredPhases must include total")

    corpus = payload.get("corpus")
    if isinstance(corpus, dict):
        if not is_sha256(corpus.get("sourceSha256")):
            failures.append("corpus.sourceSha256 must be a lowercase sha256")
        failures.extend(
            repo_path_failures("corpus.manifestPath", corpus.get("manifestPath", ""))
        )

    rows = payload.get("rows")
    if not isinstance(rows, list):
        failures.append("rows must be an array")
        rows = []

    for row in rows:
        if not isinstance(row, dict):
            failures.append("row must be an object")
            continue
        row_id = str(row.get("shaderId") or "")
        if not row_id:
            failures.append("row missing shaderId")
            continue
        if row_id in row_ids:
            failures.append(f"{row_id}: duplicate shaderId")
            continue
        row_ids.add(row_id)
        row_failures, row_claimable = row_blockers(row, required_phases)
        failures.extend(row_failures)
        if row.get("comparability", {}).get("status") == "comparable":
            comparable_rows += 1
        if row_claimable:
            claimable_rows += 1

    summary = payload.get("summary")
    if isinstance(summary, dict):
        expected = {
            "rowCount": len(rows),
            "comparableRows": comparable_rows,
            "claimableRows": claimable_rows,
        }
        for key, value in expected.items():
            if summary.get(key) != value:
                failures.append(f"summary.{key} must be {value}")
    else:
        failures.append("missing summary object")

    comparison_status = payload.get("comparisonStatus")
    claim_status = payload.get("claimStatus")
    needs_claimable_gate = (
        comparison_status == "comparable"
        or claim_status == "claimable"
        or require_claimable
    )
    if needs_claimable_gate:
        claim_blockers.extend(
            toolchain_artifact_blockers(payload.get("toolchains"), ("doe", "tint"))
        )
        missing_claim_phases = [
            phase for phase in CLAIMABLE_REQUIRED_PHASES if phase not in required_phases
        ]
        if missing_claim_phases:
            claim_blockers.append(
                "claimable compiler evidence requires phaseModel.requiredPhases to include "
                + ", ".join(CLAIMABLE_REQUIRED_PHASES)
            )
    if claim_status == "claimable" or require_claimable or claimable_rows > 0:
        claim_blockers.extend(
            toolchain_artifact_blockers(payload.get("toolchains"), ("tintWarm",))
        )
    if not rows:
        if comparison_status == "comparable":
            claim_blockers.append("comparisonStatus=comparable requires at least one row")
        if claim_status == "claimable":
            claim_blockers.append("claimStatus=claimable requires at least one row")
        reasons = summary.get("reasons") if isinstance(summary, dict) else None
        if not reasons:
            failures.append("zero-row diagnostic reports require summary.reasons")
    if comparison_status == "comparable" and comparable_rows != len(rows):
        claim_blockers.append("comparisonStatus=comparable requires every row comparable")
    if claim_status == "claimable":
        if comparison_status != "comparable":
            claim_blockers.append("claimStatus=claimable requires comparisonStatus=comparable")
        if claimable_rows != len(rows):
            claim_blockers.append("claimStatus=claimable requires every row claimable")
        reasons = summary.get("reasons") if isinstance(summary, dict) else None
        if reasons:
            claim_blockers.append("claimStatus=claimable requires empty summary.reasons")
    if require_claimable:
        if comparison_status != "comparable":
            claim_blockers.append("--require-claimable requires comparisonStatus=comparable")
        if claim_status != "claimable":
            claim_blockers.append("--require-claimable requires claimStatus=claimable")

    hard_failures = list(failures)
    if claim_status == "claimable" or comparison_status == "comparable" or require_claimable:
        hard_failures.extend(claim_blockers)

    return {
        "ok": not hard_failures,
        "failureCount": len(hard_failures),
        "failures": hard_failures,
        "claimBlockers": claim_blockers,
        "summary": {
            "rowCount": len(rows),
            "comparableRows": comparable_rows,
            "claimableRows": claimable_rows,
            "comparisonStatus": comparison_status,
            "claimStatus": claim_status,
        },
    }


def main() -> int:
    args = parse_args()
    report_path = Path(args.report)
    schema_path = Path(args.schema)

    failures: list[str] = []
    try:
        payload = load_json(report_path)
    except (OSError, UnicodeError, json.JSONDecodeError, ValueError) as exc:
        failures.append(str(exc))
        payload = {}

    try:
        schema = load_json(schema_path)
    except (OSError, UnicodeError, json.JSONDecodeError, ValueError) as exc:
        failures.append(str(exc))
        schema = {}

    if payload and schema:
        failures.extend(schema_errors(payload, schema))

    if failures:
        result = {
            "ok": False,
            "failureCount": len(failures),
            "failures": failures,
            "claimBlockers": [],
            "summary": {},
        }
    else:
        result = evaluate_report(payload, args.require_claimable)

    if args.emit_json:
        print(json.dumps(result, indent=2, sort_keys=True))
    elif result["ok"]:
        summary = result["summary"]
        print(
            "PASS: Tint compiler evidence gate "
            f"(rows={summary.get('rowCount', 0)}, "
            f"comparable={summary.get('comparableRows', 0)}, "
            f"claimable={summary.get('claimableRows', 0)})"
        )
    else:
        print("FAIL: Tint compiler evidence gate")
        for failure in result["failures"]:
            print(f"  {failure}")

    return 0 if result["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
