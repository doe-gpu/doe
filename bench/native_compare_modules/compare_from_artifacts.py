"""Post-hoc comparison from independent run receipts."""

from __future__ import annotations

import json
from copy import deepcopy
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from native_compare_modules.normalization import sample_normalized_elapsed_ms
from native_compare_modules import reporting as reporting_mod
from native_compare_modules.runner import file_sha256


COMPARE_REPORT_SCHEMA_VERSION = 1
COMPARE_REPORT_KIND = "compare-report"
DELTA_PERCENT_CONVENTION = (
    "positive_means_baseline_faster_percent_of_comparison_time_saved"
)
DELTA_PERCENT_FORMULA = "((comparisonMs - baselineMs) / comparisonMs) * 100"


def _dedupe_reasons(reasons: list[str]) -> list[str]:
    seen: set[str] = set()
    ordered: list[str] = []
    for reason in reasons:
        if reason in seen:
            continue
        seen.add(reason)
        ordered.append(reason)
    return ordered


def receipt_run_view(receipt: dict[str, Any]) -> dict[str, Any]:
    command_samples: list[dict[str, Any]] = []
    timings: list[float] = []
    normalization = receipt.get("normalization", {})
    if not isinstance(normalization, dict):
        normalization = {}
    workload = receipt.get("workload", {})
    if not isinstance(workload, dict):
        workload = {}
    for sample in receipt.get("samples", []):
        if not isinstance(sample, dict):
            continue
        measured_ms = reporting_mod.safe_float(sample.get("measuredMs"))
        if measured_ms is not None:
            timings.append(measured_ms)
        trace_artifacts = sample.get("traceArtifacts", {})
        if not isinstance(trace_artifacts, dict):
            trace_artifacts = {}
        trace_meta = sample.get("traceMeta", {})
        if not isinstance(trace_meta, dict):
            trace_meta = {}
        timing = sample.get("timing", {})
        if not isinstance(timing, dict):
            timing = {}
        restored_timing = dict(timing)
        if "commandRepeat" not in restored_timing:
            restored_timing["commandRepeat"] = int(
                sample.get("commandRepeat", normalization.get("commandRepeat", 1)) or 1
            )
        if "timingNormalizationDivisor" not in restored_timing:
            restored_timing["timingNormalizationDivisor"] = (
                reporting_mod.safe_float(
                    sample.get(
                        "timingNormalizationDivisor",
                        normalization.get("timingDivisor", 1.0),
                    )
                )
                or 1.0
            )
        if "timingConfiguredDivisor" not in restored_timing:
            restored_timing["timingConfiguredDivisor"] = (
                reporting_mod.safe_float(normalization.get("timingDivisor", 1.0))
                or 1.0
            )
        if "traceMetaSource" not in restored_timing:
            restored_timing["traceMetaSource"] = str(sample.get("timingSource", "")).strip()
        if "timingSelectionPolicy" not in restored_timing:
            restored_timing["timingSelectionPolicy"] = (
                str(trace_meta.get("timingSelectionPolicy", "")).strip()
                or "<none>"
            )
        if "uploadBufferUsage" not in restored_timing:
            restored_timing["uploadBufferUsage"] = str(
                sample.get(
                    "uploadBufferUsage",
                    normalization.get("uploadBufferUsage", ""),
                )
            ).strip()
        if "uploadSubmitEvery" not in restored_timing:
            restored_timing["uploadSubmitEvery"] = int(
                sample.get(
                    "uploadSubmitEvery",
                    normalization.get("uploadSubmitEvery", 1),
                )
                or 1
            )
        if "workloadUnitNormalizationDivisor" not in restored_timing:
            workload_unit_divisor = reporting_mod.safe_float(
                sample.get("workloadUnitNormalizationDivisor")
            )
            if workload_unit_divisor is not None and workload_unit_divisor > 0.0:
                restored_timing["workloadUnitNormalizationDivisor"] = workload_unit_divisor
        command_samples.append(
            {
                "runIndex": int(sample.get("runIndex", 0)),
                "command": sample.get("command", []),
                "elapsedMs": reporting_mod.safe_float(sample.get("wallMs")),
                "measuredRawMs": reporting_mod.safe_float(sample.get("measuredRawMs")),
                "measuredMs": measured_ms,
                "timingSource": str(sample.get("timingSource", "")).strip(),
                "timing": restored_timing,
                "traceJsonlPath": str(trace_artifacts.get("jsonlPath", "")).strip(),
                "traceMetaPath": str(trace_artifacts.get("metaPath", "")).strip(),
                "returnCode": int(sample.get("returnCode", 0)),
                "resource": sample.get("resource", {}),
                "traceMeta": trace_meta,
                "commandRepeat": int(
                    sample.get("commandRepeat", normalization.get("commandRepeat", 1)) or 1
                ),
                "uploadIgnoreFirstOps": int(
                    sample.get("uploadIgnoreFirstOps", normalization.get("ignoreFirstOps", 0))
                    or 0
                ),
                "uploadBufferUsage": str(
                    sample.get("uploadBufferUsage", normalization.get("uploadBufferUsage", ""))
                ).strip(),
                "uploadSubmitEvery": int(
                    sample.get("uploadSubmitEvery", normalization.get("uploadSubmitEvery", 1))
                    or 1
                ),
                "timingNormalizationDivisor": (
                    reporting_mod.safe_float(
                        sample.get("timingNormalizationDivisor")
                    )
                    or reporting_mod.safe_float(normalization.get("timingDivisor", 1.0))
                    or 1.0
                ),
                "workloadDomain": str(workload.get("domain", "")).strip(),
                "strictNormalizationUnit": str(
                    workload.get("strictNormalizationUnit", "")
                ).strip(),
                **(
                    {
                        "workloadUnitNormalizationDivisor": reporting_mod.safe_float(
                            sample.get("workloadUnitNormalizationDivisor")
                        )
                    }
                    if (
                        reporting_mod.safe_float(sample.get("workloadUnitNormalizationDivisor"))
                        is not None
                    )
                    else {}
                ),
            }
        )
    execution = receipt.get("execution", {})
    if not isinstance(execution, dict):
        execution = {}
    last_meta = {}
    if command_samples:
        trace_meta = command_samples[-1].get("traceMeta", {})
        if isinstance(trace_meta, dict):
            last_meta = trace_meta
    return {
        "commandSamples": command_samples,
        "stats": reporting_mod.format_stats(timings),
        "timingsMs": timings,
        "timingSources": list(execution.get("timingSources", [])),
        "timingClasses": list(execution.get("timingClasses", [])),
        "lastMeta": last_meta,
        "resourceStats": reporting_mod.summarize_resource_stats(command_samples),
    }


