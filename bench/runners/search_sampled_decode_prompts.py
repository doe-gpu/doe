#!/usr/bin/env python3
"""Search semantically sharp prompts for sampled decode fragility using mutation rounds."""

from __future__ import annotations

import argparse
import copy
import re
from pathlib import Path
from typing import Any


REPO_ROOT = Path(__file__).resolve().parents[2]
BENCH_ROOT = REPO_ROOT / "bench"
for _path_entry in (str(REPO_ROOT), str(BENCH_ROOT)):
    if _path_entry not in __import__("sys").path:
        __import__("sys").path.insert(0, _path_entry)

from bench.lib.config_validation import load_validated_config
from bench.lib.bench_utils import load_json
from bench.lib.sampled_decode_fragility import write_json
from bench.runners.determinism_search_helpers import normalize_prompt_text
from bench.runners.determinism_search_helpers import relative_or_absolute
from bench.runners.determinism_search_helpers import resolve_repo_path
from bench.runners.determinism_search_helpers import timestamp_label
from bench.runners.run_pair_agnostic_pair_miner import build_report as build_pair_mining_report
from bench.runners.run_real_logit_hunt import build_helper_config
from bench.runners.run_real_logit_hunt import build_summary
from bench.runners.run_real_logit_hunt import run_helper
from bench.runners.run_semantic_pair_mutation_search import build_prompt_candidates
from bench.runners.run_semantic_pair_mutation_search import sanitize_id


DEFAULT_PLAN_PATH = REPO_ROOT / "config" / "numeric-stability-decode-prompt-search-plan.json"
DEFAULT_OUTPUT_ROOT = REPO_ROOT / "bench" / "out" / "apple-metal-sampled-decode-prompt-search"
PLAN_SCHEMA_PATH = REPO_ROOT / "config" / "numeric-stability-decode-prompt-search-plan.schema.json"
ARTIFACT_KIND = "sampled-decode-prompt-search"
REAL_LOGIT_REPORT_FILE = "real-logit-hunt.json"
PAIR_MINING_REPORT_FILE = "pair-mining.json"
ROUND_FIXTURE_FILE = "prompt-candidates.fixture.json"
SEARCH_REPORT_FILE = "sampled_decode_prompt_search.report.json"

STRUCTURED_CHOICE_PATTERNS: tuple[re.Pattern[str], ...] = (
    re.compile(
        r"^Answer with exactly one word: (?P<choice>.+?)\. Question: (?P<question>.+?) Answer:$",
        re.IGNORECASE,
    ),
    re.compile(
        r"^Choose exactly one word: (?P<choice>.+?)\. Question: (?P<question>.+?) Answer:$",
        re.IGNORECASE,
    ),
    re.compile(
        r"^Reply with exactly one word: (?P<choice>.+?)\. Question: (?P<question>.+?) Answer:$",
        re.IGNORECASE,
    ),
    re.compile(
        r"^One-word answer only \((?P<choice>.+?)\)\. Question: (?P<question>.+?) Answer:$",
        re.IGNORECASE,
    ),
    re.compile(
        r"^Question: (?P<question>.+?) Answer with exactly one word: (?P<choice>.+?)\. Answer:$",
        re.IGNORECASE,
    ),
    re.compile(
        r"^Given the scenario, answer with exactly one word: (?P<choice>.+?)\. Scenario: (?P<question>.+?) Answer:$",
        re.IGNORECASE,
    ),
    re.compile(
        r"^(?P<choice>.+?)\s*:\s*(?P<question>.+?)$",
        re.IGNORECASE,
    ),
    re.compile(
        r"^Output only (?P<choice>.+?)\. (?P<question>.+?)$",
        re.IGNORECASE,
    ),
)

CHOICE_SLASH_RE = re.compile(r"\s*/\s*")
CHOICE_OR_RE = re.compile(r"\s*,?\s+or\s+", re.IGNORECASE)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--plan", default=str(DEFAULT_PLAN_PATH), help="Prompt search plan JSON.")
    parser.add_argument("--timestamp", default=None, help="UTC timestamp label.")
    parser.add_argument("--output-root", default=str(DEFAULT_OUTPUT_ROOT), help="Output root.")
    return parser.parse_args()


def collapse_whitespace(text: str) -> str:
    return " ".join(str(text).split())


