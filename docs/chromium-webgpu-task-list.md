# Chromium WebGPU task list

This file contains open implementation and proof obligations only. Strategy
lives in [`thesis.md`](thesis.md), acceptance gates live in
[`../browser/chromium/plan.md`](../browser/chromium/plan.md), and current state
lives in the browser milestone manifest and status shards.

## Compiler obligations

- Run Doe and Tint over the same versioned WGSL corpus.
- Preserve source, IR, backend-output, validator, and compiler identity.
- Close semantic, diagnostic, robustness, and backend-emission gaps exposed by
  real browser and downstream-project shaders.
- Publish only phase comparisons with equivalent boundaries and enough samples.
- Link CTS shader evidence to the same source/output identity chain.

## Native runtime obligations

- Require independent output oracles for promoted compute and render rows.
- Match upload, command, submit, completion, and readback work against Dawn.
- Cover crash, hang, device loss, recovery, concurrency, teardown, and memory.
- Preserve typed errors through C, Zig, browser, and JavaScript boundaries.
- Keep cache, synchronization, fallback, and hardware shortcuts explicit.
- Produce backend-specific Metal, Vulkan, and D3D12 evidence before broadening
  platform claims.

## Chromium seam obligations

- Maintain explicit `dawn`, `doe`, and governed `auto` selection.
- Make forced `doe` fail closed when Doe cannot initialize.
- Record browser executable, Doe runtime, Dawn fallback, compiler, adapter,
  driver, selector, and fallback identity in every promoted artifact.
- Preserve Chromium process, sandbox, renderer, media, accessibility, and
  security boundaries outside the WebGPU implementation seam.
- Validate canvas, presentation, external texture, media, worker, recovery,
  and device-loss behavior under forced Doe.
- Run browser CTS and application workloads under both forced runtimes.

## Published-browser obligations

- Produce a downloadable, hash-bound Chromium-family archive.
- Bind the browser binary, Doe runtime, Dawn fallback, and compiler artifacts.
- Publish a successful HTTPS download receipt.
- Provide a proof page that exposes active runtime, fallback state, and recent
  receipt links.
- Provide hosted application pages and same-workload Dawn/Doe comparison
  receipts.
- Pass the published-release, proof-surface, launch, finalizer, and
  release-candidate contracts under `browser/chromium/contracts/`.

Until these obligations pass, browser evidence remains diagnostic.

## Current blockers

- Broad browser compatibility and CTS evidence are incomplete.
- Browser release artifacts do not yet establish a promoted cross-platform
  runtime.
- Package and native runtime wins do not transfer to the browser lane.
- Reliability and end-to-end application performance need repeated supported
  hardware coverage.

## Machine-owned ledgers

- Milestones: `browser/chromium/bench/workflows/browser-milestones.json`
- Runtime selection: `config/browser-runtime-selector-policy.json`
- Responsibility map: `config/browser-responsibility-map.json`
- Capture policy: `config/browser-capture-policy.json`
- Unsupported reasons: `config/browser-unsupported-reason-taxonomy.json`
- Claim methodology:
  `browser/chromium/contracts/browser-claim-methodology.contract.md`
- Published release:
  `browser/chromium/contracts/browser-published-release.contract.md`

Add a task here only when it changes what must be built or proven. Add state to
the milestone manifest and measured results to artifacts.