def group_run_artifacts_by_workload(
    artifacts: list[dict[str, Any]],
) -> dict[str, dict[str, dict[str, Any]]]:
    grouped_lists: dict[str, dict[str, list[dict[str, Any]]]] = {}
    for artifact in artifacts:
        workload = artifact.get("workload", {})
        if not isinstance(workload, dict):
            raise ValueError("run receipt missing workload metadata")
        workload_id = str(workload.get("id", "")).strip()
        product = str(artifact.get("product", "")).strip()
        if not workload_id or not product:
            raise ValueError("run receipt missing workload.id or product")
        grouped_lists.setdefault(workload_id, {}).setdefault(product, []).append(artifact)

    grouped: dict[str, dict[str, dict[str, Any]]] = {}
    for workload_id, product_groups in grouped_lists.items():
        grouped[workload_id] = {}
        for product, receipts in product_groups.items():
            grouped[workload_id][product] = merge_run_receipts(receipts)
    return grouped


def _identity_json(value: Any) -> str:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True)


def _assert_merge_field_matches(
    *,
    receipts: list[dict[str, Any]],
    field_name: str,
    context: str,
) -> None:
    first = receipts[0].get(field_name)
    first_identity = _identity_json(first)
    for receipt in receipts[1:]:
        if _identity_json(receipt.get(field_name)) != first_identity:
            raise ValueError(f"cannot merge run receipts with different {context}")


