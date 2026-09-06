"""Freeze candidate acceptance inputs before loading a compiler or reference."""
from __future__ import annotations

import hashlib
import json
import math
from pathlib import Path, PurePosixPath
from typing import Any

import jsonschema

from bench.lib.hash_utils import file_sha256


def write_json(path: Path, value: Any) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=True,
                               allow_nan=False) + '\n', encoding='utf-8')


def freeze_job(job_path: Path, job_hash: str, candidate: Path,
               output: Path, repository: Path) -> dict[str, Any]:
    """Validate and snapshot the pinned acceptance contract and candidate."""
    job_bytes = job_path.read_bytes()
    if hashlib.sha256(job_bytes).hexdigest() != job_hash:
        raise ValueError('Acceptance job differs from the independently pinned hash')
    job = json.loads(job_bytes)
    schema = json.loads((repository / 'config/program-candidate.schema.json')
                        .read_text(encoding='utf-8'))
    jsonschema.Draft202012Validator(schema).validate(job)
    root = job_path.parent.resolve()
    destination = output / 'inputs'
    destination.mkdir()
    references: dict[str, str] = {}
    total_bytes = 0

    def retain(reference: dict[str, str]) -> bytes:
        nonlocal total_bytes
        name = reference['path']
        relative = PurePosixPath(name)
        source = (root / name).resolve()
        if (relative.is_absolute() or '..' in relative.parts
                or '\\' in name or name != relative.as_posix()
                or not source.is_relative_to(root)):
            raise ValueError(f'Acceptance reference escapes its root: {name}')
        if name in references and references[name] != reference['hash']:
            raise ValueError(f'Conflicting acceptance hashes: {name}')
        if name not in references:
            total_bytes += source.stat().st_size
            if total_bytes > job['limits']['maximumFixtureBytes']:
                raise ValueError('Frozen inputs exceed maximumFixtureBytes')
        data = source.read_bytes()
        if hashlib.sha256(data).hexdigest() != reference['hash']:
            raise ValueError(f'Acceptance input changed: {name}')
        target = destination / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
        references[name] = reference['hash']
        return data

    descriptor = json.loads(retain(job['program']))
    program_schema = json.loads((repository / 'config/compute-program.schema.json')
                                .read_text(encoding='utf-8'))
    jsonschema.Draft202012Validator(program_schema).validate(descriptor)
    if any(buffer.get('lifetime', 'invocation') != 'invocation'
           for buffer in descriptor['buffers']):
        raise ValueError('Candidate jobs require invocation-lifetime buffers')
    buffers = {buffer['id']: buffer for buffer in descriptor['buffers']}
    if len(buffers) != len(descriptor['buffers']):
        raise ValueError('Duplicate program buffer identity')
    result = buffers.get(descriptor['output'])
    if result is None or result['role'] != 'output':
        raise ValueError('Program output must identify an output buffer')
    declared_bytes = sum(buffer['size'] for buffer in buffers.values()) + result['size']
    if declared_bytes > job['limits']['maximumDeclaredBufferBytes']:
        raise ValueError('Declared buffers plus readback exceed the job budget')
    if len(descriptor['steps']) > job['limits']['maximumDispatches']:
        raise ValueError('Dispatch count exceeds the job budget')
    workgroups = sum(math.prod(step['workgroups']) for step in descriptor['steps'])
    if workgroups > job['limits']['maximumWorkgroups']:
        raise ValueError('Dispatch geometry exceeds the job budget')
    shaders = {shader['id']: shader for shader in descriptor['shaders']}
    if len(shaders) != len(descriptor['shaders']) or job['candidateShaderId'] not in shaders:
        raise ValueError('Candidate shader must identify exactly one declared shader')
    if candidate.stat().st_size > job['limits']['maximumShaderBytes']:
        raise ValueError('Candidate exceeds maximumShaderBytes')
    candidate_bytes = candidate.read_bytes()
    shaders[job['candidateShaderId']]['code'] = candidate_bytes.decode('utf-8')
    if sum(len(shader['code'].encode()) for shader in shaders.values()) > job['limits']['maximumShaderBytes']:
        raise ValueError('Combined WGSL exceeds maximumShaderBytes')
    jsonschema.Draft202012Validator(program_schema).validate(descriptor)
    retain(job['reference'])
    for reference in job['dependencies']:
        retain(reference)
    case_ids = set()
    for case in job['cases']:
        if case['id'] in case_ids:
            raise ValueError('Duplicate acceptance case identity')
        case_ids.add(case['id'])
        expected_inputs = {key for key, buffer in buffers.items() if buffer['role'] == 'input'}
        if set(case['inputs']) != expected_inputs:
            raise ValueError(f"Case {case['id']} must supply every input exactly once")
        for key, reference in case['inputs'].items():
            if len(retain(reference)) != buffers[key]['size']:
                raise ValueError(f"Case {case['id']} input {key} extent mismatch")
        if len(retain(case['expected'])) != result['size'] * 2:
            raise ValueError(f"Case {case['id']} float64 oracle extent mismatch")
    (output / 'job.json').write_bytes(job_bytes)
    (output / 'candidate.wgsl').write_bytes(candidate_bytes)
    write_json(output / 'program.json', descriptor)
    write_json(output / 'input-hashes.json', references)
    return job


def verify_frozen_inputs(output: Path) -> None:
    """Reject any changed acceptance input after child execution."""
    references = json.loads((output / 'input-hashes.json').read_text(encoding='utf-8'))
    for name, expected in references.items():
        if file_sha256(output / 'inputs' / name) != expected:
            raise ValueError(f'Acceptance snapshot changed during execution: {name}')


def environment_record(identity: dict[str, Any], backend: str,
                       execution: str) -> dict[str, Any]:
    """Bind execution-affecting identity without treating install paths as devices."""
    stable = {key: identity[key] for key in ('os', 'node', 'adapter', 'kernelObjects')}
    stable['loadedObjects'] = sorted(
        ({'name': Path(item['path']).name, 'hash': item['hash']}
         for item in identity['loadedObjects']), key=lambda item: (item['name'], item['hash']))
    stable['backend'] = backend
    stable['execution'] = execution
    return stable
