# Browser Benchmark Superset Contract (Draft)

Status: `draft`

## Objective

Define a low-maintenance browser benchmark superset that:

1. depends on core engine workload contracts in `bench/workloads/specialized/workloads.amd.vulkan.superset.json`,
2. projects browser-relevant workloads automatically into browser API tests,
3. adds browser workflow scenarios on top,
4. keeps core/runtime and nursery logic de-duplicated.

## Layer Model

1. `L0 engine`
   - canonical Dawn-vs-Doe runtime benchmark layer (`full39` strict comparable).
2. `L1 browser-api`
   - browser-executed WebGPU API scenarios projected from `L0` workload contracts.
3. `L2 browser-workflow`
   - browser component and lifecycle workflows that involve WebGPU but include browser overhead.

## Source-of-Truth Rule

1. `bench/workloads/specialized/workloads.amd.vulkan.superset.json` remains the only source for engine workload identity and ownership.
2. nursery projection manifests are generated from this source and must not hand-copy workload lists.
3. if a workload is added/removed in `L0`, the projection generator and gate must reflect this automatically.
4. projection manifests reference source workloads and projection rules with repo-relative contract paths.

## Projection Classes

Each `L0` workload maps to one of:

1. `high`
   - near-direct browser API projection expected.
2. `medium`
   - browser projection possible with declared semantic/timing drift.
3. `non_projectable`
   - runtime-internal semantics; keep in `L0` only.

## Required Projection Fields

Each projected workload row must include:

1. `sourceWorkloadId`
2. `domain`
3. `projectionClass`
4. `layerTarget` (`l1_browser_api` or `l0_only`)
5. `scenarioTemplate`
6. `comparabilityExpectation` (`strict`, `component`, `none`)
7. `requiredStatus` (`ok`, `not_applicable`)
8. `claimScope` (`l1_strict_candidate`, `l1_component_only`, `l0_only_no_claim`)
9. `claimLanguage`
10. `projectionNote`
11. `browserWorkload`

`browserWorkload` records browser-executed parameters derived from the source
workload contract. Upload rows must include `uploadBytes` so reports prove the
effective upload size rather than inferring it from workload names.
Upload rows above the browser lane's exact-upload ceiling must stay
`non_projectable`/`l0_only`; they must not be silently downscaled into a
different browser workload.
The browser upload runner may increase per-row iterations for small byte sizes
using an explicit `iterationPolicy`; reports must record requested iterations,
effective iterations, upload bytes, and total upload bytes.
Compute rows whose source shader semantics are not implemented in the browser
runner must remain component diagnostics and must identify their
`computeProjection`. Texture contract rows must include the effective texture
dimensions and mip count.

Projection manifests must also carry:

1. `sourceWorkloadsSha256`
2. `rulesSha256`
3. `projectionContractHash`

These hashes are blocking for contract synchronization.

## Browser Workflow Contract

`L2` workflow entries must define:

1. `id`
2. `scenarioTemplate`
3. `description`
4. `metrics`
5. `comparabilityExpectation`
6. `required` (bool)
7. `requiredStatus` (`ok`, `optional`)
8. `claimScope` (`l2_component_only`, `l2_diagnostic_only`)
9. `claimLanguage`

`fawn_visual_resource` workflow entries additionally define `resourcePath`,
which must point to a checked-in `browser/chromium/resources/*.html` page. These
rows are optional diagnostics for visible Fawn pages and must use
`comparabilityExpectation=none`, `requiredStatus=optional`, and
`claimScope=l2_diagnostic_only`. Layered reports and score rows must include
the current SHA-256 for each referenced visual resource; checker drift means the
artifact no longer proves which page source ran.

## Browser layered score

The browser layered score sidecar remains diagnostic. It preserves the
row-weighted `overall` summary for existing consumers and also emits
`categoryBalancedOverall`, computed from the geometric mean of category
geomeans. The fair browser-projection summary is `strictComparable`; it must
only include rows with `comparabilityExpectation=strict` and
`browserWorkload.sourceComparable=true`,
`browserWorkload.sourceClaimEligible=true`, and
`browserWorkload.benchmarkClass=comparable`.
Both summaries must carry separate paired scores for baseline and comparison
modes plus comparison percent delta. The category-balanced summary is the
browser-bench style headline: each category contributes once, while row-level
evidence remains available for auditing. Score sidecars must also emit
`bottlenecks`, sorted by negative comparison delta, so weak categories, rows,
and measured phases are explicit in the artifact.
Reports must record `modeOrder` and `modeSchedule`. `modeSchedule=grouped`
means all rows ran for one runtime before the next runtime.
`modeSchedule=paired` means each row records paired runtime execution in
`modeRunDetails` before moving to the next row. `modeSchedule=paired-balanced`
runs both row orders and averages numeric metrics per runtime, with
`orderBalancedSampleCount` recorded in row metrics. Order-sensitive reports
remain diagnostic until order-balanced evidence passes the same structural and
score gates as the grouped report. Non-grouped schedules must execute
strict-comparable `L1` rows before component diagnostics so component probes do
not precondition strict browser evidence.

