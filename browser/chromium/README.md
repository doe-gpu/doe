# Chromium browser integration layer (nursery)

## Purpose

`browser/chromium` is the repo-local browser integration layer for
Chromium work. It contains the docs, contracts, helper scripts, and diagnostic
harnesses that drive a Chromium checkout/build lane.

It is not the Chromium checkout/build workspace itself. In this repo, that
workspace is `browser/chromium_webgpu_lane/` when kept in-tree, or the
path selected by `FAWN_CHROMIUM_LANE_DIR` for external-volume setups.

This integration layer is used for:

1. The strategic challenger path to replace Dawn behind `navigator.gpu` in
   Chromium-family browsers.
2. Planning, contracts, and diagnostics for Chromium-facing Doe bring-up.

This layer is intentionally process-heavy and contract-first. It exists to
prevent architectural drift and comparability debt before implementation.

## Relationship to the dominance program

This lane is the Chromium-facing proof surface for Doe's larger objective:
surpass the Chromium WebGPU incumbent stack where Chromium is the browser
surface, Dawn is the runtime incumbent, and Tint is the shader compiler
incumbent.

The lane does not replace the independent native runtime strategy. It binds the
native Doe runtime into Chromium's `navigator.gpu` seam and proves that the
browser can run through Doe while preserving Chromium's process model, sandbox,
API behavior, and fallback governance.

The three governing requirements are:

1. Preserve program identity.
   Browser shaders and workloads must link back to source hashes, compiler
   receipts, backend artifacts, command graphs, and runtime traces.
2. Keep the native runtime path independent.
   The browser lane consumes `doe-zig-runtime` / `libwebgpu_doe`; it does not
   redefine Doe as a Chromium-only fork.
3. Make every claim receipt-backed.
   A browser-lane dominance claim requires forced-Doe evidence, hidden-fallback
   checks, Dawn fallback identity, compiler evidence against Tint where shader
   compilation is involved, and browser artifacts that pass the relevant gates.

The public proof target is a downloadable Chromium-family browser build with
Doe active in the WebGPU path. The release archive must have a public HTTPS
download URL, and the gallery pages must have hosted HTTPS URLs on
non-special-use hosts. The minimum
credible artifact is governed by
[`contracts/browser-published-release.contract.md`](contracts/browser-published-release.contract.md):
download the browser, run a WebGPU workload, inspect the source-preserving Doe
execution receipt, and compare it against Dawn. Package installs and
`doe-gpu/browser` compatibility wrappers do not satisfy that browser-runtime
claim.

## Scope

In scope:

1. Integration architecture, contracts, and rollout policy.
2. Test/gate/benchmark plans for Chromium-facing work.
3. Forced-Doe browser diagnostics, runtime identity, fallback taxonomy, and
   WebGPU workload evidence.
4. Archived optional internal module designs (`2D SDF`, `path`, `effects`,
   `compute services`, `resource scheduler`).

Out of scope:

1. Direct edits to core runtime execution in `runtime/zig/src`.
2. Redefining Doe stage order or existing gate precedence.
3. Claims of browser-wide replacement semantics before browser-lane artifacts
   pass the required gates.
4. Broad Chromium fork divergence outside WebGPU runtime integration.

## Isolation contract

This directory is isolated from core runtime development by policy:

1. No production runtime behavior is enabled from files under `browser/`.
2. No hidden feature toggles are introduced in core runtime through this layer.
3. Any future implementation promoted from this layer must:
   - move to core module directories (`runtime/zig/`, `bench/`, `config/`, etc.),
   - land with schema and migration updates,
   - pass blocking gates defined in `docs/process.md`.
4. Nothing in this layer bypasses stage discipline:
   - Mine -> Normalize -> Verify -> Bind -> Gate -> Benchmark -> Release.

Milestone status source of truth:

1. `bench/workflows/browser-milestones.json`
2. checked by `scripts/check-browser-milestones.py`
3. plan/notes describe intent and evidence, but milestone state changes should be recorded in the manifest