def extract_choice_options(choice: str) -> list[str] | None:
    normalized = collapse_whitespace(choice).strip(" .")
    if not normalized:
        return None
    if "/" in normalized:
        parts = [part.strip(" .") for part in CHOICE_SLASH_RE.split(normalized)]
    else:
        comma_normalized = CHOICE_OR_RE.sub(", ", normalized)
        parts = [part.strip(" .") for part in comma_normalized.split(",")]
    options = [part for part in parts if part]
    if len(options) < 2:
        return None
    deduped: list[str] = []
    for option in options:
        if option not in deduped:
            deduped.append(option)
    if len(deduped) < 2:
        return None
    return deduped


def render_choice_options(options: list[str]) -> str:
    if len(options) == 2:
        return f"{options[0]} or {options[1]}"
    if len(options) == 3:
        return f"{options[0]}, {options[1]}, or {options[2]}"
    return ", ".join(options[:-1]) + f", or {options[-1]}"


def extract_structured_choice_parts(prompt_text: str) -> dict[str, str] | None:
    normalized = collapse_whitespace(prompt_text)
    for pattern in STRUCTURED_CHOICE_PATTERNS:
        match = pattern.fullmatch(normalized)
        if match is None:
            continue
        choice_options = extract_choice_options(match.group("choice"))
        if choice_options is None:
            continue
        question = collapse_whitespace(match.group("question"))
        if not question:
            continue
        return {
            "choice": render_choice_options(choice_options),
            "question": question,
        }
    return None


def render_structured_choice_prompt(
    case: dict[str, Any],
    *,
    style: str,
    reverse_options: bool,
) -> str | None:
    parts = extract_structured_choice_parts(str(case["promptText"]))
    if parts is None:
        return None
    choice_options = extract_choice_options(parts["choice"])
    if choice_options is None:
        return None
    if reverse_options:
        choice_options = list(reversed(choice_options))
    choice = render_choice_options(choice_options)
    question = parts["question"]
    if style == "answer-question":
        return f"Answer with exactly one word: {choice}. Question: {question} Answer:"
    if style == "choose-question":
        return f"Choose exactly one word: {choice}. Question: {question} Answer:"
    if style == "reply-question":
        return f"Reply with exactly one word: {choice}. Question: {question} Answer:"
    if style == "parenthetical-question":
        return f"One-word answer only ({choice}). Question: {question} Answer:"
    if style == "question-answer":
        return f"Question: {question} Answer with exactly one word: {choice}. Answer:"
    if style == "scenario-answer":
        return f"Given the scenario, answer with exactly one word: {choice}. Scenario: {question} Answer:"
    if style == "inline-colon":
        return f"{choice}: {question}"
    if style == "output-only":
        return f"Output only {choice}. {question}"
    raise ValueError(f"unsupported structured-choice style: {style}")


def sanitize_prompt_candidates(prompt_candidates: list[dict[str, Any]]) -> list[dict[str, str]]:
    sanitized: list[dict[str, str]] = []
    for candidate in prompt_candidates:
        prompt_id = sanitize_id(str(candidate["id"]))
        prompt_text = str(candidate["text"]).strip()
        if not prompt_id or not prompt_text:
            continue
        sanitized.append({"id": prompt_id, "text": prompt_text})
    return sanitized


def dedupe_prompt_candidates(
    prompt_candidates: list[dict[str, Any]],
    *,
    seen_prompt_texts: set[str],
    limit: int,
) -> list[dict[str, str]]:
    deduped: list[dict[str, str]] = []
    local_seen: set[str] = set()
    used_ids: set[str] = set()
    for candidate in sanitize_prompt_candidates(prompt_candidates):
        normalized = normalize_prompt_text(candidate["text"])
        if not normalized or normalized in seen_prompt_texts or normalized in local_seen:
            continue
        prompt_id = candidate["id"]
        if prompt_id in used_ids:
            suffix = 2
            while f"{prompt_id}-{suffix}" in used_ids:
                suffix += 1
            prompt_id = f"{prompt_id}-{suffix}"
        used_ids.add(prompt_id)
        local_seen.add(normalized)
        deduped.append({"id": prompt_id, "text": candidate["text"]})
        if len(deduped) >= limit:
            break
    return deduped


