#!/usr/bin/env python3
"""Regression tests for the standalone Bun WebGPU plan executor."""

from __future__ import annotations

import json
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
CLI_PATH = REPO_ROOT / "bench" / "executors" / "run-bun-webgpu-plan.js"
BUN_FFI_PATH = REPO_ROOT / "packages" / "doe-gpu" / "src" / "vendor" / "webgpu" / "bun-ffi.js"
BUN_ENTRY_PATH = REPO_ROOT / "packages" / "doe-gpu" / "src" / "vendor" / "webgpu" / "bun.js"
INDEX_DTS_PATH = REPO_ROOT / "packages" / "doe-gpu" / "src" / "index.d.ts"
DOE_NAMESPACE_PATH = REPO_ROOT / "packages" / "doe-gpu" / "src" / "vendor" / "doe-namespace.js"
BUN = shutil.which("bun")


def write_plan(path: Path) -> None:
    plan = {
        "schemaVersion": 1,
        "planId": "simple_compute_roundtrip",
        "executorId": "bun-webgpu",
        "workloadId": "simple_compute_roundtrip",
        "domain": "compute",
        "comparable": True,
        "timing": {
            "iterations": 1,
            "warmup": 0,
            "timingSource": "doe-execution-total-ns",
            "timingClass": "operation",
        },
        "adapter": {
            "powerPreference": "high-performance",
        },
        "buffers": [
            {
                "id": "input",
                "size": 16,
                "usage": ["storage", "copy_dst"],
            },
            {
                "id": "output",
                "size": 16,
                "usage": ["storage", "copy_src"],
            },
            {
                "id": "readback",
                "size": 16,
                "usage": ["map_read", "copy_dst"],
            },
        ],
        "modules": [
            {
                "id": "multiply",
                "kind": "compute",
                "entryPoint": "main",
                "source": {
                    "kind": "inline",
                    "code": (
                        "@group(0) @binding(0) var<storage, read> input: array<f32>;\n"
                        "@group(0) @binding(1) var<storage, read_write> output: array<f32>;\n"
                        "@compute @workgroup_size(64)\n"
                        "fn main(@builtin(global_invocation_id) gid: vec3u) {\n"
                        "  let i = gid.x;\n"
                        "  if (i < arrayLength(&input)) {\n"
                        "    output[i] = input[i] * 2.0;\n"
                        "  }\n"
                        "}\n"
                    ),
                },
            }
        ],
        "steps": [
            {
                "kind": "writeBuffer",
                "bufferId": "input",
                "offset": 0,
                "data": {
                    "kind": "f32",
                    "values": [1.0, 2.0, 3.0, 4.0],
                },
            },
            {
                "kind": "dispatch",
                "moduleId": "multiply",
                "bindings": [
                    {
                        "binding": 0,
                        "bufferId": "input",
                        "bufferType": "read-only-storage",
                    },
                    {
                        "binding": 1,
                        "bufferId": "output",
                        "bufferType": "storage",
                    },
                ],
                "workgroups": [1, 1, 1],
            },
            {
                "kind": "copyBufferToBuffer",
                "srcBufferId": "output",
                "dstBufferId": "readback",
                "sizeBytes": 16,
            },
            {
                "kind": "readBuffer",
                "bufferId": "readback",
                "validate": {
                    "kind": "f32PrefixEquals",
                    "values": [2.0, 4.0, 6.0, 8.0],
                },
            },
        ],
    }
    path.write_text(json.dumps(plan, indent=2), encoding="utf-8")


