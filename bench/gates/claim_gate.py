#!/usr/bin/env python3
"""Release hard-gate for compare reports plus claim sidecars."""

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

from bench.gates.claim_comparability import workload_comparability_failures
from bench.lib import compare_claim_artifacts as artifacts_mod
from bench.lib import report_conformance
from native_compare_modules.claimability import assess_suspicious_speedup
from native_compare_modules.config_support import (
    load_benchmark_methodology_policy,
    load_workloads,
)


VALID_COMPARISON_STATUSES = {"comparable", "diagnostic"}
VALID_CLAIM_STATUSES = {"claimable", "diagnostic"}
VALID_CLAIMABILITY_MODES = {"local", "release"}
VALID_BENCHMARK_CLASSES = {"comparable", "directional"}
RELEASE_REQUIRED_POSITIVE_PERCENTILES = ["p50Percent", "p95Percent", "p99Percent"]
LOCAL_REQUIRED_POSITIVE_PERCENTILES = ["p50Percent", "p95Percent"]
DOE_PACKAGE_EXECUTION_BACKENDS = {
    "doe_bun_package",
    "doe_node_native_direct",
    "doe_node_webgpu",
}
DOE_PACKAGE_PRODUCT_PREFIXES = (
    "doe_gpu_bun_package",
    "doe_gpu_node_native_direct",
    "doe_gpu_node_package",
)
DOE_PACKAGE_REQUIRED_BOOL_FIELDS = (
    "packagePreparedSession",
    "packageSetupIncludedInSelectedTiming",
)
DOE_PACKAGE_REQUIRED_STRING_FIELDS = ("packageReadbackMode",)
DOE_PACKAGE_REQUIRED_OBJECT_FIELDS = (
    "packageFastPathStats",
    "packageNativeFastPaths",
    "packageStepBreakdownNs",
    "packageWriteBreakdown",
)
DOE_PACKAGE_WRITE_BREAKDOWN_COUNTER_FIELDS = (
    "batchCallCount",
    "batchedWriteCount",
    "dynamicWriteBytes",
    "dynamicWriteCount",
    "staticBufferLoadBytes",
    "staticBufferLoadCount",
    "totalBytes",
    "totalCount",
    "unbatchedWriteCount",
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--report",
        default="bench/out/dawn-vs-doe.compare.json",
        help="Comparison report produced by the compare lane.",
    )
    parser.add_argument(
        "--claim-report",
        default="",
        help="Optional explicit claim report path. Defaults to sibling .claim.json.",
    )
    parser.add_argument(
        "--require-comparison-status",
        default="comparable",
        help="Required top-level comparisonStatus value.",
    )
    parser.add_argument(
        "--require-claim-status",
        default="claimable",
        help="Required top-level claimStatus value.",
    )
    parser.add_argument(
        "--require-claimability-mode",
        default="release",
        help="Required claimPolicy.mode value.",
    )
    parser.add_argument(
        "--require-min-timed-samples",
        type=int,
        default=15,
        help="Minimum claimPolicy.minTimedSamples value.",
    )
    parser.add_argument(
        "--comparability-obligations",
        default="config/comparability-obligations.json",
        help="Canonical comparability-obligation contract path.",
    )
    parser.add_argument(
        "--config",
        default="",
        help=(
            "Optional compare config. When supplied with --require-workload-id-set-match, "
            "expected workload IDs are scoped by the config selector."
        ),
    )
    parser.add_argument(
        "--expected-workload-contract",
        default="",
        help=(
            "Optional workload contract JSON. When provided with hash/id checks, "
            "gate validates compare workload manifest hash and expected comparable workload IDs."
        ),
    )
    parser.add_argument(
        "--require-workload-contract-hash",
        action="store_true",
        help="Require compare workload manifest path/sha256 to match --expected-workload-contract.",
    )
    parser.add_argument(
        "--require-workload-id-set-match",
        action="store_true",
        help=(
            "Require compare workload IDs to exactly match comparable workload IDs from "
            "--expected-workload-contract."
        ),
    )
    parser.add_argument(
        "--require-backend-telemetry",
        action="store_true",
        help="Require backend selection telemetry on successful baseline-side samples.",
    )
    parser.add_argument(
        "--expected-backend-id",
        default="",
        help="Expected baseline-side backendId for successful samples when telemetry is required.",
    )
    return parser.parse_args()


def fail(message: str) -> None:
    print(f"FAIL: {message}")


def parse_int(value: Any) -> int | None:
    if isinstance(value, bool):
        return None
    if isinstance(value, int):
        return value
    return None


def parse_float(value: Any) -> float | None:
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        return float(value)
    return None


def parse_string_list(value: Any) -> list[str] | None:
    if not isinstance(value, list):
        return None
    parsed: list[str] = []
    for item in value:
        if not isinstance(item, str) or not item:
            return None
        parsed.append(item)
    return parsed


