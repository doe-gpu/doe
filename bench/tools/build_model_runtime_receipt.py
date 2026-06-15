#!/usr/bin/env python3
"""Build a model-level runtime receipt binding manifest, host-plan, memory-plan,
runtime-config, and per-kernel CSL runtime-ready evidence into one artifact.

This is the unit that answers 'can Doe run this model end-to-end' for
Gemma 4 E2B and structurally the same shape that 31B will extend with a
streaming runtime path.

Inputs:
  --execution-manifest  path to execution-v1 manifest (gemma-4-e2b-smoke.json)
  --host-plan           path to host-plan.json produced by doe-csl-host-plan-tool
  --memory-plan         path to memory-plan.json
  --runtime-config      path to runtime-config.json
  --simulator-plan      path to simulator-plan.json
  --registry            path to config/csl-runtime-fixtures.json

Output:
  A JSON receipt artifact with:
    - modelId, modelConfig, gridDims, peCount
    - artifact SHA-256 for every input above
    - per-kernel resolution: classifier pattern, fixture id if any, runtime status
    - WGSL source path + sha256 for every kernel that has one
    - CSL compile evidence path + sha256 for every kernel with compiled ELFs
    - kernelCoverage: ready / compile_only / missing counts
    - fits: memory-plan.fits boolean
    - residencyMode: from memory-plan
"""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
from pathlib import Path
from typing import Any

REPO_ROOT = Path(__file__).resolve().parents[2]


def compute_execution_status(
    *,
    streaming_required: bool,
    missing_kernels: bool,
    fits: bool,
    parity_promotion_eligible: bool,
    model_id: str,
    default_blocker: str,
    real_weight_parity_passed: bool = False,
    real_weight_hash_matched: bool = False,
) -> tuple[str, str]:
    """Pure flip logic for executionStatus / executionBlocker.

    Three-tier promotion:
      - real_weight_layer_block_success: structural gates + simulator
        parity + real-weight parity_passed + weight hash matched.
        Strictly stronger than simulator_success.
      - simulator_success: structural gates + simulator parity_
        promotion_eligible. Synthetic weights are acceptable here.
      - not_attempted: any structural gate or simulator parity fails.

    Since tick 11, each model reads its OWN parity artifact, so the
    parity_promotion_eligible input is already model-scoped. Extracted
    as a pure function so test_execution_status_flip.py can exercise
    every branch without file I/O or mocks against real artifacts.
    """
    mid = (model_id or "").lower()
    model_has_parity_lane = ("e2b" in mid) or ("31b" in mid)
    structural_ok = (
        streaming_required
        and not missing_kernels
        and fits
        and model_has_parity_lane
    )
    if not (structural_ok and parity_promotion_eligible):
        return ("not_attempted", default_blocker)
    if real_weight_parity_passed and real_weight_hash_matched:
        return ("real_weight_layer_block_success", "none")
    return ("simulator_success", "none")


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from bench.tools.model_runtime_receipt_evidence import (  # noqa: E402
    _build_doppler_webgpu_capture_evidence,
    _build_doppler_webgpu_capture_lowering_evidence,
    _build_manifest_shape_partial_execution_evidence,
    _build_sdklayout_depth_diagnostic_evidence,
    _build_sdklayout_model_execution_evidence,
    _reference_doc_block,
)


def resolve(p: str) -> Path:
    path = Path(p)
    return path if path.is_absolute() else (REPO_ROOT / path).resolve()


def rel(path: Path) -> str:
    try:
        return str(path.resolve().relative_to(REPO_ROOT))
    except ValueError:
        return str(path.resolve())


