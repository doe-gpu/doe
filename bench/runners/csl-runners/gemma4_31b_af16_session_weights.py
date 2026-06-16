"""Weight mapping and reference-request helpers for 31B af16 sessions."""

from __future__ import annotations

import argparse
import hashlib
from pathlib import Path
from typing import Any

import numpy as np

from gemma4_31b_af16_session_common import (
    DEFAULT_PROMPT_TOKEN_IDS,
    expected_model_id,
    load_json,
    rel,
    resolve,
    session_artifact_prefix,
    sha256_file,
    sha256_json,
    write_json,
)


def resolve_weight_root(manifest_path: Path, manifest: dict[str, Any]) -> Path:
    manifest_root = resolve(manifest_path).parent
    weights_ref = manifest.get("weightsRef") or {}
    raw_root = weights_ref.get("artifactRoot")
    if isinstance(raw_root, str) and raw_root:
        return (manifest_root / raw_root).resolve()
    return manifest_root


def runtime_dtype(manifest_dtype: str) -> str:
    if manifest_dtype == "BF16":
        return "bf16"
    if manifest_dtype == "F16":
        return "f16"
    if manifest_dtype == "Q4_K_M":
        return "u8_q4k"
    if manifest_dtype == "Q8_0":
        return "u8_q8"
    if manifest_dtype == "F32":
        return "f32"
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
    if manifest_dtype == "F32":
        return {
            "format": "F32",
            "storageDtype": "float32",
            "sourceDtype": "float32",
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


def shard_identities_by_index(manifest: dict[str, Any]) -> dict[int, dict[str, Any]]:
    identities: dict[int, dict[str, Any]] = {}
    for shard in manifest.get("shards") or []:
        if not isinstance(shard, dict):
            continue
        index = int(shard.get("index", len(identities)))
        identities[index] = shard
    return identities


def tensor_spans_for_runtime(
    *,
    tensor: dict[str, Any],
    shard_identities: dict[int, dict[str, Any]],
    weight_root: Path,
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
                "shardPath": str((weight_root / filename).resolve()),
                "shardSha256": str(
                    identity.get("sha256")
                    or identity.get("hash")
                    or identity.get("blake3")
                    or "missing"
                ),
                "offset": int(raw_span["offset"]),
                "size": int(raw_span["size"]),
            }
        )
    return spans


def runtime_mapping_from_tensor(
    *,
    weight_key: str,
    tensor_name: str,
    tensor: dict[str, Any],
    spans: list[dict[str, Any]],
    pe_count: int,
) -> dict[str, Any]:
    manifest_dtype = str(tensor["dtype"])
    shape = [int(value) for value in tensor.get("shape", [])]
    return {
        "shard": spans[0]["shardPath"],
        "path": spans[0]["shardPath"],
        "sha256": spans[0]["shardSha256"],
        "peBuffer": weight_key,
        "peRange": [0, max(0, pe_count - 1)],
        "dtype": runtime_dtype(manifest_dtype),
        "tensor": weight_key,
        "offsetBytes": int(spans[0]["offset"]),
        "shape": shape,
        "quant": runtime_quant(manifest_dtype),
        "weightKey": weight_key,
        "tensorName": tensor_name,
        "role": str(tensor.get("role", "unknown")),
        "layout": str(tensor.get("layout", "unknown")),
        "byteSize": int(tensor["size"]),
        "byteOffset": int(spans[0]["offset"]),
        "spans": spans,
    }


def runtime_mapping_from_sidecar(
    *,
    weight_key: str,
    path: Path,
    pe_count: int,
    runtime_config: dict[str, Any],
) -> dict[str, Any]:
    size = path.stat().st_size
    element_count = size // 4
    return {
        "shard": str(path.resolve()),
        "path": str(path.resolve()),
        "sha256": sha256_file(path),
        "peBuffer": weight_key,
        "peRange": [0, max(0, pe_count - 1)],
        "dtype": "f32",
        "tensor": weight_key,
        "offsetBytes": 0,
        "shape": sidecar_shape_for_runtime(
            weight_key=weight_key,
            element_count=element_count,
            runtime_config=runtime_config,
        ),
        "quant": runtime_quant("F32"),
        "weightKey": weight_key,
        "tensorName": weight_key,
        "role": "sidecar_weight",
        "layout": "flat_sidecar",
        "byteSize": size,
        "byteOffset": 0,
        "spans": [
            {
                "shardIndex": -1,
                "shardPath": str(path.resolve()),
                "shardSha256": sha256_file(path),
                "offset": 0,
                "size": size,
            }
        ],
    }


