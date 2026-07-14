---
name: doe-debug
description: Diagnose and fix Doe ingestion, lowering, HostPlan, Zig backend, native addon, npm package, browser, trace, proof, and Dawn-comparison failures. Use when source identity, output parity, backend selection, timing evidence, or claim status is wrong.
---

# Doe Debugging

## Capture The Surface

State whether the failure is in the compiler/runtime, npm package, Chromium
artifact, proof lane, or benchmark harness. Record source hash, plan identity,
backend, adapter, fallback state, trace hash chain, commands, and receipt.

## Trace The Boundary

```text
source -> ingest/normalize -> lowering or HostPlan -> backend selection
       -> encoded work -> execution/readback -> trace -> receipt -> claim gate
```

- Wrong result: source preservation -> lowering -> backend output -> oracle
- Missing backend: capability/profile -> selection -> explicit unsupported error
- Package failure: JS API -> native addon resolution -> staged prebuild -> call
- Browser failure: Fawn/Chromium build -> adapter -> dispatch -> smoke artifact
- Proof failure: obligation -> Lean artifact -> verification mode -> gate
- Benchmark anomaly: workload -> encoded commands -> dispatch/readback telemetry
  -> timing scope -> statistics

## Fix And Prove

Patch the first mismatched owner and add a deterministic regression. Use
structured traces instead of ad-hoc logs. Run the native or package test that
owns the failure, then the original browser or benchmark reproduction.

Treat a very high speed ratio, a zero timing phase on one side, or mismatched
dispatch counts as a harness-integrity failure until equivalent work is proven.
