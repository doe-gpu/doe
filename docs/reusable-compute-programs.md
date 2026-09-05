# Reusable compute programs

`doe-gpu/compute-program` is the explicit fixed-shape interface for repeated
compute. Its declarations contain WGSL source, shader entry points, buffers,
ordered dispatches, bindings, and an output. The schema is
[`compute-program.schema.json`](../config/compute-program.schema.json).
It has no Doppler or browser dependency.
This is the initial declared DoePlan surface. Existing `doe-gpu/plan` capture
lowering remains a separate ingestion contract; no automatic capture is implied.

## Qualified scope

| Tuple or capability | Current boundary |
| --- | --- |
| Linux AMD Vulkan; Node, Bun, Electron main process | Local retained-package correctness and lifecycle evidence; see the [live status](status/reusable-compute-programs.md) |
| Apple Metal | Host recording requires physical requalification; GPU recording is unsupported |
| Windows D3D12 | No qualified package or plan lane in this change |
| Declared buffer compute in bind group zero | Fixed dimensions, ordered dispatches, changing exact-size input bytes |
| Texture plans, dynamic dimensions, automatic arbitrary capture | Outside this descriptor; unsupported declarations fail validation |

The image and heat examples are repository applications. The declared
HoloScript LIF fixture preserves an external shader and CPU twin while adapting
orchestration to a prepared program. These diagnostic cases do not complete the
external-application portfolio or general WebGPU conformance requirements.

## Execution and lifetime

Pass a device and select `gpu-recorded`, `native-recorded`, or `webgpu`. The recorded modes accept
the registered Doe Node addon provider, also usable through Bun's Node addon
support. It requires a native contract version supporting the declaration, derived at
build time from the descriptor schema. Native version 2 accepts descriptor
versions 1 and 2; older libraries reject version 2 before allocation.
`gpu-recorded` requires Vulkan support advertised by both the addon and library.
It owns a compiled GPU command buffer, pipeline cache, and descriptor pools.
Buffer identities and extents are checked before submission; mapping or changing
an allocation invalidates the recording. Separate programs own separate native
pipeline state, so ordinary cache replacement cannot invalidate their commands.
Preparation does not dispatch the program; newly allocated resident state is
zeroed once and drained before preparation returns. Native pipeline creation costs are
included in preparation. Replacement currently recompiles GPU command state;
unchanged public resources still share their declared lifetime.

Optional `gpuTiming: 'timestamp-query'` requires a device created with the
`timestamp-query` feature. The default is `off`, declared in the options schema.
Timed programs retain a query set and resolve buffer, and include timestamp
readback in the existing output mapping. Vulkan GPU recordings retain and
validate the query pool as well as their buffers. Destroying a query invalidates
replay before submission. Updates preserve the selected timing mode.

Receipt schema version 4 retains nullable `gpuTiming`: source, compute-pass scope,
begin/end values, period, counter width, and elapsed nanoseconds. Doe Vulkan
resolves queries to nanoseconds on the GPU, including when another GPU command
consumes the destination. Query-owned scratch storage and cached conversion
pipelines avoid per-resolve CPU retrieval or a queue wait. The conversion uses
the exact physical f32 period, floors the product, and retains its low u64 bits;
the versioned contract is `config/vulkan-timestamp-policy.json`.
Subtraction of normalized integer values preserves precision at large epochs.
Unrepresentable intervals, including a hardware counter wrap that cannot be
reconstructed from normalized values, fail explicitly. The evaluation harness declares
the pinned Deno/wgpu Vulkan tick behavior explicitly and binds its calibration
to a retained physical Vulkan profile and upstream implementation sources.
Nanosecond support must be explicit in the loaded Doe addon and library;
older libraries and other Doe backends fail timed preparation until supported.
The additive `doeNativeComputeProgramTimestampNanoseconds` ABI reports resolved
units; the historical calibration ABI continues to expose physical tick units.
Receipt versions 1, 2, and 3 remain readable. Version 2 Doe timings retain their
historical raw-tick interpretation; they must not be relabeled as nanoseconds.
Pass-end markers use bottom-of-pipeline completion. GPU duration excludes input
upload, scratch clearing, query resolution, and readback. Complete invocation
wall time continues to include those operations and their instrumentation cost.
Requested buffer accounting includes public timing buffers and alignment padding;
it does not measure internal query scratch or peak device allocation.

