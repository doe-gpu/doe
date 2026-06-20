#!/usr/bin/env python3
"""Exercise cross-domain f16 flip cases through the Zig numeric stability runtime."""

from __future__ import annotations

import argparse
import datetime as dt
import json
import subprocess
import sys
import time
from pathlib import Path
from typing import Any

REPO_ROOT = Path(__file__).resolve().parents[2]
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from bench.runners.run_real_lm_head_slice_hunt import (
    TensorRowReader,
    decode_f32_buffer,
    load_json,
    resolve_repo_path,
    resolve_tensor_name,
)

MODULE_RUNNER = REPO_ROOT / "runtime" / "zig" / "zig-out" / "bin" / "module-core-runner"
POLICY_PATH = REPO_ROOT / "config" / "numeric-stability-policy.json"

TRIGGER_POLICY_ID = "numeric-instability/selected-token-disagreement-with-reference-improvement-v1"
ROUTING_POLICY_ID = "numeric-stability/prefer-stable-on-selected-token-disagreement-v1"
FAST_POLICY_ID = "lm-head-slice/forward-f16accum-v1"
STABLE_POLICY_ID = "lm-head-slice/forward-serial-v1"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--scan-result", required=True, help="Scan result JSON from scan_f16_flip_exhaustive.py")
    parser.add_argument("--harvest", required=True, nargs="+", help="Harvest JSON file(s)")
    parser.add_argument("--model-root", required=True, help="Model artifact directory")
    parser.add_argument("--answer-set-registry", required=True, help="Answer set registry JSON")
    parser.add_argument("--model-id", default="gemma-3-270m-it-q4k-ehf16-af32")
    parser.add_argument("--output-dir", default=None, help="Output directory for receipts")
    parser.add_argument("--repeats", type=int, default=3, help="Repeat count for stability check")
    parser.add_argument("--flip-type", default="answer-set-cross", help="Filter flip type")
    return parser.parse_args()


def collect_embeddings(harvest_paths: list[str]) -> dict[str, dict[str, Any]]:
    """Map promptId → {embeddingPath, ...} from harvest files."""
    prompts: dict[str, dict[str, Any]] = {}
    for path in harvest_paths:
        harvest = load_json(Path(path))
        for run in harvest.get("runs", []):
            for p in run.get("promptResults", []):
                if p["status"] != "ok":
                    continue
                pid = p.get("id", f"prompt-{p['promptIndex']:03d}")
                if pid in prompts:
                    continue
                emb = p.get("prefillEmbedding", {})
                if emb.get("embeddingArtifactPath"):
                    prompts[pid] = {
                        "embeddingPath": emb["embeddingArtifactPath"],
                        "embeddingSha256": emb["embeddingSha256"],
                    }
    return prompts


def build_request(
    *,
    hidden_state: list[float],
    candidates: list[dict[str, Any]],
    weight_rows: dict[int, list[float]],
    scenario_stem: str,
) -> dict[str, Any]:
    """Build a module-core-runner request JSON."""
    return {
        "schemaVersion": 1,
        "moduleId": "doe_numeric_stability",
        "artifactKind": "request",
        "serviceId": "matmul_logits_slice",
        "operatorFamily": "lm-head-slice",
        "semanticOpId": "matmul.logits",
        "semanticStage": scenario_stem,
        "semanticPhase": "logits",
        "triggerPolicyId": TRIGGER_POLICY_ID,
        "routingPolicyId": ROUTING_POLICY_ID,
        "fastPolicyId": FAST_POLICY_ID,
        "stablePolicyId": STABLE_POLICY_ID,
        "hiddenState": hidden_state,
        "candidates": [
            {
                "tokenId": int(c["tokenId"]),
                "label": c["tokenText"].strip(),
                "weights": weight_rows[int(c["tokenId"])],
            }
            for c in candidates
        ],
    }


