# Browser published release contract

Status: `draft`

## Goal

Define the public browser artifact required before Doe can claim Chromium
WebGPU execution evidence. The package surface is not enough for this claim.
The proof surface is a downloadable Chromium-family browser build with Doe wired
into the WebGPU runtime path.

The release name may be `Doe Browser` or `Fawn Doe`, but the artifact must make
the active runtime visible and verifiable.

## Required release artifact

A release-candidate browser bundle must include:

1. a browser zip for a platform declared by
   `config/browser-release-platform-policy.json`, with a public HTTPS download
   URL,
2. a SHA-256 for the zip and the browser executable inside it,
3. the Doe runtime library hash,
4. the Dawn fallback runtime hash,
5. the shader compiler/toolchain hash,
6. the Chromium patch manifest hash,
7. the browser runtime selector policy hash,
8. the browser release artifact bundle receipt,
9. the public download receipt for the hosted archive,
10. the release archive manifest receipt,
11. the browser release launch receipt,
12. the browser release clean-install check,
13. the Chromium source checkout/runtime-selector gate receipt,
14. the browser runtime frontier bundle receipt.

The governed platform policy currently admits macOS arm64 and Linux x64 as
independent release-candidate lanes. Each platform must satisfy this complete
artifact contract before it supports a browser claim; evidence from one
platform does not promote another.

Linux release candidates must include every package member declared by the
platform policy. The package preflight fails candidate eligibility when ICU,
V8 snapshot, resource, locale, crash-handler, sandbox, or scale-resource files
are absent or when a required executable lacks execute permission. Packaging a
Linux release candidate requires that passing preflight. Compact diagnostic
archives are explicitly not installable release candidates.

The release artifact bundle must name the browser executable member path inside
the zip and verify that member's SHA-256 against the `browserBinary` artifact
hash. A zip hash without the executable member binding is not sufficient release
evidence.
With file verification enabled, the named browser executable archive member
must also carry executable permissions. A packaged browser binary that cannot be
run is not a credible downloadable-browser artifact.

The release artifact bundle must also carry a `releaseArchiveManifest` artifact
for the packaged zip. That manifest must bind the archive path, archive
SHA-256, archive byte length, browser product identity, platform tuple,
required packaged member paths, required member hashes, member byte lengths,
and executable-bit state. With file verification enabled, the manifest must
match the actual zip member metadata. A release candidate with a local zip but
no matching manifest is not reproducible release evidence.
When archive creation is driven by a packageability preflight, the manifest
must also carry `sourcePackageInputs` with the preflight path, hash, and
artifact kind so the packageability receipt remains connected to the archive
manifest it produced.
Release-candidate artifact bundles must also carry `packageInputs` with the
preflight path, hash, and artifact kind, and the checker must compare its
product/platform, component paths, component hashes, and packaged member paths
against the bundle.
If both the bundle and archive manifest bind package inputs, those artifact
references must identify the same preflight report.

The release artifact bundle must also name packaged Doe and Dawn runtime member
paths inside the zip and verify those members' SHA-256 values against
`doeRuntime` and `dawnFallbackRuntime`. A zip that hash-binds the browser
executable but omits the packaged Doe runtime is not evidence of a downloadable
Doe-integrated browser. A release candidate without the Dawn fallback runtime
hash and archive member binding is not rollback-complete release evidence.

The `releaseArchive` artifact must carry the hosted HTTPS download URL for the
published browser archive. A release candidate with only a local archive path
or hash is not public-download-complete release evidence.
The URL host must be public release infrastructure: localhost, single-label
hosts, non-global IP literals, and reserved or test suffixes such as `.local`,
`.localhost`, `.test`, `.example`, and `.invalid`, plus the reserved
`example.com` family, do not satisfy this requirement.

The release artifact bundle must also carry a `publicDownloadReceipt` artifact
for the hosted archive. That receipt must bind the public URL, HTTP method,
successful status code, served content length, served content SHA-256, release
archive path, release archive manifest path, release archive manifest hash,
platform tuple, executable member path, and observation identity.
The served SHA-256 must match `releaseArchive.sha256`; a URL without this
receipt is only a pointer, not download evidence.

