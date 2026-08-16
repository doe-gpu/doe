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

The current vGPU diagnostic completes its required `I0`, `I1`, `W0`, and `D0`
execution matrix, including application-level replay and its retained
post-destroy lifecycle regression. DoeRuntime and the governed incumbent pass
the same exercised lifecycle outcome, so the reviewed decision assigns no
runtime-ownership credit and keeps vGPU diagnostic. A complete lane matrix is
evidence; it is not a promotion when the material outcome fails.

The HoloScript tropical-SpMV diagnostic also completes its required `I0`,
`I1`, `W0`, and `D0` matrix. All lanes pass the four exact frozen topologies,
and governed Dawn and Doe reproduce their hash-bound application evidence.
Because W0 exposes no defect, conditional `P0` is unnecessary; because D0 does
not exceed W0, the reviewed decision assigns no runtime-ownership credit and
keeps HoloScript diagnostic.

The subsequent
[HoloScript public process-observer admission](../reports/ecosystem/holoscript-snn-webgpu/holoscript-doeproof-process-observer-amd-vulkan-2026-08-16-diagnostic.json)
replaces repository-only command evidence with the exported
`doe-gpu/node-webgpu-process` observation contract. The unobserved control and
both observed provider lanes pass the unchanged application oracle; Dawn and
Doe share normalized command and mapped-output identities, and Doe replays
exactly. This admits the public evidence surface while preserving the terminal
no-ownership and no-promotion decision.

The separately reviewed
[HoloScript LIF determinism result](../reports/ecosystem/holoscript-snn-webgpu/holoscript-lif-determinism-2026-08-15-diagnostic.json)
extends that conclusion to the upstream neuron simulation. Across three frozen
input cases, all `I0`, `I1`, `W0`, and `D0` processes pass the CPU membrane
tolerances and exact spike oracle. `W0` and `D0` replay exactly, and both
providers produce identical GPU membrane and spike bytes on the declared AMD
Vulkan adapter. The governed incumbent therefore closes the outcome without a
patch; the workload is retained as a diagnostic regression with no ownership
or promotion credit.

The current-runtime
[HoloScript Electron main-process successor](../reports/ecosystem/holoscript-snn-webgpu/holoscript-electron-main-process-p0-current-runtime-2026-08-16-diagnostic.json)
exercises a distinct runtime-host boundary without reopening that Node decision.
The packaged
incumbent fails at Electron's external-`ArrayBuffer` restriction while Doe
passes the unchanged four-topology oracle. A source-built, two-file
node-webgpu/Dawn mapped-buffer ownership patch was freshly reconstructed and
also passes exactly and replays deterministically. Because that bounded
incumbent correction still closes the gap,
the Electron tuple likewise receives no DoeRuntime ownership or promotion
credit and remains a retained regression plus an upstreamable patch.

The reviewed World Labs `consumer-execution-oracles` harness subsumes its
older proposed `consumer-shader-compiles` lane. The measured workload already
runs all six representative compilation assertions and the invalid-shader
diagnostic oracle, then adds unchanged compute, render, synchronization,
readback, and independent output checks. The compile-only proposal is retired
because it would prove strictly less on the same pinned application source.

The later
[World Labs runtime-ownership diagnostic](../reports/ecosystem/world-lab-runtime-webgpu/world-lab-runtime-ownership-amd-vulkan-2026-08-16-diagnostic.json)
closes the evidence gaps and reaches a terminal decision. A transparent,
identical provider layer around Dawn and Doe records dynamic WGSL attempts,
compute dispatches, render draws, submissions, and exact mapped readbacks.
All 12 I0/I1/W0/D0 processes pass; W0 and D0 reproduce the same complete
semantic evidence and exact output identities. The governed incumbent therefore
closes the frozen outcome without a patch. World Labs remains a permanent
compiler/runtime regression and supplies no runtime-ownership or promotion
credit.

The subsequent
[public observer admission diagnostic](../reports/ecosystem/world-lab-runtime-webgpu/world-lab-package-observer-admission-amd-vulkan-2026-08-16-diagnostic.json)
replaces that application-specific proxy with `doe-gpu/observe`. Pinned Dawn
and Doe again pass all 16 assertions and reproduce identical public command
shape and mapped output identities. This admits the package evidence primitive
for diagnostic real-application use; it does not reopen the terminal World
Labs ownership decision or add performance, promotion, or release credit.

