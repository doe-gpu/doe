"""Recheck retained candidate outputs and native work independently of the worker."""
from __future__ import annotations

import json
import hashlib
import math
import struct
from collections import Counter
from pathlib import Path
from typing import Any

import jsonschema
from referencing import Registry, Resource

from bench.lib.hash_utils import file_sha256
from bench.lib.program_candidate import write_json
from bench.native_compare_modules.reporting import format_stats
from bench.tools.validate_native_program_identity_trace import build_validation


def validate_execution(output: Path, job: dict[str, Any],
                       repository: Path) -> dict[str, Any]:
    """Validate every retained result; timing cannot rescue failed correctness."""
    execution = json.loads((output / 'execution.json').read_text(encoding='utf-8'))
    schema = json.loads((repository / 'config/program-candidate-execution.schema.json').read_text(encoding='utf-8'))
    receipt_schema = json.loads((repository / 'config/compute-program-run.schema.json').read_text(encoding='utf-8'))
    registry = Registry().with_resource('compute-program-run.schema.json', Resource.from_contents(receipt_schema))
    jsonschema.Draft202012Validator(schema, registry=registry).validate(execution)
    if (execution['jobHash'] != file_sha256(output / 'job.json')
            or execution['candidateHash'] != file_sha256(output / 'candidate.wgsl')):
        raise ValueError('Execution is not bound to the retained job and candidate')
    descriptor = json.loads((output / 'program.json').read_text(encoding='utf-8'))
    program_hash = hashlib.sha256(json.dumps(descriptor, sort_keys=True,
        separators=(',', ':'), ensure_ascii=False).encode()).hexdigest()
    fixtures = {case['id']: case for case in job['cases']}
    if len({case['id'] for case in execution['cases']}) != len(execution['cases']):
        raise ValueError('Duplicate observed case')
    program_hashes = set()
    candidate_count = 0
    for case in execution['cases']:
        if case['id'] not in fixtures:
            raise ValueError('Observed case is absent from frozen acceptance')
        fixture = fixtures[case['id']]
        expected_bytes = (output / 'inputs' / fixture['expected']['path']).read_bytes()
        expected = list(value[0] for value in struct.iter_unpack('<d', expected_bytes))
        seen = set()
        for sample in case['samples']:
            identity = (sample['mode'], sample['phase'], sample['index'])
            if identity in seen:
                raise ValueError('Duplicate observed invocation')
            seen.add(identity)
            path = (output / sample['output']['path']).resolve()
            if not path.is_relative_to((output / 'outputs').resolve()):
                raise ValueError('Output reference escapes retained output directory')
            if file_sha256(path) != sample['output']['hash']:
                raise ValueError('Retained output bytes changed')
            actual = list(value[0] for value in struct.iter_unpack('<f', path.read_bytes()))
            if len(actual) != len(expected):
                raise ValueError('Retained output extent mismatch')
            passed = all(math.isfinite(left) and math.isfinite(right)
                         and abs(left - right) <= job['oracle']['absoluteTolerance']
                         + job['oracle']['relativeTolerance'] * abs(right)
                         for left, right in zip(actual, expected))
            if passed != sample['numerical']['passed']:
                raise ValueError('Observed numerical acceptance disagrees with retained bytes')
            if not passed and execution['status'] == 'accepted':
                raise ValueError('Incorrect output cannot be accepted')
            if sample['mode'] == 'candidate':
                candidate_count += 1
                receipt = sample['receipt']
                if receipt is None:
                    raise ValueError('Candidate invocation lacks an execution receipt')
                program_hashes.add(receipt['programHash'])
                if (receipt['execution'] != execution['execution']
                        or receipt['programHash'] != program_hash
                        or receipt['dispatchCount'] != len(descriptor['steps'])
                        or receipt['readbackBytes'] != len(actual) * 4
                        or receipt['outputHash'] != sample['output']['hash']
                        or receipt['inputHashes'] != {key: value['hash'] for key, value in fixture['inputs'].items()}):
                    raise ValueError('Candidate receipt differs from declared useful work')
            elif sample['receipt'] is not None:
                raise ValueError('CPU reference cannot report a GPU receipt')
        if execution['status'] == 'accepted':
            required = {(mode, phase, index) for mode in ('reference', 'candidate')
                        for phase, count in [('first', 1), ('warmup', job['sampling']['warmupRuns']),
                                             ('timed', job['sampling']['timedRuns'])]
                        for index in range(count)}
            if seen != required or not case['accepted']:
                raise ValueError('Accepted case omitted declared invocations')
        if case['ratios'] is not None:
            measured = {}
            for mode in ('reference', 'candidate'):
                times = [sample['elapsedMs'] for sample in case['samples']
                         if sample['mode'] == mode and sample['phase'] == 'timed']
                if len(times) != job['sampling']['timedRuns'] or any(value <= 0 for value in times):
                    raise ValueError('Performance evidence requires every positive timed sample')
                measured[mode] = format_stats(times, percentile_method='nearest-rank')
                for field, key in [('median', 'p50Ms'), ('p95', 'p95Ms'), ('p99', 'p99Ms')]:
                    if case[f'{mode}StatsMs'][field] != measured[mode][key]:
                        raise ValueError('Latency summary differs from raw samples')
            ratios = {key: measured['reference'][f'{key}Ms'] / measured['candidate'][f'{key}Ms']
                      for key in ('p50', 'p95')}
            if case['ratios'] != ratios:
                raise ValueError('Performance ratios differ from raw timings')
            saved = measured['reference']['p50Ms'] - measured['candidate']['p50Ms']
            cold = {sample['mode']: sample['elapsedMs'] for sample in case['samples']
                    if sample['phase'] == 'first'}
            preparation = execution['preparation']
            overhead = max(0, preparation['candidate']['processPreparationMs']
                           - preparation['reference']['processPreparationMs']
                           + cold['candidate'] - cold['reference'])
            recovery = math.ceil(overhead / saved) if saved > 0 else None
            if recovery != case['preparationRecoveryRuns']:
                raise ValueError('Preparation recovery differs from measured startup and samples')
            accepted = (ratios['p50'] >= job['performance']['minimumP50Ratio']
                        and ratios['p95'] >= job['performance']['minimumP95Ratio']
                        and recovery is not None
                        and recovery <= job['performance']['maximumPreparationRecoveryRuns'])
            if accepted != case['accepted']:
                raise ValueError('Case acceptance differs from the frozen performance criteria')
    if len(program_hashes) > 1:
        raise ValueError('Candidate changed program identity between invocations')
    if candidate_count:
        native = build_validation(output / 'native.jsonl')
        write_json(output / 'native-validation.json', native)
        if native['verdict']['status'] != 'passed':
            raise ValueError('Native execution identity validation failed')
        if native['counts']['submissions'] != candidate_count:
            raise ValueError('Native submissions differ from accepted invocation work')
        rows = [json.loads(line) for line in (output / 'native.jsonl').read_text(encoding='utf-8').splitlines() if line]
        shaders = {shader['id']: shader for shader in descriptor['shaders']}
        expected_dispatches = Counter((hashlib.sha256(shaders[step['shader']]['code'].encode()).hexdigest(),
            shaders[step['shader']]['entryPoint'], tuple(step['workgroups']), len(step['bindings']))
            for step in descriptor['steps'])
        actual_dispatches = Counter((row['wgslSha256'], row['entryPoint'],
            tuple(row['workgroups']), row['bindingCount']) for row in rows if row['event'] == 'dispatch_encoded')
        repeat = 1 if execution['execution'] == 'gpu-recorded' else candidate_count
        if actual_dispatches != Counter({key: count * repeat for key, count in expected_dispatches.items()}):
            raise ValueError('Native shader identity or dispatch geometry differs from the frozen program')
    if execution['status'] == 'accepted':
        if set(fixtures) != {case['id'] for case in execution['cases']}:
            raise ValueError('Accepted execution omitted frozen acceptance cases')
        if set(execution['teardown']) != {'candidate', 'reference'}:
            raise ValueError('Accepted execution lacks completed cleanup')
    return execution
