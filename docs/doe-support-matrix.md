# Doe Support Matrix

## Purpose

This document defines explicit capability tiers for Doe with hard contracts per tier.

Every tier has: a deployment surface, a supported API set, required gates, conformance requirements, support commitments, and allowed claim language. Claims that exceed a tier's contract are disallowed regardless of directional evidence.

Tier names are tied to deployment surface and guarantees, not vague quality labels.

This document is the product-contract layer of a larger tracking model. Spec inventory and CTS evidence are separate layers. `config/webgpu-spec-index.jsonl` is the canonical WebGPU API spec index and per-backend checklist generated from the official `@webgpu/types` surface; `config/webgpu-cts-evidence.json` is the CTS evidence ledger; `config/webgpu-capability-inventory.json` remains the internal capability inventory only.

## Tiers

| Tier | Deployment surface | Audience |
|------|-------------------|----------|
| **doe-core** | Node/Bun/CLI headless | AI/ML infra, CI/perf integrators |
| **doe-runtime** | Native apps, engines, embedded | Integrators replacing Dawn/wgpu in applications |
| **chromium** | Managed Chromium distribution | Managed Chromium WebGPU runtime distribution |

Each tier is additive: doe-runtime includes all doe-core commitments; chromium includes all doe-runtime commitments.

---

## Compatibility matrix snapshot

This is the current evidence-backed compatibility read for Doe's active lanes.
Use it as the fast answer to "what is actually covered today?" and then follow
the tier contracts below for promotion requirements.

| Layer | Evidence source | Current scope | Current read | Immediate blocker |
|------|-----------------|---------------|--------------|-------------------|
| `doe-core` | `reports/claim-index.json` plus `bench/out/amd-vulkan/` | governed AMD Vulkan runtime and package lanes | current claim state is lane-specific and artifact-owned | latest gate sidecar controls promotion; do not generalize Linux Vulkan evidence to browser or macOS claims |
| `doe-core` | `reports/claim-index.json` plus `bench/out/apple-metal/` | governed Apple Metal runtime and package lanes | macOS native/package evidence is first-class but separate from browser release evidence | macOS arm64 browser release needs its own archive, proof surface, launch receipt, and Dawn-vs-Doe receipts |
| `doe-runtime` | `bench/workloads/workloads.local.d3d12.json` | governed D3D12 contracts selected from the canonical D3D12 catalog | contract-backed; no public claim unless the claim index adds the lane | first Windows evidence run, drop-in gate, CTS subset publication, and runtime-tier gates |
| `chromium` | `browser/chromium/artifacts/` plus the browser row in `reports/claim-index.json` | governed Fawn/Chromium browser diagnostics | local same-binary Doe-vs-Dawn diagnostics exist; no public browser release claim | public HTTPS release archive, release-candidate gates, platform-specific proof/launch/comparison receipts, and a separate macOS arm64 browser lane |

Command-example coverage is artifact-owned. The detailed file-level breakdown
lives in `examples/README.md`.

---

## Surface and competitor matrix snapshot

The tier table above answers "what can Doe honestly claim today?".
This section answers the adjacent product question:
"which Doe surface exists on which host, against which competitor or
reference surface, and what is that cell for?"

Status vocabulary used below:

- `verified`: fresh evidence or an explicitly promoted governed lane exists
- `supported`: documented public surface exists, even if it is not itself a
  baseline/comparison claim lane
- `diagnostic`: useful for attribution, debugging, or local comparison, but not
  a canonical claim surface
- `scaffolded`: config/files/contracts exist, but fresh evidence or release
  maturity is missing
- `possible`: technically viable from current contracts, but not productized or
  governed today
- `not meaningful`: not a product cell we should try to fill

Subpath reminder:

- `doe-gpu` is the public npm package surface
- `doe-gpu/compute`, `doe-gpu/browser`, and `doe-gpu/hybrid` are exported
  subpaths inside that one package family
- repo-only benchmark, browser, and release tooling under `bench/` and
  `browser/chromium/` is not part of the npm package contract
- legacy `@simulatte/*` names are compatibility history, not primary product
  framing

Public release wording must keep platform identity explicit. A `doe-gpu` npm
release, native Apple Metal evidence, native AMD Vulkan evidence, Linux Fawn
diagnostics, and future macOS arm64 Fawn archives are separate rows. Do not
collapse them into one browser release or Dawn-replacement claim.

