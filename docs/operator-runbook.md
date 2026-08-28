# Doe operator runbook

This page routes common operator actions. Normative stage order and failure
precedence live in [`process.md`](process.md); executable `--help`, config, and
schemas own exact options.

## Repository checks

```bash
python3 bench/gates/schema_gate.py
python3 -m unittest bench.tests.test_doc_link_coverage
python3 scripts/check-public-claim-surfaces.py
```

From `runtime/zig/`:

```bash
zig build test
zig build test-wgsl
zig build import-fence
zig build source-layout
zig build line-limits
```

Run platform-dependent checks only on a host that satisfies their declared
preflight. Missing hardware is not a pass.

## Workload and benchmark flow

```bash
python3 bench/cli.py workload --help
python3 bench/cli.py run --help
python3 bench/cli.py compare --help
python3 bench/cli.py claim --help
```

Required order:

1. define the workload and independent oracle;
2. run each provider and retain raw receipts;
3. verify output, work shape, runtime identity, and synchronization;
4. compare equivalent executions;
5. evaluate claim policy;
6. publish only reviewed artifacts.

See [`workload-system.md`](workload-system.md),
[`benchmark-taxonomy.md`](benchmark-taxonomy.md), and
[`performance-strategy.md`](performance-strategy.md).

## Gate orchestration

The canonical orchestration entrypoints are:

```bash
python3 bench/runners/run_blocking_gates.py --help
python3 bench/runners/run_release_pipeline.py --help
```

Read the emitted manifest to confirm which optional and hardware gates actually
ran. An available flag does not mean a release was protected by that gate.

Repository-wide blocking policy remains defined by `config/gates.json`.
Promoted Node/Bun releases need the stronger reliability and performance
contract described in the developer wedge.

## Native package release candidate

After staging the platform package, generate a tuple-specific package candidate
with the packed wrapper and platform tarballs. The command installs with
lifecycle scripts disabled and optional dependencies omitted, runs the shipped
first kernel, generates fresh reliability evidence, and requires governed
primary/replay identity equality before writing the candidate.

```bash
node packages/doe-gpu/test/integration/test-integration-native-clean-install.js \
  --required --release-candidate --runtime node \
  --out reports/benchmarks/<backend>/<run-id>/doe-gpu-node-native-release-candidate.json

node packages/doe-gpu/test/integration/test-integration-native-clean-install.js \
  --required --release-candidate --runtime bun \
  --out reports/benchmarks/<backend>/<run-id>/doe-gpu-bun-native-release-candidate.json

DOE_ELECTRON_EXECUTABLE=/absolute/path/to/electron \
node packages/doe-gpu/test/integration/test-integration-native-clean-install.js \
  --required --release-candidate --runtime electron \
  --out reports/benchmarks/<backend>/<run-id>/doe-gpu-electron-native-release-candidate.json
```

Each command also writes a sibling `.reliability.json` artifact and binds it by
path and SHA-256. Candidate validation uses
`config/doe-gpu-native-release-candidate.schema.json`. A passing tuple does not
grant registry publication, another platform tuple, performance,
runtime-ownership, application-promotion, or browser credit.

## Platform routing

- Apple Metal: run the Metal host preflight, then select a declared Metal
  workload/config and strict no-fallback lane.
- Vulkan: resolve a named host profile, run strict Vulkan preflight, and use a
  workload catalog for that adapter class.
- D3D12: require a Windows host, D3D12-specific Dawn mapping, and fresh output
  evidence.
- Chromium: follow [`../browser/chromium/chromium-bringup.md`](../browser/chromium/chromium-bringup.md)
  and the browser acceptance plan.
- Cerebras: start at [`cerebras.md`](cerebras.md) and use the hardware runbook.

Do not reuse one platform's claim or fallback policy on another platform.

## Traces and failures

- Preserve the original typed cause across process and language boundaries.
- Record provider, backend, adapter, driver, source, command, output, and timing
  identity.
- Keep receipt overhead separate from normal performance measurement.
- Treat missing work, missing output, hidden fallback, or phase asymmetry as a
  failed comparison rather than a slow or fast result.
- Fix producers and gates; do not edit generated artifacts into passing state.

## Publication

Stable reviewed reports belong under `reports/`. Public measured rows enter
`reports/claim-index.json` only after their report and claim sidecar pass.
Package, native, browser, and hardware releases retain separate evidence.

Toolchain upgrades follow [`upgrade-policy.md`](upgrade-policy.md). Current
status and blockers are routed through [`status.md`](status.md).
