"""Comparability helpers for the compare lane."""

from __future__ import annotations

from pathlib import Path
from typing import Any

from bench.lib.config_validation import load_validated_config
from native_compare_modules.timing_selection import (
    RENDER_ENCODE_TIMING_DOMAINS,
)


NATIVE_EXECUTION_OPERATION_TIMING_SOURCES = {
    "doe-execution-total-ns",
    "doe-execution-workload-total-ns",
    "doe-execution-dispatch-window-ns",
    "doe-execution-encode-ns",
    "doe-execution-gpu-timestamp-ns",
}
DOE_OPERATION_TIMING_SOURCES = {
    *NATIVE_EXECUTION_OPERATION_TIMING_SOURCES,
    "doe-trace-window",
}
DAWN_OPERATION_TIMING_SOURCES = {
    "dawn-perf-wall-time",
    "dawn-perf-cpu-time",
    "dawn-perf-gpu-time",
    "dawn-perf-wall-ns",
}
OBLIGATION_SCHEMA_VERSION = 2
_REPO_ROOT = Path(__file__).resolve().parents[2]
_COMPARABILITY_OBLIGATIONS_PATH = _REPO_ROOT / "config/comparability-obligations.json"
# Legacy median-fraction threshold; retained for backwards-compatible reporting
# but no longer gates apples-to-apples per CLAUDE.md #11 ("one side reports
# zero in a timing phase ... while the other reports material cost"). The
# all-zero-vs-any-material check below is the authoritative gate.
_PHASE_ASYMMETRY_THRESHOLD = 0.10
# All-zero-vs-any-material gate (the CLAUDE.md #11 formulation):
#   * one side is said to "report zero" in a phase iff every sample's phase
#     fraction is < _PHASE_ZERO_EPSILON (tiny float-noise tolerance)
#   * the other side is said to "report material cost" iff at least
#     _PHASE_MATERIAL_MIN_SAMPLES samples have phase fraction
#     >= _PHASE_MATERIAL_FLOOR_FRACTION
# When both conditions hold, the timing scopes are measuring different things
# and the phase-equivalence gate fires regardless of the median percentile.
_PHASE_ZERO_EPSILON: float = 1e-9
_PHASE_MATERIAL_FLOOR_FRACTION: float = 0.005  # 0.5% of executionTotalNs
_PHASE_MATERIAL_MIN_SAMPLES: int = 2
_TIMING_PHASE_FIELDS: tuple[tuple[str, str], ...] = (
    ("setup", "executionSetupTotalNs"),
    ("encode", "executionEncodeTotalNs"),
    ("submitWait", "executionSubmitWaitTotalNs"),
)


def _all_samples_zero(values: list[float]) -> bool:
    """Per-sample all-zero check with float-noise epsilon."""
    if not values:
        return False
    return all(abs(value) < _PHASE_ZERO_EPSILON for value in values)


def _material_sample_count(values: list[float]) -> int:
    """Count samples whose phase fraction clears the material floor."""
    return sum(1 for value in values if value >= _PHASE_MATERIAL_FLOOR_FRACTION)


def _normalized_domain(workload_domain: str) -> str:
    return workload_domain.strip().lower()


def _strict_doe_expected_sources(workload_domain: str) -> set[str]:
    """Return the set of acceptable timing sources for a domain in strict mode.

    GPU timestamps are acceptable for all domains since they measure actual
    GPU execution time and are preferred when available.
    """
    normalized_domain = _normalized_domain(workload_domain)
    gpu = "doe-execution-gpu-timestamp-ns"
    if normalized_domain == "upload":
        return {"doe-execution-workload-total-ns", gpu}
    if normalized_domain in RENDER_ENCODE_TIMING_DOMAINS:
        return {"doe-execution-encode-ns", "doe-execution-total-ns", gpu}
    return {"doe-execution-total-ns", gpu}


def _strict_doe_expected_policies(workload_domain: str) -> set[str]:
    normalized_domain = _normalized_domain(workload_domain)
    gpu = "gpu-timestamp-fallback"
    if normalized_domain == "upload":
        return {"upload-workload-total-preferred", gpu}
    if normalized_domain in RENDER_ENCODE_TIMING_DOMAINS:
        return {"render-encode-preferred", "<none>", gpu}
    return {"<none>", gpu}


