# Cerebras evidence bundle

Cerebras evidence-bundle governance source. The packer extracts the marked
sections below into the archive-root files reviewers expect:

- `README.md`
- `CLAIM_SCOPE.md`
- `MODEL_ACCESS.md`
- `CEREBRAS_ASK.md`
- `LOCAL_INSPECTION.md`

`docs/cerebras-evidence-bundle-pointer.md` stays separate because it
is auto-generated after pack + verify and would be stale if it were
bundled.

<!-- archive:README.md:start -->
# Cerebras evidence bundle: README

Packed software-only evidence bundle for Doe's Cerebras lane. Use the run
order below. The current external ask leads with the Gemma 4 31B af16
full-prompt HostPlan hardware transcript. Qwen 3.6 27B has the matching
companion HostPlan wrapper. The E2B artifacts remain control evidence and
smaller repro fixtures.

## What's at the archive root

- `README.md`: this file.
- `BUNDLE_META.json`: build stamp: UTC timestamp, git commit,
  dirty-tree flag, host OS, cs_python availability on the bundler.
- `MANIFEST.txt`: sha256 + claim-role + path for every file inside.
- `CLAIM_SCOPE.md`: backed claims, excluded claims, and receipt paths.
- `MODEL_ACCESS.md`: cache roots, canonical Gemma 4 31B, Qwen 3.6 27B, and E2B
  artifact identities, download/materialization commands, validation
  commands, and demo scope.
- `CEREBRAS_ASK.md`: operator-facing distillation: exact endpoint
  access needed, exact command to run, exact receipt fields to
  return, publication boundaries.
- `LOCAL_INSPECTION.md`: commands for reviewers who want to browse
  the evidence in a browser (status dashboard, E2B side-by-side,
  SDK-GUI-style viewer) with the same tools the bundler uses.

Every other file lives under its repo path (`docs/`, `bench/out/`,
`config/`) inside the tar; the packager preserves layout so
cross-references inside the receipts resolve as written.

## Run order

1. **Verify the archive itself** before trusting any of its contents:

   ```
   python3 bench/tools/verify_cerebras_validation_archive.py \
     --archive <this tarball>
   ```

   This extracts to a temp dir, re-hashes every file against
   `MANIFEST.txt`, checks `BUNDLE_META.json` required fields, and
   confirms the archive filename matches `BUNDLE_META.archiveFilename`.
   Any integrity failure is a reason to request a rebuild before
   acting on the contents.

2. **Read `BUNDLE_META.json`.** If `gitDirtyTree: true`, the bundle
   was built from an uncommitted working tree. Prefer a clean
   rebuild before external circulation.

3. **Read `CLAIM_SCOPE.md`.** It enumerates the claims this bundle
   backs with evidence, the claims it explicitly does not back,
   and the external dependencies that unlock further claims. Every
   backed claim points at a `claim-role` listed in `MANIFEST.txt`.

4. **Read `MODEL_ACCESS.md`.** It pins the Gemma and Qwen Doppler
   Q4K/af16 artifacts, the raw 31B Hugging Face snapshot used by the
   bounded fallback, the E2B control artifacts, the writable Hugging Face
   cache env vars, and the first-demo scope.
   The E2B helper
   `python3 bench/tools/prepare_gemma4_e2b_access.py --print-shell`
   remains available for the smaller control lane.

5. **Read `CEREBRAS_ASK.md`.** The operator-facing distillation of
   the external ask. The first requested run is the Gemma 4 31B af16
   full-prompt HostPlan runner; Qwen 3.6 27B is available through the
   matching wrapper. It also enumerates endpoint access and
   Cerebras-assisted source checkout paths, plus the exact command,
   receipt fields, and publication boundaries for either lane.
   `docs/cerebras-hardware-runbook.md` is its parent document with
   the fuller operator context.

6. **Read `LOCAL_INSPECTION.md`** if you want to browse the
   evidence in a browser. Lists local-server commands for the
   status dashboard, E2B side-by-side demo, and SDK-GUI-style
   spatial compute viewer, all consuming the same bundle files without
   unpacking SDK binaries.

7. **Spot-check the receipts.** `MANIFEST.txt` gives a claim-role
   per file. Open any `model-runtime-receipt` or
   `cross-runtime-parity-verdict` and confirm the assertions match
   the appendix's summary. For the paranoid: re-compute sha256 of
   any `.json` and compare against the manifest row.

8. **Re-run local gates (optional).** If the unpacked archive lives
   on a host with `git` + Python available:

   ```
   python3 bench/tools/run_cerebras_evidence_bundle.py
   ```

   Runs the same local gates captured in the bundle's
   `rollup/cerebras-evidence-bundle/summary.json`. Re-running should
   yield the same `verdict: passed` unless the repo has drifted.

## Claim taxonomy at a glance