def expected_positive_percentiles_for_mode(mode: str) -> list[str]:
    if mode == "release":
        return RELEASE_REQUIRED_POSITIVE_PERCENTILES
    if mode == "local":
        return LOCAL_REQUIRED_POSITIVE_PERCENTILES
    return []


def suspicious_speedup_failures(
    *,
    workload_id: str,
    baseline_stats: dict[str, Any],
    comparison_stats: dict[str, Any],
    suspicious_speedup_ratio: float,
) -> list[str]:
    return [
        f"{workload_id}: {reason}"
        for reason in assess_suspicious_speedup(
            left_stats=baseline_stats,
            right_stats=comparison_stats,
            claim_metric_scope="selectedTiming",
            suspicious_speedup_ratio=suspicious_speedup_ratio,
        )
    ]


def workload_runtime_hint(workload: dict[str, Any]) -> str:
    workload_id = str(workload.get("id", "unknown"))
    claimability = workload.get("claimability")
    delta = workload.get("deltaPercent")
    baseline = workload.get("baseline")
    comparison = workload.get("comparison")

    reasons: list[str] = []
    if isinstance(claimability, dict):
        raw_reasons = claimability.get("reasons")
        if isinstance(raw_reasons, list):
            reasons = [str(item) for item in raw_reasons if isinstance(item, str)]

    delta_p50 = None
    delta_p95 = None
    if isinstance(delta, dict):
        delta_p50 = parse_float(delta.get("p50Percent"))
        delta_p95 = parse_float(delta.get("p95Percent"))

    baseline_p50 = None
    comparison_p50 = None
    baseline_source = "unknown"
    comparison_source = "unknown"
    if isinstance(baseline, dict):
        stats = baseline.get("stats")
        if isinstance(stats, dict):
            baseline_p50 = parse_float(stats.get("p50Ms"))
        sources = baseline.get("timingSources")
        if isinstance(sources, list) and sources:
            baseline_source = str(sources[0])
    if isinstance(comparison, dict):
        stats = comparison.get("stats")
        if isinstance(stats, dict):
            comparison_p50 = parse_float(stats.get("p50Ms"))
        sources = comparison.get("timingSources")
        if isinstance(sources, list) and sources:
            comparison_source = str(sources[0])

    parts: list[str] = [f"{workload_id}"]
    if delta_p50 is not None:
        parts.append(f"deltaP50={delta_p50:.6f}%")
    if delta_p95 is not None:
        parts.append(f"deltaP95={delta_p95:.6f}%")
    if baseline_p50 is not None:
        parts.append(f"baselineP50Ms={baseline_p50:.9f}")
    if comparison_p50 is not None:
        parts.append(f"comparisonP50Ms={comparison_p50:.9f}")
    parts.append(f"baselineTiming={baseline_source}")
    parts.append(f"comparisonTiming={comparison_source}")
    if reasons:
        parts.append("reasons=" + " | ".join(reasons))
    return ", ".join(parts)


def workload_is_dawn_vs_doe(workload: dict[str, Any]) -> bool:
    def collect_execution_backends(side_payload: Any) -> set[str]:
        if not isinstance(side_payload, dict):
            return set()
        samples = side_payload.get("commandSamples")
        if not isinstance(samples, list):
            return set()
        return {
            str(trace_meta.get("executionBackend"))
            for sample in samples
            if isinstance(sample, dict)
            for trace_meta in [sample.get("traceMeta", {})]
            if isinstance(trace_meta, dict) and trace_meta.get("executionBackend")
        }

    baseline_backends = collect_execution_backends(workload.get("baseline"))
    comparison_backends = collect_execution_backends(workload.get("comparison"))
    baseline_dawn = "dawn_delegate" in baseline_backends or "dawn-perf-tests" in baseline_backends
    comparison_dawn = (
        "dawn_delegate" in comparison_backends or "dawn-perf-tests" in comparison_backends
    )
    baseline_doe = any(
        backend in baseline_backends
        for backend in ("doe_metal", "doe_vulkan", "doe_d3d12", "webgpu-ffi", "native")
    )
    comparison_doe = any(
        backend in comparison_backends
        for backend in ("doe_metal", "doe_vulkan", "doe_d3d12", "webgpu-ffi", "native")
    )
    return (baseline_dawn and comparison_doe) or (baseline_doe and comparison_dawn)


def _successful_trace_metas(side_payload: Any) -> list[tuple[int, dict[str, Any]]]:
    if not isinstance(side_payload, dict):
        return []
    samples = side_payload.get("commandSamples")
    if not isinstance(samples, list):
        return []
    trace_metas: list[tuple[int, dict[str, Any]]] = []
    for sample_idx, sample in enumerate(samples):
        if not isinstance(sample, dict):
            continue
        if sample.get("returnCode") != 0:
            continue
        trace_meta = sample.get("traceMeta")
        if isinstance(trace_meta, dict):
            trace_metas.append((sample_idx, trace_meta))
    return trace_metas


