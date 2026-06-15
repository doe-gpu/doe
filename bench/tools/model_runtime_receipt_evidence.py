#!/usr/bin/env python3
"""Evidence block builders for build_model_runtime_receipt.py."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path
from typing import Any


REPO_ROOT = Path(__file__).resolve().parents[2]


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def resolve(p: str) -> Path:
    path = Path(p)
    return path if path.is_absolute() else (REPO_ROOT / path).resolve()


def load_json(path: Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8"))


def _reference_doc_block() -> dict[str, Any]:
    """Pointer to the human-readable in-loop pipeline reference. The
    machine-readable evidence is the receipt + parity-check artifacts;
    this doc is the reading order for triage."""
    rel = "docs/csl-layer-block-self-check.md"
    block: dict[str, Any] = {
        "path": rel,
        "exists": False,
        "purpose": (
            "Single source of truth for the in-loop pipeline that takes "
            "the generated E2B layer-block from CSL kernel through to a "
            "model receipt with a parity-contract verdict. Documents the "
            "artifact graph, the C0..C5 contract, failure-mode triage, "
            "and the cs_python + real-weights gating story."
        ),
    }
    abs_path = resolve(rel)
    if abs_path.is_file():
        block["exists"] = True
        block["sha256"] = sha256_file(abs_path)
    return block


def _file_link(rel_path: str) -> dict[str, Any]:
    block: dict[str, Any] = {"path": rel_path, "exists": False}
    if not rel_path:
        return block
    abs_path = resolve(rel_path)
    if abs_path.is_file():
        block["exists"] = True
        block["sha256"] = sha256_file(abs_path)
    return block


def _dir_link(rel_path: str) -> dict[str, Any]:
    block: dict[str, Any] = {"path": rel_path, "exists": False}
    if not rel_path:
        return block
    abs_path = resolve(rel_path)
    if abs_path.is_dir():
        block["exists"] = True
        block["fileCount"] = sum(1 for p in abs_path.rglob("*") if p.is_file())
    return block


def _stream_layout_summary(layer: dict[str, Any]) -> dict[str, Any]:
    return {
        "targetMode": layer.get("targetMode"),
        "regionName": layer.get("regionName"),
        "connectionGraph": layer.get("connectionGraph") or {},
        "hostIoLayout": layer.get("hostIoLayout") or [],
        "ioBufferSizes": layer.get("ioBufferSizes") or {},
        "sendReceiveCounts": layer.get("sendReceiveCounts") or {},
    }


def _build_sdklayout_model_execution_evidence(
    receipt: dict[str, Any],
) -> dict[str, Any] | None:
    """Promote generated SdkLayout layer-block smoke to receipt evidence.

    This block is deliberately scoped to the E2B layer-block smoke path. It
    proves a generated SdkLayout program compiled and ran through simfabric
    with direct-link host streams; it does not claim full manifest-shape model
    execution or hardware.
    """
    model_id = (receipt.get("modelId") or "").lower()
    if "e2b" not in model_id:
        return None

    trace_rel = "bench/out/gemma-4-e2b-real-weight-parity/L1/csl-sdklayout/trace.json"
    parity_rel = "bench/out/gemma-4-e2b-real-weight-parity-L1.json"
    trace_path = resolve(trace_rel)
    parity_path = resolve(parity_rel)
    if not trace_path.is_file():
        return {
            "promotionStatus": "blocked",
            "claimScope": (
                "E2B SdkLayout layer-block model execution evidence is "
                "blocked because the canonical L1 SdkLayout trace is absent."
            ),
            "blockers": ["sdklayout_layer_block_trace_absent"],
            "trace": _file_link(trace_rel),
        }

    try:
        trace = load_json(trace_path)
    except json.JSONDecodeError:
        return {
            "promotionStatus": "blocked",
            "claimScope": "E2B SdkLayout trace exists but is invalid JSON.",
            "blockers": ["sdklayout_layer_block_trace_invalid_json"],
            "trace": _file_link(trace_rel),
        }

    layer = trace.get("layerBlockSmoke") or {}
    run = trace.get("executedRun") or {}
    compile_info = trace.get("executedCompile") or {}
    output = run.get("output") or {}
    runtime_stop = run.get("runtimeStop") or {}
    simulator_paths = layer.get("simulatorArtifactPaths") or {}

    parity = None
    parity_summary: dict[str, Any] = {
        "verdictPath": parity_rel,
        "verdict": "missing",
        "promotionEligible": False,
        "tolerancePassed": False,
    }
    if parity_path.is_file():
        try:
            parity = load_json(parity_path)
        except json.JSONDecodeError:
            parity = None
        if isinstance(parity, dict):
            p = parity.get("parity") or {}
            parity_summary = {
                "verdictPath": parity_rel,
                "verdictSha256": sha256_file(parity_path),
                "verdict": parity.get("verdict"),
                "promotionEligible": parity.get("verdict") == "parity_passed",
                "outputDigestMatch": bool(p.get("outputDigestMatch")),
                "tolerancePassed": bool(p.get("tolerancePassed")),
                "layersCompared": int(p.get("layersCompared", 0)),
                "maxAbsErrAcrossLayers": float(
                    p.get("maxAbsErrAcrossLayers", 0.0)
                ),
                "maxAllowedErrAcrossLayers": float(
                    p.get("maxAllowedErrAcrossLayers", 0.0)
                ),
            }

    host_io_layout = layer.get("hostIoLayout") or []
    send_receive_counts = layer.get("sendReceiveCounts") or {}
    stream_entries = run.get("streams") or []
    compile_dir = simulator_paths.get("compileDir") or layer.get("compileArtifactDir") or ""
    output_rel = output.get("path") or ""

    blockers: list[str] = []
    if layer.get("kernelIsStub") is not False:
        blockers.append("kernel_is_stub")
    if run.get("status") != "succeeded":
        blockers.append("sdklayout_run_not_succeeded")
    if compile_info.get("status") != "succeeded":
        blockers.append("sdklayout_compile_not_succeeded")
    if runtime_stop.get("reached") is not True:
        blockers.append("runtime_stop_not_reached")
    if len(host_io_layout) < 4:
        blockers.append("host_io_layout_incomplete")
    if send_receive_counts.get("sends") != 3:
        blockers.append("send_count_mismatch")
    if send_receive_counts.get("receives") != 1:
        blockers.append("receive_count_mismatch")
    if len(stream_entries) < 4:
        blockers.append("host_sdk_stream_telemetry_missing")
    if not parity_summary.get("promotionEligible"):
        blockers.append("parity_not_promoted")
    if not _dir_link(compile_dir).get("exists"):
        blockers.append("compile_artifacts_missing")
    if not _file_link(output_rel).get("exists"):
        blockers.append("output_artifact_missing")

    status = (
        "sdk_layout_layer_block_smoke_promoted"
        if not blockers else "blocked"
    )
    return {
        "promotionStatus": status,
        "claimScope": (
            "Generated E2B SdkLayout layer-block smoke evidence only: "
            "one BF16-derived L1 smoke slice compiled and ran on local "
            "simfabric through direct-link SdkRuntime send/receive. This "
            "does not prove full manifest-shape E2B execution or hardware."
        ),
        "modelId": receipt.get("modelId"),
        "executionStatusBinding": receipt.get("executionStatus"),
        "streamExecutionPlan": {
            "path": layer.get("planPath"),
            "sha256": layer.get("planSha256"),
        },
        "kernelSource": {
            "path": layer.get("kernelSourcePath"),
            "sha256": layer.get("kernelSourceSha256"),
            "kernelIsStub": bool(layer.get("kernelIsStub")),
            "kernelStage": layer.get("kernelStage"),
        },
        "regionPortStreamGraph": _stream_layout_summary(layer),
        "hostIoLayout": host_io_layout,
        "sendReceiveCounts": send_receive_counts,
        "hostSdkTelemetry": {
            "measurementSource": (
                (run.get("streamTelemetry") or {}).get("measurementSource")
            ),
            "streams": stream_entries,
            "streamEventsTailCount": len(run.get("streamEventsTail") or []),
        },
        "simulatorArtifacts": {
            "compileDir": _dir_link(compile_dir),
            "trace": _file_link(trace_rel),
            "output": _file_link(output_rel),
            "runLogs": simulator_paths.get("runLogs") or [],
            "coreFile": simulator_paths.get("coreFile"),
        },
        "executedCompile": compile_info,
        "executedRun": {
            "status": run.get("status"),
            "numLayersChained": run.get("numLayersChained"),
            "elapsedMs": run.get("elapsedMs"),
            "dataSourceKind": (run.get("dataSource") or {}).get("kind"),
            "outputSha256": output.get("sha256"),
            "numericalParity": run.get("numericalParity") or {},
        },
        "runtimeStop": {
            "reached": bool(runtime_stop.get("reached")),
            "elapsedMs": runtime_stop.get("elapsedMs"),
            "error": runtime_stop.get("error"),
        },
        "parity": parity_summary,
        "blockers": blockers,
        "remainingClaimBlockers": [
            "full_manifest_shape_doe_csl_runtime_execution",
            "cerebras_hardware_receipt",
        ],
    }


def _attention_core_shape_run_summary(run: dict[str, Any]) -> dict[str, Any]:
    executed = run.get("executedRun") or {}
    parity = executed.get("numericalParity") or {}
    runtime_stop = executed.get("runtimeStop") or {}
    compile_info = run.get("executedCompile") or {}
    shape = run.get("shape") or {}
    per_heads = [
        head for head in (executed.get("perQueryHead") or [])
        if isinstance(head, dict)
    ]
    passed_heads = [
        head for head in per_heads if head.get("passed") is True
    ]
    compile_prefix = compile_info.get("compilePrefix") or ""
    compile_dir = str(Path(compile_prefix).parent) if compile_prefix else ""
    return {
        "attentionKind": run.get("attentionKind"),
        "headDim": shape.get("headDim"),
        "status": run.get("status"),
        "compileStatus": compile_info.get("status"),
        "compileDir": _dir_link(compile_dir),
        "runStatus": executed.get("status"),
        "runtimeStopReached": bool(runtime_stop.get("reached")),
        "numericalParity": {
            "comparison": parity.get("comparison"),
            "passed": bool(parity.get("passed")),
            "maxAbsErr": float(parity.get("maxAbsErr", 0.0)),
            "atol": float(parity.get("atol", 0.0)),
        },
        "queryHeadsCompared": len(per_heads),
        "queryHeadsPassed": len(passed_heads),
        "bytesTransferred": int(executed.get("observedBytesTransferredTotal", 0)),
        "elapsedMs": executed.get("elapsedMs"),
    }


def _build_manifest_shape_partial_execution_evidence(
    receipt: dict[str, Any],
) -> dict[str, Any] | None:
    """Bind the first manifest-shape SdkLayout slice without overclaiming."""
    model_id = (receipt.get("modelId") or "").lower()
    if "e2b" not in model_id:
        return None

    attention_rel = (
        "bench/out/manifest-shape/"
        "gemma-4-e2b-manifest-shape-attention-core.json"
    )
    attention_path = resolve(attention_rel)
    attention_link = _file_link(attention_rel)
    blocked_contract = {
        "localHeadDim": 256,
        "globalHeadDim": 512,
        "numAttentionHeads": 8,
        "numKeyValueHeads": 1,
        "numLayers": 35,
        "hiddenSize": 1536,
    }
    blocked_coverage = {
        "localHeadDimExecuted": False,
        "globalHeadDimExecuted": False,
        "groupedKvExecuted": False,
        "attentionCoreCslRuntimeExecuted": False,
        "embedUnembedExecuted": False,
        "logitsParityExecuted": False,
        "hardwareExecuted": False,
        "claimable": False,
    }
    blocked_semantic_parity = {
        "scope": "attention_core_cpu_oracle_bit_exact",
        "comparison": "bit_exact_np_array_equal",
        "passed": False,
        "maxAbsErr": 0.0,
        "queryHeadsCompared": 0,
        "claimScope": "No attention-core runtime slice is linked.",
    }
    blocked_grouped_kv = {
        "numAttentionHeads": 8,
        "numKeyValueHeads": 1,
        "queryHeadsPerKvHead": 8,
        "executed": False,
    }
    if not attention_path.is_file():
        return {
            "status": "blocked",
            "claimable": False,
            "claimScope": (
                "Partial manifest-shape execution evidence is blocked "
                "because the attention-core SdkLayout receipt is absent."
            ),
            "attentionCoreReceipt": attention_link,
            "manifestShapeContract": blocked_contract,
            "coverage": blocked_coverage,
            "semanticParity": blocked_semantic_parity,
            "groupedKvEvidence": blocked_grouped_kv,
            "shapeRuns": [],
            "blockers": ["attention_core_receipt_missing"],
            "remainingClaimBlockers": [
                "manifest_shape_attention_core_receipt",
                "full_attention_semantics_parity",
                "full_decoder_stack_manifest_shape_execution",
                "embed_unembed_and_logits_parity",
                "cerebras_hardware_receipt",
            ],
        }

    try:
        attention = load_json(attention_path)
    except json.JSONDecodeError:
        return {
            "status": "blocked",
            "claimable": False,
            "claimScope": "Attention-core SdkLayout receipt is invalid JSON.",
            "attentionCoreReceipt": attention_link,
            "manifestShapeContract": blocked_contract,
            "coverage": blocked_coverage,
            "semanticParity": blocked_semantic_parity,
            "groupedKvEvidence": blocked_grouped_kv,
            "shapeRuns": [],
            "blockers": ["attention_core_receipt_invalid_json"],
            "remainingClaimBlockers": [
                "valid_attention_core_receipt",
                "full_attention_semantics_parity",
                "full_decoder_stack_manifest_shape_execution",
                "embed_unembed_and_logits_parity",
                "cerebras_hardware_receipt",
            ],
        }

    coverage = attention.get("coverage") or {}
    grouped_kv = attention.get("groupedKvEvidence") or {}
    shape_runs = [
        run for run in (attention.get("shapeRuns") or [])
        if isinstance(run, dict)
    ]
    summaries = [_attention_core_shape_run_summary(run) for run in shape_runs]

    blockers: list[str] = []
    if attention.get("status") != "succeeded":
        blockers.append("attention_core_receipt_not_succeeded")
    if attention.get("verdict") != "manifest_shape_attention_core_passed":
        blockers.append("attention_core_verdict_not_passed")
    if coverage.get("localHeadDimExecuted") is not True:
        blockers.append("local_head_dim_not_executed")
    if coverage.get("globalHeadDimExecuted") is not True:
        blockers.append("global_head_dim_not_executed")
    if coverage.get("groupedKvExecuted") is not True:
        blockers.append("grouped_kv_not_executed")
    if coverage.get("attentionCoreCslRuntimeExecuted") is not True:
        blockers.append("attention_core_csl_runtime_not_executed")
    if grouped_kv.get("executed") is not True:
        blockers.append("grouped_kv_evidence_not_executed")

    kinds = {summary.get("attentionKind") for summary in summaries}
    if kinds != {"local", "global"}:
        blockers.append("local_global_shape_run_set_incomplete")

    total_query_heads = 0
    max_abs_err = 0.0
    for summary in summaries:
        kind = summary.get("attentionKind")
        total_query_heads += int(summary.get("queryHeadsCompared") or 0)
        parity = summary.get("numericalParity") or {}
        max_abs_err = max(max_abs_err, float(parity.get("maxAbsErr", 0.0)))
        if summary.get("status") != "succeeded":
            blockers.append(f"{kind}_shape_run_not_succeeded")
        if summary.get("compileStatus") != "succeeded":
            blockers.append(f"{kind}_compile_not_succeeded")
        if summary.get("runStatus") != "succeeded":
            blockers.append(f"{kind}_runtime_not_succeeded")
        if summary.get("runtimeStopReached") is not True:
            blockers.append(f"{kind}_runtime_stop_not_reached")
        if parity.get("passed") is not True:
            blockers.append(f"{kind}_attention_core_parity_not_passed")
        if summary.get("queryHeadsCompared") != 8:
            blockers.append(f"{kind}_query_head_count_not_8")
        if summary.get("queryHeadsPassed") != summary.get("queryHeadsCompared"):
            blockers.append(f"{kind}_query_head_parity_incomplete")
        compile_dir = summary.get("compileDir") or {}
        if compile_dir.get("exists") is not True:
            blockers.append(f"{kind}_compile_dir_missing")

    status = (
        "attention_core_runtime_slice_passed"
        if not blockers else "blocked"
    )
    claim_scope = attention.get("claimScope") or {}
    return {
        "status": status,
        "claimable": False,
        "claimScope": claim_scope.get(
            "summary",
            "Partial manifest-shape attention-core diagnostic only.",
        ),
        "attentionCoreReceipt": attention_link,
        "inputs": attention.get("inputs") or {},
        "manifestShapeContract": attention.get("manifestShapeContract") or {},
        "coverage": coverage,
        "semanticParity": {
            "scope": "attention_core_cpu_oracle_bit_exact",
            "comparison": "bit_exact_np_array_equal",
            "passed": not any(
                blocker.endswith("_attention_core_parity_not_passed")
                for blocker in blockers
            ),
            "maxAbsErr": max_abs_err,
            "queryHeadsCompared": total_query_heads,
            "claimScope": (
                "Correctness is limited to the attention-core diagnostic "
                "implemented by the receipt: full-head Q.K plus grouped "
                "K/V stream reuse. It is not full attention semantics, "
                "decoder-stack parity, logits parity, hardware, or "
                "performance evidence."
            ),
        },
        "groupedKvEvidence": grouped_kv,
        "shapeRuns": summaries,
        "blockers": blockers,
        "remainingClaimBlockers": [
            "full_attention_semantics_parity",
            "full_decoder_block_manifest_shape_execution",
            "full_decoder_stack_manifest_shape_execution",
            "embed_unembed_and_logits_parity",
            "cerebras_hardware_receipt",
        ],
    }


def _depth_diagnostic_entry(
    *,
    source_label: str,
    parity_rel: str,
    trace_rel: str,
) -> dict[str, Any]:
    parity_link = _file_link(parity_rel)
    trace_link = _file_link(trace_rel)
    entry: dict[str, Any] = {
        "sourceLabel": source_label,
        "numLayers": 35,
        "claimable": False,
        "parity": {
            "path": parity_rel,
            "exists": parity_link.get("exists", False),
        },
        "trace": trace_link,
        "blockers": [],
    }

    parity: dict[str, Any] | None = None
    if parity_link.get("exists"):
        entry["parity"]["sha256"] = parity_link.get("sha256")
        try:
            loaded = load_json(resolve(parity_rel))
            if isinstance(loaded, dict):
                parity = loaded
        except json.JSONDecodeError:
            entry["blockers"].append("parity_receipt_invalid_json")
    else:
        entry["blockers"].append("parity_receipt_missing")

    if parity is not None:
        p = parity.get("parity") or {}
        entry["parity"].update({
            "verdict": parity.get("verdict"),
            "weightsSourceLabel": parity.get("weightsSourceLabel"),
            "weightSetPinMode": parity.get("weightSetPinMode"),
            "weightsAudit": _file_link(parity.get("weightsAuditPath", "")),
            "weightsDir": parity.get("weightsDir"),
            "layersCompared": int(p.get("layersCompared", 0)),
            "tolerancePassed": bool(p.get("tolerancePassed")),
            "maxAbsErrAcrossLayers": float(
                p.get("maxAbsErrAcrossLayers", 0.0)
            ),
            "maxAllowedErrAcrossLayers": float(
                p.get("maxAllowedErrAcrossLayers", 0.0)
            ),
            "meanAbsErrAcrossLayers": float(
                p.get("meanAbsErrAcrossLayers", 0.0)
            ),
        })
        if parity.get("verdict") != "parity_passed":
            entry["blockers"].append("parity_not_passed")
        if int(parity.get("numLayers", 0)) != 35:
            entry["blockers"].append("not_full_declared_depth")
        if not bool(p.get("tolerancePassed")):
            entry["blockers"].append("tolerance_not_passed")

    if trace_link.get("exists"):
        try:
            trace = load_json(resolve(trace_rel))
        except json.JSONDecodeError:
            trace = {}
            entry["blockers"].append("trace_invalid_json")
        layer = trace.get("layerBlockSmoke") or {}
        run = trace.get("executedRun") or {}
        runtime_stop = run.get("runtimeStop") or {}
        output = run.get("output") or {}
        entry["trace"].update({
            "numLayersChained": run.get("numLayersChained"),
            "status": run.get("status"),
            "elapsedMs": run.get("elapsedMs"),
            "runtimeStopReached": bool(runtime_stop.get("reached")),
            "kernelIsStub": bool(layer.get("kernelIsStub")),
            "kernelStage": layer.get("kernelStage"),
            "streamExecutionPlan": {
                "path": layer.get("planPath"),
                "sha256": layer.get("planSha256"),
            },
            "sendReceiveCounts": layer.get("sendReceiveCounts") or {},
            "hostIoLayout": layer.get("hostIoLayout") or [],
            "hostSdkTelemetry": {
                "measurementSource": (
                    (run.get("streamTelemetry") or {}).get("measurementSource")
                ),
                "streamCount": len(run.get("streams") or []),
                "streamEventsTailCount": len(run.get("streamEventsTail") or []),
            },
            "output": _file_link(output.get("path", "")),
        })
        if run.get("status") != "succeeded":
            entry["blockers"].append("trace_run_not_succeeded")
        if run.get("numLayersChained") != 35:
            entry["blockers"].append("trace_depth_mismatch")
        if runtime_stop.get("reached") is not True:
            entry["blockers"].append("runtime_stop_not_reached")
        if layer.get("kernelIsStub") is not False:
            entry["blockers"].append("kernel_is_stub")
        counts = layer.get("sendReceiveCounts") or {}
        if counts.get("sends") != 3 or counts.get("receives") != 1:
            entry["blockers"].append("send_receive_count_mismatch")
    else:
        entry["blockers"].append("trace_missing")

    return entry


def _build_sdklayout_depth_diagnostic_evidence(
    receipt: dict[str, Any],
) -> dict[str, Any] | None:
    """Bind full-depth smoke diagnostics without promoting them to claims."""
    model_id = (receipt.get("modelId") or "").lower()
    if "e2b" not in model_id:
        return None

    diagnostic_depth = 35
    depth_tag = f"L{diagnostic_depth}"
    depth_slug = depth_tag.lower()
    entries = [
        _depth_diagnostic_entry(
            source_label="bf16_safetensors",
            parity_rel=(
                "bench/out/gemma-4-e2b-real-weight-parity-"
                f"{depth_tag}.json"
            ),
            trace_rel=(
                "bench/out/gemma-4-e2b-real-weight-parity/"
                f"{depth_tag}/csl-sdklayout/trace.json"
            ),
        ),
        _depth_diagnostic_entry(
            source_label="doppler_rdrr_q4k_int4ple",
            parity_rel=(
                "bench/out/doppler-rdrr/"
                f"gemma-4-e2b-int4ple-rdrr-{depth_slug}-"
                "parity.json"
            ),
            trace_rel=(
                "bench/out/doppler-rdrr/"
                f"gemma-4-e2b-int4ple-rdrr-{depth_slug}-"
                "parity-work/"
                "csl-sdklayout/trace.json"
            ),
        ),
    ]
    entry_blockers = [
        f"{e['sourceLabel']}:{b}"
        for e in entries
        for b in e.get("blockers", [])
    ]
    passed_entries = [
        e for e in entries
        if not e.get("blockers")
        and ((e.get("parity") or {}).get("verdict") == "parity_passed")
        and ((e.get("parity") or {}).get("tolerancePassed") is True)
    ]
    status = (
        "full_depth_smoke_diagnostic_passed"
        if len(passed_entries) == len(entries)
        else "blocked"
    )
    return {
        "status": status,
        "claimable": False,
        "claimScope": (
            "Full declared-depth E2B smoke-chain diagnostic only. The "
            "same generated SdkLayout layer-block contract is chained "
            "for 35 layers with BF16-derived and RDRR/Q4_K_M-derived "
            "smoke slices. This is not upstream manifest-shape Doe/CSL "
            "runtime execution, not Doppler production inference parity, "
            "and not hardware evidence."
        ),
        "declaredModelDepth": 35,
        "manifestShapeRuntimeExecuted": False,
        "diagnostics": entries,
        "blockers": entry_blockers,
        "remainingClaimBlockers": [
            "full_manifest_shape_doe_csl_runtime_execution",
            "doppler_production_inference_parity",
            "cerebras_hardware_receipt",
        ],
    }


def _build_doppler_webgpu_capture_evidence(
    receipt: dict[str, Any],
) -> dict[str, Any] | None:
    """Bind Doppler model capture through Doe's WebGPU provider."""
    model_id = (receipt.get("modelId") or "").lower()
    if "e2b" not in model_id:
        return None

    capture_rel = (
        "bench/out/doppler-capture/"
        "gemma-4-e2b-doe-webgpu-capture-graph.json"
    )
    capture_link = _file_link(capture_rel)
    blockers: list[str] = []
    graph: dict[str, Any] = {}
    if capture_link.get("exists") is not True:
        blockers.append("doppler_webgpu_capture_graph_missing")
    else:
        try:
            loaded = load_json(resolve(capture_rel))
            if isinstance(loaded, dict):
                graph = loaded
            else:
                blockers.append("doppler_webgpu_capture_graph_not_object")
        except json.JSONDecodeError:
            blockers.append("doppler_webgpu_capture_graph_invalid_json")

    metadata = graph.get("metadata") or {}
    bootstrap = metadata.get("bootstrap") or {}
    model = metadata.get("model") or {}
    lowering = metadata.get("loweringTarget") or {}
    counts = {
        "buffers": len(graph.get("buffers") or []),
        "bufferWrites": len(graph.get("bufferWrites") or []),
        "shaderModules": len(graph.get("shaderModules") or []),
        "computePipelines": len(graph.get("computePipelines") or []),
        "commandBuffers": len(graph.get("commandBuffers") or []),
        "submissions": len(graph.get("submissions") or []),
        "readbacks": len(graph.get("readbacks") or []),
        "unsupported": len(graph.get("unsupported") or []),
    }
    if graph:
        if graph.get("artifactKind") != "doe_webgpu_capture_graph":
            blockers.append("doppler_webgpu_capture_graph_kind_mismatch")
        if not graph.get("graphSha256"):
            blockers.append("doppler_webgpu_capture_graph_sha_missing")
        if bootstrap.get("providerInstalled") is not True:
            blockers.append("doppler_webgpu_provider_not_installed")
        if bootstrap.get("adapterProbeSucceeded") is not True:
            blockers.append("doppler_webgpu_adapter_probe_not_succeeded")
        if model.get("modelId") != "gemma-4-e2b-it-q4k-ehf16-af32":
            blockers.append("doppler_webgpu_capture_model_id_mismatch")
        for field, blocker in (
            ("shaderModules", "doppler_webgpu_capture_no_shader_modules"),
            ("computePipelines", "doppler_webgpu_capture_no_pipelines"),
            ("commandBuffers", "doppler_webgpu_capture_no_command_buffers"),
            ("submissions", "doppler_webgpu_capture_no_submissions"),
        ):
            if counts[field] < 1:
                blockers.append(blocker)
        if counts["unsupported"] != 0:
            blockers.append("doppler_webgpu_capture_contains_unsupported_calls")

    status = "capture_graph_recorded" if not blockers else "blocked"
    shader_hashes = [
        module.get("wgslSha256")
        for module in (graph.get("shaderModules") or [])
        if isinstance(module, dict) and module.get("wgslSha256")
    ]
    return {
        "status": status,
        "claimable": False,
        "claimScope": (
            "Doe-owned Node WebGPU provider bootstrap installed into a "
            "Doppler Gemma-4 E2B capture run, plus manifest-shape WGSL "
            "capture only. This records the input graph Doe must lower "
            "to HostPlan/SdkLayout/CSL; it does not prove full Doppler "
            "inference, CSL simulator execution, hardware, or performance."
        ),
        "captureGraph": {
            **capture_link,
            "graphSha256": graph.get("graphSha256"),
        },
        "bootstrap": {
            "sourceRepo": bootstrap.get("sourceRepo"),
            "sourcePath": bootstrap.get("sourcePath"),
            "providerModule": bootstrap.get("providerModule"),
            "providerInstalled": bool(bootstrap.get("providerInstalled")),
            "adapterProbeSucceeded": bool(
                bootstrap.get("adapterProbeSucceeded")
            ),
        },
        "model": {
            "modelId": model.get("modelId"),
            "modelType": model.get("modelType"),
            "quantization": model.get("quantization"),
            "manifestPath": model.get("manifestPath"),
            "manifestSha256": model.get("manifestSha256"),
            "shardCount": model.get("shardCount"),
            "tensorCount": model.get("tensorCount"),
            "architecture": model.get("architecture") or {},
        },
        "webgpuSubset": {
            "supportedWebgpuMethods": graph.get("supportedWebgpuMethods") or [],
            "unsupportedCslFeatures": graph.get("unsupportedCslFeatures") or [],
            "shaderWgslSha256": shader_hashes,
            "recordedUnsupportedCalls": graph.get("unsupported") or [],
        },
        "lowering": {
            "status": lowering.get("status") or "pending_hostplan_lowering",
            "targetBackend": lowering.get("backend") or "csl",
            "targetRuntime": (
                lowering.get("targetRuntime") or "sdk_layout_streaming"
            ),
            "hostPlanLinked": False,
            "sourceGraphSha256": graph.get("graphSha256"),
        },
        "counts": counts,
        "blockers": blockers,
        "remainingClaimBlockers": [
            "captured_graph_to_hostplan_lowering",
            "hostplan_to_sdklayout_compile",
            "csl_simulator_parity_against_doppler_runtime",
            "full_gemma4_e2b_decoder_logits",
            "cerebras_hardware_receipt",
        ],
    }