| claim-role | What it is | Who it's for |
| --- | --- | --- |
| `governance` | Policy + external ask + this README's source | Anyone |
| `real-weight-fixture` | Pinned bundle contract for E2B / 31B | Reviewers of the real-weight promotion path |
| `doppler-rdrr-fixture` | Pinned Doppler RDRR/int4ple artifact-readability contract | Reviewers of the Doppler production-artifact path |
| `model-runtime-receipt` | Per-model runtime evidence (E2B, 31B) | Primary reviewers |
| `cross-runtime-parity-verdict` | Layer-block diagnostic parity artifacts | Numerical reviewers |
| `emulator-accuracy-verdict` | CSL simfabric vs WebGPU emulator where claimable | Correctness reviewers |
| `emulator-speed-verdict` | Local-debug-only speedup (not hardware) | Ergonomics reviewers |
| `manifest-shape-probe` | Upstream E2B tensor-shape contract probe | Reviewers of the manifest-shape rewrite |
| `manifest-shape-execution-oracle` | CPU/Numpy raw-BF16 E2B text-forward oracle at upstream tensor dimensions | Reviewers of the manifest-shape rewrite; not Doe/CSL runtime evidence |
| `manifest-shape-attention-core` | SdkLayout diagnostic for E2B local/global headDim 256/512 plus grouped-KV stream reuse | Reviewers of the attention rewrite; not full attention/logits/model evidence |
| `doppler-webgpu-capture-graph` | Doppler Node WebGPU bootstrap plus Gemma-4 E2B WGSL/command capture through `doe-gpu/capture` | Reviewers of the shared JS/WGSL input surface; not HostPlan/SdkLayout/CSL execution |
| `real-weight-parity-verdict` | Real-weight smoke-contract parity, including bundled diagnostic smoke depths | Reviewers of the checkpoint-derived layer-block path |
| `doppler-rdrr-probe` | Manifest/shard/tensor-span probe for the Doppler int4ple artifact | Reviewers of structural RDRR ingestion |
| `doppler-rdrr-q4k-extraction` | Q4_K_M RDRR-to-smoke-slice materialization verdict | Reviewers of the RDRR dequant path |
| `doppler-rdrr-q4k-audit` | Shape/hash audit for RDRR-derived smoke-contract slices | Reviewers of the RDRR dequant path |
| `doppler-rdrr-q4k-parity` | RDRR-derived smoke-contract WebGPU-vs-CSL parity verdicts, including bundled diagnostic smoke depths | Numerical reviewers; not Doppler production inference parity |
| `doppler-int4ple-reference-export` | Production Doppler INT4 PLE reference export; final logits plus bounded decode transcript when present | Reviewers of the source reference lane; not Doe CSL parity by itself |
| `doppler-int4ple-execution-graph` | Hash-linked execution graph used by the production Doppler INT4 PLE reference | Reviewers checking source identity |
| `doppler-int4ple-reference-input` | Prompt and tokenized prompt bound into the reference input-set hash | Reviewers checking deterministic input identity |
| `doppler-int4ple-reference-output-tokens` | Generated token IDs from the bounded greedy transcript | Reviewers checking transcript token parity |
| `doppler-int4ple-reference-transcript` | Per-step logits and token IDs for the bounded Doppler reference transcript, without raw logits tensors | Numerical reviewers checking the transcript contract |
| `doe-csl-int4ple-blocked-transcript` | Doe CSL transcript receipt shape, graph-derived lowering plan, and normalized HostPlan bundle for the production INT4 PLE lane, currently blocked before simfabric output | Reviewers checking the missing proof producer and blocker taxonomy |
| `doppler-int4ple-pending-parity` | Doe parity receipt binding the production Doppler INT4 PLE reference and documenting the missing CSL transcript | Numerical reviewers; blocked until CSL emits the matching transcript |
| `manifest-compile-attempt` | 31B manifest-shape compile attempt receipt with typed compiler blocker taxonomy | Reviewers checking what fails before hardware |
| `manifest-compile-sweep` | 31B layer-block compile-threshold sweep summary | Reviewers checking per-PE residency headroom |
| `deployment-width-derivation` | Width recommendation derived from the compile-threshold sweep | Reviewers checking deployable smoke-width choices |
| `full-graph-compile-attempt` | 31B steps-mode full-graph compile-attempt receipt | Reviewers checking manifest-shaped compile target coverage |
| `full-graph-compile-driver-result` | Driver result backing the full-graph compile attempt | Reviewers checking measured per-target compiler verdicts |
| `simfabric-cell-source` | Production-named CSL cell source and driver files | Reviewers checking local cell reproducibility |
| `simfabric-cell-receipt` | Per-cell simfabric receipt | Numerical reviewers checking bounded CSL parity |
| `simfabric-cells-summary` | Rollup for the authored simfabric cells and their pending families | Reviewers checking cell coverage |
| `tsir-cross-backend-canary` | Real-kernel TSIR canary summary across MSL, SPIR-V, WebGPU, and WSE3 descriptors | Reviewers checking independent semantic-oracle coverage |
| `tsir-real-canary-parity-receipt` | Per-kernel parity receipts from the real-kernel TSIR canary | Numerical reviewers; CSL lane may remain typed-deferred |
| `bounded-decode-receipt` | Bounded simfabric `kv_write -> attention_decode -> sample` receipt | Reviewers checking KV/decode mechanics at bounded shape |
| `bounded-decode-stage-trace` | Per-stage trace files bound by the bounded decode receipt | Reviewers checking stage-level hashes and max error |
| `multi-token-decode-typed-blocker` | Typed blocker for local multi-token decode orchestration | Reviewers checking the remaining decode execution blocker |
| `real-weight-pin` | 31B real-weight source identity pin | Reviewers checking source identity; not Cerebras execution |
| `real-weight-hash-manifest` | Hash manifest for the pinned 31B real-weight files | Reviewers checking weight-file identity |
| `real-weight-smoke-extraction` | 31B real-weight smoke-contract extraction and audit | Reviewers checking smoke-slice materialization |
| `promoted-artifact-provenance` | Sidecar provenance for promoted stable bundle paths | Reviewers checking source-to-bundle identity |
| `target-run-receipt` | Per-target L1 receipt for WebGPU WGSL, CSL WebGPU emulator, or CSL simfabric | Reviewers of the side-by-side layer-block demo |
| `moe-lane-scope` | 26B/A4B MoE blocked-lane + 6 TODO receipts | Anyone asking about MoE |
| `rollup` | Summary artifacts (lanes, gate bundle) | Triage |
| `depth-coverage-rollup` | Which declared depths have raw files vs evidence-eligible receipts; today only L1 synthetic is claimable | Anyone asking "is this the full model?" |

## Contact and next steps

The external ask lives in `docs/cerebras-hardware-runbook.md`.
Nothing in this bundle should be circulated externally until its
verifier passes and `CLAIM_SCOPE.md` has been reviewed against what
you plan to claim.

If any required artifact is missing from `MANIFEST.txt` (e.g. you
see `missing:` lines in the manifest footer), rebuild the bundle
from a clean tree before external use.
<!-- archive:README.md:end -->

<!-- archive:CLAIM_SCOPE.md:start -->
# Cerebras evidence bundle: claim scope

This document is the **terms-of-bundle** for
`doe-cerebras-evidence-<YYYYMMDD-HHMM>-<shortSha>[-dirty].tar.gz`. It
is included in every such archive as `CLAIM_SCOPE.md` and states what
the bundle **does** and **does not** back with evidence.

It is distinct from `docs/cerebras-hardware-runbook.md`, which is the
operator-facing document describing what Cerebras would need to run.
This document is for the bundle itself: what it is honest to say once a
reviewer holds a copy.

## What this bundle claims

Each claim below is backed by an artifact inside the bundle,
enumerated in `MANIFEST.txt` with its `claim-role` tag.

1. **Gemma-4 E2B-shaped L1 synthetic layer-block parity is evidenced.**
   Backed by `rollup/all-lanes-summary-L1.json`, whose
   `evidenceEligibility.claimable=true`,
   `evidenceTier=synthetic_l1_layer_block`, and
   `runtimeParityTolerance.rollupVerdict=all_within_tolerance`.
   This is one layer-block with seeded tensors, not real weights and
   not full E2B.

2. **Gemma-4 E2B L1 real-weight smoke-contract parity is evidenced.**
   Backed by the E2B real-weight parity verdict and model-runtime
   receipt. The weights are BF16-derived smoke-contract slices
   materialized from the raw SafeTensors source discoverable through
   Doppler's local int4ple origin metadata. This is still one L1 smoke
   layer-block contract, not manifest-shape execution and not full E2B.

