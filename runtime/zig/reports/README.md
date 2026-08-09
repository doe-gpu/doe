# Zig recomposition reports

This directory separates a moving architecture inventory from the frozen
contract baseline used to judge structural changes.

## Architecture snapshot

`architecture/` is generated from the current `src/` tree and Git history:

```bash
python3 tools/generate_architecture_reports.py
python3 tools/generate_architecture_reports.py --check
python3 tools/capture_build_measurements.py
```

The generator refuses to publish a report if the source tree changes during
capture. Reports describe module ownership, resolved imports, cycles,
reachability, AST declarations, normalized declaration hashes, candidate
duplicates, candidate merges/splits, co-change coupling, and non-blocking
distribution observations. `module-decisions.json` gives every production
module one mechanical suggestion and reports review coverage. A decision is
reviewed only when `source-layout.json` binds the decision, rationale, and
reviewer to that module's exact SHA-256. Candidate reports are review inputs,
not automatic merge, split, elevation, or deletion decisions.

`build-measurements.json` is an explicitly invoked diagnostic receipt. It uses
a fresh local and global cache for the clean build, reuses the same cache for
the incremental build, inventories resulting binaries, and binds everything
to the source-tree digest. The architecture report labels an older receipt
`stale-source-mismatch`; it never carries timings across source changes.

## Frozen structural baseline

`recomposition/` records the named Git base, exact source snapshot, policy and
toolchain identity, public declarations reachable from `src/mod.zig`, and
exported shared-library symbols:

```bash
python3 tools/generate_recomposition_baseline.py
python3 tools/verify_recomposition_baseline.py
python3 tools/verify_semantic_fixtures.py
```

Do not regenerate the baseline merely because implementation source changed.
The verifier compares public declarations and exported symbols, then emits one
of three classifications:

- `exact-semantic-equivalence`
- `approved-contract-change`
- `failure`

An approved change requires both `--approve-surface` and
`--approval-reason`. Source hashes, host identity, and artifact hashes remain
receipt context; provenance-only changes do not masquerade as public API
changes.

`recomposition/semantic-fixtures/` is built from the exact named Git snapshot,
not from an unbound local binary. It contains a real command JSON and its
normalized form, stable trace rows and terminal hashes with declared volatile
timings removed, a successful replay receipt, invalid-command and invalid-WGSL
classifications, and exact MSL/HLSL/SPIR-V/CSL outputs. To compare a later
commit, capture it into a separate directory and run:

```bash
python3 tools/capture_semantic_fixtures.py --git-ref <commit> \
  --output-root <candidate-directory>
python3 tools/verify_semantic_fixtures.py \
  --candidate-root <candidate-directory>
```

For a dirty worktree, bind the candidate to the analyzed source-tree digest and
reuse that same fixture set for both semantic and ABI verification:

```bash
python3 tools/capture_semantic_fixtures.py --worktree \
  --output-root <candidate-directory>
python3 tools/verify_semantic_fixtures.py \
  --candidate-root <candidate-directory>
python3 tools/verify_recomposition_baseline.py \
  --candidate-semantic-root <candidate-directory>
```

The structural verifier fails closed when changed source has no worktree-bound
candidate fixture set. It never substitutes frozen baseline symbols or an
unbound `zig-out` library for current ABI evidence. Semantic verification
classifies shared-library metadata and symbol-file changes under the separate
`abi-surface` category.

The fixture manifest records the canonical WGSL IR digest as well as exact
MSL/HLSL/SPIR-V/CSL output bytes. For a frozen source snapshot that predates
the digest executable, the capture installs the current pure observer into the
archived compiler and records the observer source hashes under
`irDigestInstrumentation`; it does not silently attribute that observer to the
old commit.

The baseline is explicitly structural. Any behavior field marked
`not-captured` still requires its workload oracle, trace, receipt, backend, or
performance fixture before the corresponding recomposition checklist item can
be completed.
