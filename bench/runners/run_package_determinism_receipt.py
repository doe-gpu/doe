#!/usr/bin/env python3
"""Run a real Doe package execution receipt for one sample-only determinism case."""

from __future__ import annotations

import argparse
import datetime as dt
import json
import struct
import subprocess
import sys
from pathlib import Path
from typing import Any

REPO_ROOT = Path(__file__).resolve().parents[2]
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from bench.lib.bench_utils import load_json
from bench.runners.determinism_search_helpers import relative_or_absolute
from bench.runners.run_determinism_probe import annotate_commands
from bench.runners.run_determinism_probe import infer_captures_for_mode
from bench.runners.run_real_logit_hunt import resolve_repo_path
from bench.runners.run_sample_only_tie_break_probe import apply_mutation
from bench.runners.run_sample_only_tie_break_probe import build_sample_only_commands
from bench.runners.run_sample_only_tie_break_probe import ensure_fixture_shape
from bench.runners.run_sample_only_tie_break_probe import load_f32_logits
from bench.runners.run_sample_only_tie_break_probe import resolve_choice_candidates
from bench.runners.run_sample_only_tie_break_probe import resolve_choice_trigger
from bench.runners.run_sample_only_tie_break_probe import resolve_reviewed_decision
from bench.runners.run_sample_only_tie_break_probe import sanitize_id
from bench.runners.run_sample_only_tie_break_probe import select_source_cases
from bench.runners.run_sample_only_tie_break_probe import sha256_bytes

DEFAULT_FIXTURE = REPO_ROOT / "bench" / "fixtures" / "determinism" / "apple-metal-sample-only-tie-break.seatbelt-not-safe.gemma270m.json"
DEFAULT_OUTPUT_ROOT = REPO_ROOT / "bench" / "out" / "apple-metal-package-determinism"
NODE_PACKAGE_EXECUTOR = REPO_ROOT / "bench" / "executors" / "run-node-webgpu-plan.js"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fixture", default=str(DEFAULT_FIXTURE), help="Sample-only tie-break fixture JSON.")
    parser.add_argument("--source-report", required=True, help="Real-logit hunt report with persisted logits artifacts.")
    parser.add_argument("--prompt-id", required=True, help="Source promptId to promote into a package receipt.")
    parser.add_argument("--phase", default=None, help="Optional source phase filter.")
    parser.add_argument("--step-index", type=int, default=None, help="Optional source stepIndex filter.")
    parser.add_argument("--mutation-id", default="as-captured", help="Mutation id from the fixture (default: as-captured).")
    parser.add_argument(
        "--mode",
        choices=["stable-token", "stable-choice", "reviewed-choice"],
        default="stable-choice",
        help="Doe determinism mode to exercise on the package path.",
    )
    parser.add_argument("--timestamp", default=None, help="UTC timestamp label (default: current UTC time).")
    parser.add_argument("--output-root", default=str(DEFAULT_OUTPUT_ROOT), help="Output root for package receipt artifacts.")
    return parser.parse_args()


def timestamp_label(raw: str | None) -> str:
    if raw:
        return raw
    return dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")


def resolve_case_entry(report: dict[str, Any], prompt_id: str, phase: str | None, step_index: int | None) -> dict[str, Any]:
    selected = select_source_cases(
        report,
        case_count=32,
        case_filters=[{
            "promptId": prompt_id,
            **({} if phase is None else {"phase": phase}),
            **({} if step_index is None else {"stepIndex": step_index}),
        }],
    )
    if not selected:
      raise SystemExit(f"no source case matched promptId={prompt_id!r} phase={phase!r} stepIndex={step_index!r}")
    return selected[0]


def resolve_mutation(fixture: dict[str, Any], mutation_id: str) -> dict[str, Any]:
    for mutation in fixture["mutations"]:
        if mutation.get("id") == mutation_id:
            return dict(mutation)
    raise SystemExit(f"unknown mutation id {mutation_id!r} in fixture")


def build_determinism_config(
    *,
    fixture: dict[str, Any],
    case_entry: dict[str, Any],
    mode: str,
) -> dict[str, Any]:
    if mode == "stable-token":
        stable = fixture["doeStableToken"]
        return {
            "mode": "stable-token",
            "providerBoundary": "doe",
            "semanticTokenIndex": 0,
            "topCandidates": int(stable["topCandidates"]),
        }
    if mode == "stable-choice":
        stable_choice = fixture.get("doeStableChoice")
        if stable_choice is None:
            raise SystemExit("fixture does not define doeStableChoice")
        ambiguity_trigger, trigger_policy_id = resolve_choice_trigger(stable_choice)
        return {
            "mode": "stable-choice",
            "providerBoundary": "doe",
            "semanticTokenIndex": 0,
            "topCandidates": int(stable_choice["topCandidates"]),
            "policyId": stable_choice.get("policyId"),
            "triggerPolicyId": trigger_policy_id,
            "candidateSetId": stable_choice.get("candidateSetId"),
            "candidateSetSource": stable_choice.get("candidateSetSource"),
            "candidates": resolve_choice_candidates(stable_choice, case_entry),
            "ambiguityTrigger": ambiguity_trigger,
        }
    reviewed_choice = fixture.get("doeReviewedChoice")
    if reviewed_choice is None:
        raise SystemExit("fixture does not define doeReviewedChoice")
    ambiguity_trigger, trigger_policy_id = resolve_choice_trigger(reviewed_choice)
    return {
        "mode": "reviewed-choice",
        "providerBoundary": "doe",
        "semanticTokenIndex": 0,
        "topCandidates": int(reviewed_choice["topCandidates"]),
        "reviewPolicyId": reviewed_choice.get("reviewPolicyId"),
        "triggerPolicyId": trigger_policy_id,
        "candidateSetId": reviewed_choice.get("candidateSetId"),
        "candidateSetSource": reviewed_choice.get("candidateSetSource"),
        "candidates": resolve_choice_candidates(reviewed_choice, case_entry),
        "ambiguityTrigger": ambiguity_trigger,
        "decision": resolve_reviewed_decision(reviewed_choice, case_entry),
    }