## Context summary

Doe already has an ABI-focused drop-in lane and compatibility gates that make Chromium experimentation realistic:

1. Drop-in artifact:
   - `runtime/zig/zig-out/lib/libwebgpu_doe_full.{so,dylib,dll}`
2. Symbol contract and gate support:
   - `config/dropin_abi.symbols.txt`
   - `bench/drop-in/dropin_symbol_gate.py`
   - `bench/drop-in/dropin_behavior_suite.py`
   - `bench/drop-in/dropin_benchmark_suite.py`
   - `bench/drop-in/dropin_gate.py`
3. Existing pipeline/trace/replay and claimability policy:
   - `pipeline/trace/replay.py`, `bench/gates/trace_gate.py`, `bench/gates/claim_gate.py`

This layer extends those capabilities to Chromium integration planning without
coupling directly to core runtime code yet.

Browser-facing WebGPU API contracts (for example `GPUCanvasContext`,
`GPUExternalTexture`, and external texture imports/copy paths) are implemented
in the lane Chromium source checkout:

- `browser/chromium_webgpu_lane/src/third_party/blink/renderer/modules/webgpu/`

The `browser/chromium` directory remains planner/gate/probe ownership and does
not own Blink API surface files directly.

Terminology used in this directory:

1. "browser integration layer"
   - `browser/chromium/`
2. "Chromium checkout/build lane"
   - `browser/chromium_webgpu_lane/` or an externally mounted lane selected by
     `FAWN_CHROMIUM_LANE_DIR`

## Program shape

Track A (browser): strategic Dawn replacement path for `navigator.gpu` via Doe.

Track B (modules) was archived 2026-03-19. See "Track B" section below.

## Track A (browser): Dawn replacement lane

### Objective

Prove that Doe can own the WebGPU runtime implementation seam while keeping
browser behavior and process topology stable.

### Design constraints

1. Keep Chromium process model unchanged:
   - renderer behavior unchanged,
   - GPU process boundaries unchanged,
   - sandbox model unchanged.
2. Keep Dawn available as first-class fallback at every stage.
3. Use explicit runtime selection flagging and kill switches.
4. Preserve deterministic artifacts for all quality decisions.
5. Disable hidden fallback in claim mode so forced-Doe evidence is real.

### Integration principle

Only replace the WebGPU runtime seam. Do not fuse this work with unrelated compositor/layout/media refactors.

### Promotion gates

Before moving beyond experiment flags:

1. ABI/symbol completeness gate passes.
2. API behavior parity gate passes.
3. Replay and deterministic trace parity checks pass.
4. Crash/hang rate parity with fallback lane is established.
5. Performance claimability gates pass for any "faster" statement.

## Track B (modules) — archived

**Archived 2026-03-19.** Track B proposed five optional Chromium-internal
modules (`fawn_2d_sdf_renderer`, `fawn_path_engine`, `fawn_effects_pipeline`,
`fawn_compute_services`, `fawn_resource_scheduler`) that would use WebGPU
through Doe for internal browser GPU work.

This was superseded once it became clear that Chromium is already routing
Skia Graphite, WebGL, and compositor through WebGPU on its own timeline.
If Track A ever lands and Doe replaces Dawn, those subsystems automatically
run on Doe without any Doe-side plumbing. Building parallel
replacements duplicates work Google has 100+ GPU engineers doing and creates
fork divergence on every Chromium update.

The correct strategy: let browser vendors build the roads to WebGPU, build the
fastest engine at the destination.

Artifacts (contracts, schemas, policies, Zig implementations) are preserved but
inactive. Milestone governance (M4-M6) is demoted to `archived` in
`bench/workflows/browser-milestones.json`. Module ownership is marked archived
in `config/module-ownership.json`.

## What WebGPU/Doe can and cannot replace

Can replace or absorb:

1. Many explicit GPU draw/compute operations.
2. Significant portions of raster/effects work where command contracts are stable.
3. Internal GPU utility workloads with deterministic contracts.

