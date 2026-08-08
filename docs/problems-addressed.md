# Problems Doe must solve

This document defines user problems and the evidence required to say Doe solves
them. It does not claim that every requirement is already satisfied.

## Incorrect or incomplete execution

GPU work can crash, hang, silently no-op, reorder operations, return corrupt
bytes, or report success before completion.

Doe's promoted surface must require independent output oracles, complete command
counts, explicit completion, corruption tests, and typed failures. A missing
receipt or output check is a coverage gap, not a pass.

## Runtime opacity

Applications often cannot explain which provider, adapter, driver, fallback,
cache, synchronization, or readback path produced a result.

Doe must expose those choices as structured runtime identity and receipt fields.
Best-effort behavior may exist only when the contract declares it and records
the original failure cause.

## Application incompatibility

API-shaped unit tests do not prove that real projects work.

Doe must maintain a versioned downstream suite of Node, Bun, and applicable
Electron projects. Private patches beyond a documented provider substitution
must be disclosed.

## Misleading performance

An internal dispatch win can disappear after upload, compilation, queue wait,
readback, startup, or memory pressure.

Doe must measure named user operations end to end, keep cold and warm paths
separate, validate output before timing promotion, and report p50, p95, p99,
memory, retries, failures, and fallbacks together.

## Installation friction

A native runtime that requires a local compiler or undocumented environment
setup is not a package adoption path.

Every promoted tuple needs a clean-install test for the wrapper, native binary,
runtime ABI, and first real kernel. Unsupported tuples must produce an
actionable error.

## Regression diagnosis

Driver, compiler, cache, and scheduling changes can alter results or latency
without an obvious application diff.

Doe's traces and receipts must bind source, runtime, adapter, driver, workload,
output, and timing identity so a regression can be replayed and compared.

## Cross-target identity

Backend-specific implementations can drift into unrelated programs.

Doe's compiler contract preserves semantic and realization identity across
WGSL, TSIR, HostPlan, backend emitters, and execution receipts. Target-specific
optimization is allowed; undeclared semantic divergence is not.

## Evidence rule

Current capability and performance statements must link
[`reports/claim-index.json`](../reports/claim-index.json), the support matrix,
or an explicit diagnostic artifact. Intended behavior belongs in contracts;
measured state belongs in artifacts.
