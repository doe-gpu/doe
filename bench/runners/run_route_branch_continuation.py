#!/usr/bin/env python3
"""Branch real prompt continuations from raw/stable-token/stable-choice/reviewed-choice route tokens."""

from __future__ import annotations

import argparse
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
from bench.runners.run_real_logit_hunt import resolve_repo_path
from bench.runners.run_sample_only_tie_break_probe import ensure_fixture_shape
from bench.runners.run_sample_only_tie_break_probe import load_f32_logits
from bench.runners.run_sample_only_tie_break_probe import resolve_choice_candidates
from bench.runners.run_sample_only_tie_break_probe import resolve_choice_trigger
from bench.runners.run_sample_only_tie_break_probe import resolve_reviewed_decision
from bench.runners.run_semantic_pair_hunt import build_state_index

DEFAULT_OUTPUT_ROOT = REPO_ROOT / "bench" / "out" / "apple-metal-route-branch-continuation"
DEFAULT_TOP_K = 8
DOE_STABLE_TOKEN_EXECUTOR = REPO_ROOT / "bench" / "executors" / "run-doe-stable-token.js"
DOE_STABLE_CHOICE_EXECUTOR = REPO_ROOT / "bench" / "executors" / "run-doe-stable-choice.js"
DOE_REVIEWED_CHOICE_EXECUTOR = REPO_ROOT / "bench" / "executors" / "run-doe-reviewed-choice.js"
HELPER_SCRIPT = REPO_ROOT / "bench" / "executors" / "harvest-doppler-browser-route-branches.js"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fixture", required=True, help="Sample-only determinism fixture JSON.")
    parser.add_argument("--source-report", required=True, help="Real-logit hunt report JSON.")
    parser.add_argument("--prompt-id", required=True, help="Prompt id to branch from.")
    parser.add_argument("--phase", default="prefill", help="Source phase (default: prefill).")
    parser.add_argument("--step-index", type=int, default=0, help="Source step index (default: 0).")
    parser.add_argument("--continuation-steps", type=int, default=6, help="How many decode steps to take after the branch token.")
    parser.add_argument("--runs", type=int, default=3, help="Repeated route-continuation runs.")
    parser.add_argument("--top-k", type=int, default=DEFAULT_TOP_K, help="Per-step topK to keep in route reports.")
    parser.add_argument("--timestamp", default=None, help="UTC timestamp label (default: current UTC time).")
    parser.add_argument("--output-root", default=str(DEFAULT_OUTPUT_ROOT), help="Output root for route artifacts.")
    return parser.parse_args()


def timestamp_label(raw: str | None) -> str:
    if raw:
        return raw
    return dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")


def relative_or_absolute(path: Path) -> str:
    absolute = path.resolve()
    try:
        return str(absolute.relative_to(REPO_ROOT.resolve()))
    except ValueError:
        return str(absolute)


def sanitize_id(value: str) -> str:
    cleaned = "".join(ch if ch.isalnum() or ch in "-_" else "-" for ch in value.strip())
    return cleaned.strip("-") or "case"


def build_case_index(report: dict[str, Any]) -> dict[tuple[str, str, int], dict[str, Any]]:
    indexed: dict[tuple[str, str, int], dict[str, Any]] = {}
    for candidate in report.get("summary", {}).get("allCandidates") or []:
        indexed[(candidate["promptId"], candidate["phase"], int(candidate["stepIndex"]))] = candidate
    return indexed


def dominant_value(values: list[Any]) -> Any:
    counts: dict[Any, int] = {}
    for value in values:
        counts[value] = counts.get(value, 0) + 1
    return max(counts.items(), key=lambda item: item[1])[0]


def dominant_route_result(route_runs: list[dict[str, Any]]) -> dict[str, Any]:
    by_tail: dict[tuple[int, ...], dict[str, Any]] = {}
    counts: dict[tuple[int, ...], int] = {}
    for route_run in route_runs:
        key = tuple(route_run["continuationTokenIds"])
        by_tail[key] = route_run
        counts[key] = counts.get(key, 0) + 1
    best_key = max(counts.items(), key=lambda item: item[1])[0]
    return by_tail[best_key]


def find_top_candidate_by_token(
    top_candidates: list[dict[str, Any]],
    *,
    token: int,
) -> dict[str, Any]:
    for candidate in top_candidates:
        if int(candidate.get("token", -1)) == int(token):
            return candidate
    return {"token": int(token), "tokenText": None}


def compare_token_sequences(left: list[int], right: list[int]) -> int | None:
    for index, (left_token, right_token) in enumerate(zip(left, right)):
        if left_token != right_token:
            return index
    if len(left) != len(right):
        return min(len(left), len(right))
    return None