Cannot replace by itself:

1. HTML/CSS layout semantics and accessibility logic.
2. Browser orchestration and process/security policy.
3. OS-level presentation and protected path ownership.
4. Hardware decoder control APIs.

## Contract-first policy for this layer

Every proposed feature in this layer must define:

1. Input contract:
   - schema-backed request shape.
2. Output contract:
   - result artifacts and traceability fields.
3. Failure contract:
   - explicit unsupported/error taxonomy.
4. Methodology contract:
   - timing source, normalization divisors, comparability mode.
5. Fallback contract:
   - deterministic fallback path and trigger reasons.

No implicit behavior switching is allowed.

## Config and schema expectations

Future implementation promoted from this layer must use config-as-code:

1. Config files in `config/*.json`.
2. Schema files in `config/*schema*.json`.
3. Status tracking updates in `docs/status.md` for runtime-visible changes,
   temporary placeholders, or staged methods.

## Gate policy alignment

This layer inherits Doe v0 gate priorities:

1. Blocking:
   - schema,
   - correctness,
   - trace.
2. Advisory (v0 global policy):
   - verification,
   - performance.
3. Additional blocking when applicable:
   - drop-in compatibility for artifact lanes,
   - release claimability when promotion requires claim statements.

## Reliability and claimability expectations

No performance claim can be promoted without:

1. strict comparability compliance,
2. operation-scope timing consistency,
3. minimum timed sample floors,
4. positive percentile tails (`p50`, `p95`; `p99` for release claims),
5. zero execution errors in selected claim workloads.

Directional runs must be labeled non-claimable.

## Observability contract

All promoted experiments must emit:

1. run metadata (`run-metadata.schema.json`),
2. row-level trace (`trace.schema.json`),
3. run-level trace summary (`trace-meta.schema.json`),
4. reproducible artifact hashes for replay and audit.

Traceability fields must include module identity and hash chain continuity.

## Risk controls

Primary risks:

1. Hidden fallback behavior under incompatible adapters.
2. Timing-scope mismatches generating false win claims.
3. ABI drift from Chromium/Dawn evolution.
4. Excessive platform divergence from driver-specific quirks.

Mitigations:

1. explicit unsupported taxonomy and fail-fast checks,
2. strict comparability mode by default for claim lanes,
3. symbol and behavior drop-in gates in CI,
4. upstream quirk mining and deterministic normalization.

## Directory structure

Current browser integration layer structure:

1. `README.md`
   - scope, policy, and contracts overview.
2. `plan.md`
   - milestone plan, exit criteria, dependencies.
3. `chromium-bringup.md`
   - practical local bring-up path and early integration sequence.
4. `contracts/`
   - runtime selector contract and optional module contract drafts.
   - see `contracts/README.md` for index.
5. `notes/`
  - findings, experiment logs, touchpoint mapping, and promotion decisions.
6. `scripts/`
   - lane-local helpers (`scripts/bootstrap-host-tools.sh`, `scripts/env.sh`,
     `scripts/preflight.sh`, `scripts/bringup-linux.sh`,
     `scripts/run-smoke.sh`, `scripts/run-bench.sh`,
     `scripts/build-browser-gpu-scheduler.py`,
     `scripts/build-browser-webgpu-effect-experiment.py`,
     `scripts/build-browser-local-ai-workloads.py`,
     `scripts/build-browser-fallback-explanations.py`,
     `scripts/build-browser-cts-subset.py`,
     `scripts/refresh-doe-app.sh`,
     `scripts/check-browser-milestones.py`).
7. `assets/`
   - brand assets, logo source, and compiled macOS/Linux logo artifacts.

## Logo asset layout

See `assets/logo/README.md` for the literal current asset filenames and rebuild
command used by the lane scripts.

Any script/code added here must be non-production and must not alter core runtime behavior by default.

## Decision rules for promotion out of nursery

A design exits nursery only when all are true:

1. Problem statement and success metric are explicit.
2. Contract schema and migration impact are specified.
3. Gate implications are mapped (blocking/advisory).
4. Rollback and fallback behavior are explicit.
5. Ownership and maintenance burden are assigned.

If one is missing, keep the item in nursery.

## Ownership model

Recommended ownership split:

1. Runtime seam and ABI parity:
   - runtime integration owner(s).
2. Trace/replay and correctness gate policy:
   - quality owner(s).
3. Performance/claimability policy:
   - benchmark methodology owner(s).
4. Optional module incubation:
   - module-specific owners.

Cross-owner signoff is required before any promotion from nursery to core paths.

## How to use this folder

1. Read this file and `plan.md` before proposing Chromium integration changes.
2. Add or update module proposals as contract documents first.
3. Tie every proposal to gates and measurable exit criteria.
4. Promote to core directories only after passing promotion rules.

## Quick start (browser lane + external drive)

Lane setup for both macOS and Linux:

1. Choose the platform flow and run setup:
   - macOS: `./scripts/setup-macos-external-lane.sh /Volumes/chromium-lane`
   - Linux: `./scripts/setup-linux-external-lane.sh /mnt/chromium-lane`
2. Load lane env: `source ./scripts/env.sh`
3. Build Chromium on Linux with release output:
   - `./scripts/bringup-linux.sh --mode release --skip-fetch --skip-sync`
   - or for fresh pull: `./scripts/bringup-linux.sh --mode release`
4. Build/rebuild external release artifacts:
   - `./scripts/build-release-external.sh`
   - on macOS this also reapplies the Doe app wrapper to the built bundle