def sidecar_shape_for_runtime(
    *,
    weight_key: str,
    element_count: int,
    runtime_config: dict[str, Any],
) -> list[int]:
    model = runtime_config.get("modelConfig") or {}
    try:
        ple_width = int(model.get("pleWidth") or 0)
    except (TypeError, ValueError):
        ple_width = 0
    if (
        ".perLayerModelProjection.layer" in weight_key
        and ple_width > 0
        and element_count % ple_width == 0
    ):
        return [element_count // ple_width, ple_width]
    return [element_count]


def build_runtime_weight_mappings(
    *,
    manifest_path: Path,
    weight_plan: dict[str, Any],
    runtime_config: dict[str, Any],
) -> dict[str, Any]:
    manifest = load_json(manifest_path)
    tensors = manifest.get("tensors") or {}
    weight_root = resolve_weight_root(manifest_path, manifest)
    grid = (runtime_config.get("memoryPlan") or {}).get("grid") or {}
    pe_count = int(grid.get("width") or 1) * int(grid.get("height") or 1)
    shard_identities = shard_identities_by_index(manifest)
    mappings: list[dict[str, Any]] = []
    missing: list[str] = []
    sidecar_keys: list[str] = []

    for record in weight_plan.get("requiredWeights") or []:
        if not isinstance(record, dict):
            continue
        key = str(record.get("weightKey") or "")
        if not key:
            continue
        matched_tensor = record.get("matchedTensor")
        matched_file = record.get("matchedFile")
        if isinstance(matched_tensor, str) and isinstance(tensors.get(matched_tensor), dict):
            tensor = tensors[matched_tensor]
            spans = tensor_spans_for_runtime(
                tensor=tensor,
                shard_identities=shard_identities,
                weight_root=weight_root,
            )
            mappings.append(
                runtime_mapping_from_tensor(
                    weight_key=key,
                    tensor_name=matched_tensor,
                    tensor=tensor,
                    spans=spans,
                    pe_count=pe_count,
                )
            )
            continue
        if isinstance(matched_file, str) and matched_file:
            path = weight_root / matched_file
            if path.is_file():
                mappings.append(
                    runtime_mapping_from_sidecar(
                        weight_key=key,
                        path=path,
                        pe_count=pe_count,
                        runtime_config=runtime_config,
                    )
                )
                sidecar_keys.append(key)
                continue
        if record.get("resolutionKind") in {
            "linear_attention_absent_v_projection",
            "architecture_disabled_session_input",
            "linear_attention_session_state",
        }:
            continue
        missing.append(key)

    return {
        "mappings": mappings,
        "identity": {
            "modelId": manifest.get("modelId"),
            "manifestPath": rel(manifest_path),
            "manifestSha256": sha256_file(manifest_path),
            "weightSetId": (manifest.get("artifactIdentity") or {}).get(
                "weightPackId"
            ),
            "weightSetSha256": (manifest.get("artifactIdentity") or {}).get(
                "shardSetHash"
            ),
            "declaredShardCount": len(manifest.get("shards") or []),
            "requiredWeightCount": int(weight_plan.get("requiredWeightCount") or 0),
            "mappedWeightCount": len(mappings),
            "missingWeightCount": len(missing),
            "missingWeightKeys": missing,
            "sidecarWeightKeys": sidecar_keys,
            "requiredWeightKeysSha256": sha256_json(
                [
                    str(item.get("weightKey"))
                    for item in weight_plan.get("requiredWeights") or []
                    if isinstance(item, dict) and item.get("weightKey")
                ]
            ),
            "mappedWeightKeysSha256": sha256_json(
                [mapping["weightKey"] for mapping in mappings]
            ),
        },
    }


def normalize_smoke_execution(
    *,
    smoke_config_path: Path,
    out_dir: Path,
    model_layer_count: int,
) -> dict[str, Any]:
    smoke = load_json(smoke_config_path)
    payload = {
        "schemaVersion": 1,
        "artifactKind": "generic_af16_normalized_execution_v1",
        "source": {
            "path": rel(smoke_config_path),
            "sha256": sha256_file(smoke_config_path),
        },
        "modelConfig": {
            **(smoke.get("modelConfig") or {}),
            "numLayers": model_layer_count,
        },
        "steps": smoke.get("steps") or [],
    }
    payload["sourceGraphSha256"] = sha256_json(payload["steps"])
    path = out_dir / "normalized-execution-v1.json"
    write_json(path, payload)
    return {
        "present": True,
        "path": str(path),
        "sha256": sha256_file(path),
        "modelConfig": payload["modelConfig"],
        "steps": payload["steps"],
    }


def token_prompt_ids(args: argparse.Namespace) -> list[int]:
    supplied = [int(value) for value in args.prompt_token_id]
    source = supplied if supplied else DEFAULT_PROMPT_TOKEN_IDS
    count = max(1, int(args.prefill_token_count))
    if len(source) >= count:
        return source[:count]
    return [*source, *([source[-1]] * (count - len(source)))]


def build_reference_request(
    *,
    args: argparse.Namespace,
    session_dir: Path,
) -> dict[str, Any]:
    token_ids = token_prompt_ids(args)
    prompt_path = session_dir / "inputs" / "prompt.u32"
    prompt_path.parent.mkdir(parents=True, exist_ok=True)
    np.asarray(token_ids, dtype=np.uint32).tofile(prompt_path)
    transcript_path = session_dir / "reference-request.json"
    transcript_payload = {
        "schemaVersion": 1,
        "artifactKind": f"{session_artifact_prefix(args)}_runtime_request",
        "promptTokenIds": token_ids,
        "requestedDecodeSteps": int(args.decode_token_count),
        "actualDecodeSteps": 0,
        "kvCache": {
            "mode": "runtime_capture_required",
            "layerDigestCount": 0,
        },
    }
    write_json(transcript_path, transcript_payload)
    return {
        "modelId": expected_model_id(args),
        "manifestPath": rel(args.source_doppler_manifest),
        "manifestSha256": sha256_file(args.source_doppler_manifest),
        "inputSetComponents": {"tokenCount": len(token_ids)},
        "tokenizedPrompt": {
            "path": str(prompt_path),
            "sha256": hashlib.sha256(prompt_path.read_bytes()).hexdigest(),
            "tokenCount": len(token_ids),
        },
        "decodeTranscript": {
            "status": "request_ready",
            "requestedDecodeSteps": int(args.decode_token_count),
            "actualDecodeSteps": 0,
            "stopReason": "pending_runtime_execution",
            "generatedTokenIds": {"tokenCount": 0},
            "logitsDigests": [],
            "transcript": {"path": str(transcript_path)},
        },
    }
