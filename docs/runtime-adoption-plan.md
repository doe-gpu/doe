# Doe runtime adoption plan

Status: code-aligned portfolio alternative  
Strategy unit: Doe alone  
Repository owner: Doe

## Outcome

Doe becomes a controllable WebGPU compiler and runtime that real applications
choose for a repeatable material advantage. Its product includes
source-preserving WGSL lowering, typed intermediate representations, explicit
provider and backend selection, native Metal, Vulkan, and D3D12 execution,
resource and command lifecycle, diagnostics, replay, and embedding through
JavaScript and native surfaces.

DoeProof supplies the comparison and evidence discipline. It does not satisfy
the strategy test when the application keeps another runtime.

## Decisive proof

An unrelated WebGPU application voluntarily adopts Doe under an unchanged
application contract and receives a repeatable material advantage.

For this plan, "unchanged application" means:

- the same application revision, workload, inputs, commands, shader semantics,
  output oracle, and acceptance thresholds run in both comparison arms;
- only the declared provider-loading or build seam changes;
- both arms perform structurally equivalent GPU work and expose equivalent
  lifecycle phases;
- no hidden fallback, skipped work, narrower timing scope, or application fork
  creates the apparent advantage.

The adopter must keep Doe for another consequential application, runtime,
driver, adapter, or hardware change. A one-off benchmark win is insufficient.

## Independence boundary

- Doppler may supply a workload but cannot supply Doe adoption evidence.
- Reploid and Poolday are not required.
- Fawn is not required for the independent runtime strategy.
- DoeProof may qualify an incumbent without opening DoeRuntime adoption.
- Ordinary browser use of `navigator.gpu` remains browser-owned unless a
  controlled browser build actually installs Doe beneath that seam.
- Node, Bun, Deno, Electron main-process, native, and controlled Chromium claims
  remain distinct.

## Starting point

Doe already contains its WGSL compiler, WebGPU ABI and provider surfaces,
native backend implementations, package interfaces, trace and replay systems,
execution receipts, and application-comparison machinery. Current evidence is
uneven across hosts and backends. It establishes implementation and bounded
execution, not voluntary external provider adoption or general WebGPU
replacement.

## Execution gates

| Gate | Required work | Exit evidence | Does not prove |
| --- | --- | --- | --- |
| W0: adopter contract | Select one unrelated application and freeze its source revision, workload, incumbent, provider seam, shaders, commands, oracle, hardware tuple, lifecycle requirements, and material-advantage threshold. | Owner-authorized comparison contract with a credible incumbent. | Doe correctness. |
| W1: clean substitution | Install Doe from the supported package or native artifact and run the unchanged application contract through the declared provider seam. | Clean-environment reproduction with explicit Doe provider and backend identity. | Equivalent work or correctness. |
| W2: semantic and structural parity | Run the same commands and GPU work, pass the independent output oracle, and exercise initialization, concurrency, teardown, cancellation, device loss, and readback required by the application. | Comparable traces, outputs, lifecycle observations, and replay artifacts. | Material advantage. |
| W3: material advantage | Beat the incumbent on one predeclared application-valued outcome without violating W2. | Repeated application-level evidence for performance, reliability, diagnostics, deployment size, hardware reach, control, or correction cost. | Adoption. |
| W4: voluntary adoption | The external application owner selects Doe for the supported path and makes Doe a maintained dependency or distribution component. | Owner-attributed decision, integration revision, support scope, rollback path, and release evidence. | Repeatability across change. |
| W5: retained adoption | Requalify Doe after a consequential application, driver, runtime, adapter, or hardware change. | A second passing release decision under the maintained application contract. | Broad WebGPU replacement. |

## Selecting the first application

Choose the application by proof quality rather than headline visibility.

- It already runs a consequential WebGPU compute workload.
- Its owner can select or inject a provider on a controlled host.
- It has an independent, application-level output oracle.
- It exposes a problem Doe can plausibly solve through owned runtime behavior.
- Its commands and lifecycle can be compared without source divergence.
- Its owner can decide whether to retain Doe.

Prefer one host and one native backend demanded by the adopter. Broad backend
coverage cannot compensate for failure on the selected application.

## Advantage classes

Predeclare exactly which class W3 tests:

- compatibility unavailable from the incumbent;
- end-to-end latency or throughput under matching timing scope;
- peak memory or allocation stability;
- crash, hang, device-loss, concurrency, or teardown reliability;
- actionable source-linked diagnostics;
- explicit provider, fallback, and execution control;
- package size, embedding friction, or deployability;
- faster correction of an adopter-blocking compiler or runtime defect.

Isolated kernel speed is diagnostic unless it changes the application's chosen
outcome. Receipts make the result inspectable but do not replace the advantage.

## DoeProof's supporting role

DoeProof freezes W0, runs the incumbent and Doe arms, validates evidence,
detects hidden fallback and structural mismatch, and retains replay material.
It may correctly conclude that the incumbent wins. Only W4 grants product
adoption authority to DoeRuntime.

## Measures

- Clean installation and provider-substitution success.
- Application oracle and lifecycle pass rates.
- Structural command and timing-scope equivalence.
- The predeclared material-advantage outcome.
- External owner adoption and retained support scope.
- Requalification after consequential changes.
- Generalized defects converted into permanent compiler or runtime regressions.

Compiler file count, backend file count, internal receipts, and unmatched
microbenchmark wins remain supporting measures.

## Stop conditions

Stop or narrow this strategy when:

- applications cannot adopt Doe without changing their workload semantics;
- apparent wins depend on skipped work, hidden fallback, unequal timing, or a
  hardware-specific shortcut outside the adopter's required path;
- Doe repeatedly fails the application's correctness or lifecycle contract;
- no application-valued advantage survives clean-process repetition;
- application owners value DoeProof reports but consistently decline DoeRuntime;
- maintaining the adopted surface costs more than the advantage it preserves.

## Repository work queue

1. Select one application and record W0 before runtime tuning.
2. Reproduce its incumbent path and exact output oracle in a clean environment.
3. Route the unchanged contract through the narrowest supported Doe provider
   seam.
4. Fix the first correctness, lifecycle, or compatibility boundary reached by
   the application.
5. Run the governed W2 and W3 comparison with raw evidence retained.
6. Ask the external owner to accept or reject Doe as a maintained dependency.
7. If accepted, make that application a release-blocking downstream contract
   and run W5 after its next consequential change.

Mutable support, benchmark, browser, and backend status remain owned by the
claim index, support matrices, raw artifacts, and receipts. This plan cannot
promote them through prose.