def find_source_case(
    report: dict[str, Any],
    *,
    prompt_id: str,
    phase: str,
    step_index: int,
) -> dict[str, Any]:
    case_index = build_case_index(report)
    case_entry = case_index.get((prompt_id, phase, step_index))
    if case_entry is None:
        raise SystemExit(f"source report does not contain {prompt_id} phase={phase} stepIndex={step_index}")
    return case_entry


def find_state_recipe(
    report: dict[str, Any],
    *,
    prompt_id: str,
    phase: str,
    step_index: int,
) -> dict[str, Any]:
    state_index = build_state_index(report)
    recipe = state_index.get((prompt_id, phase, step_index))
    if recipe is None:
        raise SystemExit(f"source report does not contain replayable state for {prompt_id} phase={phase} stepIndex={step_index}")
    return recipe


def run_doe_route_executor(
    *,
    executor_path: Path,
    config: dict[str, Any],
    work_dir: Path,
) -> dict[str, Any]:
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False, encoding="utf-8", dir=work_dir) as handle:
        json.dump(config, handle, indent=2)
        handle.write("\n")
        config_path = Path(handle.name)
    try:
        completed = subprocess.run(
            ["node", str(executor_path), "--config", str(config_path)],
            cwd=REPO_ROOT,
            check=False,
            capture_output=True,
            text=True,
        )
    finally:
        config_path.unlink(missing_ok=True)
    if completed.returncode != 0:
        raise RuntimeError(
            f"{executor_path.name} failed\nstdout:\n{completed.stdout}\n\nstderr:\n{completed.stderr}"
        )
    output = json.loads(completed.stdout)
    report_path = resolve_repo_path(output["outputPath"])
    return load_json(report_path)


def build_doe_receipts(
    *,
    fixture: dict[str, Any],
    case_entry: dict[str, Any],
    logits_path: Path,
    output_dir: Path,
) -> dict[str, dict[str, Any]]:
    logits = load_f32_logits(logits_path)
    vocab_size = len(logits)

    stable_token_output = output_dir / "doe.stable-token.json"
    stable_token_trace = output_dir / "doe.stable-token.trace-meta.json"
    stable_token_report = run_doe_route_executor(
        executor_path=DOE_STABLE_TOKEN_EXECUTOR,
        config={
            "logitsPath": str(logits_path),
            "outputPath": str(stable_token_output),
            "traceMetaPath": str(stable_token_trace),
            "vocabSize": vocab_size,
            "mode": fixture["doeStableToken"]["mode"],
            "topCandidates": int(fixture["doeStableToken"]["topCandidates"]),
        },
        work_dir=output_dir,
    )

    receipts: dict[str, dict[str, Any]] = {
        "stable-token": stable_token_report["result"],
    }

    stable_choice_config = fixture.get("doeStableChoice")
    if stable_choice_config is not None:
        ambiguity_trigger, trigger_policy_id = resolve_choice_trigger(stable_choice_config)
        stable_choice_output = output_dir / "doe.stable-choice.json"
        stable_choice_trace = output_dir / "doe.stable-choice.trace-meta.json"
        stable_choice_report = run_doe_route_executor(
            executor_path=DOE_STABLE_CHOICE_EXECUTOR,
            config={
                "logitsPath": str(logits_path),
                "outputPath": str(stable_choice_output),
                "traceMetaPath": str(stable_choice_trace),
                "vocabSize": vocab_size,
                "mode": stable_choice_config["mode"],
                "topCandidates": int(stable_choice_config["topCandidates"]),
                "policyId": stable_choice_config.get("policyId"),
                "triggerPolicyId": trigger_policy_id,
                "candidateSetId": stable_choice_config.get("candidateSetId"),
                "candidateSetSource": stable_choice_config.get("candidateSetSource"),
                "candidates": resolve_choice_candidates(stable_choice_config, case_entry),
                "ambiguityTrigger": ambiguity_trigger,
            },
            work_dir=output_dir,
        )
        receipts["stable-choice"] = stable_choice_report["result"]

    reviewed_choice_config = fixture.get("doeReviewedChoice")
    if reviewed_choice_config is not None:
        ambiguity_trigger, trigger_policy_id = resolve_choice_trigger(reviewed_choice_config)
        reviewed_choice_output = output_dir / "doe.reviewed-choice.json"
        reviewed_choice_trace = output_dir / "doe.reviewed-choice.trace-meta.json"
        reviewed_choice_report = run_doe_route_executor(
            executor_path=DOE_REVIEWED_CHOICE_EXECUTOR,
            config={
                "logitsPath": str(logits_path),
                "outputPath": str(reviewed_choice_output),
                "traceMetaPath": str(reviewed_choice_trace),
                "vocabSize": vocab_size,
                "mode": reviewed_choice_config["mode"],
                "topCandidates": int(reviewed_choice_config["topCandidates"]),
                "reviewPolicyId": reviewed_choice_config.get("reviewPolicyId"),
                "triggerPolicyId": trigger_policy_id,
                "candidateSetId": reviewed_choice_config.get("candidateSetId"),
                "candidateSetSource": reviewed_choice_config.get("candidateSetSource"),
                "candidates": resolve_choice_candidates(reviewed_choice_config, case_entry),
                "ambiguityTrigger": ambiguity_trigger,
                "decision": resolve_reviewed_decision(reviewed_choice_config, case_entry),
            },
            work_dir=output_dir,
        )
        receipts["reviewed-choice"] = reviewed_choice_report["result"]

    return receipts


