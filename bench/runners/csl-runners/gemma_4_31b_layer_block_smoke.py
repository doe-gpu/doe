#!/usr/bin/env cs_python
"""GENERATED — Gemma 4 31B layer-block smoke runner.

Produced by bench/tools/generate_e2b_layer_block_runner.py from
bench/out/31b-full-graph/gemma-4-31b-stream-execution-plan.json (layer 0). Do not hand-edit; rerun the
generator instead.

Plan stream contract for this layer:
//   region:  transformer_layer_shape
//   layer:   0
//   input:   ple_rows_stream (1 bytes/PE)
//   input:   ple_projection_stream (23 bytes/PE)
//   input:   layer_weights_stream (7225 bytes/PE)

Smoke path: each stream carries 1024 f32 values. The kernel
runs the full 4-stage layer block (pre-attn RMSNorm; MHA with vector
Q/K/V, real-cos/sin rope, poly_c1 softmax; post-attn RMSNorm; gated
MLP with poly_c1 activation), and the runner CHAINS num_layers
(=61 by default) invocations of that kernel via
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
KERNEL_SOURCE = REPO_ROOT / "bench/out/streaming-executor/e2b-layer-block-source/transformer_layer_shape.csl"


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser()
    p.add_argument("--size", type=int, default=1024)
    p.add_argument(
        "--num-layers", type=int, default=61,
        help="How many layer-block invocations to chain (residual stream). "
             "Default = manifest.modelConfig.numLayers (61).",
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
        str(KERNEL_SOURCE), "transformer_layer_shape", 1, 1
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

    io_buffer_sizes = {
        "rows": 1024,
        "proj": 1024,
        "wts": 8192,
        "activation": 1024,
    }
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
        ("24b8dc11a180534df27100257cdbbbd8fabaa81ea1979b8cfacd0e659a7eacab|7cbaeaebbf48a53a41f0667cec91bd4618faff9e6befca5a3294ca21aa04b86a|wse3|size=" + str(args.size)).encode("utf-8")
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
    runtime_stop = {
        "reached": False,
        "elapsedMs": None,
        "error": None,
    }
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
    stream_counters = {
        "ple_rows_stream": {
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
        },
        "ple_projection_stream": {
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
        },
        "layer_weights_stream": {
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
        },
        "activation_out_stream": {
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
        },
    }
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
        stream_events.append({
            "event": "issued",
            "streamId": stream_id,
            "operation": operation,
            "layerIndex": layer_index,
            "pendingAfter": state["pendingCount"],
        })

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
        event = {
            "event": "completed",
            "streamId": stream_id,
            "operation": operation,
            "layerIndex": layer_index,
            "pendingAfter": state["pendingCount"],
            "doneBeforeWait": done_before_wait,
            "taskWaitMs": wait_elapsed_ms,
        }
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
        runtime_stop = {
            "reached": True,
            "elapsedMs": (time.time() - stop_start) * 1000.0,
            "error": None,
        }

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
        # f32 bytes and capture {dtype, shape, path, sha256, preview}.
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
        output_digest = {
            "dtype": "float32",
            "shape": [int(_final.shape[0])],
            "path": str(_output_path.relative_to(REPO_ROOT)),
            "sha256": _h.hexdigest(),
            "preview": [
                float(_final[_i])
                for _i in range(min(8, int(_final.shape[0])))
            ],
        }

        # Per-layer activation_out dumps: one .f32 per layer so the
        # demo page and downstream parity gates can compare CSL vs
        # WebGPU layer-by-layer (the right granularity for deep
        # chains where ULP-per-layer drift compounds). Writes to
        # <trace>.per_layer/layer{N}.f32 beside the final output.
        per_layer_output_dir = _trace_path.parent / (_trace_path.stem + ".per_layer")
        per_layer_output_dir.mkdir(parents=True, exist_ok=True)
        for _l_idx, _layer_out in enumerate(all_received):
            _layer_path = per_layer_output_dir / ("layer" + str(_l_idx) + ".f32")
            _layer_out.astype(np.float32).tofile(_layer_path)
            _h_layer = _hashlib.sha256()
            with _layer_path.open("rb") as _fh:
                for _ck in iter(lambda: _fh.read(1 << 20), b""):
                    _h_layer.update(_ck)
            per_layer_output_records.append({
                "layer": _l_idx,
                "path": str(_layer_path.relative_to(REPO_ROOT)),
                "sha256": _h_layer.hexdigest(),
                "shape": [int(_layer_out.shape[0])],
            })
    except Exception as exc:  # pylint: disable=broad-except
        if current_stream_id in stream_counters and current_operation is not None:
            state = stream_counters[current_stream_id]
            state["lastErrorType"] = type(exc).__name__
            state["lastErrorMessage"] = str(exc)[:160]
        run_status = f"failed:" + type(exc).__name__ + ":" + str(exc)[:160]
        failure_context = {
            "failedAtStage": current_stage,
            "failedAtDispatchIndex": current_dispatch_index,
            "lastActiveStreamId": current_stream_id,
            "lastActiveOperation": current_operation,
            "lastCompletedStreamSendReceive": last_completed_stream_send_receive,
            "streamCounters": stream_counter_list(),
            "streamEventsTail": stream_events[-16:],
            "errorType": type(exc).__name__,
            "message": str(exc)[:500],
        }
        output_digest = None
    run_elapsed_ms = (time.time() - run_start) * 1000.0

    trace = {
        "schemaVersion": 1,
        "artifactKind": "doe_streaming_executor_trace",
        "target": "wse3",
        "modelId": "gemma-4-31b-it-text-q4k-ehf16-af32",
        "executorIteration": 8,
        "sourcePlan": {
            "streamGraphPath": "",
            "executionPlanPath": "bench/out/31b-full-graph/gemma-4-31b-stream-execution-plan.json",
            "kernelSourcePath": "bench/out/streaming-executor/e2b-layer-block-source/transformer_layer_shape.csl",
        },
        "region": {
            "regionId": "transformer_layer_shape_L00",
            "width": 1,
            "height": 1,
            "peCount": 1,
        },
        "executedCompile": {
            "compilePrefix": str(Path(compile_prefix).relative_to(REPO_ROOT)),
            "elapsedMs": compile_elapsed_ms,
            "status": "succeeded",
            "cacheKey": compile_cache_key,
            "cacheKeyComponents": {
                "kernelSourceSha256": "24b8dc11a180534df27100257cdbbbd8fabaa81ea1979b8cfacd0e659a7eacab",
                "planSha256": "7cbaeaebbf48a53a41f0667cec91bd4618faff9e6befca5a3294ca21aa04b86a",
                "target": "wse3",
                "size": args.size,
            },
            "cacheState": "miss_uncached",
        },
        "executedRun": {
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
            "streamTelemetry": {
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
            },
            "streamEventsTail": stream_events[-64:],
            "runtimeStop": runtime_stop,
            "failure": failure_context,
            "dataSource": {
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
            },
            "numericalParity": {
                "maxAbsErr": max_abs_err,
                "perLayerMaxAbsErr": per_layer_max_abs_err,
                "atol": 0,
                "passed": passed,
            },
            "output": output_digest,
        },
        "streams": [
            {"role": "input",  "color": "rx_ple_rows",        "size": args.size, "dtype": "float32"},
            {"role": "input",  "color": "rx_ple_projection",  "size": args.size, "dtype": "float32"},
            {"role": "input",  "color": "rx_layer_weights",   "size": args.size, "dtype": "float32"},
            {"role": "output", "color": "tx_activation",      "size": args.size, "dtype": "float32"},
        ],
        "layerBlockSmoke": {
            "planPath": "bench/out/31b-full-graph/gemma-4-31b-stream-execution-plan.json",
            "planSha256": "7cbaeaebbf48a53a41f0667cec91bd4618faff9e6befca5a3294ca21aa04b86a",
            "layerIndex": 0,
            "regionName": "transformer_layer_shape",
            "kernelSourcePath": "bench/out/streaming-executor/e2b-layer-block-source/transformer_layer_shape.csl",
            "kernelSourceSha256": "24b8dc11a180534df27100257cdbbbd8fabaa81ea1979b8cfacd0e659a7eacab",
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
            "connectionGraph": {
                "region": "transformer_layer_shape",
                "grid": {"width": 1, "height": 1, "peCount": 1, "place": [4, 2]},
                "inputPorts": [
                    {"color": "rx_ple_rows",       "edge": "LEFT",   "size": args.size},
                    {"color": "rx_ple_projection", "edge": "TOP",    "size": args.size},
                    {"color": "rx_layer_weights",  "edge": "BOTTOM", "size": args.size},
                ],
                "outputPorts": [
                    {"color": "tx_activation",     "edge": "RIGHT",  "size": args.size},
                ],
                "crossRegionConnections": [],
            },
            "hostIoLayout": [
                {"streamId": "ple_rows_stream",       "role": "input",  "elementsPerPe": args.size,
                  "dtype": "float32", "order": "row_major", "roi": [4, 2, 1, 1],
                  "tileBehavior": "stream", "planPayloadBytes": 1,
                  "ioBufferSize": io_buffer_sizes["rows"]},
                {"streamId": "ple_projection_stream", "role": "input",  "elementsPerPe": args.size,
                  "dtype": "float32", "order": "row_major", "roi": [4, 2, 1, 1],
                  "tileBehavior": "stream", "planPayloadBytes": 23,
                  "ioBufferSize": io_buffer_sizes["proj"]},
                {"streamId": "layer_weights_stream",  "role": "input",  "elementsPerPe": args.size,
                  "dtype": "float32", "order": "row_major", "roi": [4, 2, 1, 1],
                  "tileBehavior": "stream", "planPayloadBytes": 7225,
                  "ioBufferSize": io_buffer_sizes["wts"]},
                {"streamId": "activation_out_stream", "role": "output", "elementsPerPe": args.size,
                  "dtype": "float32", "order": "row_major", "roi": [4, 2, 1, 1],
                  "tileBehavior": "stream", "planPayloadBytes": 0,
                  "ioBufferSize": io_buffer_sizes["activation"]},
            ],
            "ioBufferPolicy": {
                "rule": "next_power_of_two(max(1024, planPayloadBytes))",
                "underSizedIsFailure": True,
                "overFourTimesPayloadIsWarning": True,
            },
            "ioBufferSizes": io_buffer_sizes,
            "sendReceiveCounts": {"sends": 3, "receives": 1},
            "simulatorArtifactPaths": {
                "compileDir": str(compile_out.relative_to(REPO_ROOT)),
                "runLogs": [],
                "coreFile": None,
            },
            "sourceModelReceiptPath": "bench/out/31b-full-graph/gemma-4-31b-runtime-receipt.json",
            "perKernelShapes": [
    {
        "pattern": "gather",
        "emitter": "emitGatherLayout (runtime/zig/src/compiler/wgsl/emit/csl/emit_csl_layout.zig:237)",
        "emitterWidened2D": True,
        "paramsShape": {
            "width": 1024,
            "height": 1,
            "hidden_size": 5120,
            "rows_per_pe": 8,
            "num_tokens": 1024
        },
        "cslcParamsString": "width:1024,height:1,hidden_size:5120,rows_per_pe:8,num_tokens:1024",
        "derivationSource": "width/num_tokens from --size smoke arg; hidden_size from manifest.modelConfig.hiddenDim; height=1 for smoke (2-D needed for 31B full-grid per layout-2d-needs audit); rows_per_pe is the emitter default with no manifest override yet.",
        "manifestSteps": [
            "embed_tokens",
            "ple_gather",
            "ple_gather"
        ],
        "fixtureEquivalentCslcParamsString": "width:4,height:1"
    },
    {
        "pattern": "rope",
        "emitter": "emitRoPELayout (runtime/zig/src/compiler/wgsl/emit/csl/emit_csl_layout.zig:263)",
        "emitterWidened2D": False,
        "paramsShape": {
            "width": 1024,
            "head_dim": 160,
            "num_pairs": 80
        },
        "cslcParamsString": "width:1024,head_dim:160,num_pairs:80",
        "derivationSource": "width = num_tokens from --size (1-D layout, per-token \u2014 layout-2d-needs audit keeps rope 1-D since num_tokens<=i16); head_dim from manifest.modelConfig.headDim; num_pairs is the standard RoPE half-head_dim convention (cos+sin pair count).",
        "manifestSteps": [
            "rope_q",
            "rope_k",
            "rope_q",
            "rope_k"
        ],
        "fixtureEquivalentCslcParamsString": "width:4,height:1"
    },
    {
        "pattern": "tiled_matmul",
        "emitter": "emitMatmulLayout (runtime/zig/src/compiler/wgsl/emit/csl/emit_csl_layout.zig:168)",
        "emitterWidened2D": True,
        "invocations": [
            {
                "stepName": "q_proj",
                "paramsShape": {
                    "P": 2,
                    "Mt": 512,
                    "Kt": 2560,
                    "Nt": 2560
                },
                "cslcParamsString": "P:2,Mt:512,Kt:2560,Nt:2560",
                "weightMatrixShape": "M=1024 K=5120 N=5120"
            },
            {
                "stepName": "k_proj",
                "paramsShape": {
                    "P": 2,
                    "Mt": 512,
                    "Kt": 2560,
                    "Nt": 80
                },
                "cslcParamsString": "P:2,Mt:512,Kt:2560,Nt:80",
                "weightMatrixShape": "M=1024 K=5120 N=160"
            },
            {
                "stepName": "v_proj",
                "paramsShape": {
                    "P": 2,
                    "Mt": 512,
                    "Kt": 2560,
                    "Nt": 80
                },
                "cslcParamsString": "P:2,Mt:512,Kt:2560,Nt:80",
                "weightMatrixShape": "M=1024 K=5120 N=160"
            },
            {
                "stepName": "o_proj",
                "paramsShape": {
                    "P": 2,
                    "Mt": 512,
                    "Kt": 2560,
                    "Nt": 2560
                },
                "cslcParamsString": "P:2,Mt:512,Kt:2560,Nt:2560",
                "weightMatrixShape": "M=1024 K=5120 N=5120"
            },
            {
                "stepName": "gate_proj",
                "paramsShape": {
                    "P": 2,
                    "Mt": 512,
                    "Kt": 2560,
                    "Nt": 10240
                },
                "cslcParamsString": "P:2,Mt:512,Kt:2560,Nt:10240",
                "weightMatrixShape": "M=1024 K=5120 N=20480"
            },
            {
                "stepName": "up_proj",
                "paramsShape": {
                    "P": 2,
                    "Mt": 512,
                    "Kt": 2560,
                    "Nt": 10240
                },
                "cslcParamsString": "P:2,Mt:512,Kt:2560,Nt:10240",
                "weightMatrixShape": "M=1024 K=5120 N=20480"
            },
            {
                "stepName": "down_proj",
                "paramsShape": {
                    "P": 2,
                    "Mt": 512,
                    "Kt": 10240,
                    "Nt": 2560
                },
                "cslcParamsString": "P:2,Mt:512,Kt:10240,Nt:2560",
                "weightMatrixShape": "M=1024 K=20480 N=5120"
            }
        ],
        "derivationSource": "P = 2 for smoke (even SUMMA partition; real deployment picks P from memory-plan); Mt/Kt/Nt = weight-matrix dim // P. Weight matrix M/K/N derived from manifest.modelConfig: M = num_tokens (--size), K/N chosen per step \u2014 hiddenDim for projection inputs and output (q/k/v/o), intermediate = hiddenDim * ffnExpansionFactor for FFN gate/up N-dim and down K-dim, q_out_dim = numHeads * headDim for q/o and kv_out_dim = numKeyValueHeads * headDim for k/v. globalHeadDim is recorded for the manifest-shape attention rewrite (current value absent). This per-invocation shape emission is the pattern the 4 audit-blocked emitters (dequant/sample/fused_gemv/fused_ffn) will also use.",
        "manifestSteps": [
            "q_proj",
            "k_proj",
            "v_proj",
            "o_proj",
            "gate_proj",
            "up_proj",
            "down_proj"
        ],
        "fixtureEquivalentCslcParamsString": "width:2,height:2,P:2,Mt:8,Kt:8,Nt:8"
    },
    {
        "pattern": "attention_tiled",
        "emitter": "emitTiledAttentionLayout (runtime/zig/src/compiler/wgsl/emit/csl/emit_csl_layout.zig:403)",
        "emitterWidened2D": False,
        "invocations": [
            {
                "stepName": "attention",
                "paramsShape": {
                    "width": 1024,
                    "head_dim": 160,
                    "kv_len": 4096,
                    "q_len": 1024
                },
                "cslcParamsString": "width:1024,head_dim:160,kv_len:4096,q_len:1024"
            }
        ],
        "derivationSource": "width/q_len = num_tokens from --size (1-D per-tile row); head_dim from manifest.modelConfig.headDim; kv_len = manifest.modelConfig.maxSeqLen as the prefill upper bound (4096 for both E2B and 31B \u2014 well under i16). Per the layout-2d-needs audit, attention_tiled stays 1-D.",
        "manifestSteps": [
            "attention"
        ],
        "fixtureEquivalentCslcParamsString": "width:4,height:1,head_dim:32,kv_len:64,q_len:32"
    },
    {
        "pattern": "attention_decode",
        "emitter": "emitDecodeAttentionLayout (runtime/zig/src/compiler/wgsl/emit/csl/emit_csl_layout.zig:379)",
        "emitterWidened2D": False,
        "invocations": [
            {
                "stepName": "attention_sliding",
                "variant": "sliding",
                "paramsShape": {
                    "width": 1024,
                    "head_dim": 160,
                    "kv_chunk": 1
                },
                "cslcParamsString": "width:1024,head_dim:160,kv_chunk:1",
                "kvLenBound": 512
            },
            {
                "stepName": "attention_global",
                "variant": "global",
                "paramsShape": {
                    "width": 1024,
                    "head_dim": 160,
                    "kv_chunk": 4
                },
                "cslcParamsString": "width:1024,head_dim:160,kv_chunk:4",
                "kvLenBound": 4096
            }
        ],
        "derivationSource": "width = num_tokens from --size (1-D per-head-per-chunk); head_dim from manifest.modelConfig.headDim; kv_chunk = kv_len_bound // width with kv_len_bound = slidingWindowSize for the sliding variant and maxSeqLen for the global decode. Both bounds stay well under i16 at Gemma-4 shapes. Per the layout-2d-needs audit, attention_decode stays 1-D.",
        "manifestSteps": [
            "attention_sliding",
            "attention_global"
        ],
        "fixtureEquivalentCslcParamsString": "width:4,height:1,head_dim:32,kv_len:64,q_len:1"
    },
    {
        "pattern": "dequant",
        "emitter": "emitDequantLayout (runtime/zig/src/compiler/wgsl/emit/csl/emit_csl_layout.zig:305)",
        "emitterWidened2D": False,
        "invocations": [
            {
                "stepName": "(dormant)",
                "paramsShape": {
                    "width": 1024,
                    "num_blocks": 1
                },
                "cslcParamsString": "width:1024,num_blocks:1"
            }
        ],
        "derivationSource": "width = --size smoke arg; num_blocks = 1 fallback (no manifest step drives this). Gemma-4 fuses dequant into fused_gemv_dequant rather than issuing standalone dequant \u2014 this emitter stays live for future models that separate the two.",
        "manifestSteps": [],
        "status": "dormant_pattern_no_manifest_step"
    },
    {
        "pattern": "fused_ffn",
        "emitter": "emitFusedFfnLayout (runtime/zig/src/compiler/wgsl/emit/csl/emit_csl_layout.zig:557)",
        "emitterWidened2D": False,
        "invocations": [
            {
                "stepName": "(dormant)",
                "paramsShape": {
                    "width": 1024,
                    "in_dim": 5120,
                    "out_dim": 20480,
                    "in_per_pe": 5
                },
                "cslcParamsString": "width:1024,in_dim:5120,out_dim:20480,in_per_pe:5"
            }
        ],
        "derivationSource": "width = --size; in_dim = hiddenDim; out_dim = intermediate = hiddenDim*ffnExpansionFactor; in_per_pe = in_dim // width. No manifest step \u2014 Gemma-4 runs the FFN as three separate matmul steps (gate_proj / up_proj / down_proj) rather than fusing into one kernel, so this entry covers emitter presence only.",
        "manifestSteps": [],
        "status": "dormant_pattern_no_manifest_step"
    },
    {
        "pattern": "sample",
        "emitter": "emitSampleLayout (runtime/zig/src/compiler/wgsl/emit/csl/emit_csl_layout.zig:428)",
        "emitterWidened2D": False,
        "invocations": [
            {
                "stepName": "sample",
                "paramsShape": {
                    "width": 1024,
                    "chunk_size": 256
                },
                "cslcParamsString": "width:1024,chunk_size:256",
                "vocabSize": 262144
            }
        ],
        "derivationSource": "width = --size smoke arg; chunk_size = vocabSize // width (vocabSize from manifest.modelConfig.vocabSize = 262,144 for Gemma-4). Smoke partitions evenly but deployment will pick a chunk_size that balances per-PE SRAM budget against reduce-chain hop count \u2014 that choice lives in the step-1 generator, so this entry is flagged audit_needs_deployment_generator.",
        "manifestSteps": [
            "sample"
        ],
        "status": "audit_needs_deployment_generator",
        "fixtureEquivalentCslcParamsString": "width:4,height:1,chunk_size:1024"
    },
    {
        "pattern": "fused_gemv_dequant",
        "emitter": "emitFusedGemvLayout (runtime/zig/src/compiler/wgsl/emit/csl/emit_csl_layout.zig:448)",
        "emitterWidened2D": False,
        "invocations": [
            {
                "stepName": "q_proj",
                "paramsShape": {
                    "width": 1024,
                    "out_dim": 5120,
                    "in_dim_per_pe": 5,
                    "num_blocks_per_row": 1
                },
                "cslcParamsString": "width:1024,out_dim:5120,in_dim_per_pe:5,num_blocks_per_row:1",
                "weightMatrixShape": "M=1 K=5120 N=5120 (decode row-vector)"
            },
            {
                "stepName": "k_proj",
                "paramsShape": {
                    "width": 1024,
                    "out_dim": 160,
                    "in_dim_per_pe": 5,
                    "num_blocks_per_row": 1
                },
                "cslcParamsString": "width:1024,out_dim:160,in_dim_per_pe:5,num_blocks_per_row:1",
                "weightMatrixShape": "M=1 K=5120 N=160 (decode row-vector)"
            },
            {
                "stepName": "v_proj",
                "paramsShape": {
                    "width": 1024,
                    "out_dim": 160,
                    "in_dim_per_pe": 5,
                    "num_blocks_per_row": 1
                },
                "cslcParamsString": "width:1024,out_dim:160,in_dim_per_pe:5,num_blocks_per_row:1",
                "weightMatrixShape": "M=1 K=5120 N=160 (decode row-vector)"
            },
            {
                "stepName": "o_proj",
                "paramsShape": {
                    "width": 1024,
                    "out_dim": 5120,
                    "in_dim_per_pe": 5,
                    "num_blocks_per_row": 1
                },
                "cslcParamsString": "width:1024,out_dim:5120,in_dim_per_pe:5,num_blocks_per_row:1",
                "weightMatrixShape": "M=1 K=5120 N=5120 (decode row-vector)"
            },
            {
                "stepName": "gate_proj",
                "paramsShape": {
                    "width": 1024,
                    "out_dim": 20480,
                    "in_dim_per_pe": 5,
                    "num_blocks_per_row": 1
                },
                "cslcParamsString": "width:1024,out_dim:20480,in_dim_per_pe:5,num_blocks_per_row:1",
                "weightMatrixShape": "M=1 K=5120 N=20480 (decode row-vector)"
            },
            {
                "stepName": "up_proj",
                "paramsShape": {
                    "width": 1024,
                    "out_dim": 20480,
                    "in_dim_per_pe": 5,
                    "num_blocks_per_row": 1
                },
                "cslcParamsString": "width:1024,out_dim:20480,in_dim_per_pe:5,num_blocks_per_row:1",
                "weightMatrixShape": "M=1 K=5120 N=20480 (decode row-vector)"
            },
            {
                "stepName": "down_proj",
                "paramsShape": {
                    "width": 1024,
                    "out_dim": 5120,
                    "in_dim_per_pe": 20,
                    "num_blocks_per_row": 1
                },
                "cslcParamsString": "width:1024,out_dim:5120,in_dim_per_pe:20,num_blocks_per_row:1",
                "weightMatrixShape": "M=1 K=20480 N=5120 (decode row-vector)"
            }
        ],
        "derivationSource": "width = --size smoke arg (deployment picks per-weight-matrix width from memory-plan budgets; the audit flags this pattern as needs2DFor31B=likely pending step-1 generator output). out_dim per step from manifest.modelConfig: hiddenDim, q_out_dim = numHeads*headDim, kv_out_dim = numKeyValueHeads*headDim, or intermediate = hiddenDim*ffnExpansionFactor. in_dim_per_pe = in_dim // width. num_blocks_per_row = in_dim_per_pe // 32 (Q4K GGML block).",
        "manifestSteps": [
            "q_proj",
            "k_proj",
            "v_proj",
            "o_proj",
            "gate_proj",
            "up_proj",
            "down_proj"
        ],
        "status": "audit_needs_deployment_generator",
        "fixtureEquivalentCslcParamsString": "width:4,height:1,out_dim:64,in_dim_per_pe:512,num_blocks_per_row:2"
    },
    {
        "pattern": "attention_streaming",
        "emitter": "emitStreamingAttentionLayout (runtime/zig/src/compiler/wgsl/emit/csl/emit_csl_layout.zig:357)",
        "emitterWidened2D": False,
        "invocations": [
            {
                "stepName": "(dormant)",
                "paramsShape": {
                    "width": 1024,
                    "head_dim": 160,
                    "kv_len": 4096
                },
                "cslcParamsString": "width:1024,head_dim:160,kv_len:4096"
            }
        ],
        "derivationSource": "width = num_tokens from --size; head_dim from manifest.modelConfig.headDim; kv_len = manifest.modelConfig.maxSeqLen. Pattern is dormant in Gemma-4 \u2014 no manifest step has op=attention_streaming.",
        "manifestSteps": [],
        "status": "dormant_pattern_no_manifest_step"
    },
    {
        "pattern": "attention_linear",
        "emitter": "emitLinearAttentionLayout (runtime/zig/src/compiler/wgsl/emit/csl/emit_csl_layout.zig:489)",
        "emitterWidened2D": False,
        "invocations": [
            {
                "stepName": "(dormant)",
                "paramsShape": {
                    "width": 1024,
                    "head_dim": 160,
                    "kv_len": 4096
                },
                "cslcParamsString": "width:1024,head_dim:160,kv_len:4096"
            }
        ],
        "derivationSource": "width = num_tokens from --size; head_dim from manifest.modelConfig.headDim; kv_len = manifest.modelConfig.maxSeqLen. Pattern is dormant in Gemma-4 \u2014 no manifest step has op=attention_linear.",
        "manifestSteps": [],
        "status": "dormant_pattern_no_manifest_step",
        "fixtureEquivalentCslcParamsString": "width:4,height:1"
    },
    {
        "pattern": "kv_write",
        "emitter": "emitKvWriteLayout (runtime/zig/src/compiler/wgsl/emit/csl/emit_csl_layout.zig:512)",
        "emitterWidened2D": False,
        "invocations": [
            {
                "stepName": "kv_write",
                "variant": "standard",
                "paramsShape": {
                    "width": 1024,
                    "head_dim": 160,
                    "max_seq_len": 4096
                },
                "cslcParamsString": "width:1024,head_dim:160,max_seq_len:4096"
            },
            {
                "stepName": "kv_write_shared",
                "variant": "shared",
                "paramsShape": {
                    "width": 1024,
                    "head_dim": 160,
                    "max_seq_len": 4096
                },
                "cslcParamsString": "width:1024,head_dim:160,max_seq_len:4096"
            }
        ],
        "derivationSource": "width = num_tokens from --size (1-D per-head). head_dim from manifest.modelConfig.headDim; max_seq_len is the KV-cache capacity bound from manifest.modelConfig.maxSeqLen. Shared variant uses the same --params shape; the shared/standard split is surfaced via the invocation's `variant` field for downstream routing.",
        "manifestSteps": [
            "kv_write",
            "kv_write_shared"
        ],
        "fixtureEquivalentCslcParamsString": "width:4,height:1,head_dim:32,max_seq_len:64"
    },
    {
        "pattern": "kv_read",
        "emitter": "emitKvReadLayout (runtime/zig/src/compiler/wgsl/emit/csl/emit_csl_layout.zig:535)",
        "emitterWidened2D": False,
        "invocations": [
            {
                "stepName": "(dormant)",
                "paramsShape": {
                    "width": 1024,
                    "head_dim": 160,
                    "read_len": 1024
                },
                "cslcParamsString": "width:1024,head_dim:160,read_len:1024"
            }
        ],
        "derivationSource": "width = num_tokens from --size; head_dim from manifest.modelConfig.headDim; read_len defaults to num_tokens for the smoke case \u2014 the dormant pattern has no manifest step driving its shape. If a future graph adds an explicit kv_read step, derivation should key on that step's payload.",
        "manifestSteps": [],
        "status": "dormant_pattern_no_manifest_step"
    },
    {
        "pattern": "reduction",
        "emitter": "emitReductionLayout (runtime/zig/src/compiler/wgsl/emit/csl/emit_csl_layout.zig:112)",
        "emitterWidened2D": False,
        "paramsShape": {
            "width": 1024,
            "hidden_size": 5120
        },
        "cslcParamsString": "width:1024",
        "derivationSource": "width = num_tokens from --size (reduction emitter declares only `param width` at layout level; pe_id/num_pes/reduce_color are set per-tile by the layout not via --params). Single-PE mode per emit_csl_reduction.zig: each PE processes one full token \u2014 width <= max_seq_len <= i16, so 1-D stays fine. hidden_size is a PE-program param carried here for the predicted-footprint per-PE element derivation only.",
        "manifestSteps": [
            "ple_norm",
            "input_norm",
            "post_attn_norm",
            "ple_norm",
            "input_norm",
            "post_attn_norm"
        ],
        "fixtureEquivalentCslcParamsString": "width:4,height:1"
    }
],
        },
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
    }

    trace_path = resolve(args.trace_out)
    trace_path.parent.mkdir(parents=True, exist_ok=True)
    trace_path.write_text(json.dumps(trace, indent=2) + "\n", encoding="utf-8")

    print(
        "gemma-4-31b layer-block smoke (L00): "
        f"compile={compile_elapsed_ms:.1f}ms, run={run_elapsed_ms:.1f}ms, "
        f"run_status={run_status!r}, passed={passed}, "
        f"max_abs_err={max_abs_err:.3e} -> {trace_path}"
    )
    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main())