`native-recorded` records host commands and replays them in Zig. The WebGPU
control keeps allocations, pipelines, and bindings resident and encodes each
invocation. These are explicit modes, with no fallback between them.

Descriptor version 1 preserves invocation-local behavior: upload exact-size
input snapshots, clear scratch and output buffers, execute the ordered passes,
wait, then map/copy/unmap output. Version 2 adds buffer `lifetime`, defaulting to
`invocation`. With `lifetime: 'program'`, inputs may be omitted after their first
initialization, and scratch/output state persists across runs. Newly allocated
resident state starts at zero. Shapes and source cannot change in place; uniform
buffers must be inputs and bindings remain in group zero.

Prepare with `readback: 'none'` to keep output on the GPU. This removes output
copying, mapping, and readback allocation; optional timing still resolves and
maps its own query bytes. `run()` returns `output: null` and `outputHash: null`
when output bytes were not observed. The default remains `readback: 'output'`.
`program.output()` returns an opaque, same-device reference after a successful
run. Pass it as another program's input to copy on the GPU. The consumer holds
a resource lease through completion. Producer runs and updates reject while
leased; closing a producer drains its work and releases its ownership while
an already accepted consumer retains its copy source. New uses reject after
producer execution, update, close, or device loss. References never expose a
raw GPU buffer and copied or forged reference objects are rejected.

Receipt version 4 records program-instance identity, output generation,
input origins, prior resident-state origins, copied bytes, and API submission
count. A byte hash is present only when the bytes are known. Storage input roles
do not imply read-only WGSL: after execution their resident contents carry
program/generation provenance and a null input hash until uploaded again.
Uniform inputs retain known initialization hashes. Provenance identifies the
producing execution; it is not a numerical oracle or an output content hash.
The recorded path uses a preceding input-copy submission when needed; ordinary
WebGPU submits input-copy and compute command buffers together. Both wait for
completion, and receipts expose this distinction.

`update(descriptor)` validates and prepares a replacement. Identical resource
keys share allocations and compiled state; changed keys acquire replacements.
Resident contents survive only when their complete buffer declaration is
unchanged. Changed dimensions, type, role, or lifetime allocate fresh state.
Only successful preparation invalidates the prior program. Failed preparation
releases temporary resources and leaves the prior program available. Device
loss requires preparation on a new device. Programs reject overlapping runs,
and program operations serialize error-scope ownership on a shared device.
Applications must keep unrelated device operations outside a program operation.

Cancellation before submission prevents dispatch. Cancellation after submission
drains already-submitted work and discards output; it does not preempt a running
GPU kernel. A cancelled invocation that may have changed resident state
invalidates that program; continuing from an unobserved partial state requires
explicit preparation. Invocation-local programs remain reusable after drained
cancellation. Cancellation during mapping also discards output and unmaps the
readback buffer. Runs without a cancellation signal do not schedule a separate
event-loop turn solely for cancellation. `close()` prevents further runs,
drains the active invocation, and releases retained state. Use a process boundary for deadlines that must survive
a hung driver. Program allocations are requested buffer bytes, not measured
peak device memory.

## Reproduction

The packaged applications accept ASCII grayscale PGM files:

```bash
node packages/doe-gpu/examples/compute-program.js image input.pgm edges.pgm vulkan
node packages/doe-gpu/examples/compute-program.js heat input.pgm heat.pgm vulkan 32
node packages/doe-gpu/test/integration/test-integration-compute-program.js
```

`examples/compute-programs.js` supplies image denoising/edges and heat diffusion
declarations. Independent CPU oracles live under `bench/oracles/`; neither
hash equality nor the runtime provides the numerical truth.