Current ORT evidence to read alongside the table below:

- Node ORT provider compare artifact:
  `bench/out/node-ort-webgpu-provider-compare/20260413T191817Z/gemma270m.claim.json`
- Node ORT provider breadth artifact:
  `bench/out/node-ort-webgpu-provider-breadth/20260413T192150Z/breadth.compare.json`
- Bun ORT provider compare artifact:
  `bench/out/bun-ort-webgpu-provider-compare/gemma270m-prefill32-decode1.claim.json`
- Bun ORT provider breadth artifact:
  `bench/out/bun-ort-webgpu-provider-breadth/20260413T181619Z/breadth.compare.json`
- Browser ORT canonical compare artifact:
  `bench/out/browser-ort-webgpu-compare/20260413T193605Z/browser.compare.json`
- Native ORT EP proof slice:
  `runtime/bridge/onnxruntime-ep/artifacts/20260413T172955Z/doe-ort-ep-session-smoke.json`
- Native ORT EP bench reports:
  `bench/out/native-ort-doe-ep/matmul.report.json`,
  `bench/out/native-ort-doe-ep/matmul_add.report.json`,
  `bench/out/native-ort-doe-ep/matmul_add_relu.report.json`, and
  `bench/out/native-ort-webgpu-provider/20260413T175708Z/basic-ops.claim.json`

### Runtime package family: `doe-gpu`

| Host / platform | Doe surface | Reference surface | Kind | Current state | Value / note |
|------|------|------|------|------|------|
| Node | `doe-gpu` | `webgpu` (Dawn) | product + governed compare lane | `verified` | Public package surface exists and governed Node package lanes exist. The claim-indexed package rows are lane-specific; ORT evidence exists in-repo through the same-stack provider compare lane and remains artifact-by-artifact. |
| Bun | `doe-gpu` | `bun-webgpu` (Dawn) | product + governed compare lane | `verified` | Main Bun package niche for package-plan benchmarking, and the repo now also has a same-stack Bun ORT WebGPU provider-compare lane with a fresh local Gemma-3 270M claim artifact. |
| Deno | `doe-gpu` via `packages/doe-gpu/src/deno.js` | built-in Deno WebGPU (`navigator.gpu`, wgpu-backed) | product + governed compare lane | `verified` | Deno package lane now exists in-repo and is registered as `deno_package_compare`; still newer than Node/Bun and should be read lane-specifically. |
| Node / Bun / Deno | `createDoeRuntime()`, `runDawnVsDoeCompare()` | no package-surface incumbent | advanced helper surface | `supported` | Public helper exports exist, but compare/release operator CLIs live in-repo under `bench/` and are not npm-shipped tools. |
| Node | historical `native-direct` helper shape | raw competitor device surfaces in ad hoc four-way compares | diagnostic subpath | `diagnostic` | Useful for stripping wrapper noise out of Node package attribution. Not a public replacement promise by itself. |
| Browser | `doe-gpu/browser` | browser `navigator.gpu` | package helper surface | `supported` | Public browser package entrypoint exists, but governed browser comparison/evidence lives under `browser/chromium/`, not under the npm package family by itself. |

### Legacy helper compatibility note

Legacy `@simulatte/webgpu-doe` usage is historical compatibility surface, not a
second current package family. The transport-free helper idea still matters,
but the product framing should stay on `doe-gpu`.

| Host / platform | Legacy helper binding | Reference surface | Kind | Current state | Value / note |
|------|------|------|------|------|------|
| Node / Bun / Deno | `@simulatte/webgpu-doe` bound onto Doe runtime objects | same underlying Doe runtime | helper compatibility surface | `supported` | Historical helper shape retained for compatibility/migration context only. |
| Node | `@simulatte/webgpu-doe` bound onto `webgpu` raw devices | Dawn-backed WebGPU runtime on Node | attribution / compatibility cell | `diagnostic` | Still relevant for old attribution experiments, but not a primary product surface. |
| Bun | `@simulatte/webgpu-doe` bound onto `bun-webgpu` raw devices | Dawn-backed WebGPU runtime on Bun | compatibility cell | `possible` | Technically within the old helper contract, but not a promoted current package story. |
| Deno | `@simulatte/webgpu-doe` bound onto built-in Deno WebGPU devices | wgpu-backed Deno runtime | compatibility cell | `possible` | Allowed by the old transport-free helper model; not the preferred framing anymore. |
| Browser | `@simulatte/webgpu-doe` bound onto browser-provided `GPUDevice` objects | stock browser WebGPU surfaces | helper compatibility surface | `supported` | Useful for legacy browser-helper framing, but still not a Doe runtime replacement claim. |
| Any host | `@simulatte/webgpu-doe` treated as a standalone WebGPU runtime | runtime incumbents | product cell | `not meaningful` | The helper package does not ship Doe's direct backend implementation path and should not be described as a runtime replacement. |

