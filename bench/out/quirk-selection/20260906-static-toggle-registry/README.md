# Immutable toggle classifications

Toggle lookup now consumes static entries emitted from
`config/quirk-toggle-registry.json` by the existing Zig build. It no longer
parses JSON, allocates persistent strings, initializes a process-wide lock,
or maintains readiness state. Device-profile matching and workaround ranking
remain with their existing runtime owner. This is a focused ownership repair,
not physical backend or application qualification.

## Failure and correction

The old initializer copied names and descriptions, but on copy failure used
the parser's string instead. Unescaped strings can borrow the embedded JSON;
decoded escapes can require parser-owned storage. Publishing those decoded
strings and then freeing the parser arena leaves dangling references.
Earlier initialization failures silently published an empty registry.

`baseline-fault.txt` reproduces both outcomes. The probe substitutes a failing
allocator in a retained copy of the original module; active source is not
modified. Its backing arena retains memory physically for observation, while
the tracking wrapper records every block released by the initializer. The
test checks whether a published string falls inside released parser storage.
The escaped-string fixture is in `failure-options.zig`. The generated table in
that fixture represents the same decoded values.

`after-fault.txt` applies the same public lookup checks to the corrected module.
The static data needs no runtime allocator. Build-time parsing owns temporary
decoded strings until their contents have been serialized into the generated
options. Invalid registry versions, empty names, unknown effects, malformed
fields, and allocation failures reject the build instead of changing runtime
classification. The existing registry schema and public lookup interface are
unchanged; the raw JSON build option remains available for parity checks.

Zig's pinned Options serializer did not emit a slice of struct values correctly;
`focused-tests.txt` preserves that intermediate build failure. A narrow writer
now emits the typed table using Zig's string escaping. It shares the same
parsed configuration across all existing build tiers. Runtime and build-parser
tests use the existing generated test inventory.

## Evidence and limits

- `source-base.txt`, `source.patch`, `baseline-toggle-registry.zig`, and
  `after-toggle-registry.zig` bind the implementation change.
- `failure-probe-tail.zig` owns fault injection and released-storage tracking;
  `baseline-fault-probe.zig` and `after-fault-probe.zig` retain exact compiled
  reproductions. The baseline is expected to fail; the replacement must pass.
- `focused-corrected-tests.txt`, `final-runtime-and-tiers.txt`, and
  `final-lean-verified-tests.txt` own selector, allocation, parser, concurrency,
  runtime, build-tier, and architecture-gate results.
  Earlier logs retain the same implementation before build-parser tests moved
  into the existing `tests/core/` inventory boundary. `schema-gate-initial.txt`
  preserves the rejected direct build-script test registration.
- `lookup-probe.zig` and `build-options.zig` retain the CPU-only lookup fixture.
  `baseline-lookup.txt` and `after-lookup.txt` retain output identity and raw
  first/repeated lookup samples. `metrics.tsv` derives medians; warmup is
  excluded. First lookup is a single observation, not a latency distribution.
- `binary-sizes.txt` and build-time files retain standalone executable size,
  compiler CPU/elapsed time, and maximum RSS. Initial builds use fresh local
  caches and the existing global cache. Files named `cached-build-time` measure
  unchanged-input rebuilds, not source-edit incremental compilation. They do
  not establish whole-repository build improvements.
- `doc-tests.txt` and `schema-gate.txt` own repository checks. `SHA256SUMS`
  binds retained inputs, logs, and diagnostic binaries.

Lookup results and case-insensitive matching retain their existing meaning.
The large cold-path difference removes JSON decoding and initialization;
neither cold lookup nor repeated lookup measures GPU execution or application
latency. No GPU, driver, package release, numerical policy, or synchronization
claim is promoted by these results.

## Reproduce

From `runtime/zig/`, the ordinary test command includes the build-parser tests
through `config/zig-test-inventory.json`:

```bash
zig build test -Dtest-filter=quirk -Doptimize=ReleaseFast --summary all
zig build test -Dtest-filter=quirk -Dlean-verified=true -Doptimize=ReleaseFast --summary all
zig build test dropin dropin-compute dropin-full -Doptimize=ReleaseFast --summary all
```

The Lean-enabled command requires the current extracted proof artifact. From
the repository root, reproduce the original failure and corrected behavior:

```bash
quirk_run="$PWD/bench/out/quirk-selection/20260906-static-toggle-registry"
zig test -O ReleaseSafe --dep build_options \
  -Mroot="$quirk_run/baseline-fault-probe.zig" \
  -Mbuild_options="$quirk_run/failure-options.zig" --test-filter 'allocation fault'
zig test -O ReleaseSafe --dep build_options \
  -Mroot="$quirk_run/after-fault-probe.zig" \
  -Mbuild_options="$quirk_run/failure-options.zig" --test-filter 'allocation fault'
```

The first command deliberately returns failure. Each `fault` record contains
the allocation-failure index, whether lookup returned an entry, whether that
entry references released storage, and the successful allocation count.
The narrow instrumentation replaces `std.heap.page_allocator` with the test
allocator and appends the common test tail to each retained module.

To rebuild a lookup diagnostic, select either retained registry module:

```bash
zig build-exe -O ReleaseFast --dep registry -Mroot="$quirk_run/lookup-probe.zig" \
  --dep build_options -Mregistry="$quirk_run/after-toggle-registry.zig" \
  -Mbuild_options="$quirk_run/build-options.zig" -lc -femit-bin=/tmp/doe-toggle-lookup
/tmp/doe-toggle-lookup
```

Compare the `identity` records before interpreting timings. Samples record
batch index, lookup count, and elapsed nanoseconds; build-time files retain the
exact commands. Configuration identity is retained in the generated options.

Component: Zig build configuration and quirk lookup; architecture documentation

Intent: preserved; enforce existing configuration and ownership contracts

Acceptance evidence: released-storage reproduction, build allocation failures,
generated-value parity, concurrent lookup, runtime/build-tier and Lean-enabled
tests, architecture gates, CPU diagnostics, documentation and schema checks

Boundary effects: none; device discovery, backend execution, public interfaces,
arithmetic, synchronization, and physical qualification remain with their owners
