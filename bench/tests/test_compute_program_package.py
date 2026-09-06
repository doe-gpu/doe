"""Adversarial archive identity checks; these fixtures are not GPU evidence."""
from __future__ import annotations

import io
import json
import tarfile
import tempfile
import unittest
from pathlib import Path

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


if __name__ == '__main__':
    unittest.main()
