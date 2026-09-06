"""Retain every declared evidence path, storing identical bytes once."""
import hashlib
import os
import shutil
import tarfile
import tempfile
from pathlib import Path

root = Path('bench/out/compute-program/20260906-candidate-runner')
names = ['single', 'batched-gpu', 'batched-repeat', 'batched-webgpu', 'batched-native', 'invalid', 'wrong']
with tempfile.TemporaryDirectory(prefix='doe-candidate-archive-') as temporary:
    snapshot = Path(temporary)
    identical = {}
    for name in names:
        for source in sorted((root / name).rglob('*')):
            if not source.is_file() or 'installed-package' in source.relative_to(root / name).parts:
                continue
            digest = hashlib.sha256(source.read_bytes()).digest()
            target = snapshot / source
            target.parent.mkdir(parents=True, exist_ok=True)
            if digest in identical:
                os.link(identical[digest], target)
            else:
                shutil.copy2(source, target)
                identical[digest] = target
    with tarfile.open(root / 'candidate-evidence.tar.xz', 'w:xz', dereference=False) as archive:
        for name in names:
            archive.add(snapshot / root / name, arcname=str(root / name))
