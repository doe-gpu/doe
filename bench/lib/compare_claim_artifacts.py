"""Helpers for compare reports, claim sidecars, and referenced run receipts."""

from __future__ import annotations

from pathlib import Path
from typing import Any

from native_compare_modules.compare_from_artifacts import (
    load_compare_report as _load_compare_report,
)
from native_compare_modules.compare_from_artifacts import receipt_run_view
from native_compare_modules.claim_report import load_claim_report as _load_claim_report
from native_compare_modules.run_artifact import load_run_artifact
from native_compare_modules.runner import file_sha256


def claim_report_candidate_path(compare_report_path: Path) -> Path:
    name = compare_report_path.name
    if name.endswith(".compare.json"):
        return compare_report_path.with_name(
            name.replace(".compare.json", ".claim.json")
        )
    if name.endswith(".json"):
        return compare_report_path.with_name(name[:-5] + ".claim.json")
    return compare_report_path.with_name(name + ".claim.json")


def default_claim_report_path(compare_report_path: Path) -> Path | None:
    candidate = claim_report_candidate_path(compare_report_path)
    if candidate.exists():
        return candidate
    return None


def resolve_artifact_path(compare_report_path: Path, raw_path: str) -> Path:
    candidate = Path(raw_path)
    if candidate.is_absolute():
        return candidate.resolve()
    if candidate.exists():
        return candidate.resolve()
    return (compare_report_path.parent / candidate).resolve()


def load_compare_report(path: Path) -> dict[str, Any]:
    return _load_compare_report(path)


def load_optional_claim_report(
    compare_report_path: Path,
    *,
    explicit_path: str = "",
    required: bool = False,
) -> tuple[dict[str, Any] | None, Path | None]:
    claim_path: Path | None
    if explicit_path.strip():
        claim_path = resolve_artifact_path(compare_report_path, explicit_path.strip())
    else:
        claim_path = default_claim_report_path(compare_report_path)
    if claim_path is None or not claim_path.exists():
        if required:
            raise FileNotFoundError(
                f"claim report not found for compare report: {compare_report_path}"
            )
        return None, None
    return _load_claim_report(claim_path), claim_path


def claim_workloads_by_id(claim_report: dict[str, Any] | None) -> dict[str, dict[str, Any]]:
    if not isinstance(claim_report, dict):
        return {}
    rows = claim_report.get("workloads")
    if not isinstance(rows, list):
        return {}
    out: dict[str, dict[str, Any]] = {}
    for row in rows:
        if not isinstance(row, dict):
            continue
        workload_id = row.get("workloadId")
        if isinstance(workload_id, str) and workload_id:
            out[workload_id] = row
    return out


def required_positive_percentiles(mode: str) -> list[str]:
    if mode == "release":
        return ["p50Percent", "p95Percent", "p99Percent"]
    if mode == "local":
        return ["p50Percent", "p95Percent"]
    return []


def claim_status(compare_report: dict[str, Any], claim_report: dict[str, Any] | None) -> str:
    if isinstance(claim_report, dict):
        value = claim_report.get("claimStatus")
        if isinstance(value, str) and value:
            return value
    return "not-evaluated"


def claim_mode(claim_report: dict[str, Any] | None) -> str:
    if not isinstance(claim_report, dict):
        return ""
    claim_policy = claim_report.get("claimPolicy")
    if not isinstance(claim_policy, dict):
        return ""
    value = claim_policy.get("mode")
    return value if isinstance(value, str) else ""


# Modes accepted on the release surface. CLAUDE.md non-negotiable #7 requires
# Dawn-vs-Doe claims be apples-to-apples by default; only "strict" enforces the
# domain-specific timing-source whitelist and full phase-equivalence checks in
# native_compare_modules/comparability.py. Local diagnostic runs may use "warn"
# or "off", but those artifacts must not be promoted into release evidence.
RELEASE_REQUIRED_COMPARABILITY_MODES: tuple[str, ...] = ("strict",)


