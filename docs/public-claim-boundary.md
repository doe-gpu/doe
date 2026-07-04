# Public claim boundary

This document defines how Doe turns evidence into public wording.

## Source of truth

Public README claim rows come from:

- `reports/claim-index.json`
- `assets/readme/backend-evidence-summary.svg`
- the report and claim artifacts referenced by the claim index

Historical reports, local scratch outputs, archived status notes, and old chart
assets are engineering evidence only until they are represented in the current
claim index or explicitly labeled diagnostic/status-only.

## Required public row fields

Every README-facing evidence row must state:

- `backend`
- `surface`
- `comparison`
- `metricDirection`
- `claimState`
- `comparisonStatus` when measured evidence exists
- `claimStatus` when measured evidence exists
- `reportPath` when measured evidence exists
- `claimPath` when the row is claim-indexed
- `browserRelease` when `surface=browser-chromium`

Allowed `claimState` values:

- `claim-indexed`: public claim row backed by current report and claim metadata
- `diagnostic`: useful engineering evidence, not public speed wording
- `status-only`: support/capability status without a promoted performance row
- `scaffolded`: contract or implementation exists, but fresh evidence is absent

## Claim language rules

- A claim-indexed row may say what the artifact proves, including backend,
  surface, workload, metric direction, and comparison target.
- A Dawn replacement frontier row may only be promoted as a broad row when its
  platform/backend evidence slices are claimable. Public wording for partial
  replacement evidence must name the exact operating system, architecture, GPU
  API, GPU vendor, and runtime host proven by the slice.
- A diagnostic row may describe what was measured, but must not become "Doe is
  faster" product language.
- A status-only row may describe support status or blocker state, not benchmark
  performance.
- A scaffolded row may describe the intended lane and missing evidence.
- A Chromium browser row must bind its release evidence through
  `browserRelease`. Claim-indexed Chromium browser rows require the runtime
  frontier, release bundle, release archive path/SHA-256, release archive
  manifest path/SHA-256, public download URL, package inputs, provenance,
  public download, proof surface, launch, finalizer, finalizer check, and
  readiness report artifacts to be release-candidate and claimable where
  applicable. Package-input and provenance preflight reports must be clean:
  no blockers, no failures, and zero failure summary counts where exposed.
  Provenance `componentArtifacts` must bind the exact package-input, public
  download, proof-surface, proof-surface-check, and launch receipt paths and
  bytes named by `browserRelease`. The release archive manifest, package
  inputs, provenance, public download, proof-surface release provenance, and
  launch receipts must bind the same browser product, platform, and packaged
  member paths as the release artifact bundle. Package-input browser
  binary/Doe runtime/Dawn fallback runtime/shader compiler refs and
  archive-manifest member hashes must bind the same release bundle artifacts;
  manifest `sourcePackageInputs` refs must match the release bundle when
  present. The release archive download URL must be public HTTPS; reserved,
  local,
  single-label, credentialed, or non-HTTPS hosts do not count as claim-indexed
  browser release evidence. Its public download receipt must be a successful GET
  observation with non-empty receipt identity/observation time, HTTP 200 status,
  and served byte length matching the release archive bytes.
  Claimable runtime frontier evidence must carry no `claimBlockers`,
  `claimBlockerSummary`, `failures`, or nonzero summary counts, and its
  component summaries must bind the same proof-surface Doe runtime identity,
  promotable release-bundle promotion receipt, and release-candidate artifact
  bundle path/verified-file state named by the browser release evidence.
- A claim-indexed Chromium browser proof-surface checker report must pass with
  no failures, file verification, and public URL enforcement, and its
  `surfacePath` and `surfaceSha256` must bind to the exact proof surface named by
  `browserRelease.proofSurfacePath`.
- A claim-indexed Chromium browser finalizer report must pass with no failures
  and `summary.failureCount=0`. Its `outputs.releaseArtifactBundle` and
  `outputs.runtimeFrontierBundle` must bind the exact release bundle/runtime
  frontier paths and bytes named by `browserRelease`, and
  `inputs.packageInputs` must bind the exact package-input receipt.
- A claim-indexed Chromium browser finalizer-check receipt must pass with
  `finalizerStatus=pass`, file verification, `requirePass=true`, and no
  failures, and must bind `finalizerReportPath`/`finalizerReportSha256` to the
  exact finalizer report named by `browserRelease.finalizerReportPath`.
