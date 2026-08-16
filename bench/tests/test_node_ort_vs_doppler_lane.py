#!/usr/bin/env python3
"""Regression tests for the repo-only Node ORT-vs-Doppler lane."""

from __future__ import annotations

import json
import hashlib
import os
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
DOPPLER_BOUNDED_LIFECYCLE_PROVIDER_PATH = (
    REPO_ROOT / 'bench' / 'executors' / 'vendor-node'
    / 'doppler-node-webgpu-lifecycle-provider.mjs'
)
DOPPLER_LIFECYCLE_CONTROL_RUNNER_PATH = (
    REPO_ROOT / 'bench' / 'executors' / 'run-doppler-lifecycle-control.mjs'
)
DOPPLER_LIFECYCLE_ADJUDICATOR_PATH = (
    REPO_ROOT / 'bench' / 'executors' / 'adjudicate-doppler-lifecycle-control.mjs'
)
DOPPLER_LIFECYCLE_Q0_PLAN_PATH = (
    REPO_ROOT / 'bench' / 'vendor-node' /
    'doppler_provider_lifecycle_control_qm0.plan.json'
)
DOPPLER_LIFECYCLE_Q1_PLAN_PATH = (
    REPO_ROOT / 'bench' / 'vendor-node' /
    'doppler_provider_lifecycle_control_qm1.plan.json'
)
DOPPLER_LOGIT_DIVERGENCE_RUNNER_PATH = (
    REPO_ROOT / 'bench' / 'executors' / 'run-doppler-logit-divergence.mjs'
)
DOPPLER_LOGIT_DIVERGENCE_PLAN_PATH = (
    REPO_ROOT / 'bench' / 'vendor-node' /
    'doppler_provider_logit_divergence_qm0.plan.json'
)
DOPPLER_LOGIT_DIVERGENCE_CORRECTION_RUNNER_PATH = (
    REPO_ROOT / 'bench' / 'executors' /
    'run-doppler-logit-divergence-correction.mjs'
)
DOPPLER_LOGIT_DIVERGENCE_CORRECTION_PLAN_PATH = (
    REPO_ROOT / 'bench' / 'vendor-node' /
    'doppler_provider_logit_divergence_qm1.plan.json'
)
DOPPLER_KV_DIVERGENCE_RUNNER_PATH = (
    REPO_ROOT / 'bench' / 'executors' / 'run-doppler-kv-divergence.mjs'
)
DOPPLER_KV_DIVERGENCE_PLAN_PATH = (
    REPO_ROOT / 'bench' / 'vendor-node' / 'doppler_provider_kv_divergence_qm0.plan.json'
)
DOPPLER_LAYER0_PROBE_SCENARIO_PATH = (
    REPO_ROOT / 'bench' / 'vendor-node'
    / 'doppler_provider_layer0_probe_gemma270m_commands.json'
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

    def test_incumbent_provider_resolves_from_the_pinned_doppler_tree(self) -> None:
        source = DOPPLER_PROVIDER_RUNNER_PATH.read_text(encoding='utf-8')
        self.assertIn("scenario.dopplerRoot,\n      'node_modules/webgpu/index.js'", source)
        self.assertNotIn("bench/vendor/node-webgpu-package/index.js", source)

    def test_bounded_lifecycle_provider_waits_and_destroys_tracked_devices(self) -> None:
        with tempfile.TemporaryDirectory(prefix='doe-doppler-lifecycle-provider-') as tmpdir:
            fake_provider = Path(tmpdir) / 'fake-provider.mjs'
            fake_provider.write_text("""
export const globals = {};
export function create() {
  return {
    async requestAdapter() {
      return {
        async requestDevice() {
          return {
            queue: { async onSubmittedWorkDone() {} },
            destroy() {},
          };
        },
      };
    },
  };
}
""", encoding='utf-8')
            script = f"""
const provider = await import({json.dumps(DOPPLER_BOUNDED_LIFECYCLE_PROVIDER_PATH.as_uri())});
const gpu = provider.create();
const adapter = await gpu.requestAdapter();
await adapter.requestDevice();
await adapter.requestDevice();
console.log(JSON.stringify(await provider.releaseTrackedDevices()));
"""
            env = {
                **os.environ,
                'DOE_DOPPLER_INCUMBENT_MODULE': fake_provider.as_uri(),
            }
            result = subprocess.run(
                ['node', '--input-type=module', '-e', script],
                cwd=REPO_ROOT,
                env=env,
                capture_output=True,
                text=True,
                check=False,
            )
        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads(result.stdout)
        self.assertTrue(payload['supported'])
        self.assertEqual(payload['awaitedDeviceCount'], 2)
        self.assertEqual(payload['destroyedDeviceCount'], 2)
        self.assertEqual(payload['failureCount'], 0)

    def test_lifecycle_control_rejects_ownership_when_wrapper_closes_gap(self) -> None:
        script = f"""
import {{ decide }} from {json.dumps(DOPPLER_LIFECYCLE_CONTROL_RUNNER_PATH.as_uri())};
const plan = {{
  workload: {{ cleanProcessesPerLane: 3, sourceCommit: 'source', modelManifestSha256: 'model' }},
  implementation: {{
    incumbentProviderSha256: 'incumbent',
    boundedProviderSha256: 'wrapper',
    doeProviderSha256: 'doe',
  }},
}};
function run(laneId, provider, exitCategory, cleanup = false) {{
  return {{
    laneId,
    exitCategory,
    timedOut: false,
    trace: {{
      executionProvider: provider,
      executionSuccessCount: 1,
      dopplerSourceTrackedClean: true,
      dopplerSourceCommit: 'source',
      modelManifestSha256: 'model',
      lifecycleEvidenceState: 'release-complete',
      providerRelease: {{ released: true }},
      providerModuleSha256: laneId === 'W0' ? 'incumbent' : laneId === 'P0' ? 'wrapper' : 'doe',
      incumbentProviderModuleSha256: laneId === 'P0' ? 'incumbent' : null,
      resultSummary: {{
        status: 'ok',
        generatedTextSha256: 'text',
        generatedTokenIdsHash: 'tokens',
      }},
      providerLifecycleControl: cleanup ? {{
        supported: true,
        awaitedDeviceCount: 4,
        destroyedDeviceCount: 4,
        failureCount: 0,
      }} : {{ supported: false }},
    }},
  }};
}}
const results = {{
  W0: {{ runs: Array.from({{ length: 3 }}, () => run('W0', 'node-webgpu', 'abort')) }},
  P0: {{ runs: Array.from({{ length: 3 }}, () => run('P0', 'node-webgpu-bounded-lifecycle', 'zero', true)) }},
  D0: {{ runs: Array.from({{ length: 3 }}, () => run('D0', 'doe', 'zero')) }},
}};
console.log(JSON.stringify(decide(plan, results)));
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
        self.assertTrue(payload['evidenceValid'])
        self.assertFalse(payload['runtimeOwnershipAuthorized'])
        self.assertEqual(
            payload['decision'],
            'reject-doe-runtime-ownership-wrapper-closes-gap',
        )

    def test_lifecycle_readjudication_scopes_output_identity_to_wrapper_pair(self) -> None:
        script = f"""
import {{ adjudicate }} from {json.dumps(DOPPLER_LIFECYCLE_ADJUDICATOR_PATH.as_uri())};
function run(laneId, exitCategory, identity, cleanup = false) {{
  return {{
    laneId,
    exitCategory,
    timedOut: false,
    trace: {{
      executionSuccessCount: 1,
      dopplerSourceTrackedClean: true,
      lifecycleEvidenceState: 'release-complete',
      providerRelease: {{ released: true }},
      resultSummary: {{
        status: 'ok',
        generatedTextSha256: identity,
        generatedTokenIdsHash: `tokens-${{identity}}`,
      }},
      providerLifecycleControl: cleanup ? {{
        supported: true,
        awaitedDeviceCount: 4,
        destroyedDeviceCount: 4,
        failureCount: 0,
      }} : {{ supported: false }},
    }},
  }};
}}
const q0 = {{ results: {{
  W0: {{ runs: [
    run('W0', 'signal:SIGSEGV', 'incumbent'),
    run('W0', 'abort', 'incumbent'),
    run('W0', 'signal:SIGSEGV', 'incumbent'),
  ] }},
  P0: {{ runs: Array.from({{ length: 3 }}, () => run('P0', 'zero', 'incumbent', true)) }},
  D0: {{ runs: Array.from({{ length: 3 }}, () => run('D0', 'zero', 'doe')) }},
}} }};
const raw = Array.from({{ length: 9 }}, () => ({{
  traceMetaHashMatches: true,
  traceJsonlHashMatches: true,
  embeddedTraceMatches: true,
}}));
console.log(JSON.stringify(adjudicate(q0, raw)));
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
        self.assertEqual(
            payload['decision'],
            'reject-doe-runtime-ownership-wrapper-closes-gap',
        )
        self.assertTrue(payload['clauses']['wrapperControl'])
        self.assertTrue(payload['clauses']['doeControl'])
        self.assertFalse(payload['clauses']['crossProviderOutputIdentity'])
        self.assertTrue(payload['d0OutputDivergenceRetained'])

    def test_lifecycle_plans_bind_frozen_implementations(self) -> None:
        q0 = json.loads(DOPPLER_LIFECYCLE_Q0_PLAN_PATH.read_text(encoding='utf-8'))
        q1 = json.loads(DOPPLER_LIFECYCLE_Q1_PLAN_PATH.read_text(encoding='utf-8'))
        self.assertEqual(
            q0['implementation']['orchestratorSha256'],
            hashlib.sha256(DOPPLER_LIFECYCLE_CONTROL_RUNNER_PATH.read_bytes()).hexdigest(),
        )
        self.assertEqual(
            q0['implementation']['workerSha256'],
            hashlib.sha256(DOPPLER_PROVIDER_RUNNER_PATH.read_bytes()).hexdigest(),
        )
        self.assertEqual(
            q0['implementation']['boundedProviderSha256'],
            hashlib.sha256(DOPPLER_BOUNDED_LIFECYCLE_PROVIDER_PATH.read_bytes()).hexdigest(),
        )
        self.assertEqual(
            q1['implementation']['sha256'],
            hashlib.sha256(DOPPLER_LIFECYCLE_ADJUDICATOR_PATH.read_bytes()).hexdigest(),
        )

    def test_logit_divergence_plan_binds_orchestrator(self) -> None:
        plan = json.loads(DOPPLER_LOGIT_DIVERGENCE_PLAN_PATH.read_text(encoding='utf-8'))
        self.assertEqual(
            plan['implementation']['orchestratorSha256'],
            hashlib.sha256(DOPPLER_LOGIT_DIVERGENCE_RUNNER_PATH.read_bytes()).hexdigest(),
        )
        correction = json.loads(
            DOPPLER_LOGIT_DIVERGENCE_CORRECTION_PLAN_PATH.read_text(encoding='utf-8')
        )
        self.assertEqual(
            correction['implementation']['orchestratorSha256'],
            hashlib.sha256(
                DOPPLER_LOGIT_DIVERGENCE_CORRECTION_RUNNER_PATH.read_bytes()
            ).hexdigest(),
        )
        kv_plan = json.loads(DOPPLER_KV_DIVERGENCE_PLAN_PATH.read_text(encoding='utf-8'))
        self.assertEqual(
            kv_plan['implementation']['orchestratorSha256'],
            hashlib.sha256(DOPPLER_KV_DIVERGENCE_RUNNER_PATH.read_bytes()).hexdigest(),
        )

    def test_logit_divergence_localizes_before_sampling(self) -> None:
        script = f"""
import {{ adjudicate }} from {json.dumps(DOPPLER_LOGIT_DIVERGENCE_RUNNER_PATH.as_uri())};
const plan = {{
  workload: {{ sourceCommit: 'source', modelManifestSha256: 'model' }},
  implementation: {{ incumbentProviderSha256: 'incumbent', doeProviderSha256: 'doe' }},
}};
function run(providerModuleSha256, tokenId, digest, exitCode, signal) {{
  return {{
    exitCode,
    signal,
    timedOut: false,
    trace: {{
      executionSuccessCount: 1,
      lifecycleEvidenceState: 'release-complete',
      dopplerSourceCommit: 'source',
      modelManifestSha256: 'model',
      providerModuleSha256,
      resultSummary: {{ referenceTranscript: {{
        prompt: {{ hash: 'prompt', tokenIdsHash: 'prompt-tokens', tokenCount: 64 }},
        tokens: {{ ids: [tokenId] }},
        logits: {{ mode: 'sha256-per-step', steps: [{{
          digest,
          elementCount: 262144,
          inputTokenCount: 64,
          top: [{{ tokenId, logit: 1 }}],
        }}] }},
      }} }},
    }},
  }};
}}
const results = {{
  W0: run('incumbent', 818, 'w-logits', null, 'SIGSEGV'),
  D0: run('doe', 34492, 'd-logits', 0, null),
}};
console.log(JSON.stringify(adjudicate(plan, results)));
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
        self.assertTrue(payload['evidenceValid'])
        self.assertEqual(payload['boundary'], 'predictor-or-earlier-execution')
        self.assertFalse(payload['correctnessAssigned'])
        self.assertTrue(payload['authorizeOperationMismatchLocalization'])

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

    def test_doppler_summary_retains_explicit_logit_transcript(self) -> None:
        script = f"""
import {{ summarizeDopplerEnvelope }} from {json.dumps(SHARED_MODULE_URL)};
const transcript = {{
  prompt: {{ hash: 'prompt' }},
  tokens: {{ generatedTokenIdsHash: 'sha256:tokens', ids: [818] }},
  logits: {{ mode: 'sha256-per-step', perStepDigests: ['sha256:logits'], steps: [{{
    index: 0,
    tokenId: 818,
    inputTokenCount: 64,
    dtype: 'f32',
    elementCount: 262144,
    digest: 'sha256:logits',
    top: [{{ tokenId: 818, logit: 1, text: 'The' }}],
  }}] }},
}};
console.log(JSON.stringify(summarizeDopplerEnvelope({{
  ok: true,
  result: {{ output: 'The', metrics: {{ referenceTranscript: transcript }} }},
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
        self.assertEqual(payload['referenceTranscript']['tokens']['ids'], [818])
        self.assertEqual(
            payload['referenceTranscript']['logits']['steps'][0]['elementCount'],
            262144,
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
  dopplerCommand: scenario.doppler.command,
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
        self.assertEqual(payload['dopplerCommand'], 'bench')
        self.assertTrue(payload['dopplerModelPath'].endswith(
            '/doppler/models/local/gemma-3-270m-it-q4k-ehf16-af32'
        ))
        self.assertIsNone(payload['runtimeProfile'])

    def test_node_scenario_loader_accepts_explicit_debug_command(self) -> None:
        script = f"""
import {{ loadVendorNodeScenario }} from {json.dumps(SCENARIO_MODULE_URL)};
const scenario = await loadVendorNodeScenario(
  {json.dumps(str(DOPPLER_LAYER0_PROBE_SCENARIO_PATH))}
);
console.log(JSON.stringify({{ command: scenario.doppler.command }}));
"""
        result = subprocess.run(
            ['node', '--input-type=module', '-e', script],
            cwd=REPO_ROOT,
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), {'command': 'debug'})

    def test_node_scenario_loader_rejects_unknown_doppler_command(self) -> None:
        payload = json.loads(SCENARIO_PATH.read_text(encoding='utf-8'))
        payload[0]['doppler']['command'] = 'profile'
        with tempfile.TemporaryDirectory(prefix='doe-doppler-command-') as tmpdir:
            scenario_path = Path(tmpdir) / 'scenario.json'
            scenario_path.write_text(json.dumps(payload), encoding='utf-8')
            script = f"""
import {{ loadVendorNodeScenario }} from {json.dumps(SCENARIO_MODULE_URL)};
await loadVendorNodeScenario({json.dumps(str(scenario_path))});
"""
            result = subprocess.run(
                ['node', '--input-type=module', '-e', script],
                cwd=REPO_ROOT,
                capture_output=True,
                text=True,
                check=False,
            )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('scenario.doppler.command must be bench or debug', result.stderr)

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
