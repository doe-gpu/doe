from __future__ import annotations

import copy
import json
import math
import re
import struct
import tempfile
from pathlib import Path
from typing import Any

from bench.lib.bench_utils import load_json as load_bench_json


REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_RUNTIME_CANDIDATES = [
    REPO_ROOT / "runtime" / "zig" / "zig-out" / "bin" / "doe-zig-runtime",
    REPO_ROOT / "runtime" / "zig-out" / "bin" / "doe-zig-runtime",
]
RECEIPT_FILE_NAME = "sampled-decode.trace-meta.json.numeric-stability.jsonl"
TRACE_META_FILE_NAME = "sampled-decode.trace-meta.json"
TRACE_JSONL_FILE_NAME = "sampled-decode.trace.jsonl"
COMMANDS_FILE_NAME = "sampled-decode.commands.json"
CASE_REPORT_FILE_NAME = "sampled-decode.case.json"
MANIFEST_FILE_NAME = "sampled_decode_harvest.manifest.json"
TOKEN_INDEX_PATTERN = re.compile(r"(?:\.t|\.tok|\.step)(\d+)$")
JSON_BOOLEAN_WORDS = {"true", "false", "null"}
POLICY_ACTION_WORDS = {
    "allow",
    "block",
    "approve",
    "approved",
    "deny",
    "denied",
    "go",
    "stop",
    "public",
    "private",
    "internal",
    "external",
    "release",
    "redact",
    "accept",
    "reject",
    "keep",
}
MODERATION_WORDS = {"safe", "unsafe", "spam", "phishing", "allow", "block"}
SHORT_ANSWER_WORDS = {"yes", "no", "keep", "flip"}


def load_json(path: Path) -> Any:
    return load_bench_json(path)


def load_jsonl(path: Path) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    with path.open("r", encoding="utf-8") as handle:
        for line_number, line in enumerate(handle, start=1):
            stripped = line.strip()
            if not stripped:
                continue
            payload = json.loads(stripped)
            if not isinstance(payload, dict):
                raise ValueError(f"{path}:{line_number} must be a JSON object per line")
            rows.append(payload)
    return rows


