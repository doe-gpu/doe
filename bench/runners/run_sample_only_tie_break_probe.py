#!/usr/bin/env python3
"""Run sample-only Doe-vs-Dawn tie-break probes from persisted real-logit artifacts."""

from __future__ import annotations

import argparse
import copy
import datetime as dt
import json
import math
import subprocess
import struct
import sys
from pathlib import Path
from typing import Any

REPO_ROOT = Path(__file__).resolve().parents[2]
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from bench.lib.bench_utils import load_json

DEFAULT_FIXTURE = REPO_ROOT / "bench" / "fixtures" / "determinism" / "apple-metal-sample-only-tie-break.gemma270m.json"
DEFAULT_OUTPUT_ROOT = REPO_ROOT / "bench" / "out" / "apple-metal-sample-only-tie-break"
DOE_STABLE_TOKEN_EXECUTOR = REPO_ROOT / "bench" / "executors" / "run-doe-stable-token.js"
DOE_STABLE_CHOICE_EXECUTOR = REPO_ROOT / "bench" / "executors" / "run-doe-stable-choice.js"
DOE_REVIEWED_CHOICE_EXECUTOR = REPO_ROOT / "bench" / "executors" / "run-doe-reviewed-choice.js"
DOE_STABLE_CHOICE_CANDIDATE_SET_SOURCES = {
    "fixture-declared",
    "registry-resolved",
    "source-report-resolved",
}
UNIFORM_HANDLE = 1010
LOGITS_HANDLE = 2227
OUTPUT_TOKEN_HANDLE = 2228

from bench.runners.run_determinism_probe import annotate_commands
from bench.runners.run_determinism_probe import compare_lanes
from bench.runners.run_determinism_probe import infer_captures_for_mode
from bench.runners.run_determinism_probe import run_lane
from bench.runners.determinism_search_helpers import DEFAULT_TRIGGER_POLICY_PATH
from bench.runners.determinism_search_helpers import load_trigger_policy
from bench.runners.run_real_logit_hunt import resolve_repo_path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fixture", default=str(DEFAULT_FIXTURE), help="Sample-only tie-break fixture JSON.")
    parser.add_argument(
        "--source-report",
        required=True,
        help="Real-logit hunt report with persisted logits artifacts.",
    )
    parser.add_argument("--runs", type=int, default=None, help="Override repeated-run count from the fixture.")
    parser.add_argument("--case-count", type=int, default=None, help="Override selected candidate count from the fixture.")
    parser.add_argument("--timestamp", default=None, help="UTC timestamp label (default: current UTC time).")
    parser.add_argument("--output-root", default=str(DEFAULT_OUTPUT_ROOT), help="Output root for probe artifacts.")
    return parser.parse_args()


def timestamp_label(raw: str | None) -> str:
    if raw:
        return raw
    return dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")


