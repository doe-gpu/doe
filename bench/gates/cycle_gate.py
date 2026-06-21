#!/usr/bin/env python3
"""Cycle lock + rollback gate for claim-lane execution governance."""

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
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from bench.lib import compare_claim_artifacts as artifacts_mod
from bench.lib import output_paths
from bench.lib import report_conformance
from bench.lib.bench_utils import load_json_object as load_json
from bench.lib.config_validation import load_validated_config


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--cycle",
        default="config/claim-cycle.active.json",
        help="Cycle contract JSON path.",
    )
    parser.add_argument(
        "--report",
        default="",
        help="Optional compare-lane report path.",
    )
    parser.add_argument(
        "--substantiation-report",
        default="",
        help="Optional substantiation_gate report path.",
    )
    parser.add_argument(
        "--artifact-class",
        choices=["claim", "diagnostic"],
        default="claim",
        help="Artifact class for namespace policy checks.",
    )
    parser.add_argument(
        "--comparability-obligations",
        default="config/comparability-obligations.json",
        help="Canonical comparability-obligation contract path.",
    )
    parser.add_argument(
        "--backend-cutover-policy",
        default="config/backend-cutover-policy.json",
        help="Backend cutover policy path for rollback/cutover contract checks.",
    )
    parser.add_argument(
        "--out",
        default="bench/out/cycle_gate_report.json",
        help="Output gate report path.",
    )
    parser.add_argument(
        "--enforce-rollbacks",
        action=argparse.BooleanOptionalAction,
        default=True,
        help="Fail gate when enabled rollback flags are true.",
    )
    parser.add_argument(
        "--timestamp",
        default="",
        help=(
            "UTC suffix for output report path (YYYYMMDDTHHMMSSZ). "
            "Defaults to current UTC time when --timestamp-output is enabled."
        ),
    )
    parser.add_argument(
        "--timestamp-output",
        action=argparse.BooleanOptionalAction,
        default=True,
        help="Stamp output report path with a UTC timestamp suffix.",
    )
    return parser.parse_args()


def parse_int(value: Any) -> int | None:
    if isinstance(value, bool):
        return None
    if isinstance(value, int):
        return value
    if isinstance(value, float) and value.is_integer():
        return int(value)
    return None


def parse_float(value: Any) -> float | None:
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        return float(value)
    return None


def resolve_path(repo_root: Path, raw_path: str) -> Path:
    candidate = Path(raw_path)
    if candidate.is_absolute():
        return candidate.resolve()
    return (repo_root / candidate).resolve()


def normalize_rel(repo_root: Path, path: Path) -> str:
    try:
        return path.resolve().relative_to(repo_root).as_posix()
    except ValueError:
        return str(path.resolve())


def sum_trace_meta(workload: dict[str, Any], side: str, field: str) -> int:
    side_payload = workload.get(side)
    if not isinstance(side_payload, dict):
        return 0
    samples = side_payload.get("commandSamples")
    if not isinstance(samples, list):
        return 0
    total = 0
    for sample in samples:
        if not isinstance(sample, dict):
            continue
        trace_meta = sample.get("traceMeta")
        if not isinstance(trace_meta, dict):
            continue
        value = parse_int(trace_meta.get(field))
        if value is not None:
            total += value
    return total


