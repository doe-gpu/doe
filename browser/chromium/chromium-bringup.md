# Chromium bring-up

This runbook covers checkout and build setup only. Browser tasks, acceptance,
and milestone state live elsewhere.

## Sources of truth

- Tasks: [`../../docs/chromium-webgpu-task-list.md`](../../docs/chromium-webgpu-task-list.md)
- Acceptance: [`plan.md`](plan.md)
- Milestones: [`bench/workflows/browser-milestones.json`](bench/workflows/browser-milestones.json)
- Integration boundary: [`README.md`](README.md)

## Workspace layout

Keep Doe-owned contracts and scripts in `browser/chromium/`. Keep the Chromium
checkout, `depot_tools`, caches, and build output in the configured external
lane or ignored checkout path. Large upstream build trees do not belong in git.

## Bootstrap

```bash
cd browser/chromium
./scripts/bootstrap-host-tools.sh
source ./scripts/env.sh
```

Set up an external lane when needed:

```bash
./scripts/setup-macos-external-lane.sh /Volumes/chromium-lane
# or
./scripts/setup-linux-external-lane.sh /mnt/chromium-lane
```

Then use Chromium's normal `fetch`, `gclient`, `gn`, and `autoninja` workflow
inside the selected checkout. Exact build arguments belong in lane scripts and
the generated build receipt, not this document.

## Doe integration checks

Before interpreting browser output:

```bash
python3 browser/chromium/scripts/check-browser-milestones.py
python3 bench/tools/check_chromium_source_checkout.py \
  --source-root browser/chromium/src --root . --json
```

Use `scripts/run-smoke.sh` and `scripts/run-bench.sh` for execution. Forced Doe
must prove selected-runtime identity and fail closed when the runtime cannot be
loaded. Launch arguments alone are not runtime evidence.

## Release artifacts

Use the checked-in packaging, proof-surface, launch, and finalizer tools named
by the published-browser contract. A local app bundle or smoke report is
diagnostic until the complete release contract passes.

## Refresh and sync

- `scripts/build-release-external.sh`: rebuild the configured release lane
- `scripts/sync-release-artifacts-local.sh`: copy declared release outputs
- `scripts/refresh-doe-app.sh`: refresh the Doe runtime in a local macOS app

Current selector state, source markers, artifact hashes, and test results belong
in milestone and execution receipts. Do not add dated snapshots here.