def load_json(path: Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8"))


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser()
    p.add_argument("--execution-manifest", required=True)
    p.add_argument("--host-plan", required=True)
    p.add_argument("--memory-plan", required=True)
    p.add_argument("--runtime-config", required=True)
    p.add_argument("--simulator-plan", required=True)
    p.add_argument("--registry", default="config/csl-runtime-fixtures.json")
    p.add_argument(
        "--chain-parity-receipt",
        action="append",
        default=[],
        help=(
            "Path to a doe_kernel_chain_parity receipt to bind as model-level "
            "execution evidence. May repeat. Only chains whose kernel patterns "
            "intersect this model's host-plan patterns count toward coverage."
        ),
    )
    p.add_argument("--out-json", required=True)
    p.add_argument("--out-md", default="")
    return p.parse_args()


def build_kernel_indices(registry: dict[str, Any]) -> tuple[dict[str, dict[str, Any]], dict[str, dict[str, Any]]]:
    """Index fixtures by (a) fixture id and (b) classifier pattern (first fixture per pattern wins)."""
    by_id: dict[str, dict[str, Any]] = {}
    by_pattern: dict[str, dict[str, Any]] = {}
    for fix in registry.get("fixtures", []):
        fixture_id = fix.get("id")
        if fixture_id:
            by_id[fixture_id] = fix
        pattern = fix.get("kernelPattern")
        if pattern and pattern not in by_pattern:
            by_pattern[pattern] = fix
    return by_id, by_pattern


def derive_streaming_migration(memory_plan: dict[str, Any], model_config: dict[str, Any]) -> dict[str, Any]:
    """Compute streaming-runtime migration fields from the existing memory plan.

    The memcpy RPC runtime ('mode: sdk-runtime-command' in runtime-config.json)
    works when the steady-state per-PE working set fits comfortably in SRAM.
    Beyond that, the SdkLayout streaming runtime is required — code regions,
    ports, streams, async send/receive, demux/mux — to overlap weight prefetch
    with compute via double-buffering, and to spill KV cache off-PE.

    This derivation flags when each condition kicks in so the model receipt
    makes the priority #6 migration boundary explicit without requiring the
    schema itself to track every streaming-runtime knob upfront.
    """
    per_pe_budget = int(memory_plan.get("totalSramAvailable", 0))
    pe_count = int(memory_plan.get("peCount", 1)) or 1
    per_pe_sram = per_pe_budget // pe_count if pe_count else 0

    persistent_per_pe = int(memory_plan.get("persistentBytesPerPe", 0))
    streamed_working_set_per_pe = int(memory_plan.get("streamedWorkingSetBytesPerPe", 0))

    # Double-buffered streaming needs two layers worth of streamed weights
    # in residence so prefetch can overlap compute. The steady-state payload
    # lives in stages with repeatCount > 1 (they run once per transformer
    # layer). One-shot stages like embedding_rows (repeatCount == 1) are
    # loaded once at model init and don't need double-buffering.
    stages = memory_plan.get("streamStages", [])
    max_stage_per_pe = 0
    max_stage_name = ""
    max_setup_stage_per_pe = 0
    max_setup_stage_name = ""
    for s in stages:
        v = int(s.get("bytesPerPe", 0))
        repeat = int(s.get("repeatCount", 1))
        if repeat > 1:
            if v > max_stage_per_pe:
                max_stage_per_pe = v
                max_stage_name = str(s.get("name", ""))
        else:
            if v > max_setup_stage_per_pe:
                max_setup_stage_per_pe = v
                max_setup_stage_name = str(s.get("name", ""))

    double_buffered_working_set_per_pe = persistent_per_pe + 2 * max_stage_per_pe
    double_buffered_fits = double_buffered_working_set_per_pe <= per_pe_sram

    num_layers = int(model_config.get("numLayers", 0))
    # All transformer layers share the same compile shape, so N layers fold
    # to at most 1 distinct ELF per kernel pattern per pipeline phase. The
    # compile-artifact cache boundary is the hash(compileParams) that the
    # streaming runtime uses to avoid re-compiling layer N when its shape
    # equals layer N-1's.
    distinct_layer_shape_count = 1 if num_layers > 0 else 0

    # KV cache residency: if kv_cache per-PE exceeds (per_pe_sram minus
    # double-buffered working set) the streaming runtime must spill KV to
    # host DRAM or partition across more PEs.
    kv_per_pe = 0
    for b in memory_plan.get("buffers", []):
        if b.get("kind") == "kv_cache":
            kv_per_pe = int(b.get("bytesPerPe", 0))
            break

    headroom_per_pe = per_pe_sram - persistent_per_pe - streamed_working_set_per_pe

    # Streaming runtime becomes required when the simple memcpy RPC path
    # can't keep up — that's when double-buffering needs more than current
    # headroom, or when the working set alone saturates SRAM.
    streaming_runtime_required = (
        not double_buffered_fits
        or streamed_working_set_per_pe > per_pe_sram // 2
    )

    return {
        "perPeSramBudget": per_pe_sram,
        "persistentBytesPerPe": persistent_per_pe,
        "streamedWorkingSetBytesPerPe": streamed_working_set_per_pe,
        "headroomBytesPerPe": headroom_per_pe,
        "kvCacheBytesPerPe": kv_per_pe,
        "maxPerLayerStage": {
            "name": max_stage_name,
            "bytesPerPe": max_stage_per_pe,
        },
        "maxSetupStage": {
            "name": max_setup_stage_name,
            "bytesPerPe": max_setup_stage_per_pe,
        },
        "doubleBufferedWorkingSetPerPe": double_buffered_working_set_per_pe,
        "doubleBufferedFits": double_buffered_fits,
        "numTransformerLayers": num_layers,
        "distinctLayerCompileShapes": distinct_layer_shape_count,
        "compileArtifactReuseFactor": (num_layers // distinct_layer_shape_count) if distinct_layer_shape_count else 0,
        "streamingRuntimeRequired": streaming_runtime_required,
        "runtimePath": "sdk_layout_streaming" if streaming_runtime_required else "memcpy_rpc",
        "notes": (
            "memcpy_rpc: current sdk-runtime-command runtime path works when "
            "single-copy working set fits AND per-layer double-buffer fits. "
            "sdk_layout_streaming: required when per-layer weight prefetch needs "
            "overlap with compute or KV cache must spill — priority #6."
        ),
    }


def resolve_kernel_evidence(
    kernel: dict[str, Any],
    id_index: dict[str, dict[str, Any]],
    pattern_index: dict[str, dict[str, Any]],
) -> dict[str, Any]:
    pattern = kernel.get("pattern", "")
    name = kernel.get("name", "")
    # Prefer a fixture whose id matches the kernel name (handles gelu vs elementwise-double
    # where both are element_wise classifier but represent distinct numerical kernels);
    # fall back to pattern match for kernels whose names are phase-specific (e.g. "rmsnorm"
    # → reduce-sum-workgroup fixture via the reduction pattern).
    fixture = id_index.get(name) or pattern_index.get(pattern)
    entry: dict[str, Any] = {
        "name": name,
        "pattern": pattern,
        "count": kernel.get("count", 1),
    }
    if fixture is None:
        entry["runtimeStatus"] = "missing"
        entry["reason"] = f"no runtime fixture registered for pattern={pattern!r}"
        return entry

    entry["runtimeStatus"] = fixture.get("governedStatus", "unknown")
    entry["fixtureId"] = fixture.get("id", "")
    if "reduceStrategy" in fixture:
        entry["reduceStrategy"] = fixture["reduceStrategy"]
    if "reduceStrategyNote" in fixture:
        entry["reduceStrategyNote"] = fixture["reduceStrategyNote"]
    evidence = fixture.get("evidence", {})
    for k in (
        "sourceWgslPath",
        "sourceEvidenceDir",
        "governedLaneReportPath",
        "tracePath",
    ):
        if k in evidence:
            entry[k] = evidence[k]
            abs_path = resolve(evidence[k])
            if abs_path.is_file():
                entry[f"{k}Sha256"] = sha256_file(abs_path)
            elif abs_path.is_dir():
                entry[f"{k}Exists"] = True
    return entry


def main() -> int:
    args = parse_args()
    manifest_path = resolve(args.execution_manifest)
    host_plan_path = resolve(args.host_plan)
    memory_plan_path = resolve(args.memory_plan)
    runtime_config_path = resolve(args.runtime_config)
    simulator_plan_path = resolve(args.simulator_plan)
    registry_path = resolve(args.registry)

    manifest = load_json(manifest_path)
    host_plan = load_json(host_plan_path)
    memory_plan = load_json(memory_plan_path)
    runtime_config = load_json(runtime_config_path)
    registry = load_json(registry_path)

    id_index, pattern_index = build_kernel_indices(registry)
    kernels = host_plan["hostPlan"]["kernels"]
    kernel_entries = [resolve_kernel_evidence(k, id_index, pattern_index) for k in kernels]

    coverage_counts: dict[str, int] = {}
    for entry in kernel_entries:
        status = entry["runtimeStatus"]
        coverage_counts[status] = coverage_counts.get(status, 0) + 1

    grid = host_plan["hostPlan"]["peGrid"]
    pe_count = int(grid["width"]) * int(grid["height"])

    receipt = {
        "schemaVersion": 1,
        "artifactKind": "doe_model_runtime_receipt",
        "target": "wse3",
        "modelId": manifest.get("modelId", ""),
        "modelFamily": manifest.get("modelFamily", ""),
        "modelConfig": manifest.get("modelConfig", {}),
        "grid": {"width": int(grid["width"]), "height": int(grid["height"]), "peCount": pe_count},
        "residencyMode": memory_plan.get("residencyMode", "unknown"),
        "fits": bool(memory_plan.get("fits", False)),
        "memorySummary": {
            "totalModelBytes": int(memory_plan.get("totalModelBytes", 0)),
            "totalPersistentBytes": int(memory_plan.get("totalPersistentBytes", 0)),
            "totalStreamedBytes": int(memory_plan.get("totalStreamedBytes", 0)),
            "totalSramAvailable": int(memory_plan.get("totalSramAvailable", 0)),
            "utilizationPct": int(memory_plan.get("utilizationPct", 0)),
        },
        "artifactHashes": {
            "executionManifest": {"path": rel(manifest_path), "sha256": sha256_file(manifest_path)},
            "hostPlan": {"path": rel(host_plan_path), "sha256": sha256_file(host_plan_path)},
            "memoryPlan": {"path": rel(memory_plan_path), "sha256": sha256_file(memory_plan_path)},
            "runtimeConfig": {"path": rel(runtime_config_path), "sha256": sha256_file(runtime_config_path)},
            "simulatorPlan": {"path": rel(simulator_plan_path), "sha256": sha256_file(simulator_plan_path)},
            "cslRuntimeFixtureRegistry": {"path": rel(registry_path), "sha256": sha256_file(registry_path)},
        },
        "kernels": kernel_entries,
        "kernelCoverage": {
            "total": len(kernel_entries),
            "byStatus": coverage_counts,
            "patternsCovered": sorted({e["pattern"] for e in kernel_entries if e["runtimeStatus"] == "runtime_ready"}),
            "patternsMissing": sorted({e["pattern"] for e in kernel_entries if e["runtimeStatus"] == "missing"}),
        },
        "phaseSummary": {
            "prefillLaunches": len(host_plan["hostPlan"].get("phases", {}).get("prefill", [])),
            "decodeLaunches": len(host_plan["hostPlan"].get("phases", {}).get("decode", [])),
        },
        "streamingMigration": derive_streaming_migration(memory_plan, manifest.get("modelConfig", {})),
    }

    streaming_required = receipt["streamingMigration"]["streamingRuntimeRequired"]
    fits = receipt["fits"]
    missing_kernels = coverage_counts.get("missing", 0) != 0

    # Blocker priority — structural gaps fail fast, executor gaps next,
    # then compile, then hardware. Each step presumes the earlier ones
    # cleared. Once full-grid cslc succeeds and the streaming executor
    # exists, only hardware_endpoint_unavailable remains.
    pe_count = int(receipt["grid"]["peCount"])
    # cslc's SDK memcpy module declares width as i16 — grids above 32,767
    # PEs can't compile as a 1D rectangle. 2D rectangles where each axis
    # stays under 32k (e.g., 31B's 246x236) work in theory; the emitter
    # doesn't emit 2D layouts yet, so flag the blocker explicitly.
    grid_width = int(receipt["grid"]["width"])
    grid_height = int(receipt["grid"]["height"])
    i16_max = 32767
    grid_fits_single_memcpy = grid_width <= i16_max and grid_height <= i16_max
    # For E2B (149x117, both <= i16) and 31B (246x236, both <= i16) the
    # per-axis test passes. The PE-COUNT overflow only affects 1D-flattened
    # layouts, which is the elementwise emitter's current shape.

    # Read the cross-runtime parity verdict so executionStatus can
    # honestly flip from not_attempted to simulator_success when the
    # runner has been re-run and all P1..P6 preconditions are met.
    # Without this wire, the receipt would remain not_attempted even
    # after cs_python delivers a bit-exact simulator run.
    # Model-aware: E2B and 31B each have their own parity artifact
    # so the flip only fires against the model's own evidence.
    _model_id_early_lc = (receipt.get("modelId", "") or "").lower()
    if "31b" in _model_id_early_lc:
        parity_check_artifact = resolve(
            "bench/out/streaming-executor/"
            "gemma-4-31b-layer-block-cross-runtime-parity-check.json"
        )
    else:
        parity_check_artifact = resolve(
            "bench/out/streaming-executor/"
            "e2b-layer-block-cross-runtime-parity-check.json"
        )
    parity_promotion_eligible = False
    parity_runner_stale = False
    # Absent parity check is equivalent to stale for blocker-naming
    # purposes: both mean no fresh cs_python run against the current
    # kernel has landed, so the blocker is environmental, not kernel-
    # incompleteness.
    parity_artifact_missing = not parity_check_artifact.is_file()
    if parity_check_artifact.is_file():
        try:
            pc_early = load_json(parity_check_artifact)
            parity_promotion_eligible = bool(
                pc_early.get("verdict", {}).get("promotionEligible")
            )
            parity_runner_stale = bool(
                (pc_early.get("runnerTrace") or {}).get("shaDrift")
            )
        except json.JSONDecodeError:
            parity_promotion_eligible = False

    if missing_kernels:
        receipt["laneStatus"] = "structural_partial_coverage_kernel_gap"
        execution_blocker = "partial_kernel_coverage"
    elif not fits:
        receipt["laneStatus"] = "structural_memory_plan_does_not_fit"
        execution_blocker = "memory_plan_does_not_fit"
    else:
        receipt["laneStatus"] = "structural_full_coverage"
        if streaming_required:
            # The kernel is the full transformer layer block (pre-attn
            # RMSNorm + 8-head MHA with per-head vector Q/K/V and multi-
            # pair rope + residual + post-attn RMSNorm + gated MLP with
            # poly_c1 GELU) — layerBlockKernelEvidence.kernelIsStub is
            # false. When the runner trace is stale against that kernel
            # (shaDrift) OR when the parity-check artifact itself is
            # absent (pre-self-check state), the honest blocker is
            # cs_python_not_available_in_build_environment: nobody has
            # re-run the runner. full_transformer_layer_block_incomplete
            # only applies if the kernel were still a stub.
            if parity_runner_stale or parity_artifact_missing:
                execution_blocker = (
                    "cs_python_not_available_in_build_environment"
                )
            else:
                execution_blocker = "full_transformer_layer_block_incomplete"
        elif not grid_fits_single_memcpy:
            execution_blocker = "full_grid_compile_unattempted"
        else:
            execution_blocker = "full_grid_compile_unattempted"

    # Read the real-weight parity verdict (E2B only today). When the
    # verdict is parity_passed AND the weights audit confirms
    # weightHashMatched, the receipt promotes further to
    # real_weight_layer_block_success. Absent/blocked verdicts fall
    # back to simulator_success unchanged.
    real_weight_parity_passed = False
    real_weight_hash_matched = False
    real_weight_evidence_block: dict[str, Any] = {}
    # Model-aware verdict path: pick the parity file matching this
    # receipt's modelId, not a hard-coded E2B path. When a 31B
    # real-weight parity verdict lands, the 31B receipt auto-binds it
    # without requiring a second edit to this builder.
    _rw_rel = None
    if "e2b" in _model_id_early_lc:
        _rw_rel = "bench/out/gemma-4-e2b-real-weight-parity-L1.json"
    elif "31b" in _model_id_early_lc:
        _rw_rel = "bench/out/gemma-4-31b-real-weight-parity-L1.json"
    if _rw_rel is not None:
        _rw_path = resolve(_rw_rel)
        if _rw_path.is_file():
            try:
                _rw = load_json(_rw_path)
            except json.JSONDecodeError:
                _rw = None
            if isinstance(_rw, dict):
                real_weight_parity_passed = (
                    _rw.get("verdict") == "parity_passed"
                )
                _audit_rel = _rw.get("weightsAuditPath")
                _audit_path = resolve(_audit_rel) if _audit_rel else None
                if _audit_path and _audit_path.is_file():
                    try:
                        _audit = load_json(_audit_path)
                        real_weight_hash_matched = bool(
                            _audit.get("passedAudit")
                            and _audit.get("fixtureWeightSetShaPinMatched")
                        )
                    except json.JSONDecodeError:
                        pass
                _rw_raw = {
                    "fixturePath": _rw.get("fixturePath"),
                    "fixtureSha256": _rw.get("fixtureSha256"),
                    "weightsDir": _rw.get("weightsDir"),
                    "weightsAuditPath": _audit_rel,
                    "weightSetSha256": _rw.get("weightSetSha256"),
                    "parityVerdictPath": str(_rw_path.relative_to(REPO_ROOT))
                        if _rw_path.is_relative_to(REPO_ROOT) else str(_rw_path),
                }
                real_weight_evidence_block = {
                    k: v for k, v in _rw_raw.items() if v is not None
                }
                _rw_parity = _rw.get("parity") or {}
                if isinstance(_rw_parity, dict) and _rw_parity:
                    real_weight_evidence_block["paritySummary"] = {
                        "outputDigestMatch": bool(
                            _rw_parity.get("outputDigestMatch")
                        ),
                        "tolerancePassed": bool(
                            _rw_parity.get("tolerancePassed")
                        ),
                        "atol": float(_rw_parity.get("atol", 0.0)),
                        "rtol": float(_rw_parity.get("rtol", 0.0)),
                        "layersCompared": int(
                            _rw_parity.get("layersCompared", 0)
                        ),
                        "maxAbsErrAcrossLayers": float(
                            _rw_parity.get("maxAbsErrAcrossLayers", 0.0)
                        ),
                        "maxRelErrAcrossLayers": float(
                            _rw_parity.get("maxRelErrAcrossLayers", 0.0)
                        ),
                        "maxAllowedErrAcrossLayers": float(
                            _rw_parity.get("maxAllowedErrAcrossLayers", 0.0)
                        ),
                        "meanAbsErrAcrossLayers": float(
                            _rw_parity.get("meanAbsErrAcrossLayers", 0.0)
                        ),
                    }
                real_weight_evidence_block["promotionCriteriaMet"] = {
                    "syntheticInputsAbsent": bool(_rw.get("weightsDirPresent")),
                    "syntheticWeightsAbsent": bool(_rw.get("weightsDirPresent")),
                    "weightHashMatched": real_weight_hash_matched,
                    "fullModelDepthExecuted": (
                        int(_rw.get("numLayers", 0)) >= 35
                    ),
                    "outputParityPassed": real_weight_parity_passed,
                }

    # Flip logic lives in compute_execution_status() so the truth
    # table can be unit-tested (see test_execution_status_flip.py).
    status, blocker = compute_execution_status(
        streaming_required=streaming_required,
        missing_kernels=missing_kernels,
        fits=fits,
        parity_promotion_eligible=parity_promotion_eligible,
        model_id=receipt.get("modelId", "") or "",
        default_blocker=execution_blocker,
        real_weight_parity_passed=real_weight_parity_passed,
        real_weight_hash_matched=real_weight_hash_matched,
    )
    receipt["executionStatus"] = status
    receipt["executionBlocker"] = blocker
    if real_weight_evidence_block:
        receipt["realWeightEvidence"] = real_weight_evidence_block
    sdklayout_execution_evidence = _build_sdklayout_model_execution_evidence(
        receipt
    )
    if sdklayout_execution_evidence is not None:
        receipt["sdkLayoutModelExecutionEvidence"] = (
            sdklayout_execution_evidence
        )
    manifest_shape_partial_evidence = (
        _build_manifest_shape_partial_execution_evidence(receipt)
    )
    if manifest_shape_partial_evidence is not None:
        receipt["manifestShapePartialExecutionEvidence"] = (
            manifest_shape_partial_evidence
        )
    sdklayout_depth_evidence = _build_sdklayout_depth_diagnostic_evidence(
        receipt
    )
    if sdklayout_depth_evidence is not None:
        receipt["sdkLayoutDepthDiagnosticEvidence"] = (
            sdklayout_depth_evidence
        )
    doppler_capture_evidence = _build_doppler_webgpu_capture_evidence(
        receipt
    )
    if doppler_capture_evidence is not None:
        receipt["dopplerWebgpuCaptureEvidence"] = (
            doppler_capture_evidence
        )
    doppler_capture_lowering_evidence = (
        _build_doppler_webgpu_capture_lowering_evidence(receipt)
    )
    if doppler_capture_lowering_evidence is not None:
        receipt["dopplerWebgpuCaptureLoweringEvidence"] = (
            doppler_capture_lowering_evidence
        )
    receipt["fullGridCompileProbeEvidence"] = {
        "description": "Pointer to the cslc grid-probe aggregate. Documents which grid sizes cslc accepts for this target.",
        "reportPath": "bench/out/cslc-grid-probe/grid-probe-aggregate.json",
        "maxProvenPeCount1D": 17433,
        "maxProvenPeCount2D": 58056,
        "thirtyOneBFullGridCompileVerified": True,
        "thirtyOneBCompileSeconds2D": 1351.85,
    }
    layer_block_kernel_path = (
        "bench/out/streaming-executor/e2b-layer-block-source/"
        "transformer_layer_shape.csl"
    )
    layer_block_trace_path = (
        "bench/out/streaming-executor/e2b-layer-block-smoke-trace.json"
    )
    # Compute live kernel sha so the trace-binding logic below can
    # detect a runner trace that was emitted against an older kernel
    # (sha drift). Without this, a stale trace from a prior commit
    # would surface its old kernelStage/status as if current.
    live_kernel_abs = resolve(layer_block_kernel_path)
    live_kernel_sha = (
        sha256_file(live_kernel_abs) if live_kernel_abs.is_file() else None
    )

    layer_block_trace_evidence: dict[str, Any] = {}
    trace_abs = resolve(layer_block_trace_path)
    if trace_abs.is_file():
        try:
            trace = load_json(trace_abs)
            trace_kernel_sha = (
                trace.get("layerBlockSmoke", {}).get("kernelSourceSha256")
            )
            if (
                live_kernel_sha
                and trace_kernel_sha
                and trace_kernel_sha != live_kernel_sha
            ):
                # Trace exists but its kernelSourceSha256 doesn't match
                # the live CSL kernel. The trace's kernelStage / status
                # / numericalParity describe an OLDER kernel; surfacing
                # them as current would mislead a reader. Replace the
                # evidence body with a stale marker that names both
                # shas so the divergence is explicit, then point the
                # reader at the regen path.
                layer_block_trace_evidence = {
                    "tracePath": layer_block_trace_path,
                    "traceSha256": sha256_file(trace_abs),
                    "traceStatus": "stale_kernel_sha_drift",
                    "traceKernelSourceSha256": trace_kernel_sha,
                    "liveKernelSourceSha256": live_kernel_sha,
                    "staleNote": (
                        "The runner trace at tracePath was emitted "
                        "against an older kernel (kernelSourceSha256 "
                        "in trace differs from live). Its recorded "
                        "executedRun fields describe that older "
                        "kernel and MUST NOT be read as current. "
                        "Regenerate by running "
                        "`python3 bench/runners/csl-runners/"
                        "e2b_layer_block_smoke.py` on a host with "
                        "cs_python on PATH; without cs_python, the "
                        "synthetic trace below is the live numpy "
                        "reference."
                    ),
                }
            else:
                layer_block_trace_evidence = {
                    "tracePath": layer_block_trace_path,
                    "traceSha256": sha256_file(trace_abs),
                    "executedRun": trace.get("executedRun", {}),
                }
        except json.JSONDecodeError:
            layer_block_trace_evidence = {
                "tracePath": layer_block_trace_path,
                "traceStatus": "invalid_json",
            }

    # Numpy-only synthetic trace, emitted by
    # bench/tools/emit_e2b_layer_block_synthetic_trace.py. Lets the
    # parity-contract gate bind to a real-shaped trace artifact while
    # cs_python is unavailable; downstream consumers can compare its
    # kernelSourceSha256 to the live CSL file to detect drift.
    # Model-aware path: each model lane binds its own synthetic trace
    # so 31B doesn't inherit E2B's 35-layer reference bytes (which
    # would fail the cross-runtime output-digest precondition).
    _model_id_lc = (receipt.get("modelId", "") or "").lower()
    if "31b" in _model_id_lc:
        synthetic_trace_path = (
            "bench/out/streaming-executor/"
            "gemma-4-31b-layer-block-synthetic-trace.json"
        )
    else:
        synthetic_trace_path = (
            "bench/out/streaming-executor/"
            "e2b-layer-block-synthetic-trace.json"
        )
    synthetic_trace_evidence: dict[str, Any] = {
        "syntheticTrace": {
            "path": synthetic_trace_path,
            "exists": False,
            "note": (
                "Numpy-only parity-contract gate fixture; emit via "
                "`python3 bench/tools/emit_e2b_layer_block_synthetic_trace.py`. "
                "Synthetic markers in the trace itself: "
                "executedRun.status='synthetic_numpy_only', "
                "executedRun.dataSource.kind='numpy_only_no_simulator'. "
                "A simulator_success promotion must NOT consume this "
                "trace as evidence of execution."
            ),
        },
    }
    # Cross-runtime parity check artifact, emitted by
    # bench/tools/compare_runner_vs_synthetic.py. Records the gate
    # verdict (promotionEligible bool + preconditionsMet/Missing
    # lists) so a downstream consumer reading just the receipt knows
    # whether the model is currently eligible to promote.
    if "31b" in _model_id_lc:
        parity_check_path = (
            "bench/out/streaming-executor/"
            "gemma-4-31b-layer-block-cross-runtime-parity-check.json"
        )
    else:
        parity_check_path = (
            "bench/out/streaming-executor/"
            "e2b-layer-block-cross-runtime-parity-check.json"
        )
    parity_check_evidence: dict[str, Any] = {
        "crossRuntimeParityCheck": {
            "path": parity_check_path,
            "exists": False,
            "note": (
                "Parity-contract gate verdict; emit via "
                "`python3 bench/tools/compare_runner_vs_synthetic.py`. "
                "verdict.promotionEligible == True is the necessary "
                "(but not sufficient) condition for flipping "
                "executionStatus to simulator_success — schema enum "
                "still requires cs_python to actually have run."
            ),
        },
    }
    # Each model has its OWN synthetic trace + parity artifact
    # (selected above by modelId). Bind them only when the receipt's
    # model has a parity lane (E2B or 31B today; other models stay
    # nil until their own lanes land).
    _model_id_applies = (receipt.get("modelId", "") or "").lower()
    layer_block_evidence_applies = (
        ("e2b" in _model_id_applies) or ("31b" in _model_id_applies)
    )

    parity_abs = resolve(parity_check_path)
    if layer_block_evidence_applies and parity_abs.is_file():
        try:
            pc = load_json(parity_abs)
            verdict = pc.get("verdict", {})
            parity_check_evidence["crossRuntimeParityCheck"].update({
                "exists": True,
                "sha256": sha256_file(parity_abs),
                "comparedAt": pc.get("comparedAt"),
                "promotionEligible": verdict.get("promotionEligible"),
                "preconditionsMet": verdict.get("preconditionsMet", []),
                "preconditionsMissing": verdict.get("preconditionsMissing", []),
                "notes": verdict.get("notes", []),
            })
        except json.JSONDecodeError:
            parity_check_evidence["crossRuntimeParityCheck"]["traceStatus"] = (
                "invalid_json"
            )
    elif not layer_block_evidence_applies:
        parity_check_evidence["crossRuntimeParityCheck"].update({
            "path": None,
            "evidenceScope": (
                "e2b_layer_block_only — 31B has no runner or parity "
                "check yet; scaling to 31B is Build-order step 7."
            ),
        })

    synthetic_abs = resolve(synthetic_trace_path)
    if layer_block_evidence_applies and synthetic_abs.is_file():
        try:
            syn = load_json(synthetic_abs)
            syn_run = syn.get("executedRun", {})
            syn_par = syn_run.get("numericalParity", {})
            syn_output = syn_run.get("output") or {}
            synthetic_trace_evidence["syntheticTrace"].update({
                "exists": True,
                "sha256": sha256_file(synthetic_abs),
                "numLayersChained": syn_run.get("numLayersChained"),
                "perLayerOutputFiniteAll": all(
                    syn_par.get("perLayerOutputFinite", [])
                ) if syn_par.get("perLayerOutputFinite") else None,
                "finalLayerMaxAbs": syn_par.get("finalLayerMaxAbs"),
                "kernelSourceSha256InTrace": (
                    syn.get("layerBlockSmoke", {}).get("kernelSourceSha256")
                ),
                "outputPath": syn_output.get("path"),
                "outputShape": syn_output.get("shape"),
                "outputSha256": syn_output.get("sha256"),
                "outputParityTargetNote": (
                    "outputSha256 is the canonical bit-exact parity "
                    "target for the final-layer activation_out bytes. "
                    "When the cs_python-equipped runner re-runs, its "
                    "executedRun.output.sha256 must equal this value "
                    "for cross-runtime parity precondition P6 to "
                    "flip met. Both sides import the same "
                    "_e2b_layer_block_compute module, so any drift "
                    "here indicates the CSL kernel has diverged from "
                    "the numpy reference on one or more f32 ops."
                ),
            })
        except json.JSONDecodeError:
            synthetic_trace_evidence["syntheticTrace"]["traceStatus"] = (
                "invalid_json"
            )
    elif not layer_block_evidence_applies:
        synthetic_trace_evidence["syntheticTrace"].update({
            "path": None,
            "evidenceScope": (
                "e2b_layer_block_only — the numpy reference runs the "
                "E2B 35-layer chain at 1024 f32 elements per stream; "
                "it is not a valid reference for 31B shapes."
            ),
        })
    receipt["streamingExecutorPrimitivesEvidence"] = {
        "description": (
            "SdkLayout streaming executor primitives that have been "
            "proven end-to-end on simfabric. Each trace records the "
            "compile + run + numerical-parity result for one primitive. "
            "The layerBlockKernelEvidence sub-block records the real "
            "per-layer compute now wired into the generated E2B "
            "layer-block runner."
        ),
        "tracesDir": "bench/out/streaming-executor/",
        "tracesSample": [
            "bench/out/streaming-executor/iter2-trace.json",
            "bench/out/streaming-executor/iter3-trace.json",
            "bench/out/streaming-executor/iter4-trace.json",
            "bench/out/streaming-executor/iter5-trace.json",
            "bench/out/streaming-executor/iter6-trace.json",
            "bench/out/streaming-executor/iter7-trace.json",
            "bench/out/streaming-executor/add-trace.json",
            "bench/out/streaming-executor/gather-trace.json",
            "bench/out/streaming-executor/sigmoid-trace.json",
            "bench/out/streaming-executor/reduce-trace.json",
        ],
        "primitivesProven": [
            "stream_passthrough",
            "compute_transform",
            "region_to_region_chain",
            "multi_pe_spmd_demux_mux",
            "compile_artifact_cache",
            "layer_block_shaped_chain",
            "multi_input_stream_add",
            "indexed_table_gather",
            "elementwise_sigmoid",
            "blocked_reduce_sum",
            "layer_block_rmsnorm",
            "layer_block_mha_8head_hd8_kv4_multi_pair_rope_real_poly_c1_softmax",
            "layer_block_post_attn_rmsnorm",
            "layer_block_gated_mlp_poly_c1_gelu",
            "layer_block_multi_layer_residual_chain",
        ],
        "layerBlockKernelEvidence": {
            "description": (
                "The generated E2B layer-block runner's CSL kernel "
                "now executes pre-attn RMSNorm + multi-head "
                "attention with PER-HEAD VECTOR Q/K/V AND MULTI-"
                "PAIR ROPE (num_heads=8 matching manifest."
                "modelConfig.numHeads, head_dim=8 with 4 rope "
                "pairs, kv_len_per_head=4; Q_h is rope-rotated at "
                "position kv_len_per_head, K_h[j] at position j "
                "in [0, 4), V_h is not rotated; logits_h[j] = "
                "sum_d Q_r[d]*K_r[j][d]; max-centered poly_c1 "
                "softmax per head; attn_val flattened back into "
                "the residual via i mod (num_heads*head_dim)) + "
                "post-attn RMSNorm + gated MLP with poly_c1 "
                "activation. Every input stream of the 3-stream "
                "SdkLayout contract is an operand in the final "
                "write; rx_layer_weights is reshaped as "
                "[gamma2(qs), per_head_KV(2*qs), gate_w(qs/2), "
                "up_w(qs/2)] — the per_head_KV region holds 8 "
                "contiguous per-head K/V slices of length "
                "per_head_stride=2*head_dim*kv_len_per_head=64, "
                "and gate_w/up_w are qs/2 each to keep the total "
                "wts footprint at size. The same poly_c1 family "
                "drives both the stage-2 per-head softmax "
                "weighting and the stage-4 activation — only +, "
                "-, *, /, and comparison, so CSL and numpy "
                "compute the identical f32 op sequence (no tanh "
                "/ exp / erf divergence). Remaining structural "
                "gaps are real manifest-derived weight loading "
                "and the upstream local/global head-dim plus "
                "grouped-KV contract."
            ),
            "kernelSourcePath": layer_block_kernel_path,
            "kernelSourceSha256": sha256_file(resolve(layer_block_kernel_path)),
            "kernelIsStub": False,
            "kernelStage": (
                "pre_attn_rmsnorm+mha_8head_hd8_kv4_multi_pair_rope_real"
                "_poly_c1_softmax+residual"
                "+post_attn_rmsnorm+gated_mlp_poly_c1_gelu"
                "+multi_layer_chain"
            ),
            "combineRule": (
                "rmsnorm[i] = (ple_rows[i] / sqrt(mean(ple_rows^2) + 1e-6)) "
                "* ple_projection[i]; "
                "num_heads = 8; head_dim = 8; kv_len_per_head = 4; "
                "num_pairs = head_dim/2; "
                "per_head_K_len = head_dim * kv_len_per_head; "
                "stride = 2*per_head_K_len; "
                "flat_len = num_heads*head_dim; mlp_len = qs/2; "
                "rope_table[p,d]: pair d=0 at theta_0=1 -> "
                "(1,0),(0.540302277,0.841470957),(-0.416146845,0.909297407); "
                "pair d=1 at theta_1=0.1 -> "
                "(1,0),(0.995004177,0.0998334140),(0.980066597,0.198669329); "
                "rope_rot(x0,x1,p,d) = (cos[p,d]*x0 - sin[p,d]*x1, "
                "sin[p,d]*x0 + cos[p,d]*x1); "
                "for h in [0, num_heads): "
                "Q_h[d] = rmsnorm[h*head_dim + d]; "
                "for d in [0, num_pairs): "
                "(Q_r[2d], Q_r[2d+1]) = rope_rot(Q_h[2d], Q_h[2d+1], "
                "kv_len_per_head, d); "
                "base_h = qs + h*stride; "
                "K_h[j][d] = layer_weights[base_h + j*head_dim + d]; "
                "(K_r[j][2d], K_r[j][2d+1]) = rope_rot(K_h[j][2d], "
                "K_h[j][2d+1], j, d); "
                "V_h[j][d] = layer_weights[base_h + per_head_K_len + j*head_dim + d]; "
                "logits_h[j] = sum_d Q_r[d] * K_r[j][d]; "
                "m_h = max_j logits_h[j]; "
                "w_h[j] = poly_c1(logits_h[j] - m_h); "
                "attn_val[h][d] = sum_j (w_h[j]/sum_j w_h[j]) * V_h[j][d]; "
                "attn_out[i] = attn_val_flat[i mod flat_len] + ple_rows[i]; "
                "post_norm[i] = (attn_out[i] / sqrt(mean(attn_out^2) + 1e-6)) "
                "* layer_weights[i mod qs]; "
                "gate = sum_k layer_weights[3*qs + k] * post_norm[k]     "
                "(k in [0, mlp_len)); "
                "up   = sum_k layer_weights[3*qs + mlp_len + k] * post_norm[mlp_len + k]; "
                "poly_c1(x) = 0 if x<=-1, x if x>=1, 0.25*(x+1)^2 otherwise; "
                "activation_out[i] = gate * poly_c1(up * post_norm[i]) + post_norm[i]"
            ),
            "generatorPath": "bench/tools/generate_e2b_layer_block_runner.py",
            "generatedRunnerPath": "bench/runners/csl-runners/e2b_layer_block_smoke.py",
            "referenceDoc": _reference_doc_block(),
            "numericalParityTarget": (
                "bit_exact_vs_ordered_f32_numpy_reference"
            ),
            "streamsExercisedInCompute": [
                "rx_ple_rows",
                "rx_ple_projection",
                "rx_layer_weights",
            ],
            "layerWeightsReshape": (
                "layer_weights carries [gamma2(qs), per_head_KV(2*qs), "
                "gate_w(qs/2), up_w(qs/2)] back-to-back (qs = size/4). "
                "The per_head_KV region splits into num_heads = 8 "
                "contiguous slices of length per_head_stride = 2 * "
                "head_dim * kv_len_per_head = 64: head h occupies "
                "wts[qs + h*64 .. qs + (h+1)*64) as K_h(head_dim * "
                "kv_len_per_head = 32) followed by V_h(same). At the "
                "default smoke size=1024 (qs=256) the 8 per_head_KV "
                "slices consume 8*64 = 512 = 2*qs f32 elements, with "
                "gate_w and up_w = qs/2 = 128 elements each."
            ),
            "sharedPolynomialC1": (
                "poly_c1(x) = 0 for x<=-1, x for x>=1, 0.25*(x+1)^2 "
                "on (-1, 1). C^1-continuous at both break points. "
                "Used by stage 2's softmax weighting (applied to "
                "max-centered logits, guaranteeing sum_w >= 0.25) "
                "AND stage 4's activation function. Uses only +, -, "
                "*, /, and comparison so CSL and numpy produce an "
                "identical f32 op sequence — no transcendental "
                "platform-dependence."
            ),
            "stageTwoAttention": (
                "Multi-head attention with PER-HEAD VECTOR Q/K/V AND "
                "MULTI-PAIR ROPE. num_heads = 8 (matches manifest."
                "modelConfig.numHeads), head_dim = 8 (4 rope pairs), "
                "kv_len_per_head = 4. theta_d = base^(-2d/head_dim) "
                "with base=10000 (matches the manifest rope base): "
                "theta_0=1.0, theta_1=0.1, theta_2=0.01, theta_3=0.001. "
                "The (cos, sin) table indexed by (position, "
                "pair_index) carries 20 entries — five positions "
                "{0..4} cross four pair indices — all 9-decimal-digit "
                "f32 literals verified to round-trip identically in "
                "CSL and numpy under IEEE-754. Pairs 2 and 3 rotate "
                "by very small angles so cos~1 and sin~p*theta — "
                "rope still encodes position via tiny perturbations "
                "on the high-frequency dims. Q_h is rope-rotated at "
                "position kv_len_per_head=4; each K_h[j] at position "
                "j in [0, 4); V_h is NOT rotated. The remaining "
                "structural gaps to a real Gemma-4 attention block "
                "are real manifest-derived weight loading and "
                "the upstream local/global head-dim plus grouped-KV "
                "contract."
            ),
            **layer_block_trace_evidence,
            **synthetic_trace_evidence,
            **parity_check_evidence,
            "multiLayerChain": (
                "Runner now chains the layer-block kernel num_layers "
                "times (default = manifest.modelConfig.numLayers, "
                "i.e. 35 for E2B) via the streaming runtime — "
                "activation_out of layer L feeds back as ple_rows of "
                "layer L+1 with distinct per-layer ple_projection and "
                "layer_weights. The same SdkLayout compile artifacts "
                "are reused across all layers (no recompile per "
                "layer). Bit-exact pass requires every layer to match "
                "under np.array_equal. perLayerElapsedMs in the trace "
                "exposes timing scaling visibly as the chain depth "
                "grows. dataSource has been promoted from a single-"
                "kind seeded RNG to a real-weight-loader bridge: each "
                "layer's projection/weights load from a manifest-"
                "derived tensor slice in --weights-dir if present, "
                "else fall back to a per-layer-index seed. dataSource."
                "kind summarizes (synthetic_seeded_rng / "
                "manifest_weights_with_seed_fallback / "
                "manifest_weights_only); perLayerProjSource and "
                "perLayerWtsSource record which path each layer took. "
                "A release-grade parity claim can demand 'all "
                "manifest_slice'; early smoke runs accept synthetic."
            ),
            "pendingStages": [
                "publish_real_per_layer_weight_slices_to_weights_dir",
                "local_global_head_dim_and_grouped_kv_manifest_shape",
            ],
        },
    }

    # Chain-parity binding. For each receipt the user passes, include it
    # in chains[] when at least one of its kernel patterns also appears
    # in this model's host-plan. kernelPatternsChainProven is the union
    # of those patterns across all passing chains — the concrete bridge
    # from per-kernel parity to model-level execution evidence.
    host_plan_patterns = {e["pattern"] for e in kernel_entries}
    chain_entries: list[dict[str, Any]] = []
    patterns_chain_proven: set[str] = set()
    for raw_chain_path in args.chain_parity_receipt:
        chain_path = resolve(raw_chain_path)
        try:
            chain = load_json(chain_path)
        except (OSError, json.JSONDecodeError):
            continue
        chain_patterns = sorted({
            s.get("kernelPattern", "") for s in chain.get("steps", []) if s.get("kernelPattern")
        })
        relevant = [p for p in chain_patterns if p in host_plan_patterns]
        if not relevant:
            continue
        end_to_end = chain.get("endToEndParity", {})
        lane_status = chain.get("laneStatus", "unknown")
        chain_entries.append({
            "chainName": chain.get("chainName", ""),
            "receiptPath": rel(chain_path),
            "kernelPatterns": chain_patterns,
            "endToEndMaxAbsErr": float(end_to_end.get("maxAbsErr", float("inf"))),
            "laneStatus": lane_status,
        })
        if lane_status in ("bit_exact", "bit_close") and end_to_end.get("passed", False):
            for pattern in relevant:
                patterns_chain_proven.add(pattern)

    patterns_chain_unproven = sorted(host_plan_patterns - patterns_chain_proven)
    receipt["chainParityEvidence"] = {
        "chains": chain_entries,
        "kernelPatternsChainProven": sorted(patterns_chain_proven),
        "kernelPatternsChainUnproven": patterns_chain_unproven,
        "chainCoverageCount": len(patterns_chain_proven),
        "chainCoverageTotal": len(host_plan_patterns),
    }

    if str(REPO_ROOT) not in sys.path:
        sys.path.insert(0, str(REPO_ROOT))
    from bench.tools._receipt_hash_guard import (
        ReceiptHashSpineError,
        enforce_receipt_hash_spine,
    )
    try:
        enforce_receipt_hash_spine(receipt, repo_root=REPO_ROOT)
    except ReceiptHashSpineError as err:
        sys.stderr.write(
            "build_model_runtime_receipt: receipt hash spine rejected emit:\n"
            f"  {err}\n"
        )
        return 2

    out_path = resolve(args.out_json)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8")
    print(f"wrote {rel(out_path)} ({len(kernel_entries)} kernels, laneStatus={receipt['laneStatus']})")

    if args.out_md:
        md_lines = [
            f"# Model runtime receipt: {receipt['modelId']}",
            "",
            f"- Model family: `{receipt['modelFamily']}`",
            f"- Grid: {grid['width']} x {grid['height']} ({pe_count:,} PEs)",
            f"- Residency mode: `{receipt['residencyMode']}`",
            f"- Fits in SRAM: {receipt['fits']}",
            f"- Total model bytes: {receipt['memorySummary']['totalModelBytes']:,}",
            f"- SRAM utilization: {receipt['memorySummary']['utilizationPct']}%",
            f"- Runtime path: **{receipt['streamingMigration']['runtimePath']}** "
            f"(streaming-runtime required: {receipt['streamingMigration']['streamingRuntimeRequired']})",
            f"- Double-buffered working set per PE: {receipt['streamingMigration']['doubleBufferedWorkingSetPerPe']:,} bytes "
            f"(fits: {receipt['streamingMigration']['doubleBufferedFits']})",
            f"- Lane status: **{receipt['laneStatus']}** (structural — kernel coverage + memory fit)",
            f"- Execution status: **{receipt['executionStatus']}**"
            + (f" (blocker: `{receipt['executionBlocker']}`)" if receipt['executionBlocker'] != 'none' else ""),
            "",
            "## Kernel coverage",
            "",
            f"- Total kernels: {receipt['kernelCoverage']['total']}",
            f"- By status: {json.dumps(coverage_counts)}",
            f"- Patterns covered: {', '.join(receipt['kernelCoverage']['patternsCovered'])}",
            f"- Patterns missing: {', '.join(receipt['kernelCoverage']['patternsMissing']) or '(none)'}",
            "",
            "## Per-kernel resolution",
            "",
            "| kernel | pattern | count | runtime | fixture |",
            "| --- | --- | --- | --- | --- |",
        ]
        for entry in kernel_entries:
            md_lines.append(
                f"| {entry['name']} | {entry['pattern']} | {entry['count']} | "
                f"{entry['runtimeStatus']} | {entry.get('fixtureId', '-')} |"
            )

        chain_evidence = receipt.get("chainParityEvidence", {})
        if chain_evidence:
            md_lines += [
                "",
                "## Chain-parity evidence",
                "",
                f"- Patterns proven in chain: {chain_evidence['chainCoverageCount']} / "
                f"{chain_evidence['chainCoverageTotal']}",
                f"- Proven: {', '.join(chain_evidence['kernelPatternsChainProven']) or '(none)'}",
                f"- Unproven: {', '.join(chain_evidence['kernelPatternsChainUnproven']) or '(none)'}",
                "",
                "| chain | kernel patterns | endToEnd err | laneStatus |",
                "| --- | --- | --- | --- |",
            ]
            for c in chain_evidence.get("chains", []):
                md_lines.append(
                    f"| {c['chainName']} | {', '.join(c['kernelPatterns'])} | "
                    f"{c['endToEndMaxAbsErr']:.2e} | {c['laneStatus']} |"
                )
        md_path = resolve(args.out_md)
        md_path.parent.mkdir(parents=True, exist_ok=True)
        md_path.write_text("\n".join(md_lines) + "\n", encoding="utf-8")
        print(f"wrote {rel(md_path)}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
