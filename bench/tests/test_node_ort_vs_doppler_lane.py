#!/usr/bin/env python3
"""Regression tests for the repo-only Node ORT-vs-Doppler lane."""

from __future__ import annotations

import json
import hashlib
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
BENCH_ROOT = REPO_ROOT / 'bench'
for _path_entry in (str(REPO_ROOT), str(BENCH_ROOT)):
    if _path_entry not in sys.path:
        sys.path.insert(0, _path_entry)

from bench.native_compare_modules import config_support


WORKLOAD_ID = 'node_ort_vs_doppler_gemma3_270m_prefill_64tok_decode_64tok'
WORKLOADS_PATH = REPO_ROOT / 'bench' / 'workloads' / 'workloads.node.ort-vs-doppler.json'
COMPARE_CONFIG_PATH = (
    REPO_ROOT / 'bench' / 'native-compare' / 'compare.config.node.ort-vs-doppler.gemma270m.json'
)
SCENARIO_PATH = REPO_ROOT / 'bench' / 'vendor-node' / 'ort_doe_vs_doppler_gemma270m_commands.json'
SCENARIO_MODULE_URL = (
    REPO_ROOT / 'bench' / 'executors' / 'vendor-node' / 'scenario.js'
).resolve().as_uri()
TRACE_ARTIFACT_MODULE_URL = (
    REPO_ROOT / 'bench' / 'executors' / 'vendor-node' / 'trace-artifact.js'
).resolve().as_uri()
SHARED_MODULE_URL = (
    REPO_ROOT / 'bench' / 'executors' / 'vendor-node' / 'shared.js'
).resolve().as_uri()
DOPPLER_PROVIDER_WORKLOAD_ID = (
    'doppler_provider_compare_gemma3_270m_prefill_64tok_decode_64tok'
)
DOPPLER_PROVIDER_WORKLOADS_PATH = (
    REPO_ROOT / 'bench' / 'workloads' / 'workloads.node.doppler-provider-compare.json'
)
DOPPLER_PROVIDER_COMPARE_CONFIG_PATH = (
    REPO_ROOT / 'bench' / 'native-compare' /
    'compare.config.node.doppler-provider.gemma270m.json'
)
DOPPLER_PROVIDER_SCENARIO_PATH = (
    REPO_ROOT / 'bench' / 'vendor-node' / 'doppler_provider_compare_gemma270m_commands.json'
)
DOPPLER_PROVIDER_DIAGNOSTIC_SCENARIO_PATH = (
    REPO_ROOT / 'bench' / 'vendor-node' /
    'doppler_provider_diagnostic_gemma270m_commands.json'
)
DOPPLER_PROVIDER_RUNNER_PATH = (
    REPO_ROOT / 'bench' / 'executors' / 'run-node-doppler-ort-bench.js'
)


