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

The shipped Node example at
[`packages/doe-gpu/examples/live-simulation.js`](../packages/doe-gpu/examples/live-simulation.js)
provides a terminal workspace for resident heat diffusion. Generate editable
WGSL with `node packages/doe-gpu/examples/live-simulation.js --write-shader heat.wgsl`,
then start the workspace with `--backend vulkan --execution gpu-recorded`.
Enter `edit heat.wgsl` after changing the file, or `rate 0.1` to change the next
iteration's parameter. `format new-format` proposes an explicitly different
state interpretation; `approve id` and `decline id` resolve its reset decision.
`cancel`, `save path.wgsl`, `status`, and `quit` manage the workspace.

Candidates run in a separate bounded process against the unchanged independent
heat reference and configured adversarial inputs while the old simulation
continues. The active process pauses at an iteration boundary for assessment
and activation; destructive edits stay paused for the exact reset decision.
Activation prepares the replacement on the original device and reports its
pause. The compiler is not made asynchronous by this example. Numerical failure
in an active frame stops the workspace because already modified GPU state is
not assumed recoverable. Cancellation closes candidate processes or waits for
bounded active submissions; it does not preempt a kernel.

Migration: this is an additive Node example using the existing program API.
`config/live-simulation.json` owns its dimensions, reference tolerances, inputs,
and process limits, with matching shipped assets. Heap limits constrain the
JavaScript heap; reported worker RSS is host process memory, not GPU memory.
The application fixes its GPU buffer extents and has no automatic backend
fallback. Physical Metal and other hosts require separate application testing.

Pass a device and select `gpu-recorded`, `native-recorded`, or `webgpu`. The recorded modes accept
the registered Doe Node addon provider, also usable through Bun's Node addon
support. It requires a native contract version supporting the declaration, derived at
build time from the schema's `nativeContractVersion` definition. Native version
2 accepts descriptor versions 1, 2, and 3; version 3's additional state-update
policy runs in the package. Older libraries reject resident declarations before
allocation. The native command ABI has not changed.
`gpu-recorded` requires Vulkan support advertised by both the addon and library.
It owns a compiled GPU command buffer, retained pipelines, and descriptor pools.
Buffer identities and extents are checked before submission; mapping or changing
an allocation invalidates the recording. Programs own private descriptor state;
ordinary cache replacement cannot invalidate their commands.
Preparation does not dispatch the program; newly allocated resident state is
zeroed once and drained before preparation returns. Native pipeline creation costs are
included in preparation. Replacement records new GPU commands while retaining
unchanged public resources and compatible live native compute pipelines.