def write_resident_plan(path: Path) -> None:
    plan = {
        "schemaVersion": 1,
        "planId": "resident_roundtrip",
        "executorId": "bun-webgpu",
        "workloadId": "resident_roundtrip",
        "domain": "compute",
        "comparable": True,
        "timing": {
            "iterations": 1,
            "warmup": 0,
            "timingSource": "doe-execution-total-ns",
            "timingClass": "operation",
        },
        "buffers": [
            {
                "id": "static_input",
                "size": 16,
                "usage": ["storage", "copy_dst"],
            },
            {
                "id": "dynamic_input",
                "size": 16,
                "usage": ["uniform", "copy_dst"],
            },
            {
                "id": "output",
                "size": 16,
                "usage": ["storage"],
            },
        ],
        "modules": [
            {
                "id": "noop",
                "kind": "compute",
                "entryPoint": "main",
                "source": {
                    "kind": "inline",
                    "code": "@compute @workgroup_size(1) fn main() {}\n",
                },
            }
        ],
        "steps": [
            {
                "id": "static-load",
                "kind": "writeBuffer",
                "bufferId": "static_input",
                "offset": 0,
                "data": {
                    "kind": "file",
                    "cacheNamespace": "unit_test",
                    "cacheKey": "alpha",
                    "sizeBytes": 16,
                },
            },
            {
                "id": "dynamic-write",
                "kind": "writeBuffer",
                "bufferId": "dynamic_input",
                "offset": 0,
                "data": {
                    "kind": "f32",
                    "values": [1.0, 2.0, 3.0, 4.0],
                },
            },
            {
                "id": "dispatch",
                "kind": "dispatch",
                "moduleId": "noop",
                "bindings": [
                    {
                        "binding": 0,
                        "bufferId": "static_input",
                        "bufferType": "read-only-storage",
                    },
                    {
                        "binding": 1,
                        "bufferId": "dynamic_input",
                        "bufferType": "uniform",
                    },
                    {
                        "binding": 2,
                        "bufferId": "output",
                        "bufferType": "storage",
                    },
                ],
                "workgroups": [1, 1, 1],
            },
        ],
    }
    path.write_text(json.dumps(plan, indent=2), encoding="utf-8")


