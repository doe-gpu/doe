# Cerebras hardware runbook

Operator-facing entry point for testing Doe's Gemma 4 31B and Qwen 3.6 27B
lanes on Cerebras WSE/WSC. Deeper architecture, claim taxonomy, and acceptance
bars live under the cross-references at the bottom.

## What this runbook covers

Two model lanes share the same CSL toolchain, the same evidence-bundle layout,
and the same hardware-ask shape:

- Gemma 4 31B dense — primary first hardware target
- Qwen 3.6 27B hybrid (full-attention + DeltaNet SSM) — second model target

Each lane now has a full-prompt af16 HostPlan runner and bounded fallback
surfaces. Keep the labels separate:

- **Full-prompt af16 HostPlan runner.** Uses the Doppler Gemma 4 31B af16
  or Qwen 3.6 27B af16 manifest, real Q4K weight shards, generated
  HostPlan/CSL, and concrete prompt token IDs. This is the hardware target
  that can return a token/logit/KV transcript or a fail-closed hardware
  blocker.
- **Layer-block smoke runner.** Bounded shape only. Useful for SDK, endpoint,
  receipt-shape, and optional real-weight smoke checks. Not a full-prompt run.
- **Per-kernel cells.** Bounded kernel checks. Useful for targeted parity and
  hardware bring-up. Not a full-model transcript.

## Two paths to a hardware receipt

Either path produces the same receipt shape. Pick whichever the endpoint
provider prefers.

- **Path A — endpoint access.** Cerebras provides a reachable CS/WSC endpoint
  and we run the runner from our side with `--cmaddr <addr>`.
- **Path B — Cerebras-assisted source checkout run.** A Cerebras engineer
  clones Doe at the bundle commit, verifies the archive, runs the commands
  below internally, and returns the receipt artifacts. Nothing from our side
  has to execute on Cerebras infrastructure.

## Reference

| Resource | Where |
|---|---|
| Current bundle pointer (auto-generated) | [`docs/cerebras-evidence-bundle-pointer.md`](cerebras-evidence-bundle-pointer.md) |
| Bundle source (packer extracts archive root files from this) | [`docs/cerebras-evidence-bundle.md`](cerebras-evidence-bundle.md) |
| Build a fresh bundle | `bench/tools/prepare_cerebras_validation_bundle.sh` |
| Build emulator source archive | `python3 bench/tools/pack_cerebras_emulator_source_archive.py` |
| Verify a received archive | `python3 bench/tools/verify_cerebras_validation_archive.py --archive <path>` |
| Run Gemma full-prompt hardware path | `bench/tools/run_gemma4_31b_af16_hardware_path.sh --cmaddr <endpoint>` |
| Run Qwen full-prompt hardware path | `bench/tools/run_qwen3_6_27b_af16_hardware_path.sh --cmaddr <endpoint>` |
| Summarize an archive without unpacking | `bench/tools/summarize_cerebras_evidence_archive.sh <path>` |
| Verify a returned hardware receipt | `python3 bench/tools/verify_returned_hardware_receipt.py --receipt <path>` |
| Check no-hardware Qwen readiness classification | `python3 bench/tools/check_cerebras_no_hardware_readiness.py` |
| Governance + claim boundaries | [`docs/hardware-validation-appendix.md`](hardware-validation-appendix.md) |
| Cerebras lane front door | [`docs/cerebras.md`](cerebras.md) |
| Model ledgers (acceptance bars + blockers) | [`docs/cerebras-model-ledgers.md`](cerebras-model-ledgers.md) |
| Live status snapshot | `bench/out/r3-cerebras-status/snapshot.md` (run `bench/tools/cerebras_status_snapshot.py`) |
| Live status shard | [`docs/status/cerebras-csl.md`](status/cerebras-csl.md) |
| Active fail-closed queue (Gemma) | `cerebras-model-ledgers.md` § Active fail-closed queue |

## Operator setup

All commands in this section run from the Doe repository root unless a command
explicitly changes directory. For a repo-published bundle, clone the pinned
checkout and let the wrapper verify the bundled archive:

```bash
git clone https://github.com/doerun/doe.git
cd doe
git checkout <bundle-commit>

python3 -m venv .venv
. .venv/bin/activate
python3 -m pip install numpy jsonschema huggingface_hub

mkdir -p bench/out/hardware-run
```

The hardware host must also provide the Cerebras SDK surface: `cslc` on `PATH`
or passed with `--cslc-executable`, and a Python environment that can import
`cerebras.sdk.runtime.sdkruntimepybind`.

