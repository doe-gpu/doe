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

The core suite currently wraps the repository Python contracts, rebuilt native
drop-in and Node bridge, Node and Bun package contracts, the exact-byte Metal
oracle, and the Zig runtime contracts. Browser and comparison workloads use the
same envelope but remain separate until their live executor artifacts are
available.

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

Migration is monotonic: an old mechanism remains callable while being wrapped,
but only the registered workload result is authoritative for the migrated
contract.
