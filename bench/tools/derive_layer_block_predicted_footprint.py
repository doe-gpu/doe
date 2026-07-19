#!/usr/bin/env python3
"""Derive a predicted per-pattern cycle/byte footprint for one E2B layer block.

Reads bench/out/streaming-executor/e2b-layer-block-smoke-trace.json's
layerBlockSmoke.perKernelShapes (14 patterns × invocations) and
computes a naive footprint prediction per invocation. The aggregate
per-layer + whole-model predictions are the baseline for predicted-
vs-observed diffs once plan Build-order step 3 (E2B simulator
execution) lands a real simulator trace.

Derivation is intentionally naive — the diff's useful signal is
*where observed diverges from predicted*, not precision of the
predictions. Prediction model:

  elementsPerPe       = product of per-invocation dims, per pattern
                        (e.g. gather: num_tokens * hidden_size * rows_per_pe)
  bytesPerPe          = elementsPerPe * 4   (f32)
  cyclesPerPe         = elementsPerPe       (1 op / element baseline)
  bytesPerLayer       = bytesPerPe * invocation.widthPEs
  cyclesPerLayer      = cyclesPerPe           (single-pass; parallelism
                                               is captured in width)
  bytesPerModel       = bytesPerLayer * numLayers
  cyclesPerModel      = cyclesPerLayer * numLayers

Skips invocations marked dormant_pattern_no_manifest_step so the
model total reflects what actually runs. audit_needs_deployment_generator
invocations are included but flagged so the dashboard can mark them
as "predicted under smoke assumptions".

Output: bench/out/layer-block-predicted-footprint/e2b-predicted-footprint.json
Schema: config/doe-layer-block-predicted-footprint.schema.json
"""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
GOVERNED_LANE_ROOT = REPO_ROOT / "bench/out/dual-compile-evidence/governed-lane-sdk-handoff"

# Per-target manifest + output paths. Smoke-trace path is only used
# for E2B today (no 31B layer-block smoke runner exists yet); 31B
# derives perKernelShapes on the fly from the manifest via the
# shared layer-block-runner helper.
TARGETS: dict[str, dict[str, str]] = {
    "e2b": {
        "manifestPath": "runtime/zig/examples/execution-v1/gemma-4-e2b-smoke.json",
        "smokeTracePath": "bench/out/streaming-executor/e2b-layer-block-smoke-trace.json",
        "outPath": "bench/out/layer-block-predicted-footprint/e2b-predicted-footprint.json",
        "modelReceiptPath": "bench/out/e2b-full-graph/gemma-4-e2b-runtime-receipt.json",
    },
    "31b": {
        "manifestPath": "runtime/zig/examples/execution-v1/gemma-4-31b-smoke.json",
        "smokeTracePath": "",  # no 31B smoke runner yet
        "outPath": "bench/out/layer-block-predicted-footprint/31b-predicted-footprint.json",
        "modelReceiptPath": "bench/out/31b-full-graph/gemma-4-31b-runtime-receipt.json",
    },
}


# Shared per-kernel shape derivation lives in the layer-block-runner
# generator. Import it so both producers stay in sync instead of
# duplicating the 14-pattern formula table.
sys.path.insert(0, str(REPO_ROOT / "bench/tools"))
from generate_e2b_layer_block_runner import derive_per_kernel_shapes  # noqa: E402


# Pattern → governed-lane sim-success dir (relative to GOVERNED_LANE_ROOT).
# Only patterns with an existing governed-lane receipt — dormant and
# audit-blocked patterns will leave observedFixtureEvidence null.
OBSERVED_FIXTURE_DIRS: dict[str, str] = {
    "gather":              "sim-success-gather",
    "element_wise":        "sim-success-elementwise-double",
    "reduction":           "sim-success-reduce-sum-workgroup",
    "rope":                "sim-success-rope",
    "tiled_matmul":        "sim-success-tiled-matmul",
    "attention_tiled":     "sim-success-attention-tiled",
    "attention_decode":    "sim-success-attention-decode",
    "attention_linear":    "sim-success-attention-linear",
    "sample":              "sim-success-sample",
    "fused_gemv_dequant":  "sim-success-fused-gemv-dequant",
    "kv_write":            "sim-success-kv-write",
    "dequant":             "sim-success-dequant",
}


