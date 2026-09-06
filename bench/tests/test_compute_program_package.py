"""Adversarial archive identity checks; these fixtures are not GPU evidence."""
from __future__ import annotations

import io
import json
import shutil
import tarfile
import tempfile
import unittest
from pathlib import Path

import jsonschema

from bench.lib.compute_program_package import load_qualification, validate_package_root
from bench.lib.hash_utils import file_sha256

ROOT = Path(__file__).resolve().parents[2]


class ComputeProgramPackageTests(unittest.TestCase):
    def setUp(self) -> None:
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.package_root = self.root / 'node_modules/doe-gpu'
        self.report = {
            'schemaVersion': 1, 'kind': 'compute_program_package_qualification',
            'status': 'passed', 'error': None, 'packages': [], 'artifacts': [],
            'hosts': [{'host': host, 'executable': host, 'executableHash': 'a' * 64,
                       'libraryHash': 'b' * 64, 'status': 'passed'} for host in ['node', 'bun', 'electron']],
            'lifecycleCycles': 3, 'timeoutMs': 1000, 'claimStatus': 'diagnostic',
            'installation': 'retained-local-tarballs-with-install-scripts', 'limits': ['test fixture'],
        }
        for name in ['doe-gpu', 'doe-gpu-linux-x64']:
            path = self.root / f'{name}.tgz'
            files = {'package.json': json.dumps({'name': name}).encode(), 'src/entry.js': b'export const identity = 1;'}
            with tarfile.open(path, 'w:gz') as archive:
                for relative, data in files.items():
                    member = tarfile.TarInfo(f'package/{relative}')
                    member.size = len(data)
                    archive.addfile(member, io.BytesIO(data))
                    installed = self.root / 'node_modules' / name / relative
                    installed.parent.mkdir(parents=True, exist_ok=True)
                    installed.write_bytes(data)
            self.report['packages'].append({'path': str(path), 'hash': file_sha256(path)})
        self.summary = self.root / 'summary.json'
        self.save()

    def save(self) -> None:
        self.summary.write_text(json.dumps(self.report))

    def test_exact_installed_archive_bytes(self) -> None:
        qualification = load_qualification(self.summary, ROOT)
        validate_package_root(self.package_root, qualification)

    def test_rejects_changed_archive(self) -> None:
        Path(self.report['packages'][0]['path']).write_bytes(b'replaced package')
        with self.assertRaisesRegex(ValueError, 'Qualified archive changed'):
            load_qualification(self.summary, ROOT)

    def test_rejects_changed_installed_javascript(self) -> None:
        (self.package_root / 'src/entry.js').write_bytes(b'export const identity = 2;')
        with self.assertRaisesRegex(ValueError, 'differs from qualified archive'):
            validate_package_root(self.package_root, self.report)

    def test_rejects_installed_file_symlink_escape(self) -> None:
        original = self.package_root / 'src/entry.js'
        outside = self.root / 'outside.js'
        outside.write_bytes(original.read_bytes())
        original.unlink()
        original.symlink_to(outside)
        with self.assertRaisesRegex(ValueError, 'escaped package'):
            validate_package_root(self.package_root, self.report)

    def test_rejects_missing_hosts_or_different_libraries(self) -> None:
        self.report['hosts'][0]['libraryHash'] = 'c' * 64
        self.save()
        with self.assertRaisesRegex(ValueError, 'same qualified package'):
            load_qualification(self.summary, ROOT)
        self.report['hosts'][0]['libraryHash'] = 'b' * 64
        self.report['hosts'].pop()
        self.save()
        with self.assertRaisesRegex(ValueError, 'same qualified package'):
            load_qualification(self.summary, ROOT)

    def test_rejects_duplicate_wrapper_archive(self) -> None:
        self.report['packages'][1] = self.report['packages'][0]
        with self.assertRaisesRegex(ValueError, 'one wrapper and one native'):
            validate_package_root(self.package_root, self.report)

    def test_portable_qualification_survives_relocation_without_rewriting_hashes(self) -> None:
        self.report['schemaVersion'] = 2
        witness = self.root / 'execution.json'
        witness.write_bytes(b'{"unitFixture":true}')
        self.report['artifacts'] = [{'path': witness.name, 'hash': file_sha256(witness)}]
        for reference in self.report['packages']:
            reference['path'] = Path(reference['path']).name
        self.save()
        original_hash = file_sha256(self.summary)
        relocated = self.root / 'relocated'
        relocated.mkdir()
        for reference in [*self.report['packages'], *self.report['artifacts']]:
            source = self.root / reference['path']
            shutil.move(source, relocated / source.name)
        shutil.move(self.summary, relocated / self.summary.name)
        path = relocated / 'summary.json'
        self.assertEqual(file_sha256(path), original_hash)
        qualification = load_qualification(path, ROOT)
        validate_package_root(self.package_root, qualification)
        (relocated / witness.name).write_bytes(b'changed evidence')
        with self.assertRaisesRegex(ValueError, 'Qualified artifact changed'):
            load_qualification(path, ROOT)

    def test_portable_qualification_rejects_absolute_and_escaping_paths(self) -> None:
        self.report['schemaVersion'] = 2
        for reference in self.report['packages']:
            reference['path'] = Path(reference['path']).name
        for value in ['/archive.tgz', '../archive.tgz', 'C:\\archive.tgz', '..']:
            self.report['packages'][0]['path'] = value
            self.save()
            with self.assertRaises(jsonschema.ValidationError):
                load_qualification(self.summary, ROOT)


if __name__ == '__main__':
    unittest.main()
