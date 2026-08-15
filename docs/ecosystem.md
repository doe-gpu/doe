# Ecosystem registry

This page defines registry governance only. Doe's product strategy,
downstream-application portfolio, promotion flywheel, and commercial journey
live only in [`thesis.md`](thesis.md).

Doe keeps ecosystem research as governed evidence rather than a sales
spreadsheet. The canonical actor records live in
[`../config/ecosystem-registry.json`](../config/ecosystem-registry.json), and
their shape is enforced by
[`../config/ecosystem-registry.schema.json`](../config/ecosystem-registry.schema.json).
This page explains how to interpret and update that registry; it does not copy
its actor inventory, scores, or benchmark results.

## Actors and independent scores

A registry subject is an **actor** with an explicit type: project, package,
company, foundation, or runtime. Projects and packages remain separate from
their owning organizations so one company's repositories can have different
workloads, evidence, and relationships to Doe.

The versioned scoring vocabulary lives in
[`../config/ecosystem-scoring-policy.json`](../config/ecosystem-scoring-policy.json):

- **Doe Leverage** measures how materially Doe could improve correctness,
  reliability, performance, installation, or diagnosis.
- **Existing Capability Coverage** measures how much runtime-adjacent work the
  actor already owns, including shaders, orchestration, provider setup, code
  generation, diagnostics, or runtime implementation.

Relationship labels are derived from both scores by the scoring policy. They
are never stored on actors. A score revision names its policy version,
registry revision, reviewer, review status, changed observations, and
evidence-backed reasons. Initial source assessments remain provisional until
an upstream source review and a measured harness produce a reviewed report.

## State boundaries

Relationship hypotheses, engagement, evidence, adoption, and release promotion
are independent:

```text
engagement: discovered -> researched -> harness-ready -> measured
            -> outreach-ready -> integrated

evidence:   source-only -> diagnostic -> comparable -> claimable

adoption:   none -> validation-workload -> adopter -> design-partner
            -> supported-integration

promotion:  not-promoted -> candidate -> promoted
```

`retired` is an engagement terminal state, not an evidence verdict. A source
review does not imply measurement. A comparable report does not imply a
public claim. Outreach readiness requires either a reproducible win or a
concrete receipt-explained failure in a reviewed report.

`adoptionStage` records an evidenced external relationship, not a relationship
hypothesis derived from scores. A measured application can become a
`validation-workload` without becoming an adopter. `adopter` or later requires
an integrated engagement and a validated production provider substitution.
`promotionStatus` answers a separate release-engineering question: whether
Doe releases must run and pass that actor's harness.

The versioned promotion floor lives in
[`../config/external-project-promotion-policy.json`](../config/external-project-promotion-policy.json).
A promoted harness requires claimable evidence on physical GPU hardware,
unchanged application and shader source, validated installation, concurrency,
teardown, stress, bounded memory growth, p50/p95/p99 performance evidence,
receipt replay, and a blocking release command. A diagnostic workload cannot
be promoted by changing its registry label. Promotion additionally requires a
predeclared runtime-ownership plan and reviewed attribution showing whether the
application should use DoeRuntime or DoeProof after the governed incumbent
controls and ownership costs are considered.

## Evidence routing

- Checked-in harness manifests, minimal patches, immutable inputs, and reviewed
  oracles live under [`../bench/external-projects/`](../bench/external-projects/).
- Fixed failures discovered by those applications have checked-in regression
  records under `bench/external-projects/<actor-id>/failures/`. Each record
  binds the original evidence to a minimized repro, implementation paths, and
  permanent regression tests.
- Generated clones, logs, raw samples, receipts, and run manifests live under
  `bench/out/external-projects/<actor-id>/<run-id>/`.
- Stable reviewed summaries live under
  [`../reports/ecosystem/`](../reports/ecosystem/).
- Public claims enter [`../reports/claim-index.json`](../reports/claim-index.json)
  only after correctness, equivalence, reliability, and claim gates pass.

Generated evidence is preserved by run identity. Reviewed reports are added;
they are not rewritten to erase earlier outcomes. Registry score changes point
to the observation that changed the score and preserve earlier revisions in
`scoreHistory`.

Prepare or execute a registered harness through the stable benchmark CLI:

```bash
python3 bench/cli.py external prepare --actor <actor-id> --harness <harness-id>
python3 bench/cli.py external reproduce --actor <actor-id> --harness <harness-id>
```

The preparation receipt binds the exact upstream commit, clean-source state,
host and hardware identity, tool versions, contracts, and built provider
artifacts. The reproduction receipt verifies and binds that preparation before
running policy gates and workload evidence. A reviewed report proposed for
promotion must reference a passing, hash-valid, claim-eligible preparation
receipt for the same actor, harness, and upstream commit.

## Validation and views

Run the blocking semantic checker:

```bash
python3 bench/gates/ecosystem_registry_gate.py
python3 bench/gates/external_project_release_gate.py
```

The canonical release pipeline runs
`bench/runners/run_external_project_release_suite.py`. It executes every
promoted harness and fails the release on any nonzero result. Zero promoted
harnesses is reported honestly rather than treated as downstream proof; use
`--require-promoted` when auditing a release policy that must contain at least
one promoted application.

Render a current view directly from JSON:

```bash
python3 -m bench.tools.render_ecosystem_registry --format markdown
python3 -m bench.tools.render_ecosystem_registry --format json
```

Rendered views are disposable. The registry and referenced reports remain the
source of truth.
