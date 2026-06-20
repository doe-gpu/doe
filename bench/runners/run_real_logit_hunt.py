#!/usr/bin/env python3
"""Harvest real Doppler logits and rank low-margin greedy candidates for Doe determinism work."""

from __future__ import annotations

import argparse
import collections
import copy
import datetime as dt
import json
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any


REPO_ROOT = Path(__file__).resolve().parents[2]
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from bench.lib.bench_utils import load_json

DEFAULT_FIXTURE = REPO_ROOT / "bench" / "fixtures" / "determinism" / "apple-metal-real-logit-hunt.gemma270m.json"
DEFAULT_OUTPUT_ROOT = REPO_ROOT / "bench" / "out" / "apple-metal-real-logit-hunt"
HELPER_SCRIPT = REPO_ROOT / "bench" / "executors" / "harvest-doppler-browser-logits.js"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fixture", default=str(DEFAULT_FIXTURE), help="Real-logit hunt fixture JSON.")
    parser.add_argument("--runs", type=int, default=None, help="Override repeat count from the fixture.")
    parser.add_argument("--timestamp", default=None, help="UTC timestamp label (default: current UTC time).")
    parser.add_argument("--output-root", default=str(DEFAULT_OUTPUT_ROOT), help="Output root for hunt artifacts.")
    parser.add_argument("--persist-logits", action="store_true", help="Persist harvested logits .bin artifacts.")
    parser.add_argument("--top-candidates", type=int, default=10, help="Number of ranked candidates to keep in the summary.")
    return parser.parse_args()


def resolve_repo_path(raw: str) -> Path:
    path = Path(raw)
    if path.is_absolute():
        return path
    return REPO_ROOT / path


def timestamp_label(raw: str | None) -> str:
    if raw:
        return raw
    return dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")


def ensure_fixture_shape(fixture: dict[str, Any]) -> None:
    required = [
        "scenarioId",
        "dopplerRepoPath",
        "modelArtifactPath",
        "modelId",
        "promptCandidates",
        "defaultRepeatCount",
    ]
    missing = [field for field in required if field not in fixture]
    if missing:
        raise ValueError(f"fixture missing required fields: {', '.join(missing)}")
    if not isinstance(fixture["promptCandidates"], list) or not fixture["promptCandidates"]:
        raise ValueError("fixture must define at least one prompt candidate")


def build_step_label(step: dict[str, Any]) -> str:
    if step["phase"] == "prefill":
        return "prefill"
    return f"decode[{step['stepIndex']}]"


def step_group_key(prompt: dict[str, Any], step: dict[str, Any]) -> tuple[Any, ...]:
    return (
        prompt.get("id") or f"prompt-{prompt['promptIndex']:03d}",
        prompt["promptIndex"],
        prompt["text"],
        step["phase"],
        step["stepIndex"],
    )


def tier_priority(summary: dict[str, Any]) -> int:
    if summary["greedyTokenFlipObserved"]:
        return 0
    if summary["exactMaxTieObserved"]:
        return 1
    if summary["byteDriftObserved"]:
        return 2
    return 3


def candidate_tier(summary: dict[str, Any]) -> str:
    if summary["greedyTokenFlipObserved"]:
        return "greedy_flip"
    if summary["exactMaxTieObserved"]:
        return "exact_max_tie"
    if summary["byteDriftObserved"]:
        return "byte_drift"
    return "near_tie"


def gather_candidate_groups(harvest: dict[str, Any]) -> dict[tuple[Any, ...], list[dict[str, Any]]]:
    groups: dict[tuple[Any, ...], list[dict[str, Any]]] = collections.defaultdict(list)
    for run in harvest.get("runs", []):
        repeat_index = run["repeatIndex"]
        for prompt in run.get("promptResults", []):
            if prompt.get("status") != "ok":
                continue
            for step in prompt.get("steps", []):
                entry = {
                    "repeatIndex": repeat_index,
                    "promptId": prompt.get("id"),
                    "promptIndex": prompt["promptIndex"],
                    "promptText": prompt["text"],
                    "phase": step["phase"],
                    "stepIndex": step["stepIndex"],
                    "stepLabel": build_step_label(step),
                    "greedyToken": step["greedyToken"],
                    "greedyLogit": step["greedyLogit"],
                    "top2Gap": step.get("top2Gap"),
                    "exactMaxTieCount": step.get("exactMaxTieCount", 0),
                    "logitsSha256": step["logitsSha256"],
                    "logitsArtifactPath": step.get("logitsArtifactPath"),
                    "topCandidates": copy.deepcopy(step.get("topCandidates") or []),
                    "inputToken": step.get("inputToken"),
                    "currentIdsLength": step.get("currentIdsLength"),
                    "promptTokenCount": step.get("promptTokenCount"),
                    "promptTokenIds": list(prompt.get("promptTokenIds") or []),
                    "topCandidateTokenMembership": sorted(int(candidate["token"]) for candidate in (step.get("topCandidates") or [])),
                }
                groups[step_group_key(prompt, step)].append(entry)
    return groups


