#!/usr/bin/env python3
"""Shared conformance checks for compare and claim artifacts."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

from bench.lib import compare_claim_artifacts as artifacts_mod
from bench.lib.hash_utils import file_sha256, json_sha256


REPORT_SCHEMA_VERSION = 1
ACCEPTED_REPORT_SCHEMA_VERSIONS = {1}
SHA256_HEX_LENGTH = 64
SHA256_ZERO = "0" * SHA256_HEX_LENGTH
WORKLOAD_MANIFEST_ARCHIVE_REGISTRY = Path("config/workload-manifest-archives.json")


def parse_int(value: Any) -> int | None:
    if isinstance(value, bool):
        return None
    if isinstance(value, int):
        return value
    if isinstance(value, float) and value.is_integer():
        return int(value)
    return None


def load_json_object(path: Path) -> dict[str, Any]:
    payload = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(payload, dict):
        raise ValueError(f"invalid JSON object: {path}")
    return payload


def is_sha256_hex(value: Any) -> bool:
    return (
        isinstance(value, str)
        and len(value) == SHA256_HEX_LENGTH
        and all(ch in "0123456789abcdef" for ch in value)
    )


def load_obligation_contract(path: Path) -> tuple[int, set[str]]:
    payload = load_json_object(path)
    schema_version = parse_int(payload.get("schemaVersion"))
    if schema_version is None:
        raise ValueError(
            f"invalid comparability obligation contract: schemaVersion missing/invalid in {path}"
        )
    obligation_ids: set[str] = set()
    if schema_version == 1:
        raw_ids = payload.get("obligationIds")
        if not isinstance(raw_ids, list) or not raw_ids:
            raise ValueError(
                f"invalid comparability obligation contract: obligationIds missing/invalid in {path}"
            )
        for index, raw in enumerate(raw_ids):
            if not isinstance(raw, str) or not raw:
                raise ValueError(
                    "invalid comparability obligation contract: "
                    f"obligationIds[{index}] must be non-empty string in {path}"
                )
            obligation_ids.add(raw)
        return schema_version, obligation_ids

    if schema_version != 2:
        raise ValueError(
            "invalid comparability obligation contract: "
            f"unsupported schemaVersion {schema_version} in {path}"
        )

    raw_obligations = payload.get("obligations")
    if not isinstance(raw_obligations, list) or not raw_obligations:
        raise ValueError(
            f"invalid comparability obligation contract: obligations missing/invalid in {path}"
        )
    for index, raw in enumerate(raw_obligations):
        if not isinstance(raw, dict):
            raise ValueError(
                "invalid comparability obligation contract: "
                f"obligations[{index}] must be object in {path}"
            )
        obligation_id = raw.get("id")
        if not isinstance(obligation_id, str) or not obligation_id:
            raise ValueError(
                "invalid comparability obligation contract: "
                f"obligations[{index}].id must be non-empty string in {path}"
            )
        obligation_ids.add(obligation_id)
    return schema_version, obligation_ids


def resolve_contract_path(
    *,
    report_path: Path,
    repo_root: Path,
    raw_contract_path: str,
) -> Path:
    direct = Path(raw_contract_path)
    if direct.is_absolute():
        return direct

    repo_relative = (repo_root / direct).resolve()
    if repo_relative.exists():
        return repo_relative

    report_relative = (report_path.parent / direct).resolve()
    if report_relative.exists():
        return report_relative

    return repo_relative


def normalize_reported_manifest_path(raw_contract_path: str, repo_root: Path) -> str:
    path = Path(raw_contract_path)
    if path.is_absolute():
        try:
            return path.resolve().relative_to(repo_root.resolve()).as_posix()
        except ValueError:
            return path.as_posix()
    return path.as_posix()


def load_workload_manifest_archives(path: Path) -> dict[tuple[str, str], str]:
    payload = load_json_object(path)
    schema_version = parse_int(payload.get("schemaVersion"))
    if schema_version != 1:
        raise ValueError(
            f"invalid workload manifest archive registry: schemaVersion must be 1 in {path}"
        )
    raw_archives = payload.get("archives")
    if not isinstance(raw_archives, list):
        raise ValueError(
            f"invalid workload manifest archive registry: archives missing/invalid in {path}"
        )
    archives: dict[tuple[str, str], str] = {}
    for index, raw in enumerate(raw_archives):
        if not isinstance(raw, dict):
            raise ValueError(
                "invalid workload manifest archive registry: "
                f"archives[{index}] must be object in {path}"
            )
        original_path = raw.get("originalPath")
        archive_hash = raw.get("sha256")
        archive_path = raw.get("archivePath")
        if not isinstance(original_path, str) or not original_path.strip():
            raise ValueError(
                "invalid workload manifest archive registry: "
                f"archives[{index}].originalPath missing/invalid in {path}"
            )
        if not is_sha256_hex(archive_hash):
            raise ValueError(
                "invalid workload manifest archive registry: "
                f"archives[{index}].sha256 missing/invalid in {path}"
            )
        if not isinstance(archive_path, str) or not archive_path.strip():
            raise ValueError(
                "invalid workload manifest archive registry: "
                f"archives[{index}].archivePath missing/invalid in {path}"
            )
        key = (Path(original_path).as_posix(), archive_hash)
        if key in archives:
            raise ValueError(
                "invalid workload manifest archive registry: duplicate archive for "
                f"{original_path}@{archive_hash} in {path}"
            )
        archives[key] = archive_path
    return archives


def resolve_archived_contract_path(
    *,
    repo_root: Path,
    raw_contract_path: str,
    report_contract_hash: str,
) -> Path | None:
    registry_path = repo_root / WORKLOAD_MANIFEST_ARCHIVE_REGISTRY
    if not registry_path.exists():
        return None
    archives = load_workload_manifest_archives(registry_path)
    key = (
        normalize_reported_manifest_path(raw_contract_path, repo_root),
        report_contract_hash,
    )
    archive_path_raw = archives.get(key)
    if archive_path_raw is None:
        return None
    archive_path = Path(archive_path_raw)
    if archive_path.is_absolute():
        return archive_path
    return (repo_root / archive_path).resolve()


def resolve_contract_path_for_report_hash(
    *,
    report_path: Path,
    repo_root: Path,
    raw_contract_path: str,
    report_contract_hash: str,
) -> Path:
    resolved_contract_path = resolve_contract_path(
        report_path=report_path,
        repo_root=repo_root,
        raw_contract_path=raw_contract_path,
    )
    if (
        resolved_contract_path.exists()
        and file_sha256(resolved_contract_path) == report_contract_hash
    ):
        return resolved_contract_path
    archived_contract_path = resolve_archived_contract_path(
        repo_root=repo_root,
        raw_contract_path=raw_contract_path,
        report_contract_hash=report_contract_hash,
    )
    if archived_contract_path is not None:
        return archived_contract_path
    return resolved_contract_path


def load_contract_workloads_by_id(path: Path) -> dict[str, dict[str, Any]]:
    payload = load_json_object(path)
    raw_workloads = payload.get("workloads")
    if not isinstance(raw_workloads, list):
        raise ValueError(f"invalid workload contract: missing workloads[] in {path}")
    rows_by_id: dict[str, dict[str, Any]] = {}
    for row in raw_workloads:
        if not isinstance(row, dict):
            continue
        workload_id = row.get("id")
        if isinstance(workload_id, str) and workload_id:
            rows_by_id[workload_id] = row
    if not rows_by_id:
        raise ValueError(f"invalid workload contract: no workload IDs in {path}")
    return rows_by_id


def load_contract_workload_ids(path: Path) -> set[str]:
    return set(load_contract_workloads_by_id(path))


def validate_report_conformance(
    *,
    payload: dict[str, Any],
    report_path: Path,
    repo_root: Path,
    expected_obligation_schema_version: int,
    expected_obligation_ids: set[str],
) -> tuple[bool, str]:
    if payload.get("artifactKind") != "compare-report":
        return False, "artifactKind must be 'compare-report'"
    schema_version = parse_int(payload.get("schemaVersion"))
    if schema_version != REPORT_SCHEMA_VERSION:
        return (
            False,
            f"schemaVersion must be {REPORT_SCHEMA_VERSION} (found {payload.get('schemaVersion')!r})",
        )

    workloads = payload.get("workloads")
    if not isinstance(workloads, list) or not workloads:
        return False, "missing or empty workloads list"

    comparison_status = payload.get("comparisonStatus")
    if comparison_status not in {"comparable", "diagnostic"}:
        return False, "missing or invalid comparisonStatus"

    participants = payload.get("participants")
    if not isinstance(participants, dict):
        return False, "missing participants object"
    for side_name in ("left", "right"):
        side = participants.get(side_name)
        if not isinstance(side, dict):
            return False, f"participants.{side_name} missing/invalid"
        if not isinstance(side.get("product"), str) or not str(side.get("product")).strip():
            return False, f"participants.{side_name}.product missing/invalid"
        if not isinstance(side.get("executorId"), str) or not str(side.get("executorId")).strip():
            return False, f"participants.{side_name}.executorId missing/invalid"

    workload_manifest = payload.get("workloadManifest")
    if not isinstance(workload_manifest, dict):
        return False, "missing workloadManifest object"
    raw_contract_path = workload_manifest.get("path")
    if not isinstance(raw_contract_path, str) or not raw_contract_path.strip():
        return False, "workloadManifest.path missing or invalid"
    report_contract_hash = workload_manifest.get("sha256")
    if not isinstance(report_contract_hash, str) or not report_contract_hash.strip():
        return False, "workloadManifest.sha256 missing or invalid"

    try:
        resolved_contract_path = resolve_contract_path_for_report_hash(
            report_path=report_path,
            repo_root=repo_root,
            raw_contract_path=raw_contract_path,
            report_contract_hash=report_contract_hash,
        )
    except (OSError, UnicodeError, json.JSONDecodeError, ValueError) as exc:
        return False, str(exc)
    if not resolved_contract_path.exists():
        return False, f"workload manifest path does not exist: {resolved_contract_path}"
    expected_contract_hash = file_sha256(resolved_contract_path)
    if report_contract_hash != expected_contract_hash:
        return (
            False,
            "workloadManifest.sha256 mismatch "
            f"(report={report_contract_hash} expected={expected_contract_hash})",
        )

    try:
        contract_workload_rows = load_contract_workloads_by_id(resolved_contract_path)
    except (OSError, UnicodeError, json.JSONDecodeError, ValueError) as exc:
        return False, str(exc)
    contract_workload_ids = set(contract_workload_rows)

    comparability_summary = payload.get("comparabilitySummary")
    if not isinstance(comparability_summary, dict):
        return False, "missing comparabilitySummary object"
    workload_count = parse_int(comparability_summary.get("workloadCount"))
    non_comparable_count = parse_int(comparability_summary.get("nonComparableCount"))
    if workload_count != len(workloads):
        return False, "comparabilitySummary.workloadCount mismatch"
    if non_comparable_count is None:
        return False, "comparabilitySummary.nonComparableCount missing/invalid"

    seen_workload_ids: set[str] = set()
    observed_non_comparable = 0
    for workload_index, workload in enumerate(workloads):
        if not isinstance(workload, dict):
            return False, f"workloads[{workload_index}] must be an object"
        workload_id = workload.get("id")
        if not isinstance(workload_id, str) or not workload_id:
            return False, f"workloads[{workload_index}].id must be a non-empty string"
        if workload_id in seen_workload_ids:
            return False, f"duplicate workload id in report: {workload_id}"
        seen_workload_ids.add(workload_id)
        if workload_id not in contract_workload_ids:
            return False, f"workload id not present in workload contract: {workload_id}"
        contract_row = contract_workload_rows[workload_id]

        workload_path_asymmetry = workload.get("pathAsymmetry")
        if workload_path_asymmetry is not None and not isinstance(workload_path_asymmetry, bool):
            return False, f"{workload_id}: pathAsymmetry must be bool when present"
        workload_path_asymmetry_note = workload.get("pathAsymmetryNote")
        if workload_path_asymmetry_note is not None and not isinstance(
            workload_path_asymmetry_note, str
        ):
            return False, f"{workload_id}: pathAsymmetryNote must be string when present"
        contract_path_asymmetry = bool(contract_row.get("pathAsymmetry", False))
        if (
            isinstance(workload_path_asymmetry, bool)
            and workload_path_asymmetry != contract_path_asymmetry
        ):
            return False, (
                f"{workload_id}: pathAsymmetry does not match workload contract "
                f"({workload_path_asymmetry} vs {contract_path_asymmetry})"
            )
        contract_path_asymmetry_note = str(contract_row.get("pathAsymmetryNote", ""))
        if (
            isinstance(workload_path_asymmetry_note, str)
            and workload_path_asymmetry_note != contract_path_asymmetry_note
        ):
            return False, (
                f"{workload_id}: pathAsymmetryNote does not match workload contract"
            )

        workload_matching = workload.get("workloadMatching")
        if not isinstance(workload_matching, dict):
            return False, f"{workload_id}: missing workloadMatching object"
        if not isinstance(workload_matching.get("matched"), bool):
            return False, f"{workload_id}: workloadMatching.matched must be bool"
        matching_reasons = workload_matching.get("reasons")
        if not isinstance(matching_reasons, list) or any(
            not isinstance(item, str) for item in matching_reasons
        ):
            return False, f"{workload_id}: workloadMatching.reasons must be a string list"

        comparability = workload.get("comparability")
        if not isinstance(comparability, dict):
            return False, f"{workload_id}: missing comparability object"
        comparable = comparability.get("comparable")
        if not isinstance(comparable, bool):
            return False, f"{workload_id}: comparability.comparable must be bool"
        reasons = comparability.get("reasons")
        if not isinstance(reasons, list) or any(not isinstance(item, str) for item in reasons):
            return False, f"{workload_id}: comparability.reasons must be a string list"
        if not comparable:
            observed_non_comparable += 1

        obligation_schema_version = comparability.get("obligationSchemaVersion")
        if obligation_schema_version is not None:
            if parse_int(obligation_schema_version) != expected_obligation_schema_version:
                return (
                    False,
                    f"{workload_id}: comparability.obligationSchemaVersion mismatch",
                )
            obligations = comparability.get("obligations")
            if not isinstance(obligations, list) or not obligations:
                return False, f"{workload_id}: comparability.obligations must be a non-empty list"
            for obligation_index, obligation in enumerate(obligations):
                if not isinstance(obligation, dict):
                    return (
                        False,
                        f"{workload_id}: comparability.obligations[{obligation_index}] must be object",
                    )
                obligation_id = obligation.get("id")
                if not isinstance(obligation_id, str) or not obligation_id:
                    return (
                        False,
                        f"{workload_id}: comparability.obligations[{obligation_index}].id invalid",
                    )
                if obligation_id not in expected_obligation_ids:
                    return (
                        False,
                        f"{workload_id}: obligation id not in canonical contract: {obligation_id}",
                    )
                for field_name in ("blocking", "applicable", "passes"):
                    if not isinstance(obligation.get(field_name), bool):
                        return (
                            False,
                            f"{workload_id}: comparability.obligations[{obligation_index}].{field_name} must be bool",
                        )
            blocking_failed = comparability.get("blockingFailedObligations")
            if not isinstance(blocking_failed, list):
                return False, f"{workload_id}: comparability.blockingFailedObligations must be list"
            for failed_index, failed in enumerate(blocking_failed):
                if not isinstance(failed, str) or not failed:
                    return (
                        False,
                        f"{workload_id}: comparability.blockingFailedObligations[{failed_index}] invalid",
                    )
                if failed not in expected_obligation_ids:
                    return (
                        False,
                        f"{workload_id}: unknown blocking failed obligation id {failed}",
                    )
            if comparable and blocking_failed:
                return (
                    False,
                    f"{workload_id}: comparable workload must not include blockingFailedObligations",
                )

    if observed_non_comparable != non_comparable_count:
        return False, "comparabilitySummary.nonComparableCount mismatch"
    return True, ""


def validate_claim_report_conformance(
    *,
    compare_payload: dict[str, Any],
    compare_report_path: Path,
    claim_payload: dict[str, Any],
    claim_report_path: Path,
) -> tuple[bool, str]:
    if claim_payload.get("artifactKind") != "claim-report":
        return False, "artifactKind must be 'claim-report'"
    if parse_int(claim_payload.get("schemaVersion")) != 1:
        return False, "claim report schemaVersion must be 1"

    compare_ref = claim_payload.get("compareReport")
    if not isinstance(compare_ref, dict):
        return False, "claim report missing compareReport object"
    compare_sha = compare_ref.get("sha256")
    if not is_sha256_hex(compare_sha):
        return False, "claim report compareReport.sha256 missing/invalid"
    actual_compare_sha = file_sha256(compare_report_path)
    if compare_sha != actual_compare_sha:
        return False, "claim report compareReport.sha256 mismatch"

    comparison_status = claim_payload.get("comparisonStatus")
    if comparison_status != compare_payload.get("comparisonStatus"):
        return False, "claim report comparisonStatus mismatch with compare report"

    claim_status = claim_payload.get("claimStatus")
    if claim_status not in {"claimable", "diagnostic"}:
        return False, "claim report claimStatus missing/invalid"
    pass_flag = claim_payload.get("pass")
    if not isinstance(pass_flag, bool):
        return False, "claim report pass missing/invalid"
    if pass_flag != (claim_status == "claimable"):
        return False, "claim report pass does not match claimStatus"

    claim_policy = claim_payload.get("claimPolicy")
    if not isinstance(claim_policy, dict):
        return False, "claim report missing claimPolicy object"
    mode = claim_policy.get("mode")
    if mode not in {"local", "release"}:
        return False, "claim report claimPolicy.mode missing/invalid"
    min_timed_samples = parse_int(claim_policy.get("minTimedSamples"))
    if min_timed_samples is None or min_timed_samples < 0:
        return False, "claim report claimPolicy.minTimedSamples missing/invalid"
    policy_hash = claim_policy.get("policyHash")
    if not is_sha256_hex(policy_hash):
        return False, "claim report claimPolicy.policyHash missing/invalid"
    benchmark_policy = claim_policy.get("benchmarkPolicy")
    if not isinstance(benchmark_policy, dict):
        return False, "claim report claimPolicy.benchmarkPolicy missing/invalid"
    benchmark_policy_path = benchmark_policy.get("path")
    benchmark_policy_sha = benchmark_policy.get("sha256")
    if not isinstance(benchmark_policy_path, str):
        return False, "claim report claimPolicy.benchmarkPolicy.path missing/invalid"
    if not isinstance(benchmark_policy_sha, str):
        return False, "claim report claimPolicy.benchmarkPolicy.sha256 missing/invalid"
    if benchmark_policy_path.strip():
        resolved = artifacts_mod.resolve_artifact_path(
            claim_report_path,
            benchmark_policy_path.strip(),
        )
        if not resolved.exists():
            return False, f"claim benchmark policy path does not exist: {resolved}"
        actual_benchmark_sha = file_sha256(resolved)
        if benchmark_policy_sha != actual_benchmark_sha:
            return False, "claim report benchmark policy sha mismatch"

    compare_workloads = compare_payload.get("workloads")
    if not isinstance(compare_workloads, list) or not compare_workloads:
        return False, "compare report missing workloads for claim validation"
    compare_workload_ids = {
        workload.get("id")
        for workload in compare_workloads
        if isinstance(workload, dict) and isinstance(workload.get("id"), str)
    }

    claim_workloads = claim_payload.get("workloads")
    if not isinstance(claim_workloads, list) or not claim_workloads:
        return False, "claim report workloads missing/invalid"
    seen_ids: set[str] = set()
    observed_failures = 0
    for index, workload in enumerate(claim_workloads):
        if not isinstance(workload, dict):
            return False, f"claim report workloads[{index}] must be object"
        workload_id = workload.get("workloadId")
        if not isinstance(workload_id, str) or not workload_id:
            return False, f"claim report workloads[{index}].workloadId missing/invalid"
        if workload_id in seen_ids:
            return False, f"duplicate claim workloadId in claim report: {workload_id}"
        seen_ids.add(workload_id)
        if workload_id not in compare_workload_ids:
            return False, f"claim workloadId not present in compare report: {workload_id}"
        if not isinstance(workload.get("claimable"), bool):
            return False, f"{workload_id}: claimable must be bool"
        reasons = workload.get("reasons")
        if not isinstance(reasons, list) or any(not isinstance(item, str) for item in reasons):
            return False, f"{workload_id}: reasons must be a string list"
        if workload.get("claimable") is not True:
            observed_failures += 1
        for key in ("claimMetricField", "claimMetricScope"):
            value = workload.get(key)
            if not isinstance(value, str):
                return False, f"{workload_id}: {key} missing/invalid"
        required_positive = workload.get("requiredPositivePercentiles")
        if not isinstance(required_positive, list) or any(
            not isinstance(item, str) for item in required_positive
        ):
            return False, f"{workload_id}: requiredPositivePercentiles missing/invalid"

    if seen_ids != compare_workload_ids:
        missing = sorted(compare_workload_ids - seen_ids)
        extra = sorted(seen_ids - compare_workload_ids)
        return False, f"claim report workload set mismatch: missing={missing} extra={extra}"

    top_reasons = claim_payload.get("reasons")
    if not isinstance(top_reasons, list) or any(not isinstance(item, str) for item in top_reasons):
        return False, "claim report reasons missing/invalid"
    if claim_status == "claimable" and observed_failures != 0:
        return False, "claimable claim report cannot contain non-claimable workloads"
    if claim_status == "diagnostic" and observed_failures == 0:
        return False, "diagnostic claim report must contain at least one non-claimable workload"
    return True, ""
