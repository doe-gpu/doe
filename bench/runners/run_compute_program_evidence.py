"""Sequential AMD Vulkan or Apple Metal application evaluation and native audit."""
from __future__ import annotations

import argparse
import json
import math
import os
import re
import shutil
import subprocess
from pathlib import Path
from typing import Any

import jsonschema

from bench.gates.compute_program_gate import completion_mode, digest, validate_run
from bench.lib.compute_program_fixture import fixture_references, load_fixture
from bench.lib.compute_program_package import (
    install_qualification,
    load_qualification,
    validate_package_root,
)
from bench.native_compare_modules.reporting import format_stats

ROOT = Path(__file__).resolve().parents[2]


def same_adapter(candidate: dict[str, Any], control: dict[str, Any]) -> bool:
    if candidate['isFallbackAdapter'] is not False or control['isFallbackAdapter'] is not False:
        return False
    if control['vendorID'] is not None and control['deviceID'] is not None:
        return (candidate['vendorID'], candidate['deviceID']) == (control['vendorID'], control['deviceID'])
    if str(control['vendor']).isdigit() and str(control['device']).isdigit():
        return (candidate['vendorID'], candidate['deviceID']) == (int(control['vendor']), int(control['device']))
    normalize = lambda value: re.sub(r'[^a-z0-9]', '', str(value).lower())
    return (normalize(candidate['vendor']) == normalize(control['vendor'])
            and normalize(candidate['device']) == normalize(control['device']))


def run_child(
    provider: str, application: str, phase: str, output: Path,
    policy_path: Path, policy: dict[str, Any], backend: str,
    node: str, deno: str, native_library: Path | None,
    package_root: Path | None = None, package_qualification: Path | None = None,
) -> dict[str, Any]:
    command = [node]
    environment = dict(os.environ)
    if package_root is not None:
        environment = {key: value for key, value in environment.items()
                       if not key.startswith('DOE_') and key not in ('NODE_PATH', 'NODE_OPTIONS', 'ELECTRON_RUN_AS_NODE')}
    environment.pop("DOE_PROGRAM_IDENTITY_TRACE_PATH", None)
    if provider == "wgpu":
        command = [deno, "run", "--allow-all", "--unstable-webgpu"]
        environment["DENO_WEBGPU_BACKEND"] = backend
    if provider.startswith("doe-"):
        if package_root is None:
            if native_library is None:
                raise ValueError('Doe evaluation requires a native library or a qualified package')
            environment["DOE_WEBGPU_LIB"] = str(native_library)
        if phase == "audit" and backend == "vulkan":
            journal = Path(f"{output}.native.jsonl")
            journal.write_text("", encoding="utf-8")
            environment["DOE_PROGRAM_IDENTITY_TRACE_PATH"] = str(journal)
    command += [
        "bench/runners/run-compute-program.mjs", f"--provider={provider}",
        f"--application={application}", f"--phase={phase}",
        f"--output={output}", f"--policy={policy_path}", f"--backend={backend}",
    ]
    if package_root is not None:
        command += [f'--package-root={package_root}', f'--package-qualification={package_qualification}']
    if policy.get('gpuTiming', 'off') != 'off' and backend == 'vulkan':
        command.append(f'--hardware={output.parent / "hardware-profile.json"}')
    result = subprocess.run(command, cwd=ROOT, env=environment, capture_output=True,
                            text=True, timeout=policy["processTimeoutMs"] / 1000, check=False)
    Path(f"{output}.stdout").write_text(result.stdout, encoding="utf-8")
    Path(f"{output}.stderr").write_text(result.stderr, encoding="utf-8")
    if result.returncode:
        raise ValueError(f"{provider}/{application}/{phase}: failed; see {output}.stderr and {output}")
    report = validate_run(output, ROOT, policy)
    if report["policyHash"] != digest(policy_path):
        raise ValueError(f"{output}: evaluation policy changed")
    return report


