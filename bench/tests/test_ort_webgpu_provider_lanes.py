#!/usr/bin/env python3
"""Regression tests for the ORT WebGPU provider-compare lanes.

Consolidates the bun/node/browser same-stack compare and breadth lanes into
one file. Common fixture wiring (workload manifest, compare config,
scenario payload) lives in helper methods; lane-specific tests (bun helper
probes, node trace-artifact writer) stay on the per-lane subclasses.
"""

from __future__ import annotations

import json
import importlib.util
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from dataclasses import dataclass, field
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
BENCH_ROOT = REPO_ROOT / "bench"
for _path_entry in (str(REPO_ROOT), str(BENCH_ROOT)):
    if _path_entry not in sys.path:
        sys.path.insert(0, _path_entry)

from bench.native_compare_modules import config_support
from bench.native_compare_modules.executor_registry import (
    resolve_executor_boundary,
    resolve_executor_command_template,
)
from bench.native_compare_modules.timing_selection import classify_timing_source


BUN = shutil.which("bun")


def _bun_webgpu_unavailable_reason() -> str:
    if not BUN:
        return "bun is required for Bun ORT provider helper tests"
    script = """
try {
  const mod = await import('bun-webgpu');
  if (typeof mod.setupGlobals !== 'function') {
    throw new Error('bun-webgpu does not export setupGlobals()');
  }
  mod.setupGlobals();
  if (!globalThis.navigator?.gpu) {
    throw new Error('bun-webgpu did not install navigator.gpu');
  }
} catch (error) {
  console.error(error?.stack || String(error));
  process.exit(1);
}
"""
    result = subprocess.run(
        [BUN, "--eval", script],
        cwd=REPO_ROOT,
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode == 0:
        return ""
    lines = [
        line.strip()
        for line in (result.stderr or result.stdout).strip().splitlines()
        if line.strip()
    ]
    for line in lines:
        if "bun-webgpu is not supported" in line:
            return line
    for line in lines:
        if "Bun has crashed" in line:
            return "bun-webgpu provider probe crashed under Bun"
    for line in lines:
        if line.startswith("Error:"):
            return line
    return lines[-1] if lines else "bun-webgpu provider is unavailable"


BUN_WEBGPU_UNAVAILABLE = _bun_webgpu_unavailable_reason()


@dataclass(frozen=True)
class LaneFixture:
    workloads_path: Path
    compare_config_path: Path
    baseline_executor_id: str
    comparison_executor_id: str = ""
    comparison_name: str = ""
    expected_ids: tuple[str, ...] = ()
    claimability_mode: str = "off"
    comparison_command_template_contains: tuple[str, ...] = ()


class LaneHelpersMixin(unittest.TestCase):
    fixture: LaneFixture

    def _load_workloads(self, selector_ids: list[str]) -> list:
        return config_support.load_workloads(
            self.fixture.workloads_path,
            "",
            include_noncomparable=True,
            include_extended=False,
            workload_cohort="all",
            selector={"ids": selector_ids},
        )

    def _assert_compare_config_core(
        self, payload: dict, *, require_timing_class: str = "operation"
    ) -> None:
        baseline = payload["baseline"]
        self.assertEqual(baseline["executorId"], self.fixture.baseline_executor_id)
        comparison = payload["comparison"]
        if self.fixture.comparison_executor_id:
            self.assertEqual(comparison["executorId"], self.fixture.comparison_executor_id)
        if self.fixture.comparison_name:
            self.assertEqual(comparison["name"], self.fixture.comparison_name)
        for fragment in self.fixture.comparison_command_template_contains:
            self.assertIn(fragment, comparison["commandTemplate"])
        self.assertEqual(payload["comparability"]["mode"], "strict")
        self.assertEqual(payload["comparability"]["requireTimingClass"], require_timing_class)
        self.assertEqual(payload["claimability"]["mode"], self.fixture.claimability_mode)


class _CompareLaneBase(LaneHelpersMixin):
    """Single-workload compare lanes (bun/node provider-compare)."""

    workload_id: str
    commands_path: str
    scenario_path: Path
    scenario_module_url: str
    prefill_tokens: int
    decode_tokens: int
    min_timed_samples: int = 3

    def test_workload_manifest_loads_strict_provider_compare_lane(self) -> None:
        workloads = self._load_workloads([self.workload_id])
        self.assertEqual(len(workloads), 1)
        workload = workloads[0]
        self.assertEqual(workload.id, self.workload_id)
        self.assertTrue(workload.comparable)
        self.assertEqual(workload.benchmark_class, "comparable")
        self.assertTrue(workload.claim_eligible)
        self.assertEqual(workload.commands_path, self.commands_path)
        self.assertTrue((REPO_ROOT / workload.commands_path).exists())

    def test_compare_config_is_strict_operation_claimable(self) -> None:
        payload = json.loads(self.fixture.compare_config_path.read_text(encoding="utf-8"))
        self._assert_compare_config_core(payload)
        self.assertGreaterEqual(payload["run"]["iterations"], 7)
        self.assertEqual(payload["claimability"]["minTimedSamples"], self.min_timed_samples)
        self.assertEqual(payload["selector"]["ids"], [self.workload_id])

    def test_scenario_payload_matches_provider_compare_contract(self) -> None:
        payload = json.loads(self.scenario_path.read_text(encoding="utf-8"))
        self.assertEqual(len(payload), 1)
        scenario = payload[0]
        self.assertEqual(scenario["kind"], "vendor-node-benchmark-scenario")
        self.assertEqual(scenario["schemaVersion"], 1)
        self.assertEqual(scenario["scenarioId"], self.workload_id)
        self.assertEqual(scenario["promptWorkload"]["prefillTokens"], self.prefill_tokens)
        self.assertEqual(scenario["promptWorkload"]["decodeTokens"], self.decode_tokens)
        self.assertEqual(scenario["tjs"]["modelId"], "onnx-community/gemma-3-270m-it-ONNX")
        self.assertEqual(
            scenario["tjs"]["localModelPath"],
            "../../../doppler/node_modules/@huggingface/transformers/.cache",
        )

    def _run_scenario_loader(self) -> dict:
        script = f"""
import {{ loadVendorNodeScenario }} from {json.dumps(self.scenario_module_url)};
const scenario = await loadVendorNodeScenario({json.dumps(str(self.scenario_path))});
console.log(JSON.stringify({{
  scenarioId: scenario.scenarioId,
  cacheMode: scenario.cacheMode,
  loadMode: scenario.loadMode,
  dopplerRoot: scenario.dopplerRoot,
  tjsLocalModelPath: scenario.tjs.localModelPath,
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
        self.assertEqual(payload["scenarioId"], self.workload_id)
        self.assertEqual(payload["cacheMode"], "warm")
        self.assertEqual(payload["loadMode"], "http")
        self.assertTrue(payload["dopplerRoot"].endswith("/doppler"))
        self.assertTrue(
            payload["tjsLocalModelPath"].endswith(
                "/doppler/node_modules/@huggingface/transformers/.cache"
            )
        )
        return payload


class _BreadthLaneBase(LaneHelpersMixin):
    """Breadth lanes (bun/node provider-compare breadth)."""

    def test_workload_manifest_loads_all_breadth_ids(self) -> None:
        workloads = self._load_workloads(list(self.fixture.expected_ids))
        self.assertEqual([w.id for w in workloads], list(self.fixture.expected_ids))
        for workload in workloads:
            self.assertTrue(workload.comparable)
            self.assertTrue(workload.claim_eligible)
            self.assertTrue((REPO_ROOT / workload.commands_path).exists())

    def test_compare_config_tracks_expected_breadth_ids(self) -> None:
        payload = json.loads(self.fixture.compare_config_path.read_text(encoding="utf-8"))
        self._assert_compare_config_core(payload)
        self.assertGreaterEqual(payload["run"]["iterations"], 7)
        self.assertEqual(payload["selector"]["ids"], list(self.fixture.expected_ids))


# === Bun compare lane ===


_BUN_SHARED_MODULE_URL = (
    REPO_ROOT / "bench" / "executors" / "vendor-node" / "shared.js"
).resolve().as_uri()
_NODE_SHARED_MODULE_URL = _BUN_SHARED_MODULE_URL


class BunOrtWebGpuProviderCompareLaneTests(_CompareLaneBase):
    workload_id = "bun_ort_webgpu_provider_compare_gemma3_270m_prefill_32tok_decode_1tok"
    commands_path = (
        "bench/vendor-bun/ort_webgpu_provider_compare_gemma270m_prefill32_decode1_commands.json"
    )
    scenario_path = REPO_ROOT / "bench" / "vendor-bun" / (
        "ort_webgpu_provider_compare_gemma270m_prefill32_decode1_commands.json"
    )
    scenario_module_url = (
        REPO_ROOT / "bench" / "executors" / "vendor-node" / "scenario.js"
    ).resolve().as_uri()
    prefill_tokens = 32
    decode_tokens = 1
    fixture = LaneFixture(
        workloads_path=REPO_ROOT
        / "bench"
        / "workloads"
        / "workloads.bun.ort-webgpu-provider-compare.json",
        compare_config_path=REPO_ROOT
        / "bench"
        / "native-compare"
        / "compare.config.bun.ort-webgpu-provider.gemma270m.prefill32.decode1.json",
        baseline_executor_id="tjs_ort_bun_doe",
        comparison_executor_id="tjs_ort_bun_webgpu_package",
        claimability_mode="local",
    )

    def test_node_scenario_loader_resolves_bun_provider_compare_fields(self) -> None:
        self._run_scenario_loader()

    @unittest.skipIf(BUN_WEBGPU_UNAVAILABLE, BUN_WEBGPU_UNAVAILABLE)
    def test_bun_provider_helper_supports_doe_and_bun_webgpu(self) -> None:
        script = f"""
import {{ installTjsOrtWebGpuProvider }} from {json.dumps(_BUN_SHARED_MODULE_URL)};
const doeProvider = await installTjsOrtWebGpuProvider('doe', 'bun');
const bunProvider = await installTjsOrtWebGpuProvider('bun-webgpu', 'bun');
console.log(JSON.stringify({{
  doeBackend: doeProvider.executionBackend,
  bunBackend: bunProvider.executionBackend,
  doeProviderName: doeProvider.providerName,
  bunProviderName: bunProvider.providerName,
  platform: process.platform,
  bunBackendType: bunProvider.adapterRequestOptions.backendType ?? null,
  hasBunBackendType: Object.prototype.hasOwnProperty.call(
    bunProvider.adapterRequestOptions,
    'backendType',
  ),
  bunForceFallbackAdapter: bunProvider.adapterRequestOptions.forceFallbackAdapter,
  hasDoeGpu: !!doeProvider.gpu,
  hasBunGpu: !!bunProvider.gpu,
}}));
"""
        env = dict(os.environ)
        env["DOE_WEBGPU_LIB"] = str(
            REPO_ROOT / "runtime" / "zig" / "zig-out" / "lib" / "libwebgpu_doe.so"
        )
        result = subprocess.run(
            [BUN, "--eval", script],
            cwd=REPO_ROOT,
            env=env,
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads(result.stdout)
        self.assertEqual(payload["doeBackend"], "tjs_ort_bun_webgpu")
        self.assertEqual(payload["bunBackend"], "tjs_ort_bun_webgpu_package")
        self.assertEqual(payload["doeProviderName"], "doe-gpu")
        self.assertEqual(payload["bunProviderName"], "bun-webgpu")
        expected_backend_type = None if payload["platform"] == "darwin" else 6
        self.assertEqual(payload["bunBackendType"], expected_backend_type)
        self.assertEqual(payload["hasBunBackendType"], expected_backend_type is not None)
        self.assertFalse(payload["bunForceFallbackAdapter"])
        self.assertTrue(payload["hasDoeGpu"])
        self.assertTrue(payload["hasBunGpu"])

    @unittest.skipIf(BUN_WEBGPU_UNAVAILABLE, BUN_WEBGPU_UNAVAILABLE)
    def test_bun_provider_helper_allows_backend_type_override_to_default(self) -> None:
        script = f"""
import {{ installTjsOrtWebGpuProvider }} from {json.dumps(_BUN_SHARED_MODULE_URL)};
const bunProvider = await installTjsOrtWebGpuProvider('bun-webgpu', 'bun');
console.log(JSON.stringify({{
  hasBackendType: Object.prototype.hasOwnProperty.call(
    bunProvider.adapterRequestOptions,
    'backendType',
  ),
  backendType: bunProvider.adapterRequestOptions.backendType ?? null,
}}));
"""
        env = dict(os.environ)
        env["DOE_WEBGPU_LIB"] = str(
            REPO_ROOT / "runtime" / "zig" / "zig-out" / "lib" / "libwebgpu_doe.so"
        )
        env["DOE_BUN_WEBGPU_BACKEND_TYPE"] = "default"
        result = subprocess.run(
            [BUN, "--eval", script],
            cwd=REPO_ROOT,
            env=env,
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads(result.stdout)
        self.assertFalse(payload["hasBackendType"])
        self.assertIsNone(payload["backendType"])


# === Node compare lane ===


_NODE_TRACE_ARTIFACT_MODULE_URL = (
    REPO_ROOT / "bench" / "executors" / "vendor-node" / "trace-artifact.js"
).resolve().as_uri()


class NodeOrtWebGpuProviderCompareLaneTests(_CompareLaneBase):
    workload_id = "node_ort_webgpu_provider_compare_gemma3_270m_prefill_64tok_decode_64tok"
    commands_path = "bench/vendor-node/ort_webgpu_provider_compare_gemma270m_commands.json"
    scenario_path = REPO_ROOT / "bench" / "vendor-node" / (
        "ort_webgpu_provider_compare_gemma270m_commands.json"
    )
    scenario_module_url = (
        REPO_ROOT / "bench" / "executors" / "vendor-node" / "scenario.js"
    ).resolve().as_uri()
    prefill_tokens = 64
    decode_tokens = 64
    fixture = LaneFixture(
        workloads_path=REPO_ROOT
        / "bench"
        / "workloads"
        / "workloads.node.ort-webgpu-provider-compare.json",
        compare_config_path=REPO_ROOT
        / "bench"
        / "native-compare"
        / "compare.config.node.ort-webgpu-provider.gemma270m.json",
        baseline_executor_id="tjs_ort_node_doe",
        comparison_name="tjs_ort_node_webgpu_package",
        claimability_mode="local",
        comparison_command_template_contains=(
            "DOE_NODE_WEBGPU_ADAPTER='Radeon 8060S Graphics (RADV STRIX_HALO)'",
            "run-node-tjs-ort-webgpu.js",
        ),
    )

    def test_scenario_payload_matches_provider_compare_contract(self) -> None:
        super().test_scenario_payload_matches_provider_compare_contract()
        payload = json.loads(self.scenario_path.read_text(encoding="utf-8"))
        scenario = payload[0]
        self.assertEqual(
            scenario["doppler"]["modelPath"],
            "../../../doppler/models/local/gemma-3-270m-it-q4k-ehf16-af32",
        )

    def test_node_scenario_loader_resolves_provider_compare_fields(self) -> None:
        self._run_scenario_loader()

    def test_webgpu_execution_counter_helper_records_dispatch_and_submit_counts(self) -> None:
        script = f"""
import {{ installWebGpuExecutionCounters }} from {json.dumps(_NODE_SHARED_MODULE_URL)};

class GPUComputePassEncoder {{
  dispatchWorkgroups() {{
    return 'dispatch';
  }}
  dispatchWorkgroupsIndirect() {{
    return 'dispatch-indirect';
  }}
}}

class GPUQueue {{
  submit() {{
    return 'submit';
  }}
}}

globalThis.GPUComputePassEncoder = GPUComputePassEncoder;
globalThis.GPUQueue = GPUQueue;

const queue = new GPUQueue();
const counters = installWebGpuExecutionCounters({{ queue }});
const pass = new GPUComputePassEncoder();
pass.dispatchWorkgroups(1, 1, 1);
pass.dispatchWorkgroupsIndirect({{}}, 0);
queue.submit([]);
const first = counters.snapshot();
counters.reset();
const second = counters.snapshot();
console.log(JSON.stringify({{ first, second }}));
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
        first = payload["first"]
        second = payload["second"]
        self.assertTrue(first["vendorNodeWebgpuCounterPatches"]["dispatchWorkgroups"])
        self.assertTrue(first["vendorNodeWebgpuCounterPatches"]["dispatchWorkgroupsIndirect"])
        self.assertTrue(first["vendorNodeWebgpuCounterPatches"]["queueSubmit"])
        self.assertEqual(first["executionDispatchCount"], 2)
        self.assertEqual(first["executionSubmitCount"], 1)
        self.assertNotIn("executionDispatchCount", second)
        self.assertNotIn("executionSubmitCount", second)

    def test_ort_profile_summary_uses_webgpu_node_count_as_dispatch_evidence(self) -> None:
        with tempfile.TemporaryDirectory(prefix="doe-node-ort-profile-evidence-") as tmpdir:
            trace_meta_path = Path(tmpdir) / "sample.meta.json"
            script = f"""
import {{ writeFile }} from 'node:fs/promises';
import {{ resolve }} from 'node:path';
import {{
  collectOrtProfileSummary,
  createOrtProfileContext,
}} from {json.dumps(_NODE_SHARED_MODULE_URL)};

const context = await createOrtProfileContext({json.dumps(str(trace_meta_path))}, 'node-webgpu-ort');
await writeFile(resolve(context.profileDir, 'node-webgpu-ort_2026-01-01.json'), JSON.stringify([
  {{ cat: 'Session', name: 'session_initialization', args: {{}} }},
  {{ cat: 'Node', name: 'matmul_kernel_time', args: {{ provider: 'WebGpuExecutionProvider', op_name: 'MatMul' }} }},
  {{ cat: 'Node', name: 'cast_kernel_time', args: {{ provider: 'WebGpuExecutionProvider', op_name: 'Cast' }} }},
  {{ cat: 'Node', name: 'shape_kernel_time', args: {{ provider: 'CPUExecutionProvider', op_name: 'Shape' }} }}
]));
let ended = 0;
const summary = await collectOrtProfileSummary(
  {{ model: {{ sessions: {{ model: {{ endProfiling() {{ ended += 1; }} }} }} }} }},
  context,
);
console.log(JSON.stringify({{ ended, summary }}));
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
        summary = payload["summary"]
        self.assertEqual(payload["ended"], 1)
        self.assertTrue(summary["ortProfileEnabled"])
        self.assertEqual(summary["ortProfileFileCount"], 1)
        self.assertEqual(summary["ortProfileNodeCount"], 3)
        self.assertEqual(summary["ortProfileWebGpuNodeCount"], 2)
        self.assertEqual(summary["ortProfileCpuNodeCount"], 1)
        self.assertEqual(summary["executionDispatchCount"], 2)
        self.assertEqual(summary["executionDispatchEvidenceSource"], "ort-profile-webgpu-node-count")
        self.assertEqual(summary["ortProfileProviderCounts"]["WebGpuExecutionProvider"], 2)
        self.assertEqual(summary["ortProfileWebGpuTopOps"][0]["name"], "Cast")

    def test_trace_artifact_writer_emits_custom_provider_compare_metadata(self) -> None:
        with tempfile.TemporaryDirectory(prefix="doe-node-ort-webgpu-provider-compare-") as tmpdir:
            tmp = Path(tmpdir)
            meta_path = tmp / "trace.meta.json"
            jsonl_path = tmp / "trace.ndjson"
            script = f"""
import {{ readFile }} from 'node:fs/promises';
import {{
  writeVendorNodeSuccessTrace,
  writeVendorNodeFailureTrace,
}} from {json.dumps(_NODE_TRACE_ARTIFACT_MODULE_URL)};

const traceMetaPath = {json.dumps(str(meta_path))};
const traceJsonlPath = {json.dumps(str(jsonl_path))};
await writeVendorNodeSuccessTrace({{
  runtimeHost: 'bun',
  traceMetaPath,
  traceJsonlPath,
  benchmarkLane: 'node-ort-webgpu-provider-compare',
  workloadId: {json.dumps(self.workload_id)},
  scenarioId: {json.dumps(self.workload_id)},
  executionBackend: 'tjs_ort_node_webgpu',
  executionLabel: 'Transformers.js ORT node WebGPU on doe-gpu',
  executionProvider: 'doe',
  executionProviderName: 'doe-gpu',
  processWallMs: 42.5,
  timingMs: 20.5,
  timingSource: 'tjs-ort-generation-ms',
  timingClass: 'operation',
  adapterInfo: {{ vendor: 'AMD', architecture: 'gfx11', device: 'mock', description: '', subgroupMinSize: 32, subgroupMaxSize: 64 }},
  phaseTimingsMs: {{ promptSynthesisMs: 10, pipelineLoadMs: 12, generationMs: 20.5 }},
  promptSummary: {{ promptSource: 'synthetic', promptLength: 512, prefillTokens: 64, decodeTokens: 64 }},
  resultSummary: {{ generatedTextLength: 64, generatedTextPreview: 'alpha' }},
  extraMeta: {{ vendorStack: 'transformers.js+onnxruntime-node' }},
}});
const successMeta = JSON.parse(await readFile(traceMetaPath, 'utf8'));
const successRows = (await readFile(traceJsonlPath, 'utf8')).trim().split('\\n').map((line) => JSON.parse(line));

await writeVendorNodeFailureTrace({{
  runtimeHost: 'bun',
  traceMetaPath,
  traceJsonlPath,
  benchmarkLane: 'node-ort-webgpu-provider-compare',
  workloadId: {json.dumps(self.workload_id)},
  scenarioId: {json.dumps(self.workload_id)},
  executionBackend: 'tjs_ort_node_webgpu_package',
  executionLabel: 'Transformers.js ORT node WebGPU on node-webgpu',
  executionProvider: 'node-webgpu',
  executionProviderName: 'node-webgpu',
  processWallMs: 11.25,
  errorMessage: 'node-webgpu adapter unavailable',
}});
const failureMeta = JSON.parse(await readFile(traceMetaPath, 'utf8'));
const failureRows = (await readFile(traceJsonlPath, 'utf8')).trim().split('\\n').map((line) => JSON.parse(line));

console.log(JSON.stringify({{
  successMeta,
  successRows,
  failureMeta,
  failureRows,
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
            success_meta = payload["successMeta"]
            success_row = payload["successRows"][0]
            failure_meta = payload["failureMeta"]
            failure_row = payload["failureRows"][0]

        self.assertEqual(success_meta["benchmarkLane"], "node-ort-webgpu-provider-compare")
        self.assertEqual(success_meta["runtimeHost"], "bun")
        self.assertEqual(success_meta["executionProvider"], "doe")
        self.assertEqual(success_meta["executionProviderName"], "doe-gpu")
        self.assertEqual(success_meta["executionSuccessCount"], 1)
        self.assertEqual(success_meta["executionErrorCount"], 0)
        self.assertEqual(success_meta["timingMs"], 20.5)
        self.assertEqual(success_meta["timingSource"], "tjs-ort-generation-ms")
        self.assertEqual(success_meta["timingClass"], "operation")
        self.assertEqual(success_meta["phaseTimingsMs"]["generationMs"], 20.5)
        self.assertEqual(success_row["timingMs"], 20.5)
        self.assertEqual(success_row["timingSource"], "tjs-ort-generation-ms")
        self.assertEqual(success_row["timingClass"], "operation")
        self.assertEqual(success_row["status"], "success")

        self.assertEqual(failure_meta["benchmarkLane"], "node-ort-webgpu-provider-compare")
        self.assertEqual(failure_meta["runtimeHost"], "bun")
        self.assertEqual(failure_meta["executionProvider"], "node-webgpu")
        self.assertEqual(failure_meta["executionProviderName"], "node-webgpu")
        self.assertEqual(failure_meta["executionSuccessCount"], 0)
        self.assertEqual(failure_meta["executionErrorCount"], 1)
        self.assertEqual(failure_row["status"], "error")
        self.assertIn("adapter unavailable", failure_row["errorMessage"])


# === Breadth lanes ===


class BunOrtWebGpuProviderBreadthLaneTests(_BreadthLaneBase):
    fixture = LaneFixture(
        workloads_path=REPO_ROOT
        / "bench"
        / "workloads"
        / "workloads.bun.ort-webgpu-provider-compare.json",
        compare_config_path=REPO_ROOT
        / "bench"
        / "native-compare"
        / "compare.config.bun.ort-webgpu-provider.breadth.json",
        baseline_executor_id="tjs_ort_bun_doe",
        comparison_executor_id="tjs_ort_bun_webgpu_package",
        expected_ids=(
            "bun_ort_webgpu_provider_compare_gemma3_270m_prefill_32tok_decode_1tok",
            "bun_ort_webgpu_provider_compare_gemma3_270m_prefill_256tok_decode_1tok",
        ),
        claimability_mode="off",
    )


class NodeOrtWebGpuProviderBreadthLaneTests(_BreadthLaneBase):
    fixture = LaneFixture(
        workloads_path=REPO_ROOT
        / "bench"
        / "workloads"
        / "workloads.node.ort-webgpu-provider-compare.breadth.json",
        compare_config_path=REPO_ROOT
        / "bench"
        / "native-compare"
        / "compare.config.node.ort-webgpu-provider.breadth.json",
        baseline_executor_id="tjs_ort_node_doe",
        comparison_name="tjs_ort_node_webgpu_package",
        expected_ids=(
            "node_ort_webgpu_provider_compare_gemma3_270m_prefill_64tok_decode_64tok",
            "node_ort_webgpu_provider_compare_gemma3_270m_prefill_32tok_decode_1tok",
            "node_ort_webgpu_provider_compare_gemma3_270m_prefill_256tok_decode_1tok",
            "node_ort_webgpu_provider_compare_gemma3_270m_prefill_32tok_decode_128tok",
            "node_ort_webgpu_provider_compare_gemma3_1b_prefill_32tok_decode_1tok",
        ),
        claimability_mode="off",
        comparison_command_template_contains=(
            "DOE_NODE_WEBGPU_ADAPTER='Radeon 8060S Graphics (RADV STRIX_HALO)'",
        ),
    )


# === Browser compare lane ===


class BrowserOrtWebGpuCompareLaneTests(_BreadthLaneBase):
    fixture = LaneFixture(
        workloads_path=REPO_ROOT
        / "bench"
        / "workloads"
        / "workloads.browser.ort-webgpu-compare.json",
        compare_config_path=REPO_ROOT
        / "bench"
        / "native-compare"
        / "compare.config.browser.ort-webgpu.json",
        baseline_executor_id="browser_ort_webgpu_dawn",
        comparison_executor_id="browser_ort_webgpu_doe",
        expected_ids=(
            "browser_ort_webgpu_compare_sentiment",
            "browser_ort_webgpu_compare_sentiment_medium",
            "browser_ort_webgpu_compare_sentiment_longform",
        ),
        claimability_mode="off",
    )

    def test_workload_manifest_loads_all_breadth_ids(self) -> None:
        workloads = self._load_workloads(list(self.fixture.expected_ids))
        self.assertEqual([w.id for w in workloads], list(self.fixture.expected_ids))
        for workload in workloads:
            self.assertTrue(workload.comparable)
            self.assertFalse(workload.claim_eligible)
            self.assertTrue((REPO_ROOT / workload.commands_path).exists())
            scenario = json.loads((REPO_ROOT / workload.commands_path).read_text(encoding="utf-8"))[0]
            self.assertGreaterEqual(scenario["timedIters"], 20)
            self.assertGreaterEqual(scenario["warmupIters"], 5)

    def test_compare_config_tracks_expected_breadth_ids(self) -> None:
        payload = json.loads(self.fixture.compare_config_path.read_text(encoding="utf-8"))
        self._assert_compare_config_core(payload, require_timing_class="operation")
        self.assertGreaterEqual(payload["run"]["iterations"], 7)
        self.assertEqual(payload["selector"]["ids"], list(self.fixture.expected_ids))

    def test_executor_registry_resolves_browser_compare_executors(self) -> None:
        dawn_template = resolve_executor_command_template("browser_ort_webgpu_dawn")
        doe_template = resolve_executor_command_template("browser_ort_webgpu_doe")
        self.assertIn("run-browser-ort-bench.py", dawn_template)
        self.assertIn("--mode dawn", dawn_template)
        self.assertIn("--mode doe", doe_template)
        self.assertEqual(resolve_executor_boundary("browser_ort_webgpu_dawn"), "commands")
        self.assertEqual(resolve_executor_boundary("browser_ort_webgpu_doe"), "commands")

    def test_browser_ort_timed_mean_is_operation_timing(self) -> None:
        self.assertEqual(classify_timing_source("browser-ort-timed-mean-ms"), "operation")
        self.assertEqual(classify_timing_source("tjs-ort-generation-ms"), "operation")
        executor_path = REPO_ROOT / "bench" / "executors" / "run-browser-ort-bench.py"
        spec = importlib.util.spec_from_file_location("run_browser_ort_bench", executor_path)
        self.assertIsNotNone(spec)
        module = importlib.util.module_from_spec(spec)
        assert spec is not None and spec.loader is not None
        spec.loader.exec_module(module)

        trace_meta = module._trace_meta(
            workload_id="browser_ort_webgpu_compare_sentiment",
            scenario={"scenarioId": "browser_ort_webgpu_compare_sentiment", "task": "sentiment"},
            mode="doe",
            mode_report={
                "success": True,
                "timedMeanMs": 12.5,
                "timedIterationsMs": [12.0, 12.5, 13.0],
                "elapsedMs": 1500,
                "webgpuDispatchCount": 10,
                "webgpuQueueSubmitCount": 4,
            },
            report={"taskConfig": {"model": "distilbert"}},
        )
        self.assertEqual(trace_meta["timingSource"], "browser-ort-timed-mean-ms")
        self.assertEqual(trace_meta["timingClass"], "operation")
        self.assertEqual(trace_meta["timingMs"], 12.5)
        self.assertEqual(trace_meta["browserOrtTimedMeanMs"], 12.5)
        self.assertEqual(trace_meta["processWallMs"], 1500)
        self.assertEqual(trace_meta["executionDispatchCount"], 10)
        self.assertEqual(trace_meta["executionSubmitCount"], 4)


# Guard against unittest discovering the abstract base classes as test cases.
del _CompareLaneBase
del _BreadthLaneBase
del LaneHelpersMixin


if __name__ == "__main__":
    unittest.main()
