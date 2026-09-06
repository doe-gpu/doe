"""Generate deterministic distance inputs and independently summed float64 oracles."""
from __future__ import annotations

import array
import hashlib
import json
import math
import struct
import sys
from pathlib import Path

ROWS = 4096
DIMENSIONS = 256
ROOT = Path(__file__).resolve().parent


def main() -> int:
    if sys.byteorder != 'little':
        raise ValueError('Fixture generation requires a little-endian host')
    data_root = ROOT / 'data'
    data_root.mkdir(exist_ok=True)

    def retain(name: str, data: bytes) -> dict[str, str]:
        (ROOT / name).write_bytes(data)
        return {'path': name, 'hash': hashlib.sha256(data).hexdigest()}

    def floats(values: list[float]) -> array.array:
        return array.array('f', values)

    cases = []
    for case in ('zero', 'signed', 'ramp', 'mixed_scale'):
        if case == 'zero':
            database = floats([0] * (ROWS * DIMENSIONS))
            query = floats([0] * DIMENSIONS)
        else:
            database = floats([((index * 17 % 257) - 128) / 128
                               for index in range(ROWS * DIMENSIONS)])
            query = floats([((index * 31 % 257) - 128) / 128 for index in range(DIMENSIONS)])
            if case == 'ramp':
                database = floats([index % DIMENSIONS / DIMENSIONS for index in range(ROWS * DIMENSIONS)])
            elif case == 'mixed_scale':
                database = floats([value * (1024 if index % 2 else 1 / 1024)
                                   for index, value in enumerate(database)])
        expected = array.array('d', [math.fsum((database[row * DIMENSIONS + column] - query[column]) ** 2
                                             for column in range(DIMENSIONS)) for row in range(ROWS)])
        cases.append({'id': case, 'inputs': {
            'database': retain(f'data/{case}.database.f32', database.tobytes()),
            'query': retain(f'data/{case}.query.f32', query.tobytes()),
            'parameters': retain('data/parameters.u32', struct.pack('<4I', ROWS, DIMENSIONS, 0, 0)),
        }, 'expected': retain(f'data/{case}.expected.f64', expected.tobytes())})
    program = {'schemaVersion': 1, 'id': 'vector_distance', 'buffers': [
        {'id': name, 'size': size, 'role': 'output' if name == 'output' else 'input',
         'type': 'uniform' if name == 'parameters' else 'storage'}
        for name, size in [('database', ROWS * DIMENSIONS * 4), ('query', DIMENSIONS * 4),
                           ('parameters', 16), ('output', ROWS * 4)]],
        'shaders': [{'id': 'distance', 'entryPoint': 'main', 'code': (ROOT / 'distance.wgsl').read_text(encoding='utf-8')}],
        'steps': [{'shader': 'distance', 'workgroups': [ROWS, 1, 1],
                   'bindings': [{'binding': index, 'buffer': name} for index, name in enumerate(
                       ['database', 'query', 'parameters', 'output'])]}], 'output': 'output'}
    encoded = lambda value: (json.dumps(value, indent=2, sort_keys=True) + '\n').encode()
    job = {'schemaVersion': 1, 'id': 'vector_distance', 'program': retain('program.json', encoded(program)),
           'candidateShaderId': 'distance', 'reference': retain('reference.mjs', (ROOT / 'reference.mjs').read_bytes()),
           'dependencies': [], 'cases': cases,
           'oracle': {'absoluteTolerance': 1e-5, 'relativeTolerance': 2e-5,
                      'expectedFormat': 'float64-le', 'outputFormat': 'float32-le'},
           'limits': {'jobTimeoutMs': 120000, 'requestTimeoutMs': 10000, 'maximumShaderBytes': 65536,
                      'maximumDeclaredBufferBytes': 8388608, 'maximumWorkgroups': ROWS,
                      'maximumDispatches': 1, 'maximumHeapMiB': 128, 'maximumProcessOutputBytes': 1048576,
                      'maximumFixtureBytes': 33554432},
           'sampling': {'warmupRuns': 5, 'timedRuns': 30, 'percentileMethod': 'nearest-rank'},
           'performance': {'minimumP50Ratio': 1.05, 'minimumP95Ratio': 1.05,
                           'maximumPreparationRecoveryRuns': 1000}}
    reference = retain('job.json', encoded(job))
    print(reference['hash'])
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
