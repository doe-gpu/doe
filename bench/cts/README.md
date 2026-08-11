# CTS provider tooling

`cts/` contains Doe's repo-only WebGPU CTS provider shims.

Current entrypoints:

- `cts/fawn-node-gpu-provider.js`
- `cts/fawn-node-gpu-provider.cjs`
- `cts/probe-fawn-node-adapter.cjs`

These files are internal operator tooling, not public package contracts. The
main consumer today is the CTS subset runner documented in
[`bench/README.md`](../bench/README.md).

Ownership and usage:

- treat `cts/` as an internal conformance surface
- keep provider filenames stable when benchmark/config surfaces reference them
- bind retained CTS runs to the provider's materialized adapter identity probe
- add new CTS-facing helpers here only when they are part of repo workflows