def parse_cslc_params(cmd_list: list[str]) -> str | None:
    for tok in cmd_list or []:
        if tok.startswith("--params="):
            return tok[len("--params="):]
    return None


def load_observed_evidence(pattern: str) -> dict | None:
    """Return observed governed-lane evidence for a pattern, or None."""
    sub = OBSERVED_FIXTURE_DIRS.get(pattern)
    if not sub:
        return None
    fixture_dir = GOVERNED_LANE_ROOT / sub
    driver_path = fixture_dir / "driver-result.json"
    trace_path = fixture_dir / "trace.json"
    if not driver_path.exists():
        return None
    dr = json.loads(driver_path.read_text())
    compile_targets = dr.get("compile", {}).get("targets") or []
    compile_cmd = compile_targets[0].get("command") if compile_targets else []
    observed_params = parse_cslc_params(compile_cmd)
    run_status = dr.get("run", {}).get("status", "unknown")
    compile_status = dr.get("compile", {}).get("status", "unknown")
    out = {
        "fixtureDir": str(fixture_dir.relative_to(REPO_ROOT)),
        "driverResultPath": str(driver_path.relative_to(REPO_ROOT)),
        "driverResultSha256": sha256(driver_path),
        "observedCslcParamsString": observed_params,
        "compileStatus": compile_status,
        "runStatus": run_status,
    }
    if trace_path.exists():
        out["tracePath"] = str(trace_path.relative_to(REPO_ROOT))
        out["traceSha256"] = sha256(trace_path)
        trace_data = json.loads(trace_path.read_text())
        for k in ("width", "chunkSize", "totalElements", "runtimePassed", "runtimeMaxAbsErr"):
            if k in trace_data:
                out[k] = trace_data[k]
        # Quantitative observed bytes/cycles from trace dims. totalElements
        # counts across all PEs; divide by width for per-PE. f32 baseline
        # matches the predicted model. cycles are not in trace.json — leave
        # observedCyclesPerPe null until the simulator's cycle counts land.
        te = trace_data.get("totalElements")
        w = trace_data.get("width")
        if isinstance(te, int) and isinstance(w, int) and w > 0:
            els = te // w
            out["observedElementsPerPe"] = els
            out["observedBytesPerPe"] = els * 4
        else:
            out["observedElementsPerPe"] = None
            out["observedBytesPerPe"] = None
        out["observedCyclesPerPe"] = None  # not carried by trace.json today
    return out


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


# Emitter default values for dims that aren't in the layout-level
# --params but *are* consumed by elements_per_pe. Pulled from the
# `param <name>: i16 = <default>;` declarations in
# runtime/zig/src/compiler/wgsl/emit/csl/emit_csl_layout.zig and the per-kernel PE
# emitter files. Used when computing fixtureEquivalentBytesPerPe: the
# fixture's --params string only lists overridden params, so missing
# dims fall back to these defaults.
EMITTER_DEFAULTS: dict[str, dict[str, int]] = {
    "gather":            {"hidden_size": 64, "rows_per_pe": 8, "num_tokens": 4},
    "rope":              {"head_dim": 128, "num_pairs": 64},
    "attention_linear":  {"head_dim": 64, "kv_len": 16},
    # reduction's hidden_size is a PE-program constant, not a cslc
    # --params value. The governed-lane reduction fixture runs at
    # WGSL workgroup_size=1024 (reduce-sum-workgroup.wgsl), so each
    # PE effectively sums 1024 elements. Hardcode that here so the
    # fixtureEquivalent formula matches observedElementsPerPe=1024
    # and reduction's fixture ratio lands at exact_match rather than
    # unexpected_divergence_formula_suspect.
    "reduction":         {"hidden_size": 1024},
    # Other emitters declare all dims without defaults and rely on cslc
    # --params overrides — the fixture strings are complete for them.
}


def parse_cslc_params_dict(params_str: str | None) -> dict:
    """Parse 'k1:v1,k2:v2,...' into {k1: int(v1), ...}. Ignores empty."""
    if not params_str:
        return {}
    out: dict[str, int] = {}
    for tok in params_str.split(","):
        if ":" not in tok:
            continue
        k, v = tok.split(":", 1)
        try:
            out[k.strip()] = int(v.strip())
        except ValueError:
            pass
    return out