Evaluation policy, tolerances, dimensions, sample settings, deadline, and CPU
outcome threshold live in
[`compute-program-evaluation.json`](../config/compute-program-evaluation.json).
Use `python3 bench/cli.py program evaluate --help` for the
sequential physical-device matrix. Raw results live under
`bench/out/compute-program/`. Measurements remain diagnostic until independent
fairness and outcome admission; Deno/wgpu and Node/Dawn host differences remain
explicit. Native audit traces run separately from timing samples.
The gate rechecks retained output bytes against the independent CPU oracle,
verifies native dispatch/source/backend-artifact identities, and recomputes rows.
Use `python3 bench/cli.py program verify <matrix>/summary.json`.
The evaluation policy selects the nearest-rank estimator for both the Python
aggregate and JavaScript process statistics. Historical comparison callers keep
their existing estimator. Raw samples, provider binaries, evaluation policy,
and implementation sources are retained with each new matrix. Use its retained
policy with `program verify --policy` when the repository policy has changed.
New matrices retain their resolved `policy.json`, including copied external
fixtures. Pass that policy to verification so the matrix remains independent of
the original fixture location.
Evaluation policy schema version 4 declares `gpuTiming` and
`dawnTimestampQuantization` (`default` or `disabled`); historical policies leave
timing off. Run schema version 3 records GPU duration statistics. The gate
recomputes durations from raw counter values and calibration, validates timing
buffer work, and recomputes GPU percentiles. Historical receipts and older
run schemas remain readable. Quantized timestamps and different resolve paths
must be accounted for before comparing GPU timing or instrumentation costs.
Timed Vulkan policies also select `vulkanDeviceIndex`, `wgpuTimestampUnits`,
`timestampSources`, and `timestampPeriodRelativeTolerance`. The tolerance only
accounts for decimal rounding in `vulkaninfo` JSON. Physical device selection
initializes Doe's timestamp period even when the runtime's separate diagnostic
query pool has never been created. Missing calibration, a different adapter,
an ambiguous compute-queue counter width, or a period mismatch fails the gate.
New run artifacts retain the loaded native addon and physical clock profile.
Preparation break-even uses mean preparation cost and median
invocation savings; no break-even is asserted when invocation does not improve.

## External declared simulation

Prepare HoloScript through the existing external reproduction front door, then
freeze the declared simulation from the pinned Git objects:

```bash
python3 bench/cli.py program prepare-lif \
  --upstream=bench/out/external-projects/holoscript-snn-webgpu/upstream \
  --output=bench/out/compute-program/20260905-holoscript-lif-final-fixture \
  --case=large-65536x10
```

The destination must be new. The fixture retains source, license, shader,
TypeScript compiler, CPU oracle, input bytes, expected outputs, and numerical
requirements. Compilation uses the upstream package's pinned TypeScript
dependency. The membrane comparison requires both original tolerances; final
spikes must match exactly. A packing pass retains both observables in the public
program's output. Every provider executes that same pass and the same batched
ticks. This is an explicit orchestration adaptation; the unchanged application
compatibility receipts remain separate.

Use `program evaluate --policy config/compute-program-external-evaluation.json`
with the usual physical backend and executable arguments. That policy binds the
fixture hash. Alternative frozen cases require an explicit policy referencing
their generated fixture and hash. Unknown applications without a fixture fail.
The profile includes resident simulation acceptance; inspect its current
[numerical qualification state](status/reusable-compute-programs.md) before
interpreting a failed run. A failed oracle stops the matrix before timing claims.
The generic fixture loader and existing matrix handle multiple inputs and
strict external observables without a separate performance harness.

For a continuously advancing simulation, pass `--sequence-runs` to the same
`program prepare-lif` command. Freeze enough oracle states for cold execution,
every warmup, and every timed run; audits also require the post-cancellation
invocation. The sequence fixture uses program-lifetime buffers and uploads
inputs only on its first invocation. Its unchanged upstream CPU twin advances
through the same batches of ticks before any GPU run. Ordinary Doe, Dawn, and
wgpu receive the same resident declarations and input schedule as prepared Doe.
This is a distinct workload from repeatedly resetting the simulation.

## Retained package qualification