@unittest.skipUnless(BUN, "bun is required for Bun executor tests")
class BunWebGPUExecutorTests(unittest.TestCase):
    def test_bun_adapter_request_device_keeps_capability_queries_lazy(self) -> None:
        source = BUN_FFI_PATH.read_text(encoding="utf-8")
        start = source.index("adapterRequestDevice(adapter, _descriptor, classes) {")
        end = source.index("\n    },\n    adapterDestroy(native) {", start)
        block = source[start:end]

        self.assertIn("const device = new classes.DoeGPUDevice(native, adapter._instance);", block)
        self.assertIn("device._adapter = adapter;", block)
        self.assertNotIn("device.limits = deviceLimits(native);", block)
        self.assertNotIn("device.features = deviceFeatures(native);", block)
        self.assertNotIn("device._adapterInfo = adapter.info;", block)

    def test_bun_encoder_backend_elides_duplicate_pipeline_and_bind_group_sets(self) -> None:
        source = BUN_FFI_PATH.read_text(encoding="utf-8")

        self.assertIn("function updatePassPipelineState(pass, pipelineNative)", source)
        self.assertIn("function updatePassBindGroupState(pass, index, bindGroupNative)", source)
        self.assertIn("if (!updatePassPipelineState(pass, pipelineNative)) {", source)
        self.assertIn("if (!updatePassBindGroupState(pass, index, bindGroupNative)) {", source)

    def test_bun_lazy_dispatch_copy_uses_submit_flush_paths(self) -> None:
        source = BUN_FFI_PATH.read_text(encoding="utf-8")

        self.assertNotIn("function canFinishBunLazyDispatchCopyCommandsAsNativeBuffer(commands)", source)
        self.assertNotIn("function finishBunLazyDispatchCopyCommandsAsNativeCommandBuffer(encoder, commands)", source)
        self.assertNotIn("function tryFinishBunLazyDispatchCopyCommandsAsNativeCommandBuffer(encoder, commands)", source)
        self.assertNotIn("doeNativeCreateComputeDispatchCopyCommandBuffer", source)
        self.assertNotIn("doeNativeCreateComputeDispatchCopyCommandBufferOneBindGroup", source)
        self.assertNotIn("doeNativeCreateComputeDispatchBatchCopyCommandBuffer", source)
        self.assertIn("commandBufferBuild: 0", source)
        self.assertIn("const cmds = buffers[0]._commands;", source)
        self.assertIn("let batchedCommands = null;", source)
        self.assertIn("batchedCommands = commandBuffer._commands;", source)
        self.assertIn("commands.push(...commandBuffer._commands);", source)
        self.assertIn("if (batchedCommands !== null) {", source)
        self.assertIn("const DOE_WEBGPU_SUBMIT_BREAKDOWN = envFlagEnabled(process.env.DOE_WEBGPU_SUBMIT_BREAKDOWN);", source)
        self.assertIn("const dispatchBatchCopyFlushBreakdown = DOE_WEBGPU_SUBMIT_BREAKDOWN", source)
        self.assertIn("wgpu.symbols.doeNativeComputeDispatchBatchCopyFlush;", source)
        self.assertIn("doeNativeComputePrewarmDispatchBindings", source)
        self.assertIn("export function prewarmPreparedDispatches(queue, dispatchCommands)", source)
        self.assertIn("computePrewarmDispatchBindings", source)
        self.assertIn("doeNativeComputeDispatchFlush", source)
        self.assertIn("doeNativeComputeDispatchFlushOneBindGroup", source)

    def test_bun_lazy_submit_breakdown_is_opt_in_and_shader_bytes_are_cached(self) -> None:
        source = BUN_FFI_PATH.read_text(encoding="utf-8")

        self.assertIn("function envFlagEnabled(value)", source)
        self.assertIn("DOE_WEBGPU_SUBMIT_BREAKDOWN", source)
        self.assertIn("const dispatchFlushBreakdown = DOE_WEBGPU_SUBMIT_BREAKDOWN", source)
        self.assertIn("const dispatchFlush = wgpu.symbols.doeNativeComputeDispatchFlush ?? dispatchFlushBreakdown;", source)
        self.assertIn("const shaderSourceBytesCache = new Map();", source)
        self.assertIn("function cachedShaderSourceBytes(code)", source)
        self.assertIn("const codeBytes = cachedShaderSourceBytes(code);", source)

    def test_bun_lazy_dispatch_uses_compact_single_bind_group_commands(self) -> None:
        source = BUN_FFI_PATH.read_text(encoding="utf-8")

        self.assertIn("function pushBunLazyDispatchCommand(pass, pipelineNative, x, y, z)", source)
        self.assertIn("function bunCommandBindGroupCount(cmd)", source)
        self.assertIn("function bunCommandBindGroupAt(cmd, index)", source)
        self.assertIn("b: bindGroup", source)
        self.assertNotIn(
            "pass._encoder._commands.push({ t: 0, p: pass._pipeline, bg: [...pass._bindGroups], x, y, z });",
            source,
        )
        self.assertNotIn(
            "pass._encoder._commands.push({ t: 0, p: pipelineNative, bg: [...pass._bindGroups], x, y, z });",
            source,
        )

    def test_bun_readback_flush_breakdown_reuses_queue_scratch(self) -> None:
        source = BUN_FFI_PATH.read_text(encoding="utf-8")
        start = source.index("bufferMapReadCopyUnmap(wrapper, native, mode, offset, size) {")
        end = source.index("\n    },\n    bufferGetMappedRange(wrapper, native, offset, size) {", start)
        block = source[start:end]

        self.assertIn("doeBufferMapReadCopyUnmapFlat", source)
        self.assertIn("function queueFlushBreakdownScratch(queue)", source)
        self.assertIn("function queueMapReadCopyUnmapScratch(queue)", source)
        self.assertIn("queue._flushWaitCompletedNs = new BigUint64Array(1);", source)
        self.assertIn("queue._flushDeferredCopyNs = new BigUint64Array(1);", source)
        self.assertIn("queue._flushDeferredResolveNs = new BigUint64Array(1);", source)
        self.assertIn(
            "queue._mapReadCopyUnmapNs = new BigUint64Array(READBACK_BREAKDOWN_FIELD_COUNT);",
            source,
        )
        self.assertIn("wgpu.symbols.doeBufferMapReadCopyUnmapFlat(", block)
        self.assertIn("queueMapReadCopyUnmapScratch(queue)", block)
        self.assertIn("queueFlushBreakdownScratch(wrapper._queue);", block)
        self.assertIn("const waitCompletedNs = wrapper._queue._flushWaitCompletedNs;", block)
        self.assertNotIn("const waitCompletedNs = new BigUint64Array(1);", block)
        self.assertNotIn("const deferredCopyNs = new BigUint64Array(1);", block)
        self.assertNotIn("const deferredResolveNs = new BigUint64Array(1);", block)

    def test_bun_queue_submit_reuses_dispatch_scratch_arrays(self) -> None:
        source = BUN_FFI_PATH.read_text(encoding="utf-8")

        self.assertIn("function ensureBindGroupPtrScratch(queue, count)", source)
        self.assertIn("function ensureDispatchBatchScratch(queue, dispatchCount)", source)
        self.assertIn("let bgPtrs = null;", source)
        self.assertIn('typeof dispatchFlushOneBindGroup === "function"', source)
        self.assertIn("bgPtrs = ensureBindGroupPtrScratch(queue, bgCount);", source)
        self.assertIn("const scratch = ensureDispatchBatchScratch(queue, dispatchCount);", source)
        self.assertIn("doeQueueSubmitOneAndRelease", source)
        self.assertIn("wgpu.symbols.doeQueueSubmitOneAndRelease(queueNative, commandBuffer._native);", source)
        self.assertIn("queue._emptyBindGroupPtrArray = new BigUint64Array(0);", source)
        self.assertIn("queue._singleBindGroupPtrArray = new BigUint64Array(1);", source)

    def test_bun_queue_write_batch_uses_native_compact_abi(self) -> None:
        source = BUN_FFI_PATH.read_text(encoding="utf-8")
        shared_surface = (REPO_ROOT / "packages" / "doe-gpu" / "src" / "vendor" / "webgpu" / "shared" / "full-surface.js").read_text(encoding="utf-8")

        self.assertIn("doeNativeQueueWriteBufferBatch", source)
        self.assertIn("doeNativeQueueWriteBufferBatchDataPtrs", source)
        self.assertIn("function ensureQueueWriteBatchScratch(queue, count, byteLength)", source)
        self.assertIn("queue._writeBatchScratch = {};", source)
        self.assertIn("queueWriteBufferBatch(queue, native, entries) {", source)
        self.assertIn("const writeBatchDataPtrs = wgpu.symbols.doeNativeQueueWriteBufferBatchDataPtrs;", source)
        self.assertIn("const writeBatch = wgpu.symbols.doeNativeQueueWriteBufferBatch;", source)
        self.assertIn("scratch.dataPtrs[index] = hotU64(dataPtr);", source)
        self.assertIn("writeBatchDataPtrs(", source)
        self.assertIn("scratch.buffers[index] = hotU64(entry.bufferNative);", source)
        self.assertIn("scratch.data.set(entry.view, dataOffset);", source)
        self.assertIn("writeBatch(", source)
        self.assertIn("typeof backend.queueWriteBufferBatch === 'function'", shared_surface)
        self.assertIn("__doeWriteBufferBatch", shared_surface)

    def test_bun_ffi_uses_validated_native_flat_setup_hooks(self) -> None:
        source = BUN_FFI_PATH.read_text(encoding="utf-8")
        shared_surface = (
            REPO_ROOT
            / "packages"
            / "doe-gpu"
            / "src"
            / "vendor"
            / "webgpu"
            / "shared"
            / "full-surface.js"
        ).read_text(encoding="utf-8")

        self.assertIn("doeNativeDeviceCreateBufferFlat", source)
        self.assertIn("doeNativeDeviceCreateShaderModuleWgsl", source)
        self.assertIn("doeNativeDeviceCreateComputePipelineMain", source)
        self.assertIn("doeNativeDeviceCreateBufferBindGroupLayoutFlat4", source)
        self.assertIn("doeNativeDeviceCreateBufferBindGroupFlat4", source)
        self.assertIn("doeNativeDeviceCreatePipelineLayoutOne", source)
        self.assertIn("preflightShaderSourceOnCreate: false", source)
        self.assertIn("function tryCreateBufferBindGroupLayoutFast4(", shared_surface)
        self.assertIn("function tryCreateBufferBindGroupFast4(", shared_surface)

        buffer_start = source.index("deviceCreateBuffer(device, validated) {")
        buffer_end = source.index("\n    },\n    deviceCreateShaderModule", buffer_start)
        buffer_block = source[buffer_start:buffer_end]
        self.assertIn("wgpu.symbols.doeNativeDeviceCreateBufferFlat(", buffer_block)

        bind_group_start = source.index("deviceCreateBufferBindGroupFlat4(")
        bind_group_end = source.index("\n    },\n    deviceCreateBindGroup(", bind_group_start)
        bind_group_block = source[bind_group_start:bind_group_end]
        self.assertIn(
            'typeof wgpu.symbols.doeNativeDeviceCreateBufferBindGroupFlat4 !== "function"',
            bind_group_block,
        )
        self.assertIn("wgpu.symbols.doeNativeDeviceCreateBufferBindGroupFlat4(", bind_group_block)

    def test_bun_entry_uses_measured_platform_default(self) -> None:
        source = BUN_ENTRY_PATH.read_text(encoding="utf-8")

        self.assertIn('const ffiDefaultPlatforms = new Set(["darwin", "linux"]);', source)
        self.assertIn('const requestedBackend = process.env.DOE_BUN_WEBGPU_BACKEND ?? "";', source)
        self.assertIn('const runtime = requestedBackend === "full"', source)
        self.assertIn('requestedBackend === "ffi" || ffiDefaultPlatforms.has(process.platform)', source)
        self.assertIn("export const fastPathStats = runtime.fastPathStats;", source)
        self.assertNotIn("const runtime = ffi.providerInfo().loaded ? ffi : full;", source)

    def test_public_types_include_fast_path_stats(self) -> None:
        source = INDEX_DTS_PATH.read_text(encoding="utf-8")

        self.assertIn("export interface FastPathStats", source)
        self.assertIn("export const fastPathStats: FastPathStats | undefined;", source)
        self.assertIn("fastPathStats: typeof fastPathStats;", source)

    def test_doe_namespace_omits_empty_compute_descriptors_for_lazy_paths(self) -> None:
        source = DOE_NAMESPACE_PATH.read_text(encoding="utf-8")

        self.assertIn("function descriptorWithOptionalLabel(label)", source)
        self.assertIn("device.createCommandEncoder(descriptorWithOptionalLabel(options.label))", source)
        self.assertIn(
            "this._encoder.beginComputePass(descriptorWithOptionalLabel(label ?? this.label))",
            source,
        )
        self.assertIn(
            "this._encoder.beginComputePass(descriptorWithOptionalLabel(options.label ?? this.label))",
            source,
        )
        self.assertNotIn("device.createCommandEncoder({ label: options.label ?? undefined })", source)
        self.assertNotIn("beginComputePass({ label: label ?? this.label ?? undefined })", source)

    def test_bun_backend_exposes_combined_readback_copy_path(self) -> None:
        source = BUN_FFI_PATH.read_text(encoding="utf-8")

        self.assertIn("bufferMapReadCopyUnmap(wrapper, native, mode, offset, size) {", source)
        self.assertIn("doeNativeQueueFlushBreakdown", source)
        self.assertIn("const copied = fullSurfaceBackend.bufferReadCopy(wrapper, native, offset, size);", source)
        self.assertIn("wrapper.__doe_readback_breakdown_ns = readbackBreakdownNs;", source)
        self.assertIn("bufferReadCopy(_wrapper, native, offset, size) {", source)
        self.assertIn("wgpu.symbols.wgpuBufferUnmap(native);", source)

    def test_dry_run_emits_bun_webgpu_metadata(self) -> None:
        with tempfile.TemporaryDirectory(prefix="doe-bun-webgpu-executor-") as tmpdir:
            tmp = Path(tmpdir)
            plan_path = tmp / "plan.json"
            meta_path = tmp / "trace-meta.json"
            trace_path = tmp / "trace.jsonl"
            write_plan(plan_path)

            result = subprocess.run(
                [
                    str(BUN),
                    str(CLI_PATH),
                    "--provider",
                    "bun-webgpu",
                    "--plan",
                    str(plan_path),
                    "--trace-meta",
                    str(meta_path),
                    "--trace-jsonl",
                    str(trace_path),
                    "--workload",
                    "simple_compute_roundtrip",
                    "--dry-run",
                ],
                cwd=REPO_ROOT,
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            meta = json.loads(meta_path.read_text(encoding="utf-8"))
            rows = [json.loads(line) for line in trace_path.read_text(encoding="utf-8").splitlines() if line.strip()]

            self.assertEqual(meta["executionBackend"], "bun_webgpu_package")
            self.assertEqual(meta["executionProvider"], "bun-webgpu")
            self.assertEqual(meta["executionProviderName"], "bun-webgpu")
            self.assertFalse(meta["packagePreparedSession"])
            self.assertEqual(len(rows), 4)
            self.assertTrue(all(row["executionBackend"] == "bun_webgpu_package" for row in rows))

    def test_dry_run_emits_prepared_doe_bun_metadata(self) -> None:
        with tempfile.TemporaryDirectory(prefix="doe-bun-webgpu-executor-") as tmpdir:
            tmp = Path(tmpdir)
            plan_path = tmp / "plan.json"
            meta_path = tmp / "trace-meta.json"
            trace_path = tmp / "trace.jsonl"
            write_plan(plan_path)

            result = subprocess.run(
                [
                    str(BUN),
                    str(CLI_PATH),
                    "--provider",
                    "doe",
                    "--prepared-session",
                    "--plan",
                    str(plan_path),
                    "--trace-meta",
                    str(meta_path),
                    "--trace-jsonl",
                    str(trace_path),
                    "--workload",
                    "simple_compute_roundtrip",
                    "--dry-run",
                ],
                cwd=REPO_ROOT,
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            meta = json.loads(meta_path.read_text(encoding="utf-8"))
            self.assertEqual(meta["executionBackend"], "doe_bun_package")
            self.assertEqual(meta["executionProvider"], "doe")
            self.assertEqual(meta["executionProviderName"], "doe-gpu")
            self.assertTrue(meta["packagePreparedSession"])
            self.assertEqual(meta["workloadUnitWallSource"], "trace-meta-process-wall")

    def test_dry_run_emits_doe_bun_ffi_metadata(self) -> None:
        with tempfile.TemporaryDirectory(prefix="doe-bun-webgpu-executor-") as tmpdir:
            tmp = Path(tmpdir)
            plan_path = tmp / "plan.json"
            meta_path = tmp / "trace-meta.json"
            trace_path = tmp / "trace.jsonl"
            write_plan(plan_path)

            result = subprocess.run(
                [
                    str(BUN),
                    str(CLI_PATH),
                    "--provider",
                    "doe-ffi",
                    "--plan",
                    str(plan_path),
                    "--trace-meta",
                    str(meta_path),
                    "--trace-jsonl",
                    str(trace_path),
                    "--workload",
                    "simple_compute_roundtrip",
                    "--dry-run",
                ],
                cwd=REPO_ROOT,
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            meta = json.loads(meta_path.read_text(encoding="utf-8"))
            self.assertEqual(meta["executionBackend"], "doe_bun_package")
            self.assertEqual(meta["executionProvider"], "doe-ffi")
            self.assertEqual(meta["executionProviderName"], "doe-gpu/bun-ffi")
            self.assertFalse(meta["packagePreparedSession"])

    def test_dry_run_resident_buffer_loads_exclude_static_loads(self) -> None:
        with tempfile.TemporaryDirectory(prefix="doe-bun-webgpu-executor-") as tmpdir:
            tmp = Path(tmpdir)
            plan_path = tmp / "plan.json"
            meta_path = tmp / "trace-meta.json"
            trace_path = tmp / "trace.jsonl"
            write_resident_plan(plan_path)

            result = subprocess.run(
                [
                    str(BUN),
                    str(CLI_PATH),
                    "--provider",
                    "doe",
                    "--prepared-session",
                    "--resident-buffer-loads",
                    "--plan",
                    str(plan_path),
                    "--trace-meta",
                    str(meta_path),
                    "--trace-jsonl",
                    str(trace_path),
                    "--workload",
                    "resident_roundtrip",
                    "--dry-run",
                    "--command-repeat",
                    "2",
                ],
                cwd=REPO_ROOT,
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            meta = json.loads(meta_path.read_text(encoding="utf-8"))
            rows = [json.loads(line) for line in trace_path.read_text(encoding="utf-8").splitlines() if line.strip()]

            self.assertTrue(meta["packagePreparedSession"])
            self.assertTrue(meta["packageResidentBufferLoads"])
            self.assertEqual(meta["executionRowCount"], 4)
            self.assertEqual(meta["executionSuccessCount"], 4)
            self.assertEqual(meta["executionDispatchCount"], 2)
            self.assertEqual([row["stepIndex"] for row in rows], [1, 2, 1, 2])


if __name__ == "__main__":
    unittest.main()
