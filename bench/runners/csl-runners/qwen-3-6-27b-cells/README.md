# Qwen 3.6 27B simfabric-cell drivers

Tracked source for the small-shape end-to-end simfabric runs of the
Qwen 3.6 27B cell set: `rmsnorm`, `rope_partial`, `residual`, `silu`,
`embed`, `tiled` (SUMMA matmul), `kv_write`, `gemv` (Q4_K dequant +
GEMV), `sample`, and `attn_decode`.

`attn_prefill` is not packaged as a standalone small-shape cell in this
directory. It is covered by the manifest-shape semantic-pattern path:
`attention_prefill_kv_axis_sharded` compiles cleanly through the current
SDK driver, with multi-Q causal-prefill and per-PE residency under the
WSE-3 budget. See `docs/cerebras-model-ledgers.md`.

Each cell is a triple of `<kernel>_layout(_patched).csl`,
`<kernel>_pe_program.csl`, and `<kernel>_run.py` (cs_python driver).
The driver compiles the cell via `cslc`, runs it under simfabric,
verifies parity vs a host-computed reference, and writes a per-kernel
receipt under `bench/out/r3-2-27b-qwen-<kernel>-simfabric-cell/`
(regeneration output, gitignored).

`bench/tools/synthesize_qwen_3_6_27b_simfabric_cells_summary_receipt.py`
aggregates the per-cell receipts into a single summary at
`bench/out/r3-2-27b-qwen-simfabric-cells/summary-receipt.json`.

## Layout patches

`rmsnorm`, `residual`, and `silu` ship `*_layout_patched.csl` because
the manifest-shape host plan
(`runtime/zig/src/compiler/wgsl/emit/csl/emit_csl_layout.zig`) deliberately does
**not** forward `hidden_size` / `chunk_size` from `layout.csl` to
`pe_program.csl`. At manifest hidden_dim=5120 the per-PE buffers
(60 KB) overflow the WSE-3 per-PE 38 KB working budget; the broader
R3-2 single-PE-reduction → fabric-shard redesign closes that gap.
For the small-shape canary the per-PE buffers fit comfortably, so the
layout is patched here to forward the param. See the `notWhat` block
in each receipt for the full rationale.

The remaining layouts already forward all per-PE shape params used by
their bounded cells.

## Cell-specific notes

- **`sample`** validates the paired value+index reduction path. Earlier
  versions only reduced the running max value; current source propagates
  the global argmax index through the chain and the cell checks it against
  `np.argmax`.

- **`attn_decode`** validates the WSE-3 async receive form for the
  reduction task. Earlier source used a synchronous receive shape that did
  not activate the receive task; current source launches and checks
  bounded scaled-dot-product softmax attention.

- **`silu`** remains a standalone passthrough cell
  (`output[idx] = input[idx] * 1.0`) and verifies that current emitted
  source faithfully executes. The model FFN path is the wired
  `silu_gated` semantic path outside this cell directory.

## Regenerating the receipts

```sh
SDK=/home/x/cerebras-sdk-2.10.0
CELLS=$PWD/bench/runners/csl-runners/qwen-3-6-27b-cells
OUT=$PWD/bench/out

for kernel in rmsnorm rope_partial residual silu embed tiled kv_write gemv sample attn_decode; do
  case "$kernel" in
    rmsnorm)      params="width:4,hidden_size:128" ;;
    rope_partial) params="width:4,head_dim:8,num_pairs:2" ;;
    residual)     params="width:4,height:1,chunk_size:128" ;;
    silu)         params="width:4,height:1,chunk_size:128" ;;
    embed)        params="width:2,height:1,hidden_size:16,hidden_per_pe:16,rows_per_pe:8,num_tokens:2,tokens_per_chunk:2" ;;
    tiled)        params="P:2,Mt:4,Kt:4,Nt:4" ;;
    kv_write)     params="width:4,height:1,head_dim:8,max_seq_len:8,slots_per_pe:8" ;;
    gemv)         params="width:4,height:1,out_dim:4,out_dim_per_pe:4,in_dim_per_pe:512,num_blocks_per_row:2" ;;
    sample)       params="width:2,chunk_size:128" ;;
    attn_decode)  params="width:1,head_dim:8,kv_chunk:8" ;;
  esac
  layout="$CELLS/${kernel}_layout_patched.csl"
  [[ -f "$layout" ]] || layout="$CELLS/${kernel}_layout.csl"
  cell_out="$OUT/r3-2-27b-qwen-${kernel//_/-}-simfabric-cell"
  mkdir -p "$cell_out"
  cp "$layout" "$cell_out/layout.csl"
  cp "$CELLS/${kernel}_pe_program.csl" "$cell_out/pe_program.csl"
  cp "$CELLS/${kernel}_run.py" "$cell_out/run.py"
  cd "$cell_out"
  $SDK/cslc layout.csl --arch=wse3 --fabric-dims=11,5 --fabric-offsets=4,1 \
    --params="$params" --memcpy --channels=1 -o compiled
  $SDK/cs_python run.py --name compiled --out-receipt receipt.json
  cd -
done

python3 bench/tools/synthesize_qwen_3_6_27b_simfabric_cells_summary_receipt.py
```

The cell drivers write per-cell receipts under `bench/out/`, and the
summary synthesizer aggregates the current result set.

## What this validates

- The per-kernel CSL emitted by Doe's manifest-shape host plan
  compiles cleanly via cslc 2.10.0 for the packaged cell set.
- For the arithmetic cells that carry canonical host references, the
  kernel arithmetic matches the declared formulation within float32
  precision under simfabric execution.
- The `partialRotaryFactor` wiring delta from
  `runtime/zig/src/spatial/csl/csl_host_plan_tool.zig`'s `compileParamsForPattern`
  rope branch flows through the layout → pe_program forwarding chain
  end-to-end (rope_partial cell).
- The deliberate non-forwarding of `hidden_size`/`chunk_size` at
  manifest scale is documented in-place — the patches here are
  small-shape-only and not a Doe-side change.

## What this does NOT validate

- Manifest-shape execution. Manifest-shape compile evidence is tracked
  through the full-graph compile receipt, not this cell directory.
- Multi-kernel chains (each cell is single-kernel only; the analog
  of Gemma's `r3-1-31b-multi-token-decode` 2-step chain is a separate
  follow-up).
- Hardware execution (simfabric only).
- A standalone `attn_prefill` cell. That path is covered through
  `attention_prefill_kv_axis_sharded` manifest-shape compile evidence.
- Real standalone SiLU arithmetic for the `silu` cell. The model FFN
  activation path is represented by the wired `silu_gated` semantic path,
  not this passthrough canary.
- Full hybrid-architecture parity across attention and SSM layers.
