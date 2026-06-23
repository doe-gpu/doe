"""Comparability checks used by the release claim gate."""

from __future__ import annotations

from typing import Any


def _parse_int(value: Any) -> int | None:
    if isinstance(value, bool):
        return None
    if isinstance(value, int):
        return value
    return None


def workload_comparability_failures(
    *,
    workload_id: str,
    workload: dict[str, Any],
    require_comparison_status: str,
    expected_obligation_ids: set[str],
    expected_obligation_schema_version: int,
    required_obligation_ids: set[str] | None = None,
) -> tuple[list[str], bool]:
    failures: list[str] = []
    workload_comparability = workload.get("comparability")
    if not isinstance(workload_comparability, dict):
        return [f"{workload_id}: missing comparability object"], False

    comparable_flag = workload_comparability.get("comparable")
    if require_comparison_status == "comparable" and comparable_flag is not True:
        failures.append(f"{workload_id}: comparability.comparable must be true")

    obligation_schema_version = _parse_int(
        workload_comparability.get("obligationSchemaVersion")
    )
    if obligation_schema_version != expected_obligation_schema_version:
        failures.append(
            f"{workload_id}: comparability.obligationSchemaVersion must be "
            f"{expected_obligation_schema_version}"
        )

    obligations = workload_comparability.get("obligations")
    observed_obligation_ids: set[str] = set()
    if not isinstance(obligations, list) or not obligations:
        failures.append(
            f"{workload_id}: comparability.obligations must be a non-empty list"
        )
    else:
        for obligation_idx, obligation in enumerate(obligations):
            if not isinstance(obligation, dict):
                failures.append(
                    f"{workload_id}: comparability.obligations[{obligation_idx}] "
                    "must be an object"
                )
                continue
            obligation_id = obligation.get("id")
            if not isinstance(obligation_id, str) or not obligation_id:
                failures.append(
                    f"{workload_id}: comparability.obligations[{obligation_idx}].id "
                    "must be a non-empty string"
                )
            elif obligation_id not in expected_obligation_ids:
                failures.append(
                    f"{workload_id}: comparability.obligations[{obligation_idx}].id "
                    f"{obligation_id!r} is not in canonical obligation contract"
                )
            else:
                observed_obligation_ids.add(obligation_id)
            for field_name in ("blocking", "applicable", "passes"):
                if not isinstance(obligation.get(field_name), bool):
                    failures.append(
                        f"{workload_id}: comparability.obligations[{obligation_idx}]."
                        f"{field_name} must be bool"
                    )

    for obligation_id in sorted(required_obligation_ids or set()):
        if obligation_id not in observed_obligation_ids:
            failures.append(
                f"{workload_id}: comparability missing required obligation "
                f"{obligation_id}"
            )

    blocking_failed = workload_comparability.get("blockingFailedObligations")
    if not isinstance(blocking_failed, list):
        failures.append(
            f"{workload_id}: comparability.blockingFailedObligations must be a list"
        )
    else:
        for failed_idx, failed_obligation in enumerate(blocking_failed):
            if not isinstance(failed_obligation, str) or not failed_obligation:
                failures.append(
                    f"{workload_id}: comparability.blockingFailedObligations"
                    f"[{failed_idx}] must be a non-empty string"
                )
            elif failed_obligation not in expected_obligation_ids:
                failures.append(
                    f"{workload_id}: comparability.blockingFailedObligations"
                    f"[{failed_idx}] {failed_obligation!r} is not in canonical "
                    "obligation contract"
                )
        if comparable_flag is True and blocking_failed:
            failures.append(
                f"{workload_id}: comparable workload must not have "
                "blockingFailedObligations"
            )

    return failures, True
