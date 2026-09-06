"""Bind application execution to qualified npm archives and installed bytes."""
from __future__ import annotations

import hashlib
import json
import os
import shutil
import subprocess
import tarfile
from pathlib import Path, PurePosixPath
from typing import Any

import jsonschema

from bench.lib.hash_utils import file_sha256


def load_qualification(path: Path, repository: Path) -> dict[str, Any]:
    report = json.loads(path.read_text())
    schema = json.loads((repository / 'config/compute-program-package.schema.json').read_text())
    jsonschema.Draft202012Validator(schema).validate(report)
    if (report['status'] != 'passed' or report['error'] is not None
            or sorted(host['host'] for host in report['hosts']) != ['bun', 'electron', 'node']
            or len({host['libraryHash'] for host in report['hosts']}) != 1
            or len(report['packages']) != 2):
        raise ValueError('Application evaluation requires the same qualified package on Node, Bun, and Electron')
    for reference in report['packages']:
        if file_sha256(Path(reference['path'])) != reference['hash']:
            raise ValueError(f'Qualified archive changed: {reference["path"]}')
    return report


def validate_package_root(package_root: Path, report: dict[str, Any]) -> None:
    """Compare installed package inputs with the exact retained archive members."""
    names = []
    for reference in report['packages']:
        with tarfile.open(reference['path'], 'r:gz') as archive:
            manifest = archive.extractfile('package/package.json')
            if manifest is None:
                raise ValueError('Qualified archive lacks package.json')
            name = json.loads(manifest.read())['name']
            if name != 'doe-gpu' and name not in ('doe-gpu-linux-x64', 'doe-gpu-darwin-arm64'):
                raise ValueError(f'Unexpected qualified package: {name}')
            names.append(name)
            installed = package_root if name == 'doe-gpu' else package_root.parent / name
            for member in archive.getmembers():
                relative = PurePosixPath(member.name)
                if relative.parts[0] != 'package' or '..' in relative.parts:
                    raise ValueError(f'Invalid archive member: {member.name}')
                if member.isdir():
                    continue
                if not member.isfile():
                    raise ValueError(f'Unsupported archive member: {member.name}')
                target = installed.joinpath(*relative.parts[1:])
                if not target.resolve().is_relative_to(installed.resolve()):
                    raise ValueError(f'Installed file escaped package: {target}')
                source = archive.extractfile(member)
                if source is None or file_sha256(target) != hashlib.sha256(source.read()).hexdigest():
                    raise ValueError(f'Installed package differs from qualified archive: {target}')
    if names.count('doe-gpu') != 1 or len(set(names)) != 2:
        raise ValueError('Qualification requires one wrapper and one native platform archive')


def install_qualification(path: Path, output: Path, repository: Path, timeout_ms: int) -> Path:
    report = load_qualification(path, repository)
    project = output / 'installed-package'
    project.mkdir()
    (project / 'package.json').write_text(json.dumps({'name': 'doe-retained-application-evaluation',
                                                    'private': True, 'type': 'module'}))
    archives = output / 'package-archives'
    archives.mkdir()
    retained = []
    for index, reference in enumerate(report['packages']):
        target = archives / f'{index}-{Path(reference["path"]).name}'
        shutil.copyfile(reference['path'], target)
        retained.append(str(target))
    environment = {key: value for key, value in os.environ.items()
                   if not key.startswith('DOE_') and key not in ('NODE_PATH', 'NODE_OPTIONS', 'ELECTRON_RUN_AS_NODE')}
    result = subprocess.run(['npm', 'install', '--offline', '--omit=optional', '--no-audit', '--no-fund', *retained],
                            cwd=project, env=environment, capture_output=True, text=True,
                            timeout=timeout_ms / 1000, check=False)
    (output / 'package-install.stdout').write_text(result.stdout)
    (output / 'package-install.stderr').write_text(result.stderr)
    if result.returncode:
        raise ValueError('Qualified package installation failed; see package-install.stderr')
    package_root = project / 'node_modules/doe-gpu'
    validate_package_root(package_root, report)
    return package_root