def comparability_mode(compare_report: dict[str, Any]) -> str:
    policy = compare_report.get("comparabilityPolicy")
    if not isinstance(policy, dict):
        return ""
    value = policy.get("mode")
    return value if isinstance(value, str) else ""


def ensure_release_strict_comparability(
    compare_report: dict[str, Any],
    report_path: Path,
    *,
    surface: str,
) -> None:
    mode = comparability_mode(compare_report)
    if mode in RELEASE_REQUIRED_COMPARABILITY_MODES:
        return
    allowed = ", ".join(RELEASE_REQUIRED_COMPARABILITY_MODES)
    raise RuntimeError(
        f"{surface}: compare report {report_path} carries "
        f"comparabilityPolicy.mode={mode!r}; release surface requires one of: "
        f"{allowed}. Re-run the compare lane without --comparability-mode "
        f"warn/off, or route this artifact through a non-release path."
    )


def claim_min_timed_samples(claim_report: dict[str, Any] | None) -> int | None:
    if not isinstance(claim_report, dict):
        return None
    claim_policy = claim_report.get("claimPolicy")
    if not isinstance(claim_policy, dict):
        return None
    value = claim_policy.get("minTimedSamples")
    return value if isinstance(value, int) else None


def non_claimable_count(compare_report: dict[str, Any], claim_report: dict[str, Any] | None) -> int:
    claim_rows = claim_workloads_by_id(claim_report)
    if not claim_rows:
        return 0
    count = 0
    for workload in compare_report.get("workloads", []):
        if not isinstance(workload, dict):
            continue
        workload_id = workload.get("id")
        if not isinstance(workload_id, str) or not workload_id:
            continue
        claim_entry = claim_rows.get(workload_id)
        if not isinstance(claim_entry, dict):
            count += 1
            continue
        if claim_entry.get("claimable") is not True:
            count += 1
    return count


def load_run_receipt(
    compare_report_path: Path,
    raw_path: str,
    *,
    cache: dict[str, dict[str, Any]] | None = None,
) -> dict[str, Any]:
    resolved = resolve_artifact_path(compare_report_path, raw_path)
    cache_key = str(resolved)
    if cache is not None and cache_key in cache:
        return cache[cache_key]
    receipt = load_run_artifact(resolved)
    receipt["_receiptPath"] = str(resolved)
    if cache is not None:
        cache[cache_key] = receipt
    return receipt


def load_workload_receipts(
    entry: dict[str, Any],
    compare_report_path: Path,
    *,
    cache: dict[str, dict[str, Any]] | None = None,
) -> tuple[dict[str, Any], dict[str, Any]]:
    receipts = entry.get("receipts")
    if not isinstance(receipts, dict):
        raise ValueError(f"compare workload missing receipts: {entry.get('id')!r}")
    left = receipts.get("left")
    right = receipts.get("right")
    if not isinstance(left, dict) or not isinstance(right, dict):
        raise ValueError(f"compare workload receipts missing sides: {entry.get('id')!r}")
    left_path = left.get("path")
    right_path = right.get("path")
    if not isinstance(left_path, str) or not left_path.strip():
        raise ValueError(f"compare workload missing left receipt path: {entry.get('id')!r}")
    if not isinstance(right_path, str) or not right_path.strip():
        raise ValueError(f"compare workload missing right receipt path: {entry.get('id')!r}")
    return (
        load_run_receipt(compare_report_path, left_path, cache=cache),
        load_run_receipt(compare_report_path, right_path, cache=cache),
    )


def workload_claimability(
    claim_report: dict[str, Any] | None,
    workload_id: str,
) -> dict[str, Any]:
    row = claim_workloads_by_id(claim_report).get(workload_id)
    if not isinstance(row, dict):
        return {
            "evaluated": False,
            "claimable": None,
            "reasons": [],
        }
    required_positive = row.get("requiredPositivePercentiles")
    if not isinstance(required_positive, list):
        required_positive = []
    return {
        "evaluated": True,
        "claimable": row.get("claimable") is True,
        "reasons": [
            str(item)
            for item in row.get("reasons", [])
            if isinstance(item, str) and item
        ],
        "claimMetricField": str(row.get("claimMetricField", "")),
        "claimMetricScope": str(row.get("claimMetricScope", "")),
        "requiredPositivePercentiles": [
            str(item) for item in required_positive if isinstance(item, str) and item
        ],
    }


