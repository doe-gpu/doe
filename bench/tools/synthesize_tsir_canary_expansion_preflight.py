#!/usr/bin/env python3
"""Synthesize the TSIR canary expansion preflight receipt.

Mitigates "TSIR kernel coverage", "TSIR backend coverage", and "TSIR
numerical statuses" from docs/cerebras-model-ledgers.md (Remaining
no-hardware evidence gaps).

Today the nightly TSIR parity canary covers 6 fixtures
(fused_gemv/rms_norm/gather × webgpu-generic/wse3) plus a partial
real-canary subset (fused_gemv real × 2 backends). This preflight
records:

  - the in-hand bootstrap canary state (3 kernels, 2 backends, 6
    fixtures, identity-chain pass),
  - the real-canary subset state (1 kernel passing + 1 kernel
    structurally blocked),
  - the expansion contract (4 additional real kernels + 2 additional
    backends = full real-canary at 12 fixture pairs),
  - the named blockers that prevent the expansion from running today:
      * doppler_transcript_arg_not_threaded — real kernels
        (rmsnorm/embed/lm_head_gemv/attention_*) require
        --doppler-transcript for the parity CLI; the canary does not
        yet pass it, so non-fused_gemv real kernels hit
        'parity CLI did not write a receipt'.
      * attention_bodyOp_schema_gap — TSIR semantic schema does not
        yet have an attention bodyOp; D3 must extend
        config/doe-tsir-semantic.schema.json before attention
        fixtures can carry meaningful realizations.
      * msl_spirv_canary_lanes_absent — emit_msl.zig and
        emit_spir_v.zig exist, but no canary fixtures pair them with
        bootstrap inputs. The real-canary expansion past 12 fixtures
        needs MSL + SPIR-V manifest entries for each kernel.
      * numerical_compare_oracle_not_wired — comparisons[].status[1]
        and [2] (numerical compare against reference, cross-backend
        hash agreement) are 'deferred' because the backend execution
        paths return 'not_implemented'. Wiring them requires running
        the WGSL via Doe-WebGPU and the CSL via simfabric for each
        fixture.

Authors the receipt at
bench/out/r3-1-tsir-canary-expansion-preflight/receipt.json with all
four named blockers and the contract for closing each.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_OUT = (
    REPO_ROOT / "bench/out/r3-1-tsir-canary-expansion-preflight/receipt.json"
)


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--out", type=Path, default=DEFAULT_OUT)
    return p.parse_args()


def main() -> int:
    args = parse_args()
    receipt = {
        "schemaVersion": 1,
        "artifactKind": "doe_tsir_canary_expansion_preflight",
        "purpose": (
            "Preflight that records the TSIR canary's current coverage, "
            "the contract for full expansion (kernels + backends + "
            "numerical statuses), and the named blockers that prevent "
            "expansion today."
        ),
        "currentCoverage": {
            "bootstrapCanary": {
                "fixtureDir": "bench/fixtures/tsir-manifest-entries",
                "fixtureCount": 6,
                "kernels": ["fused_gemv", "rms_norm", "gather"],
                "backends": ["webgpu-generic", "wse3"],
                "statuses": {
                    "identity": "pass for 6/6",
                    "numerical_compare": "deferred",
                    "cross_backend_hash": "deferred",
                },
            },
            "realCanarySubset": {
                "fixtureDir": "bench/fixtures/tsir-real-entries-canary-subset",
                "fixtureCount": 4,
                "kernels": ["fused_gemv", "rmsnorm"],
                "backends": ["webgpu-generic", "wse3"],
                "result": (
                    "fused_gemv real × 2 backends pass identity; rmsnorm "
                    "real × 2 backends fail at parity-CLI level — "
                    "blocked on --doppler-transcript wiring."
                ),
            },
            "inputFixturesAuthored": {
                "dir": "bench/fixtures/tsir-bootstrap-inputs",
                "addedThisIteration": [
                    "embed.json",
                    "lm_head_gemv.json",
                    "attention_head256_f16kv.json",
                    "attention_head512_f16kv.json",
                ],
                "_note": (
                    "These input fixtures unblock the canary's FileNotFoundError "
                    "when --inputs-dir is queried for the new kernels. They do "
                    "NOT unblock parity execution — non-fused_gemv real kernels "
                    "still hit 'parity CLI did not write a receipt' until the "
                    "doppler-transcript wiring lands."
                ),
            },
        },
        "expansionContract": {
            "targetFixtureCount": 12,
            "kernels": [
                "fused_gemv",
                "rmsnorm",
                "embed",
                "lm_head_gemv",
                "attention_head256_f16kv",
                "attention_head512_f16kv",
            ],
            "backends": ["webgpu-generic", "wse3"],
            "statusesNeeded": {
                "identity": "pass for all 12",
                "numerical_compare": "non-deferred for all 12",
                "cross_backend_hash": "non-deferred for all 12",
            },
            "fullBackendMatrixContract": {
                "extendedBackends": ["webgpu-generic", "wse3", "msl", "spir-v"],
                "extendedFixtureCount": 24,
            },
        },
        "blockers": [
            {
                "class": "doppler_transcript_arg_not_threaded",
                "detail": (
                    "Real kernels (rmsnorm, embed, lm_head_gemv, "
                    "attention_head256_f16kv, attention_head512_f16kv) "
                    "require --doppler-transcript when invoking "
                    "bench/tools/doe_parity.py because the re-scoped "
                    "TSIR plan uses Doppler's browser WebGPU transcript "
                    "as the reference oracle for real shapes (Step 1 of "
                    "docs/tsir-lowering-plan.md). The canary at "
                    "bench/gates/nightly_tsir_parity_canary.py does not "
                    "thread that argument."
                ),
                "namedExtension": (
                    "bench/gates/nightly_tsir_parity_canary.py: add "
                    "--doppler-transcripts-dir, look up "
                    "<kernel>.doppler-transcript.json beside each "
                    "manifest entry, pass it to the parity CLI when "
                    "present."
                ),
                "blocksKernels": [
                    "rmsnorm",
                    "embed",
                    "lm_head_gemv",
                    "attention_head256_f16kv",
                    "attention_head512_f16kv",
                ],
            },
            {
                "class": "attention_bodyOp_schema_gap",
                "detail": (
                    "config/doe-tsir-semantic.schema.json bodyOp enum "
                    "is currently {unknown, fused_gemv, rms_norm, "
                    "gather}. Attention fixtures pin "
                    "body.op='unknown' as a placeholder. D3 must add "
                    "attention_scores (or a finer-grained variant) "
                    "plus binding/axis roles for Q/K/V/output before "
                    "attention realization can carry meaningful "
                    "semantics."
                ),
                "namedExtension": (
                    "config/doe-tsir-semantic.schema.json: extend "
                    "bodyOp enum, bindingRole enum, and axisRole enum "
                    "with the attention vocabulary captured in "
                    "runtime/zig/tests/tsir/real/attention_head256_f16kv/"
                    "attention_head256_f16kv.notes.md."
                ),
                "blocksKernels": [
                    "attention_head256_f16kv",
                    "attention_head512_f16kv",
                ],
            },
            {
                "class": "msl_spirv_canary_lanes_absent",
                "detail": (
                    "runtime/zig/src/compiler/tsir/emit_msl.zig and "
                    "emit_spir_v.zig exist as TSIR backend emitters. "
                    "No canary fixtures pair them with bootstrap "
                    "inputs; bench/fixtures/tsir-real-entries/ only "
                    "contains *.webgpu-generic.json and *.wse3.json "
                    "entries."
                ),
                "namedExtension": (
                    "bench/fixtures/tsir-real-entries/: add "
                    "<kernel>.msl.json and <kernel>.spir-v.json "
                    "entries for each kernel by running the existing "
                    "TSIR realization pipeline through the MSL and "
                    "SPIR-V emitters."
                ),
                "blocksBackends": ["msl", "spir-v"],
            },
            {
                "class": "numerical_compare_oracle_not_wired",
                "detail": (
                    "doe_parity.run_backend() returns "
                    "'not_implemented' for both webgpu and "
                    "csl-simfabric — the parity receipt's "
                    "comparisons[].status fields for those backends "
                    "are 'deferred' as a result. Status 2 (numerical "
                    "compare against reference) and status 3 "
                    "(cross-backend hash agreement) cannot promote "
                    "until backend execution paths produce real "
                    "output hashes."
                ),
                "namedExtension": (
                    "bench/tools/doe_parity.py:run_backend: replace "
                    "the 'not_implemented' stubs with calls into "
                    "Doe-WebGPU runtime (for webgpu) and simfabric "
                    "runner (for csl-simfabric) that load the input "
                    "fixture, run the kernel, hash the output. Each "
                    "backend invocation is non-trivial — minutes per "
                    "fixture for csl-simfabric."
                ),
                "blocksStatuses": [
                    "numerical_compare",
                    "cross_backend_hash",
                ],
            },
        ],
        "claim": {
            "scope": (
                "TSIR canary expansion contract is bound to in-hand "
                "coverage (6 bootstrap + 4 real-canary subset). The "
                "preflight names every blocker preventing expansion "
                "and records the named extension that closes each."
            ),
            "notWhat": (
                "Not actual canary expansion. Not numerical-status "
                "wiring. The 4 input fixtures authored this iteration "
                "(embed.json, lm_head_gemv.json, "
                "attention_head256_f16kv.json, "
                "attention_head512_f16kv.json) unblock FileNotFoundError "
                "but not the upstream parity-CLI doppler-transcript "
                "requirement."
            ),
            "summary": (
                "Canary at 6+4 fixtures; expansion blocked on 4 named "
                "extensions (doppler-transcript wiring, attention "
                "bodyOp schema, MSL/SPIR-V canary entries, backend "
                "execution wiring)."
            ),
        },
    }

    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(
        json.dumps(receipt, indent=2) + "\n", encoding="utf-8"
    )
    print(f"wrote {args.out} (4 named blockers, 6+4 fixtures in-hand)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
