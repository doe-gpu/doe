"""Validate fixed-shape program evidence without granting speed or adoption claims."""
from __future__ import annotations

import hashlib
import json
import math
import struct
from pathlib import Path
from typing import Any

import jsonschema


from bench.lib.hash_utils import file_sha256 as digest
from bench.lib.native_program_replay import validate_gpu_replays
from bench.lib.compute_program_fixture import load_fixture, accepts


def validate_run(path: Path, root: Path, policy: dict[str, Any]) -> dict[str, Any]:
    report = json.loads(path.read_text(encoding="utf-8"))
    schema = json.loads((root / "config/compute-program-run.schema.json").read_text())
    jsonschema.Draft202012Validator(schema).validate(report)
    if report["status"] != "passed":
        raise ValueError(f"{path}: provider failed: {report['error']}")
    if report['error'] is not None or report['provider'] not in policy['providers'] or report['application'] not in policy['applications']:
        raise ValueError(f'{path}: run is outside the frozen evaluation policy')
    if report['adapter']['isFallbackAdapter'] is not False:
        raise ValueError(f'{path}: fallback state is not explicitly physical')
    program_path = root / report["programPath"]
    program = json.loads(program_path.read_text(encoding="utf-8"))
    program_schema = json.loads((root / "config/compute-program.schema.json").read_text())
    jsonschema.Draft202012Validator(program_schema).validate(program)
    canonical = json.dumps(program, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
    program_hash = hashlib.sha256(canonical.encode()).hexdigest()
    if program_hash != report["programHash"]:
        raise ValueError(f"{path}: program identity mismatch")
    artifact = report["providerArtifact"]
    if digest(Path(artifact["path"])) != artifact["hash"]:
        raise ValueError(f"{path}: provider bytes changed")
    expected_samples = policy["timedRuns"] if report["phase"] == "measure" else 1
    if len(report["samples"]) != expected_samples:
        raise ValueError(f"{path}: timed-sample count mismatch")
    input_paths = report.get('inputPaths', {'input': report.get('inputPath')})
    declared_inputs = {buffer['id']: buffer['size'] for buffer in program['buffers'] if buffer['role'] == 'input'}
    if set(input_paths) != set(declared_inputs) or any(
            (root / filename).stat().st_size != declared_inputs[name] for name, filename in input_paths.items()):
        raise ValueError(f'{path}: input identities or extents do not match declared resources')
    input_hashes = {name: digest(root / filename) for name, filename in input_paths.items()}
    checks = []
    fixture_reference = policy.get('fixtures', {}).get(report['application'])
    if fixture_reference:
        if not report.get('fixturePath'):
            raise ValueError(f'{path}: missing frozen external fixture')
        fixture_path = root / report['fixturePath']
        fixture = load_fixture(fixture_path, root, fixture_reference['hash'])
        if (fixture['application'] != report['application']
                or fixture['program']['hash'] != digest(program_path)
                or fixture['expected']['hash'] != digest(root / report['expectedPath'])
                or {name: reference['hash'] for name, reference in fixture['inputs'].items()} != input_hashes):
            raise ValueError(f'{path}: external source, input or oracle differs from the frozen fixture')
        checks = fixture['checks']
    elif report.get('fixturePath'):
        raise ValueError(f'{path}: external fixture is not declared in the policy')
    expected = [value[0] for value in struct.iter_unpack('<d', (root / report['expectedPath']).read_bytes())]
    for index, sample in enumerate([report["cold"], *report["samples"]]):
        receipt = sample["receipt"]
        expected_run = 1 if index == 0 else index + 1 + (policy['warmupRuns'] if report['phase'] == 'measure' else 0)
        expected_execution = policy['preparedExecution'] if report['provider'] == 'doe-recorded' else 'webgpu'
        if receipt['run'] != expected_run or receipt['execution'] != expected_execution:
            raise ValueError(f'{path}: repeat accounting or execution treatment mismatch')
        output_bytes = (root / sample['outputPath']).read_bytes()
        if hashlib.sha256(output_bytes).hexdigest() != receipt['outputHash']:
            raise ValueError(f"{path}: output bytes changed")
        actual = [value[0] for value in struct.iter_unpack('<f', output_bytes)]
        if len(actual) != len(expected) or not actual:
            raise ValueError(f"{path}: numerical output shape mismatch")
        if any(not math.isfinite(a) or not math.isfinite(e)
               or abs(a - e) > policy['absoluteTolerance'] + policy['relativeTolerance'] * abs(e)
               for a, e in zip(actual, expected)):
            raise ValueError(f"{path}: retained numerical output failed")
        for check in checks:
            for position in range(check['offset'], check['offset'] + check['count']):
                if not accepts(actual[position], expected[position], check):
                    raise ValueError(f'{path}: retained external oracle failed at {position}')
        if not sample["oracle"]["passed"] or sample["oracle"]["firstFailure"] is not None:
            raise ValueError(f"{path}: numerical oracle failed")
        if receipt["programHash"] != program_hash or receipt["inputHashes"] != input_hashes:
            raise ValueError(f"{path}: input or program receipt identity mismatch")
        if receipt["dispatchCount"] != len(program["steps"]):
            raise ValueError(f"{path}: declared dispatch count mismatch")
        buffers = program["buffers"]
        output = next(item for item in buffers if item["id"] == program["output"])
        expected_counts = {
            "uploadedBytes": sum(item["size"] for item in buffers if item["role"] == "input"),
            "clearedBytes": sum(item["size"] for item in buffers if item["role"] != "input"),
            "readbackBytes": output["size"],
            "allocatedBufferBytes": sum(item['size'] for item in buffers) + output['size'],
        }
        if any(receipt[key] != value for key, value in expected_counts.items()):
            raise ValueError(f"{path}: resource work mismatch")
        if len(output_bytes) != output['size'] or report['allocatedBufferBytes'] != receipt['allocatedBufferBytes']:
            raise ValueError(f'{path}: output or resident allocation shape mismatch')
        if any(receipt["timingMs"][phase] <= 0 for phase in ("upload", "submitWait", "readback", "total")):
            raise ValueError(f"{path}: missing execution phase")
        if sample["wallMs"] < receipt["timingMs"]["total"]:
            raise ValueError(f"{path}: selected timing exceeds invocation wall")
    if report["phase"] == "audit":
        if report["lifecycle"] != {"cancellationRejected": True, "reuseAfterCancellation": True}:
            raise ValueError(f"{path}: cancellation/recovery audit missing")
        successful_runs = len(report["samples"]) + 2
        if report["observed"]["maps"] != successful_runs:
            raise ValueError(f"{path}: readback work missing")
        if report["provider"] == "doe-recorded":
            expected_encoded = len(program["steps"])
        else:
            expected_encoded = len(program["steps"]) * successful_runs
            if report["observed"]["submissions"] != successful_runs:
                raise ValueError(f"{path}: submission work missing")
        if report["observed"]["dispatchesEncoded"] != expected_encoded:
            raise ValueError(f"{path}: public command observation mismatch")
        if report["provider"].startswith("doe-") and report["backend"] == "vulkan":
            validate_native_audit(path, program, successful_runs,
                                  gpu_recorded=report["provider"] == "doe-recorded" and policy["preparedExecution"] == "gpu-recorded")
    return report


def validate_native_audit(path: Path, program: dict[str, Any], runs: int, *, gpu_recorded: bool = False) -> None:
    journal = Path(f"{path}.native.jsonl")
    rows = [json.loads(line) for line in journal.read_text().splitlines() if line]
    dispatches = [row for row in rows if row.get("event") == "dispatch_encoded"]
    completions = [row for row in rows if row.get("event") == "submission_succeeded"]
    if gpu_recorded:
        recordings = validate_gpu_replays(rows)
        if (len(recordings) != 1 or len(recordings[0]['submissions']) != runs
                or len(dispatches) != len(program['steps'])):
            raise ValueError(f'{journal}: missing GPU preparation or replay work')
    elif len(dispatches) != runs * len(program["steps"]) or len(completions) < runs:
        raise ValueError(f"{journal}: missing native dispatch or submission work")
    shaders = {shader["id"]: shader for shader in program["shaders"]}
    for index, row in enumerate(dispatches):
        step = program["steps"][index % len(program["steps"])]
        shader = shaders[step["shader"]]
        source_hash = hashlib.sha256(shader["code"].encode()).hexdigest()
        if row["wgslSha256"] != source_hash or row["workgroups"] != step["workgroups"]:
            raise ValueError(f"{journal}: native source or dispatch geometry mismatch")
        if row["entryPoint"] != shader["entryPoint"] or row["bindingCount"] != len(step["bindings"]):
            raise ValueError(f"{journal}: native entry point or resource binding mismatch")
        filename = Path(row["backendArtifactFile"])
        if filename.name != str(filename):
            raise ValueError(f"{journal}: backend artifact must be adjacent to its journal")
        if digest(journal.parent / filename) != row["backendArtifactSha256"]:
            raise ValueError(f"{journal}: backend artifact bytes changed")


def validate_matrix(path: Path, root: Path, policy_path: Path) -> dict[str, Any]:
    from bench.runners.run_compute_program_evidence import comparison_rows

    summary = json.loads(path.read_text())
    schema = json.loads((root / 'config/compute-program-matrix.schema.json').read_text())
    jsonschema.Draft202012Validator(schema).validate(summary)
    policy = json.loads(policy_path.read_text())
    if summary['status'] != 'diagnostic' or summary['error'] is not None or digest(policy_path) != summary['policyHash']:
        raise ValueError(f'{path}: unsuccessful matrix or changed policy')
    for reference in [*summary['sources'], *summary['artifacts']]:
        if digest(root / reference['path']) != reference['hash']:
            raise ValueError(f"{path}: changed artifact {reference['path']}")
    reports = []
    for reference in summary['artifacts']:
        artifact_path = root / reference['path']
        if artifact_path.suffix != '.json' or artifact_path.name.endswith('.program.json'):
            continue
        artifact = json.loads(artifact_path.read_text())
        if artifact.get('kind') == 'compute_program_evaluation':
            reports.append((artifact_path, validate_run(artifact_path, root, policy)))
    for application in policy['applications']:
        for provider in policy['providers']:
            group = [report for _, report in reports if report['application'] == application and report['provider'] == provider]
            if sum(report['phase'] == 'audit' for report in group) != 1 or sum(report['phase'] == 'measure' for report in group) != policy['processRuns']:
                raise ValueError(f'{path}: incomplete audit or measurement coverage')
    if summary['rows'] != comparison_rows(reports, policy):
        raise ValueError(f'{path}: comparison rows do not match raw measurements')
    return summary


if __name__ == '__main__':
    import argparse
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('matrix', type=Path)
    parser.add_argument('--policy', type=Path, default=Path('config/compute-program-evaluation.json'))
    args = parser.parse_args()
    validate_matrix(args.matrix.resolve(), Path(__file__).resolve().parents[2], args.policy.resolve())
    print('compute program matrix: numerical artifacts, execution work, identities and diagnostic rows verified')