### Runtime, ABI, and browser cells

| Host / platform | Doe surface | Reference surface | Kind | Current state | Value / note |
|------|------|------|------|------|------|
| macOS Apple Silicon | Doe Metal backend | Dawn Metal delegate | governed runtime compare lane | `verified` | Claim-indexed Doe-vs-Dawn native strict and release evidence exists for the governed Apple Metal lanes. macOS arm64 remains separate from Linux Vulkan browser diagnostics; browser release wording requires macOS-specific Fawn archive and proof receipts. |
| Linux AMD Vulkan | Doe Vulkan backend | Dawn Vulkan delegate | governed runtime compare lane | `verified` | Claim-indexed Doe-vs-Dawn runtime release evidence exists for the governed AMD Vulkan lane. Keep Linux Vulkan browser diagnostics and package rows separate from native release wording. |
| Windows D3D12 | Doe D3D12 backend | Dawn D3D12 delegate | governed runtime compare lane | `scaffolded` | Contracts, configs, and runtime path exist, but the current inventory still lacks a fresh Windows evidence artifact. Recommended path to first evidence: GCP Windows Server 2022 + NVIDIA (G2/L4). D3D12 is fully supported on NVIDIA on Windows Server; initial results will be directional, not claimable, pending D3D12-specific Dawn mapping validation. |
| Native apps / engines / embedded | `libwebgpu_doe.{so,dylib,dll}` drop-in runtime | Dawn / wgpu via `webgpu.h` ABI | runtime replacement target | `scaffolded` | `docs/status.md` now points at a publishable Apple Metal runtime bundle with stripped dylib, hashes/sizes, drop-in gate, native consumer, compare-dev, sync/timing gates, and CTS publication, but the broader runtime tier is still missing non-Apple runtime slices and backend-wide release publication. |
| Any `webgpu.h` host | Doe shared-library ABI surface | Dawn ABI / `webgpu.h` expectations | validation cell | `scaffolded` | Fresh Apple dylib ABI/runtime validation is now bundled in `docs/status.md`, but full validation across the intended runtime hosts/backends is still incomplete. |
| Chromium / Doe browser lane | Doe as browser `navigator.gpu` runtime | Chromium / Chrome Dawn path | browser compare / smoke cell | `diagnostic` | Browser lane exists and is governed. Local same-binary Fawn diagnostics are engineering evidence, but public browser release and macOS arm64 coverage remain separate blockers from claim-grade native/package replacement language. |

### Exhaustiveness notes

The matrix above is intentionally exhaustive across the named surfaces that
exist in the repo today:

- runtime package family
  - Node, Bun, Deno, CLI, and the Node-only `native-direct` diagnostic subpath
- helper package family
  - bound to Doe runtime surfaces, competitor runtime surfaces, and browser
    `GPUDevice` surfaces
- native/runtime/browser deployment tiers
  - Metal, Vulkan, D3D12, drop-in ABI, and browser integration

Cells not listed separately are intentionally folded into one of those rows:

- `doe-gpu/compute`, `doe-gpu/browser`, and `doe-gpu/hybrid` are API-shape
  entrypoints inside the same runtime package family, not separate API
  surfaces
- legacy `@simulatte/webgpu/node` and `@simulatte/webgpu/bun` names are
  host-specific history aliases of the same package family and inherit the same
  lane status as their current `doe-gpu` parent rows
- browser competitors are represented at the browser tier, not duplicated under
  the npm package family

### Tracking model