3. **Doe can structurally read the local Doppler Gemma-4 E2B int4ple
   RDRR artifact.** Backed by the Doppler RDRR fixture and probe
   verdict. This validates manifest/origin hashes, declared shard
   sizes, selected shard hash, target tensor spans, Q4_K_M packed-size
   formulas, and int4 PLE metadata. The structural probe itself is not
   the Q4_K_M parity verdict and not Doppler production inference
   output parity.

4. **Doppler RDRR Q4_K_M L1 smoke-contract parity is evidenced.**
   Backed by the RDRR Q4_K_M extraction artifact, RDRR weights audit,
   wrapper parity verdict, and inner WebGPU-vs-CSL simfabric parity
   verdict. This dequantizes the local RDRR Q4_K_M spans into Doe's
   existing E2B L1 smoke-contract slice format. It is not Doppler
   production inference output parity, not manifest-shape execution,
   and not full E2B.

5. **The production Doppler INT4 PLE lane has an output-ready
   reference export when the `doppler-int4ple-reference-export`
   artifact is present.** This is source-reference evidence only. The
   final-logits tensor is an intermediate checkpoint; the promotion
   target is a bounded deterministic prefill+decode transcript with
   per-step logits and token IDs. The
   `doe-csl-int4ple-blocked-transcript` artifact records the Doe CSL
   transcript receipt shape, graph-derived lowering blockers, a
   normalized HostPlan bundle, and the current missing simfabric
   producer. It is not Doe CSL parity, not hardware evidence, and not
   a performance claim.

6. **E2B declared-depth smoke-chain diagnostics are bundled.** Backed
   by the BF16-derived and RDRR Q4_K_M diagnostic parity verdicts for
   the declared smoke depths beyond L1. These artifacts show depth
   progress for the same smoke contract; they are not promoted release
   evidence, manifest-shape execution, full E2B, or hardware evidence.

7. **The raw BF16 Gemma-4 E2B text checkpoint executes at manifest
   shape in a CPU/Numpy oracle.** Backed by the
   `manifest-shape-execution-oracle` artifact. This covers one
   text-only token through embed, PLE, all E2B decoder layers, final
   norm, and tied lm-head top-k at upstream local/global head
   dimensions. It is not Doe/CSL runtime evidence, not hardware
   evidence, and not a performance claim.

8. **Doe/CSL executes the E2B manifest-shape attention-core diagnostic
   for local/global head dimensions.** Backed by the
   `manifest-shape-attention-core` artifact. This covers SdkLayout
   simfabric execution for `headDim=256`, `globalHeadDim=512`, and
   grouped-KV stream reuse across eight query heads. It is not full
   attention, not decoder-stack execution, not logits parity, not
   hardware, and not a performance claim.

9. **Doe carries E2B and 31B through governed compiler/runtime
   artifacts.** Backed by the model-runtime receipts and fixture
   contracts. This is a lowering/artifact-chain claim, not a Doe/CSL
   full-model execution claim.

10. **31B no-hardware evidence has moved beyond L1-only smoke.**
    Backed by manifest compile-attempt receipts, the compile-threshold
    sweep, the steps-mode full-graph compile attempt, bounded
    single-step decode, real-weight source pin and smoke extraction,
    and the real-kernel TSIR canary. These artifacts reduce local
    unknowns but do not replace a WSE hardware receipt.

11. **Gemma 4 31B AF16 has production-named simfabric cell evidence
    for the lm-head path.** Backed by `simfabric-cell-source`,
    `simfabric-cell-receipt`, and `simfabric-cells-summary` artifacts.
    The current cell is `lm_head_prefill`; it uses the production
    kernel stem, compiles at bounded shape, runs on local simfabric,
    stages f16 activation and weights, reduces f32 partials, and compares
    against a host f32 oracle. This is not hardware, not manifest-shape
    execution, not full-vocabulary output, and not coverage for every
    Gemma kernel family.

12. **The TSIR real-kernel reference and Doe-WebGPU lanes agree for
    the bundled canary set.** Backed by the `tsir-cross-backend-canary`
    summary and per-kernel parity receipts. The CSL simfabric lane is
    intentionally typed-deferred when the channel or per-kernel compile
    dirs are not ready.

13. **Doppler-equivalent WebGPU and Doe-emitted CSL agree on the L1
   synthetic layer-block contract within `atol=1e-3`.** Explicitly
   labeled *Doppler-equivalent*: a separate WGSL harness matching the
   semantic contract, not Doppler's production inference path.

14. **CSL WebGPU emulator is faster than local CSL simfabric on the
   same host for local debug.** Backed by the L1 emulator speed
   verdict. Scoped explicitly to "local debug ergonomics" per
   `compare_csl_emulator_vs_simfabric_speed.py`.

15. **Unified Doe entrypoint routes to five backend targets, with
   runtime-output receipts for three L1 side-by-side lanes.** Backed
   by `rollup/all-lanes-summary-L1.json` plus `target-run-receipt`
   artifacts for `webgpu-wgsl`, `csl-sdklayout`, and
   `csl-webgpu-emulator`. `doe-metal` and `doe-vulkan` are
   backend-identity probes, not Gemma-4 output parity on Doe's native
   backend.

## What this bundle does NOT claim

Each non-claim here is actively gated in repo by
`bench/gates/claim_discipline_gate.py` and/or
`docs/claim-discipline.md`. Any archive prose that asserts these is a
bundle integrity failure.

- **Gemma-4 runs on Cerebras hardware.** No `hardware_success`
  receipt exists in this bundle. Simfabric is not hardware.

- **Any Gemma-4 / Cerebras / CSL / WSE / WSC performance claim
  outside the emulator-vs-local-simfabric debug-path exception.**

- **Gemma-4 31B runs at manifest shape.** The manifest is
  `numHeads=32, headDim=160`; the bundle evidences smoke shape only.

- **Gemma-4 26B/A4B MoE works on Cerebras, CSL, or any lane.** The
  bundle explicitly includes six `moe-lane-scope` TODO files plus a
  `lane-status.json` with `laneStatus=blocked`. Claim-discipline's MoE
  gate rejects "26B/A4B is running/working/operational" language.

- **Doe executes the full Gemma-4 model end-to-end.** The bundle's
  manifest-shape full text-forward artifact is a CPU/Numpy oracle.
  Doe/CSL runtime evidence remains scoped to the layer-block smoke
  contract and does not yet cover a manifest-shape end-to-end runtime
  receipt.

- **L2/L4/L8/L35 are claimable E2B parity depths.** The depth matrix
  distinguishes raw diagnostic files from evidence-eligible receipts.
  Bundled BF16/RDRR smoke diagnostics beyond L1 are not promoted
  receipts. Today only L1 synthetic and E2B L1 real-weight
  smoke-contract evidence are claimable.

- **31B real Gemma-4 weights have executed on Cerebras or produced a
  parity verdict.** The bundle includes a source identity pin and
  smoke-contract extraction/audit. It does not include a Cerebras
  execution receipt or Doppler-vs-Doe parity verdict for those weights.