Use `python3 bench/cli.py program qualify-package --help` to retain
package archives once, install those exact archives with install scripts enabled
in fresh directories, and exercise Node, Bun, and Electron. That harness runs
the ordinary provider, repeated lifecycle, and plan regressions from the
installed package. It grants neither registry publication nor release admission.

## Migration and evidence boundaries

This is an additive contract. Existing plan/capture and Doppler Program Bundle
formats keep their meanings; they are not automatically executable programs.
The preparation counters and run receipt schemas accompany the descriptor.
No runtime checks have been removed by a proof claim.

Evaluation policy schema version 2 adds `preparedExecution` and
`percentileMethod`. Run receipts add the `gpu-recorded` execution value. Native
identity traces add `compute_program_prepared` and `compute_program_submitted`
events binding the retained recording, dispatch count, and submission index.
GPU replay audits require preparation once and matching subsequent submissions;
re-encoding dispatches on every invocation does not satisfy that contract.
`program verify-native` validates the shared native replay contract and SPIR-V
artifacts. Native object-creation records now have a schema alongside dispatch
and submission records. Its dispatch count describes encoded records; replay
submission events carry the repeated work count.
Compute pipeline release now honors retained references during program updates.

Evaluation policy schema version 3 adds hash-bound `fixtures`. Evaluation run
schema version 2 replaces the single `inputPath` with `inputPaths` and records
the optional retained fixture. Historical policy and run versions remain
readable. Public compute-program descriptors and run receipts keep their
existing versions. Fixture schema, provenance, complete oracle coverage, and
input extents are blocking validation requirements.

Fixture schema version 2 adds an explicit `sequence` with `inputs:
'initialize-once'` and ordered, hash-bound expected states. This version requires
program-lifetime buffers; mixed lifetimes and varying inputs require a future
sequence contract. Evaluation run schema version 4 retains `warmups`,
`lifecycleRuns`, and `failedRun` alongside cold and timed samples. Numerical
failures retain the actual output and receipt. The gate checks every successful
invocation's oracle, resource work, and preceding state generation, including
warmups and cancellation recovery. Timed percentiles still exclude those
untimed records. Earlier fixture and evaluation versions keep their reset
semantics and remain readable; public receipt version 4 is unchanged.

Vulkan cache insertion failures now restore active compute and descriptor
ownership. Rebuild the native library to receive the correction; cache keys,
public descriptors, and receipt fields are unchanged.

Vulkan `clearBuffer` now records a GPU fill at submission, with transfer
dependencies, instead of performing a mapped host clear during encoding.
Buffer copies also use ordered GPU commands, including copy-only submissions
after an asynchronous compute submission. Host-visible memory does not permit
a CPU copy to race an unfinished GPU producer. The unchanged UMAP workload
and the separate-submission regression exercise this boundary.
JavaScript buffer copies and clears invalidate host shadows at submission as
well as encoding; partial uploads cannot validate stale untouched bytes.
Existing command field layouts
remain unchanged; programs must be recorded again after updating the library.
Replay dispatches share one conservative compute barrier. Its source and
destination scopes already cover the former identical dependency barrier;
the shared helper clears the covered tracking state. Indirect dispatches retain
their separate argument-read dependency before that bookkeeping is cleared.
This removes duplicate barriers without claiming proof-driven elimination.

Vulkan MAP_READ allocations now use
[`vulkan-buffer-memory-policy.json`](../config/vulkan-buffer-memory-policy.json).
The policy prefers CPU-cached memory while requiring host visibility and
coherence. If no supported cached coherent type exists, selection retains the
required properties. This changes allocation policy for ordinary WebGPU and
prepared programs alike. GPU copies, completion waits, mapping, and numerical
checks still execute. The performance effect depends on physical memory types;
see the [Vulkan property contract](https://docs.vulkan.org/refpages/latest/refpages/source/VkMemoryPropertyFlagBits.html).

Remaining strategy acceptance includes a meaningful application advantage over
the strongest controls, actual peak GPU memory, independently
reproduced Metal results, a frozen external application portfolio, and external
repeat use. Repository example programs are not externally owned applications.
A reusable
host recording alone does not establish the broader program compiler envisioned
in [`thesis.md`](thesis.md).
