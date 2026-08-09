# umap-gpu SGD output oracle

The reviewed admission oracle is the pinned upstream
`src/__tests__/umap-output-gpu.test.ts` suite at commit
`7884b287f49bc057df7e0856c5539f130a20e0ad`. The provider alias changes only
the package resolved for the suite's existing `import('webgpu')` calls. The
test source, both WGSL shaders, inputs, epochs, thresholds, synchronization,
and readback remain unchanged.

The suite must pass all eight upstream assertions:

- every output value is finite;
- the embedding has non-trivial spread;
- the input k-nearest-neighbor graph contains only within-cluster edges;
- every point is closer to its own cluster centroid;
- mean inter-cluster distance exceeds twice mean intra-cluster distance;
- every embedded nearest neighbor has the expected cluster label;
- no edge fires during epoch zero when its next-sample epoch is deferred; and
- edges fire during epoch one in the controlled two-node case.

These are structural correctness and lifecycle checks, not exact floating-point
identity. The suite does not emit the embedding bytes, so reviewed evidence can
record assertion identity but must not claim byte-identical provider outputs.

The upstream `benchmark/index.ts` is not the oracle. It generates different
random inputs for its CPU and GPU rows and does not validate the embedding.
The upstream `umap-gpu-vs-cpu-comparison.test.ts` is useful diagnostic coverage,
but its Spearman threshold did not pass reliably under the incumbent software
renderer on the admission host. Neither surface is used to weaken or replace
the eight-assertion output suite.