def ensure_fixture_shape(fixture: dict[str, Any]) -> None:
    required = [
        "scenarioId",
        "kernelRoot",
        "profile",
        "backendLanes",
        "doeStableToken",
        "mutations",
        "defaultRunCount",
        "defaultCaseCount",
    ]
    missing = [field for field in required if field not in fixture]
    if missing:
        raise ValueError(f"fixture missing required fields: {', '.join(missing)}")
    if not fixture["backendLanes"]:
        raise ValueError("fixture must define at least one backend lane")
    if not fixture["mutations"]:
        raise ValueError("fixture must define at least one mutation")
    stable_choice = fixture.get("doeStableChoice")
    if stable_choice is not None:
        if not isinstance(stable_choice, dict):
            raise ValueError("fixture.doeStableChoice must be an object when provided")
        for field in ("mode", "topCandidates", "candidates", "triggerPolicyId", "candidateSetId", "candidateSetSource"):
            if field not in stable_choice:
                raise ValueError(f"fixture.doeStableChoice missing required field: {field}")
        if not isinstance(stable_choice["candidates"], list) or len(stable_choice["candidates"]) < 2:
            raise ValueError("fixture.doeStableChoice.candidates must contain at least two entries")
        if not isinstance(stable_choice["triggerPolicyId"], str) or not stable_choice["triggerPolicyId"].strip():
            raise ValueError("fixture.doeStableChoice.triggerPolicyId must be a non-empty string")
        if not isinstance(stable_choice["candidateSetId"], str) or not stable_choice["candidateSetId"].strip():
            raise ValueError("fixture.doeStableChoice.candidateSetId must be a non-empty string")
        if stable_choice["candidateSetSource"] not in DOE_STABLE_CHOICE_CANDIDATE_SET_SOURCES:
            raise ValueError(
                "fixture.doeStableChoice.candidateSetSource must be fixture-declared, "
                "registry-resolved, or source-report-resolved"
            )
        if "ambiguityTrigger" not in stable_choice and "ambiguityTriggerPolicyId" not in stable_choice:
            raise ValueError(
                "fixture.doeStableChoice must define ambiguityTrigger or ambiguityTriggerPolicyId"
            )
        if "ambiguityTriggerPolicyId" in stable_choice:
            ambiguity_trigger_policy_id = stable_choice["ambiguityTriggerPolicyId"]
            if not isinstance(ambiguity_trigger_policy_id, str) or not ambiguity_trigger_policy_id.strip():
                raise ValueError("fixture.doeStableChoice.ambiguityTriggerPolicyId must be a non-empty string")
            if ambiguity_trigger_policy_id != stable_choice["triggerPolicyId"]:
                raise ValueError(
                    "fixture.doeStableChoice.triggerPolicyId must match "
                    "fixture.doeStableChoice.ambiguityTriggerPolicyId when both are provided"
                )
    reviewed_choice = fixture.get("doeReviewedChoice")
    if reviewed_choice is not None:
        if not isinstance(reviewed_choice, dict):
            raise ValueError("fixture.doeReviewedChoice must be an object when provided")
        for field in (
            "mode",
            "topCandidates",
            "candidates",
            "triggerPolicyId",
            "candidateSetId",
            "candidateSetSource",
            "decision",
        ):
            if field not in reviewed_choice:
                raise ValueError(f"fixture.doeReviewedChoice missing required field: {field}")
        if not isinstance(reviewed_choice["candidates"], list) or len(reviewed_choice["candidates"]) < 2:
            raise ValueError("fixture.doeReviewedChoice.candidates must contain at least two entries")
        if not isinstance(reviewed_choice["triggerPolicyId"], str) or not reviewed_choice["triggerPolicyId"].strip():
            raise ValueError("fixture.doeReviewedChoice.triggerPolicyId must be a non-empty string")
        if not isinstance(reviewed_choice["candidateSetId"], str) or not reviewed_choice["candidateSetId"].strip():
            raise ValueError("fixture.doeReviewedChoice.candidateSetId must be a non-empty string")
        if reviewed_choice["candidateSetSource"] not in DOE_STABLE_CHOICE_CANDIDATE_SET_SOURCES:
            raise ValueError(
                "fixture.doeReviewedChoice.candidateSetSource must be fixture-declared, "
                "registry-resolved, or source-report-resolved"
            )
        if "ambiguityTrigger" not in reviewed_choice and "ambiguityTriggerPolicyId" not in reviewed_choice:
            raise ValueError(
                "fixture.doeReviewedChoice must define ambiguityTrigger or ambiguityTriggerPolicyId"
            )
        if not isinstance(reviewed_choice["decision"], dict):
            raise ValueError("fixture.doeReviewedChoice.decision must be an object")
        for field in ("reviewerId",):
            value = reviewed_choice["decision"].get(field)
            if not isinstance(value, str) or not value.strip():
                raise ValueError(f"fixture.doeReviewedChoice.decision.{field} must be a non-empty string")
        if (
            reviewed_choice["decision"].get("token") is None
            and not reviewed_choice["decision"].get("tokenText")
        ):
            raise ValueError("fixture.doeReviewedChoice.decision requires token or tokenText")
        if "ambiguityTriggerPolicyId" in reviewed_choice:
            ambiguity_trigger_policy_id = reviewed_choice["ambiguityTriggerPolicyId"]
            if not isinstance(ambiguity_trigger_policy_id, str) or not ambiguity_trigger_policy_id.strip():
                raise ValueError("fixture.doeReviewedChoice.ambiguityTriggerPolicyId must be a non-empty string")
            if ambiguity_trigger_policy_id != reviewed_choice["triggerPolicyId"]:
                raise ValueError(
                    "fixture.doeReviewedChoice.triggerPolicyId must match "
                    "fixture.doeReviewedChoice.ambiguityTriggerPolicyId when both are provided"
                )


def relative_or_absolute(path: Path) -> str:
    absolute = path.resolve()
    try:
        return str(absolute.relative_to(REPO_ROOT.resolve()))
    except ValueError:
        return str(absolute)


def sanitize_id(value: str) -> str:
    cleaned = "".join(ch if ch.isalnum() or ch in "-_" else "-" for ch in value.strip())
    return cleaned.strip("-") or "case"


def sha256_bytes(payload: bytes) -> str:
    import hashlib

    return hashlib.sha256(payload).hexdigest()