def _obligation(
    *,
    obligation_id: str,
    blocking: bool,
    applicable: bool,
    passes: bool,
    details: dict[str, Any] | None = None,
) -> dict[str, Any]:
    return {
        "id": obligation_id,
        "blocking": bool(blocking),
        "applicable": bool(applicable),
        "passes": bool(passes) if applicable else True,
        "details": details if isinstance(details, dict) else {},
    }


def _record_obligation(
    obligations: list[dict[str, Any]],
    reasons: list[str],
    *,
    obligation_id: str,
    blocking: bool,
    applicable: bool,
    passes: bool,
    failure_reason: str = "",
    details: dict[str, Any] | None = None,
) -> None:
    obligations.append(
        _obligation(
            obligation_id=obligation_id,
            blocking=blocking,
            applicable=applicable,
            passes=passes,
            details=details,
        )
    )
    if blocking and applicable and (not passes) and failure_reason:
        reasons.append(failure_reason)


def _sources_match_with_runtime_compatibility(
    *,
    left_sources: list[str],
    right_sources: list[str],
    workload_domain: str,
    comparability_mode: str,
    required_timing_class: str,
    is_dawn_vs_doe: bool,
    is_left_dawn_perf: bool,
    is_right_dawn_perf: bool,
    is_left_dawn_delegate: bool,
    is_right_dawn_delegate: bool,
    is_left_dawn: bool,
    is_right_dawn: bool,
    is_left_doe: bool,
    is_right_doe: bool,
) -> bool:
    if not left_sources or not right_sources:
        return False
    if comparability_mode == "strict" and required_timing_class == "process-wall":
        return set(left_sources) == {"wall-time"} and set(right_sources) == {"wall-time"}
    if not is_dawn_vs_doe:
        return left_sources == right_sources

    left_set = set(left_sources)
    right_set = set(right_sources)
    normalized_domain = _normalized_domain(workload_domain)
    strict_both_doe_native = (
        comparability_mode == "strict"
        and (is_left_dawn_delegate or is_left_doe)
        and (is_right_dawn_delegate or is_right_doe)
    )
    if comparability_mode == "strict":
        doe_expected = _strict_doe_expected_sources(normalized_domain)
        left_expected: set[str] | None = None
        right_expected: set[str] | None = None
        if is_left_dawn_perf:
            left_expected = {"dawn-perf-wall-time"}
        elif is_left_dawn_delegate or is_left_doe:
            left_expected = doe_expected
        if is_right_dawn_perf:
            right_expected = {"dawn-perf-wall-time"}
        elif is_right_dawn_delegate or is_right_doe:
            right_expected = doe_expected
        if left_expected is not None and not left_set.issubset(left_expected):
            return False
        if right_expected is not None and not right_set.issubset(right_expected):
            return False
        if strict_both_doe_native and left_set != right_set:
            return False
        return True

    if is_left_dawn_perf and not left_set.issubset(DAWN_OPERATION_TIMING_SOURCES):
        return False
    if is_right_dawn_perf and not right_set.issubset(DAWN_OPERATION_TIMING_SOURCES):
        return False
    if is_left_dawn_delegate and not left_set.issubset(DOE_OPERATION_TIMING_SOURCES):
        return False
    if is_right_dawn_delegate and not right_set.issubset(DOE_OPERATION_TIMING_SOURCES):
        return False
    if is_left_doe and not left_set.issubset(DOE_OPERATION_TIMING_SOURCES):
        return False
    if is_right_doe and not right_set.issubset(DOE_OPERATION_TIMING_SOURCES):
        return False
    return True


