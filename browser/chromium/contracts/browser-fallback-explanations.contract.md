# Browser fallback explanations contract

Status: `draft`

## Objective

Define developer-visible unsupported-capability and fallback explanations for
browser-lane artifacts. Explanations must name the capability, surface, status,
browser reason code, shared Doe evidence blocker code, developer action,
evidence path, and fallback visibility policy.

## Input shape

The explanation schema is
[`config/browser-fallback-explanations.schema.json`](../../../config/browser-fallback-explanations.schema.json).
Each artifact declares runtime identity, explanation rows, and origin-scoped
privacy policy. It also declares the shared evidence blocker taxonomy used by
each row's `evidenceBlockerCode`.
When `--runtime-identity-root` is supplied, the checker resolves
`runtimeIdentity.runtimeIdentityPath` and requires its selected runtime and
fallback state to match either a `browser_runtime_identity` artifact or the
referenced browser smoke report.

## Output artifacts

The artifact kind is `browser_fallback_explanations`. Artifacts are diagnostic
until generated from Chromium browser runs.

`browser/chromium/scripts/build-browser-fallback-explanations.py` converts a
Playwright smoke report plus optional companion artifacts into developer-facing
fallback and unsupported-capability rows. Missing companion artifacts are
reported as unsupported rows with the exact smoke flag needed to generate the
evidence.

## Failure taxonomy

The structural checker reports:

- `hidden_fallback_allowed`
- `invalid_schema_version`
- `invalid_artifact_kind`
- `unsafe_artifact_path`
- `missing_reason_code`
- `missing_evidence_blocker_code`
- `unknown_evidence_blocker_code`
- `evidence_blocker_code_mismatch`
- `missing_developer_action`
- `fallback_status_mismatch`
- `unsafe_privacy_policy`
- runtime identity reference failures from the shared browser runtime-identity
  reference checker

## Fallback policy

Hidden fallback is never allowed. If a fallback is applied, the row status must
be `fallback` and the row must carry a reason code.
Every row must also carry an `evidenceBlockerCode` from
[`config/evidence-blocker-taxonomy.json`](../../../config/evidence-blocker-taxonomy.json)
that matches the browser reason taxonomy crosswalk.
Explanation evidence paths must be repo-relative references; absolute paths and
parent traversal are rejected before promotion checks.

## Gate coverage

- Schema validation: `python3 bench/gates/schema_gate.py`
- Builder:
  `python3 browser/chromium/scripts/build-browser-fallback-explanations.py --report <browser-smoke.json> --mode doe --out <browser-fallback-explanations.json>`
- Structural check:
  `python3 browser/chromium/scripts/check-browser-fallback-explanations.py --explanations examples/browser-fallback-explanations.sample.json --taxonomy-root . --runtime-identity-root .`

## Promotion criteria

Promotion requires browser-generated explanations attached to runtime-selection,
capability, workload, and replay artifacts wherever a capability is unsupported
or a fallback path is taken.