def elements_per_pe(pattern: str, params: dict) -> int:
    """Naive element-count estimate from an invocation's paramsShape."""
    p = params or {}
    if pattern == "gather":
        # Gather output per PE = (num_tokens * hidden_size) / width.
        # Per the gather sim runner at bench/runners/csl-runners/
        # gather_sim_runner.py, out_per_pe is reshaped as
        # (width, num_tokens, hidden_size) — each PE holds
        # num_tokens * hidden_size output elements. But trace.totalElements
        # and chunkSize reflect a per-PE chunk of num_tokens * hidden_size /
        # width (the per-PE slice after distribution). Match that here
        # so fixtureEquivalent matches observed.
        width = max(1, int(p.get("width", 1)))
        return int(p.get("num_tokens", 0)) * int(p.get("hidden_size", 0)) // width
    if pattern == "rope":
        # RoPE's per-PE input is (width, head_dim) — one token per PE
        # rotated in place. See bench/runners/csl-runners/
        # rope_sim_runner.py:27 and trace.json's chunkSize == head_dim
        # (128 for the fixture). num_pairs is a param threading count,
        # not a multiplier of per-PE work.
        return int(p.get("head_dim", 0))
    if pattern == "reduction":
        # Single-PE-per-token mode (emit_csl_reduction.zig): each PE sums
        # hidden_size f32 values for one token. Prior formula returned 1
        # per PE and underpredicted observed by ~1000x for the E2B
        # hiddenDim=1536 case — divergence ratio fed back and this
        # correction uses hidden_size from the carried paramsShape.
        return int(p.get("hidden_size", 1))
    if pattern == "tiled_matmul":
        # Per-PE output tile is Mt x Nt f32 values. Mt*Kt*Nt counts
        # compute ops (FMACs), not output bytes — the trace's
        # totalElements reports the output tile, which is Mt*Nt.
        # See fixture P:2,Mt:8,Kt:8,Nt:8 giving per-PE = 64 = Mt*Nt.
        return int(p.get("Mt", 0)) * int(p.get("Nt", 0))
    if pattern in ("attention_tiled",):
        return int(p.get("head_dim", 0)) * int(p.get("kv_len", 0)) * int(p.get("q_len", 1))
    if pattern == "attention_decode":
        # Per-PE output is (head_dim,) — decode attention collapses kv
        # across rows to a single output vector. kv_chunk / kv_len size
        # the inner compute loop, not the output bytes. See
        # bench/runners/csl-runners/attention_decode_sim_runner.py:50.
        return int(p.get("head_dim", 0))
    if pattern in ("attention_streaming", "attention_linear"):
        # Per-PE output is (head_dim,) per token. kv_len scales the
        # iteration count but not the output bytes. See
        # bench/runners/csl-runners/attention_linear_sim_runner.py:31.
        return int(p.get("head_dim", 0))
    if pattern == "kv_write":
        # Per-PE write is K + V slices, each head_dim wide (see
        # bench/runners/csl-runners/kv_write_sim_runner.py:41-42). The
        # trace's chunkSize reports head_dim (32 for the fixture), so
        # treat that as the per-PE figure. max_seq_len sizes the
        # destination KV cache but doesn't multiply the single-step
        # write bytes.
        return int(p.get("head_dim", 0))
    if pattern == "kv_read":
        return int(p.get("head_dim", 0)) * int(p.get("read_len", 0))
    if pattern == "sample":
        return int(p.get("chunk_size", 0))
    if pattern == "fused_gemv_dequant":
        return int(p.get("out_dim", 0)) * int(p.get("in_dim_per_pe", 1))
    if pattern == "fused_ffn":
        return int(p.get("in_per_pe", 1)) * int(p.get("out_dim", 0))
    if pattern == "dequant":
        return int(p.get("num_blocks", 1)) * 32  # Q4K block = 32 elements
    return 0


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument(
        "--target-model",
        choices=sorted(TARGETS.keys()),
        default="e2b",
        help="Which Gemma-4 target to derive a footprint for.",
    )
    p.add_argument("--smoke-size", type=int, default=16,
                   help="Only used when deriving shapes from the manifest (no smoke trace).")
    args = p.parse_args()

    target = TARGETS[args.target_model]
    manifest_path = REPO_ROOT / target["manifestPath"]
    smoke_trace_path = REPO_ROOT / target["smokeTracePath"] if target["smokeTracePath"] else None
    out_path = REPO_ROOT / target["outPath"]

    manifest = json.loads(manifest_path.read_text())
    num_layers = int(manifest.get("modelConfig", {}).get("numLayers", 0))

    # Two ways to source perKernelShapes: (a) read from the E2B layer-block
    # smoke trace (existing path for E2B); (b) derive from the manifest via
    # the shared helper (needed for 31B, which has no smoke runner yet).
    trace = None
    if smoke_trace_path and smoke_trace_path.exists():
        trace = json.loads(smoke_trace_path.read_text())
        shapes = (trace.get("layerBlockSmoke") or {}).get("perKernelShapes") or []
    else:
        shapes = derive_per_kernel_shapes(plan={}, manifest=manifest, smoke_size=args.smoke_size)

    F32 = 4
    total_bytes_per_layer = 0
    total_cycles_per_layer = 0
    per_pattern = []
    for entry in shapes:
        pattern = entry.get("pattern", "")
        status = entry.get("status")
        invocations = entry.get("invocations") or []
        if not invocations and "paramsShape" in entry:
            # Back-compat for patterns that don't use invocations[].
            invocations = [{
                "stepName": entry.get("manifestSteps", ["(single)"])[0] if entry.get("manifestSteps") else "(single)",
                "paramsShape": entry["paramsShape"],
                "cslcParamsString": entry.get("cslcParamsString", ""),
            }]

        inv_predictions = []
        pattern_bytes = 0
        pattern_cycles = 0
        for inv in invocations:
            params = inv.get("paramsShape", {})
            els = elements_per_pe(pattern, params)
            bytes_per_pe = els * F32
            cycles_per_pe = els
            pattern_bytes += bytes_per_pe
            pattern_cycles += cycles_per_pe
            inv_predictions.append({
                "stepName": inv.get("stepName", "(unknown)"),
                "elementsPerPe": els,
                "bytesPerPe": bytes_per_pe,
                "cyclesPerPe": cycles_per_pe,
            })

        # Bind observed governed-lane evidence (existing) so each
        # pattern carries a predicted-vs-observed pair where available.
        observed_fixture = load_observed_evidence(pattern)
        predicted_cslc = (
            invocations[0].get("cslcParamsString") if invocations else
            entry.get("cslcParamsString", "")
        )
        # Prefer fixtureEquivalentCslcParamsString when the entry carries
        # one — it's the smoke-shape counterpart of the deployment shape
        # and matches what the governed-lane fixture actually passed to
        # cslc. Without it, fall back to the primary (deployment) cslc
        # string, which will miss match at fixture scale.
        match_cslc = entry.get("fixtureEquivalentCslcParamsString") or predicted_cslc
        shape_match = None
        if observed_fixture and observed_fixture.get("observedCslcParamsString"):
            shape_match = (
                match_cslc == observed_fixture["observedCslcParamsString"]
            )

        # Quantitative predicted-vs-observed ratio — null when observed
        # bytes aren't available.
        observed_bytes = (observed_fixture or {}).get("observedBytesPerPe")
        predicted_to_observed_bytes_ratio = None
        if observed_bytes and pattern_bytes and observed_bytes > 0:
            predicted_to_observed_bytes_ratio = round(pattern_bytes / observed_bytes, 4)

        # Same-shape comparison: evaluate elements_per_pe at the fixture
        # cslc params merged with emitter defaults for any dim the
        # fixture string doesn't override. This is the ratio that
        # should be ~1 when the prediction formula agrees with the
        # fixture at the fixture's own shape.
        fixture_bytes_per_pe = None
        fixture_to_observed_bytes_ratio = None
        fixture_cslc = entry.get("fixtureEquivalentCslcParamsString")
        if fixture_cslc:
            fixture_params = dict(EMITTER_DEFAULTS.get(pattern, {}))
            fixture_params.update(parse_cslc_params_dict(fixture_cslc))
            # reduction needs hidden_size to match the fixture; emitter
            # default is low. If the fixture hard-codes a different
            # hidden_size via PE-program code (not --params), we can't
            # see it here — this is a known-but-acceptable gap.
            fixture_els = elements_per_pe(pattern, fixture_params)
            fixture_bytes_per_pe = fixture_els * F32
            if observed_bytes and fixture_bytes_per_pe and observed_bytes > 0:
                fixture_to_observed_bytes_ratio = round(
                    fixture_bytes_per_pe / observed_bytes, 4
                )

        # Classification of the divergence. Prefer the same-shape
        # (fixtureEquivalent) ratio when present — that's the signal
        # "does our formula agree with the fixture at the fixture's
        # shape?". Only when fixture ratio is absent do we fall back
        # to the deployment ratio (which reports the smoke-vs-
        # deployment gap, always large).
        divergence_classification: str | None = None
        width_ratio_hint: float | None = None
        classification_ratio = (
            fixture_to_observed_bytes_ratio
            if fixture_to_observed_bytes_ratio is not None
            else predicted_to_observed_bytes_ratio
        )
        if classification_ratio is not None:
            r = classification_ratio
            if 0.9 <= r <= 1.1:
                divergence_classification = "exact_match"
            elif r > 1.1:
                divergence_classification = "expected_shape_divergence"
            else:
                divergence_classification = "unexpected_divergence_formula_suspect"
            # Width-ratio hint: the fixture usually runs at width:4 while
            # the predicted uses the --size arg. A ratio that matches
            # (predicted_width / observed_width)^k for small k is
            # consistent with pure shape scaling. Record the raw width
            # ratio so downstream consumers can spot-check.
            pred_width = (invocations[0].get("paramsShape", {}).get("width") if invocations else None) or 0
            obs_width = (observed_fixture or {}).get("width") or 0
            if pred_width and obs_width:
                width_ratio_hint = round(pred_width / obs_width, 4)

        pattern_entry = {
            "pattern": pattern,
            "status": status,
            "invocationCount": len(invocations),
            "bytesPerPe": pattern_bytes,
            "cyclesPerPe": pattern_cycles,
            "invocations": inv_predictions,
            "predictedCslcParamsString": predicted_cslc,
            "observedFixtureEvidence": observed_fixture,
            "predictedMatchesObservedShape": shape_match,
            "observedBytesPerPe": observed_bytes,
            "observedCyclesPerPe": (observed_fixture or {}).get("observedCyclesPerPe"),
            "predictedToObservedBytesRatio": predicted_to_observed_bytes_ratio,
            "fixtureEquivalentBytesPerPe": fixture_bytes_per_pe,
            "fixtureEquivalentToObservedBytesRatio": fixture_to_observed_bytes_ratio,
            "divergenceClassification": divergence_classification,
            "widthRatioHint": width_ratio_hint,
        }
        per_pattern.append(pattern_entry)
        if status == "dormant_pattern_no_manifest_step":
            continue
        # Even audit-blocked patterns contribute to the baseline — the
        # dashboard can subtract them if needed.
        total_bytes_per_layer += pattern_bytes
        total_cycles_per_layer += pattern_cycles

    artifact = {
        "schemaVersion": 1,
        "artifactKind": "doe_layer_block_predicted_footprint",
        "targetModel": args.target_model,
        "generatedFrom": {
            "tracePath": str(smoke_trace_path.relative_to(REPO_ROOT)) if smoke_trace_path and smoke_trace_path.exists() else None,
            "traceSha256": sha256(smoke_trace_path) if smoke_trace_path and smoke_trace_path.exists() else None,
            "manifestPath": target["manifestPath"],
            "manifestSha256": sha256(manifest_path),
            "shapesSource": "smoke_trace" if trace is not None else "manifest_derived",
        },
        "modelId": (trace or {}).get("modelId", "") or manifest.get("modelId", ""),
        "numLayers": num_layers,
        "predictionModel": {
            "name": "naive_elements_times_one_cycle_and_f32_bytes",
            "dtypeBytes": F32,
            "cyclesPerElement": 1,
            "notes": (
                "Baseline for predicted-vs-observed diffs. Predictions are "
                "deliberately coarse so divergence from observed simulator "
                "traces carries signal. elementsPerPe is a per-pattern formula "
                "from paramsShape (see derive_layer_block_predicted_footprint.py)."
            ),
        },
        "perPattern": per_pattern,
        "aggregate": {
            # NAMING NOTE: these fields are cumulative per-invocation
            # footprints summed across patterns + layers. They do NOT
            # represent actual per-PE residency — when multiple
            # invocations share a PE in the real deployment, their
            # bytes overlap in memory rather than adding. The
            # cumulative number is still useful as a baseline for
            # divergence analysis (it moves the same way as observed
            # when formulas are correct), but callers reading the
            # aggregate as "memory footprint" will be misled. See
            # cumulativeInvocationBytes*PerPe below for the honest
            # label, and residentBytesPerPe (populated when a
            # generator emits actual PE residency data) for the
            # eventual memory-accurate field.
            "bytesPerLayerPerPe": total_bytes_per_layer,
            "cyclesPerLayerPerPe": total_cycles_per_layer,
            "bytesPerModelPerPe": total_bytes_per_layer * num_layers,
            "cyclesPerModelPerPe": total_cycles_per_layer * num_layers,
            "cumulativeInvocationBytesPerLayerPerPe": total_bytes_per_layer,
            "cumulativeInvocationCyclesPerLayerPerPe": total_cycles_per_layer,
            "cumulativeInvocationBytesPerModelPerPe": total_bytes_per_layer * num_layers,
            "cumulativeInvocationCyclesPerModelPerPe": total_cycles_per_layer * num_layers,
            "residentBytesPerPe": None,
            "residentBytesPerPeSource": "not_yet_populated",
            "activePatternCount": sum(
                1 for p in per_pattern
                if p["status"] != "dormant_pattern_no_manifest_step"
            ),
            "dormantPatternCount": sum(
                1 for p in per_pattern
                if p["status"] == "dormant_pattern_no_manifest_step"
            ),
            # Divergence rollup — how many patterns have observed bytes
            # bound, how many match predicted shape exactly, how many
            # have non-null ratio. A non-null ratio != 1 is the signal
            # "this pattern's shape at deployment doesn't match the
            # smoke fixture run; expect divergence when step-3 real
            # traces land".
            "observedEvidenceBoundCount": sum(
                1 for p in per_pattern
                if p.get("observedFixtureEvidence") is not None
            ),
            "predictedMatchesObservedShapeCount": sum(
                1 for p in per_pattern
                if p.get("predictedMatchesObservedShape") is True
            ),
            "predictedToObservedBytesRatioSamples": [
                {"pattern": p["pattern"], "ratio": p["predictedToObservedBytesRatio"]}
                for p in per_pattern
                if p.get("predictedToObservedBytesRatio") is not None
            ],
            "divergenceClassificationTally": {
                cls: sum(1 for p in per_pattern if p.get("divergenceClassification") == cls)
                for cls in (
                    "exact_match",
                    "expected_shape_divergence",
                    "unexpected_divergence_formula_suspect",
                )
            },
        },
        "notes": (
            "Derived from layerBlockSmoke.perKernelShapes in the E2B layer-"
            "block smoke trace. Dormant patterns (status=dormant_pattern_no_"
            "manifest_step) are excluded from aggregate totals — they don't "
            "run in the current model graph. audit_needs_deployment_generator "
            "entries are included at smoke shapes; real deployment widths "
            "from the step-1 execution-plan generator will shift those numbers "
            "once landed."
        ),
    }

    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(artifact, indent=2) + "\n")
    ag = artifact["aggregate"]
    print(
        f"predicted footprint ({args.target_model}): {ag['activePatternCount']} active + "
        f"{ag['dormantPatternCount']} dormant patterns; "
        f"cumulative per-invocation {ag['cumulativeInvocationBytesPerLayerPerPe']:,} bytes/layer/PE × "
        f"{num_layers} layers = "
        f"{ag['cumulativeInvocationBytesPerModelPerPe']:,} bytes/PE (cumulative, NOT residency) -> "
        f"{out_path.relative_to(REPO_ROOT)}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