- Product contract: this document and the package contract docs define what each surface is allowed to promise.
- Spec index and backend checklist: `config/webgpu-spec-index.jsonl` tracks the WebGPU API surface by official interface/member and string-union enum from `@webgpu/types`, and now carries per-backend checklist cells for `metal`, `vulkan`, `d3d12`, and `browser`, each split into `implementation`, `correctness`, and `performance` evidence. WGSL builtins/types remain a follow-up layer.
- CTS evidence: `config/webgpu-cts-evidence.json` tracks actual CTS runs,
  query buckets, pass/fail results, artifact paths, and the claim-policy block.
  `examples/webgpu-cts-subset-receipt.sample.json` is the hash-linked repo
  publication receipt derived from that ledger.
  `examples/webgpu-cts-backend-pass-ledger.sample.json` groups that subset by
  backend identity. Broad conformance and replacement language remains
  disallowed by the claim boundary.
- Internal capability inventory: `config/webgpu-capability-inventory.json` remains useful for Doe implementation tracking, but it is not the spec index and it is not CTS evidence.
- Chromium integration overlay: `config/webgpu-integration-chromium.json` records what changes when the browser lane runs through the wire protocol and browser-owned media/image paths.
- Generated surface views: `config/generated/webgpu-surface-{compute,headless,chromium}.json` are convenience reports derived from the canonical ledgers above; they are not source-of-truth files.

---

## Tier 1: doe-core

### Scope

Headless compute, benchmarking, and evidence infrastructure via Node/Bun/CLI.

### Deployment surface

- `doe-gpu` (Node runtime, Bun FFI, Deno, CLI-adjacent helper surface)
- `doe-zig-runtime` CLI binary
- `libwebgpu_doe.{dylib,so,dll}` via FFI (compute-focused paths)
- browser/runtime replacement packaging beyond the headless package name belongs to the `doe-runtime` tier, not a separate public package name today

### Supported API

From the `doe-gpu` API contract v1:

| API | Status | Notes |
|-----|--------|-------|
| `create(createArgs?)` | Required | Returns provider-backed GPU object with `requestAdapter` |
| `globals` | Required | Provider globals for `globalThis` bootstrap |
| `setupGlobals(target?, createArgs?)` | Required | Installs `navigator.gpu` + enum bootstrap |
| `requestAdapter(adapterOptions?, createArgs?)` | Required | Returns `Promise<GPUAdapter \| null>` when provider supports in-process adapter callbacks |
| `requestDevice(options?)` | Required | Returns `Promise<GPUDevice>` when provider supports in-process adapter/device callbacks |
| `createDoeRuntime(options?)` | Required | Advanced helper surface for `runRaw` and `runBench` orchestration |
| `runDawnVsDoeCompare(options)` | Required | Advanced helper that wraps repo compare tooling when the compare assets are present |
| `providerInfo()` | Required | Module/load diagnostics |

Package boundary:

- `doe-gpu` does not ship compare or release npm CLI binaries.
- Canonical compare/release operator entrypoints live in the repo under `bench/`.
- See `docs/internal-tooling.md` for the tooling boundary contract.

### Not supported

- Full browser-parity `navigator.gpu` object model emulation
- Full WebGPU enum surface (only constants required by real integrations)
- `GPUCanvasContext`, presentation/swapchain APIs
- Full object lifetime/event parity (`device lost` events, full error scopes, full mapping semantics)
- npm `webgpu` drop-in compatibility guarantee for arbitrary packages
- Doe-native Bun FFI callback trampoline for `wgpuInstanceRequestAdapter`/`wgpuAdapterRequestDevice` (in progress)

### Required gates

| Gate | Mode | Script |
|------|------|--------|
| Schema | Blocking | `bench/gates/schema_gate.py` |
| Correctness | Blocking | `bench/gates/check_correctness.py` |
| Trace/replay | Blocking | `bench/gates/trace_gate.py` |
| Comparability | Blocking | `bench/cli.py compare --strict` |
| Claim | Blocking for claim artifacts | `bench/gates/claim_gate.py` |
| Performance | Advisory | `gates.json` ratchet |

### Conformance requirements

- No CTS publication requirement.
- Correctness is validated by internal trace replay and comparability gates, not external CTS.
- Behavioral correctness for supported operations (buffer upload, copy, barrier, dispatch, render) must pass internal gate suite.

### SLA / support commitments