- **Full E2B real-weight execution has been proven on Doe/CSL.** The
  E2B real-weight Doe/CSL evidence is L1 smoke-contract only. The
  manifest-shape full text-forward oracle is CPU/Numpy and does not
  promote the Doe runtime receipt.

- **Doppler production INT4 PLE parity against Doe CSL has been
  proven.** The production Doppler reference export is only the source
  side. The parity receipt remains blocked until Doe CSL simfabric
  emits the same bounded prefill+decode transcript with matching
  manifest, graph, weights, input set, real KV/cache behavior,
  per-step logits, token IDs, no stubs, and no synthetic inputs or
  weights.

## What must land externally to unlock additional claims

| Unlock | External dependency |
| --- | --- |
| Doppler production INT4 PLE transcript parity | Doppler-owned production prefill+decode transcript export plus Doe CSL simfabric transcript for the same prompt/input contract, manifest, graph, weights, real KV/cache behavior, per-step logits, and token IDs |
| 31B real-weight layer-block parity | Runner consumes the pinned 31B smoke slices and returns a comparable Doe receipt |
| Manifest-shape execution | Embed/unembed, decoder-stack stream binding, full attention semantics, and logits parity for E2B local `headDim=256`, `globalHeadDim=512`, `numKeyValueHeads=1`, or 31B `headDim=160`; in-repo structural work |
| Full E2B end-to-end | Embed + 35 transformer + unembed + sample wired through the streaming runtime; in-repo structural work |
| Gemma-4 runs on Cerebras hardware | Hardware receipt via either (a) endpoint access for us to run the runner with `--cmaddr` / `csl_appliance_driver.py`, or (b) Cerebras-assisted bundle run that returns the receipt |
| Any MoE claim | Six MoE component receipts (router, top-k, dispatch, shared-expert, combine, per-expert-batching) replacing the current TODO files |

## Bundle expiration signals

- `BUNDLE_META.gitDirtyTree=true`: the bundler's working tree had
  uncommitted changes. The receipts may or may not correspond to a
  reproducible commit. Prefer a dirty=false rebuild before external
  circulation.
- Any file referenced by `MANIFEST.txt` that is missing at unpack
  time: bundle-integrity failure.
- A `hardware_success` receipt landing in-repo that postdates the
  bundle's git commit: the claim surface has expanded and the bundle
  understates current state.

## Reviewer workflow

1. Read `BUNDLE_META.json`; confirm `gitDirtyTree=false` and the
   short SHA matches what you expected.
2. Read `CLAIM_SCOPE.md`; know what the bundle backs.
3. Read `CEREBRAS_ASK.md`; it is the operator-facing command,
   endpoint-access ask, and receipt-field list.
4. Read `LOCAL_INSPECTION.md` if you want to browse the evidence in a
   browser.
5. Read `MANIFEST.txt`; see each file's `claim-role`.
6. Re-compute any `.json` sha256 you want to spot-check against the
   manifest entry.
7. Read `bench/out/cerebras-evidence-bundle/summary.json`; local gates
   should report `status=passed`, except documented skipped optional
   gates.

If any of 1-7 fails, reject the bundle and request a rebuild.
<!-- archive:CLAIM_SCOPE.md:end -->

<!-- archive:MODEL_ACCESS.md:start -->
# Gemma 4 and Qwen model access handoff

Model/cache metadata for the Cerebras evidence handoff. It pins
the local artifact identities and the environment variables that make
the raw SafeTensors, Doppler RDRR, and hardware-run commands resolve
consistently.

## Cache roots

The current Linux host should not use `/media/x/models` for Hugging
Face auth or cache state unless its permissions are fixed. A failed
`hf auth login` that tries to create
`/media/x/models/huggingface_cache` is an environment problem, not a
model problem.

Use the home-backed cache and explicit model roots:

```bash
export HF_HOME=/home/x/.cache/huggingface
export HUGGINGFACE_HUB_CACHE=/home/x/.cache/huggingface/hub
export HF_HUB_CACHE=/home/x/.cache/huggingface/hub
export DOE_MODELS_ROOT=/home/x/model-downloads
export DOE_GEMMA4_31B_SAFETENSORS_DIR=/home/x/model-downloads/gemma-4-31B-it
export DOE_RDRR_ROOT=/home/x/model-downloads/Clocksmith-rdrr
export DOE_GEMMA4_31B_AF16_MANIFEST=/home/x/model-downloads/Clocksmith-rdrr/models/gemma-4-31b-it-text-q4k-ehf16-af16/manifest.json
export DOE_QWEN3_6_27B_AF16_MANIFEST=/home/x/model-downloads/Clocksmith-rdrr/models/qwen-3-6-27b-q4k-eaf16/manifest.json
export DOE_GEMMA4_E2B_SAFETENSORS_DIR=/home/x/model-downloads/gemma4-e2b-it
export DOE_GEMMA4_E2B_RDRR_ROOT=/home/x/deco/doppler/models/local/gemma-4-e2b-it-q4k-ehf16-af32-int4ple
```

Run the preflight after changing any of those paths:

```bash
python3 bench/tools/prepare_gemma4_e2b_access.py --print-shell
```

Add `--create` to create the selected cache directories. Add
`--require-assets` when a CI/operator step must fail if the raw
SafeTensors or Doppler RDRR artifact is missing.

## Canonical artifacts

The primary 31B hardware lane starts from the Doppler af16 manifest and
its shared Q4K weight pack:

- upstream model id: `google/gemma-4-31B-it`
- upstream page: <https://huggingface.co/google/gemma-4-31B-it>
- pinned upstream revision:
  `439edf5652646a0d1bd8b46bfdc1d3645761a445`
- hosted RDRR repo: `clocksmith/rdrr`
- hosted af16 revision:
  `e6f36589da5f860d9da9b10efdc945434f1f1be2`
- hosted af16 path:
  `models/gemma-4-31b-it-text-q4k-ehf16-af16`
- hosted af32 Q4K primary path:
  `models/gemma-4-31b-it-text-q4k-ehf16-af32`
- Doppler af16 manifest:
  `$DOE_GEMMA4_31B_AF16_MANIFEST`
- Doppler primary Q4K weight pack:
  `models/local/gemma-4-31b-it-text-q4k-ehf16-af32`
- expected manifest id:
  `gemma-4-31b-it-text-q4k-ehf16-af16`
- expected shard-set hash:
  `sha256:54933058e14fa0be4480912e641b897730db3e8ee7e871bdb2a92fd404ade146`
- active Doe use: Gemma 4 31B af16 HostPlan runner, final-norm plus
  selected-logit splice receipt, and hardware transcript path

The Qwen companion hardware lane starts from the Doppler af16 manifest and
its shared Q4K weight pack:

- upstream model id: `Qwen/Qwen3.6-27B`
- hosted RDRR repo: `clocksmith/rdrr`
- hosted af16 revision:
  `3dee21b3b12d65ac7fef9b24cbf759cacc953a67`
- hosted af16 path:
  `models/qwen-3-6-27b-q4k-eaf16`
- hosted shared Q4K primary path:
  `models/qwen-3-6-27b-q4k-ehaf16`
- Doppler af16 manifest:
  `$DOE_QWEN3_6_27B_AF16_MANIFEST`
- expected manifest id:
  `qwen-3-6-27b-q4k-eaf16`
- expected shard-set hash:
  `sha256:f355a595b115d4a40041bcb2fbe4d131316e422e65df28e5ed4573d2c9051108`
- active Doe use: Qwen 3.6 27B af16 HostPlan runner, final-norm plus
  selected-logit splice receipt, and hardware transcript path

The canonical raw checkpoint source for the BF16/text oracle lane is
`google/gemma-4-E2B-it` from Hugging Face:

- upstream model id: `google/gemma-4-E2B-it`
- upstream page: <https://huggingface.co/google/gemma-4-E2B-it>
- local raw snapshot: `$DOE_GEMMA4_E2B_SAFETENSORS_DIR`
- expected local files: `config.json`, one or more `.safetensors`
  files, `tokenizer.json`, and `tokenizer_config.json`
- active Doe use: manifest-shape CPU oracle and BF16-derived
  smoke-contract layer-block slices

The canonical Doppler production-artifact lane is the local RDRR/Q4_K_M
fixture:

- fixture: `config/gemma-4-e2b-doppler-rdrr-int4ple-fixture.json`
- local root: `$DOE_GEMMA4_E2B_RDRR_ROOT`
- expected local files: `manifest.json`, `origin.json`,
  `tokenizer.json`, and shard files
- quantization: `Q4_K_M`
- active Doe use: RDRR structural probe, Q4_K_M smoke-slice
  extraction, and smoke-contract parity

Raw BF16 and RDRR/Q4_K_M are both active lanes. They prove different
things: the BF16 lane verifies the upstream text checkpoint and
smoke-contract slice extraction; the RDRR lane verifies that Doe can
consume Doppler's converted artifact shape and dequantized smoke
slices. Neither lane is full Doppler production inference parity yet.

## Download and validation commands

Authenticate without writing credentials into the model root:

```bash
hf auth login --token <token> --add-to-git-credential false
```

Download the hosted 31B RDRR pair used by the af16 hardware lane. The
af16 manifest references the af32 primary weight pack through
`weightsRef`, so both paths must be present under the same local root:

```bash
hf download clocksmith/rdrr \
  --repo-type model \
  --revision e6f36589da5f860d9da9b10efdc945434f1f1be2 \
  --include "models/gemma-4-31b-it-text-q4k-ehf16-af16/*" \
  --include "models/gemma-4-31b-it-text-q4k-ehf16-af32/*" \
  --local-dir "$DOE_RDRR_ROOT"
```

Download the hosted Qwen RDRR pair used by the af16 hardware lane. The af16
manifest references the ehaf16 shared Q4K primary weight pack through
`weightsRef`:

```bash
hf download clocksmith/rdrr \
  --repo-type model \
  --revision 3dee21b3b12d65ac7fef9b24cbf759cacc953a67 \
  --include "models/qwen-3-6-27b-q4k-eaf16/*" \
  --include "models/qwen-3-6-27b-q4k-ehaf16/*" \
  --local-dir "$DOE_RDRR_ROOT"
```

Validate the 31B Doppler artifact before running Doe:

```bash
cd /home/x/deco/doe
python3 - <<'PY'
import json
import os
import hashlib
from pathlib import Path

def sha256_file(path):
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return "sha256:" + h.hexdigest()

manifest_path = Path(os.environ["DOE_GEMMA4_31B_AF16_MANIFEST"]).resolve()
manifest = json.loads(manifest_path.read_text())
assert manifest["modelId"] == "gemma-4-31b-it-text-q4k-ehf16-af16"
weights_ref = manifest["weightsRef"]
weights_root = (manifest_path.parent / weights_ref["artifactRoot"]).resolve()
weights_manifest = json.loads((weights_root / "manifest.json").read_text())
assert sha256_file(weights_root / "manifest.json") == weights_ref["manifestDigest"]
assert weights_manifest["artifactIdentity"]["shardSetHash"] == weights_ref["shardSetHash"]
missing = [
    shard["filename"]
    for shard in weights_manifest["shards"]
    if not (weights_root / shard["filename"]).is_file()
]
if missing:
    raise SystemExit(f"missing Doppler weight shards: {missing[:5]}")
print(f"validated {manifest_path}")
PY
```

Download the raw E2B BF16 snapshot:

```bash
hf download google/gemma-4-E2B-it \
  --local-dir "$DOE_GEMMA4_E2B_SAFETENSORS_DIR"
```

Validate the raw BF16 lane:

```bash
python3 bench/tools/probe_gemma4_e2b_manifest_shape.py \
  --source-dir "$DOE_GEMMA4_E2B_SAFETENSORS_DIR"

python3 bench/tools/run_gemma4_e2b_manifest_shape_execution.py \
  --source-dir "$DOE_GEMMA4_E2B_SAFETENSORS_DIR"

python3 bench/tools/extract_gemma4_e2b_weight_slices.py \
  --source-dir "$DOE_GEMMA4_E2B_SAFETENSORS_DIR" \
  --out-json bench/out/gemma-4-e2b-real-weight-extraction.json
```

Validate the Doppler RDRR/Q4_K_M lane:

```bash
python3 bench/tools/probe_doppler_rdrr_artifact.py \
  --artifact-root "$DOE_GEMMA4_E2B_RDRR_ROOT"

python3 bench/tools/run_doppler_rdrr_q4k_parity.py \
  --artifact-root "$DOE_GEMMA4_E2B_RDRR_ROOT"
```

Those commands are path-resilient: if the environment variables above
are set, the tools use them as defaults. Explicit flags still win for
one-off runs.

## Cerebras access commands

Direct endpoint:

```bash
cs_python bench/runners/csl-runners/e2b_layer_block_smoke.py \
  --num-layers 35 \
  --compile-out bench/out/hardware-run/compile \
  --trace-out bench/out/hardware-run/trace.json \
  --weights-dir bench/out/gemma-4-e2b-real-weights \
  --cmaddr "$DOE_CSL_CMADDR"
```

WSC appliance:

```bash
python3 runtime/zig/tools/csl_appliance_driver.py \
  --code-dir bench/out/streaming-executor/e2b-layer-block-source \
  --layout layout.csl \
  --compiler-args "<operator-supplied cslc args>" \
  --compile-output bench/out/hardware-run/compile \
  --runner-command "cs_python bench/runners/csl-runners/e2b_layer_block_smoke.py --num-layers 35 --compile-out bench/out/hardware-run/compile --trace-out bench/out/hardware-run/trace.json --weights-dir bench/out/gemma-4-e2b-real-weights --cmaddr %CMADDR%" \
  --download "bench/out/hardware-run/trace.json:bench/out/hardware-run/trace.json" \
  --receipt-out bench/out/hardware-run/appliance-receipt.json \
  --system
```

The WSC command uses `%CMADDR%` so `SdkLauncher` resolves the endpoint
at run time. Receipts redact that to `$DOE_CSL_CMADDR`; raw endpoints
and credentials must not be checked into repo artifacts.

## First demo scope

The first demo should show:

- E2B slice proof as the primary live row: Doppler/RDRR identity,
  BF16/RDRR slice provenance, SdkLayout smoke status, parity, and
  blockers
- 31B dense as a structural/blocked row: stream graph and model receipt
  present, execution/hardware absent
- Cerebras hardware as absent until a `hardware_success` receipt exists

Do not show full E2B, 31B execution, MoE, or performance claims as
green until the corresponding model-level and hardware receipts exist.
<!-- archive:MODEL_ACCESS.md:end -->

<!-- archive:CEREBRAS_ASK.md:start -->
# Cerebras operator: ask

Operator-facing page for whoever at Cerebras is running the validation
on the endpoint. Tight and single-purpose. The rest of the bundle's
documents are reviewer-facing; this one is for the person pressing
Enter on the hardware.

Before running, read `MODEL_ACCESS.md` in the bundle. It pins model-access
policy, writable Hugging Face cache env vars, and the claim boundary. The
primary hardware ask is the Gemma 4 31B af16 full-prompt HostPlan run. Qwen
3.6 27B now has a matching af16 full-prompt HostPlan wrapper for the companion
hybrid-architecture lane. The layer-block runner is a bounded fallback, not
the main claim.

Current local bridge evidence: the final-norm plus selected-logit splice at
`bench/out/r3-1-31b-af16-doppler-csl-splice/selected-logit-splice/selected-logit-splice.json`
uses the real Gemma 4 31B af16 hidden state for
`<bos>The color of the sky is`, real tied lm-head weights, and generated CSL.
It computes final RMSNorm and Doppler's selected lm-head candidate logits,
keeps token `3730` (` blue`) as the winner, and records the candidate-count,
max selected-logit diff, final-norm diff, and decision margin bound in the
receipt.
This is not full hardware parity; it is the local bridge proof the hardware
path is meant to extend.

The Qwen companion receipt is
`bench/out/r3-2-27b-af16-doppler-csl-splice/selected-logit-splice/selected-logit-splice.json`.
It binds the real Qwen 3.6 27B final-prompt state, CSL-owned final RMSNorm,
selected Q4_K_M lm-head rows, generated CSL, and the same top-token decision
check. It has the same boundary: selected-logit local proof, not a hardware
receipt.

## Two paths

**Path A: endpoint access.** We run the runner from our side against a
Cerebras-provided endpoint:

1. **Reachable CS/WSC endpoint.** Either a direct `--cmaddr <ip:port>`
   target or an appliance SdkLauncher endpoint.
2. **SDK Python environment** matching the `csPython` on the bundler's
   host. SDK 2.10 is the active Doe CSL floor; older receipts are
   historical and should not be used for new hardware claims.
3. **Authorization to run the runner** in `bench/runners/csl-runners/`
   against the endpoint with the pinned manifest, HostPlan, CSL, and
   Doppler weight artifact.

**Path B: Cerebras-assisted source checkout run.** A Cerebras engineer
runs the same commands internally and returns the receipt artifacts:

1. **Clone Doe at the archive commit** and verify the archive.
2. **Fetch the Doppler RDRR artifact** from `clocksmith/rdrr`, or mount an
   already-validated copy.
3. **Build generated CSL, compile it with cslc, run the full-prompt
   HostPlan runner, and return the trace artifacts.**
4. **Redact what your policy requires.** Every `hardware.*` field has
   an explicit `"redacted"` convention so we can compare receipts
   without leaking endpoint identity.

## What to run

Clone the source checkout. For a repo-published bundle, the archive is already
in the checkout and the wrapper verifies it before running:

```bash
git clone https://github.com/doerun/doe.git
cd doe
git checkout <bundle-commit>

python3 -m venv .venv
. .venv/bin/activate
python3 -m pip install numpy jsonschema huggingface_hub

mkdir -p bench/out/hardware-run
```

Then run the Gemma wrapper. It performs the hosted RDRR fetch and validation,
bundled archive verification, SDK compile from the bundled HostPlan source,
and full-prompt hardware execution. The endpoint is the required run
parameter.

```bash
export CMADDR=<operator-supplied>

bench/tools/run_gemma4_31b_af16_hardware_path.sh \
  --cmaddr "$CMADDR"
```

`clocksmith/rdrr` is publicly fetchable. Pass `--hf-token <token>` only if the
host wants authenticated Hugging Face access. The default path does not require
`zig`; use `--rebuild-hostplan` only when regenerating HostPlan/CSL from the
execution-v1 input:

```bash
bench/tools/run_gemma4_31b_af16_hardware_path.sh \
  --cmaddr "$CMADDR" \
  --rebuild-hostplan
```

If the evidence archive is supplied separately instead of through the repo,
pass `--archive <path>`.

For the Qwen companion lane, use the matching wrapper:

```bash
bench/tools/run_qwen3_6_27b_af16_hardware_path.sh \
  --cmaddr "$CMADDR"
```

That wrapper fetches `clocksmith/rdrr` revision
`3dee21b3b12d65ac7fef9b24cbf759cacc953a67`, model path
`models/qwen-3-6-27b-q4k-eaf16`, and the shared weight pack
`models/qwen-3-6-27b-q4k-ehaf16`. It uses the bundled HostPlan source under
`bench/fixtures/cerebras-hostplans/qwen3-6-27b-af16/`.

Before running on hardware, confirm the Cerebras SDK is available: expose
`cslc` through `PATH` or `--cslc-executable`, and use a Python environment that
can import `cerebras.sdk.runtime.sdkruntimepybind`.

The wrapper expands to the commands below. Keep them here for audit and for
operators who prefer each step separated.

Fetch the hosted model artifact if a validated RDRR copy is not already
mounted. The af16 manifest references the af32 primary weight pack through
`weightsRef`, so both paths must be present under the same local root:

```bash
export HF_HOME="${HF_HOME:-$HOME/.cache/huggingface}"
export HUGGINGFACE_HUB_CACHE="${HUGGINGFACE_HUB_CACHE:-$HF_HOME/hub}"
export HF_HUB_CACHE="${HF_HUB_CACHE:-$HF_HOME/hub}"
export DOE_RDRR_ROOT="${DOE_RDRR_ROOT:-$PWD/../rdrr-cache/Clocksmith-rdrr}"

hf auth login --token <token> --add-to-git-credential false

hf download clocksmith/rdrr \
  --repo-type model \
  --revision e6f36589da5f860d9da9b10efdc945434f1f1be2 \
  --include "models/gemma-4-31b-it-text-q4k-ehf16-af16/*" \
  --include "models/gemma-4-31b-it-text-q4k-ehf16-af32/*" \
  --local-dir "$DOE_RDRR_ROOT"

export DOE_GEMMA4_31B_AF16_MANIFEST="$DOE_RDRR_ROOT/models/gemma-4-31b-it-text-q4k-ehf16-af16/manifest.json"
```

Validate the manifest and shared Q4K shards:

```bash
python3 - <<'PY'
import json
import os
import hashlib
from pathlib import Path

def sha256_file(path):
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return "sha256:" + h.hexdigest()

manifest_path = Path(os.environ["DOE_GEMMA4_31B_AF16_MANIFEST"]).resolve()
manifest = json.loads(manifest_path.read_text())
assert manifest["modelId"] == "gemma-4-31b-it-text-q4k-ehf16-af16"
weights_ref = manifest["weightsRef"]
weights_root = (manifest_path.parent / weights_ref["artifactRoot"]).resolve()
weights_manifest = json.loads((weights_root / "manifest.json").read_text())
assert sha256_file(weights_root / "manifest.json") == weights_ref["manifestDigest"]
assert weights_manifest["artifactIdentity"]["shardSetHash"] == weights_ref["shardSetHash"]
missing = [
    shard["filename"]
    for shard in weights_manifest["shards"]
    if not (weights_root / shard["filename"]).is_file()
]
if missing:
    raise SystemExit(f"missing Doppler weight shards: {missing[:5]}")
print(f"validated {manifest_path}")
PY
```

Build the generated HostPlan/CSL bundle and compile the targets:

```bash
zig build csl-host-plan-tool

runtime/zig/zig-out/bin/doe-csl-host-plan-tool \
  --input runtime/zig/examples/execution-v1/gemma-4-31b-af16-smoke.json \
  --bundle-root bench/out/hardware-run/gemma4-31b-af16-hostplan \
  --mode steps \
  --cslc-executable cslc

python3 runtime/zig/tools/csl_sdk_driver.py \
  bench/out/hardware-run/gemma4-31b-af16-hostplan/simulator-plan.json \
  --cslc-executable cslc
```

Replace `cslc` with the SDK-local executable path if it is not on `PATH`.

Run the full-prompt hardware path. The prompt token IDs are
`<bos>The color of the sky is`; the Doppler reference continuation is
token `3730` (` blue`).

```bash
python3 bench/runners/csl-runners/gemma4_31b_af16_hostplan_streaming_runner.py \
  --source-doppler-manifest "$DOE_GEMMA4_31B_AF16_MANIFEST" \
  --smoke-config runtime/zig/examples/execution-v1/gemma-4-31b-af16-smoke.json \
  --host-plan bench/out/hardware-run/gemma4-31b-af16-hostplan/host-plan.json \
  --simulator-plan bench/out/hardware-run/gemma4-31b-af16-hostplan/simulator-plan.json \
  --runtime-config bench/out/hardware-run/gemma4-31b-af16-hostplan/runtime-config.json \
  --compile-root bench/out/hardware-run/gemma4-31b-af16-hostplan/compile \
  --prefill-token-count 7 \
  --decode-token-count 2 \
  --prompt-token-id 2 \
  --prompt-token-id 818 \
  --prompt-token-id 2258 \
  --prompt-token-id 529 \
  --prompt-token-id 506 \
  --prompt-token-id 7217 \
  --prompt-token-id 563 \
  --execute \
  --cmaddr <operator-supplied> \
  --session-lm-head-dispatch-mode dense_gemv_width_tiled_session \
  --session-lm-head-tile-width 32 \
  --session-lm-head-tile-dispatch-budget 0 \
  --session-prefill-q4k-gemv-output-pe-rows 4 \
  --session-out-dir bench/out/hardware-run/gemma4-31b-af16-session \
  --out bench/out/hardware-run/gemma4-31b-af16-trace.json
```

Return the top-level trace, the session trace, the progress log, and
the driver result files under `bench/out/hardware-run/`.

## Bounded fallback runs

These are useful if the endpoint owner wants a smaller preflight first.
They are not full-prompt Gemma 4 31B evidence.

Layer-block smoke on real-weight smoke slices:

```bash
export DOE_GEMMA4_31B_SAFETENSORS_DIR="${DOE_GEMMA4_31B_SAFETENSORS_DIR:-$PWD/../model-downloads/gemma-4-31B-it}"

hf download google/gemma-4-31B-it \
  --revision 439edf5652646a0d1bd8b46bfdc1d3645761a445 \
  --local-dir "$DOE_GEMMA4_31B_SAFETENSORS_DIR"
```

```bash
python3 bench/tools/extract_gemma4_31b_weight_slices.py \
  --source-dir "$DOE_GEMMA4_31B_SAFETENSORS_DIR" \
  --projection-substitute-tensor pre_feedforward_layernorm.weight \
  --linear-attention-policy skip-with-layout-metadata \
  --out-dir bench/out/gemma-4-31b-real-weights \
  --out-json bench/out/gemma-4-31b-real-weights/verdict.json

cs_python bench/runners/csl-runners/gemma_4_31b_layer_block_smoke.py \
  --num-layers 61 \
  --size 1024 \
  --weights-dir bench/out/gemma-4-31b-real-weights \
  --compile-out bench/out/hardware-run/layer-block-smoke-compile \
  --trace-out bench/out/hardware-run/layer-block-smoke-trace.json \
  --cmaddr <operator-supplied>
```

Gemma af16 lm-head cell:

```bash
python3 bench/tools/run_gemma4_31b_af16_simfabric_cells.py \
  --cmaddr <operator-supplied>
```

## What to return

For the full-prompt run, return these files when present:

- `bench/out/hardware-run/gemma4-31b-af16-trace.json`
- `bench/out/hardware-run/gemma4-31b-af16-session/trace.json`
- `bench/out/hardware-run/gemma4-31b-af16-session/progress.jsonl`
- `bench/out/hardware-run/gemma4-31b-af16-hostplan/trace.json.driver-result.json`

For any returned receipt, fill explicit fields with `"redacted"` rather
than omitting them when operator policy does not allow disclosure.

- `hardware.endpoint`: operator-scoped tag, not raw IP, or `"redacted"`
- `hardware.jobId`: provider-assigned job identifier, or `"redacted"`
- `hardware.sdkVersion`: Cerebras SDK release string
- `hardware.fabricId`: fabric identity for trace pinning
- `hardware.deviceArch`: e.g. `"wse3"`
- `executedCompile.elapsedMs`: only if operator authorizes disclosure;
  otherwise `"redacted"`
