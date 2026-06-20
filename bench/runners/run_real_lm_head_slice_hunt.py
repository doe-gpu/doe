#!/usr/bin/env python3
"""Search real prompt final-projection slices for accumulation-policy token flips and promote the best case."""

from __future__ import annotations

import argparse
import collections
import copy
import json
import math
import struct
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Any


REPO_ROOT = Path(__file__).resolve().parents[2]
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from bench.runners.run_determinism_probe import timestamp_label
from bench.runners.run_real_logit_hunt import ensure_fixture_shape as ensure_source_fixture_shape
from bench.runners.run_real_logit_hunt import load_json
from bench.runners.run_real_logit_hunt import resolve_repo_path


DEFAULT_FIXTURE = REPO_ROOT / "bench" / "fixtures" / "determinism" / "apple-metal-real-lm-head-slice-hunt.gemma270m.policy-breadth.json"
DEFAULT_OUTPUT_ROOT = REPO_ROOT / "bench" / "out" / "apple-metal-real-lm-head-slice-hunt"
HELPER_SCRIPT = REPO_ROOT / "bench" / "executors" / "harvest-doppler-browser-logits.js"
REDUCTION_ORDER_RUNNER = REPO_ROOT / "bench" / "runners" / "run_reduction_order_logit_flip.py"
SELECTIVE_RERUN_RUNNER = REPO_ROOT / "bench" / "runners" / "run_selective_stable_rerun_probe.py"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fixture", default=str(DEFAULT_FIXTURE), help="Real LM-head slice hunt fixture JSON.")
    parser.add_argument("--runs", type=int, default=None, help="Override repeat count from the source fixture.")
    parser.add_argument("--timestamp", default=None, help="UTC timestamp label (default: current UTC time).")
    parser.add_argument("--output-root", default=str(DEFAULT_OUTPUT_ROOT), help="Output root for hunt artifacts.")
    parser.add_argument("--top-candidates", type=int, default=12, help="Number of ranked search candidates to keep.")
    return parser.parse_args()


def relative_or_absolute(path: Path) -> str:
    absolute = path.resolve()
    try:
        return str(absolute.relative_to(REPO_ROOT.resolve()))
    except ValueError:
        return str(absolute)


def ensure_fixture_shape(fixture: dict[str, Any]) -> None:
    required = [
        "scenarioId",
        "sourceRealLogitFixturePath",
        "topCandidatePrefixes",
        "promotion",
    ]
    missing = [field for field in required if field not in fixture]
    if missing:
        raise ValueError(f"fixture missing required fields: {', '.join(missing)}")
    promotion_required = [
        "kernelRoot",
        "profile",
        "queueWaitMode",
        "queueSyncMode",
        "backendLanes",
        "variants",
        "policyRegistryPath",
        "triggerPolicyId",
        "routingPolicyId",
    ]
    missing_promotion = [field for field in promotion_required if field not in fixture["promotion"]]
    if missing_promotion:
        raise ValueError(f"fixture.promotion missing required fields: {', '.join(missing_promotion)}")
    if not fixture["topCandidatePrefixes"]:
        raise ValueError("fixture.topCandidatePrefixes must be non-empty")


def build_helper_config(
    source_fixture: dict[str, Any],
    *,
    output_dir: Path,
    repeat_count: int,
    token_texts_to_resolve: list[str],
) -> dict[str, Any]:
    return {
        "scenarioId": source_fixture["scenarioId"],
        "dopplerRepoPath": str(resolve_repo_path(source_fixture["dopplerRepoPath"])),
        "modelArtifactPath": str(resolve_repo_path(source_fixture["modelArtifactPath"])),
        "modelId": source_fixture["modelId"],
        "outputDir": str(output_dir),
        "repeatCount": repeat_count,
        "decodeSteps": source_fixture.get("decodeSteps", 0),
        "topK": source_fixture.get("topK", 32),
        "persistLogits": False,
        "capturePrefillEmbedding": True,
        "prefillEmbeddingMode": "last",
        "tokenTextsToResolve": token_texts_to_resolve,
        "useChatTemplate": source_fixture.get("useChatTemplate", False),
        "runtimeConfig": copy.deepcopy(source_fixture.get("runtimeConfig") or {}),
        "browser": copy.deepcopy(source_fixture.get("browser") or {}),
        "promptCandidates": copy.deepcopy(source_fixture["promptCandidates"]),
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
            "real-lm-head helper failed\n"
            f"stdout:\n{completed.stdout}\n"
            f"stderr:\n{completed.stderr}"
        )
    return json.loads(completed.stdout)