def summarize_candidate_group(group_key: tuple[Any, ...], entries: list[dict[str, Any]]) -> dict[str, Any]:
    prompt_id, prompt_index, prompt_text, phase, step_index = group_key
    gaps = [entry["top2Gap"] for entry in entries if entry["top2Gap"] is not None]
    greedy_tokens = [entry["greedyToken"] for entry in entries]
    input_tokens = [entry["inputToken"] for entry in entries if entry["inputToken"] is not None]
    digests = [entry["logitsSha256"] for entry in entries]
    prompt_token_sequences = [tuple(entry.get("promptTokenIds") or []) for entry in entries]
    top_candidate_memberships = [
        tuple(
            entry.get("topCandidateTokenMembership")
            or sorted(int(candidate["token"]) for candidate in (entry.get("topCandidates") or []))
        )
        for entry in entries
    ]
    dominant_digest, dominant_digest_count = collections.Counter(digests).most_common(1)[0]
    dominant_token, dominant_token_count = collections.Counter(greedy_tokens).most_common(1)[0]
    summary = {
        "promptId": prompt_id,
        "promptIndex": prompt_index,
        "promptText": prompt_text,
        "phase": phase,
        "stepIndex": step_index,
        "stepLabel": entries[0]["stepLabel"],
        "repeatCount": len(entries),
        "minTop2Gap": min(gaps) if gaps else None,
        "maxTop2Gap": max(gaps) if gaps else None,
        "meanTop2Gap": (sum(gaps) / len(gaps)) if gaps else None,
        "exactMaxTieObserved": any(entry["exactMaxTieCount"] > 1 for entry in entries),
        "maxExactTieCount": max((entry["exactMaxTieCount"] for entry in entries), default=0),
        "greedyTokenValues": sorted(set(greedy_tokens)),
        "uniqueGreedyTokenCount": len(set(greedy_tokens)),
        "dominantGreedyToken": dominant_token,
        "dominantGreedyTokenRate": dominant_token_count / len(greedy_tokens),
        "greedyTokenFlipObserved": len(set(greedy_tokens)) > 1,
        "logitsDigestValues": sorted(set(digests)),
        "uniqueDigestCount": len(set(digests)),
        "dominantLogitsDigest": dominant_digest,
        "dominantLogitsDigestRate": dominant_digest_count / len(digests),
        "byteDriftObserved": len(set(digests)) > 1,
        "promptTokenizationStable": len(set(prompt_token_sequences)) == 1,
        "topCandidateMembershipStable": len(set(top_candidate_memberships)) == 1,
        "inputTokenValues": sorted(set(input_tokens)),
        "contextTokenFlipObserved": len(set(input_tokens)) > 1 if input_tokens else False,
        "stabilityContracts": {
            "scout": {
                "requirementId": "scout-v1",
                "promptTokenizationStable": len(set(prompt_token_sequences)) == 1,
                "topCandidateMembershipStable": len(set(top_candidate_memberships)) == 1,
                "passed": len(set(prompt_token_sequences)) == 1 and len(set(top_candidate_memberships)) == 1,
            }
        },
        "artifacts": [
            {
                "repeatIndex": entry["repeatIndex"],
                "logitsSha256": entry["logitsSha256"],
                "logitsArtifactPath": entry.get("logitsArtifactPath"),
                "greedyToken": entry["greedyToken"],
                "top2Gap": entry["top2Gap"],
                "topCandidates": entry["topCandidates"],
                "inputToken": entry["inputToken"],
                "promptTokenIds": list(entry.get("promptTokenIds") or []),
            }
            for entry in entries
        ],
    }
    summary["candidateTier"] = candidate_tier(summary)
    return summary