- A claim-indexed Chromium browser launch receipt must prove a packaged Doe
  WebGPU launch, bind `proofSurface.path`/`proofSurface.sha256`/
  `proofSurface.kind` to the exact published proof surface named by
  `browserRelease.proofSurfacePath`, load the `about:doe` proof page, load a
  public HTTPS gallery page, load same-page Dawn/Doe comparison mode, emit
  side-by-side Dawn/Doe receipts, and observe proof/gallery/Dawn/Doe receipt
  IDs. The launch receipt must match the loaded proof surface's proof page,
  gallery page, comparison row, receipt IDs, and active backend. Its proof and
  gallery receipt IDs must match the receipt IDs loaded from the proof
  surface's diagnostic and public-gallery receipt payloads.
- A claim-indexed Chromium browser proof surface must expose `about:doe` Doe
  diagnostics, compiler path, TSIR/HostPlan/CSL status,
  hidden-fallback-disabled state, recent execution receipt coverage for
  proof-page payloads, gallery receipts, and comparison receipts, with no
  unbacked recent receipt IDs, public hosted gallery pages for
  compute/rendering/tensor/shader-edge/benchmark-trace categories, no
  unrecognized gallery categories, and same-page Dawn/Doe comparison parity.
  The diagnostics `compilerPath` must match the release bundle
  `shaderCompiler.path`, and the loaded `runtimeIdentityPath` artifact's
  provider or runtime-selection hashes must match the release bundle browser
  binary, Doe runtime, and Dawn fallback runtime hashes.
- The same-page comparison runner gallery artifact must visibly show the
  comparison ID, workload ID, runner page/scope/modes, side-by-side receipt
  emission, comparison artifact path, and both Dawn/Doe receipt IDs and payload
  links.
- The same-page `comparisonArtifact` must be loaded and hash-matched, must be
  a strict browser smoke report with valid report-hash and mode-result
  hash-chain evidence, must cover both runtimes with timing class and mode
  results matching the runner/policy, must bind runtime-selection hashes to the
  release bundle browser binary, Dawn fallback runtime, and Doe runtime
  artifacts, and both Dawn and Doe execution receipt command evidence must name
  that comparison artifact path and hash-bind either the comparison artifact
  file or report hash.
- A claim-indexed Chromium browser proof surface must load unambiguous,
  hash-matched execution receipt artifacts that expose receipt ID, workload ID,
  WGSL source shader text/hash aliases/entry point, lowering path bound to
  selected runtime, backend identity matching selected runtime, driver/device
  identity, command-graph or flight-recorder SHA evidence, exactly one output
  or frame SHA-256, complete command coverage, clean no-hidden-fallback runtime
  selector/fallback state, and numeric setup/encode/submit-wait timing phases.
  Loaded Dawn/Doe comparison
  receipt payloads must match the comparison workload ID plus source
  text/hash/language/entry point, driver, device, command evidence,
  output/frame hash and identity kind, command coverage, and timing-class
  identity, and `comparisonPolicy` declarations must match the loaded receipt
  evidence.
- A claim-indexed Chromium browser proof surface must load a hash-matched proof
  page diagnostic receipt. That receipt must bind the proof-page artifact
  hash/byte length, `about:doe` URL, runtime identity path, diagnostics, release
  provenance, and recent receipt IDs exposed by the proof surface. The
  proof-page artifact itself must visibly show those diagnostics, release
  provenance, recent receipt IDs, and every recent receipt payload link.
- A claim-indexed Chromium browser proof surface must load hash-matched public
  gallery receipt artifacts for each gallery row. Those receipts must bind the
  hosted URL, HTTP 200 status, gallery artifact hash/byte length, workload
  contract, workload IDs, receipt IDs, and receipt artifact paths exposed by
  the proof surface. Gallery `workloadIds` must exactly match the unique
  workload IDs from the linked execution receipt payloads, and gallery
  `receiptIds` must exactly match the linked execution receipt artifact IDs.
  Each gallery artifact must also visibly show its category, workload contract,
  workload IDs, receipt IDs, and receipt artifact links.
- Public Chromium browser claims must keep the release bundle, provenance
  report, public download receipt, published proof surface, launch receipt, and
  readiness row bound to the same release archive and manifest identity named by
  `browserRelease`.
- Public Chromium browser claims must also keep the release artifact bundle's
  component summaries bound to the same `browserRelease` component receipt
  paths, artifact kinds, and file hashes.

## Public docs restrictions

Public-facing docs must not hardcode benchmark percentages unless the same row
also cites a current report path and claim state. Prefer citing
`reports/claim-index.json` or the backend evidence summary.

Public-facing docs must not cite removed README charts such as:

- `assets/readme/package-claims.svg`
- `assets/readme/ort-claims.svg`
- `assets/readme/this-machine-results.svg`
- `packages/doe-gpu/assets/package-results.svg`

## Enforcement

Run the public claim checker before publishing README/reporting changes:

```bash
python3 scripts/check-public-claim-surfaces.py
```

The checker validates the claim index shape and scans public docs for stale
chart references or hardcoded package-performance percentages.