5. Run browser checks with lane defaults:
   - `./scripts/run-smoke.sh --mode both`
   - `./scripts/run-bench.sh --mode both`
   - selector diagnostic mode:
     `./scripts/run-bench.sh --mode auto`
   - runtime-selector policy:
     `python3 browser/chromium/scripts/check-browser-runtime-selector-policy.py --policy config/browser-runtime-selector-policy.json`
   - responsibility-map gate:
     `python3 bench/tools/check_browser_responsibility_map.py --map config/browser-responsibility-map.json`
   - optional canvas/WebGPU fusion:
     `./scripts/run-smoke.sh --mode doe --canvas-webgpu-fusion-out browser/chromium/artifacts/canvas-webgpu-fusion.json --canvas-webgpu-fusion-mode doe`
   - optional media-path probe:
     `./scripts/run-smoke.sh --mode doe --media-path-probe-out browser/chromium/artifacts/media-path-probe.json --media-path-probe-mode doe`
   - optional recovery parity:
     `./scripts/run-smoke.sh --mode both --recovery-parity-out browser/chromium/artifacts/recovery-parity.json`
   - optional CTS subset projection:
     `./scripts/run-smoke.sh --mode both --cts-subset-out browser/chromium/artifacts/browser-cts-subset.json`
   - optional flight recorder plus shader links:
     `./scripts/run-smoke.sh --mode both --flight-recorder-components examples/browser-gpu-flight-recorder.sample.json --flight-recorder-out browser/chromium/artifacts/browser-gpu-flight-recorder.json --shader-links-out browser/chromium/artifacts/browser-shader-links.json`
   - browser claim promotion receipt:
     `python3 bench/browser/browser_claim_gate.py --promotion-receipt-out bench/out/browser-claim/browser-claim-promotion-receipt.json`
   - release package input preflight:
     `python3 bench/tools/check_browser_release_package_inputs.py --package-dir <chromium-out-or-Fawn.app> --package-root-name <Fawn-Doe-platform-arch-or-Fawn.app> --doe-runtime <libwebgpu_doe> --dawn-fallback-runtime <libdawn_native> --shader-compiler runtime/zig/zig-out/bin/doe-zig-runtime --product-version <version> --product-channel <diagnostic|release_candidate> --platform-os <macos|linux> --platform-arch <arm64|x64> --out <browser-release-package-inputs.json>`
   - release archive zip and manifest:
     package-input-driven lane:
     `python3 browser/chromium/scripts/package-browser-release-archive.py --package-inputs <browser-release-package-inputs.json> --package-inputs-root <artifact-root> --out <Fawn-Doe-platform-arch.zip> --manifest-out <Fawn-Doe-platform-arch.manifest.json>`
     The package-input-driven manifest includes `sourcePackageInputs`, binding the exact packageability preflight that supplied product/platform identity, runtime inputs, and packaged member paths.
     macOS release-candidate lane:
     `python3 browser/chromium/scripts/package-browser-release-archive.py --package-dir <Fawn.app> --out <Fawn-Doe-macos-arm64.zip> --manifest-out <Fawn-Doe-macos-arm64.manifest.json> --doe-runtime <libwebgpu_doe> --dawn-fallback-runtime <libdawn_native> --product-version <version> --product-channel release_candidate --platform-os macos --platform-arch arm64`
     Linux diagnostic lane:
     `python3 browser/chromium/scripts/package-browser-release-archive.py --package-dir <chromium-out-dir> --package-root-name <Fawn-Doe-linux-x64> --out <Fawn-Doe-linux-x64.zip> --manifest-out <Fawn-Doe-linux-x64.manifest.json> --doe-runtime <libwebgpu_doe.so> --dawn-fallback-runtime <libdawn_native.so> --product-version <version> --product-channel diagnostic --platform-os linux --platform-arch x64`
   - lower-level release bundle assembly must pass `--package-inputs <browser-release-package-inputs.json>` for release candidates alongside `--release-archive <browser-release.zip>` and `--release-archive-manifest <browser-release.manifest.json>` so product/platform identity, packaged member paths, and browser/runtime/compiler artifact paths come from the packageability preflight; the emitted bundle hash-binds that preflight as `packageInputs`, duplicate explicit paths must match it, and the archive manifest's `sourcePackageInputs` must bind the same report.
   - public archive download receipt:
     `python3 bench/tools/build_browser_public_download_receipt.py --url <https-browser-archive-url> --receipt-id <receipt-id> --release-archive <Fawn-Doe-macos-arm64.zip> --release-archive-manifest <Fawn-Doe-macos-arm64.manifest.json> --product-version <version> --product-channel release_candidate --platform-os macos --platform-arch arm64 --browser-executable-archive-path Fawn.app/Contents/MacOS/Chromium --browser-app-metadata-archive-path Fawn.app/Contents/Info.plist --doe-runtime-archive-path Fawn.app/Contents/Frameworks/libwebgpu_doe.so --dawn-fallback-runtime-archive-path Fawn.app/Contents/Frameworks/libdawn_native.so --out <browser-public-download-receipt.json>`
   - public gallery receipts:
     `python3 bench/tools/build_browser_public_gallery_receipt.py --url <https-gallery-page-url> --receipt-id <receipt-id> --category <compute|rendering|tensor|shader_edge|benchmark_trace> --gallery-artifact <gallery-page.html> --workload-contract-path <browser-gallery-contract.md> --receipt-payload <browser-execution-receipt.json> --out <browser-public-gallery-receipt.json>`
   - per-run browser execution receipts:
     `python3 bench/tools/build_browser_execution_receipt.py --smoke-report <browser-smoke-report.json> --mode <dawn|doe> --receipt-id <receipt-id> --workload-id <workload-id> --source-shader <shader.wgsl> --command-count <count> --success-count <count> --dispatch-count <count> --output-hash <sha256> --setup-ns <ns> --encode-ns <ns> --submit-wait-ns <ns> --out <browser-execution-receipt.json>`
   - proof page diagnostic receipt:
     `python3 bench/tools/build_browser_proof_page_receipt.py --receipt-id <receipt-id> --url about:doe --proof-artifact <captured-about-doe.html> --runtime-identity-path <browser-runtime-identity.json> --active-backend webgpu-doe --compiler-path runtime/zig/zig-out/bin/doe-zig-runtime --tsir-status <status> --host-plan-status <status> --csl-status <status> --release-archive <browser-release.zip> --release-archive-url <https-browser-archive-url> --release-archive-manifest <browser-release.manifest.json> --public-download-receipt <browser-public-download-receipt.json> --product-version <version> --product-channel release_candidate --platform-os macos --platform-arch arm64 --browser-executable-archive-path Fawn.app/Contents/MacOS/Chromium --browser-app-metadata-archive-path Fawn.app/Contents/Info.plist --doe-runtime-archive-path Fawn.app/Contents/Frameworks/libwebgpu_doe.so --dawn-fallback-runtime-archive-path Fawn.app/Contents/Frameworks/libdawn_native.so --recent-receipt-id <dawn-receipt-id> --recent-receipt-id <doe-receipt-id> --out <browser-proof-page-receipt.json>`
   - published proof surface:
     `python3 bench/tools/build_browser_published_proof_surface.py --surface-id <surface-id> --capture-policy-path config/browser-capture-policy.json --runtime-identity-path <browser-runtime-identity.json> --proof-page-artifact <captured-about-doe.html> --proof-page-receipt <browser-proof-page-receipt.json> --proof-receipt-payload <dawn-execution-receipt.json> --proof-receipt-payload <doe-execution-receipt.json> --gallery-entry <gallery-entry.json> --comparison-entry <comparison-entry.json> --out <browser-published-proof-surface.json>`
   - published proof surface check:
     `python3 bench/tools/check_browser_published_proof_surface.py --surface <browser-published-proof-surface.json> --verify-files-root <artifact-root> --require-public-urls --out <browser-published-proof-surface-check.json>`
   - packaged browser launch receipt:
     `python3 bench/tools/build_browser_release_launch_receipt.py --receipt-id <receipt-id> --release-archive <browser-release.zip> --release-archive-url <https-browser-archive-url> --release-archive-manifest <browser-release.manifest.json> --proof-surface <browser-published-proof-surface.json> --product-version <version> --product-channel release_candidate --platform-os macos --platform-arch arm64 --browser-executable-archive-path Fawn.app/Contents/MacOS/Chromium --browser-app-metadata-archive-path Fawn.app/Contents/Info.plist --doe-runtime-archive-path Fawn.app/Contents/Frameworks/libwebgpu_doe.so --dawn-fallback-runtime-archive-path Fawn.app/Contents/Frameworks/libdawn_native.so --active-backend webgpu-doe --proof-page-artifact-path <captured-about-doe.html> --proof-page-receipt-id <proof-page-receipt-id> --gallery-url <https-gallery-page-url> --gallery-category compute --gallery-artifact-path <gallery-page.html> --gallery-receipt-id <gallery-receipt-id> --comparison-id <comparison-id> --comparison-workload-id <workload-id> --comparison-page-artifact-path <gallery-page.html> --comparison-artifact-path <browser-smoke-report.json> --comparison-dawn-receipt-id <dawn-receipt-id> --comparison-doe-receipt-id <doe-receipt-id> --observed-receipt-id <proof-page-receipt-id> --observed-receipt-id <gallery-receipt-id> --observed-receipt-id <dawn-receipt-id> --observed-receipt-id <doe-receipt-id> --out <browser-release-launch-receipt.json>`
   - post-download local provenance staging:
     `python3 bench/tools/stage_browser_release_candidate_provenance.py --surface-template <previous-proof-surface.json> --release-archive <browser-release.zip> --release-archive-url <https-browser-archive-url> --release-archive-manifest <browser-release.manifest.json> --public-download-receipt <browser-public-download-receipt.json> --proof-page-artifact <captured-about-doe.html> --proof-page-receipt-id <proof-page-receipt-id> --browser-launch-receipt-id <launch-receipt-id> --package-inputs <browser-release-package-inputs.json> --tsir-status <status> --host-plan-status <status> --csl-status <status> --proof-page-receipt-out <browser-proof-page-receipt.json> --proof-surface-out <browser-published-proof-surface.json> --proof-surface-check-out <browser-published-proof-surface-check.json> --browser-launch-receipt-out <browser-release-launch-receipt.json> --provenance-report-out <browser-release-candidate-provenance.json> --verify-files-root <artifact-root>`
     The staging helper requires `--package-inputs` and derives the proof-page compiler path from the package-input shader compiler unless an explicit duplicate path matches it.
   - release-candidate provenance preflight:
     `python3 bench/tools/check_browser_release_candidate_provenance.py --release-archive <browser-release.zip> --release-archive-url <https-browser-archive-url> --release-archive-manifest <browser-release.manifest.json> --public-download-receipt <browser-public-download-receipt.json> --proof-surface <browser-published-proof-surface.json> --proof-surface-check <browser-published-proof-surface-check.json> --browser-launch-receipt <browser-release-launch-receipt.json> --package-inputs <browser-release-package-inputs.json> --verify-files-root <artifact-root> --out <browser-release-candidate-provenance.json>`
     This preflight requires the archive manifest's `sourcePackageInputs` to
     match the same package-input receipt.
   - release-candidate finalizer:
     `python3 bench/tools/finalize_browser_release_candidate_bundle.py --bundle-id <bundle-id> --provenance-report <browser-release-candidate-provenance.json> --release-archive <browser-release.zip> --release-archive-url <https-browser-archive-url> --release-archive-manifest <browser-release.manifest.json> --public-download-receipt <browser-public-download-receipt.json> --proof-surface <browser-published-proof-surface.json> --proof-surface-check <browser-published-proof-surface-check.json> --browser-launch-receipt <browser-release-launch-receipt.json> --chromium-source-checkout <chromium-source-checkout-check.json> --runtime-identity <browser-runtime-identity.json> --runtime-frontier-bundle-out <browser-runtime-frontier-bundle.json> --package-inputs <browser-release-package-inputs.json> --claim-report <browser-claim-report.json> --promotion-receipt <browser-claim-promotion-receipt.json> --verify-files-root <artifact-root> --out <browser-release-artifact-bundle.json> --report-out <browser-release-candidate-finalizer.json>`
   - release-candidate finalizer check:
     `python3 bench/tools/check_browser_release_candidate_finalizer.py --report <browser-release-candidate-finalizer.json> --verify-files-root <artifact-root> --require-pass --out <browser-release-candidate-finalizer-check.json>`
     Passing finalizer reports must bind `inputs.packageInputs`, and the check
     verifies that receipt against the emitted release bundle. The checker
     receipt also binds the checked finalizer report path/hash so readiness
     evidence cannot pair a stale check with a different finalizer report;
     release-candidate readiness requires the receipt to show both
     `verifyFilesRootProvided=true` and `requirePass=true`.
   - `build_browser_release_artifact_bundle.py --bootstrap-runtime-frontier`
     remains the lower-level assembler; release-candidate promotion should use
     the finalizer after the provenance report passes.
   - release-candidate channel/provenance must be rebuilt through the archive
     manifest, public download receipt, proof-page receipt, published proof
     surface, and launch receipt; diagnostic-channel artifacts are expected to
     fail candidate verification instead of being relabeled.
6. If only Doe runtime code changed on macOS:
   - `./scripts/refresh-doe-app.sh`
   - rebuilds `libwebgpu_doe_full.dylib` and reapplies the app-bundle Doe wrapper

Notes:
- Lane-local env file is `.external-lane.env` (mac helper also writes legacy `.external-macos.env` for compatibility).
- External checkout/caches are stored at:
  - `<external_volume>/chromium/{src,depot_tools,cache}`
- Local release sync remains in `browser/chromium/out/fawn_release_local`
  (literal current folder name used by the lane scripts).

## Current status

This lane contains planning/contracts docs, lane-local bring-up scripts, and a lane-local Chromium workspace (`src/`) with in-flight Track A (browser) seam integration edits.

No core `zig` production runtime behavior is introduced by this directory by default.
