#!/usr/bin/env python3
"""Check the Doe-vs-Tint compiler frontier evidence bundle."""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
from pathlib import Path
from typing import Any

try:
    from bench.tools._repo_import import ensure_repo_root
except ModuleNotFoundError:
    from _repo_import import ensure_repo_root

REPO_ROOT = ensure_repo_root(__file__)

from bench.gates import tint_compiler_evidence_gate  # noqa: E402
from bench.tools import check_tint_phase_benchmark_evidence  # noqa: E402
from bench.tools import check_tint_compiler_target_validation  # noqa: E402
from bench.tools import check_wgsl_lowering_link_receipt  # noqa: E402


VALID_TARGETS = {"msl", "spirv", "dxil", "hlsl"}
TARGET_VALIDATION_KIND = "tint_compiler_target_validation"
PHASE_BENCHMARK_KIND = "tint_phase_benchmark_evidence"
LOWERING_LINK_KIND = "wgsl_lowering_link_receipt"
COMPILER_EVIDENCE_KIND = "tint-compiler-evidence"
REQUIRED_BENCHMARK_SCOPES = ("parseWgsl", "validateIr", "generateBackend")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--compiler-evidence",
        action="append",
        default=[],
        help="Tint compiler evidence report. Repeat when bundle receipts span corpora.",
    )
    parser.add_argument(
        "--lowering-link-receipt",
        action="append",
        default=[],
        help="WGSL lowering-link receipt path. Repeat for multiple corpora.",
    )
    parser.add_argument(
        "--target-validation",
        action="append",
        default=[],
        help="Tint compiler target-validation receipt path. Repeat for multiple corpora.",
    )
    parser.add_argument(
        "--phase-benchmark-evidence",
        action="append",
        default=[],
        help="Tint phase-benchmark evidence receipt path. Repeat for multiple corpora.",
    )
    parser.add_argument(
        "--required-target",
        action="append",
        dest="required_targets",
        required=True,
        choices=sorted(VALID_TARGETS),
        help="Backend target that must be covered by the frontier bundle.",
    )
    parser.add_argument(
        "--verify-files-root",
        default="",
        help="Resolve lowering-link source and receipt paths under this root.",
    )
    parser.add_argument(
        "--schema",
        default="config/tint-compiler-evidence.schema.json",
        help="Schema used to validate compiler evidence reports.",
    )
    parser.add_argument(
        "--require-claimable",
        action="store_true",
        help="Fail when compiler evidence remains diagnostic.",
    )
    parser.add_argument("--out", default="", help="Optional output receipt path.")
    parser.add_argument("--json", action="store_true", dest="emit_json")
    return parser.parse_args()


def load_json(path: Path) -> dict[str, Any]:
    payload = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(payload, dict):
        raise ValueError(f"expected JSON object: {path}")
    return payload