def rank_candidates(candidates: list[dict[str, Any]]) -> list[dict[str, Any]]:
    return sorted(
        candidates,
        key=lambda summary: (
            tier_priority(summary),
            float("inf") if summary["minTop2Gap"] is None else summary["minTop2Gap"],
            summary["promptIndex"],
            summary["stepIndex"],
        ),
    )


def build_summary(harvest: dict[str, Any], *, top_candidates: int) -> dict[str, Any]:
    groups = gather_candidate_groups(harvest)
    candidates = [summarize_candidate_group(group_key, entries) for group_key, entries in groups.items()]
    ranked = rank_candidates(candidates)
    tier_counts = collections.Counter(candidate["candidateTier"] for candidate in ranked)
    return {
        "promptCount": len({candidate["promptId"] for candidate in ranked}),
        "stepCandidateCount": len(ranked),
        "tierCounts": dict(tier_counts),
        "topCandidates": ranked[:top_candidates],
        "allCandidates": ranked,
    }


def build_helper_config(
    fixture: dict[str, Any],
    *,
    output_dir: Path,
    repeat_count: int,
    persist_logits: bool,
) -> dict[str, Any]:
    return {
        "scenarioId": fixture["scenarioId"],
        "dopplerRepoPath": str(resolve_repo_path(fixture["dopplerRepoPath"])),
        "modelArtifactPath": str(resolve_repo_path(fixture["modelArtifactPath"])),
        "modelId": fixture["modelId"],
        "outputDir": str(output_dir),
        "repeatCount": repeat_count,
        "decodeSteps": fixture.get("decodeSteps", 1),
        "topK": fixture.get("topK", 5),
        "persistLogits": persist_logits,
        "capturePrefillEmbedding": fixture.get("capturePrefillEmbedding", False),
        "prefillEmbeddingMode": fixture.get("prefillEmbeddingMode", "last"),
        "useChatTemplate": fixture.get("useChatTemplate", False),
        "runtimeConfig": copy.deepcopy(fixture.get("runtimeConfig") or {}),
        "browser": copy.deepcopy(fixture.get("browser") or {}),
        "promptCandidates": copy.deepcopy(fixture["promptCandidates"]),
    }


def run_helper(config: dict[str, Any], *, work_dir: Path) -> dict[str, Any]:
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False, encoding="utf-8", dir=work_dir) as handle:
        json.dump(config, handle, indent=2)
        handle.write("\n")
        config_path = Path(handle.name)
    try:
        completed = subprocess.run(
            ["node", str(HELPER_SCRIPT), "--config", str(config_path)],
            cwd=REPO_ROOT,
            check=False,
            capture_output=True,
            text=True,
        )
    finally:
        config_path.unlink(missing_ok=True)
    if completed.returncode != 0:
        raise RuntimeError(
            "real-logit helper failed\n"
            f"stdout:\n{completed.stdout}\n"
            f"stderr:\n{completed.stderr}"
        )
    return json.loads(completed.stdout)


def main() -> int:
    args = parse_args()
    fixture_path = resolve_repo_path(args.fixture)
    fixture = load_json(fixture_path)
    ensure_fixture_shape(fixture)
    repeat_count = args.runs or int(fixture["defaultRepeatCount"])
    output_root = resolve_repo_path(args.output_root)
    stamp = timestamp_label(args.timestamp)
    output_dir = output_root / stamp
    output_dir.mkdir(parents=True, exist_ok=True)
    helper_config = build_helper_config(
        fixture,
        output_dir=output_dir,
        repeat_count=repeat_count,
        persist_logits=args.persist_logits,
    )
    harvest = run_helper(helper_config, work_dir=output_dir)
    summary = build_summary(harvest, top_candidates=args.top_candidates)
    report = {
        "schemaVersion": 1,
        "source": "doe-real-logit-hunt",
        "scenarioId": fixture["scenarioId"],
        "fixturePath": relative_or_absolute(fixture_path),
        "timestamp": stamp,
        "persistLogits": args.persist_logits,
        "harvest": harvest,
        "summary": summary,
    }
    report_path = output_dir / f"{fixture['scenarioId']}.real-logit-hunt.json"
    report_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"reportPath": relative_or_absolute(report_path), "topCandidates": summary["topCandidates"]}, indent=2))
    return 0


def relative_or_absolute(path: Path) -> str:
    absolute = path.resolve()
    try:
        return str(absolute.relative_to(REPO_ROOT.resolve()))
    except ValueError:
        return str(absolute)


if __name__ == "__main__":
    sys.exit(main())