def build_helper_config(
    *,
    source_report: dict[str, Any],
    prompt_id: str,
    prompt_text: str,
    output_dir: Path,
    continuation_steps: int,
    repeat_count: int,
    top_k: int,
    seed_current_ids: list[int],
    route_specs: list[dict[str, Any]],
) -> dict[str, Any]:
    harvest = source_report["harvest"]
    return {
        "dopplerRepoPath": str(resolve_repo_path(harvest["dopplerRepoPath"])),
        "modelArtifactPath": str(resolve_repo_path(harvest["modelArtifactPath"])),
        "modelId": harvest["modelId"],
        "outputDir": str(output_dir),
        "repeatCount": repeat_count,
        "continuationSteps": continuation_steps,
        "topK": top_k,
        "useChatTemplate": bool(harvest.get("useChatTemplate", False)),
        "runtimeConfig": copy.deepcopy(harvest.get("runtimeConfig") or {}),
        "browser": copy.deepcopy(harvest.get("browser") or {}),
        "promptId": prompt_id,
        "promptText": prompt_text,
        "routeSpecs": [
            {
                "id": route_spec["id"],
                "seedCurrentIds": list(seed_current_ids),
                "seedToken": int(route_spec["seedToken"]),
            }
            for route_spec in route_specs
        ],
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
            "route-branch helper failed\n"
            f"stdout:\n{completed.stdout}\n"
            f"stderr:\n{completed.stderr}"
        )
    return json.loads(completed.stdout)


def summarize_routes(
    helper_result: dict[str, Any],
    *,
    route_token_metadata: dict[str, dict[str, Any]],
) -> dict[str, Any]:
    grouped: dict[str, list[dict[str, Any]]] = {}
    for run in helper_result.get("runs", []):
        for route_result in run.get("routeResults", []):
            grouped.setdefault(route_result["id"], []).append(route_result)

    route_summaries: list[dict[str, Any]] = []
    for route_id, route_runs in grouped.items():
        dominant = dominant_route_result(route_runs)
        stable = len({tuple(run["continuationTokenIds"]) for run in route_runs}) == 1
        route_summaries.append(
            {
                "routeId": route_id,
                **route_token_metadata[route_id],
                "repeatCount": len(route_runs),
                "continuationStable": stable,
                "dominantTailText": dominant.get("decodedTailText"),
                "dominantContinuationTokenIds": dominant.get("continuationTokenIds"),
                "dominantContinuationTokenTexts": dominant.get("continuationTokenTexts"),
                "dominantSeedTokenText": dominant.get("seedTokenText"),
                "runs": route_runs,
            }
        )

    route_summaries.sort(key=lambda entry: entry["routeId"])
    comparisons: list[dict[str, Any]] = []
    by_id = {entry["routeId"]: entry for entry in route_summaries}
    route_ids = [entry["routeId"] for entry in route_summaries]
    for index, left_id in enumerate(route_ids):
        for right_id in route_ids[index + 1 :]:
            left = by_id[left_id]
            right = by_id[right_id]
            first_divergence = compare_token_sequences(
                list(left["dominantContinuationTokenIds"] or []),
                list(right["dominantContinuationTokenIds"] or []),
            )
            comparisons.append(
                {
                    "leftRouteId": left_id,
                    "rightRouteId": right_id,
                    "sameSeedToken": left["seedToken"] == right["seedToken"],
                    "sameContinuation": first_divergence is None,
                    "firstDivergenceStepIndex": first_divergence,
                }
            )
    return {
        "routes": route_summaries,
        "comparisons": comparisons,
    }


def validate_route_summary(route_summary: dict[str, Any]) -> None:
    for comparison in route_summary.get("comparisons", []):
        if comparison.get("sameSeedToken") and not comparison.get("sameContinuation"):
            raise RuntimeError(
                "route continuation inconsistency: routes with the same seed token diverged "
                f"({comparison['leftRouteId']} vs {comparison['rightRouteId']})"
            )


