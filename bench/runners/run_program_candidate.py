"""Evaluate a WGSL candidate against a separately pinned acceptance job."""
from __future__ import annotations

import argparse
import json
import os
import signal
import subprocess
from pathlib import Path
from typing import Any

import jsonschema

from bench.lib.compute_program_package import install_qualification
from bench.lib.hash_utils import file_sha256
from bench.lib.program_candidate import environment_record, freeze_job, verify_frozen_inputs, write_json
from bench.lib.program_candidate_evidence import validate_execution

ROOT = Path(__file__).resolve().parents[2]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--job', required=True, type=Path, help='Frozen job manifest')
    parser.add_argument('--job-sha256', required=True, help='Independently pinned acceptance hash')
    parser.add_argument('--candidate', required=True, type=Path, help='WGSL replacing the declared shader')
    parser.add_argument('--package-qualification', required=True, type=Path, help='Exact retained package qualification')
    parser.add_argument('--output', required=True, type=Path, help='New retained evidence directory')
    parser.add_argument('--node', required=True, type=Path, help='Node executable')
    parser.add_argument('--backend', required=True, choices=['vulkan'], help='Physical backend with native replay validation')
    parser.add_argument('--execution', required=True, choices=['gpu-recorded', 'native-recorded', 'webgpu'], help='Explicit prepared execution mode')
    parser.add_argument('--previous', type=Path, help='Prior summary whose environment will be compared after fresh execution')
    args = parser.parse_args()
    output = args.output.resolve()
    if not output.is_relative_to(ROOT):
        parser.error('--output must be inside the repository for native artifact validation')
    if len(args.job_sha256) != 64 or any(value not in '0123456789abcdef' for value in args.job_sha256):
        parser.error('--job-sha256 must be a lowercase SHA-256 digest')
    output.mkdir(parents=True, exist_ok=False)
    report: dict[str, Any] = {
        'schemaVersion': 1, 'kind': 'program_candidate_acceptance',
        'claimStatus': 'diagnostic', 'status': 'rejected', 'error': None,
        'jobHash': args.job_sha256, 'candidateHash': file_sha256(args.candidate),
        'environmentHash': None, 'previous': None, 'environmentChanged': None,
        'requalification': 'fresh-execution-required', 'artifacts': [],
    }
    try:
        previous = None
        if args.previous:
            previous = json.loads(args.previous.read_text(encoding='utf-8'))
            schema = json.loads((ROOT / 'config/program-candidate-report.schema.json').read_text(encoding='utf-8'))
            jsonschema.Draft202012Validator(schema).validate(previous)
            if previous['jobHash'] != args.job_sha256:
                raise ValueError('Previous result belongs to a different acceptance job')
            for artifact in previous['artifacts']:
                source = (args.previous.parent / artifact['path']).resolve()
                if (not source.is_relative_to(args.previous.parent.resolve())
                        or file_sha256(source) != artifact['hash']):
                    raise ValueError('Previous result has missing or changed evidence')
            if (previous['environmentHash'] is not None
                    and file_sha256(args.previous.parent / 'environment.json') != previous['environmentHash']):
                raise ValueError('Previous environment identity differs from its retained bytes')
            (output / 'previous.json').write_bytes(args.previous.read_bytes())
            report['previous'] = {'path': 'previous.json', 'hash': file_sha256(output / 'previous.json')}
        job = freeze_job(args.job.resolve(), args.job_sha256,
                         args.candidate.resolve(), output, ROOT)
        package_root = install_qualification(args.package_qualification.resolve(),
                                             output, ROOT, job['limits']['jobTimeoutMs'])
        environment = {key: value for key, value in os.environ.items()
                       if not key.startswith('DOE_') and key not in
                       ('NODE_PATH', 'NODE_OPTIONS', 'ELECTRON_RUN_AS_NODE')}
        command = [str(args.node.resolve()), str(ROOT / 'bench/runners/run-program-candidate.mjs'),
                   str(output), str(package_root), args.backend, args.execution]
        write_json(output / 'command.json', command)
        with (output / 'controller.stdout').open('w', encoding='utf-8') as stdout, (
                output / 'controller.stderr').open('w', encoding='utf-8') as stderr:
            process = subprocess.Popen(command, cwd=ROOT, env=environment,
                                       stdout=stdout, stderr=stderr, start_new_session=True)
            try:
                # Node owns child deadlines and cleanup; the outer bound also
                # catches a broken controller rather than trusting its report.
                process.wait(timeout=(job['limits']['jobTimeoutMs']
                                      + job['limits']['requestTimeoutMs']) / 1000)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGTERM)
                try:
                    process.wait(timeout=job['limits']['requestTimeoutMs'] / 1000)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait()
                raise ValueError('Candidate controller exceeded the outer deadline')
        verify_frozen_inputs(output)
        if file_sha256(output / 'job.json') != args.job_sha256:
            raise ValueError('Acceptance job changed during execution')
        if file_sha256(output / 'candidate.wgsl') != report['candidateHash']:
            raise ValueError('Candidate changed during execution')
        execution = validate_execution(output, job, ROOT)
        if execution['environment']:
            stable = environment_record(execution['environment'], execution['backend'], execution['execution'])
            write_json(output / 'environment.json', stable)
            report['environmentHash'] = file_sha256(output / 'environment.json')
            if previous and previous['environmentHash'] is not None:
                report['environmentChanged'] = report['environmentHash'] != previous['environmentHash']
        if process.returncode == 0 and execution['status'] == 'accepted':
            report['status'] = 'accepted'
        else:
            report['error'] = (execution['error'] or {}).get('message', 'Frozen performance criteria were not met')
    except (ValueError, OSError, jsonschema.ValidationError) as error:
        report['error'] = str(error)
    sources = output / 'sources'
    sources.mkdir()
    paths = [ROOT / 'bench/cli.py', *[ROOT / path for path in [
        'bench/runners/run_program_candidate.py', 'bench/runners/run-program-candidate.mjs',
        'bench/runners/program-candidate-worker.mjs', 'bench/lib/program_candidate.py',
        'bench/lib/program_candidate_evidence.py', 'bench/lib/compute_program_package.py',
        'bench/shared/lib/stats.js', 'bench/oracles/compute-programs.mjs',
        'packages/doe-gpu/src/node-process-requests.js',
        'packages/doe-gpu/src/node-process-termination.js',
        'config/program-candidate.schema.json', 'config/program-candidate-execution.schema.json',
        'config/program-candidate-report.schema.json', 'config/compute-program.schema.json',
        'config/compute-program-run.schema.json', 'bench/lib/hash_utils.py',
        'bench/lib/native_program_replay.py', 'bench/native_compare_modules/reporting.py',
        'bench/tools/validate_native_program_identity_trace.py',
        'config/native-program-identity-trace-row.schema.json']]]
    for path in paths:
        target = sources / path.relative_to(ROOT)
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(path.read_bytes())
    revision = subprocess.run(['git', 'rev-parse', 'HEAD'], cwd=ROOT,
                              capture_output=True, text=True, check=True)
    (output / 'workspace-head.txt').write_text(revision.stdout, encoding='utf-8')
    report['artifacts'] = [{'path': path.relative_to(output).as_posix(), 'hash': file_sha256(path)}
                           for path in sorted(output.rglob('*'))
                           if path.is_file() and 'installed-package' not in path.relative_to(output).parts]
    schema = json.loads((ROOT / 'config/program-candidate-report.schema.json').read_text(encoding='utf-8'))
    jsonschema.Draft202012Validator(schema).validate(report)
    write_json(output / 'summary.json', report)
    print(json.dumps({'status': report['status'], 'error': report['error'], 'summary': str(output / 'summary.json')}))
    return 0 if report['status'] == 'accepted' else 1


if __name__ == '__main__':
    raise SystemExit(main())
