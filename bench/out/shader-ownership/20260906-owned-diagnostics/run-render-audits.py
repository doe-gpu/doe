from pathlib import Path
import json
import shutil
import subprocess
from bench.lib.compute_program_package import install_qualification
from bench.lib.compute_program_fixture import load_fixture, fixture_references
from bench.runners.run_compute_program_evidence import run_child

root = Path.cwd()
output = root / 'bench/out/compute-program/20260906-render-ownership-audits'
output.mkdir(exist_ok=False)
qualification = root / 'bench/out/compute-program/20260906-render-ownership-qualified/summary.json'
policy = json.loads((root / 'config/compute-program-external-evaluation.json').read_text())
package = install_qualification(qualification, output, root, policy['processTimeoutMs'])
for application, reference in policy['fixtures'].items():
    source = root / reference['path']
    fixture = load_fixture(source, root, reference['hash'])
    destination = output / 'fixtures' / application
    destination.mkdir(parents=True)
    for artifact in fixture_references(fixture):
        retained = destination / artifact['path']
        retained.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source.parent / artifact['path'], retained)
    shutil.copyfile(source, destination / 'fixture.json')
    reference['path'] = str(destination / 'fixture.json')
policy_path = output / 'policy.json'
policy_path.write_text(json.dumps(policy, indent=2) + '\n')
for application in policy['applications']:
    for provider in ('doe-recorded', 'doe-webgpu'):
        target = output / f'{application}.{provider}.audit.json'
        run_child(provider, application, 'audit', target, policy_path, policy,
                  'vulkan', '/usr/bin/node', '/tmp/doe-deno-2.9.6', None,
                  package, qualification)
        subprocess.run(['python3', 'bench/cli.py', 'program', 'verify-native',
                        '--trace', f'{target}.native.jsonl', '--spirv-val', '/usr/bin/spirv-val',
                        '--out', f'{target}.verification.json'], check=True)
        print(f'passed: {application}/{provider}', flush=True)