def parse_cycle_contract(repo_root: Path, path: Path) -> tuple[dict[str, Any], list[str], list[str], dict[str, Any], list[str], list[str]]:
    failures: list[str] = []
    warnings: list[str] = []
    checks: dict[str, Any] = {
        "hashes": {},
        "workloadSet": {},
        "methodology": {},
        "milestones": {},
    }

    payload = load_validated_config(path)
    if parse_int(payload.get("schemaVersion")) != 1:
        failures.append("cycle schemaVersion must be 1")

    cycle_id = payload.get("cycleId")
    if not isinstance(cycle_id, str) or not cycle_id.strip():
        failures.append("cycleId missing/invalid")

    contracts = payload.get("contracts")
    if not isinstance(contracts, dict):
        failures.append("contracts missing/invalid")
        return payload, failures, warnings, checks, [], []

    contract_refs: dict[str, Path] = {}
    contract_hashes: dict[str, str] = {}
    for key in ("workloadContract", "benchmarkPolicy", "compareConfig", "substantiationPolicy"):
        ref = contracts.get(key)
        if not isinstance(ref, dict):
            failures.append(f"contracts.{key} missing/invalid")
            continue
        raw_path = ref.get("path")
        raw_hash = ref.get("sha256")
        if not isinstance(raw_path, str) or not raw_path.strip():
            failures.append(f"contracts.{key}.path missing/invalid")
            continue
        if not report_conformance.is_sha256_hex(raw_hash):
            failures.append(f"contracts.{key}.sha256 missing/invalid")
            continue
        resolved = resolve_path(repo_root, raw_path)
        contract_refs[key] = resolved
        contract_hashes[key] = raw_hash
        if not resolved.exists():
            failures.append(f"contracts.{key}.path does not exist: {resolved}")
            continue
        actual_hash = report_conformance.file_sha256(resolved)
        checks["hashes"][key] = {
            "path": normalize_rel(repo_root, resolved),
            "expectedSha256": raw_hash,
            "actualSha256": actual_hash,
            "match": raw_hash == actual_hash,
        }
        if actual_hash != raw_hash:
            failures.append(
                f"contracts.{key}.sha256 mismatch: expected={raw_hash} actual={actual_hash}"
            )

    comparable_ids: list[str] = []
    directional_ids: list[str] = []
    methodology = payload.get("methodology")

    workload_sets = payload.get("workloadSets")
    if not isinstance(workload_sets, dict):
        failures.append("workloadSets missing/invalid")
    else:
        comparable_raw = workload_sets.get("comparableIds")
        directional_raw = workload_sets.get("directionalIds")
        if not isinstance(comparable_raw, list) or not comparable_raw:
            failures.append("workloadSets.comparableIds missing/invalid")
        else:
            comparable_ids = sorted({str(item) for item in comparable_raw if isinstance(item, str) and item})
        if not isinstance(directional_raw, list):
            failures.append("workloadSets.directionalIds missing/invalid")
        else:
            directional_ids = sorted({str(item) for item in directional_raw if isinstance(item, str) and item})

    workload_contract_path = contract_refs.get("workloadContract")
    if workload_contract_path is not None and workload_contract_path.exists():
        workload_payload = load_json(workload_contract_path)
        workloads = workload_payload.get("workloads")
        if not isinstance(workloads, list):
            failures.append("workload contract missing workloads[]")
        else:
            selector = methodology.get("selector") if isinstance(methodology, dict) else None
            selected_rows = workloads
            if isinstance(selector, dict):
                cohort_filter = selector.get("cohorts", [])
                benchmark_class_filter = selector.get("benchmarkClass", [])
                claim_eligible_only = bool(selector.get("claimEligibleOnly", False))
                domain_filter = selector.get("domains", [])
                id_filter = selector.get("ids", [])
                exclude_ids = set(selector.get("excludeIds", []))
                filtered_rows: list[dict[str, Any]] = []
                for row in workloads:
                    if not isinstance(row, dict):
                        continue
                    workload_id = row.get("id")
                    if not isinstance(workload_id, str) or not workload_id:
                        continue
                    if workload_id in exclude_ids:
                        continue
                    if id_filter and workload_id not in id_filter:
                        continue
                    row_cohorts = row.get("cohorts", row.get("suiteTags", []))
                    if cohort_filter and not any(tag in cohort_filter for tag in row_cohorts):
                        continue
                    row_benchmark_class = row.get(
                        "benchmarkClass",
                        "comparable" if bool(row.get("comparable", False)) else "directional",
                    )
                    if benchmark_class_filter and row_benchmark_class not in benchmark_class_filter:
                        continue
                    if claim_eligible_only and not bool(row.get("claimEligible", True)):
                        continue
                    if domain_filter and row.get("domain") not in domain_filter:
                        continue
                    filtered_rows.append(row)
                selected_rows = filtered_rows
            expected_comparable = sorted(
                {
                    row.get("id")
                    for row in selected_rows
                    if isinstance(row, dict)
                    and isinstance(row.get("id"), str)
                    and row.get("id")
                    and bool(row.get("comparable", False))
                }
            )
            expected_directional = sorted(
                {
                    row.get("id")
                    for row in selected_rows
                    if isinstance(row, dict)
                    and isinstance(row.get("id"), str)
                    and row.get("id")
                    and not bool(row.get("comparable", False))
                }
            )
            checks["workloadSet"] = {
                "expectedComparableCount": len(expected_comparable),
                "expectedDirectionalCount": len(expected_directional),
                "declaredComparableCount": len(comparable_ids),
                "declaredDirectionalCount": len(directional_ids),
            }
            if comparable_ids != expected_comparable:
                missing = sorted(set(expected_comparable) - set(comparable_ids))
                extra = sorted(set(comparable_ids) - set(expected_comparable))
                failures.append(
                    "workloadSets.comparableIds mismatch with workload contract: "
                    f"missing={missing} extra={extra}"
                )
            if directional_ids != expected_directional:
                missing = sorted(set(expected_directional) - set(directional_ids))
                extra = sorted(set(directional_ids) - set(expected_directional))
                failures.append(
                    "workloadSets.directionalIds mismatch with workload contract: "
                    f"missing={missing} extra={extra}"
                )

    if not isinstance(methodology, dict):
        failures.append("methodology missing/invalid")
    else:
        compare_config_path = contract_refs.get("compareConfig")
        if compare_config_path is not None and compare_config_path.exists():
            config_payload = load_json(compare_config_path)
            run = config_payload.get("run") if isinstance(config_payload.get("run"), dict) else {}
            comparability = (
                config_payload.get("comparability")
                if isinstance(config_payload.get("comparability"), dict)
                else {}
            )
            claimability = (
                config_payload.get("claimability")
                if isinstance(config_payload.get("claimability"), dict)
                else {}
            )

            expected_pairs = [
                (
                    "iterations",
                    parse_int(methodology.get("iterations")),
                    parse_int(run.get("iterations")),
                ),
                (
                    "warmup",
                    parse_int(methodology.get("warmup")),
                    parse_int(run.get("warmup")),
                ),
                (
                    "comparabilityMode",
                    methodology.get("comparabilityMode"),
                    comparability.get("mode"),
                ),
                (
                    "requireTimingClass",
                    methodology.get("requireTimingClass"),
                    comparability.get("requireTimingClass"),
                ),
                (
                    "claimabilityMode",
                    methodology.get("claimabilityMode"),
                    claimability.get("mode"),
                ),
                (
                    "minTimedSamples",
                    parse_int(methodology.get("minTimedSamples")),
                    parse_int(claimability.get("minTimedSamples")),
                ),
            ]
            for field, expected, actual in expected_pairs:
                match = expected == actual
                checks["methodology"][field] = {
                    "expected": expected,
                    "actual": actual,
                    "match": match,
                }
                if not match:
                    failures.append(
                        f"methodology mismatch for {field}: expected={expected!r} actual={actual!r}"
                    )
            expected_selector = methodology.get("selector")
            actual_selector = (
                config_payload.get("selector")
                if isinstance(config_payload.get("selector"), dict)
                else None
            )
            selector_match = expected_selector == actual_selector
            checks["methodology"]["selector"] = {
                "expected": expected_selector,
                "actual": actual_selector,
                "match": selector_match,
            }
            if not selector_match:
                failures.append(
                    "methodology mismatch for selector: "
                    f"expected={expected_selector!r} actual={actual_selector!r}"
                )

    milestones = payload.get("milestones")
    if not isinstance(milestones, list) or not milestones:
        failures.append("milestones missing/invalid")
    else:
        milestone_ids: set[str] = set()
        for idx, milestone in enumerate(milestones):
            if not isinstance(milestone, dict):
                failures.append(f"milestones[{idx}] must be object")
                continue
            milestone_id = milestone.get("id")
            owner = milestone.get("owner")
            due_date = milestone.get("dueDate")
            kpis = milestone.get("kpis")
            if not isinstance(milestone_id, str) or not milestone_id:
                failures.append(f"milestones[{idx}].id missing/invalid")
            else:
                if milestone_id in milestone_ids:
                    failures.append(f"duplicate milestone id: {milestone_id}")
                milestone_ids.add(milestone_id)
            if not isinstance(owner, str) or not owner:
                failures.append(f"milestones[{idx}].owner missing/invalid")
            if not isinstance(due_date, str) or not due_date:
                failures.append(f"milestones[{idx}].dueDate missing/invalid")
            else:
                try:
                    datetime.strptime(due_date, "%Y-%m-%d")
                except ValueError:
                    failures.append(
                        f"milestones[{idx}].dueDate must be YYYY-MM-DD (found {due_date!r})"
                    )
            if not isinstance(kpis, list) or not kpis:
                failures.append(f"milestones[{idx}].kpis missing/invalid")

    return payload, failures, warnings, checks, comparable_ids, directional_ids