def _timing_normalization(
    left_receipt: dict[str, Any],
    right_receipt: dict[str, Any],
) -> dict[str, Any]:
    left = left_receipt.get("normalization")
    right = right_receipt.get("normalization")
    if not isinstance(left, dict):
        left = {}
    if not isinstance(right, dict):
        right = {}
    return {
        "baselineDivisor": left.get("timingDivisor"),
        "comparisonDivisor": right.get("timingDivisor"),
        "baselineCommandRepeat": left.get("commandRepeat"),
        "comparisonCommandRepeat": right.get("commandRepeat"),
        "baselineIgnoreFirstOps": left.get("ignoreFirstOps"),
        "comparisonIgnoreFirstOps": right.get("ignoreFirstOps"),
        "baselineUploadSubmitEvery": left.get("uploadSubmitEvery"),
        "comparisonUploadSubmitEvery": right.get("uploadSubmitEvery"),
    }


def _trace_meta_hashes_for_receipt(
    receipt: dict[str, Any],
    compare_report_path: Path,
) -> list[dict[str, str]]:
    rows: list[dict[str, str]] = []
    seen: set[str] = set()
    for sample in receipt.get("samples", []):
        if not isinstance(sample, dict):
            continue
        trace_artifacts = sample.get("traceArtifacts")
        if not isinstance(trace_artifacts, dict):
            continue
        raw_path = trace_artifacts.get("metaPath")
        if not isinstance(raw_path, str) or not raw_path.strip():
            continue
        resolved = resolve_artifact_path(compare_report_path, raw_path.strip())
        resolved_key = str(resolved)
        if resolved_key in seen:
            continue
        seen.add(resolved_key)
        rows.append(
            {
                "path": resolved_key,
                "sha256": file_sha256(resolved) if resolved.exists() else "",
            }
        )
    return rows


def extract_profile_ids_from_receipt(receipt: dict[str, Any]) -> set[str]:
    profile_ids: set[str] = set()
    for sample in receipt.get("samples", []):
        if not isinstance(sample, dict):
            continue
        if sample.get("returnCode") != 0:
            continue
        trace_meta = sample.get("traceMeta")
        if not isinstance(trace_meta, dict):
            continue
        profile = trace_meta.get("profile")
        if not isinstance(profile, dict):
            continue
        vendor = profile.get("vendor")
        api = profile.get("api")
        driver = profile.get("driver")
        if not isinstance(vendor, str) or not vendor.strip():
            continue
        if not isinstance(api, str) or not api.strip():
            continue
        if not isinstance(driver, str) or not driver.strip():
            continue
        family = profile.get("deviceFamily")
        family_value = family.strip() if isinstance(family, str) else ""
        profile_ids.add(
            "|".join([vendor.strip(), api.strip(), family_value, driver.strip()])
        )
    return profile_ids


def projected_workload(
    entry: dict[str, Any],
    compare_report_path: Path,
    *,
    claim_report: dict[str, Any] | None,
    cache: dict[str, dict[str, Any]] | None = None,
) -> dict[str, Any]:
    workload_id = str(entry.get("id", "")).strip()
    left_receipt, right_receipt = load_workload_receipts(
        entry,
        compare_report_path,
        cache=cache,
    )
    left_view = receipt_run_view(left_receipt)
    right_view = receipt_run_view(right_receipt)
    return {
        **entry,
        "baseline": {
            **left_view,
            "name": str(left_receipt.get("product", "")).strip(),
        },
        "comparison": {
            **right_view,
            "name": str(right_receipt.get("product", "")).strip(),
        },
        "claimability": workload_claimability(claim_report, workload_id),
        "timingNormalization": _timing_normalization(left_receipt, right_receipt),
        "traceMetaHashes": {
            "baseline": _trace_meta_hashes_for_receipt(left_receipt, compare_report_path),
            "comparison": _trace_meta_hashes_for_receipt(
                right_receipt,
                compare_report_path,
            ),
        },
        "workloadAllowBaselineNoExecution": bool(
            left_receipt.get("normalization", {}).get("allowNoExecution", False)
        ),
        "workloadAllowComparisonNoExecution": bool(
            right_receipt.get("normalization", {}).get("allowNoExecution", False)
        ),
    }