def _side_declares_doe_package(side_payload: Any) -> bool:
    if not isinstance(side_payload, dict):
        return False
    product_name = str(side_payload.get("name", "")).strip()
    if product_name.startswith(DOE_PACKAGE_PRODUCT_PREFIXES):
        return True
    for _, trace_meta in _successful_trace_metas(side_payload):
        execution_backend = str(trace_meta.get("executionBackend", "")).strip()
        if execution_backend in DOE_PACKAGE_EXECUTION_BACKENDS:
            return True
    return False


def _non_negative_number_dict(value: Any) -> bool:
    if not isinstance(value, dict) or not value:
        return False
    for item in value.values():
        if isinstance(item, bool):
            return False
        if not isinstance(item, (int, float)):
            return False
        if float(item) < 0.0:
            return False
    return True


def _non_negative_number(value: Any) -> bool:
    if isinstance(value, bool):
        return False
    if not isinstance(value, (int, float)):
        return False
    return float(value) >= 0.0


def _bool_dict(value: Any) -> bool:
    if not isinstance(value, dict) or not value:
        return False
    return all(isinstance(item, bool) for item in value.values())


def package_write_breakdown_failures(
    *,
    workload_id: str,
    side_name: str,
    sample_idx: int,
    value: Any,
) -> list[str]:
    prefix = f"{workload_id}: {side_name} sample {sample_idx}"
    if not isinstance(value, dict) or not value:
        return [f"{prefix} missing packageWriteBreakdown object"]

    failures: list[str] = []
    batch_method = value.get("batchMethod")
    if not isinstance(batch_method, str) or not batch_method.strip():
        failures.append(f"{prefix} missing packageWriteBreakdown.batchMethod string")

    for field_name in DOE_PACKAGE_WRITE_BREAKDOWN_COUNTER_FIELDS:
        if not _non_negative_number(value.get(field_name)):
            failures.append(
                f"{prefix} missing packageWriteBreakdown.{field_name} "
                "non-negative number"
            )

    by_data_kind = value.get("byDataKind")
    if not isinstance(by_data_kind, dict) or not by_data_kind:
        failures.append(f"{prefix} missing packageWriteBreakdown.byDataKind object")
    by_semantic_phase = value.get("bySemanticPhase")
    if not isinstance(by_semantic_phase, dict) or not by_semantic_phase:
        failures.append(f"{prefix} missing packageWriteBreakdown.bySemanticPhase object")

    if failures:
        return failures

    total_count = value["totalCount"]
    batched_count = value["batchedWriteCount"]
    unbatched_count = value["unbatchedWriteCount"]
    static_count = value["staticBufferLoadCount"]
    dynamic_count = value["dynamicWriteCount"]
    total_bytes = value["totalBytes"]
    static_bytes = value["staticBufferLoadBytes"]
    dynamic_bytes = value["dynamicWriteBytes"]
    batch_call_count = value["batchCallCount"]

    if batched_count + unbatched_count != total_count:
        failures.append(
            f"{prefix} packageWriteBreakdown batched+unbatched count "
            "must equal totalCount"
        )
    if static_count + dynamic_count != total_count:
        failures.append(
            f"{prefix} packageWriteBreakdown static+dynamic count "
            "must equal totalCount"
        )
    if static_bytes + dynamic_bytes != total_bytes:
        failures.append(
            f"{prefix} packageWriteBreakdown static+dynamic bytes "
            "must equal totalBytes"
        )
    if batch_method == "none":
        if batched_count != 0 or batch_call_count != 0:
            failures.append(
                f"{prefix} packageWriteBreakdown batchMethod=none requires "
                "zero batchedWriteCount and batchCallCount"
            )
    elif batched_count <= 0 or batch_call_count <= 0:
        failures.append(
            f"{prefix} packageWriteBreakdown batchMethod={batch_method!r} "
            "requires positive batchedWriteCount and batchCallCount"
        )
    return failures