def merge_run_receipts(receipts: list[dict[str, Any]]) -> dict[str, Any]:
    if not receipts:
        raise ValueError("cannot merge an empty run receipt list")
    if len(receipts) == 1:
        return receipts[0]

    for field_name, context in (
        ("product", "products"),
        ("executorId", "executor ids"),
        ("workload", "workloads"),
        ("workloadManifest", "workload manifests"),
        ("normalization", "normalization metadata"),
    ):
        _assert_merge_field_matches(
            receipts=receipts,
            field_name=field_name,
            context=context,
        )

    merged = deepcopy(receipts[0])
    merged_samples: list[dict[str, Any]] = []
    receipt_paths: list[str] = []
    return_codes: list[int] = []
    timing_sources: set[str] = set()
    timing_classes: set[str] = set()
    timed_sample_count = 0
    success = True

    for receipt in receipts:
        path = str(receipt.get("_receiptPath", "")).strip()
        if path:
            receipt_paths.append(path)
        execution = receipt.get("execution", {})
        if not isinstance(execution, dict):
            execution = {}
        success = success and bool(execution.get("success", False))
        timed_sample_count += int(execution.get("timedSampleCount", 0) or 0)
        for return_code in execution.get("returnCodes", []):
            try:
                return_codes.append(int(return_code))
            except (TypeError, ValueError):
                continue
        timing_sources.update(str(value) for value in execution.get("timingSources", []))
        timing_classes.update(str(value) for value in execution.get("timingClasses", []))
        for sample in receipt.get("samples", []):
            if isinstance(sample, dict):
                merged_samples.append(deepcopy(sample))

    merged["samples"] = merged_samples
    if receipt_paths:
        merged["_receiptPath"] = receipt_paths[0]
        merged["_receiptPaths"] = receipt_paths
    execution = merged.get("execution", {})
    if not isinstance(execution, dict):
        execution = {}
    execution["success"] = success
    execution["timedSampleCount"] = timed_sample_count
    execution["returnCodes"] = sorted(set(return_codes))
    execution["timingSources"] = sorted(timing_sources)
    execution["timingClasses"] = sorted(timing_classes)
    execution["mergedReceiptCount"] = len(receipts)
    merged["execution"] = execution
    return merged


def _workload_manifest_ref(receipt: dict[str, Any]) -> dict[str, Any]:
    manifest = receipt.get("workloadManifest", {})
    if not isinstance(manifest, dict):
        return {}
    return {
        "path": str(manifest.get("path", "")).strip(),
        "sha256": str(manifest.get("sha256", "")).strip(),
        "ownership": str(manifest.get("ownership", "")).strip(),
        "inputFreshness": str(manifest.get("inputFreshness", "")).strip(),
        "freshnessReason": str(manifest.get("freshnessReason", "")).strip(),
        "generatorId": str(manifest.get("generatorId", "")).strip(),
        "generatorInputHash": str(manifest.get("generatorInputHash", "")).strip(),
        "generatedAt": str(manifest.get("generatedAt", "")).strip(),
    }


def _receipt_ref(receipt: dict[str, Any]) -> dict[str, str]:
    path = str(receipt.get("_receiptPath", "")).strip()
    if path and Path(path).exists():
        sha256 = file_sha256(Path(path))
    else:
        sha256 = ""
    return {
        "path": path,
        "product": str(receipt.get("product", "")).strip(),
        "sha256": sha256,
    }


