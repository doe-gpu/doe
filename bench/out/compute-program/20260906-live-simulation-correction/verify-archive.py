"""Verify retained contents and hard links against every matrix artifact hash."""
import hashlib
import json
from pathlib import Path
import tarfile

root = Path.cwd()
checkpoint = root / 'bench/out/compute-program/20260906-live-simulation-correction'
summary = json.loads((root / 'bench/out/compute-program/20260906-live-simulation-applications/summary.json').read_text())
expected = {str(Path(item['path']).relative_to(root)): item['hash'] for item in [*summary['artifacts'], *summary['sources']]}
observed = {}
with tarfile.open(checkpoint / 'application-comparison.tar.xz', 'r|xz') as archive:
    for member in archive:
        if member.isdir():
            continue
        if member.islnk():
            digest = observed[member.linkname]
        elif member.isfile():
            digest = hashlib.sha256(archive.extractfile(member).read()).hexdigest()
        else:
            raise ValueError(f'Unexpected archive member type: {member.name}')
        if member.name in expected and digest != expected[member.name]:
            raise ValueError(f'Archive hash mismatch: {member.name}')
        observed[member.name] = digest
missing = set(expected) - set(observed)
if missing:
    raise ValueError(f'Missing matrix inputs: {sorted(missing)}')
print(f'PASS: {len(expected)} referenced paths verified; {len(observed)} retained file paths')