def check_artifact_namespace(
    *,
    repo_root: Path,
    artifact_path: Path,
    artifact_class: str,
    policy: dict[str, Any],
) -> tuple[bool, str]:
    normalized = normalize_rel(repo_root, artifact_path)
    canonical_prefix = policy.get("canonicalPrefix")
    canonical_disallow = policy.get("canonicalDisallowPrefixes")
    diagnostic_allowed = policy.get("diagnosticAllowedPrefixes")

    if not isinstance(canonical_prefix, str):
        return False, "artifactPolicy.canonicalPrefix missing/invalid"
    if not isinstance(canonical_disallow, list):
        return False, "artifactPolicy.canonicalDisallowPrefixes missing/invalid"
    if not isinstance(diagnostic_allowed, list):
        return False, "artifactPolicy.diagnosticAllowedPrefixes missing/invalid"

    if artifact_class == "claim":
        if not normalized.startswith(canonical_prefix):
            return False, (
                f"claim artifact path must start with {canonical_prefix!r} "
                f"(found {normalized!r})"
            )
        for prefix in canonical_disallow:
            if isinstance(prefix, str) and normalized.startswith(prefix):
                return False, (
                    f"claim artifact path must not start with {prefix!r} "
                    f"(found {normalized!r})"
                )
        return True, ""

    for prefix in diagnostic_allowed:
        if isinstance(prefix, str) and normalized.startswith(prefix):
            return True, ""
    return False, (
        "diagnostic artifact path must be under allowed prefixes "
        f"{diagnostic_allowed!r} (found {normalized!r})"
    )


