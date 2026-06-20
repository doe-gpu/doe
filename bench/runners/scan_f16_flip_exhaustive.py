#!/usr/bin/env python3
"""Exhaustive offline scan: for every harvested hidden state, check all top-K token pairs for f16 accumulation flips."""

from __future__ import annotations

import argparse
import collections
import json
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
    forward_dot_f16accum,
    forward_dot_f32,
    load_json,
    resolve_model_answer_sets,
    resolve_repo_path,
    resolve_tensor_name,
    reverse_dot_f32,
    scalar_argmax,
    tree64_dot_f32,
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--harvest", required=True, nargs="+", help="Harvest JSON file(s)")
    parser.add_argument("--model-root", required=True, help="Model artifact directory")
    parser.add_argument("--answer-set-registry", default=None, help="Answer set registry JSON")
    parser.add_argument("--model-id", default="gemma-3-270m-it-q4k-ehf16-af32", help="Model ID for answer set lookup")
    parser.add_argument("--top-k", type=int, default=64, help="Number of top candidates to evaluate per prompt")
    parser.add_argument("--pairwise", action="store_true", help="Check all C(K,2) pairs (slower but exhaustive)")
    parser.add_argument("--cross-answer-set", action="store_true", help="Evaluate all answer set pairs against all hidden states")
    return parser.parse_args()


def collect_prompt_data(harvest_paths: list[str]) -> list[dict[str, Any]]:
    """Load all harvest files, deduplicate by prompt ID, pick representative run."""
    prompts_by_id: dict[str, dict[str, Any]] = {}
    for path in harvest_paths:
        harvest = load_json(Path(path))
        for run in harvest.get("runs", []):
            for p in run.get("promptResults", []):
                if p["status"] != "ok":
                    continue
                pid = p.get("id", f"prompt-{p['promptIndex']:03d}")
                if pid in prompts_by_id:
                    continue  # keep first representative
                emb = p.get("prefillEmbedding", {})
                if not emb.get("embeddingArtifactPath"):
                    continue
                prompts_by_id[pid] = {
                    "promptId": pid,
                    "promptIndex": p["promptIndex"],
                    "promptText": p["text"],
                    "embeddingPath": emb["embeddingArtifactPath"],
                    "embeddingSha256": emb["embeddingSha256"],
                    "topCandidates": p["steps"][0]["topCandidates"],
                }
    return sorted(prompts_by_id.values(), key=lambda x: x["promptIndex"])


def compute_logits_for_tokens(
    hidden: list[float],
    token_ids: list[int],
    rows_by_token: dict[int, list[float]],
) -> dict[str, list[float]]:
    """Compute logits for a list of token IDs using all 4 variants."""
    results: dict[str, list[float]] = {
        "forward_f32": [],
        "reverse_f32": [],
        "tree64_f32": [],
        "f16accum": [],
    }
    for tid in token_ids:
        weights = rows_by_token[tid]
        results["forward_f32"].append(forward_dot_f32(hidden, weights))
        results["reverse_f32"].append(reverse_dot_f32(hidden, weights))
        results["tree64_f32"].append(tree64_dot_f32(hidden, weights))
        results["f16accum"].append(forward_dot_f16accum(hidden, weights))
    return results


def find_argmax_flips(logits_by_variant: dict[str, list[float]], token_ids: list[int], token_texts: list[str]) -> list[dict[str, Any]]:
    """Check if any variant pair disagrees on argmax over the full candidate set."""
    flips = []
    variant_names = list(logits_by_variant.keys())
    argmaxes = {v: scalar_argmax(logits_by_variant[v]) for v in variant_names}
    for i, va in enumerate(variant_names):
        for vb in variant_names[i + 1:]:
            if argmaxes[va] != argmaxes[vb]:
                flips.append({
                    "type": "full-argmax",
                    "variantA": va,
                    "variantB": vb,
                    "winnerA": {"tokenId": token_ids[argmaxes[va]], "tokenText": token_texts[argmaxes[va]], "logit": logits_by_variant[va][argmaxes[va]]},
                    "winnerB": {"tokenId": token_ids[argmaxes[vb]], "tokenText": token_texts[argmaxes[vb]], "logit": logits_by_variant[vb][argmaxes[vb]]},
                    "gapA": logits_by_variant[va][argmaxes[va]] - logits_by_variant[va][argmaxes[vb]],
                    "gapB": logits_by_variant[vb][argmaxes[vb]] - logits_by_variant[vb][argmaxes[va]],
                })
    return flips


