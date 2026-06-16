#!/usr/bin/env python3
"""One-shot pipeline smoke for the E2B layer-block in-loop work.

Runs seven steps in order (early-exits on STEP 0 or STEP 5 drift),
then asserts the contract:

  0. test_e2b_layer_block_compute.py
       -> golden-value unit test for the canonical compute_layer_block
          (early-exit gate: if goldens drifted, downstream regen is
          skipped so stale traces don't propagate the divergence)
  1. generate_e2b_layer_block_runner.py
       -> regen the SDK runner from the live CSL kernel + manifest
  2. emit_e2b_layer_block_synthetic_trace.py
       -> regen the numpy-only synthetic trace
  3. compare_runner_vs_synthetic.py
       -> regen the cross-runtime parity check verdict
  4. build_model_runtime_receipt.py (with E2B inputs)
       -> regen the model receipt; binds steps 2 + 3 by path/sha
  5. validate_e2b_receipt_links.py
       -> walk every (path, sha256) pair the receipt records and
          assert the file is on-disk with matching sha (early-exit
          gate: a stale link means the receipt now disagrees with
          the file system, downstream contract assertions can't
          trust the receipt content)
  6. emit_csl_reference_parity_sample.py
       -> regen the schema sample at
          examples/doe-csl-reference-parity.gemma-4-e2b-layer-block.sample.json
          from current artifacts so it auto-surfaces sha drift and
          the numpy-reference output digest (was previously hand-
          maintained and went stale across kernel upgrades)

Then asserts a growing set of structural contracts. The current set
spans C0..C41 (as of the last update; see below for the authoritative
enumeration). Broadly they cover:

  - Core kernel/trace/receipt integrity (C0-C15)
  - Cerebras evidence bundle pack/verify round-trip and the packer ↔
    verifier sync across extensions, path-substrings, and role
    taxonomy (C16, C22, C23, C32)
  - Demo HTML/JS/server invariants: routes, cross-links, data-copy
    targets, emulator soft-fail, ANSI-strip and runner-error
    formatter (C17, C18, C25, C27, C33)
  - Bundle-doc governance: skip-lists synced across packer/gate/
    verifier, pointer-doc stale-lag guard, prep-script ordering,
    tools-index completeness (C28-C31)

Authoritative enumeration lives in two places and stays in sync via
C31: `bench/tools/cerebras-evidence-bundle-tools.md` has the contract
table; this file itself emits `C<N> PASS`/`C<N> FAIL` lines at
runtime. Prefer grepping the code over restating contracts here —
this docstring intentionally does not enumerate individual contracts
because the list drifts faster than prose can keep up.

Exit 0 if all checks pass; exit 1 if any failed (with a per-check
diff report). Lets the parity-contract gate (parallel-safe support
track) use this as a pre-flight before computing its own gate state.
"""

from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path

from e2b_layer_block_self_check_bundle_contracts import run_bundle_contracts
from e2b_layer_block_self_check_context import SelfCheckPaths
from e2b_layer_block_self_check_demo_contracts import run_demo_tooling_contracts
from e2b_layer_block_self_check_model_contracts import run_model_contracts
from e2b_layer_block_self_check_receipt_contracts import run_receipt_contracts

REPO_ROOT = Path(__file__).resolve().parents[2]



def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser()
    p.add_argument(
        "--manifest",
        default="runtime/zig/examples/execution-v1/gemma-4-e2b-smoke.json",
    )
    p.add_argument(
        "--receipt-out",
        default="bench/out/e2b-full-graph/gemma-4-e2b-runtime-receipt.json",
    )
    p.add_argument(
        "--receipt-md-out",
        default="bench/out/e2b-full-graph/gemma-4-e2b-runtime-receipt.md",
    )
    return p.parse_args()