def evaluate_report(
    *,
    repo_root: Path,
    report_path: Path,
    cycle_payload: dict[str, Any],
    comparable_ids: list[str],
    obligations_path: Path,
) -> tuple[dict[str, Any], list[str], list[str], dict[str, Any]]:
    failures: list[str] = []
    warnings: list[str] = []
    rollback_metrics: dict[str, Any] = {
        "unexpectedUnsupportedWorkloads": 0,
        "unexpectedErrorWorkloads": 0,
        "unexpectedNoExecutionWorkloads": 0,
        "missingAllowNoExecutionEvidenceWorkloads": 0,
        "tailNonPositiveWorkloads": 0,
    }

    compare_payload, claim_payload, claim_report_path = artifacts_mod.load_compare_bundle(
        report_path,
        require_claim=True,
    )
    assert claim_payload is not None
    assert claim_report_path is not None
    payload = artifacts_mod.projected_compare_report(
        compare_payload,
        report_path,
        claim_report=claim_payload,
    )

    expected_obligation_schema_version, expected_obligation_ids = report_conformance.load_obligation_contract(
        obligations_path
    )
    conformant, reason = report_conformance.validate_report_conformance(
        payload=compare_payload,
        report_path=report_path,
        repo_root=repo_root,
        expected_obligation_schema_version=expected_obligation_schema_version,
        expected_obligation_ids=expected_obligation_ids,
    )
    if not conformant:
        failures.append(f"report conformance failed: {reason}")
    claim_conformant, claim_reason = report_conformance.validate_claim_report_conformance(
        compare_payload=compare_payload,
        compare_report_path=report_path,
        claim_payload=claim_payload,
        claim_report_path=claim_report_path,
    )
    if not claim_conformant:
        failures.append(f"claim report conformance failed: {claim_reason}")

    cycle_contracts = cycle_payload.get("contracts")
    workload_contract = cycle_contracts.get("workloadContract") if isinstance(cycle_contracts, dict) else {}
    benchmark_policy = cycle_contracts.get("benchmarkPolicy") if isinstance(cycle_contracts, dict) else {}

    report_workload_contract = payload.get("workloadContract")
    if not isinstance(report_workload_contract, dict):
        failures.append("report missing workloadContract object")
    else:
        expected_sha = workload_contract.get("sha256")
        actual_sha = report_workload_contract.get("sha256")
        if expected_sha != actual_sha:
            failures.append(
                "report workloadContract.sha256 mismatch with cycle: "
                f"expected={expected_sha!r} actual={actual_sha!r}"
            )

    report_benchmark_policy = payload.get("benchmarkPolicy")
    if not isinstance(report_benchmark_policy, dict):
        failures.append("report missing benchmarkPolicy object")
    else:
        expected_sha = benchmark_policy.get("sha256")
        actual_sha = report_benchmark_policy.get("sha256")
        if expected_sha != actual_sha:
            failures.append(
                "report benchmarkPolicy.sha256 mismatch with cycle: "
                f"expected={expected_sha!r} actual={actual_sha!r}"
            )

    workloads = payload.get("workloads")
    if not isinstance(workloads, list):
        failures.append("report missing workloads[]")
        workloads = []
    report_ids = sorted(
        {
            row.get("id")
            for row in workloads
            if isinstance(row, dict) and isinstance(row.get("id"), str)
        }
    )
    if report_ids != sorted(comparable_ids):
        missing = sorted(set(comparable_ids) - set(report_ids))
        extra = sorted(set(report_ids) - set(comparable_ids))
        failures.append(
            "report workload IDs do not match cycle comparable set: "
            f"missing={missing} extra={extra}"
        )

    comparison_status = payload.get("comparisonStatus")
    claim_status = payload.get("claimStatus")
    comparability_summary = (
        payload.get("comparabilitySummary")
        if isinstance(payload.get("comparabilitySummary"), dict)
        else {}
    )
    claimability_summary = (
        payload.get("claimabilitySummary")
        if isinstance(payload.get("claimabilitySummary"), dict)
        else {}
    )

    non_comparable_count = parse_int(comparability_summary.get("nonComparableCount"))
    non_claimable_count = parse_int(claimability_summary.get("nonClaimableCount"))
    if non_comparable_count is None:
        non_comparable_count = 0
    if non_claimable_count is None:
        non_claimable_count = 0

    if comparison_status != "comparable":
        failures.append(f"report comparisonStatus must be 'comparable' (found {comparison_status!r})")
    if claim_status != "claimable":
        failures.append(f"report claimStatus must be 'claimable' (found {claim_status!r})")
    if non_comparable_count != 0:
        failures.append(f"report nonComparableCount must be 0 (found {non_comparable_count})")
    if non_claimable_count != 0:
        failures.append(f"report nonClaimableCount must be 0 (found {non_claimable_count})")

    for workload in workloads:
        if not isinstance(workload, dict):
            continue
        workload_id = workload.get("id")
        if not isinstance(workload_id, str) or workload_id not in comparable_ids:
            continue

        success = sum_trace_meta(workload, "baseline", "executionSuccessCount")
        unsupported = sum_trace_meta(workload, "baseline", "executionUnsupportedCount")
        error = sum_trace_meta(workload, "baseline", "executionErrorCount")
        allow_baseline_no_execution = bool(workload.get("workloadAllowBaselineNoExecution", False))

        if error > 0:
            rollback_metrics["unexpectedErrorWorkloads"] += 1
        if success <= 0:
            if allow_baseline_no_execution:
                if unsupported <= 0:
                    rollback_metrics["missingAllowNoExecutionEvidenceWorkloads"] += 1
            else:
                rollback_metrics["unexpectedNoExecutionWorkloads"] += 1
        if unsupported > 0:
            if not (allow_baseline_no_execution and success <= 0 and error == 0):
                rollback_metrics["unexpectedUnsupportedWorkloads"] += 1

        delta = workload.get("deltaPercent")
        p50 = p95 = p99 = None
        if isinstance(delta, dict):
            p50 = parse_float(delta.get("p50Percent"))
            p95 = parse_float(delta.get("p95Percent"))
            p99 = parse_float(delta.get("p99Percent"))
        if (
            p50 is None
            or p95 is None
            or p99 is None
            or p50 <= 0.0
            or p95 <= 0.0
            or p99 <= 0.0
        ):
            rollback_metrics["tailNonPositiveWorkloads"] += 1

    report_summary = {
        "comparisonStatus": comparison_status,
        "claimStatus": claim_status,
        "nonComparableCount": non_comparable_count,
        "nonClaimableCount": non_claimable_count,
        "workloadCount": len(workloads),
        "workloadIdCount": len(report_ids),
        "claimReportPath": str(claim_report_path),
    }

    return payload, failures, warnings, {"summary": report_summary, "rollbackMetrics": rollback_metrics}