def find_pairwise_flips(
    logits_by_variant: dict[str, list[float]],
    token_ids: list[int],
    token_texts: list[str],
    *,
    focus_variants: tuple[str, str] = ("forward_f32", "f16accum"),
) -> list[dict[str, Any]]:
    """Check all C(K,2) pairs for flips between two specific variants."""
    va, vb = focus_variants
    la = logits_by_variant[va]
    lb = logits_by_variant[vb]
    flips = []
    n = len(token_ids)
    for i in range(n):
        for j in range(i + 1, n):
            a_winner = i if la[i] > la[j] else j
            b_winner = i if lb[i] > lb[j] else j
            if a_winner != b_winner:
                gap_a = abs(la[i] - la[j])
                gap_b = abs(lb[i] - lb[j])
                flips.append({
                    "type": "pairwise",
                    "variantA": va,
                    "variantB": vb,
                    "tokenI": {"tokenId": token_ids[i], "tokenText": token_texts[i], "logitA": la[i], "logitB": lb[i]},
                    "tokenJ": {"tokenId": token_ids[j], "tokenText": token_texts[j], "logitA": la[j], "logitB": lb[j]},
                    "winnerA_index": a_winner,
                    "winnerB_index": b_winner,
                    "gapA": gap_a,
                    "gapB": gap_b,
                })
    return flips


def find_answer_set_flips(
    hidden: list[float],
    answer_sets: list[dict[str, Any]],
    rows_by_token: dict[int, list[float]],
    resolved_token_map: dict[str, int],
) -> list[dict[str, Any]]:
    """Evaluate all answer set pairs against this hidden state, regardless of prompt anchors."""
    flips = []
    for answer_set in answer_sets:
        options = answer_set.get("options", [])
        if len(options) < 2:
            continue
        # Resolve token IDs for each option
        option_tokens = []
        for option in options:
            token_id = None
            token_text = None
            for form in option.get("forms", []):
                ft = form.get("tokenText")
                if ft and ft in resolved_token_map:
                    token_id = resolved_token_map[ft]
                    token_text = ft
                    break
            if token_id is None or token_id not in rows_by_token:
                break
            option_tokens.append({"tokenId": token_id, "tokenText": token_text, "optionId": option["id"]})
        if len(option_tokens) < 2:
            continue

        token_ids = [t["tokenId"] for t in option_tokens]
        if len(set(token_ids)) < 2:
            continue

        # Compute logits for this pair
        f32_logits = [forward_dot_f32(hidden, rows_by_token[tid]) for tid in token_ids]
        f16_logits = [forward_dot_f16accum(hidden, rows_by_token[tid]) for tid in token_ids]
        f32_winner = scalar_argmax(f32_logits)
        f16_winner = scalar_argmax(f16_logits)
        if f32_winner != f16_winner:
            gap = abs(f32_logits[0] - f32_logits[1])
            flips.append({
                "type": "answer-set-cross",
                "answerSetId": answer_set["id"],
                "options": option_tokens,
                "f32Logits": f32_logits,
                "f16Logits": f16_logits,
                "f32Winner": option_tokens[f32_winner]["optionId"],
                "f16Winner": option_tokens[f16_winner]["optionId"],
                "f32Gap": gap,
            })
    return flips


