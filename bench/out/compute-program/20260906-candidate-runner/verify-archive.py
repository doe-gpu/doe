"""Verify every archived summary reference without relying on installed projects."""
import hashlib
import json
import tarfile
from pathlib import Path, PurePosixPath

root = Path('bench/out/compute-program/20260906-candidate-runner')
observed = {}
expected = {}
summaries = {}
with tarfile.open(root / 'candidate-evidence.tar.xz', 'r|xz') as archive:
    for member in archive:
        if member.isdir():
            continue
        data = None
        if member.islnk():
            digest = observed[member.linkname]
        elif member.isfile():
            data = archive.extractfile(member).read()
            digest = hashlib.sha256(data).hexdigest()
        else:
            raise ValueError(f'Unexpected member type: {member.name}')
        observed[member.name] = digest
        if member.name.endswith('/summary.json'):
            if data is not None:
                summaries[digest] = json.loads(data)
            summary = summaries[digest]
            parent = PurePosixPath(member.name).parent
            for item in summary['artifacts']:
                path = PurePosixPath(item['path'])
                if path.is_absolute() or '..' in path.parts:
                    raise ValueError('Manifest reference escapes its evidence root')
                expected[str(parent / path)] = item['hash']
for path, digest in expected.items():
    if observed.get(path) != digest:
        raise ValueError(f'Missing or changed evidence: {path}')
print(f'PASS: {len(expected)} manifest references verified across {len(observed)} archived paths')
