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
    for collection in ['packages', 'artifacts']:
        for reference in report[collection]:
            original = Path(reference['path'])
            resolved = original
            if report['schemaVersion'] >= 2:
                resolved = (path.parent / original).resolve()
                if original.name != reference['path'] or not resolved.is_relative_to(path.parent.resolve()):
                    raise ValueError(f'Qualification reference escapes its retained directory: {original}')
                reference['path'] = str(resolved)
            if file_sha256(resolved) != reference['hash']:
                kind = 'archive' if collection == 'packages' else 'artifact'
                raise ValueError(f'Qualified {kind} changed: {original}')
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
    archives = output / 'package-inputs'
    archives.mkdir()
    retained_names = {}
    for reference in [*report['packages'], *report['artifacts']]:
        target = archives / Path(reference['path']).name
        if target.name in retained_names:
            if retained_names[target.name] != reference['hash']:
                raise ValueError(f'Conflicting retained package artifact: {target.name}')
            continue
        retained_names[target.name] = reference['hash']
        shutil.copyfile(reference['path'], target)
        if file_sha256(target) != reference['hash']:
            raise ValueError(f'Package artifact changed during retention: {target.name}')
    if 'summary.json' in retained_names:
        raise ValueError('Qualification artifacts conflict with the retained summary name')
    shutil.copyfile(path, archives / 'summary.json')
    retained = [str(archives / Path(reference['path']).name) for reference in report['packages']]
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
