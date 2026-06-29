# bench/native-compare

Compare configurations for native Doe-vs-Dawn benchmarking. Each
`compare.config.<platform>.<backend>[.variant].json` declares the two
sides of a compare (baseline + comparison), workload set, comparability
mode, and timing-class requirements.

Use via the CLI:

```
python3 bench/cli.py run-config \
  --config bench/native-compare/compare.config.apple.metal.compare.json \
  --side baseline
python3 bench/cli.py run-config \
  --config bench/native-compare/compare.config.apple.metal.compare.json \
  --side comparison
```

Lanes covered: `apple-metal`, `amd-vulkan`, `local-d3d12` (native
backend); ORT WebGPU EP under Node and Bun (`compare.config.{node,bun}.
ort-webgpu-provider.*.json`). Promoted-vs-explicit status is summarised
in the first-benchmark matrix in [`bench/README.md`](../README.md).

Helper Python (`compare_*.py`) here is shared between the CLI and the
release pipeline; runtime executors live in
[`bench/executors/`](../executors/), and apples-to-apples enforcement lives in
[`bench/lib/comparability_coherence.py`](../lib/comparability_coherence.py).

`wgpu_benchmark_adapter.py` is a real-runner adapter only. It fails closed when
`--wgpu-runner` is absent and never emits synthetic timing or trace artifacts.