- `executedRun.elapsedMs`: same disclosure policy
- `executedRun.status`: `"succeeded"` or `"failed:<taxonomy>"`
- `executedRun.generatedTokenIds`: if the full-prompt run reaches token
  output
- `executedRun.logitsDigest` or `executedRun.output.sha256`: if logits
  or output tensors are returned
- `executedRun.blocker`: typed blocker if the run stops before token
  output
- `executedRun.lastPhaseReached`: final phase marker when available
- `claimScope`: explicit `{claimable: [...], notClaimable: [...]}`

## What we will NOT publish without written approval

- Any hardware timing beyond what the operator authorizes
- Endpoint identity (IP, physical location, rack/appliance IDs)
- Queue-depth, fabric-level, or operator-internal telemetry in SDK logs
- Any performance claim beyond the receipt's own local numerical
  comparison fields
- Comparisons against other hardware unless the methodology is jointly
  signed off

See `docs/claim-discipline.md` for the full enforcement policy. The
claim-discipline gate in this repo rejects any performance prose that
does not cite a `hardware_success` receipt; the gate only goes INACTIVE
when such a receipt exists in `bench/out/`.

## Point of contact

Questions, clarifications, or receipt-field negotiation: reply to the
email thread this archive came from, or the sender address on the
outreach message. The Doe team is the point of contact; we handle the
interpretation side of anything that comes back.

`docs/cerebras-hardware-runbook.md` is the parent runbook;
`CEREBRAS_ASK.md` is its operational distillation. If the two ever
disagree, the runbook wins.
<!-- archive:CEREBRAS_ASK.md:end -->

<!-- archive:LOCAL_INSPECTION.md:start -->
# Bundle: local inspection

Commands for a reviewer who has unpacked the bundle into a repo
checkout and wants to browse the evidence with the same browser tools
the bundler uses. All commands assume the repo root is the current
directory.

## Pre-flight

```bash
python3 bench/tools/verify_cerebras_validation_archive.py \
  --archive <the tarball you received>
```

Must PASS before acting on anything inside. The verifier re-checks
every manifest sha, BUNDLE_META shape, claim-role taxonomy, and runs
the claim-discipline regex scan against every doc in the archive.

## Status dashboard (static)

Shows the rollup of target matrix + claim badges in one view.

```bash
# No server needed; static HTML
open demos/doe-status-dashboard/index.html
```

Or behind any static HTTP server if the browser refuses `file://`
relative fetches.

## E2B side-by-side demo (static OR with local CSL)

Shows WebGPU + CSL simfabric + CSL-WebGPU-emulator output comparisons
with the evidence cockpit strip.

Static-only mode:

```bash
python3 -m http.server 8020
# then open http://localhost:8020/demos/gemma4-e2b-csl-sim/
# click "Load Stored CSL" to fetch the pinned L=1 reference trace
```

Live mode, requiring `cs_python` on PATH:

```bash
python3 demos/gemma4-e2b-csl-sim/server.py --port 8020
# then open http://localhost:8020/demos/gemma4-e2b-csl-sim/
# "Run CSL Simulator" now dispatches a live cs_python invocation
```

## SDK-GUI-style spatial compute viewer

```bash
python3 demos/gemma4-e2b-csl-sim/server.py --port 8030
# then open http://localhost:8030/demos/doe-sdk-gui-viewer/
# default path auto-loads compile-L1; paste another compile workdir
# into the work-directory input to inspect that spatial compute state
```

The viewer is shaped after the Cerebras SDK GUI reference screenshots:
work-directory bar, route/color selector, scalable fabric viewport, PE
coordinate selector and drilldown, instruction/source/wavelet timeline
panes, debug pane, timeline navigation controls, and a terminal drawer
for exported commands.

It inspects repo-relative compile workdirs through the same
metadata-only server routes used by the E2B side-by-side demo. It maps
colors.json, host-I/O streams, stream telemetry, trace status, and Doe
evidence-bundle verdicts into the GUI without returning `.elf`, `.map`,
`.symbols`, `.viz`, or other SDK-owned file bytes.

The command strip also exposes copyable local commands for:

- `sdk_debug_shell visualize --artifact_dir ...` once the compile
  workdir is validated
- `python3 bench/tools/run_cerebras_evidence_bundle.py`
- `python3 bench/tools/pack_cerebras_validation_archive.py`
- `python3 bench/tools/verify_cerebras_validation_archive.py --archive ...`

On LAN HTTP origins where `navigator.clipboard` is blocked, the viewer
falls back to the browser's user-gesture copy path. When path redaction
is enabled, local-path commands are shown but not copyable.

## `sdk_debug_shell visualize` command

If the bundler's `BUNDLE_META.csPython.csPythonAvailableOnBundler` is
`true`, Cerebras SDK was reachable at pack time. The matching native
visualize command on a Cerebras-SDK-equipped host:

```bash
sdk_debug_shell visualize --artifact_dir <compile-workdir>
```

The `<compile-workdir>` is the compile workdir the runner wrote `.elf`,
`.lst`, `.map`, `.symbols`, and `.viz` files into during compilation.
These files are explicitly excluded from this bundle; they contain
SDK-internal binary artifacts that a reviewer should not receive
through a shared archive.

If `BUNDLE_META.csPython.csPythonAvailableOnBundler` is `false`, the
bundler had no Cerebras SDK installed; the visualize command is not
available via this bundle. Reviewers with their own SDK installation
can re-run the runner (see `CEREBRAS_ASK.md`) against the pinned
manifest/graph/kernel hashes in this bundle to produce their own
compile workdir, then visualize it locally.

## Archive summary

```bash
bench/tools/summarize_cerebras_evidence_archive.sh <archive>
```

Prints E2B/31B/MoE status, bundle gate verdict, manifest-shape
contract, RDRR Q4_K_M parity, declared-depth diagnostics, and emulator
verdicts entirely from inside the tarball via `tar -xzO | jq`, no
unpack needed.

## Evidence-bundle regen (on the bundler's tree)

```bash
python3 bench/tools/run_cerebras_evidence_bundle.py
```

Runs the local gates the bundle's
`rollup/cerebras-evidence-bundle/summary.json` captures. Useful if a
reviewer wants to confirm the same `verdict=passed` the archive records
still holds on the current repo state.

## Closing the loop

After a `hardware_success` receipt lands, re-run
`pack_cerebras_validation_archive.py` to produce a new archive whose
`BUNDLE_META.gitCommit` postdates the receipt and whose
claim-discipline gate state flips to INACTIVE for hardware-gated rules.
<!-- archive:LOCAL_INSPECTION.md:end -->