[`vulkan-compute-pipeline-policy.json`](../config/vulkan-compute-pipeline-policy.json)
selects `share-live-exact` at build time. The device registry checks complete
SPIR-V words, entry point, ordered descriptor layout definitions, and effective
required subgroup size before sharing a pipeline. Resource handles, buffer
extents, and dispatch counts remain private recording inputs; changing them
requires a new recording but can preserve its pipeline. Changed shader code,
layout, entry point, or subgroup requirement creates another pipeline. Another
device has another registry. The last active, cached, retired, or prepared owner
releases the pipeline; the registry does not retain unused pipeline history.
The shared owner also retains its creation layout for Vulkan implementations
without maintenance4 lifetime guarantees.
The `private` policy builds independent pipelines for controlled comparisons.
Local active and cached pipeline selection applies the same exact identity
checks. Hashes locate candidates; collisions retain distinct owning entries,
including pipelines already referenced by recorded commands. Effective subgroup
policy is resolved before lookup. Layout reuse also checks the layout definition.
Descriptor caches compare complete binding declarations, native resource handles,
allocation generations, buffer extents, and image layouts. New native resources
receive distinct generations even if a driver recycles a handle; image views
also require their original parent image. Collisions retain independent pools,
and failed preparation restores the previous descriptor owner. Buffer aliases
resolve their final allocation before descriptors capture handles. Prepared
programs validate retained resources before submission. These are internal
correctness checks; public descriptor, native ABI, and receipt versions remain
unchanged.
Program close releases owned bind groups, layouts, pipelines, shaders, and
buffers when their last program or output lease ends. Buffer destruction drains
submitted work and releases backing storage even while native handles remain
referenced. Ordinary Vulkan caches discard descriptors for destroyed buffers
while retaining compatible pipelines and unrelated live bindings. Device
teardown releases its queue reference; native resources retain the device they
need for subsequent cleanup. These lifecycle corrections preserve declaration,
options, and receipt schema versions. Checkpoint DRM allocation and residency
records in the [live status](status/reusable-compute-programs.md) are resource
retention diagnostics, not peak-memory or driver-loss evidence.
Linux package qualification runs the same native resource-retention regression
in Node, Bun, and Electron. It retains closed programs while checking DRM
allocation totals and device teardown, including timestamp scratch storage and
labeled queues. This adds acceptance evidence within qualification version 2;
it does not change its schema or establish another platform's resource behavior.
Native compute command recording owns pipelines, bind groups, indirect buffers,
copy resources, and query-resolution destinations until command buffer release.
Finishing transfers those references from the encoder; abandoning the encoder
releases them. Compute passes pin their encoder, and encoders and command
buffers retain their cleanup device. Fused compute/copy constructors follow the
same ownership rule, including failed preparation. This corrects caller-release
lifetimes without changing public declarations or receipts. Explicit resource
destruction still invalidates its backing storage. General JavaScript garbage
collection and rendering dependency ownership require separate qualification.
Native-direct JavaScript submission consumes command buffers and rejects reused
or duplicate buffers before submission. Finished encoders and ended compute
passes release their native handles. Native-direct mapped ranges use host-owned
ArrayBuffers on every host; writable mappings copy back before unmap, read
mappings do not, and unmap or destruction detaches the returned range. This
replaces external ArrayBuffers that Electron cannot create. The existing
mapped-range timing includes the host copy, so older native-direct measurements
do not establish the same readback cost. Package qualification checks command
consumption, mapped-at-creation writes, write remapping, and detachment in each
controlled host. These corrections add no public fields or fallback mode.
Compatible descriptor layouts permit sharing the compiled pipeline while
keeping descriptor sets independent, as specified by
[Vulkan layout compatibility](https://docs.vulkan.org/spec/latest/chapters/descriptorsets.html#descriptorsets-compatibility).

Optional `gpuTiming: 'timestamp-query'` requires a device created with the
`timestamp-query` feature. The default is `off`, declared in the options schema.
Timed programs retain a query set and resolve buffer, and include timestamp
readback in the existing output mapping. Vulkan GPU recordings retain and
validate the query pool as well as their buffers. Destroying a query invalidates
replay before submission. Updates preserve the selected timing mode.

Receipt schema version 5 requests queue completion and readback mapping together
and waits for both before consuming bytes. `completionMode` is `queue-and-map`
when output or timestamps need mapping, and `queue-only` otherwise. Failure
waits for both operations to settle and unmaps any successfully mapped buffer
before resource leases can be released. Cancellation checks still discard output
and invalidate submitted resident state. This scheduling applies to every
provider using the declared program interface.

Version 5 `timingMs.submitWait` includes submission and concurrent mapping;
`readback` includes byte copying, timestamp decoding, and unmapping. Versions
1–4 retain their sequential queue-then-map timing meaning. Evaluation rejects
mixed completion schedules, and historical receipts must not be relabeled.
Complete useful-operation wall time remains the application metric. The
[WebGPU promise ordering contract](https://gpuweb.github.io/gpuweb/#promise-ordering)
does not permit assuming that either independently awaited operation completes
the other; both remain explicit.

Receipt schema version 5 retains nullable `gpuTiming`: source, compute-pass scope,
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

### State-update approval migration

Descriptor versions 1 and 2 preserve their previous update behavior. Version 3
requires a nonempty, application-owned `stateFormat` on program-lifetime buffers
and rejects it on invocation-lifetime buffers. Changing a format explicitly
changes state interpretation even when the byte size is identical. Keeping a
format declares compatible interpretation; the runtime does not infer semantic
equivalence of arbitrary shader edits.

`assessUpdate(next)` runs while the program is idle and returns an immutable
assessment with retained, replaced, discarded, and created resident state.
Replaced entries include both declarations. Its schema is `updateAssessment`
under the descriptor schema. Assessment causes no allocation or GPU work beyond
host metadata. If either the old or proposed descriptor is version 3, replacing
or discarding resident buffers requires
`update(next, { assessment, reset: 'approve' })`. The default is `preserve`.
Downgrading a descriptor cannot bypass this check. Compatible edits can call
`update(next)` directly.

Approval is bound to the exact immutable proposed descriptor, original program
instance, and invocation revision. Starting another accepted run expires the
assessment, even if that run is subsequently cancelled. An invalid input rejected
before a run starts does not expire it. Serialized or copied assessments carry
information without authority. A rejected reset throws `DOE_PROGRAM_RESET_REQUIRED`
with its assessment; a foreign, copied, or stale approval throws
`DOE_PROGRAM_STALE_ASSESSMENT`. No replacement resource is acquired before these
checks. Failed replacement preparation preserves old state; its assessment can
be retried while that state remains at the assessed revision. Success closes the
old program and releases its resources only after replacement preparation.

Updates still require an idle program and own its device error scopes during
preparation. This contract does not imply background pipeline compilation or
kernel preemption.

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

Qualification artifact version 2 stores archive and evidence filenames relative
to its own directory. Move that directory intact to reproduce elsewhere;
recorded hashes do not change. The loader rejects escaping references and checks
all retained artifacts. Version 1 preserves its original path semantics.

Pass that retained summary to the existing evaluator with
`program evaluate --package-qualification <summary.json>` instead of
`--native-library`. The evaluator installs the same wrapper and platform
archives offline with install scripts enabled, loads the installed program
executor for every provider, and loads Doe's native library from that
installation. The gate checks archive hashes, every packaged file, the
qualification's host/library agreement, and the actual loaded library. Changed
package bytes and mixed package sources fail before comparisons are admitted.
Installed files, archives, install logs, and execution artifacts remain in the
evaluation directory.
The evaluator also retains the complete qualification inputs under
`package-inputs/`, so a version 2 qualification remains usable after its original
directory is unavailable.
The Dawn control is pinned in `bench/package.json` and `bench/package-lock.json`;
`npm ci --prefix bench` installs that declared comparator dependency.

Evaluation artifact version 5 adds `packageQualification` and `packageRoot`.
Both are null for workspace-library evaluation; package evaluation binds the
qualification hash and the installed wrapper path. Earlier evaluation versions
retain their meanings and cannot carry these fields. This changes repository
evaluation artifacts, not public compute-program descriptors or run receipts.

## Migration and evidence boundaries

Evaluation policy version 5 requires an explicit `gpuActivity` value. `off`
preserves execution without host observations. `reject-observed-linux-drm`
requires Vulkan on a Linux host with a single PCI DRM render device. The generic
policy explicitly disables this platform-specific check; the AMD external
policy enables it. Earlier policy versions retain their original behavior.
Timestamp settings remain independent, with their existing grouped contract.

The Python evaluator brackets each measured child process with raw DRM fdinfo
snapshots outside the child's timing interval. The versioned
`*.gpu-activity.json` sidecar binds these observations to the evaluation hash,
policy hash, and physical device. Shared file descriptors are deduplicated by
DRM client identity. Positive foreign engine activity, disappeared clients,
missing counters, and counter regressions reject timing admission. Matrix
verification recomputes admission from the raw sidecar and requires every run
to use the matrix's policy. Numerical audit execution is unchanged.

The observer covers readable clients at process boundaries. It records unreadable
processes and cannot observe clients that start and exit between snapshots.
Passing this check does not prove exclusive access or replace an isolated
performance host. Rejected runs retain their numerical outputs and observations;
they cannot produce comparison rows. Counter identity and units follow the
[Linux DRM usage-statistics contract](https://docs.kernel.org/gpu/drm-usage-stats.html).
No public program descriptor, receipt, or package ABI changes with this policy.

The Vulkan pipeline cache now treats precomputed hashes as lookup hints, not
identity proofs. Rebuild the native library to apply this correction; public
descriptor, receipt, and ABI fields are unchanged. Earlier hash-only failures
remain retained independently of corrected physical execution.

The Vulkan compute pipeline policy is an additive build contract. Existing
package descriptors, public receipts, and native ABI versions keep their
meanings; rebuild the native library to apply the policy. Native lifecycle
regressions check shared Vulkan handles, private descriptor pools, changed code
and layouts, allocation failures, creator teardown, and device isolation with
actual dispatch/readback. Package resource counters continue to describe public
resource acquisition and must not be interpreted as native pipeline counts.

Vulkan buffer publication reserves registry capacity before native allocation
and initialization. Failed publication cannot leave a queued clear without a
resource owner. Resizing drains prior work and retains the old allocation until
its replacement is created. This ownership correction changes no descriptor,
receipt, or ABI fields; earlier failure artifacts remain historical evidence.

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