The release artifact bundle must carry a `proofSurface` artifact that verifies
the local diagnostics proof page, checked capture policy, active Doe runtime
identity, required gallery categories, linked receipt payloads, and paired
Dawn-vs-Doe comparison receipts. With file verification enabled, the proof page
and at least one gallery page must visibly expose each comparison ID, workload
ID, comparison artifact, and both Dawn/Doe receipt payloads. A release
candidate without the proof surface is not browser-proof-complete release
evidence.

The release artifact bundle must carry a `browserLaunchReceipt` artifact for
release candidates. That receipt must prove the packaged browser was launched
from the release archive, selected Doe, disabled hidden fallback, exposed
WebGPU, loaded the proof page, loaded at least one hosted gallery page, and
observed the proof/gallery receipt IDs. It must also bind the same-page
Dawn/Doe comparison row from the proof surface and observe the paired Dawn and
Doe receipt IDs. The launch receipt must bind the same browser product,
platform, release archive, release archive manifest, proof surface, and
packaged executable/app/runtime member paths as the release bundle. A release
candidate that only hashes a zip without a launch receipt is not evidence that
the downloadable browser actually runs the proof surface.

Release-candidate and release launch receipts must bind a passing
`browser_release_clean_install_check`. The check must safely extract the zip to
a fresh temporary directory, use no borrowed members, run the extracted
browser launch probe, and run strict forced-Dawn and forced-Doe WebGPU smoke
using the browser and Doe library from that extraction. It must bind the
archive, manifest, product, platform, browser hash, and Doe runtime hash, and it
must reject runtime fallback. A launch receipt assembled from declared facts
without this observational check is not release-candidate evidence.

The release artifact bundle must carry a `chromiumSourceCheckout` artifact for
release candidates. That artifact must be a passing
`chromium_source_checkout_check` report with `requireRuntimeSelector=true` and
no missing required checks, proving the Chromium source checkout carried the
runtime-selector markers before the downloadable browser is promoted.

For release candidates, the proof surface `runtimeIdentityPath` must load a
runtime identity whose `provider.artifactIdentity` or
`runtimeSelection.artifactIdentity` hashes match the same release bundle
`browserBinary`, `doeRuntime`, and `dawnFallbackRuntime` hashes. A proof page
that reports Doe active but points at different packaged browser/runtime bytes
is not evidence for the downloadable archive.

Release-candidate proof-page diagnostics must also bind the visible
`compilerPath` back to the release bundle `shaderCompiler.path`. A diagnostics
page that reports a compiler path unrelated to the shipped compiler artifact is
not compiler-path evidence for the downloadable archive.

The release artifact bundle must also carry a `runtimeFrontierBundle` artifact.
That frontier receipt must summarize the checked release bundle path, the same
release bundle `bundleId`, the same release status, a claim-promotion receipt
path present in the release bundle `promotionReceipts`, and a runtime identity
path matching the proof surface `runtimeIdentityPath`; release-candidate
evidence must also report verified release artifact files and
`claimabilityStatus=claimable` with no frontier claim blockers or failures, and
its runtime identity, promotion, and release-bundle component summaries must
pass with promotion status `promotable`. A frontier receipt for another release
bundle, promotion receipt, runtime identity, blocked/failed frontier, or
non-promotable component is not browser frontier evidence for this downloadable
archive.

The proof page must also bind release provenance: browser product identity,
platform tuple, release archive path, release archive SHA-256, hosted download
URL, release archive manifest path, release archive manifest hash, public
download receipt hash, and packaged executable/app/runtime member paths. The
proof-page diagnostic receipt must carry matching release provenance, so
`about:doe` diagnostics cannot be reused across a different downloadable
browser archive. The release artifact bundle checker must compare that
proof-page release provenance against the release bundle itself.

Downloadable release artifacts must also declare `browserProduct` identity.
The product must be either `doe-browser` / `Doe Browser` or `fawn-doe` /
`Fawn Doe`, include a version string, and use a channel matching the release
bundle status. The public download receipt must bind the same product identity
as the release bundle.
The public download receipt producer must reject missing receipt ID,
observation identity, release archive path, release archive manifest path/hash,
browser product identity, platform identity, or packaged executable/app/runtime
member paths before emitting the receipt.