def _timing_selection_policy_match_with_runtime_compatibility(
    *,
    left_policies: list[str],
    right_policies: list[str],
    workload_domain: str,
    comparability_mode: str,
    required_timing_class: str,
    is_dawn_vs_doe: bool,
    is_left_dawn_perf: bool,
    is_right_dawn_perf: bool,
    is_left_dawn_delegate: bool,
    is_right_dawn_delegate: bool,
    is_left_dawn: bool,
    is_right_dawn: bool,
    is_left_doe: bool,
    is_right_doe: bool,
) -> bool:
    if not left_policies or not right_policies:
        return False
    if comparability_mode == "strict" and required_timing_class == "process-wall":
        expected = {"forced-process-wall"}
        return set(left_policies) == expected and set(right_policies) == expected
    if not is_dawn_vs_doe:
        return left_policies == right_policies

    left_set = set(left_policies)
    right_set = set(right_policies)
    normalized_domain = _normalized_domain(workload_domain)
    strict_both_doe_native = (
        comparability_mode == "strict"
        and (is_left_dawn_delegate or is_left_doe)
        and (is_right_dawn_delegate or is_right_doe)
    )

    if comparability_mode == "strict":
        doe_expected = _strict_doe_expected_policies(normalized_domain)
        left_expected: set[str] | None = None
        right_expected: set[str] | None = None
        if is_left_dawn_perf:
            left_expected = {"<none>"}
        elif is_left_dawn_delegate or is_left_doe:
            left_expected = doe_expected
        if is_right_dawn_perf:
            right_expected = {"<none>"}
        elif is_right_dawn_delegate or is_right_doe:
            right_expected = doe_expected
        if left_expected is not None and not left_set.issubset(left_expected):
            return False
        if right_expected is not None and not right_set.issubset(right_expected):
            return False
        if strict_both_doe_native and left_set != right_set:
            return False
        return True

    doe_allowed = {"<none>"}
    if normalized_domain == "upload":
        doe_allowed = {"upload-workload-total-preferred"}
    elif normalized_domain in RENDER_ENCODE_TIMING_DOMAINS:
        doe_allowed = {"<none>", "render-encode-preferred"}
    dawn_perf_allowed = {"<none>"}
    dawn_delegate_allowed = doe_allowed

    if is_left_dawn_perf and not left_set.issubset(dawn_perf_allowed):
        return False
    if is_right_dawn_perf and not right_set.issubset(dawn_perf_allowed):
        return False
    if is_left_dawn_delegate and not left_set.issubset(dawn_delegate_allowed):
        return False
    if is_right_dawn_delegate and not right_set.issubset(dawn_delegate_allowed):
        return False
    if is_left_doe and not left_set.issubset(doe_allowed):
        return False
    if is_right_doe and not right_set.issubset(doe_allowed):
        return False
    return True


def _validate_fact_names(payload: dict[str, Any]) -> tuple[str, ...]:
    raw_facts = payload.get("facts")
    if not isinstance(raw_facts, list) or not raw_facts:
        raise ValueError(
            "invalid comparability obligation contract: facts must be a non-empty list"
        )
    facts: list[str] = []
    for index, raw in enumerate(raw_facts):
        if not isinstance(raw, str) or not raw:
            raise ValueError(
                "invalid comparability obligation contract: "
                f"facts[{index}] must be a non-empty string"
            )
        facts.append(raw)
    if len(facts) != len(set(facts)):
        raise ValueError("invalid comparability obligation contract: duplicate facts")
    return tuple(facts)


def _load_comparability_contract() -> tuple[int, tuple[str, ...], tuple[dict[str, Any], ...]]:
    payload = load_validated_config(_COMPARABILITY_OBLIGATIONS_PATH)
    schema_version = payload.get("schemaVersion")
    if schema_version != OBLIGATION_SCHEMA_VERSION:
        raise ValueError(
            "comparability obligation contract schemaVersion mismatch: "
            f"expected {OBLIGATION_SCHEMA_VERSION}, got {schema_version!r}"
        )
    fact_names = _validate_fact_names(payload)
    known_facts = set(fact_names)
    raw_obligations = payload.get("obligations")
    if not isinstance(raw_obligations, list) or not raw_obligations:
        raise ValueError(
            "invalid comparability obligation contract: obligations must be a non-empty list"
        )

    def validate_expr(expr: Any, *, label: str) -> None:
        if not isinstance(expr, dict):
            raise ValueError(f"{label} must be an object")
        keys = set(expr)
        if keys == {"const"}:
            if not isinstance(expr["const"], bool):
                raise ValueError(f"{label}.const must be bool")
            return
        if keys == {"fact"}:
            fact_name = expr["fact"]
            if not isinstance(fact_name, str) or fact_name not in known_facts:
                raise ValueError(f"{label}.fact must reference a known fact")
            return
        if keys == {"not"}:
            validate_expr(expr["not"], label=f"{label}.not")
            return
        if keys in ({"allOf"}, {"anyOf"}):
            values = expr[next(iter(keys))]
            if not isinstance(values, list) or not values:
                raise ValueError(f"{label} must contain a non-empty list")
            for index, value in enumerate(values):
                validate_expr(value, label=f"{label}[{index}]")
            return
        raise ValueError(f"{label} uses unsupported expression shape")

    ids: list[str] = []
    obligations: list[dict[str, Any]] = []
    seen_ids: set[str] = set()
    for index, raw in enumerate(raw_obligations):
        if not isinstance(raw, dict):
            raise ValueError(
                "invalid comparability obligation contract: "
                f"obligations[{index}] must be an object"
            )
        raw_id = raw.get("id")
        if not isinstance(raw_id, str) or not raw_id:
            raise ValueError(
                "invalid comparability obligation contract: "
                f"obligations[{index}].id must be a non-empty string"
            )
        if raw_id in seen_ids:
            raise ValueError("invalid comparability obligation contract: duplicate obligation ids")
        seen_ids.add(raw_id)
        if not isinstance(raw.get("blocking"), bool):
            raise ValueError(
                "invalid comparability obligation contract: "
                f"obligations[{index}].blocking must be bool"
            )
        validate_expr(raw.get("applicableWhen"), label=f"obligations[{index}].applicableWhen")
        validate_expr(raw.get("passesWhen"), label=f"obligations[{index}].passesWhen")
        ids.append(raw_id)
        obligations.append(raw)
    return schema_version, tuple(ids), tuple(obligations)