def doe_package_telemetry_failures(
    *,
    workload_id: str,
    side_name: str,
    side_payload: Any,
) -> list[str]:
    if not _side_declares_doe_package(side_payload):
        return []

    failures: list[str] = []
    trace_metas = _successful_trace_metas(side_payload)
    if not trace_metas:
        return [
            f"{workload_id}: {side_name} Doe package payload has no successful traceMeta samples"
        ]

    observed_doe_package_sample = False
    for sample_idx, trace_meta in trace_metas:
        execution_backend = str(trace_meta.get("executionBackend", "")).strip()
        if execution_backend not in DOE_PACKAGE_EXECUTION_BACKENDS:
            failures.append(
                f"{workload_id}: {side_name} sample {sample_idx} "
                f"executionBackend={execution_backend!r} is not a Doe package backend"
            )
            continue
        observed_doe_package_sample = True

        for field_name in DOE_PACKAGE_REQUIRED_BOOL_FIELDS:
            if not isinstance(trace_meta.get(field_name), bool):
                failures.append(
                    f"{workload_id}: {side_name} sample {sample_idx} "
                    f"missing {field_name} bool"
                )
        for field_name in DOE_PACKAGE_REQUIRED_STRING_FIELDS:
            value = trace_meta.get(field_name)
            if not isinstance(value, str) or not value.strip():
                failures.append(
                    f"{workload_id}: {side_name} sample {sample_idx} "
                    f"missing {field_name} string"
                )
        for field_name in DOE_PACKAGE_REQUIRED_OBJECT_FIELDS:
            value = trace_meta.get(field_name)
            if field_name == "packageNativeFastPaths":
                if not _bool_dict(value):
                    failures.append(
                        f"{workload_id}: {side_name} sample {sample_idx} "
                        "missing packageNativeFastPaths boolean map"
                    )
            elif field_name in {"packageFastPathStats", "packageStepBreakdownNs"}:
                if not _non_negative_number_dict(value):
                    failures.append(
                        f"{workload_id}: {side_name} sample {sample_idx} "
                        f"missing {field_name} non-negative numeric map"
                    )
            elif field_name == "packageWriteBreakdown":
                failures.extend(
                    package_write_breakdown_failures(
                        workload_id=workload_id,
                        side_name=side_name,
                        sample_idx=sample_idx,
                        value=value,
                    )
                )
            elif not isinstance(value, dict) or not value:
                failures.append(
                    f"{workload_id}: {side_name} sample {sample_idx} "
                    f"missing {field_name} object"
                )

    if not observed_doe_package_sample:
        failures.append(
            f"{workload_id}: {side_name} payload did not report a Doe package backend"
        )
    return failures


def load_expected_comparable_workload_ids(path: Path, config_path: Path | None = None) -> set[str]:
    if config_path is not None:
        config_payload = json.loads(config_path.read_text(encoding="utf-8"))
        if not isinstance(config_payload, dict):
            raise ValueError(f"invalid compare config: expected top-level object at {config_path}")
        run_config = config_payload.get("run")
        if not isinstance(run_config, dict):
            run_config = {}
        selector = config_payload.get("selector")
        if selector is not None and not isinstance(selector, dict):
            raise ValueError(f"invalid compare config: selector must be an object in {config_path}")
        workload_filter_raw = run_config.get("workloadFilter", "")
        workload_filter = workload_filter_raw if isinstance(workload_filter_raw, str) else ""
        workloads = load_workloads(
            path,
            workload_filter=workload_filter,
            include_noncomparable=True,
            include_extended=True,
            workload_cohort="all",
            selector=selector,
        )
        workload_ids = {
            workload.id
            for workload in workloads
            if workload.comparable and workload.benchmark_class == "comparable"
        }
        if not workload_ids:
            raise ValueError(
                f"invalid workload contract/config: no comparable workload IDs selected by {config_path}"
            )
        return workload_ids

    raw_workloads = load_workload_contract_rows(path).values()
    workload_ids: set[str] = set()
    for row in raw_workloads:
        workload_id = row.get("id")
        if not isinstance(workload_id, str) or not workload_id:
            continue
        comparable = bool(row.get("comparable", False))
        benchmark_class_raw = row.get("benchmarkClass")
        if benchmark_class_raw is None:
            benchmark_class = "comparable" if comparable else "directional"
        else:
            benchmark_class = str(benchmark_class_raw).strip().lower()
        if benchmark_class not in VALID_BENCHMARK_CLASSES:
            raise ValueError(
                f"invalid workload contract: {workload_id} benchmarkClass must be one of "
                f"{sorted(VALID_BENCHMARK_CLASSES)}"
            )
        if benchmark_class == "comparable" and not comparable:
            raise ValueError(
                f"invalid workload contract: {workload_id} benchmarkClass=comparable requires comparable=true"
            )
        if benchmark_class == "directional" and comparable:
            raise ValueError(
                f"invalid workload contract: {workload_id} benchmarkClass=directional requires comparable=false"
            )
        if benchmark_class == "comparable" and comparable:
            workload_ids.add(workload_id)
    if not workload_ids:
        raise ValueError(f"invalid workload contract: no comparable workload IDs in {path}")
    return workload_ids


def load_workload_contract_rows(path: Path) -> dict[str, dict[str, Any]]:
    return report_conformance.load_contract_workloads_by_id(path)


