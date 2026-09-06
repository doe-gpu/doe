"""Retain every evidence path while storing identical bytes once in the archive."""
import hashlib
import os
import shutil
from pathlib import Path
import tarfile
import tempfile

root = Path('bench/out/compute-program/20260906-live-simulation-applications')
archive = Path('bench/out/compute-program/20260906-live-simulation-correction/application-comparison.tar.xz')
with tempfile.TemporaryDirectory(prefix='doe-evidence-archive-') as temporary:
    target_root = Path(temporary)
    identical = {}
    for source in sorted(root.rglob('*')):
        if not source.is_file():
            continue
        digest = hashlib.sha256(source.read_bytes()).digest()
        destination = target_root / source
        destination.parent.mkdir(parents=True, exist_ok=True)
        previous = identical.get(digest)
        if previous is None:
            shutil.copy2(source, destination)
            identical[digest] = destination
        else:
            os.link(previous, destination)
    with tarfile.open(archive, 'w:xz', dereference=False) as output:
        output.add(target_root / root, arcname=str(root))
