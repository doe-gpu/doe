#!/usr/bin/env cs_python
"""SdkLayout streaming executor — iteration 2.

Extends iter-1 (compile + load + run + stop) with the real stream
contract: create_input_port / create_output_port on the code region,
bind fabric colors via set_param_all, create_input_stream /
create_output_stream on the layout, then runtime.send / runtime.receive
for actual data flow.

Kernel: bench/out/streaming-executor/iter2-source/stream_passthrough.csl
— identity via @mov32 DSD from fabric color rx to fabric color tx.

Verification: the received buffer must equal the sent buffer bit-exactly
(no copy transformation in the passthrough). Trace records observed
bytes and wall times.
"""

from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path

import numpy as np

from cerebras.sdk.runtime.sdkruntimepybind import (  # pylint: disable=no-name-in-module
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


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser()
    p.add_argument(
        "--kernel-source",
        default="bench/out/streaming-executor/iter2-source/stream_passthrough.csl",
    )
    p.add_argument("--region-name", default="stream_passthrough")
    p.add_argument("--size", type=int, default=16)
    p.add_argument(
        "--compile-out",
        default="bench/out/streaming-executor/iter2",
    )
    p.add_argument(
        "--trace-out",
        default="bench/out/streaming-executor/iter2-trace.json",
    )
    p.add_argument("--cmaddr", default="")
    return p.parse_args()


REPO_ROOT = Path(__file__).resolve().parents[3]


def resolve(raw: str) -> Path:
    p = Path(raw)
    return p if p.is_absolute() else REPO_ROOT / p


def main() -> int:
    args = parse_args()
    kernel_source_path = resolve(args.kernel_source)
    compile_out = resolve(args.compile_out)
    compile_out.mkdir(parents=True, exist_ok=True)

    # Build the layout.
    compile_start = time.time()
    config = SimfabConfig(dump_core=False)
    target = SdkTarget.WSE3
    platform = get_platform(args.cmaddr.strip(), config, target)
    layout = SdkLayout(platform)

    # Single-PE code region running the passthrough kernel.
    region = layout.create_code_region(str(kernel_source_path), args.region_name, 1, 1)

    # Fabric colors for input/output + routing from the region edges.
    rx = Color("rx")
    tx = Color("tx")
    receiver_routes = RoutingPosition().set_output([Route.RAMP])
    sender_routes = RoutingPosition().set_input([Route.RAMP])

    region.set_param_all("size", args.size)
    region.set_param_all(rx)
    region.set_param_all(tx)

    rx_port = region.create_input_port(rx, Edge.LEFT, [receiver_routes], args.size)
    tx_port = region.create_output_port(tx, Edge.RIGHT, [sender_routes], args.size)
    region.place(4, 1)

    in_stream = layout.create_input_stream(rx_port)
    out_stream = layout.create_output_stream(tx_port)

    compile_prefix = str(compile_out / args.region_name)
    compile_artifacts = layout.compile(out_prefix=compile_prefix)
    compile_elapsed_ms = (time.time() - compile_start) * 1000.0

    # Runtime execution.
    run_start = time.time()
    runtime = SdkRuntime(compile_artifacts, platform, memcpy_required=False)
    try:
        runtime.load()
        runtime.run()

        rng = np.random.default_rng(seed=131)
        sent = rng.integers(0, 1 << 20, size=args.size, dtype=np.uint32)
        received = np.empty(args.size, dtype=np.uint32)
        runtime.send(in_stream, sent, nonblock=True)
        runtime.receive(out_stream, received, args.size, nonblock=True)
        runtime.stop()

        max_abs_err = int(np.max(np.abs(received.astype(np.int64) - sent.astype(np.int64))))
        passed = bool(np.array_equal(received, sent))
        run_status = "succeeded" if passed else "mismatch"
    except Exception as exc:  # pylint: disable=broad-except
        max_abs_err = -1
        passed = False
        run_status = f"failed:{type(exc).__name__}:{str(exc)[:160]}"
    run_elapsed_ms = (time.time() - run_start) * 1000.0

    observed_bytes_sent = args.size * 4  # u32
    observed_bytes_received = args.size * 4

    trace = {
        "schemaVersion": 1,
        "artifactKind": "doe_streaming_executor_trace",
        "target": "wse3",
        "modelId": "",
        "executorIteration": 2,
        "sourcePlan": {
            "streamGraphPath": "",
            "executionPlanPath": "",
            "kernelSourcePath": str(kernel_source_path.relative_to(REPO_ROOT)),
        },
        "region": {
            "regionId": args.region_name,
            "width": 1,
            "height": 1,
            "peCount": 1,
        },
        "executedCompile": {
            "compilePrefix": str(Path(compile_prefix).relative_to(REPO_ROOT)),
            "elapsedMs": compile_elapsed_ms,
            "status": "succeeded",
        },
        "executedRun": {
            "status": run_status,
            "elapsedMs": run_elapsed_ms,
            "observedBytesTransferredPerPe": observed_bytes_sent + observed_bytes_received,
            "observedBytesTransferredTotal": observed_bytes_sent + observed_bytes_received,
            "numericalParity": {
                "maxAbsErr": max_abs_err,
                "atol": 0,
                "passed": passed,
            },
        },
        "streams": [
            {"role": "input",  "color": "rx", "size": args.size, "dtype": "uint32"},
            {"role": "output", "color": "tx", "size": args.size, "dtype": "uint32"},
        ],
        "notes": (
            "Iter-2 — real data flow through SdkLayout streams. Single 1×1 PE "
            "region runs @mov32 DSD passthrough from rx to tx. Future "
            "iterations extend to multi-PE regions, multiple streams, ring "
            "buffers, and compile-artifact caching."
        ),
    }

    trace_path = resolve(args.trace_out)
    trace_path.parent.mkdir(parents=True, exist_ok=True)
    trace_path.write_text(json.dumps(trace, indent=2) + "\n", encoding="utf-8")

    print(f"executor iter-2: compile {compile_elapsed_ms:.1f} ms, "
          f"run {run_elapsed_ms:.1f} ms, run_status={run_status!r}, "
          f"passed={passed}, max_abs_err={max_abs_err} → {trace_path}")
    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main())