def load_f32_logits(path: Path) -> list[float]:
    payload = path.read_bytes()
    if len(payload) % 4 != 0:
        raise ValueError(f"logits payload must be 4-byte aligned: {path}")
    if not payload:
        raise ValueError(f"logits payload must not be empty: {path}")
    return list(struct.unpack("<" + "f" * (len(payload) // 4), payload))


def as_f32(value: float) -> float:
    return struct.unpack("<f", struct.pack("<f", float(value)))[0]


def nextafter_f32(value: float, toward: float) -> float:
    current = as_f32(value)
    target = float(toward)
    if math.isnan(current) or math.isnan(target):
        return math.nan
    if current == target:
        return current
    if current == 0.0:
        bits = 0x00000001 if target > 0.0 else 0x80000001
        return struct.unpack("<f", struct.pack("<I", bits))[0]
    bits = struct.unpack("<I", struct.pack("<f", current))[0]
    increasing = target > current
    if current > 0.0:
        bits = bits + 1 if increasing else bits - 1
    else:
        bits = bits - 1 if increasing else bits + 1
    return struct.unpack("<f", struct.pack("<I", bits))[0]


def roundtrip_f32_list(values: list[float]) -> list[float]:
    return [as_f32(value) for value in values]


def encode_f32_words(values: list[float]) -> list[int]:
    payload = struct.pack("<" + "f" * len(values), *values)
    return [struct.unpack("<I", payload[offset : offset + 4])[0] for offset in range(0, len(payload), 4)]


def rank_logits(values: list[float], *, top_k: int) -> list[dict[str, Any]]:
    ranked = sorted(
        ({"token": index, "logit": value} for index, value in enumerate(values)),
        key=lambda item: (-item["logit"], item["token"]),
    )
    return ranked[:top_k]


def expected_greedy_from_logits(values: list[float], *, top_k: int) -> dict[str, Any]:
    top_candidates = rank_logits(values, top_k=top_k)
    max_value = top_candidates[0]["logit"]
    max_indices = [index for index, value in enumerate(values) if value == max_value]
    runner_up = top_candidates[1]["logit"] if len(top_candidates) >= 2 else None
    return {
        "expectedGreedyToken": min(max_indices),
        "maxValue": max_value,
        "exactMaxTieCount": len(max_indices),
        "topCandidates": top_candidates,
        "top2Gap": (max_value - runner_up) if runner_up is not None else None,
    }


def resolve_explicit_tokens(mutation: dict[str, Any], case_entry: dict[str, Any]) -> tuple[list[int], list[str | None]]:
    if mutation.get("tokens") is not None:
        tokens = [int(token) for token in mutation["tokens"]]
        token_texts = [None] * len(tokens)
        return tokens, token_texts
    requested_texts = mutation.get("tokenTexts")
    if not requested_texts:
        raise ValueError("explicit token mutations require either tokens or tokenTexts")
    source_top = case_entry.get("artifacts", [{}])[0].get("topCandidates") or []
    tokens: list[int] = []
    token_texts: list[str | None] = []
    for requested in requested_texts:
        match = next((entry for entry in source_top if entry.get("tokenText") == requested), None)
        if match is None:
            raise ValueError(
                f"token text {requested!r} not found in source top candidates for "
                f"{case_entry.get('promptId')} {case_entry.get('stepLabel')}"
            )
        tokens.append(int(match["token"]))
        token_texts.append(match.get("tokenText"))
    return tokens, token_texts


def resolve_choice_candidates(choice_config: dict[str, Any], case_entry: dict[str, Any]) -> list[dict[str, Any]]:
    source_top = case_entry.get("artifacts", [{}])[0].get("topCandidates") or []
    resolved: list[dict[str, Any]] = []
    for entry in choice_config["candidates"]:
        if isinstance(entry, int):
            resolved.append({"token": int(entry), "label": None})
            continue
        if not isinstance(entry, dict):
            raise ValueError("doeStableChoice.candidates entries must be integers or objects")
        token = entry.get("token")
        label = entry.get("label")
        if token is None:
            token_text = entry.get("tokenText")
            if not token_text:
                raise ValueError("doeStableChoice candidate objects require token or tokenText")
            match = next((candidate for candidate in source_top if candidate.get("tokenText") == token_text), None)
            if match is None:
                raise ValueError(
                    f"doeStableChoice tokenText {token_text!r} not found in source top candidates for "
                    f"{case_entry.get('promptId')} {case_entry.get('stepLabel')}"
                )
            token = int(match["token"])
            if label is None:
                label = token_text
        resolved.append({"token": int(token), "label": label})
    return resolved


def resolve_reviewed_decision(reviewed_choice_config: dict[str, Any], case_entry: dict[str, Any]) -> dict[str, Any]:
    raw_decision = copy.deepcopy(reviewed_choice_config["decision"])
    source_top = case_entry.get("artifacts", [{}])[0].get("topCandidates") or []
    token = raw_decision.get("token")
    label = raw_decision.get("label")
    if token is None:
        token_text = raw_decision.get("tokenText")
        match = next((candidate for candidate in source_top if candidate.get("tokenText") == token_text), None)
        if match is None:
            raise ValueError(
                f"doeReviewedChoice decision tokenText {token_text!r} not found in source top candidates for "
                f"{case_entry.get('promptId')} {case_entry.get('stepLabel')}"
            )
        token = int(match["token"])
        if label is None:
            label = token_text
    return {
        "token": int(token),
        "label": label,
        "reviewerId": raw_decision["reviewerId"],
        "decisionId": raw_decision.get("decisionId"),
        "decisionRef": raw_decision.get("decisionRef"),
        "signature": raw_decision.get("signature"),
    }


def resolve_choice_trigger(choice_config: dict[str, Any]) -> tuple[dict[str, Any], str | None]:
    trigger = choice_config.get("ambiguityTrigger")
    trigger_policy_id = choice_config.get("triggerPolicyId")
    ambiguity_trigger_policy_id = choice_config.get("ambiguityTriggerPolicyId")
    if trigger is not None:
        return copy.deepcopy(trigger), trigger_policy_id
    if ambiguity_trigger_policy_id is None:
        raise ValueError("doeStableChoice requires ambiguityTrigger or ambiguityTriggerPolicyId")
    policy_path = resolve_repo_path(str(choice_config.get("triggerPolicyPath") or DEFAULT_TRIGGER_POLICY_PATH))
    policy = load_trigger_policy(policy_path, str(ambiguity_trigger_policy_id))
    return {"mode": policy["mode"], "epsilon": policy["epsilon"]}, policy["id"]


def apply_mutation(
    source_logits: list[float],
    mutation: dict[str, Any],
    *,
    top_k: int,
    case_entry: dict[str, Any] | None = None,
) -> tuple[list[float], dict[str, Any]]:
    mutated = roundtrip_f32_list(source_logits)
    ranked = rank_logits(source_logits, top_k=max(top_k, mutation.get("topK", 0), 4))
    if len(ranked) < 2:
        raise ValueError("sample-only mutations require at least two logits")
    top1 = ranked[0]
    top2 = ranked[1]
    kind = mutation["kind"]
    mutation_details = {
        "kind": kind,
        "top1Token": top1["token"],
        "top1Logit": top1["logit"],
        "top2Token": top2["token"],
        "top2Logit": top2["logit"],
    }
    if kind == "identity":
        pass
    elif kind == "top2_exact_tie":
        tie_value = as_f32(max(top1["logit"], top2["logit"]))
        mutated[top1["token"]] = tie_value
        mutated[top2["token"]] = tie_value
        mutation_details["tieValue"] = tie_value
    elif kind == "topk_exact_tie":
        tie_k = int(mutation.get("topK", 4))
        tie_value = as_f32(ranked[0]["logit"])
        tied_tokens = [entry["token"] for entry in ranked[:tie_k]]
        for token in tied_tokens:
            mutated[token] = tie_value
        mutation_details["tieValue"] = tie_value
        mutation_details["tiedTokens"] = tied_tokens
    elif kind == "top2_first_candidate_wins_by_ulp":
        tie_value = as_f32(max(top1["logit"], top2["logit"]))
        mutated[top1["token"]] = nextafter_f32(tie_value, math.inf)
        mutated[top2["token"]] = tie_value
        mutation_details["baseTieValue"] = tie_value
    elif kind == "top2_second_candidate_wins_by_ulp":
        tie_value = as_f32(max(top1["logit"], top2["logit"]))
        mutated[top1["token"]] = tie_value
        mutated[top2["token"]] = nextafter_f32(tie_value, math.inf)
        mutation_details["baseTieValue"] = tie_value
    elif kind == "explicit_tokens_exact_tie":
        if case_entry is None:
            raise ValueError("explicit token mutations require source case metadata")
        tied_tokens, tied_token_texts = resolve_explicit_tokens(mutation, case_entry)
        tie_value = nextafter_f32(top1["logit"], math.inf)
        for token in tied_tokens:
            mutated[token] = tie_value
        mutation_details["tieValue"] = tie_value
        mutation_details["tiedTokens"] = tied_tokens
        mutation_details["tiedTokenTexts"] = tied_token_texts
    else:
        raise ValueError(f"unsupported mutation kind: {kind}")
    return roundtrip_f32_list(mutated), mutation_details


def build_sample_only_commands(logits: list[float]) -> list[dict[str, Any]]:
    buffer_size = len(logits) * 4
    return [
        {
            "kind": "buffer_write",
            "handle": UNIFORM_HANDLE,
            "bufferSize": 16,
            "data": [len(logits), 0, 0, 0],
        },
        {
            "kind": "buffer_write",
            "handle": LOGITS_HANDLE,
            "bufferSize": buffer_size,
            "data": encode_f32_words(logits),
        },
        {
            "kind": "kernel_dispatch",
            "kernel": "sample.wgsl",
            "x": 1,
            "y": 1,
            "z": 1,
            "initialize_buffers_on_create": True,
            "bindings": [
                {
                    "binding": 0,
                    "group": 0,
                    "kind": "buffer",
                    "buffer_type": "uniform",
                    "resource_handle": UNIFORM_HANDLE,
                    "buffer_size": 16,
                    "visibility": "compute",
                },
                {
                    "binding": 1,
                    "group": 0,
                    "kind": "buffer",
                    "buffer_type": "readonly",
                    "resource_handle": LOGITS_HANDLE,
                    "buffer_size": buffer_size,
                    "visibility": "compute",
                },
                {
                    "binding": 2,
                    "group": 0,
                    "kind": "buffer",
                    "buffer_type": "storage",
                    "resource_handle": OUTPUT_TOKEN_HANDLE,
                    "buffer_size": 4,
                    "visibility": "compute",
                },
            ],
        },
    ]


def matches_source_case(candidate: dict[str, Any], case_filter: dict[str, Any]) -> bool:
    if candidate.get("promptId") != case_filter["promptId"]:
        return False
    if case_filter.get("phase") is not None and candidate.get("phase") != case_filter["phase"]:
        return False
    if case_filter.get("stepIndex") is not None and candidate.get("stepIndex") != case_filter["stepIndex"]:
        return False
    if case_filter.get("stepLabel") is not None and candidate.get("stepLabel") != case_filter["stepLabel"]:
        return False
    return True


def select_source_cases(
    report: dict[str, Any],
    *,
    case_count: int,
    case_filters: list[dict[str, Any]] | None = None,
) -> list[dict[str, Any]]:
    candidates = report.get("summary", {}).get("allCandidates") or report.get("summary", {}).get("topCandidates") or []
    if case_filters:
        selected: list[dict[str, Any]] = []
        for case_filter in case_filters:
            match = next(
                (
                    candidate
                    for candidate in candidates
                    if matches_source_case(candidate, case_filter)
                    and candidate.get("artifacts")
                    and candidate["artifacts"][0].get("logitsArtifactPath")
                ),
                None,
            )
            if match is None:
                raise ValueError(
                    "source report does not contain persisted logits for "
                    f"{case_filter['promptId']} phase={case_filter.get('phase')} "
                    f"stepIndex={case_filter.get('stepIndex')}"
                )
            selected.append(match)
        return selected
    selected: list[dict[str, Any]] = []
    for candidate in candidates:
        artifacts = candidate.get("artifacts") or []
        if not artifacts:
            continue
        logits_path = artifacts[0].get("logitsArtifactPath")
        if not logits_path:
            continue
        selected.append(candidate)
        if len(selected) >= case_count:
            break
    if not selected:
        raise ValueError(
            "source report does not contain persisted logits artifacts; rerun run_real_logit_hunt.py with --persist-logits"
        )
    return selected


def build_sample_only_tie_break_audit(
    lane_summaries: dict[str, dict[str, Any]],
    *,
    expected_greedy_token: int,
    exact_max_tie_count: int,
) -> dict[str, Any]:
    op_id = "sample.output_token"
    lane_audit: dict[str, Any] = {}
    for lane_id, lane_summary in lane_summaries.items():
        operator = lane_summary["operators"][op_id]
        actual = operator.get("dominantDecodedValue")
        lane_audit[lane_id] = {
            "available": actual is not None,
            "expectedGreedyToken": expected_greedy_token,
            "actualSampledToken": actual,
            "matchesExpectedGreedyToken": actual == expected_greedy_token if actual is not None else None,
            "exactMaxTieCount": exact_max_tie_count,
        }
    lane_ids = list(lane_audit.keys())
    cross_lane = {}
    if lane_ids:
        actual_values = {lane_id: lane_audit[lane_id]["actualSampledToken"] for lane_id in lane_ids}
        cross_lane[op_id] = {
            "expectedGreedyToken": expected_greedy_token,
            "actualSampledTokenByLane": actual_values,
            "sameActualSampledTokenAcrossLanes": len(set(actual_values.values())) == 1,
            "allLanesMatchExpectedGreedyToken": all(
                lane_audit[lane_id]["matchesExpectedGreedyToken"] for lane_id in lane_ids
            ),
        }
    return {"source": "explicit_input_logits", "lanes": lane_audit, "crossLane": cross_lane}


def case_claim_summary(
    lane_summaries: dict[str, dict[str, Any]],
    cross_lane: dict[str, Any],
    tie_break_audit: dict[str, Any],
    stable_token: dict[str, Any],
    stable_choice: dict[str, Any] | None,
    reviewed_choice: dict[str, Any] | None,
) -> dict[str, Any]:
    op_id = "sample.output_token"
    doe = lane_summaries.get("doe")
    dawn = lane_summaries.get("dawn")
    cross_op = cross_lane["operators"][op_id]
    audit = tie_break_audit["crossLane"].get(op_id, {})
    doe_raw_matches_expected = tie_break_audit["lanes"].get("doe", {}).get("matchesExpectedGreedyToken")
    stable_matches_expected = stable_token.get("matchesExpectedGreedyToken")
    claim = {
        "mode": (
            "reviewed-choice"
            if reviewed_choice is not None
            else "stable-choice" if stable_choice is not None else "stable-token"
        ),
        "doeStableAcrossRuns": doe["stableAcrossRuns"] if doe else None,
        "dawnStableAcrossRuns": dawn["stableAcrossRuns"] if dawn else None,
        "sameAcrossLanes": cross_op["sameAcrossLanes"],
        "sameDecodedValueAcrossLanes": cross_op.get("sameDecodedValueAcrossLanes"),
        "allLanesMatchExpectedGreedyToken": audit.get("allLanesMatchExpectedGreedyToken"),
        "doeRawMatchesExpectedGreedyToken": doe_raw_matches_expected,
        "doeStableTokenMatchesExpectedGreedyToken": stable_matches_expected,
        "doeStableTokenDiffersFromDoeRawToken": (
            stable_token.get("token") != tie_break_audit["lanes"].get("doe", {}).get("actualSampledToken")
            if stable_token.get("token") is not None
            else None
        ),
        "doeStableTokenDifferentiator": bool(
            stable_matches_expected and doe_raw_matches_expected is False
        ),
        "doeMoreDeterministicThanDawn": bool(doe and dawn and doe["stableAcrossRuns"] and not dawn["stableAcrossRuns"]),
        "claimableDemoStability": {
            "requirementId": "claimable-demo-v1",
            "doeFinalTokenStable": doe["stableAcrossRuns"] if doe else None,
            "dawnFinalTokenStable": dawn["stableAcrossRuns"] if dawn else None,
            "receiptReplayStable": bool(stable_token.get("receipt", {}).get("logitsSha256")) if isinstance(stable_token.get("receipt"), dict) else None,
            "passed": bool((doe["stableAcrossRuns"] if doe else False) and (dawn["stableAcrossRuns"] if dawn else False)),
        },
    }
    if stable_choice is None:
        claim.update(
            {
                "doeStableChoiceConfigured": False,
                "doeStableChoiceTriggered": None,
                "doeStableChoiceSelectedBy": None,
                "doeStableChoiceDiffersFromDoeRawToken": None,
                "doeStableChoiceDiffersFromDoeStableToken": None,
                "doeStableChoiceDifferentiator": False,
            }
        )
    else:
        doe_raw_token = tie_break_audit["lanes"].get("doe", {}).get("actualSampledToken")
        claim.update(
            {
                "doeStableChoiceConfigured": True,
                "doeStableChoiceTriggered": stable_choice["receipt"]["ambiguityTriggered"],
                "doeStableChoiceSelectedBy": stable_choice["receipt"]["selectedBy"],
                "doeStableChoiceDiffersFromDoeRawToken": (
                    stable_choice.get("token") != doe_raw_token if stable_choice.get("token") is not None else None
                ),
                "doeStableChoiceDiffersFromDoeStableToken": (
                    stable_choice.get("token") != stable_token.get("token")
                    if stable_choice.get("token") is not None and stable_token.get("token") is not None
                    else None
                ),
                "doeStableChoiceDifferentiator": bool(
                    stable_choice["receipt"]["ambiguityTriggered"]
                    and stable_choice.get("token") is not None
                    and stable_choice.get("token") != doe_raw_token
                ),
            }
        )
    if reviewed_choice is None:
        claim.update(
            {
                "doeReviewedChoiceConfigured": False,
                "doeReviewedChoiceTriggered": None,
                "doeReviewedChoiceSelectedBy": None,
                "doeReviewedChoiceDecisionAccepted": None,
                "doeReviewedChoiceDiffersFromDoeRawToken": None,
                "doeReviewedChoiceDiffersFromDoeStableToken": None,
                "doeReviewedChoiceDiffersFromDoeStableChoice": None,
                "doeReviewedChoiceDifferentiator": False,
            }
        )
        return claim
    doe_raw_token = tie_break_audit["lanes"].get("doe", {}).get("actualSampledToken")
    stable_choice_token = stable_choice.get("token") if stable_choice is not None else None
    claim.update(
        {
            "doeReviewedChoiceConfigured": True,
            "doeReviewedChoiceTriggered": reviewed_choice["receipt"]["ambiguityTriggered"],
            "doeReviewedChoiceSelectedBy": reviewed_choice["receipt"]["selectedBy"],
            "doeReviewedChoiceDecisionAccepted": reviewed_choice["receipt"]["decisionAccepted"],
            "doeReviewedChoiceDiffersFromDoeRawToken": (
                reviewed_choice.get("token") != doe_raw_token if reviewed_choice.get("token") is not None else None
            ),
            "doeReviewedChoiceDiffersFromDoeStableToken": (
                reviewed_choice.get("token") != stable_token.get("token")
                if reviewed_choice.get("token") is not None and stable_token.get("token") is not None
                else None
            ),
            "doeReviewedChoiceDiffersFromDoeStableChoice": (
                reviewed_choice.get("token") != stable_choice_token
                if reviewed_choice.get("token") is not None and stable_choice_token is not None
                else None
            ),
            "doeReviewedChoiceDifferentiator": bool(
                reviewed_choice["receipt"]["decisionAccepted"]
                and reviewed_choice.get("token") is not None
                and any(
                    reference_token is not None and reviewed_choice.get("token") != reference_token
                    for reference_token in (doe_raw_token, stable_token.get("token"), stable_choice_token)
                )
            ),
        }
    )
    return claim


def run_doe_stable_token(
    *,
    fixture: dict[str, Any],
    logits_path: Path,
    case_dir: Path,
    case_id: str,
    expected_greedy_token: int,
) -> dict[str, Any]:
    stable_config = fixture["doeStableToken"]
    config_path = case_dir / "doe_stable_token.config.json"
    report_path = case_dir / "doe.stable-token.json"
    trace_meta_path = case_dir / "doe.stable-token.trace-meta.json"
    config = {
        "logitsPath": str(logits_path),
        "outputPath": str(report_path),
        "traceMetaPath": str(trace_meta_path),
        "vocabSize": int(logits_path.stat().st_size // 4),
        "mode": stable_config["mode"],
        "topCandidates": int(stable_config["topCandidates"]),
        "label": f"{case_id}-stable-token",
    }
    config_path.write_text(json.dumps(config, indent=2) + "\n", encoding="utf-8")
    subprocess.run(
        ["node", str(DOE_STABLE_TOKEN_EXECUTOR), "--config", str(config_path)],
        check=True,
        cwd=str(REPO_ROOT),
        capture_output=True,
        text=True,
    )
    report = load_json(report_path)
    token = report["result"]["token"]
    return {
        "mode": report["mode"],
        "reportPath": relative_or_absolute(report_path),
        "traceMetaPath": relative_or_absolute(trace_meta_path),
        "traceMeta": report.get("traceMeta"),
        "token": token,
        "receipt": report["result"]["receipt"],
        "matchesExpectedGreedyToken": token == expected_greedy_token,
    }


def run_doe_stable_choice(
    *,
    fixture: dict[str, Any],
    case_entry: dict[str, Any],
    logits_path: Path,
    case_dir: Path,
    case_id: str,
) -> dict[str, Any] | None:
    stable_choice_config = fixture.get("doeStableChoice")
    if stable_choice_config is None:
        return None
    ambiguity_trigger, trigger_policy_id = resolve_choice_trigger(stable_choice_config)
    config_path = case_dir / "doe_stable_choice.config.json"
    report_path = case_dir / "doe.stable-choice.json"
    trace_meta_path = case_dir / "doe.stable-choice.trace-meta.json"
    config = {
        "logitsPath": str(logits_path),
        "outputPath": str(report_path),
        "traceMetaPath": str(trace_meta_path),
        "vocabSize": int(logits_path.stat().st_size // 4),
        "mode": stable_choice_config["mode"],
        "topCandidates": int(stable_choice_config["topCandidates"]),
        "policyId": stable_choice_config.get("policyId"),
        "triggerPolicyId": trigger_policy_id,
        "candidateSetId": stable_choice_config.get("candidateSetId"),
        "candidateSetSource": stable_choice_config.get("candidateSetSource"),
        "candidates": resolve_choice_candidates(stable_choice_config, case_entry),
        "ambiguityTrigger": ambiguity_trigger,
        "label": f"{case_id}-stable-choice",
    }
    config_path.write_text(json.dumps(config, indent=2) + "\n", encoding="utf-8")
    subprocess.run(
        ["node", str(DOE_STABLE_CHOICE_EXECUTOR), "--config", str(config_path)],
        check=True,
        cwd=str(REPO_ROOT),
        capture_output=True,
        text=True,
    )
    report = load_json(report_path)
    return {
        "mode": report["mode"],
        "reportPath": relative_or_absolute(report_path),
        "traceMetaPath": relative_or_absolute(trace_meta_path),
        "traceMeta": report.get("traceMeta"),
        "token": report["result"]["token"],
        "receipt": report["result"]["receipt"],
    }


def run_doe_reviewed_choice(
    *,
    fixture: dict[str, Any],
    case_entry: dict[str, Any],
    logits_path: Path,
    case_dir: Path,
    case_id: str,
) -> dict[str, Any] | None:
    reviewed_choice_config = fixture.get("doeReviewedChoice")
    if reviewed_choice_config is None:
        return None
    ambiguity_trigger, trigger_policy_id = resolve_choice_trigger(reviewed_choice_config)
    config_path = case_dir / "doe_reviewed_choice.config.json"
    report_path = case_dir / "doe.reviewed-choice.json"
    trace_meta_path = case_dir / "doe.reviewed-choice.trace-meta.json"
    config = {
        "logitsPath": str(logits_path),
        "outputPath": str(report_path),
        "traceMetaPath": str(trace_meta_path),
        "vocabSize": int(logits_path.stat().st_size // 4),
        "mode": reviewed_choice_config["mode"],
        "topCandidates": int(reviewed_choice_config["topCandidates"]),
        "reviewPolicyId": reviewed_choice_config.get("reviewPolicyId"),
        "triggerPolicyId": trigger_policy_id,
        "candidateSetId": reviewed_choice_config.get("candidateSetId"),
        "candidateSetSource": reviewed_choice_config.get("candidateSetSource"),
        "candidates": resolve_choice_candidates(reviewed_choice_config, case_entry),
        "ambiguityTrigger": ambiguity_trigger,
        "decision": resolve_reviewed_decision(reviewed_choice_config, case_entry),
        "label": f"{case_id}-reviewed-choice",
    }
    config_path.write_text(json.dumps(config, indent=2) + "\n", encoding="utf-8")
    subprocess.run(
        ["node", str(DOE_REVIEWED_CHOICE_EXECUTOR), "--config", str(config_path)],
        check=True,
        cwd=str(REPO_ROOT),
        capture_output=True,
        text=True,
    )
    report = load_json(report_path)
    return {
        "mode": report["mode"],
        "reportPath": relative_or_absolute(report_path),
        "traceMetaPath": relative_or_absolute(trace_meta_path),
        "traceMeta": report.get("traceMeta"),
        "token": report["result"]["token"],
        "receipt": report["result"]["receipt"],
    }


def run_case(
    *,
    fixture: dict[str, Any],
    case_entry: dict[str, Any],
    mutation: dict[str, Any],
    output_dir: Path,
    run_count: int,
) -> dict[str, Any]:
    source_logits_path = resolve_repo_path(case_entry["artifacts"][0]["logitsArtifactPath"])
    source_logits = load_f32_logits(source_logits_path)
    mutated_logits, mutation_details = apply_mutation(
        source_logits,
        mutation,
        top_k=max(5, int(mutation.get("topK", 0) or 0)),
        case_entry=case_entry,
    )
    expected = expected_greedy_from_logits(mutated_logits, top_k=5)
    case_id = sanitize_id(f"{case_entry['promptId']}-{case_entry['stepLabel']}-{mutation['id']}")
    case_dir = output_dir / case_id
    case_dir.mkdir(parents=True, exist_ok=True)

    source_bytes = source_logits_path.read_bytes()
    mutated_bytes = struct.pack("<" + "f" * len(mutated_logits), *mutated_logits)
    source_copy_path = case_dir / "source.logits.bin"
    mutated_path = case_dir / "input.logits.bin"
    source_copy_path.write_bytes(source_bytes)
    mutated_path.write_bytes(mutated_bytes)

    commands = build_sample_only_commands(mutated_logits)
    commands_bytes = (json.dumps(commands, indent=2) + "\n").encode("utf-8")
    commands_sha256 = sha256_bytes(commands_bytes)
    captures = infer_captures_for_mode(commands, determinism_mode="stable-token", semantic_stage="sample_only")
    annotated_commands = annotate_commands(commands, captures, execution_plan_hash=commands_sha256)
    annotated_bytes = (json.dumps(annotated_commands, indent=2) + "\n").encode("utf-8")
    annotated_path = case_dir / "sample_only.commands.annotated.json"
    annotated_path.write_bytes(annotated_bytes)

    lane_summaries: dict[str, dict[str, Any]] = {}
    for lane in fixture["backendLanes"]:
        lane_summaries[lane["id"]] = run_lane(
            lane_id=lane["id"],
            backend_lane=lane["backendLane"],
            run_count=run_count,
            commands_path=annotated_path,
            output_dir=case_dir,
            profile=fixture["profile"],
            kernel_root=resolve_repo_path(fixture["kernelRoot"]),
            queue_wait_mode=fixture.get("queueWaitMode", "process-events"),
            queue_sync_mode=fixture.get("queueSyncMode", "per-command"),
            captures=captures,
        )

    cross_lane = compare_lanes(lane_summaries, captures)
    tie_break_audit = build_sample_only_tie_break_audit(
        lane_summaries,
        expected_greedy_token=expected["expectedGreedyToken"],
        exact_max_tie_count=expected["exactMaxTieCount"],
    )
    stable_token = run_doe_stable_token(
        fixture=fixture,
        logits_path=mutated_path,
        case_dir=case_dir,
        case_id=case_id,
        expected_greedy_token=expected["expectedGreedyToken"],
    )
    stable_choice = run_doe_stable_choice(
        fixture=fixture,
        case_entry=case_entry,
        logits_path=mutated_path,
        case_dir=case_dir,
        case_id=case_id,
    )
    reviewed_choice = run_doe_reviewed_choice(
        fixture=fixture,
        case_entry=case_entry,
        logits_path=mutated_path,
        case_dir=case_dir,
        case_id=case_id,
    )
    report = {
        "schemaVersion": 1,
        "source": "doe-sample-only-tie-break-case",
        "caseId": case_id,
        "determinismMode": "stable-token",
        "sourceCandidate": {
            "promptId": case_entry["promptId"],
            "promptText": case_entry["promptText"],
            "stepLabel": case_entry["stepLabel"],
            "phase": case_entry["phase"],
            "stepIndex": case_entry["stepIndex"],
            "sourceLogitsArtifactPath": relative_or_absolute(source_logits_path),
            "sourceLogitsSha256": sha256_bytes(source_bytes),
            "sourceTop2Gap": case_entry["minTop2Gap"],
        },
        "mutation": {
            "id": mutation["id"],
            **mutation_details,
        },
        "inputLogits": {
            "path": relative_or_absolute(mutated_path),
            "sha256": sha256_bytes(mutated_bytes),
            "vocabSize": len(mutated_logits),
            "expectedGreedyToken": expected["expectedGreedyToken"],
            "exactMaxTieCount": expected["exactMaxTieCount"],
            "top2Gap": expected["top2Gap"],
            "topCandidates": expected["topCandidates"],
        },
        "commandsPath": relative_or_absolute(annotated_path),
        "commandsSha256": sha256_bytes(annotated_bytes),
        "captures": captures,
        "lanes": lane_summaries,
        "crossLane": cross_lane,
        "tieBreakAudit": tie_break_audit,
        "doeStableToken": stable_token,
        "doeStableChoice": stable_choice,
        "doeReviewedChoice": reviewed_choice,
        "claim": case_claim_summary(
            lane_summaries,
            cross_lane,
            tie_break_audit,
            stable_token,
            stable_choice,
            reviewed_choice,
        ),
    }
    report_path = case_dir / f"{case_id}.determinism.json"
    report_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    return {
        "caseId": case_id,
        "reportPath": relative_or_absolute(report_path),
        "promptId": case_entry["promptId"],
        "stepLabel": case_entry["stepLabel"],
        "mutationId": mutation["id"],
        "expectedGreedyToken": expected["expectedGreedyToken"],
        "exactMaxTieCount": expected["exactMaxTieCount"],
        "top2Gap": expected["top2Gap"],
        "claim": report["claim"],
        "doeStableToken": stable_token,
        "doeStableChoice": stable_choice,
        "doeReviewedChoice": reviewed_choice,
        "laneTokens": {
            lane_id: lane_summaries[lane_id]["operators"]["sample.output_token"].get("dominantDecodedValue")
            for lane_id in lane_summaries
        },
    }


def build_summary(results: list[dict[str, Any]]) -> dict[str, Any]:
    divergence_cases = [
        result
        for result in results
        if not result["claim"]["sameDecodedValueAcrossLanes"]
        or not result["claim"]["allLanesMatchExpectedGreedyToken"]
    ]
    by_mutation: dict[str, dict[str, Any]] = {}
    for result in results:
        bucket = by_mutation.setdefault(
            result["mutationId"],
            {"caseCount": 0, "divergenceCount": 0, "allSameAcrossLanes": True, "allMatchExpectedGreedyToken": True},
        )
        bucket["caseCount"] += 1
        bucket["allSameAcrossLanes"] = bucket["allSameAcrossLanes"] and bool(result["claim"]["sameDecodedValueAcrossLanes"])
        bucket["allMatchExpectedGreedyToken"] = bucket["allMatchExpectedGreedyToken"] and bool(
            result["claim"]["allLanesMatchExpectedGreedyToken"]
        )
        if (
            not result["claim"]["sameDecodedValueAcrossLanes"]
            or not result["claim"]["allLanesMatchExpectedGreedyToken"]
        ):
            bucket["divergenceCount"] += 1
    return {
        "caseCount": len(results),
        "divergenceCaseCount": len(divergence_cases),
        "firstDivergenceCaseId": divergence_cases[0]["caseId"] if divergence_cases else None,
        "allCasesSameAcrossLanes": all(result["claim"]["sameDecodedValueAcrossLanes"] for result in results),
        "allCasesMatchExpectedGreedyToken": all(result["claim"]["allLanesMatchExpectedGreedyToken"] for result in results),
        "stableTokenDifferentiatorCaseCount": sum(
            1 for result in results if result["claim"]["doeStableTokenDifferentiator"]
        ),
        "stableChoiceDifferentiatorCaseCount": sum(
            1 for result in results if result["claim"]["doeStableChoiceDifferentiator"]
        ),
        "reviewedChoiceDifferentiatorCaseCount": sum(
            1 for result in results if result["claim"]["doeReviewedChoiceDifferentiator"]
        ),
        "byMutation": by_mutation,
    }


def main() -> int:
    args = parse_args()
    fixture_path = resolve_repo_path(args.fixture)
    source_report_path = resolve_repo_path(args.source_report)
    fixture = load_json(fixture_path)
    ensure_fixture_shape(fixture)
    source_report = load_json(source_report_path)
    run_count = args.runs or int(fixture["defaultRunCount"])
    case_count = args.case_count or int(fixture["defaultCaseCount"])
    stamp = timestamp_label(args.timestamp)
    output_dir = resolve_repo_path(args.output_root) / stamp
    output_dir.mkdir(parents=True, exist_ok=True)

    selected_cases = select_source_cases(
        source_report,
        case_count=case_count,
        case_filters=copy.deepcopy(fixture.get("sourceCases") or None),
    )
    results: list[dict[str, Any]] = []
    for case_entry in selected_cases:
        for mutation in fixture["mutations"]:
            results.append(
                run_case(
                    fixture=fixture,
                    case_entry=case_entry,
                    mutation=mutation,
                    output_dir=output_dir,
                    run_count=run_count,
                )
            )

    report = {
        "schemaVersion": 1,
        "source": "doe-sample-only-tie-break-probe",
        "scenarioId": fixture["scenarioId"],
        "fixturePath": relative_or_absolute(fixture_path),
        "sourceReportPath": relative_or_absolute(source_report_path),
        "sourceReportSha256": sha256_bytes(source_report_path.read_bytes()),
        "timestamp": stamp,
        "runCount": run_count,
        "selectedCaseCount": len(selected_cases),
        "results": results,
        "summary": build_summary(results),
    }
    report_path = output_dir / f"{fixture['scenarioId']}.sample-only-tie-break.json"
    report_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"reportPath": relative_or_absolute(report_path), "summary": report["summary"]}, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
