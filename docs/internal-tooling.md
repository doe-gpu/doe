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
