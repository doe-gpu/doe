#!/usr/bin/env python3
"""Regression tests for the standalone Node WebGPU plan executor."""

from __future__ import annotations

import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
CLI_PATH = REPO_ROOT / "bench" / "executors" / "run-node-webgpu-plan.js"
EXECUTOR_MODULE_URL = (REPO_ROOT / "bench" / "executors" / "node-webgpu" / "executor.js").resolve().as_uri()
PACKAGE_INDEX_PATH = REPO_ROOT / "packages" / "doe-gpu" / "src" / "vendor" / "webgpu" / "index.js"
PACKAGE_BUN_PATH = REPO_ROOT / "packages" / "doe-gpu" / "src" / "bun.js"
RUNTIME_ENCODER_NATIVE_PATH = REPO_ROOT / "runtime" / "zig" / "src" / "doe_encoder_native.zig"
RUNTIME_METAL_SUBMIT_PATH = REPO_ROOT / "runtime" / "zig" / "src" / "doe_queue_submit_metal.zig"
RUNTIME_QUEUE_SHARED_PATH = REPO_ROOT / "runtime" / "zig" / "src" / "doe_queue_submit_shared.zig"
RUNTIME_COMPUTE_FAST_PATH = REPO_ROOT / "runtime" / "zig" / "src" / "doe_compute_fast.zig"
NAPI_QUEUE_PATH = REPO_ROOT / "runtime" / "bridge" / "webgpu-addon" / "doe_napi_queue.c"
NAPI_BUFFER_PATH = REPO_ROOT / "runtime" / "bridge" / "webgpu-addon" / "doe_napi_buffer.c"
NAPI_INIT_PATH = REPO_ROOT / "runtime" / "bridge" / "webgpu-addon" / "doe_napi_init.c"
NAPI_INTERNAL_PATH = REPO_ROOT / "runtime" / "bridge" / "webgpu-addon" / "doe_napi_internal.h"
NAPI_ND_IMMEDIATES_PATH = REPO_ROOT / "runtime" / "bridge" / "webgpu-addon" / "doe_napi_nd_immediates.c"
BUN_ENTRY_PATH = REPO_ROOT / "packages" / "doe-gpu" / "src" / "vendor" / "webgpu" / "bun.js"
BUN_FFI_PATH = REPO_ROOT / "packages" / "doe-gpu" / "src" / "vendor" / "webgpu" / "bun-ffi.js"
PACKAGE_EXECUTION_POLICY_PATH = REPO_ROOT / "config" / "package-execution-policy.json"


