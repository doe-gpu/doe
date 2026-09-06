"""Acceptance tampering and limits are rejected before any GPU is selected."""
from __future__ import annotations

import copy
import hashlib
import json
import shutil
import struct
import tempfile
import unittest
from pathlib import Path

import jsonschema

from bench.lib.hash_utils import file_sha256
from bench.lib.program_candidate import environment_record, freeze_job, verify_frozen_inputs, write_json

ROOT = Path(__file__).resolve().parents[2]


class CandidateJobTests(unittest.TestCase):
    def setUp(self) -> None:
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.source = self.root / 'source'
        self.source.mkdir()
        self.output = self.root / 'output'
        self.output.mkdir()
        self.program = {'schemaVersion': 1, 'id': 'test', 'buffers': [
            {'id': 'input', 'size': 4, 'role': 'input', 'type': 'storage'},
            {'id': 'output', 'size': 4, 'role': 'output', 'type': 'storage'}],
            'shaders': [{'id': 'main', 'code': 'original', 'entryPoint': 'main'}],
            'steps': [{'shader': 'main', 'bindings': [{'binding': 0, 'buffer': 'input'},
                       {'binding': 1, 'buffer': 'output'}], 'workgroups': [1, 1, 1]}],
            'output': 'output'}
        self.job = copy.deepcopy(json.loads((ROOT / 'bench/fixtures/program-candidate/job.json')
                                            .read_text(encoding='utf-8')))
        self.job['program'] = self.reference('program.json', json.dumps(self.program).encode())
        self.job['candidateShaderId'] = 'main'
        self.job['reference'] = self.reference('reference.mjs', b'export function compute() {}')
        self.job['cases'] = [{'id': 'zero', 'inputs': {'input': self.reference('input.bin', struct.pack('<f', 0))},
                              'expected': self.reference('expected.bin', struct.pack('<d', 0))}]
        self.candidate = self.root / 'candidate.wgsl'
        self.candidate.write_text('replacement', encoding='utf-8')
        self.job_path = self.source / 'job.json'

    def reference(self, name: str, data: bytes) -> dict[str, str]:
        (self.source / name).write_bytes(data)
        return {'path': name, 'hash': hashlib.sha256(data).hexdigest()}

    def freeze(self, override_hash: str | None = None) -> dict:
        write_json(self.job_path, self.job)
        return freeze_job(self.job_path, override_hash or file_sha256(self.job_path),
                          self.candidate, self.output, ROOT)

    def test_candidate_changes_only_declared_shader(self) -> None:
        self.freeze()
        program = json.loads((self.output / 'program.json').read_text(encoding='utf-8'))
        self.assertEqual(program['shaders'][0]['code'], 'replacement')
        program['shaders'][0]['code'] = 'original'
        self.assertEqual(program, self.program)
        verify_frozen_inputs(self.output)
        (self.output / 'inputs/expected.bin').write_bytes(struct.pack('<d', 1))
        with self.assertRaisesRegex(ValueError, 'snapshot changed'):
            verify_frozen_inputs(self.output)

    def test_independently_pinned_job_rejects_changed_acceptance(self) -> None:
        with self.assertRaisesRegex(ValueError, 'independently pinned hash'):
            self.freeze('0' * 64)

    def test_rejects_changed_oracle_hash(self) -> None:
        (self.source / 'expected.bin').write_bytes(struct.pack('<d', 1))
        with self.assertRaisesRegex(ValueError, 'Acceptance input changed'):
            self.freeze()

    def test_rejects_symlink_escape(self) -> None:
        expected = self.source / 'expected.bin'
        outside = self.root / 'outside.bin'
        shutil.move(expected, outside)
        expected.symlink_to(outside)
        with self.assertRaisesRegex(ValueError, 'escapes its root'):
            self.freeze()

    def test_rejects_path_traversal(self) -> None:
        self.job['reference']['path'] = '../reference.mjs'
        with self.assertRaisesRegex(ValueError, 'escapes its root'):
            self.freeze()

    def test_rejects_resident_state(self) -> None:
        self.program['schemaVersion'] = 2
        self.program['buffers'][0]['lifetime'] = 'program'
        self.job['program'] = self.reference('program.json', json.dumps(self.program).encode())
        with self.assertRaisesRegex(ValueError, 'invocation-lifetime'):
            self.freeze()

    def test_rejects_buffer_and_readback_budget(self) -> None:
        self.job['limits']['maximumDeclaredBufferBytes'] = 8
        with self.assertRaisesRegex(ValueError, 'plus readback'):
            self.freeze()

    def test_rejects_shader_budget(self) -> None:
        self.job['limits']['maximumShaderBytes'] = 1
        with self.assertRaisesRegex(ValueError, 'maximumShaderBytes'):
            self.freeze()

    def test_rejects_missing_inputs_and_short_oracle(self) -> None:
        self.job['cases'][0]['inputs'] = {'wrong': self.job['cases'][0]['inputs']['input']}
        with self.assertRaisesRegex(ValueError, 'every input exactly once'):
            self.freeze()

    def test_rejects_short_oracle(self) -> None:
        self.job['cases'][0]['expected'] = self.reference('expected.bin', struct.pack('<f', 0))
        with self.assertRaisesRegex(ValueError, 'float64 oracle extent'):
            self.freeze()

    def test_rejects_unknown_policy_and_inadequate_sample_floor(self) -> None:
        self.job['oracle']['disableValidation'] = True
        with self.assertRaises(jsonschema.ValidationError):
            self.freeze()
        del self.job['oracle']['disableValidation']
        self.job['sampling']['timedRuns'] = 1
        with self.assertRaises(jsonschema.ValidationError):
            self.freeze()

    def test_driver_bytes_and_device_identity_invalidate_environment(self) -> None:
        identity = {'os': {'release': 'kernel'}, 'node': {'hash': 'node'},
                    'adapter': {'driverVersion': 1, 'deviceID': 2}, 'kernelObjects': [],
                    'loadedObjects': [{'path': '/installation/driver.so', 'hash': 'old'}]}
        original = environment_record(copy.deepcopy(identity), 'vulkan', 'gpu-recorded')
        identity['loadedObjects'][0]['path'] = '/relocated/driver.so'
        self.assertEqual(original, environment_record(identity, 'vulkan', 'gpu-recorded'))
        identity['loadedObjects'][0]['hash'] = 'changed-driver-bytes'
        self.assertNotEqual(original, environment_record(identity, 'vulkan', 'gpu-recorded'))
        identity['loadedObjects'][0]['hash'] = 'old'
        identity['adapter']['deviceID'] = 3
        self.assertNotEqual(original, environment_record(identity, 'vulkan', 'gpu-recorded'))


if __name__ == '__main__':
    unittest.main()