For macOS release archives, the bundle must name the packaged `Info.plist`
member path. That plist must bind the same display name, bundle identifier,
version, package type, and executable name as the release bundle product and
browser executable member.

For non-macOS release archives, the bundle must name a packaged
browser metadata JSON member. That metadata must bind the same browser product,
platform tuple, executable member path, Doe runtime member path, and Dawn
fallback runtime member path as the release bundle.

## Per-run receipts

Every WebGPU run in the published browser proof lane must emit a receipt that
binds:

1. source shader text and source shader hash,
2. source-to-IR-to-backend lowering path,
3. selected backend,
4. driver and device identity,
5. command graph or flight-recorder artifact reference,
6. output hash or frame hash,
7. timing class and timing phases,
8. runtime selector state,
9. fallback state and reason code,
10. receipt ID.

Receipts with hidden fallback, missing source text, missing source hash,
missing output identity, or missing runtime identity remain diagnostic. Browser
execution receipts must include inline `sourceShader.source`, not only a source
hash, so public browser evidence preserves the shader source body that was
lowered. Source hash fields must match the inline source bytes.

## Comparison Mode

The published browser must expose a comparison mode that runs the same page
workload through Dawn and forced Doe, then emits side-by-side receipts. The
comparison is claimable only when both sides prove the same workload identity,
adapter/device policy, timing scope, command coverage, and output hash policy.
The public comparison surface must bind a runner whose page artifact is one of
the gallery pages, whose execution scope is `same_page`, whose modes are Dawn
then Doe, and whose side-by-side receipt emission is explicit. That runner page
must link the side-by-side comparison artifact and both underlying execution
receipt payloads.
The proof-surface producer must reject comparison rows whose runner page
artifact is not one of the gallery artifacts it hash-links.

The comparison receipt must also carry an explicit comparison policy declaring
same workload ID, same source shader identity, same adapter/device identity,
same timing scope, exact command coverage match, output hash/frame hash policy,
and no hidden fallback. The proof-surface gate must reject policy fields that
drift from the paired receipt payloads.
Before emitting a comparison receipt, the producer must also validate the
comparison artifact as a strict Dawn+Doe Chromium WebGPU smoke report with a
valid hash chain.
The checker must bind each comparison artifact mode result back to the linked
Dawn or Doe execution receipt: runtime selector fields, driver identity, and
declared adapter/device identity cannot drift between the side-by-side smoke
artifact and the receipt payloads it publishes.

For browser proof comparisons, same adapter/device identity includes matching
driver identity and matching device identity across the Dawn and Doe receipts.
The proof-surface producer must reject paired receipts that drift on either
field before declaring `same_device_identity`.

The proof-surface producer must also reject comparison entries whose paired
receipts do not identify Dawn and Doe respectively, whose receipt workload IDs
or comparison-row workload ID drift, or whose command coverage differs before
declaring `same_workload_id` or `exact_match`.

Before a published proof-surface manifest hash-links any execution receipt, the
producer must reject receipts that are missing lowering path, backend,
driver/device identity, command evidence, complete command coverage, output
identity, clean runtime selector state, clean fallback state, or timing phases.
That producer-side receipt check must run before comparison policies can
declare `no_hidden_fallback` or `exact_match`.

Auto mode can be useful for diagnostics, but it cannot support browser
replacement claim language.

## Public Test Gallery

The release must link to hosted gallery pages that exercise:

1. compute kernels,
2. rendering and presentation,
3. tensor/model workloads,
4. shader edge cases and diagnostics,
5. benchmark traces.

Each gallery page must name the workload contract, expose workload IDs, emit
receipt IDs, and link to the generated artifact paths. Demo pages without
receipts are examples, not browser proof.
The proof-surface producer must reject gallery page artifacts that do not
visibly expose their category, workload contract path, workload IDs, receipt
IDs, and receipt artifact links.

