#!/usr/bin/env python3
"""Shared helpers for Doe determinism pair mining and promotion search."""

from __future__ import annotations

import datetime as dt
import math
import re
import sys
from pathlib import Path
from typing import Any


REPO_ROOT = Path(__file__).resolve().parents[2]
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from bench.lib.bench_utils import load_json

_MULTI_SPACE_RE = re.compile(r"\s+")
_NON_WORD_RE = re.compile(r"[^a-z0-9'-]+")
_WORD_BOUNDARY_CACHE: dict[str, re.Pattern[str]] = {}
DEFAULT_SINGLE_TOKEN_RE = re.compile(r"^[A-Za-z][A-Za-z'-]*$")
DEFAULT_TRIGGER_POLICY_PATH = REPO_ROOT / "config" / "determinism-trigger-policy.json"
DEFAULT_ANSWER_SET_REGISTRY_PATH = REPO_ROOT / "config" / "determinism-answer-set-registry.json"


def resolve_repo_path(raw: str) -> Path:
    path = Path(raw)
    if path.is_absolute():
        return path
    return REPO_ROOT / path


def relative_or_absolute(path: Path) -> str:
    absolute = path.resolve()
    try:
        return str(absolute.relative_to(REPO_ROOT.resolve()))
    except ValueError:
        return str(absolute)


def timestamp_label(raw: str | None) -> str:
    if raw:
        return raw
    return dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")


def normalize_prompt_text(text: str) -> str:
    return _MULTI_SPACE_RE.sub(" ", _NON_WORD_RE.sub(" ", text.lower())).strip()


def normalize_answer_token_text(raw: str) -> str:
    stripped = raw.strip().lower()
    cleaned = _NON_WORD_RE.sub(" ", stripped)
    return _MULTI_SPACE_RE.sub(" ", cleaned).strip()


def is_single_token_answer_text(
    raw: str,
    *,
    min_normalized_length: int,
    require_word_like: bool,
) -> bool:
    normalized = normalize_answer_token_text(raw)
    if len(normalized) < min_normalized_length or " " in normalized:
        return False
    if not require_word_like:
        return True
    return bool(DEFAULT_SINGLE_TOKEN_RE.fullmatch(normalized))


def prompt_contains_normalized_token(prompt_text: str, normalized_token: str) -> bool:
    if not normalized_token:
        return False
    pattern = _WORD_BOUNDARY_CACHE.get(normalized_token)
    if pattern is None:
        pattern = re.compile(rf"(?<![a-z0-9']){re.escape(normalized_token)}(?![a-z0-9'])")
        _WORD_BOUNDARY_CACHE[normalized_token] = pattern
    return bool(pattern.search(normalize_prompt_text(prompt_text)))


def looks_like_bounded_answer_prompt(prompt_text: str, *, required_substrings: list[str]) -> bool:
    lowered = prompt_text.lower()
    return all(fragment.lower() in lowered for fragment in required_substrings)


def canonical_pair_id(left_text: str, right_text: str) -> str:
    parts = sorted((normalize_answer_token_text(left_text), normalize_answer_token_text(right_text)))
    sanitized = ["".join(ch if ch.isalnum() else "-" for ch in part).strip("-") or "token" for part in parts]
    return "__".join(sanitized)


def canonical_candidate_order(left: dict[str, Any], right: dict[str, Any]) -> list[dict[str, Any]]:
    ordered = sorted(
        (
            {
                "token": int(left["token"]),
                "tokenText": left.get("tokenText"),
                "normalizedTokenText": normalize_answer_token_text(left.get("tokenText") or ""),
            },
            {
                "token": int(right["token"]),
                "tokenText": right.get("tokenText"),
                "normalizedTokenText": normalize_answer_token_text(right.get("tokenText") or ""),
            },
        ),
        key=lambda entry: (entry["token"], entry["normalizedTokenText"]),
    )
    return ordered


def load_trigger_policy(policy_path: Path, policy_id: str) -> dict[str, Any]:
    registry = load_json(policy_path)
    for policy in registry.get("policies") or []:
        if policy.get("id") == policy_id:
            return dict(policy)
    raise ValueError(f"trigger policy {policy_id!r} not found in {relative_or_absolute(policy_path)}")


def load_answer_set_model_registry(registry_path: Path, model_id: str) -> dict[str, Any]:
    registry = load_json(registry_path)
    for model_entry in registry.get("models") or []:
        if model_entry.get("modelId") == model_id:
            return dict(model_entry)
    raise ValueError(f"answer-set registry missing modelId {model_id!r} in {relative_or_absolute(registry_path)}")


def answer_form_matches(form: dict[str, Any], token_text: str, normalized_token_text: str) -> bool:
    form_token_text = form.get("tokenText")
    if isinstance(form_token_text, str) and token_text == form_token_text:
        return True
    return normalized_token_text == str(form.get("normalizedTokenText") or "").strip().lower()


