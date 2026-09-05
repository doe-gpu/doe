"""Install the same retained npm artifacts and exercise each controlled host."""
from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import tempfile
from pathlib import Path

import jsonschema

from bench.gates.compute_program_gate import digest

ROOT = Path(__file__).resolve().parents[2]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--node', required=True)
    parser.add_argument('--bun', required=True)
    parser.add_argument('--electron', required=True)
    parser.add_argument('--platform-package', choices=['doe-gpu-linux-x64', 'doe-gpu-darwin-arm64'], required=True)
    parser.add_argument('--lifecycle-cycles', type=int, required=True)
    parser.add_argument('--timeout-ms', type=int, required=True)
    args = parser.parse_args()
    if args.lifecycle_cycles < 3 or args.timeout_ms <= 0:
        parser.error('Require lifecycle-cycles >= 3 and timeout-ms > 0')
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    report = {'schemaVersion': 1, 'kind': 'compute_program_package_qualification',
              'status': 'running', 'error': None, 'packages': [], 'hosts': [], 'artifacts': [],
              'lifecycleCycles': args.lifecycle_cycles, 'timeoutMs': args.timeout_ms,
              'claimStatus': 'diagnostic', 'installation': 'retained-local-tarballs-with-install-scripts',
              'limits': ['Local candidate, not registry publication or release admission',
                         'Electron main process only; no renderer or Chromium provider substitution',
                         'Explicit device destruction tests recovery; no forced driver loss']}
    environment = {key: value for key, value in os.environ.items()
                   if not key.startswith('DOE_') and key not in ('NODE_PATH', 'NODE_OPTIONS', 'ELECTRON_RUN_AS_NODE')}

    def run(command: list[str], cwd: Path, label: str, extra: dict[str, str] | None = None) -> str:
        result = subprocess.run(command, cwd=cwd, env={**environment, **(extra or {})},
                                capture_output=True, text=True, check=False, timeout=args.timeout_ms / 1000)
        (output / f'{label}.stdout').write_text(result.stdout)
        (output / f'{label}.stderr').write_text(result.stderr)
        if result.returncode:
            raise ValueError(f'{label}: exit {result.returncode}; see retained stdout/stderr')
        return result.stdout

    try:
        tarballs = []
        for name in ['doe-gpu', args.platform_package]:
            manifest = json.loads(run(['npm', 'pack', '--ignore-scripts', '--json', '--pack-destination', str(output)],
                                      ROOT / 'packages' / name, f'pack-{name}'))[0]
            path = output / manifest['filename']
            tarballs.append(str(path))
            report['packages'].append({'path': str(path), 'hash': digest(path)})
        fixtures = ROOT / 'packages/doe-gpu/test/fixtures'
        for host in ['node', 'bun', 'electron']:
            executable = Path(shutil.which(getattr(args, host)) or getattr(args, host)).resolve()
            with tempfile.TemporaryDirectory(prefix=f'doe-program-{host}-') as directory:
                scratch = Path(directory)
                (scratch / 'package.json').write_text(json.dumps({'name': 'doe-retained-program-qualification',
                                                                 'private': True, 'type': 'module', 'main': 'entry.mjs'}))
                run(['npm', 'install', '--offline', '--omit=optional', '--no-audit', '--no-fund', *tarballs], scratch, f'{host}-install')
                shutil.copyfile(fixtures / 'native-release-candidate.mjs', scratch / 'candidate.mjs')
                shutil.copyfile(fixtures / 'native-clean-install-lifecycle.mjs', scratch / 'lifecycle.mjs')
                replacements = {'../../src/native.js': 'doe-gpu/native',
                                '../../src/bun.js': 'doe-gpu',
                                '../../src/compute-program.js': 'doe-gpu/compute-program',
                                '../../src/vendor/webgpu/webgpu-constants.js': 'doe-gpu/native'}
                for source in ['runtime/zig/src/backend/vulkan/vk_timestamp_normalize.wgsl',
                               'config/vulkan-timestamp-policy.json']:
                    shutil.copyfile(ROOT / source, scratch / Path(source).name)
                    shutil.copyfile(ROOT / source, output / Path(source).name)
                    replacements[f'../../../../{source}'] = f'./{Path(source).name}'
                for fixture, name in [('plans', 'compute-program'), ('timestamps', 'timestamp-query'),
                                      ('normalization', 'timestamp-normalization')]:
                    regression = (ROOT / f'packages/doe-gpu/test/integration/test-integration-{name}.js').read_text()
                    for before, after in replacements.items():
                        regression = regression.replace(before, after)
                    (scratch / f'{fixture}.mjs').write_text(regression)
                for fixture in ['candidate', 'lifecycle', 'plans', 'timestamps', 'normalization']:
                    entry = f"await import('./{fixture}.mjs');\n"
                    if host == 'electron':
                        entry = "try {\n" + entry + "(await import('electron')).app.exit(0);\n} catch (error) { console.error(error); (await import('electron')).app.exit(1); }\n"
                    (scratch / 'entry.mjs').write_text(entry)
                    shutil.copyfile(scratch / f'{fixture}.mjs', output / f'{host}-{fixture}.mjs')
                    shutil.copyfile(scratch / 'entry.mjs', output / f'{host}-{fixture}-entry.mjs')
                    launch = ['--headless', '--no-sandbox', '--disable-gpu', str(scratch)] if host == 'electron' else [str(scratch / 'entry.mjs')]
                    text = run([str(executable), *launch], scratch, f'{host}-{fixture}',
                               {'DOE_NATIVE_RELEASE_CANDIDATE_RUNTIME': host, 'DOE_NATIVE_LIFECYCLE_RUNTIME': host,
                                'DOE_NATIVE_LIFECYCLE_CYCLES': str(args.lifecycle_cycles)})
                    if fixture == 'plans' and args.platform_package == 'doe-gpu-linux-x64':
                        (scratch / 'entry.mjs').write_text("process.argv.push('--timestamps');\n" + entry)
                        shutil.copyfile(scratch / 'entry.mjs', output / f'{host}-plans-timed-entry.mjs')
                        run([str(executable), *launch], scratch, f'{host}-plans-timed')
                    if host == 'bun' and fixture == 'timestamps':
                        ffi_entry = scratch / 'timestamps-ffi-entry.mjs'
                        ffi_entry.write_text("process.argv.push('--bun-ffi');\n" + entry)
                        shutil.copyfile(ffi_entry, output / 'bun-timestamps-ffi-entry.mjs')
                        run([str(executable), str(ffi_entry)], scratch, 'bun-timestamps-ffi',
                            {'DOE_BUN_WEBGPU_BACKEND': 'ffi'})
                    if fixture == 'candidate':
                        candidate = json.loads(text)
                        receipt = candidate['receipt']
                        if not candidate['ok'] or not candidate['validation']['valid'] or receipt['status'] != 'pass':
                            raise ValueError(f'{host}: governed provider qualification failed')
                        if candidate['output'] != list(range(2, 17, 2)) or receipt['checkpoint'] != 'release-complete':
                            raise ValueError(f'{host}: output or teardown failed')
                    if fixture == 'lifecycle':
                        lifecycle = json.loads(text)
                        provider = lifecycle['provider']
                        library = Path(provider['doeLibraryPath'])
                        if not library.is_relative_to(scratch / 'node_modules' / args.platform_package):
                            raise ValueError(f'{host}: native library escaped clean install')
                        if not provider['doeNative'] or provider['buildMetadataSource'] != 'prebuild':
                            raise ValueError(f'{host}: native provider identity not established')
                report['hosts'].append({'host': host, 'executable': str(executable), 'executableHash': digest(executable),
                                        'libraryHash': digest(library), 'status': 'passed'})
                print(f'qualified retained package: {host}', flush=True)
        if len({host['libraryHash'] for host in report['hosts']}) != 1:
            raise ValueError('Runtime hosts loaded different native libraries')
        report['status'] = 'passed'
    except (ValueError, KeyError, OSError, subprocess.SubprocessError) as error:
        report['status'] = 'failed'
        report['error'] = str(error)
    finally:
        report['artifacts'] = [{'path': str(path), 'hash': digest(path)} for path in sorted(output.iterdir()) if path.is_file()]
        schema = json.loads((ROOT / 'config/compute-program-package.schema.json').read_text())
        jsonschema.Draft202012Validator(schema).validate(report)
        (output / 'summary.json').write_text(json.dumps(report, indent=2, sort_keys=True) + '\n')
    print(json.dumps({'status': report['status'], 'error': report['error'], 'summary': str(output / 'summary.json')}))
    return int(report['status'] != 'passed')


if __name__ == '__main__':
    raise SystemExit(main())
