# Doe process law

This is the normative process contract. Exact commands and platform procedures
live in `docs/operator-runbook.md`, `bench/README.md`, topical runbooks, and
executable `--help`. Checked-in schemas and policy assets remain authoritative
for their fields and values.

## Canonical intent contract

Doe does not add a second free-form run-intent field. Executable intent is the
workload tuple:

```text
immutable inputs + oracle + executor + correctness/claim policy + required evidence
```

An `operationKind` may be derived for routing, but it must not duplicate or
override workload policy. Timing is evidence carried by a workload; it does not
make an unverified workload claim-bearing.

## Stage order

Every promoted change follows this order:

```text
Mine -> Normalize -> Verify -> Bind -> Gate -> Benchmark -> Release
```

1. **Mine** records upstream behavior and immutable provenance.
2. **Normalize** converts mined behavior into strict, versioned Doe contracts.
3. **Verify** proves, guards, or rejects the normalized behavior.
4. **Bind** maps accepted contracts to runtime/compiler implementation points.
5. **Gate** checks schema, correctness, trace, verification, and any
   claim-specific obligations.
6. **Benchmark** measures only workloads that passed the required earlier
   stages.
7. **Release** publishes only evidence-bound artifacts that satisfy the
   declared promotion policy.

A later stage never excuses or overrides an earlier-stage failure. Rejected,
guard-only, diagnostic-only, and incomplete artifacts must remain visibly
classified and cannot be promoted by benchmark results.

## Workload and evidence law

- A workload declares immutable input identity, oracle, executor, policy,
  required artifacts, and evidence extensions.
- Correctness precedes performance interpretation.
- Claim-bearing workloads must emit every evidence extension declared by their
  policy. Missing evidence fails closed.
- Focused module tests are valid executor mechanisms when they provide a
  smaller first-failure boundary or unique oracle sensitivity. Remove one only
  after the workload duplicate-removal gate proves equivalent sensitivity.
- Public claims bind to receipts, source/config identities, execution boundary,
  toolchain identity, and comparability status.
- A claim-bearing external-project report must reference a passing preparation
  receipt that binds the same actor, harness, upstream commit, clean checkout,
  physical support target, toolchain, and Doe/provider artifacts. The release
  gate opens and verifies that receipt; a manifest declaration alone is not
  evidence.

## Gate policy and failure precedence

- Schema, correctness, trace, and required verification gates are blocking.
- Claim runs additionally require comparability coherence, structural
  equivalence, timing/sample policy, claimability, and indexed evidence gates
  selected by the claim contract.
- Advisory performance evidence cannot override a blocking failure.
- Unsupported behavior, stale generated artifacts, missing provenance, unknown
  fields, placeholder semantics, and absent proof metadata fail closed.
- Platform-specific lanes may be skipped only when their checked-in policy
  permits that classification; a skip is never positive evidence.
- The first failing obligation is the primary failure. Later failures may add
  diagnostics but must not conceal it.

## Verification precedence

Use the strongest required mechanism declared by the contract:

1. `lean_required` must have current hash-bound Lean evidence.
2. `lean_preferred` uses current Lean evidence when available and otherwise the
   explicit governed guard/rejection path.
3. `guard_only` retains the runtime guard and its tests.

Proofs may eliminate runtime branches only when the extracted registry binds
the theorem, classification, mirrored runtime symbol, and source hash. A proof
artifact with missing or stale metadata is invalid.

## Compiler completeness

A lowering step emits either a valid typed semantic value or a typed rejection
with source/node location and reason. Semantic placeholders are forbidden.
Artifacts containing rejections are diagnostic-only and cannot enter code
generation, parity promotion, or claim-bearing workloads.

## Refactor law

Behavior-preserving refactors follow this evidence sequence:

```text
capture characterization workload
-> extract neutral contract
-> move implementation
-> preserve an exercised compatibility facade
-> compare semantic digest, trace, oracle, and receipt
-> remove the facade only after consumers migrate
```

If a refactor intentionally tightens or changes a contract, its receipt must
classify that delta separately from preserved cases. Compatibility facades
remain only while an exercised consumer requires them.

## Debug and trace law

- Diagnostics observe execution; they do not silently select different
  semantics.
- Traces use stable operation codes, monotonic ordering, hash chaining, and
  explicit artifact identity.
- Diagnostic and claim-bearing outputs remain partitioned.
- Replay validates metadata and the complete trace chain before interpreting
  results.

## Policy values and generated guidance

- Domain thresholds, ABI values, retry counts, sizes, and timing policy live in
  named constants or versioned config, with one source of truth.
- Generated guides and views are checked against their canonical registries.
- Current commands belong in the operator runbook or generated help, not in
  this process law.
- Toolchain upgrades follow `docs/upgrade-policy.md` and must regenerate and
  revalidate affected provenance-bound artifacts.