def write_json(path: Path, payload: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(
        "w",
        encoding="utf-8",
        dir=path.parent,
        prefix=f".{path.name}.",
        suffix=".tmp",
        delete=False,
    ) as handle:
        handle.write(json.dumps(payload, indent=2) + "\n")
        temp_path = Path(handle.name)
    temp_path.replace(path)


def write_jsonl(path: Path, rows: list[dict[str, Any]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(
        "w",
        encoding="utf-8",
        dir=path.parent,
        prefix=f".{path.name}.",
        suffix=".tmp",
        delete=False,
    ) as handle:
        for row in rows:
            handle.write(json.dumps(row))
            handle.write("\n")
        temp_path = Path(handle.name)
    temp_path.replace(path)


def repo_rel(path_value: str | Path | None) -> str | None:
    if path_value is None:
        return None
    path = Path(path_value)
    absolute = path if path.is_absolute() else (REPO_ROOT / path)
    absolute = absolute.resolve()
    try:
        return str(absolute.relative_to(REPO_ROOT.resolve()))
    except ValueError:
        return str(absolute)


def find_runtime_bin(explicit_path: str | None) -> Path:
    candidates: list[Path] = []
    if explicit_path:
        candidates.append(Path(explicit_path))
    candidates.extend(DEFAULT_RUNTIME_CANDIDATES)
    for candidate in candidates:
        if candidate.exists():
            return candidate
    raise FileNotFoundError(
        "doe-zig-runtime not found; build it with `zig build doe-runtime` or pass --runtime-bin"
    )


def float_to_u32_word(value: float) -> int:
    return struct.unpack("<I", struct.pack("<f", float(value)))[0]


def split_u64_words(value: int) -> tuple[int, int]:
    masked = int(value) & 0xFFFFFFFFFFFFFFFF
    return masked & 0xFFFFFFFF, (masked >> 32) & 0xFFFFFFFF


def encode_sample_uniform(
    *,
    vocab_size: int,
    temperature: float,
    top_k: int,
    top_p: float,
    rng_seed: int,
    rng_draw: float,
) -> list[int]:
    seed_lo, seed_hi = split_u64_words(rng_seed)
    return [
        int(vocab_size),
        int(top_k),
        float_to_u32_word(top_p),
        float_to_u32_word(temperature),
        seed_lo,
        seed_hi,
        float_to_u32_word(rng_draw),
        1,
    ]


def buffer_binding_handle(dispatch: dict[str, Any], binding_index: int) -> int:
    for binding in dispatch.get("bindings") or []:
        if int(binding.get("binding", -1)) == binding_index:
            return int(binding["resource_handle"])
    raise ValueError(f"dispatch is missing binding {binding_index}")


def kernel_basename(command: dict[str, Any]) -> str | None:
    kernel = command.get("kernel")
    if not isinstance(kernel, str):
        return None
    return Path(kernel).name


def find_prior_buffer_write_index(commands: list[dict[str, Any]], handle: int) -> int:
    for index in range(len(commands) - 1, -1, -1):
        command = commands[index]
        if command.get("kind") != "buffer_write":
            continue
        if int(command.get("handle", -1)) == handle:
            return index
    raise ValueError(f"buffer_write for handle {handle} not found")


def is_candidate_final_logits_dispatch(command: dict[str, Any], logits_handle: int) -> bool:
    if command.get("kind") != "kernel_dispatch":
        return False
    for binding in command.get("bindings") or []:
        if int(binding.get("resource_handle", -1)) != logits_handle:
            continue
        if str(binding.get("buffer_type", "")).lower() in {"storage", "read_write"}:
            return True
        if int(binding.get("binding", -1)) == 3:
            return True
    return False


def find_prior_final_logits_index(commands: list[dict[str, Any]], logits_handle: int) -> int:
    for index in range(len(commands) - 1, -1, -1):
        if is_candidate_final_logits_dispatch(commands[index], logits_handle):
            return index
    raise ValueError(f"final logits dispatch for handle {logits_handle} not found")


def patch_commands_for_sampled_decode(
    commands: list[dict[str, Any]],
    *,
    semantic_stage: str,
    sample_config: dict[str, Any],
    max_sample_steps: int | None,
) -> list[dict[str, Any]]:
    patched = copy.deepcopy(commands)
    result: list[dict[str, Any]] = []
    sample_step_count = 0
    for command in patched:
        if command.get("kind") != "kernel_dispatch" or kernel_basename(command) != "sample.wgsl":
            result.append(command)
            continue
        if max_sample_steps is not None and sample_step_count >= max_sample_steps:
            break

        uniform_handle = buffer_binding_handle(command, 0)
        logits_handle = buffer_binding_handle(command, 1)
        uniform_index = find_prior_buffer_write_index(result, uniform_handle)
        uniform_command = result[uniform_index]
        uniform_words = list(uniform_command.get("data") or [])
        if not uniform_words:
            raise ValueError(f"sample uniform buffer_write for handle {uniform_handle} has no data")
        vocab_size = int(uniform_words[0])
        uniform_command["bufferSize"] = 32
        uniform_command["data"] = encode_sample_uniform(
            vocab_size=vocab_size,
            temperature=float(sample_config["temperature"]),
            top_k=int(sample_config["topK"]),
            top_p=float(sample_config["topP"]),
            rng_seed=int(sample_config["rngSeed"]),
            rng_draw=float(sample_config["rngDraw"]),
        )

        final_logits_index = find_prior_final_logits_index(result, logits_handle)
        final_logits = result[final_logits_index]
        step_stage = f"{semantic_stage}.t{sample_step_count}"
        final_logits["semanticOpId"] = "decode.final_logits"
        final_logits["semanticStage"] = step_stage
        final_logits["semanticPhase"] = "final_logits"
        final_logits["semanticTokenIndex"] = sample_step_count

        command["bindings"][0]["buffer_size"] = 32
        command["semanticOpId"] = "decode.sample_token"
        command["semanticStage"] = step_stage
        command["semanticPhase"] = "sample_token"
        command["semanticTokenIndex"] = sample_step_count
        result.append(command)
        sample_step_count += 1
    return result


def receipt_matches_decode_boundary(receipt: dict[str, Any]) -> bool:
    return (
        receipt.get("semanticOpId") == "decode.sample_token"
        or str(receipt.get("semanticOpId", "")).startswith("decode.sample_token.")
        or receipt.get("semanticPhase") == "sample_token"
        or receipt.get("operatorFamily") == "decode-sample-token"
    )


def decode_step_index(receipt: dict[str, Any]) -> int:
    for value in (receipt.get("semanticOpId"), receipt.get("semanticStage")):
        match = TOKEN_INDEX_PATTERN.search(str(value or ""))
        if match:
            return int(match.group(1))
    return int(receipt.get("semanticTokenIndex") or 0)


def decode_step_key(receipt: dict[str, Any]) -> str:
    return f"{receipt.get('semanticStage') or 'decode'}::{receipt.get('semanticOpId') or 'decode.sample_token'}"


def decode_rows_by_step(receipts: list[dict[str, Any]]) -> list[dict[str, Any]]:
    rows = [receipt for receipt in receipts if receipt_matches_decode_boundary(receipt)]
    return sorted(rows, key=decode_step_index)


def selected_token_changed(receipt: dict[str, Any]) -> bool:
    metrics = ((receipt.get("decodeBoundary") or {}).get("metrics") or {})
    if metrics.get("actualSelectedTokenChanged") is not None:
        return bool(metrics["actualSelectedTokenChanged"])
    selected = receipt.get("selectedToken") or {}
    return (
        int(selected.get("fast", -1)) != int(selected.get("stable", -1))
        or int(selected.get("fast", -1)) != int(selected.get("reference", -1))
    )


def receipt_repeat_signature(receipt: dict[str, Any]) -> tuple[Any, ...]:
    metrics = ((receipt.get("decodeBoundary") or {}).get("metrics") or {})
    selected = receipt.get("selectedToken") or {}
    boundary = receipt.get("decodeBoundary") or {}
    route = receipt.get("route") or {}
    return (
        int(selected.get("fast", -1)),
        int(selected.get("stable", -1)),
        int(selected.get("reference", -1)),
        int(boundary.get("liveSelectedToken", -1)),
        bool(metrics.get("actualSelectedTokenChanged")),
        route.get("decision"),
    )


def adjacent_decode_persistence(receipts: list[dict[str, Any]], start_index: int, max_steps: int) -> int:
    persistence = 0
    for offset in range(1, max_steps + 1):
        target = start_index + offset
        if target >= len(receipts):
            break
        if not selected_token_changed(receipts[target]):
            break
        persistence += 1
    return persistence


def suffix_replay_override(receipts: list[dict[str, Any]], start_index: int, max_steps: int) -> dict[str, Any]:
    available_steps = max(0, min(len(receipts) - start_index - 1, max_steps))
    if available_steps == 0:
        return {"available": False, "divergent": False, "replayStepCount": None}
    divergent = any(
        selected_token_changed(receipts[start_index + offset])
        for offset in range(1, available_steps + 1)
    )
    return {
        "available": True,
        "divergent": divergent,
        "replayStepCount": available_steps,
    }


def normalize_token_text(value: str | None) -> str | None:
    if value is None:
        return None
    stripped = str(value).strip()
    if not stripped:
        return None
    if stripped[:1] in {"\"", "'"} and stripped[-1:] == stripped[:1] and len(stripped) >= 2:
        stripped = stripped[1:-1].strip()
    return stripped or None


def canonical_token_form(value: str | None) -> str | None:
    normalized = normalize_token_text(value)
    if normalized is None:
        return None
    return re.sub(r"[^a-z0-9_]+", "", normalized.lower()) or None


def meaningful_token_class(selected_token_text: dict[str, Any], semantic_priority_class: str) -> str:
    token_forms = {
        form
        for form in (
            canonical_token_form(selected_token_text.get("fast")),
            canonical_token_form(selected_token_text.get("stable")),
            canonical_token_form(selected_token_text.get("reference")),
        )
        if form is not None
    }
    if any(form in JSON_BOOLEAN_WORDS for form in token_forms):
        return "json-literal"
    if any(form in {"public", "private", "internal", "external", "release", "redact"} for form in token_forms):
        return "visibility-label"
    if any(form in {"approve", "approved", "deny", "denied", "accept", "reject"} for form in token_forms):
        return "approval-label"
    if any(form in MODERATION_WORDS for form in token_forms):
        return "moderation-label"
    if any(form in POLICY_ACTION_WORDS for form in token_forms):
        return "policy-action-word"
    if semantic_priority_class == "tool-choice" or any("_" in form for form in token_forms):
        return "tool-identifier"
    return "whole-word-answer"


def semantic_scenario_bucket(selected_token_text: dict[str, Any], semantic_priority_class: str) -> str:
    token_forms = {
        form
        for form in (
            canonical_token_form(selected_token_text.get("fast")),
            canonical_token_form(selected_token_text.get("stable")),
            canonical_token_form(selected_token_text.get("reference")),
        )
        if form is not None
    }
    if semantic_priority_class == "tool-choice":
        return "tool-choice"
    if any(form in JSON_BOOLEAN_WORDS for form in token_forms):
        return "json-boolean"
    if any(form in {"public", "private", "internal", "external", "release", "redact"} for form in token_forms):
        return "visibility-label"
    if any(form in {"approve", "approved", "deny", "denied", "accept", "reject"} for form in token_forms):
        return "approval-label"
    if any(form in MODERATION_WORDS for form in token_forms):
        return "moderation-label"
    return "policy-action"


def backend_match(receipt: dict[str, Any], backend: dict[str, Any]) -> bool:
    execution_identity = receipt.get("executionIdentity") or {}
    return (
        execution_identity.get("profileVendor") == backend["vendor"]
        and execution_identity.get("profileApi") == backend["api"]
        and execution_identity.get("profileFamily") == backend["family"]
        and execution_identity.get("profileDriver") == backend["driver"]
    )


def summarize_rank_counts(ranked_cases: list[dict[str, Any]]) -> dict[str, int]:
    counts = {"promotable": 0, "investigate": 0, "reject": 0}
    for case in ranked_cases:
        bucket = str(case["rankingBucket"])
        counts[bucket] = counts.get(bucket, 0) + 1
    return counts


def relative_or_absolute(path: Path) -> str:
    absolute = path.resolve()
    try:
        return str(absolute.relative_to(REPO_ROOT.resolve()))
    except ValueError:
        return str(absolute)


def cdf_distance_metrics(receipt: dict[str, Any]) -> float | None:
    metrics = ((receipt.get("decodeBoundary") or {}).get("metrics") or {})
    value = metrics.get("cdfDistanceToDraw")
    return None if value is None else float(value)


def case_sort_key(case: dict[str, Any]) -> tuple[float, str]:
    cdf_distance = cdf_distance_metrics(case)
    boundary = math.inf if cdf_distance is None else cdf_distance
    return (boundary, str(case.get("caseId") or ""))