def initial_prompt_candidates(plan: dict[str, Any], source_fixture: dict[str, Any]) -> list[dict[str, str]]:
    initial = plan.get("initialPromptCandidates") or source_fixture["promptCandidates"]
    return dedupe_prompt_candidates(
        list(initial),
        seen_prompt_texts=set(),
        limit=int(plan["maxPromptCandidatesPerRound"]),
    )


def build_round_fixture(
    source_fixture: dict[str, Any],
    *,
    scenario_id: str,
    prompt_candidates: list[dict[str, str]],
    repeat_count: int | None,
) -> dict[str, Any]:
    fixture = copy.deepcopy(source_fixture)
    fixture["scenarioId"] = scenario_id
    fixture["promptCandidates"] = list(prompt_candidates)
    if repeat_count is not None:
        fixture["defaultRepeatCount"] = int(repeat_count)
    return fixture


def write_real_logit_report(
    *,
    round_dir: Path,
    fixture_path: Path,
    scenario_id: str,
    timestamp: str,
    persist_logits: bool,
    harvest: dict[str, Any],
    top_candidates_to_keep: int,
) -> Path:
    report = {
        "schemaVersion": 1,
        "source": "doe-real-logit-hunt",
        "scenarioId": scenario_id,
        "fixturePath": relative_or_absolute(fixture_path),
        "timestamp": timestamp,
        "persistLogits": persist_logits,
        "harvest": harvest,
        "summary": build_summary(harvest, top_candidates=top_candidates_to_keep),
    }
    report_path = round_dir / REAL_LOGIT_REPORT_FILE
    write_json(report_path, report)
    return report_path


def select_source_cases(
    pair_report: dict[str, Any],
    *,
    beam_width: int,
    minimum_usefulness_score: float,
) -> list[dict[str, Any]]:
    selected: list[dict[str, Any]] = []
    for case in pair_report.get("cases") or []:
        usefulness = float(case.get("usefulnessScore") or 0.0)
        if usefulness < minimum_usefulness_score:
            continue
        selected.append(case)
        if len(selected) >= beam_width:
            break
    return selected


def build_next_round_prompt_candidates(
    source_cases: list[dict[str, Any]],
    *,
    mutation_templates: list[dict[str, Any]],
    seen_prompt_texts: set[str],
    limit: int,
) -> list[dict[str, str]]:
    generic_templates = [template for template in mutation_templates if template.get("kind") != "structured-choice"]
    prompt_candidates: list[dict[str, Any]] = []
    if generic_templates:
        prompt_candidates, _ = build_prompt_candidates(source_cases, templates=generic_templates)
    for case in source_cases:
        pair_id = case.get("pairId") or case.get("candidatePairId")
        for template in mutation_templates:
            if template.get("kind") != "structured-choice":
                continue
            mutated_text = render_structured_choice_prompt(
                case,
                style=str(template["style"]),
                reverse_options=bool(template.get("reverseOptions", False)),
            )
            if not mutated_text or mutated_text == case["promptText"]:
                continue
            prompt_candidates.append(
                {
                    "id": sanitize_id(f"{case['promptId']}--{pair_id}--{template['id']}"),
                    "text": mutated_text,
                }
            )
    return dedupe_prompt_candidates(
        prompt_candidates,
        seen_prompt_texts=seen_prompt_texts,
        limit=limit,
    )