def _build_doppler_webgpu_capture_lowering_evidence(
    receipt: dict[str, Any],
) -> dict[str, Any] | None:
    """Bind the first captured WebGPU graph to a CSL attention slice."""
    model_id = (receipt.get("modelId") or "").lower()
    if "e2b" not in model_id:
        return None

    lowering_rel = (
        "bench/out/doppler-capture/"
        "gemma-4-e2b-capture-to-csl-attention-core-lowering.json"
    )
    lowering_link = _file_link(lowering_rel)
    blockers: list[str] = []
    lowering: dict[str, Any] = {}
    if lowering_link.get("exists") is not True:
        blockers.append("doppler_webgpu_capture_lowering_receipt_missing")
    else:
        try:
            loaded = load_json(resolve(lowering_rel))
            if isinstance(loaded, dict):
                lowering = loaded
            else:
                blockers.append("doppler_webgpu_capture_lowering_not_object")
        except json.JSONDecodeError:
            blockers.append("doppler_webgpu_capture_lowering_invalid_json")

    source = lowering.get("source") or {}
    host_plan_view = lowering.get("capturedHostPlanView") or {}
    artifacts = lowering.get("loweredArtifacts") or {}
    simulator = lowering.get("simulatorEvidence") or {}
    semantic = simulator.get("semanticParity") or {}
    source_graph = source.get("captureGraph") or {}

    if lowering:
        if lowering.get("artifactKind") != (
            "doe_doppler_webgpu_capture_to_csl_attention_core_lowering"
        ):
            blockers.append("doppler_webgpu_capture_lowering_kind_mismatch")
        if lowering.get("status") != (
            "attention_core_capture_slice_lowered_and_simulated"
        ):
            blockers.append("doppler_webgpu_capture_lowering_not_simulated")
        if lowering.get("claimable") is not False:
            blockers.append("doppler_webgpu_capture_lowering_claimable")
        if source_graph.get("graphSha256") != (
            (receipt.get("dopplerWebgpuCaptureEvidence") or {})
            .get("captureGraph", {})
            .get("graphSha256")
        ):
            blockers.append("doppler_webgpu_capture_lowering_graph_sha_mismatch")
        if int(host_plan_view.get("workgroupDispatchCount", 0)) < 1:
            blockers.append("doppler_webgpu_capture_lowering_no_dispatches")
        if len(host_plan_view.get("bindings") or []) < 4:
            blockers.append("doppler_webgpu_capture_lowering_bindings_missing")
        if semantic.get("passed") is not True:
            blockers.append("doppler_webgpu_capture_lowering_parity_not_passed")
        if semantic.get("againstDopplerProductionInference") is not False:
            blockers.append("doppler_webgpu_capture_lowering_scope_mismatch")

    status = (
        "attention_core_capture_slice_lowered_and_simulated"
        if not blockers
        else "blocked"
    )
    return {
        "status": status,
        "claimable": False,
        "claimScope": (
            "Partial captured-graph lowering only. This binds the "
            "Doppler WebGPU capture graph to the first Gemma-4 E2B "
            "manifest-shape attention-core SdkLayout/CSL simulator "
            "slice and its CPU-oracle parity; it is not full Doppler "
            "inference capture, not full graph lowering, not logits "
            "parity, not hardware, and not performance evidence."
        ),
        "loweringReceipt": {
            **lowering_link,
            "sourceGraphSha256": source_graph.get("graphSha256"),
        },
        "source": {
            "captureGraph": source_graph,
            "shaderModules": source.get("shaderModules") or [],
            "model": source.get("model") or {},
        },
        "capturedHostPlanView": {
            "workload": host_plan_view.get("workload"),
            "workgroupSize": host_plan_view.get("workgroupSize") or [],
            "workgroupDispatchCount": host_plan_view.get(
                "workgroupDispatchCount"
            ),
            "readbackCheckpoints": host_plan_view.get("readbackCheckpoints"),
            "bindingCount": len(host_plan_view.get("bindings") or []),
            "bufferRoles": [
                role.get("role")
                for role in (host_plan_view.get("bufferRoles") or [])
                if isinstance(role, dict)
            ],
        },
        "loweredArtifacts": {
            "sdkVersionFloor": artifacts.get("sdkVersionFloor"),
            "targetBackend": artifacts.get("targetBackend"),
            "targetRuntime": artifacts.get("targetRuntime"),
            "pythonSdkLayoutRunner": artifacts.get("pythonSdkLayoutRunner") or {},
            "cslKernel": artifacts.get("cslKernel") or {},
            "attentionCoreReceipt": artifacts.get("attentionCoreReceipt") or {},
        },
        "simulatorEvidence": {
            "status": simulator.get("status"),
            "hardwareExecuted": bool(simulator.get("hardwareExecuted")),
            "semanticParity": {
                "passed": bool(semantic.get("passed")),
                "scope": semantic.get("scope"),
                "againstDopplerProductionInference": bool(
                    semantic.get("againstDopplerProductionInference")
                ),
                "shapeRunCount": len(semantic.get("shapeRuns") or []),
            },
        },
        "blockers": blockers,
        "remainingClaimBlockers": [
            "ordinary_doppler_inference_graph_capture",
            "full_captured_webgpu_graph_to_hostplan_lowering",
            "automated_wgsl_to_csl_kernel_lowering",
            "embed_unembed_decoder_logits_parity",
            "cerebras_hardware_receipt",
        ],
    }