def _receipt_matching(
    *,
    baseline: dict[str, Any],
    comparison: dict[str, Any],
) -> dict[str, Any]:
    reasons: list[str] = []
    baseline_workload = baseline.get("workload", {})
    comparison_workload = comparison.get("workload", {})
    if not isinstance(baseline_workload, dict):
        baseline_workload = {}
    if not isinstance(comparison_workload, dict):
        comparison_workload = {}

    baseline_id = str(baseline_workload.get("id", "")).strip()
    comparison_id = str(comparison_workload.get("id", "")).strip()
    if baseline_id != comparison_id:
        reasons.append(
            f"receipt workload id mismatch: {baseline_id!r} vs {comparison_id!r}"
        )

    baseline_manifest = _workload_manifest_ref(baseline)
    comparison_manifest = _workload_manifest_ref(comparison)
    baseline_manifest_hash = baseline_manifest.get("sha256", "")
    comparison_manifest_hash = comparison_manifest.get("sha256", "")
    if baseline_manifest_hash and comparison_manifest_hash:
        if baseline_manifest_hash != comparison_manifest_hash:
            reasons.append(
                "workload manifest hash mismatch: "
                f"{baseline_manifest_hash} vs {comparison_manifest_hash}"
            )

    baseline_norm = baseline.get("normalization", {})
    comparison_norm = comparison.get("normalization", {})
    if not isinstance(baseline_norm, dict):
        baseline_norm = {}
    if not isinstance(comparison_norm, dict):
        comparison_norm = {}
    for field_name in (
        "commandRepeat",
        "ignoreFirstOps",
        "timingDivisor",
        "uploadBufferUsage",
        "uploadSubmitEvery",
        "allowNoExecution",
    ):
        if baseline_norm.get(field_name) != comparison_norm.get(field_name):
            reasons.append(
                f"normalization mismatch for {field_name}: "
                f"{baseline_norm.get(field_name)!r} vs "
                f"{comparison_norm.get(field_name)!r}"
            )

    baseline_execution = baseline.get("execution", {})
    comparison_execution = comparison.get("execution", {})
    if not isinstance(baseline_execution, dict):
        baseline_execution = {}
    if not isinstance(comparison_execution, dict):
        comparison_execution = {}
    baseline_classes = sorted(baseline_execution.get("timingClasses", []))
    comparison_classes = sorted(comparison_execution.get("timingClasses", []))
    if baseline_classes != comparison_classes:
        reasons.append(
            f"timing class mismatch: {baseline_classes!r} vs {comparison_classes!r}"
        )

    return {
        "matched": not reasons,
        "reasons": reasons,
        "baselineManifest": baseline_manifest,
        "comparisonManifest": comparison_manifest,
    }


def _normalization_label(receipt: dict[str, Any]) -> str:
    normalization = receipt.get("normalization", {})
    if not isinstance(normalization, dict):
        return "none"
    command_repeat = int(normalization.get("commandRepeat", 1) or 1)
    timing_divisor = float(normalization.get("timingDivisor", 1.0) or 1.0)
    if timing_divisor != 1.0:
        return "per_op"
    if command_repeat > 1:
        return "repeat"
    return "none"


def _overall_stats(entries: list[dict[str, Any]], field: str) -> dict[str, Any]:
    baseline_values: list[float] = []
    comparison_values: list[float] = []
    for entry in entries:
        if not entry.get("comparability", {}).get("comparable", False):
            continue
        baseline_values.extend(entry.get("baselineValues", {}).get(field, []))
        comparison_values.extend(entry.get("comparisonValues", {}).get(field, []))
    baseline_stats = reporting_mod.format_stats(baseline_values)
    comparison_stats = reporting_mod.format_stats(comparison_values)
    return {
        "baselineStatsMs": baseline_stats,
        "comparisonStatsMs": comparison_stats,
        "deltaPercent": _delta_percent_from_stats(
            baseline_stats,
            comparison_stats,
        ),
    }


