# Frozen candidate search jobs

`prepare.py` reconstructs the single-query binary inputs and independent
float64 expectations. `prepare-batched.py` uses those inputs for a separate
batch of queries and reuses the original CPU routine. Run them in that order;
their printed hashes identify the generated job manifests. Binary inputs are
generated and retained in each execution artifact, rather than committed here.

Pin the job hash before changing candidate WGSL. Regenerating a descriptor or
reference after an edit changes the acceptance identity; it cannot authorize
the edited candidate under the original hash. The single-query and batched
jobs have different useful operations and must retain separate conclusions.

The fixtures exercise zero, signed, structured, and mixed-scale finite inputs.
Python's independently summed float64 expectations and the JavaScript CPU
reference remain separate from WGSL. These repository search routines are
diagnostic examples, not third-party application adoption or incumbent GPU
comparisons. Commands and evidence semantics are in
[`reusable-compute-programs.md`](../../../docs/reusable-compute-programs.md#bounded-candidate-jobs).