The full-prompt wrappers fetch hosted Doppler RDRR artifacts from
`clocksmith/rdrr`; no safetensors conversion is part of the HostPlan hardware
path. The Gemma manual fetch is:

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

Validate the Doppler artifact before launching hardware:

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

## Scripted Gemma run

The wrapper below performs the common operator steps after checkout: bundled
archive verification, hosted RDRR fetch, RDRR validation, SDK compile, and
full-prompt hardware execution. The checkout carries the evidence archive and
bundled HostPlan source, so the endpoint is the only required run parameter.

```bash
export CMADDR=<operator-supplied>

bench/tools/run_gemma4_31b_af16_hardware_path.sh \
  --cmaddr "$CMADDR"
```

`clocksmith/rdrr` is publicly fetchable. Pass `--hf-token <token>` only if the
host wants authenticated Hugging Face access.

The default path does not require `zig`; it uses the bundled HostPlan source
and compiles it with `cslc`. To regenerate HostPlan/CSL from the execution-v1
input instead, pass `--rebuild-hostplan`:

```bash
bench/tools/run_gemma4_31b_af16_hardware_path.sh \
  --cmaddr "$CMADDR" \
  --rebuild-hostplan
```

If the evidence archive is supplied separately instead of through the repo,
pass `--archive <path>`.

## Scripted Qwen run

The Qwen wrapper uses the same operator shape as Gemma: archive verification,
hosted RDRR fetch, RDRR validation, SDK compile from the bundled HostPlan
source, then full-prompt hardware execution. The endpoint is the required run
parameter.

```bash
export CMADDR=<operator-supplied>

bench/tools/run_qwen3_6_27b_af16_hardware_path.sh \
  --cmaddr "$CMADDR"
```

`clocksmith/rdrr` is publicly fetchable. Pass `--hf-token <token>` only if the
host wants authenticated Hugging Face access.

The default path does not require `zig`; it uses the bundled HostPlan source
and compiles it with `cslc`. To regenerate HostPlan/CSL from the execution-v1
input instead, pass `--rebuild-hostplan`:

```bash
bench/tools/run_qwen3_6_27b_af16_hardware_path.sh \
  --cmaddr "$CMADDR" \
  --rebuild-hostplan
```

If the evidence archive is supplied separately instead of through the repo,
pass `--archive <path>`.

## Current local evidence

The strongest local no-hardware check is the final-norm plus selected-logit splice:
`bench/out/r3-1-31b-af16-doppler-csl-splice/selected-logit-splice/selected-logit-splice.json`.
It uses the real Gemma 4 31B af16 hidden state for
`<bos>The color of the sky is`, real tied lm-head weights, and generated CSL.
The CSL path computes final RMSNorm and the selected lm-head candidate logits,
keeps token `3730` (` blue`) as the winner, and records the candidate-count,
max selected-logit diff, final-norm diff, and decision margin bound in the
receipt. The companion Qwen receipt at
`bench/out/r3-2-27b-af16-doppler-csl-splice/selected-logit-splice/selected-logit-splice.json`
does the same for Qwen 3.6 27B.

Do not treat that as full hardware parity. It is the bridge proof that says the
same model artifact and generated CSL preserve the local reference's top-token
decision on manifest-shape candidate logits after CSL-owned final norm. The
hardware run below is the full-prompt validation path.

## Gemma 4 31B runner steps

### Full-prompt af16 HostPlan run

The scripted path above is the preferred operator command. The manual sequence
below is the same path expanded for audit.

Build the generated HostPlan/CSL bundle from source, then compile every target
with the SDK driver:

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

Run the full-prompt HostPlan against the endpoint. The prompt token IDs below
are `<bos>The color of the sky is`; the Doppler reference continuation is token
`3730` (` blue`).

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

Return:

- `bench/out/hardware-run/gemma4-31b-af16-trace.json`
- `bench/out/hardware-run/gemma4-31b-af16-session/trace.json`
- `bench/out/hardware-run/gemma4-31b-af16-session/progress.jsonl`
- any `*.driver-result.json` files under `bench/out/hardware-run/`

This is the primary Gemma hardware path. A successful run closes the
token/logit/KV transcript lane for the provided prompt. A blocked run is still
useful if it returns the named blocker and the phase reached.

### Bounded layer-block fallback

Use this only as an endpoint and receipt-shape check, or as a labeled
`real_weight_smoke_shape` run after the smoke slices below are materialized. It
is not a full-prompt Gemma 4 31B run.

The fallback extractor reads raw safetensors, not the primary RDRR artifact:

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

### AF16 simfabric cells