At least one gallery page for each published Dawn-vs-Doe comparison must expose
the comparison ID, workload ID, comparison artifact, Dawn receipt payload, and
Doe receipt payload on the same page.

Release-candidate proof surfaces must also provide a hosted HTTPS URL for each
gallery page. Local gallery artifacts can back file/hash verification, but they
do not satisfy the public gallery surface without the hosted URL. Gallery URLs
use the same public-host rule as release archive download URLs.

Each hosted gallery page must also carry a `browser_public_gallery_receipt`
artifact that binds the page URL, successful GET status, served content length,
served content SHA-256, gallery artifact path, workload contract path,
workload IDs, receipt IDs, receipt artifact paths, category, and observation
identity. The served SHA-256 must match the hash-bound gallery artifact. A
gallery URL without this receipt is only a pointer, not hosted demo evidence.
The proof-surface producer must reject gallery receipts that do not report a
GET request, status code 200, a receipt ID, and observation identity before the
gallery page can be hash-linked.
The public gallery receipt producer must reject missing receipt ID,
observation identity, gallery artifact path, workload contract path, workload
IDs, receipt IDs, or receipt artifact paths before emitting the receipt.

## Proof Page

The browser must expose a local diagnostics page such as `about:doe` or an
equivalent internal URL. The page must show:

1. active runtime mode,
2. active backend,
3. compiler path,
4. TSIR, HostPlan, and CSL status,
5. fallback policy state,
6. recent receipt IDs,
7. links to per-run receipt payloads,
8. comparison IDs, workload IDs, comparison artifacts, and paired Dawn/Doe
   receipt payloads for recent comparison-mode runs.

For Doe proof surfaces, the proof-page `activeBackend` value must match the
backend reported by at least one linked Doe execution receipt, so the
diagnostics page cannot claim a generic WebGPU path while the receipt evidence
names a different Doe backend.

The proof page is a diagnostics surface, not a permission bypass. It must obey
the browser capture policy and redact or hash page data that should not leave
the origin boundary.

Release-candidate proof surfaces must carry a `browser_proof_page_receipt`
artifact for the local diagnostics page. That receipt must bind the internal
URL, load type, loaded status, served content SHA-256, served content length,
proof artifact path, runtime identity path, diagnostics fields, recent receipt
IDs, and observation identity. The served SHA-256 must match the hash-bound
proof page artifact, and the diagnostics must match the proof surface
diagnostics.
The proof-surface producer must reject proof-page receipts that do not report
the expected load type, loaded status, receipt ID, diagnostics object, release
provenance object, and observation identity before the proof page can be
hash-linked.
The proof-surface producer must reject proof-page receipts whose
`recentReceiptIds` are not backed by the execution receipt payloads linked from
the same proof page.
Before writing a proof surface, the producer must also reject proof-page
artifacts that do not visibly expose the active diagnostics values, release
provenance fields, recent receipt IDs, linked receipt payload paths, and
same-page Dawn-vs-Doe comparison evidence.

## Claim Boundary

The public browser claim is:

1. download the browser,
2. run a WebGPU workload,
3. inspect the source-preserving Doe execution receipt,
4. compare it against Dawn.

This contract does not claim that all Chromium WebGPU workloads are replaced by
Doe, that Doe is globally faster than Dawn, or that package/browser-wrapper
execution proves browser runtime replacement.

## Gate Coverage

The published release contract depends on:

1. browser claim methodology,
2. runtime selector and fallback policy,
3. browser GPU flight recorder,
4. browser shader links,
5. browser benchmark superset,
6. browser release artifact bundle,
7. browser runtime frontier bundle,
8. Chromium patch manifest,
9. browser artifact identity coverage,
10. browser unsupported/fallback reason taxonomy.

## Promotion Criteria

This contract can move out of draft only after a release-candidate browser
bundle verifies all referenced files and hashes, the downloadable archive and
gallery pages expose hosted HTTPS URLs, the downloadable archive and every
hosted gallery page have matching public served-byte receipts, the comparison
gallery emits paired Dawn/Doe receipts from one page, and the proof page exposes
active runtime identity and comparison receipt links without hidden fallback
through a matching diagnostics page receipt.
