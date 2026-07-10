# CI

## 2026-07-10 - Hosted checks and manual hardware lanes

Push and pull-request status is limited to deterministic GitHub-hosted checks:
agent/workflow contracts, WGSL compiler tests, Lean proof extraction, and the
path-filtered package and native-freshness contracts.

AMD Vulkan, drop-in compatibility, macOS browser refresh, quirk mining,
release gates, and claim-trend workflows remain available through explicit
`workflow_dispatch`. Those lanes require repository-external hardware, vendor
sources, or retained runner state and are not automatic branch status checks.

`bench/tests/test_ci_workflow_surface.py` owns the workflow inventory, trigger
policy, action-major policy, and current repository-layout checks. The Lean
workflow also rejects drift between `config/comparability-obligations.json` and
the checked-in generated Lean contract.

Local verification entrypoints:

- `python3 bench/tests/test_ci_workflow_surface.py`
- `zig build test-wgsl` and `zig build test-wgsl -Dlean-verified=true` from
  `runtime/zig`
- `bash pipeline/lean/extract.sh`
- `python3 pipeline/lean/test_proof_pipeline.py`
- `node --test test/unit/*.test.js` from `packages/doe-gpu`
