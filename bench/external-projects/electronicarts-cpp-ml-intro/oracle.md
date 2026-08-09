# cpp-ml-intro MNIST WebGPU oracle

The harness imports the pinned generated `mnist_Module.js` and `Shared.js`
without modifying them. It supplies the two imports left as TODOs by the
generated Node entrypoint: the checked-in `Backprop_Weights.bin` buffer and each
of the ten checked-in 28x28 digit PNGs. The only output-resource adaptation adds
`COPY_SRC` before the generated output buffer is allocated so the ten inference
activations can be read back. Application assets, generated WGSL, graph order,
dispatches, weights, synchronization, and numerical inputs remain unchanged.

The independent CPU oracle implements the same fixed 784-30-10 network directly
from the checked-in weights. It decodes each PNG's red channel, applies the sRGB
transfer used by the generated texture view, evaluates both sigmoid layers with
f32-rounded multiply-accumulate steps, and produces ten activation values.

A sample passes only when all of the following hold:

- all ten generated GPU executions complete without timeout, signal, validation
  error, or provider-native compiler/resource diagnostic;
- every GPU activation is finite;
- GPU and CPU choose the same maximum-activation neuron for all ten inputs; and
- every ten-value output vector is within `0.0025` maximum absolute error of the
  CPU result.

The tolerance covers implementation-dependent f32 transcendental and
accumulation behavior while the argmax check protects classification semantics.
The filename is recorded as dataset context, not as the equivalence oracle: the
checked-in `5.png` is classified as neuron 6 by both the CPU and Dawn paths.

Each provider runs the complete ten-image workload in three clean processes.
Physical-hardware comparability additionally requires an accessible render node,
a non-software adapter, and complete adapter/driver identity. Process timing on
software rendering or an oracle-failing provider is diagnostic only.