- Artifact reproducibility: any published benchmark artifact must be reproducible from the same inputs, config, and runtime version.
- Gate stability: blocking gates must not regress (pass→fail) without a tracked config or code change.
- API stability: the `doe-gpu` API contract v1 surface is stable; breaking changes require version bump.
- No uptime/availability SLA (headless tooling, not a service).

### Allowed claim language

| Claim | Allowed | Condition |
|-------|---------|-----------|
| "Strict apples-to-apples Dawn comparison on [N] workloads" | Yes | Cite artifact path, `comparisonStatus=comparable`, `claimStatus=claimable` |
| "Deterministic trace and replay for GPU workloads" | Yes | Trace gate passes |
| "Hash-linked benchmark artifacts" | Yes | Artifacts conform to trace-meta schema |
| "Faster than Dawn on [specific workloads]" | Yes | Per claim discipline rules (artifact, workload set, backend, timing class, claimStatus) |
| "Dawn replacement" | No | Requires doe-runtime tier |
| "Production WebGPU runtime" | No | Requires doe-runtime tier |
| "Conformant WebGPU implementation" | No | Requires doe-runtime tier with CTS publication |

---

## Tier 2: doe-runtime

### Scope

Drop-in native WebGPU runtime for applications, engines, and embedded systems. Replaces Dawn or wgpu as the `webgpu.h` provider.

### Deployment surface

- `libwebgpu_doe.so` / `libwebgpu_doe.dylib` as shared library
- Static linking for embedded targets
- All doe-core surfaces (Node/Bun/CLI)

### Supported API

All of doe-core, plus:

| API | Status | Notes |
|-----|--------|-------|
| `webgpu.h` ABI | Required | Full symbol set verified by `dropin_gate.py` |
| `wgpuCreateInstance` | Required | Via shared library export |
| `wgpuInstanceRequestAdapter` | Required | Callback-based per `webgpu.h` spec |
| `wgpuAdapterRequestDevice` | Required | Callback-based per `webgpu.h` spec |
| Buffer operations | Required | Create, map, unmap, write, copy |
| Texture operations | Required | Create, write, copy, view |
| Render pipeline | Required | Create, bind, draw, draw indexed |
| Compute pipeline | Required | Create, bind, dispatch |
| Command encoding | Required | Full `GPUCommandEncoder` surface |
| Queue operations | Required | Submit, writeBuffer, writeTexture, onSubmittedWorkDone |

### Expanded scope vs doe-core

| Capability | doe-core | doe-runtime |
|-----------|----------|-------------|
| `webgpu.h` ABI completeness | Partial (compute paths) | Full (verified by gate) |
| Render pipeline | Not required | Required |
| Texture operations | Not required | Required |
| Presentation/swapchain | Not required | Required only for windowed/browser-integrated targets |
| Error scopes | Not required | Required |
| Device lost events | Not required | Required |
| Shader module creation | Via helper/runtime tooling | In-process via `webgpu.h` |

### Not supported

- Browser-specific presentation integration (swapchain is native-window, not `GPUCanvasContext`)
- Chromium GPU process integration
- Browser security sandbox enforcement (that is chromium)

### Required gates

All doe-core gates, plus:

| Gate | Mode | Script |
|------|------|--------|
| Drop-in ABI | Blocking | `bench/dropin_gate.py` |
| CTS subset | Blocking | Target: selected CTS subset at published pass rate |
| Backend selection | Blocking | `run_blocking_gates.py --with-backend-selection-gate` |
| Sync conformance | Blocking per backend | Metal: `--with-metal-sync-conformance-gate`; Vulkan: `--with-vulkan-sync-conformance-gate` |
| Timing policy | Blocking per backend | Metal: `--with-metal-timing-policy-gate`; Vulkan: `--with-vulkan-timing-policy-gate` |
| Shader artifact | Blocking | `--with-shader-artifact-gate` |

### Conformance requirements

- **CTS subset publication required.** Select a meaningful CTS subset covering implemented operations. Publish pass/fail status and backend identity through the typed CTS subset receipt plus backend pass ledger, and track trend per release.
- **Minimum pass rate target:** To be established after first CTS run. Initial publication of any number (even low) is required; trend direction matters more than absolute value.
- **Regression policy:** CTS pass rate must not regress between releases. Any regression blocks release until fixed or explicitly waived with tracking in `docs/status.md`.

