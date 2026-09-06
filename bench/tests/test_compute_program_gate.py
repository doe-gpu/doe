"""Adversarial evidence tests; fixture bytes are not physical runtime evidence."""
from __future__ import annotations

import copy
import hashlib
import json
import struct
import subprocess
import tempfile
import unittest
from pathlib import Path

import jsonschema

from bench.gates.compute_program_gate import (
    digest,
    validate_gpu_timing,
    validate_native_audit,
    validate_run,
)
from bench.lib.compute_program_fixture import load_fixture
from bench.native_compare_modules.reporting import format_stats
from bench.runners.run_compute_program_evidence import comparison_rows, same_adapter

ROOT = Path(__file__).resolve().parents[2]


class ComputeProgramGateTests(unittest.TestCase):
    def setUp(self) -> None:
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.path = Path(self.directory.name) / 'run.json'
        self.policy = json.loads((ROOT / 'config/compute-program-evaluation.json').read_text())
        self.program = {
            'schemaVersion': 1, 'id': 'fixture',
            'buffers': [{'id': 'input', 'size': 4, 'role': 'input', 'type': 'storage'},
                        {'id': 'output', 'size': 4, 'role': 'output', 'type': 'storage'}],
            'shaders': [{'id': 'copy', 'entryPoint': 'main', 'code': 'fixture shader identity'}],
            'steps': [{'shader': 'copy', 'bindings': [{'binding': 0, 'buffer': 'input'},
                                                    {'binding': 1, 'buffer': 'output'}], 'workgroups': [1, 1, 1]}],
            'output': 'output',
        }
        program_path = self.path.with_suffix('.program.json')
        program_path.write_text(json.dumps(self.program))
        identity = hashlib.sha256(json.dumps(self.program, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
        input_path = self.path.with_suffix('.input.f32')
        output_path = self.path.with_suffix('.output.f32')
        expected_path = self.path.with_suffix('.expected.f64')
        for path in [input_path, output_path]:
            path.write_bytes(struct.pack('<f', 1.0))
        expected_path.write_bytes(struct.pack('<d', 1.0))
        provider_path = self.path.with_suffix('.provider.bin')
        provider_path.write_bytes(b'unit-test provider artifact')
        receipt = {'schemaVersion': 1, 'programHash': identity, 'execution': 'webgpu', 'run': 1,
                   'inputHashes': {'input': digest(input_path)}, 'outputHash': digest(output_path),
                   'dispatchCount': 1, 'uploadedBytes': 4, 'clearedBytes': 4, 'readbackBytes': 4,
                   'readbackPath': 'mapAsync-copy-unmap', 'allocatedBufferBytes': 12,
                   'timingMs': {'upload': 1, 'encode': 1, 'submitWait': 1, 'readback': 1, 'total': 4}}
        sample = {'wallMs': 5, 'cpuMs': 2, 'receipt': receipt, 'outputPath': str(output_path),
                  'oracle': {'passed': True, 'maxAbsoluteError': 0, 'firstFailure': None}}
        repeated = copy.deepcopy(sample)
        repeated['receipt']['run'] = 2
        adapter = dict.fromkeys(['vendor', 'architecture', 'device', 'description', 'vendorID', 'deviceID', 'driverVersion'])
        adapter['isFallbackAdapter'] = False
        self.report = {'schemaVersion': 1, 'kind': 'compute_program_evaluation', 'claimStatus': 'diagnostic',
                       'provider': 'dawn', 'application': 'image_edges', 'phase': 'audit', 'backend': 'vulkan',
                       'policyHash': '0' * 64, 'programPath': str(program_path), 'inputPath': str(input_path),
                       'expectedPath': str(expected_path), 'runtime': {'name': 'node', 'version': 'fixture'},
                       'status': 'passed', 'error': None, 'cold': sample, 'samples': [repeated],
                       'programHash': identity, 'preparationMs': 1, 'deviceStartupMs': 1, 'teardownMs': 1,
                       'preparation': {'createdResources': 1, 'reusedResources': 0}, 'adapter': adapter,
                       'providerArtifact': {'path': str(provider_path), 'hash': digest(provider_path)},
                       'allocatedBufferBytes': 12, 'peakProcessRssBytes': 1024,
                       'lifecycle': {'cancellationRejected': True, 'reuseAfterCancellation': True},
                       'observed': {'dispatchesEncoded': 3, 'submissions': 3, 'maps': 3},
                       'latencyStatsMs': None, 'cpuStatsMs': None, 'measurementLimits': ['test fixture']}

    def validate(self) -> None:
        self.path.write_text(json.dumps(self.report))
        validate_run(self.path, ROOT, self.policy)

    def test_measurement_requires_declared_gpu_activity_evidence(self) -> None:
        self.policy['gpuActivity'] = 'reject-observed-linux-drm'
        self.validate()
        self.report['phase'] = 'measure'
        with self.assertRaises(FileNotFoundError):
            self.validate()

    def test_completion_receipt_migration_and_timing_scope_parity(self) -> None:
        receipt = copy.deepcopy(self.report['cold']['receipt'])
        receipt.update(schemaVersion=5, gpuTiming=None, completionMode='queue-and-map',
                       programInstance='6b9e2178-7a71-4671-afad-46a641a65413',
                       inputOrigins={}, residentStateBefore={}, outputGeneration=1,
                       copiedInputBytes=0, submissionCount=1)
        schema = json.loads((ROOT / 'config/compute-program-run.schema.json').read_text())
        validator = jsonschema.Draft202012Validator(schema)
        validator.validate(receipt)
        for mutation in [
            {'completionMode': 'queue-only'},
            {'schemaVersion': 4},
            {'readbackPath': 'none'},
        ]:
            with self.assertRaises(jsonschema.ValidationError):
                validator.validate(receipt | mutation)
        validator.validate(receipt | {'readbackPath': 'none', 'completionMode': 'queue-only',
                                      'readbackBytes': 0, 'outputHash': None,
                                      'timingMs': receipt['timingMs'] | {'readback': 0}})
        missing = dict(receipt)
        del missing['completionMode']
        with self.assertRaises(jsonschema.ValidationError):
            validator.validate(missing)
        validator.validate(missing | {'schemaVersion': 4})
        self.report['samples'][0]['receipt'] = receipt
        with self.assertRaisesRegex(ValueError, 'mixed completion timing scopes'):
            comparison_rows([(self.path, self.report)], self.policy)

    def test_current_receipts_bind_provenance_and_actual_submissions(self) -> None:
        for sample in [self.report['cold'], *self.report['samples']]:
            receipt = sample['receipt']
            receipt.update(schemaVersion=4, gpuTiming=None,
                           programInstance='6b9e2178-7a71-4671-afad-46a641a65413',
                           inputOrigins={name: {'kind': 'host', 'hash': value}
                                         for name, value in receipt['inputHashes'].items()},
                           residentStateBefore={}, outputGeneration=receipt['run'],
                           copiedInputBytes=0, submissionCount=1)
        self.validate()
        original = copy.deepcopy(self.report)
        for mutate in [
            lambda r: r.update(outputGeneration=1),
            lambda r: r.update(programInstance='f40b3f10-690a-4c8e-bb4f-baf9427e58bf'),
            lambda r: r.update(inputOrigins={'input': {'kind': 'zero'}}),
            lambda r: r.update(residentStateBefore={'output': {'kind': 'zero'}}),
            lambda r: r.update(copiedInputBytes=4),
            lambda r: r.update(submissionCount=2),
        ]:
            self.report = copy.deepcopy(original)
            mutate(self.report['samples'][0]['receipt'])
            with self.assertRaisesRegex(ValueError, 'provenance or submission'):
                self.validate()

    def test_resident_sequence_binds_every_state_and_rejects_reset_work(self) -> None:
        self.program['schemaVersion'] = 2
        for buffer in self.program['buffers']:
            buffer['lifetime'] = 'program'
        program_path = Path(self.report['programPath'])
        program_path.write_text(json.dumps(self.program))
        identity = hashlib.sha256(json.dumps(self.program, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
        self.report.update(schemaVersion=4, programHash=identity, gpuStatsNs=None,
                           providerAddonArtifact=None, timestampCalibrationArtifact=None,
                           warmups=[], lifecycleRuns=[], failedRun=None,
                           inputPaths={'input': self.report.pop('inputPath')})
        expected_refs = []
        samples = []
        instance = '6b9e2178-7a71-4671-afad-46a641a65413'
        for run in range(1, 4):
            sample = copy.deepcopy(self.report['cold'])
            output = self.path.with_name(f'output-{run}.f32')
            expected = self.path.with_name(f'expected-{run}.f64')
            output.write_bytes(struct.pack('<f', run))
            expected.write_bytes(struct.pack('<d', run))
            expected_refs.append({'path': expected.name, 'hash': digest(expected)})
            sample['outputPath'] = str(output)
            receipt = sample['receipt']
            def state(buffer: str, generation: int = run - 1) -> dict:
                return {'kind': 'program-state', 'programHash': identity, 'programInstance': instance,
                        'buffer': buffer, 'generation': generation}
            input_hash = receipt['inputHashes']['input']
            receipt.update(schemaVersion=4, programHash=identity, run=run, programInstance=instance,
                           gpuTiming=None, outputHash=digest(output), outputGeneration=run,
                           inputHashes={'input': input_hash if run == 1 else None},
                           inputOrigins={'input': {'kind': 'host', 'hash': input_hash} if run == 1 else state('input')},
                           residentStateBefore={'output': {'kind': 'zero'} if run == 1 else state('output')},
                           uploadedBytes=4 if run == 1 else 0, clearedBytes=0,
                           copiedInputBytes=0, submissionCount=1)
            samples.append(sample)
        self.report.update(cold=samples[0], samples=[samples[1]], lifecycleRuns=[samples[2]],
                           expectedPath=str(self.path.parent / expected_refs[0]['path']))
        self.report['observed']['submissions'] = 4
        fixture = {
            'schemaVersion': 2, 'kind': 'compute_program_fixture', 'application': 'image_edges',
            'sourceRepo': 'https://example.com/unit-fixture', 'sourceCommit': '0' * 40,
            'caseId': 'resident', 'generatorRuntime': 'test', 'adaptation': 'adversarial resident fixture',
            'program': {'path': program_path.name, 'hash': digest(program_path)},
            'inputs': {'input': {'path': Path(self.report['inputPaths']['input']).name,
                                 'hash': digest(Path(self.report['inputPaths']['input']))}},
            'expected': expected_refs[0], 'sequence': {'inputs': 'initialize-once', 'expected': expected_refs},
            'sources': [{'path': program_path.name, 'hash': digest(program_path)}],
            'checks': [{'offset': 0, 'count': 1, 'mode': 'exact', 'absoluteTolerance': 0,
                        'relativeTolerance': 0, 'relativeEpsilon': 0}],
        }
        fixture_path = self.path.with_name('fixture.json')
        fixture_path.write_text(json.dumps(fixture))
        self.policy['fixtures'] = {'image_edges': {'path': str(fixture_path), 'hash': digest(fixture_path)}}
        self.report['fixturePath'] = str(fixture_path)
        self.validate()
        original = copy.deepcopy(self.report)
        for mutate in [
            lambda r: r.update(lifecycleRuns=[]),
            lambda r: r.update(warmups=[r['cold']]),
            lambda r: r.update(failedRun=r['cold']),
            lambda r: r['samples'][0]['receipt'].update(uploadedBytes=4),
            lambda r: r['samples'][0]['receipt'].update(clearedBytes=4),
            lambda r: r['samples'][0]['receipt']['residentStateBefore']['output'].update(generation=99),
            lambda r: r['lifecycleRuns'][0]['receipt']['inputOrigins']['input'].update(generation=1),
            lambda r: r['samples'][0].update(outputPath=r['cold']['outputPath'],
                                            receipt={**r['samples'][0]['receipt'], 'outputHash': r['cold']['receipt']['outputHash']}),
        ]:
            self.report = copy.deepcopy(original)
            mutate(self.report)
            with self.assertRaises(ValueError):
                self.validate()

    def test_timestamp_evidence_rejects_changed_units_scope_counts_and_statistics(self) -> None:
        self.policy['gpuTiming'] = 'timestamp-query'
        timing = {'source': 'webgpu-nanoseconds', 'scope': 'compute-pass',
                  'beginTicks': '1000', 'endTicks': '1400', 'periodNs': 1, 'validBits': 64, 'elapsedNs': 400}
        for sample in [self.report['cold'], *self.report['samples']]:
            sample['receipt'].update(schemaVersion=2, gpuTiming=copy.deepcopy(timing),
                                     readbackBytes=20, allocatedBufferBytes=48)
        self.report['allocatedBufferBytes'] = 48
        self.report['gpuStatsNs'] = dict.fromkeys(['mean', 'min', 'max', 'median', 'p95', 'p99'], 400)
        self.report['gpuStatsNs']['count'] = 1
        self.validate()
        original = copy.deepcopy(self.report)
        for mutate in [
            lambda r: r['samples'][0]['receipt']['gpuTiming'].update(periodNs=2),
            lambda r: r['samples'][0]['receipt']['gpuTiming'].update(elapsedNs=401),
            lambda r: r['samples'][0]['receipt']['gpuTiming'].update(source='vulkan-query-ticks'),
            lambda r: r['samples'][0]['receipt']['gpuTiming'].update(beginTicks=str(1 << 64)),
            lambda r: r['samples'][0]['receipt'].update(gpuTiming=None),
            lambda r: r['samples'][0]['receipt'].update(readbackBytes=4),
            lambda r: r['gpuStatsNs'].update(p95=401),
            lambda r: r['gpuStatsNs'].update(count=2),
        ]:
            self.report = copy.deepcopy(original)
            mutate(self.report)
            with self.assertRaises(ValueError):
                self.validate()

    def test_gpu_tick_calibration_rejects_default_nanosecond_period(self) -> None:
        policy = {'gpuTiming': 'timestamp-query', 'timestampPeriodRelativeTolerance': 0.00001}
        clock = {'properties': {'VkPhysicalDeviceProperties': {'limits': {'timestampPeriod': 10.019}}},
                 'queueFamiliesProperties': [{'VkQueueFamilyProperties': {
                     'queueFlags': ['VK_QUEUE_COMPUTE_BIT'], 'timestampValidBits': 64}}]}
        timing = {'source': 'vulkan-query-ticks', 'scope': 'compute-pass', 'beginTicks': '100',
                  'endTicks': '200', 'periodNs': 10.019036293029785, 'validBits': 64,
                  'elapsedNs': 1001.9036293029785}
        self.assertTrue(validate_gpu_timing({'gpuTiming': timing}, 'doe-recorded', policy, clock))
        timing.update(periodNs=1, elapsedNs=100)
        with self.assertRaisesRegex(ValueError, 'physical Vulkan profile'):
            validate_gpu_timing({'gpuTiming': timing}, 'doe-recorded', policy, clock)

    def test_normalized_native_queries_require_new_receipt_and_nanosecond_units(self) -> None:
        policy = {'gpuTiming': 'timestamp-query'}
        timing = {'source': 'webgpu-nanoseconds', 'scope': 'compute-pass', 'beginTicks': '100',
                  'endTicks': '200', 'periodNs': 1, 'validBits': 64, 'elapsedNs': 100}
        receipt = {'schemaVersion': 3, 'gpuTiming': timing}
        self.assertTrue(validate_gpu_timing(receipt, 'doe-recorded', policy))
        for field, value in [('periodNs', 10), ('validBits', 48), ('source', 'vulkan-query-ticks')]:
            changed = copy.deepcopy(receipt)
            changed['gpuTiming'][field] = value
            with self.assertRaises(ValueError):
                validate_gpu_timing(changed, 'doe-recorded', policy)

    def test_valid_artifact_and_fail_closed_mutations(self) -> None:
        self.validate()
        original = copy.deepcopy(self.report)
        mutations = [
            lambda r: r['observed'].update(dispatchesEncoded=0),
            lambda r: r['observed'].update(maps=0),
            lambda r: r['samples'][0]['receipt'].update(dispatchCount=0),
            lambda r: r['samples'][0]['receipt'].update(run=1),
            lambda r: r['samples'][0]['receipt']['timingMs'].update(submitWait=0),
            lambda r: r['samples'][0]['receipt'].update(readbackBytes=0),
            lambda r: r['adapter'].update(isFallbackAdapter=True),
            lambda r: r['samples'][0].update(wallMs=1),
        ]
        for mutation in mutations:
            self.report = copy.deepcopy(original)
            mutation(self.report)
            with self.assertRaises(ValueError):
                self.validate()

    def test_forged_output_hash_does_not_replace_numerical_truth(self) -> None:
        path = Path(self.report['cold']['outputPath'])
        path.write_bytes(struct.pack('<f', 100.0))
        for sample in [self.report['cold'], *self.report['samples']]:
            sample['receipt']['outputHash'] = digest(path)
        with self.assertRaisesRegex(ValueError, 'retained numerical output failed'):
            self.validate()

    def test_native_dispatch_geometry_and_backend_bytes_are_bound(self) -> None:
        artifact = self.path.parent / 'shader.spv'
        artifact.write_bytes(b'fixture backend program')
        row = {'event': 'dispatch_encoded', 'wgslSha256': hashlib.sha256(self.program['shaders'][0]['code'].encode()).hexdigest(),
               'workgroups': [1, 1, 1], 'entryPoint': 'main', 'bindingCount': 2,
               'backendArtifactFile': artifact.name, 'backendArtifactSha256': digest(artifact)}
        journal = Path(f'{self.path}.native.jsonl')
        journal.write_text(json.dumps(row) + '\n' + json.dumps({'event': 'submission_succeeded'}) + '\n')
        validate_native_audit(self.path, self.program, 1)
        artifact.write_bytes(b'changed')
        with self.assertRaisesRegex(ValueError, 'backend artifact bytes changed'):
            validate_native_audit(self.path, self.program, 1)
        with self.assertRaisesRegex(ValueError, 'missing native dispatch'):
            validate_native_audit(self.path, self.program, 2)

    def test_comparisons_reject_mixed_installed_and_workspace_executors(self) -> None:
        changed = copy.deepcopy(self.report)
        changed['packageQualification'] = {'path': 'qualification.json', 'hash': 'a' * 64}
        changed['packageRoot'] = '/installed/node_modules/doe-gpu'
        with self.assertRaisesRegex(ValueError, 'mixed package execution sources'):
            comparison_rows([(self.path, self.report), (self.path, changed)], self.policy)

    def test_evaluation_package_fields_are_paired_and_versioned(self) -> None:
        report = copy.deepcopy(self.report)
        report.update(schemaVersion=5, inputPaths={'input': report['inputPath']}, fixturePath=None,
                      providerAddonArtifact=None, timestampCalibrationArtifact=None, gpuStatsNs=None,
                      warmups=[], lifecycleRuns=[], failedRun=None,
                      packageQualification=None, packageRoot=None)
        schema = json.loads((ROOT / 'config/compute-program-run.schema.json').read_text())
        validator = jsonschema.Draft202012Validator(schema)
        validator.validate(report)
        for mutation in [
            {'schemaVersion': 4},
            {'packageRoot': '/unexpected-install'},
            {'packageQualification': {'path': 'qualification.json', 'hash': 'a' * 64}},
        ]:
            with self.assertRaises(jsonschema.ValidationError):
                validator.validate(report | mutation)
        del report['packageRoot']
        with self.assertRaises(jsonschema.ValidationError):
            validator.validate(report)

    def test_adapter_labels_are_normalized_without_accepting_a_different_device(self) -> None:
        doe = {'isFallbackAdapter': False, 'vendor': 'AMD', 'device': 'Radeon Fixture GPU', 'vendorID': 4098, 'deviceID': 7}
        dawn = {'isFallbackAdapter': False, 'vendor': 'amd', 'device': 'radeon-fixture-gpu-', 'vendorID': None, 'deviceID': None}
        self.assertTrue(same_adapter(doe, dawn))
        self.assertFalse(same_adapter(doe, {**dawn, 'device': 'different-gpu'}))
        self.assertFalse(same_adapter(doe, {**dawn, 'isFallbackAdapter': True}))

    def test_gpu_replay_requires_one_preparation_and_matching_submissions(self) -> None:
        self.test_native_dispatch_geometry_and_backend_bytes_are_bound()
        artifact = self.path.parent / 'shader.spv'
        artifact.write_bytes(b'fixture backend program')
        journal = Path(f'{self.path}.native.jsonl')
        dispatch = json.loads(journal.read_text().splitlines()[0])
        dispatch.update(processId=1, sequence=1)
        prepared = {'event': 'compute_program_prepared', 'programId': 7, 'dispatchCount': 1,
                    'submissionIndex': 0, 'sequence': 2, 'processId': 1}
        submitted = {'event': 'compute_program_submitted', 'programId': 7, 'dispatchCount': 1,
                     'submissionIndex': 1, 'sequence': 3, 'processId': 1}
        journal.write_text(''.join(json.dumps(row) + '\n' for row in [dispatch, prepared, submitted]))
        validate_native_audit(self.path, self.program, 1, gpu_recorded=True)
        submitted['programId'] = 8
        journal.write_text(''.join(json.dumps(row) + '\n' for row in [dispatch, prepared, submitted]))
        with self.assertRaisesRegex(ValueError, 'GPU replay identity'):
            validate_native_audit(self.path, self.program, 1, gpu_recorded=True)

    def test_new_percentile_policy_matches_javascript_and_preserves_legacy(self) -> None:
        samples = [list(range(1, 33)), [9], [4, 0, 4, 2, 8, 1, 7]]
        script = "import { stats } from './bench/shared/lib/stats.js'; console.log(JSON.stringify(JSON.parse(process.argv[1]).map(stats)));"
        result = subprocess.run(['node', '--input-type=module', '-e', script, json.dumps(samples)],
                                cwd=ROOT, capture_output=True, text=True, check=True)
        for values, javascript in zip(samples, json.loads(result.stdout)):
            python = format_stats(values, percentile_method='nearest-rank')
            for left, right in [('p50Ms', 'median'), ('p95Ms', 'p95'), ('p99Ms', 'p99')]:
                self.assertEqual(python[left], javascript[right])
        self.assertEqual(format_stats(samples[0])['p95Ms'], 30)
        self.assertEqual(format_stats(samples[0], percentile_method='nearest-rank')['p95Ms'], 31)

    def test_external_fixture_preserves_exact_observables_and_provenance(self) -> None:
        def reference(path: str) -> dict[str, str]:
            return {'path': Path(path).name, 'hash': digest(Path(path))}

        fixture = {
            'schemaVersion': 1, 'kind': 'compute_program_fixture', 'application': 'image_edges',
            'sourceRepo': 'https://example.com/unit-fixture', 'sourceCommit': '0' * 40,
            'caseId': 'test', 'generatorRuntime': 'test', 'adaptation': 'adversarial unit fixture',
            'program': reference(self.report['programPath']),
            'inputs': {'input': reference(self.report['inputPath'])},
            'expected': reference(self.report['expectedPath']),
            'sources': [reference(self.report['programPath'])],
            'checks': [{'offset': 0, 'count': 1, 'mode': 'exact', 'absoluteTolerance': 0,
                        'relativeTolerance': 0, 'relativeEpsilon': 0}],
        }
        path = self.path.with_name('fixture.json')
        path.write_text(json.dumps(fixture))
        self.policy['fixtures'] = {'image_edges': {'path': str(path), 'hash': digest(path)}}
        self.report.update(schemaVersion=2, fixturePath=str(path),
                           inputPaths={'input': self.report.pop('inputPath')})
        self.validate()
        output = Path(self.report['cold']['outputPath'])
        output.write_bytes(struct.pack('<f', 1.000001))
        for sample in [self.report['cold'], *self.report['samples']]:
            sample['receipt']['outputHash'] = digest(output)
        with self.assertRaisesRegex(ValueError, 'retained external oracle failed'):
            self.validate()
        fixture['checks'][0]['offset'] = 1
        path.write_text(json.dumps(fixture))
        with self.assertRaisesRegex(ValueError, 'without gaps or overlap'):
            load_fixture(path, ROOT)
        fixture['checks'][0]['offset'] = 0
        path.write_text(json.dumps(fixture))
        Path(self.report['inputPaths']['input']).write_bytes(struct.pack('<f', 2.0))
        with self.assertRaisesRegex(ValueError, 'reference escapes or changed'):
            load_fixture(path, ROOT)


if __name__ == '__main__':
    unittest.main()
