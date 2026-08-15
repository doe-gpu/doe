# Chromium integration layer

`browser/chromium/` owns Doe's repository-local Chromium integration contracts,
scripts, milestone checks, and diagnostic artifacts. It is not the Chromium
checkout itself and it does not change the public `doe-gpu/browser` contract.

Fawn is Doe's first-class browser product target. Success means a released
Chromium-family archive runs an unchanged WebGPU application through forced
Doe with an independent oracle, physical hardware identity, reliable
lifecycle behavior, and a narrow compatibility or performance benefit. It
does not mean a general browser benchmark win.

## Boundaries

- The external Chromium checkout/build workspace is selected separately by the
  lane tooling.
- Core native runtime behavior belongs under `runtime/zig/`.
- Browser schemas and shared policy belong under `config/`.
- Browser execution and release results belong in lane artifacts.
- Package evidence cannot promote this lane.

Doe changes only the WebGPU implementation seam. Chromium's process model,
sandbox, renderer, layout, media, accessibility, origin, and security policy
remain browser-owned.

## Source of truth

- Tasks: [`../../docs/chromium-webgpu-task-list.md`](../../docs/chromium-webgpu-task-list.md)
- Acceptance: [`plan.md`](plan.md)
- Milestones: [`bench/workflows/browser-milestones.json`](bench/workflows/browser-milestones.json)
- Contracts: [`contracts/`](contracts/)
- Live status:
  [`../../docs/status/runtime-backends-and-bench.md`](../../docs/status/runtime-backends-and-bench.md)

Do not add a parallel task list, strategy, or artifact inventory to this file.

## Directory map

| Path | Responsibility |
| --- | --- |
| `contracts/` | Formal runtime, benchmark, receipt, and release obligations |
| `scripts/` | Lane builders, checkers, and launch helpers |
| `bench/` | Browser workload and milestone configuration |
| `artifacts/` | Checked-in diagnostics and governed browser evidence |
| `src/` | Optional external checkout link or workspace, not Doe-owned source |

## Operating rules

- Forced Doe mode must fail closed.
- Governed fallback must be explicit and typed.
- Every result must identify the browser binary and selected runtime.
- Diagnostic rows must remain separate from claimable rows.
- A public claim requires the published-browser contract, not a local smoke
  test or package wrapper.
- A release-candidate launch receipt must bind the isolated clean-install
  verifier; declared launch facts are insufficient.
- Contract changes require matching schema, checker, and fixture updates.

## Verification

Use the scripts and commands named by the milestone manifest and acceptance
plan. The manifest owns which checks are required for each milestone; this
README intentionally does not copy the changing command inventory.

## Current boundary

The lane has forced-runtime contracts, diagnostics, a governed Linux package
policy, and an isolated archive verifier. The retained compact archive fails
that verifier because it is not an installable Chromium package. The lane does
not yet establish an unchanged-application release gate, broad browser
compatibility, a promoted release, or a general performance claim.

Archived Track B module designs remain historical references only. New work
must attach to the canonical task list and milestone manifest.