def sha256_file(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def failure(code: str, path: str, message: str) -> dict[str, str]:
    return {"code": code, "path": path, "message": message}


def resolve_repo_path(path_text: str, root: Path) -> Path:
    path = Path(path_text)
    if path.is_absolute():
        return path
    return root / path


def stable_unique(items: list[str]) -> list[str]:
    out: list[str] = []
    for item in items:
        if item not in out:
            out.append(item)
    return out


def normalize_required_targets(required_targets: list[str]) -> tuple[list[str], list[dict[str, str]]]:
    targets: list[str] = []
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
        if target not in targets:
            targets.append(target)
    if not targets:
        failures.append(
            failure(
                "missing_required_targets",
                "requiredTargets",
                "at least one backend target is required",
            )
        )
    return targets, failures


def target_list(payload: dict[str, Any]) -> list[str]:
    raw_targets = payload.get("requiredTargets")
    if isinstance(raw_targets, list):
        return [str(item) for item in raw_targets if item in VALID_TARGETS]
    target = payload.get("target")
    if isinstance(target, str) and target in VALID_TARGETS:
        return [target]
    return []


def rows_for_target(payload: dict[str, Any], target: str) -> list[dict[str, Any]]:
    rows = payload.get("rows")
    if not isinstance(rows, list):
        return []
    out: list[dict[str, Any]] = []
    for row in rows:
        if isinstance(row, dict) and row.get("target") == target:
            out.append(row)
        elif isinstance(row, dict) and row.get("backendTarget") == target:
            out.append(row)
    return out


def evidence_path_from_receipt(payload: dict[str, Any]) -> str:
    value = payload.get("evidencePath")
    return value if isinstance(value, str) else ""


def evidence_paths_from_receipt(payload: dict[str, Any]) -> list[str]:
    values = payload.get("evidencePaths")
    if isinstance(values, list):
        paths = [str(item) for item in values if isinstance(item, str) and item]
        if paths:
            return stable_unique(paths)
    path = evidence_path_from_receipt(payload)
    return [path] if path else []


def first_evidence_path(paths: list[str]) -> str:
    return paths[0] if paths else ""


def summary_evidence_paths(summary: dict[str, Any]) -> list[str]:
    paths = summary.get("evidencePaths")
    if isinstance(paths, list):
        normalized = [str(item) for item in paths if isinstance(item, str) and item]
        if normalized:
            return stable_unique(normalized)
    path = summary.get("evidencePath")
    return [path] if isinstance(path, str) and path else []


def row_identity(
    row: dict[str, Any],
    *,
    target_field: str = "target",
) -> tuple[str, str] | None:
    target = row.get(target_field)
    shader_id = row.get("shaderId")
    if (
        isinstance(target, str)
        and target in VALID_TARGETS
        and isinstance(shader_id, str)
        and shader_id
    ):
        return target, shader_id
    return None


def compiler_evidence_row_index(
    *,
    payload: dict[str, Any],
    report_path: str,
    failures: list[dict[str, str]],
) -> dict[tuple[str, str], dict[str, Any]]:
    rows = payload.get("rows")
    if not isinstance(rows, list):
        return {}
    index: dict[tuple[str, str], dict[str, Any]] = {}
    for row_index, row in enumerate(rows):
        if not isinstance(row, dict):
            continue
        key = row_identity(row)
        if key is None:
            continue
        if key in index:
            target, shader_id = key
            failures.append(
                failure(
                    "compiler_evidence_duplicate_row_identity",
                    f"{report_path}.rows[{row_index}]",
                    (
                        "compiler evidence rows must have unique "
                        f"target/shaderId identity: {target}/{shader_id}"
                    ),
                )
            )
            continue
        index[key] = row
    return index


def positive_integer_mapping(value: Any) -> dict[str, int]:
    if not isinstance(value, dict):
        return {}
    timings: dict[str, int] = {}
    for key, item in value.items():
        if isinstance(key, str) and isinstance(item, int) and item > 0:
            timings[key] = item
    return timings


def tint_status(result: Any) -> str:
    if not isinstance(result, dict):
        return "missing"
    status = result.get("status")
    if status in {"ok", "failed", "unsupported"}:
        return str(status)
    return "missing"


def expected_phase_benchmark_row(
    compiler_row: dict[str, Any],
    *,
    exact_phases: list[str],
) -> dict[str, Any]:
    tint = compiler_row.get("tint")
    status = tint_status(tint)
    if status != "ok":
        return {
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
    exact_timings = positive_integer_mapping(tint.get("phaseTimingsNs"))
    missing_exact_phases = [
        phase for phase in exact_phases if phase not in exact_timings
    ]
    return {
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


def exact_phase_timings_complete(result: Any, exact_phases: list[str]) -> bool:
    if not isinstance(result, dict) or result.get("status") != "ok":
        return False
    timings = positive_integer_mapping(result.get("phaseTimingsNs"))
    return all(phase in timings for phase in exact_phases)


def benchmark_scope_timings_complete(result: Any) -> bool:
    if not isinstance(result, dict) or result.get("status") != "ok":
        return False
    timings = positive_integer_mapping(result.get("phaseBenchmarkTimingsNs"))
    return all(scope in timings for scope in REQUIRED_BENCHMARK_SCOPES)


def phase_timing_counts(
    *,
    rows: list[dict[str, Any]],
    exact_phases: list[str],
) -> dict[str, int]:
    counts = {
        "rowCount": len(rows),
        "doeOkRows": 0,
        "tintOkRows": 0,
        "doeExactPhaseCompleteRows": 0,
        "doeExactPhaseMissingRows": 0,
        "tintExactPhaseCompleteRows": 0,
        "tintExactPhaseMissingRows": 0,
        "tintBenchmarkScopeCoveredRows": 0,
        "tintBenchmarkScopeMissingRows": 0,
        "notApplicableRows": 0,
    }
    for row in rows:
        doe = row.get("doe")
        if tint_status(doe) == "ok":
            counts["doeOkRows"] += 1
            if exact_phase_timings_complete(doe, exact_phases):
                counts["doeExactPhaseCompleteRows"] += 1
            else:
                counts["doeExactPhaseMissingRows"] += 1

        tint = row.get("tint")
        if tint_status(tint) != "ok":
            counts["notApplicableRows"] += 1
            continue
        counts["tintOkRows"] += 1
        if exact_phase_timings_complete(tint, exact_phases):
            counts["tintExactPhaseCompleteRows"] += 1
        else:
            counts["tintExactPhaseMissingRows"] += 1
        if benchmark_scope_timings_complete(tint):
            counts["tintBenchmarkScopeCoveredRows"] += 1
        else:
            counts["tintBenchmarkScopeMissingRows"] += 1
    return counts


def phase_timing_coverage(
    *,
    compiler_payloads: dict[str, dict[str, Any]],
    required_targets: list[str],
) -> dict[str, Any]:
    exact_phases = stable_unique(
        [
            phase
            for payload in compiler_payloads.values()
            for phase in check_tint_phase_benchmark_evidence.required_exact_phases(payload)
        ]
    )
    if not exact_phases:
        exact_phases = list(check_tint_phase_benchmark_evidence.DEFAULT_EXACT_PHASES)

    required_target_set = set(required_targets)
    by_evidence_path: list[dict[str, Any]] = []
    all_counts = phase_timing_counts(rows=[], exact_phases=exact_phases)
    for evidence_path, payload in compiler_payloads.items():
        payload_rows = payload.get("rows")
        if not isinstance(payload_rows, list):
            payload_rows = []
        rows = [
            row
            for row in payload_rows
            if isinstance(row, dict) and row.get("target") in required_target_set
        ]
        targets = stable_unique(
            [
                row["target"]
                for row in rows
                if isinstance(row.get("target"), str) and row["target"] in VALID_TARGETS
            ]
        )
        counts = phase_timing_counts(rows=rows, exact_phases=exact_phases)
        for key, value in counts.items():
            all_counts[key] += value
        by_evidence_path.append(
            {
                "evidencePath": evidence_path,
                "targets": targets,
                **counts,
            }
        )

    return {
        "requiredExactPhases": exact_phases,
        "requiredBenchmarkScopes": list(REQUIRED_BENCHMARK_SCOPES),
        **all_counts,
        "coverageByEvidencePath": by_evidence_path,
    }


def receipt_exact_phases(payload: dict[str, Any]) -> list[str]:
    phases = payload.get("requiredExactPhases")
    if not isinstance(phases, list):
        return []
    return [phase for phase in phases if isinstance(phase, str) and phase]


def add_unique_blocker(
    blockers: list[dict[str, str]],
    *,
    code: str,
    path: str,
    message: str,
) -> None:
    item = failure(code, path, message)
    if item not in blockers:
        blockers.append(item)


def compiler_claim_blocker_message(blocker: str) -> str:
    parts = blocker.split(": ", 1)
    if len(parts) != 2:
        return blocker
    row_and_side, detail = parts
    side_parts = row_and_side.rsplit(":", 1)
    if len(side_parts) != 2:
        return detail
    return f"{side_parts[1]}: {detail}"


def summarize_compiler_claim_blockers(blockers: list[str]) -> list[dict[str, Any]]:
    summary: list[dict[str, Any]] = []
    for blocker in blockers:
        message = compiler_claim_blocker_message(blocker)
        for item in summary:
            if item["message"] == message:
                item["count"] += 1
                break
        else:
            summary.append(
                {
                    "code": "claimable_tint_compiler_evidence_report",
                    "message": message,
                    "count": 1,
                }
            )
    return summary


def load_receipts(
    *,
    paths: list[str],
    root: Path,
    expected_kind: str,
    label: str,
    failures: list[dict[str, str]],
) -> list[dict[str, Any]]:
    receipts: list[dict[str, Any]] = []
    for index, path_text in enumerate(paths):
        path = resolve_repo_path(path_text, root)
        receipt_path = f"{label}[{index}]"
        try:
            payload = load_json(path)
        except (OSError, UnicodeError, json.JSONDecodeError, ValueError) as exc:
            failures.append(
                failure(
                    f"{label}_load_failed",
                    receipt_path,
                    f"failed to load {path_text}: {exc}",
                )
            )
            continue
        if payload.get("artifactKind") != expected_kind:
            failures.append(
                failure(
                    f"{label}_invalid_artifact_kind",
                    f"{receipt_path}.artifactKind",
                    f"artifactKind must be {expected_kind}",
                )
            )
        receipts.append({"path": path_text, "sha256": sha256_file(path), "payload": payload})
    return receipts


def component_evidence_path_failures(
    *,
    receipts: list[dict[str, Any]],
    label: str,
    allowed_paths: list[str],
) -> list[dict[str, str]]:
    failures: list[dict[str, str]] = []
    allowed = set(allowed_paths)
    for index, receipt in enumerate(receipts):
        for path in evidence_paths_from_receipt(receipt["payload"]):
            if path not in allowed:
                failures.append(
                    failure(
                        f"{label}_unlisted_evidence_path",
                        f"{label}Receipts[{index}].evidencePaths",
                        (
                            f"{label} receipt evidence path must be supplied via "
                            f"--compiler-evidence: {path}"
                        ),
                    )
                )
    return failures


def evaluate_compiler_evidence(
    *,
    evidence_paths: list[str],
    root: Path,
    schema: dict[str, Any],
    failures: list[dict[str, str]],
) -> tuple[
    list[dict[str, Any]],
    list[dict[str, str]],
    dict[str, dict[tuple[str, str], dict[str, Any]]],
    dict[str, dict[str, Any]],
]:
    reports: list[dict[str, Any]] = []
    claim_blockers: list[dict[str, str]] = []
    row_indexes: dict[str, dict[tuple[str, str], dict[str, Any]]] = {}
    payloads: dict[str, dict[str, Any]] = {}
    for index, path_text in enumerate(evidence_paths):
        report_path = f"compilerEvidence[{index}]"
        blocker_count_start = len(claim_blockers)
        path = resolve_repo_path(path_text, root)
        try:
            payload = load_json(path)
        except (OSError, UnicodeError, json.JSONDecodeError, ValueError) as exc:
            failures.append(
                failure(
                    "compiler_evidence_load_failed",
                    report_path,
                    f"failed to load {path_text}: {exc}",
                )
            )
            continue
        payloads[path_text] = payload
        report_sha256 = sha256_file(path)
        row_indexes[path_text] = compiler_evidence_row_index(
            payload=payload,
            report_path=report_path,
            failures=failures,
        )
        if payload.get("artifactKind") != COMPILER_EVIDENCE_KIND:
            failures.append(
                failure(
                    "compiler_evidence_invalid_artifact_kind",
                    f"{report_path}.artifactKind",
                    "artifactKind must be tint-compiler-evidence",
                )
            )
        schema_failures = tint_compiler_evidence_gate.schema_errors(payload, schema)
        for schema_failure in schema_failures:
            failures.append(
                failure(
                    "compiler_evidence_schema_failure",
                    report_path,
                    schema_failure,
                )
            )
        result = (
            tint_compiler_evidence_gate.evaluate_report(payload, require_claimable=False)
            if not schema_failures
            else {
                "ok": False,
                "summary": {
                    "rowCount": 0,
                    "comparableRows": 0,
                    "claimableRows": 0,
                    "comparisonStatus": "",
                    "claimStatus": "",
                },
                "failures": schema_failures,
                "claimBlockers": [],
            }
        )
        for item in result.get("failures", []):
            failures.append(
                failure("compiler_evidence_gate_failure", report_path, str(item))
            )
        summary = result.get("summary", {})
        report_claim_blockers = [str(item) for item in result.get("claimBlockers", [])]
        report_claim_blocker_summary = summarize_compiler_claim_blockers(
            report_claim_blockers
        )
        for blocker_index, blocker in enumerate(report_claim_blockers):
            add_unique_blocker(
                claim_blockers,
                code="claimable_tint_compiler_evidence_report",
                path=f"{report_path}.claimBlockers[{blocker_index}]",
                message=blocker,
            )
        comparison_status = summary.get("comparisonStatus", "")
        claim_status = summary.get("claimStatus", "")
        if comparison_status != "comparable":
            add_unique_blocker(
                claim_blockers,
                code="claimable_tint_compiler_evidence_report",
                path=f"{report_path}.comparisonStatus",
                message="compiler evidence must be comparable before it can support a Tint replacement claim",
            )
            report_claim_blocker_summary.append(
                {
                    "code": "claimable_tint_compiler_evidence_report",
                    "message": "compiler evidence must be comparable before it can support a Tint replacement claim",
                    "count": 1,
                }
            )
        if claim_status != "claimable":
            add_unique_blocker(
                claim_blockers,
                code="claimable_tint_compiler_evidence_report",
                path=f"{report_path}.claimStatus",
                message="compiler evidence must be claimable before it can support a Tint replacement claim",
            )
            report_claim_blocker_summary.append(
                {
                    "code": "claimable_tint_compiler_evidence_report",
                    "message": "compiler evidence must be claimable before it can support a Tint replacement claim",
                    "count": 1,
                }
            )
        reports.append(
            {
                "path": path_text,
                "sha256": report_sha256,
                "diagnosticGateStatus": "pass" if result.get("ok") else "fail",
                "comparisonStatus": summary.get("comparisonStatus", ""),
                "claimStatus": summary.get("claimStatus", ""),
                "rowCount": summary.get("rowCount", 0),
                "comparableRows": summary.get("comparableRows", 0),
                "claimableRows": summary.get("claimableRows", 0),
                "claimBlockerCount": len(claim_blockers) - blocker_count_start,
                "claimBlockerSummary": report_claim_blocker_summary,
            }
        )
    return reports, claim_blockers, row_indexes, payloads


def find_compiler_row(
    *,
    compiler_rows: dict[str, dict[tuple[str, str], dict[str, Any]]],
    evidence_paths: list[str],
    key: tuple[str, str],
) -> dict[str, Any] | None:
    for evidence_path in evidence_paths:
        row = compiler_rows.get(evidence_path, {}).get(key)
        if row is not None:
            return row
    return None


def compiler_side_ready(result: Any) -> bool:
    return (
        isinstance(result, dict)
        and result.get("status") == "ok"
        and result.get("validationStatus") == "passed"
    )


def add_lowering_row_mismatch(
    failures: list[dict[str, str]],
    *,
    row_path: str,
    field: str,
    target: str,
    shader_id: str,
    detail: str,
) -> None:
    failures.append(
        failure(
            "lowering_link_row_mismatch",
            f"{row_path}.{field}",
            f"lowering-link {field} must match supplied compiler evidence {detail} for {target}/{shader_id}",
        )
    )


def check_lowering_link_row_identities(
    *,
    receipts: list[dict[str, Any]],
    compiler_rows: dict[str, dict[tuple[str, str], dict[str, Any]]],
) -> list[dict[str, str]]:
    failures: list[dict[str, str]] = []
    for receipt_index, receipt in enumerate(receipts):
        payload = receipt["payload"]
        evidence_paths = evidence_paths_from_receipt(payload)
        rows = payload.get("rows")
        if not isinstance(rows, list):
            continue
        for row_index, row in enumerate(rows):
            if not isinstance(row, dict):
                continue
            key = row_identity(row, target_field="backendTarget")
            if key is None:
                continue
            compiler_row = find_compiler_row(
                compiler_rows=compiler_rows,
                evidence_paths=evidence_paths,
                key=key,
            )
            target, shader_id = key
            row_path = f"loweringLinkReceipts[{receipt_index}].rows[{row_index}]"
            if compiler_row is None:
                failures.append(
                    failure(
                        "lowering_link_row_not_in_compiler_evidence",
                        f"{row_path}.shaderId",
                        (
                            "lowering-link row target/shaderId must exist in supplied "
                            f"compiler evidence: {target}/{shader_id}"
                        ),
                    )
                )
                continue
            for lowering_field, compiler_field in (
                ("sourcePath", "sourcePath"),
                ("expectedValidity", "expectedValidity"),
                ("shaderStage", "shaderStage"),
            ):
                if row.get(lowering_field) != compiler_row.get(compiler_field):
                    add_lowering_row_mismatch(
                        failures,
                        row_path=row_path,
                        field=lowering_field,
                        target=target,
                        shader_id=shader_id,
                        detail=compiler_field,
                    )
            compiler_source_hash = compiler_row.get("sourceSha256")
            lowering_source_hash = row.get("sourceSha256")
            if (
                isinstance(compiler_source_hash, str)
                and isinstance(lowering_source_hash, str)
                and compiler_source_hash != lowering_source_hash
            ):
                failures.append(
                    failure(
                        "lowering_link_source_hash_mismatch",
                        f"{row_path}.sourceSha256",
                        (
                            "lowering-link sourceSha256 must match supplied compiler "
                            f"evidence for {target}/{shader_id}"
                        ),
                    )
                )
            for side, mapping in (
                (
                    "doe",
                    (
                        ("doeIrSha256", "irSha256"),
                        ("doeBackendOutputSha256", "outputSha256"),
                        ("doeReceiptPath", "receiptPath"),
                        ("doeValidationStatus", "validationStatus"),
                    ),
                ),
                (
                    "tint",
                    (
                        ("tintBackendOutputSha256", "outputSha256"),
                        ("tintReceiptPath", "receiptPath"),
                        ("tintValidationStatus", "validationStatus"),
                    ),
                ),
            ):
                compiler_side = compiler_row.get(side)
                if not compiler_side_ready(compiler_side):
                    continue
                assert isinstance(compiler_side, dict)
                for lowering_field, compiler_field in mapping:
                    if row.get(lowering_field) == compiler_side.get(compiler_field):
                        continue
                    add_lowering_row_mismatch(
                        failures,
                        row_path=row_path,
                        field=lowering_field,
                        target=target,
                        shader_id=shader_id,
                        detail=f"{side}.{compiler_field}",
                    )
    return failures


def coverage_shader_identity_failures(
    *,
    receipt_index: int,
    label: str,
    code_prefix: str,
    coverage: Any,
    fallback_evidence_paths: list[str],
    compiler_rows: dict[str, dict[tuple[str, str], dict[str, Any]]],
) -> list[dict[str, str]]:
    failures: list[dict[str, str]] = []
    if not isinstance(coverage, list):
        return failures
    for coverage_index, item in enumerate(coverage):
        if not isinstance(item, dict):
            continue
        target = item.get("target")
        if not isinstance(target, str) or target not in VALID_TARGETS:
            continue
        evidence_paths = evidence_paths_from_receipt(item)
        if not evidence_paths:
            evidence_paths = fallback_evidence_paths
        shader_ids = item.get("shaderIds")
        if not isinstance(shader_ids, list):
            continue
        for shader_index, shader_id in enumerate(shader_ids):
            if not isinstance(shader_id, str) or not shader_id:
                continue
            if find_compiler_row(
                compiler_rows=compiler_rows,
                evidence_paths=evidence_paths,
                key=(target, shader_id),
            ) is not None:
                continue
            failures.append(
                failure(
                    f"{code_prefix}_coverage_row_not_in_compiler_evidence",
                    (
                        f"{label}Receipts[{receipt_index}].targetCoverage"
                        f"[{coverage_index}].shaderIds[{shader_index}]"
                    ),
                    (
                        f"{label} coverage target/shaderId must exist in supplied "
                        f"compiler evidence: {target}/{shader_id}"
                    ),
                )
            )
    return failures


def check_target_validation_row_identities(
    *,
    receipts: list[dict[str, Any]],
    compiler_rows: dict[str, dict[tuple[str, str], dict[str, Any]]],
) -> list[dict[str, str]]:
    failures: list[dict[str, str]] = []
    for receipt_index, receipt in enumerate(receipts):
        payload = receipt["payload"]
        failures.extend(
            coverage_shader_identity_failures(
                receipt_index=receipt_index,
                label="targetValidation",
                code_prefix="target_validation",
                coverage=payload.get("targetCoverage"),
                fallback_evidence_paths=evidence_paths_from_receipt(payload),
                compiler_rows=compiler_rows,
            )
        )
    return failures


def check_target_validation_receipt_bindings(
    *,
    receipts: list[dict[str, Any]],
    compiler_payloads: dict[str, dict[str, Any]],
    verify_files_root: Path | None,
) -> list[dict[str, str]]:
    failures: list[dict[str, str]] = []
    compared_fields = (
        "evidencePath",
        "evidencePaths",
        "requiredTargets",
        "status",
        "targetCoverage",
        "claimBlockers",
        "claimBlockerSummary",
        "claimBlockerSummaryByEvidencePath",
        "failures",
        "summary",
    )
    for receipt_index, receipt in enumerate(receipts):
        payload = receipt["payload"]
        targets = target_list(payload)
        evidence_paths = evidence_paths_from_receipt(payload)
        evidence_reports = [
            (path, compiler_payloads[path])
            for path in evidence_paths
            if path in compiler_payloads
        ]
        if not targets or not evidence_reports:
            continue
        expected = check_tint_compiler_target_validation.build_report(
            evidence_reports=evidence_reports,
            required_targets=targets,
            verify_files_root=verify_files_root,
            allow_diagnostic_rows=True,
        )
        for field in compared_fields:
            if payload.get(field) == expected.get(field):
                continue
            failures.append(
                failure(
                    "target_validation_receipt_mismatch",
                    f"targetValidationReceipts[{receipt_index}].{field}",
                    (
                        f"target-validation receipt {field} must match supplied "
                        "compiler evidence"
                    ),
                )
            )
    return failures


def check_phase_benchmark_row_identities(
    *,
    receipts: list[dict[str, Any]],
    compiler_rows: dict[str, dict[tuple[str, str], dict[str, Any]]],
) -> list[dict[str, str]]:
    failures: list[dict[str, str]] = []
    for receipt_index, receipt in enumerate(receipts):
        payload = receipt["payload"]
        evidence_paths = evidence_paths_from_receipt(payload)
        exact_phases = receipt_exact_phases(payload)
        rows = payload.get("rows")
        if isinstance(rows, list):
            for row_index, row in enumerate(rows):
                if not isinstance(row, dict):
                    continue
                key = row_identity(row)
                if key is None:
                    continue
                compiler_row = find_compiler_row(
                    compiler_rows=compiler_rows,
                    evidence_paths=evidence_paths,
                    key=key,
                )
                target, shader_id = key
                if compiler_row is None:
                    failures.append(
                        failure(
                            "phase_benchmark_row_not_in_compiler_evidence",
                            f"phaseBenchmarkReceipts[{receipt_index}].rows[{row_index}].shaderId",
                            (
                                "phase-benchmark row target/shaderId must exist in supplied "
                                f"compiler evidence: {target}/{shader_id}"
                            ),
                        )
                    )
                    continue
                expected = expected_phase_benchmark_row(
                    compiler_row,
                    exact_phases=exact_phases,
                )
                for field, expected_value in expected.items():
                    if row.get(field) == expected_value:
                        continue
                    failures.append(
                        failure(
                            "phase_benchmark_row_mismatch",
                            (
                                f"phaseBenchmarkReceipts[{receipt_index}].rows"
                                f"[{row_index}].{field}"
                            ),
                            (
                                f"phase-benchmark row {field} must match supplied "
                                f"compiler evidence for {target}/{shader_id}"
                            ),
                        )
                    )
        failures.extend(
            coverage_shader_identity_failures(
                receipt_index=receipt_index,
                label="phaseBenchmark",
                code_prefix="phase_benchmark",
                coverage=payload.get("targetCoverage"),
                fallback_evidence_paths=evidence_paths,
                compiler_rows=compiler_rows,
            )
        )
    return failures


def check_phase_benchmark_receipt_bindings(
    *,
    receipts: list[dict[str, Any]],
    compiler_payloads: dict[str, dict[str, Any]],
) -> list[dict[str, str]]:
    failures: list[dict[str, str]] = []
    compared_fields = (
        "evidencePath",
        "requiredTargets",
        "requiredBenchmarkScopes",
        "requiredExactPhases",
        "status",
        "targetCoverage",
        "rows",
        "failures",
        "summary",
    )
    for receipt_index, receipt in enumerate(receipts):
        payload = receipt["payload"]
        targets = target_list(payload)
        evidence_paths = evidence_paths_from_receipt(payload)
        if not targets or len(evidence_paths) != 1:
            continue
        evidence_path = evidence_paths[0]
        evidence = compiler_payloads.get(evidence_path)
        if evidence is None:
            continue
        expected = check_tint_phase_benchmark_evidence.build_report(
            evidence=evidence,
            evidence_path=evidence_path,
            required_targets=targets,
        )
        for field in compared_fields:
            if payload.get(field) == expected.get(field):
                continue
            failures.append(
                failure(
                    "phase_benchmark_receipt_mismatch",
                    f"phaseBenchmarkReceipts[{receipt_index}].{field}",
                    (
                        f"phase-benchmark receipt {field} must match supplied "
                        "compiler evidence"
                    ),
                )
            )
    return failures


def lowering_link_claim_blockers(
    summaries: list[dict[str, Any]],
) -> list[dict[str, str]]:
    blockers: list[dict[str, str]] = []
    for index, summary in enumerate(summaries):
        if summary.get("status") != "pass":
            add_unique_blocker(
                blockers,
                code="wgsl_lowering_link_claim_bundle",
                path=f"loweringLinkReceipts[{index}].status",
                message="WGSL lowering-link receipt must pass before it can support a compiler claim",
            )
        if int(summary.get("diagnosticRows", 0)) > 0:
            add_unique_blocker(
                blockers,
                code="wgsl_lowering_link_claim_bundle",
                path=f"loweringLinkReceipts[{index}].diagnosticRows",
                message="WGSL lowering-link receipt must not carry diagnostic rows for a compiler claim",
            )
    return blockers


def target_validation_claim_blockers(
    receipts: list[dict[str, Any]],
) -> list[dict[str, str]]:
    blockers: list[dict[str, str]] = []
    for index, receipt in enumerate(receipts):
        payload = receipt["payload"]
        if payload.get("status") != "pass":
            add_unique_blocker(
                blockers,
                code="shader_artifact_validation_for_target_backends",
                path=f"targetValidationReceipts[{index}].status",
                message="target-backend validation receipt must pass before it can support a compiler claim",
            )
        receipt_failures = payload.get("failures")
        if isinstance(receipt_failures, list) and receipt_failures:
            add_unique_blocker(
                blockers,
                code="shader_artifact_validation_for_target_backends",
                path=f"targetValidationReceipts[{index}].failures",
                message="target-backend validation receipt must not carry failures for a compiler claim",
            )
        receipt_claim_blockers = payload.get("claimBlockers")
        if not isinstance(receipt_claim_blockers, list):
            continue
        for blocker_index, blocker in enumerate(receipt_claim_blockers):
            if not isinstance(blocker, dict):
                continue
            message = blocker.get("message")
            code = blocker.get("code")
            add_unique_blocker(
                blockers,
                code="shader_artifact_validation_for_target_backends",
                path=f"targetValidationReceipts[{index}].claimBlockers[{blocker_index}]",
                message=str(message or code or "target validation claim blocker"),
            )
    return blockers


def summarize_lowering_receipt(
    *,
    receipt: dict[str, Any],
    verify_files_root: Path | None,
    index: int,
    failures: list[dict[str, str]],
) -> dict[str, Any]:
    path_text = str(receipt["path"])
    payload = receipt["payload"]
    check_failures = check_wgsl_lowering_link_receipt.check_receipt(
        payload,
        verify_files_root,
    )
    for item in check_failures:
        failures.append(
            failure(
                "lowering_link_receipt_failure",
                f"loweringLinkReceipts[{index}]",
                f"{item.get('code', 'failure')}: {item.get('message', '')}",
            )
        )
    rows = payload.get("rows")
    if not isinstance(rows, list):
        rows = []
    targets = stable_unique(
        [
            row["backendTarget"]
            for row in rows
            if isinstance(row, dict) and row.get("backendTarget") in VALID_TARGETS
        ]
    )
    summary = payload.get("summary") if isinstance(payload.get("summary"), dict) else {}
    evidence_paths = evidence_paths_from_receipt(payload)
    return {
        "path": path_text,
        "sha256": receipt["sha256"],
        "evidencePath": first_evidence_path(evidence_paths),
        "evidencePaths": evidence_paths,
        "status": "fail" if check_failures else "pass",
        "targets": targets,
        "rowCount": summary.get("rowCount", len(rows)),
        "linkedRows": summary.get("linkedRows", 0),
        "diagnosticRows": summary.get("diagnosticRows", 0),
    }


def summarize_status_receipt(
    *,
    receipt: dict[str, Any],
    index: int,
    label: str,
    failures: list[dict[str, str]],
) -> dict[str, Any]:
    payload = receipt["payload"]
    label_code = "target_validation" if label == "targetValidation" else "phase_benchmark"
    status = payload.get("status")
    if status != "pass":
        failures.append(
            failure(
                f"{label_code}_not_passed",
                f"{label}Receipts[{index}].status",
                f"{label} receipt must have status=pass",
            )
        )
    receipt_failures = payload.get("failures")
    if isinstance(receipt_failures, list) and receipt_failures:
        failures.append(
            failure(
                f"{label_code}_has_failures",
                f"{label}Receipts[{index}].failures",
                f"{label} receipt carries failures",
            )
        )
    evidence_paths = evidence_paths_from_receipt(payload)
    summary = {
        "path": str(receipt["path"]),
        "sha256": receipt["sha256"],
        "evidencePath": first_evidence_path(evidence_paths),
        "evidencePaths": evidence_paths,
        "status": status if status in {"pass", "fail"} else "fail",
        "targets": target_list(payload),
        "summary": payload.get("summary") if isinstance(payload.get("summary"), dict) else {},
    }
    if label == "targetValidation":
        summary["claimBlockerSummary"] = (
            payload.get("claimBlockerSummary")
            if isinstance(payload.get("claimBlockerSummary"), list)
            else []
        )
        summary["claimBlockerSummaryByEvidencePath"] = (
            payload.get("claimBlockerSummaryByEvidencePath")
            if isinstance(payload.get("claimBlockerSummaryByEvidencePath"), list)
            else []
        )
    return summary


def coverage_for_target(
    *,
    target: str,
    lowering_links: list[dict[str, Any]],
    target_validations: list[dict[str, Any]],
    phase_benchmarks: list[dict[str, Any]],
) -> dict[str, Any]:
    lowering_for_target = [
        item for item in lowering_links if target in item.get("targets", [])
    ]
    validations_for_target = [
        item for item in target_validations if target in item.get("targets", [])
    ]
    phases_for_target = [
        item for item in phase_benchmarks if target in item.get("targets", [])
    ]
    return {
        "target": target,
        "loweringLinkReceipts": [item["path"] for item in lowering_for_target],
        "targetValidationReceipts": [item["path"] for item in validations_for_target],
        "phaseBenchmarkReceipts": [item["path"] for item in phases_for_target],
        "evidencePaths": stable_unique(
            [
                evidence_path
                for item in lowering_for_target + validations_for_target + phases_for_target
                for evidence_path in summary_evidence_paths(item)
            ]
        ),
        "linkedRows": sum(int(item.get("linkedRows", 0)) for item in lowering_for_target),
        "validatedRows": sum(
            int(item.get("summary", {}).get("validatedRows", 0))
            for item in validations_for_target
        ),
        "phaseBenchmarkCoveredRows": sum(
            int(item.get("summary", {}).get("phaseBenchmarkCoveredRows", 0))
            for item in phases_for_target
        ),
    }


def build_report(
    *,
    compiler_evidence_paths: list[str],
    lowering_link_receipt_paths: list[str],
    target_validation_paths: list[str],
    phase_benchmark_paths: list[str],
    required_targets: list[str],
    schema: dict[str, Any],
    root: Path,
    verify_files_root: Path | None = None,
    require_claimable: bool = False,
) -> dict[str, Any]:
    targets, failures = normalize_required_targets(required_targets)
    if not lowering_link_receipt_paths:
        failures.append(
            failure(
                "missing_lowering_link_receipt",
                "loweringLinkReceipts",
                "at least one lowering-link receipt is required",
            )
        )
    if not target_validation_paths:
        failures.append(
            failure(
                "missing_target_validation_receipt",
                "targetValidationReceipts",
                "at least one target-validation receipt is required",
            )
        )
    if not phase_benchmark_paths:
        failures.append(
            failure(
                "missing_phase_benchmark_receipt",
                "phaseBenchmarkReceipts",
                "at least one phase-benchmark evidence receipt is required",
            )
        )

    lowering_receipts = load_receipts(
        paths=lowering_link_receipt_paths,
        root=root,
        expected_kind=LOWERING_LINK_KIND,
        label="lowering_link",
        failures=failures,
    )
    target_receipts = load_receipts(
        paths=target_validation_paths,
        root=root,
        expected_kind=TARGET_VALIDATION_KIND,
        label="target_validation",
        failures=failures,
    )
    phase_receipts = load_receipts(
        paths=phase_benchmark_paths,
        root=root,
        expected_kind=PHASE_BENCHMARK_KIND,
        label="phase_benchmark",
        failures=failures,
    )

    evidence_paths = stable_unique(list(compiler_evidence_paths))
    if not evidence_paths:
        failures.append(
            failure(
                "missing_compiler_evidence_report",
                "compilerEvidence",
                "at least one compiler evidence report is required",
            )
        )
    failures.extend(
        component_evidence_path_failures(
            receipts=lowering_receipts,
            label="loweringLink",
            allowed_paths=evidence_paths,
        )
    )
    failures.extend(
        component_evidence_path_failures(
            receipts=target_receipts,
            label="targetValidation",
            allowed_paths=evidence_paths,
        )
    )
    failures.extend(
        component_evidence_path_failures(
            receipts=phase_receipts,
            label="phaseBenchmark",
            allowed_paths=evidence_paths,
        )
    )

    (
        compiler_reports,
        claim_blockers,
        compiler_rows,
        compiler_payloads,
    ) = evaluate_compiler_evidence(
        evidence_paths=evidence_paths,
        root=root,
        schema=schema,
        failures=failures,
    )
    failures.extend(
        check_lowering_link_row_identities(
            receipts=lowering_receipts,
            compiler_rows=compiler_rows,
        )
    )
    failures.extend(
        check_target_validation_row_identities(
            receipts=target_receipts,
            compiler_rows=compiler_rows,
        )
    )
    failures.extend(
        check_target_validation_receipt_bindings(
            receipts=target_receipts,
            compiler_payloads=compiler_payloads,
            verify_files_root=verify_files_root,
        )
    )
    failures.extend(
        check_phase_benchmark_row_identities(
            receipts=phase_receipts,
            compiler_rows=compiler_rows,
        )
    )
    failures.extend(
        check_phase_benchmark_receipt_bindings(
            receipts=phase_receipts,
            compiler_payloads=compiler_payloads,
        )
    )

    lowering_summaries = [
        summarize_lowering_receipt(
            receipt=receipt,
            verify_files_root=verify_files_root,
            index=index,
            failures=failures,
        )
        for index, receipt in enumerate(lowering_receipts)
    ]
    target_summaries = [
        summarize_status_receipt(
            receipt=receipt,
            index=index,
            label="targetValidation",
            failures=failures,
        )
        for index, receipt in enumerate(target_receipts)
    ]
    claim_blockers.extend(lowering_link_claim_blockers(lowering_summaries))
    claim_blockers.extend(target_validation_claim_blockers(target_receipts))
    phase_summaries = [
        summarize_status_receipt(
            receipt=receipt,
            index=index,
            label="phaseBenchmark",
            failures=failures,
        )
        for index, receipt in enumerate(phase_receipts)
    ]

    coverage = [
        coverage_for_target(
            target=target,
            lowering_links=lowering_summaries,
            target_validations=target_summaries,
            phase_benchmarks=phase_summaries,
        )
        for target in targets
    ]
    for item in coverage:
        target = item["target"]
        if not item["loweringLinkReceipts"]:
            failures.append(
                failure(
                    "target_missing_lowering_link_receipt",
                    f"coverageByTarget.{target}.loweringLinkReceipts",
                    f"no lowering-link receipt covers target {target}",
                )
            )
        if not item["targetValidationReceipts"]:
            failures.append(
                failure(
                    "target_missing_validation_receipt",
                    f"coverageByTarget.{target}.targetValidationReceipts",
                    f"no target-validation receipt covers target {target}",
                )
            )
        if not item["phaseBenchmarkReceipts"]:
            failures.append(
                failure(
                    "target_missing_phase_benchmark_receipt",
                    f"coverageByTarget.{target}.phaseBenchmarkReceipts",
                    f"no phase-benchmark receipt covers target {target}",
                )
            )

    timing_coverage = phase_timing_coverage(
        compiler_payloads=compiler_payloads,
        required_targets=targets,
    )
    claimability_status = "claimable" if not claim_blockers else "blocked"
    if require_claimable and claim_blockers:
        failures.extend(claim_blockers)
    report = {
        "schemaVersion": 1,
        "artifactKind": "tint_compiler_frontier_bundle",
        "requiredTargets": targets,
        "status": "fail" if failures else "pass",
        "claimabilityStatus": claimability_status,
        "compilerEvidenceReports": compiler_reports,
        "componentReceipts": {
            "loweringLinks": lowering_summaries,
            "targetValidations": target_summaries,
            "phaseBenchmarks": phase_summaries,
        },
        "coverageByTarget": coverage,
        "phaseTimingCoverage": timing_coverage,
        "claimBlockers": claim_blockers,
        "failures": failures,
        "summary": {
            "compilerEvidenceReportCount": len(compiler_reports),
            "loweringLinkReceiptCount": len(lowering_summaries),
            "targetValidationReceiptCount": len(target_summaries),
            "phaseBenchmarkReceiptCount": len(phase_summaries),
            "coveredTargetCount": sum(
                1
                for item in coverage
                if item["loweringLinkReceipts"]
                and item["targetValidationReceipts"]
                and item["phaseBenchmarkReceipts"]
            ),
            "claimBlockerCount": len(claim_blockers),
            "failureCount": len(failures),
        },
    }
    return report


def main() -> int:
    args = parse_args()
    root = REPO_ROOT
    try:
        schema = load_json(resolve_repo_path(args.schema, root))
        verify_files_root = (
            resolve_repo_path(args.verify_files_root, root).resolve()
            if args.verify_files_root
            else None
        )
        report = build_report(
            compiler_evidence_paths=list(args.compiler_evidence),
            lowering_link_receipt_paths=list(args.lowering_link_receipt),
            target_validation_paths=list(args.target_validation),
            phase_benchmark_paths=list(args.phase_benchmark_evidence),
            required_targets=list(args.required_targets),
            schema=schema,
            root=root,
            verify_files_root=verify_files_root,
            require_claimable=args.require_claimable,
        )
    except (OSError, UnicodeError, json.JSONDecodeError, ValueError) as exc:
        report = {
            "schemaVersion": 1,
            "artifactKind": "tint_compiler_frontier_bundle",
            "requiredTargets": [],
            "status": "fail",
            "claimabilityStatus": "blocked",
            "compilerEvidenceReports": [],
            "componentReceipts": {
                "loweringLinks": [],
                "targetValidations": [],
                "phaseBenchmarks": [],
            },
            "coverageByTarget": [],
            "claimBlockers": [],
            "failures": [failure("input_load_failed", "input", str(exc))],
            "summary": {
                "compilerEvidenceReportCount": 0,
                "loweringLinkReceiptCount": 0,
                "targetValidationReceiptCount": 0,
                "phaseBenchmarkReceiptCount": 0,
                "coveredTargetCount": 0,
                "claimBlockerCount": 0,
                "failureCount": 1,
            },
        }

    if args.out:
        out_path = resolve_repo_path(args.out, root)
        out_path.parent.mkdir(parents=True, exist_ok=True)
        out_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    if args.emit_json:
        print(json.dumps(report, indent=2))
    elif report["failures"]:
        print("FAIL: Tint compiler frontier bundle")
        for item in report["failures"]:
            print(f"- {item['code']}: {item['path']}: {item['message']}")
    else:
        print(
            "PASS: Tint compiler frontier bundle "
            f"({report['claimabilityStatus']})"
        )
    return 1 if report["failures"] else 0


if __name__ == "__main__":
    sys.exit(main())
