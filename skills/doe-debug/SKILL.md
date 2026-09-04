---
name: doe-debug
description: Diagnose a named Doe ingestion, lowering, HostPlan, backend, package, browser, trace, proof, or comparison failure; implement a repair only when requested.
---

# Doe Debugging

Diagnosis is read-only. Patch the identified owner only when the user's request includes implementation.

## Prerequisites

Supply the failing compiler, runtime, package, browser, proof, or benchmark command;
the expected result; and source, backend, adapter, plan, and receipt identities.

## Procedure

1. Capture the execution surface and equivalent-work evidence below.
2. Trace ingestion, lowering, HostPlan, backend, packaging, and proof boundaries.
3. Report the first mismatch; if repair is requested, patch its owner and rerun the
   focused proof without interpreting incomparable timing results.

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

## Authorized Repair And Proof

When repair is requested, patch the first mismatched owner and add a deterministic regression. Use
structured traces instead of ad-hoc logs. Run the native or package test that
owns the failure, then the original browser or benchmark reproduction.

Treat a very high speed ratio, a zero timing phase on one side, or mismatched
dispatch counts as a harness-integrity failure until equivalent work is proven.

## Validation

The original command produces equivalent work and the expected source identity,
output, trace, or proof on the affected backend.

## Stop Conditions

Stop before interpreting performance when workloads or timing scopes differ.
Stop when the required source revision, backend artifact, or reproduction command
is unavailable.

## Outputs

A boundary diagnosis with workload-equivalence evidence and, for an authorized
repair, the focused regression, trace/proof result, and applicable backend receipt.

## Side Effects

Diagnosis reads artifacts and may execute local backends. Authorized repair may edit
Doe and write build/test artifacts; publishing and deployment are not authorized.
