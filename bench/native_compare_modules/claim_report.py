"""Separate claim evaluation from compare reports."""

from __future__ import annotations

import json
import hashlib
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from native_compare_modules.claimability import assess_claimability
from native_compare_modules.compare_from_artifacts import load_compare_report, receipt_run_view
from native_compare_modules.run_artifact import load_run_artifact
from native_compare_modules.runner import file_sha256


CLAIM_REPORT_SCHEMA_VERSION = 1
CLAIM_REPORT_KIND = "claim-report"


@dataclass(frozen=True)
class _ClaimWorkload:
    id: str
    domain: str
    comparable: bool
    claim_eligible: bool
    path_asymmetry: bool
    path_asymmetry_note: str


def _benchmark_policy_ref(source_path: str) -> dict[str, Any]:
    if not source_path:
        return {"path": "", "sha256": ""}
    path = Path(source_path)
    return {
        "path": str(path),
        "sha256": file_sha256(path) if path.exists() else "",
    }


def _claim_policy_hash(
    *,
    mode: str,
    min_timed_samples: int,
    benchmark_policy_ref: dict[str, Any],
) -> str:
    payload = {
        "mode": mode,
        "minTimedSamples": min_timed_samples,
        "benchmarkPolicy": benchmark_policy_ref,
    }
    rendered = json.dumps(payload, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(rendered.encode("utf-8")).hexdigest()


def _workload_proxy(entry: dict[str, Any]) -> _ClaimWorkload:
    return _ClaimWorkload(
        id=str(entry.get("id", "")).strip(),
        domain=str(entry.get("domain", "")).strip(),
        comparable=bool(entry.get("workloadComparable", False)),
        claim_eligible=bool(entry.get("claimEligible", True)),
        path_asymmetry=bool(entry.get("pathAsymmetry", False)),
        path_asymmetry_note=str(entry.get("pathAsymmetryNote", "")).strip(),
    )


def _load_receipt_from_entry(entry: dict[str, Any], side_name: str) -> dict[str, Any]:
    receipts = entry.get("receipts", {})
    if not isinstance(receipts, dict):
        raise ValueError(f"compare workload entry missing receipts: {entry.get('id')}")
    side = receipts.get(side_name)
    if not isinstance(side, dict):
        raise ValueError(
            f"compare workload entry missing {side_name} receipt: {entry.get('id')}"
        )
    path = str(side.get("path", "")).strip()
    if not path:
        raise ValueError(
            f"compare workload entry missing {side_name} receipt path: {entry.get('id')}"
        )
    return load_run_artifact(path)


def build_claim_report(
    *,
    compare_report: dict[str, Any],
    compare_report_path: str | Path,
    benchmark_policy: Any,
    mode: str,
    min_timed_samples: int,
) -> dict[str, Any]:
    """Evaluate claimability from a compare report and its referenced receipts."""
    if mode not in {"local", "release"}:
        raise ValueError("claim mode must be one of ['local', 'release']")
    compare_path = Path(compare_report_path)
    benchmark_policy_ref = _benchmark_policy_ref(benchmark_policy.source_path)
    policy_hash = _claim_policy_hash(
        mode=mode,
        min_timed_samples=min_timed_samples,
        benchmark_policy_ref=benchmark_policy_ref,
    )
    workload_results: list[dict[str, Any]] = []
    failure_reasons: list[str] = []
    for entry in compare_report.get("workloads", []):
        if not isinstance(entry, dict):
            continue
        baseline_receipt = _load_receipt_from_entry(entry, "left")
        comparison_receipt = _load_receipt_from_entry(entry, "right")
        claimability = assess_claimability(
            mode=mode,
            min_timed_samples=min_timed_samples,
            workload=_workload_proxy(entry),
            baseline=receipt_run_view(baseline_receipt),
            comparison=receipt_run_view(comparison_receipt),
            delta=entry.get("deltaPercent", {}),
            timing_interpretation=entry.get("timingInterpretation", {}),
            comparability=entry.get("comparability", {}),
            benchmark_policy=benchmark_policy,
        )
        workload_result = {
            "workloadId": entry.get("id", ""),
            "evaluated": bool(claimability.get("evaluated", True)),
            "claimable": bool(claimability.get("claimable", False)),
            "reasons": list(claimability.get("reasons", [])),
            "claimMetricField": claimability.get("claimMetricField", ""),
            "claimMetricScope": claimability.get("claimMetricScope", ""),
            "skipReason": claimability.get("skipReason", ""),
            "auditNotes": list(claimability.get("auditNotes", [])),
            "requiredPositivePercentiles": list(
                claimability.get("requiredPositivePercentiles", [])
            ),
        }
        workload_results.append(workload_result)
        if not workload_result["claimable"]:
            failure_reasons.append(
                f"{workload_result['workloadId']}: "
                + " | ".join(workload_result["reasons"])
            )
    claim_status = "claimable" if not failure_reasons else "diagnostic"
    return {
        "schemaVersion": CLAIM_REPORT_SCHEMA_VERSION,
        "artifactKind": CLAIM_REPORT_KIND,
        "generatedAt": datetime.now(timezone.utc).isoformat(),
        "compareReport": {
            "path": str(compare_path),
            "sha256": file_sha256(compare_path),
        },
        "comparisonStatus": compare_report.get("comparisonStatus", ""),
        "claimStatus": claim_status,
        "pass": claim_status == "claimable",
        "claimPolicy": {
            "mode": mode,
            "minTimedSamples": min_timed_samples,
            "benchmarkPolicy": benchmark_policy_ref,
            "policyHash": policy_hash,
        },
        "workloads": workload_results,
        "reasons": failure_reasons,
    }


def write_claim_report(report: dict[str, Any], path: Path) -> Path:
    """Write claim report to disk."""
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps(report, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    return path


def load_claim_report(path: str | Path) -> dict[str, Any]:
    """Load a claim report from disk."""
    report_path = Path(path)
    if not report_path.exists():
        raise FileNotFoundError(f"claim report not found: {report_path}")
    payload = json.loads(report_path.read_text(encoding="utf-8"))
    if not isinstance(payload, dict):
        raise ValueError(f"claim report must be a JSON object: {report_path}")
    if payload.get("artifactKind") != CLAIM_REPORT_KIND:
        raise ValueError(
            f"expected artifactKind={CLAIM_REPORT_KIND!r}, "
            f"got {payload.get('artifactKind')!r}: {report_path}"
        )
    return payload


def load_compare_report_with_path(path: str | Path) -> dict[str, Any]:
    """Thin helper for config/CLI claim entrypoints."""
    return load_compare_report(path)