def run_request(request: dict[str, Any], case_dir: Path) -> dict[str, Any]:
    """Run a request through module-core-runner and return the result."""
    case_dir.mkdir(parents=True, exist_ok=True)
    request_path = case_dir / "request.json"
    receipt_path = case_dir / "receipt.jsonl"
    trace_meta_path = case_dir / "trace-meta.json"

    request["receiptPath"] = str(receipt_path)
    request["traceMetaPath"] = str(trace_meta_path)

    with open(request_path, "w") as f:
        json.dump(request, f, indent=2)
        f.write("\n")

    result = subprocess.run(
        [
            str(MODULE_RUNNER),
            "--module", "doe_numeric_stability",
            "--request", str(request_path),
            "--policy", str(POLICY_PATH),
        ],
        cwd=REPO_ROOT,
        check=False,
        text=True,
        capture_output=True,
    )
    if result.returncode != 0:
        raise RuntimeError(f"module-core-runner failed: {result.stderr or result.stdout}")
    return json.loads(result.stdout)


def main() -> int:
    args = parse_args()
    t0 = time.time()

    # Load scan results
    scan = load_json(Path(args.scan_result))
    flips = [f for f in scan["flips"] if f["type"] == args.flip_type]
    print(f"Found {len(flips)} {args.flip_type} flips to exercise", file=sys.stderr)

    # Load embeddings
    embeddings = collect_embeddings(args.harvest)
    print(f"Loaded embeddings for {len(embeddings)} prompts", file=sys.stderr)

    # Load model
    model_root = resolve_repo_path(args.model_root)
    manifest = load_json(model_root / "manifest.json")
    tensor_name = resolve_tensor_name(manifest)

    # Collect all token IDs we need
    token_ids_needed: set[int] = set()
    for flip in flips:
        for opt in flip["options"]:
            token_ids_needed.add(int(opt["tokenId"]))

    print(f"Reading {len(token_ids_needed)} weight rows...", file=sys.stderr)
    row_reader = TensorRowReader(model_root, manifest, tensor_name)
    try:
        weight_rows = row_reader.read_rows(sorted(token_ids_needed))
    finally:
        row_reader.close()

    # Setup output directory
    timestamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    output_dir = Path(args.output_dir) if args.output_dir else (
        REPO_ROOT / "bench" / "out" / "cross-domain-f16-flip-exercise" / timestamp
    )
    output_dir.mkdir(parents=True, exist_ok=True)

    # Deduplicate flips by (promptId, answerSetId) — some have identical embeddings
    seen_keys: set[str] = set()
    unique_flips: list[dict[str, Any]] = []
    for flip in flips:
        key = f"{flip['promptId']}:{flip.get('answerSetId', '')}"
        emb_info = embeddings.get(flip["promptId"])
        if emb_info:
            key = f"{emb_info['embeddingSha256']}:{flip.get('answerSetId', '')}"
        if key in seen_keys:
            continue
        seen_keys.add(key)
        unique_flips.append(flip)

    print(f"After dedup: {len(unique_flips)} unique cases to exercise", file=sys.stderr)

    # Exercise each flip
    results = []
    for i, flip in enumerate(unique_flips):
        prompt_id = flip["promptId"]
        answer_set_id = flip.get("answerSetId", "unknown")

        emb_info = embeddings.get(prompt_id)
        if not emb_info:
            print(f"  [{i+1}] SKIP {prompt_id}: no embedding", file=sys.stderr)
            continue

        hidden = decode_f32_buffer(resolve_repo_path(emb_info["embeddingPath"]))
        candidates = flip["options"]

        scenario_stem = f"{prompt_id}__{answer_set_id}"
        case_id = scenario_stem.replace(".", "_").replace("/", "_")
        case_dir = output_dir / case_id

        request = build_request(
            hidden_state=hidden,
            candidates=candidates,
            weight_rows=weight_rows,
            scenario_stem=scenario_stem,
        )

        # Run multiple times for stability
        last_result = None
        consistent = True
        for r in range(args.repeats):
            try:
                result = run_request(request, case_dir)
                if last_result is not None and result["routeDecision"] != last_result["routeDecision"]:
                    consistent = False
                last_result = result
            except RuntimeError as e:
                print(f"  [{i+1}] ERROR {case_id}: {e}", file=sys.stderr)
                last_result = None
                break

        if last_result is None:
            continue

        receipt = last_result["receipt"]
        trigger = receipt.get("trigger", {})
        route = receipt.get("route", {})
        selected_tokens = receipt.get("selectedToken", {})

        entry = {
            "caseId": case_id,
            "promptId": prompt_id,
            "answerSetId": answer_set_id,
            "promptText": flip.get("promptText", "")[:100],
            "f32Gap": flip.get("f32Gap"),
            "options": [{"tokenId": o["tokenId"], "tokenText": o["tokenText"], "optionId": o["optionId"]} for o in candidates],
            "routeDecision": last_result["routeDecision"],
            "consistent": consistent,
            "triggerFired": trigger.get("fired", False),
            "selectedTokenFast": selected_tokens.get("fast"),
            "selectedTokenStable": selected_tokens.get("stable"),
            "selectedTokenReference": selected_tokens.get("reference"),
            "fastCandidateLogits": [c.get("fastLogit") for c in receipt.get("candidates", [])],
            "stableCandidateLogits": [c.get("stableLogit") for c in receipt.get("candidates", [])],
            "referenceCandidateLogits": [c.get("referenceLogit") for c in receipt.get("candidates", [])],
            "triggerChecks": trigger.get("checks", {}),
            "proofLinks": [
                link.get("theoremId")
                for container in (trigger, route)
                for link in container.get("proofLinks") or []
            ],
        }
        results.append(entry)

        status = "CAUGHT" if entry["routeDecision"] == "prefer-stable" else entry["routeDecision"]
        fast_tok = entry["selectedTokenFast"]
        stable_tok = entry["selectedTokenStable"]
        opt_labels = {o["tokenId"]: o["optionId"] for o in candidates}
        fast_label = opt_labels.get(fast_tok, f"?{fast_tok}")
        stable_label = opt_labels.get(stable_tok, f"?{stable_tok}")
        print(
            f"  [{i+1}/{len(unique_flips)}] {status:14s} | {answer_set_id:30s} | "
            f"fast->{fast_label:>12s} stable->{stable_label:<12s} | gap={flip.get('f32Gap', 0):.6f} | {prompt_id}",
            file=sys.stderr,
        )

    # Write summary report
    caught = sum(1 for r in results if r["routeDecision"] == "prefer-stable")
    accepted = sum(1 for r in results if r["routeDecision"] == "accept-fast")
    abstained = sum(1 for r in results if r["routeDecision"] == "abstain")
    inconsistent = sum(1 for r in results if not r["consistent"])

    report = {
        "schemaVersion": 1,
        "source": "doe-cross-domain-f16-flip-exercise",
        "timestamp": timestamp,
        "summary": {
            "totalCases": len(results),
            "preferStable": caught,
            "acceptFast": accepted,
            "abstain": abstained,
            "inconsistent": inconsistent,
            "catchRate": round(caught / max(len(results), 1) * 100, 1),
        },
        "cases": results,
    }

    report_path = output_dir / "exercise-report.json"
    with open(report_path, "w") as f:
        json.dump(report, f, indent=2)
        f.write("\n")

    total_time = time.time() - t0
    print(f"\n{'='*80}", file=sys.stderr)
    print(f"Results: {caught} prefer-stable, {accepted} accept-fast, {abstained} abstain", file=sys.stderr)
    print(f"Catch rate: {caught}/{len(results)} = {report['summary']['catchRate']}%", file=sys.stderr)
    print(f"Report: {report_path}", file=sys.stderr)
    print(f"Total time: {total_time:.1f}s", file=sys.stderr)

    # Print report path to stdout for pipeline chaining
    print(str(report_path))
    return 0


if __name__ == "__main__":
    sys.exit(main())