def projected_compare_report(
    compare_report: dict[str, Any],
    compare_report_path: Path,
    *,
    claim_report: dict[str, Any] | None,
    cache: dict[str, dict[str, Any]] | None = None,
) -> dict[str, Any]:
    participants = compare_report.get("participants")
    if not isinstance(participants, dict):
        participants = {}
    left = participants.get("left")
    right = participants.get("right")
    if not isinstance(left, dict):
        left = {}
    if not isinstance(right, dict):
        right = {}

    first_entry = None
    workloads = compare_report.get("workloads")
    if isinstance(workloads, list) and workloads:
        first_entry = workloads[0] if isinstance(workloads[0], dict) else None
    first_left_receipt = None
    first_right_receipt = None
    if isinstance(first_entry, dict):
        first_left_receipt, first_right_receipt = load_workload_receipts(
            first_entry,
            compare_report_path,
            cache=cache,
        )

    claim_policy = claim_report.get("claimPolicy") if isinstance(claim_report, dict) else {}
    if not isinstance(claim_policy, dict):
        claim_policy = {}
    workload_manifest = compare_report.get("workloadManifest")
    if not isinstance(workload_manifest, dict):
        workload_manifest = {}

    projected_workloads: list[dict[str, Any]] = []
    if isinstance(workloads, list):
        for entry in workloads:
            if not isinstance(entry, dict):
                continue
            projected_workloads.append(
                projected_workload(
                    entry,
                    compare_report_path,
                    claim_report=claim_report,
                    cache=cache,
                )
            )

    return {
        **compare_report,
        "baseline": {
            "name": str(left.get("product", "")).strip(),
        },
        "comparison": {
            "name": str(right.get("product", "")).strip(),
        },
        "workloadContract": {
            "path": str(workload_manifest.get("path", "")).strip(),
            "sha256": str(workload_manifest.get("sha256", "")).strip(),
        },
        "benchmarkPolicy": (
            claim_policy.get("benchmarkPolicy")
            if isinstance(claim_policy.get("benchmarkPolicy"), dict)
            else {"path": "", "sha256": ""}
        ),
        "claimabilityPolicy": {
            "mode": claim_mode(claim_report),
            "minTimedSamples": claim_min_timed_samples(claim_report),
            "requiredPositivePercentiles": required_positive_percentiles(
                claim_mode(claim_report)
            ),
        },
        "claimabilitySummary": {
            "workloadCount": len(projected_workloads),
            "nonClaimableCount": non_claimable_count(compare_report, claim_report),
        },
        "claimStatus": claim_status(compare_report, claim_report),
        "runParameters": {
            "iterations": (
                first_left_receipt.get("invocation", {}).get("iterations")
                if isinstance(first_left_receipt, dict)
                else None
            ),
            "warmup": (
                first_left_receipt.get("invocation", {}).get("warmup")
                if isinstance(first_left_receipt, dict)
                else None
            ),
        },
        "workloads": projected_workloads,
    }


def load_compare_bundle(
    compare_report_path: Path,
    *,
    explicit_claim_path: str = "",
    require_claim: bool = False,
) -> tuple[dict[str, Any], dict[str, Any] | None, Path | None]:
    compare_report = load_compare_report(compare_report_path)
    claim_report, claim_path = load_optional_claim_report(
        compare_report_path,
        explicit_path=explicit_claim_path,
        required=require_claim,
    )
    return compare_report, claim_report, claim_path
