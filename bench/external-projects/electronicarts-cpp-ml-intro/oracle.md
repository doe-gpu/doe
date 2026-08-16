# cpp-ml-intro MNIST WebGPU oracle

The harness imports the pinned generated `mnist_Module.js` and `Shared.js`
without modifying them. It supplies the two imports left as TODOs by the
generated Node entrypoint: the checked-in `Backprop_Weights.bin` buffer and each
of the ten checked-in 28x28 digit PNGs. The only output-resource adaptation adds
`COPY_SRC` before the generated output buffer is allocated so the ten inference
activations can be read back. Application assets, generated WGSL, graph order,
dispatches, weights, synchronization, and numerical inputs remain unchanged.

The independent CPU oracle checks the graph in two stages. First it decodes each
PNG's red channel, applies the analytic sRGB transfer used by the imported
texture view, and compares that vector with a readback of the generated graph's
`NN_Input` texture. Second it evaluates the fixed 784-30-10 network from the
observed `NN_Input` vector and checked-in weights, using f32-rounded
multiply-accumulate steps, and compares both hidden and output activations.

The input boundary permits at most one half of an 8-bit normalized quantum
(`0.5 / 255`) between the analytic sRGB value and the hardware texture-conversion
result. Once that provider-owned conversion is observed and bounded, the hidden
and output network stages must each remain within `1e-5` of the independent CPU
calculation. This prevents texture-format conversion precision from being
misclassified as a neural-compute error while tightening the compute check by
two orders of magnitude.

A sample passes only when all of the following hold:

- all ten generated GPU executions complete without timeout, signal, validation
  error, or provider-native compiler/resource diagnostic;
- every GPU activation is finite;
- GPU and CPU choose the same maximum-activation neuron for all ten inputs; and
- every 784-value transformed input is within `0.5 / 255` maximum absolute error
  of the analytic sRGB input;
- every 30-value hidden vector is within `1e-5` maximum absolute error of the CPU
  hidden result; and
- every ten-value output vector is within `1e-5` maximum absolute error of the
  CPU output result.

The network tolerances cover implementation-dependent f32 transcendental and
accumulation behavior while the argmax check protects classification semantics.
The filename is recorded as dataset context, not as the equivalence oracle: the
checked-in `5.png` is classified as neuron 6 by both the CPU and Dawn paths.

Each provider runs the complete ten-image workload in three clean processes.
Physical-hardware comparability additionally requires an accessible render node,
a non-software adapter, and complete adapter/driver identity. Process timing on
software rendering or an oracle-failing provider is diagnostic only.

The public DoeProof CLI successor runs the same oracle through `run`, `verify`,
`inspect`, `compare`, and `replay` under Node read-only permissions. Its frozen
qm7 correction preserves compute bindings 16 and 17 required by the unchanged
Presentation pass. Passing that boundary proves declared-file identity, exact
provider selection, output equivalence, and semantic replay; it does not prove
OS dependency closure, performance, runtime ownership, promotion, or release
eligibility. The reviewed result is
[`../../../reports/ecosystem/electronicarts-cpp-ml-intro/cpp-ml-mnist-doeproof-cli-filesystem-amd-vulkan-2026-08-16-diagnostic.json`](../../../reports/ecosystem/electronicarts-cpp-ml-intro/cpp-ml-mnist-doeproof-cli-filesystem-amd-vulkan-2026-08-16-diagnostic.json).

The qm9 clean-install successor runs the same contract from a fresh local
package installation containing the wrapper, Linux x64 platform payload,
pinned incumbent, PNG dependency, and copied exact application. Two independent
installation roots pass both providers and both semantic replays. This proves
the local-tarball Node/Linux x64/AMD Vulkan application boundary, not registry
publication or complete operating-system dependency closure. The reviewed
result is
[`../../../reports/ecosystem/electronicarts-cpp-ml-intro/cpp-ml-mnist-doeproof-cli-clean-install-amd-vulkan-2026-08-16-diagnostic.json`](../../../reports/ecosystem/electronicarts-cpp-ml-intro/cpp-ml-mnist-doeproof-cli-clean-install-amd-vulkan-2026-08-16-diagnostic.json).

The frozen persistent-performance-control screen measures the complete
ten-image operation in 30 cold processes and 100 warm suites per provider.
Every sample must still pass this oracle and reproduce one exact semantic
identity. The result rejects DoeRuntime ownership for this property because
Doe is slower than pinned Dawn at every required cold and warm percentile; it
does not authorize a clean-install performance successor or promotion stress.
The reviewed result is
[`../../../reports/ecosystem/electronicarts-cpp-ml-intro/cpp-ml-mnist-persistent-performance-control-amd-vulkan-2026-08-16-diagnostic.json`](../../../reports/ecosystem/electronicarts-cpp-ml-intro/cpp-ml-mnist-persistent-performance-control-amd-vulkan-2026-08-16-diagnostic.json).