Texture scenario rows must expose `textureMs` when the row can measure the
texture path separately from scenario startup. The score metric priority prefers
that scenario-local value before falling back to total `elapsedMs`. Sampled
texture rows must also expose the texture iteration count, warmup count, and
phase-level timing summaries for the phases exercised by the scenario:
texture creation, texture write, view creation, render pipeline creation,
submit/readback, map/read, wait, property query, and destroy.
Render-readback rows must expose `renderMs` plus the render-path phases they
exercise so render scoring is not dominated by adapter/device setup.

## Focused diagnostic runs

The layered runner may accept explicit category filters for tuning weak browser
surfaces. A filtered report must stay `claimStatus=diagnostic`, must include a
`workloadFilter` object with selected categories and before/after row counts,
and must not contain L1 or L2 rows outside the selected categories. The checker
validates coverage only for rows in the filter. Filtered reports are engineering
diagnostics, not full-superset evidence. Score sidecars produced from filtered
reports must carry the same `workloadFilter`.

The layered runner must make adapter policy explicit. The default diagnostic
policy is `powerPreference=high-performance` for both modes; alternate adapter
policy runs must record the selected value in report methodology.

## Gate Requirements

Nursery superset gate must fail when:

1. generated projection rows are not 1:1 with `L0` workload IDs,
2. any `high` or `medium` row lacks an `L1` scenario template,
3. any `non_projectable` row is incorrectly marked as `L1`,
4. projection hashes drift from active workloads/rules,
5. a provided layered browser report misses any required projected `L1` row,
6. required `L1/L2` rows are present without explicit `status` + `statusCode`,
7. report claim-scope fields drift from projection/workflow contracts,
8. report evidence lacks workload identity, runtime selection, adapter
   identity, shader compiler identity, or trace hash fields.

Diagnostic `auto` mode is allowed only as runtime-selector evidence. It must
carry `selectionMode=auto`, a concrete `selectedRuntime` of `dawn` or `doe`,
`forcedMode=null`, visible fallback reason codes when fallback is applied, and
the same artifact identities as the selected runtime. Claim gates still require
explicit `dawn` plus forced `doe` evidence.

## Failure Taxonomy (Browser Lane)

Required stable status codes:

1. `ok`
2. `l0_only`
3. unsupported class:
   - `adapter_null`
   - `webgpu_unavailable`
   - `api_unsupported`
   - `sandbox_constraint`
   - `launch_surface_unavailable`
   - `scenario_template_unknown`
4. failure class:
   - `browser_launch_failed`
   - `mode_setup_failed`
   - `scenario_runtime_error`

## Claim Semantics

1. `L0` claim language remains strict and release-policy gated.
2. `L1` can use strict claim language only when timing scope and semantics align.
3. `L2` must use workflow/component claim language; no direct substitution for `L0`.
4. reports must explicitly label layer and comparability expectation.

## Promotion Out of Nursery

Promote only after:

1. projection and workflow schemas are stable,
2. generator + gate run green over repeated windows,
3. browser layer artifacts are reproducible and traceable,
4. ownership for maintenance is explicit.

## Cadence and Approvals

Execution cadence:

1. daily browser smoke runs,
2. twice-weekly layered browser benchmark runs,
3. weekly promotion review.

Promotion gate approvals must match the roles declared by the workflow
manifest and promotion-approvals artifact.

## Artifact Discipline

1. Diagnostic browser artifacts remain nursery-local or under `bench/out/scratch`.
2. Writing diagnostics to canonical `bench/out` claim paths is prohibited by default.
3. Promotion to canonical `bench/out` requires formal promotion review + approvals.

## Rollback Triggers

1. hand-maintained scenario drift from workload source-of-truth,
2. hidden toggles affecting comparability semantics,
3. missing runtime-mode evidence in reports,
4. claim wording that exceeds scenario class.

## Ownership Split

1. Chromium lane lead: Playwright harness and workflow scenarios.
2. Contracts liaison: projection rules and schema/hash checks.
3. Coordinator: promotion boundary control from diagnostics to claim-adjacent artifacts.
