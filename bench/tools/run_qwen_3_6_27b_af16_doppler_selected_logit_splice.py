#!/usr/bin/env python3
"""Run a Doppler-state to CSL top-k selected-logit splice for Qwen 3.6 27B AF16."""

from __future__ import annotations

import argparse
import json
import shutil
import sys
from pathlib import Path
from typing import Any

import numpy as np

REPO_ROOT = Path(__file__).resolve().parents[2]
RUNNER_DIR = REPO_ROOT / "bench/runners/csl-runners"
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))
if str(RUNNER_DIR) not in sys.path:
    sys.path.insert(0, str(RUNNER_DIR))

from bench.tools._receipt_hash_guard import enforce_receipt_hash_spine  # noqa: E402
from bench.tools.doppler_rdrr_q4k import (  # noqa: E402
    Q4_K_M_BLOCK_BYTES,
    Q4_K_M_BLOCK_ELEMENTS,
    dequantize_q4km_flat_bytes,
    read_tensor_byte_range,
)
from bench.tools.run_gemma4_31b_af16_doppler_selected_logit_splice import (  # noqa: E402
    DEFAULT_CELLS_ROOT,
    DEFAULT_SDK_ROOT,
    DEFAULT_TAIL_CELLS_ROOT,
    IN_DIM_PER_PE,
    artifact,
    compile_cell,
    compile_final_norm_cell,
    f16_tensor_slice,
    generated_token_ids,
    load_json,
    reference_prefill_logits_path,
    reference_top_token_ids,
    rel,
    resolve,
    run_chunk,
    run_final_norm_cell,
    sha256_bytes,
    sha256_file,
    tensor_sha256,
    weight_root,
    write_json,
)


MODEL_ID = "qwen-3-6-27b-q4k-eaf16"
DEFAULT_MANIFEST = (
    REPO_ROOT / "../doppler/models/local/qwen-3-6-27b-q4k-eaf16/manifest.json"
).resolve()
DEFAULT_REFERENCE_ROOT = (
    REPO_ROOT
    / "bench/out/doppler-reference/"
    "qwen-3-6-27b-eaf16-the-color-of-the-sky-is-prefill-decode8"
)
DEFAULT_TSIR_FIXTURE = DEFAULT_REFERENCE_ROOT / "tsir-fixture"
DEFAULT_REFERENCE_EXPORT = (
    DEFAULT_REFERENCE_ROOT
    / "int4ple-export/doppler_int4ple_reference_export.json"
)
DEFAULT_REFERENCE_REPORT = DEFAULT_REFERENCE_ROOT / "reference-report.json"
DEFAULT_PROGRAM_BUNDLE = DEFAULT_REFERENCE_ROOT / "program-bundle.node.json"
DEFAULT_OUT_DIR = (
    REPO_ROOT
    / "bench/out/r3-2-27b-af16-doppler-csl-splice/selected-logit-splice"
)
HIDDEN_SIZE = 5120
CHUNK_PE_WIDTH = 32
FINAL_LAYER_INDEX = 63
DEFAULT_TOKEN_ID = 760


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, default=DEFAULT_MANIFEST)
    parser.add_argument("--tsir-fixture", type=Path, default=DEFAULT_TSIR_FIXTURE)
    parser.add_argument("--reference-export", type=Path, default=DEFAULT_REFERENCE_EXPORT)
    parser.add_argument("--reference-report", type=Path, default=DEFAULT_REFERENCE_REPORT)
    parser.add_argument("--program-bundle", type=Path, default=DEFAULT_PROGRAM_BUNDLE)
    parser.add_argument("--out-dir", type=Path, default=DEFAULT_OUT_DIR)
    parser.add_argument("--sdk-root", type=Path, default=DEFAULT_SDK_ROOT)
    parser.add_argument("--cells-root", type=Path, default=DEFAULT_CELLS_ROOT)
    parser.add_argument("--tail-cells-root", type=Path, default=DEFAULT_TAIL_CELLS_ROOT)
    parser.add_argument(
        "--token-id",
        type=int,
        default=None,
        help="Optional primary token id. Default uses Doppler's reference argmax.",
    )
    parser.add_argument(
        "--top-k",
        type=int,
        default=64,
        help="Number of Doppler top logits to replay through CSL.",
    )
    parser.add_argument("--chunk-pe-width", type=int, default=CHUNK_PE_WIDTH)
    parser.add_argument("--atol", type=float, default=2.0e-2)
    return parser.parse_args()


