# Public and internal tooling

The machine-readable boundary is `config/tool-surfaces.json`. When prose and
the manifest disagree, the manifest wins.

## Public surface

`packages/doe-gpu/` is the public npm package. Its `package.json` owns exports
and packaged files, including the `doe-proof-node` executable; its README owns
user-facing installation, contract, and examples.

Advanced JavaScript helpers remain public when exported by the manifest, even
when their primary use is repository evidence. That is semver surface, not
authorization to describe repo-only CLIs as npm product features.

`doe-proof-node` is the narrow public exception: it operates only on the
provider-neutral governed process contract and cannot promote benchmark,
runtime-ownership, or release claims. Other benchmark and release CLIs remain
repo-only.

## Repo-only surface

Unless the manifest says otherwise, these are contributor/operator tooling:

- `bench/` compare, claim, release, and reporting commands;
- `runtime/zig/` build and compiler tools;
- `browser/chromium/` browser contracts, scripts, and diagnostics;
- `pipeline/` trace, proof, and upstream-intelligence tooling;
- top-level `scripts/`, `examples/`, `demos/`, and `nursery/`.

`bench/gates/catscan_gate.py` is the internal component-charter validator and
generated-index owner. It is a contributor gate, not a public package API.

`bench/tools/program_execution_identity_receipt.py` is the internal
source-to-backend execution receipt builder and verifier. Its optional blocking
gate rebuilds the receipt from every referenced byte; the tool is not an npm
package surface.

`DOE_PROGRAM_IDENTITY_TRACE_PATH` enables the repo-governed native Vulkan
program-identity journal. Its schema lives at
`config/native-program-identity-trace-row.schema.json`; exact compute, vertex,
and fragment SPIR-V bytes are materialized next to the journal under their
digest. Direct-render rows record the native internal submit-and-wait completion
boundary; compute rows remain joined to later outer queue submissions.
Application gates, not the runtime alone, must join those rows to public
observations and an independent output oracle.

`bench/tools/validate_native_program_identity_trace.py` is the standalone
repo-only validator for that journal. It checks every row against the registered
schema, enforces per-process sequence integrity, requires later outer submission
for compute dispatches, optionally requires the direct-render internal
completion marker, hashes every materialized SPIR-V file, and runs `spirv-val`.
Its verdict deliberately stops before public-observer identity and output
correctness; application admission still owns those joins.

`bench/executors/run-doppler-lifecycle-control.mjs` is the frozen repo-only
Doppler teardown comparator. It runs clean W0, bounded-incumbent P0, and D0
processes, preserving natural native termination instead of masking it.
`bench/executors/adjudicate-doppler-lifecycle-control.mjs` is the correction-only
reader for the immutable q0 traces: it treats SIGABRT and SIGSEGV as distinct
signals within one post-release native-failure property, compares exact output
only across the same-runtime W0/P0 attribution pair, and retains any D0 output
divergence separately. Neither tool can grant performance, ownership,
promotion, or release credit.

`bench/executors/run-doppler-logit-divergence.mjs` is the separately frozen
one-step correctness localizer. It captures the finalized f32 logit transcript
from W0 and D0, verifies identical prompt/model geometry, and distinguishes a
predictor-or-earlier divergence from sampling/token-selection divergence. It
does not decide which provider is correct; that requires an independent logits
oracle.

`bench/executors/run-doppler-logit-divergence-correction.mjs` is the bounded
successor for a capture-mode W0 teardown hang. It runs the exact incumbent
behind the already-proved post-inference cleanup wrapper, requires its prompt,
selected token, and finalized-logit digest to match the persisted W0 transcript,
and compares that trace with the hash-revalidated D0 trace. It changes the
cleanup boundary only; it cannot reinterpret provider correctness.

`bench/executors/run-doppler-kv-divergence.mjs` is the next bounded correctness
localizer. It captures exact used-byte key/value digests for every retained
model layer in P0 and D0, rechecks each lane's predecessor logits, and reports
the first observed differing KV layer or a downstream-of-KV boundary. A layer
digest is a localization coordinate, not an independent correctness oracle.

Repo-only tooling may produce public evidence. The tool itself does not become
a supported package interface.

## Claim boundary

Public measured claims come from `reports/claim-index.json` and referenced
artifacts. Package docs must not hardcode benchmark percentages or promote
diagnostic rows.

Run:

```bash
python3 scripts/check-public-claim-surfaces.py
```

Historical npm names and archived research are not active product surfaces.
