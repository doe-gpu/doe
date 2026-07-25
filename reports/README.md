# Reports

Tracked report fixtures and parity receipts that are small enough to keep in
tree.

Use `bench/out/` for generated run workspaces, large benchmark outputs, and
machine-local evidence. Keep files here only when they are stable reference
artifacts that tests, docs, or reviews may inspect directly.

- `refactors/` contains schema-backed characterization receipts for structural
  changes. A receipt distinguishes preserved cases from explicit contract
  tightening and binds the before/after source identities.

- `claim-index.json` lists the benchmark receipt paths that support the public
  README claim charts without requiring broad historical `bench/out` retention.
  `claim-indexed` entries must carry `comparisonStatus=comparable`,
  `claimStatus=claimable`, and a claim sidecar path. Diagnostic and status-only
  entries may stay visible, but they are not public speed claims.
  Chromium browser release rows use the typed `browserRelease` object to bind
  the release bundle, runtime frontier, release archive path/SHA-256, release
  archive manifest path/SHA-256, public download URL, package inputs,
  provenance, public download, proof surface, launch, finalizer, finalizer
  check, and readiness report evidence before a browser build can become
  claim-indexed. The claim-index gate also checks those paths, the archive and
  manifest bytes, clean package-input/provenance preflight state, provenance
  component refs for package-input/public-download/proof-surface/check/launch
  receipts, public HTTPS download URL validity, public download GET observation
  identity/status/served-length evidence, nested release identity, release
  artifact bundle component summaries, archive-manifest/package-input/
  provenance/public-download/proof-surface/launch identity against the release
  bundle's browser product, platform, and packaged member paths, manifest
  member hashes, package-input browser binary/Doe runtime/Dawn fallback runtime/
  shader compiler refs against the release bundle artifacts, manifest
  `sourcePackageInputs` refs when present, and the readiness-exposed receipt
  hashes against the Chromium browser row in the named readiness report. Loaded runtime
  frontier bundles must be claimable with no `claimBlockers`,
  `claimBlockerSummary`, `failures`, or nonzero summary counts, and must bind
  the same proof-surface Doe runtime identity, promotable release-bundle
  promotion receipt, and release-candidate artifact bundle path/verified-file
  state named by the browser release evidence.
  Claim-indexed Chromium rows must bind a passing proof-surface checker report
  with no failures, file verification, and public URL enforcement; that report's
  `surfacePath` and `surfaceSha256` must match the exact proof surface named by
  `browserRelease.proofSurfacePath`.
  The finalizer report must pass with no failures, `summary.failureCount=0`,
  `summary.claimabilityStatus` matching the runtime frontier bundle,
  `summary.releaseBundleIdentitySha256` matching the release bundle identity
  projection, output refs bound to the exact release bundle/runtime frontier
  paths and bytes named by `browserRelease`, and an input ref bound to the
  exact package-input receipt.
  The finalizer-check receipt must pass with `finalizerStatus=pass`, file
  verification, `requirePass=true`, and no failures, and must bind
  `finalizerReportPath`/`finalizerReportSha256` to the exact finalizer report
  named by `browserRelease.finalizerReportPath`.
  Claim-indexed Chromium rows must also bind a launch receipt proving a packaged
  Doe WebGPU launch whose `proofSurface.path`/`proofSurface.sha256`/
  `proofSurface.kind` match the exact published proof surface named by
  `browserRelease.proofSurfacePath`, plus a loaded `about:doe` proof page,
  loaded public HTTPS gallery page, same-page Dawn/Doe comparison mode,
  side-by-side Dawn/Doe receipt emission, and observed proof/gallery/Dawn/Doe
  receipt IDs. The launch receipt must match the loaded proof surface's proof
  page, loaded gallery page, comparison row, receipt IDs, and active backend,
  including proof/gallery receipt IDs loaded from the proof-surface diagnostic
  and public-gallery receipt payloads.
  The loaded proof surface itself must also
  expose `about:doe` Doe diagnostics, compiler path, TSIR/HostPlan/CSL status,
  hidden-fallback-disabled state, recent execution receipt coverage for
  proof-page payloads, gallery receipts, and comparison receipts, with no
  unbacked recent receipt IDs, public hosted gallery pages for
  compute/rendering/tensor/shader-edge/benchmark-trace categories, no
  unrecognized gallery categories, and same-page Dawn/Doe comparison parity.
  The proof-surface diagnostics `compilerPath` must match the release bundle
  `shaderCompiler.path`, and the loaded `runtimeIdentityPath` artifact's
  provider or runtime-selection hashes must match the release bundle browser
  binary, Doe runtime, and Dawn fallback runtime hashes.
  The same-page runner
  gallery artifact must visibly show the comparison ID, workload ID, runner
  page/scope/modes, side-by-side receipt emission, comparison artifact path, and
  both Dawn/Doe receipt IDs and payload links. The same-page
  `comparisonArtifact` must also be loaded and hash-matched as a strict
  browser smoke report with valid report-hash and mode-result hash-chain
  evidence. Its runtime-selection hashes must match the release bundle browser
  binary, Dawn fallback runtime, and Doe runtime artifacts, and both Dawn and
  Doe execution receipt command evidence must name that comparison artifact
  path and hash-bind either the comparison artifact file or report hash.
  Referenced execution
  receipt refs must be unambiguous, and receipt files must hash-match their
  proof-surface artifact refs and expose receipt ID, workload ID, WGSL source
  shader text/hash aliases/entry point, lowering path bound to selected runtime, backend identity matching
  selected runtime, driver/device identity, command-graph or flight-recorder SHA evidence,
  exactly one output or frame SHA-256, complete command coverage, clean
  no-hidden-fallback runtime selector/fallback state, and numeric
  setup/encode/submit-wait timing phases.
  Loaded Dawn/Doe comparison receipt payloads must also match the comparison
  workload ID plus source text/hash/language/entry point, driver, device,
  command evidence, output/frame hash and identity kind, command coverage, and
  timing-class identity, and `comparisonPolicy` declarations must match the
  loaded receipt evidence. The proof-page diagnostic
  receipt must
  hash-match its artifact ref and bind the proof-page artifact hash/byte length,
  `about:doe` URL, runtime identity path, diagnostics, release provenance, and
  recent receipt IDs exposed by the proof surface; the proof-page artifact must
  visibly show those diagnostics, release provenance, recent receipt IDs, and
  every recent receipt payload link.
  Public gallery receipt files must also hash-match their artifact refs and bind
  the hosted URL, HTTP 200 status, gallery artifact hash/byte length, workload
  contract, workload IDs, receipt IDs, and receipt artifact paths exposed by the
  proof surface; gallery `workloadIds` must exactly match the unique workload
  IDs from the linked execution receipt payloads, gallery `receiptIds` must
  exactly match the linked execution receipt artifact IDs, and the gallery
  artifact itself must visibly show the category, workload contract, workload
  IDs, receipt IDs, and receipt artifact links.
