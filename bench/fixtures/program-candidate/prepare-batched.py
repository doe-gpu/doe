"""Freeze a distinct batched search job; preserve the single-query acceptance."""
from __future__ import annotations

import array
import copy
import hashlib
import json
import math
import struct
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
QUERIES = 16


def main() -> int:
    if sys.byteorder != 'little':
        raise ValueError('Fixture generation requires a little-endian host')
    job = copy.deepcopy(json.loads((ROOT / 'job.json').read_text(encoding='utf-8')))
    program = json.loads((ROOT / job['program']['path']).read_text(encoding='utf-8'))
    rows, dimensions, _, _ = struct.unpack('<4I', (ROOT / 'data/parameters.u32').read_bytes())

    def retain(name: str, data: bytes) -> dict[str, str]:
        (ROOT / name).write_bytes(data)
        return {'path': name, 'hash': hashlib.sha256(data).hexdigest()}

    def encoded(value: dict) -> bytes:
        return (json.dumps(value, indent=2, sort_keys=True) + '\n').encode()

    code = (ROOT / 'distance.wgsl').read_text(encoding='utf-8')
    if code.count('query[column]') != 1 or code.count('output[row]') != 1:
        raise ValueError('Single-query shader changed; batch construction must be reviewed')
    code = code.replace('query[column]', 'query[group.y * parameters.dimensions + column]')
    code = code.replace('output[row]', 'output[group.y * parameters.rows + row]')
    retain('batched-distance.wgsl', code.encode())
    program['id'] = 'batched_vector_distance'
    program['shaders'][0]['code'] = code
    for buffer in program['buffers']:
        if buffer['id'] in ('query', 'output'):
            buffer['size'] *= QUERIES
    program['steps'][0]['workgroups'][1] = QUERIES
    job['id'] = program['id']
    job['program'] = retain('batched-program.json', encoded(program))
    job['dependencies'] = [job['reference']]
    job['reference'] = retain('batched-reference.mjs', (ROOT / 'batched-reference.mjs').read_bytes())
    job['limits']['maximumWorkgroups'] *= QUERIES
    for case in job['cases']:
        database = array.array('f')
        database.frombytes((ROOT / case['inputs']['database']['path']).read_bytes())
        query = array.array('f')
        query.frombytes((ROOT / case['inputs']['query']['path']).read_bytes())
        queries = array.array('f', [value + (index / QUERIES if case['id'] != 'zero' else 0)
                                   for index in range(QUERIES) for value in query])
        expected = array.array('d', [math.fsum((database[row * dimensions + column]
                                    - queries[index * dimensions + column]) ** 2
                                    for column in range(dimensions))
                                    for index in range(QUERIES) for row in range(rows)])
        case['inputs']['query'] = retain(f"data/{case['id']}.batched-query.f32", queries.tobytes())
        case['inputs']['parameters'] = retain('data/batched-parameters.u32', struct.pack('<4I', rows, dimensions, QUERIES, 0))
        case['expected'] = retain(f"data/{case['id']}.batched-expected.f64", expected.tobytes())
    print(retain('batched-job.json', encoded(job))['hash'])
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
