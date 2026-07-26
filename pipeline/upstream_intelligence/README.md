# Dawn/Tint upstream intelligence

This package is Doe's active, update-aware intake and review pipeline for Dawn
Gerrit changes and the Chromium issues they reference. It replaces the
`dawn-research/` regex experiment as the operational history surface. The
source miner in `pipeline/agent/` remains the independent source-code
corroboration lane.

## Contract

The pipeline separates four authorities:

1. **Upstream events** are immutable versions of Gerrit changes and Chromium
   issues in SQLite.
2. **Normalized findings** deterministically score files, issue links,
   backend terms, vendors, and failure terms.
3. **Enrichments** provide a readable deterministic summary or a
   schema-constrained LLM review. They cannot change finding evidence.
4. **Promotion receipts** record a maintainer decision and the exact finding
   input hash. They explicitly do not authorize a runtime mutation.

An upstream report therefore cannot silently become a Doe quirk. A separate
workload, oracle, proof obligation when required, and runtime/config change are
still needed under `docs/process.md`.

## Source coverage

Gerrit is exhaustively paginated for the configured query. Pagination fails
when `maxPages` is exhausted while `_more_changes` is still present. Live sync
uses a durable high-water mark plus an overlap window, and the event key
includes both the upstream update timestamp and current revision. Updated
changes are retained as new versions rather than discarded by change number.

Chromium Issue Tracker does not expose a documented public bulk-listing API.
The pipeline therefore discovers issues from Gerrit `Bug:`, `Fixed:`,
`Fixes:`, and `Issue:` footers and from explicit operator-supplied IDs. It
enriches each public issue-by-ID page and records every fetch or parse failure
in the run receipt. Private or missing issues receive explicit unavailable
records. Requests above the per-run bound enter a durable pending queue and
are resumed on later syncs. `coverageComplete` means every discovered issue ID
was fetched or classified unavailable, with no deferred or retryable failures;
it does not claim an exhaustive crawl of all Chromium issues.
Unavailable IDs are retried after the configured `unavailableRetryDays`, so a
later visibility change is eventually observed.

The issue adapter parses the page's server-provided
`defrostedResourcesJspb` payload with balanced JSON scanning. This is an
upstream compatibility seam, so parser fixtures and live probes are both
required. Stored Gerrit events are a policy-minimized projection that excludes
reviewer/account metadata, and issue descriptions are capped by
`maxDescriptionCharacters`.

## Commands

Canonical invocation:

```bash
python3 -m pipeline.upstream_intelligence --help
```

Synchronize from the durable live cursor:

```bash
python3 -m pipeline.upstream_intelligence sync
```

Require actual model enrichment instead of the deterministic review fallback:

```bash
OPENAI_API_KEY=... \
python3 -m pipeline.upstream_intelligence --require-llm sync
```

Backfill a closed Gerrit interval:

```bash
python3 -m pipeline.upstream_intelligence backfill \
  --after 2025-01-01 \
  --before 2025-02-01
```

Supply issue IDs that are not referenced by a Gerrit footer:

```bash
python3 -m pipeline.upstream_intelligence sync \
  --issue-ids 538691038,123456789
```

Replay the checked-in legacy Gerrit archive without network access:

```bash
python3 -m pipeline.upstream_intelligence replay \
  dawn-research/data/raw_changes/changes-*.jsonl
```

Malformed archive rows are hash-recorded in `inputRejections`, excluded from
normalization, and make coverage incomplete. Add `--fail-on-rejection` when a
strict replay should stop at any rejected row.

Record a review decision:

```bash
python3 -m pipeline.upstream_intelligence gate \
  --finding-id dawn-cl-123456 \
  --decision approved \
  --reviewer maintainer-id \
  --reason "Reproduced by governed workload <id>." \
  --output bench/out/upstream-intelligence/reviews/dawn-cl-123456.json
```

Inspect durable state:

```bash
python3 -m pipeline.upstream_intelligence status
```

Global `--database` and `--output-root` options support isolated lanes. Exact
network, relevance, model, and storage policy lives in
`config/upstream-intelligence.json` and its closed schema.

## LLM behavior

The provider request includes the normalized finding, evidence URLs, and a
versioned prompt identity. The response must match a closed JSON schema:
summary, Doe impact, failure mechanism, recommended action, confidence, and
citations. Results are cached by finding input hash, provider, model, and
prompt version. Evidence changes or prompt/model changes therefore cause a new
enrichment. `maxFindingsPerRun` bounds provider calls. Uncached current and
historical findings form a durable queue derived from the findings table;
newest evidence is processed first and the remainder is listed in
`enrichmentDeferred`.

Upstream prose is explicitly treated as untrusted data rather than model
instructions. Enrichment is rejected if it cites a URL outside the supplied
Gerrit and issue evidence set.

Backlog is not an execution failure. `operationalSuccess` remains true while
bounded issue or enrichment work is deferred, and `coverageComplete` remains
false until both queues drain. Transport, parse, model, schema, and input
rejection failures make the command exit nonzero after writing its receipt.

Without the configured credential, normal local runs emit an explicitly
`deterministic/deterministic-v1` review. `--require-llm` fails instead. The
scheduled workflow uses `--require-llm`, so it cannot claim model review while
silently using the fallback.

## Artifacts and state

Default local state:

```text
bench/out/upstream-intelligence/
├── state.sqlite3
└── runs/<run-id>/
    ├── run.json
    ├── findings.json
    ├── enrichments.json
    └── review.md
```

The SQLite database is operational state, not release evidence. Run receipts
and reviewed promotion receipts are schema-backed. Stable evidence intended
for a claim must be deliberately promoted to the appropriate tracked report
surface.

The nightly workflow restores the database through a versioned cache, prevents
overlapping syncs, requires `OPENAI_API_KEY`, uploads review packets, and
retains source-miner outputs. Cache loss is safe: the configured
`initialAfter` boundary allows rebuilding the active history.

## Verification

```bash
python3 -m unittest pipeline.upstream_intelligence.test_upstream_intelligence
python3 -m unittest pipeline.agent.test_mine_quirks
python3 -m unittest bench.tests.test_config_schemas
python3 bench/tests/test_ci_workflow_surface.py
```

Tests cover Gerrit pagination and truncation, nested current-revision metadata,
issue-page parsing, deterministic normalization, update versions, monotonic
cursors, strict/cached model output, replay artifacts, and the review gate.