def run_step(label: str, argv: list) -> tuple[bool, str]:
    print(f"  [{label}] " + " ".join(str(a) for a in argv))
    try:
        r = subprocess.run(
            argv,
            cwd=str(REPO_ROOT),
            capture_output=True,
            text=True,
            timeout=300,
        )
    except subprocess.TimeoutExpired:
        return False, "timeout"
    if r.returncode != 0:
        return False, f"exit={r.returncode}\nstderr:\n{r.stderr[-400:]}"
    last = r.stdout.strip().splitlines()
    print(f"     -> {last[-1] if last else '(no output)'}")
    return True, ""


def main() -> int:
    args = parse_args()
    runner_path = REPO_ROOT / "bench/runners/csl-runners/e2b_layer_block_smoke.py"
    kernel_path = REPO_ROOT / (
        "bench/out/streaming-executor/e2b-layer-block-source/"
        "transformer_layer_shape.csl"
    )
    synthetic_path = REPO_ROOT / (
        "bench/out/streaming-executor/e2b-layer-block-synthetic-trace.json"
    )
    receipt_path = REPO_ROOT / args.receipt_out
    schema_path = REPO_ROOT / "config/doe-model-runtime-receipt.schema.json"

    print("E2B layer-block self-check (in-loop pipeline)")
    print()
    print("STEP 0: golden-value unit test for compute_layer_block")
    ok, msg = run_step("unit-test", [
        "python3", "bench/tools/test_e2b_layer_block_compute.py",
    ])
    if not ok:
        print(f"  FAILED: {msg}")
        print()
        print("ABORT: compute_layer_block goldens drifted from the unit "
              "test. Skipping downstream regen so stale traces don't "
              "propagate the divergence. If the kernel changed "
              "intentionally, regenerate the goldens via:")
        print("  PRINT_GOLDENS=1 python3 bench/tools/test_e2b_layer_block_compute.py")
        print("then update VARYING_GOLDEN_HEX in the test and re-run.")
        return 1

    print()
    print("STEP 1: regen runner from live CSL kernel + manifest")
    ok, msg = run_step("runner", [
        "python3", "bench/tools/generate_e2b_layer_block_runner.py",
    ])
    if not ok:
        print(f"  FAILED: {msg}")
        return 1

    print()
    print("STEP 2: regen numpy-only synthetic trace")
    ok, msg = run_step("synthetic", [
        "python3", "bench/tools/emit_e2b_layer_block_synthetic_trace.py",
    ])
    if not ok:
        print(f"  FAILED: {msg}")
        return 1

    print()
    print("STEP 3: regen cross-runtime parity check")
    ok, msg = run_step("parity-check", [
        "python3", "bench/tools/compare_runner_vs_synthetic.py",
    ])
    if not ok:
        print(f"  FAILED: {msg}")
        return 1

    print()
    print("STEP 3a: refresh Doppler WebGPU capture graph")
    ok, msg = run_step("doppler-capture", [
        "node",
        "bench/tools/capture_doppler_gemma4_webgpu_graph.mjs",
        "--out-json",
        "bench/out/doppler-capture/"
        "gemma-4-e2b-doe-webgpu-capture-graph.json",
    ])
    if not ok:
        print(f"  FAILED: {msg}")
        return 1

    print()
    print("STEP 3b: refresh capture-to-CSL attention-core lowering receipt")
    ok, msg = run_step("capture-lowering", [
        "python3",
        "bench/tools/record_doppler_capture_to_csl_attention_core_lowering.py",
        "--out-json",
        "bench/out/doppler-capture/"
        "gemma-4-e2b-capture-to-csl-attention-core-lowering.json",
    ])
    if not ok:
        print(f"  FAILED: {msg}")
        return 1

    print()
    print("STEP 4: regen model receipt")
    ok, msg = run_step("receipt", [
        "python3", "bench/tools/build_model_runtime_receipt.py",
        "--execution-manifest", args.manifest,
        "--host-plan", "bench/out/e2b-full-graph/host-plan.json",
        "--memory-plan", "bench/out/e2b-full-graph/memory-plan.json",
        "--runtime-config", "bench/out/e2b-full-graph/runtime-config.json",
        "--simulator-plan", "bench/out/e2b-full-graph/simulator-plan.json",
        "--out-json", args.receipt_out,
        "--out-md", args.receipt_md_out,
    ])
    if not ok:
        print(f"  FAILED: {msg}")
        return 1

    # Auto-regen the doe_run.py all-lanes rollup so executionStatus +
    # realWeightEvidence the receipt just computed are visible to the
    # dashboard and browser cockpit without a second manual step. Per
    # user's 15-item list (#10): "Regenerate the doe_run.py all-lanes
    # rollup after every receipt regen so the dashboard and demo
    # consume one canonical summary."
    print()
    print("STEP 4b: regen all-lanes rollup from per-target receipts + model receipt")
    ok, msg = run_step("rollup", [
        "python3", "bench/tools/summarize_doe_run_lanes.py",
        "--num-layers", "1",
        "--out-json", "bench/out/doe-run/all-lanes-summary-L1.json",
    ])
    if not ok:
        # Rollup regen is not-fatal — the receipt is authoritative.
        # Just surface the reason so it's visible in the log, then
        # continue. A missing rollup would only affect the dashboard.
        print(f"  NON-FATAL: {msg}")

    print()
    print("STEP 5: validate receipt link integrity (path + sha for every "
          "linked artifact)")
    ok, msg = run_step("link-integrity", [
        "python3", "bench/tools/validate_e2b_receipt_links.py",
    ])
    if not ok:
        print(f"  FAILED: {msg}")
        print()
        print("ABORT: at least one receipt-linked artifact has drifted "
              "on disk (path missing or sha mismatch). The receipt "
              "now disagrees with the file system; rerun the self-"
              "check after fixing the drift.")
        return 1

    print()
    print("STEP 6: regen CSL reference parity sample from current artifacts")
    ok, msg = run_step("parity-sample", [
        "python3", "bench/tools/emit_csl_reference_parity_sample.py",
    ])
    if not ok:
        print(f"  FAILED: {msg}")
        return 1

    print()
    print("CONTRACT ASSERTIONS")
    paths = SelfCheckPaths(
        repo_root=REPO_ROOT,
        runner_path=runner_path,
        kernel_path=kernel_path,
        synthetic_path=synthetic_path,
        receipt_path=receipt_path,
        schema_path=schema_path,
    )
    failures, receipt, lbk = run_receipt_contracts(paths)
    failures.extend(run_model_contracts(paths, receipt))
    failures.extend(run_demo_tooling_contracts(paths))
    failures.extend(run_bundle_contracts(paths))

    print()
    if failures:
        print(f"SELF-CHECK FAILED ({len(failures)} contract violation(s)):")
        for f in failures:
            print("  " + f)
        return 1

    print("SELF-CHECK PASSED -- in-loop pipeline is healthy.")
    pc = lbk.get("crossRuntimeParityCheck", {})
    print(
        "  parity-check verdict: promotionEligible="
        + str(pc.get("promotionEligible"))
        + f"  met={len(pc.get('preconditionsMet', []))}/6"
        + f"  missing={pc.get('preconditionsMissing', [])}"
    )
    if pc.get("promotionEligible") is not True:
        missing = pc.get("preconditionsMissing", []) or []
        if any(
            token in m
            for m in missing
            for token in ("P2", "P3", "P5", "P6")
        ):
            print()
            print(
                "  to unblock: run the following on a cs_python-equipped "
                "host, then rerun this self-check:"
            )
            print("    python3 bench/runners/csl-runners/e2b_layer_block_smoke.py")
            print(
                "  that command compiles + runs the 35-layer chain, "
                "emits the smoke-trace with output digest, and the "
                "flip wire promotes executionStatus to simulator_success."
            )
    return 0


if __name__ == "__main__":
    sys.exit(main())
