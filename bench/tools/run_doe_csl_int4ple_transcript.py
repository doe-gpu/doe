#!/usr/bin/env python3
"""Emit the Doe CSL INT4 PLE transcript receipt.

This is the governed front door for the missing proof producer. Today it emits
an explicit blocked receipt because the production INT4 PLE prefill/decode CSL
lowering is not implemented. The receipt shape is intentionally the same shape
the future simfabric runner must populate when it exists.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import jsonschema

REPO_ROOT = Path(__file__).resolve().parents[2]
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from bench.tools.doe_csl_host_io_layout import attach_host_io_layout
from bench.tools.int4ple_manifest_compile_params import (
    apply_manifest_compile_params,
    manifest_compile_param_projection,
)
from bench.tools.int4ple_runtime_weight_mappings import (
    infer_layer_index_from_steps,
    inferred_rmsnorm_weight_key,
    layer_index_from_step_weight_key,
    required_weight_keys,
    tensor_name_candidates_for_weight_key,
    tensor_name_for_weight_key,
)

FIXTURE_REGISTRY = Path("config/csl-runtime-fixtures.json")
HOST_PLAN_TOOL = Path("runtime/zig/zig-out/bin/doe-csl-host-plan-tool")
DEFAULT_HOSTPLAN_BUNDLE_ROOT = Path(
    "bench/out/doppler-reference/"
    "gemma-3-1b-doe-csl-hostplan"
)
CSL_SDK_DRIVER = Path("runtime/zig/tools/csl_sdk_driver.py")
MIN_REAL_INT4PLE_RUNTIME_TIMEOUT_MS = 3_600_000
INT4PLE_COMPILE_TIMEOUT_SECONDS = 60
INT4PLE_RUNTIME_RUNNER = Path(
    "bench/runners/csl-runners/int4ple_compile_target_sim_runner.py"
)
SHARED_EXECUTION_CONTRACT_TOOL = Path(
    "bench/tools/build_doppler_shared_execution_contract.py"
)
PROGRAM_BUNDLE_SCHEMA = Path("config/doe-doppler-program-bundle.schema.json")
FLOAT32_BYTES = 4
UINT32_BYTES = 4

FIXTURE_BY_DOPPLER_KERNEL = {
    "attn_decode": "attention-decode",
    "attn_head256": "attention-tiled",
    "attn_head512": "attention-tiled",
    "embed": "gather",
    "gelu": "gelu",
    "gemv": "fused-gemv-dequant",
    "lm_head_gemv": "fused-gemv-dequant",
    "lm_head_gemv": "fused-gemv-dequant",
    "lm_head_prefill": "tiled-matmul",
    "q4_decode_gemv": "fused-gemv-dequant",
    "q4_widetile": "fused-gemv-dequant",
    "rope": "rope",
    "sample": "sample",
    "tiled": "tiled-matmul",
}

DOPPLER_KERNEL_TO_HOSTPLAN_OP = {
    "attn_decode": "attention",
    "attn_head256": "attention_prefill",
    "attn_head512": "attention_prefill",
    "embed": "embed",
    "final_norm_stable": "rmsnorm",
    "gelu": "gelu",
    "gemv": "matmul_q4k",
    "lm_head_gemv": "matmul_q4k",
    "lm_head_gemv": "matmul_q4k",
    "lm_head_prefill": "matmul",
    "q4_decode_gemv": "matmul_q4k",
    "q4_widetile": "matmul_q4k",
    "residual": "residual",
    "rmsnorm": "rmsnorm",
    "rope": "rope",
    "sample": "sample",
    "tiled": "matmul",
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--reference-export",
        default=(
            "bench/out/doppler-reference/"
            "program-bundle-export/"
            "doppler_program_bundle_reference_export.json"
        ),
    )
    parser.add_argument(
        "--program-bundle",
        default=None,
        help=(
            "Optional Doppler-owned Program Bundle source. When present, Doe "
            "derives the HostPlan projection from this bundle instead of the "
            "older local reference-export graph hash."
        ),
    )
    parser.add_argument(
        "--schema",
        default="config/doe-csl-int4ple-transcript.schema.json",
    )
    parser.add_argument(
        "--out",
        default=(
            "bench/out/doppler-reference/"
            "gemma-4-e2b-int4ple-doe-csl-transcript.blocked.json"
        ),
    )
    parser.add_argument(
        "--fixture-registry",
        default=str(FIXTURE_REGISTRY),
        help="CSL fixture registry used to classify graph lowering gaps.",
    )
    parser.add_argument(
        "--hostplan-tool",
        default=str(HOST_PLAN_TOOL),
        help="Doe execution-v1 HostPlan lowering tool.",
    )
    parser.add_argument(
        "--hostplan-bundle-root",
        default=str(DEFAULT_HOSTPLAN_BUNDLE_ROOT),
        help="Output directory for the normalized HostPlan bundle.",
    )
    parser.add_argument(
        "--simulator-driver-result",
        default=None,
        help=(
            "Optional simulator driver result. Defaults to the driver-result "
            "path derived from the HostPlan bundle simulator trace path."
        ),
    )
    parser.add_argument(
        "--simulator-trace",
        default=None,
        help=(
            "Optional simulator trace. Defaults to the trace path declared by "
            "the HostPlan bundle simulator plan."
        ),
    )
    parser.add_argument(
        "--max-layers",
        type=int,
        default=-1,
        help=(
            "Optional layer-count override (>=1). When set, the HostPlan "
            "projection truncates prefill+decode to this many layers instead "
            "of using manifest.architecture.numLayers. The host-plan bundle "
            "records both the effective numLayers and the original "
            "manifestNumLayers under modelConfig, so the override is "
            "auditable from existing artifacts without rewriting the manifest. "
            "Use to produce bounded-depth simfabric receipts that exercise "
            "the full prefill+decode launch chain (including kv_write, "
            "kv_read, sample) at tractable wallclock."
        ),
    )
    return parser.parse_args()


def resolve(raw: str | Path) -> Path:
    path = Path(raw)
    return path if path.is_absolute() else (REPO_ROOT / path).resolve()


def resolve_relative(base: Path, raw: str | Path) -> Path:
    path = Path(raw)
    return path if path.is_absolute() else (base / path).resolve()


def rel(path: Path) -> str:
    try:
        return path.resolve().relative_to(REPO_ROOT).as_posix()
    except ValueError:
        return str(path.resolve())


def load_json(path: Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8"))


def write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps(value, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


def clean_directory(path: Path) -> None:
    if not path.exists():
        return
    if not path.is_dir():
        raise ValueError(f"expected directory: {path}")
    for child in path.iterdir():
        if child.is_dir():
            clean_directory(child)
            child.rmdir()
        else:
            child.unlink()


def sha256_json(value: Any) -> str:
    data = json.dumps(value, indent=2, sort_keys=True).encode("utf-8")
    return hashlib.sha256(data + b"\n").hexdigest()


def sha256_compact_json(value: Any) -> str:
    data = json.dumps(value, separators=(",", ":"), sort_keys=True).encode("utf-8")
    return hashlib.sha256(data).hexdigest()


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def schema_failures(data: Any, schema: Any) -> list[str]:
    validator = jsonschema.Draft202012Validator(schema)
    return [
        f"{'.'.join(str(p) for p in e.absolute_path) or '<root>'}: {e.message}"
        for e in sorted(
            validator.iter_errors(data),
            key=lambda item: tuple(str(p) for p in item.absolute_path),
        )
    ]


def reference_transcript_digest(export: dict[str, Any]) -> dict[str, Any]:
    transcript = export.get("decodeTranscript") or {}
    linked = transcript.get("transcript") or {}
    generated = transcript.get("generatedTokenIds") or {}
    return {
        "path": linked.get("path", "pending"),
        "sha256": linked.get("sha256", "pending"),
        "requestedDecodeSteps": transcript.get(
            "requestedDecodeSteps",
            transcript.get("decodeStepsRequested", 0),
        ),
        "actualDecodeSteps": transcript.get(
            "actualDecodeSteps",
            transcript.get("decodeStepsProduced", 0),
        ),
        "stopReason": transcript.get("stopReason", "pending"),
        "generatedTokenIdsSha256": generated.get("sha256", "pending"),
        "logitsDigestSha256": sha256_json(transcript.get("logitsDigests", [])),
    }


def strip_sha256_prefix(value: str) -> str:
    return value.removeprefix("sha256:")


def strip_doppler_hash(value: Any) -> str:
    if not isinstance(value, str) or not value:
        return "pending"
    return strip_sha256_prefix(value)


def program_bundle_repo_root(program_bundle_path: Path) -> Path:
    for parent in program_bundle_path.resolve().parents:
        if (
            (parent / "package.json").is_file()
            and (parent / "src/tooling/program-bundle.js").is_file()
        ):
            return parent
    return program_bundle_path.resolve().parent


def resolve_program_bundle_path(
    program_bundle_path: Path,
    raw_path: str,
) -> Path:
    path = Path(raw_path)
    if path.is_absolute():
        return path.resolve()
    root = program_bundle_repo_root(program_bundle_path)
    return (root / path).resolve()


def write_u32_array(path: Path, values: list[int]) -> dict[str, Any]:
    path.parent.mkdir(parents=True, exist_ok=True)
    data = b"".join(
        int(value).to_bytes(UINT32_BYTES, "little", signed=False)
        for value in values
    )
    path.write_bytes(data)
    return {
        "path": rel(path),
        "sha256": sha256_file(path),
        "dtype": "uint32",
        "tokenCount": len(values),
        "preview": values[:8],
    }


def u32_file_to_values(path: Path) -> list[int] | None:
    if not path.is_file() or path.stat().st_size % UINT32_BYTES != 0:
        return None
    data = path.read_bytes()
    values = []
    for offset in range(0, len(data), UINT32_BYTES):
        values.append(
            int.from_bytes(data[offset : offset + UINT32_BYTES], "little", signed=False)
        )
    return values


def find_tokenized_prompt_artifact(
    *,
    expected_token_ids_sha256: str,
    expected_token_count: int,
    out_dir: Path,
) -> dict[str, Any] | None:
    if not expected_token_ids_sha256 or expected_token_count <= 0:
        return None
    search_root = out_dir.parent
    candidates = sorted(search_root.glob("**/tokenized_prompt.u32"))
    candidates.extend(sorted(search_root.glob("**/*tokenized_prompt*.u32")))
    seen: set[Path] = set()
    for candidate in candidates:
        resolved = candidate.resolve()
        if resolved in seen:
            continue
        seen.add(resolved)
        values = u32_file_to_values(resolved)
        if values is None or len(values) != expected_token_count:
            continue
        if sha256_compact_json(values) != expected_token_ids_sha256:
            continue
        materialized_path = out_dir / "program_bundle_tokenized_prompt.u32"
        if resolved != materialized_path.resolve():
            shutil.copyfile(resolved, materialized_path)
        return {
            "path": rel(materialized_path),
            "sha256": sha256_file(materialized_path),
            "dtype": "uint32",
            "tokenCount": len(values),
            "preview": values[:8],
            "source": "hash_matched_program_bundle_tokenIdsHash",
            "sourcePath": rel(resolved),
            "tokenIdsSha256": expected_token_ids_sha256,
        }
    return None


def materialize_tokenized_prompt_from_doppler_tokenizer(
    *,
    program_bundle_path: Path,
    manifest_path: Path,
    manifest: dict[str, Any],
    prompt_text: str,
    expected_token_ids_sha256: str,
    expected_token_count: int,
    out_dir: Path,
) -> dict[str, Any] | None:
    if not expected_token_ids_sha256 or expected_token_count <= 0:
        return None
    tokenizer_config = manifest.get("tokenizer") or {}
    tokenizer_file = tokenizer_config.get("file")
    if not isinstance(tokenizer_file, str) or not tokenizer_file.strip():
        return None
    tokenizer_path = (manifest_path.resolve().parent / tokenizer_file).resolve()
    if not tokenizer_path.is_file():
        return None

    chat_template = (manifest.get("inference") or {}).get("chatTemplate") or {}
    use_chat_template = (
        bool(chat_template.get("enabled")) if isinstance(chat_template, dict) else False
    )
    chat_template_type = (
        str(chat_template.get("type"))
        if isinstance(chat_template, dict) and chat_template.get("type")
        else None
    )
    doppler_root = program_bundle_repo_root(program_bundle_path)
    script = f"""
