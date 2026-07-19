#!/usr/bin/env python3
"""Generate an SdkLayout runner for one E2B layer block from the plan.

Reads gemma-4-e2b-stream-execution-plan.json, pulls out the
per-layer-schedule entry for one layer (default: layer 0), and emits a
cs_python runner script that:

  - creates an SdkLayout code region named after plan.codeRegion
    ('transformer_layer_shape'),
  - declares one input port per stream named in the plan
    (ple_rows_stream, ple_projection_stream, layer_weights_stream),
  - declares one output port for the activation the layer emits,
  - feeds all streams from the host at smoke-sized payloads,
  - verifies activation_out across a num_layers-long chain of
    layer-block invocations against a host numpy reference that
    replays every reduction, rope rotation, and activation in the
    same scalar f32 op sequence as the CSL kernel,
  - writes a trace with layerBlockSmokeStatus=succeeded and
    per-layer maxAbsErr.

The CSL kernel that consumes these streams is at
bench/out/streaming-executor/e2b-layer-block-source/
transformer_layer_shape.csl — it executes the full 4-stage layer
block (pre-attn RMSNorm, MHA with vector Q/K/V + real-cos/sin
rope + poly_c1 softmax, post-attn RMSNorm, gated MLP with
poly_c1 activation). The runner chains the kernel num_layers
times via the streaming runtime, threading activation_out -> next
layer's ple_rows. All operations use only +, -, *, /, comparison
and a hardcoded cos/sin table — no platform math.tanh/exp/erf —
so np.array_equal remains the pass gate at every layer.

The generator itself produces a plain Python file (not a template),
so reviewers can read the runner directly and the regeneration is
byte-stable.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser()
    p.add_argument(
        "--execution-plan",
        default="bench/out/e2b-full-graph/gemma-4-e2b-stream-execution-plan.json",
    )
    p.add_argument("--layer-index", type=int, default=0)
    p.add_argument("--smoke-size", type=int, default=1024,
                   help="Per-stream f32 count for smoke payloads (default 1024).")
    p.add_argument(
        "--kernel-source",
        default="bench/out/streaming-executor/e2b-layer-block-source/transformer_layer_shape.csl",
    )
    p.add_argument(
        "--runner-out",
        default="bench/runners/csl-runners/e2b_layer_block_smoke.py",
    )
    p.add_argument(
        "--manifest",
        default="runtime/zig/examples/execution-v1/gemma-4-e2b-smoke.json",
        help="execution-v1 manifest to read modelConfig from. Switch "
             "to the 31B manifest + 31B plan + 31B receipt to emit a "
             "31B runner (Build-order step 7 scaffold).",
    )
    p.add_argument(
        "--source-model-receipt",
        default="bench/out/e2b-full-graph/gemma-4-e2b-runtime-receipt.json",
        help="Path embedded into the emitted trace as "
             "sourceModelReceiptPath. Must match the target model.",
    )
    return p.parse_args()


def resolve(raw: str) -> Path:
    p = Path(raw)
    return p if p.is_absolute() else REPO_ROOT / p


def next_power_of_two(n: int) -> int:
    if n <= 1:
        return 1
    return 1 << (n - 1).bit_length()


def stream_buffer_size(payload_bytes: int) -> int:
    return next_power_of_two(max(1024, payload_bytes))


TEMPLATE = '''#!/usr/bin/env cs_python
"""GENERATED — {model_label} layer-block smoke runner.

Produced by bench/tools/generate_e2b_layer_block_runner.py from
{plan_path_rel} (layer {layer_index}). Do not hand-edit; rerun the
generator instead.

Plan stream contract for this layer:
{stream_contract_comment}

