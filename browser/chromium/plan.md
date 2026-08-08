# Chromium integration acceptance plan

This file defines milestone acceptance. Tasks live in
[`../../docs/chromium-webgpu-task-list.md`](../../docs/chromium-webgpu-task-list.md)
and state lives in [`bench/workflows/browser-milestones.json`](bench/workflows/browser-milestones.json).

## Scope

- Integrate Doe at Chromium's WebGPU implementation seam.
- Preserve browser-owned process, sandbox, API, media, and security behavior.
- Keep fallback explicit and disable it in forced-Doe evidence.
- Bind source, runtime, browser, output, and receipt identity.

## Milestones

### M0: contracts

- Runtime selector, fallback, benchmark, claim, responsibility, and release
  contracts exist with schemas and checkers.
- The milestone manifest names required artifacts and checks.

### M1: forced runtime

- Chromium launches in declared `dawn`, `doe`, and governed `auto` modes.
- Forced Doe fails closed.
- Runtime identity and fallback state appear in artifacts.

### M2: correctness and reliability

- Dawn and forced Doe run the same browser workload set.
- Independent output oracles, CTS coverage, crash, hang, recovery, device-loss,
  concurrency, and memory checks pass for the promoted platform.
- Trace and replay identity is complete.

### M3: end-to-end performance

- Both runtimes execute equivalent application work.
- Cold and warm user-visible operations report p50, p95, p99, memory, failures,
  retries, and fallback state.
- A practical winning threshold larger than noise is release-blocking for any
  promoted speed claim.

### M4: published release

- A public HTTPS archive binds the browser, Doe runtime, Dawn fallback, and
  compiler bytes.
- Download, proof-page, gallery, comparison, launch, finalizer, and candidate
  receipts all pass their contracts.
- Installation and launch instructions work on the declared clean system.

## Promotion rule

Milestones are cumulative. Missing M2 evidence cannot be offset by M3 timing,
and local M3 evidence cannot substitute for M4 distribution proof.

Until M4 passes for a declared platform, the browser lane remains diagnostic.

## Archived work

Track B internal-module proposals are retired. Historical contracts may remain
for reference, but they are not active milestones or product surfaces.
