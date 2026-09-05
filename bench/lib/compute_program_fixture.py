"""Hash-bound external inputs and numerical requirements for declared programs."""
from __future__ import annotations

import json
from pathlib import Path
from typing import Any

import jsonschema

from bench.lib.hash_utils import file_sha256


def fixture_references(fixture: dict[str, Any]) -> list[dict[str, str]]:
    return [fixture['program'], fixture['expected'], *fixture['inputs'].values(), *fixture['sources'],
            *fixture.get('sequence', {}).get('expected', [])]


def load_fixture(path: Path, root: Path, identity: str | None = None) -> dict[str, Any]:
    """Validate every referenced byte and require complete output-oracle coverage."""
    if identity is not None and file_sha256(path) != identity:
        raise ValueError(f'{path}: external fixture identity changed')
    fixture = json.loads(path.read_text(encoding='utf-8'))
    schema = json.loads((root / 'config/compute-program-fixture.schema.json').read_text(encoding='utf-8'))
    jsonschema.Draft202012Validator(schema).validate(fixture)
    for reference in fixture_references(fixture):
        target = (path.parent / reference['path']).resolve()
        if not target.is_relative_to(path.parent.resolve()) or file_sha256(target) != reference['hash']:
            raise ValueError(f'{path}: fixture reference escapes or changed: {reference["path"]}')
    program = json.loads((path.parent / fixture['program']['path']).read_text(encoding='utf-8'))
    program_schema = json.loads((root / 'config/compute-program.schema.json').read_text(encoding='utf-8'))
    jsonschema.Draft202012Validator(program_schema).validate(program)
    expected_inputs = {buffer['id']: buffer['size'] for buffer in program['buffers'] if buffer['role'] == 'input'}
    if set(expected_inputs) != set(fixture['inputs']):
        raise ValueError(f'{path}: fixture inputs do not match declared resources')
    for name, size in expected_inputs.items():
        if (path.parent / fixture['inputs'][name]['path']).stat().st_size != size:
            raise ValueError(f'{path}: input extent mismatch for {name}')
    expected_size = (path.parent / fixture['expected']['path']).stat().st_size
    count = expected_size // 8
    output = next(buffer for buffer in program['buffers'] if buffer['id'] == program['output'])
    if expected_size % 8 or count * 4 != output['size']:
        raise ValueError(f'{path}: expected output extent mismatch')
    if sequence := fixture.get('sequence'):
        if program['schemaVersion'] != 2 or any(buffer.get('lifetime') != 'program' for buffer in program['buffers']):
            raise ValueError(f'{path}: initialize-once sequences require explicit program-lifetime buffers')
        if sequence['expected'][0] != fixture['expected']:
            raise ValueError(f'{path}: sequence must begin at the initial oracle')
        if any((path.parent / item['path']).stat().st_size != expected_size for item in sequence['expected']):
            raise ValueError(f'{path}: sequence oracle extent mismatch')
    offset = 0
    for check in fixture['checks']:
        if check['offset'] != offset:
            raise ValueError(f'{path}: numerical checks must cover the output without gaps or overlap')
        offset += check['count']
    if offset != count:
        raise ValueError(f'{path}: numerical checks do not cover the output')
    return fixture


def accepts(actual: float, expected: float, check: dict[str, Any]) -> bool:
    """Apply the declared exact or strict absolute-and-relative external oracle."""
    if check['mode'] == 'exact':
        return actual == expected
    error = abs(actual - expected)
    return (error < check['absoluteTolerance']
            and error / (abs(expected) + check['relativeEpsilon']) < check['relativeTolerance'])