Gemma also has a bounded production-named CSL cell under
`bench/runners/csl-runners/gemma-4-31b-af16-cells/`. Regenerate the local
receipt set with:

```bash
python3 bench/tools/run_gemma4_31b_af16_simfabric_cells.py
```

The current cell is `lm_head_prefill`. It compiles and runs the
dense-GEMV lm-head path at bounded shape, stages f16 activation and weight
payloads, reduces f32 partials across the row chain, and compares the sink
output with a host f32 oracle. The summary receipt is:

`bench/out/r3-1-31b-gemma-af16-simfabric-cells/summary-receipt.json`

For endpoint validation, pass:

```bash
python3 bench/tools/run_gemma4_31b_af16_simfabric_cells.py \
  --cmaddr <operator-supplied>
```

This is cell-level correctness evidence. It is not full 31B manifest-shape
execution and does not replace a returned hardware transcript.

### Current Gemma 31B blocker

`cerebras-model-ledgers.md` Layer C is fail-closed on **Gemma af16 lm-head
dispatch evidence**. The bounded receipt at
`bench/out/r3-1-31b-af16-bounded-inference-smoke/receipt.json` validates the
f16 dtype contract but records `inferenceEvidenceGate.dispatch_evidence_lm_head_unbound`
because no token/logit/KV transcript exists yet. Diagnostic multi-row split-D2H
tiles still hang at `memcpy_d2h_start`; the live simfabric session
(`bench/out/r3-1-31b-af16-hostplan-session-bos-raw-sky-color-is-fast-embed512`)
is historical local evidence. The current hardware target is the full-prompt
af16 HostPlan runner above; a returned hardware trace is what closes or names
the remaining token/logit/KV blocker.

## Qwen 3.6 27B runner steps

### Full-prompt af16 HostPlan run

The scripted path above is the preferred operator command. The manual sequence
below is the same path expanded for audit.

Fetch the hosted model artifact if a validated RDRR copy is not already
mounted. The af16 manifest references the shared Q4K primary weight pack
through `weightsRef`, so both paths must be present under the same local root:

```bash
export HF_HOME="${HF_HOME:-$HOME/.cache/huggingface}"
export HUGGINGFACE_HUB_CACHE="${HUGGINGFACE_HUB_CACHE:-$HF_HOME/hub}"
export HF_HUB_CACHE="${HF_HUB_CACHE:-$HF_HOME/hub}"
export DOE_RDRR_ROOT="${DOE_RDRR_ROOT:-$PWD/../rdrr-cache/Clocksmith-rdrr}"

hf download clocksmith/rdrr \
  --repo-type model \
  --revision 3dee21b3b12d65ac7fef9b24cbf759cacc953a67 \
  --include "models/qwen-3-6-27b-q4k-eaf16/*" \
  --include "models/qwen-3-6-27b-q4k-ehaf16/*" \
  --local-dir "$DOE_RDRR_ROOT"

export DOE_QWEN3_6_27B_AF16_MANIFEST="$DOE_RDRR_ROOT/models/qwen-3-6-27b-q4k-eaf16/manifest.json"
```

Build the generated HostPlan/CSL bundle from source, then compile every target
with the SDK driver:

```bash
zig build csl-host-plan-tool

runtime/zig/zig-out/bin/doe-csl-host-plan-tool \
  --input runtime/zig/examples/execution-v1/qwen-3-6-27b-smoke.json \
  --bundle-root bench/out/hardware-run/qwen3-6-27b-af16-hostplan \
  --mode steps \
  --cslc-executable cslc

python3 runtime/zig/tools/csl_sdk_driver.py \
  bench/out/hardware-run/qwen3-6-27b-af16-hostplan/simulator-plan.json \
  --cslc-executable cslc
```

Replace `cslc` with the SDK-local executable path if it is not on `PATH`.

Run the full-prompt HostPlan against the endpoint. The prompt token IDs are
the Qwen chat-template form of `The color of the sky is`; the Doppler
reference continuation starts with token `760` (`The`).