def _delta_percent_from_stats(
    baseline_stats: dict[str, Any],
    comparison_stats: dict[str, Any],
) -> dict[str, float]:
    result: dict[str, float] = {}
    for baseline_key, output_key in (
        ("p10Ms", "p10Percent"),
        ("p50Ms", "p50Percent"),
        ("p95Ms", "p95Percent"),
        ("p99Ms", "p99Percent"),
        ("meanMs", "meanPercent"),
    ):
        baseline_value = reporting_mod.safe_float(baseline_stats.get(baseline_key))
        comparison_value = reporting_mod.safe_float(comparison_stats.get(baseline_key))
        if (
            baseline_value is None
            or comparison_value is None
            or comparison_value <= 0.0
        ):
            result[output_key] = 0.0
            continue
        result[output_key] = (
            (comparison_value - baseline_value) / comparison_value
        ) * 100.0
    return result


def _wall_values(receipt: dict[str, Any]) -> list[float]:
    values: list[float] = []
    run_view = receipt_run_view(receipt)
    for sample in run_view.get("commandSamples", []):
        if not isinstance(sample, dict):
            continue
        value = sample_normalized_elapsed_ms(sample)
        if value is not None:
            values.append(value)
    return values


def _measured_values(receipt: dict[str, Any]) -> list[float]:
    values: list[float] = []
    for sample in receipt.get("samples", []):
        if not isinstance(sample, dict):
            continue
        value = reporting_mod.safe_float(sample.get("measuredMs"))
        if value is not None:
            values.append(value)
    return values