def main() -> int:
    args = parse_args()
    t0 = time.time()

    # Load prompt data from all harvests
    prompts = collect_prompt_data(args.harvest)
    print(f"Loaded {len(prompts)} unique prompts from {len(args.harvest)} harvest(s)", file=sys.stderr)

    # Load model manifest and weight reader
    model_root = resolve_repo_path(args.model_root)
    manifest = load_json(model_root / "manifest.json")
    tensor_name = resolve_tensor_name(manifest)

    # Collect all unique token IDs we need
    all_token_ids: set[int] = set()
    for prompt in prompts:
        for c in prompt["topCandidates"][:args.top_k]:
            all_token_ids.add(int(c["token"]))

    # Also collect answer-set token IDs if doing cross-evaluation
    answer_sets: list[dict[str, Any]] = []
    resolved_token_map: dict[str, int] = {}
    if args.cross_answer_set and args.answer_set_registry:
        registry = load_json(Path(args.answer_set_registry))
        answer_sets = resolve_model_answer_sets(registry, model_id=args.model_id)
        # Build resolved token map from harvest's resolvedTokens
        for path in args.harvest:
            harvest = load_json(Path(path))
            for text, info in (harvest.get("resolvedTokens") or {}).items():
                if info.get("singleToken") and info.get("tokenId") is not None:
                    resolved_token_map[text] = int(info["tokenId"])
                    all_token_ids.add(int(info["tokenId"]))
                elif not info.get("singleToken"):
                    # Gemma prepends BOS (token 2); real token is the second element
                    tids = info.get("tokenIds", [])
                    if len(tids) == 2 and tids[0] == 2:
                        resolved_token_map[text] = int(tids[1])
                        all_token_ids.add(int(tids[1]))

    print(f"Reading {len(all_token_ids)} weight rows from {tensor_name}...", file=sys.stderr)
    row_reader = TensorRowReader(model_root, manifest, tensor_name)
    try:
        rows_by_token = row_reader.read_rows(sorted(all_token_ids))
    finally:
        row_reader.close()
    print(f"Weight rows loaded in {time.time() - t0:.1f}s", file=sys.stderr)

    # Scan each prompt
    all_flips: list[dict[str, Any]] = []
    total_pairs_checked = 0

    for pi, prompt in enumerate(prompts):
        t1 = time.time()
        hidden = decode_f32_buffer(resolve_repo_path(prompt["embeddingPath"]))
        candidates = prompt["topCandidates"][:args.top_k]
        token_ids = [int(c["token"]) for c in candidates]
        token_texts = [c.get("tokenText", f"?{c['token']}") for c in candidates]

        # Compute all variant logits
        logits = compute_logits_for_tokens(hidden, token_ids, rows_by_token)

        # Check full-argmax flips
        argmax_flips = find_argmax_flips(logits, token_ids, token_texts)
        for flip in argmax_flips:
            flip["promptId"] = prompt["promptId"]
            flip["promptText"] = prompt["promptText"]
            all_flips.append(flip)

        # Check pairwise flips (forward_f32 vs f16accum)
        if args.pairwise:
            pairwise_flips = find_pairwise_flips(logits, token_ids, token_texts)
            total_pairs_checked += len(token_ids) * (len(token_ids) - 1) // 2
            for flip in pairwise_flips:
                flip["promptId"] = prompt["promptId"]
                flip["promptText"] = prompt["promptText"]
                all_flips.append(flip)

        # Cross-answer-set evaluation
        if args.cross_answer_set and answer_sets:
            as_flips = find_answer_set_flips(hidden, answer_sets, rows_by_token, resolved_token_map)
            for flip in as_flips:
                flip["promptId"] = prompt["promptId"]
                flip["promptText"] = prompt["promptText"]
                all_flips.append(flip)

        elapsed = time.time() - t1
        flip_count = sum(1 for f in all_flips if f.get("promptId") == prompt["promptId"])
        if flip_count > 0:
            print(f"  [{pi+1}/{len(prompts)}] {prompt['promptId']}: {flip_count} flip(s) ({elapsed:.1f}s)", file=sys.stderr)
        elif (pi + 1) % 10 == 0:
            print(f"  [{pi+1}/{len(prompts)}] scanning... ({elapsed:.1f}s)", file=sys.stderr)

    total_time = time.time() - t0

    # Summary
    flip_types = collections.Counter(f["type"] for f in all_flips)
    f16_flips = [f for f in all_flips if "f16" in f.get("variantB", "") or "f16" in f.get("variantA", "")]
    unique_prompts_with_flips = set(f["promptId"] for f in all_flips)

    report = {
        "promptCount": len(prompts),
        "topK": args.top_k,
        "pairwiseEnabled": args.pairwise,
        "crossAnswerSetEnabled": args.cross_answer_set,
        "totalPairsChecked": total_pairs_checked,
        "totalFlips": len(all_flips),
        "flipsByType": dict(flip_types),
        "uniquePromptsWithFlips": sorted(unique_prompts_with_flips),
        "f16FlipCount": len(f16_flips),
        "totalTimeSeconds": round(total_time, 1),
        "flips": all_flips,
    }

    print(json.dumps(report, indent=2))
    print(f"\nDone: {len(all_flips)} total flips across {len(unique_prompts_with_flips)} prompts in {total_time:.1f}s", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