def run_search(
    plan: dict[str, Any],
    *,
    plan_path: Path,
    output_dir: Path,
    timestamp: str,
    run_helper_fn=run_helper,
    pair_report_builder=build_pair_mining_report,
) -> dict[str, Any]:
    source_fixture_path = resolve_repo_path(str(plan["sourceFixturePath"]))
    pair_fixture_path = resolve_repo_path(str(plan["pairMiningFixturePath"]))
    source_fixture = load_json(source_fixture_path)
    pair_fixture = load_json(pair_fixture_path)

    current_prompt_candidates = initial_prompt_candidates(plan, source_fixture)
    seen_prompt_texts = {normalize_prompt_text(candidate["text"]) for candidate in current_prompt_candidates}
    round_reports: list[dict[str, Any]] = []
    all_cases: list[dict[str, Any]] = []

    for round_index in range(int(plan["rounds"])):
        if not current_prompt_candidates:
            break
        round_label = f"round-{round_index + 1:02d}"
        round_dir = output_dir / round_label
        round_dir.mkdir(parents=True, exist_ok=True)
        scenario_id = f"{source_fixture['scenarioId']}--{round_label}"
        round_fixture = build_round_fixture(
            source_fixture,
            scenario_id=scenario_id,
            prompt_candidates=current_prompt_candidates,
            repeat_count=plan.get("repeatCount"),
        )
        round_fixture_path = round_dir / ROUND_FIXTURE_FILE
        write_json(round_fixture_path, round_fixture)

        helper_config = build_helper_config(
            round_fixture,
            output_dir=round_dir / "harvest",
            repeat_count=int(round_fixture["defaultRepeatCount"]),
            persist_logits=bool(plan["persistLogits"]),
        )
        harvest = run_helper_fn(helper_config, work_dir=round_dir)
        real_logit_report_path = write_real_logit_report(
            round_dir=round_dir,
            fixture_path=round_fixture_path,
            scenario_id=scenario_id,
            timestamp=timestamp,
            persist_logits=bool(plan["persistLogits"]),
            harvest=harvest,
            top_candidates_to_keep=int(plan["topCandidatesToKeep"]),
        )
        pair_report = pair_report_builder(
            pair_fixture,
            source_report_paths=[real_logit_report_path],
            per_prompt_limit=int(plan["perPromptLimit"]),
            global_limit=int(plan["globalLimit"]),
        )
        pair_report_path = round_dir / PAIR_MINING_REPORT_FILE
        write_json(pair_report_path, pair_report)
        round_cases = list(pair_report.get("cases") or [])
        all_cases.extend(round_cases)

        source_cases = select_source_cases(
            pair_report,
            beam_width=int(plan["beamWidth"]),
            minimum_usefulness_score=float(plan.get("minimumUsefulnessScore") or 0.0),
        )
        next_prompt_candidates = build_next_round_prompt_candidates(
            source_cases,
            mutation_templates=list(plan["mutationTemplates"]),
            seen_prompt_texts=seen_prompt_texts,
            limit=int(plan["maxPromptCandidatesPerRound"]),
        )
        seen_prompt_texts.update(normalize_prompt_text(candidate["text"]) for candidate in next_prompt_candidates)

        round_reports.append(
            {
                "roundIndex": round_index + 1,
                "roundLabel": round_label,
                "fixturePath": relative_or_absolute(round_fixture_path),
                "realLogitReportPath": relative_or_absolute(real_logit_report_path),
                "pairMiningReportPath": relative_or_absolute(pair_report_path),
                "promptCandidateCount": len(current_prompt_candidates),
                "minedCaseCount": len(round_cases),
                "sourceCaseCount": len(source_cases),
                "topCases": round_cases[: min(len(round_cases), int(plan["beamWidth"]))],
                "nextPromptCandidates": next_prompt_candidates,
            }
        )
        current_prompt_candidates = next_prompt_candidates

    all_cases.sort(key=lambda case: (-float(case.get("usefulnessScore") or 0.0), str(case.get("promptId") or "")))
    summary = {
        "executedRoundCount": len(round_reports),
        "bestCaseCount": min(len(all_cases), int(plan["topCandidatesToKeep"])),
        "bestCases": all_cases[: min(len(all_cases), int(plan["topCandidatesToKeep"]))],
        "finalPromptCandidateCount": len(current_prompt_candidates),
        "finalPromptCandidates": current_prompt_candidates,
    }
    return {
        "schemaVersion": 1,
        "artifactKind": ARTIFACT_KIND,
        "timestamp": timestamp,
        "planPath": relative_or_absolute(plan_path),
        "sourceFixturePath": relative_or_absolute(source_fixture_path),
        "pairMiningFixturePath": relative_or_absolute(pair_fixture_path),
        "rounds": round_reports,
        "summary": summary,
    }


def main() -> None:
    args = parse_args()
    plan_path = Path(args.plan)
    plan = load_validated_config(plan_path, PLAN_SCHEMA_PATH)
    timestamp = timestamp_label(args.timestamp)
    output_dir = Path(args.output_root) / timestamp
    output_dir.mkdir(parents=True, exist_ok=True)
    report = run_search(
        plan,
        plan_path=plan_path,
        output_dir=output_dir,
        timestamp=timestamp,
    )
    report_path = output_dir / SEARCH_REPORT_FILE
    write_json(report_path, report)
    print(str(report_path))


if __name__ == "__main__":
    main()