(
    OBLIGATION_SCHEMA_VERSION,
    CANONICAL_COMPARABILITY_OBLIGATION_IDS,
    COMPARABILITY_OBLIGATION_RULES,
) = _load_comparability_contract()


def _evaluate_rule_expr(expr: dict[str, Any], facts: dict[str, Any]) -> bool:
    keys = set(expr)
    if keys == {"const"}:
        return bool(expr["const"])
    if keys == {"fact"}:
        value = facts.get(str(expr["fact"]))
        if not isinstance(value, bool):
            raise ValueError(f"comparability facts field {expr['fact']!r} must be bool")
        return value
    if keys == {"not"}:
        return not _evaluate_rule_expr(expr["not"], facts)
    if keys == {"allOf"}:
        return all(_evaluate_rule_expr(item, facts) for item in expr["allOf"])
    if keys == {"anyOf"}:
        return any(_evaluate_rule_expr(item, facts) for item in expr["anyOf"])
    raise ValueError(f"unsupported comparability expression {expr!r}")


def evaluate_comparability_from_facts(
    facts: dict[str, Any],
) -> dict[str, Any]:
    if not isinstance(facts, dict):
        raise ValueError("comparability facts must be an object")

    obligations: list[dict[str, Any]] = []
    for obligation_id, rule in zip(
        CANONICAL_COMPARABILITY_OBLIGATION_IDS,
        COMPARABILITY_OBLIGATION_RULES,
        strict=True,
    ):
        applicable = _evaluate_rule_expr(rule["applicableWhen"], facts)
        passes = _evaluate_rule_expr(rule["passesWhen"], facts)
        obligations.append(
            _obligation(
                obligation_id=obligation_id,
                blocking=bool(rule["blocking"]),
                applicable=applicable,
                passes=passes,
                details={},
            )
        )

    generated_obligation_ids = [str(item.get("id", "")) for item in obligations]
    if generated_obligation_ids != list(CANONICAL_COMPARABILITY_OBLIGATION_IDS):
        raise ValueError(
            "internal comparability obligation contract drift: generated ids do not "
            "match config/comparability-obligations.json"
        )

    blocking_failed_obligations = [
        str(item.get("id", ""))
        for item in obligations
        if item.get("applicable") is True
        and item.get("blocking") is True
        and item.get("passes") is False
    ]
    advisory_failed_obligations = [
        str(item.get("id", ""))
        for item in obligations
        if item.get("applicable") is True
        and item.get("blocking") is False
        and item.get("passes") is False
    ]

    return {
        "obligationSchemaVersion": OBLIGATION_SCHEMA_VERSION,
        "obligations": obligations,
        "blockingFailedObligations": blocking_failed_obligations,
        "advisoryFailedObligations": advisory_failed_obligations,
        "comparable": len(blocking_failed_obligations) == 0,
    }

from native_compare_modules.comparability_runtime import (
    assess_timing_phase_equivalence,
)
from native_compare_modules.compare_assessment import compare_assessment
from native_compare_modules.comparability_upload_contract import (
    assert_runtime_not_stale,
    find_fawn_runtime_index,
    is_dawn_writebuffer_upload_workload,
    subprocess_combined_output,
    validate_upload_apples_to_apples,
    verify_fawn_upload_runtime_contract,
)