### SLA / support commitments

All doe-core commitments, plus:

- ABI stability: `webgpu.h` symbol set does not break between minor versions. Symbol additions are non-breaking; symbol removal or signature change requires major version bump.
- Binary artifact availability: stripped shared library published per release, per backend (Metal, Vulkan), per target (macOS arm64, Linux x86_64, etc.).
- Binary size and build time: published per release, compared against Dawn baseline.
- Conformance trend: CTS subset results published per release.
- Bug response: issues with reproducible trace artifacts get priority triage.

### Allowed claim language

All doe-core claims, plus:

| Claim | Allowed | Condition |
|-------|---------|-----------|
| "Drop-in Dawn/wgpu replacement" | Yes | `dropin_gate.py` passes, CTS subset published |
| "Lighter than Dawn" | Yes | Only with published binary size + build time + dependency count comparison |
| "Conformance-tracked WebGPU runtime" | Yes | CTS subset results published |
| "Production WebGPU runtime" | Yes | All blocking gates green, CTS published, at least one external consumer validated |
| "Full WebGPU implementation" | No | Until CTS pass rate exceeds threshold (TBD) |
| "Browser-ready" | No | Requires chromium tier |
| "Formally verified" | No | Until Lean proof pipeline is operational in CI with specific scope documented |

---

## Tier 3: chromium

### Scope

Managed Chromium distribution with Doe as the WebGPU runtime.

### Consumer hardware coverage plan

Chromium-tier validation must cover real Chrome/WebGPU behavior, not just OS
availability. The practical first-pass matrix is:

| Lane | Host type | GPU class | Why it matters |
|------|-----------|-----------|----------------|
| macOS baseline | physical Mac mini or MacBook | Apple Silicon integrated GPU | Mainstream Chrome/macOS consumer path |
| Windows Intel baseline | physical laptop or mini PC | Intel integrated GPU | Common laptop path and low-power adapter behavior |
| Windows AMD baseline | physical laptop or mini PC | AMD integrated GPU | Common APU path with different driver behavior |
| Windows high tier | physical desktop/laptop or cloud | NVIDIA discrete GPU | Main high-end Windows/perf lane |
| Linux baseline | physical mini PC or laptop | AMD integrated GPU | Best practical Linux consumer lane with fewer vendor-specific surprises |
| Linux high tier | physical desktop or cloud | NVIDIA discrete GPU | Add when Linux performance is a serious support surface |

Use physical machines for integrated-GPU consumer coverage. Use cloud for
repeatable NVIDIA Windows/Linux automation and burst reruns. Do not make every
machine a performance lane: most of the Chromium matrix should answer
compatibility and regression questions before it answers benchmarking
questions.

### Deployment surface

- Chromium fork binary (macOS, Linux, Windows)
- Doe integrated as `--use-webgpu-runtime=doe`
- All doe-runtime surfaces available via Chromium's GPU process

### Supported API

All of doe-runtime, plus:

| API | Status | Notes |
|-----|--------|-------|
| `navigator.gpu` | Required | Full browser WebGPU API via Doe backend |
| `GPUCanvasContext` | Required | Browser presentation integration |
| Chromium GPU process integration | Required | Doe runs in GPU process with sandbox |
| Chromium flags | Required | `--use-webgpu-runtime=doe`, `--disable-webgpu-doe`, `--doe-webgpu-library-path` |

### Expanded scope vs doe-runtime

| Capability | doe-runtime | chromium |
|-----------|-------------|--------------|
| Browser `navigator.gpu` | Not supported | Required |
| `GPUCanvasContext` / presentation | Native-window only | Browser tab integration |
| GPU process sandbox | Not applicable | Required |
| Security patch cadence | Not applicable | Required SLA |
| Upstream rebase | Not applicable | Required cadence |
| Rollback to Dawn | Explicit lane/config selection only (no runtime override switch) | Managed, policy-driven |

### Not supported at launch

- Full WebGPU spec conformance parity with Chrome/Dawn (may lag on edge cases)
- WebGPU extensions not in `webgpu.h` core
- WebCodecs GPU integration (future)

### Required gates

All doe-runtime gates, plus:

| Gate | Mode | Script |
|------|------|--------|
| Cycle lock/rollback | Blocking | `bench/gates/cycle_gate.py` |
| Cutover verification | Blocking per lane | `--with-local-metal-gates --local-metal-lane metal_doe_app` |
| Claim rehearsal | Required for release claims | `bench/tools/build_claim_rehearsal_artifacts.py` |
| Substantiation | Required for trend publication | `bench/runners/run_release_claim_windows.py` |

### Conformance requirements

All doe-runtime requirements, plus:

- **Expanded CTS coverage:** CTS subset must cover browser-visible API surface, not just compute/buffer operations.
- **Browser smoke tests:** Standard WebGPU samples (rotating cube, compute boids, deferred rendering) must render correctly in the Doe Chromium lane.
- **Regression gate:** No CTS regression and no browser smoke test regression between releases.

### Operational commitments

| Commitment | Target | Notes |
|-----------|--------|-------|
| Security patch cadence | Within 72 hours of Chrome stable security update | GPU process CVEs prioritized |
| Upstream rebase cadence | Per Chrome major release (every 4 weeks) | Doe integration isolated to minimize conflict surface |
| Rollback policy | Runtime backend override switch removed; use explicit lane/config policy | Deterministic recovery via audited policy updates |
| Diff size tracking | Published per release | Doe Chromium lane vs upstream Chromium diff LOC tracked; growing diff requires justification |
| Release cadence | Monthly minimum, aligned with Chrome stable | Hotfix releases for security within SLA |

### Fork maintenance contracts

| Area | Contract |
|------|----------|
| Isolation boundary | The Doe Chromium lane modifies only: `third_party/dawn/` replacement surface, GPU process initialization/runtime selection, `webgpu.h` binding layer, and packaging/branding/launcher metadata required for distribution. All other Chromium code tracked upstream without modification. |
| Rebase strategy | Cherry-pick security patches immediately. Full rebase per Chrome major release. Merge conflicts in the isolation boundary are resolved by the Doe team; conflicts outside that boundary indicate scope creep. |
| Diff ceiling | If the Doe Chromium lane diff exceeds 50K LOC (excluding `third_party/dawn/` replacement), trigger architectural review to re-isolate. |
| Security audit | Doe runtime code in GPU process is in-scope for security review. Sandbox boundary behavior must match Dawn's guarantees or explicitly document deviations. |

### Allowed claim language

All doe-runtime claims, plus:

| Claim | Allowed | Condition |
|-------|---------|-----------|
| "Managed browser with controlled GPU behavior" | Yes | Operational commitments met, at least one release shipped |
| "Independent GPU runtime patching" | Yes | Demonstrated by shipping a Doe fix without waiting for Chrome release |
| "Auditable GPU behavior" | Yes | Trace/replay operational in browser context |
| "Enterprise-grade browser" | Yes | Security patch SLA demonstrated over 3+ release cycles |
| "Regulated/sovereign browser" | Yes | All operational commitments met + hash-linked artifact chain operational |
| "FedRAMP/HIPAA/IL4+ ready" | No | Until actual certification or compliance audit completed |
| "Formally verified browser" | No | Until Lean proof pipeline is operational with documented scope |

---

## Tier progression

```
doe-core ──────────► doe-runtime ──────────► chromium
  │                     │                       │
  │ Ship now            │ Ship when:            │ Ship when:
  │                     │ - requestAdapter FFI  │ - rebase cadence proven
  │ Headless compute    │   works in-process    │ - security SLA demonstrated
  │ + evidence infra    │ - CTS subset          │ - browser smoke tests pass
  │                     │   published           │ - operational commitments
  │                     │ - dropin gate green   │   documented and met
  │                     │ - binary size         │
  │                     │   measured            │
  │                     │                       │
  ▼                     ▼                       ▼
  CI/perf integrators   Engine/embedded teams   Managed-runtime distribution
  AI/ML infra           Dawn/wgpu replacers     consumers
  AI workload integration   Native app developers
```

### Promotion criteria

**doe-core → doe-runtime:**

1. `wgpuInstanceRequestAdapter` callback trampoline operational (Bun FFI or synchronous variant)
2. `dropin_gate.py` passes on full `webgpu.h` symbol set
3. First CTS subset run published with pass/fail counts
4. Binary size and build time comparison vs Dawn published
5. At least one external consumer validated (AI workload stack, game engine, or embedded integrator)