def write_plan(path: Path, *, valid: bool = True) -> None:
    plan = {
        "schemaVersion": 1,
        "planId": "simple_compute_roundtrip",
        "executorId": "node_webgpu_package",
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

    if not valid:
        plan["buffers"][0]["usage"] = ["storage"]

    path.write_text(json.dumps(plan, indent=2), encoding="utf-8")


def write_command_plan(path: Path) -> None:
    plan = {
        "schemaVersion": 1,
        "planKind": "benchmark_ir",
        "workloadId": "command_plan_roundtrip",
        "irPath": "bench/ir/test.json",
        "irScenario": "command_plan_roundtrip",
        "commandCount": 2,
        "bufferWriteCount": 1,
        "dispatchCount": 1,
        "sourceIrSha256": "abc",
        "compatibilityCommandsSha256": "def",
        "planSha256": "ghi",
        "commands": [
            {
                "kind": "buffer_write",
                "handle": 1001,
                "bufferSize": 16,
                "data": [1, 2, 3, 4],
            },
            {
                "kind": "kernel_dispatch",
                "kernel": "rmsnorm.wgsl",
                "x": 1,
                "y": 1,
                "z": 1,
                "bindings": [
                    {
                        "binding": 0,
                        "resource_handle": 1001,
                        "buffer_size": 16,
                        "buffer_type": "uniform",
                    },
                    {
                        "binding": 1,
                        "resource_handle": 2001,
                        "buffer_size": 64,
                        "buffer_type": "readonly",
                    },
                    {
                        "binding": 2,
                        "resource_handle": 2002,
                        "buffer_size": 64,
                        "buffer_type": "storage",
                    },
                ],
            },
        ],
    }
    path.write_text(json.dumps(plan, indent=2), encoding="utf-8")


def write_buffer_load_command_plan(path: Path) -> None:
    plan = {
        "schemaVersion": 1,
        "planKind": "benchmark_ir",
        "workloadId": "buffer_load_roundtrip",
        "irPath": "bench/ir/test.json",
        "irScenario": "buffer_load_roundtrip",
        "commandCount": 2,
        "bufferWriteCount": 0,
        "bufferLoadCount": 1,
        "dispatchCount": 1,
        "sourceIrSha256": "abc",
        "compatibilityCommandsSha256": "def",
        "planSha256": "ghi",
        "commands": [
            {
                "kind": "buffer_load",
                "handle": 2001,
                "bufferSize": 64,
                "byteLength": 64,
                "cacheNamespace": "unit_test",
                "cacheKey": "alpha",
                "assetKey": "buffer_load_roundtrip:handle-2001",
                "generator": "splitmix64_f32_nonzero_v1",
                "seed": 7,
                "scale": 0.125,
            },
            {
                "kind": "kernel_dispatch",
                "kernel": "rmsnorm.wgsl",
                "x": 1,
                "y": 1,
                "z": 1,
                "bindings": [
                    {
                        "binding": 0,
                        "resource_handle": 2001,
                        "buffer_size": 64,
                        "buffer_type": "readonly",
                    },
                    {
                        "binding": 1,
                        "resource_handle": 2002,
                        "buffer_size": 64,
                        "buffer_type": "storage",
                    },
                ],
            },
        ],
    }
    path.write_text(json.dumps(plan, indent=2), encoding="utf-8")


def write_resident_buffer_load_command_plan(path: Path) -> None:
    plan = {
        "schemaVersion": 1,
        "planKind": "benchmark_ir",
        "workloadId": "resident_buffer_load_roundtrip",
        "irPath": "bench/ir/test.json",
        "irScenario": "resident_buffer_load_roundtrip",
        "commandCount": 3,
        "bufferWriteCount": 1,
        "bufferLoadCount": 1,
        "dispatchCount": 1,
        "sourceIrSha256": "abc",
        "compatibilityCommandsSha256": "def",
        "planSha256": "resident-buffer-load-roundtrip",
        "commands": [
            {
                "kind": "buffer_load",
                "handle": 2001,
                "bufferSize": 64,
                "byteLength": 64,
                "cacheNamespace": "unit_test",
                "cacheKey": "alpha",
                "assetKey": "resident_buffer_load_roundtrip:handle-2001",
                "generator": "splitmix64_f32_nonzero_v1",
                "seed": 7,
                "scale": 0.125,
            },
            {
                "kind": "buffer_write",
                "handle": 1001,
                "bufferSize": 16,
                "data": [1, 2, 3, 4],
            },
            {
                "kind": "kernel_dispatch",
                "kernel": "rmsnorm.wgsl",
                "x": 1,
                "y": 1,
                "z": 1,
                "bindings": [
                    {
                        "binding": 0,
                        "resource_handle": 1001,
                        "buffer_size": 16,
                        "buffer_type": "uniform",
                    },
                    {
                        "binding": 1,
                        "resource_handle": 2001,
                        "buffer_size": 64,
                        "buffer_type": "readonly",
                    },
                    {
                        "binding": 2,
                        "resource_handle": 2002,
                        "buffer_size": 64,
                        "buffer_type": "storage",
                    },
                ],
            },
        ],
    }
    path.write_text(json.dumps(plan, indent=2), encoding="utf-8")


class NodeWebGPUExecutorTests(unittest.TestCase):
    def test_node_package_encoder_backend_elides_duplicate_pipeline_and_bind_group_sets(self) -> None:
        source = PACKAGE_INDEX_PATH.read_text(encoding="utf-8")

        self.assertIn("function updatePassPipelineState(pass, pipelineNative)", source)
        self.assertIn("function updatePassBindGroupState(pass, index, bindGroupNative)", source)
        self.assertIn("if (!updatePassPipelineState(pass, pipelineNative)) {", source)
        self.assertIn("if (!updatePassBindGroupState(pass, index, bindGroupNative)) {", source)

    def test_node_package_encoder_backend_uses_dispatch_bound_fast_path_for_pending_state(self) -> None:
        source = PACKAGE_INDEX_PATH.read_text(encoding="utf-8")

        self.assertIn("function materializeNodePendingComputeState(pass, nativePass)", source)
        self.assertIn("typeof addon.computePassDispatchBound === 'function'", source)
        self.assertIn("clearPendingBoundDispatchState(pass);", source)
        self.assertIn("materializeNodePendingComputeState(pass, nativePass);", source)

    def test_node_package_backend_exposes_combined_readback_copy_path(self) -> None:
        source = PACKAGE_INDEX_PATH.read_text(encoding="utf-8")

        self.assertIn("bufferMapReadCopyUnmap(wrapper, native, mode, offset, size) {", source)
        self.assertIn("typeof addon.bufferMapReadCopyUnmap === 'function'", source)
        self.assertIn("addon.bufferMapReadCopyUnmap(", source)
        self.assertIn("const ZERO_READBACK_BREAKDOWN_NS = Object.freeze({", source)
        self.assertIn("wrapper.__doe_readback_breakdown_ns = ZERO_READBACK_BREAKDOWN_NS;", source)
        self.assertIn("wrapper.__doe_readback_breakdown_ns = {", source)
        self.assertIn("const copied = addon.bufferReadCopy(native, offset, size);", source)
        self.assertIn("addon.bufferUnmap(native);", source)

    def test_node_package_exports_fast_path_stats_for_receipts(self) -> None:
        source = PACKAGE_INDEX_PATH.read_text(encoding="utf-8")
        executor_source = (REPO_ROOT / "bench" / "executors" / "node-webgpu" / "executor.js").read_text(
            encoding="utf-8"
        )

        self.assertIn("const fastPathStats = { dispatchFlush: 0, flushAndMap: 0, commandBufferBuild: 0 };", source)
        self.assertIn("fastPathStats.commandBufferBuild += 1;", source)
        self.assertIn("fastPathStats.flushAndMap += 1;", source)
        self.assertIn("fastPathStats.dispatchFlush += 1;", source)
        self.assertIn("function addonSubmitBreakdownIndicatesDispatchFlush(addonBreakdown)", source)
        self.assertIn("if (!addonBreakdown) {\n    return false;\n  }", source)
        self.assertIn("queueWriteBufferBatchDataPtrs", source)
        self.assertIn("export { fastPathStats };", source)
        self.assertIn("fastPathStats,", source)
        self.assertIn("function snapshotPackageNativeFastPaths(providerModule)", executor_source)
        self.assertIn("packageNativeFastPaths", executor_source)
        self.assertIn("queueWriteBufferBatchDataPtrs", executor_source)
        self.assertIn("export function nativeQueueSyncInfo(queue)", source)
        self.assertIn("nativeAddon.queueSyncInfo(native)", source)
        self.assertIn("export function nativePipelineCacheInfo(queue)", source)
        self.assertIn("nativeAddon.queuePipelineCacheInfo(native)", source)
        self.assertIn("export function packagePipelineCacheFlush(queue = null)", source)
        self.assertIn("nativeAddon.packagePipelineCacheFlush(native)", source)
        self.assertIn("queueFamilyPolicy: info.queueFamilyPolicy", source)
        self.assertIn("deferredSubmissionSyncPolicy: info.deferredSubmissionSyncPolicy", source)
        self.assertIn("queueFamilySupportsGraphics: info.queueFamilySupportsGraphics", source)
        self.assertIn("function snapshotPackageNativeQueueSyncInfo(providerModule, queue)", executor_source)
        self.assertIn("packageNativeQueueSyncInfo", executor_source)
        self.assertIn("function snapshotPackagePipelineCacheInfo(providerModule, queue, flushNs = 0)", executor_source)
        self.assertIn("function flushPackagePipelineCache(providerModule, queue, debugLog)", executor_source)
        self.assertIn("pipelineCache", executor_source)
        self.assertIn("result.queueFamilyPolicy = info.queueFamilyPolicy;", executor_source)
        self.assertIn("result.deferredSubmissionSyncPolicy = info.deferredSubmissionSyncPolicy;", executor_source)
        self.assertIn("result.queueFamilySupportsGraphics = info.queueFamilySupportsGraphics;", executor_source)

    def test_bun_package_exports_native_fast_path_identity(self) -> None:
        public_bun_source = PACKAGE_BUN_PATH.read_text(encoding="utf-8")
        bun_entry_source = BUN_ENTRY_PATH.read_text(encoding="utf-8")
        bun_ffi_source = BUN_FFI_PATH.read_text(encoding="utf-8")

        self.assertIn("nativeFastPathInfo,", public_bun_source)
        self.assertIn("export const nativeFastPathInfo = runtime.nativeFastPathInfo ?? full.nativeFastPathInfo;", bun_entry_source)
        self.assertIn("function nativeFastPathInfoFromSymbols()", bun_ffi_source)
        self.assertIn("export function nativeFastPathInfo()", bun_ffi_source)
        self.assertIn("nativeFastPaths,", bun_ffi_source)
        self.assertIn("doeBufferMapReadCopyUnmapFlat", bun_ffi_source)
        self.assertIn("prewarmPreparedDispatches,", public_bun_source)
        self.assertIn("export const prewarmPreparedDispatches = runtime.prewarmPreparedDispatches ?? full.prewarmPreparedDispatches;", bun_entry_source)
        self.assertIn("doeNativeComputePrewarmDispatchBindings", bun_ffi_source)
        self.assertIn("computePrewarmDispatchBindings", bun_ffi_source)
        self.assertIn("export function prewarmPreparedDispatches(queue, dispatchCommands)", bun_ffi_source)
        self.assertIn("nativeQueueSyncInfo,", public_bun_source)
        self.assertIn("export const nativeQueueSyncInfo = runtime.nativeQueueSyncInfo ?? full.nativeQueueSyncInfo;", bun_entry_source)
        self.assertIn("export function nativeQueueSyncInfo(queue)", bun_ffi_source)
        self.assertIn("doeNativeQueueSyncInfo", bun_ffi_source)
        self.assertIn("nativePipelineCacheInfo,", public_bun_source)
        self.assertIn("export const nativePipelineCacheInfo = runtime.nativePipelineCacheInfo ?? full.nativePipelineCacheInfo;", bun_entry_source)
        self.assertIn("packagePipelineCacheFlush,", public_bun_source)
        self.assertIn("export const packagePipelineCacheFlush = runtime.packagePipelineCacheFlush ?? full.packagePipelineCacheFlush;", bun_entry_source)
        self.assertIn("export function nativePipelineCacheInfo(queue)", bun_ffi_source)
        self.assertIn("doeNativeQueuePipelineCacheInfo", bun_ffi_source)
        self.assertIn("export function packagePipelineCacheFlush(queue = null)", bun_ffi_source)
        self.assertIn("doeNativeQueuePipelineCacheFlush", bun_ffi_source)
        self.assertIn("doeNativeQueueFamilyPolicyCode", bun_ffi_source)
        self.assertIn("doeNativeQueueDeferredSubmissionSyncPolicyCode", bun_ffi_source)
        self.assertIn("function attachQueueFamilyInfo(info, queueNative)", bun_ffi_source)
        self.assertIn("info.queueFamilySupportsGraphics = queueFamilySupportsGraphics !== 0;", bun_ffi_source)

    def test_napi_package_exports_combined_readback_copy_path(self) -> None:
        buffer_source = NAPI_BUFFER_PATH.read_text(encoding="utf-8")
        init_source = NAPI_INIT_PATH.read_text(encoding="utf-8")

        self.assertIn("napi_value doe_buffer_map_read_copy_unmap", buffer_source)
        self.assertIn("pfn_doeNativeQueueFlushBreakdown", buffer_source)
        self.assertIn("pfn_doeNativeBufferMapAsync", buffer_source)
        self.assertIn('napi_set_named_property(env, result_obj, "bytes", bytes);', buffer_source)
        self.assertIn('EXPORT_FN("bufferMapReadCopyUnmap",                   doe_buffer_map_read_copy_unmap)', init_source)

    def test_napi_package_exports_queue_sync_info(self) -> None:
        queue_source = NAPI_QUEUE_PATH.read_text(encoding="utf-8")
        init_source = NAPI_INIT_PATH.read_text(encoding="utf-8")
        header_source = NAPI_INTERNAL_PATH.read_text(encoding="utf-8")

        self.assertIn("napi_value doe_queue_sync_info", queue_source)
        self.assertIn("pfn_doeNativeQueueSyncInfo(queue)", queue_source)
        self.assertIn("pfn_doeNativeQueueFamilyPolicyCode(queue)", queue_source)
        self.assertIn("pfn_doeNativeQueueDeferredSubmissionSyncPolicyCode(queue)", queue_source)
        self.assertIn("queueFamilySupportsGraphics", queue_source)
        self.assertIn('EXPORT_FN("queueSyncInfo",                            doe_queue_sync_info)', init_source)
        self.assertIn("DECL_PFN(uint32_t, doeNativeQueueSyncInfo", header_source)
        self.assertIn("DECL_PFN(uint32_t, doeNativeQueueFamilyPolicyCode", header_source)
        self.assertIn("DECL_PFN(uint32_t, doeNativeQueueDeferredSubmissionSyncPolicyCode", header_source)

    def test_napi_readback_map_prefers_doe_native_map_symbol(self) -> None:
        for path in (NAPI_BUFFER_PATH, NAPI_QUEUE_PATH, NAPI_ND_IMMEDIATES_PATH):
            source = path.read_text(encoding="utf-8")
            native_index = source.index("if (pfn_doeNativeBufferMapAsync)")
            wgpu_index = source.index("else if (pfn_wgpuBufferMapAsync2)", native_index)
            self.assertLess(native_index, wgpu_index, path)

    def test_classify_bringup_unsupported_recognizes_unavailable_errors(self) -> None:
        script = f"""
import {{ classifyBringupUnsupported }} from {json.dumps(EXECUTOR_MODULE_URL)};
const classified = classifyBringupUnsupported('requestDevice', {{
  code: 'DOE_REQUEST_DEVICE_ERROR',
  message: 'requestDevice failed (status=3, detail=vulkan runtime init failed)',
}});
console.log(JSON.stringify(classified));
"""
        result = subprocess.run(
            ["node", "--input-type=module", "-e", script],
            cwd=REPO_ROOT,
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        classified = json.loads(result.stdout)
        self.assertEqual(classified["unsupportedCode"], "device_unavailable")
        self.assertEqual(classified["reason"], "adapter_unavailable")
        self.assertIn("vulkan runtime init failed", classified["detail"])

    def test_provider_failure_reason_normalization(self) -> None:
        script = f"""
import {{
  PROVIDER_FAILURE_REASONS,
  normalizeProviderFailureReason,
  providerAvailabilityFailure,
}} from {json.dumps(EXECUTOR_MODULE_URL)};
const payload = {{
  reasons: PROVIDER_FAILURE_REASONS,
  known: normalizeProviderFailureReason('native_webgpu_unavailable'),
  unknown: normalizeProviderFailureReason('new_future_reason'),
  failure: providerAvailabilityFailure({{
    reason: 'provider_import_failed',
    provider: 'node-webgpu',
    providerName: 'node-webgpu',
    runtimeHost: 'node',
    loader: 'node-dawn',
    stage: 'provider.resolve',
    detail: 'Cannot find package webgpu',
  }}),
}};
console.log(JSON.stringify(payload));
"""
        result = subprocess.run(
            ["node", "--input-type=module", "-e", script],
            cwd=REPO_ROOT,
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads(result.stdout)
        self.assertIn("native_webgpu_unavailable", payload["reasons"])
        self.assertEqual(payload["known"], "native_webgpu_unavailable")
        self.assertEqual(payload["unknown"], "runner_error")
        self.assertEqual(payload["failure"]["reason"], "provider_import_failed")
        self.assertEqual(payload["failure"]["runtimeHost"], "node")

    def test_resolve_provider_module_availability_classifies_loader_failure(self) -> None:
        script = f"""
import {{ resolveProviderModuleAvailability }} from {json.dumps(EXECUTOR_MODULE_URL)};
const availability = await resolveProviderModuleAvailability({{
  provider: 'unit-test-provider',
  providerName: 'Unit Test Provider',
  executionBackend: 'unit_test_backend',
  loader: 'unit-test-loader',
}}, {{ runtimeHost: 'node' }});
console.log(JSON.stringify(availability));
"""
        result = subprocess.run(
            ["node", "--input-type=module", "-e", script],
            cwd=REPO_ROOT,
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        availability = json.loads(result.stdout)
        self.assertFalse(availability["ok"])
        self.assertEqual(availability["reason"], "unsupported_runtime_host")
        self.assertEqual(availability["provider"], "unit-test-provider")
        self.assertEqual(availability["providerName"], "Unit Test Provider")
        self.assertEqual(availability["runtimeHost"], "node")
        self.assertEqual(availability["loader"], "unit-test-loader")
        self.assertEqual(availability["stage"], "provider.resolve")
        self.assertIn("unsupported provider loader", availability["detail"])

    def test_build_shader_source_receipt_hashes_exact_source_text(self) -> None:
        script = f"""
import {{ buildShaderSourceReceipt }} from {json.dumps(EXECUTOR_MODULE_URL)};
const receipt = buildShaderSourceReceipt({{
  id: 'multiply',
  entryPoint: 'main',
  source: {{ kind: 'path', path: 'bench/kernels/multiply.wgsl' }},
}}, 'abc');
console.log(JSON.stringify(receipt));
"""
        result = subprocess.run(
            ["node", "--input-type=module", "-e", script],
            cwd=REPO_ROOT,
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        receipt = json.loads(result.stdout)
        self.assertEqual(receipt["moduleId"], "multiply")
        self.assertEqual(receipt["sourceKind"], "path")
        self.assertEqual(receipt["path"], "bench/kernels/multiply.wgsl")
        self.assertEqual(receipt["entryPoint"], "main")
        self.assertEqual(receipt["byteLength"], 3)
        self.assertEqual(
            receipt["sha256"],
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
        )

    def test_build_unsupported_execution_result_preserves_prepared_session_boundary(self) -> None:
        script = f"""
import {{ buildUnsupportedExecutionResult }} from {json.dumps(EXECUTOR_MODULE_URL)};
const result = buildUnsupportedExecutionResult({{
  normalizedPlan: {{
    workloadId: 'alpha',
    planId: 'alpha-plan',
    planHash: 'alpha-hash',
    executionShape: {{
      stepCount: 4,
      dispatchCount: 2,
      bufferCount: 2,
      moduleCount: 1,
      writeBufferCount: 1,
      copyBufferToBufferCount: 0,
      readBufferCount: 0,
    }},
    buffers: [],
    modules: [],
    steps: [],
  }},
  spec: {{
    provider: 'doe',
    providerName: 'doe-gpu',
    executionBackend: 'doe_node_webgpu',
  }},
  preparedSession: true,
  hostInputReadTotalNs: 11,
  hostInputParseTotalNs: 12,
  hostWorkloadPrepareTotalNs: 13,
  hostExecutorInitTotalNs: 14,
  processWallMs: 1.5,
  unsupportedCode: 'provider_execution_unavailable',
  unsupportedDetail: 'node-webgpu execution unavailable for provider node-webgpu on this Apple host',
  providerFailureReason: 'native_webgpu_unavailable',
  evidenceBlockerCode: 'native_webgpu_unavailable',
}});
console.log(JSON.stringify(result));
"""
        result = subprocess.run(
            ["node", "--input-type=module", "-e", script],
            cwd=REPO_ROOT,
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads(result.stdout)
        meta = payload["meta"]
        self.assertEqual(meta["executionRowCount"], 0)
        self.assertEqual(meta["executionSuccessCount"], 0)
        self.assertEqual(meta["executionUnsupportedCount"], 1)
        self.assertEqual(meta["unsupportedCode"], "provider_execution_unavailable")
        self.assertEqual(
            meta["unsupportedDetail"],
            "node-webgpu execution unavailable for provider node-webgpu on this Apple host",
        )
        self.assertEqual(meta["providerFailureReason"], "native_webgpu_unavailable")
        self.assertEqual(meta["evidenceBlockerCode"], "native_webgpu_unavailable")
        self.assertEqual(meta["hostInputReadTotalNs"], 0)
        self.assertEqual(meta["hostInputParseTotalNs"], 0)
        self.assertEqual(meta["hostWorkloadPrepareTotalNs"], 0)
        self.assertEqual(meta["hostExecutorInitTotalNs"], 0)
        self.assertTrue(meta["packagePreparedSession"])
        self.assertEqual(meta["workloadUnitWallSource"], "trace-meta-process-wall")
        self.assertEqual(payload["rows"], [])

    def test_build_error_execution_result_marks_error_count(self) -> None:
        script = f"""
import {{ buildErrorExecutionResult }} from {json.dumps(EXECUTOR_MODULE_URL)};
const result = buildErrorExecutionResult({{
  normalizedPlan: {{
    schemaVersion: 1,
    executorId: 'node_webgpu_package',
    workloadId: 'alpha',
    planId: 'alpha-plan',
    planHash: 'alpha-hash',
    domain: 'compute',
    comparable: true,
    timing: {{ iterations: 1, warmup: 0, timingSource: 'doe-execution-total-ns', timingClass: 'operation' }},
    executionShape: {{
      stepCount: 4,
      dispatchCount: 2,
      bufferCount: 2,
      moduleCount: 1,
      writeBufferCount: 1,
      copyBufferToBufferCount: 0,
      readBufferCount: 0,
    }},
  }},
  spec: {{
    provider: 'node-webgpu',
    providerName: 'webgpu',
    executionBackend: 'node_webgpu_package',
  }},
  preparedSession: false,
  hostInputReadTotalNs: 11,
  hostInputParseTotalNs: 12,
  hostWorkloadPrepareTotalNs: 13,
  hostExecutorInitTotalNs: 14,
  processWallMs: 2.5,
}});
console.log(JSON.stringify(result));
"""
        result = subprocess.run(
            ["node", "--input-type=module", "-e", script],
            cwd=REPO_ROOT,
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads(result.stdout)
        meta = payload["meta"]
        self.assertEqual(meta["executionErrorCount"], 1)
        self.assertEqual(meta["executionUnsupportedCount"], 0)
        self.assertEqual(meta["executionSuccessCount"], 0)
        self.assertFalse(meta["packagePreparedSession"])
        self.assertEqual(payload["rows"], [])

    def test_build_error_execution_result_zeroes_prepared_session_pre_boundary_totals(self) -> None:
        script = f"""
import {{ buildErrorExecutionResult }} from {json.dumps(EXECUTOR_MODULE_URL)};
const result = buildErrorExecutionResult({{
  normalizedPlan: null,
  workloadId: 'prepared_error_alpha',
  planPath: '/tmp/prepared_error_alpha.json',
  spec: {{
    provider: 'doe',
    providerName: 'doe-gpu',
    executionBackend: 'doe_node_webgpu',
  }},
  preparedSession: true,
  hostInputReadTotalNs: 11,
  hostInputParseTotalNs: 12,
  hostWorkloadPrepareTotalNs: 13,
  hostExecutorInitTotalNs: 14,
  processWallMs: 2.5,
}});
console.log(JSON.stringify(result));
"""
        result = subprocess.run(
            ["node", "--input-type=module", "-e", script],
            cwd=REPO_ROOT,
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads(result.stdout)
        meta = payload["meta"]
        self.assertEqual(meta["executionErrorCount"], 1)
        self.assertTrue(meta["packagePreparedSession"])
        self.assertEqual(meta["hostInputReadTotalNs"], 0)
        self.assertEqual(meta["hostInputParseTotalNs"], 0)
        self.assertEqual(meta["hostWorkloadPrepareTotalNs"], 0)
        self.assertEqual(meta["hostExecutorInitTotalNs"], 0)
        self.assertEqual(meta["workloadUnitWallSource"], "trace-meta-process-wall")

    def test_build_dispatch_binding_cache_key_reuses_identical_bindings(self) -> None:
        script = f"""
import {{ buildDispatchBindingCacheKey }} from {json.dumps(EXECUTOR_MODULE_URL)};
const a = buildDispatchBindingCacheKey({{
  bindings: [
    {{ binding: 0, bufferId: 'buf_a', bufferType: 'read-only-storage', offset: 0 }},
    {{ binding: 1, bufferId: 'buf_b', bufferType: 'storage', offset: 16, size: 64 }},
  ],
}});
const b = buildDispatchBindingCacheKey({{
  bindings: [
    {{ binding: 0, bufferId: 'buf_a', bufferType: 'read-only-storage', offset: 0 }},
    {{ binding: 1, bufferId: 'buf_b', bufferType: 'storage', offset: 16, size: 64 }},
  ],
}});
const c = buildDispatchBindingCacheKey({{
  bindings: [
    {{ binding: 0, bufferId: 'buf_a', bufferType: 'read-only-storage', offset: 0 }},
    {{ binding: 1, bufferId: 'buf_c', bufferType: 'storage', offset: 16, size: 64 }},
  ],
}});
console.log(JSON.stringify({{ a, b, c }}));
"""
        result = subprocess.run(
            ["node", "--input-type=module", "-e", script],
            cwd=REPO_ROOT,
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads(result.stdout)
        self.assertEqual(payload["a"], payload["b"])
        self.assertNotEqual(payload["a"], payload["c"])

    def test_build_dispatch_binding_layout_cache_key_ignores_buffer_identity(self) -> None:
        script = f"""
import {{ buildDispatchBindingLayoutCacheKey }} from {json.dumps(EXECUTOR_MODULE_URL)};
const a = buildDispatchBindingLayoutCacheKey({{
  bindings: [
    {{ binding: 0, bufferId: 'buf_a', bufferType: 'read-only-storage', offset: 0 }},
    {{ binding: 1, bufferId: 'buf_b', bufferType: 'storage', offset: 16, size: 64 }},
  ],
}});
const b = buildDispatchBindingLayoutCacheKey({{
  bindings: [
    {{ binding: 0, bufferId: 'buf_c', bufferType: 'read-only-storage', offset: 128 }},
    {{ binding: 1, bufferId: 'buf_d', bufferType: 'storage', offset: 256, size: 64 }},
  ],
}});
const c = buildDispatchBindingLayoutCacheKey({{
  bindings: [
    {{ binding: 0, bufferId: 'buf_c', bufferType: 'uniform', offset: 0 }},
    {{ binding: 1, bufferId: 'buf_d', bufferType: 'storage', offset: 16, size: 64 }},
  ],
}});
console.log(JSON.stringify({{ a, b, c }}));
"""
        result = subprocess.run(
            ["node", "--input-type=module", "-e", script],
            cwd=REPO_ROOT,
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads(result.stdout)
        self.assertEqual(payload["a"], payload["b"])
        self.assertNotEqual(payload["a"], payload["c"])

    def test_readback_copy_helper_prefers_combined_native_path(self) -> None:
        script = f"""
import {{ copyReadBufferBytes }} from {json.dumps(EXECUTOR_MODULE_URL)};
const calls = [];
const buffer = {{
  size: 4,
  __doe_diag_map_read_copy_unmap_queue_wait_completed_ms: 1.25,
  __doe_diag_map_read_copy_unmap_deferred_copy_ms: 0.125,
  __doe_diag_map_read_copy_unmap_deferred_resolve_ms: 0.25,
  __doe_diag_map_read_copy_unmap_map_ms: 0.375,
  __doe_diag_map_read_copy_unmap_copy_ms: 0.5,
  __doe_diag_map_read_copy_unmap_unmap_ms: 0.625,
  _mapReadCopyUnmap(mode, offset, size) {{
    calls.push(['combined', mode, offset, size]);
    return new Uint8Array([1, 2, 3, 4]).buffer;
  }},
  async mapAsync() {{
    calls.push(['mapAsync']);
  }},
  getMappedRange() {{
    calls.push(['getMappedRange']);
    return new Uint8Array([9, 9, 9, 9]).buffer;
  }},
  unmap() {{
    calls.push(['unmap']);
  }},
}};
const result = await copyReadBufferBytes({{
  buffer,
  globals: {{ GPUMapMode: {{ READ: 1 }} }},
  sizeBytes: 4,
}});
console.log(JSON.stringify({{
  calls,
  bytes: Array.from(result.bytes),
  path: result.path,
  combinedNsPositive: result.breakdownNs.readbackMapReadCopyUnmapTotalNs >= 0,
  queueWaitNs: result.breakdownNs.readbackMapReadCopyUnmapQueueWaitCompletedTotalNs,
  deferredCopyNs: result.breakdownNs.readbackMapReadCopyUnmapDeferredCopyTotalNs,
  deferredResolveNs: result.breakdownNs.readbackMapReadCopyUnmapDeferredResolveTotalNs,
  mapNs: result.breakdownNs.readbackMapReadCopyUnmapMapTotalNs,
  copyNs: result.breakdownNs.readbackMapReadCopyUnmapCopyTotalNs,
  unmapNs: result.breakdownNs.readbackMapReadCopyUnmapUnmapTotalNs,
  mapAsyncNs: result.breakdownNs.readbackMapAsyncTotalNs,
}}));
"""
        result = subprocess.run(
            ["node", "--input-type=module", "-e", script],
            cwd=REPO_ROOT,
            env={**os.environ, "DOE_WEBGPU_SUBMIT_BREAKDOWN": "1"},
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads(result.stdout)
        self.assertEqual(payload["calls"], [["combined", 1, 0, 4]])
        self.assertEqual(payload["bytes"], [1, 2, 3, 4])
        self.assertEqual(payload["path"], "map-read-copy-unmap")
        self.assertTrue(payload["combinedNsPositive"])
        self.assertEqual(payload["queueWaitNs"], 1_250_000)
        self.assertEqual(payload["deferredCopyNs"], 125_000)
        self.assertEqual(payload["deferredResolveNs"], 250_000)
        self.assertEqual(payload["mapNs"], 375_000)
        self.assertEqual(payload["copyNs"], 500_000)
        self.assertEqual(payload["unmapNs"], 625_000)
        self.assertEqual(payload["mapAsyncNs"], 0)

    def test_readback_copy_helper_skips_direct_diagnostics_by_default(self) -> None:
        script = f"""
import {{ copyReadBufferBytes }} from {json.dumps(EXECUTOR_MODULE_URL)};
const buffer = {{
  size: 4,
  __doe_diag_map_read_copy_unmap_queue_wait_completed_ms: 1.25,
  __doe_readback_breakdown_ns: {{
    readbackMapReadCopyUnmapQueueWaitCompletedTotalNs: 500000,
  }},
  _mapReadCopyUnmap() {{
    return new Uint8Array([1, 2, 3, 4]).buffer;
  }},
}};
const result = await copyReadBufferBytes({{
  buffer,
  globals: {{ GPUMapMode: {{ READ: 1 }} }},
  sizeBytes: 4,
}});
console.log(JSON.stringify({{
  path: result.path,
  bytes: Array.from(result.bytes),
  queueWaitNs: result.breakdownNs.readbackMapReadCopyUnmapQueueWaitCompletedTotalNs,
}}));
"""
        env = {**os.environ}
        env.pop("DOE_WEBGPU_SUBMIT_BREAKDOWN", None)
        result = subprocess.run(
            ["node", "--input-type=module", "-e", script],
            cwd=REPO_ROOT,
            env=env,
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads(result.stdout)
        self.assertEqual(payload["path"], "map-read-copy-unmap")
        self.assertEqual(payload["bytes"], [1, 2, 3, 4])
        self.assertEqual(payload["queueWaitNs"], 0)

    def test_readback_copy_helper_uses_native_read_copy_after_map(self) -> None:
        script = f"""
	import {{ copyReadBufferBytes }} from {json.dumps(EXECUTOR_MODULE_URL)};
const calls = [];
const buffer = {{
  size: 4,
  async mapAsync(mode) {{
    calls.push(['mapAsync', mode]);
  }},
  _readCopy(offset, size) {{
    calls.push(['readCopy', offset, size]);
    return new Uint8Array([5, 6, 7, 8]).buffer;
  }},
  getMappedRange() {{
    calls.push(['getMappedRange']);
    return new Uint8Array([9, 9, 9, 9]).buffer;
  }},
  unmap() {{
    calls.push(['unmap']);
  }},
}};
const result = await copyReadBufferBytes({{
  buffer,
  globals: {{ GPUMapMode: {{ READ: 1 }} }},
  sizeBytes: 4,
}});
console.log(JSON.stringify({{
  calls,
  bytes: Array.from(result.bytes),
  path: result.path,
  readCopyNsPositive: result.breakdownNs.readbackNativeReadCopyTotalNs >= 0,
  hostCopyNs: result.breakdownNs.readbackHostCopyTotalNs,
}}));
"""
        result = subprocess.run(
            ["node", "--input-type=module", "-e", script],
            cwd=REPO_ROOT,
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads(result.stdout)
        self.assertEqual(payload["calls"], [["mapAsync", 1], ["readCopy", 0, 4], ["unmap"]])
        self.assertEqual(payload["bytes"], [5, 6, 7, 8])
        self.assertEqual(payload["path"], "mapped-native-read-copy")
        self.assertTrue(payload["readCopyNsPositive"])
        self.assertEqual(payload["hostCopyNs"], 0)

    def test_readback_copy_helper_can_force_map_async_path(self) -> None:
        script = f"""
import {{ copyReadBufferBytes }} from {json.dumps(EXECUTOR_MODULE_URL)};
const calls = [];
const buffer = {{
  size: 4,
  _mapReadCopyUnmap() {{
    calls.push(['combined']);
    return new Uint8Array([1, 2, 3, 4]).buffer;
  }},
  async mapAsync(mode) {{
    calls.push(['mapAsync', mode]);
  }},
  getMappedRange(offset, size) {{
    calls.push(['getMappedRange', offset, size]);
    return new Uint8Array([9, 10, 11, 12]).buffer;
  }},
  unmap() {{
    calls.push(['unmap']);
  }},
}};
const result = await copyReadBufferBytes({{
  buffer,
  globals: {{ GPUMapMode: {{ READ: 1 }} }},
  sizeBytes: 4,
  readbackMode: 'mapAsync',
}});
console.log(JSON.stringify({{
  calls,
  bytes: Array.from(result.bytes),
  path: result.path,
}}));
"""
        result = subprocess.run(
            ["node", "--input-type=module", "-e", script],
            cwd=REPO_ROOT,
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads(result.stdout)
        self.assertEqual(payload["calls"], [["mapAsync", 1], ["getMappedRange", 0, 4], ["unmap"]])
        self.assertEqual(payload["bytes"], [9, 10, 11, 12])
        self.assertEqual(payload["path"], "mapped-range-host-copy")

    def test_readback_copy_helper_keeps_standard_host_copy_fallback(self) -> None:
        script = f"""
import {{ copyReadBufferBytes }} from {json.dumps(EXECUTOR_MODULE_URL)};
const calls = [];
const buffer = {{
  size: 4,
  async mapAsync(mode) {{
    calls.push(['mapAsync', mode]);
  }},
  getMappedRange(offset, size) {{
    calls.push(['getMappedRange', offset, size]);
    return new Uint8Array([9, 10, 11, 12]).buffer;
  }},
  unmap() {{
    calls.push(['unmap']);
  }},
}};
const result = await copyReadBufferBytes({{
  buffer,
  globals: {{ GPUMapMode: {{ READ: 1 }} }},
  sizeBytes: 4,
}});
console.log(JSON.stringify({{
  calls,
  bytes: Array.from(result.bytes),
  path: result.path,
  getMappedRangeNsPositive: result.breakdownNs.readbackGetMappedRangeTotalNs >= 0,
  hostCopyNsPositive: result.breakdownNs.readbackHostCopyTotalNs >= 0,
}}));
"""
        result = subprocess.run(
            ["node", "--input-type=module", "-e", script],
            cwd=REPO_ROOT,
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads(result.stdout)
        self.assertEqual(payload["calls"], [["mapAsync", 1], ["getMappedRange", 0, 4], ["unmap"]])
        self.assertEqual(payload["bytes"], [9, 10, 11, 12])
        self.assertEqual(payload["path"], "mapped-range-host-copy")
        self.assertTrue(payload["getMappedRangeNsPositive"])
        self.assertTrue(payload["hostCopyNsPositive"])

    def test_normalize_plan_accepts_upload_readback_without_modules(self) -> None:
        script = f"""
import {{ normalizePlan }} from {json.dumps((REPO_ROOT / "bench" / "executors" / "node-webgpu" / "plan.js").resolve().as_uri())};
const normalized = normalizePlan({{
  schemaVersion: 1,
  planId: 'upload-only',
  executorId: 'node_webgpu_package',
  workloadId: 'upload_only',
  domain: 'upload-readback',
  comparable: true,
  timing: {{
    iterations: 1,
    warmup: 0,
    timingSource: 'doe-execution-total-ns',
    timingClass: 'operation',
  }},
  adapter: {{ powerPreference: 'high-performance', requiredFeatures: [], requiredLimits: {{}} }},
  buffers: [
    {{ id: 'src', size: 4, usage: ['copy_dst', 'copy_src'] }},
    {{ id: 'dst', size: 4, usage: ['copy_dst', 'map_read'] }},
  ],
  modules: [],
  steps: [
    {{ kind: 'writeBuffer', bufferId: 'src', offset: 0, data: {{ kind: 'u32', values: [7] }} }},
    {{ kind: 'copyBufferToBuffer', srcBufferId: 'src', dstBufferId: 'dst', srcOffset: 0, dstOffset: 0, sizeBytes: 4 }},
    {{ kind: 'readBuffer', bufferId: 'dst', validate: {{ kind: 'u32PrefixEquals', values: [7] }} }},
  ],
}});
console.log(JSON.stringify(normalized.executionShape));
"""
        result = subprocess.run(
            ["node", "--input-type=module", "-e", script],
            cwd=REPO_ROOT,
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        shape = json.loads(result.stdout)
        self.assertEqual(shape["moduleCount"], 0)
        self.assertEqual(shape["dispatchCount"], 0)
        self.assertEqual(shape["writeBufferCount"], 1)
        self.assertEqual(shape["copyBufferToBufferCount"], 1)
        self.assertEqual(shape["readBufferCount"], 1)

    def test_dry_run_command_repeat_reports_repeated_execution_shape(self) -> None:
        with tempfile.TemporaryDirectory(prefix="doe-node-webgpu-repeat-") as tmpdir:
            tmp = Path(tmpdir)
            plan_path = tmp / "plan.json"
            trace_meta_path = tmp / "trace.meta.json"
            trace_jsonl_path = tmp / "trace.ndjson"
            write_plan(plan_path)
            script = f"""
import {{ executePlanFile }} from {json.dumps(EXECUTOR_MODULE_URL)};
const result = await executePlanFile({{
  planPath: {json.dumps(str(plan_path))},
  workloadId: 'simple_compute_roundtrip',
  provider: 'node-webgpu',
  runtimeHost: 'node',
  traceMetaPath: {json.dumps(str(trace_meta_path))},
  traceJsonlPath: {json.dumps(str(trace_jsonl_path))},
  dryRun: true,
  commandRepeat: 3,
}});
console.log(JSON.stringify({{
  rowCount: result.meta.executionRowCount,
  successCount: result.meta.executionSuccessCount,
  dispatchCount: result.meta.executionDispatchCount,
  shaderSourceReceipts: result.meta.shaderSourceReceipts,
  shaderSourceReceiptsHash: result.meta.shaderSourceReceiptsHash,
  rows: result.rows.length,
}}));
"""
            result = subprocess.run(
                ["node", "--input-type=module", "-e", script],
                cwd=REPO_ROOT,
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            payload = json.loads(result.stdout)
            self.assertEqual(payload["rowCount"], 12)
            self.assertEqual(payload["successCount"], 12)
            self.assertEqual(payload["dispatchCount"], 3)
            self.assertEqual(len(payload["shaderSourceReceipts"]), 1)
            self.assertEqual(payload["shaderSourceReceipts"][0]["moduleId"], "multiply")
            self.assertRegex(payload["shaderSourceReceipts"][0]["sha256"], r"^[0-9a-f]{64}$")
            self.assertRegex(payload["shaderSourceReceiptsHash"], r"^[0-9a-f]{64}$")
            self.assertEqual(payload["rows"], 12)

    def test_build_request_device_descriptor_omits_empty_fields(self) -> None:
        script = f"""
import {{ buildRequestDeviceDescriptor }} from {json.dumps(EXECUTOR_MODULE_URL)};
const empty = buildRequestDeviceDescriptor({{
  requiredFeatures: [],
  requiredLimits: {{}},
}});
const populated = buildRequestDeviceDescriptor({{
  requiredFeatures: ['shader-f16'],
  requiredLimits: {{ maxStorageBuffersPerShaderStage: 8 }},
}});
console.log(JSON.stringify({{ empty, populated }}));
"""
        result = subprocess.run(
            ["node", "--input-type=module", "-e", script],
            cwd=REPO_ROOT,
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads(result.stdout)
        self.assertEqual(payload["empty"], {})
        self.assertEqual(payload["populated"]["requiredFeatures"], ["shader-f16"])
        self.assertEqual(
            payload["populated"]["requiredLimits"]["maxStorageBuffersPerShaderStage"],
            8,
        )

    def test_command_plan_roundtrip_preserves_capture_semantics_and_determinism(self) -> None:
        script = f"""
import {{ normalizePlan }} from {json.dumps((REPO_ROOT / "bench" / "executors" / "node-webgpu" / "plan.js").resolve().as_uri())};
const plan = {{
  schemaVersion: 1,
  planKind: 'benchmark_ir',
  workloadId: 'sample_capture_roundtrip',
  planSha256: 'sample-capture-roundtrip',
  compatibilityCommandsSha256: 'sample-capture-roundtrip',
  determinism: {{
    mode: 'stable-token',
    semanticTokenIndex: 0,
    providerBoundary: 'doe',
    topCandidates: 4,
  }},
  commands: [
    {{
      kind: 'buffer_write',
      handle: 1010,
      bufferSize: 16,
      data: [1, 0, 0, 0],
    }},
    {{
      kind: 'buffer_write',
      handle: 2227,
      bufferSize: 16,
      data: [0, 0, 0, 0],
      semanticOpId: 'decode.final_logits',
      semanticStage: 'sample_only',
      semanticPhase: 'final_logits',
      semanticTokenIndex: 0,
      semanticExecutionPlanHash: 'abc123',
      captureBufferHandle: 2227,
      captureSize: 16,
    }},
    {{
      kind: 'kernel_dispatch',
      kernel: 'sample.wgsl',
      x: 1,
      y: 1,
      z: 1,
      bindings: [
        {{
          binding: 0,
          resource_handle: 1010,
          buffer_size: 16,
          buffer_type: 'uniform',
        }},
        {{
          binding: 1,
          resource_handle: 2227,
          buffer_size: 16,
          buffer_type: 'readonly',
        }},
        {{
          binding: 2,
          resource_handle: 2228,
          buffer_size: 4,
          buffer_type: 'storage',
        }},
      ],
      semanticOpId: 'sample.output_token',
      semanticStage: 'sample_only',
      semanticPhase: 'output_token',
      semanticTokenIndex: 0,
      semanticExecutionPlanHash: 'abc123',
      captureBufferHandle: 2228,
      captureSize: 4,
    }},
  ],
}};
const normalized = normalizePlan(plan);
console.log(JSON.stringify(normalized));
"""
        result = subprocess.run(
            ["node", "--input-type=module", "-e", script],
            cwd=REPO_ROOT,
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads(result.stdout)
        self.assertEqual(payload["determinism"]["mode"], "stable-token")
        self.assertEqual(payload["determinism"]["providerBoundary"], "doe")
        self.assertEqual(payload["executionShape"]["readBufferCount"], 2)
        self.assertEqual(payload["executionShape"]["copyBufferToBufferCount"], 2)
        read_steps = [step for step in payload["steps"] if step["kind"] == "readBuffer"]
        self.assertEqual(read_steps[0]["semanticPhase"], "final_logits")
        self.assertEqual(read_steps[1]["semanticPhase"], "output_token")
        self.assertEqual(read_steps[0]["captureSourceBufferId"], "buffer_2227")
        self.assertEqual(read_steps[1]["captureSourceBufferId"], "buffer_2228")

    def test_command_plan_roundtrip_defaults_to_unknown_directional_metadata(self) -> None:
        script = f"""
import {{ normalizePlan }} from {json.dumps((REPO_ROOT / "bench" / "executors" / "node-webgpu" / "plan.js").resolve().as_uri())};
const plan = {{
  schemaVersion: 1,
  planKind: 'benchmark_ir',
  workloadId: 'sample_command_plan',
  planSha256: 'sample-command-plan',
  compatibilityCommandsSha256: 'sample-command-plan',
  commands: [
    {{
      kind: 'buffer_write',
      handle: 1,
      bufferSize: 16,
      data: [1, 2, 3, 4],
    }},
    {{
      kind: 'kernel_dispatch',
      kernel: 'sample.wgsl',
      x: 1,
      y: 1,
      z: 1,
      bindings: [
        {{
          binding: 0,
          resource_handle: 1,
          buffer_size: 16,
          buffer_type: 'uniform',
        }},
        {{
          binding: 1,
          resource_handle: 2,
          buffer_size: 16,
          buffer_type: 'storage',
        }},
      ],
    }},
  ],
}};
const normalized = normalizePlan(plan);
console.log(JSON.stringify({{ domain: normalized.domain, comparable: normalized.comparable }}));
"""
        result = subprocess.run(
            ["node", "--input-type=module", "-e", script],
            cwd=REPO_ROOT,
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads(result.stdout)
        self.assertEqual(payload["domain"], "unknown")
        self.assertFalse(payload["comparable"])

    def test_executor_source_does_not_use_private_dispatch_bound_fast_path(self) -> None:
        source = (REPO_ROOT / "bench" / "executors" / "node-webgpu" / "executor.js").read_text(
            encoding="utf-8"
        )
        self.assertNotIn("pass._dispatchBound(", source)

    def test_terminal_readback_map_completion_policy_is_structural(self) -> None:
        script = f"""
import {{ readBufferMapCanCompleteSubmit }} from {json.dumps(EXECUTOR_MODULE_URL)};
const terminalCopy = [
  {{ kind: 'dispatch' }},
  {{ kind: 'copyBufferToBuffer', dstBufferId: 'readback' }},
  {{ kind: 'readBuffer', bufferId: 'readback' }},
];
const nonTerminalCopy = [
  {{ kind: 'copyBufferToBuffer', dstBufferId: 'readback' }},
  {{ kind: 'readBuffer', bufferId: 'readback' }},
  {{ kind: 'dispatch' }},
];
const wrongTarget = [
  {{ kind: 'copyBufferToBuffer', dstBufferId: 'other' }},
  {{ kind: 'readBuffer', bufferId: 'readback' }},
];
const terminalWrite = [
  {{ kind: 'writeBuffer', bufferId: 'readback' }},
  {{ kind: 'readBuffer', bufferId: 'readback' }},
];
console.log(JSON.stringify({{
  terminalCopy: readBufferMapCanCompleteSubmit(terminalCopy, 2, terminalCopy[2]),
  nonTerminalCopy: readBufferMapCanCompleteSubmit(nonTerminalCopy, 1, nonTerminalCopy[1]),
  wrongTarget: readBufferMapCanCompleteSubmit(wrongTarget, 1, wrongTarget[1]),
  terminalWrite: readBufferMapCanCompleteSubmit(terminalWrite, 1, terminalWrite[1]),
}}));
"""
        result = subprocess.run(
            ["node", "--input-type=module", "-e", script],
            cwd=REPO_ROOT,
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads(result.stdout)
        self.assertTrue(payload["terminalCopy"])
        self.assertFalse(payload["nonTerminalCopy"])
        self.assertFalse(payload["wrongTarget"])
        self.assertTrue(payload["terminalWrite"])

    def test_doe_queue_wait_skips_pre_wait_macrotask_yield(self) -> None:
        script = f"""
import {{ queueWaitNeedsPreYield }} from {json.dumps(EXECUTOR_MODULE_URL)};
const mode = 'readback-or-fence.mapAsync';
console.log(JSON.stringify({{
  doe: queueWaitNeedsPreYield({{ queueWaitMode: mode, providerSpec: {{ provider: 'doe' }} }}),
  doeDirect: queueWaitNeedsPreYield({{ queueWaitMode: mode, providerSpec: {{ provider: 'doe-direct' }} }}),
  nodeWebgpu: queueWaitNeedsPreYield({{ queueWaitMode: mode, providerSpec: {{ provider: 'node-webgpu' }} }}),
  packageMode: queueWaitNeedsPreYield({{ queueWaitMode: 'queue.onSubmittedWorkDone', providerSpec: {{ provider: 'node-webgpu' }} }}),
}}));
"""
        result = subprocess.run(
            ["node", "--input-type=module", "-e", script],
            cwd=REPO_ROOT,
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads(result.stdout)
        self.assertFalse(payload["doe"])
        self.assertFalse(payload["doeDirect"])
        self.assertTrue(payload["nodeWebgpu"])
        self.assertFalse(payload["packageMode"])

    def test_terminal_readback_map_completion_policy_covers_node_and_bun(self) -> None:
        source = (REPO_ROOT / "bench" / "executors" / "node-webgpu" / "executor.js").read_text(
            encoding="utf-8"
        )
        self.assertIn("runtimeHost === 'node' || runtimeHost === 'bun'", source)
        self.assertIn("runtime.queueWaitMode === NODE_PACKAGE_QUEUE_WAIT_MODE", source)
        self.assertIn("readBufferMapCanCompleteSubmit(normalizedPlan.steps, index, step)", source)

    def test_node_doe_package_source_keeps_dispatch_copy_batched_for_submit(self) -> None:
        source = (
            REPO_ROOT / "packages" / "doe-gpu" / "src" / "vendor" / "webgpu" / "index.js"
        ).read_text(encoding="utf-8")
        self.assertIn("encoder._native = addon.createCommandEncoder(", source)
        self.assertIn("new classes.DoeGPUComputePassEncoder(null, encoder)", source)
        self.assertIn("finishNodeLazyCommandsAsNativeCommandBuffer(encoder, commands)", source)
        self.assertIn("addon.createComputeDispatchCopyCommandBuffer(", source)
        self.assertIn("addon.createComputeDispatchBatchCopyCommandBuffer(", source)
        self.assertIn("canFinishNodeLazyDispatchCopyCommandsAsNativeBuffer(commands)", source)
        self.assertIn("bg: pass._bindGroups.slice()", source)
        self.assertIn("b: bindGroup", source)
        self.assertIn("return { _commands: commands, _batched: true };", source)
        self.assertIn("const addonBreakdown = addon.submitBatched(deviceNative, queueNative, cmds);", source)
        self.assertIn("fastPathStats.dispatchFlush += 1", source)
        self.assertIn("nativeFastPathInfo()", source)

        napi_source = NAPI_QUEUE_PATH.read_text(encoding="utf-8")
        self.assertIn("read_command_bind_groups(env, cmd", napi_source)
        self.assertIn('compact_bind_groups = get_prop(env, cmd, "b")', napi_source)
        self.assertIn("compact_type != napi_undefined", napi_source)
        self.assertIn("get_command_type(env, cmd)", napi_source)
        self.assertNotIn("get_command_field(env, cmd", napi_source)
        self.assertNotIn("bool cmd_is_array", napi_source)
        self.assertNotIn("bool copy_is_array", napi_source)
        self.assertIn("doe_queue_submit_one", napi_source)
        self.assertIn("addon.queueSubmitOne(queueNative, singleNative)", source)

    def test_runtime_copy_buffer_records_doe_buffers_for_submit_replay(self) -> None:
        source = RUNTIME_ENCODER_NATIVE_PATH.read_text(encoding="utf-8")
        copy_section = source[
            source.index("pub export fn doeNativeCopyBufferToBuffer"):
            source.index("pub export fn doeNativeCommandEncoderCopyBufferToTexture")
        ]

        self.assertIn(".src = @ptrCast(src),", copy_section)
        self.assertIn(".dst = @ptrCast(dst),", copy_section)
        self.assertNotIn("if (enc.dev.backend == .vulkan)", copy_section)

    def test_runtime_metal_submit_has_copy_only_deferred_path(self) -> None:
        submit_source = RUNTIME_METAL_SUBMIT_PATH.read_text(encoding="utf-8")
        shared_source = RUNTIME_QUEUE_SHARED_PATH.read_text(encoding="utf-8")

        self.assertIn("fn try_execute_copy_only_deferred(", submit_source)
        self.assertIn("shared.make_deferred_copy_plan(", submit_source)
        self.assertIn("queue_flush_breakdown.executeDeferredCopies(q);", submit_source)
        self.assertIn("const src_mtl = if (src_buf) |src| src.mtl else c.src;", submit_source)
        self.assertIn("pub fn make_deferred_copy_plan(", shared_source)
        self.assertIn("pub fn append_deferred_copy_plan(", shared_source)

    def test_package_runtime_has_batch_dispatch_copy_fast_path(self) -> None:
        compute_source = RUNTIME_COMPUTE_FAST_PATH.read_text(encoding="utf-8")
        napi_source = NAPI_QUEUE_PATH.read_text(encoding="utf-8")
        bun_source = BUN_FFI_PATH.read_text(encoding="utf-8")

        self.assertIn("pub export fn doeNativeComputeDispatchBatchCopyFlush(", compute_source)
        self.assertIn("metal_bridge_cmd_buf_encode_blit_copy(", compute_source)
        self.assertIn("queue_submit.try_schedule_deferred_copy(", compute_source)
        self.assertIn("queue_submit.flush_before_submit_if_needed_timed(q)", compute_source)
        self.assertIn("pfn_doeNativeComputeDispatchBatchCopyFlush", napi_source)
        self.assertIn("dispatch_then_copy", napi_source)
        self.assertIn(
            "if (!submit_breakdown_enabled()) return make_submit_completion_hint(env, flush_ns, 0, 0, 0);",
            napi_source,
        )
        self.assertIn(
            "return make_submit_completion_hint(env, flush_ns, wait_completed_ns, deferred_copy_ns, deferred_resolve_ns);",
            napi_source,
        )
        self.assertIn("doeNativeComputeDispatchBatchCopyFlush", bun_source)
        self.assertIn("dispatchThenCopy", bun_source)

    def test_evaluate_execution_determinism_uses_host_byte_policy(self) -> None:
        script = f"""
import {{ evaluateExecutionDeterminism }} from {json.dumps((REPO_ROOT / "bench" / "executors" / "node-webgpu" / "determinism.js").resolve().as_uri())};
const logits = new Uint8Array(new Float32Array([1, 7, 7, 2]).buffer);
const token = new Uint8Array(new Uint32Array([2]).buffer);
const result = await evaluateExecutionDeterminism({{
  determinismConfig: {{
    mode: 'stable-token',
    semanticTokenIndex: 0,
    providerBoundary: 'doe',
    topCandidates: 4,
  }},
  provider: 'doe',
  captureRows: new Map([
    ['0:final_logits', {{ bytes: logits, semanticPhase: 'final_logits', semanticTokenIndex: 0 }}],
    ['0:output_token', {{ bytes: token, semanticPhase: 'output_token', semanticTokenIndex: 0 }}],
  ]),
}});
console.log(JSON.stringify(result));
"""
        result = subprocess.run(
            ["node", "--input-type=module", "-e", script],
            cwd=REPO_ROOT,
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads(result.stdout)
        self.assertEqual(payload["rawToken"], 2)
        self.assertEqual(payload["receipt"]["token"], 1)
        self.assertEqual(payload["determinism"]["mode"], "stable-token")
        self.assertEqual(payload["determinism"]["selectedBy"], "stable-token-policy")

    def test_readback_capture_summary_hashes_bytes_and_semantics(self) -> None:
        script = f"""
import {{ summarizeReadbackCapture }} from {json.dumps(EXECUTOR_MODULE_URL)};
const summary = summarizeReadbackCapture({{
  repeatIndex: 3,
  stepIndex: 38,
  step: {{
    id: 'step-36-capture-read',
    bufferId: 'capture_36_2228',
    semanticOpId: 'gemma3_270m_decode_1tok_sample_token',
    semanticStage: 'inference',
    semanticPhase: 'decode_sample_token',
    semanticTokenIndex: 0,
    semanticExecutionPlanHash: 'abc123',
    captureSourceBufferId: 'buffer_2228',
    captureOffset: 0,
    captureSize: 4,
    captureDecode: 'u32_le',
  }},
  bytes: Uint8Array.from([2, 0, 0, 0]),
}});
console.log(JSON.stringify(summary));
"""
        result = subprocess.run(
            ["node", "--input-type=module", "-e", script],
            cwd=REPO_ROOT,
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads(result.stdout)
        self.assertEqual(payload["repeatIndex"], 3)
        self.assertEqual(payload["stepIndex"], 38)
        self.assertEqual(payload["byteLength"], 4)
        self.assertEqual(payload["decodedU32Le"], 2)
        self.assertEqual(
            payload["sha256"],
            "26b25d457597a7b0463f9620f666dd10aa2c4373a505967c7c8d70922a2d6ece",
        )
        self.assertEqual(payload["semanticPhase"], "decode_sample_token")
        self.assertEqual(payload["captureSourceBufferId"], "buffer_2228")

    def test_readback_capture_summary_reuses_exact_small_digest_cache(self) -> None:
        script = f"""
import {{ summarizeReadbackCapture }} from {json.dumps(EXECUTOR_MODULE_URL)};
const digestCache = new Map();
const step = {{ id: 'token-read', bufferId: 'token' }};
const first = summarizeReadbackCapture({{
  repeatIndex: 0,
  stepIndex: 1,
  step,
  bytes: Uint8Array.from([243, 8, 0, 0]),
  digestCache,
}});
const second = summarizeReadbackCapture({{
  repeatIndex: 1,
  stepIndex: 1,
  step,
  bytes: Uint8Array.from([243, 8, 0, 0]),
  digestCache,
}});
console.log(JSON.stringify({{
  sameDigest: first.sha256 === second.sha256,
  decodedU32Le: second.decodedU32Le,
  cacheSize: digestCache.size,
  hasNumericKey: digestCache.has(2291),
}}));
"""
        result = subprocess.run(
            ["node", "--input-type=module", "-e", script],
            cwd=REPO_ROOT,
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads(result.stdout)
        self.assertTrue(payload["sameDigest"])
        self.assertEqual(payload["decodedU32Le"], 2291)
        self.assertEqual(payload["cacheSize"], 1)
        self.assertTrue(payload["hasNumericKey"])

    def test_write_buffer_materialization_cache_reuses_step_data(self) -> None:
        script = f"""
import {{ materializeWriteBufferDataForStep }} from {json.dumps(EXECUTOR_MODULE_URL)};
const cache = new Map();
const data = {{ kind: 'u32', values: [1, 2, 3, 4] }};
const first = materializeWriteBufferDataForStep(cache, 7, data);
const second = materializeWriteBufferDataForStep(cache, 7, data);
const third = materializeWriteBufferDataForStep(cache, 8, data);
console.log(JSON.stringify({{
  sameStepReused: first === second,
  differentStepSeparate: first !== third,
  firstValues: Array.from(first),
  cacheSize: cache.size,
}}));
"""
        result = subprocess.run(
            ["node", "--input-type=module", "-e", script],
            cwd=REPO_ROOT,
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads(result.stdout)
        self.assertTrue(payload["sameStepReused"])
        self.assertTrue(payload["differentStepSeparate"])
        self.assertEqual(payload["firstValues"], [1, 2, 3, 4])
        self.assertEqual(payload["cacheSize"], 2)

    def test_package_write_breakdown_classifies_static_and_dynamic_writes(self) -> None:
        script = f"""
import {{ zeroPackageWriteBreakdown, recordPackageWriteBreakdown }} from {json.dumps(EXECUTOR_MODULE_URL)};
const stats = zeroPackageWriteBreakdown();
recordPackageWriteBreakdown(stats, {{
  kind: 'writeBuffer',
  data: {{ kind: 'file' }},
  semanticPhase: 'buffer_load',
}}, 1024);
recordPackageWriteBreakdown(stats, {{
  kind: 'writeBuffer',
  data: {{ kind: 'u32', values: [1, 2, 3, 4] }},
}}, 16);
console.log(JSON.stringify(stats));
"""
        result = subprocess.run(
            ["node", "--input-type=module", "-e", script],
            cwd=REPO_ROOT,
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads(result.stdout)
        self.assertEqual(payload["totalCount"], 2)
        self.assertEqual(payload["totalBytes"], 1040)
        self.assertEqual(payload["staticBufferLoadCount"], 1)
        self.assertEqual(payload["staticBufferLoadBytes"], 1024)
        self.assertEqual(payload["dynamicWriteCount"], 1)
        self.assertEqual(payload["dynamicWriteBytes"], 16)
        self.assertEqual(payload["byDataKind"]["file"], {"count": 1, "bytes": 1024})
        self.assertEqual(payload["byDataKind"]["u32"], {"count": 1, "bytes": 16})
        self.assertEqual(payload["bySemanticPhase"]["buffer_load"], {"count": 1, "bytes": 1024})
        self.assertEqual(payload["bySemanticPhase"]["dynamic_write"], {"count": 1, "bytes": 16})

    def test_static_buffer_load_step_classification_uses_file_or_semantic_phase(self) -> None:
        script = f"""
import {{ isStaticBufferLoadStep }} from {json.dumps(EXECUTOR_MODULE_URL)};
console.log(JSON.stringify({{
  fileData: isStaticBufferLoadStep({{
    kind: 'writeBuffer',
    data: {{ kind: 'file' }},
  }}),
  semanticPhase: isStaticBufferLoadStep({{
    kind: 'writeBuffer',
    data: {{ kind: 'u32', values: [1] }},
    semanticPhase: 'buffer_load',
  }}),
  dynamicWrite: isStaticBufferLoadStep({{
    kind: 'writeBuffer',
    data: {{ kind: 'u32', values: [1] }},
  }}),
  dispatch: isStaticBufferLoadStep({{ kind: 'dispatch' }}),
}}));
"""
        result = subprocess.run(
            ["node", "--input-type=module", "-e", script],
            cwd=REPO_ROOT,
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads(result.stdout)
        self.assertTrue(payload["fileData"])
        self.assertTrue(payload["semanticPhase"])
        self.assertFalse(payload["dynamicWrite"])
        self.assertFalse(payload["dispatch"])

    def test_resident_buffer_load_plan_rejects_static_dynamic_buffer_conflict(self) -> None:
        script = f"""
import {{ validateResidentBufferLoadPlan }} from {json.dumps(EXECUTOR_MODULE_URL)};
try {{
  validateResidentBufferLoadPlan({{
    steps: [
      {{
        kind: 'writeBuffer',
        bufferId: 'shared',
        data: {{ kind: 'file', cacheNamespace: 'unit', cacheKey: 'a', sizeBytes: 4 }},
      }},
      {{
        kind: 'writeBuffer',
        bufferId: 'shared',
        data: {{ kind: 'u32', values: [1] }},
      }},
    ],
  }});
  console.log(JSON.stringify({{ ok: true }}));
}} catch (error) {{
  console.log(JSON.stringify({{ ok: false, message: error.message }}));
}}
"""
        result = subprocess.run(
            ["node", "--input-type=module", "-e", script],
            cwd=REPO_ROOT,
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads(result.stdout)
        self.assertFalse(payload["ok"])
        self.assertIn("cannot preload buffers that also receive dynamic writes", payload["message"])
        self.assertIn("shared", payload["message"])

    def test_lookup_unsupported_package_execution_entry_matches_host_specific_lane(self) -> None:
        script = f"""
import {{ lookupUnsupportedPackageExecutionEntry }} from {json.dumps(EXECUTOR_MODULE_URL)};
const policy = {{
  schemaVersion: 1,
  unsupportedExecutions: [
    {{
      id: 'apple-node-node-webgpu-gemma1b-mac-lan',
      runtimeHost: 'node',
      provider: 'node-webgpu',
      workloadId: 'inference_gemma3_1b_prefill_64tok_decode_64tok',
      host: {{
        platform: 'darwin',
        arch: 'arm64',
        hostname: 'mac.lan',
        osRelease: '25.3.0',
      }},
      unsupportedCode: 'provider_execution_unavailable',
      message: 'node-webgpu execution unavailable for provider node-webgpu on this Apple host',
      detail: 'diagnostic detail',
    }},
  ],
}};
const matched = lookupUnsupportedPackageExecutionEntry(policy, {{
  runtimeHost: 'node',
  provider: 'node-webgpu',
  workloadId: 'inference_gemma3_1b_prefill_64tok_decode_64tok',
  platform: 'darwin',
  arch: 'arm64',
  hostname: 'mac.lan',
  osRelease: '25.3.0',
}});
const missed = lookupUnsupportedPackageExecutionEntry(policy, {{
  runtimeHost: 'node',
  provider: 'node-webgpu',
  workloadId: 'inference_gemma3_1b_prefill_64tok_decode_64tok',
  platform: 'darwin',
  arch: 'arm64',
  hostname: 'other-host',
  osRelease: '25.3.0',
}});
console.log(JSON.stringify({{ matched, missed }}));
"""
        result = subprocess.run(
            ["node", "--input-type=module", "-e", script],
            cwd=REPO_ROOT,
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads(result.stdout)
        self.assertEqual(payload["matched"]["unsupportedCode"], "provider_execution_unavailable")
        self.assertIsNone(payload["missed"])

    def test_lookup_package_write_batching_entry_matches_provider_method(self) -> None:
        script = f"""
	import {{ lookupPackageWriteBatchingEntry }} from {json.dumps(EXECUTOR_MODULE_URL)};
const policy = {{
  schemaVersion: 1,
  writeBatching: [
    {{
      id: 'bun-ffi-min-batch',
      runtimeHost: 'bun',
      provider: 'doe-ffi',
      method: 'queue.__doeWriteBufferBatch',
      minConsecutiveWrites: 16,
      evidence: 'bench/out/example.phase-delta.json',
      detail: 'fixture',
    }},
  ],
  unsupportedExecutions: [],
}};
const matched = lookupPackageWriteBatchingEntry(policy, {{
  runtimeHost: 'bun',
  provider: 'doe-ffi',
  method: 'queue.__doeWriteBufferBatch',
}});
const missed = lookupPackageWriteBatchingEntry(policy, {{
  runtimeHost: 'bun',
  provider: 'doe-ffi',
  method: 'queue.writeBufferBatch.compact',
}});
console.log(JSON.stringify({{ matched, missed }}));
"""
        result = subprocess.run(
            ["node", "--input-type=module", "-e", script],
            cwd=REPO_ROOT,
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads(result.stdout)
        self.assertEqual(payload["matched"]["minConsecutiveWrites"], 16)
        self.assertIsNone(payload["missed"])

    def test_lookup_package_readback_mode_entry_matches_workload(self) -> None:
        script = f"""
	import {{ lookupPackageReadbackModeEntry }} from {json.dumps(EXECUTOR_MODULE_URL)};
const policy = {{
  schemaVersion: 1,
  readbackMode: [
    {{
      id: 'bun-ffi-package-mapasync',
      runtimeHost: 'bun',
      provider: 'doe-ffi',
      workloadId: ['package_image_rgba_invert_1024', 'package_vector_scale_add_262k'],
      mode: 'mapAsync',
      evidence: 'bench/out/example.phase-delta.json',
      detail: 'fixture',
    }},
    {{
      id: 'node-package-mapasync',
      runtimeHost: 'node',
      provider: 'doe',
      workloadId: ['package_queue_submit_completion'],
      packagePreparedSession: true,
      mode: 'mapAsync',
      evidence: 'bench/out/node.phase-delta.json',
      detail: 'fixture',
    }},
    {{
      id: 'node-package-native',
      runtimeHost: 'node',
      provider: 'doe',
      workloadId: ['package_queue_submit_completion'],
      packagePreparedSession: false,
      mode: 'native-map-read-copy-unmap',
      evidence: 'bench/out/node-cold.phase-delta.json',
      detail: 'fixture',
    }},
  ],
  unsupportedExecutions: [],
}};
const matched = lookupPackageReadbackModeEntry(policy, {{
  runtimeHost: 'bun',
  provider: 'doe-ffi',
  workloadId: 'package_image_rgba_invert_1024',
}});
const missed = lookupPackageReadbackModeEntry(policy, {{
  runtimeHost: 'bun',
  provider: 'doe-ffi',
  workloadId: 'package_queue_submit_completion',
}});
const nodeMatched = lookupPackageReadbackModeEntry(policy, {{
  runtimeHost: 'node',
  provider: 'doe',
  workloadId: 'package_queue_submit_completion',
  packagePreparedSession: true,
}});
const nodeColdMatched = lookupPackageReadbackModeEntry(policy, {{
  runtimeHost: 'node',
  provider: 'doe',
  workloadId: 'package_queue_submit_completion',
  packagePreparedSession: false,
}});
console.log(JSON.stringify({{ matched, missed, nodeMatched, nodeColdMatched }}));
"""
        result = subprocess.run(
            ["node", "--input-type=module", "-e", script],
            cwd=REPO_ROOT,
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads(result.stdout)
        self.assertEqual(payload["matched"]["mode"], "mapAsync")
        self.assertEqual(payload["nodeMatched"]["mode"], "mapAsync")
        self.assertEqual(payload["nodeColdMatched"]["mode"], "native-map-read-copy-unmap")
        self.assertIsNone(payload["missed"])

    def test_package_execution_policy_keeps_bun_ffi_queue_on_mapasync(self) -> None:
        policy = json.loads(PACKAGE_EXECUTION_POLICY_PATH.read_text(encoding="utf-8"))
        entries = policy["readbackMode"]
        mapasync_entry = next(
            entry
            for entry in entries
            if entry["id"] == "bun-ffi-package-developer-mapasync-readback"
        )
        native_queue_entries = [
            entry
            for entry in entries
            if entry["runtimeHost"] == "bun"
            and entry["provider"] == "doe-ffi"
            and entry["mode"] == "native-map-read-copy-unmap"
            and "package_queue_submit_completion" in entry["workloadId"]
        ]

        self.assertIn("package_queue_submit_completion", mapasync_entry["workloadId"])
        self.assertEqual(native_queue_entries, [])

    def test_prepared_session_boundary_scopes_pre_boundary_host_totals(self) -> None:
        script = f"""
import {{ boundaryScopedHostTotals }} from {json.dumps(EXECUTOR_MODULE_URL)};
console.log(JSON.stringify(boundaryScopedHostTotals({{
  preparedSession: true,
  hostInputReadTotalNs: 11,
  hostInputParseTotalNs: 12,
  hostWorkloadPrepareTotalNs: 13,
  hostExecutorInitTotalNs: 14,
  hostUploadPrewarmTotalNs: 15,
  hostKernelPrewarmTotalNs: 16,
  hostCommandOrchestrationTotalNs: 17,
  hostArtifactFinalizeTotalNs: 18,
}})));
"""
        result = subprocess.run(
            ["node", "--input-type=module", "-e", script],
            cwd=REPO_ROOT,
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        totals = json.loads(result.stdout)
        self.assertEqual(totals["hostInputReadTotalNs"], 0)
        self.assertEqual(totals["hostInputParseTotalNs"], 0)
        self.assertEqual(totals["hostWorkloadPrepareTotalNs"], 0)
        self.assertEqual(totals["hostExecutorInitTotalNs"], 0)
        self.assertEqual(totals["hostUploadPrewarmTotalNs"], 15)
        self.assertEqual(totals["hostKernelPrewarmTotalNs"], 16)
        self.assertEqual(totals["hostCommandOrchestrationTotalNs"], 17)
        self.assertEqual(totals["hostArtifactFinalizeTotalNs"], 0)

    def test_dry_run_emits_trace_meta_and_jsonl(self) -> None:
        with tempfile.TemporaryDirectory(prefix="doe-node-webgpu-executor-") as tmpdir:
            tmp = Path(tmpdir)
            plan_path = tmp / "plan.json"
            meta_path = tmp / "trace-meta.json"
            trace_path = tmp / "trace.jsonl"
            write_plan(plan_path)

            result = subprocess.run(
                [
                    "node",
                    str(CLI_PATH),
                    "--provider",
                    "node-webgpu",
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
            self.assertEqual(result.stderr, "")

            meta = json.loads(meta_path.read_text(encoding="utf-8"))
            rows = [json.loads(line) for line in trace_path.read_text(encoding="utf-8").splitlines() if line.strip()]

            self.assertEqual(meta["executionBackend"], "node_webgpu_package")
            self.assertEqual(meta["executionProvider"], "node-webgpu")
            self.assertEqual(meta["executionProviderName"], "node-webgpu")
            self.assertEqual(meta["timingSource"], "doe-execution-total-ns")
            self.assertEqual(meta["timingClass"], "operation")
            self.assertEqual(meta["executionQueueSyncMode"], "per-command")
            self.assertEqual(meta["executionQueueWaitMode"], "readback-or-fence.mapAsync")
            self.assertEqual(meta["executionRowCount"], 4)
            self.assertEqual(meta["executionSuccessCount"], 4)
            self.assertEqual(meta["executionDispatchCount"], 1)
            self.assertEqual(meta["provider"], "node-webgpu")
            self.assertEqual(meta["hostInputReadTotalNs"], 0)
            self.assertEqual(meta["hostExecutorInitTotalNs"], 0)
            self.assertFalse(meta["packagePreparedSession"])
            self.assertTrue(meta["packageSetupIncludedInSelectedTiming"])
            self.assertEqual(meta["packageSetupTotalNs"], 0)
            self.assertEqual(len(rows), 4)
            self.assertEqual([row["stepKind"] for row in rows], ["writeBuffer", "dispatch", "copyBufferToBuffer", "readBuffer"])
            self.assertTrue(all(row["executionBackend"] == "node_webgpu_package" for row in rows))
            self.assertTrue(all(row["executionProvider"] == "node-webgpu" for row in rows))
            self.assertTrue(all(row["executionProviderName"] == "node-webgpu" for row in rows))

    def test_dry_run_supports_doe_provider_metadata(self) -> None:
        with tempfile.TemporaryDirectory(prefix="doe-node-webgpu-executor-") as tmpdir:
            tmp = Path(tmpdir)
            plan_path = tmp / "plan.json"
            meta_path = tmp / "trace-meta.json"
            trace_path = tmp / "trace.jsonl"
            write_plan(plan_path)

            result = subprocess.run(
                [
                    "node",
                    str(CLI_PATH),
                    "--provider",
                    "doe",
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

            self.assertEqual(meta["executionBackend"], "doe_node_webgpu")
            self.assertEqual(meta["executionProvider"], "doe")
            self.assertEqual(meta["executionProviderName"], "doe-gpu")
            self.assertEqual(meta["provider"], "doe")
            self.assertFalse(meta["packagePreparedSession"])
            self.assertEqual(len(rows), 4)
            self.assertTrue(all(row["executionBackend"] == "doe_node_webgpu" for row in rows))
            self.assertTrue(all(row["executionProvider"] == "doe" for row in rows))
            self.assertTrue(all(row["executionProviderName"] == "doe-gpu" for row in rows))

    def test_dry_run_supports_doe_native_direct_provider_metadata(self) -> None:
        with tempfile.TemporaryDirectory(prefix="doe-node-webgpu-executor-") as tmpdir:
            tmp = Path(tmpdir)
            plan_path = tmp / "plan.json"
            meta_path = tmp / "trace-meta.json"
            trace_path = tmp / "trace.jsonl"
            write_plan(plan_path)

            result = subprocess.run(
                [
                    "node",
                    str(CLI_PATH),
                    "--provider",
                    "doe-direct",
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

            self.assertEqual(meta["executionBackend"], "doe_node_native_direct")
            self.assertEqual(meta["executionProvider"], "doe-direct")
            self.assertEqual(meta["executionProviderName"], "doe-gpu/native-direct")
            self.assertEqual(meta["provider"], "doe-direct")
            self.assertFalse(meta["packagePreparedSession"])
            self.assertEqual(len(rows), 4)
            self.assertTrue(all(row["executionBackend"] == "doe_node_native_direct" for row in rows))
            self.assertTrue(all(row["executionProvider"] == "doe-direct" for row in rows))
            self.assertTrue(all(row["executionProviderName"] == "doe-gpu/native-direct" for row in rows))

    def test_dry_run_supports_prepared_session_metadata(self) -> None:
        with tempfile.TemporaryDirectory(prefix="doe-node-webgpu-executor-") as tmpdir:
            tmp = Path(tmpdir)
            plan_path = tmp / "plan.json"
            meta_path = tmp / "trace-meta.json"
            trace_path = tmp / "trace.jsonl"
            write_plan(plan_path)

            result = subprocess.run(
                [
                    "node",
                    str(CLI_PATH),
                    "--provider",
                    "node-webgpu",
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
            self.assertTrue(meta["packagePreparedSession"])
            self.assertFalse(meta["packageSetupIncludedInSelectedTiming"])
            self.assertEqual(meta["workloadUnitWallSource"], "trace-meta-process-wall")

    def test_invalid_plan_is_rejected_before_execution(self) -> None:
        with tempfile.TemporaryDirectory(prefix="doe-node-webgpu-executor-") as tmpdir:
            tmp = Path(tmpdir)
            plan_path = tmp / "plan.json"
            meta_path = tmp / "trace-meta.json"
            trace_path = tmp / "trace.jsonl"
            write_plan(plan_path, valid=False)

            result = subprocess.run(
                [
                    "node",
                    str(CLI_PATH),
                    "--provider",
                    "node-webgpu",
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
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("node-webgpu supervisor", result.stderr)
            self.assertTrue(meta_path.exists())
            self.assertTrue(trace_path.exists())
            meta = json.loads(meta_path.read_text(encoding="utf-8"))
            self.assertEqual(meta["executionErrorCount"], 1)
            self.assertEqual(meta["workload"], "simple_compute_roundtrip")
            self.assertEqual(trace_path.read_text(encoding="utf-8"), "")

    def test_unparseable_plan_still_emits_terminal_artifacts(self) -> None:
        with tempfile.TemporaryDirectory(prefix="doe-node-webgpu-executor-") as tmpdir:
            tmp = Path(tmpdir)
            plan_path = tmp / "bad-plan.json"
            meta_path = tmp / "trace-meta.json"
            trace_path = tmp / "trace.jsonl"
            plan_path.write_text("{ not valid json", encoding="utf-8")

            result = subprocess.run(
                [
                    "node",
                    str(CLI_PATH),
                    "--provider",
                    "node-webgpu",
                    "--plan",
                    str(plan_path),
                    "--trace-meta",
                    str(meta_path),
                    "--trace-jsonl",
                    str(trace_path),
                    "--workload",
                    "bad_plan_workload",
                ],
                cwd=REPO_ROOT,
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertTrue(meta_path.exists())
            self.assertTrue(trace_path.exists())
            meta = json.loads(meta_path.read_text(encoding="utf-8"))
            self.assertEqual(meta["executionErrorCount"], 1)
            self.assertEqual(meta["workload"], "bad_plan_workload")
            self.assertEqual(meta["executionShape"]["stepCount"], 0)
            self.assertEqual(trace_path.read_text(encoding="utf-8"), "")

    def test_cli_writes_error_meta_when_workload_id_mismatch(self) -> None:
        with tempfile.TemporaryDirectory(prefix="doe-node-webgpu-executor-") as tmpdir:
            tmp = Path(tmpdir)
            plan_path = tmp / "plan.json"
            meta_path = tmp / "trace-meta.json"
            trace_path = tmp / "trace.jsonl"
            write_plan(plan_path)

            result = subprocess.run(
                [
                    "node",
                    str(CLI_PATH),
                    "--provider",
                    "node-webgpu",
                    "--plan",
                    str(plan_path),
                    "--trace-meta",
                    str(meta_path),
                    "--trace-jsonl",
                    str(trace_path),
                    "--workload",
                    "wrong_workload_id",
                ],
                cwd=REPO_ROOT,
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertTrue(meta_path.exists())
            self.assertTrue(trace_path.exists())

            meta = json.loads(meta_path.read_text(encoding="utf-8"))
            self.assertEqual(meta["executionErrorCount"], 1)
            self.assertEqual(meta["executionUnsupportedCount"], 0)
            self.assertEqual(meta["executionRowCount"], 0)
            self.assertEqual(trace_path.read_text(encoding="utf-8"), "")

    def test_generated_command_plan_is_accepted_in_dry_run(self) -> None:
        with tempfile.TemporaryDirectory(prefix="doe-node-webgpu-executor-") as tmpdir:
            tmp = Path(tmpdir)
            plan_path = tmp / "command-plan.json"
            meta_path = tmp / "trace-meta.json"
            trace_path = tmp / "trace.jsonl"
            write_command_plan(plan_path)

            result = subprocess.run(
                [
                    "node",
                    str(CLI_PATH),
                    "--provider",
                    "node-webgpu",
                    "--plan",
                    str(plan_path),
                    "--trace-meta",
                    str(meta_path),
                    "--trace-jsonl",
                    str(trace_path),
                    "--workload",
                    "command_plan_roundtrip",
                    "--dry-run",
                ],
                cwd=REPO_ROOT,
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            meta = json.loads(meta_path.read_text(encoding="utf-8"))
            self.assertEqual(meta["executionBackend"], "node_webgpu_package")
            self.assertEqual(meta["executionRowCount"], 2)
            self.assertEqual(meta["executionDispatchCount"], 1)

    def test_generated_buffer_load_command_plan_is_accepted_in_dry_run(self) -> None:
        with tempfile.TemporaryDirectory(prefix="doe-node-webgpu-executor-") as tmpdir:
            tmp = Path(tmpdir)
            plan_path = tmp / "command-plan.json"
            meta_path = tmp / "trace-meta.json"
            trace_path = tmp / "trace.jsonl"
            write_buffer_load_command_plan(plan_path)

            result = subprocess.run(
                [
                    "node",
                    str(CLI_PATH),
                    "--provider",
                    "doe",
                    "--plan",
                    str(plan_path),
                    "--trace-meta",
                    str(meta_path),
                    "--trace-jsonl",
                    str(trace_path),
                    "--workload",
                    "buffer_load_roundtrip",
                    "--dry-run",
                ],
                cwd=REPO_ROOT,
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            meta = json.loads(meta_path.read_text(encoding="utf-8"))
            self.assertEqual(meta["executionBackend"], "doe_node_webgpu")
            self.assertEqual(meta["executionRowCount"], 2)
            self.assertEqual(meta["executionDispatchCount"], 1)

    def test_resident_buffer_load_dry_run_excludes_static_loads_from_selected_loop(self) -> None:
        with tempfile.TemporaryDirectory(prefix="doe-node-webgpu-executor-") as tmpdir:
            tmp = Path(tmpdir)
            plan_path = tmp / "command-plan.json"
            meta_path = tmp / "trace-meta.json"
            trace_path = tmp / "trace.jsonl"
            write_resident_buffer_load_command_plan(plan_path)

            result = subprocess.run(
                [
                    "node",
                    str(CLI_PATH),
                    "--provider",
                    "doe",
                    "--plan",
                    str(plan_path),
                    "--trace-meta",
                    str(meta_path),
                    "--trace-jsonl",
                    str(trace_path),
                    "--workload",
                    "resident_buffer_load_roundtrip",
                    "--dry-run",
                    "--prepared-session",
                    "--resident-buffer-loads",
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
            self.assertEqual(
                meta["packageResidentBufferLoadBreakdown"],
                {
                    "count": 0,
                    "bytes": 0,
                    "materializeTotalNs": 0,
                    "queueWriteTotalNs": 0,
                    "queueWaitTotalNs": 0,
                },
            )
            self.assertEqual(meta["executionRowCount"], 4)
            self.assertEqual(meta["executionSuccessCount"], 4)
            self.assertEqual(meta["executionDispatchCount"], 2)
            self.assertEqual([row["stepIndex"] for row in rows], [1, 2, 1, 2])
            self.assertEqual([row["stepKind"] for row in rows], ["writeBuffer", "dispatch", "writeBuffer", "dispatch"])

    def test_resident_buffer_load_mode_requires_prepared_session(self) -> None:
        with tempfile.TemporaryDirectory(prefix="doe-node-webgpu-executor-") as tmpdir:
            tmp = Path(tmpdir)
            plan_path = tmp / "command-plan.json"
            write_resident_buffer_load_command_plan(plan_path)
            script = f"""
import {{ executePlanFile }} from {json.dumps(EXECUTOR_MODULE_URL)};
try {{
  await executePlanFile({{
    planPath: {json.dumps(str(plan_path))},
    workloadId: 'resident_buffer_load_roundtrip',
    provider: 'doe',
    dryRun: true,
    preparedSession: false,
    residentBufferLoads: true,
  }});
  console.log(JSON.stringify({{ ok: true }}));
}} catch (error) {{
  console.log(JSON.stringify({{ ok: false, message: error.message }}));
}}
"""
            result = subprocess.run(
                ["node", "--input-type=module", "-e", script],
                cwd=REPO_ROOT,
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            payload = json.loads(result.stdout)
            self.assertFalse(payload["ok"])
            self.assertIn("--resident-buffer-loads requires --prepared-session", payload["message"])

    def test_materialize_buffer_data_reads_cache_backed_file_descriptor(self) -> None:
        with tempfile.TemporaryDirectory(prefix="doe-node-webgpu-assets-") as tmpdir:
            cache_dir = Path(tmpdir)
            asset_dir = cache_dir / "unit_test"
            asset_dir.mkdir(parents=True, exist_ok=True)
            (asset_dir / "alpha.bin").write_bytes(bytes([1, 2, 3, 4]))
            script = f"""
import {{ materializeBufferData }} from {json.dumps((REPO_ROOT / "bench" / "executors" / "node-webgpu" / "plan.js").resolve().as_uri())};
const descriptor = {{
  kind: 'file',
  cacheNamespace: 'unit_test',
  cacheKey: 'alpha',
  sizeBytes: 4,
}};
const first = materializeBufferData(descriptor);
const second = materializeBufferData(descriptor);
console.log(JSON.stringify({{ bytes: Array.from(first), cached: first === second }}));
"""
            env = dict(os.environ)
            env["DOE_BENCH_ASSET_CACHE_DIR"] = str(cache_dir)
            result = subprocess.run(
                ["node", "--input-type=module", "-e", script],
                cwd=REPO_ROOT,
                capture_output=True,
                text=True,
                check=False,
                env=env,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(json.loads(result.stdout), {"bytes": [1, 2, 3, 4], "cached": True})


if __name__ == "__main__":
    unittest.main()
