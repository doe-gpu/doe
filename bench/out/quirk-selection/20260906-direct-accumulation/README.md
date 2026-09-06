# Direct quirk accumulation

The runtime selector now retains each command bucket's best candidate and match
count directly. Both public builders share accumulation and finalization.
Scope membership, scoring, stable first-input ties, profile filtering, action
identity, proof blocking, command aliases, borrowed payloads, and the allocator
and error interfaces retain their existing contracts. No schema or runtime
policy fields change.

## Diagnosis and correction

`baseline-confirmed-tests.txt` reproduces allocation-failure cleanup gaps in
both original builders. The failing allocator allows an initial allocation,
then rejects a later bucket allocation. The test checks the builder's own frees;
an outer test arena subsequently reclaims stranded storage without hiding the
accounting failure. The other characterization tests pass on the original
implementation. Earlier compilation and stale-review failures remain in the
intermediate logs; they are not the accepted reproduction.

The replacement removes temporary match lists and their sorts. It updates a
winner only on strict improvement, retaining the stable sort's first input when
score, proof priority, explicit priority, and identifier are all equal. Bucket
fields define the compile-time accumulation walk. The public allocator error
set remains explicit even though selection no longer needs that allocator.
`finalizeBucket` still owns the existing proof and action decisions, preserving
the Lean runtime-symbol mapping.

## Evidence

- `source-base.txt`, `source.patch`, `baseline-runtime.zig`, and
  `after-runtime.zig` bind the original revision and changed selector.
- `baseline-confirmed-tests.txt` owns the original failure and characterization.
- `after-focused-tests.txt`, `runtime-tests.txt`, and `lean-verified-tests.txt`
  own the corrected test results, including the runtime architecture gates.
- `probe.zig` and `build-options.zig` retain the exact diagnostic fixture and
  build inputs. `baseline-probe.txt` and `after-probe.txt` own raw decision
  digests, timed batches, allocator accounting, and cleanup checks.
- `metrics.tsv` contains derived preparation medians and allocation totals.
  `parity-check.txt` records equality of both builder decision digests and
  balanced successful-run allocation accounting.
- `binary-sizes.txt` owns executable section sizes. Build-time files retain
  process CPU, elapsed time, and maximum RSS. Initial probe builds use fresh
  local caches with the existing global cache; the files named `incremental`
  measure cached rebuilds with unchanged inputs. They are not measurements of
  a fully clean repository build or source-edit incremental compilation.
- `doc-tests.txt` and `schema-gate.txt` own documentation and schema checks.
- `SHA256SUMS` binds the retained source, binaries, reports, and logs.

## Interpretation

This is a CPU-only, instrumented preparation diagnostic. The declared profile
is a matching fixture; no Vulkan, Metal, or D3D12 execution occurs. The complete
measured operation is context preparation plus cleanup. Both variants use the
same fixture, prefix decision checks, warmup, batch counts, allocator wrapper,
and output consumption. Warmup is excluded. Matching decisions cover complete
bucket values, including selected action and match count.

The large observed reduction requires this scope check: the removed work is
allocation and sorting, while the prepared decisions remain equal. Allocator
accounting contributes measurement overhead, and timings are local samples,
not a release comparison. The fixture does not exercise first-use toggle
registry initialization, which has a separate allocation lifecycle. This work
does not establish GPU speed, an application deadline crossing, package
qualification, physical portability, or an incumbent advantage.

## Reproduction

Run the focused selector tests and the ordinary runtime suite from
`runtime/zig/`:

```bash
zig build test -Dtest-filter=quirk -Doptimize=ReleaseFast --summary all
zig build test -Dtest-filter=quirk -Dlean-verified=true -Doptimize=ReleaseFast --summary all
zig build test -Doptimize=ReleaseFast --summary all
```

The Lean-enabled command requires the current extracted proof artifact under
the existing build contract. To reproduce the standalone diagnostic without
changing active source, run from the repository root:

```bash
quirk_run="$PWD/bench/out/quirk-selection/20260906-direct-accumulation"
quirk_snapshot="$(mktemp -d /tmp/doe-quirk-probe.XXXXXX)"
cp -a runtime/zig/src "$quirk_snapshot/src"
cp "$quirk_run/probe.zig" "$quirk_snapshot/main.zig"
cp "$quirk_run/build-options.zig" "$quirk_snapshot/build-options.zig"
cp "$quirk_run/baseline-runtime.zig" "$quirk_snapshot/src/quirk/runtime.zig"
zig build-exe -O ReleaseFast --dep build_options \
  -Mroot="$quirk_snapshot/main.zig" -Mbuild_options="$quirk_snapshot/build-options.zig" \
  -lc -femit-bin="$quirk_snapshot/baseline" --cache-dir "$quirk_snapshot/baseline-cache"
"$quirk_snapshot/baseline" 2> "$quirk_snapshot/baseline.txt"
cp "$quirk_run/after-runtime.zig" "$quirk_snapshot/src/quirk/runtime.zig"
zig build-exe -O ReleaseFast --dep build_options \
  -Mroot="$quirk_snapshot/main.zig" -Mbuild_options="$quirk_snapshot/build-options.zig" \
  -lc -femit-bin="$quirk_snapshot/after" --cache-dir "$quirk_snapshot/after-cache"
"$quirk_snapshot/after" 2> "$quirk_snapshot/after.txt"
```

Use the revision bound by this change for transitive source, the retained
toolchain version in `environment.txt`, and compare the `decisions` records
before interpreting the `sample` records. Timing values need not reproduce
exactly. Each sample records profile filtering, batch index, preparation count,
elapsed nanoseconds, allocation count, and requested allocation bytes. Cleanup
records retain total allocated bytes, freed bytes, and the consumed checksum.

Component: Zig runtime quirk selection; strategy documentation

Intent: preserved; proposed user outcomes clarify existing expansion conditions

Acceptance evidence: retained failure, stable-sort characterization, decision
digests, runtime and Lean-enabled tests, source-layout/import gates, diagnostic
cost and code-size measurements, documentation and schema checks

Boundary effects: none; backend commands, arithmetic, synchronization, policy,
public API shapes, and qualification eligibility remain unchanged