The later
[source-bound compilation diagnostic](../reports/ecosystem/world-lab-runtime-webgpu/world-lab-package-compilation-observer-amd-vulkan-2026-08-16-diagnostic.json)
closes the public observer's negative-path evidence gap. Immediate
compilation-info checkpoints preserve all eight upstream validation calls,
including the compile-only worker. Dawn and Doe each bind exactly one error to
the same invalid runtime shader source while retaining their distinct message
and location detail. This is diagnostic evidence and does not alter the
terminal runtime-ownership result.

The wgsl-fns independent-correction diagnostic executes all five required
lanes. The pinned incumbent crashes, but DoeRuntime and the independently
prepared `webgpu@0.3.10` plus no-isolation control both complete the frozen
compilation corpus, exact `smoothStep` dispatch/readback, and deterministic
replay. The cheaper wrapper-level correction closes the exercised outcome, so
the reviewed decision assigns no runtime-ownership credit and keeps wgsl-fns
diagnostic.

The later
[wgsl-fns public compilation-observer admission](../reports/ecosystem/wgsl-fns/wgsl-fns-public-compilation-observer-amd-vulkan-2026-08-16-diagnostic.json)
binds the unchanged semantic workload's `getCompilationInfo()` call to its
exact observed shader module. Dawn and Doe return identical empty diagnostics
for the valid shader, then reproduce the same normalized command and exact
mapped-output identities. This is public DoeProof failure-localization
infrastructure, not a new DoeRuntime ownership or promotion result.

The cpp-ml MNIST independent-correction diagnostic also reaches a terminal
ownership decision. Ambient Dawn, pinned Dawn, governed Dawn, and DoeRuntime
each pass the same staged independent oracle; governed Dawn and DoeRuntime
also reproduce their semantic evidence hashes. The owned runtime therefore
receives no ownership credit for this frozen application outcome, while the
passing graph remains a retained cross-provider correctness regression.

The correction-only
[cpp-ml public DoeProof CLI diagnostic](../reports/ecosystem/electronicarts-cpp-ml-intro/cpp-ml-mnist-doeproof-cli-filesystem-amd-vulkan-2026-08-16-diagnostic.json)
then runs governed Dawn and Doe through the package `run`, `verify`, `inspect`,
`compare`, and `replay` surface under Node read-only permissions. It fixes a
native truncation that omitted compute bindings 16 and 17, passes twice with
exact cross-provider output, and authorizes this public evidence boundary. It
does not reopen the terminal ownership decision or grant performance,
promotion, release, or OS dependency-closure credit.

The subsequent
[cpp-ml clean-install DoeProof diagnostic](../reports/ecosystem/electronicarts-cpp-ml-intro/cpp-ml-mnist-doeproof-cli-clean-install-amd-vulkan-2026-08-16-diagnostic.json)
packs the wrapper, Linux x64 platform payload, pinned incumbent, and PNG
dependency, installs them with lifecycle scripts disabled, copies the exact
pinned application, and repeats the full command chain from two independent
installation roots. Both providers and both replays pass the same oracle. The
first frozen attempt also exposed and permanently records an installed-package
resolution bug: package execution must prefer its installed platform payload
before probing development-workspace paths. This closes the local-tarball
application installation gap for Node/Linux x64/AMD Vulkan only; it does not
promote cpp-ml or change its ownership decision.

The final distinct cpp-ml ownership hypothesis is now closed by the
[persistent-performance-control diagnostic](../reports/ecosystem/electronicarts-cpp-ml-intro/cpp-ml-mnist-persistent-performance-control-amd-vulkan-2026-08-16-diagnostic.json).
Pinned Dawn and Doe each pass 30 cold processes and 100 warm exact-oracle
suites with one shared semantic output identity. Doe is slower at every frozen
percentile: 1.391x–1.521x on cold execution and 1.720x–1.768x on warm suites.
The result rejects both the 1.10x material-win gate and the 1.05x regression
ceiling. cpp-ml therefore remains a clean-installed DoeProof and permanent
compiler/runtime regression workload, not a DoeRuntime-owned application or a
promotion candidate.

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