def main() -> int:
    args = parse_args()
    fixture_path = resolve_repo_path(args.fixture)
    fixture = load_json(fixture_path)
    ensure_fixture_shape(fixture)

    source_report_path = resolve_repo_path(args.source_report)
    source_report = load_json(source_report_path)
    case_entry = find_source_case(
        source_report,
        prompt_id=args.prompt_id,
        phase=args.phase,
        step_index=args.step_index,
    )
    state_recipe = find_state_recipe(
        source_report,
        prompt_id=args.prompt_id,
        phase=args.phase,
        step_index=args.step_index,
    )
    source_artifact = case_entry["artifacts"][0]
    logits_path = resolve_repo_path(source_artifact["logitsArtifactPath"])

    stamp = timestamp_label(args.timestamp)
    output_root = resolve_repo_path(args.output_root)
    output_dir = output_root / stamp
    case_id = sanitize_id(f"{args.prompt_id}-{args.phase}-{args.step_index}")
    case_dir = output_dir / case_id
    case_dir.mkdir(parents=True, exist_ok=True)

    receipts = build_doe_receipts(
        fixture=fixture,
        case_entry=case_entry,
        logits_path=logits_path,
        output_dir=case_dir,
    )

    source_top_candidates = source_artifact.get("topCandidates") or []
    raw_token = int(source_artifact["greedyToken"])
    raw_token_text = find_top_candidate_by_token(source_top_candidates, token=raw_token).get("tokenText")

    route_token_metadata = {
        "raw": {
            "seedToken": raw_token,
            "seedTokenText": raw_token_text,
            "selectedBy": "raw-greedy",
            "receipt": None,
        },
        "stable-token": {
            "seedToken": int(receipts["stable-token"]["token"]),
            "seedTokenText": receipts["stable-token"]["receipt"].get("tokenText"),
            "selectedBy": receipts["stable-token"]["receipt"]["selectedBy"],
            "receipt": receipts["stable-token"]["receipt"],
        },
    }
    if "stable-choice" in receipts:
        route_token_metadata["stable-choice"] = {
            "seedToken": int(receipts["stable-choice"]["token"]),
            "seedTokenText": receipts["stable-choice"]["receipt"].get("tokenText"),
            "selectedBy": receipts["stable-choice"]["receipt"]["selectedBy"],
            "receipt": receipts["stable-choice"]["receipt"],
        }
    if "reviewed-choice" in receipts:
        route_token_metadata["reviewed-choice"] = {
            "seedToken": int(receipts["reviewed-choice"]["token"]),
            "seedTokenText": receipts["reviewed-choice"]["receipt"].get("tokenText"),
            "selectedBy": receipts["reviewed-choice"]["receipt"]["selectedBy"],
            "receipt": receipts["reviewed-choice"]["receipt"],
        }

    helper_config = build_helper_config(
        source_report=source_report,
        prompt_id=args.prompt_id,
        prompt_text=case_entry["promptText"],
        output_dir=case_dir,
        continuation_steps=args.continuation_steps,
        repeat_count=args.runs,
        top_k=args.top_k,
        seed_current_ids=list(state_recipe["currentIds"]),
        route_specs=[
            {"id": route_id, "seedToken": metadata["seedToken"]}
            for route_id, metadata in route_token_metadata.items()
        ],
    )
    helper_result = run_helper(helper_config, work_dir=case_dir)
    route_summary = summarize_routes(helper_result, route_token_metadata=route_token_metadata)
    validate_route_summary(route_summary)

    report = {
        "schemaVersion": 1,
        "source": "doe-route-branch-continuation",
        "fixturePath": relative_or_absolute(fixture_path),
        "sourceReportPath": relative_or_absolute(source_report_path),
        "promptId": args.prompt_id,
        "promptText": case_entry["promptText"],
        "phase": args.phase,
        "stepIndex": args.step_index,
        "sourceLogitsArtifactPath": source_artifact["logitsArtifactPath"],
        "sourceLogitsSha256": source_artifact["logitsSha256"],
        "sourceTopCandidates": source_top_candidates[: args.top_k],
        "stateRecipe": {
            "promptTokenIds": state_recipe["promptTokenIds"],
            "decodePrefixTokenIds": state_recipe["currentIds"][len(state_recipe["promptTokenIds"]) :],
            "currentIds": state_recipe["currentIds"],
            "currentIdsLength": state_recipe["currentIdsLength"],
        },
        "continuationSteps": args.continuation_steps,
        "helperResult": helper_result,
        "routeSummary": route_summary,
    }
    report_path = case_dir / f"{case_id}.route-branch-continuation.json"
    report_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(
        json.dumps(
            {
                "reportPath": relative_or_absolute(report_path),
                "routeIds": [route["routeId"] for route in route_summary["routes"]],
            },
            indent=2,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