def main() -> int:
    args = parse_args()
    repo_root = REPO_ROOT
    report_path = Path(args.report)
    obligation_contract_path = Path(args.comparability_obligations)
    if not obligation_contract_path.is_absolute():
        obligation_contract_path = repo_root / obligation_contract_path
    expected_workload_contract_path = (
        Path(args.expected_workload_contract)
        if isinstance(args.expected_workload_contract, str) and args.expected_workload_contract.strip()
        else None
    )
    if expected_workload_contract_path is not None and not expected_workload_contract_path.is_absolute():
        expected_workload_contract_path = (repo_root / expected_workload_contract_path).resolve()
    compare_config_path = (
        Path(args.config)
        if isinstance(args.config, str) and args.config.strip()
        else None
    )
    if compare_config_path is not None and not compare_config_path.is_absolute():
        compare_config_path = (repo_root / compare_config_path).resolve()
    if not report_path.exists():
        fail(f"missing report: {report_path}")
        return 1
    if not obligation_contract_path.exists():
        fail(f"missing comparability obligation contract: {obligation_contract_path}")
        return 1
    if (args.require_workload_contract_hash or args.require_workload_id_set_match) and (
        expected_workload_contract_path is None
    ):
        fail(
            "--require-workload-contract-hash/--require-workload-id-set-match requires "
            "--expected-workload-contract"
        )
        return 1
    if expected_workload_contract_path is not None and not expected_workload_contract_path.exists():
        fail(f"missing expected workload contract: {expected_workload_contract_path}")
        return 1
    if compare_config_path is not None and not compare_config_path.exists():
        fail(f"missing compare config: {compare_config_path}")
        return 1

    if args.require_comparison_status not in VALID_COMPARISON_STATUSES:
        fail(
            "invalid --require-comparison-status="
            f"{args.require_comparison_status} expected one of {sorted(VALID_COMPARISON_STATUSES)}"
        )
        return 1
    if args.require_claim_status not in VALID_CLAIM_STATUSES:
        fail(
            "invalid --require-claim-status="
            f"{args.require_claim_status} expected one of {sorted(VALID_CLAIM_STATUSES)}"
        )
        return 1
    if args.require_claimability_mode not in VALID_CLAIMABILITY_MODES:
        fail(
            "invalid --require-claimability-mode="
            f"{args.require_claimability_mode} expected one of {sorted(VALID_CLAIMABILITY_MODES)}"
        )
        return 1
    if args.require_min_timed_samples < 0:
        fail(
            "invalid --require-min-timed-samples="
            f"{args.require_min_timed_samples} expected >= 0"
        )
        return 1

    try:
        (
            compare_report,
            claim_report,
            claim_report_path,
        ) = artifacts_mod.load_compare_bundle(
            report_path,
            explicit_claim_path=args.claim_report,
            require_claim=True,
        )
    except (OSError, json.JSONDecodeError, ValueError, FileNotFoundError) as exc:
        fail(str(exc))
        return 1
    assert claim_report is not None
    assert claim_report_path is not None

    try:
        (
            expected_obligation_schema_version,
            expected_obligation_ids,
        ) = report_conformance.load_obligation_contract(obligation_contract_path)
    except (OSError, json.JSONDecodeError, ValueError) as exc:
        fail(str(exc))
        return 1

    compare_ok, compare_error = report_conformance.validate_report_conformance(
        payload=compare_report,
        report_path=report_path,
        repo_root=repo_root,
        expected_obligation_schema_version=expected_obligation_schema_version,
        expected_obligation_ids=expected_obligation_ids,
    )
    if not compare_ok:
        fail(f"compare report conformance failed: {compare_error}")
        return 1

    claim_ok, claim_error = report_conformance.validate_claim_report_conformance(
        compare_payload=compare_report,
        compare_report_path=report_path,
        claim_payload=claim_report,
        claim_report_path=claim_report_path,
    )
    if not claim_ok:
        fail(f"claim report conformance failed: {claim_error}")
        return 1

    expected_workload_hash = ""
    expected_workload_ids: set[str] = set()
    expected_workload_rows: dict[str, dict[str, Any]] = {}
    if expected_workload_contract_path is not None:
        try:
            expected_workload_hash = report_conformance.file_sha256(expected_workload_contract_path)
            expected_workload_rows = load_workload_contract_rows(expected_workload_contract_path)
            expected_workload_ids = load_expected_comparable_workload_ids(
                expected_workload_contract_path,
                compare_config_path,
            )
        except (OSError, UnicodeError, json.JSONDecodeError, ValueError) as exc:
            fail(str(exc))
            return 1

    receipt_cache: dict[str, dict[str, Any]] = {}
    report = artifacts_mod.projected_compare_report(
        compare_report,
        report_path,
        claim_report=claim_report,
        cache=receipt_cache,
    )

    failures: list[str] = []

    comparison_status = compare_report.get("comparisonStatus")
    claim_status = claim_report.get("claimStatus")
    claim_policy = claim_report.get("claimPolicy")
    if not isinstance(claim_policy, dict):
        claim_policy = {}
    claim_mode = claim_policy.get("mode")
    min_samples = parse_int(claim_policy.get("minTimedSamples"))
    benchmark_policy = claim_policy.get("benchmarkPolicy")
    if not isinstance(benchmark_policy, dict):
        benchmark_policy = {}
    workloads = report.get("workloads")
    if not isinstance(workloads, list):
        workloads = []

    if comparison_status != args.require_comparison_status:
        failures.append(
            "comparisonStatus mismatch: expected "
            f"{args.require_comparison_status}, got {comparison_status!r}"
        )
    if claim_status != args.require_claim_status:
        failures.append(
            f"claimStatus mismatch: expected {args.require_claim_status}, got {claim_status!r}"
        )
    if claim_mode != args.require_claimability_mode:
        failures.append(
            "claimPolicy.mode mismatch: expected "
            f"{args.require_claimability_mode}, got {claim_mode!r}"
        )
    if min_samples is None:
        failures.append("claimPolicy.minTimedSamples missing or invalid")
    elif min_samples < args.require_min_timed_samples:
        failures.append(
            "claimPolicy.minTimedSamples below requirement: "
            f"required >= {args.require_min_timed_samples}, got {min_samples}"
        )

    benchmark_policy_path = benchmark_policy.get("path")
    benchmark_policy_sha = benchmark_policy.get("sha256")
    if not isinstance(benchmark_policy_path, str) or not benchmark_policy_path.strip():
        failures.append("claimPolicy.benchmarkPolicy.path missing or invalid")
    if not report_conformance.is_sha256_hex(benchmark_policy_sha):
        failures.append("claimPolicy.benchmarkPolicy.sha256 missing or invalid")
    suspicious_speedup_ratio = 0.0
    if isinstance(benchmark_policy_path, str) and benchmark_policy_path.strip():
        benchmark_policy_config_path = Path(benchmark_policy_path)
        if not benchmark_policy_config_path.is_absolute():
            benchmark_policy_config_path = repo_root / benchmark_policy_config_path
        try:
            loaded_benchmark_policy = load_benchmark_methodology_policy(
                str(benchmark_policy_config_path)
            )
            suspicious_speedup_ratio = loaded_benchmark_policy.suspicious_speedup_ratio
        except (OSError, UnicodeError, json.JSONDecodeError, ValueError) as exc:
            failures.append(str(exc))

    non_claimable_count = artifacts_mod.non_claimable_count(compare_report, claim_report)
    if args.require_claim_status == "claimable" and non_claimable_count != 0:
        failures.append(
            "claimable reports require zero non-claimable workloads "
            f"(found {non_claimable_count})"
        )
    if args.require_claim_status == "diagnostic" and non_claimable_count == 0:
        failures.append("diagnostic reports must contain at least one non-claimable workload")

    report_workload_rows: dict[str, dict[str, Any]] = {}
    workload_contract = report.get("workloadContract")
    if isinstance(workload_contract, dict):
        report_contract_path = workload_contract.get("path")
        if isinstance(report_contract_path, str) and report_contract_path.strip():
            try:
                resolved_report_contract_path = report_conformance.resolve_contract_path(
                    report_path=report_path,
                    repo_root=repo_root,
                    raw_contract_path=report_contract_path,
                )
                if resolved_report_contract_path.exists():
                    report_workload_rows = load_workload_contract_rows(
                        resolved_report_contract_path
                    )
            except (OSError, UnicodeError, json.JSONDecodeError, ValueError) as exc:
                failures.append(str(exc))

    for index, workload in enumerate(workloads):
        if not isinstance(workload, dict):
            failures.append(f"workloads[{index}] is not an object")
            continue
        workload_id = workload.get("id", f"workload[{index}]")
        report_row_path_asymmetry = workload.get("pathAsymmetry")
        if report_row_path_asymmetry is not None and not isinstance(
            report_row_path_asymmetry, bool
        ):
            failures.append(f"{workload_id}: pathAsymmetry must be bool when present")
        report_row_path_asymmetry_note = workload.get("pathAsymmetryNote")
        if report_row_path_asymmetry_note is not None and not isinstance(
            report_row_path_asymmetry_note, str
        ):
            failures.append(f"{workload_id}: pathAsymmetryNote must be string when present")
        report_contract_row = report_workload_rows.get(str(workload_id), {})
        expected_contract_row = expected_workload_rows.get(str(workload_id), {})
        report_contract_path_asymmetry = bool(report_contract_row.get("pathAsymmetry", False))
        expected_contract_path_asymmetry = bool(
            expected_contract_row.get("pathAsymmetry", False)
        )
        path_asymmetry_applies = workload_is_dawn_vs_doe(workload)
        if (
            isinstance(report_row_path_asymmetry, bool)
            and report_contract_row
            and report_row_path_asymmetry != report_contract_path_asymmetry
        ):
            failures.append(
                f"{workload_id}: report pathAsymmetry does not match workload contract "
                f"({report_row_path_asymmetry} vs {report_contract_path_asymmetry})"
            )
        if (
            isinstance(report_row_path_asymmetry_note, str)
            and report_contract_row
            and report_row_path_asymmetry_note
            != str(report_contract_row.get("pathAsymmetryNote", ""))
        ):
            failures.append(
                f"{workload_id}: report pathAsymmetryNote does not match workload contract"
            )
        if (
            path_asymmetry_applies
            and (
                args.require_comparison_status == "comparable"
                or args.require_claim_status == "claimable"
            )
        ):
            if report_row_path_asymmetry is True:
                failures.append(
                    f"{workload_id}: comparable/claimable reports cannot include pathAsymmetry=true"
                )
            if report_contract_path_asymmetry:
                failures.append(
                    f"{workload_id}: workload contract marks pathAsymmetry=true; "
                    "comparable/claimable reports are invalid until structural equivalence is restored"
                )
            elif expected_contract_path_asymmetry:
                failures.append(
                    f"{workload_id}: expected workload contract marks pathAsymmetry=true; "
                    "comparable/claimable reports are invalid until structural equivalence is restored"
                )

        workload_contract_comparable = workload.get("workloadComparable")
        if workload_contract_comparable not in (True, False):
            failures.append(
                f"{workload_id}: workloadComparable must be true/false in report workload row"
            )
        elif args.require_claim_status == "claimable" and workload_contract_comparable is not True:
            failures.append(f"{workload_id}: claimable reports require workloadComparable=true")

        workload_claimability = workload.get("claimability")
        if not isinstance(workload_claimability, dict):
            failures.append(f"{workload_id}: missing claimability object")
            continue
        evaluated = workload_claimability.get("evaluated")
        claimable = workload_claimability.get("claimable")
        required_positive = parse_string_list(
            workload_claimability.get("requiredPositivePercentiles")
        )
        expected_required = expected_positive_percentiles_for_mode(
            args.require_claimability_mode
        )
        if required_positive is None:
            failures.append(f"{workload_id}: claimability.requiredPositivePercentiles missing/invalid")
        elif required_positive != expected_required:
            failures.append(
                f"{workload_id}: claimability.requiredPositivePercentiles mismatch: "
                f"expected {expected_required}, got {required_positive}"
            )
        if evaluated is not True:
            failures.append(f"{workload_id}: claimability.evaluated must be true")
        if args.require_claim_status == "claimable" and claimable is not True:
            failures.append(f"{workload_id}: claimability.claimable must be true")
        if args.require_claim_status == "diagnostic" and claimable is not False:
            failures.append(f"{workload_id}: claimability.claimable must be false")

        if args.require_claim_status == "claimable":
            baseline_stats = workload.get("baselineStatsMs", {})
            comparison_stats = workload.get("comparisonStatsMs", {})
            if not isinstance(baseline_stats, dict):
                baseline_stats = {}
            if not isinstance(comparison_stats, dict):
                comparison_stats = {}
            left_count = parse_int(baseline_stats.get("count"))
            right_count = parse_int(comparison_stats.get("count"))
            effective_min_timed_samples = (
                min_samples
                if min_samples is not None
                else args.require_min_timed_samples
            )
            if left_count is None or left_count < effective_min_timed_samples:
                failures.append(
                    f"{workload_id}: baselineStatsMs.count must be >= {effective_min_timed_samples}"
                )
            if right_count is None or right_count < effective_min_timed_samples:
                failures.append(
                    f"{workload_id}: comparisonStatsMs.count must be >= {effective_min_timed_samples}"
                )
            delta = workload.get("deltaPercent")
            if not isinstance(delta, dict):
                failures.append(f"{workload_id}: missing deltaPercent object")
            else:
                for percentile in expected_required:
                    value = parse_float(delta.get(percentile))
                    if value is None:
                        failures.append(
                            f"{workload_id}: deltaPercent.{percentile} missing or invalid"
                        )
                    elif value <= 0.0:
                        failures.append(
                            f"{workload_id}: deltaPercent.{percentile} must be > 0 "
                            "(positive means baseline faster)"
                        )
            failures.extend(
                suspicious_speedup_failures(
                    workload_id=str(workload_id),
                    baseline_stats=baseline_stats,
                    comparison_stats=comparison_stats,
                    suspicious_speedup_ratio=suspicious_speedup_ratio,
                )
            )

        comparability_failures, has_comparability = workload_comparability_failures(
            workload_id=str(workload_id),
            workload=workload,
            require_comparison_status=args.require_comparison_status,
            expected_obligation_ids=expected_obligation_ids,
            expected_obligation_schema_version=expected_obligation_schema_version,
        )
        failures.extend(comparability_failures)
        if not has_comparability:
            continue

        if args.require_claim_status == "claimable":
            failures.extend(
                doe_package_telemetry_failures(
                    workload_id=str(workload_id),
                    side_name="baseline",
                    side_payload=workload.get("baseline"),
                )
            )
            failures.extend(
                doe_package_telemetry_failures(
                    workload_id=str(workload_id),
                    side_name="comparison",
                    side_payload=workload.get("comparison"),
                )
            )

        if args.require_backend_telemetry and args.require_claim_status == "claimable":
            left_payload = workload.get("baseline")
            if not isinstance(left_payload, dict):
                failures.append(f"{workload_id}: missing baseline payload for backend telemetry checks")
                continue
            command_samples = left_payload.get("commandSamples")
            if not isinstance(command_samples, list) or not command_samples:
                failures.append(f"{workload_id}: missing baseline.commandSamples for backend telemetry checks")
                continue
            for sample_idx, sample in enumerate(command_samples):
                if not isinstance(sample, dict):
                    continue
                if sample.get("returnCode") != 0:
                    continue
                trace_meta = sample.get("traceMeta")
                if not isinstance(trace_meta, dict):
                    failures.append(
                        f"{workload_id}: sample {sample_idx} missing traceMeta for backend telemetry checks"
                    )
                    continue
                backend_id = trace_meta.get("backendId")
                if not isinstance(backend_id, str) or not backend_id:
                    failures.append(f"{workload_id}: sample {sample_idx} missing backendId")
                elif args.expected_backend_id and backend_id != args.expected_backend_id:
                    failures.append(
                        f"{workload_id}: sample {sample_idx} backendId mismatch "
                        f"expected={args.expected_backend_id} got={backend_id}"
                    )
                selection_reason = trace_meta.get("backendSelectionReason")
                if not isinstance(selection_reason, str) or not selection_reason:
                    failures.append(
                        f"{workload_id}: sample {sample_idx} missing backendSelectionReason"
                    )
                selection_policy_hash = trace_meta.get("selectionPolicyHash")
                if not isinstance(selection_policy_hash, str) or not selection_policy_hash:
                    failures.append(
                        f"{workload_id}: sample {sample_idx} missing selectionPolicyHash"
                    )
                fallback_used = trace_meta.get("fallbackUsed")
                if not isinstance(fallback_used, bool):
                    failures.append(
                        f"{workload_id}: sample {sample_idx} missing fallbackUsed bool"
                    )

    if args.require_workload_contract_hash:
        if not isinstance(workload_contract, dict):
            failures.append("missing workloadContract object")
        else:
            report_contract_path = workload_contract.get("path")
            report_contract_hash = workload_contract.get("sha256")
            if not isinstance(report_contract_path, str) or not report_contract_path.strip():
                failures.append("workloadContract.path missing or invalid")
            if not isinstance(report_contract_hash, str) or not report_contract_hash.strip():
                failures.append("workloadContract.sha256 missing or invalid")
            elif report_contract_hash != expected_workload_hash:
                failures.append(
                    "workloadContract.sha256 mismatch: "
                    f"report={report_contract_hash} expected={expected_workload_hash}"
                )
            if expected_workload_contract_path is not None and isinstance(report_contract_path, str):
                resolved_report_path = report_conformance.resolve_contract_path(
                    report_path=report_path,
                    repo_root=repo_root,
                    raw_contract_path=report_contract_path,
                )
                if resolved_report_path != expected_workload_contract_path:
                    failures.append(
                        "workloadContract.path mismatch: "
                        f"report={resolved_report_path} expected={expected_workload_contract_path}"
                    )

    if args.require_workload_id_set_match:
        report_workload_ids = {
            str(workload.get("id"))
            for workload in workloads
            if isinstance(workload, dict) and isinstance(workload.get("id"), str)
        }
        missing_ids = sorted(expected_workload_ids - report_workload_ids)
        unexpected_ids = sorted(report_workload_ids - expected_workload_ids)
        if missing_ids:
            failures.append(
                "missing expected comparable workload IDs: " + ", ".join(missing_ids)
            )
        if unexpected_ids:
            failures.append(
                "unexpected comparable workload IDs in report: " + ", ".join(unexpected_ids)
            )

    if failures:
        fail("claim gate failed")
        for item in failures:
            print(item)
        if args.require_claim_status == "claimable" and workloads:
            print("non-claimable runtime details:")
            printed = False
            for workload in workloads:
                if not isinstance(workload, dict):
                    continue
                workload_claimability = workload.get("claimability")
                if not isinstance(workload_claimability, dict):
                    continue
                if workload_claimability.get("claimable") is True:
                    continue
                print(workload_runtime_hint(workload))
                printed = True
            if not printed:
                print("none")
        return 1

    print(
        "PASS: claim gate satisfied "
        f"(requiredMode={args.require_claimability_mode}, "
        f"comparisonStatus={comparison_status}, claimStatus={claim_status})"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