import fs from 'node:fs/promises';
import {{ Tokenizer }} from {json.dumps((doppler_root / "src/inference/tokenizer.js").as_posix())};
import {{ applyChatTemplate }} from {json.dumps((doppler_root / "src/inference/pipelines/text/init-chat-templates.js").as_posix())};

console.log = () => {{}};
console.info = () => {{}};
console.warn = () => {{}};

const manifest = JSON.parse(await fs.readFile({json.dumps(manifest_path.as_posix())}, 'utf8'));
const tokenizerJson = JSON.parse(await fs.readFile({json.dumps(tokenizer_path.as_posix())}, 'utf8'));
const tokenizer = new Tokenizer();
await tokenizer.initialize(manifest, {{ loadTokenizerJson: async () => tokenizerJson }});
const promptText = {json.dumps(prompt_text)};
const useChatTemplate = {json.dumps(use_chat_template)};
const chatTemplateType = {json.dumps(chat_template_type)};
const processedPrompt = useChatTemplate && chatTemplateType
  ? applyChatTemplate(promptText, chatTemplateType)
  : promptText;
const ids = tokenizer.encode(processedPrompt).map((value) => Number(value));
process.stdout.write(JSON.stringify({{ ids }}));
"""
    completed = subprocess.run(
        ["node", "--input-type=module", "-"],
        cwd=doppler_root,
        input=script,
        text=True,
        capture_output=True,
        check=False,
        timeout=60,
    )
    if completed.returncode != 0:
        stderr = completed.stderr.strip()
        raise ValueError(
            "failed to materialize Program Bundle tokenized prompt with "
            f"Doppler tokenizer: {stderr or 'node exited non-zero'}"
        )
    try:
        payload = json.loads(completed.stdout)
    except json.JSONDecodeError as exc:
        raise ValueError(
            "Doppler tokenizer materialization emitted invalid JSON"
        ) from exc
    ids = payload.get("ids")
    if not isinstance(ids, list) or not all(isinstance(value, int) for value in ids):
        raise ValueError("Doppler tokenizer materialization did not emit token IDs")
    if len(ids) != expected_token_count:
        raise ValueError(
            "Doppler tokenizer token-count mismatch: "
            f"expected {expected_token_count}, got {len(ids)}"
        )
    actual_hash = sha256_compact_json(ids)
    if actual_hash != expected_token_ids_sha256:
        raise ValueError(
            "Doppler tokenizer token hash mismatch: "
            f"expected {expected_token_ids_sha256}, got {actual_hash}"
        )

    artifact = write_u32_array(out_dir / "program_bundle_tokenized_prompt.u32", ids)
    artifact.update(
        {
            "source": "materialized_doppler_bundled_tokenizer",
            "sourcePath": rel(tokenizer_path),
            "tokenIdsSha256": expected_token_ids_sha256,
        }
    )
    return artifact


def program_bundle_step_array(step: dict[str, Any]) -> list[str]:
    result = [str(step["op"]), str(step["kernelId"])]
    weights = step.get("weights")
    if isinstance(weights, str) and weights:
        result.append(weights)
    return result


def program_bundle_execution_graph_projection(
    program_bundle: dict[str, Any],
    export: dict[str, Any],
    manifest: dict[str, Any] | None = None,
    *,
    num_layers_override: int | None = None,
) -> dict[str, Any]:
    graph_hash = export["executionGraphSha256"]
    execution = program_bundle.get("execution") or {}
    kernels = {}
    num_layers: int | None = None
    if isinstance(manifest, dict):
        arch = manifest.get("architecture") or {}
        raw = arch.get("numLayers")
        if isinstance(raw, int) and raw > 0:
            num_layers = raw
    if num_layers_override is not None:
        if num_layers_override < 1:
            raise ValueError(
                f"num_layers_override must be >=1, got {num_layers_override}"
            )
        if num_layers is not None and num_layers_override > num_layers:
            raise ValueError(
                f"num_layers_override={num_layers_override} exceeds "
                f"manifest.architecture.numLayers={num_layers}"
            )
        num_layers = num_layers_override
    for module in program_bundle.get("wgslModules") or []:
        if not isinstance(module, dict):
            continue
        module_id = module.get("id")
        if not isinstance(module_id, str) or not module_id:
            continue
        kernels[module_id] = {
            "kernel": module.get("file", "pending"),
            "entry": module.get("entry", "main"),
            "digest": module.get("digest", "sha256:pending"),
        }

    pre_layer: list[list[str]] = []
    decode: list[list[str]] = []
    post_layer: list[list[str]] = []
    prefill_groups: list[dict[str, Any]] = []
    prefill_by_layers: dict[tuple[int, ...], dict[str, Any]] = {}

    for step in execution.get("steps") or []:
        if not isinstance(step, dict):
            continue
        section = step.get("section")
        phase = step.get("phase")
        record = program_bundle_step_array(step)
        if section == "preLayer":
            pre_layer.append(record)
        elif section == "postLayer":
            post_layer.append(record)
        elif section == "layer" and phase == "decode":
            decode.append(record)
        elif section == "layer" and phase == "prefill":
            raw_layers = step.get("layers")
            if isinstance(raw_layers, str) and raw_layers == "all":
                if num_layers is None:
                    raise ValueError(
                        f"Program Bundle prefill step declares layers=\"all\" but "
                        f"manifest.architecture.numLayers is missing: {step.get('id')}"
                    )
                raw_layers = list(range(num_layers))
            if not isinstance(raw_layers, list):
                raise ValueError(
                    f"Program Bundle prefill step lacks explicit layers: {step.get('id')}"
                )
            layers = tuple(int(layer) for layer in raw_layers)
            group = prefill_by_layers.get(layers)
            if group is None:
                group = {"layers": list(layers), "steps": []}
                prefill_by_layers[layers] = group
                prefill_groups.append(group)
            group["steps"].append(record)

    return {
        "schemaVersion": 1,
        "artifactKind": "doppler_program_bundle_execution_graph_projection",
        "source": "doppler.program-bundle.execution.steps",
        "modelId": export["modelId"],
        "manifestSha256": export["manifestSha256"],
        "programBundleId": program_bundle.get("bundleId", "pending"),
        "programBundleExecutionGraphSha256": graph_hash,
        "execution": {
            "kernels": kernels,
            "preLayer": pre_layer,
            "prefill": prefill_groups,
            "decode": decode,
            "postLayer": post_layer,
        },
    }


def normalize_program_bundle_stop_reason(raw: Any) -> str:
    if raw == "max-tokens":
        return "decode_steps_exhausted"
    if isinstance(raw, str) and raw:
        return raw
    return "pending"


def manifest_shard_identities(manifest: dict[str, Any]) -> list[dict[str, Any]]:
    identities = []
    for shard in manifest.get("shards") or []:
        if not isinstance(shard, dict):
            continue
        sha256 = shard.get("sha256") or shard.get("hash")
        filename = shard.get("filename") or shard.get("path")
        if not isinstance(sha256, str) or not isinstance(filename, str):
            continue
        identity = {
            "index": int(shard.get("index", len(identities))),
            "filename": filename,
            "sha256": strip_doppler_hash(sha256),
            "sizeBytes": int(shard.get("sizeBytes") or shard.get("size") or 0),
            "identitySource": "manifest_declared",
        }
        offset = shard.get("offsetBytes") or shard.get("offset")
        if isinstance(offset, int):
            identity["offsetBytes"] = offset
        identities.append(identity)
    if not identities:
        raise ValueError("Program Bundle manifest has no shard identities")
    return identities


def program_bundle_logits_digests(reference: dict[str, Any]) -> list[dict[str, Any]]:
    logits = reference.get("logits") or {}
    raw_steps = logits.get("steps") or []
    if not isinstance(raw_steps, list):
        return []

    digests: list[dict[str, Any]] = []
    for raw_step in raw_steps:
        if not isinstance(raw_step, dict):
            continue
        step_index = int(raw_step.get("index") or len(digests))
        element_count = int(raw_step.get("elementCount") or 0)
        dtype = str(raw_step.get("dtype") or "f32")
        digest = strip_doppler_hash(raw_step.get("digest"))
        if not digest or digest == "pending":
            continue
        if dtype not in ("f32", "float32"):
            raise ValueError(f"unsupported Program Bundle logits dtype: {dtype!r}")
        digests.append(
            {
                "stepIndex": step_index,
                "phase": "decode",
                "contextTokenCount": int(raw_step.get("inputTokenCount") or 0),
                "selectedTokenId": int(raw_step.get("tokenId") or 0),
                "dtype": "float32",
                "shape": [element_count],
                "path": (
                    "digest-only:doppler-program-bundle-reference-logits-step-"
                    f"{step_index}"
                ),
                "sha256": digest,
                "byteLength": element_count * FLOAT32_BYTES,
            }
        )
    return digests


def program_bundle_kv_cache_summary(reference: dict[str, Any]) -> dict[str, Any]:
    kv_cache = reference.get("kvCache") or {}
    byte_digests = kv_cache.get("byteDigests") or []
    return {
        "mode": kv_cache.get("mode", "not_captured"),
        "byteDigestMode": kv_cache.get("byteDigestMode", "not_captured"),
        "byteDigest": kv_cache.get("byteDigest", "pending"),
        "layerDigestCount": len(byte_digests) if isinstance(byte_digests, list) else 0,
        "seqLen": int(kv_cache.get("seqLen") or 0),
        "kvDtype": kv_cache.get("kvDtype", "pending"),
    }


def export_from_program_bundle(
    program_bundle_path: Path,
    out_dir: Path,
) -> tuple[dict[str, Any], Path]:
    program_bundle = load_json(program_bundle_path)
    if program_bundle.get("schema") != "doppler.program-bundle/v1":
        raise ValueError(
            f"unsupported Program Bundle schema: {program_bundle.get('schema')!r}"
        )
    out_dir.mkdir(parents=True, exist_ok=True)

    sources = program_bundle.get("sources") or {}
    manifest_source = sources.get("manifest") or {}
    manifest_path = resolve_program_bundle_path(
        program_bundle_path,
        str(manifest_source.get("path", "")),
    )
    manifest = load_json(manifest_path)
    manifest_sha256 = strip_doppler_hash(manifest_source.get("hash"))
    graph_sha256 = strip_doppler_hash((sources.get("executionGraph") or {}).get("hash"))
    reference = program_bundle.get("referenceTranscript") or {}
    prompt = reference.get("prompt") or {}
    tokens = reference.get("tokens") or {}
    output = reference.get("output") or {}
    phase = reference.get("phase") or {}

    prompt_path = out_dir / "program_bundle_prompt.txt"
    prompt_text = str(prompt.get("identity", ""))
    prompt_path.write_text(prompt_text, encoding="utf-8")

    generated_token_ids = [
        int(token) for token in (tokens.get("ids") or []) if isinstance(token, int)
    ]
    generated = write_u32_array(
        out_dir / "program_bundle_generated_tokens.u32",
        generated_token_ids,
    )
    logits_digests = program_bundle_logits_digests(reference)
    kv_cache_summary = program_bundle_kv_cache_summary(reference)
    transcript_path = out_dir / "program_bundle_decode_transcript.json"
    transcript_payload = {
        "schemaVersion": 1,
        "artifactKind": "doppler_program_bundle_reference_transcript_projection",
        "bundleId": program_bundle.get("bundleId", "pending"),
        "modelId": program_bundle.get("modelId", "pending"),
        "manifestSha256": manifest_sha256,
        "executionGraphSha256": graph_sha256,
        "requestedDecodeSteps": int(output.get("tokensGenerated") or 0),
        "actualDecodeSteps": len(generated_token_ids),
        "decodeStepsRequested": int(output.get("tokensGenerated") or 0),
        "decodeStepsProduced": len(generated_token_ids),
        "stopReason": normalize_program_bundle_stop_reason(output.get("stopReason")),
        "prompt": prompt,
        "generatedTokenIds": generated_token_ids,
        "generatedTokenIdsSha256": generated["sha256"],
        "logitsDigests": logits_digests,
        "kvCache": kv_cache_summary,
        "sourceReferenceTranscript": reference,
    }
    write_json(transcript_path, transcript_payload)

    shard_identities = manifest_shard_identities(manifest)
    weight_set_id = (
        manifest.get("artifactIdentity", {}).get("weightPackId")
        or manifest.get("weightSetId")
        or f"{program_bundle.get('modelId', 'unknown')}-declared-shards"
    )
    token_count = int(phase.get("prefillTokens") or 0)
    token_ids_sha256 = strip_doppler_hash(prompt.get("tokenIdsHash"))
    chat_template = (manifest.get("inference") or {}).get("chatTemplate") or {}
    use_chat_template = (
        bool(chat_template.get("enabled"))
        if isinstance(chat_template, dict)
        else False
    )
    tokenized_prompt = find_tokenized_prompt_artifact(
        expected_token_ids_sha256=token_ids_sha256,
        expected_token_count=token_count,
        out_dir=out_dir,
    ) or materialize_tokenized_prompt_from_doppler_tokenizer(
        program_bundle_path=program_bundle_path,
        manifest_path=manifest_path,
        manifest=manifest,
        prompt_text=prompt_text,
        expected_token_ids_sha256=token_ids_sha256,
        expected_token_count=token_count,
        out_dir=out_dir,
    )
    if tokenized_prompt is None:
        raise ValueError(
            "Program Bundle tokenized prompt is unavailable: expected "
            f"tokenIdsHash={token_ids_sha256!r} tokenCount={token_count}. "
            "Export concrete token IDs or provide a bundled tokenizer artifact."
        )
    input_set_components = {
        "modelId": program_bundle["modelId"],
        "promptSha256": strip_doppler_hash(prompt.get("hash")),
        "runtimeProfile": "program-bundle/browser-reference",
        "decodeSteps": int(output.get("tokensGenerated") or 0),
        "samplingSha256": sha256_json({"source": "doppler_program_bundle"}),
        "tokenCount": token_count,
        "tokenizedPromptSha256": token_ids_sha256,
        "useChatTemplate": use_chat_template,
    }
    input_set_sha256 = sha256_json(input_set_components)
    graph_path = out_dir / "program_bundle_execution_graph.json"

    export = {
        "schemaVersion": 1,
        "artifactKind": "doppler_int4ple_reference_export",
        "referenceKind": "prefill_decode_transcript",
        "exportStatus": "contract_bound",
        "modelId": program_bundle["modelId"],
        "manifestPath": str(manifest_path),
        "manifestSha256": manifest_sha256,
        "executionGraphSha256": graph_sha256,
        "executionGraph": {
            "path": rel(graph_path),
            "sha256": graph_sha256,
            "source": "doppler.program-bundle.execution.steps",
        },
        "weightSetId": weight_set_id,
        "weightSetSha256": strip_doppler_hash(sources.get("weightSetHash")),
        "shardIdentities": shard_identities,
        "inputSetSha256": input_set_sha256,
        "inputSetComponents": input_set_components,
        "prompt": {
            "path": rel(prompt_path),
            "sha256": sha256_file(prompt_path),
            "source": "doppler_program_bundle_reference_prompt",
        },
        "tokenizedPrompt": tokenized_prompt,
        "tensorDigest": {
            "name": "final_logits",
            "status": "pending",
            "dtype": "float32",
            "shape": [0],
            "path": "pending",
            "sha256": "pending",
            "byteLength": 0,
            "preview": [],
        },
        "decodeTranscript": {
            "status": "output_ready",
            "transcript": {
                "path": rel(transcript_path),
                "sha256": sha256_file(transcript_path),
                "source": "doppler_program_bundle_reference_transcript_projection",
            },
            "requestedDecodeSteps": transcript_payload["requestedDecodeSteps"],
            "actualDecodeSteps": transcript_payload["actualDecodeSteps"],
            "decodeStepsRequested": transcript_payload["decodeStepsRequested"],
            "decodeStepsProduced": transcript_payload["decodeStepsProduced"],
            "stopReason": transcript_payload["stopReason"],
            "sampling": {
                "temperature": 0,
                "topK": 1,
                "topP": 1,
                "repetitionPenalty": 1.0,
                "padTokenId": None,
                "seed": None,
            },
            "generatedTokenIds": generated,
            "logitsDigests": logits_digests,
        },
        "producer": {
            "runtime": "doppler_browser_webgpu",
            "toolPath": rel(program_bundle_path),
            "dopplerRoot": str(program_bundle_repo_root(program_bundle_path)),
            "runtimeProfile": "program-bundle/browser-reference",
            "webgpuProvider": reference.get("surface", "browser-webgpu"),
        },
        "programBundleSourcePath": str(program_bundle_path.resolve()),
        "programBundleId": program_bundle.get("bundleId", "pending"),
        "inputsSynthetic": False,
        "weightsSynthetic": False,
        "tolerancePolicy": {
            "comparison": "max_abs",
            "atol": 1e-3,
            "rtol": 0,
            "notes": (
                "Doppler Program Bundle reference carries exact token IDs, "
                "per-step logits digests, and KV byte-digest metadata. Doe CSL "
                "must produce its own bytes/digests before parity can pass."
            ),
        },
        "claimBoundary": {
            "claimable": False,
            "scope": (
                "Doppler-owned Program Bundle reference. It becomes Cerebras "
                "evidence only after Doe CSL binds the same bundle id, graph, "
                "weights, prompt, token IDs, logits policy, and KV evidence."
            ),
            "blockedUntil": [
                "Doe CSL simfabric bounded prefill+decode transcript for the same Program Bundle",
                "Doe CSL reference parity gate promotion criteria pass",
                "Cerebras hardware receipt binds the same Program Bundle",
            ],
        },
    }
    graph = program_bundle_execution_graph_projection(program_bundle, export, manifest)
    write_json(graph_path, graph)
    export_path = out_dir / "doppler_program_bundle_reference_export.json"
    write_json(export_path, export)
    return export, export_path


def source_program(
    export: dict[str, Any],
    *,
    execution_depth: str = "not_executed",
    program_bundle: dict[str, Any] | None = None,
    program_bundle_link: dict[str, Any] | None = None,
) -> dict[str, Any]:
    graph = export.get("executionGraph") or {}
    source = {
        "authoringSurface": "doppler_execution_v1",
        "manifestPath": export["manifestPath"],
        "manifestSha256": export["manifestSha256"],
        "graphPath": graph.get("path", "pending"),
        "graphSha256": export["executionGraphSha256"],
        "weightSetId": export["weightSetId"],
        "weightSha256": export["weightSetSha256"],
        "inputSetSha256": export["inputSetSha256"],
        "executionDepth": execution_depth,
    }
    if program_bundle is not None and program_bundle_link is not None:
        source["programBundle"] = program_bundle_link
        if program_bundle.get("schema") == "doppler.program-bundle/v1":
            entrypoints = (program_bundle.get("host") or {}).get("entrypoints") or []
            first_entrypoint = entrypoints[0] if entrypoints else {}
            source["programBundleId"] = program_bundle.get("bundleId", "pending")
            source["programContractVersion"] = program_bundle["schema"]
            source["wgslModulesSha256"] = sha256_json(program_bundle["wgslModules"])
            source["hostEntrypointSha256"] = strip_doppler_hash(
                first_entrypoint.get("sourceHash")
            )
            source["runtimeProfile"] = "program-bundle/browser-reference"
            source["captureProfile"] = (
                program_bundle.get("captureProfile") or {}
            ).get("schema", "doppler.capture-profile/v1")
        else:
            source["programContractVersion"] = program_bundle["programContractVersion"]
            source["wgslModulesSha256"] = sha256_json(program_bundle["wgslModules"])
            source["hostEntrypointSha256"] = program_bundle["hostEntrypoint"]["sha256"]
            source["runtimeProfile"] = program_bundle["runtimeProfile"]["id"]
            source["captureProfile"] = program_bundle["captureProfile"]["profileId"]
    return source


def load_fixture_ids(path: Path) -> set[str]:
    registry = load_json(path)
    fixtures = registry.get("fixtures") or []
    return {
        fixture["id"]
        for fixture in fixtures
        if isinstance(fixture, dict) and isinstance(fixture.get("id"), str)
    }


def hash_link(path: Path, source: str | None = None) -> dict[str, Any]:
    link: dict[str, Any] = {
        "path": rel(path),
        "sha256": sha256_file(path),
    }
    if source is not None:
        link["source"] = source
    return link


def pending_link(source: str) -> dict[str, Any]:
    return {
        "path": "pending",
        "sha256": "pending",
        "source": source,
    }


def derived_driver_result_path(trace_path: Path) -> Path:
    return trace_path.with_name(f"{trace_path.name}.driver-result.json")


def plan_trace_path(simulator_plan_path: Path) -> Path:
    plan = load_json(simulator_plan_path)
    outputs = plan.get("outputs") or {}
    trace_path = outputs.get("tracePath")
    if not isinstance(trace_path, str) or not trace_path:
        raise ValueError("simulator plan is missing outputs.tracePath")
    return resolve_relative(simulator_plan_path.parent, trace_path)


@dataclass(frozen=True)
class SimulatorEvidence:
    receipt_status: str
    csl_transcript: dict[str, Any]
    kv_cache_evidence: dict[str, Any]
    simulator_run: dict[str, Any]
    blocker: str
    production_ops: frozenset[str]
    execution_depth: str


def graph_path_from_export(export: dict[str, Any]) -> Path:
    graph = export.get("executionGraph") or {}
    graph_path = graph.get("path")
    if not isinstance(graph_path, str) or not graph_path:
        raise ValueError("reference export is missing executionGraph.path")
    return resolve(graph_path)


def prefill_group_name(group: dict[str, Any], index: int) -> str:
    layers = group.get("layers") or []
    steps = group.get("steps") or []
    kernels = {
        step[1]
        for step in steps
        if isinstance(step, list) and len(step) >= 2
    }
    if "attn_head256" in kernels:
        label = "local_attention_layers"
    elif "attn_head512" in kernels:
        label = "global_attention_layers"
    else:
        label = f"group_{index}"
    if not layers:
        return f"prefill.{label}"
    return f"prefill.{label}.{layers[0]}-{layers[-1]}"


def graph_stage_records(graph: dict[str, Any]) -> list[dict[str, str]]:
    execution = graph.get("execution")
    if not isinstance(execution, dict):
        raise ValueError("execution graph is missing execution object")

    records: list[dict[str, str]] = []

    for step in execution.get("preLayer") or []:
        records.append(stage_record("preLayer", step))

    for index, group in enumerate(execution.get("prefill") or []):
        if not isinstance(group, dict):
            continue
        stage = prefill_group_name(group, index)
        for step in group.get("steps") or []:
            records.append(stage_record(stage, step))

    for step in execution.get("decode") or []:
        records.append(stage_record("decode.layers.0-34", step))

    for step in execution.get("postLayer") or []:
        records.append(stage_record("postLayer", step))

    return records


def stage_record(stage: str, step: Any) -> dict[str, str]:
    if not isinstance(step, list) or len(step) < 2:
        raise ValueError(f"invalid execution graph step in {stage}: {step!r}")
    operation, kernel_id = step[0], step[1]
    if not isinstance(operation, str) or not isinstance(kernel_id, str):
        raise ValueError(f"invalid execution graph step in {stage}: {step!r}")
    record = {
        "stage": stage,
        "operation": operation,
        "kernelId": kernel_id,
    }
    if len(step) >= 3 and isinstance(step[2], str):
        record["weightRef"] = step[2]
    return record


def kernel_metadata(
    graph: dict[str, Any],
    kernel_id: str,
) -> dict[str, Any]:
    kernels = graph.get("execution", {}).get("kernels", {})
    metadata = kernels.get(kernel_id, {})
    return metadata if isinstance(metadata, dict) else {}


def manifest_model_config(
    export: dict[str, Any],
    bounded_max_seq_len: int,
    *,
    num_layers_override: int | None = None,
) -> dict[str, Any]:
    manifest = load_json(resolve(export["manifestPath"]))
    arch = manifest.get("architecture")
    if not isinstance(arch, dict):
        raise ValueError("Doppler manifest is missing architecture")
    # Gemma 3 (non-PLE) manifests omit globalHeadDim / hiddenSizePerLayerInput /
    # vocabSizePerLayerInput. Default them to 0 so the INT4 PLE lowering can
    # still run the transcript producer as a diagnostic; when a model has no
    # PLE tier the downstream PLE slice routing is a no-op.
    raw_global_head_dim = arch.get("globalHeadDim")
    global_head_dim = int(raw_global_head_dim) if isinstance(raw_global_head_dim, int) else 0
    raw_ple_width = arch.get("hiddenSizePerLayerInput")
    ple_width = int(raw_ple_width) if isinstance(raw_ple_width, int) else 0
    raw_ple_vocab = arch.get("vocabSizePerLayerInput")
    ple_vocab = int(raw_ple_vocab) if isinstance(raw_ple_vocab, int) else 0
    manifest_num_layers = int(arch["numLayers"])
    if num_layers_override is not None:
        if num_layers_override < 1:
            raise ValueError(
                f"num_layers_override must be >=1, got {num_layers_override}"
            )
        if num_layers_override > manifest_num_layers:
            raise ValueError(
                f"num_layers_override={num_layers_override} exceeds "
                f"manifest.architecture.numLayers={manifest_num_layers}"
            )
        effective_num_layers = num_layers_override
    else:
        effective_num_layers = manifest_num_layers
    return {
        "hiddenDim": int(arch["hiddenSize"]),
        "numHeads": int(arch["numAttentionHeads"]),
        "headDim": int(arch["headDim"]),
        "globalHeadDim": global_head_dim,
        "numKeyValueHeads": int(arch["numKeyValueHeads"]),
        "numLayers": effective_num_layers,
        "manifestNumLayers": manifest_num_layers,
        "vocabSize": int(arch["vocabSize"]),
        "maxSeqLen": bounded_max_seq_len,
        "quantFormat": "q4k",
        "ffnExpansionFactor": (
            int(arch["intermediateSize"]) // int(arch["hiddenSize"])
        ),
        "ffnMatrixCount": 3,
        "pleWidth": ple_width,
        "pleVocabSize": ple_vocab,
    }


def transcript_seq_len_bound(export: dict[str, Any]) -> int:
    components = export.get("inputSetComponents") or {}
    token_count = int(components.get("tokenCount") or 0)
    decode_steps = int(components.get("decodeSteps") or 0)
    return max(1, token_count + decode_steps)


def sliding_window_size(export: dict[str, Any]) -> int:
    manifest = load_json(resolve(export["manifestPath"]))
    inference = manifest.get("inference") or {}
    attention = inference.get("attention") or {}
    value = attention.get("slidingWindow")
    return int(value) if isinstance(value, int) and value > 0 else 512


def step_to_hostplan(
    phase: str,
    step: Any,
    *,
    layer_index: int | None = None,
) -> dict[str, Any]:
    record = stage_record(phase, step)
    kernel_id = record["kernelId"]
    op = DOPPLER_KERNEL_TO_HOSTPLAN_OP.get(kernel_id)
    if op is None:
        raise ValueError(f"no HostPlan op mapping for kernel {kernel_id!r}")
    entry = {
        "name": record["operation"],
        "phase": phase,
        "op": op,
        "kernelKey": kernel_id,
    }
    if "weightRef" in record:
        weight_ref = record["weightRef"]
        if layer_index is not None:
            weight_ref = weight_ref.replace("{L}", str(layer_index))
        entry["weightsKey"] = weight_ref
    return entry


def find_prefill_group_for_layer(
    groups: list[Any],
    layer_index: int,
) -> dict[str, Any]:
    for group in groups:
        if not isinstance(group, dict):
            continue
        layers = group.get("layers") or []
        if layer_index in layers:
            return group
    raise ValueError(f"prefill group missing layer {layer_index}")


def normalized_hostplan_execution(
    export: dict[str, Any],
    graph: dict[str, Any],
    *,
    num_layers_override: int | None = None,
) -> dict[str, Any]:
    model_config = manifest_model_config(
        export,
        transcript_seq_len_bound(export),
        num_layers_override=num_layers_override,
    )
    execution = graph.get("execution")
    if not isinstance(execution, dict):
        raise ValueError("execution graph is missing execution object")

    prefill_steps: list[dict[str, Any]] = []
    decode_steps: list[dict[str, Any]] = []
    for step in execution.get("preLayer") or []:
        prefill_steps.append(step_to_hostplan("prefill", step))

    prefill_groups = execution.get("prefill") or []
    for layer_index in range(model_config["numLayers"]):
        group = find_prefill_group_for_layer(prefill_groups, layer_index)
        for step in group.get("steps") or []:
            prefill_steps.append(
                step_to_hostplan(
                    "prefill",
                    step,
                    layer_index=layer_index,
                )
            )

    for layer_index in range(model_config["numLayers"]):
        for step in execution.get("decode") or []:
            decode_steps.append(
                step_to_hostplan(
                    "decode",
                    step,
                    layer_index=layer_index,
                )
            )

    for step in execution.get("postLayer") or []:
        name = step[0] if isinstance(step, list) and step else ""
        if name == "sample":
            decode_steps.append(step_to_hostplan("decode", step))
        elif name == "lm_head":
            decode_steps.append(step_to_hostplan("decode", step))
        elif isinstance(name, str) and name.endswith("_prefill"):
            prefill_steps.append(step_to_hostplan("prefill", step))
        else:
            prefill_steps.append(step_to_hostplan("prefill", step))
            decode_steps.append(step_to_hostplan("decode", step))

    return {
        "modelFamily": "gemma4",
        "modelId": export["modelId"],
        "sourceGraphSha256": export["executionGraphSha256"],
        "modelConfig": model_config,
        "placementPolicy": {
            "maxGridWidth": 512,
            "maxGridHeight": 512,
            "preferSquare": True,
        },
        "eosTokenId": 1,
        "slidingWindowSize": sliding_window_size(export),
        "layerPattern": {
            "type": "every_n",
            "period": 5,
            "offset": 4,
        },
        "numKvSharedLayers": int(model_config["numLayers"]),
        "steps": prefill_steps + decode_steps,
    }


def hostplan_bundle_blocked(source_graph_sha256: str, message: str) -> dict[str, Any]:
    return {
        "status": "hostplan_failed",
        "sourceGraphSha256": source_graph_sha256,
        "normalizedExecution": {
            "path": "pending",
            "sha256": "pending",
            "source": "hostplan_normalization_failed",
        },
        "bundleRoot": "pending",
        "hostPlan": {
            "path": "pending",
            "sha256": "pending",
            "source": "hostplan_lowering_failed",
        },
        "runtimeConfig": {
            "path": "pending",
            "sha256": "pending",
            "source": "hostplan_lowering_failed",
        },
        "memoryPlan": {
            "path": "pending",
            "sha256": "pending",
            "source": "hostplan_lowering_failed",
        },
        "simulatorPlan": {
            "path": "pending",
            "sha256": "pending",
            "source": "hostplan_lowering_failed",
        },
        "programBundle": {
            "path": "pending",
            "sha256": "pending",
            "source": "hostplan_lowering_failed",
        },
        "compileInputCoverage": {
            "compileRoot": "pending",
            "totalTargetCount": 0,
            "presentTargetCount": 0,
            "missingTargetCount": 0,
            "targets": [],
        },
        "weightMappingCoverage": {
            "status": "not_attempted",
            "manifestPath": "pending",
            "manifestSha256": "pending",
            "weightSetId": "pending",
            "weightSetSha256": "pending",
            "requiredWeightCount": 0,
            "mappedWeightCount": 0,
            "missingWeightCount": 0,
            "missingWeightKeys": [],
            "requiredWeightKeysSha256": "pending",
            "mappedWeightKeysSha256": "pending",
            "runtimeConfigPath": "pending",
            "runtimeConfigSha256": "pending",
        },
        "hostIoLayoutCoverage": {
            "status": "not_attempted",
            "runtimeConfigPath": "pending",
            "runtimeConfigSha256": "pending",
            "hostIoLayoutSha256": "pending",
            "entryCount": 0,
            "requiredRoles": [
                "weight",
                "state",
                "tokenized_prompt",
                "logits_output",
                "generated_tokens_output",
            ],
            "coveredRoles": [],
            "missingRoles": [
                "weight",
                "state",
                "tokenized_prompt",
                "logits_output",
                "generated_tokens_output",
            ],
            "mappedWeightEntryCount": 0,
            "stateBufferEntryCount": 0,
            "hostInputEntryCount": 0,
            "hostOutputEntryCount": 0,
        },
        "simulatorDriverResult": {
            "path": "pending",
            "sha256": "pending",
            "source": "not_attempted",
            "status": "blocked",
            "exitCode": 0,
            "compileStatus": "not_attempted",
            "compileReason": "hostplan_lowering_failed",
            "runStatus": "blocked",
            "runReason": "hostplan_lowering_failed",
        },
        "prefillLaunchCount": 0,
        "decodeLaunchCount": 0,
        "kernelCount": 0,
        "blocker": message,
    }


def compile_input_coverage(
    bundle_root: Path,
    simulator_plan: dict[str, Any],
) -> dict[str, Any]:
    inputs = simulator_plan.get("inputs") or {}
    compile_root = bundle_root / str(inputs.get("compileRootPath", "compile"))
    targets = []
    present = 0
    for target in inputs.get("compileTargets") or []:
        name = str(target["name"])
        layout_path = compile_root / str(target["layout"])
        pe_program_path = compile_root / str(target["peProgram"])
        layout_present = layout_path.is_file()
        pe_program_present = pe_program_path.is_file()
        ready = layout_present and pe_program_present
        if ready:
            present += 1
        targets.append(
            {
                "name": name,
                "layoutPath": rel(layout_path),
                "peProgramPath": rel(pe_program_path),
                "layoutPresent": layout_present,
                "peProgramPresent": pe_program_present,
                "ready": ready,
            }
        )
    total = len(targets)
    return {
        "compileRoot": rel(compile_root),
        "totalTargetCount": total,
        "presentTargetCount": present,
        "missingTargetCount": total - present,
        "targets": targets,
    }


def runtime_dtype(manifest_dtype: str) -> str:
    if manifest_dtype == "BF16":
        return "bf16"
    if manifest_dtype == "F16":
        return "f16"
    if manifest_dtype == "Q4_K_M":
        return "u8_q4k"
    if manifest_dtype == "Q8_0":
        return "u8_q8"
    raise ValueError(f"unsupported runtime weight dtype: {manifest_dtype}")


def runtime_quant(manifest_dtype: str) -> dict[str, Any]:
    if manifest_dtype == "BF16":
        return {
            "format": "BF16",
            "storageDtype": "bfloat16",
            "sourceDtype": "bfloat16",
        }
    if manifest_dtype == "F16":
        return {
            "format": "F16",
            "storageDtype": "float16",
            "sourceDtype": "float16",
        }
    if manifest_dtype == "Q4_K_M":
        return {
            "format": "Q4_K_M",
            "storageDtype": "uint8",
            "sourceDtype": "float16",
            "blockSizeElements": 256,
            "blockSizeBytes": 144,
            "encoding": "rdrr_int4ple",
        }
    if manifest_dtype == "Q8_0":
        return {
            "format": "Q8_0",
            "storageDtype": "uint8",
            "sourceDtype": "float16",
            "blockSizeElements": 32,
            "blockSizeBytes": 34,
            "encoding": "rdrr_int4ple",
        }
    raise ValueError(f"unsupported runtime weight quant metadata: {manifest_dtype}")


def shard_identities_by_index(
    export: dict[str, Any],
) -> dict[int, dict[str, Any]]:
    identities: dict[int, dict[str, Any]] = {}
    for shard in export.get("shardIdentities") or []:
        if not isinstance(shard, dict):
            continue
        identities[int(shard["index"])] = shard
    return identities


def manifest_tensor_spans(
    tensor: dict[str, Any],
    shard_identities: dict[int, dict[str, Any]],
    manifest_root: Path,
) -> list[dict[str, Any]]:
    raw_spans = tensor.get("spans")
    if not isinstance(raw_spans, list):
        raw_spans = [
            {
                "shardIndex": int(tensor["shard"]),
                "offset": int(tensor["offset"]),
                "size": int(tensor["size"]),
            }
        ]
    spans: list[dict[str, Any]] = []
    for raw_span in raw_spans:
        shard_index = int(raw_span["shardIndex"])
        identity = shard_identities.get(shard_index, {})
        filename = str(identity.get("filename", f"shard_{shard_index:05d}.bin"))
        spans.append(
            {
                "shardIndex": shard_index,
                "shardPath": rel(manifest_root / filename),
                "shardSha256": str(
                    identity.get("sha256")
                    or identity.get("hash")
                    or "missing"
                ),
                "offset": int(raw_span["offset"]),
                "size": int(raw_span["size"]),
            }
        )
    return spans


def runtime_weight_mapping(
    *,
    weight_key: str,
    tensor_name: str,
    tensor: dict[str, Any],
    spans: list[dict[str, Any]],
    pe_count: int,
) -> dict[str, Any]:
    if not spans:
        raise ValueError(f"tensor has no shard span: {tensor_name}")
    manifest_dtype = str(tensor["dtype"])
    shape = [int(value) for value in tensor.get("shape", [])]
    byte_offset = int(spans[0]["offset"])
    mapping: dict[str, Any] = {
        "shard": spans[0]["shardPath"],
        "path": spans[0]["shardPath"],
        "sha256": spans[0]["shardSha256"],
        "peBuffer": weight_key,
        "peRange": [0, max(0, pe_count - 1)],
        "dtype": runtime_dtype(manifest_dtype),
        "tensor": weight_key,
        "offsetBytes": byte_offset,
        "shape": shape,
        "quant": runtime_quant(manifest_dtype),
        "weightKey": weight_key,
        "tensorName": tensor_name,
        "role": str(tensor.get("role", "unknown")),
        "layout": str(tensor.get("layout", "unknown")),
        "byteSize": int(tensor["size"]),
        "byteOffset": byte_offset,
        "spans": spans,
    }
    source_transform = tensor.get("sourceTransform")
    if isinstance(source_transform, dict):
        mapping["sourceTransform"] = source_transform
    return mapping


def patch_runtime_weight_mappings(
    runtime_config_path: Path,
    export: dict[str, Any],
    normalized_execution: dict[str, Any],
) -> dict[str, Any]:
    runtime_config = load_json(runtime_config_path)
    manifest_path = resolve(export["manifestPath"])
    manifest_root = manifest_path.parent
    manifest = load_json(manifest_path)
    tensors = manifest.get("tensors") or {}
    if not isinstance(tensors, dict):
        raise ValueError("Doppler manifest is missing tensor table")

    required_keys = required_weight_keys(normalized_execution)
    grid = runtime_config.get("memoryPlan", {}).get("grid", {})
    pe_count = int(grid.get("width", 1)) * int(grid.get("height", 1))
    shard_identities = shard_identities_by_index(export)
    mappings: list[dict[str, Any]] = []
    missing: list[str] = []

    for weight_key in required_keys:
        try:
            tensor_names = tensor_name_candidates_for_weight_key(weight_key)
        except ValueError:
            missing.append(weight_key)
            continue
        tensor_name = next(
            (name for name in tensor_names if isinstance(tensors.get(name), dict)),
            "",
        )
        tensor = tensors.get(tensor_name)
        if not isinstance(tensor, dict):
            missing.append(weight_key)
            continue
        spans = manifest_tensor_spans(tensor, shard_identities, manifest_root)
        mappings.append(
            runtime_weight_mapping(
                weight_key=weight_key,
                tensor_name=tensor_name,
                tensor=tensor,
                spans=spans,
                pe_count=pe_count,
            )
        )

    runtime_config["weightMappings"] = mappings
    runtime_config["weightIdentity"] = {
        "modelId": export["modelId"],
        "manifestPath": export["manifestPath"],
        "manifestSha256": export["manifestSha256"],
        "weightSetId": export["weightSetId"],
        "weightSetSha256": export["weightSetSha256"],
        "declaredShardCount": len(export.get("shardIdentities") or []),
        "requiredWeightCount": len(required_keys),
        "mappedWeightCount": len(mappings),
        "missingWeightCount": len(missing),
        "missingWeightKeys": missing,
        "requiredWeightKeysSha256": sha256_json(required_keys),
        "mappedWeightKeysSha256": sha256_json(
            [mapping["weightKey"] for mapping in mappings]
        ),
    }
    write_json(runtime_config_path, runtime_config)
    return {
        "status": "complete" if not missing and mappings else "incomplete",
        "manifestPath": export["manifestPath"],
        "manifestSha256": export["manifestSha256"],
        "weightSetId": export["weightSetId"],
        "weightSetSha256": export["weightSetSha256"],
        "requiredWeightCount": len(required_keys),
        "mappedWeightCount": len(mappings),
        "missingWeightCount": len(missing),
        "missingWeightKeys": missing,
        "requiredWeightKeysSha256": sha256_json(required_keys),
        "mappedWeightKeysSha256": sha256_json(
            [mapping["weightKey"] for mapping in mappings]
        ),
        "runtimeConfigPath": rel(runtime_config_path),
        "runtimeConfigSha256": sha256_file(runtime_config_path),
    }


def enable_compile_target_runtime_command(
    runtime_config_path: Path,
    reference_export_path: Path,
) -> None:
    runtime_config = load_json(runtime_config_path)
    runtime_config["mode"] = "sdk-runtime-command"
    runtime_config["cmaddrEnvVar"] = "DOE_CSL_CMADDR"
    runtime_config["command"] = [
        rel(resolve(INT4PLE_RUNTIME_RUNNER)),
        "--plan={plan_path}",
        "--runtime-config={plan_dir}/runtime-config.json",
        "--compile-root={compile_root}",
        f"--reference-export={rel(reference_export_path)}",
        "--trace-out={trace_path}",
        "--progress-out={progress_path}",
        "{residual_diagnostic_compile_dir_arg}",
        "{cmaddr_arg}",
    ]
    write_json(runtime_config_path, runtime_config)


def patch_simulator_plan_runtime_metadata(
    simulator_plan_path: Path,
    runtime_config_path: Path,
) -> None:
    simulator_plan = load_json(simulator_plan_path)
    runtime_config = load_json(runtime_config_path)
    runtime = simulator_plan.get("runtime")
    if not isinstance(runtime, dict):
        raise ValueError(f"simulator plan lacks runtime object: {simulator_plan_path}")

    weight_mappings = runtime_config.get("weightMappings")
    state_buffers = runtime_config.get("stateBuffers")
    runtime["weightMappingCount"] = (
        len(weight_mappings) if isinstance(weight_mappings, list) else 0
    )
    runtime["stateBufferCount"] = (
        len(state_buffers) if isinstance(state_buffers, list) else 0
    )
    for key in ("maxDecodeTokens", "timeoutMs", "batchSize", "eosTokenId"):
        if key not in runtime_config:
            continue
        value = runtime_config.get(key)
        if isinstance(value, int) or value is None:
            runtime[key] = value
    runtime_config_timeout = runtime_config.get("timeoutMs")
    if (
        not isinstance(runtime_config_timeout, int)
        or runtime_config_timeout < MIN_REAL_INT4PLE_RUNTIME_TIMEOUT_MS
    ):
        runtime_config["timeoutMs"] = MIN_REAL_INT4PLE_RUNTIME_TIMEOUT_MS
    timeout_ms = runtime.get("timeoutMs")
    if not isinstance(timeout_ms, int) or timeout_ms < MIN_REAL_INT4PLE_RUNTIME_TIMEOUT_MS:
        runtime["timeoutMs"] = MIN_REAL_INT4PLE_RUNTIME_TIMEOUT_MS
    runtime["compileTimeoutSeconds"] = INT4PLE_COMPILE_TIMEOUT_SECONDS
    write_json(runtime_config_path, runtime_config)
    write_json(simulator_plan_path, simulator_plan)


def run_simulator_driver(bundle_root: Path) -> dict[str, Any]:
    plan_path = bundle_root / "simulator-plan.json"
    result_path = bundle_root / "simulator-driver-result.json"
    runtime_config = load_json(bundle_root / "runtime-config.json")
    timeout_ms = runtime_config.get("timeoutMs")
    timeout_seconds = (
        max(1, (timeout_ms + 999) // 1000)
        if isinstance(timeout_ms, int) and timeout_ms > 0
        else max(1, MIN_REAL_INT4PLE_RUNTIME_TIMEOUT_MS // 1000)
    )
    command = [
        sys.executable,
        str(resolve(CSL_SDK_DRIVER)),
        str(plan_path),
        "--out-json",
        str(result_path),
        "--runtime-timeout-seconds",
        str(timeout_seconds),
    ]
    proc = subprocess.run(
        command,
        cwd=REPO_ROOT,
        check=False,
        capture_output=True,
        text=True,
    )
    if not result_path.exists():
        write_json(
            result_path,
            {
                "schemaVersion": 1,
                "artifactKind": "csl_simulator_driver_result",
                "target": "wse3",
                "contract": "explicit_driver_outcome",
                "simulatorPlanPath": str(plan_path),
                "compilerExecutable": None,
                "runtimeConfigPath": str(bundle_root / "runtime-config.json"),
                "compile": {
                    "attempted": False,
                    "status": "failed",
                    "reason": "driver_result_missing",
                    "targets": [],
                },
                "run": {
                    "attempted": False,
                    "status": "blocked",
                    "reason": "driver_result_missing",
                    "executionTarget": "simfabric",
                    "cmaddrProvided": False,
                    "tracePath": str(bundle_root / "trace.json"),
                    "traceProduced": False,
                    "stdoutPath": str(bundle_root / "stdout.log"),
                    "stderrPath": str(bundle_root / "stderr.log"),
                },
                "driverProcess": {
                    "exitCode": proc.returncode,
                    "stdout": proc.stdout,
                    "stderr": proc.stderr,
                },
            },
        )
    result = load_json(result_path)
    compile_result = result.get("compile") or {}
    run_result = result.get("run") or {}
    status = "succeeded" if proc.returncode == 0 else "blocked"
    if compile_result.get("status") == "failed" or run_result.get("status") == "failed":
        status = "failed"
    return {
        **hash_link(result_path, "csl_sdk_driver"),
        "status": status,
        "exitCode": proc.returncode,
        "compileStatus": str(compile_result.get("status", "unknown")),
        "compileReason": str(compile_result.get("reason", "unknown")),
        "runStatus": str(run_result.get("status", "unknown")),
        "runReason": str(run_result.get("reason", "unknown")),
    }


def build_shared_execution_contract(
    *,
    reference_export_path: Path,
    program_bundle_path: Path,
    bundle_root: Path,
) -> dict[str, Any]:
    contract_path = bundle_root / "shared-execution-contract.json"
    command = [
        sys.executable,
        str(resolve(SHARED_EXECUTION_CONTRACT_TOOL)),
        "--reference-export",
        str(reference_export_path),
        "--program-bundle",
        str(program_bundle_path),
        "--hostplan-bundle-root",
        str(bundle_root),
        "--out",
        str(contract_path),
    ]
    proc = subprocess.run(
        command,
        cwd=REPO_ROOT,
        check=False,
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0 or not contract_path.is_file():
        details = proc.stderr.strip() or proc.stdout.strip() or "unknown error"
        raise ValueError(
            "shared execution contract build failed: "
            f"{details}"
        )
    return hash_link(contract_path, "doe_shared_execution_contract")


def build_hostplan_bundle(
    export: dict[str, Any],
    reference_export_path: Path,
    bundle_root: Path,
    hostplan_tool: Path,
    *,
    num_layers_override: int | None = None,
) -> dict[str, Any]:
    graph_path = graph_path_from_export(export)
    graph = load_json(graph_path)
    source_graph_sha256 = export["executionGraphSha256"]
    graph_file_sha256 = sha256_file(graph_path)
    projected_graph_sha256 = graph.get("programBundleExecutionGraphSha256")
    if (
        graph_file_sha256 != source_graph_sha256
        and projected_graph_sha256 != source_graph_sha256
    ):
        raise ValueError("execution graph hash mismatch before HostPlan lowering")

    bundle_root.mkdir(parents=True, exist_ok=True)
    clean_directory(bundle_root)
    normalized_path = bundle_root / "normalized-execution-v1.json"
    normalized = normalized_hostplan_execution(
        export,
        graph,
        num_layers_override=num_layers_override,
    )
    write_json(normalized_path, normalized)

    command = [
        str(hostplan_tool),
        "--input",
        str(normalized_path),
        "--bundle-root",
        str(bundle_root),
        "--mode",
        "steps",
        "--driver-executable-path",
        str(resolve(CSL_SDK_DRIVER)),
    ]
    proc = subprocess.run(
        command,
        cwd=REPO_ROOT,
        check=False,
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        log_path = bundle_root / "hostplan-lowering-error.json"
        write_json(
            log_path,
            {
                "command": command,
                "returncode": proc.returncode,
                "stdout": proc.stdout,
                "stderr": proc.stderr,
            },
        )
        blocked = hostplan_bundle_blocked(
            source_graph_sha256,
            f"HostPlan lowering failed with exit code {proc.returncode}.",
        )
        blocked["normalizedExecution"] = hash_link(
            normalized_path,
            "production_graph_normalized_to_execution_v1",
        )
        return blocked

    host_plan_path = bundle_root / "host-plan.json"
    runtime_config_path = bundle_root / "runtime-config.json"
    memory_plan_path = bundle_root / "memory-plan.json"
    simulator_plan_path = bundle_root / "simulator-plan.json"
    normalized_path = bundle_root / "normalized-execution-v1.json"
    host_plan = load_json(host_plan_path)
    simulator_plan = load_json(simulator_plan_path)
    normalized_execution = load_json(normalized_path)
    program_bundle_path = bundle_root / "doppler-program-bundle.json"
    program_bundle_source = export.get("programBundleSourcePath")
    if isinstance(program_bundle_source, str) and program_bundle_source:
        shutil.copyfile(resolve(program_bundle_source), program_bundle_path)
    else:
        raise ValueError(
            "HostPlan lowering requires an explicit canonical Program Bundle; "
            "the reference export must include programBundleSourcePath from --program-bundle."
        )
    host_plan_body = host_plan.get("hostPlan") or {}
    phases = host_plan_body.get("phases") or {}
    weight_coverage = patch_runtime_weight_mappings(
        runtime_config_path,
        export,
        normalized_execution,
    )
    host_io_coverage = attach_host_io_layout(
        runtime_config_path,
        export,
        REPO_ROOT,
    )
    enable_compile_target_runtime_command(
        runtime_config_path,
        reference_export_path,
    )
    patch_simulator_plan_runtime_metadata(
        simulator_plan_path,
        runtime_config_path,
    )
    simulator_plan = load_json(simulator_plan_path)
    runtime_config = load_json(runtime_config_path)
    manifest_compile_projection = manifest_compile_param_projection(
        runtime_config=runtime_config,
        reference=export,
    )
    manifest_compile_application = apply_manifest_compile_params(
        simulator_plan=simulator_plan,
        runtime_config=runtime_config,
        reference=export,
    )
    if manifest_compile_application.get("status") == "applied":
        write_json(simulator_plan_path, simulator_plan)
    runtime_config_sha256 = sha256_file(runtime_config_path)
    host_io_coverage["runtimeConfigSha256"] = runtime_config_sha256
    weight_coverage["runtimeConfigSha256"] = runtime_config_sha256
    coverage = compile_input_coverage(bundle_root, simulator_plan)
    driver_result = run_simulator_driver(bundle_root)
    shared_execution_contract = build_shared_execution_contract(
        reference_export_path=reference_export_path,
        program_bundle_path=program_bundle_path,
        bundle_root=bundle_root,
    )
    return {
        "status": "hostplan_ready",
        "sourceGraphSha256": source_graph_sha256,
        "normalizedExecution": hash_link(
            normalized_path,
            "production_graph_normalized_to_execution_v1",
        ),
        "bundleRoot": rel(bundle_root),
        "hostPlan": hash_link(host_plan_path, "doe_csl_host_plan_tool"),
        "runtimeConfig": hash_link(runtime_config_path, "doe_csl_host_plan_tool"),
        "memoryPlan": hash_link(memory_plan_path, "doe_csl_host_plan_tool"),
        "simulatorPlan": hash_link(simulator_plan_path, "doe_csl_host_plan_tool"),
        "programBundle": hash_link(program_bundle_path, "doe_program_bundle_ingest"),
        "sharedExecutionContract": shared_execution_contract,
        "compileInputCoverage": coverage,
        "manifestCompileParamProjection": manifest_compile_projection,
        "manifestCompileParamApplication": manifest_compile_application,
        "weightMappingCoverage": weight_coverage,
        "hostIoLayoutCoverage": host_io_coverage,
        "simulatorDriverResult": driver_result,
        "prefillLaunchCount": len(phases.get("prefill") or []),
        "decodeLaunchCount": len(phases.get("decode") or []),
        "kernelCount": len(host_plan_body.get("kernels") or []),
        "blocker": (
            "HostPlan bundle is generated, but the CSL transcript runner is "
            "still blocked until compile inputs are materialized for every "
            "production-bound kernel, real RDRR weights/KV state are wired, "
            "simfabric runs, and token/logit/KV transcript artifacts are "
            "emitted."
        ),
    }


def blocked_evidence(
    export: dict[str, Any],
    receipt_status: str,
    blocker: str,
    *,
    driver_result_path: Path | None = None,
    trace_path: Path | None = None,
    simulator_status: str = "not_run",
    production_ops: frozenset[str] = frozenset(),
) -> SimulatorEvidence:
    requested = reference_transcript_digest(export)["requestedDecodeSteps"]
    layer_count = manifest_model_config(export, transcript_seq_len_bound(export))[
        "numLayers"
    ]
    sim_run = {
        "runner": rel(Path(__file__)),
        "status": simulator_status,
        "tracePath": "pending",
        "traceSha256": "pending",
        "kernelStage": "pending_full_int4ple_csl_transcript_lowering",
        "kernelIsStub": True,
        "elapsedMs": None,
        "runReason": blocker,
    }
    if trace_path is not None and trace_path.is_file():
        sim_run["tracePath"] = rel(trace_path)
        sim_run["traceSha256"] = sha256_file(trace_path)
        try:
            trace = load_json(trace_path)
        except (OSError, json.JSONDecodeError):
            trace = {}
        trace_run = trace.get("simulatorRun") if isinstance(trace, dict) else {}
        if isinstance(trace_run, dict):
            if trace_run.get("kernelIsStub") is False:
                sim_run["kernelIsStub"] = False
            for key in ("executionTarget", "compileStatus", "kernelStage", "elapsedMs"):
                value = trace_run.get(key)
                if value is not None:
                    sim_run[key] = value
    if driver_result_path is not None and driver_result_path.is_file():
        sim_run["driverResult"] = hash_link(driver_result_path, "csl_sdk_driver")
        try:
            driver_result = load_json(driver_result_path)
        except (OSError, json.JSONDecodeError):
            driver_result = {}
        compile_result = (
            driver_result.get("compile") if isinstance(driver_result, dict) else {}
        )
        if isinstance(compile_result, dict):
            compile_status = compile_result.get("status")
            if compile_status is not None:
                sim_run["compileStatus"] = compile_status
        run = driver_result.get("run") if isinstance(driver_result, dict) else {}
        if isinstance(run, dict):
            execution_target = run.get("executionTarget")
            if execution_target is not None:
                sim_run["executionTarget"] = execution_target
            reason = run.get("reason")
            if reason is not None:
                sim_run["runReason"] = f"{blocker} ({reason})"
            last_progress_phase = str(run.get("lastProgressPhase") or "")
            if last_progress_phase in {
                "hostplan_executor_bootstrap_complete",
                "hostplan_launch_start",
                "hostplan_launch_complete",
            }:
                sim_run["kernelStage"] = "int4ple_hostplan_executor_runtime"
                sim_run["kernelIsStub"] = False
            progress_path = run.get("progressPath")
            if isinstance(progress_path, str) and Path(progress_path).is_file():
                progress_file = Path(progress_path)
                sim_run["progressPath"] = rel(progress_file)
                sim_run["progressSha256"] = sha256_file(progress_file)
                try:
                    progress_text = progress_file.read_text(encoding="utf-8")
                except OSError:
                    progress_text = ""
                if '"phase": "launch_compute"' in progress_text:
                    sim_run["kernelStage"] = "int4ple_compile_target_runtime_diagnostic"
                    sim_run["kernelIsStub"] = False
                elif (
                    '"phase": "hostplan_executor_bootstrap_complete"' in progress_text
                    or '"phase": "hostplan_launch_start"' in progress_text
                ):
                    sim_run["kernelStage"] = "int4ple_hostplan_executor_runtime"
                    sim_run["kernelIsStub"] = False
    return SimulatorEvidence(
        receipt_status=receipt_status,
        csl_transcript={
            "status": "not_produced",
            "requestedDecodeSteps": requested,
            "actualDecodeSteps": 0,
            "stopReason": "not_run",
            "transcript": pending_link(
                "pending_full_int4ple_csl_transcript_lowering"
            ),
            "generatedTokenIds": {
                "path": "pending",
                "sha256": "pending",
                "dtype": "uint32",
                "tokenCount": 0,
                "preview": [],
            },
            "logitsDigests": [],
        },
        kv_cache_evidence={
            "realKvCache": False,
            "evidenceSource": "not_available",
            "cacheWriteCount": 0,
            "cacheReadCount": 0,
            "blocker": blocker,
            "layerSpanCoverage": {
                "layerCount": layer_count,
                "coveredLayerCount": 0,
                "spans": [],
            },
            "stepStateDigests": [],
        },
        simulator_run=sim_run,
        blocker=blocker,
        production_ops=production_ops,
        execution_depth="not_executed",
    )


def driver_targets(driver_result: dict[str, Any]) -> dict[str, dict[str, Any]]:
    targets = (driver_result.get("compile") or {}).get("targets") or []
    return {
        target["name"]: target
        for target in targets
        if isinstance(target, dict) and isinstance(target.get("name"), str)
    }


def target_input_ready(
    compile_root: Path,
    plan_target: dict[str, Any],
    driver_target: dict[str, Any],
) -> tuple[bool, str]:
    name = plan_target.get("name")
    source_wgsl = plan_target.get("sourceWgslPath")
    if isinstance(source_wgsl, str) and source_wgsl:
        return (
            resolve(source_wgsl).is_file(),
            f"sourceWgslPath missing for {name}: {source_wgsl}",
        )
    layout_raw = plan_target.get("layout")
    pe_raw = plan_target.get("peProgram")
    if not isinstance(layout_raw, str) or not isinstance(pe_raw, str):
        return False, f"compile target {name} lacks layout/peProgram paths"
    candidates = [
        (resolve_relative(compile_root, layout_raw), resolve_relative(compile_root, pe_raw)),
        (resolve(driver_target.get("layoutPath", "")), resolve(driver_target.get("peProgramPath", ""))),
    ]
    if any(layout.is_file() and pe.is_file() for layout, pe in candidates):
        return True, ""
    return False, f"compile/source inputs missing for {name}"


def production_ops_from_driver_result(
    simulator_plan: dict[str, Any],
    simulator_plan_path: Path,
    driver_result: dict[str, Any],
) -> tuple[frozenset[str], list[str]]:
    inputs = simulator_plan.get("inputs") or {}
    raw_root = inputs.get("compileRootPath")
    if not isinstance(raw_root, str) or not raw_root:
        return frozenset(), ["simulator plan is missing inputs.compileRootPath"]
    compile_root = resolve_relative(simulator_plan_path.parent, raw_root)
    targets_by_name = driver_targets(driver_result)
    production_ops: set[str] = set()
    blockers = []
    for target in inputs.get("compileTargets") or []:
        name = target.get("name") if isinstance(target, dict) else None
        driver_target = targets_by_name.get(name or "", {})
        if not isinstance(name, str):
            blockers.append("simulator plan compile target missing name")
        else:
            ready, reason = target_input_ready(compile_root, target, driver_target)
            if ready:
                production_ops.add(name)
            else:
                blockers.append(reason)
            if driver_target.get("status") != "succeeded":
                blockers.append(
                    f"compile target {name} status={driver_target.get('status')!r}"
                )
    return frozenset(production_ops), blockers


def trace_source_matches(trace: dict[str, Any], export: dict[str, Any]) -> bool:
    source = trace.get("sourceProgram") or {}
    return isinstance(source, dict) and all(
        source.get(key) == export[expected_key]
        for key, expected_key in (
            ("manifestSha256", "manifestSha256"),
            ("graphSha256", "executionGraphSha256"),
            ("inputSetSha256", "inputSetSha256"),
            ("weightSha256", "weightSetSha256"),
        )
    )


def trace_full_model_depth(trace: dict[str, Any]) -> bool:
    source = trace.get("sourceProgram") or {}
    executed = trace.get("executedRun") or {}
    model_execution = trace.get("modelExecution") or {}
    return (
        isinstance(source, dict) and source.get("executionDepth") == "full_model"
    ) or (
        isinstance(executed, dict) and executed.get("fullModelDepthExecuted") is True
    ) or (
        isinstance(model_execution, dict)
        and model_execution.get("fullModelDepthExecuted") is True
    )


def normalize_hash_link(
    value: dict[str, Any],
    trace_dir: Path,
    label: str,
) -> tuple[dict[str, Any] | None, str | None]:
    path_text = value.get("path")
    sha256 = value.get("sha256")
    if not isinstance(path_text, str) or not isinstance(sha256, str):
        return None, f"{label}.path/hash is missing"
    path = resolve_relative(trace_dir, path_text)
    if not path.is_file():
        path = resolve(path_text)
    if not path.is_file():
        return None, f"{label}.path missing: {path_text}"
    actual = sha256_file(path)
    if actual != sha256:
        return None, f"{label}.sha256={sha256!r}, actual {actual!r}"
    return {**value, "path": rel(path), "sha256": sha256}, None


def normalize_transcript_artifacts(
    transcript: dict[str, Any],
    trace_dir: Path,
) -> tuple[dict[str, Any] | None, str | None]:
    result = {
        key: transcript.get(key)
        for key in ("status", "requestedDecodeSteps", "actualDecodeSteps", "stopReason")
    }
    linked, failure = normalize_hash_link(
        transcript.get("transcript") or {},
        trace_dir,
        "cslTranscript.transcript",
    )
    if failure:
        return None, failure
    result["transcript"] = linked
    tokens = dict(transcript.get("generatedTokenIds") or {})
    linked, failure = normalize_hash_link(
        tokens,
        trace_dir,
        "cslTranscript.generatedTokenIds",
    )
    if failure:
        return None, failure
    tokens["path"], tokens["sha256"] = linked["path"], linked["sha256"]
    result["generatedTokenIds"] = tokens
    logits = []
    allowed = {
        "stepIndex",
        "phase",
        "contextTokenCount",
        "selectedTokenId",
        "dtype",
        "shape",
        "path",
        "sha256",
        "byteLength",
    }
    for index, digest in enumerate(transcript.get("logitsDigests") or []):
        if not isinstance(digest, dict):
            return None, f"cslTranscript.logitsDigests[{index}] is not an object"
        linked, failure = normalize_hash_link(
            digest,
            trace_dir,
            f"cslTranscript.logitsDigests[{index}]",
        )
        if failure:
            return None, failure
        item = {key: value for key, value in digest.items() if key in allowed}
        item["path"], item["sha256"] = linked["path"], linked["sha256"]
        logits.append(item)
    result["logitsDigests"] = logits
    return result, None


def successful_trace_evidence(
    *,
    export: dict[str, Any],
    trace: dict[str, Any],
    trace_path: Path,
    driver_result: dict[str, Any],
    driver_result_path: Path,
    production_ops: frozenset[str],
) -> SimulatorEvidence:
    run = driver_result.get("run") or {}

    def block(reason: str) -> SimulatorEvidence:
        return blocked_evidence(
            export,
            "blocked_incomplete_simulator_evidence",
            reason,
            driver_result_path=driver_result_path,
            trace_path=trace_path,
            simulator_status=str(run.get("status", "succeeded")),
            production_ops=production_ops,
        )

    simulator = trace.get("simulatorRun") or {}
    simulator = simulator if isinstance(simulator, dict) else {}
    if not trace_source_matches(trace, export):
        return block("simulator trace sourceProgram does not match reference export")
    if not trace_full_model_depth(trace):
        return block("simulator trace does not prove full-model execution depth")
    transcript = trace.get("cslTranscript")
    if not isinstance(transcript, dict) or transcript.get("status") != "output_ready":
        return block("simulator trace does not contain cslTranscript output_ready")
    normalized_transcript, failure = normalize_transcript_artifacts(
        transcript,
        trace_path.parent,
    )
    if failure:
        return block(failure)
    kv_cache = trace.get("kvCacheEvidence")
    if not isinstance(kv_cache, dict) or kv_cache.get("realKvCache") is not True:
        return block("simulator trace does not contain real kvCacheEvidence")
    if simulator.get("kernelIsStub", trace.get("kernelIsStub")) is not False:
        return block("simulator trace does not prove kernelIsStub=false")
    return SimulatorEvidence(
        receipt_status="simulator_success",
        csl_transcript=normalized_transcript,
        kv_cache_evidence=kv_cache,
        simulator_run={
            "runner": rel(Path(__file__)),
            "status": "succeeded",
            "tracePath": rel(trace_path),
            "traceSha256": sha256_file(trace_path),
            "driverResult": hash_link(driver_result_path, "csl_sdk_driver"),
            "executionTarget": run.get("executionTarget", "simfabric"),
            "compileStatus": (driver_result.get("compile") or {}).get(
                "status",
                "succeeded",
            ),
            "runReason": run.get("reason", "simulator run succeeded"),
            "kernelStage": simulator.get("kernelStage", "full_int4ple_csl_transcript"),
            "kernelIsStub": False,
            "elapsedMs": simulator.get("elapsedMs"),
        },
        blocker="",
        production_ops=production_ops,
        execution_depth="full_model",
    )


def load_simulator_evidence(
    export: dict[str, Any],
    hostplan_bundle: dict[str, Any],
    *,
    simulator_driver_result: str | None,
    simulator_trace: str | None,
) -> SimulatorEvidence:
    if hostplan_bundle.get("status") != "hostplan_ready":
        return blocked_evidence(
            export,
            "blocked_missing_hostplan_bundle",
            hostplan_bundle.get("blocker", "HostPlan bundle is not ready."),
        )

    simulator_plan_link = hostplan_bundle.get("simulatorPlan") or {}
    simulator_plan_path_text = simulator_plan_link.get("path")
    if not isinstance(simulator_plan_path_text, str):
        return blocked_evidence(
            export,
            "blocked_missing_simulator_evidence",
            "HostPlan bundle is missing simulatorPlan.path.",
        )
    simulator_plan_path = resolve(simulator_plan_path_text)
    if not simulator_plan_path.is_file():
        return blocked_evidence(
            export,
            "blocked_missing_simulator_evidence",
            f"simulator plan missing: {simulator_plan_path_text}",
        )

    trace_path = (
        resolve(simulator_trace)
        if simulator_trace is not None
        else plan_trace_path(simulator_plan_path)
    )
    driver_link = hostplan_bundle.get("simulatorDriverResult") or {}
    driver_link_path = driver_link.get("path")
    driver_result_path = resolve(simulator_driver_result) if simulator_driver_result else (
        resolve(driver_link_path)
        if isinstance(driver_link_path, str) and driver_link_path != "pending"
        else derived_driver_result_path(trace_path)
    )
    if not driver_result_path.is_file():
        return blocked_evidence(
            export,
            "blocked_missing_simulator_evidence",
            f"simulator driver result missing: {rel(driver_result_path)}",
            driver_result_path=driver_result_path,
            trace_path=trace_path,
        )

    driver_result = load_json(driver_result_path)
    if driver_result.get("artifactKind") != "csl_simulator_driver_result":
        return blocked_evidence(
            export,
            "blocked_incomplete_simulator_evidence",
            "simulator driver result artifactKind is not csl_simulator_driver_result",
            driver_result_path=driver_result_path,
            trace_path=trace_path,
        )

    compile_status = (driver_result.get("compile") or {}).get("status")
    run = driver_result.get("run") or {}
    run_status = run.get("status")
    run_trace_path = run.get("tracePath")
    if simulator_trace is None and isinstance(run_trace_path, str) and run_trace_path:
        trace_path = resolve(run_trace_path)
    simulator_plan = load_json(simulator_plan_path)
    production_ops, compile_input_blockers = production_ops_from_driver_result(
        simulator_plan,
        simulator_plan_path,
        driver_result,
    )
    if compile_status != "succeeded":
        return blocked_evidence(
            export,
            "simulator_failed",
            f"simulator compile status={compile_status!r}",
            driver_result_path=driver_result_path,
            trace_path=trace_path,
            simulator_status=str(run_status or "blocked"),
            production_ops=production_ops,
        )
    if compile_input_blockers:
        return blocked_evidence(
            export,
            "blocked_incomplete_simulator_evidence",
            "; ".join(compile_input_blockers[:4]),
            driver_result_path=driver_result_path,
            trace_path=trace_path,
            simulator_status=str(run_status or "blocked"),
            production_ops=production_ops,
        )
    if run_status != "succeeded":
        return blocked_evidence(
            export,
            "simulator_failed",
            f"simulator run status={run_status!r}: {run.get('reason', '')}",
            driver_result_path=driver_result_path,
            trace_path=trace_path,
            simulator_status=str(run_status or "failed"),
            production_ops=production_ops,
        )
    if not trace_path.is_file():
        return blocked_evidence(
            export,
            "blocked_missing_simulator_evidence",
            f"simulator trace missing: {rel(trace_path)}",
            driver_result_path=driver_result_path,
            trace_path=trace_path,
            simulator_status=str(run_status),
            production_ops=production_ops,
        )

    trace = load_json(trace_path)
    return successful_trace_evidence(
        export=export,
        trace=trace,
        trace_path=trace_path,
        driver_result=driver_result,
        driver_result_path=driver_result_path,
        production_ops=production_ops,
    )


def build_lowering_plan(
    export: dict[str, Any],
    fixture_ids: set[str],
    production_ops: frozenset[str] = frozenset(),
) -> dict[str, Any]:
    graph_path = graph_path_from_export(export)
    graph = load_json(graph_path)
    graph_hash = sha256_file(graph_path)
    expected_hash = export["executionGraphSha256"]
    projected_hash = graph.get("programBundleExecutionGraphSha256")
    if graph_hash != expected_hash and projected_hash != expected_hash:
        raise ValueError(
            "execution graph hash mismatch: "
            f"{graph_hash} != {expected_hash}"
        )

    stages = []
    unsupported = []
    available_fixtures = set()
    for record in graph_stage_records(graph):
        kernel_id = record["kernelId"]
        metadata = kernel_metadata(graph, kernel_id)
        fixture_id = FIXTURE_BY_DOPPLER_KERNEL.get(kernel_id)
        hostplan_op = DOPPLER_KERNEL_TO_HOSTPLAN_OP.get(kernel_id)
        stage = {
            "stage": record["stage"],
            "operation": record["operation"],
            "kernelId": kernel_id,
            "status": "missing_production_csl_kernel",
        }
        if hostplan_op is not None:
            stage["hostPlanOp"] = hostplan_op
        if isinstance(metadata.get("kernel"), str):
            stage["kernelFile"] = metadata["kernel"]
        if isinstance(metadata.get("entry"), str):
            stage["entry"] = metadata["entry"]
        if kernel_id in production_ops or (
            hostplan_op is not None and hostplan_op in production_ops
        ):
            stage["status"] = "production_csl_kernel_available"
            stage["source"] = "simulator_driver_compile_target"
        elif fixture_id and fixture_id in fixture_ids:
            stage["fixtureId"] = fixture_id
            stage["status"] = "fixture_available_not_production_bound"
            stage["blocker"] = (
                f"CSL fixture {fixture_id!r} exists, but no production "
                "Doppler INT4 PLE graph binding emits this full-model "
                "transcript stage."
            )
            available_fixtures.add(fixture_id)
            reason = (
                f"fixture {fixture_id!r} is runtime-ready only as an "
                "isolated pattern, not as a production transcript kernel"
            )
        else:
            stage["blocker"] = (
                "No production CSL lowering is registered for this "
                "Doppler execution-v1 kernel in the INT4 PLE transcript lane."
            )
            reason = "no production CSL lowering registered for this kernel"
        stages.append(stage)
        if stage["status"] == "production_csl_kernel_available":
            continue
        unsupported_stage = {
            "stage": stage["stage"],
            "operation": stage["operation"],
            "kernelId": kernel_id,
            "reason": reason,
        }
        if "hostPlanOp" in stage:
            unsupported_stage["hostPlanOp"] = stage["hostPlanOp"]
        if "kernelFile" in stage:
            unsupported_stage["kernelFile"] = stage["kernelFile"]
        unsupported.append(unsupported_stage)

    production_count = sum(
        1 for stage in stages
        if stage["status"] == "production_csl_kernel_available"
    )
    status = (
        "ready_for_simfabric"
        if production_count == len(stages) and not unsupported
        else "blocked_missing_production_kernels"
    )
    return {
        "status": status,
        "sourceGraphSha256": expected_hash,
        "operationCount": len(stages),
        "supportedOperationCount": production_count,
        "missingOperationCount": len(unsupported),
        "availableFixtureIds": sorted(available_fixtures),
        "stages": stages,
        "unsupportedKernels": unsupported,
    }


def summarize_lowering_blocker(plan: dict[str, Any]) -> str:
    unsupported = plan.get("unsupportedKernels") or []
    kernels = []
    for item in unsupported:
        kernel_id = item.get("kernelId")
        if isinstance(kernel_id, str) and kernel_id not in kernels:
            kernels.append(kernel_id)
    preview = ", ".join(kernels[:8])
    suffix = "" if len(kernels) <= 8 else f", +{len(kernels) - 8} more"
    return (
        "Doe CSL simfabric bounded prefill+decode transcript is blocked: "
        f"{plan.get('missingOperationCount', 0)} graph stage(s) lack "
        "production-bound CSL lowering"
        f" ({preview}{suffix})."
    )


def build_blocked_receipt(
    export: dict[str, Any],
    lowering_plan: dict[str, Any],
    hostplan_bundle: dict[str, Any],
    simulator_evidence: SimulatorEvidence,
) -> dict[str, Any]:
    input_components = export.get("inputSetComponents") or {}
    reference = reference_transcript_digest(export)
    requested = reference["requestedDecodeSteps"]
    actual = reference["actualDecodeSteps"]
    stop_reason = reference["stopReason"]
    blocker = simulator_evidence.blocker
    status = simulator_evidence.receipt_status
    if (
        status == "simulator_success"
        and lowering_plan.get("status") != "ready_for_simfabric"
    ):
        status = "blocked_missing_csl_lowering"
        blocker = summarize_lowering_blocker(lowering_plan)
    elif hostplan_bundle.get("status") != "hostplan_ready":
        status = "blocked_missing_hostplan_bundle"
        blocker = hostplan_bundle.get("blocker", "HostPlan bundle is not ready.")
    elif status == "simulator_success":
        blocker = ""
    program_bundle_link = hostplan_bundle.get("programBundle")
    program_bundle = None
    if isinstance(program_bundle_link, dict):
        raw_path = program_bundle_link.get("path")
        if isinstance(raw_path, str):
            program_bundle_path = resolve(raw_path)
            if program_bundle_path.is_file():
                program_bundle = load_json(program_bundle_path)
    shared_contract = None
    shared_contract_link = hostplan_bundle.get("sharedExecutionContract")
    if isinstance(shared_contract_link, dict):
        raw_path = shared_contract_link.get("path")
        if isinstance(raw_path, str):
            contract_path = resolve(raw_path)
            if contract_path.is_file():
                shared_contract = load_json(contract_path)
    source_program_payload = source_program(
        export,
        execution_depth=simulator_evidence.execution_depth,
        program_bundle=program_bundle,
        program_bundle_link=program_bundle_link,
    )
    decode_request = {
        "requestedDecodeSteps": requested,
        "expectedActualDecodeSteps": actual,
        "expectedStopReason": stop_reason,
        "samplingSha256": input_components.get("samplingSha256", "pending"),
        "inputSetSha256": export["inputSetSha256"],
    }
    if isinstance(shared_contract, dict):
        shared_source = shared_contract.get("sourceProgram")
        if isinstance(shared_source, dict):
            source_program_payload = dict(shared_source)
            source_program_payload["executionDepth"] = (
                simulator_evidence.execution_depth
            )
        shared_request = shared_contract.get("decodeRequest")
        if isinstance(shared_request, dict):
            decode_request = {
                "requestedDecodeSteps": int(
                    shared_request.get("requestedDecodeSteps") or requested
                ),
                "expectedActualDecodeSteps": int(
                    shared_request.get("expectedActualDecodeSteps") or actual
                ),
                "expectedStopReason": shared_request.get(
                    "expectedStopReason",
                    stop_reason,
                ),
                "samplingSha256": shared_request.get(
                    "samplingSha256",
                    input_components.get("samplingSha256", "pending"),
                ),
                "inputSetSha256": shared_request.get(
                    "inputSetSha256",
                    export["inputSetSha256"],
                ),
            }
        transcript_contract = shared_contract.get("transcriptContract")
        if isinstance(transcript_contract, dict):
            shared_reference = transcript_contract.get("referenceTranscript")
            if isinstance(shared_reference, dict):
                reference = shared_reference
    return {
        "schemaVersion": 1,
        "artifactKind": "doe_csl_int4ple_transcript",
        "status": status,
        "modelId": export["modelId"],
        "sourceProgram": source_program_payload,
        "decodeRequest": decode_request,
        "referenceTranscript": reference,
        "loweringPlan": lowering_plan,
        "hostPlanBundle": hostplan_bundle,
        "cslTranscript": simulator_evidence.csl_transcript,
        "kvCacheEvidence": simulator_evidence.kv_cache_evidence,
        "simulatorRun": simulator_evidence.simulator_run,
        "inputsSynthetic": False,
        "weightsSynthetic": False,
        "blocker": blocker,
    }


def main() -> int:
    args = parse_args()
    try:
        reference_export_path = resolve(args.reference_export)
        if args.program_bundle:
            export, reference_export_path = export_from_program_bundle(
                resolve(args.program_bundle),
                reference_export_path.parent,
            )
        else:
            export = load_json(reference_export_path)
        schema = load_json(resolve(args.schema))
        fixture_ids = load_fixture_ids(resolve(args.fixture_registry))
        num_layers_override: int | None = None
        if args.max_layers > 0:
            num_layers_override = int(args.max_layers)
        hostplan_bundle = build_hostplan_bundle(
            export,
            reference_export_path,
            resolve(args.hostplan_bundle_root),
            resolve(args.hostplan_tool),
            num_layers_override=num_layers_override,
        )
        simulator_evidence = load_simulator_evidence(
            export,
            hostplan_bundle,
            simulator_driver_result=args.simulator_driver_result,
            simulator_trace=args.simulator_trace,
        )
        lowering_plan = build_lowering_plan(
            export,
            fixture_ids,
            simulator_evidence.production_ops,
        )
        receipt = build_blocked_receipt(
            export,
            lowering_plan,
            hostplan_bundle,
            simulator_evidence,
        )
        failures = schema_failures(receipt, schema)
        if failures:
            print("FAIL: Doe CSL INT4 PLE transcript receipt schema")
            for failure in failures:
                print(f"  {failure}")
            return 1
        out = resolve(args.out)
        write_json(out, receipt)
    except (OSError, KeyError, ValueError, json.JSONDecodeError) as exc:
        print(f"FAIL: Doe CSL INT4 PLE transcript receipt: {exc}")
        return 1

    print(
        "PASS: wrote Doe CSL INT4 PLE transcript receipt "
        f"({rel(resolve(args.out))})"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
