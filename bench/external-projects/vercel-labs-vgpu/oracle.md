# vgpu Node ORT oracle

The reviewed oracle is the pinned upstream
`experiments/ort-init-device/node/run.ts` workload at commit
`86f2cadbd7a087f1695d736a12e218ab1ea2fc63`.

The workload verifies the SHA-256 of `identity-1x1x4x4.onnx`, configures ONNX
Runtime Web for the WebGPU execution provider, and requires ORT to return a
GPU-resident output buffer. It then runs the unchanged vgpu WGSL consumer over
that output through two paths:

- `snapshot`: one GPU buffer copy before the consumer dispatch;
- `reference`: a zero-copy wrapper preserving raw `GPUBuffer` identity.

Both paths must return all 16 expected floating-point values within the
upstream `1e-5` tolerance. The upstream evidence must also report every
assertion true, including singleton provider creation, device identity, the
anti-CPU-fallback check, copy counts, raw-buffer identity, queue completion,
and teardown ownership/order. The harness treats only upstream `status: PASS`
with every assertion true as an oracle success.

The provider substitution is limited to resolving the `webgpu` package import.
No upstream application, shader, model, expected value, or lifecycle assertion
is patched.

`repro-onuncapturederror.mjs` is a separate minimized compatibility probe. It
does not replace or modify the upstream oracle; it isolates the standard
`GPUDevice.onuncapturederror` setter used by ONNX Runtime so a provider fix can
be checked before rerunning the complete application.
