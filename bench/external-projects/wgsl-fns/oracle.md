# wgsl-fns compilation and semantic oracle

The harness executes the pinned upstream `test/index.test.js` unchanged with
`CI` and `GITHUB_ACTIONS` unset. The only substitution is resolution of the
existing exact `webgpu` package specifier to the requested provider wrapper.

The source workload contains 13 assertions. Four WebGPU assertions generate
compute shaders from the package's complete 110-function corpus: every
function with resolved dependencies, three function combinations, the full
corpus together, and five collision-prone groups. The upstream oracle requires
zero error-severity `getCompilationInfo()` messages. The other nine assertions
check source assembly and dependency ordering.

That upstream oracle is necessary but not sufficient. Some providers can emit
native compiler failures without returning them from `getCompilationInfo()`.
The reviewed harness therefore also requires:

- the test worker and parent process to exit without a signal or timeout;
- exactly 13 passed assertions with no failures, cancellations, or skips; and
- zero native shader-translation or `createShaderModule` failure diagnostics.

Any native compiler failure invalidates the sample even if the upstream test
process reports success. This replacement check does not alter upstream source,
shader strings, corpus membership, dependency resolution, or acceptance rules;
it closes a false-positive channel at the provider API boundary.

The harness also executes one independently reviewed semantic workload without
editing the upstream package. It obtains the exact upstream `smoothStep`
function through `getFns`, embeds that source in a compute shader, and evaluates
these eight exactly representable inputs:

```text
-0.25, 0, 0.125, 0.25, 0.5, 0.75, 1, 1.25
```

The CPU oracle expects:

```text
0, 0, 0.04296875, 0.15625, 0.5, 0.84375, 1, 1
```

The provider must dispatch two workgroups of four invocations, copy the output
to a staging buffer, await queue completion, map the buffer, and return all
eight values exactly. The result binds the upstream function source, generated
shader, input, expected output, actual output, dispatch, synchronization,
readback, provider, and adapter identities by SHA-256 where applicable.

This semantic check proves only the frozen `smoothStep` execution path. The
remaining upstream corpus is still compilation-only, and no performance claim
is admissible unless the incumbent completes equivalent work. Physical-GPU
comparability additionally requires an accessible render node, non-software
adapter, and complete adapter/driver identity.

The P0 control uses the independently prepared `webgpu@0.3.10` package and
Node's explicit no-isolation test mode. That invocation leaves the test file,
shader corpus, semantic dispatch, diagnostics, and output oracle unchanged
while removing the test-worker IPC channel that the native addon intermittently
corrupts. The package receipt, module path, and isolation mode are replay-bound.