def q4km_tensor_row(
    *,
    manifest: dict[str, Any],
    root: Path,
    tensor_name: str,
    row_index: int,
) -> tuple[np.ndarray, bytes]:
    tensor = (manifest.get("tensors") or {}).get(tensor_name)
    if not isinstance(tensor, dict):
        raise ValueError(f"tensor_missing:{tensor_name}")
    if tensor.get("dtype") != "Q4_K_M":
        raise ValueError(f"tensor_dtype_unsupported:{tensor_name}:{tensor.get('dtype')}")
    if tensor.get("layout") != "row":
        raise ValueError(f"tensor_layout_unsupported:{tensor_name}:{tensor.get('layout')}")
    shape = tensor.get("shape")
    if not isinstance(shape, list) or len(shape) != 2:
        raise ValueError(f"tensor_shape_unsupported:{tensor_name}:{shape}")
    rows = int(shape[0])
    cols = int(shape[1])
    if row_index < 0 or row_index >= rows:
        raise ValueError(f"row_index_out_of_range:{row_index}:{rows}")
    blocks_per_row = (cols + Q4_K_M_BLOCK_ELEMENTS - 1) // Q4_K_M_BLOCK_ELEMENTS
    row_bytes = read_tensor_byte_range(
        root,
        manifest,
        tensor_name=tensor_name,
        byte_start=row_index * blocks_per_row * Q4_K_M_BLOCK_BYTES,
        byte_count=blocks_per_row * Q4_K_M_BLOCK_BYTES,
    )
    values = dequantize_q4km_flat_bytes(
        row_bytes,
        blocks_per_row,
        [1, blocks_per_row * Q4_K_M_BLOCK_ELEMENTS],
    )
    return np.asarray(values[:cols], dtype=np.float32), row_bytes


def optional_artifact(path: Path) -> dict[str, Any] | None:
    return artifact(path) if path.is_file() else None


def reference_fixture_hash(paths: list[Path]) -> str:
    payload = {
        "kind": "qwen_3_6_27b_af16_selected_logit_fixture",
        "artifacts": [
            {"path": rel(path), "sha256": sha256_file(path), "byteLength": path.stat().st_size}
            for path in paths
            if path.is_file()
        ],
    }
    return sha256_bytes(json.dumps(payload, sort_keys=True).encode("utf-8"))


