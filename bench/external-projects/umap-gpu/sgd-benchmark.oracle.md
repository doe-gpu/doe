# UMAP SGD benchmark oracle

The harness executes the pinned upstream `GPUSgd` implementation and its two
unchanged WGSL shaders. It replaces the upstream test's ambient `Math.random`
with the declared deterministic generator in `sgd-benchmark.inputs.json`.

A sample passes only when all output values are finite, the x-axis spread
exceeds the frozen floor, the mean inter-cluster distance exceeds the mean
intra-cluster distance by the frozen ratio, and every point's nearest neighbor
has the same fixture label. Every measured run in one clean process must return
the same 192 output bytes. Provider replay must reproduce that identity.

Timing covers `GPUSgd.init()`, all 500 two-pass epochs, synchronization, mapped
readback, and output materialization. Process startup, Vitest startup, and
provider probing are reported separately and cannot become selected-operation
performance evidence.

Cross-provider byte identity is reported but is not required: a provider may
pass through the semantic oracle when floating-point bytes differ. A runtime
ownership win requires Doe to beat the governed incumbent at both p50 and p95
by the predeclared material margin while preserving the same semantic work.