def find_answer_option_entry(answer_option: dict[str, Any], candidate_entries: list[dict[str, Any]]) -> dict[str, Any] | None:
    forms = answer_option.get("forms") or []
    for entry in candidate_entries:
        for form in forms:
            if answer_form_matches(form, entry["tokenText"], entry["normalizedTokenText"]):
                return entry
    return None


def evaluate_trigger_policy(
    trigger_policy: dict[str, Any],
    candidate_logit_values: list[float],
) -> dict[str, Any]:
    if len(candidate_logit_values) < 2:
        raise ValueError("trigger policy evaluation requires at least two candidate logits")
    sorted_logits = sorted((float(value) for value in candidate_logit_values), reverse=True)
    top_logit = sorted_logits[0]
    runner_up = sorted_logits[1]
    if trigger_policy["mode"] == "exact-max-tie":
        ambiguous_count = sum(1 for value in sorted_logits if value == top_logit)
        return {
            "policyId": trigger_policy["id"],
            "mode": trigger_policy["mode"],
            "epsilon": trigger_policy["epsilon"],
            "candidateTopGap": top_logit - runner_up,
            "ambiguousCandidateCount": ambiguous_count,
            "wouldTrigger": ambiguous_count >= 2,
        }
    epsilon = float(trigger_policy["epsilon"])
    ambiguous_count = sum(1 for value in sorted_logits if (top_logit - value) <= epsilon)
    return {
        "policyId": trigger_policy["id"],
        "mode": trigger_policy["mode"],
        "epsilon": epsilon,
        "candidateTopGap": top_logit - runner_up,
        "ambiguousCandidateCount": ambiguous_count,
        "wouldTrigger": ambiguous_count >= 2,
    }


def build_stage_stability_requirements(
    *,
    scout_prompt_tokenization_stable: bool,
    scout_top_candidate_membership_stable: bool,
    promote_candidate_set_stable: bool,
    promote_digest_stable: bool,
) -> dict[str, Any]:
    return {
        "scout": {
            "requirementId": "scout-v1",
            "promptTokenizationStable": scout_prompt_tokenization_stable,
            "topCandidateMembershipStable": scout_top_candidate_membership_stable,
            "passed": scout_prompt_tokenization_stable and scout_top_candidate_membership_stable,
        },
        "promote": {
            "requirementId": "promote-v1",
            "candidateSetStable": promote_candidate_set_stable,
            "digestStable": promote_digest_stable,
            "passed": promote_candidate_set_stable and promote_digest_stable,
        },
        "claimableDemo": {
            "requirementId": "claimable-demo-v1",
            "finalTokenStable": None,
            "receiptReplayStable": None,
            "passed": None,
        },
    }


def compute_outsider_lead(top_candidates: list[dict[str, Any]], *, pair_tokens: set[int], pair_top_logit: float) -> float:
    outsider_logits = [float(entry["logit"]) for entry in top_candidates if int(entry["token"]) not in pair_tokens]
    if not outsider_logits:
        return 0.0
    return max(0.0, max(outsider_logits) - pair_top_logit)


def bounded_score(value: float, *, ceiling: float) -> float:
    if ceiling <= 0.0:
        return 0.0
    return max(0.0, 1.0 - min(value, ceiling) / ceiling)


def compute_usefulness_score(
    *,
    pair_gap: float,
    pair_lead_from_top: float,
    outsider_lead: float,
    prompt_anchor_count: int,
    bounded_answer_prompt: bool,
    source_byte_stable: bool,
    source_greedy_stable: bool,
    policy: dict[str, Any],
) -> float:
    score = 0.0
    score += bounded_score(pair_gap, ceiling=float(policy["maxPairGapForScore"])) * float(policy["pairGapWeight"])
    score += bounded_score(pair_lead_from_top, ceiling=float(policy["maxPairLeadForScore"])) * float(policy["pairLeadWeight"])
    score += bounded_score(outsider_lead, ceiling=float(policy["maxOutsiderLeadForScore"])) * float(policy["outsiderLeadWeight"])
    score += min(float(prompt_anchor_count), 2.0) * float(policy["promptAnchorWeight"])
    if bounded_answer_prompt:
        score += float(policy["boundedAnswerPromptWeight"])
    if source_byte_stable:
        score += float(policy["sourceByteStableWeight"])
    if source_greedy_stable:
        score += float(policy["sourceGreedyStableWeight"])
    return round(score, 6)


def pair_case_sort_key(case: dict[str, Any]) -> tuple[float, float, float, str, int]:
    return (
        -float(case["usefulnessScore"]),
        float(case["pairGap"]),
        float(case["outsiderLead"]),
        str(case["promptId"]),
        int(case["stepIndex"]),
    )


def semantic_match_sort_key(match: dict[str, Any]) -> tuple[float, float, float, int, int]:
    usefulness = match.get("usefulnessScore")
    usefulness_value = -math.inf if usefulness is None else float(usefulness)
    return (
        -usefulness_value,
        float(match["pairGap"]),
        float(match.get("pairLeadFromTop", 0.0)),
        int(match["leftRank"]),
        int(match["rightRank"]),
    )