def comparison_rows(reports: list[tuple[Path, dict[str, Any]]], policy: dict[str, Any]) -> list[dict[str, Any]]:
    def statistics(values: list[float]) -> dict[str, float]:
        return format_stats(values, percentile_method=policy["percentileMethod"])

    rows = []
    reliability = json.loads((ROOT / 'config/benchmark-methodology-thresholds.json').read_text())['reliability']
    for application in policy["applications"]:
        completion_modes = {
            completion_mode(sample['receipt'])
            for _, report in reports if report['application'] == application
            for sample in [report['cold'], *report.get('warmups', []), *report['samples'], *report.get('lifecycleRuns', [])]
        }
        if len(completion_modes) != 1:
            raise ValueError(f'{application}: mixed completion timing scopes')
        package_sources = {
            (report.get('packageQualification', {}).get('hash') if report.get('packageQualification') else None,
             report.get('packageRoot'))
            for _, report in reports if report['application'] == application
        }
        if len(package_sources) != 1:
            raise ValueError(f'{application}: mixed package execution sources')
        groups = {
            provider: [(path, report) for path, report in reports
                       if report["application"] == application and report["provider"] == provider
                       and report["phase"] == "measure"]
            for provider in policy["providers"]
        }
        doe = groups["doe-recorded"]
        for comparator in (provider for provider in groups if provider != "doe-recorded"):
            control = groups[comparator]
            if not doe or not control:
                continue
            identities = {report["programHash"] for _, report in [*doe, *control]}
            inputs = {json.dumps(report["cold"]["receipt"]["inputHashes"], sort_keys=True) for _, report in [*doe, *control]}
            if len(identities) != 1 or len(inputs) != 1 or not all(
                    same_adapter(doe[0][1]['adapter'], report['adapter']) for _, report in [*doe, *control]):
                raise ValueError(f"{application}/{comparator}: workload or hardware mismatch")
            candidate_stats = statistics([sample["wallMs"] for _, report in doe for sample in report["samples"]])
            control_stats = statistics([sample["wallMs"] for _, report in control for sample in report["samples"]])
            doe_cpu = statistics([sample["cpuMs"] for _, report in doe for sample in report["samples"]])
            control_cpu = statistics([sample["cpuMs"] for _, report in control for sample in report["samples"]])
            saved = control_stats["p50Ms"] - candidate_stats["p50Ms"]
            preparation_delta = sum(report["preparationMs"] for _, report in doe) / len(doe) - sum(
                report["preparationMs"] for _, report in control) / len(control)
            rows.append({
                "rowId": f"{application}_vs_{comparator}", "backend": doe[0][1]["backend"],
                "comparator": comparator, "claimStatus": "diagnostic",
                "baselineStatsMs": candidate_stats, "comparisonStatsMs": control_stats,
                "p50SpeedRatio": control_stats["p50Ms"] / candidate_stats["p50Ms"],
                "p95SpeedRatio": control_stats["p95Ms"] / candidate_stats["p95Ms"],
                "p99SpeedRatio": control_stats["p99Ms"] / candidate_stats["p99Ms"],
                "cpuP95Ratio": control_cpu["p95Ms"] / doe_cpu["p95Ms"],
                "suspiciousSpeedup": control_stats['p50Ms'] / candidate_stats['p50Ms'] >= reliability['suspiciousSpeedupRatio'],
                "preparationRecoveredAfterRuns": max(0, math.ceil(preparation_delta / saved)) if saved > 0 else None,
                "deadlineCrossing": candidate_stats["p95Ms"] <= policy["interactiveDeadlineMs"] < control_stats["p95Ms"],
                "cpuOutcome": control_cpu["p95Ms"] >= doe_cpu["p95Ms"] * policy["minimumCpuReductionRatio"],
                "artifactPaths": [str(path) for path, _ in [*doe, *control]],
                "caveat": "Application invocation wall; persistent resources on both sides. GPU recording owns its compiled command buffer; preparation is measured separately. wgpu uses Deno and includes its host/polling costs. Requested buffer bytes are not peak GPU memory. No independent adoption or Metal transfer is inferred.",
            })
    return rows


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--backend", required=True, choices=["vulkan", "metal"], help="Physical backend to evaluate")
    parser.add_argument("--output", type=Path, required=True, help="New evidence directory")
    parser.add_argument("--node", default="node", help="Node-compatible runtime executable")
    parser.add_argument("--deno", required=True, help="Pinned Deno executable for wgpu control")
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--native-library", type=Path, help="Built Doe native library")
    source.add_argument("--package-qualification", type=Path, help="Passed qualify-package summary; installs those exact retained archives")
    parser.add_argument("--policy", type=Path, default=ROOT / "config/compute-program-evaluation.json", help="Frozen evaluation policy")
    args = parser.parse_args()
    policy = json.loads(args.policy.read_text(encoding="utf-8"))
    schema = json.loads((ROOT / "config/compute-program-evaluation.schema.json").read_text())
    jsonschema.Draft202012Validator(schema).validate(policy)
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    original_policy = args.policy.resolve()
    for reference in policy.get('timestampSources', []):
        if digest(ROOT / reference['path']) != reference['hash']:
            raise ValueError(f'Timestamp implementation source changed: {reference["path"]}')
    for application, reference in policy.get('fixtures', {}).items():
        if application not in policy['applications']:
            raise ValueError(f'Unused fixture {application}')
        fixture_path = Path(reference['path']).resolve()
        fixture = load_fixture(fixture_path, ROOT, reference['hash'])
        if fixture['application'] != application:
            raise ValueError(f'Fixture application mismatch for {application}')
        destination = output / 'fixtures' / application
        destination.mkdir(parents=True)
        if sequence := fixture.get('sequence'):
            required_runs = max(3, 1 + policy['warmupRuns'] + policy['timedRuns'])
            if len(sequence['expected']) < required_runs:
                raise ValueError(f'Fixture sequence {application} requires {required_runs} frozen oracle states')
        references = fixture_references(fixture)
        for artifact in references:
            retained = destination / artifact['path']
            retained.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(fixture_path.parent / artifact['path'], retained)
        shutil.copyfile(fixture_path, destination / 'fixture.json')
        reference['path'] = str(destination / 'fixture.json')
    args.policy = output / 'policy.json'
    args.policy.write_text(json.dumps(policy, indent=2) + '\n', encoding='utf-8')
    reports: list[tuple[Path, dict[str, Any]]] = []
    summary: dict[str, Any] = {"schemaVersion": 1, "kind": "compute_program_matrix", "status": "running",
                               "policyHash": digest(args.policy), "backend": args.backend,
                               "rows": [], "artifacts": [], "sources": [], "error": None}
    source_paths = [Path(__file__), ROOT / 'bench/runners/run-compute-program.mjs',
                    ROOT / 'bench/gates/compute_program_gate.py', ROOT / 'bench/oracles/compute-programs.mjs',
                    ROOT / 'bench/shared/lib/stats.js', ROOT / 'bench/native_compare_modules/reporting.py',
                    ROOT / 'bench/lib/hash_utils.py', ROOT / 'bench/lib/native_program_replay.py', args.policy.resolve(),
                    ROOT / 'bench/lib/compute_program_fixture.py', original_policy,
                    ROOT / 'config/benchmark-methodology-thresholds.json',
                    ROOT / 'config/vulkan-buffer-memory-policy.json',
                    ROOT / 'config/vulkan-timestamp-policy.json',
                    ROOT / 'config/spirv-compute-arithmetic-policy.json',
                    ROOT / 'config/spirv-compute-arithmetic-policy.schema.json',
                    ROOT / 'runtime/zig/src/backend/vulkan/vk_timestamp_normalize.wgsl',
                    ROOT / 'runtime/zig/build.zig',
                    ROOT / 'packages/doe-gpu/examples/compute-programs.js']
    source_paths += list((ROOT / 'packages/doe-gpu/src').rglob('*.js'))
    source_paths += list((ROOT / 'runtime/zig/src').rglob('*.zig'))
    source_paths += list((ROOT / 'runtime/bridge/webgpu-addon').glob('*.c'))
    source_paths += list((ROOT / 'runtime/bridge/webgpu-addon').glob('*.h'))
    source_paths += list((ROOT / 'config').glob('compute-program*.schema.json'))
    source_paths += [ROOT / reference['path'] for reference in policy.get('timestampSources', [])]
    source_paths += [ROOT / 'bench/lib/compute_program_package.py', ROOT / 'config/compute-program-package.schema.json']
    source_paths += [ROOT / 'bench/package.json', ROOT / 'bench/package-lock.json']
    if args.package_qualification is not None:
        source_paths.append(args.package_qualification.resolve())
    original_sources = []
    for path in sorted(set(source_paths)):
        source = path.resolve()
        relative = source.relative_to(ROOT) if source.is_relative_to(ROOT) else Path('external') / source.name
        retained = output / 'sources' / relative
        retained.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, retained)
        identity = digest(retained)
        original_sources.append({'path': str(source), 'hash': identity})
        summary['sources'].append({'path': str(retained), 'hash': identity})
    try:
        package_root = None
        if args.package_qualification is not None:
            package_root = install_qualification(args.package_qualification.resolve(), output, ROOT, policy['processTimeoutMs'])
            args.package_qualification = output / 'package-inputs/summary.json'
        native_library = args.native_library.resolve() if args.native_library is not None else None
        inventory_command = ['vulkaninfo', '--summary'] if args.backend == 'vulkan' else ['system_profiler', 'SPDisplaysDataType', '-json']
        inventory = subprocess.run(inventory_command, capture_output=True, text=True, check=True, timeout=policy['processTimeoutMs'] / 1000)
        (output / 'hardware.txt').write_text(inventory.stdout + inventory.stderr)
        if policy.get('gpuTiming', 'off') != 'off' and args.backend == 'vulkan':
            subprocess.run(['vulkaninfo', f'--json={policy["vulkanDeviceIndex"]}',
                            '-o', str(output / 'hardware-profile.json')],
                           capture_output=True, check=True, timeout=policy['processTimeoutMs'] / 1000)
        # Audit all providers before interpreting any measurements.
        for application in policy["applications"]:
            for provider in policy["providers"]:
                path = output / f"{application}.{provider}.audit.json"
                report = run_child(provider, application, "audit", path, args.policy, policy,
                                   args.backend, args.node, args.deno, native_library, package_root, args.package_qualification)
                reports.append((path, report))
                print(f"audit passed: {application}/{provider}", flush=True)
        for process_index in range(policy["processRuns"]):
            providers = policy["providers"]
            rotated = providers[process_index % len(providers):] + providers[:process_index % len(providers)]
            for application in policy["applications"]:
                for provider in rotated:
                    path = output / f"{application}.{provider}.process-{process_index}.json"
                    report = run_child(provider, application, "measure", path, args.policy, policy,
                                       args.backend, args.node, args.deno, native_library, package_root, args.package_qualification)
                    reports.append((path, report))
                    print(f"measured: {application}/{provider}/process-{process_index}", flush=True)
        if package_root is not None:
            validate_package_root(package_root, load_qualification(args.package_qualification, ROOT))
        summary["rows"] = comparison_rows(reports, policy)
        summary["status"] = "diagnostic"
    except (ValueError, OSError, subprocess.SubprocessError, jsonschema.ValidationError) as error:
        summary["status"] = "failed"
        summary["error"] = str(error)
    finally:
        summary["artifacts"] = [{"path": str(path), "hash": digest(path)} for path in sorted(output.rglob('*'))
                                if path.is_file() and not path.is_relative_to(output / 'sources')]
        if any(digest(Path(source['path'])) != source['hash'] for source in original_sources):
            summary['status'] = 'failed'
            summary['error'] = 'Evaluation implementation changed during execution'
        summary_schema = json.loads((ROOT / 'config/compute-program-matrix.schema.json').read_text())
        jsonschema.Draft202012Validator(summary_schema).validate(summary)
        (output / "summary.json").write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(json.dumps({"summary": str(output / "summary.json"), "status": summary["status"], "error": summary["error"]}))
    return int(summary["status"] == "failed")


if __name__ == "__main__":
    raise SystemExit(main())