def decode_f32_buffer(path: Path) -> list[float]:
    payload = path.read_bytes()
    if len(payload) % 4 != 0:
        raise ValueError(f"expected 4-byte aligned f32 payload: {path}")
    if not payload:
        return []
    return list(struct.unpack("<" + "f" * (len(payload) // 4), payload))


def f32(value: float) -> float:
    return struct.unpack("<f", struct.pack("<f", float(value)))[0]


def f16(value: float) -> float:
    return struct.unpack("<e", struct.pack("<e", float(value)))[0]


def forward_dot_f32(hidden: list[float], weights: list[float]) -> float:
    acc = 0.0
    for left, right in zip(hidden, weights, strict=True):
        acc = f32(acc + f32(left * right))
    return acc


def reverse_dot_f32(hidden: list[float], weights: list[float]) -> float:
    acc = 0.0
    for left, right in zip(reversed(hidden), reversed(weights), strict=True):
        acc = f32(acc + f32(left * right))
    return acc


def tree64_dot_f32(hidden: list[float], weights: list[float]) -> float:
    width = 64
    partial = [0.0] * width
    for tid in range(width):
        acc = 0.0
        for index in range(tid, len(hidden), width):
            acc = f32(acc + f32(hidden[index] * weights[index]))
        partial[tid] = acc
    stride = width // 2
    while stride > 0:
        for tid in range(stride):
            partial[tid] = f32(partial[tid] + partial[tid + stride])
        stride //= 2
    return partial[0]


def forward_dot_f16accum(hidden: list[float], weights: list[float]) -> float:
    acc = 0.0
    for left, right in zip(hidden, weights, strict=True):
        product = f16(f16(left) * f16(right))
        acc = f16(f16(acc) + product)
    return float(acc)


def exact_dot(hidden: list[float], weights: list[float]) -> float:
    return float(sum(float(left) * float(right) for left, right in zip(hidden, weights, strict=True)))


def scalar_argmax(values: list[float]) -> int:
    best_index = 0
    best_value = values[0]
    for index, value in enumerate(values[1:], start=1):
        if value > best_value:
            best_value = value
            best_index = index
    return best_index


def compute_variant_logit(variant_id: str, hidden: list[float], weights: list[float]) -> float:
    if variant_id == "forward":
        return forward_dot_f32(hidden, weights)
    if variant_id == "reverse":
        return reverse_dot_f32(hidden, weights)
    if variant_id == "tree64":
        return tree64_dot_f32(hidden, weights)
    if variant_id == "f16accum":
        return forward_dot_f16accum(hidden, weights)
    raise ValueError(f"unsupported variant id: {variant_id}")


@dataclass(frozen=True)
class TensorSpan:
    shard_index: int
    file_offset: int
    size: int
    tensor_offset: int
    tensor_end: int


class TensorRowReader:
    def __init__(self, model_root: Path, manifest: dict[str, Any], tensor_name: str) -> None:
        self.model_root = model_root
        self.manifest = manifest
        self.tensor_name = tensor_name
        tensor = manifest["tensors"][tensor_name]
        self.shape = tensor["shape"]
        self.dtype = tensor["dtype"]
        if self.dtype != "F16":
            raise ValueError(f"expected F16 tensor for {tensor_name}, got {self.dtype}")
        if len(self.shape) != 2:
            raise ValueError(f"expected 2D tensor for {tensor_name}, got {self.shape}")
        self.rows = int(self.shape[0])
        self.cols = int(self.shape[1])
        self.row_bytes = self.cols * 2
        spans: list[TensorSpan] = []
        tensor_offset = 0
        for raw_span in tensor["spans"]:
            size = int(raw_span["size"])
            spans.append(
                TensorSpan(
                    shard_index=int(raw_span["shardIndex"]),
                    file_offset=int(raw_span["offset"]),
                    size=size,
                    tensor_offset=tensor_offset,
                    tensor_end=tensor_offset + size,
                )
            )
            tensor_offset += size
        if tensor_offset != int(tensor["size"]):
            raise ValueError(
                f"tensor span size mismatch for {tensor_name}: spans={tensor_offset} tensor.size={tensor['size']}"
            )
        self.spans = spans
        self._handles: dict[int, Any] = {}

    def close(self) -> None:
        for handle in self._handles.values():
            handle.close()
        self._handles.clear()

    def _handle(self, shard_index: int):
        handle = self._handles.get(shard_index)
        if handle is not None:
            return handle
        shard_info = self.manifest["shards"][shard_index]
        shard_path = self.model_root / shard_info["filename"]
        handle = shard_path.open("rb")
        self._handles[shard_index] = handle
        return handle

    def _read_tensor_range(self, start: int, size: int) -> bytes:
        end = start + size
        remaining = size
        output = bytearray(size)
        for span in self.spans:
            overlap_start = max(start, span.tensor_offset)
            overlap_end = min(end, span.tensor_end)
            if overlap_start >= overlap_end:
                continue
            read_size = overlap_end - overlap_start
            handle = self._handle(span.shard_index)
            handle.seek(span.file_offset + (overlap_start - span.tensor_offset))
            chunk = handle.read(read_size)
            if len(chunk) != read_size:
                raise ValueError(
                    f"short read for {self.tensor_name}: shard={span.shard_index} want={read_size} got={len(chunk)}"
                )
            output[overlap_start - start : overlap_end - start] = chunk
            remaining -= read_size
            if remaining == 0:
                break
        if remaining != 0:
            raise ValueError(f"incomplete tensor read for {self.tensor_name}: missing={remaining}")
        return bytes(output)

    def read_rows(self, row_ids: list[int]) -> dict[int, list[float]]:
        out: dict[int, list[float]] = {}
        format_string = "<" + "e" * self.cols
        for row_id in row_ids:
            if row_id < 0 or row_id >= self.rows:
                raise ValueError(f"row {row_id} out of range for {self.tensor_name}")
            payload = self._read_tensor_range(row_id * self.row_bytes, self.row_bytes)
            out[row_id] = [float(value) for value in struct.unpack(format_string, payload)]
        return out


def resolve_tensor_name(manifest: dict[str, Any]) -> str:
    if manifest["inference"]["output"].get("tieWordEmbeddings"):
        return "model.embed_tokens.weight"
    for name in ("lm_head", "lm_head.weight"):
        if name in manifest["tensors"]:
            return name
    raise ValueError("could not resolve LM-head tensor name from manifest")


def resolve_model_answer_sets(registry: dict[str, Any], *, model_id: str) -> list[dict[str, Any]]:
    for model_entry in registry.get("models", []):
        if model_entry.get("modelId") == model_id:
            return list(model_entry.get("answerSets") or [])
    return []


def is_meaningful_token_text(token_text: str | None) -> bool:
    if token_text is None:
        return False
    return any(char.isalnum() for char in token_text)


def build_resolved_candidate(token_info: dict[str, Any], token_text: str) -> dict[str, Any] | None:
    if not token_info or not token_info.get("singleToken"):
        return None
    token_id = token_info.get("tokenId")
    if token_id is None:
        return None
    return {
        "token": int(token_id),
        "tokenText": token_info.get("decodedTokenText") or token_text,
        "logit": None,
    }


def extract_prompt_choice_rows(
    prompt_text: str,
    top_candidates: list[dict[str, Any]],
    resolved_tokens: dict[str, Any] | None = None,
) -> list[dict[str, Any]] | None:
    normalized = " ".join(prompt_text.strip().split())
    lower = normalized.lower()
    markers = ("choose exactly one word:", "answer with exactly one word:")
    selected_marker = next((marker for marker in markers if marker in lower), None)
    if selected_marker is None:
        return None
    start = lower.index(selected_marker) + len(selected_marker)
    tail = normalized[start:].strip()
    line = tail.split(".")[0].strip()
    if " or " not in line:
        return None
    left_text, right_text = [part.strip() for part in line.split(" or ", 1)]
    if not left_text or not right_text:
        return None

    def find_candidate(option_text: str) -> dict[str, Any] | None:
        candidates = [f" {option_text}", option_text, f" {option_text.capitalize()}", option_text.capitalize()]
        for candidate in top_candidates:
            if candidate.get("tokenText") in candidates:
                return copy.deepcopy(candidate)
        for token_text in candidates:
            resolved_candidate = build_resolved_candidate((resolved_tokens or {}).get(token_text), token_text)
            if resolved_candidate is not None:
                return resolved_candidate
        return None

    left_candidate = find_candidate(left_text)
    right_candidate = find_candidate(right_text)
    if left_candidate is None or right_candidate is None:
        return None
    if int(left_candidate["token"]) == int(right_candidate["token"]):
        return None
    return [left_candidate, right_candidate]


def extract_prompt_choice_token_texts(prompt_text: str) -> list[str]:
    normalized = " ".join(prompt_text.strip().split())
    lower = normalized.lower()
    markers = ("choose exactly one word:", "answer with exactly one word:")
    selected_marker = next((marker for marker in markers if marker in lower), None)
    if selected_marker is None:
        return []
    start = lower.index(selected_marker) + len(selected_marker)
    tail = normalized[start:].strip()
    line = tail.split(".")[0].strip()
    if " or " not in line:
        return []
    left_text, right_text = [part.strip() for part in line.split(" or ", 1)]
    if not left_text or not right_text:
        return []
    candidates = []
    for option_text in (left_text, right_text):
        candidates.extend([f" {option_text}", option_text, f" {option_text.capitalize()}", option_text.capitalize()])
    return candidates


def collect_token_texts_to_resolve(source_fixture: dict[str, Any], answer_sets: list[dict[str, Any]]) -> list[str]:
    token_texts: list[str] = []
    seen: set[str] = set()

    def add(token_text: str | None) -> None:
        if not token_text or token_text in seen:
            return
        seen.add(token_text)
        token_texts.append(token_text)

    for answer_set in answer_sets:
        for option in answer_set.get("options") or []:
            for form in option.get("forms") or []:
                add(form.get("tokenText"))

    for prompt in source_fixture["promptCandidates"]:
        for token_text in extract_prompt_choice_token_texts(prompt["text"]):
            add(token_text)
    return token_texts


def build_prompt_groups(harvest: dict[str, Any]) -> list[dict[str, Any]]:
    groups: dict[tuple[str, int, str], list[dict[str, Any]]] = collections.defaultdict(list)
    for run in harvest.get("runs", []):
        for prompt in run.get("promptResults", []):
            groups[(prompt.get("id") or f"prompt-{prompt['promptIndex']:03d}", prompt["promptIndex"], prompt["text"])].append(
                {
                    "repeatIndex": run["repeatIndex"],
                    "status": prompt["status"],
                    "prompt": prompt,
                }
            )

    summaries: list[dict[str, Any]] = []
    for (prompt_id, prompt_index, prompt_text), entries in groups.items():
        ok_entries = [entry for entry in entries if entry["status"] == "ok"]
        if not ok_entries:
            summaries.append(
                {
                    "promptId": prompt_id,
                    "promptIndex": prompt_index,
                    "promptText": prompt_text,
                    "repeatCount": len(entries),
                    "okRepeatCount": 0,
                    "sourceStable": False,
                    "reason": "all-runs-failed",
                }
            )
            continue
        representative = ok_entries[0]["prompt"]
        prefill = representative["steps"][0]
        token_sequences = [tuple(entry["prompt"]["promptTokenIds"]) for entry in ok_entries]
        prefill_digests = [entry["prompt"]["steps"][0]["logitsSha256"] for entry in ok_entries]
        embedding_digests = [
            entry["prompt"].get("prefillEmbedding", {}).get("embeddingSha256")
            for entry in ok_entries
            if entry["prompt"].get("prefillEmbedding")
        ]
        top_memberships = [
            tuple(int(candidate["token"]) for candidate in entry["prompt"]["steps"][0]["topCandidates"])
            for entry in ok_entries
        ]
        source_stable = (
            len(set(token_sequences)) == 1
            and len(set(prefill_digests)) == 1
            and len(set(embedding_digests)) == 1
            and len(set(top_memberships)) == 1
        )
        summaries.append(
            {
                "promptId": prompt_id,
                "promptIndex": prompt_index,
                "promptText": prompt_text,
                "repeatCount": len(entries),
                "okRepeatCount": len(ok_entries),
                "sourceStable": source_stable,
                "reason": None if source_stable else "source-instability",
                "representativePrompt": representative,
                "prefillStep": prefill,
                "prefillEmbedding": representative.get("prefillEmbedding"),
            }
        )
    return sorted(summaries, key=lambda entry: entry["promptIndex"])


def evaluate_rows_case(
    *,
    prompt_group: dict[str, Any],
    case_id: str,
    candidate_source: str,
    candidate_rows: list[dict[str, Any]],
    rows_by_token: dict[int, list[float]],
    variants: list[dict[str, Any]],
    rank_bias: int,
) -> dict[str, Any] | None:
    if not prompt_group["sourceStable"]:
        return None
    prefill_embedding = prompt_group.get("prefillEmbedding")
    if not prefill_embedding or not prefill_embedding.get("embeddingArtifactPath"):
        return None
    hidden = decode_f32_buffer(resolve_repo_path(prefill_embedding["embeddingArtifactPath"]))
    candidate_token_ids = [int(candidate["token"]) for candidate in candidate_rows]
    exact_reference_logits = [exact_dot(hidden, rows_by_token[token_id]) for token_id in candidate_token_ids]
    exact_reference_index = scalar_argmax(exact_reference_logits)
    exact_reference_token_id = candidate_token_ids[exact_reference_index]
    policy_logits = {
        variant["id"]: [compute_variant_logit(variant["id"], hidden, rows_by_token[token_id]) for token_id in candidate_token_ids]
        for variant in variants
    }
    variant_summaries: dict[str, dict[str, Any]] = {}
    selected_token_ids: set[int] = set()
    for variant in variants:
        logits = policy_logits[variant["id"]]
        selected_index = scalar_argmax(logits)
        selected_token_id = candidate_token_ids[selected_index]
        selected_token_ids.add(selected_token_id)
        variant_summaries[variant["id"]] = {
            "policyId": variant["policyId"],
            "kernel": variant["kernel"],
            "selectedRowIndex": selected_index,
            "selectedTokenId": selected_token_id,
            "selectedTokenText": candidate_rows[selected_index].get("tokenText"),
            "logits": logits,
            "matchesExactReference": selected_index == exact_reference_index,
        }
    flip_observed = len(selected_token_ids) > 1
    if not flip_observed:
        return None
    stable_variant = variant_summaries["forward"]
    preferred_fast_variant_id = None
    expected_route = None
    for candidate_id in ("f16accum", "tree64", "reverse"):
        if candidate_id not in variant_summaries:
            continue
        candidate_variant = variant_summaries[candidate_id]
        if candidate_variant["selectedRowIndex"] == stable_variant["selectedRowIndex"]:
            continue
        if stable_variant["matchesExactReference"] and not candidate_variant["matchesExactReference"]:
            preferred_fast_variant_id = candidate_id
            expected_route = "prefer-stable"
            break
        if (not stable_variant["matchesExactReference"]) and candidate_variant["matchesExactReference"]:
            preferred_fast_variant_id = candidate_id
            expected_route = "accept-fast"
            break
    candidate_rows_out = []
    for index, candidate in enumerate(candidate_rows):
        candidate_rows_out.append(
            {
                "rowIndex": index,
                "tokenId": int(candidate["token"]),
                "tokenText": candidate.get("tokenText"),
                "prefillLogit": float(candidate["logit"]),
            }
        )
    return {
        "promptId": prompt_group["promptId"],
        "promptIndex": prompt_group["promptIndex"],
        "promptText": prompt_group["promptText"],
        "caseId": case_id,
        "candidateSource": candidate_source,
        "prefixSize": len(candidate_rows),
        "candidateRows": candidate_rows_out,
        "prefillTop2Gap": prompt_group["prefillStep"].get("top2Gap"),
        "prefillEmbeddingSha256": prefill_embedding["embeddingSha256"],
        "prefillEmbeddingArtifactPath": prefill_embedding["embeddingArtifactPath"],
        "exactReferenceRowIndex": exact_reference_index,
        "exactReferenceTokenId": exact_reference_token_id,
        "exactReferenceTokenText": candidate_rows[exact_reference_index].get("tokenText"),
        "exactReferenceLogits": exact_reference_logits,
        "variants": variant_summaries,
        "preferredFastVariantId": preferred_fast_variant_id,
        "expectedRouteDecision": expected_route,
        "flipObserved": True,
        "rankScore": (
            rank_bias,
            0 if expected_route == "prefer-stable" else
            1 if expected_route == "accept-fast" else
            2,
            math.inf if prompt_group["prefillStep"].get("top2Gap") is None else prompt_group["prefillStep"]["top2Gap"],
            len(candidate_rows),
            prompt_group["promptIndex"],
        ),
    }


def evaluate_prefix_candidate_case(
    *,
    prompt_group: dict[str, Any],
    prefix_size: int,
    rows_by_token: dict[int, list[float]],
    variants: list[dict[str, Any]],
) -> dict[str, Any] | None:
    top_candidates = prompt_group["prefillStep"]["topCandidates"]
    if len(top_candidates) < prefix_size:
        return None
    selected_rows = copy.deepcopy(top_candidates[:prefix_size])
    if not all(is_meaningful_token_text(candidate.get("tokenText")) for candidate in selected_rows):
        return None
    return evaluate_rows_case(
        prompt_group=prompt_group,
        case_id=f"top-prefix-{prefix_size}",
        candidate_source="top-prefix",
        candidate_rows=selected_rows,
        rows_by_token=rows_by_token,
        variants=variants,
        rank_bias=3,
    )


def match_answer_set_rows(
    prompt_text: str,
    top_candidates: list[dict[str, Any]],
    answer_set: dict[str, Any],
    resolved_tokens: dict[str, Any] | None = None,
) -> list[dict[str, Any]] | None:
    lowered_prompt = prompt_text.lower()
    prompt_anchors = [str(anchor).lower() for anchor in answer_set.get("promptAnchors") or []]
    if prompt_anchors and not any(anchor in lowered_prompt for anchor in prompt_anchors):
        return None
    resolved: list[dict[str, Any]] = []
    used_tokens: set[int] = set()
    for option in answer_set.get("options") or []:
        selected = None
        for form in option.get("forms") or []:
            token_text = form.get("tokenText")
            if not token_text:
                continue
            for candidate in top_candidates:
                if int(candidate["token"]) in used_tokens:
                    continue
                if candidate.get("tokenText") == token_text:
                    selected = copy.deepcopy(candidate)
                    break
            if selected is None:
                selected = build_resolved_candidate((resolved_tokens or {}).get(token_text), token_text)
            if selected is not None:
                break
        if selected is None:
            return None
        selected["answerSetOptionId"] = option.get("id")
        selected["answerSetOptionLabel"] = option.get("label")
        used_tokens.add(int(selected["token"]))
        resolved.append(selected)
    return resolved if len(resolved) >= 2 else None


def rank_candidate_cases(cases: list[dict[str, Any]]) -> list[dict[str, Any]]:
    return sorted(cases, key=lambda entry: entry["rankScore"])


def f32_bits(values: list[float]) -> list[int]:
    return [struct.unpack("<I", struct.pack("<f", float(value)))[0] for value in values]


def build_commands(hidden: list[float], weight_rows: list[list[float]], *, kernel: str) -> list[dict[str, Any]]:
    row_count = len(weight_rows)
    col_count = len(hidden)
    flattened_weights: list[float] = []
    for row in weight_rows:
        if len(row) != col_count:
            raise ValueError("weight row width mismatch")
        flattened_weights.extend(row)
    return [
        {"kind": "buffer_write", "handle": 4201, "bufferSize": 16, "data": [row_count, col_count, 0, 0]},
        {"kind": "buffer_write", "handle": 4202, "bufferSize": col_count * 4, "data": f32_bits(hidden)},
        {
            "kind": "buffer_write",
            "handle": 4203,
            "bufferSize": row_count * col_count * 4,
            "data": f32_bits(flattened_weights),
        },
        {"kind": "buffer_write", "handle": 4210, "bufferSize": 16, "data": [row_count, 0, 0, 0]},
        {
            "kind": "kernel_dispatch",
            "kernel": kernel,
            "x": row_count,
            "y": 1,
            "z": 1,
            "initialize_buffers_on_create": True,
            "bindings": [
                {"binding": 0, "group": 0, "kind": "buffer", "buffer_type": "uniform", "resource_handle": 4201, "buffer_size": 16, "visibility": "compute"},
                {"binding": 1, "group": 0, "kind": "buffer", "buffer_type": "readonly", "resource_handle": 4202, "buffer_size": col_count * 4, "visibility": "compute"},
                {"binding": 2, "group": 0, "kind": "buffer", "buffer_type": "readonly", "resource_handle": 4203, "buffer_size": row_count * col_count * 4, "visibility": "compute"},
                {"binding": 3, "group": 0, "kind": "buffer", "buffer_type": "storage", "resource_handle": 4204, "buffer_size": row_count * 4, "visibility": "compute"},
            ],
        },
        {
            "kind": "kernel_dispatch",
            "kernel": "sample.wgsl",
            "x": 1,
            "y": 1,
            "z": 1,
            "initialize_buffers_on_create": True,
            "bindings": [
                {"binding": 0, "group": 0, "kind": "buffer", "buffer_type": "uniform", "resource_handle": 4210, "buffer_size": 16, "visibility": "compute"},
                {"binding": 1, "group": 0, "kind": "buffer", "buffer_type": "readonly", "resource_handle": 4204, "buffer_size": row_count * 4, "visibility": "compute"},
                {"binding": 2, "group": 0, "kind": "buffer", "buffer_type": "storage", "resource_handle": 4205, "buffer_size": 4, "visibility": "compute"},
            ],
        },
    ]


def run_python_runner(script_path: Path, args: list[str]) -> str:
    completed = subprocess.run(
        ["python3", str(script_path), *args],
        cwd=REPO_ROOT,
        check=False,
        capture_output=True,
        text=True,
    )
    if completed.returncode != 0:
        raise RuntimeError(
            f"{script_path.name} failed\nstdout:\n{completed.stdout}\n\nstderr:\n{completed.stderr}"
        )
    return completed.stdout.strip()


def promote_case(
    fixture: dict[str, Any],
    case: dict[str, Any],
    *,
    harvest: dict[str, Any],
    model_root: Path,
    manifest: dict[str, Any],
    output_dir: Path,
    timestamp: str,
) -> dict[str, Any]:
    promotion = fixture["promotion"]
    kernel_root = resolve_repo_path(promotion["kernelRoot"])
    variants = promotion["variants"]
    candidate_token_ids = [entry["tokenId"] for entry in case["candidateRows"]]
    tensor_name = resolve_tensor_name(manifest)
    row_reader = TensorRowReader(model_root, manifest, tensor_name)
    try:
        rows_by_token = row_reader.read_rows(candidate_token_ids)
    finally:
        row_reader.close()
    hidden = decode_f32_buffer(resolve_repo_path(case["prefillEmbeddingArtifactPath"]))
    case_dir = output_dir / f"{case['promptId']}-prefix{case['prefixSize']}"
    case_dir.mkdir(parents=True, exist_ok=True)

    variant_entries: list[dict[str, Any]] = []
    for variant in variants:
        commands = build_commands(
            hidden,
            [rows_by_token[token_id] for token_id in candidate_token_ids],
            kernel=variant["kernel"],
        )
        commands_path = case_dir / f"{case['promptId']}.{variant['id']}.commands.json"
        commands_path.write_text(json.dumps(commands, indent=2) + "\n", encoding="utf-8")
        variant_entries.append(
            {
                "id": variant["id"],
                "policyId": variant["policyId"],
                "commandsPath": relative_or_absolute(commands_path),
            }
        )

    reduction_fixture = {
        "scenarioId": f"{fixture['scenarioId']}_{case['promptId']}_prefix{case['prefixSize']}",
        "description": (
            "Real prompt LM-head slice reduction-order counterexample: same final-norm hidden state, "
            "same real candidate rows, different accumulation policies, different selected row."
        ),
        "kernelRoot": relative_or_absolute(kernel_root),
        "profile": promotion["profile"],
        "queueWaitMode": promotion["queueWaitMode"],
        "queueSyncMode": promotion["queueSyncMode"],
        "backendLanes": promotion["backendLanes"],
        "defaultRunCount": int(promotion.get("defaultRunCount", 3)),
        "candidateRows": case["candidateRows"],
        "sourcePromptId": case["promptId"],
        "sourcePromptText": case["promptText"],
        "sourceEmbeddingSha256": case["prefillEmbeddingSha256"],
        "logitsSemanticOpId": "matmul.logits",
        "selectedTokenSemanticOpId": "sample.token",
        "exactReferenceLogits": case["exactReferenceLogits"],
        "exactReferenceTopToken": case["exactReferenceRowIndex"],
        "captures": [
            {
                "commandIndex": 4,
                "semanticOpId": "matmul.logits",
                "semanticStage": "real_lm_head_slice",
                "semanticPhase": "logits",
                "captureBufferHandle": 4204,
                "captureOffset": 0,
                "captureSize": len(case["candidateRows"]) * 4,
            },
            {
                "commandIndex": 5,
                "semanticOpId": "sample.token",
                "semanticStage": "real_lm_head_slice",
                "semanticPhase": "sample_token",
                "captureBufferHandle": 4205,
                "captureOffset": 0,
                "captureSize": 4,
                "decode": "u32le",
            },
        ],
        "variants": variant_entries,
    }
    reduction_fixture_path = case_dir / f"{reduction_fixture['scenarioId']}.fixture.json"
    reduction_fixture_path.write_text(json.dumps(reduction_fixture, indent=2) + "\n", encoding="utf-8")

    reduction_stdout = run_python_runner(
        REDUCTION_ORDER_RUNNER,
        [
            "--fixture",
            str(reduction_fixture_path),
            "--runs",
            str(promotion.get("defaultRunCount", 3)),
            "--timestamp",
            timestamp,
            "--output-root",
            str(promotion.get("reductionOutputRoot", REPO_ROOT / "bench" / "out" / "apple-metal-reduction-order-logit-flip")),
        ],
    )
    reduction_report_path = Path(reduction_stdout.splitlines()[-1].strip())
    reduction_report = load_json(reduction_report_path)

    fast_variant_id = case["preferredFastVariantId"]
    selective_fixture = {
        "scenarioId": f"{reduction_fixture['scenarioId']}_selective_stable_rerun",
        "description": "Selective stable-rerun route over a real prompt LM-head slice counterexample.",
        "policyRegistryPath": promotion["policyRegistryPath"],
        "triggerPolicyId": promotion["triggerPolicyId"],
        "routingPolicyId": promotion["routingPolicyId"],
        "operatorFamily": "lm-head-slice",
        "fastVariantId": fast_variant_id,
        "stableVariantId": "forward",
        "selectedTokenOpId": "sample.token",
        "sensitiveOperators": ["matmul.logits"],
    }
    selective_fixture_path = case_dir / f"{selective_fixture['scenarioId']}.fixture.json"
    selective_fixture_path.write_text(json.dumps(selective_fixture, indent=2) + "\n", encoding="utf-8")
    selective_stdout = run_python_runner(
        SELECTIVE_RERUN_RUNNER,
        [
            "--fixture",
            str(selective_fixture_path),
            "--source-report",
            str(reduction_report_path),
            "--timestamp",
            timestamp,
            "--output-root",
            str(promotion.get("selectiveOutputRoot", REPO_ROOT / "bench" / "out" / "apple-metal-selective-stable-rerun")),
        ],
    )
    selective_report_path = Path(selective_stdout.splitlines()[-1].strip())
    selective_report = load_json(selective_report_path)
    return {
        "promptId": case["promptId"],
        "promptText": case["promptText"],
        "candidateRows": case["candidateRows"],
        "expectedRouteDecision": case["expectedRouteDecision"],
        "preferredFastVariantId": fast_variant_id,
        "reductionFixturePath": relative_or_absolute(reduction_fixture_path),
        "reductionReportPath": relative_or_absolute(reduction_report_path),
        "reductionClaim": reduction_report["claim"],
        "selectiveFixturePath": relative_or_absolute(selective_fixture_path),
        "selectiveReportPath": relative_or_absolute(selective_report_path),
        "selectiveClaim": selective_report["claim"],
    }


def main() -> int:
    args = parse_args()
    fixture_path = resolve_repo_path(args.fixture)
    fixture = load_json(fixture_path)
    ensure_fixture_shape(fixture)

    source_fixture_path = resolve_repo_path(fixture["sourceRealLogitFixturePath"])
    source_fixture = load_json(source_fixture_path)
    ensure_source_fixture_shape(source_fixture)
    answer_set_registry = (
        load_json(resolve_repo_path(fixture["answerSetRegistryPath"]))
        if fixture.get("answerSetRegistryPath")
        else None
    )
    answer_sets = resolve_model_answer_sets(answer_set_registry, model_id=source_fixture["modelId"]) if answer_set_registry else []
    token_texts_to_resolve = collect_token_texts_to_resolve(source_fixture, answer_sets)

    stamp = timestamp_label(args.timestamp)
    output_dir = resolve_repo_path(args.output_root) / stamp
    output_dir.mkdir(parents=True, exist_ok=True)

    repeat_count = args.runs or int(source_fixture["defaultRepeatCount"])
    helper_config = build_helper_config(
        source_fixture,
        output_dir=output_dir,
        repeat_count=repeat_count,
        token_texts_to_resolve=token_texts_to_resolve,
    )
    harvest = run_helper(helper_config, work_dir=output_dir)
    harvest_path = output_dir / f"{fixture['scenarioId']}.harvest.json"
    harvest_path.write_text(json.dumps(harvest, indent=2) + "\n", encoding="utf-8")

    model_root = resolve_repo_path(source_fixture["modelArtifactPath"])
    manifest = load_json(model_root / "manifest.json")
    resolved_tokens = harvest.get("resolvedTokens") or {}
    tensor_name = resolve_tensor_name(manifest)
    prompt_groups = build_prompt_groups(harvest)
    stable_groups = [group for group in prompt_groups if group.get("sourceStable")]

    candidate_token_ids: set[int] = set()
    for group in stable_groups:
        prompt_choice_rows = extract_prompt_choice_rows(group["promptText"], group["prefillStep"]["topCandidates"], resolved_tokens)
        if prompt_choice_rows:
            for candidate in prompt_choice_rows:
                candidate_token_ids.add(int(candidate["token"]))
        for prefix_size in fixture["topCandidatePrefixes"]:
            top_candidates = group["prefillStep"]["topCandidates"]
            if len(top_candidates) < prefix_size:
                continue
            for candidate in top_candidates[:prefix_size]:
                candidate_token_ids.add(int(candidate["token"]))
        for answer_set in answer_sets:
            matched_rows = match_answer_set_rows(group["promptText"], group["prefillStep"]["topCandidates"], answer_set, resolved_tokens)
            if not matched_rows:
                continue
            for candidate in matched_rows:
                candidate_token_ids.add(int(candidate["token"]))

    row_reader = TensorRowReader(model_root, manifest, tensor_name)
    try:
        rows_by_token = row_reader.read_rows(sorted(candidate_token_ids))
    finally:
        row_reader.close()

    variants = fixture["promotion"]["variants"]
    all_cases: list[dict[str, Any]] = []
    for group in stable_groups:
        prompt_choice_rows = extract_prompt_choice_rows(group["promptText"], group["prefillStep"]["topCandidates"], resolved_tokens)
        if prompt_choice_rows:
            case = evaluate_rows_case(
                prompt_group=group,
                case_id="prompt-choice",
                candidate_source="prompt-choice",
                candidate_rows=prompt_choice_rows,
                rows_by_token=rows_by_token,
                variants=variants,
                rank_bias=0,
            )
            if case is not None:
                all_cases.append(case)
        for prefix_size in fixture["topCandidatePrefixes"]:
            case = evaluate_prefix_candidate_case(
                prompt_group=group,
                prefix_size=int(prefix_size),
                rows_by_token=rows_by_token,
                variants=variants,
            )
            if case is not None:
                all_cases.append(case)
        for answer_set in answer_sets:
            matched_rows = match_answer_set_rows(group["promptText"], group["prefillStep"]["topCandidates"], answer_set, resolved_tokens)
            if not matched_rows:
                continue
            case = evaluate_rows_case(
                prompt_group=group,
                case_id=answer_set["id"],
                candidate_source="answer-set",
                candidate_rows=matched_rows,
                rows_by_token=rows_by_token,
                variants=variants,
                rank_bias=1,
            )
            if case is not None:
                case["answerSetId"] = answer_set["id"]
                case["answerSetDescription"] = answer_set.get("description")
                all_cases.append(case)

    ranked_cases = rank_candidate_cases(all_cases)
    promoted: list[dict[str, Any]] = []
    for case in ranked_cases[: int(fixture["promotion"].get("maxPromotedCases", 1))]:
        if not case["preferredFastVariantId"]:
            continue
        promoted.append(
            promote_case(
                fixture,
                case,
                harvest=harvest,
                model_root=model_root,
                manifest=manifest,
                output_dir=output_dir,
                timestamp=stamp,
            )
        )

    report = {
        "schemaVersion": 1,
        "source": "doe-real-lm-head-slice-hunt",
        "scenarioId": fixture["scenarioId"],
        "fixturePath": relative_or_absolute(fixture_path),
        "sourceRealLogitFixturePath": relative_or_absolute(source_fixture_path),
        "timestamp": stamp,
        "harvestPath": relative_or_absolute(harvest_path),
        "answerSetRegistryPath": relative_or_absolute(resolve_repo_path(fixture["answerSetRegistryPath"])) if fixture.get("answerSetRegistryPath") else None,
        "tensorName": tensor_name,
        "promptGroups": prompt_groups,
        "summary": {
            "sourcePromptCount": len(prompt_groups),
            "stablePromptCount": len(stable_groups),
            "candidateCaseCount": len(all_cases),
            "topCandidates": ranked_cases[: args.top_candidates],
            "promotedCaseCount": len(promoted),
            "promotedCases": promoted,
        },
    }
    report_path = output_dir / f"{fixture['scenarioId']}.real-lm-head-slice-hunt.json"
    report_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"reportPath": relative_or_absolute(report_path), "promotedCases": promoted}, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
