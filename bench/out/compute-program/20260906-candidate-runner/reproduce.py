"""Retained invocation recipe; acceptance remains in each pinned job."""
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[4]
OUTPUT = Path(__file__).resolve().parent
QUALIFICATION = ROOT / 'bench/out/compute-program/20260906-candidate-qualified/summary.json'
CASES = [
    ('single', 'job.json', '2fd8a1c733bf82fbd13231d1f4a0cad2bf4bc575d7523475a841a8cb2477ebbb', 'bench/fixtures/program-candidate/distance.wgsl', 'gpu-recorded', None, 1),
    ('batched-gpu', 'batched-job.json', '5f337544a7551a4e07caad57f14574a07cf23fc70607d34a9ce24920fcb03f13', 'bench/fixtures/program-candidate/batched-distance.wgsl', 'gpu-recorded', None, 0),
    ('batched-repeat', 'batched-job.json', '5f337544a7551a4e07caad57f14574a07cf23fc70607d34a9ce24920fcb03f13', 'bench/fixtures/program-candidate/batched-distance.wgsl', 'gpu-recorded', 'batched-gpu', 0),
    ('batched-webgpu', 'batched-job.json', '5f337544a7551a4e07caad57f14574a07cf23fc70607d34a9ce24920fcb03f13', 'bench/fixtures/program-candidate/batched-distance.wgsl', 'webgpu', 'batched-repeat', 0),
    ('batched-native', 'batched-job.json', '5f337544a7551a4e07caad57f14574a07cf23fc70607d34a9ce24920fcb03f13', 'bench/fixtures/program-candidate/batched-distance.wgsl', 'native-recorded', 'batched-webgpu', 0),
    ('invalid', 'batched-job.json', '5f337544a7551a4e07caad57f14574a07cf23fc70607d34a9ce24920fcb03f13', 'bench/out/compute-program/20260906-candidate-probes/invalid.wgsl', 'gpu-recorded', None, 1),
    ('wrong', 'batched-job.json', '5f337544a7551a4e07caad57f14574a07cf23fc70607d34a9ce24920fcb03f13', 'bench/out/compute-program/20260906-candidate-probes/wrong.wgsl', 'gpu-recorded', None, 1),
]
for name, job, job_hash, candidate, mode, previous, expected in CASES:
    command = ['python3', 'bench/cli.py', 'program', 'candidate',
        '--job', f'bench/fixtures/program-candidate/{job}', '--job-sha256', job_hash,
        '--candidate', candidate, '--package-qualification', str(QUALIFICATION),
        '--output', str(OUTPUT / name), '--node', '/usr/bin/node', '--backend', 'vulkan', '--execution', mode]
    if previous:
        command += ['--previous', str(OUTPUT / previous / 'summary.json')]
    with (OUTPUT / f'{name}.log').open('w') as log:
        result = subprocess.run(command, cwd=ROOT, stdout=log, stderr=log)
    print(name, result.returncode, flush=True)
    if result.returncode != expected:
        raise RuntimeError(f'Unexpected outcome for {name}; inspect its retained report')