def evaluate_substantiation_report(path: Path) -> tuple[dict[str, Any], list[str]]:
    failures: list[str] = []
    payload = load_json(path)
    passed = payload.get("pass")
    if passed is not True:
        failures.append("substantiation report indicates pass=false")
    return payload, failures


def main() -> int:
    args = parse_args()
    repo_root = REPO_ROOT

    cycle_path = resolve_path(repo_root, args.cycle)
    if not cycle_path.exists():
        print(f"FAIL: missing cycle contract: {cycle_path}")
        return 1
    backend_cutover_policy_path = resolve_path(repo_root, args.backend_cutover_policy)
    if not backend_cutover_policy_path.exists():
        print(f"FAIL: missing backend cutover policy: {backend_cutover_policy_path}")
        return 1

    output_timestamp = output_paths.resolve_timestamp(args.timestamp) if args.timestamp_output else ""
    out_path = output_paths.with_timestamp(args.out, output_timestamp, enabled=args.timestamp_output)

    failures: list[str] = []
    warnings: list[str] = []

    cycle_payload, cycle_failures, cycle_warnings, checks, comparable_ids, directional_ids = parse_cycle_contract(
        repo_root, cycle_path
    )
    failures.extend(cycle_failures)
    warnings.extend(cycle_warnings)
    try:
        backend_cutover_policy = load_json(backend_cutover_policy_path)
    except (OSError, UnicodeError, json.JSONDecodeError, ValueError) as exc:
        print(f"FAIL: invalid backend cutover policy: {exc}")
        return 1
    if parse_int(backend_cutover_policy.get("schemaVersion")) != 1:
        failures.append("backend cutover policy schemaVersion must be 1")
    checks["backendCutoverPolicy"] = {
        "path": normalize_rel(repo_root, backend_cutover_policy_path),
        "cutoverTargetLane": (
            backend_cutover_policy.get("cutover", {}).get("targetLane")
            if isinstance(backend_cutover_policy.get("cutover"), dict)
            else ""
        ),
        "rollbackSwitchName": (
            backend_cutover_policy.get("rollback", {}).get("switchName")
            if isinstance(backend_cutover_policy.get("rollback"), dict)
            else ""
        ),
    }

    artifact_path: Path | None = None
    artifact_policy = cycle_payload.get("artifactPolicy") if isinstance(cycle_payload, dict) else {}
    artifact_namespace_violation = False

    report_payload: dict[str, Any] | None = None
    report_evaluation: dict[str, Any] = {}
    report_failures: list[str] = []
    report_warnings: list[str] = []

    if args.report:
        artifact_path = resolve_path(repo_root, args.report)
        if not artifact_path.exists():
            failures.append(f"missing report artifact: {artifact_path}")
        else:
            ok, reason = check_artifact_namespace(
                repo_root=repo_root,
                artifact_path=artifact_path,
                artifact_class=args.artifact_class,
                policy=artifact_policy if isinstance(artifact_policy, dict) else {},
            )
            if not ok:
                artifact_namespace_violation = True
                report_failures.append(reason)

            obligations_path = resolve_path(repo_root, args.comparability_obligations)
            if not obligations_path.exists():
                report_failures.append(f"missing comparability obligations contract: {obligations_path}")
            else:
                try:
                    report_payload, eval_failures, eval_warnings, eval_checks = evaluate_report(
                        repo_root=repo_root,
                        report_path=artifact_path,
                        cycle_payload=cycle_payload,
                        comparable_ids=comparable_ids,
                        obligations_path=obligations_path,
                    )
                    report_failures.extend(eval_failures)
                    report_warnings.extend(eval_warnings)
                    report_evaluation = eval_checks
                except (OSError, UnicodeError, json.JSONDecodeError, ValueError) as exc:
                    report_failures.append(f"failed to evaluate report: {exc}")

    substantiation_payload: dict[str, Any] | None = None
    substantiation_failures: list[str] = []
    if args.substantiation_report:
        subst_path = resolve_path(repo_root, args.substantiation_report)
        if not subst_path.exists():
            substantiation_failures.append(f"missing substantiation report: {subst_path}")
        else:
            try:
                substantiation_payload, subst_failures = evaluate_substantiation_report(subst_path)
                substantiation_failures.extend(subst_failures)
            except (OSError, UnicodeError, json.JSONDecodeError, ValueError) as exc:
                substantiation_failures.append(f"failed to parse substantiation report: {exc}")

    rollback_criteria = cycle_payload.get("rollbackCriteria") if isinstance(cycle_payload, dict) else {}
    attestations = cycle_payload.get("attestations") if isinstance(cycle_payload, dict) else {}

    rollback_flags = {
        "runtimeUnexpectedStatus": False,
        "comparableNonClaimable": False,
        "comparabilityMismatch": False,
        "schemaMigrationStatusProcessMissing": False,
        "substantiationWindowFailure": False,
        "artifactNamespaceViolation": artifact_namespace_violation,
        "browserPromotionWithoutSchemaObligation": False,
    }

    rollback_metrics = report_evaluation.get("rollbackMetrics") if isinstance(report_evaluation, dict) else {}
    if isinstance(rollback_metrics, dict):
        rollback_flags["runtimeUnexpectedStatus"] = (
            int(rollback_metrics.get("unexpectedUnsupportedWorkloads", 0)) > 0
            or int(rollback_metrics.get("unexpectedErrorWorkloads", 0)) > 0
            or int(rollback_metrics.get("unexpectedNoExecutionWorkloads", 0)) > 0
            or int(rollback_metrics.get("missingAllowNoExecutionEvidenceWorkloads", 0)) > 0
        )
        rollback_flags["comparableNonClaimable"] = (
            int(rollback_metrics.get("tailNonPositiveWorkloads", 0)) > 0
        )

    if isinstance(report_evaluation.get("summary"), dict):
        summary = report_evaluation["summary"]
        rollback_flags["comparabilityMismatch"] = (
            summary.get("comparisonStatus") != "comparable"
            or int(summary.get("nonComparableCount", 0)) > 0
        )
        rollback_flags["comparableNonClaimable"] = rollback_flags["comparableNonClaimable"] or (
            summary.get("claimStatus") != "claimable"
            or int(summary.get("nonClaimableCount", 0)) > 0
        )

    rollback_flags["schemaMigrationStatusProcessMissing"] = not bool(
        attestations.get("schemaMigrationStatusProcessComplete", False)
    )
    rollback_flags["substantiationWindowFailure"] = len(substantiation_failures) > 0

    if args.artifact_class == "claim" and artifact_path is not None:
        rel = normalize_rel(repo_root, artifact_path).lower()
        rollback_flags["browserPromotionWithoutSchemaObligation"] = (
            "browser" in rel or "chromium" in rel
        )

    enabled_rollback_flags: dict[str, bool] = {}
    for key, value in rollback_flags.items():
        enabled = bool(rollback_criteria.get(key, False)) if isinstance(rollback_criteria, dict) else False
        enabled_rollback_flags[key] = enabled and value

    if args.enforce_rollbacks:
        for key, value in enabled_rollback_flags.items():
            if value:
                failures.append(f"rollback criterion triggered: {key}")

    failures.extend(report_failures)
    warnings.extend(report_warnings)
    failures.extend(substantiation_failures)

    result = {
        "schemaVersion": 1,
        "generatedAtUtc": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        "outputTimestamp": output_timestamp,
        "cyclePath": normalize_rel(repo_root, cycle_path),
        "cycleId": cycle_payload.get("cycleId") if isinstance(cycle_payload, dict) else "",
        "artifactClass": args.artifact_class,
        "reportPath": normalize_rel(repo_root, artifact_path) if artifact_path is not None else "",
        "substantiationReportPath": (
            normalize_rel(repo_root, resolve_path(repo_root, args.substantiation_report))
            if args.substantiation_report
            else ""
        ),
        "workloadSets": {
            "comparableCount": len(comparable_ids),
            "directionalCount": len(directional_ids),
            "comparableIds": comparable_ids,
            "directionalIds": directional_ids,
        },
        "checks": checks,
        "reportEvaluation": report_evaluation,
        "rollbackFlags": rollback_flags,
        "enabledRollbackFlags": enabled_rollback_flags,
        "failures": failures,
        "warnings": warnings,
        "pass": len(failures) == 0,
    }
    if substantiation_payload is not None:
        result["substantiationSummary"] = {
            "pass": substantiation_payload.get("pass"),
            "reportCount": substantiation_payload.get("reportCount"),
            "qualifyingReportCount": substantiation_payload.get("qualifyingReportCount"),
            "uniqueLeftProfileCount": substantiation_payload.get("uniqueLeftProfileCount"),
        }

    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    output_paths.write_run_manifest_for_outputs(
        [out_path],
        {
            "runType": "cycle_gate",
            "config": {
                "cycle": normalize_rel(repo_root, cycle_path),
                "artifactClass": args.artifact_class,
                "enforceRollbacks": args.enforce_rollbacks,
            },
            "fullRun": bool(args.report),
            "claimGateRan": False,
            "dropinGateRan": False,
            "reportPath": str(out_path),
            "status": "passed" if result["pass"] else "failed",
        },
    )

    if result["pass"]:
        print("PASS: cycle gate")
        print(f"report: {out_path}")
        return 0

    print("FAIL: cycle gate")
    for failure in failures:
        print(f"  {failure}")
    if warnings:
        print("WARN:")
        for warning in warnings:
            print(f"  {warning}")
    print(f"report: {out_path}")
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