def main() -> None:
    args = parse_args()
    fixture_path = Path(args.fixture).resolve()
    fixture = load_json(fixture_path)
    ensure_fixture_shape(fixture)
    report = load_json(Path(args.source_report).resolve())
    case_entry = resolve_case_entry(report, args.prompt_id, args.phase, args.step_index)
    mutation = resolve_mutation(fixture, args.mutation_id)

    source_logits_path = resolve_repo_path(case_entry["artifacts"][0]["logitsArtifactPath"])
    source_logits = load_f32_logits(source_logits_path)
    mutated_logits, mutation_details = apply_mutation(
        source_logits,
        mutation,
        top_k=max(5, int(mutation.get("topK", 0) or 0)),
        case_entry=case_entry,
    )

    commands = build_sample_only_commands(mutated_logits)
    commands_sha256 = sha256_bytes((json.dumps(commands, indent=2) + "\n").encode("utf-8"))
    captures = infer_captures_for_mode(commands, determinism_mode="stable-decode-step", semantic_stage="sample_only")
    annotated_commands = annotate_commands(commands, captures, execution_plan_hash=commands_sha256)

    determinism = build_determinism_config(
        fixture=fixture,
        case_entry=case_entry,
        mode=args.mode,
    )

    timestamp = timestamp_label(args.timestamp)
    output_root = Path(args.output_root).resolve()
    output_dir = output_root / timestamp
    case_id = sanitize_id(f"{case_entry['promptId']}-{case_entry['stepLabel']}-{args.mutation_id}-{args.mode}")
    case_dir = output_dir / case_id
    case_dir.mkdir(parents=True, exist_ok=True)

    logits_path = case_dir / "input.logits.bin"
    logits_path.write_bytes(struct.pack("<" + "f" * len(mutated_logits), *mutated_logits))
    commands_path = case_dir / "sample_only.commands.annotated.json"
    commands_path.write_text(json.dumps(annotated_commands, indent=2) + "\n", encoding="utf-8")

    plan = {
        "schemaVersion": 1,
        "planKind": "benchmark_ir",
        "workloadId": f"package_determinism_{case_id}",
        "planSha256": commands_sha256,
        "compatibilityCommandsSha256": commands_sha256,
        "commandCount": len(annotated_commands),
        "commands": annotated_commands,
        "determinism": determinism,
    }
    plan_path = case_dir / "package_determinism.plan.json"
    plan_path.write_text(json.dumps(plan, indent=2) + "\n", encoding="utf-8")

    trace_meta_path = case_dir / "doe.node-package.trace-meta.json"
    trace_jsonl_path = case_dir / "doe.node-package.trace.jsonl"
    command = [
        "node",
        str(NODE_PACKAGE_EXECUTOR),
        "--provider",
        "doe",
        "--plan",
        str(plan_path),
        "--trace-meta",
        str(trace_meta_path),
        "--trace-jsonl",
        str(trace_jsonl_path),
        "--workload",
        plan["workloadId"],
    ]
    completed = subprocess.run(
        command,
        cwd=REPO_ROOT,
        capture_output=True,
        text=True,
        check=False,
    )
    if completed.returncode != 0:
        raise SystemExit(
            f"package determinism execution failed with code {completed.returncode}\n"
            f"stdout:\n{completed.stdout}\n\nstderr:\n{completed.stderr}"
        )

    trace_meta = load_json(trace_meta_path)
    report_payload = {
        "schemaVersion": 1,
        "source": "doe-package-determinism-receipt",
        "fixturePath": relative_or_absolute(fixture_path),
        "sourceReportPath": relative_or_absolute(Path(args.source_report).resolve()),
        "caseId": case_id,
        "mode": args.mode,
        "promptId": case_entry["promptId"],
        "promptText": case_entry["promptText"],
        "phase": case_entry["phase"],
        "stepIndex": case_entry["stepIndex"],
        "mutation": {
            "id": mutation["id"],
            **mutation_details,
        },
        "determinism": determinism,
        "artifacts": {
            "logitsPath": relative_or_absolute(logits_path),
            "commandsPath": relative_or_absolute(commands_path),
            "planPath": relative_or_absolute(plan_path),
            "traceMetaPath": relative_or_absolute(trace_meta_path),
            "traceJsonlPath": relative_or_absolute(trace_jsonl_path),
        },
        "traceMeta": trace_meta,
    }
    report_path = case_dir / f"{case_id}.package-determinism.json"
    report_path.write_text(json.dumps(report_payload, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({
        "reportPath": relative_or_absolute(report_path),
        "traceMetaPath": relative_or_absolute(trace_meta_path),
        "determinismMode": args.mode,
        "token": trace_meta.get("determinism", {}).get("token"),
    }, indent=2))


if __name__ == "__main__":
    main()
