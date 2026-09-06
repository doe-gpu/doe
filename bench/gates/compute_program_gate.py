"""Validate fixed-shape program evidence without granting speed or adoption claims."""
from __future__ import annotations

import hashlib
import json
import math
import struct
from pathlib import Path
from typing import Any

import jsonschema

from bench.lib.compute_program_fixture import accepts, load_fixture
from bench.lib.hash_utils import file_sha256 as digest
from bench.lib.native_program_replay import validate_gpu_replays
from bench.native_compare_modules.reporting import format_stats

TIMESTAMP_BYTES = struct.calcsize('<Q')
TIMESTAMP_QUERY_COUNT = 2
MAX_SAFE_TIMESTAMP_INTERVAL = (1 << 53) - 1


def completion_mode(receipt: dict[str, Any]) -> str:
    return receipt['completionMode'] if receipt['schemaVersion'] >= 5 else 'queue-then-map'


def validate_gpu_timing(receipt: dict[str, Any], provider: str, policy: dict[str, Any],
                        calibration: dict[str, Any] | None = None) -> bool:
    timing = receipt.get('gpuTiming')
    enabled = policy.get('gpuTiming', 'off') == 'timestamp-query'
    if (timing is not None) != enabled:
        raise ValueError('GPU timing does not match the frozen policy')
    if not enabled:
        return False
    expected_source = 'vulkan-query-ticks' if provider.startswith('doe-') and receipt.get('schemaVersion', 2) < 3 else 'webgpu-nanoseconds'
    if provider == 'wgpu' and policy.get('wgpuTimestampUnits') == 'vulkan-ticks':
        expected_source = 'wgpu-vulkan-query-ticks'
    if timing['source'] != expected_source or timing['scope'] != 'compute-pass':
        raise ValueError('GPU timestamp source or scope mismatch')
    if expected_source == 'webgpu-nanoseconds' and (timing['periodNs'] != 1 or timing['validBits'] != 64):
        raise ValueError('Standard WebGPU timestamps must use nanoseconds')
    if expected_source != 'webgpu-nanoseconds':
        if calibration is None:
            raise ValueError('Native GPU ticks require independent physical calibration')
        properties = calibration['properties']['VkPhysicalDeviceProperties']
        bits = {family['VkQueueFamilyProperties']['timestampValidBits']
                for family in calibration['queueFamiliesProperties']
                if 'VK_QUEUE_COMPUTE_BIT' in family['VkQueueFamilyProperties']['queueFlags']}
        if (bits != {timing['validBits']} or not math.isclose(
                timing['periodNs'], properties['limits']['timestampPeriod'],
                rel_tol=policy['timestampPeriodRelativeTolerance'], abs_tol=0)):
            raise ValueError('GPU timestamp calibration differs from the physical Vulkan profile')
    begin, end = int(timing['beginTicks']), int(timing['endTicks'])
    if not (0 <= begin < 1 << 64 and 0 <= end < 1 << 64):
        raise ValueError('GPU timestamps exceed the native result width')
    ticks = (end - begin) % (1 << timing['validBits'])
    elapsed = ticks * timing['periodNs']
    if ticks > MAX_SAFE_TIMESTAMP_INTERVAL or elapsed > MAX_SAFE_TIMESTAMP_INTERVAL or not math.isclose(
            elapsed, timing['elapsedNs'], rel_tol=1e-12, abs_tol=0):
        raise ValueError('GPU timestamp interval or calibration mismatch')
    return True


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
    calibration = None
    if report['schemaVersion'] >= 3 and report['backend'] == 'vulkan' and policy.get('gpuTiming', 'off') != 'off':
        reference = report.get('timestampCalibrationArtifact')
        if not reference or digest(Path(reference['path'])) != reference['hash']:
            raise ValueError(f'{path}: independent timestamp calibration is missing or changed')
        calibration = json.loads(Path(reference['path']).read_text())['capabilities']['device']
        physical = calibration['properties']['VkPhysicalDeviceProperties']
        if report['provider'] != 'dawn':
            adapter = report['adapter']
            vendor = adapter['vendorID'] if adapter['vendorID'] is not None else int(adapter['vendor'])
            device = adapter['deviceID'] if adapter['deviceID'] is not None else int(adapter['device'])
            if (vendor, device) != (physical['vendorID'], physical['deviceID']):
                raise ValueError(f'{path}: timestamp calibration belongs to a different physical adapter')
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
    if report['schemaVersion'] >= 3 and report['provider'].startswith('doe-'):
        addon = report.get('providerAddonArtifact')
        if not addon or digest(Path(addon['path'])) != addon['hash']:
            raise ValueError(f'{path}: loaded addon identity is missing or changed')
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
    sequence = None
    fixture_path = None
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
        sequence = fixture.get('sequence')
    elif report.get('fixturePath'):
        raise ValueError(f'{path}: external fixture is not declared in the policy')
    expected = [value[0] for value in struct.iter_unpack('<d', (root / report['expectedPath']).read_bytes())]
    resident = [buffer for buffer in program['buffers'] if buffer.get('lifetime') == 'program']
    if resident and (sequence is None or report['schemaVersion'] < 4):
        raise ValueError(f'{path}: resident evaluation requires a frozen sequence and complete invocation records')
    all_samples = [report['cold'], *report['samples']]
    if report['schemaVersion'] >= 4:
        warmup_count = policy['warmupRuns'] if report['phase'] == 'measure' else 0
        lifecycle_count = 1 if report['phase'] == 'audit' else 0
        if (len(report['warmups']) != warmup_count or len(report['lifecycleRuns']) != lifecycle_count
                or report['failedRun'] is not None):
            raise ValueError(f'{path}: incomplete warmup or lifecycle invocation records')
        all_samples = [report['cold'], *report['warmups'], *report['samples'], *report['lifecycleRuns']]
        if sequence and len(sequence['expected']) < len(all_samples):
            raise ValueError(f'{path}: frozen sequence is shorter than the declared execution')
    if len({completion_mode(sample["receipt"]) for sample in all_samples}) != 1:
        raise ValueError(f'{path}: mixed completion timing scopes')
    for index, sample in enumerate(all_samples):
        receipt = sample["receipt"]
        expected_run = 1 if index == 0 else index + 1 + (policy['warmupRuns'] if report['phase'] == 'measure' else 0)
        if report['schemaVersion'] >= 4:
            expected_run = index + 1
        if sequence:
            expected_file = fixture_path.parent / sequence['expected'][index]['path']
            expected = [value[0] for value in struct.iter_unpack('<d', expected_file.read_bytes())]
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
        expected_hashes = dict(input_hashes)
        expected_origins = {name: {'kind': 'host', 'hash': value} for name, value in input_hashes.items()}
        expected_state = {}
        if sequence:
            if receipt['schemaVersion'] < 4:
                raise ValueError(f'{path}: sequence requires generation-bound receipts')
            instance = report['cold']['receipt']['programInstance']
            for buffer in program['buffers']:
                origin = {'kind': 'program-state', 'programHash': program_hash,
                          'programInstance': instance, 'buffer': buffer['id'], 'generation': expected_run - 1}
                if buffer['role'] != 'input':
                    expected_state[buffer['id']] = origin if index else {'kind': 'zero'}
                elif index and buffer['type'] == 'storage':
                    expected_hashes[buffer['id']] = None
                    expected_origins[buffer['id']] = origin
        if receipt["programHash"] != program_hash or receipt["inputHashes"] != expected_hashes:
            raise ValueError(f"{path}: input or program receipt identity mismatch")
        if receipt['schemaVersion'] >= 4 and (receipt['inputOrigins'] != expected_origins
                    or receipt['residentStateBefore'] != expected_state
                    or receipt['outputGeneration'] != expected_run
                    or receipt['programInstance'] != report['cold']['receipt']['programInstance']
                    or receipt['copiedInputBytes'] != 0
                    or receipt['submissionCount'] != 1
                    or receipt['readbackPath'] != 'mapAsync-copy-unmap'):
            raise ValueError(f'{path}: invocation provenance or submission work mismatch')
        if receipt["dispatchCount"] != len(program["steps"]):
            raise ValueError(f"{path}: declared dispatch count mismatch")
        buffers = program["buffers"]
        output = next(item for item in buffers if item["id"] == program["output"])
        has_timing = validate_gpu_timing(receipt, report['provider'], policy, calibration)
        query_bytes = TIMESTAMP_QUERY_COUNT * TIMESTAMP_BYTES if has_timing else 0
        padding = (-output['size']) % TIMESTAMP_BYTES if has_timing else 0
        expected_counts = {
            "uploadedBytes": 0 if sequence and index else sum(item["size"] for item in buffers if item["role"] == "input"),
            "clearedBytes": sum(item["size"] for item in buffers if item["role"] != "input" and item.get('lifetime') != 'program'),
            "readbackBytes": output["size"] + query_bytes,
            "allocatedBufferBytes": sum(item['size'] for item in buffers) + output['size'] + padding + 2 * query_bytes,
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
            initialization_submissions = int(any(buffer['role'] != 'input' for buffer in resident))
            if report["observed"]["submissions"] != successful_runs + initialization_submissions:
                raise ValueError(f"{path}: submission work missing")
        if report["observed"]["dispatchesEncoded"] != expected_encoded:
            raise ValueError(f"{path}: public command observation mismatch")
        if report["provider"].startswith("doe-") and report["backend"] == "vulkan":
            validate_native_audit(path, program, successful_runs,
                                  gpu_recorded=report["provider"] == "doe-recorded" and policy["preparedExecution"] == "gpu-recorded")
    if policy.get('gpuTiming', 'off') == 'timestamp-query':
        expected = format_stats([sample['receipt']['gpuTiming']['elapsedNs'] / 1_000_000 for sample in report['samples']],
                                percentile_method=policy['percentileMethod'])
        observed = report.get('gpuStatsNs')
        fields = {'mean': 'meanMs', 'min': 'minMs', 'max': 'maxMs', 'median': 'p50Ms', 'p95': 'p95Ms', 'p99': 'p99Ms'}
        if (not observed or observed['count'] != expected['count']
                or any(not math.isclose(observed[key], expected[field] * 1_000_000, rel_tol=1e-12, abs_tol=0)
                       for key, field in fields.items())):
            raise ValueError(f'{path}: GPU timestamp statistics mismatch')
    elif report.get('gpuStatsNs') is not None:
        raise ValueError(f'{path}: GPU timing statistics present with timing disabled')
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
