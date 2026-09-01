# doe-status-dashboard

Single-page static demo that binds to Doe's artifact schemas and renders the
current state of WGSL → multi-backend compile + CSL runtime readiness.
The first table also renders the generated, hash-bound qualification decision
for Gemma 3 270M under Electron on the admitted AMD Vulkan tuple.

## View

Serve from the repo root (the page fetches artifacts from `../../bench/out/`):

```bash
cd /path/to/doe
python3 -m http.server 8000
```

Then open <http://localhost:8000/demos/doe-status-dashboard/>.

Generate the Gemma qualification bundle from its machine-owned plan and
evidence before serving the page:

```bash
python3 bench/tools/generate_gemma270m_qualification_status.py
```

## What it binds to

Each row is re-derived from a JSON artifact at view time. No labels are
hardcoded; "Aspirational" rows in particular lift their `executionStatus` and
`executionBlocker` text verbatim from the receipt so the dashboard and the
artifact cannot drift.

| row | source |
| --- | --- |
| Gemma 270M Electron qualification | `bench/out/qualification/gemma270m-amd/status-bundle.json`, generated from `config/gemma270m-qualification-dashboard-plan.json` |
| WGSL → multi-backend compile | `bench/out/cross-backend-matrix/wgsl-backend-matrix.json` |
| WGSL backend equivalence crosswalk | `bench/out/wgsl-backend-equivalence/index.json` |
| SdkLayout streaming executor primitives | `bench/out/e2b-full-graph/gemma-4-e2b-runtime-receipt.json` → `streamingExecutorPrimitivesEvidence` |
| Full-grid cslc feasibility | `bench/out/cslc-grid-probe/grid-probe-aggregate.json` |
| E2B / 31B structural readiness | `bench/out/e2b-full-graph/*-runtime-receipt.json`, `bench/out/31b-full-graph/*-runtime-receipt.json` |
| CSL full execution (simulator) | `executionStatus` + `executionBlocker` from each model receipt |
| CSL hardware execution | gated on the simulator blocker clearing; dashboard shows the blocker chain |

## What it does not do

This is a static page. It doesn't re-run any gate, regenerate any artifact,
or validate against schemas at view time — it trusts that the sweep has
already done that. Schema validation lives in `bench/gates/schema_gate.py`.
The page does not infer or hardcode the Gemma gate statuses; it displays the
six generated gate records and their hash-bound evidence links.

## Intentional distinction

The `bench/out/streaming-executor/` traces prove stream primitives run on
simfabric (stream I/O, compute transform, region-to-region chain, multi-PE
SPMD, compile cache, 4-stage layer-block chain). The generated E2B
layer-block smoke runner now also records a non-stub simulator trace for
pre-attn RMSNorm, scalar attention-inner-product with residual, and
post-attn RMSNorm, plus a gated MLP stage with bit-exact ReLU standing
in for GELU. The E2B receipt still carries
`executionStatus=not_attempted` because full multi-head attention over
KV cache and a shared polynomial GELU replacement are not wired into the
layer-block runner yet.
The dashboard renders these as separate rows so "partial layer-block
simulator proof: pass" doesn't get conflated with "full-model CSL
execution: blocked".

The schema's `executionBlocker` enum was widened with
`full_transformer_layer_block_incomplete` to name this gap precisely; the
legacy `sdk_layout_streaming_executor_missing` and
`streaming_executor_not_bound_to_execution_plan` values remain in the enum
for backward compatibility but are no longer emitted by
`build_model_runtime_receipt.py`.