class NodeOrtVsDopplerLaneTests(unittest.TestCase):
    def test_doppler_provider_workload_is_diagnostic_and_comparable(self) -> None:
        workloads = config_support.load_workloads(
            DOPPLER_PROVIDER_WORKLOADS_PATH,
            '',
            include_noncomparable=True,
            include_extended=False,
            workload_cohort='all',
            selector={'ids': [DOPPLER_PROVIDER_WORKLOAD_ID]},
        )
        self.assertEqual(len(workloads), 1)
        workload = workloads[0]
        self.assertTrue(workload.comparable)
        self.assertEqual(workload.benchmark_class, 'comparable')
        self.assertFalse(workload.claim_eligible)
        self.assertEqual(
            workload.commands_path,
            'bench/vendor-node/doppler_provider_compare_gemma270m_commands.json',
        )

    def test_doppler_provider_compare_config_is_strict_but_not_claimable(self) -> None:
        payload = json.loads(
            DOPPLER_PROVIDER_COMPARE_CONFIG_PATH.read_text(encoding='utf-8')
        )
        self.assertEqual(payload['baseline']['executorId'], 'doppler_node_doe')
        self.assertEqual(payload['comparison']['executorId'], 'doppler_node_webgpu')
        self.assertEqual(payload['comparability']['mode'], 'strict')
        self.assertEqual(payload['comparability']['requireTimingClass'], 'process-wall')
        self.assertEqual(payload['claimability']['mode'], 'off')
        self.assertEqual(payload['selector']['ids'], [DOPPLER_PROVIDER_WORKLOAD_ID])

    def test_doppler_provider_scenario_declares_owned_lane(self) -> None:
        payload = json.loads(DOPPLER_PROVIDER_SCENARIO_PATH.read_text(encoding='utf-8'))
        self.assertEqual(len(payload), 1)
        scenario = payload[0]
        self.assertEqual(scenario['scenarioId'], DOPPLER_PROVIDER_WORKLOAD_ID)
        self.assertEqual(scenario['benchmarkLane'], 'doppler-node-provider-compare')
        self.assertEqual(scenario['promptWorkload']['prefillTokens'], 64)
        self.assertEqual(scenario['promptWorkload']['decodeTokens'], 64)
        self.assertEqual(
            scenario['doppler']['modelId'],
            'gemma-3-270m-it-q4k-ehf16-af32',
        )

    def test_doppler_provider_diagnostic_is_bounded_and_separate(self) -> None:
        payload = json.loads(
            DOPPLER_PROVIDER_DIAGNOSTIC_SCENARIO_PATH.read_text(encoding='utf-8')
        )
        self.assertEqual(len(payload), 1)
        scenario = payload[0]
        self.assertEqual(
            scenario['scenarioId'],
            'doppler_provider_diagnostic_gemma3_270m_prefill_64tok_decode_1tok',
        )
        self.assertEqual(scenario['benchmarkLane'], 'doppler-node-provider-diagnostic')
        self.assertEqual(scenario['promptWorkload']['decodeTokens'], 1)
        self.assertEqual(
            scenario['doppler']['runtimeConfig']['shared']['benchmark']['run'],
            {'warmupRuns': 0, 'timedRuns': 1},
        )

    def test_doppler_provider_persists_inference_before_native_release(self) -> None:
        source = DOPPLER_PROVIDER_RUNNER_PATH.read_text(encoding='utf-8')
        provisional = source.index(
            "lifecycleEvidenceState: 'inference-complete-release-pending'"
        )
        release = source.index('const providerRelease = typeof releaseProvider')
        terminal = source.index("lifecycleEvidenceState: 'release-complete'")
        self.assertLess(provisional, release)
        self.assertLess(release, terminal)

    def test_doppler_summary_hashes_exact_generated_text(self) -> None:
        script = f"""
import {{ summarizeDopplerEnvelope }} from {json.dumps(SHARED_MODULE_URL)};
console.log(JSON.stringify(summarizeDopplerEnvelope({{
  ok: true,
  result: {{ output: 'hello' }},
}})));
"""
        result = subprocess.run(
            ['node', '--input-type=module', '-e', script],
            cwd=REPO_ROOT,
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads(result.stdout)
        self.assertEqual(payload['status'], 'ok')
        self.assertEqual(payload['outputSource'], 'result.output')
        self.assertEqual(payload['generatedTextLength'], 5)
        self.assertEqual(
            payload['generatedTextSha256'],
            hashlib.sha256(b'hello').hexdigest(),
        )

    def test_workload_manifest_loads_directional_lane(self) -> None:
        workloads = config_support.load_workloads(
            WORKLOADS_PATH,
            '',
            include_noncomparable=True,
            include_extended=False,
            workload_cohort='all',
            selector={'ids': [WORKLOAD_ID]},
        )
        self.assertEqual(len(workloads), 1)
        workload = workloads[0]
        self.assertEqual(workload.id, WORKLOAD_ID)
        self.assertFalse(workload.comparable)
        self.assertEqual(workload.benchmark_class, 'directional')
        self.assertEqual(workload.directional_reason, 'methodology_gap')
        self.assertFalse(workload.claim_eligible)
        self.assertEqual(workload.commands_path, 'bench/vendor-node/ort_doe_vs_doppler_gemma270m_commands.json')
        self.assertTrue((REPO_ROOT / workload.commands_path).exists())

    def test_compare_config_is_process_wall_directional(self) -> None:
        payload = json.loads(COMPARE_CONFIG_PATH.read_text(encoding='utf-8'))
        self.assertEqual(payload['baseline']['executorId'], 'tjs_ort_node_doe')
        self.assertEqual(payload['comparison']['executorId'], 'doppler_node_doe')
        self.assertEqual(payload['comparability']['mode'], 'off')
        self.assertEqual(payload['comparability']['requireTimingClass'], 'process-wall')
        self.assertEqual(payload['claimability']['mode'], 'off')
        self.assertEqual(payload['selector']['ids'], [WORKLOAD_ID])

    def test_scenario_payload_matches_lane_contract(self) -> None:
        payload = json.loads(SCENARIO_PATH.read_text(encoding='utf-8'))
        self.assertEqual(len(payload), 1)
        scenario = payload[0]
        self.assertEqual(scenario['kind'], 'vendor-node-benchmark-scenario')
        self.assertEqual(scenario['schemaVersion'], 1)
        self.assertEqual(scenario['scenarioId'], WORKLOAD_ID)
        self.assertEqual(scenario['promptWorkload']['prefillTokens'], 64)
        self.assertEqual(scenario['promptWorkload']['decodeTokens'], 64)
        self.assertEqual(scenario['tjs']['modelId'], 'onnx-community/gemma-3-270m-it-ONNX')
        self.assertEqual(scenario['doppler']['modelId'], 'gemma-3-270m-it-q4k-ehf16-af32')
        self.assertEqual(scenario['doppler']['loadMode'], 'http')
        self.assertEqual(
            scenario['doppler']['modelPath'],
            '../../../doppler/models/local/gemma-3-270m-it-q4k-ehf16-af32',
        )

    def test_node_scenario_loader_resolves_doppler_fields(self) -> None:
        script = f"""
import {{ loadVendorNodeScenario }} from {json.dumps(SCENARIO_MODULE_URL)};
const scenario = await loadVendorNodeScenario({json.dumps(str(SCENARIO_PATH))});
console.log(JSON.stringify({{
  scenarioId: scenario.scenarioId,
  cacheMode: scenario.cacheMode,
  loadMode: scenario.loadMode,
  tjsLocalModelPath: scenario.tjs.localModelPath,
  dopplerLoadMode: scenario.doppler.loadMode,
  dopplerModelPath: scenario.doppler.modelPath,
  runtimeProfile: scenario.doppler.runtimeProfile,
}}));
"""
        result = subprocess.run(
            ['node', '--input-type=module', '-e', script],
            cwd=REPO_ROOT,
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads(result.stdout)
        self.assertEqual(payload['scenarioId'], WORKLOAD_ID)
        self.assertEqual(payload['cacheMode'], 'warm')
        self.assertEqual(payload['loadMode'], 'http')
        self.assertTrue(payload['tjsLocalModelPath'].endswith(
            '/doppler/node_modules/@huggingface/transformers/.cache'
        ))
        self.assertEqual(payload['dopplerLoadMode'], 'http')
        self.assertTrue(payload['dopplerModelPath'].endswith(
            '/doppler/models/local/gemma-3-270m-it-q4k-ehf16-af32'
        ))
        self.assertIsNone(payload['runtimeProfile'])

    def test_trace_artifact_writer_emits_vendor_node_lane_contract(self) -> None:
        with tempfile.TemporaryDirectory(prefix='doe-node-ort-vs-doppler-') as tmpdir:
            tmp = Path(tmpdir)
            meta_path = tmp / 'trace.meta.json'
            jsonl_path = tmp / 'trace.ndjson'
            script = f"""
import {{ readFile }} from 'node:fs/promises';
import {{
  writeVendorNodeSuccessTrace,
  writeVendorNodeFailureTrace,
}} from {json.dumps(TRACE_ARTIFACT_MODULE_URL)};

const traceMetaPath = {json.dumps(str(meta_path))};
const traceJsonlPath = {json.dumps(str(jsonl_path))};
await writeVendorNodeSuccessTrace({{
  traceMetaPath,
  traceJsonlPath,
  workloadId: {json.dumps(WORKLOAD_ID)},
  scenarioId: {json.dumps(WORKLOAD_ID)},
  executionBackend: 'tjs_ort_node_webgpu',
  executionLabel: 'Transformers.js ORT lane',
  processWallMs: 42.5,
  adapterInfo: {{ vendor: 'AMD', architecture: 'gfx11', device: 'mock', description: '', subgroupMinSize: 32, subgroupMaxSize: 64 }},
  phaseTimingsMs: {{ promptSynthesisMs: 10, pipelineLoadMs: 12, generationMs: 20.5 }},
  promptSummary: {{ promptSource: 'synthetic', promptLength: 512, prefillTokens: 64, decodeTokens: 64 }},
  resultSummary: {{ generatedTextLength: 64, generatedTextPreview: 'alpha' }},
  extraMeta: {{ vendorStack: 'transformers.js+onnxruntime-node' }},
}});
const successMeta = JSON.parse(await readFile(traceMetaPath, 'utf8'));
const successRows = (await readFile(traceJsonlPath, 'utf8')).trim().split('\\n').map((line) => JSON.parse(line));

await writeVendorNodeFailureTrace({{
  traceMetaPath,
  traceJsonlPath,
  workloadId: {json.dumps(WORKLOAD_ID)},
  scenarioId: {json.dumps(WORKLOAD_ID)},
  executionBackend: 'doppler_node_webgpu',
  executionLabel: 'Doppler lane',
  processWallMs: 11.25,
  errorMessage: '[Embed] GPU embeddings required for gather path.',
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
                ['node', '--input-type=module', '-e', script],
                cwd=REPO_ROOT,
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            payload = json.loads(result.stdout)
            success_meta = payload['successMeta']
            success_row = payload['successRows'][0]
            failure_meta = payload['failureMeta']
            failure_row = payload['failureRows'][0]

        self.assertEqual(success_meta['benchmarkLane'], 'node-ort-vs-doppler')
        self.assertEqual(success_meta['executionProviderName'], 'doe-gpu')
        self.assertEqual(success_meta['executionSuccessCount'], 1)
        self.assertEqual(success_meta['executionErrorCount'], 0)
        self.assertEqual(success_meta['timingSource'], 'wall-time')
        self.assertEqual(success_meta['workloadUnitWallSource'], 'trace-meta-process-wall')
        self.assertEqual(success_meta['phaseTimingsMs']['generationMs'], 20.5)
        self.assertEqual(success_meta['promptSummary']['prefillTokens'], 64)
        self.assertEqual(success_meta['resultSummary']['generatedTextPreview'], 'alpha')
        self.assertEqual(success_row['traceFormat'], 'vendor-node-benchmark-v1')
        self.assertEqual(success_row['workloadUnitWallSource'], 'trace-meta-process-wall')
        self.assertEqual(success_row['status'], 'success')

        self.assertEqual(failure_meta['benchmarkLane'], 'node-ort-vs-doppler')
        self.assertEqual(failure_meta['executionSuccessCount'], 0)
        self.assertEqual(failure_meta['executionErrorCount'], 1)
        self.assertTrue(failure_meta['terminalFailureCaptured'])
        self.assertIn('GPU embeddings required', failure_meta['failureMessage'])
        self.assertEqual(failure_row['status'], 'error')
        self.assertIn('GPU embeddings required', failure_row['errorMessage'])


if __name__ == '__main__':
    unittest.main()
