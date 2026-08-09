# wgsl-fns compilation-suite oracle

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

This is a compilation and process-stability oracle. It does not dispatch the
compiled functions, read back output values, prove semantic equivalence, or
support performance claims. Physical-GPU comparability additionally requires
an accessible render node, non-software adapter, and complete adapter/driver
identity.