Smoke path: each stream carries {smoke_size} f32 values. The kernel
runs the full 4-stage layer block (pre-attn RMSNorm; MHA with vector
Q/K/V, real-cos/sin rope, poly_c1 softmax; post-attn RMSNorm; gated
MLP with poly_c1 activation), and the runner CHAINS num_layers
(={num_layers_default} by default) invocations of that kernel via
the streaming runtime —
activation_out of layer L is fed back as ple_rows of layer L+1 (the
residual stream pattern of a transformer block tower), with distinct
per-layer ple_projection and layer_weights. The bit-exact host numpy
reference replays the same chain. Pass requires every layer to match
under np.array_equal.
"""

from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path

import numpy as np

# Canonical compute_layer_block lives next to this runner so the
# generated SDK runner and the numpy-only synthetic-trace tool both
# import the same source. Single source of truth keeps the parity-
# contract gate honest about kernel/numpy bit-exactness.
sys.path.insert(0, str(Path(__file__).resolve().parent))
from _e2b_layer_block_compute import compute_layer_block  # noqa: E402

from cerebras.sdk.runtime.sdkruntimepybind import (
    Color,
    Edge,
    Route,
    RoutingPosition,
    SdkLayout,
    SdkRuntime,
    SdkTarget,
    SimfabConfig,
    get_platform,
)

REPO_ROOT = Path(__file__).resolve().parents[3]
KERNEL_SOURCE = REPO_ROOT / "{kernel_source_rel}"


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser()
    p.add_argument("--size", type=int, default={smoke_size})
    p.add_argument(
        "--num-layers", type=int, default={num_layers_default},
        help="How many layer-block invocations to chain (residual stream). "
             "Default = manifest.modelConfig.numLayers ({num_layers_default}).",
    )
    p.add_argument(
        "--start-layer-index", type=int, default=0,
        help="Global layer index used for per-layer seed/weight lookup. "
             "Default 0. Probe runs can set 1 to execute layer 1 as a "
             "single invocation.",
    )
    p.add_argument(
        "--initial-rows-file", default="",
        help="Optional f32 file for the first ple_rows payload. When empty, "
             "uses the deterministic initial rows seed.",
    )
    p.add_argument(
        "--freeze-layer-index", type=int, default=-1,
        help="Probe-only override. When >= 0, every invocation uses this "
             "global layer index for projection/weight seed lookup.",
    )
    p.add_argument(
        "--reset-rows-each-layer", action="store_true",
        help="Probe-only override. Send the initial rows payload on every "
             "invocation instead of feeding activation_out forward.",
    )
    p.add_argument(
        "--weights-dir", default="",
        help="Directory containing per-layer weight slice files named "
             "<weight_key>.f32. When a slice exists for a layer it loads the "
             "first --size f32 values; otherwise the loader falls back to a "
             "deterministic per-layer-index seed. Empty (default) means "
             "every layer uses the seed fallback.",
    )
    p.add_argument(
        "--compile-out",
        default="bench/out/streaming-executor/e2b-layer-block-smoke",
    )
    p.add_argument(
        "--trace-out",
        default="bench/out/streaming-executor/e2b-layer-block-smoke-trace.json",
    )
    p.add_argument("--cmaddr", default="")
    return p.parse_args()


def resolve(raw: str) -> Path:
    p = Path(raw)
    return p if p.is_absolute() else REPO_ROOT / p


def main() -> int:
    args = parse_args()
    compile_out = resolve(args.compile_out)
    compile_out.mkdir(parents=True, exist_ok=True)

    compile_start = time.time()
    config = SimfabConfig(dump_core=False)
    target = SdkTarget.WSE3
    platform = get_platform(args.cmaddr.strip(), config, target)
    layout = SdkLayout(platform)

    region = layout.create_code_region(
        str(KERNEL_SOURCE), "{region_name}", 1, 1
    )

    rx_ple_rows = Color("rx_ple_rows")
    rx_ple_projection = Color("rx_ple_projection")
    rx_layer_weights = Color("rx_layer_weights")
    tx_activation = Color("tx_activation")

    recv = RoutingPosition().set_output([Route.RAMP])
    send = RoutingPosition().set_input([Route.RAMP])

    region.set_param_all("size", args.size)
    region.set_param_all(rx_ple_rows)
    region.set_param_all(rx_ple_projection)
    region.set_param_all(rx_layer_weights)
    region.set_param_all(tx_activation)

    rows_port = region.create_input_port(rx_ple_rows, Edge.LEFT, [recv], args.size)
    proj_port = region.create_input_port(rx_ple_projection, Edge.TOP, [recv], args.size)
    wts_port  = region.create_input_port(rx_layer_weights, Edge.BOTTOM, [recv], args.size)
    act_port  = region.create_output_port(tx_activation, Edge.RIGHT, [send], args.size)

    region.place(4, 2)

    io_buffer_sizes = {{
        "rows": {rows_io_buffer_size},
        "proj": {proj_io_buffer_size},
        "wts": {wts_io_buffer_size},
        "activation": {activation_io_buffer_size},
    }}
    rows_stream = layout.create_input_stream(
        rows_port, io_buffer_size=io_buffer_sizes["rows"]
    )
    proj_stream = layout.create_input_stream(
        proj_port, io_buffer_size=io_buffer_sizes["proj"]
    )
    wts_stream  = layout.create_input_stream(
        wts_port, io_buffer_size=io_buffer_sizes["wts"]
    )
    act_stream  = layout.create_output_stream(
        act_port, io_buffer_size=io_buffer_sizes["activation"]
    )

    compile_prefix = str(compile_out / "transformer_layer_shape")
    compile_artifacts = layout.compile(out_prefix=compile_prefix)
    compile_elapsed_ms = (time.time() - compile_start) * 1000.0

    # Content-addressed compile cache key. A future compile cache
    # (SdkLayout hardening gap 1) will index compiled artifacts by
    # this key; today we only record it so every trace carries the
    # key that cache lookup/insert would use. Components that change
    # the compile output must appear here: kernel source content,
    # plan topology, target arch, and the shape parameter baked into
    # the region.
    import hashlib as _hashlib_cache  # local to avoid module-top noise
    compile_cache_key = _hashlib_cache.sha256(
        ("{kernel_source_sha256}|{plan_sha256}|wse3|size=" + str(args.size)).encode("utf-8")
    ).hexdigest()

    run_start = time.time()
    runtime = SdkRuntime(compile_artifacts, platform, memcpy_required=False)
    num_layers_smoke = args.num_layers
    max_abs_err = -1.0
    per_layer_max_abs_err = [-1.0] * num_layers_smoke
    per_layer_elapsed_ms = [-1.0] * num_layers_smoke
    passed = False
    output_digest = None
    per_layer_output_records = []
    failure_context = None
    runtime_stop = {{
        "reached": False,
        "elapsedMs": None,
        "error": None,
    }}
    current_stage = "runtime_constructed"
    current_dispatch_index = None
    current_stream_id = None
    current_operation = None
    stream_order = [
        "ple_rows_stream",
        "ple_projection_stream",
        "layer_weights_stream",
        "activation_out_stream",
    ]
    stream_counters = {{
        "ple_rows_stream": {{
            "role": "input",
            "operation": "send",
            "issuedCount": 0,
            "completedCount": 0,
            "pendingCount": 0,
            "maxQueueDepth": 0,
            "droppedSendCount": 0,
            "submissionFailureCount": 0,
            "doneBeforeWaitCount": 0,
            "taskWaitTotalMs": 0.0,
            "taskWaitMaxMs": 0.0,
        }},
        "ple_projection_stream": {{
            "role": "input",
            "operation": "send",
            "issuedCount": 0,
            "completedCount": 0,
            "pendingCount": 0,
            "maxQueueDepth": 0,
            "droppedSendCount": 0,
            "submissionFailureCount": 0,
            "doneBeforeWaitCount": 0,
            "taskWaitTotalMs": 0.0,
            "taskWaitMaxMs": 0.0,
        }},
        "layer_weights_stream": {{
            "role": "input",
            "operation": "send",
            "issuedCount": 0,
            "completedCount": 0,
            "pendingCount": 0,
            "maxQueueDepth": 0,
            "droppedSendCount": 0,
            "submissionFailureCount": 0,
            "doneBeforeWaitCount": 0,
            "taskWaitTotalMs": 0.0,
            "taskWaitMaxMs": 0.0,
        }},
        "activation_out_stream": {{
            "role": "output",
            "operation": "receive",
            "issuedCount": 0,
            "completedCount": 0,
            "pendingCount": 0,
            "maxQueueDepth": 0,
            "droppedSendCount": 0,
            "submissionFailureCount": 0,
            "doneBeforeWaitCount": 0,
            "taskWaitTotalMs": 0.0,
            "taskWaitMaxMs": 0.0,
        }},
    }}
    stream_events = []
    last_completed_stream_send_receive = None

    def stream_counter_list():
        out = []
        for stream_id in stream_order:
            item = dict(stream_counters[stream_id])
            item["streamId"] = stream_id
            out.append(item)
        return out

    def record_issue(stream_id, operation, layer_index):
        state = stream_counters[stream_id]
        state["issuedCount"] += 1
        state["pendingCount"] += 1
        state["maxQueueDepth"] = max(
            state["maxQueueDepth"], state["pendingCount"]
        )
        stream_events.append({{
            "event": "issued",
            "streamId": stream_id,
            "operation": operation,
            "layerIndex": layer_index,
            "pendingAfter": state["pendingCount"],
        }})

    def submit_stream_task(stream_id, operation, layer_index, submit_fn):
        nonlocal current_stage
        nonlocal current_dispatch_index
        nonlocal current_stream_id
        nonlocal current_operation
        current_stage = "stream_submit"
        current_dispatch_index = layer_index
        current_stream_id = stream_id
        current_operation = operation
        try:
            task = submit_fn()
        except Exception:
            state = stream_counters[stream_id]
            state["submissionFailureCount"] += 1
            if operation == "send":
                state["droppedSendCount"] += 1
            raise
        record_issue(stream_id, operation, layer_index)
        return task

    def wait_stream_task(stream_id, operation, layer_index, task):
        nonlocal current_stage
        nonlocal current_dispatch_index
        nonlocal current_stream_id
        nonlocal current_operation
        nonlocal last_completed_stream_send_receive
        current_stage = "stream_wait"
        current_dispatch_index = layer_index
        current_stream_id = stream_id
        current_operation = operation
        done_before_wait = None
        done_probe_error = None
        try:
            done_before_wait = bool(runtime.is_task_done(task))
        except Exception as probe_exc:
            done_probe_error = (
                type(probe_exc).__name__ + ":" + str(probe_exc)[:120]
            )
        wait_start = time.time()
        runtime.task_wait(task)
        wait_elapsed_ms = (time.time() - wait_start) * 1000.0
        state = stream_counters[stream_id]
        state["completedCount"] += 1
        state["pendingCount"] = max(0, state["pendingCount"] - 1)
        if done_before_wait:
            state["doneBeforeWaitCount"] += 1
        state["taskWaitTotalMs"] += wait_elapsed_ms
        state["taskWaitMaxMs"] = max(state["taskWaitMaxMs"], wait_elapsed_ms)
        event = {{
            "event": "completed",
            "streamId": stream_id,
            "operation": operation,
            "layerIndex": layer_index,
            "pendingAfter": state["pendingCount"],
            "doneBeforeWait": done_before_wait,
            "taskWaitMs": wait_elapsed_ms,
        }}
        if done_probe_error is not None:
            event["doneProbeError"] = done_probe_error
        stream_events.append(event)
        last_completed_stream_send_receive = event
        current_stream_id = None
        current_operation = None

    # Bit-exact numpy reference is the canonical compute_layer_block
    # imported at module top from _e2b_layer_block_compute.py (which
    # lives next to this runner). The synthetic-trace tool imports
    # the same module so the parity-contract gate has one source of
    # truth.
    # Multi-layer chain. Each layer reads its own ple_projection and
    # layer_weights; activation_out of layer L is fed back as ple_rows
    # of layer L+1 (the residual stream pattern of a transformer block
    # tower). The same SdkLayout compile artifacts are reused across
    # layers via the streaming-runtime send/receive primitives — no
    # recompile per layer.
    try:
        runtime.load()
        runtime.run()

        # Real-weight-loader bridge with per-layer-index seed fallback.
        # Each layer's projection/weights load from a manifest-derived
        # tensor slice if present in --weights-dir, else fall back to
        # a deterministic seed. Per-layer source-kind is recorded so
        # the parity-contract gate can read which layers used real
        # weights vs synthetic.
        INITIAL_ROWS_SEED = 1000
        PER_LAYER_BASE    = 2000
        weights_dir_abs = (
            (REPO_ROOT / args.weights_dir) if args.weights_dir else None
        )

        def load_layer_data(weight_key, fallback_seed, size, kind):
            """Load size f32 values from <weights_dir>/<weight_key>.f32 if
            available; else generate via default_rng(fallback_seed).
            Returns (np.ndarray, source_kind_str)."""
            if weights_dir_abs is not None:
                slice_path = weights_dir_abs / (weight_key + ".f32")
                if slice_path.exists():
                    raw = np.fromfile(
                        slice_path, dtype=np.float32, count=size
                    )
                    if raw.shape[0] == size:
                        rel = str(slice_path.relative_to(REPO_ROOT))
                        return raw, "manifest_slice:" + rel
            rng_l = np.random.default_rng(seed=fallback_seed)
            return (
                rng_l.standard_normal(size=size, dtype=np.float32),
                "synthetic_seed:" + str(fallback_seed),
            )

        initial_rows_path = (
            (REPO_ROOT / args.initial_rows_file)
            if args.initial_rows_file else None
        )
        if initial_rows_path is not None:
            initial_rows = np.fromfile(
                initial_rows_path, dtype=np.float32, count=args.size
            )
            if initial_rows.shape[0] != args.size:
                raise ValueError(
                    "--initial-rows-file did not contain --size f32 values"
                )
            initial_rows_source = "file:" + str(
                initial_rows_path.relative_to(REPO_ROOT)
            )
        else:
            rng_init = np.random.default_rng(seed=INITIAL_ROWS_SEED)
            initial_rows = rng_init.standard_normal(
                size=args.size, dtype=np.float32
            )
            initial_rows_source = "synthetic_seed:" + str(INITIAL_ROWS_SEED)
        per_layer_proj: list = []
        per_layer_wts:  list = []
        per_layer_seeds: list = []
        per_layer_proj_source: list = []
        per_layer_wts_source:  list = []
        for l_idx in range(num_layers_smoke):
            if args.freeze_layer_index >= 0:
                global_l_idx = args.freeze_layer_index
            else:
                global_l_idx = args.start_layer_index + l_idx
            seed_l = PER_LAYER_BASE + global_l_idx
            proj_l, proj_src = load_layer_data(
                "per_layer_inputs.perLayerModelProjection.layer"
                + str(global_l_idx),
                seed_l, args.size, "projection",
            )
            wts_l, wts_src = load_layer_data(
                "layer." + str(global_l_idx) + ".smoke_layer_block_wts",
                seed_l, args.size, "weights",
            )
            per_layer_proj.append(proj_l)
            per_layer_wts.append(wts_l)
            per_layer_seeds.append(seed_l)
            per_layer_proj_source.append(proj_src)
            per_layer_wts_source.append(wts_src)
        # Summarize whether the run used any real-weight slices.
        all_sources = per_layer_proj_source + per_layer_wts_source
        is_synthetic = all(s.startswith("synthetic_seed:") for s in all_sources)
        is_manifest  = all(s.startswith("manifest_slice:") for s in all_sources)
        if is_synthetic:
            data_source_kind = "synthetic_seeded_rng"
        elif is_manifest:
            data_source_kind = "manifest_weights_only"
        else:
            data_source_kind = "manifest_weights_with_seed_fallback"

        # Numpy reference: chain compute_layer_block num_layers_smoke
        # times, threading expected[L] -> rows for L+1.
        all_expected = []
        rows_ref = initial_rows.copy()
        for l_idx in range(num_layers_smoke):
            rows_for_layer = (
                initial_rows if args.reset_rows_each_layer else rows_ref
            )
            expected_l = compute_layer_block(
                rows_for_layer,
                per_layer_proj[l_idx],
                per_layer_wts[l_idx],
                args.size,
            )
            all_expected.append(expected_l)
            if not args.reset_rows_each_layer:
                rows_ref = expected_l

        # Device chain: same loop, threading received[L] -> rows for L+1.
        # Per-layer elapsed-ms is recorded so timing scales visibly when
        # the diagnostic chain depth grows (for example, the E2B manifest
        # transformer-block count). Deeper synthetic chains are not a
        # full-model parity claim.
        all_received = []
        rows_curr = initial_rows.copy()
        for l_idx in range(num_layers_smoke):
            current_stage = "layer_dispatch"
            current_dispatch_index = l_idx
            layer_start = time.time()
            received = np.empty(args.size, dtype=np.float32)
            rows_for_layer = (
                initial_rows if args.reset_rows_each_layer else rows_curr
            )
            task_rows = submit_stream_task(
                "ple_rows_stream",
                "send",
                l_idx,
                lambda: runtime.send(
                    rows_stream, rows_for_layer, nonblock=True
                ),
            )
            task_proj = submit_stream_task(
                "ple_projection_stream",
                "send",
                l_idx,
                lambda: runtime.send(
                    proj_stream, per_layer_proj[l_idx], nonblock=True
                ),
            )
            task_wts = submit_stream_task(
                "layer_weights_stream",
                "send",
                l_idx,
                lambda: runtime.send(
                    wts_stream, per_layer_wts[l_idx], nonblock=True
                ),
            )
            task_act = submit_stream_task(
                "activation_out_stream",
                "receive",
                l_idx,
                lambda: runtime.receive(
                    act_stream, received, args.size, nonblock=True
                ),
            )
            # The next layer consumes activation_out as ple_rows. Wait for
            # all per-layer direct-link tasks before copying or feeding it.
            wait_stream_task("ple_rows_stream", "send", l_idx, task_rows)
            wait_stream_task("ple_projection_stream", "send", l_idx, task_proj)
            wait_stream_task("layer_weights_stream", "send", l_idx, task_wts)
            wait_stream_task(
                "activation_out_stream", "receive", l_idx, task_act
            )
            per_layer_elapsed_ms[l_idx] = (time.time() - layer_start) * 1000.0
            all_received.append(received.copy())
            if not args.reset_rows_each_layer:
                rows_curr = received

        current_stage = "runtime_stop"
        stop_start = time.time()
        runtime.stop()
        runtime_stop = {{
            "reached": True,
            "elapsedMs": (time.time() - stop_start) * 1000.0,
            "error": None,
        }}

        # Per-layer parity. Pass requires every layer to be bit-exact.
        layer_passed = []
        for l_idx in range(num_layers_smoke):
            err = float(np.max(np.abs(all_received[l_idx] - all_expected[l_idx])))
            per_layer_max_abs_err[l_idx] = err
            layer_passed.append(
                bool(np.array_equal(all_received[l_idx], all_expected[l_idx]))
            )
        max_abs_err = max(per_layer_max_abs_err) if per_layer_max_abs_err else -1.0
        passed = bool(all(layer_passed))
        run_status = "succeeded" if passed else "mismatch"

        # Output tensor digest: write the final-layer activation_out as
        # f32 bytes and capture {{dtype, shape, path, sha256, preview}}.
        # doe_csl_reference_parity gate's cslRun.output field consumes
        # this — once a Doppler/browser reference output is bound,
        # --require-output-parity flips the gate to passed.
        import hashlib as _hashlib  # local to avoid module-top noise
        _final = all_received[-1] if all_received else np.empty(0, dtype=np.float32)
        _trace_path = resolve(args.trace_out)
        _output_path = _trace_path.with_suffix(".output.f32")
        _output_path.parent.mkdir(parents=True, exist_ok=True)
        _final.astype(np.float32).tofile(_output_path)
        _h = _hashlib.sha256()
        with _output_path.open("rb") as _fh:
            for _ck in iter(lambda: _fh.read(1 << 20), b""):
                _h.update(_ck)
        output_digest = {{
            "dtype": "float32",
            "shape": [int(_final.shape[0])],
            "path": str(_output_path.relative_to(REPO_ROOT)),
            "sha256": _h.hexdigest(),
            "preview": [
                float(_final[_i])
                for _i in range(min(8, int(_final.shape[0])))
            ],
        }}

        # Per-layer activation_out dumps: one .f32 per layer so the
        # demo page and downstream parity gates can compare CSL vs
        # WebGPU layer-by-layer (the right granularity for deep
        # chains where ULP-per-layer drift compounds). Writes to
        # <trace>.per_layer/layer{{N}}.f32 beside the final output.
        per_layer_output_dir = _trace_path.parent / (_trace_path.stem + ".per_layer")
        per_layer_output_dir.mkdir(parents=True, exist_ok=True)
        for _l_idx, _layer_out in enumerate(all_received):
            _layer_path = per_layer_output_dir / ("layer" + str(_l_idx) + ".f32")
            _layer_out.astype(np.float32).tofile(_layer_path)
            _h_layer = _hashlib.sha256()
            with _layer_path.open("rb") as _fh:
                for _ck in iter(lambda: _fh.read(1 << 20), b""):
                    _h_layer.update(_ck)
            per_layer_output_records.append({{
                "layer": _l_idx,
                "path": str(_layer_path.relative_to(REPO_ROOT)),
                "sha256": _h_layer.hexdigest(),
                "shape": [int(_layer_out.shape[0])],
            }})
    except Exception as exc:  # pylint: disable=broad-except
        if current_stream_id in stream_counters and current_operation is not None:
            state = stream_counters[current_stream_id]
            state["lastErrorType"] = type(exc).__name__
            state["lastErrorMessage"] = str(exc)[:160]
        run_status = f"failed:" + type(exc).__name__ + ":" + str(exc)[:160]
        failure_context = {{
            "failedAtStage": current_stage,
            "failedAtDispatchIndex": current_dispatch_index,
            "lastActiveStreamId": current_stream_id,
            "lastActiveOperation": current_operation,
            "lastCompletedStreamSendReceive": last_completed_stream_send_receive,
            "streamCounters": stream_counter_list(),
            "streamEventsTail": stream_events[-16:],
            "errorType": type(exc).__name__,
            "message": str(exc)[:500],
        }}
        output_digest = None
    run_elapsed_ms = (time.time() - run_start) * 1000.0

    trace = {{
        "schemaVersion": 1,
        "artifactKind": "doe_streaming_executor_trace",
        "target": "wse3",
        "modelId": "{model_id}",
        "executorIteration": 8,
        "sourcePlan": {{
            "streamGraphPath": "",
            "executionPlanPath": "{plan_path_rel}",
            "kernelSourcePath": "{kernel_source_rel}",
        }},
        "region": {{
            "regionId": "{region_name}_L{layer_index:02d}",
            "width": 1,
            "height": 1,
            "peCount": 1,
        }},
        "executedCompile": {{
            "compilePrefix": str(Path(compile_prefix).relative_to(REPO_ROOT)),
            "elapsedMs": compile_elapsed_ms,
            "status": "succeeded",
            "cacheKey": compile_cache_key,
            "cacheKeyComponents": {{
                "kernelSourceSha256": "{kernel_source_sha256}",
                "planSha256": "{plan_sha256}",
                "target": "wse3",
                "size": args.size,
            }},
            "cacheState": "miss_uncached",
        }},
        "executedRun": {{
            "status": run_status,
            "elapsedMs": run_elapsed_ms,
            "numLayersChained": num_layers_smoke,
            "perLayerElapsedMs": per_layer_elapsed_ms,
            "perLayerOutputs": per_layer_output_records,
            "observedBytesTransferredPerPe":
                args.size * 4 * 4 * num_layers_smoke,
            "observedBytesTransferredTotal":
                args.size * 4 * 4 * num_layers_smoke,
            "streams": stream_counter_list(),
            "streamTelemetry": {{
                "measurementSource": "host_sdk_task_handles",
                "queueDepthDefinition": (
                    "submitted nonblocking SDK tasks not yet observed "
                    "complete by task_wait, counted per stream"
                ),
                "droppedSendCountSource": (
                    "host SDK submission exceptions before a task handle "
                    "is returned; SDK fabric-level drop counters are not "
                    "exposed here"
                ),
                "streamEventsTailCount": len(stream_events[-64:]),
            }},
            "streamEventsTail": stream_events[-64:],
            "runtimeStop": runtime_stop,
            "failure": failure_context,
            "dataSource": {{
                "kind": data_source_kind,
                "initialRowsSeed": INITIAL_ROWS_SEED,
                "initialRowsSource": initial_rows_source,
                "startLayerIndex": args.start_layer_index,
                "freezeLayerIndex": (
                    args.freeze_layer_index
                    if args.freeze_layer_index >= 0 else None
                ),
                "resetRowsEachLayer": args.reset_rows_each_layer,
                "perLayerBase": PER_LAYER_BASE,
                "perLayerSeeds": per_layer_seeds,
                "weightsDir": str(weights_dir_abs.relative_to(REPO_ROOT))
                              if weights_dir_abs and weights_dir_abs.exists()
                              else None,
                "perLayerProjSource": per_layer_proj_source,
                "perLayerWtsSource":  per_layer_wts_source,
                "swapBoundary": (
                    "Each layer's projection and weights load via "
                    "load_layer_data(weight_key, seed_l, size). When "
                    "<weights-dir>/<weight_key>.f32 exists, the loader "
                    "reads the first --size f32 values; otherwise it "
                    "falls back to default_rng(PER_LAYER_BASE + l_idx). "
                    "perLayerProjSource and perLayerWtsSource record "
                    "which path each layer took, so the parity-contract "
                    "gate can demand 'all manifest_slice' for a release-"
                    "grade claim or accept synthetic for early smoke."
                ),
            }},
            "numericalParity": {{
                "maxAbsErr": max_abs_err,
                "perLayerMaxAbsErr": per_layer_max_abs_err,
                "atol": 0,
                "passed": passed,
            }},
            "output": output_digest,
        }},
        "streams": [
            {{"role": "input",  "color": "rx_ple_rows",        "size": args.size, "dtype": "float32"}},
            {{"role": "input",  "color": "rx_ple_projection",  "size": args.size, "dtype": "float32"}},
            {{"role": "input",  "color": "rx_layer_weights",   "size": args.size, "dtype": "float32"}},
            {{"role": "output", "color": "tx_activation",      "size": args.size, "dtype": "float32"}},
        ],
        "layerBlockSmoke": {{
            "planPath": "{plan_path_rel}",
            "planSha256": "{plan_sha256}",
            "layerIndex": {layer_index},
            "regionName": "{region_name}",
            "kernelSourcePath": "{kernel_source_rel}",
            "kernelSourceSha256": "{kernel_source_sha256}",
            "kernelIsStub": False,
            "combineRule": (
                "rmsnorm[i] = (ple_rows[i] / sqrt(mean(ple_rows^2) + 1e-6)) * ple_projection[i]; "
                "num_heads = 8; head_dim = 8; kv_len_per_head = 4; num_pairs = head_dim/2; "
                "per_head_K_len = head_dim * kv_len_per_head; stride = 2*per_head_K_len; "
                "flat_len = num_heads*head_dim; mlp_len = qs/2; "
                "rope_table[p,d]: pair d=0 at theta_0=1 -> "
                "(1,0),(0.540302277,0.841470957),(-0.416146845,0.909297407); "
                "pair d=1 at theta_1=0.1 -> "
                "(1,0),(0.995004177,0.0998334140),(0.980066597,0.198669329); "
                "rope_rot(x0,x1,p,d) = (cos[p,d]*x0 - sin[p,d]*x1, "
                "sin[p,d]*x0 + cos[p,d]*x1); "
                "for h in [0, num_heads): "
                "Q_h[d] = rmsnorm[h*head_dim + d]; "
                "for d in [0, num_pairs): "
                "(Q_r[2d], Q_r[2d+1]) = rope_rot(Q_h[2d], Q_h[2d+1], "
                "kv_len_per_head, d); "
                "base_h = qs + h*stride; "
                "K_h[j][d] = layer_weights[base_h + j*head_dim + d]; "
                "(K_r[j][2d], K_r[j][2d+1]) = rope_rot(K_h[j][2d], "
                "K_h[j][2d+1], j, d); "
                "V_h[j][d] = layer_weights[base_h + per_head_K_len + j*head_dim + d]; "
                "logits_h[j] = sum_d Q_r[d] * K_r[j][d]; "
                "m_h = max_j logits_h[j]; "
                "w_h[j] = poly_c1(logits_h[j] - m_h); "
                "attn_val[h][d] = sum_j (w_h[j]/sum_j w_h[j]) * V_h[j][d]; "
                "attn_out[i] = attn_val_flat[i mod flat_len] + ple_rows[i]; "
                "post_norm[i] = (attn_out[i] / sqrt(mean(attn_out^2) + 1e-6)) "
                "* layer_weights[i mod qs]; "
                "gate = sum_k layer_weights[3*qs + k] * post_norm[k]     (k in [0, mlp_len)); "
                "up   = sum_k layer_weights[3*qs + mlp_len + k] * post_norm[mlp_len + k]; "
                "poly_c1(x) = 0 if x<=-1, x if x>=1, 0.25*(x+1)^2 otherwise; "
                "activation_out[i] = gate * poly_c1(up * post_norm[i]) + post_norm[i]"
            ),
            "kernelStage": (
                "pre_attn_rmsnorm+mha_8head_hd8_kv4_multi_pair_rope_real"
                "_poly_c1_softmax+residual"
                "+post_attn_rmsnorm+gated_mlp_poly_c1_gelu"
                "+multi_layer_chain"
            ),
            "status": run_status,
            "targetMode": "local_simfabric",
            "compileArtifactDir": str(compile_out.relative_to(REPO_ROOT)),
            "compileArtifactPrefix": str(Path(compile_prefix).relative_to(REPO_ROOT)),
            "connectionGraph": {{
                "region": "{region_name}",
                "grid": {{"width": 1, "height": 1, "peCount": 1, "place": [4, 2]}},
                "inputPorts": [
                    {{"color": "rx_ple_rows",       "edge": "LEFT",   "size": args.size}},
                    {{"color": "rx_ple_projection", "edge": "TOP",    "size": args.size}},
                    {{"color": "rx_layer_weights",  "edge": "BOTTOM", "size": args.size}},
                ],
                "outputPorts": [
                    {{"color": "tx_activation",     "edge": "RIGHT",  "size": args.size}},
                ],
                "crossRegionConnections": [],
            }},
            "hostIoLayout": [
                {{"streamId": "ple_rows_stream",       "role": "input",  "elementsPerPe": args.size,
                  "dtype": "float32", "order": "row_major", "roi": [4, 2, 1, 1],
                  "tileBehavior": "stream", "planPayloadBytes": {rows_payload_bytes},
                  "ioBufferSize": io_buffer_sizes["rows"]}},
                {{"streamId": "ple_projection_stream", "role": "input",  "elementsPerPe": args.size,
                  "dtype": "float32", "order": "row_major", "roi": [4, 2, 1, 1],
                  "tileBehavior": "stream", "planPayloadBytes": {proj_payload_bytes},
                  "ioBufferSize": io_buffer_sizes["proj"]}},
                {{"streamId": "layer_weights_stream",  "role": "input",  "elementsPerPe": args.size,
                  "dtype": "float32", "order": "row_major", "roi": [4, 2, 1, 1],
                  "tileBehavior": "stream", "planPayloadBytes": {wts_payload_bytes},
                  "ioBufferSize": io_buffer_sizes["wts"]}},
                {{"streamId": "activation_out_stream", "role": "output", "elementsPerPe": args.size,
                  "dtype": "float32", "order": "row_major", "roi": [4, 2, 1, 1],
                  "tileBehavior": "stream", "planPayloadBytes": 0,
                  "ioBufferSize": io_buffer_sizes["activation"]}},
            ],
            "ioBufferPolicy": {{
                "rule": "next_power_of_two(max(1024, planPayloadBytes))",
                "underSizedIsFailure": True,
                "overFourTimesPayloadIsWarning": True,
            }},
            "ioBufferSizes": io_buffer_sizes,
            "sendReceiveCounts": {{"sends": 3, "receives": 1}},
            "simulatorArtifactPaths": {{
                "compileDir": str(compile_out.relative_to(REPO_ROOT)),
                "runLogs": [],
                "coreFile": None,
            }},
            "sourceModelReceiptPath": "{source_model_receipt_rel}",
            "perKernelShapes": {per_kernel_shapes_literal},
        }},
        "notes": (
            "GENERATED from bench/tools/generate_e2b_layer_block_runner.py. "
            "First SdkLayout runner emitted from the E2B stream-execution-plan. "
            "Stage 1 = pre-attn RMSNorm (ple_rows, ple_projection); stage 2 "
            "= single-head attention: Q = rmsnorm[0]; K[j] = wts[qs+j], "
            "V[j] = wts[qs+kv_len+j] with kv_len = qs/2; logits = Q*K; "
            "max-centered poly_c1 softmax; attn_val = sum sm[j]*V[j]; "
            "attn_out[i] = attn_val + ple_rows[i]; stage 3 = post-attn "
            "RMSNorm with gamma2 = wts[0..qs) broadcast 4x; stage 4 = "
            "gated MLP with gate = wts[2qs..3qs)·post_norm[0..qs), "
            "up = wts[3qs..4qs)·post_norm[qs..2qs), and activation_out = "
            "gate * poly_c1(up * post_norm) + post_norm. poly_c1 is the "
            "shared C^1 polynomial (0 for x<=-1, x for x>=1, 0.25*(x+1)^2 "
            "otherwise) used by both the stage-2 softmax weighting and "
            "the stage-4 activation — no transcendentals, bit-exact "
            "reproducible in both CSL and numpy. layer_weights reshape: "
            "[gamma2, attn_scale=(K,V), gate_w, up_w] (four back-to-back "
            "quarters of size/4). Remaining stages (multi-head with "
            "multiple heads, longer KV, rope) land in follow-up ticks."
        ),
    }}

    trace_path = resolve(args.trace_out)
    trace_path.parent.mkdir(parents=True, exist_ok=True)
    trace_path.write_text(json.dumps(trace, indent=2) + "\\n", encoding="utf-8")

    print(
        "{model_label_slug} layer-block smoke (L{layer_index:02d}): "
        f"compile={{compile_elapsed_ms:.1f}}ms, run={{run_elapsed_ms:.1f}}ms, "
        f"run_status={{run_status!r}}, passed={{passed}}, "
        f"max_abs_err={{max_abs_err:.3e}} -> {{trace_path}}"
    )
    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main())
'''


def derive_per_kernel_shapes(
    plan: dict,
    manifest: dict,
    smoke_size: int,
) -> list[dict]:
    """Pick --params shape for each real kernel pattern this layer touches.

    Today only gather is widened (see plan Build-order step 2 audit at
    bench/out/layout-2d-needs/layout-2d-needs.json). This function
    demonstrates the per-kernel-shape-emission pattern that plan step 1
    owes the step-2 sweep. Extending to more patterns (rope, attention,
    dequant, etc.) is follow-up; the data structure's shape is what
    matters for cross-step readability.

    Derivation rule for gather:
      width         = smoke_size (so num_tokens = smoke_size stays <= i16;
                      real deployment uses num_tokens from the step expansion)
      height        = 1    (1-D smoke; 2-D for 31B full-grid is a future flip)
      hidden_size   = manifest.modelConfig.hiddenDim
      rows_per_pe   = 8    (emitter default; the manifest has no override yet)
      num_tokens    = smoke_size
    """
    mc = manifest.get("modelConfig", {})
    hidden_dim = int(mc.get("hiddenDim", 0))
    head_dim = int(mc.get("headDim", 0))
    global_head_dim = int(mc.get("globalHeadDim", 0))
    num_kv_heads = int(mc.get("numKeyValueHeads", 0))
    shapes: list[dict] = []

    # Pattern -> fixture-scale cslc --params string, one entry per
    # governed-lane sim-success fixture (pulled from each fixture's
    # driver-result.json compile.targets[0].command --params=).
    # Each fixture ran at smoke shapes; these strings let
    # predictedMatchesObservedShape flip True on the footprint diff
    # when the generator emits them alongside the deployment-scale
    # shapes. A mismatch between any entry here and the actual
    # driver-result would be caught by the footprint's ratio test.
    FIXTURE_EQUIVALENT_CSLC_PARAMS: dict[str, str] = {
        "gather":              "width:4,height:1",
        "rope":                "width:4,height:1",
        "reduction":           "width:4,height:1",
        "tiled_matmul":        "width:2,height:2,P:2,Mt:8,Kt:8,Nt:8",
        "attention_tiled":     "width:4,height:1,head_dim:32,kv_len:64,q_len:32",
        "attention_decode":    "width:4,height:1,head_dim:32,kv_len:64,q_len:1",
        "attention_linear":    "width:4,height:1",
        "kv_write":            "width:4,height:1,head_dim:32,max_seq_len:64",
        "sample":              "width:4,height:1,chunk_size:1024",
        "fused_gemv_dequant":  "width:4,height:1,out_dim:64,in_dim_per_pe:512,num_blocks_per_row:2",
    }

    def attach_fixture_equivalent(entry: dict) -> dict:
        s = FIXTURE_EQUIVALENT_CSLC_PARAMS.get(entry.get("pattern"))
        if s:
            entry["fixtureEquivalentCslcParamsString"] = s
        return entry
    # Smoke-shape gather: the manifest has two gather steps
    # (embed_tokens and ple_gather); emit one shape entry that covers
    # the shared pattern-level --params. Real deployment would pick
    # per-step widths based on the weight matrix / token count.
    shapes.append({
        "pattern": "gather",
        "emitter": "emitGatherLayout (runtime/zig/src/compiler/wgsl/emit/csl/emit_csl_layout.zig:237)",
        "emitterWidened2D": True,
        "paramsShape": {
            "width": smoke_size,
            "height": 1,
            "hidden_size": hidden_dim or 64,
            "rows_per_pe": 8,
            "num_tokens": smoke_size,
        },
        "cslcParamsString": (
            f"width:{smoke_size},height:1,"
            f"hidden_size:{hidden_dim or 64},"
            f"rows_per_pe:8,num_tokens:{smoke_size}"
        ),
        # fixtureEquivalentCslcParamsString is attached by
        # attach_fixture_equivalent at the end of this function (all 10
        # bound-pattern entries share the same post-processing).
        "derivationSource": (
            "width/num_tokens from --size smoke arg; hidden_size from "
            "manifest.modelConfig.hiddenDim; height=1 for smoke (2-D "
            "needed for 31B full-grid per layout-2d-needs audit); "
            "rows_per_pe is the emitter default with no manifest override yet."
        ),
        "manifestSteps": [
            s["name"] for s in manifest.get("steps", [])
            if s.get("op") in ("embed", "ple_gather")
        ],
    })
    # Smoke-shape rope: the audit keeps rope 1-D since its width is
    # per-token (num_tokens <= max_seq_len <= ~4k, well under i16).
    # num_pairs follows the standard RoPE complex-rotation layout:
    # head_dim f32 values pair up into head_dim/2 (cos,sin) pairs.
    rope_num_pairs = (head_dim // 2) if head_dim else 64
    shapes.append({
        "pattern": "rope",
        "emitter": "emitRoPELayout (runtime/zig/src/compiler/wgsl/emit/csl/emit_csl_layout.zig:263)",
        "emitterWidened2D": False,
        "paramsShape": {
            "width": smoke_size,
            "head_dim": head_dim or 128,
            "num_pairs": rope_num_pairs,
        },
        "cslcParamsString": (
            f"width:{smoke_size},"
            f"head_dim:{head_dim or 128},"
            f"num_pairs:{rope_num_pairs}"
        ),
        "derivationSource": (
            "width = num_tokens from --size (1-D layout, per-token — "
            "layout-2d-needs audit keeps rope 1-D since num_tokens<=i16); "
            "head_dim from manifest.modelConfig.headDim; num_pairs is the "
            "standard RoPE half-head_dim convention (cos+sin pair count)."
        ),
        "manifestSteps": [
            s["name"] for s in manifest.get("steps", [])
            if s.get("op") == "rope"
        ],
    })
    # Smoke-shape tiled_matmul: emitter at L168 takes P × P SUMMA tiles
    # with Mt/Kt/Nt per-tile dims. Already 2-D per the audit (emitter
    # declares P with u16). Unlike gather/rope/reduction, tiled_matmul
    # has MULTIPLE call sites per layer (q/k/v/o projections plus FFN
    # gate/up/down), each with different K/N dims. Emit one pattern
    # entry with an `invocations[]` sub-list — a generalization the
    # remaining weight-matrix patterns (dequant, fused_gemv, fused_ffn)
    # will also use.
    ffn_expansion = int(mc.get("ffnExpansionFactor", 4))
    num_heads = int(mc.get("numHeads", 0))
    hidden = hidden_dim or 1536
    intermediate = hidden * ffn_expansion
    # Pick a small P for smoke so Mt/Kt/Nt stay small ints cslc can
    # round-trip. Real deployment uses larger P from memory-plan.
    P_smoke = 2
    q_out_dim = (num_heads or 8) * (head_dim or 256)
    kv_out_dim = (num_kv_heads or 1) * (head_dim or 256)

    def mm_params(step_name: str, m: int, k: int, n: int) -> dict:
        """Compute {P, Mt, Kt, Nt} with simple even division; round up if
        needed. Smoke values — real deployment picks P from the memory plan."""
        def tile(d: int) -> int:
            return max(1, d // P_smoke)
        mt, kt, nt = tile(m), tile(k), tile(n)
        return {
            "stepName": step_name,
            "paramsShape": {"P": P_smoke, "Mt": mt, "Kt": kt, "Nt": nt},
            "cslcParamsString": f"P:{P_smoke},Mt:{mt},Kt:{kt},Nt:{nt}",
            "weightMatrixShape": f"M={m} K={k} N={n}",
        }

    mm_invocations = [
        mm_params("q_proj",    smoke_size, hidden,      q_out_dim),
        mm_params("k_proj",    smoke_size, hidden,      kv_out_dim),
        mm_params("v_proj",    smoke_size, hidden,      kv_out_dim),
        mm_params("o_proj",    smoke_size, q_out_dim,   hidden),
        mm_params("gate_proj", smoke_size, hidden,       intermediate),
        mm_params("up_proj",   smoke_size, hidden,       intermediate),
        mm_params("down_proj", smoke_size, intermediate, hidden),
    ]
    shapes.append({
        "pattern": "tiled_matmul",
        "emitter": "emitMatmulLayout (runtime/zig/src/compiler/wgsl/emit/csl/emit_csl_layout.zig:168)",
        "emitterWidened2D": True,
        "invocations": mm_invocations,
        "derivationSource": (
            "P = 2 for smoke (even SUMMA partition; real deployment picks P "
            "from memory-plan); Mt/Kt/Nt = weight-matrix dim // P. Weight "
            "matrix M/K/N derived from manifest.modelConfig: M = num_tokens "
            "(--size), K/N chosen per step — hiddenDim for projection inputs "
            "and output (q/k/v/o), intermediate = hiddenDim * ffnExpansionFactor "
            "for FFN gate/up N-dim and down K-dim, q_out_dim = numHeads * "
            "headDim for q/o and kv_out_dim = numKeyValueHeads * headDim "
            "for k/v. globalHeadDim is recorded for the manifest-shape "
            f"attention rewrite (current value {global_head_dim or 'absent'}). "
            "This per-invocation shape emission is the "
            "pattern the 4 audit-blocked emitters (dequant/sample/fused_gemv/"
            "fused_ffn) will also use."
        ),
        "manifestSteps": [
            s["name"] for s in manifest.get("steps", [])
            if s.get("op") == "matmul" and s.get("kernelKey") == "tiled"
        ],
    })
    # Smoke-shape attention_tiled: emitter at L403 takes width + head_dim
    # + kv_len + q_len. Per the audit attention_tiled stays 1-D since the
    # width is per-tile (per-head-per-row). Manifest has one tiled
    # attention step per layer (prefill); the decode variants land on
    # attention_decode, not this pattern.
    max_seq_len = int(mc.get("maxSeqLen", 4096))
    attn_tiled_steps = [
        s["name"] for s in manifest.get("steps", [])
        if s.get("op") == "attention_prefill"
    ]
    shapes.append({
        "pattern": "attention_tiled",
        "emitter": "emitTiledAttentionLayout (runtime/zig/src/compiler/wgsl/emit/csl/emit_csl_layout.zig:403)",
        "emitterWidened2D": False,
        "invocations": [
            {
                "stepName": step_name,
                "paramsShape": {
                    "width": smoke_size,
                    "head_dim": head_dim or 128,
                    "kv_len": max_seq_len,
                    "q_len": smoke_size,
                },
                "cslcParamsString": (
                    f"width:{smoke_size},"
                    f"head_dim:{head_dim or 128},"
                    f"kv_len:{max_seq_len},"
                    f"q_len:{smoke_size}"
                ),
            }
            for step_name in (attn_tiled_steps or ["attention"])
        ],
        "derivationSource": (
            "width/q_len = num_tokens from --size (1-D per-tile row); "
            "head_dim from manifest.modelConfig.headDim; kv_len = "
            "manifest.modelConfig.maxSeqLen as the prefill upper bound "
            "(4096 for both E2B and 31B — well under i16). Per the "
            "layout-2d-needs audit, attention_tiled stays 1-D."
        ),
        "manifestSteps": attn_tiled_steps,
    })
    # Smoke-shape attention_decode: emitter at L379 takes width + head_dim
    # + kv_chunk (NOT kv_len — the decode emitter chunks the KV cache).
    # Manifest has two decode-attention variants per layer: sliding
    # (bounded by slidingWindowSize) and global (bounded by maxSeqLen).
    # Per the audit stays 1-D (per-head-per-chunk width).
    sliding_window = int(m.get("slidingWindowSize", 0)) if (m := manifest) else 0
    decode_invocations = []
    for s in manifest.get("steps", []):
        op = s.get("op", "")
        key = s.get("kernelKey", "")
        if op == "attention_sliding":
            kv_len = sliding_window or 512
            variant = "sliding"
        elif op == "attention" and "decode" in key:
            kv_len = max_seq_len
            variant = "global"
        else:
            continue
        kv_chunk = max(1, kv_len // smoke_size)
        decode_invocations.append({
            "stepName": s["name"],
            "variant": variant,
            "paramsShape": {
                "width": smoke_size,
                "head_dim": head_dim or 128,
                "kv_chunk": kv_chunk,
            },
            "cslcParamsString": (
                f"width:{smoke_size},"
                f"head_dim:{head_dim or 128},"
                f"kv_chunk:{kv_chunk}"
            ),
            "kvLenBound": kv_len,
        })
    if decode_invocations:
        shapes.append({
            "pattern": "attention_decode",
            "emitter": "emitDecodeAttentionLayout (runtime/zig/src/compiler/wgsl/emit/csl/emit_csl_layout.zig:379)",
            "emitterWidened2D": False,
            "invocations": decode_invocations,
            "derivationSource": (
                "width = num_tokens from --size (1-D per-head-per-chunk); "
                "head_dim from manifest.modelConfig.headDim; kv_chunk = "
                "kv_len_bound // width with kv_len_bound = slidingWindowSize "
                "for the sliding variant and maxSeqLen for the global decode. "
                "Both bounds stay well under i16 at Gemma-4 shapes. Per the "
                "layout-2d-needs audit, attention_decode stays 1-D."
            ),
            "manifestSteps": [inv["stepName"] for inv in decode_invocations],
        })
    # Smoke-shape dequant (dormant): emitter at L305 takes width +
    # num_blocks. Gemma-4 fuses dequant into GEMV (see
    # fused_gemv_dequant above), so no standalone dequant step appears
    # in the manifest. Record emitter-default shape and flag as dormant.
    dequant_steps = [s["name"] for s in manifest.get("steps", []) if s.get("op") == "dequant"]
    if not dequant_steps:
        shapes.append({
            "pattern": "dequant",
            "emitter": "emitDequantLayout (runtime/zig/src/compiler/wgsl/emit/csl/emit_csl_layout.zig:305)",
            "emitterWidened2D": False,
            "invocations": [{
                "stepName": "(dormant)",
                "paramsShape": {
                    "width": smoke_size,
                    "num_blocks": 1,
                },
                "cslcParamsString": f"width:{smoke_size},num_blocks:1",
            }],
            "derivationSource": (
                "width = --size smoke arg; num_blocks = 1 fallback (no "
                "manifest step drives this). Gemma-4 fuses dequant into "
                "fused_gemv_dequant rather than issuing standalone "
                "dequant — this emitter stays live for future models "
                "that separate the two."
            ),
            "manifestSteps": [],
            "status": "dormant_pattern_no_manifest_step",
        })

    # Smoke-shape fused_ffn (dormant): emitter at L557 takes width +
    # in_dim + out_dim + in_per_pe. Gemma-4 decomposes FFN into
    # gate_proj / up_proj / down_proj matmuls (via tiled_matmul and
    # fused_gemv_dequant) rather than one fused op, so no manifest
    # step references this emitter today.
    fused_ffn_steps = [s["name"] for s in manifest.get("steps", []) if s.get("op") == "fused_ffn"]
    if not fused_ffn_steps:
        in_per_pe = max(1, hidden // smoke_size)
        shapes.append({
            "pattern": "fused_ffn",
            "emitter": "emitFusedFfnLayout (runtime/zig/src/compiler/wgsl/emit/csl/emit_csl_layout.zig:557)",
            "emitterWidened2D": False,
            "invocations": [{
                "stepName": "(dormant)",
                "paramsShape": {
                    "width": smoke_size,
                    "in_dim": hidden,
                    "out_dim": intermediate,
                    "in_per_pe": in_per_pe,
                },
                "cslcParamsString": (
                    f"width:{smoke_size},"
                    f"in_dim:{hidden},"
                    f"out_dim:{intermediate},"
                    f"in_per_pe:{in_per_pe}"
                ),
            }],
            "derivationSource": (
                "width = --size; in_dim = hiddenDim; out_dim = "
                "intermediate = hiddenDim*ffnExpansionFactor; in_per_pe "
                "= in_dim // width. No manifest step — Gemma-4 runs the "
                "FFN as three separate matmul steps (gate_proj / up_proj "
                "/ down_proj) rather than fusing into one kernel, so "
                "this entry covers emitter presence only."
            ),
            "manifestSteps": [],
            "status": "dormant_pattern_no_manifest_step",
        })

    # Smoke-shape sample: emitter at L428 takes width + chunk_size.
    # vocabSize = 262,144 for Gemma-4 (both E2B and 31B) — well above
    # i16 if distributed with chunk_size=1. Per the audit this is one
    # of the 4 audit-blocked emitters: whether deployment chooses a
    # chunk_size that keeps width below i16 depends on the step-1
    # generator's output.
    vocab_size = int(mc.get("vocabSize", 0))
    sample_steps = [s["name"] for s in manifest.get("steps", []) if s.get("op") == "sample"]
    if vocab_size and sample_steps:
        chunk_size = max(1, vocab_size // smoke_size)
        shapes.append({
            "pattern": "sample",
            "emitter": "emitSampleLayout (runtime/zig/src/compiler/wgsl/emit/csl/emit_csl_layout.zig:428)",
            "emitterWidened2D": False,
            "invocations": [{
                "stepName": sample_steps[0],
                "paramsShape": {
                    "width": smoke_size,
                    "chunk_size": chunk_size,
                },
                "cslcParamsString": f"width:{smoke_size},chunk_size:{chunk_size}",
                "vocabSize": vocab_size,
            }],
            "derivationSource": (
                "width = --size smoke arg; chunk_size = vocabSize // width "
                "(vocabSize from manifest.modelConfig.vocabSize = 262,144 "
                "for Gemma-4). Smoke partitions evenly but deployment "
                "will pick a chunk_size that balances per-PE SRAM budget "
                "against reduce-chain hop count — that choice lives in "
                "the step-1 generator, so this entry is flagged "
                "audit_needs_deployment_generator."
            ),
            "manifestSteps": sample_steps,
            "status": "audit_needs_deployment_generator",
        })
    # Smoke-shape fused_gemv_dequant: emitter at L448 takes width +
    # out_dim + in_dim_per_pe + num_blocks_per_row. Per the audit this
    # is one of the 4 entries whose needs2DFor31B resolves to "likely"
    # and is gated on the step-1 generator's per-weight-matrix width
    # derivation. The shapes below use a fixed smoke width (--size)
    # and partition each weight matrix's in_dim by width; deployment
    # will pick width from memory-plan budgets.
    #
    # Q4K packs scales + quants in 32-element blocks (GGML convention).
    Q4K_BLOCK = 32
    gemv_invocations = []
    for s in manifest.get("steps", []):
        if s.get("op") != "matmul_q4k" or s.get("kernelKey") != "gemv":
            continue
        name = s["name"]
        # Same weight-matrix shape table as tiled_matmul — the decode
        # path uses the same matrices, dequantized on the fly.
        if name == "q_proj":
            in_dim, out_dim = hidden, q_out_dim
        elif name in ("k_proj", "v_proj"):
            in_dim, out_dim = hidden, kv_out_dim
        elif name == "o_proj":
            in_dim, out_dim = q_out_dim, hidden
        elif name in ("gate_proj", "up_proj"):
            in_dim, out_dim = hidden, intermediate
        elif name == "down_proj":
            in_dim, out_dim = intermediate, hidden
        else:
            # Unknown step — defer to deployment generator.
            continue
        in_dim_per_pe = max(1, in_dim // smoke_size)
        num_blocks_per_row = max(1, in_dim_per_pe // Q4K_BLOCK)
        gemv_invocations.append({
            "stepName": name,
            "paramsShape": {
                "width": smoke_size,
                "out_dim": out_dim,
                "in_dim_per_pe": in_dim_per_pe,
                "num_blocks_per_row": num_blocks_per_row,
            },
            "cslcParamsString": (
                f"width:{smoke_size},"
                f"out_dim:{out_dim},"
                f"in_dim_per_pe:{in_dim_per_pe},"
                f"num_blocks_per_row:{num_blocks_per_row}"
            ),
            "weightMatrixShape": f"M=1 K={in_dim} N={out_dim} (decode row-vector)",
        })
    if gemv_invocations:
        shapes.append({
            "pattern": "fused_gemv_dequant",
            "emitter": "emitFusedGemvLayout (runtime/zig/src/compiler/wgsl/emit/csl/emit_csl_layout.zig:448)",
            "emitterWidened2D": False,
            "invocations": gemv_invocations,
            "derivationSource": (
                "width = --size smoke arg (deployment picks per-weight-matrix "
                "width from memory-plan budgets; the audit flags this pattern "
                "as needs2DFor31B=likely pending step-1 generator output). "
                "out_dim per step from manifest.modelConfig: hiddenDim, "
                "q_out_dim = numHeads*headDim, kv_out_dim = "
                "numKeyValueHeads*headDim, or intermediate = "
                "hiddenDim*ffnExpansionFactor. in_dim_per_pe = in_dim // width. "
                "num_blocks_per_row = in_dim_per_pe // 32 (Q4K GGML block)."
            ),
            "manifestSteps": [inv["stepName"] for inv in gemv_invocations],
            "status": "audit_needs_deployment_generator",
        })
    # Smoke-shape attention_streaming (dormant): emitter at L357 takes
    # width + head_dim + kv_len. Per the audit stays 1-D (per-head). No
    # Gemma-4 manifest step currently lands on this pattern — the model
    # uses attention_tiled for prefill and attention_decode for decode.
    # The entry records emitter-default shape so the 14-pattern coverage
    # stays complete; real deployment would populate this when a future
    # model adds a streaming-attention variant.
    shapes.append({
        "pattern": "attention_streaming",
        "emitter": "emitStreamingAttentionLayout (runtime/zig/src/compiler/wgsl/emit/csl/emit_csl_layout.zig:357)",
        "emitterWidened2D": False,
        "invocations": [{
            "stepName": "(dormant)",
            "paramsShape": {
                "width": smoke_size,
                "head_dim": head_dim or 128,
                "kv_len": max_seq_len,
            },
            "cslcParamsString": (
                f"width:{smoke_size},"
                f"head_dim:{head_dim or 128},"
                f"kv_len:{max_seq_len}"
            ),
        }],
        "derivationSource": (
            "width = num_tokens from --size; head_dim from "
            "manifest.modelConfig.headDim; kv_len = manifest.modelConfig.maxSeqLen. "
            "Pattern is dormant in Gemma-4 — no manifest step has op=attention_streaming."
        ),
        "manifestSteps": [],
        "status": "dormant_pattern_no_manifest_step",
    })
    # Smoke-shape attention_linear (dormant): emitter at L489 takes
    # width + head_dim + kv_len (no q_len). Same dormant story as
    # streaming attention — Gemma-4 doesn't use linear attention.
    shapes.append({
        "pattern": "attention_linear",
        "emitter": "emitLinearAttentionLayout (runtime/zig/src/compiler/wgsl/emit/csl/emit_csl_layout.zig:489)",
        "emitterWidened2D": False,
        "invocations": [{
            "stepName": "(dormant)",
            "paramsShape": {
                "width": smoke_size,
                "head_dim": head_dim or 64,
                "kv_len": max_seq_len,
            },
            "cslcParamsString": (
                f"width:{smoke_size},"
                f"head_dim:{head_dim or 64},"
                f"kv_len:{max_seq_len}"
            ),
        }],
        "derivationSource": (
            "width = num_tokens from --size; head_dim from "
            "manifest.modelConfig.headDim; kv_len = manifest.modelConfig.maxSeqLen. "
            "Pattern is dormant in Gemma-4 — no manifest step has op=attention_linear."
        ),
        "manifestSteps": [],
        "status": "dormant_pattern_no_manifest_step",
    })
    # Smoke-shape kv_write: emitter at L512 takes width + head_dim +
    # max_seq_len. 1-D per audit (per-head). Manifest has two kv_write
    # variants: standard and shared. Both land on the kv_write pattern.
    kv_write_invocations = []
    for s in manifest.get("steps", []):
        if s.get("op") in ("kv_write", "kv_write_shared"):
            kv_write_invocations.append({
                "stepName": s["name"],
                "variant": "shared" if s.get("op") == "kv_write_shared" else "standard",
                "paramsShape": {
                    "width": smoke_size,
                    "head_dim": head_dim or 128,
                    "max_seq_len": max_seq_len,
                },
                "cslcParamsString": (
                    f"width:{smoke_size},"
                    f"head_dim:{head_dim or 128},"
                    f"max_seq_len:{max_seq_len}"
                ),
            })
    if kv_write_invocations:
        shapes.append({
            "pattern": "kv_write",
            "emitter": "emitKvWriteLayout (runtime/zig/src/compiler/wgsl/emit/csl/emit_csl_layout.zig:512)",
            "emitterWidened2D": False,
            "invocations": kv_write_invocations,
            "derivationSource": (
                "width = num_tokens from --size (1-D per-head). "
                "head_dim from manifest.modelConfig.headDim; max_seq_len "
                "is the KV-cache capacity bound from "
                "manifest.modelConfig.maxSeqLen. Shared variant uses the "
                "same --params shape; the shared/standard split is "
                "surfaced via the invocation's `variant` field for "
                "downstream routing."
            ),
            "manifestSteps": [inv["stepName"] for inv in kv_write_invocations],
        })
    # Smoke-shape kv_read: emitter at L535 takes width + head_dim +
    # read_len. 1-D per audit. Not in E2B/31B manifests today — the
    # pattern is dormant in current Gemma-4 steps; every attention
    # kernel inlines its own KV fetch. Emit the entry anyway so the
    # generator's shape coverage matches the 14-emitter audit.
    shapes.append({
        "pattern": "kv_read",
        "emitter": "emitKvReadLayout (runtime/zig/src/compiler/wgsl/emit/csl/emit_csl_layout.zig:535)",
        "emitterWidened2D": False,
        "invocations": [{
            "stepName": "(dormant)",
            "paramsShape": {
                "width": smoke_size,
                "head_dim": head_dim or 128,
                "read_len": smoke_size,
            },
            "cslcParamsString": (
                f"width:{smoke_size},"
                f"head_dim:{head_dim or 128},"
                f"read_len:{smoke_size}"
            ),
        }],
        "derivationSource": (
            "width = num_tokens from --size; head_dim from "
            "manifest.modelConfig.headDim; read_len defaults to "
            "num_tokens for the smoke case — the dormant pattern has "
            "no manifest step driving its shape. If a future graph adds "
            "an explicit kv_read step, derivation should key on that "
            "step's payload."
        ),
        "manifestSteps": [],
        "status": "dormant_pattern_no_manifest_step",
    })
    # Smoke-shape reduction (RMSNorm / softmax single-PE lowering): the
    # emitter at L112 declares only `param width: i16;` — reduce_color,
    # pe_id, and num_pes are set at tile-code time by the layout, not
    # via --params. Width is per-token (one PE per token for the single-
    # PE RMSNorm lowering); per the audit reduction stays 1-D because
    # num_tokens stays <= i16.
    reduction_manifest_ops = ("rmsnorm", "ple_norm", "softmax", "layernorm")
    shapes.append({
        "pattern": "reduction",
        "emitter": "emitReductionLayout (runtime/zig/src/compiler/wgsl/emit/csl/emit_csl_layout.zig:112)",
        "emitterWidened2D": False,
        "paramsShape": {
            "width": smoke_size,
            # hidden_size is a PE-program param (not a layout --params), but
            # it's the key dim for per-PE element count in reduction —
            # each PE sums hidden_size f32 values per token. Carry it here
            # so the predicted-footprint derivation has the data it needs
            # (prior formula returned 1 elem/PE and mispredicted observed
            # by ~1000x — predictedToObservedBytesRatio fed back the fix).
            "hidden_size": hidden_dim or 64,
        },
        "cslcParamsString": f"width:{smoke_size}",
        "derivationSource": (
            "width = num_tokens from --size (reduction emitter declares "
            "only `param width` at layout level; pe_id/num_pes/reduce_color "
            "are set per-tile by the layout not via --params). Single-PE "
            "mode per emit_csl_reduction.zig: each PE processes one full "
            "token — width <= max_seq_len <= i16, so 1-D stays fine. "
            "hidden_size is a PE-program param carried here for the "
            "predicted-footprint per-PE element derivation only."
        ),
        "manifestSteps": [
            s["name"] for s in manifest.get("steps", [])
            if s.get("op") in reduction_manifest_ops
        ],
    })
    for entry in shapes:
        attach_fixture_equivalent(entry)
    return shapes


def main() -> int:
    args = parse_args()
    plan_path = resolve(args.execution_plan)
    plan = json.loads(plan_path.read_text())

    layers = plan["perLayerSchedule"]
    if args.layer_index < 0 or args.layer_index >= len(layers):
        raise SystemExit(f"--layer-index {args.layer_index} out of range 0..{len(layers) - 1}")
    layer = layers[args.layer_index]

    # Read the manifest that produced this plan so per-kernel shapes can be
    # grounded in modelConfig dims, not hand-typed numbers. Parametric via
    # --manifest so the same generator emits E2B or 31B runners.
    manifest_rel = args.manifest
    manifest_path = resolve(manifest_rel)
    manifest = json.loads(manifest_path.read_text())
    per_kernel_shapes = derive_per_kernel_shapes(plan, manifest, args.smoke_size)
    # Default chain depth comes from the manifest's modelConfig.numLayers
    # so the smoke matches the model's real transformer-block tower depth.
    num_layers_default = int(manifest.get("modelConfig", {}).get("numLayers", 2))

    # Build the comment that captures the stream contract from the plan.
    stream_contract_lines = [
        f"//   region:  {layer['codeRegion']}",
        f"//   layer:   {layer['layerIndex']}",
    ]
    for s in layer.get("streams", []):
        stream_contract_lines.append(
            f"//   input:   {s['streamId']} ({s['payloadBytes']} bytes/PE)"
        )
    stream_contract_comment = "\n".join(stream_contract_lines)
    stream_payloads = {
        str(s["streamId"]): int(s.get("payloadBytes", 0))
        for s in layer.get("streams", [])
    }
    rows_payload_bytes = stream_payloads.get("ple_rows_stream", 0)
    proj_payload_bytes = stream_payloads.get("ple_projection_stream", 0)
    wts_payload_bytes = stream_payloads.get("layer_weights_stream", 0)
    rows_io_buffer_size = stream_buffer_size(rows_payload_bytes)
    proj_io_buffer_size = stream_buffer_size(proj_payload_bytes)
    wts_io_buffer_size = stream_buffer_size(wts_payload_bytes)
    activation_io_buffer_size = 1024

    kernel_source_path = resolve(args.kernel_source)
    kernel_source_rel = str(kernel_source_path.relative_to(REPO_ROOT))
    plan_path_rel = str(plan_path.relative_to(REPO_ROOT))
    plan_sha256 = sha256(plan_path)
    kernel_source_sha256 = sha256(kernel_source_path)

    # Render perKernelShapes as a Python-literal dict inside the runner
    # (the runner embeds it verbatim in the trace). json.dumps gives valid
    # Python for the values we emit here (True is JSON true, which Python
    # also accepts under json.loads; the generated runner serializes via
    # json.dumps so the True/False/None mapping round-trips cleanly).
    per_kernel_shapes_literal = json.dumps(per_kernel_shapes, indent=4) \
        .replace("true", "True").replace("false", "False").replace("null", "None")

    source_model_receipt_rel = args.source_model_receipt
    model_id = str(plan.get("modelId", ""))
    model_id_lower = model_id.lower()
    if "31b" in model_id_lower:
        model_label = "Gemma 4 31B"
        model_label_slug = "gemma-4-31b"
    elif "e2b" in model_id_lower:
        model_label = "Gemma 4 E2B"
        model_label_slug = "gemma-4-e2b"
    else:
        model_label = model_id or "model"
        model_label_slug = model_label.lower().replace(" ", "-")
    runner_text = TEMPLATE.format(
        plan_path_rel=plan_path_rel,
        plan_sha256=plan_sha256,
        layer_index=args.layer_index,
        smoke_size=args.smoke_size,
        num_layers_default=num_layers_default,
        kernel_source_rel=kernel_source_rel,
        kernel_source_sha256=kernel_source_sha256,
        region_name=layer["codeRegion"],
        model_id=model_id,
        model_label=model_label,
        model_label_slug=model_label_slug,
        stream_contract_comment=stream_contract_comment,
        rows_payload_bytes=rows_payload_bytes,
        proj_payload_bytes=proj_payload_bytes,
        wts_payload_bytes=wts_payload_bytes,
        rows_io_buffer_size=rows_io_buffer_size,
        proj_io_buffer_size=proj_io_buffer_size,
        wts_io_buffer_size=wts_io_buffer_size,
        activation_io_buffer_size=activation_io_buffer_size,
        per_kernel_shapes_literal=per_kernel_shapes_literal,
        source_model_receipt_rel=source_model_receipt_rel,
    )

    runner_out = resolve(args.runner_out)
    runner_out.parent.mkdir(parents=True, exist_ok=True)
    runner_out.write_text(runner_text, encoding="utf-8")
    runner_out.chmod(0o755)

    print(
        f"generated {runner_out.relative_to(REPO_ROOT)} from "
        f"{plan_path_rel} (layer {args.layer_index}, "
        f"{len(layer.get('streams', []))} input streams, "
        f"region={layer['codeRegion']!r})"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