def compare_workload_from_artifacts(
    *,
    baseline: dict[str, Any],
    comparison: dict[str, Any],
    comparability_mode: str = "strict",
    required_timing_class: str = "operation",
    resource_probe: str = "none",
    resource_sample_target_count: int = 0,
    primary_metric: str = "measured_ms",
) -> dict[str, Any]:
    """Compare two run receipts for the same workload."""
    import native_compare_modules.comparability  # noqa: F401
    import native_compare_modules.compare_assessment as compare_assessment_mod
    import native_compare_modules.timing_interpretation as timing_interpretation_mod

    baseline_workload = baseline.get("workload", {})
    if not isinstance(baseline_workload, dict):
        baseline_workload = {}

    matching = _receipt_matching(
        baseline=baseline,
        comparison=comparison,
    )
    baseline_run_view = receipt_run_view(baseline)
    comparison_run_view = receipt_run_view(comparison)
    baseline_normalization = baseline.get("normalization", {})
    comparison_normalization = comparison.get("normalization", {})
    if not isinstance(baseline_normalization, dict):
        baseline_normalization = {}
    if not isinstance(comparison_normalization, dict):
        comparison_normalization = {}

    comparability = compare_assessment_mod.compare_assessment(
        workload_id=str(baseline_workload.get("id", "")).strip(),
        workload_comparable=bool(baseline_workload.get("comparable", False)),
        workload_domain=str(baseline_workload.get("domain", "")).strip(),
        workload_api=str(baseline_workload.get("api", "")).strip(),
        workload_commands_path=str(baseline_workload.get("commandsPath", "")).strip(),
        workload_path_asymmetry=bool(baseline_workload.get("pathAsymmetry", False)),
        workload_path_asymmetry_note=str(
            baseline_workload.get("pathAsymmetryNote", "")
        ).strip(),
        baseline_command_repeat=int(baseline_normalization.get("commandRepeat", 1) or 1),
        comparison_command_repeat=int(
            comparison_normalization.get("commandRepeat", 1) or 1
        ),
        baseline=baseline_run_view,
        comparison=comparison_run_view,
        required_timing_class=required_timing_class,
        allow_baseline_no_execution=bool(
            baseline_normalization.get("allowNoExecution", False)
        ),
        resource_probe=resource_probe,
        comparability_mode=comparability_mode,
        resource_sample_target_count=resource_sample_target_count,
    )
    comparability_reasons = _dedupe_reasons(
        list(matching.get("reasons", [])) + list(comparability.get("reasons", []))
    )
    comparability = {
        **comparability,
        "comparable": bool(comparability.get("comparable", False))
        and bool(matching.get("matched", False)),
        "reasons": comparability_reasons,
    }

    timing_interpretation = timing_interpretation_mod.build_timing_interpretation(
        baseline=baseline_run_view,
        comparison=comparison_run_view,
    )
    measured_baseline = _measured_values(baseline)
    measured_comparison = _measured_values(comparison)
    wall_baseline = _wall_values(baseline)
    wall_comparison = _wall_values(comparison)
    primary_field = primary_metric
    if primary_metric not in {"measured_ms", "wall_ms"}:
        raise ValueError(
            "primary_metric must be one of ['measured_ms', 'wall_ms']"
        )
    if primary_metric == "measured_ms":
        baseline_values = measured_baseline
        comparison_values = measured_comparison
    else:
        baseline_values = wall_baseline
        comparison_values = wall_comparison

    baseline_stats = reporting_mod.format_stats(baseline_values)
    comparison_stats = reporting_mod.format_stats(comparison_values)
    wall_baseline_stats = reporting_mod.format_stats(wall_baseline)
    wall_comparison_stats = reporting_mod.format_stats(wall_comparison)

    workload_id = str(
        baseline_workload.get("id")
        or comparison.get("workload", {}).get("id", "")
    ).strip()
    return {
        "id": workload_id,
        "name": str(baseline_workload.get("name", "")).strip(),
        "description": str(baseline_workload.get("description", "")).strip(),
        "domain": str(baseline_workload.get("domain", "")).strip(),
        "workloadComparable": bool(baseline_workload.get("comparable", False)),
        "benchmarkClass": str(
            baseline_workload.get("benchmarkClass", "directional")
        ).strip(),
        "claimEligible": bool(baseline_workload.get("claimEligible", True)),
        "pathAsymmetry": bool(baseline_workload.get("pathAsymmetry", False)),
        "pathAsymmetryNote": str(
            baseline_workload.get("pathAsymmetryNote", "")
        ).strip(),
        "receipts": {
            "left": _receipt_ref(baseline),
            "right": _receipt_ref(comparison),
        },
        "workloadMatching": matching,
        "comparability": comparability,
        "primaryMetric": primary_field,
        "normalization": _normalization_label(baseline),
        "baselineStatsMs": baseline_stats,
        "comparisonStatsMs": comparison_stats,
        "deltaPercent": _delta_percent_from_stats(
            baseline_stats,
            comparison_stats,
        ),
        "workloadUnitWall": {
            "baselineStatsMs": wall_baseline_stats,
            "comparisonStatsMs": wall_comparison_stats,
            "deltaPercent": _delta_percent_from_stats(
                wall_baseline_stats,
                wall_comparison_stats,
            ),
        },
        "timingInterpretation": timing_interpretation,
        "baselineValues": {
            "measured_ms": measured_baseline,
            "wall_ms": wall_baseline,
        },
        "comparisonValues": {
            "measured_ms": measured_comparison,
            "wall_ms": wall_comparison,
        },
    }


def _attach_receipt_hashes(entry: dict[str, Any]) -> dict[str, Any]:
    receipts = entry.get("receipts", {})
    if not isinstance(receipts, dict):
        return entry
    for side_name in ("left", "right"):
        side = receipts.get(side_name)
        if not isinstance(side, dict):
            continue
        path = str(side.get("path", "")).strip()
        if path and Path(path).exists():
            side["sha256"] = file_sha256(Path(path))
        else:
            side["sha256"] = ""
    return entry


