# Contracts Index

This directory contains contract drafts for the Chromium WebGPU lane.

These files define candidate module boundaries and promotion expectations before implementation.

Archived Track B module filenames retain their historical `fawn-*` identifiers
because the archived schemas and fixtures still use those ids.

## Files

1. `runtime-selector-and-fallback.contract.md`
   - Track A runtime selection, kill switch, denylist, and fallback contract.
2. `fawn-2d-sdf-renderer.contract.md`
   - Track B 2D SDF/MSDF renderer module contract.
3. `fawn-path-engine.contract.md`
   - Track B path processing and fallback contract.
4. `fawn-effects-pipeline.contract.md`
   - Track B effects graph contract.
5. `fawn-compute-services.contract.md`
   - Track B internal compute services contract.
6. `fawn-resource-scheduler.contract.md`
   - Track B resource and submit-cadence scheduler contract.
7. `module-contract-matrix.md`
   - Cross-module input/output schema fields, required gates, and rollout KPIs.
8. `browser-benchmark-superset.contract.md`
   - Layered browser benchmark superset contract (`L0`/`L1`/`L2`) and projection/gate rules.
   - includes hash-synchronization, status-code taxonomy, cadence, and promotion-approval policy.
9. `browser-claim-methodology.contract.md`
   - Forced-runtime browser claim methodology and required runtime-selection
     artifact fields.
10. `browser-responsibility-map.contract.md`
   - CPU/GPU browser responsibility map contract and claim-candidate binding
     rules.
11. `browser-gpu-flight-recorder.contract.md`
   - Page-level GPU capture artifact contract for shaders, IR, backend output,
     command graphs, frame hashes, timings, and typed failures.
12. `browser-canvas-webgpu-fusion.contract.md`
   - Canvas 2D, WebGPU, image-filter, and presentation graph-sharing probe
     contract.
13. `browser-shader-links.contract.md`
   - Developer-visible source-to-IR-to-backend shader provenance contract.
14. `browser-gpu-scheduler.contract.md`
   - Page-level GPU scheduler probe contract for WebGPU, canvas, video, CSS
     effects, local AI, and compositor-adjacent work.
15. `browser-webgpu-effect-experiment.contract.md`
   - WebGPU-backed browser visual effect experiment contract that keeps
     layout, accessibility, and security semantics browser-owned.
16. `browser-local-ai-workloads.contract.md`
   - Browser local AI workload and receipt contract for embeddings, ranking,
     image/video transforms, and model inference.
17. `browser-pipeline-cache-receipts.contract.md`
   - Developer-visible cache hit/miss and pipeline creation receipt contract.
18. `browser-fallback-explanations.contract.md`
   - Developer-visible unsupported-capability and fallback explanation
     contract.
19. `browser-media-path-probe.contract.md`
   - External texture, external image copy, and shared texture/import probe
     contract.
20. `browser-recovery-parity.contract.md`
   - Dawn-vs-Doe crash, hang, device-loss, validation-error, and recovery
     parity contract.
21. `browser-cts-subset.contract.md`
   - Browser CTS subset contract for paired Dawn and forced-Doe evidence.
22. `browser-published-release.contract.md`
   - Published Chromium-family browser release contract for downloadable
     Doe/Fawn browser artifacts, per-run receipts, Dawn-vs-Doe comparison mode,
     hosted proof gallery with public comparison links, and local diagnostics
     page requirements.
23. `../bench/workflows/browser-milestones.json`
   - schema-backed M0-M6 status manifest for current nursery state and local evidence.

## Contract Rules

1. Every contract must define:
   - input shape,
   - output artifacts,
   - failure taxonomy,
   - fallback policy,
   - gate coverage,
   - promotion criteria.
2. Any runtime-visible field promoted from these drafts must gain:
   - schema entries under `config/*schema*.json`,
   - status/process updates when behavior changes.
3. No draft in this directory may silently alter core runtime behavior.

## Draft Status

All contracts here are `draft` and non-binding until promoted through Doe stage and gate policy.
