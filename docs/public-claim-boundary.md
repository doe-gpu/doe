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

Allowed `claimState` values:

- `claim-indexed`: public claim row backed by current report and claim metadata
- `diagnostic`: useful engineering evidence, not public speed wording
- `status-only`: support/capability status without a promoted performance row
- `scaffolded`: contract or implementation exists, but fresh evidence is absent

## Claim language rules

- A claim-indexed row may say what the artifact proves, including backend,
  surface, workload, metric direction, and comparison target.
- A diagnostic row may describe what was measured, but must not become "Doe is
  faster" product language.
- A status-only row may describe support status or blocker state, not benchmark
  performance.
- A scaffolded row may describe the intended lane and missing evidence.

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
