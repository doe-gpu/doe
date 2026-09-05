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
support. It requires a matching native contract version, derived at build time
from the descriptor schema; old addons or libraries fail before allocation.
`gpu-recorded` requires Vulkan support advertised by both the addon and library.
It owns a compiled GPU command buffer, pipeline cache, and descriptor pools.
Buffer identities and extents are checked before submission; mapping or changing
an allocation invalidates the recording. Separate programs own separate native
pipeline state, so ordinary cache replacement cannot invalidate their commands.
Preparation does not submit the program. Native pipeline creation costs are
included in preparation. Replacement currently recompiles GPU command state;
unchanged public resources still share their declared lifetime.

`native-recorded` records host commands and replays them in Zig. The WebGPU
control keeps allocations, pipelines, and bindings resident and encodes each
invocation. These are explicit modes, with no fallback between them.

Every invocation uploads exact-size snapshots of all declared inputs, clears
scratch and output buffers, executes the ordered compute passes, waits for
completion, and performs map/copy/unmap readback. The program never exposes its
GPU resources. Input bytes may change; shapes and source cannot change in place.
Uniform buffers must be inputs. Only buffer bindings in bind group zero are
admitted in this initial contract.

`update(descriptor)` validates and prepares a replacement. Identical resource
keys share allocations and compiled state; changed keys acquire replacements.
Only successful preparation invalidates the prior program. Failed preparation
releases temporary resources and leaves the prior program available. Device
loss requires preparation on a new device. Programs reject overlapping runs,
and program operations serialize error-scope ownership on a shared device.
Applications must keep unrelated device operations outside a program operation.

Cancellation before submission prevents dispatch. Cancellation after submission
drains already-submitted work and discards output; it does not preempt a running
GPU kernel. Cancellation during mapping also discards output and unmaps the
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
The generic fixture loader and existing matrix handle multiple inputs and
strict external observables without a separate performance harness.

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
the strongest controls, actual peak GPU memory and GPU time, independently
reproduced Metal results, a frozen external application portfolio, and external
repeat use. Repository example programs are not externally owned applications.
A reusable
host recording alone does not establish the broader program compiler envisioned
in [`thesis.md`](thesis.md).