def build_compare_report(
    *,
    workload_entries: list[dict[str, Any]],
    baseline_artifact: dict[str, Any],
    comparison_artifact: dict[str, Any],
    comparability_mode: str,
    required_timing_class: str,
    primary_metric: str = "measured_ms",
    out_path: str = "",
    run_artifact_paths: list[str] | None = None,
    comparability_min_timed_samples: int = 0,
    smoke_comparability_min_timed_samples: int = 0,
    benchmark_policy_path: str = "",
) -> dict[str, Any]:
    """Assemble a compare-only report from workload entries."""
    enriched_entries = [_attach_receipt_hashes(entry) for entry in workload_entries]
    comparability_failures = [
        {
            "workloadId": entry["id"],
            "reasons": entry["comparability"].get("reasons", []),
        }
        for entry in enriched_entries
        if not entry["comparability"].get("comparable", False)
    ]
    comparison_status = "comparable" if not comparability_failures else "diagnostic"
    workload_manifest = baseline_artifact.get("workloadManifest", {})
    if not isinstance(workload_manifest, dict):
        workload_manifest = {}
    entries = []
    for entry in enriched_entries:
        sanitized = dict(entry)
        sanitized.pop("baselineValues", None)
        sanitized.pop("comparisonValues", None)
        entries.append(sanitized)
    report = {
        "schemaVersion": COMPARE_REPORT_SCHEMA_VERSION,
        "artifactKind": COMPARE_REPORT_KIND,
        "generatedAt": datetime.now(timezone.utc).isoformat(),
        "outPath": out_path,
        "comparisonStatus": comparison_status,
        "primaryMetric": primary_metric,
        "deltaPercentConvention": DELTA_PERCENT_CONVENTION,
        "deltaPercentFormula": DELTA_PERCENT_FORMULA,
        "comparabilityPolicy": {
            "mode": comparability_mode,
            "requireTimingClass": required_timing_class,
        },
        "participants": {
            "left": {
                "product": baseline_artifact.get("product", ""),
                "executorId": baseline_artifact.get("executorId", ""),
                "runtimeIdentity": baseline_artifact.get("runtimeIdentity", {}),
                "hostIdentity": baseline_artifact.get("hostIdentity", {}),
            },
            "right": {
                "product": comparison_artifact.get("product", ""),
                "executorId": comparison_artifact.get("executorId", ""),
                "runtimeIdentity": comparison_artifact.get("runtimeIdentity", {}),
                "hostIdentity": comparison_artifact.get("hostIdentity", {}),
            },
        },
        "workloadManifest": workload_manifest,
        "runReceiptPaths": run_artifact_paths or [],
        "comparabilitySummary": {
            "workloadCount": len(entries),
            "nonComparableCount": len(comparability_failures),
        },
        "comparabilityFailures": comparability_failures,
        "overall": _overall_stats(enriched_entries, primary_metric),
        "overallWorkloadUnitWall": _overall_stats(enriched_entries, "wall_ms"),
        "workloads": entries,
    }

    from bench.lib import comparability_coherence as coherence_mod

    coherence = coherence_mod.assess_report(
        report,
        min_timed_samples=max(comparability_min_timed_samples, 0),
        smoke_min_timed_samples=max(smoke_comparability_min_timed_samples, 0),
        benchmark_policy_path=benchmark_policy_path,
    )
    if comparison_status == "comparable" and coherence.get("status") != "pass":
        report["comparisonStatus"] = "diagnostic"
        coherence["statusBeforeCoherence"] = "comparable"
        coherence["finalComparisonStatus"] = "diagnostic"
    else:
        coherence["statusBeforeCoherence"] = comparison_status
        coherence["finalComparisonStatus"] = report["comparisonStatus"]
    report["comparabilityCoherence"] = coherence
    return report


def write_compare_report(report: dict[str, Any], path: Path) -> Path:
    """Write comparison report to disk."""
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps(report, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    return path


def load_compare_report(path: str | Path) -> dict[str, Any]:
    """Load a compare report from disk."""
    compare_path = Path(path)
    if not compare_path.exists():
        raise FileNotFoundError(f"compare report not found: {compare_path}")
    payload = json.loads(compare_path.read_text(encoding="utf-8"))
    if not isinstance(payload, dict):
        raise ValueError(f"compare report must be a JSON object: {compare_path}")
    if payload.get("artifactKind") != COMPARE_REPORT_KIND:
        raise ValueError(
            f"expected artifactKind={COMPARE_REPORT_KIND!r}, "
            f"got {payload.get('artifactKind')!r}: {compare_path}"
        )
    return payload
