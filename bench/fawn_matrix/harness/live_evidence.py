"""Evidence validation, evaluation, and promotion receipts for live workloads."""

from __future__ import annotations

import hashlib
import hmac
import json
import os
from pathlib import Path
from typing import Any

from bench.fawn_matrix.harness.lanes import compute_percentile
from bench.fawn_matrix.harness.types import Lane


class LiveEvidenceError(ValueError):
    """Raised when live workload evidence is not admissible."""


LANES = [lane.value for lane in Lane]
RUNTIMES = {
    Lane.LANE_A.value: "dawn",
    Lane.LANE_B.value: "dawn",
    Lane.LANE_C.value: "doe",
    Lane.LANE_D.value: "doe",
}


def canonical_hash(value: Any) -> str:
    encoded = json.dumps(
        value,
        sort_keys=True,
        separators=(",", ":"),
    ).encode()
    return hashlib.sha256(encoded).hexdigest()


def file_hash(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _require(condition: bool, message: str) -> None:
    if not condition:
        raise LiveEvidenceError(message)


def validate_live_raw(
    payload: dict[str, Any],
    workload: dict[str, Any],
) -> dict[str, Any]:
    _require(not payload.get("simulated_mode"), "simulated evidence rejected")
    _require(payload.get("reportKind") == "fawn-doe-live-workload-raw", "wrong report kind")
    _require(payload.get("workloadId") == workload["workloadId"], "workload mismatch")
    _require(payload.get("runStatus") == "passed", "executor did not pass")
    _require(not payload.get("errors"), "executor recorded errors")
    _require(set(payload.get("lanes", {})) == set(LANES), "all four lanes are required")
    run = payload["run"]
    _require(run.get("laneOrderPolicy") == "rotating_interleaved_v1", "samples are not interleaved")
    _require(run.get("timedIterations") == workload["timedIterations"], "timed count mismatch")
    oracle_by_iteration: dict[tuple[str, int], set[str]] = {}
    output_by_iteration: dict[tuple[str, int], set[str]] = {}
    order_by_iteration: dict[tuple[str, int], set[int]] = {}
    for lane_id in LANES:
        lane = payload["lanes"][lane_id]
        runtime = lane["runtimeIdentity"]
        _require(runtime.get("selectedRuntime") == RUNTIMES[lane_id], f"{lane_id} runtime mismatch")
        _require(not runtime.get("fallbackApplied"), f"{lane_id} applied fallback")
        _require(not runtime.get("hiddenFallbackAllowed"), f"{lane_id} permits hidden fallback")
        _require(runtime.get("activeRuntimeProof", {}).get("matched"), f"{lane_id} runtime proof failed")
        for identity_key in ("browserIdentity", "runtimeIdentity"):
            identity = lane[identity_key]
            artifact_path = Path(identity.get("executablePath") or identity.get("artifactPath"))
            expected_hash = identity.get("executableSha256") or identity.get("artifactSha256")
            _require(artifact_path.is_file(), f"missing artifact {artifact_path}")
            _require(file_hash(artifact_path) == expected_hash, f"artifact hash mismatch {artifact_path}")
        expected_transport = "fawn_direct_raw_cdp_v1" if lane_id == Lane.LANE_D.value else "playwright_v1"
        _require(lane.get("transport") == expected_transport, f"{lane_id} transport mismatch")
        samples = lane.get("samples", [])
        timed = [sample for sample in samples if sample.get("phase") == "timed"]
        _require(len(timed) == workload["timedIterations"], f"{lane_id} timed sample count mismatch")
        _require(len({sample["timing"]["totalWallMs"] for sample in timed}) > 1, f"{lane_id} constant timings")
        for sample in samples:
            _require(sample.get("success") and sample.get("oraclePass"), f"{lane_id} sample failed")
            _require(sample["timing"]["totalWallMs"] > 0, f"{lane_id} invalid timing")
            key = (sample["phase"], sample["iteration"])
            order_by_iteration.setdefault(key, set()).add(sample["orderIndex"])
            if payload["workloadId"] == "webgpu_model_preprocessing":
                output_by_iteration.setdefault(key, set()).add(sample["outputSha256"])
            else:
                oracle_by_iteration.setdefault(key, set()).add(sample["oracleSha256"])
    _require(all(value == {0, 1, 2, 3} for value in order_by_iteration.values()), "lane order is incomplete")
    _require(all(len(value) == 1 for value in output_by_iteration.values()), "GPU outputs differ across lanes")
    _require(all(len(value) == 1 for value in oracle_by_iteration.values()), "task oracle differs across lanes")
    return {
        "status": "pass",
        "physicalHardware": payload.get("platform", {}).get("hardwareIdentity", {}).get("verified") is True,
        "interleaved": True,
        "structuralEquivalence": "pass",
        "independentOracle": True,
    }


def _metrics(samples: list[dict[str, Any]], workload_id: str) -> dict[str, Any]:
    timed = [sample for sample in samples if sample["phase"] == "timed"]
    latencies = [sample["timing"]["totalWallMs"] for sample in timed]
    metrics: dict[str, Any] = {
        "sampleCount": len(timed),
        "successRate": sum(bool(sample["success"]) for sample in timed) / len(timed),
        "latencyMsP50": compute_percentile(latencies, 0.50),
        "latencyMsP95": compute_percentile(latencies, 0.95),
        "latencyMsP99": compute_percentile(latencies, 0.99),
        "memoryPeakMb": max(sample.get("memoryMb", 0) for sample in timed),
    }
    if workload_id == "webgpu_model_preprocessing":
        for key in (
            "compilationMs",
            "pipelineCreationMs",
            "uploadMs",
            "dispatchMs",
            "synchronizationMs",
            "readbackMs",
        ):
            metrics[key + "P50"] = compute_percentile(
                [sample["timing"][key] for sample in timed],
                0.50,
            )
        metrics["maxAbsError"] = max(sample["maxAbsError"] for sample in timed)
    else:
        metrics["contextBytesP50"] = compute_percentile([sample["contextBytes"] for sample in timed], 0.50)
        metrics["contextTokensP50"] = compute_percentile([sample["contextTokens"] for sample in timed], 0.50)
        metrics["coldLatencyMsP50"] = compute_percentile(
            [sample["timing"]["totalWallMs"] for sample in timed if sample["sessionMode"] == "cold"], 0.50)
        metrics["warmLatencyMsP50"] = compute_percentile(
            [sample["timing"]["totalWallMs"] for sample in timed if sample["sessionMode"] == "warm"], 0.50)
    return metrics


def evaluate_live_workload(
    payload: dict[str, Any],
    workload: dict[str, Any],
    comparability: dict[str, Any],
    raw_path: Path,
) -> dict[str, Any]:
    lane_metrics = {
        lane_id: _metrics(payload["lanes"][lane_id]["samples"], payload["workloadId"])
        for lane_id in LANES
    }
    a = lane_metrics[Lane.LANE_A.value]
    b = lane_metrics[Lane.LANE_B.value]
    c = lane_metrics[Lane.LANE_C.value]
    d = lane_metrics[Lane.LANE_D.value]
    report: dict[str, Any] = {
        "schemaVersion": 1,
        "reportKind": "fawn-doe-live-workload-platform-report",
        "workloadId": payload["workloadId"],
        "evidenceStatus": "physical_diagnostic",
        "platform": payload["platform"],
        "comparability": comparability,
        "laneMetrics": lane_metrics,
        "rawArtifact": {"path": str(raw_path), "sha256": file_hash(raw_path)},
    }
    if payload["workloadId"] == "webgpu_model_preprocessing":
        speedup = b["latencyMsP50"] / c["latencyMsP50"]
        evidenced = speedup >= workload["materialSpeedupRatio"]
        report.update({
            "primaryComparison": "lane_c_over_lane_b",
            "speedupCOverB": speedup,
            "overallThesisStatus": "DOE_RUNTIME_PREPROCESSING_EVIDENCED" if evidenced else "DOE_RUNTIME_PREPROCESSING_NOT_EVIDENCED",
            "productDecision": "Use DoeRuntime beneath Fawn for this workload after the second physical platform agrees." if evidenced else "Retain Dawn beneath Fawn for this workload while DoeRuntime improves.",
        })
    else:
        speedup = a["latencyMsP50"] / d["latencyMsP50"]
        cold_speedup = a["coldLatencyMsP50"] / d["coldLatencyMsP50"]
        warm_speedup = a["warmLatencyMsP50"] / d["warmLatencyMsP50"]
        token_reduction = a["contextTokensP50"] / d["contextTokensP50"]
        byte_reduction = a["contextBytesP50"] / d["contextBytesP50"]
        evidenced = (
            cold_speedup >= workload["materialSpeedupRatio"]
            and warm_speedup >= workload["materialSpeedupRatio"]
            and token_reduction
            >= workload["materialContextReductionRatio"]
        )
        report.update({
            "primaryComparison": "lane_d_over_lane_a",
            "speedupDOverA": speedup,
            "coldSpeedupDOverA": cold_speedup,
            "warmSpeedupDOverA": warm_speedup,
            "tokenReductionDOverA": token_reduction,
            "byteReductionDOverA": byte_reduction,
            "overallThesisStatus": "VERTICAL_AGENT_STACK_EVIDENCED" if evidenced else "VERTICAL_AGENT_STACK_NOT_EVIDENCED",
            "productDecision": "Promote the complete stack only after the second physical platform agrees." if evidenced else "Do not promote the complete vertical stack from this workload.",
        })
    report["reportHash"] = canonical_hash(report)
    return report


def promotion_receipt(subject: dict[str, Any], signing_environment: str) -> dict[str, Any]:
    subject_hash = canonical_hash(subject)
    key = os.environ.get(signing_environment)
    signature = hmac.new(key.encode(), subject_hash.encode(), hashlib.sha256).hexdigest() if key else None
    return {
        "receiptKind": "doe-promotion-receipt-v1",
        "subjectSha256": subject_hash,
        "signatureAlgorithm": "hmac-sha256" if key else None,
        "signature": signature,
        "signatureStatus": "signed" if key else "unsigned_review_required",
    }


def build_platform_suite(
    reports: list[dict[str, Any]],
    signing_environment: str,
) -> dict[str, Any]:
    by_workload = {
        report.get("workloadId") or report.get("workload_id"): report
        for report in reports
    }
    required = {"context_snapshot_diff", "webgpu_model_preprocessing", "multi_step_agent_interaction"}
    _require(set(by_workload) == required, "suite requires all three workloads")
    platform_ids = {report["platform"]["platformId"] for report in reports}
    _require(len(platform_ids) == 1, "suite reports must share one platform")
    _require(all(report.get("evidenceStatus") in {"physical_diagnostic", "physical"} or report.get("evidence_status") == "physical_diagnostic" for report in reports), "suite contains non-physical evidence")
    _require(
        all(report.get("comparability", {}).get("status") == "pass" for report in reports),
        "suite contains incomparable evidence",
    )
    suite = {
        "schemaVersion": 1,
        "reportKind": "fawn-doe-platform-suite",
        "platform": reports[0]["platform"],
        "workloads": by_workload,
        "decisions": {
            "fawnShell": by_workload["context_snapshot_diff"].get("speedup_b_over_a", 0) >= 1.05,
            "doeRuntime": by_workload["webgpu_model_preprocessing"]["overallThesisStatus"] == "DOE_RUNTIME_PREPROCESSING_EVIDENCED",
            "directProtocol": by_workload["context_snapshot_diff"].get("overall_thesis_status") == "FAWN_DIRECT_CONTEXT_PATH_EVIDENCED",
            "verticalStack": by_workload["multi_step_agent_interaction"]["overallThesisStatus"] == "VERTICAL_AGENT_STACK_EVIDENCED",
        },
    }
    suite["earnedComponents"] = sorted(
        component
        for component, earned in suite["decisions"].items()
        if earned
    )
    suite["promotionReceipt"] = promotion_receipt(suite, signing_environment)
    suite["reportHash"] = canonical_hash(suite)
    return suite


def aggregate_platform_suites(
    suites: list[dict[str, Any]],
    core_platforms: list[str],
    desktop_platforms: list[str],
) -> dict[str, Any]:
    by_platform = {suite["platform"]["platformId"]: suite for suite in suites}
    missing_core = sorted(set(core_platforms) - set(by_platform))
    _require(not missing_core, "missing core physical platforms: " + ", ".join(missing_core))
    identities = [suite["platform"]["hardwareIdentity"]["identityHash"] for suite in suites]
    _require(len(identities) == len(set(identities)), "physical hardware identities are not distinct")
    aggregate = {
        "schemaVersion": 1,
        "reportKind": "fawn-doe-cross-platform-suite",
        "platforms": by_platform,
        "corePlatformStatus": "pass",
        "desktopPlatformStatus": "pass" if set(desktop_platforms) <= set(by_platform) else "pending",
        "missingDesktopPlatforms": sorted(set(desktop_platforms) - set(by_platform)),
        "publicationStatus": "review_required",
    }
    aggregate["reportHash"] = canonical_hash(aggregate)
    return aggregate


def validate_passport_candidate(aggregate: dict[str, Any]) -> None:
    _require(aggregate.get("reportKind") == "fawn-doe-cross-platform-suite", "wrong aggregate kind")
    _require(aggregate.get("corePlatformStatus") == "pass", "core platform gate failed")
    for platform_id, suite in aggregate.get("platforms", {}).items():
        _require(suite.get("promotionReceipt", {}).get("signatureStatus") == "signed", f"{platform_id} receipt is unsigned")
        _require(bool(suite.get("earnedComponents")), f"{platform_id} earned no product component")
        _require(suite.get("decisions", {}).get("verticalStack") is True, f"{platform_id} vertical task gate failed")
