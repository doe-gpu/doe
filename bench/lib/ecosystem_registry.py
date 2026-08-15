"""Semantic validation and rendering for the Doe ecosystem registry."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path
from typing import Any


ENGAGEMENT_STATUSES = (
    "discovered",
    "researched",
    "harness-ready",
    "measured",
    "outreach-ready",
    "integrated",
    "retired",
)
EVIDENCE_MATURITY = (
    "source-only",
    "diagnostic",
    "comparable",
    "claimable",
)
ADOPTION_STAGES = (
    "none",
    "validation-workload",
    "adopter",
    "design-partner",
    "supported-integration",
)
PROMOTION_STATES = (
    "not-promoted",
    "candidate",
    "promoted",
    "suspended",
    "retired",
)
ACTIVE_HARNESS_STATUSES = {"ready", "measured"}
PIN_REQUIRED_STATUSES = {
    "harness-ready",
    "measured",
    "outreach-ready",
    "integrated",
}
MEASUREMENT_REQUIRED_STATUSES = {
    "measured",
    "outreach-ready",
    "integrated",
}
REPORT_REQUIRED_MATURITY = {"diagnostic", "comparable", "claimable"}
OUTREACH_READY_STATUSES = {"outreach-ready", "integrated"}
OUTREACH_READY_OUTCOMES = {
    "reproducible-win",
    "receipt-explained-failure",
}
SHA256_PATTERN_LENGTH = 64
COMMIT_PATTERN_LENGTH = 40


def load_json_object(path: Path) -> dict[str, Any]:
    """Load a JSON object.

    Parameters
    ----------
    path:
        JSON file to load.

    Returns
    -------
    dict[str, Any]
        Parsed object.

    Raises
    ------
    ValueError
        If the JSON root is not an object.
    """
    payload = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(payload, dict):
        raise ValueError(f"expected JSON object: {path}")
    return payload


def sha256_file(path: Path) -> str:
    """Return the SHA-256 digest of a file."""
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def failure(code: str, path: str, message: str) -> dict[str, str]:
    """Build a stable semantic failure record."""
    return {"code": code, "path": path, "message": message}


def _band_for_score(policy: dict[str, Any], score: int) -> str:
    matches = [
        band.get("id")
        for band in policy.get("bands", [])
        if isinstance(band, dict)
        and isinstance(band.get("minimum"), int)
        and isinstance(band.get("maximum"), int)
        and band["minimum"] <= score <= band["maximum"]
    ]
    if len(matches) != 1 or not isinstance(matches[0], str):
        raise ValueError(f"score {score} maps to {len(matches)} scoring bands")
    return matches[0]


def derive_label(
    policy: dict[str, Any],
    doe_leverage: int,
    existing_capability_coverage: int,
) -> str:
    """Derive a relationship label from the two independent scores."""
    leverage_band = _band_for_score(policy, doe_leverage)
    coverage_band = _band_for_score(policy, existing_capability_coverage)
    matches = [
        entry.get("label")
        for entry in policy.get("derivedLabels", [])
        if isinstance(entry, dict)
        and entry.get("doeLeverageBand") == leverage_band
        and entry.get("existingCapabilityCoverageBand") == coverage_band
    ]
    if len(matches) != 1 or not isinstance(matches[0], str):
        raise ValueError(
            "score bands "
            f"{leverage_band}/{coverage_band} map to {len(matches)} labels"
        )
    return matches[0]


def _validate_policy(policy: dict[str, Any]) -> list[dict[str, str]]:
    failures: list[dict[str, str]] = []
    bands = policy.get("bands", [])
    band_ids: list[str] = []
    score_coverage: dict[int, list[str]] = {score: [] for score in range(6)}
    for index, band in enumerate(bands):
        if not isinstance(band, dict):
            continue
        band_id = band.get("id")
        minimum = band.get("minimum")
        maximum = band.get("maximum")
        if isinstance(band_id, str):
            if band_id in band_ids:
                failures.append(
                    failure(
                        "duplicate_score_band",
                        f"bands[{index}].id",
                        f"duplicate score band: {band_id}",
                    )
                )
            band_ids.append(band_id)
        if isinstance(minimum, int) and isinstance(maximum, int):
            if minimum > maximum:
                failures.append(
                    failure(
                        "invalid_score_band_range",
                        f"bands[{index}]",
                        f"minimum {minimum} exceeds maximum {maximum}",
                    )
                )
            for score in range(max(0, minimum), min(5, maximum) + 1):
                if isinstance(band_id, str):
                    score_coverage[score].append(band_id)

    for score, matches in score_coverage.items():
        if len(matches) != 1:
            failures.append(
                failure(
                    "invalid_score_band_coverage",
                    "bands",
                    f"score {score} must map to exactly one band, got {matches}",
                )
            )

    expected_pairs = {(left, right) for left in band_ids for right in band_ids}
    actual_pairs: dict[tuple[str, str], int] = {}
    labels: set[str] = set()
    for index, entry in enumerate(policy.get("derivedLabels", [])):
        if not isinstance(entry, dict):
            continue
        pair = (
            str(entry.get("doeLeverageBand", "")),
            str(entry.get("existingCapabilityCoverageBand", "")),
        )
        actual_pairs[pair] = actual_pairs.get(pair, 0) + 1
        label = entry.get("label")
        if isinstance(label, str):
            if label in labels:
                failures.append(
                    failure(
                        "duplicate_derived_label",
                        f"derivedLabels[{index}].label",
                        f"derived label is reused: {label}",
                    )
                )
            labels.add(label)

    for pair in sorted(expected_pairs):
        count = actual_pairs.get(pair, 0)
        if count != 1:
            failures.append(
                failure(
                    "invalid_derived_label_mapping",
                    "derivedLabels",
                    f"band pair {pair[0]}/{pair[1]} must map once, got {count}",
                )
            )
    for pair in sorted(set(actual_pairs) - expected_pairs):
        failures.append(
            failure(
                "unknown_score_band_in_label",
                "derivedLabels",
                f"derived label references unknown band pair {pair[0]}/{pair[1]}",
            )
        )

    if tuple(policy.get("engagementStatuses", [])) != ENGAGEMENT_STATUSES:
        failures.append(
            failure(
                "engagement_status_order_drift",
                "engagementStatuses",
                "engagement status order must match the governed progression",
            )
        )
    if tuple(policy.get("evidenceMaturity", [])) != EVIDENCE_MATURITY:
        failures.append(
            failure(
                "evidence_maturity_order_drift",
                "evidenceMaturity",
                "evidence maturity order must match the governed progression",
            )
        )

    axes = policy.get("scoreRange", {}).get("axes", {})
    for axis_name in ("doeLeverage", "existingCapabilityCoverage"):
        anchors = axes.get(axis_name, {}).get("anchors", [])
        scores = [
            anchor.get("score")
            for anchor in anchors
            if isinstance(anchor, dict)
        ]
        if sorted(scores) != list(range(6)):
            failures.append(
                failure(
                    "invalid_axis_anchors",
                    f"scoreRange.axes.{axis_name}.anchors",
                    f"axis anchors must contain scores 0 through 5 exactly once: {scores}",
                )
            )
    return failures


def _valid_commit(value: Any) -> bool:
    return (
        isinstance(value, str)
        and len(value) == COMMIT_PATTERN_LENGTH
        and all(character in "0123456789abcdef" for character in value)
    )


def _actor_report_failures(
    actor: dict[str, Any],
    actor_path: str,
    root: Path,
    claim_entries: dict[str, dict[str, Any]],
) -> list[dict[str, str]]:
    failures: list[dict[str, str]] = []
    actor_id = actor.get("id")
    reports = actor.get("reviewedReports", [])
    report_ids: set[str] = set()
    for index, report_ref in enumerate(reports):
        if not isinstance(report_ref, dict):
            continue
        report_path = f"{actor_path}.reviewedReports[{index}]"
        report_id = report_ref.get("reportId")
        if isinstance(report_id, str):
            if report_id in report_ids:
                failures.append(
                    failure(
                        "duplicate_reviewed_report_id",
                        f"{report_path}.reportId",
                        report_id,
                    )
                )
            report_ids.add(report_id)
        relative_path = report_ref.get("path")
        if not isinstance(relative_path, str):
            continue
        expected_prefix = f"reports/ecosystem/{actor_id}/"
        if not relative_path.startswith(expected_prefix):
            failures.append(
                failure(
                    "reviewed_report_wrong_actor_directory",
                    f"{report_path}.path",
                    f"expected path under {expected_prefix}",
                )
            )
            continue
        absolute_path = root / relative_path
        if not absolute_path.is_file():
            failures.append(
                failure(
                    "missing_reviewed_report",
                    f"{report_path}.path",
                    relative_path,
                )
            )
            continue
        expected_sha = report_ref.get("sha256")
        if isinstance(expected_sha, str) and len(expected_sha) == SHA256_PATTERN_LENGTH:
            actual_sha = sha256_file(absolute_path)
            if actual_sha != expected_sha:
                failures.append(
                    failure(
                        "reviewed_report_hash_mismatch",
                        f"{report_path}.sha256",
                        f"expected {expected_sha}, got {actual_sha}",
                    )
                )
        try:
            report = load_json_object(absolute_path)
        except (OSError, UnicodeError, json.JSONDecodeError, ValueError) as exc:
            failures.append(
                failure(
                    "invalid_reviewed_report",
                    f"{report_path}.path",
                    str(exc),
                )
            )
            continue
        if report.get("actorId") != actor_id:
            failures.append(
                failure(
                    "reviewed_report_actor_mismatch",
                    f"{report_path}.path",
                    f"report actorId is {report.get('actorId')!r}",
                )
            )
        if report.get("reportId") != report_id:
            failures.append(
                failure(
                    "reviewed_report_id_mismatch",
                    f"{report_path}.path",
                    f"reportId expected {report_id!r}, got {report.get('reportId')!r}",
                )
            )
        if report.get("review", {}).get("status") != "reviewed":
            failures.append(
                failure(
                    "report_not_reviewed",
                    f"{report_path}.path",
                    "referenced report must carry review.status=reviewed",
                )
            )
        upstream = report.get("upstream", {})
        actor_source = actor.get("source", {})
        if upstream.get("commit") != actor_source.get("upstreamCommit"):
            failures.append(
                failure(
                    "reviewed_report_upstream_mismatch",
                    f"{report_path}.path",
                    "report commit does not match the actor's pinned commit",
                )
            )
        if upstream.get("licenseIdentifier") != actor_source.get(
            "license", {}
        ).get("identifier"):
            failures.append(
                failure(
                    "reviewed_report_license_mismatch",
                    f"{report_path}.path",
                    "report license does not match the actor registry",
                )
            )
        report_maturity = report.get("evidenceMaturity")
        promotion_assessment = report.get("promotionAssessment", {})
        promotion_gates = (
            "installation",
            "supportHardware",
            "concurrency",
            "teardown",
            "stress",
            "memory",
            "receipts",
            "replay",
            "performance",
            "ownership",
            "release",
        )
        if promotion_assessment.get("eligibility") == "eligible":
            nonpassing_promotion_gates = [
                gate_name
                for gate_name in promotion_gates
                if promotion_assessment.get(gate_name, {}).get("status") != "pass"
            ]
            if report_maturity != "claimable" or nonpassing_promotion_gates:
                failures.append(
                    failure(
                        "invalid_promotion_eligibility",
                        f"{report_path}.path",
                        "eligible reports require claimable maturity and passing "
                        "promotion gates; non-passing gates: "
                        + ", ".join(nonpassing_promotion_gates),
                    )
                )
        equivalence = report.get("equivalence", {})
        if report_maturity in {"comparable", "claimable"}:
            equivalence_fields = (
                "status",
                "oracleStatus",
                "providerIdentityStatus",
                "hiddenFallbackStatus",
                "dispatchShapeStatus",
                "synchronizationStatus",
                "readbackStatus",
                "outputIdentityStatus",
            )
            failed_fields = [
                field_name
                for field_name in equivalence_fields
                if equivalence.get(field_name) != "pass"
            ]
            if failed_fields:
                failures.append(
                    failure(
                        "comparable_report_failed_equivalence",
                        f"{report_path}.path",
                        "non-passing equivalence fields: "
                        + ", ".join(failed_fields),
                    )
                )
        for side_name in ("baseline", "comparison"):
            reliability = report.get("reliability", {}).get(side_name, {})
            run_count = reliability.get("cleanProcessRuns")
            outcome_count = sum(
                value
                for value in (
                    reliability.get("successes"),
                    reliability.get("failures"),
                    reliability.get("crashes"),
                    reliability.get("hangs"),
                    reliability.get("timeouts"),
                )
                if isinstance(value, int)
            )
            if isinstance(run_count, int) and outcome_count != run_count:
                failures.append(
                    failure(
                        "reliability_outcome_count_mismatch",
                        f"{report_path}.path",
                        f"{side_name} outcomes {outcome_count} do not equal "
                        f"clean-process runs {run_count}",
                    )
                )
            performance = report.get("performance", {}).get(side_name, {})
            for thermal_state in ("cold", "warm"):
                percentiles = performance.get(thermal_state, {})
                values = [
                    percentiles.get("p50"),
                    percentiles.get("p95"),
                    percentiles.get("p99"),
                ]
                if all(isinstance(value, (int, float)) for value in values):
                    if values != sorted(values):
                        failures.append(
                            failure(
                                "nonmonotonic_performance_percentiles",
                                f"{report_path}.path",
                                f"{side_name} {thermal_state} percentiles "
                                f"are not monotonic: {values}",
                            )
                        )

    claims = actor.get("claimIndexRefs", [])
    if claims and not reports:
        failures.append(
            failure(
                "claim_without_reviewed_report",
                f"{actor_path}.claimIndexRefs",
                "claim references require at least one reviewed report",
            )
        )
    for index, claim_ref in enumerate(claims):
        if not isinstance(claim_ref, dict):
            continue
        claim_path = f"{actor_path}.claimIndexRefs[{index}]"
        report_id = claim_ref.get("reviewedReportId")
        if report_id not in report_ids:
            failures.append(
                failure(
                    "claim_reviewed_report_missing",
                    f"{claim_path}.reviewedReportId",
                    f"unknown reviewed report: {report_id}",
                )
            )
        entry_id = claim_ref.get("entryId")
        if entry_id not in claim_entries:
            failures.append(
                failure(
                    "claim_index_entry_missing",
                    f"{claim_path}.entryId",
                    f"unknown claim-index entry: {entry_id}",
                )
            )
    return failures


def _actor_harness_failures(
    actor: dict[str, Any],
    actor_path: str,
    root: Path,
) -> list[dict[str, str]]:
    failures: list[dict[str, str]] = []
    actor_id = actor.get("id")
    source = actor.get("source", {})
    harnesses = actor.get("harnesses", [])
    harness_ids: set[str] = set()
    active_count = 0
    measured_count = 0
    for index, harness in enumerate(harnesses):
        if not isinstance(harness, dict):
            continue
        harness_path = f"{actor_path}.harnesses[{index}]"
        harness_id = harness.get("id")
        if isinstance(harness_id, str):
            if harness_id in harness_ids:
                failures.append(
                    failure(
                        "duplicate_harness_id",
                        f"{harness_path}.id",
                        harness_id,
                    )
                )
            harness_ids.add(harness_id)

        oracle = harness.get("oracle")
        if not isinstance(oracle, dict):
            failures.append(
                failure(
                    "harness_missing_oracle",
                    f"{harness_path}.oracle",
                    "every harness requires an explicit oracle",
                )
            )
            continue

        status = harness.get("status")
        if status in ACTIVE_HARNESS_STATUSES:
            active_count += 1
            if status == "measured":
                measured_count += 1
            if oracle.get("status") != "reviewed":
                failures.append(
                    failure(
                        "active_harness_oracle_not_reviewed",
                        f"{harness_path}.oracle.status",
                        "ready and measured harnesses require a reviewed oracle",
                    )
                )
            manifest_rel = harness.get("manifestPath")
            if not isinstance(manifest_rel, str):
                failures.append(
                    failure(
                        "active_harness_missing_manifest",
                        f"{harness_path}.manifestPath",
                        "ready and measured harnesses require a manifest path",
                    )
                )
                continue
            expected_prefix = f"bench/external-projects/{actor_id}/"
            if not manifest_rel.startswith(expected_prefix):
                failures.append(
                    failure(
                        "harness_manifest_wrong_actor_directory",
                        f"{harness_path}.manifestPath",
                        f"expected path under {expected_prefix}",
                    )
                )
                continue
            manifest_path = root / manifest_rel
            if not manifest_path.is_file():
                failures.append(
                    failure(
                        "missing_harness_manifest",
                        f"{harness_path}.manifestPath",
                        manifest_rel,
                    )
                )
                continue
            try:
                manifest = load_json_object(manifest_path)
            except (OSError, UnicodeError, json.JSONDecodeError, ValueError) as exc:
                failures.append(
                    failure(
                        "invalid_harness_manifest",
                        f"{harness_path}.manifestPath",
                        str(exc),
                    )
                )
                continue
            expected_fields = {
                "actorId": actor_id,
                "harnessId": harness_id,
            }
            for field_name, expected in expected_fields.items():
                if manifest.get(field_name) != expected:
                    failures.append(
                        failure(
                            "harness_manifest_identity_mismatch",
                            f"{harness_path}.manifestPath",
                            f"{field_name} expected {expected!r}, got "
                            f"{manifest.get(field_name)!r}",
                        )
                    )
            upstream = manifest.get("upstream", {})
            if upstream.get("commit") != source.get("upstreamCommit"):
                failures.append(
                    failure(
                        "harness_upstream_commit_mismatch",
                        f"{harness_path}.manifestPath",
                        "manifest commit does not match the actor's pinned commit",
                    )
                )
            if upstream.get("license", {}).get("identifier") != source.get(
                "license", {}
            ).get("identifier"):
                failures.append(
                    failure(
                        "harness_license_mismatch",
                        f"{harness_path}.manifestPath",
                        "manifest license does not match the actor registry",
                    )
                )

    engagement_status = actor.get("engagementStatus")
    if engagement_status in PIN_REQUIRED_STATUSES:
        if not _valid_commit(source.get("upstreamCommit")):
            failures.append(
                failure(
                    "unpinned_active_actor",
                    f"{actor_path}.source.upstreamCommit",
                    "harness-ready or later actors require a pinned upstream commit",
                )
            )
        if active_count == 0:
            failures.append(
                failure(
                    "engagement_without_ready_harness",
                    f"{actor_path}.engagementStatus",
                    f"{engagement_status} requires a ready or measured harness",
                )
            )
    if engagement_status in MEASUREMENT_REQUIRED_STATUSES and measured_count == 0:
        failures.append(
            failure(
                "measured_engagement_without_measured_harness",
                f"{actor_path}.engagementStatus",
                f"{engagement_status} requires a measured harness",
            )
        )
    return failures


def _actor_promotion_failures(
    actor: dict[str, Any],
    actor_path: str,
    root: Path,
    promotion_policy: dict[str, Any],
) -> list[dict[str, str]]:
    """Validate adoption and release promotion without inferring relationships."""
    failures: list[dict[str, str]] = []
    adoption_stage = actor.get("adoptionStage")
    promotion_status = actor.get("promotionStatus")
    reports: list[dict[str, Any]] = []
    for report_ref in actor.get("reviewedReports", []):
        if not isinstance(report_ref, dict):
            continue
        relative_path = report_ref.get("path")
        if not isinstance(relative_path, str):
            continue
        try:
            reports.append(load_json_object(root / relative_path))
        except (OSError, UnicodeError, json.JSONDecodeError, ValueError):
            continue

    manifests: list[dict[str, Any]] = []
    for harness in actor.get("harnesses", []):
        if not isinstance(harness, dict):
            continue
        relative_path = harness.get("manifestPath")
        if not isinstance(relative_path, str):
            continue
        try:
            manifests.append(load_json_object(root / relative_path))
        except (OSError, UnicodeError, json.JSONDecodeError, ValueError):
            continue

    if adoption_stage == "validation-workload":
        has_diagnostic_report = any(
            report.get("evidenceMaturity") in {"diagnostic", "comparable", "claimable"}
            for report in reports
        )
        has_measured_harness = any(
            harness.get("status") == "measured"
            for harness in actor.get("harnesses", [])
            if isinstance(harness, dict)
        )
        if not has_diagnostic_report or not has_measured_harness:
            failures.append(
                failure(
                    "validation_workload_without_measurement",
                    f"{actor_path}.adoptionStage",
                    "validation-workload requires a measured harness and reviewed diagnostic report",
                )
            )
    if adoption_stage in {"adopter", "design-partner", "supported-integration"}:
        has_validated_install = any(
            manifest.get("installation", {}).get("productionStatus") == "validated"
            for manifest in manifests
        )
        if actor.get("engagementStatus") != "integrated" or not has_validated_install:
            failures.append(
                failure(
                    "adoption_without_validated_integration",
                    f"{actor_path}.adoptionStage",
                    "adopter or later requires integrated engagement and validated production substitution",
                )
            )

    promoted_manifests = [
        manifest
        for manifest in manifests
        if manifest.get("releasePolicy", {}).get("promotionState") == "promoted"
    ]
    if promotion_status == "promoted":
        eligible_reports = [
            report
            for report in reports
            if report.get("evidenceMaturity") == "claimable"
            and report.get("promotionAssessment", {}).get("eligibility") == "eligible"
        ]
        if adoption_stage not in {"adopter", "design-partner", "supported-integration"}:
            failures.append(
                failure(
                    "promotion_without_adoption",
                    f"{actor_path}.promotionStatus",
                    "promoted actors must be adopters or a later adoption stage",
                )
            )
        if not promoted_manifests or not eligible_reports:
            failures.append(
                failure(
                    "promotion_without_eligible_artifacts",
                    f"{actor_path}.promotionStatus",
                    "promotion requires a promoted harness manifest and eligible claimable report",
                )
            )
        for manifest in promoted_manifests:
            release_policy = manifest.get("releasePolicy", {})
            if not release_policy.get("blocking"):
                failures.append(
                    failure(
                        "promoted_harness_not_blocking",
                        f"{actor_path}.harnesses",
                        "promoted harnesses must block releases",
                    )
                )
            if not manifest.get("supportTargets") or not any(
                target.get("status") == "promoted"
                for target in manifest.get("supportTargets", [])
                if isinstance(target, dict)
            ):
                failures.append(
                    failure(
                        "promoted_harness_without_support_target",
                        f"{actor_path}.harnesses",
                        "promoted harnesses require at least one promoted physical support target",
                    )
                )
    elif promoted_manifests:
        failures.append(
            failure(
                "manifest_actor_promotion_mismatch",
                f"{actor_path}.promotionStatus",
                "a promoted harness requires actor promotionStatus=promoted",
            )
        )

    expected_policy_version = promotion_policy.get("policyVersion")
    for report in reports:
        report_policy = report.get("promotionAssessment", {}).get("policyVersion")
        if report_policy != expected_policy_version:
            failures.append(
                failure(
                    "report_promotion_policy_mismatch",
                    f"{actor_path}.reviewedReports",
                    f"expected promotion policy {expected_policy_version!r}, got {report_policy!r}",
                )
            )
    return failures


def _actor_failure_record_failures(
    actor: dict[str, Any], actor_path: str, root: Path
) -> list[dict[str, str]]:
    failures: list[dict[str, str]] = []
    actor_id = actor.get("id")
    source_commit = actor.get("source", {}).get("upstreamCommit")
    harness_ids = {
        harness.get("id")
        for harness in actor.get("harnesses", [])
        if isinstance(harness, dict)
    }
    record_ids: set[str] = set()
    for index, relative_path in enumerate(actor.get("failureRecords", [])):
        record_path = f"{actor_path}.failureRecords[{index}]"
        if not isinstance(relative_path, str):
            continue
        expected_prefix = f"bench/external-projects/{actor_id}/failures/"
        if not relative_path.startswith(expected_prefix):
            failures.append(
                failure(
                    "failure_record_wrong_actor_directory",
                    record_path,
                    f"expected path under {expected_prefix}",
                )
            )
            continue
        try:
            record = load_json_object(root / relative_path)
        except (OSError, UnicodeError, json.JSONDecodeError, ValueError) as exc:
            failures.append(failure("invalid_failure_record", record_path, str(exc)))
            continue
        record_id = record.get("failureId")
        if isinstance(record_id, str):
            if record_id in record_ids:
                failures.append(
                    failure("duplicate_failure_record", record_path, record_id)
                )
            record_ids.add(record_id)
        if record.get("actorId") != actor_id:
            failures.append(
                failure("failure_record_actor_mismatch", record_path, str(record_id))
            )
        if record.get("harnessId") not in harness_ids:
            failures.append(
                failure(
                    "failure_record_harness_mismatch",
                    record_path,
                    f"unknown harness: {record.get('harnessId')}",
                )
            )
        if record.get("upstreamCommit") != source_commit:
            failures.append(
                failure("failure_record_upstream_mismatch", record_path, str(record_id))
            )
        for field_name in (
            "minimizedReproPaths",
            "implementationPaths",
            "regressionTestPaths",
        ):
            for source_path in record.get(field_name, []):
                if isinstance(source_path, str) and not (root / source_path).is_file():
                    failures.append(
                        failure(
                            "failure_record_source_missing",
                            record_path,
                            f"missing {field_name} path: {source_path}",
                        )
                    )
    return failures


def evaluate_registry(
    registry: dict[str, Any],
    policy: dict[str, Any],
    root: Path,
    claim_index: dict[str, Any] | None = None,
    promotion_policy: dict[str, Any] | None = None,
) -> dict[str, Any]:
    """Evaluate registry invariants that JSON Schema cannot express."""
    failures = _validate_policy(policy)
    claim_payload = claim_index or {"entries": []}
    claim_entries = {
        entry.get("id"): entry
        for entry in claim_payload.get("entries", [])
        if isinstance(entry, dict) and isinstance(entry.get("id"), str)
    }

    policy_version = policy.get("policyVersion")
    if registry.get("scoringPolicyVersion") != policy_version:
        failures.append(
            failure(
                "registry_scoring_policy_mismatch",
                "scoringPolicyVersion",
                f"expected {policy_version!r}",
            )
        )

    active_promotion_policy = promotion_policy or {
        "policyVersion": registry.get("promotionPolicyVersion")
    }
    if registry.get("promotionPolicyVersion") != active_promotion_policy.get(
        "policyVersion"
    ):
        failures.append(
            failure(
                "registry_promotion_policy_mismatch",
                "promotionPolicyVersion",
                f"expected {active_promotion_policy.get('policyVersion')!r}",
            )
        )

    actors = registry.get("actors", [])
    actor_map = {
        actor.get("id"): actor
        for actor in actors
        if isinstance(actor, dict) and isinstance(actor.get("id"), str)
    }
    queue = registry.get("evaluationQueue", [])
    queue_positions: list[int] = []
    queued_actor_ids: set[str] = set()
    for index, queue_entry in enumerate(queue):
        if not isinstance(queue_entry, dict):
            continue
        queue_path = f"evaluationQueue[{index}]"
        position = queue_entry.get("position")
        if isinstance(position, int):
            queue_positions.append(position)
        actor_id = queue_entry.get("actorId")
        if actor_id in queued_actor_ids:
            failures.append(
                failure(
                    "duplicate_evaluation_queue_actor",
                    f"{queue_path}.actorId",
                    str(actor_id),
                )
            )
        if isinstance(actor_id, str):
            queued_actor_ids.add(actor_id)
        actor = actor_map.get(actor_id)
        if actor is None:
            failures.append(
                failure(
                    "unknown_evaluation_queue_actor",
                    f"{queue_path}.actorId",
                    str(actor_id),
                )
            )
            continue
        harness_ids = {
            harness.get("id")
            for harness in actor.get("harnesses", [])
            if isinstance(harness, dict)
        }
        for harness_id in queue_entry.get("plannedHarnessIds", []):
            if harness_id not in harness_ids:
                failures.append(
                    failure(
                        "unknown_evaluation_queue_harness",
                        f"{queue_path}.plannedHarnessIds",
                        f"unknown harness for {actor_id}: {harness_id}",
                    )
                )
    expected_positions = list(range(1, len(queue_positions) + 1))
    if sorted(queue_positions) != expected_positions:
        failures.append(
            failure(
                "invalid_evaluation_queue_positions",
                "evaluationQueue",
                f"positions must be contiguous from 1: {queue_positions}",
            )
        )

    actor_ids: set[str] = set()
    for index, actor in enumerate(actors):
        if not isinstance(actor, dict):
            continue
        actor_path = f"actors[{index}]"
        actor_id = actor.get("id")
        if isinstance(actor_id, str):
            if actor_id in actor_ids:
                failures.append(
                    failure(
                        "duplicate_actor_id",
                        f"{actor_path}.id",
                        actor_id,
                    )
                )
            actor_ids.add(actor_id)

        observations = actor.get("observations", [])
        observation_ids: set[str] = set()
        for observation_index, observation in enumerate(observations):
            if not isinstance(observation, dict):
                continue
            observation_id = observation.get("id")
            if isinstance(observation_id, str):
                if observation_id in observation_ids:
                    failures.append(
                        failure(
                            "duplicate_observation_id",
                            f"{actor_path}.observations[{observation_index}].id",
                            observation_id,
                        )
                    )
                observation_ids.add(observation_id)

        score_revisions = actor.get("scoreHistory", [])
        revision_ids: set[str] = set()
        for revision_index, revision in enumerate(score_revisions):
            if not isinstance(revision, dict):
                continue
            revision_path = f"{actor_path}.scoreHistory[{revision_index}]"
            revision_id = revision.get("revisionId")
            if isinstance(revision_id, str):
                if revision_id in revision_ids:
                    failures.append(
                        failure(
                            "duplicate_score_revision_id",
                            f"{revision_path}.revisionId",
                            revision_id,
                        )
                    )
                revision_ids.add(revision_id)
            if revision.get("scoringPolicyVersion") != policy_version:
                failures.append(
                    failure(
                        "score_revision_policy_mismatch",
                        f"{revision_path}.scoringPolicyVersion",
                        f"expected {policy_version!r}",
                    )
                )
            references: list[Any] = list(
                revision.get("changedByObservationRefs", [])
            )
            for axis_name in ("doeLeverage", "existingCapabilityCoverage"):
                axis = revision.get(axis_name, {})
                for reason in axis.get("reasons", []):
                    if isinstance(reason, dict):
                        references.extend(reason.get("observationRefs", []))
            for reference in references:
                if reference not in observation_ids:
                    failures.append(
                        failure(
                            "unknown_score_observation",
                            revision_path,
                            f"score references unknown observation: {reference}",
                        )
                    )

        for harness_index, harness in enumerate(actor.get("harnesses", [])):
            if not isinstance(harness, dict):
                continue
            oracle = harness.get("oracle", {})
            for reference in oracle.get("observationRefs", []):
                if reference not in observation_ids:
                    failures.append(
                        failure(
                            "unknown_harness_observation",
                            f"{actor_path}.harnesses[{harness_index}].oracle",
                            f"oracle references unknown observation: {reference}",
                        )
                    )

        if score_revisions:
            latest = score_revisions[-1]
            if isinstance(latest, dict):
                latest_revision = latest.get("registryRevision")
                registry_revision = registry.get("registryRevision")
                score_from_future = False
                if isinstance(latest_revision, str) and isinstance(
                    registry_revision, str
                ):
                    try:
                        score_from_future = int(latest_revision) > int(
                            registry_revision
                        )
                    except ValueError:
                        pass
                if score_from_future:
                    failures.append(
                        failure(
                            "score_revision_from_future_registry",
                            f"{actor_path}.scoreHistory[-1].registryRevision",
                            "latest score cannot name a future registry revision",
                        )
                    )
                try:
                    derive_label(
                        policy,
                        latest.get("doeLeverage", {}).get("score"),
                        latest.get("existingCapabilityCoverage", {}).get("score"),
                    )
                except (TypeError, ValueError) as exc:
                    failures.append(
                        failure(
                            "score_label_derivation_failed",
                            f"{actor_path}.scoreHistory[-1]",
                            str(exc),
                        )
                    )
                if latest.get("reviewStatus") == "reviewed":
                    has_measured_harness = any(
                        isinstance(harness, dict)
                        and harness.get("status") == "measured"
                        for harness in actor.get("harnesses", [])
                    )
                    if not has_measured_harness or not actor.get("reviewedReports"):
                        failures.append(
                            failure(
                                "final_score_without_harness_review",
                                f"{actor_path}.scoreHistory[-1].reviewStatus",
                                "reviewed scores require a measured harness and reviewed report",
                            )
                        )
                    if actor.get("lastReviewedAt") is None:
                        failures.append(
                            failure(
                                "reviewed_score_missing_review_time",
                                f"{actor_path}.lastReviewedAt",
                                "reviewed scores require lastReviewedAt",
                            )
                        )

        failures.extend(_actor_harness_failures(actor, actor_path, root))
        failures.extend(
            _actor_report_failures(actor, actor_path, root, claim_entries)
        )
        failures.extend(
            _actor_promotion_failures(
                actor,
                actor_path,
                root,
                active_promotion_policy,
            )
        )
        failures.extend(
            _actor_failure_record_failures(actor, actor_path, root)
        )
        reports = actor.get("reviewedReports", [])
        maturity = actor.get("evidenceMaturity")
        if maturity in REPORT_REQUIRED_MATURITY and not reports:
            failures.append(
                failure(
                    "evidence_maturity_without_report",
                    f"{actor_path}.evidenceMaturity",
                    f"{maturity} requires a reviewed report",
                )
            )
        if maturity == "claimable" and not actor.get("claimIndexRefs"):
            failures.append(
                failure(
                    "claimable_without_claim_index",
                    f"{actor_path}.evidenceMaturity",
                    "claimable evidence requires a claim-index reference",
                )
            )
        if actor.get("engagementStatus") in OUTREACH_READY_STATUSES:
            if maturity not in {"comparable", "claimable"}:
                failures.append(
                    failure(
                        "outreach_without_comparable_evidence",
                        f"{actor_path}.engagementStatus",
                        "outreach readiness requires comparable or claimable evidence",
                    )
                )
            report_outcomes: set[str] = set()
            for report_ref in reports:
                if not isinstance(report_ref, dict):
                    continue
                relative_path = report_ref.get("path")
                if not isinstance(relative_path, str):
                    continue
                try:
                    report = load_json_object(root / relative_path)
                except (OSError, UnicodeError, json.JSONDecodeError, ValueError):
                    continue
                outcome = report.get("outcome")
                if isinstance(outcome, str):
                    report_outcomes.add(outcome)
            if not report_outcomes.intersection(OUTREACH_READY_OUTCOMES):
                failures.append(
                    failure(
                        "outreach_without_actionable_outcome",
                        f"{actor_path}.engagementStatus",
                        "outreach readiness requires a reproducible win or "
                        "receipt-explained failure",
                    )
                )

    return {
        "schemaVersion": 1,
        "artifactKind": "ecosystem-registry-check",
        "ok": not failures,
        "failures": failures,
        "summary": {
            "actorCount": len(actors) if isinstance(actors, list) else 0,
            "failureCount": len(failures),
        },
    }


def registry_rows(
    registry: dict[str, Any], policy: dict[str, Any]
) -> list[dict[str, Any]]:
    """Build current, derived actor rows for renderers."""
    rows: list[dict[str, Any]] = []
    for actor in registry.get("actors", []):
        if not isinstance(actor, dict):
            continue
        history = actor.get("scoreHistory", [])
        if not history or not isinstance(history[-1], dict):
            continue
        latest = history[-1]
        leverage = latest.get("doeLeverage", {}).get("score")
        coverage = latest.get("existingCapabilityCoverage", {}).get("score")
        rows.append(
            {
                "id": actor.get("id"),
                "name": actor.get("name"),
                "type": actor.get("type"),
                "doeLeverage": leverage,
                "existingCapabilityCoverage": coverage,
                "derivedLabel": derive_label(policy, leverage, coverage),
                "engagementStatus": actor.get("engagementStatus"),
                "evidenceMaturity": actor.get("evidenceMaturity"),
                "adoptionStage": actor.get("adoptionStage"),
                "promotionStatus": actor.get("promotionStatus"),
                "scoreReviewStatus": latest.get("reviewStatus"),
                "lastReviewedAt": actor.get("lastReviewedAt"),
            }
        )
    return sorted(
        rows,
        key=lambda row: (
            -int(row["doeLeverage"]),
            -int(row["existingCapabilityCoverage"]),
            str(row["name"]).lower(),
        ),
    )


def render_markdown(registry: dict[str, Any], policy: dict[str, Any]) -> str:
    """Render a current Markdown view without becoming a second registry."""
    lines = [
        "# Doe ecosystem registry summary",
        "",
        (
            "Generated from `config/ecosystem-registry.json` with scoring policy "
            f"`{policy.get('policyVersion')}`."
        ),
        "",
        "| Actor | Type | DL | ECC | Derived relationship | Engagement | "
        "Evidence | Adoption | Promotion | Score review |",
        "| --- | --- | ---: | ---: | --- | --- | --- | --- | --- | --- |",
    ]
    for row in registry_rows(registry, policy):
        lines.append(
            "| {name} | {type} | {doeLeverage} | "
            "{existingCapabilityCoverage} | {derivedLabel} | "
            "{engagementStatus} | {evidenceMaturity} | "
            "{adoptionStage} | {promotionStatus} | {scoreReviewStatus} |".format(**row)
        )
    lines.append("")
    return "\n".join(lines)
