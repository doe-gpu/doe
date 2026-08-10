# Workload system

Doe has no unit-test category. Every check is a correctness-bearing workload.
Workload size does not create a separate category, and timing does not make a
workload claim-bearing.

## Contract

Each workload declares:

- immutable input paths, hashed by the runner;
- an expected outcome and oracle;
- an executor identity and kind: pure, native, browser, or comparison;
- a correctness-only or claim-bearing policy;
- typed evidence extensions required by that policy.

The consolidated ledger keeps only the fields every executor shares:
workload identity, input identity, expected outcome, executor identity,
correctness and first failing boundary, measured timing, policy identity, and
evidence-extension references. Metal state, browser identity, parser
diagnostics, proof metadata, and statistical evidence belong in typed
extensions rather than the core envelope.

Broad repository workloads use `repository-tree` inputs. The runner hashes
tracked and nonignored source bytes, including deleted tracked paths, while
excluding ignored build outputs and dependency caches from source identity.

## Promotion law

Every workload measures elapsed time. Correctness-only policy treats that
timing as diagnostic observation. Claim-bearing policy additionally requires
its declared evidence extensions. A failing oracle prevents claim evidence
from being attached to the result, and a missing required extension fails the
workload at the evidence boundary.

Compilation, process exit, or schema validity can be an oracle only when that
is the declared outcome. A GPU performance workload needs a semantic output
oracle before it can enter claim-bearing comparison and promotion gates.

## Native command-graph oracle migration

Native output-oracle schema version 1 remains the compatibility contract for
one isolated kernel dispatch. It creates a fresh zero-filled execution context,
runs the oracle-owned dispatch count, and captures that dispatch's declared
binding.

Schema version 2 adds `scope=command_graph`. The runtime replays buffer writes
and every preceding dispatch in one context, then captures the declared binding
from the final oracle-bearing dispatch. The scenario-level benchmark IR field
is materialized only onto the final expanded dispatch, so nested repeat
structure remains source-owned rather than duplicated.

Version 2 also requires an explicit `reference_class`. An
`independent_v1` reference can satisfy strict claim admission.
`cross_runtime_consensus_v1` records exact provider parity and is useful
structural evidence, but it cannot satisfy the independent semantic-oracle
obligation. Migration is additive: version 1 inputs retain their original
isolated behavior and do not gain a new required field.

## Package adapter identity migration

Run-receipt schema version 1 now permits additive `vendorID`, `deviceID`, and
`driverVersion` fields under `hostIdentity.adapter`. Package traces carry the
same fields in `adapterInfo`. Vulkan records the native packed driver version;
comparison normalizes that value to its semantic version before checking an
incumbent provider's textual driver description.

Older receipts remain schema-readable and use zero for absent numeric identity
fields. That compatibility does not make them claimable: strict Vulkan package
comparison requires one matching nonzero vendor/device identity and driver
version on both providers. This migration closes the previous path where a
generic adapter label could pass hardware-path comparability.

## Executors

Executors are adapters beneath the workload law:

| Kind | Job |
| --- | --- |
| `pure` | Deterministic transforms, schemas, hashing, and rejection paths |
| `native` | Runtime, compiler, and device-backed execution |
| `browser` | Fawn or Chromium execution with browser and device evidence |
| `comparison` | Matched multi-product execution and structural equivalence |

`zig test`, Python processes, native Metal, browser lanes, and Doe-versus-Dawn
are execution mechanisms. Their raw output is not an independent source of
truth; the workload ledger records the verdict and binds the detailed output
through extensions. Process executors preserve the actual return code and
stdout/stderr as typed extensions so a failed oracle remains diagnosable.
`process-json` oracles also validate stdout against a declared schema and
expected semantic status before attaching the structured result.

## Current front door

The suite contract is
[`config/doe-workload-suite.json`](../config/doe-workload-suite.json). Run the
full registered slice or one workload with:

```sh
python3 bench/cli.py workload
python3 bench/cli.py workload --workload-id zig_runtime_contracts
```

The runner emits one `doe-workload-ledger` plus extension files. Existing
focused checks remain in place while their invocation moves behind registered
workloads. Existing run, compare, and claim receipts become typed extensions
for claim-bearing workloads; they are not replaced or weakened.

The core suite wraps the repository Python contracts, rebuilt native drop-in
and Node bridge, Node and Bun package contracts, exact-output Metal transfer
and compute oracles, matched package upload/readback and browser-render
oracles, and the Zig runtime contracts. Browser identity and device evidence
remain typed process-JSON evidence rather than fields in the core ledger.

## Correctness-bearing benchmark pilots

The staged Metal buffer-write slice no longer has a separate exact-byte test.
Its benchmark executes repeated production writes, records write, flush,
capture, and wall timing, and compares every captured byte. A second registered
workload deliberately corrupts the device buffer and passes only when the same
oracle rejects the result. Timing remains diagnostic under correctness-only
policy; performance promotion still requires a declared claim-bearing policy.

The native Metal compute slice follows the same law. It repeatedly writes an
input buffer, dispatches the production kernel, compares the complete output
against its CPU oracle, and records each execution phase. Its corruption
workload proves that a dispatch receipt with altered output cannot pass.

The package upload/readback slice executes one plan through Doe and the
Dawn-backed Node provider. Each side reads the complete uploaded buffer and
must match the plan-owned SHA-256 oracle; agreement between providers is not
sufficient. The active catalog row supersedes the earlier partial-capture row,
whose plan remains available only for replaying historical receipts. A paired
corruption workload changes the expected digest and passes only when both
providers reject it.

The browser render slice executes one manifest row through stock Chromium with
Dawn and Fawn with Doe. The projection manifest owns the render dimensions,
viewport/scissor rectangle, inside and outside colors, row layout, and expected
SHA-256. Each runtime must match every RGBA8 byte and prove the selected runtime
identity. Its paired corruption workload changes only the expected digest and
passes only when both runtimes reject the otherwise identical GPU result.
Timing is recorded but remains correctness-only evidence.

Strict comparison still separates correctness from performance promotion. A
row becomes diagnostic when selected operation timing and workload-unit wall
disagree on the direction of any required claim percentile. The faster scope
cannot hide a loss in the other scope.

## Duplicate-test removal gate

A standalone test body can be removed after its registered workload executes
the same production path, preserves the assertion in a structured oracle,
proves oracle sensitivity with a deliberate invalid outcome, and passes in the
consolidated ledger. Keep any focused test that still owns a unique property,
rejection path, or smaller first-failure boundary. Migration removes duplicate
assertions; it does not trade coverage for timing.

## Migration order

1. Register existing deterministic and Zig checks without changing their
   assertions.
2. Add semantic output oracles to GPU timing workloads that currently prove
   only submission or duration.
3. Register native and browser execution through their existing front doors.
4. Register Doe-versus-incumbent comparisons as claim-bearing workloads whose
   extensions contain matched receipts, structural-equivalence results, and
   claim decisions.
5. Make repository and release gates consume the consolidated ledger for the
   workloads they own.

Migration is monotonic: an old mechanism remains callable while being wrapped.
After the duplicate-test removal gate passes, the workload becomes the only
authoritative implementation of that contract.
