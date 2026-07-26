# CI

## 2026-07-25 - Scheduled Dawn/Tint intelligence

`nightly-quirk-mining.yml` now has a schedule in addition to manual dispatch.
It restores versioned SQLite state, validates the intelligence and config
contracts, requires a model credential, synchronizes exhaustive Gerrit pages
and referenced Chromium issues, emits review packets, runs the checked-out
source miner without swallowed failures, and uploads both artifact families.
Issue and model work are policy-bounded and resume from cached durable queues;
backlog is distinguished from an operational failure in each receipt.
The model output is triage-only; promotion remains a separate receipt and
workload-gated change.

## 2026-07-10 - Hosted checks and manual hardware lanes

Push and pull-request status is limited to deterministic GitHub-hosted checks:
agent/workflow contracts, WGSL compiler tests, Lean proof extraction, and the
path-filtered package and native-freshness contracts.

AMD Vulkan, drop-in compatibility, macOS browser refresh, release gates, and
claim-trend workflows remain available through explicit `workflow_dispatch`.
The quirk and upstream-intelligence lane is scheduled but is not a required
push/pull-request status check.

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