def main() -> int:
    args = parse_args()
    manifest_path = resolve(args.manifest)
    tsir_fixture = resolve(args.tsir_fixture)
    reference_export_path = resolve(args.reference_export)
    reference_report_path = resolve(args.reference_report)
    program_bundle_path = resolve(args.program_bundle)
    out_dir = resolve(args.out_dir)
    sdk_root = resolve(args.sdk_root)
    cells_root = resolve(args.cells_root)
    tail_cells_root = resolve(args.tail_cells_root)

    manifest = load_json(manifest_path)
    reference_export = load_json(reference_export_path)
    source_root = weight_root(manifest_path, manifest)
    post_ffn_path = tsir_fixture / f"layer_{FINAL_LAYER_INDEX}/post_ffn.npy"
    if not post_ffn_path.is_file():
        raise ValueError(f"qwen_post_ffn_fixture_missing:{post_ffn_path}")
    post_ffn = np.load(post_ffn_path, allow_pickle=False).astype(np.float32)
    hidden_rows = post_ffn.reshape(-1, HIDDEN_SIZE)
    final_input = hidden_rows[-1]

    inference = manifest.get("inference") or {}
    norm_cfg = inference.get("normalization") or {}
    output_cfg = inference.get("output") or {}
    rms_norm_eps = float(norm_cfg.get("rmsNormEps", 1.0e-6))
    rms_norm_weight_offset = bool(norm_cfg.get("rmsNormWeightOffset", False))
    final_logit_softcap = output_cfg.get("finalLogitSoftcapping")
    tie_word_embeddings = bool(output_cfg.get("tieWordEmbeddings", False))

    norm_weight = f16_tensor_slice(
        manifest=manifest,
        root=source_root,
        tensor_name="model.language_model.norm.weight",
        elem_offset=0,
        elem_count=HIDDEN_SIZE,
    ).astype(np.float32)
    rms = np.sqrt(np.mean(final_input * final_input) + rms_norm_eps)
    norm_scale = norm_weight + (1.0 if rms_norm_weight_offset else 0.0)
    normalized = (final_input / rms) * norm_scale
    host_activation = normalized.astype(np.float16)
    final_norm_compile = compile_final_norm_cell(
        hidden_size=HIDDEN_SIZE,
        weight_offset=rms_norm_weight_offset,
        out_dir=out_dir,
        sdk_root=sdk_root,
        tail_cells_root=tail_cells_root,
        artifact_kind="qwen_3_6_27b_af16_final_norm_f16_compile_receipt",
    )
    final_norm_run = run_final_norm_cell(
        compile_dir=Path(str(final_norm_compile["compileDir"])),
        input_hidden=final_input,
        norm_weight=norm_weight,
        expected_activation=host_activation,
        out_dir=out_dir,
        sdk_root=sdk_root,
    )
    final_norm_output = final_norm_run.get("output") or {}
    if final_norm_run["status"] == "succeeded" and final_norm_output.get("path"):
        activation = np.load(
            resolve(Path(str(final_norm_output["path"]))),
            allow_pickle=False,
        ).astype(np.float16)
    else:
        activation = host_activation

    logits_path = reference_prefill_logits_path(reference_export)
    logits = np.fromfile(logits_path, dtype=np.float32)
    expected_token_id = int(np.argmax(logits))
    top_token_ids = reference_top_token_ids(logits, int(args.top_k))
    primary_token_id = int(args.token_id) if args.token_id is not None else expected_token_id
    if primary_token_id < 0 or primary_token_id >= logits.size:
        raise ValueError(f"token_id_out_of_range:{primary_token_id}:{logits.size}")
    candidate_token_ids = [primary_token_id] + [
        token for token in top_token_ids if token != primary_token_id
    ]
    rank_by_token = {token: index + 1 for index, token in enumerate(top_token_ids)}
    selected_text = None
    logits_digest_token = None
    for item in (reference_export.get("decodeTranscript") or {}).get("logitsDigests") or []:
        if isinstance(item, dict) and item.get("phase") == "prefill":
            logits_digest_token = item.get("selectedTokenId")
            selected_text = item.get("selectedText")
            break
    generated_tokens = generated_token_ids(reference_export)

    if out_dir.exists():
        shutil.rmtree(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    compile_cache: dict[int, dict[str, Any]] = {}
    chunk_width = max(1, int(args.chunk_pe_width))
    chunk_elems = chunk_width * IN_DIM_PER_PE

    def run_token(token_id: int) -> dict[str, Any]:
        lm_head_row_f32, lm_head_row_raw = q4km_tensor_row(
            manifest=manifest,
            root=source_root,
            tensor_name="lm_head.weight",
            row_index=token_id,
        )
        lm_head_row = lm_head_row_f32.astype(np.float16)
        chunk_results: list[dict[str, Any]] = []
        chunk_values: list[float] = []
        chunk_index = 0
        token_dir = out_dir / f"token-{token_id}"
        for start in range(0, HIDDEN_SIZE, chunk_elems):
            count = min(chunk_elems, HIDDEN_SIZE - start)
            width = (count + IN_DIM_PER_PE - 1) // IN_DIM_PER_PE
            padded = width * IN_DIM_PER_PE
            act_chunk = np.zeros(padded, dtype=np.float16)
            weight_chunk = np.zeros(padded, dtype=np.float16)
            act_chunk[:count] = activation[start : start + count]
            weight_chunk[:count] = lm_head_row[start : start + count]
            if width not in compile_cache:
                compile_cache[width] = compile_cell(
                    width=width,
                    out_dir=out_dir,
                    sdk_root=sdk_root,
                    cells_root=cells_root,
                    artifact_kind="qwen_3_6_27b_af16_selected_logit_compile_receipt",
                )
            result = run_chunk(
                chunk_index=chunk_index,
                width=width,
                compile_dir=Path(str(compile_cache[width]["compileDir"])),
                activation=act_chunk,
                weight=weight_chunk,
                out_dir=token_dir,
                sdk_root=sdk_root,
            )
            result["hiddenStart"] = start
            result["hiddenCount"] = count
            result["cpuPartial"] = float(
                np.dot(act_chunk.astype(np.float32), weight_chunk.astype(np.float32))
            )
            chunk_results.append(result)
            if result["status"] != "succeeded" or result["outputValue"] is None:
                break
            chunk_values.append(float(result["outputValue"]))
            chunk_index += 1

        cpu_raw = float(
            np.dot(activation.astype(np.float32), lm_head_row.astype(np.float32))
        )
        cpu_softcapped = cpu_raw
        if isinstance(final_logit_softcap, (int, float)):
            cpu_softcapped = float(
                final_logit_softcap * np.tanh(cpu_raw / final_logit_softcap)
            )
        csl_raw = float(np.sum(np.array(chunk_values, dtype=np.float32)))
        csl_softcapped = csl_raw
        if isinstance(final_logit_softcap, (int, float)):
            csl_softcapped = float(
                final_logit_softcap * np.tanh(csl_raw / final_logit_softcap)
            )
        expected_logit = float(logits[token_id])
        logit_abs_diff = abs(csl_softcapped - expected_logit)
        csl_matches_cpu = len(chunk_values) == len(chunk_results) and all(
            abs(float(item.get("outputValue") or 0.0) - float(item["cpuPartial"])) <= 1.0e-4
            for item in chunk_results
            if item.get("status") == "succeeded"
        )
        all_chunks_succeeded = len(chunk_results) > 0 and all(
            item.get("status") == "succeeded" for item in chunk_results
        )
        return {
            "tokenId": token_id,
            "referenceRank": rank_by_token.get(token_id),
            "expectedLogit": expected_logit,
            "rawLogit": csl_raw,
            "softcappedLogit": csl_softcapped,
            "cpuRawLogit": cpu_raw,
            "cpuSoftcappedLogit": cpu_softcapped,
            "logitAbsDiff": logit_abs_diff,
            "chunkCount": len(chunk_results),
            "chunkResults": chunk_results,
            "allChunksSucceeded": all_chunks_succeeded,
            "cslCpuPartialsMatch": csl_matches_cpu,
            "lmHeadQ4RowSha256": sha256_bytes(lm_head_row_raw),
            "lmHeadDequantizedRowSha256": tensor_sha256(lm_head_row),
        }

    candidate_runs = [run_token(token_id) for token_id in candidate_token_ids]
    primary_run = candidate_runs[0]
    max_logit_abs_diff = max(float(run["logitAbsDiff"]) for run in candidate_runs)
    csl_argmax_token_id = int(
        max(candidate_runs, key=lambda run: float(run["softcappedLogit"]))["tokenId"]
    )
    reference_top1_top2_margin = (
        float(logits[top_token_ids[0]] - logits[top_token_ids[1]])
        if len(top_token_ids) > 1
        else float("inf")
    )
    decision_margin_lower_bound = reference_top1_top2_margin - (
        2.0 * max_logit_abs_diff
    )
    argmax_decision_stable = (
        csl_argmax_token_id == expected_token_id
        and decision_margin_lower_bound > 0.0
    )
    all_candidates_succeeded = all(
        bool(run["allChunksSucceeded"]) for run in candidate_runs
    )
    all_candidates_match_cpu = all(
        bool(run["cslCpuPartialsMatch"]) for run in candidate_runs
    )
    all_candidates_match_doppler = all(
        float(run["logitAbsDiff"]) <= float(args.atol) for run in candidate_runs
    )
    generated_token_match = not generated_tokens or expected_token_id == int(generated_tokens[0])
    digest_token_match = logits_digest_token is None or expected_token_id == int(logits_digest_token)
    token_matches = (
        csl_argmax_token_id == expected_token_id
        and generated_token_match
        and digest_token_match
    )
    comparison_mode = (
        "parity"
        if all_candidates_match_doppler
        else "argmax_decision_bound"
    )
    verdict = (
        "pass"
        if all_candidates_succeeded
        and final_norm_run["status"] == "succeeded"
        and bool(final_norm_run.get("withinAtol"))
        and all_candidates_match_cpu
        and argmax_decision_stable
        and token_matches
        else "blocked"
    )
    blockers: list[str] = []
    if not all_candidates_succeeded:
        blockers.append("topk_selected_logits_csl_chunk_blocked")
    if final_norm_run["status"] != "succeeded":
        blockers.append("final_norm_csl_blocked")
    elif not final_norm_run.get("withinAtol"):
        blockers.append("final_norm_csl_host_f16_exceeds_tolerance")
    if not all_candidates_match_cpu:
        blockers.append("topk_selected_logits_csl_cpu_partial_mismatch")
    if not argmax_decision_stable:
        blockers.append("topk_selected_logits_decision_margin_not_positive")
    if not token_matches:
        blockers.append("topk_selected_logits_argmax_mismatch")

    fixture_hash = reference_fixture_hash(
        [
            post_ffn_path,
            reference_export_path,
            reference_report_path,
            program_bundle_path,
            logits_path,
        ]
    )
    receipt = {
        "schemaVersion": 1,
        "artifactKind": "qwen_3_6_27b_af16_doppler_selected_logit_splice_receipt",
        "receiptClass": "manifest_shape_doppler_selected_logit_splice",
        "comparisonMode": comparison_mode,
        "verdict": verdict,
        "blockers": blockers,
        "modelId": MODEL_ID,
        "manifestPath": rel(manifest_path),
        "manifestSha256": sha256_file(manifest_path),
        "referenceFixtureHash": fixture_hash,
        "sourceProgram": {
            "authoringSurface": "doppler_execution_v1",
            "manifestSha256": str(reference_export.get("manifestSha256") or ""),
            "executionGraphSha256": str(reference_export.get("executionGraphSha256") or ""),
            "weightSetSha256": str(reference_export.get("weightSetSha256") or ""),
            "inputSetSha256": str(reference_export.get("inputSetSha256") or ""),
            "referenceExport": artifact(reference_export_path),
            "referenceReport": optional_artifact(reference_report_path),
            "programBundle": optional_artifact(program_bundle_path),
        },
        "splicePoint": {
            "kind": "selected_lm_head_logit",
            "layerIndex": FINAL_LAYER_INDEX,
            "inputProbe": "post_ffn",
            "promptTokenCount": int(hidden_rows.shape[0]),
            "selectedTokenId": primary_token_id,
            "selectedTokenIds": candidate_token_ids,
            "topK": len(top_token_ids),
            "selectedText": selected_text,
        },
        "dopplerReference": {
            "tsirFixtureRoot": rel(tsir_fixture),
            "inputTensor": artifact(post_ffn_path),
            "prefillLogits": artifact(logits_path),
            "expectedTokenId": expected_token_id,
            "expectedTopKTokenIds": top_token_ids,
            "expectedTopKLogits": [
                {"rank": index + 1, "tokenId": token, "logit": float(logits[token])}
                for index, token in enumerate(top_token_ids)
            ],
            "logitsDigestSelectedTokenId": logits_digest_token,
            "generatedTokenIds": generated_tokens,
            "expectedSelectedLogit": float(logits[primary_token_id]),
        },
        "weights": {
            "sourceRoot": rel(source_root),
            "finalNormTensor": "model.language_model.norm.weight",
            "lmHeadTensor": "lm_head.weight",
            "lmHeadStorageDtype": "Q4_K_M",
            "lmHeadTiedEmbedding": tie_word_embeddings,
            "rmsNormWeightOffset": rms_norm_weight_offset,
            "finalNormSha256": tensor_sha256(norm_weight.astype(np.float16)),
            "finalNormCslOutputSha256": str(final_norm_run.get("outputSha256") or ""),
            "selectedLmHeadQ4RowSha256": primary_run["lmHeadQ4RowSha256"],
            "selectedLmHeadDequantizedRowSha256": primary_run[
                "lmHeadDequantizedRowSha256"
            ],
            "candidateLmHeadRows": [
                {
                    "tokenId": int(run["tokenId"]),
                    "q4RowSha256": run["lmHeadQ4RowSha256"],
                    "dequantizedRowSha256": run["lmHeadDequantizedRowSha256"],
                }
                for run in candidate_runs
            ],
        },
        "cslRun": {
            "tailKernels": ["final_norm_f16", "lm_head_prefill"],
            "finalNorm": final_norm_run,
            "kernel": "lm_head_prefill",
            "chunkPeWidth": chunk_width,
            "inDimPerPe": IN_DIM_PER_PE,
            "topK": len(top_token_ids),
            "candidateCount": len(candidate_runs),
            "candidateTokenIds": candidate_token_ids,
            "candidateRuns": candidate_runs,
            "referenceArgmaxTokenId": expected_token_id,
            "cslArgmaxTokenId": csl_argmax_token_id,
            "maxLogitAbsDiff": max_logit_abs_diff,
            "allCandidateLogitsWithinTolerance": all_candidates_match_doppler,
            "strictLogitTolerancePassed": all_candidates_match_doppler,
            "strictLogitToleranceAtol": float(args.atol),
            "referenceTop1Top2Margin": reference_top1_top2_margin,
            "decisionMarginLowerBound": decision_margin_lower_bound,
            "argmaxDecisionStable": argmax_decision_stable,
            "chunkCount": int(primary_run["chunkCount"]),
            "chunkResults": primary_run["chunkResults"],
            "rawLogit": float(primary_run["rawLogit"]),
            "softcappedLogit": float(primary_run["softcappedLogit"]),
            "cpuRawLogit": float(primary_run["cpuRawLogit"]),
            "cpuSoftcappedLogit": float(primary_run["cpuSoftcappedLogit"]),
            "softcap": final_logit_softcap,
            "rmsNormEps": rms_norm_eps,
            "logitAbsDiff": float(primary_run["logitAbsDiff"]),
            "atol": float(args.atol),
        },
        "claim": {
            "scope": (
                "Doppler supplies real Qwen 3.6 27B af16 post-FFN state for "
                "the final prompt position; CSL computes final RMSNorm plus "
                "the q4k lm-head logits for the Doppler top-k token candidates "
                "across hidden chunks and preserves the top-token decision."
            ),
            "notWhat": (
                "Not a full-vocabulary argmax, not a full layer-63 CSL run, "
                "and not hardware execution. The q4k lm-head row is "
                "dequantized host-side and each selected dense dot runs in CSL; "
                "strict logit tolerance status is recorded separately from the "
                "top-token decision bound."
            ),
        },
    }
    enforce_receipt_hash_spine(receipt, repo_root=REPO_ROOT)
    schema_path = REPO_ROOT / "config/doppler-selected-logit-splice-receipt.schema.json"
    try:
        import jsonschema  # type: ignore[import-not-found]
    except ImportError:
        pass
    else:
        jsonschema.Draft202012Validator(load_json(schema_path)).validate(receipt)
    receipt_path = out_dir / "selected-logit-splice.json"
    write_json(receipt_path, receipt)
    print(
        f"wrote {rel(receipt_path)} "
        f"(verdict={verdict}, topK={len(top_token_ids)}, "
        f"token={primary_token_id}, maxDiff={max_logit_abs_diff:.6e})"
    )
    return 0 if verdict == "pass" else 1


if __name__ == "__main__":
    sys.exit(main())
