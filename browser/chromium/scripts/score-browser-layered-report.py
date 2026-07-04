#!/usr/bin/env python3
"""Score a browser layered diagnostic report without promoting it to a claim."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import sys
from datetime import UTC, datetime
from pathlib import Path
from typing import Any


METRIC_PRIORITY: tuple[tuple[str, str], ...] = (
    ("usPerOp", "microseconds"),
    ("usPerFrame", "microseconds"),
    ("usPerSubmit", "microseconds"),
    ("avgFrameMs", "milliseconds"),
    ("p95FrameMs", "milliseconds"),
    ("msPerPipeline", "milliseconds"),
    ("msPerResize", "milliseconds"),
    ("renderMs", "milliseconds"),
    ("textureMs", "milliseconds"),
    ("startupMs", "milliseconds"),
    ("totalMs", "milliseconds"),
    ("elapsedMs", "milliseconds"),
)

PHASE_METRICS: tuple[str, ...] = (
    "bufferInitMs",
    "createTextureMs",
    "writeTextureMs",
    "createRenderTargetMs",
    "shaderModuleMs",
    "computePipelineMs",
    "renderPipelineMs",
    "createViewMs",
    "createSamplerMs",
    "createBindGroupMs",
    "encodeSubmitMs",
    "dispatchElapsedMs",
    "submitReadbackMs",
    "mapReadMs",
    "waitMs",
    "propertyQueryMs",
    "destroyMs",
)

SELECTED_METRIC_DISTRIBUTION_SUFFIXES: tuple[tuple[str, str], ...] = (
    ("avg", "Avg"),
    ("p10", "P10"),
    ("p50", "P50"),
    ("p95", "P95"),
    ("p99", "P99"),
)

CATEGORY_BY_DOMAIN = {
    "compute": "compute",
    "p0-compute": "compute",
    "copy": "memory",
    "upload": "memory",
    "resource": "resources",
    "p0-resource": "resources",
    "p1-resource-table": "resources",
    "p1-resource-table-macro": "resources",
    "pipeline": "pipeline",
    "pipeline-async": "pipeline",
    "render": "render",
    "p0-render": "render",
    "p0-render-macro": "render",
    "render-bundle": "render",
    "render-macro": "render",
    "surface": "surface",
    "texture-contract": "texture",
    "texture-macro": "texture",
    "texture-raster": "texture",
    "p1-capability": "capability",
    "p1-capability-macro": "capability",
    "p2-lifecycle": "lifecycle",
    "p2-lifecycle-macro": "lifecycle",
}

CATEGORY_BY_WORKFLOW_ID = {
    "startup_adapter_device": "startup",
    "canvas_reconfigure_resize": "canvas",
    "queue_submit_burst": "queue",
    "async_pipeline_burst": "pipeline",
    "fawn_visual_particle_trails": "visual",
    "fawn_visual_magnetic_fluids": "visual",
    "fawn_visual_prismatic_fluids": "visual",
}

SCORE_METHOD_ID = "browser-layered-geomean-lower-is-better-v2"
STRICT_COMPARABLE_CRITERIA = (
    "comparabilityExpectation=strict, browserWorkload.sourceComparable=true, "
    "browserWorkload.sourceClaimEligible=true, browserWorkload.benchmarkClass=comparable"
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--report", required=True, help="Layered diagnostic report JSON.")
    parser.add_argument("--out", required=True, help="Score report output JSON.")
    parser.add_argument("--baseline-mode", default="doe", help="Baseline runtime mode.")
    parser.add_argument("--comparison-mode", default="dawn", help="Comparison runtime mode.")
    return parser.parse_args()


def load_json(path: Path) -> dict[str, Any]:
    payload = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(payload, dict):
        raise ValueError(f"invalid JSON object: {path}")
    return payload


def stable_json(value: Any) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode("utf-8")


def sha256_hex(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def numeric_metric(metrics: dict[str, Any], key: str) -> float | None:
    value = metrics.get(key)
    if not isinstance(value, int | float):
        return None
    parsed = float(value)
    if not math.isfinite(parsed) or parsed <= 0:
        return None
    return parsed


def numeric_phase_metric(metrics: dict[str, Any], key: str) -> float | None:
    value = metrics.get(key)
    if not isinstance(value, int | float):
        return None
    parsed = float(value)
    if not math.isfinite(parsed) or parsed < 0:
        return None
    return parsed


def selected_metric_distribution(metrics: dict[str, Any], metric: str) -> dict[str, Any] | None:
    values: dict[str, Any] = {}
    for label, suffix in SELECTED_METRIC_DISTRIBUTION_SUFFIXES:
        value = numeric_metric(metrics, f"{metric}{suffix}")
        if value is not None:
            values[label] = value
    sample_count = metrics.get("sourceKernelSampleCount")
    if isinstance(sample_count, int) and sample_count > 0:
        values["sampleCount"] = sample_count
    samples = metrics.get(f"{metric}Samples")
    if isinstance(samples, list) and samples:
        numeric_samples = [
            float(value)
            for value in samples
            if isinstance(value, int | float) and math.isfinite(float(value)) and float(value) > 0.0
        ]
        if len(numeric_samples) == len(samples):
            values["samples"] = numeric_samples
    if not values:
        return None
    return values


def selected_metric_percentile_deltas(
    baseline_metrics: dict[str, Any],
    comparison_metrics: dict[str, Any],
    metric: str,
) -> list[dict[str, Any]]:
    deltas = []
    for label, suffix in SELECTED_METRIC_DISTRIBUTION_SUFFIXES:
        if label == "avg":
            continue
        baseline_value = numeric_metric(baseline_metrics, f"{metric}{suffix}")
        comparison_value = numeric_metric(comparison_metrics, f"{metric}{suffix}")
        if baseline_value is None or comparison_value is None:
            continue
        baseline_lead_percent = ((comparison_value - baseline_value) / comparison_value) * 100.0
        deltas.append(
            {
                "percentile": label,
                "metric": metric,
                "baselineValue": baseline_value,
                "comparisonValue": comparison_value,
                "comparisonDelta": comparison_value - baseline_value,
                "comparisonDeltaPercent": baseline_lead_percent,
                "baselineLeadPercent": baseline_lead_percent,
            }
        )
    return deltas


def select_metric(
    baseline_metrics: dict[str, Any],
    comparison_metrics: dict[str, Any],
) -> tuple[str, str, float, float] | None:
    for key, unit in METRIC_PRIORITY:
        baseline_value = numeric_metric(baseline_metrics, key)
        comparison_value = numeric_metric(comparison_metrics, key)
        if baseline_value is not None and comparison_value is not None:
            return key, unit, baseline_value, comparison_value
    return None


def summarize_phase_metrics(
    baseline_metrics: dict[str, Any],
    comparison_metrics: dict[str, Any],
) -> list[dict[str, Any]]:
    phases = []
    for metric in PHASE_METRICS:
        baseline_value = numeric_phase_metric(baseline_metrics, metric)
        comparison_value = numeric_phase_metric(comparison_metrics, metric)
        if baseline_value is None or comparison_value is None:
            continue
        if baseline_value == 0.0 and comparison_value == 0.0:
            continue
        baseline_lead_percent = (
            ((comparison_value - baseline_value) / comparison_value) * 100.0
            if comparison_value > 0.0
            else None
        )
        phases.append(
            {
                "metric": metric,
                "unit": "milliseconds",
                "baselineValue": baseline_value,
                "comparisonValue": comparison_value,
                "comparisonDelta": comparison_value - baseline_value,
                "comparisonDeltaPercent": baseline_lead_percent,
                "baselineLeadPercent": baseline_lead_percent,
            }
        )
    return phases


def category_for_row(layer: str, row: dict[str, Any]) -> str:
    if layer == "l2":
        row_id = row.get("id")
        if isinstance(row_id, str):
            return CATEGORY_BY_WORKFLOW_ID.get(row_id, "workflow")
        return "workflow"

    domain = row.get("domain")
    if isinstance(domain, str) and domain:
        return CATEGORY_BY_DOMAIN.get(domain, domain)
    return "uncategorized"


def row_id_for(layer: str, row: dict[str, Any]) -> str:
    key = "id" if layer == "l2" else "sourceWorkloadId"
    row_id = row.get(key)
    if not isinstance(row_id, str) or not row_id.strip():
        raise ValueError(f"{layer} row missing {key}")
    return row_id


def exclusion(
    *,
    layer: str,
    row_id: str,
    category: str,
    reason: str,
    baseline_status: str | None,
    comparison_status: str | None,
) -> dict[str, Any]:
    return {
        "layer": layer,
        "rowId": row_id,
        "category": category,
        "reason": reason,
        "baselineStatus": baseline_status,
        "comparisonStatus": comparison_status,
    }


def build_row_score(
    *,
    layer: str,
    row: dict[str, Any],
    baseline_mode: str,
    comparison_mode: str,
) -> tuple[dict[str, Any] | None, dict[str, Any] | None]:
    row_id = row_id_for(layer, row)
    category = category_for_row(layer, row)
    runtimes = row.get("runtimes")
    if not isinstance(runtimes, dict):
        return None, exclusion(
            layer=layer,
            row_id=row_id,
            category=category,
            reason="missing runtimes object",
            baseline_status=None,
            comparison_status=None,
        )

    baseline = runtimes.get(baseline_mode)
    comparison = runtimes.get(comparison_mode)
    if not isinstance(baseline, dict) or not isinstance(comparison, dict):
        return None, exclusion(
            layer=layer,
            row_id=row_id,
            category=category,
            reason="missing baseline or comparison mode result",
            baseline_status=None,
            comparison_status=None,
        )

    baseline_status = baseline.get("status")
    comparison_status = comparison.get("status")
    if baseline_status != "ok" or comparison_status != "ok":
        return None, exclusion(
            layer=layer,
            row_id=row_id,
            category=category,
            reason="baseline and comparison must both be ok",
            baseline_status=str(baseline_status),
            comparison_status=str(comparison_status),
        )

    baseline_metrics = baseline.get("metrics")
    comparison_metrics = comparison.get("metrics")
    if not isinstance(baseline_metrics, dict) or not isinstance(comparison_metrics, dict):
        return None, exclusion(
            layer=layer,
            row_id=row_id,
            category=category,
            reason="missing metrics object",
            baseline_status=str(baseline_status),
            comparison_status=str(comparison_status),
        )

    selected = select_metric(baseline_metrics, comparison_metrics)
    if selected is None:
        return None, exclusion(
            layer=layer,
            row_id=row_id,
            category=category,
            reason="no shared positive timing metric",
            baseline_status=str(baseline_status),
            comparison_status=str(comparison_status),
        )

    metric, unit, baseline_value, comparison_value = selected
    ratio = baseline_value / comparison_value
    paired_scores = paired_mode_scores_from_ratio(
        ratio,
        baseline_mode=baseline_mode,
        comparison_mode=comparison_mode,
    )
    return {
        "layer": layer,
        "rowId": row_id,
        "resourcePath": row.get("resourcePath") if isinstance(row.get("resourcePath"), str) else None,
        "resourceSha256": row.get("resourceSha256") if isinstance(row.get("resourceSha256"), str) else None,
        "category": category,
        "scenarioTemplate": row.get("scenarioTemplate", ""),
        "projectionClass": row.get("projectionClass"),
        "comparabilityExpectation": row.get("comparabilityExpectation"),
        "claimScope": row.get("claimScope"),
        "browserWorkload": row.get("browserWorkload")
        if isinstance(row.get("browserWorkload"), dict)
        else None,
        "metric": metric,
        "unit": unit,
        "baselineMode": baseline_mode,
        "comparisonMode": comparison_mode,
        "baselineValue": baseline_value,
        "comparisonValue": comparison_value,
        "selectedMetricDistribution": {
            "baseline": selected_metric_distribution(baseline_metrics, metric),
            "comparison": selected_metric_distribution(comparison_metrics, metric),
            "percentileDeltas": selected_metric_percentile_deltas(
                baseline_metrics,
                comparison_metrics,
                metric,
            ),
        },
        "phaseMetrics": summarize_phase_metrics(
            baseline_metrics,
            comparison_metrics,
        ),
        "ratio": ratio,
        "legacyRatioScore": ratio * 100.0,
        **paired_scores,
        "score": paired_scores["baselineScore"],
    }, None


def geometric_mean(values: list[float]) -> float:
    if not values:
        raise ValueError("cannot score empty ratio set")
    return math.exp(sum(math.log(value) for value in values) / len(values))


def paired_mode_scores_from_ratio(
    ratio: float,
    *,
    baseline_mode: str,
    comparison_mode: str,
) -> dict[str, Any]:
    baseline_score = 100.0 / (1.0 + ratio)
    comparison_score = (100.0 * ratio) / (1.0 + ratio)
    return {
        "baselineMode": baseline_mode,
        "comparisonMode": comparison_mode,
        "baselineScore": baseline_score,
        "comparisonScore": comparison_score,
        "comparisonDeltaPercent": (1.0 - ratio) * 100.0,
        "baselineLeadPercent": (1.0 - ratio) * 100.0,
    }


def summarize_rows(rows: list[dict[str, Any]]) -> dict[str, Any]:
    ratios = [float(row["ratio"]) for row in rows]
    geomean_ratio = geometric_mean(ratios)
    paired_scores = paired_mode_scores_from_ratio(
        geomean_ratio,
        baseline_mode=str(rows[0]["baselineMode"]),
        comparison_mode=str(rows[0]["comparisonMode"]),
    )
    return {
        **paired_scores,
        "score": paired_scores["baselineScore"],
        "legacyRatioScore": geomean_ratio * 100.0,
        "geomeanRatio": geomean_ratio,
        "rowCount": len(rows),
        "fasterRowCount": sum(1 for ratio in ratios if ratio < 1.0),
        "slowerRowCount": sum(1 for ratio in ratios if ratio > 1.0),
        "parityRowCount": sum(1 for ratio in ratios if ratio == 1.0),
    }


def summarize_categories(rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
    by_category: dict[str, list[dict[str, Any]]] = {}
    for row in rows:
        by_category.setdefault(str(row["category"]), []).append(row)

    categories = []
    for category in sorted(by_category):
        summary = summarize_rows(by_category[category])
        categories.append({"category": category, **summary})
    return categories


def summarize_category_balanced(
    categories: list[dict[str, Any]],
    *,
    baseline_mode: str,
    comparison_mode: str,
) -> dict[str, Any]:
    ratios = [float(category["geomeanRatio"]) for category in categories]
    geomean_ratio = geometric_mean(ratios)
    paired_scores = paired_mode_scores_from_ratio(
        geomean_ratio,
        baseline_mode=baseline_mode,
        comparison_mode=comparison_mode,
    )
    return {
        **paired_scores,
        "categoryCount": len(categories),
        "rowCount": sum(int(category["rowCount"]) for category in categories),
        "score": paired_scores["baselineScore"],
        "legacyRatioScore": geomean_ratio * 100.0,
        "geomeanRatio": geomean_ratio,
        "fasterCategoryCount": sum(1 for ratio in ratios if ratio < 1.0),
        "slowerCategoryCount": sum(1 for ratio in ratios if ratio > 1.0),
        "parityCategoryCount": sum(1 for ratio in ratios if ratio == 1.0),
    }


def strict_comparable_exclusion_reason(row: dict[str, Any]) -> str | None:
    if row.get("comparabilityExpectation") != "strict":
        return "comparabilityExpectation is not strict"
    browser_workload = row.get("browserWorkload")
    if not isinstance(browser_workload, dict):
        return "missing browserWorkload"
    if browser_workload.get("sourceComparable") is not True:
        return "sourceComparable is not true"
    if browser_workload.get("sourceClaimEligible") is not True:
        return "sourceClaimEligible is not true"
    if browser_workload.get("benchmarkClass") != "comparable":
        return "benchmarkClass is not comparable"
    return None


def strict_comparable_excluded_row(row: dict[str, Any], reason: str) -> dict[str, Any]:
    return {
        "layer": row.get("layer"),
        "rowId": row.get("rowId"),
        "category": row.get("category"),
        "reason": reason,
        "comparabilityExpectation": row.get("comparabilityExpectation"),
        "browserWorkload": row.get("browserWorkload"),
    }


def strict_comparable_summary(rows: list[dict[str, Any]]) -> dict[str, Any]:
    candidates = [row for row in rows if row.get("comparabilityExpectation") == "strict"]
    selected: list[dict[str, Any]] = []
    excluded: list[dict[str, Any]] = []
    for row in candidates:
        exclusion_reason = strict_comparable_exclusion_reason(row)
        if exclusion_reason is None:
            selected.append(row)
        else:
            excluded.append(strict_comparable_excluded_row(row, exclusion_reason))

    if not selected:
        return {
            "selectionCriteria": STRICT_COMPARABLE_CRITERIA,
            "candidateRowCount": len(candidates),
            "rowCount": 0,
            "excludedRowCount": len(excluded),
            "excludedRows": excluded,
            "overall": None,
            "categoryBalancedOverall": None,
            "categories": [],
            "bottlenecks": summarize_bottlenecks(categories=[], rows=[]),
        }

    categories = summarize_categories(selected)
    return {
        "selectionCriteria": STRICT_COMPARABLE_CRITERIA,
        "candidateRowCount": len(candidates),
        "rowCount": len(selected),
        "excludedRowCount": len(excluded),
        "excludedRows": excluded,
        "overall": summarize_rows(selected),
        "categoryBalancedOverall": summarize_category_balanced(
            categories,
            baseline_mode=str(selected[0]["baselineMode"]),
            comparison_mode=str(selected[0]["comparisonMode"]),
        ),
        "bottlenecks": summarize_bottlenecks(categories=categories, rows=selected),
        "categories": categories,
    }


def summarize_bottlenecks(
    *,
    categories: list[dict[str, Any]],
    rows: list[dict[str, Any]],
    limit: int = 5,
) -> dict[str, Any]:
    slower_categories = [
        category
        for category in categories
        if float(category["baselineLeadPercent"]) < 0.0
    ]
    slower_rows = [
        row
        for row in rows
        if float(row["baselineLeadPercent"]) < 0.0
    ]

    worst_categories = sorted(
        slower_categories,
        key=lambda category: float(category["baselineLeadPercent"]),
    )[:limit]
    worst_rows = sorted(
        slower_rows,
        key=lambda row: float(row["baselineLeadPercent"]),
    )[:limit]
    slower_phases = [
        {
            "layer": row["layer"],
            "rowId": row["rowId"],
            "category": row["category"],
            "scenarioTemplate": row["scenarioTemplate"],
            "phaseMetric": phase["metric"],
            "baselineValue": phase["baselineValue"],
            "comparisonValue": phase["comparisonValue"],
            "comparisonDelta": phase["comparisonDelta"],
            "baselineLeadPercent": phase["baselineLeadPercent"],
        }
        for row in rows
        for phase in row["phaseMetrics"]
        if float(phase["comparisonDelta"]) < 0.0
    ]
    slower_percentiles = [
        {
            "layer": row["layer"],
            "rowId": row["rowId"],
            "category": row["category"],
            "scenarioTemplate": row["scenarioTemplate"],
            "metric": percentile["metric"],
            "percentile": percentile["percentile"],
            "baselineValue": percentile["baselineValue"],
            "comparisonValue": percentile["comparisonValue"],
            "comparisonDelta": percentile["comparisonDelta"],
            "baselineLeadPercent": percentile["baselineLeadPercent"],
        }
        for row in rows
        for percentile in row["selectedMetricDistribution"]["percentileDeltas"]
        if float(percentile["comparisonDelta"]) < 0.0
    ]
    worst_phases = sorted(
        slower_phases,
        key=lambda phase: float(phase["comparisonDelta"]),
    )[:limit]
    worst_percentiles = sorted(
        slower_percentiles,
        key=lambda percentile: float(percentile["comparisonDelta"]),
    )[:limit]

    return {
        "basis": "baselineLeadPercent ascending; negative means baseline mode was slower",
        "slowerCategoryCount": len(slower_categories),
        "slowerRowCount": len(slower_rows),
        "slowerPhaseCount": len(slower_phases),
        "slowerSelectedPercentileCount": len(slower_percentiles),
        "worstCategories": [
            {
                "category": category["category"],
                "baselineScore": category["baselineScore"],
                "comparisonScore": category["comparisonScore"],
                "comparisonDeltaPercent": category["comparisonDeltaPercent"],
                "baselineLeadPercent": category["baselineLeadPercent"],
                "rowCount": category["rowCount"],
            }
            for category in worst_categories
        ],
        "worstRows": [
            {
                "layer": row["layer"],
                "rowId": row["rowId"],
                "category": row["category"],
                "scenarioTemplate": row["scenarioTemplate"],
                "metric": row["metric"],
                "baselineValue": row["baselineValue"],
                "comparisonValue": row["comparisonValue"],
                "comparisonDeltaPercent": row["comparisonDeltaPercent"],
                "baselineLeadPercent": row["baselineLeadPercent"],
                "resourcePath": row["resourcePath"],
                "resourceSha256": row["resourceSha256"],
            }
            for row in worst_rows
        ],
        "worstPhases": worst_phases,
        "worstSelectedPercentiles": worst_percentiles,
    }


def mode_detail_by_mode(report_payload: dict[str, Any]) -> dict[str, dict[str, Any]]:
    details_raw = report_payload.get("modeRunDetails")
    if not isinstance(details_raw, list):
        return {}
    details: dict[str, dict[str, Any]] = {}
    for detail in details_raw:
        if not isinstance(detail, dict):
            continue
        mode = detail.get("mode")
        if isinstance(mode, str) and mode and mode not in details:
            details[mode] = detail
    return details


def mode_run_trace(report_payload: dict[str, Any]) -> list[dict[str, Any]]:
    details_raw = report_payload.get("modeRunDetails")
    if not isinstance(details_raw, list):
        return []
    trace: list[dict[str, Any]] = []
    for detail in details_raw:
        if not isinstance(detail, dict):
            continue
        trace.append(
            {
                "mode": detail.get("mode", ""),
                "scheduleLayer": detail.get("scheduleLayer", ""),
                "scheduleUnit": detail.get("scheduleUnit", ""),
                "schedulePass": detail.get("schedulePass"),
                "hash": detail.get("hash"),
                "previousHash": detail.get("previousHash"),
            }
        )
    return trace


def build_mode_identity(mode: str, detail: dict[str, Any] | None) -> dict[str, Any]:
    if not isinstance(detail, dict):
        return {
            "mode": mode,
            "selectedRuntime": "",
            "fallbackApplied": False,
            "fallbackReasonCode": "",
            "hiddenFallbackAllowed": False,
            "selectorVersion": "",
            "browserExecutablePath": "",
            "browserExecutableSha256": None,
            "browserVersion": "",
            "userAgent": "",
            "dawnRuntimePath": "",
            "dawnRuntimeSha256": None,
            "doeRuntimePath": "",
            "doeRuntimeSha256": None,
            "shaderCompilerIdentity": {},
            "adapterIdentity": {},
            "traceHash": None,
            "previousTraceHash": None,
        }

    runtime_selection = detail.get("runtimeSelection")
    if not isinstance(runtime_selection, dict):
        runtime_selection = {}
    artifact_identity = runtime_selection.get("artifactIdentity")
    if not isinstance(artifact_identity, dict):
        artifact_identity = {}
    runtime_probe = detail.get("runtimeProbe")
    if not isinstance(runtime_probe, dict):
        runtime_probe = {}
    runtime_evidence = detail.get("runtimeEvidence")
    if not isinstance(runtime_evidence, dict):
        runtime_evidence = {}

    return {
        "mode": mode,
        "selectedRuntime": runtime_selection.get("selectedRuntime", ""),
        "fallbackApplied": bool(runtime_selection.get("fallbackApplied", False)),
        "fallbackReasonCode": runtime_selection.get("fallbackReasonCode", ""),
        "hiddenFallbackAllowed": bool(runtime_selection.get("hiddenFallbackAllowed", False)),
        "selectorVersion": runtime_selection.get("selectorVersion", ""),
        "browserExecutablePath": artifact_identity.get("browserExecutablePath", ""),
        "browserExecutableSha256": artifact_identity.get("browserExecutableSha256"),
        "browserVersion": runtime_evidence.get("browserVersion", ""),
        "userAgent": runtime_evidence.get("userAgent", ""),
        "dawnRuntimePath": artifact_identity.get("dawnRuntimePath", ""),
        "dawnRuntimeSha256": artifact_identity.get("dawnRuntimeSha256"),
        "doeRuntimePath": artifact_identity.get("doeLibPath", ""),
        "doeRuntimeSha256": artifact_identity.get("doeLibSha256"),
        "shaderCompilerIdentity": detail.get("shaderCompilerIdentity", {}),
        "adapterIdentity": runtime_probe.get("adapterIdentity", {}),
        "traceHash": detail.get("hash"),
        "previousTraceHash": detail.get("previousHash"),
    }


def build_score_report(
    report_payload: dict[str, Any],
    *,
    report_path: Path,
    baseline_mode: str,
    comparison_mode: str,
) -> dict[str, Any]:
    if report_payload.get("reportKind") != "browser-layered-diagnostic":
        raise ValueError("input reportKind must be browser-layered-diagnostic")

    mode_order = report_payload.get("modeOrder")
    if not isinstance(mode_order, list):
        raise ValueError("input report missing modeOrder[]")
    if baseline_mode not in mode_order or comparison_mode not in mode_order:
        raise ValueError(
            "input report must contain both baseline and comparison modes: "
            f"{baseline_mode}, {comparison_mode}"
        )

    scored_rows: list[dict[str, Any]] = []
    excluded_rows: list[dict[str, Any]] = []
    for layer in ("l1", "l2"):
        section = report_payload.get(layer)
        if not isinstance(section, dict):
            raise ValueError(f"input report missing {layer} object")
        rows = section.get("rows")
        if not isinstance(rows, list):
            raise ValueError(f"input report missing {layer}.rows[]")
        for row in rows:
            if not isinstance(row, dict):
                continue
            scored, excluded = build_row_score(
                layer=layer,
                row=row,
                baseline_mode=baseline_mode,
                comparison_mode=comparison_mode,
            )
            if scored is not None:
                scored_rows.append(scored)
            if excluded is not None:
                excluded_rows.append(excluded)

    if not scored_rows:
        raise ValueError("no scorable rows found in layered report")

    mode_chrome_paths = report_payload.get("modeChromePaths")
    if not isinstance(mode_chrome_paths, dict):
        mode_chrome_paths = {}
    mode_details = mode_detail_by_mode(report_payload)

    categories = summarize_categories(scored_rows)
    output = {
        "schemaVersion": 1,
        "generatedAt": datetime.now(UTC).isoformat().replace("+00:00", "Z"),
        "reportKind": "browser-layered-score",
        "benchmarkClass": "directional",
        "comparisonStatus": "diagnostic",
        "claimStatus": "diagnostic",
        "timingClass": report_payload.get("timingClass", "scenario"),
        "timingSource": report_payload.get("timingSource", "browser-performance-now"),
        "sourceReport": {
            "path": str(report_path),
            "sha256": sha256_hex(report_path.read_bytes()),
            "reportKind": report_payload.get("reportKind"),
            "projectionContractHash": report_payload.get("projectionContractHash"),
            "reportHash": report_payload.get("reportHash"),
        },
        "baselineMode": baseline_mode,
        "comparisonMode": comparison_mode,
        "modeOrder": report_payload.get("modeOrder", []),
        "modeSchedule": report_payload.get("modeSchedule", "grouped"),
        "browserExecutables": {
            "baseline": mode_chrome_paths.get(baseline_mode, ""),
            "comparison": mode_chrome_paths.get(comparison_mode, ""),
        },
        "workloadIdentity": report_payload.get("workloadIdentity", {}),
        "workloadFilter": report_payload.get("workloadFilter", {"kind": "none", "categories": []}),
        "methodology": report_payload.get("methodology", {}),
        "browserEnvironmentEvidence": report_payload.get("browserEnvironmentEvidence", {}),
        "modeIdentities": {
            "baseline": build_mode_identity(
                baseline_mode,
                mode_details.get(baseline_mode),
            ),
            "comparison": build_mode_identity(
                comparison_mode,
                mode_details.get(comparison_mode),
            ),
        },
        "modeRunTrace": mode_run_trace(report_payload),
        "scoreMethod": {
            "id": SCORE_METHOD_ID,
            "legacyRelativeIndexParityScore": 100.0,
            "ratioFormula": "baselineMetric / comparisonMetric",
            "scoreFormula": "baselineScore from pairedModeScoreFormula",
            "legacyRatioScoreFormula": "100 * geometric_mean(rowRatios)",
            "categoryBalancedScoreFormula": "baselineScore from pairedModeScoreFormula over category geomean ratios",
            "pairedModeScoreFormula": "baselineScore=100/(1+ratio), comparisonScore=100*ratio/(1+ratio)",
            "comparisonDeltaPercentFormula": "(1 - baselineMetric / comparisonMetric) * 100",
            "baselineLeadPercentFormula": "(comparisonMetric - baselineMetric) / comparisonMetric * 100",
            "strictComparableBasis": f"strictComparable includes only scorable rows with {STRICT_COMPARABLE_CRITERIA}.",
            "metricPriority": [metric for metric, _unit in METRIC_PRIORITY],
            "selectedMetricDistribution": {
                "sampleCountField": "sourceKernelSampleCount when emitted by the row",
                "percentiles": ["p10", "p50", "p95", "p99"],
            },
            "categoryMapping": {
                "source": "domain for L1 rows; workflow id for L2 rows",
                "domainRules": CATEGORY_BY_DOMAIN,
                "workflowRules": CATEGORY_BY_WORKFLOW_ID,
            },
            "notes": [
                "Lower metric values are better.",
                "baselineScore and comparisonScore are paired mode scores; parity is 50/50.",
                "comparisonDeltaPercent and baselineLeadPercent are positive when the baseline mode was faster.",
                "score is the baseline paired score; legacyRatioScore keeps the older geomean-ratio index.",
                "overall is row-weighted; categoryBalancedOverall gives each category one vote.",
                "strictComparable is the fair summary for strict projected browser rows that are source-comparable and source-claim-eligible.",
                "This score is diagnostic and not a release performance claim.",
            ],
        },
        "overall": {
            "baselineMode": baseline_mode,
            "comparisonMode": comparison_mode,
            **summarize_rows(scored_rows),
        },
        "categoryBalancedOverall": summarize_category_balanced(
            categories,
            baseline_mode=baseline_mode,
            comparison_mode=comparison_mode,
        ),
        "bottlenecks": summarize_bottlenecks(
            categories=categories,
            rows=scored_rows,
        ),
        "strictComparable": strict_comparable_summary(scored_rows),
        "categories": categories,
        "rows": scored_rows,
        "excludedRows": excluded_rows,
    }
    output["scoreReportHash"] = sha256_hex(stable_json(output))
    return output


def main() -> int:
    args = parse_args()
    report_path = Path(args.report).resolve()
    out_path = Path(args.out).resolve()
    try:
        report_payload = load_json(report_path)
        score_report = build_score_report(
            report_payload,
            report_path=report_path,
            baseline_mode=args.baseline_mode,
            comparison_mode=args.comparison_mode,
        )
    except Exception as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        return 2

    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(
        json.dumps(score_report, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    overall = score_report["overall"]
    category_balanced = score_report["categoryBalancedOverall"]
    print(
        "[browser-score] "
        f"{args.baseline_mode}={overall['baselineScore']:.2f} "
        f"{args.comparison_mode}={overall['comparisonScore']:.2f} "
        f"delta={overall['baselineLeadPercent']:+.2f}% "
        f"categoryBalanced.{args.baseline_mode}={category_balanced['baselineScore']:.2f} "
        f"categoryBalanced.{args.comparison_mode}={category_balanced['comparisonScore']:.2f} "
        f"categoryBalanced.delta={category_balanced['baselineLeadPercent']:+.2f}% "
        f"rows={overall['rowCount']} "
        f"categories={category_balanced['categoryCount']} "
        f"out={out_path}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