**doe-runtime → chromium:**

1. All doe-runtime promotion criteria met
2. Chromium fork builds and boots with Doe as WebGPU runtime on at least one platform
3. Browser smoke tests (rotating cube, compute boids) render correctly
4. Security patch flow demonstrated: at least one Chrome security patch applied within 72-hour target
5. Rebase cadence demonstrated: at least one full Chrome major version rebase completed
6. Operational commitments documented in shipping artifacts (not just internal docs)
7. Rollback to Dawn baseline validated end-to-end in browser context

---

## Layer escalation guidance

Use the lowest layer that can honestly describe the current evidence. Do not
escalate a command stream, package surface, or claim language just because the
code path exists.

1. Keep an item at example-only status when it is merely schema-valid or locally useful.
   It is not yet a supported compatibility claim if it lacks a workload
   contract and a fresh artifact.

2. Escalate an example into `doe-core` only when all of the following are true:
   it is wired into a versioned workload contract, the latest artifact records
   successful execution with blocking obligations passing, and the example's
   status is documented as fresh evidence or diagnostic in `examples/README.md`.

3. Treat `diagnostic` examples as evidence-bearing but non-promotable.
   They are valid for debugging and regression tracking, but they do not justify
   "faster", "supported", or broader replacement language for that lane.

4. Escalate from `doe-core` to `doe-runtime` only after the runtime-visible
   surface is proven outside the package/CLI layer: `webgpu.h` ABI coverage,
   `dropin_gate.py`, CTS subset publication, callback/device creation, and the
   backend-specific blocking gates required by this document.

5. Escalate from `doe-runtime` to `chromium` only after the browser lane
   has its own evidence: Chromium boot with Doe selected, browser smoke tests,
   rebase cadence, security-patch cadence, and rollback validation. Native
   runtime evidence does not automatically transfer to the browser tier.

6. Demote quickly when the latest artifact regresses.
   If a lane flips from claimable to diagnostic, or from fresh evidence to
   contract-only, the docs must immediately stop using the higher-status label.

This guidance is intentionally conservative: fresh artifacts outrank older
claimable runs, and explicit lane evidence outranks assumptions from nearby
layers.

---

## Claim discipline by tier

The claim discipline rules from [`docs/claim-discipline.md`](claim-discipline.md) apply universally, but the *scope* of allowed claims differs by tier:

| Rule | doe-core | doe-runtime | chromium |
|------|----------|-------------|--------------|
| Performance claims require artifact citation | Yes | Yes | Yes |
| No generalization beyond covered workloads | Yes | Yes | Yes |
| Regression blocks "faster" language | Yes | Yes | Yes |
| "Replacement" language allowed | No | Yes (with CTS) | Yes |
| "Production" language allowed | No | Yes (with gates) | Yes |
| "Conformant" language allowed | No | Yes (with CTS trend) | Yes |
| "Full-stack distribution" language allowed | No | No | Yes |

---

## Relationship to AI workloads

AI workload stacks are consumers of Doe, not tiers of Doe. Representative tier requirements:

| AI workload use case | Minimum Doe Tier | Reason |
|-----------------|-----------------|--------|
| Browser inference on stock WebGPU | None (uses Dawn/wgpu via host browser) | Doe not involved |
| Headless inference via Node provider module | doe-core | Needs `requestAdapter`/`requestDevice` in Node |
| Vertically integrated browser AI stack | chromium | Needs browser-integrated `navigator.gpu` on Doe |
| Sovereign AI stack (all three) | chromium | Full stack requires all tiers |

AI workload stacks can ship value today on stock WebGPU (no Doe dependency). The Doe integration path adds value incrementally as tiers mature.

---

## Current evidence

This matrix defines tier meaning and claim boundaries. It is not the live
status surface.

Current evidence and blockers live in:

- [`docs/status.md`](status.md) for routing
- [`docs/status/runtime-backends-and-bench.md`](status/runtime-backends-and-bench.md)
  for backend and benchmark-lane narrative status
- `bench/out/**/{*.json,*.claim.json}` for compare, claim, and run receipts

Do not add dated status tables here. If a lane's claim level changes, update
the owning status shard and artifact-backed claim output, then keep this file
limited to the tier definitions and demotion rules.
