# Doe performance contract

This page defines measurement and comparison mechanics only. Performance's
place in the product priority order and downstream-application strategy lives
only in [`thesis.md`](thesis.md).

## Purpose

Performance is part of the promoted Node/Bun product contract. A speed claim is
eligible only after correctness, structural equivalence, runtime identity, and
failure checks pass.

`config/gates.json` classifies performance as advisory repository-wide. Each
promoted developer-wedge workload must additionally declare a blocking
performance decision in its promotion contract.

## Measurement order

1. Validate both outputs with an independent oracle.
2. Prove both sides executed the same declared work.
3. Verify provider, backend, adapter, driver, cache, and fallback identity.
4. Verify timing-scope symmetry.
5. Measure the complete user-visible operation.
6. Evaluate latency, memory, failures, retries, and fallbacks together.
7. Emit compare and claim artifacts.

Failure at an earlier step makes timing diagnostic.

## User-visible operations

Promoted Node/Bun evidence should include cold and warm forms of:

- inference prefill and decode;
- embeddings and vector operations;
- upload through readback;
- shader and pipeline creation;
- prepared pipeline reuse;
- process and device memory.

Internal phase timing remains useful for diagnosis. It cannot rescue an
end-to-end loss.

## Comparability requirements

Both products must use the same:

- workload inputs and output contract;
- command and dispatch shape;
- cache and preparation state;
- upload, completion, and readback semantics;
- hardware and driver environment;
- timing class and normalization;
- sample and warmup policy.

Skipped work, zero-dispatch asymmetry, missing timing phases, different
readback paths, or hardware-specific shortcuts make a row diagnostic unless
the workload explicitly declares the asymmetry and forbids generalization.

## Statistical requirements

- Report p50, p95, and p99 for release claims.
- Use enough independent samples for the declared tail percentile and disclose
  the estimator and variance.
- Set a practical winning margin larger than observed benchmark noise.
- Repeat evidence across independent process runs.
- Treat unusually large speedups as fairness-audit triggers.

The sample floors and reliability policy belong in
`config/benchmark-methodology-thresholds.json`, not prose. A configured floor
that cannot support its declared percentile must fail methodology review.

## Claim artifacts

Every promoted result must retain:

- raw run artifacts for both products;
- comparison and claim sidecars;
- workload and config hashes;
- output-oracle result;
- runtime and hardware identity;
- timing-scope and structural-equivalence verdicts;
- memory and failure summaries;
- fallback and retry state.

Public prose should link `reports/claim-index.json`, not transcribe percentages.

## Optimization loop

1. Reproduce one named end-to-end loss.
2. Attribute it with phase receipts and profiles.
3. Change one runtime or compiler contract.
4. rerun correctness and reliability gates;
5. rerun the matched comparison;
6. retain the change only when the user-visible result and tails remain valid.

Dated investigations belong in status archives, not this contract.