```bash
python3 bench/runners/csl-runners/qwen3_6_27b_af16_hostplan_streaming_runner.py \
  --source-doppler-manifest "$DOE_QWEN3_6_27B_AF16_MANIFEST" \
  --smoke-config runtime/zig/examples/execution-v1/qwen-3-6-27b-smoke.json \
  --host-plan bench/out/hardware-run/qwen3-6-27b-af16-hostplan/host-plan.json \
  --simulator-plan bench/out/hardware-run/qwen3-6-27b-af16-hostplan/simulator-plan.json \
  --runtime-config bench/out/hardware-run/qwen3-6-27b-af16-hostplan/runtime-config.json \
  --compile-root bench/out/hardware-run/qwen3-6-27b-af16-hostplan/compile \
  --prefill-token-count 18 \
  --decode-token-count 8 \
  --prompt-token-id 248045 \
  --prompt-token-id 846 \
  --prompt-token-id 198 \
  --prompt-token-id 760 \
  --prompt-token-id 1829 \
  --prompt-token-id 314 \
  --prompt-token-id 279 \
  --prompt-token-id 12515 \
  --prompt-token-id 369 \
  --prompt-token-id 248046 \
  --prompt-token-id 198 \
  --prompt-token-id 248045 \
  --prompt-token-id 74455 \
  --prompt-token-id 198 \
  --prompt-token-id 248068 \
  --prompt-token-id 271 \
  --prompt-token-id 248069 \
  --prompt-token-id 271 \
  --execute \
  --cmaddr <operator-supplied> \
  --session-lm-head-dispatch-mode dense_gemv_width_tiled_session \
  --session-lm-head-tile-width 32 \
  --session-lm-head-tile-dispatch-budget 0 \
  --session-prefill-q4k-gemv-output-pe-rows 4 \
  --session-out-dir bench/out/hardware-run/qwen3-6-27b-af16-session \
  --out bench/out/hardware-run/qwen3-6-27b-af16-trace.json
```

Return:

- `bench/out/hardware-run/qwen3-6-27b-af16-trace.json`
- `bench/out/hardware-run/qwen3-6-27b-af16-session/trace.json`
- `bench/out/hardware-run/qwen3-6-27b-af16-session/progress.jsonl`
- any `*.driver-result.json` files under `bench/out/hardware-run/`

### Bounded cell checks

Qwen also keeps per-kernel CSL cells under
`bench/runners/csl-runners/qwen-3-6-27b-cells/`. Each cell is a bounded
kernel check with its own `cs_python` driver.

Run any one cell against a reachable endpoint:

```bash
cs_python bench/runners/csl-runners/qwen-3-6-27b-cells/<kernel>_run.py \
    --cmaddr <operator-supplied> \
    --out-receipt bench/out/hardware-run/qwen-<kernel>-receipt.json
```

The 10 cells today are: `rmsnorm`, `rope_partial`, `residual`, `silu`,
`embed`, `tiled` (SUMMA matmul), `kv_write`, `gemv` (Q4_K dequant + GEMV),
`sample`, and `attn_decode`. `attn_prefill` is not packaged as a
standalone small-shape cell — it is covered by the manifest-shape
semantic-pattern path `attention_prefill_kv_axis_sharded`, which
compiles cleanly under the current SDK driver with multi-Q
causal-prefill and per-PE residency under the WSE-3 budget. The earlier
`linker_pe_memory_overflow` blocker is closed; see
[`docs/cerebras-model-ledgers.md`](cerebras-model-ledgers.md)
for the audit trail.

The aggregator at
`bench/tools/synthesize_qwen_3_6_27b_simfabric_cells_summary_receipt.py` rolls
cell receipts into one summary at
`bench/out/r3-2-27b-qwen-simfabric-cells/summary-receipt.json`.

### Multi-token decode chain

Higher-level Qwen prefill + decode orchestration runs through:

```bash
cs_python bench/runners/csl-runners/multi_token_decode_orchestrator_qwen.py \
    --cmaddr <operator-supplied>
```

This is correctness-oriented chain evidence, not a replacement for the
full-prompt HostPlan hardware path above.

### Local simfabric ceiling probe

The local probe below uses the same Qwen full-prompt runner without `cmaddr`
and writes a receipt that records the first observed local blocker:

```bash
python3 bench/tools/run_qwen3_6_27b_af16_local_simfabric_ceiling.py
```

The Qwen probe forwards the same embedding ROI controls as the hardware
wrapper. The default is recorded in the receipt; pass
`--session-embed-roi-hidden-per-pe 0` to use the HostPlan compile parameter.

Receipt path:

`bench/out/r3-2-27b-af16-local-simfabric-ceiling/receipt.json`

### Current Qwen 27B blocker

The Qwen full-graph manifest compile receipt reports `blocker.class="none"`;
the top-k Doppler-to-CSL lm-head splice is bound; the per-kernel cells pass
under documented canary constraints. The missing evidence is a returned
full-prompt hardware trace from `run_qwen3_6_27b_af16_hardware_path.sh`, or a
fail-closed trace naming the first hardware-side blocker.

## What receipt fields we need back

Emitted as `doe_target_run_receipt` (existing schema) with `target=hardware`,
plus the hardware-specific fields:

- `hardware.endpoint` — redacted (host/appliance tag, not raw IP)
- `hardware.jobId` — provider-assigned, redacted if policy requires
- `hardware.sdkVersion` — Cerebras SDK release running on the endpoint
- `hardware.fabricId` and `hardware.deviceArch` — for trace pinning
- `executedCompile.elapsedMs` and `executedRun.elapsedMs` — only if endpoint
  policy permits disclosure
- `executedRun.status` — `succeeded` / `failed:<taxonomy>`
- `executedRun.generatedTokenIds` — if the full-prompt run reaches token output
- `executedRun.logitsDigest` or `executedRun.output.sha256` — if logits or
  output tensors are returned
- `executedRun.numericalParity` — token/logit comparison against the Doppler
  reference when output is available
- `executedRun.blocker` and `executedRun.lastPhaseReached` — if the run stops
  before token output
- `cacheKeyComponents` — kernel, plan, target, and shape fields
- Signed-off `claimScope` — explicit enumeration of what the receipt does and
  does not claim

Use `verify_returned_hardware_receipt.py` to mechanically check the returned
JSON before binding it.

## Publication boundaries

Per [`docs/claim-discipline.md`](claim-discipline.md), without explicit
endpoint-provider approval we will not publish:

- Hardware timing (`elapsedMs`) beyond what the operator authorizes.
- Endpoint identity, IP, physical location, rack or appliance IDs.
- Queue-depth, fabric-level, or operator-internal telemetry surfaced in SDK
  logs.
- Any performance claim beyond the returned parity receipt's own scope.
- Comparisons against other hardware unless the methodology is jointly signed
  off.

The current public claim scope is **portability and parity**, not speed.

## Email asks

When requesting a hardware run, attach the current bundle and pull pointer
metadata from `docs/cerebras-evidence-bundle-pointer.md` for the archive sha256
and verdict line. Example body:

> Subject: Gemma 4 31B af16 HostPlan validation request on Cerebras hardware
>
> Hi <name>,
>
> We have a software evidence bundle for Doe's Gemma 4 on Cerebras lane and
> would like to validate the Gemma 4 31B af16 full-prompt HostPlan path on
> WSE/WSC.
>
> The command path is: clone Doe at the bundle commit, fetch the hosted Doppler
> Gemma 4 31B af16 RDRR artifact from `clocksmith/rdrr`, build the generated
> HostPlan/CSL bundle, compile with cslc, then run
> `gemma4_31b_af16_hostplan_streaming_runner.py` against `<bos>The color of
> the sky is`.
>
> Please return the top-level trace, session trace, progress log, and driver
> result files under `bench/out/hardware-run/`. Redact endpoint details per
> policy; the blocker taxonomy and last phase reached are enough if token
> output does not complete.
>
> Bundle pointer: <fill from docs/cerebras-evidence-bundle-pointer.md after
> clean rebuild>.
>
> We will not publish endpoint identity, fabric identity, queue details,
> hardware timing, or performance comparisons without written approval.

The Qwen 27B ask uses the same email shape with
`bench/tools/run_qwen3_6_27b_af16_hardware_path.sh` and the Qwen evidence
summary.

## Local pre-flight before sending

Before circulating a bundle externally, regenerate from a clean tree and
spot-check the verdict:

```bash
git status                                        # clean tree
bench/tools/prepare_cerebras_validation_bundle.sh # rebuild + refresh pointer
python3 bench/tools/verify_cerebras_validation_archive.py \
    --archive bench/out/$(grep -oP 'doe-cerebras-evidence-\S+\.tar\.gz' \
        docs/cerebras-evidence-bundle-pointer.md | head -1)
```

The pointer file lists the archive sha256, MANIFEST sha256, BUNDLE_META sha256,
size, git commit, dirty flag, and verdict (`passed N/N steps`). If `git dirty`
shows `dirty` in the pointer, rebuild from a clean tree before circulation.

## See also

- [`docs/cerebras.md`](cerebras.md) — single front door for the whole lane
  (progress, source, reproduce, run on hardware, why).
- [`docs/cerebras-evidence-bundle.md`](cerebras-evidence-bundle.md) — bundle
  source-of-truth (the packer extracts archive-root files from marked sections
  here).
- [`docs/hardware-validation-appendix.md`](hardware-validation-appendix.md) —
  bundle compatibility and claim-governance companion.
- [`docs/cerebras-model-ledgers.md`](cerebras-model-ledgers.md) — full
  model evidence ledgers, integrity invariants, optimization roadmap.
- [`docs/status/cerebras-csl.md`](status/cerebras-csl.md) — live status shard.
