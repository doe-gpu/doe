"""Capture explicit host/backend availability for recomposition evidence."""

from __future__ import annotations

import argparse
import json
import os
import platform
import re
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Any

from source_architecture import canonical_json, sha256_file


ROOT = Path(__file__).resolve().parents[1]
REPO_ROOT = ROOT.parents[1]
OUTPUT_PATH = ROOT / "reports" / "recomposition" / "backend-evidence.json"
DEFAULT_VULKAN_OUTPUT_WORKLOAD_ID = "compute_workgroup_atomic_1024"
DEFAULT_METAL_OUTPUT_WORKLOAD_ID = DEFAULT_VULKAN_OUTPUT_WORKLOAD_ID
DEFAULT_D3D12_OUTPUT_WORKLOAD_ID = DEFAULT_VULKAN_OUTPUT_WORKLOAD_ID
SCHEMA_VERSION = 4


def _field(content: str, name: str) -> str | None:
    match = re.search(rf"^\s*{re.escape(name)}\s*=\s*(.+?)\s*$", content, re.MULTILINE)
    return match.group(1) if match else None


def _load_object(path: Path, label: str) -> dict[str, Any]:
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise ValueError(f"unable to load {label} {path}: {exc}") from exc
    if not isinstance(payload, dict):
        raise ValueError(f"{label} must be a JSON object: {path}")
    return payload


def _resolve_repo_path(repo_root: Path, raw_path: object, label: str) -> Path:
    if not isinstance(raw_path, str) or not raw_path:
        raise ValueError(f"{label} path is missing")
    relative = Path(raw_path)
    if relative.is_absolute():
        raise ValueError(f"{label} path must be repository-relative: {raw_path}")
    resolved_root = repo_root.resolve()
    resolved = (resolved_root / relative).resolve()
    try:
        resolved.relative_to(resolved_root)
    except ValueError as exc:
        raise ValueError(f"{label} path escapes repository root: {raw_path}") from exc
    return resolved


def _verified_run_side(
    repo_root: Path,
    workload: dict[str, Any],
    side: str,
    expected_product: str,
    expected_backend: str,
    backend_label: str,
    expected_api: str,
) -> dict[str, Any]:
    evidence_label = f"{backend_label} output"
    receipts = workload.get("receipts")
    reference = receipts.get(side) if isinstance(receipts, dict) else None
    if not isinstance(reference, dict):
        raise ValueError(f"{evidence_label} report has no {side} run receipt")
    if reference.get("product") != expected_product:
        raise ValueError(f"{evidence_label} report {side} product identity mismatch")
    receipt_path = _resolve_repo_path(
        repo_root,
        reference.get("path"),
        f"{evidence_label} report {side} receipt",
    )
    if sha256_file(receipt_path) != reference.get("sha256"):
        raise ValueError(f"{evidence_label} report {side} receipt SHA-256 mismatch")
    receipt = _load_object(receipt_path, f"{evidence_label} report {side} receipt")
    if receipt.get("product") != expected_product:
        raise ValueError(f"{evidence_label} receipt {side} product identity mismatch")
    host_identity = receipt.get("hostIdentity")
    if not isinstance(host_identity, dict):
        raise ValueError(f"{evidence_label} receipt {side} host identity is missing")
    if host_identity.get("api") != expected_api:
        raise ValueError(f"{evidence_label} receipt {side} API identity mismatch")
    receipt_workload = receipt.get("workload")
    if not isinstance(receipt_workload, dict):
        raise ValueError(f"{evidence_label} receipt {side} workload is missing")
    if receipt_workload.get("id") != workload.get("id"):
        raise ValueError(f"{evidence_label} receipt {side} workload identity mismatch")
    samples = receipt.get("samples")
    if not isinstance(samples, list) or not samples:
        raise ValueError(f"{evidence_label} receipt {side} has no samples")
    stats_key = "baselineStatsMs" if side == "left" else "comparisonStatsMs"
    stats = workload.get(stats_key)
    expected_sample_count = stats.get("count") if isinstance(stats, dict) else None
    if expected_sample_count != len(samples):
        raise ValueError(f"{evidence_label} receipt {side} sample count mismatch")

    dispatch_counts: set[int] = set()
    oracle_counts: set[int] = set()
    matched_counts: set[int] = set()
    for index, sample in enumerate(samples):
        if not isinstance(sample, dict) or sample.get("success") is not True:
            raise ValueError(f"{evidence_label} receipt {side} sample {index} failed")
        trace_meta = sample.get("traceMeta")
        if not isinstance(trace_meta, dict):
            raise ValueError(
                f"{evidence_label} receipt {side} sample {index} traceMeta is missing"
            )
        if trace_meta.get("executionBackend") != expected_backend:
            raise ValueError(
                f"{evidence_label} receipt {side} sample {index} backend mismatch"
            )
        if trace_meta.get("fallbackUsed") is not False:
            raise ValueError(
                f"{evidence_label} receipt {side} sample {index} used fallback"
            )
        dispatch_count = trace_meta.get("executionDispatchCount")
        success_count = trace_meta.get("executionSuccessCount")
        oracle_count = trace_meta.get("outputOracleCount")
        matched_count = trace_meta.get("outputOracleMatchedCount")
        failed_count = trace_meta.get("outputOracleFailedCount")
        if not isinstance(dispatch_count, int) or dispatch_count <= 0:
            raise ValueError(
                f"{evidence_label} receipt {side} sample {index} has no dispatches"
            )
        if not isinstance(success_count, int) or success_count <= 0:
            raise ValueError(
                f"{evidence_label} receipt {side} sample {index} has no "
                "successful output"
            )
        if not isinstance(oracle_count, int) or oracle_count <= 0:
            raise ValueError(
                f"{evidence_label} receipt {side} sample {index} has no output oracle"
            )
        if matched_count != oracle_count or failed_count != 0:
            raise ValueError(
                f"{evidence_label} receipt {side} sample {index} output oracle failed"
            )
        dispatch_counts.add(dispatch_count)
        oracle_counts.add(oracle_count)
        matched_counts.add(matched_count)
    if len(dispatch_counts) != 1 or len(oracle_counts) != 1 or len(matched_counts) != 1:
        raise ValueError(f"{evidence_label} receipt {side} execution shape is unstable")
    return {
        "dispatchCount": dispatch_counts.pop(),
        "executionBackend": expected_backend,
        "outputOracleCount": oracle_counts.pop(),
        "outputOracleMatchedCount": matched_counts.pop(),
        "product": expected_product,
        "sampleCount": len(samples),
    }


def _representative_output_evidence(
    report_path: Path,
    repo_root: Path,
    workload_id: str,
    backend_label: str = "Vulkan",
    expected_backend: str = "doe_vulkan",
) -> dict[str, Any]:
    expected_api = backend_label.lower()
    resolved_report = report_path.resolve()
    resolved_root = repo_root.resolve()
    try:
        relative_report = resolved_report.relative_to(resolved_root)
    except ValueError as exc:
        raise ValueError(
            f"{backend_label} output report must be inside the repository"
        ) from exc
    report = _load_object(resolved_report, f"{backend_label} output report")
    if report.get("comparisonStatus") != "comparable":
        raise ValueError(f"{backend_label} output report is not comparable")
    workloads = report.get("workloads")
    if not isinstance(workloads, list):
        raise ValueError(f"{backend_label} output report workloads are missing")
    matching = [
        row
        for row in workloads
        if isinstance(row, dict) and row.get("id") == workload_id
    ]
    if len(matching) != 1:
        raise ValueError(
            f"{backend_label} output report must contain exactly one workload "
            f"{workload_id!r}"
        )
    workload = matching[0]
    comparability = workload.get("comparability")
    if (
        not isinstance(comparability, dict)
        or comparability.get("comparable") is not True
    ):
        raise ValueError(f"{backend_label} output workload is not comparable")
    if comparability.get("blockingFailedObligations") not in (None, []):
        raise ValueError(
            f"{backend_label} output workload has blocking comparability failures"
        )
    baseline = _verified_run_side(
        resolved_root,
        workload,
        "left",
        "doe",
        expected_backend,
        backend_label,
        expected_api,
    )
    comparison = _verified_run_side(
        resolved_root,
        workload,
        "right",
        "dawn_delegate",
        "dawn_delegate",
        backend_label,
        expected_api,
    )
    if baseline["dispatchCount"] != comparison["dispatchCount"]:
        raise ValueError(
            f"{backend_label} output receipts have mismatched dispatch counts"
        )
    if baseline["outputOracleCount"] != comparison["outputOracleCount"]:
        raise ValueError(
            f"{backend_label} output receipts have mismatched output oracle counts"
        )
    return {
        "baseline": baseline,
        "comparison": comparison,
        "reportPath": relative_report.as_posix(),
        "reportSha256": sha256_file(resolved_report),
        "workloadId": workload_id,
    }


def _host_identity() -> dict[str, str]:
    return {
        "machine": platform.machine(),
        "operatingSystem": platform.system(),
        "release": platform.release(),
    }


def _metal_device_from_payload(payload: object) -> dict[str, str | None] | None:
    if not isinstance(payload, dict):
        return None
    displays = payload.get("SPDisplaysDataType")
    if not isinstance(displays, list):
        return None
    for display in displays:
        if not isinstance(display, dict):
            continue
        name = display.get("sppci_model") or display.get("_name")
        if not isinstance(name, str) or not name.strip():
            continue
        lowered = name.lower()
        if "software" in lowered or "virtual" in lowered:
            continue
        driver_info = display.get("spdisplays_metal")
        return {
            "deviceName": name.strip(),
            "driverInfo": driver_info if isinstance(driver_info, str) else None,
            "driverName": "Metal",
        }
    return None


def _metal_device() -> dict[str, str | None] | None:
    executable = shutil.which("system_profiler")
    if executable is None:
        return None
    result = subprocess.run(
        [executable, "SPDisplaysDataType", "-json"],
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        return None
    try:
        payload = json.loads(result.stdout)
    except json.JSONDecodeError:
        return None
    return _metal_device_from_payload(payload)


def _d3d12_device_from_payload(payload: object) -> dict[str, str | None] | None:
    rows = payload if isinstance(payload, list) else [payload]
    for row in rows:
        if not isinstance(row, dict):
            continue
        name = row.get("Name")
        if not isinstance(name, str) or not name.strip():
            continue
        lowered = name.lower()
        if "basic render" in lowered or "remote display" in lowered:
            continue
        compatibility = row.get("AdapterCompatibility")
        driver_version = row.get("DriverVersion")
        return {
            "deviceName": name.strip(),
            "driverInfo": (
                driver_version if isinstance(driver_version, str) else None
            ),
            "driverName": (
                compatibility if isinstance(compatibility, str) else "D3D12"
            ),
        }
    return None


def _d3d12_device() -> dict[str, str | None] | None:
    executable = shutil.which("powershell") or shutil.which("pwsh")
    if executable is None:
        return None
    command = (
        "Get-CimInstance Win32_VideoController | "
        "Select-Object Name,DriverVersion,AdapterCompatibility | "
        "ConvertTo-Json -Compress"
    )
    result = subprocess.run(
        [executable, "-NoProfile", "-NonInteractive", "-Command", command],
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        return None
    try:
        payload = json.loads(result.stdout)
    except json.JSONDecodeError:
        return None
    return _d3d12_device_from_payload(payload)


def _os_backend(
    *,
    backend_label: str,
    required_host_os: str,
    expected_backend: str,
    output_report: Path | None,
    output_workload_id: str,
) -> dict[str, Any]:
    if platform.system() != required_host_os:
        if output_report is not None:
            raise ValueError(
                f"{backend_label} output requires a {required_host_os} host"
            )
        return {
            "availability": "not-available-host-os",
            "physicalGpuEligible": False,
            "representativeOutput": "not-captured",
            "requiredHostOs": required_host_os,
        }
    device = _metal_device() if required_host_os == "Darwin" else _d3d12_device()
    eligible = device is not None
    backend: dict[str, Any] = {
        "availability": (
            "physical-adapter-accessible" if eligible else "diagnostic-only"
        ),
        "physicalGpuEligible": eligible,
        "representativeOutput": "eligible-not-run" if eligible else "not-captured",
        "requiredHostOs": required_host_os,
    }
    if device is not None:
        backend["device"] = device
    if output_report is not None:
        if not eligible:
            raise ValueError(
                f"representative {backend_label} output requires an eligible "
                "physical adapter"
            )
        backend["evidenceHost"] = _host_identity()
        backend["representativeOutputEvidence"] = _representative_output_evidence(
            output_report,
            REPO_ROOT,
            output_workload_id,
            backend_label,
            expected_backend,
        )
        backend["representativeOutput"] = "captured"
    return backend


def _vulkan(
    vulkan_output_report: Path | None = None,
    vulkan_output_workload_id: str = DEFAULT_VULKAN_OUTPUT_WORKLOAD_ID,
) -> dict[str, Any]:
    executable = shutil.which("vulkaninfo")
    render_nodes = sorted(Path("/dev/dri").glob("renderD*"))
    node_records = [
        {
            "path": str(path),
            "readable": os.access(path, os.R_OK),
            "writable": os.access(path, os.W_OK),
        }
        for path in render_nodes
    ]
    if executable is None:
        return {
            "availability": "not-captured-vulkaninfo-missing",
            "physicalGpuEligible": False,
            "renderNodes": node_records,
            "representativeOutput": "not-captured",
        }
    result = subprocess.run(
        [executable, "--summary"],
        check=False,
        capture_output=True,
        text=True,
    )
    combined = result.stdout + result.stderr
    device_type = _field(combined, "deviceType")
    device_name = _field(combined, "deviceName")
    driver_name = _field(combined, "driverName")
    driver_info = _field(combined, "driverInfo")
    physical = bool(device_name) and device_type != "PHYSICAL_DEVICE_TYPE_CPU" and not (
        device_name and "llvmpipe" in device_name.lower()
    )
    nodes_accessible = any(
        record["readable"] and record["writable"] for record in node_records
    )
    eligible = physical and nodes_accessible
    backend = {
        "availability": (
            "physical-adapter-accessible" if eligible else "diagnostic-only"
        ),
        "device": {
            "deviceName": device_name,
            "deviceType": device_type,
            "driverInfo": driver_info,
            "driverName": driver_name,
        },
        "physicalGpuEligible": eligible,
        "renderNodes": node_records,
        "representativeOutput": (
            "not-captured-physical-run-required"
            if not physical
            else "not-captured-render-node-access-required"
            if not nodes_accessible
            else "eligible-not-run"
        ),
        "softwareFallbackDetected": bool(
            device_name and "llvmpipe" in device_name.lower()
        ),
        "summaryExitCode": result.returncode,
    }
    if vulkan_output_report is not None:
        if not eligible:
            raise ValueError(
                "representative Vulkan output requires an eligible physical adapter"
            )
        backend["representativeOutputEvidence"] = _representative_output_evidence(
            vulkan_output_report,
            REPO_ROOT,
            vulkan_output_workload_id,
        )
        backend["evidenceHost"] = _host_identity()
        backend["representativeOutput"] = "captured"
    return backend


def _preserve_captured_backends(
    backends: dict[str, dict[str, Any]],
    existing: dict[str, Any] | None,
) -> None:
    if not isinstance(existing, dict):
        return
    existing_backends = existing.get("backends")
    if not isinstance(existing_backends, dict):
        return
    existing_host = existing.get("host")
    for name in backends:
        prior = existing_backends.get(name)
        if not isinstance(prior, dict):
            continue
        if prior.get("representativeOutput") != "captured":
            continue
        if "evidenceHost" not in prior and isinstance(existing_host, dict):
            prior = {**prior, "evidenceHost": existing_host}
        backends[name] = prior


def capture(
    vulkan_output_report: Path | None = None,
    vulkan_output_workload_id: str = DEFAULT_VULKAN_OUTPUT_WORKLOAD_ID,
    metal_output_report: Path | None = None,
    metal_output_workload_id: str = DEFAULT_METAL_OUTPUT_WORKLOAD_ID,
    d3d12_output_report: Path | None = None,
    d3d12_output_workload_id: str = DEFAULT_D3D12_OUTPUT_WORKLOAD_ID,
    existing: dict[str, Any] | None = None,
) -> dict[str, Any]:
    backends = {
        "d3d12": _os_backend(
            backend_label="D3D12",
            required_host_os="Windows",
            expected_backend="doe_d3d12",
            output_report=d3d12_output_report,
            output_workload_id=d3d12_output_workload_id,
        ),
        "metal": _os_backend(
            backend_label="Metal",
            required_host_os="Darwin",
            expected_backend="doe_metal",
            output_report=metal_output_report,
            output_workload_id=metal_output_workload_id,
        ),
        "vulkan": _vulkan(vulkan_output_report, vulkan_output_workload_id),
    }
    _preserve_captured_backends(backends, existing)
    outputs_captured = all(
        backend["representativeOutput"] == "captured"
        for backend in backends.values()
    )
    return {
        "backends": backends,
        "claimable": outputs_captured,
        "evidenceMaturity": "comparable" if outputs_captured else "diagnostic",
        "policy": {
            "physicalHardwareRequired": True,
            "softwareFallbackProhibited": True,
        },
        "schemaVersion": SCHEMA_VERSION,
        "status": "captured" if outputs_captured else "hardware-evidence-incomplete",
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=OUTPUT_PATH)
    parser.add_argument(
        "--vulkan-output-report",
        type=Path,
        help="Comparable native report whose hash-bound run receipts prove output.",
    )
    parser.add_argument(
        "--metal-output-report",
        type=Path,
        help="Comparable native report whose hash-bound Metal receipts prove output.",
    )
    parser.add_argument(
        "--metal-output-workload-id",
        default=DEFAULT_METAL_OUTPUT_WORKLOAD_ID,
        help="Representative workload to verify in --metal-output-report.",
    )
    parser.add_argument(
        "--d3d12-output-report",
        type=Path,
        help="Comparable native report whose hash-bound D3D12 receipts prove output.",
    )
    parser.add_argument(
        "--d3d12-output-workload-id",
        default=DEFAULT_D3D12_OUTPUT_WORKLOAD_ID,
        help="Representative workload to verify in --d3d12-output-report.",
    )
    parser.add_argument(
        "--vulkan-output-workload-id",
        default=DEFAULT_VULKAN_OUTPUT_WORKLOAD_ID,
        help="Representative workload to verify in --vulkan-output-report.",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        existing = (
            _load_object(args.output, "existing backend evidence")
            if args.output.is_file()
            else None
        )
        payload = capture(
            args.vulkan_output_report,
            args.vulkan_output_workload_id,
            args.metal_output_report,
            args.metal_output_workload_id,
            args.d3d12_output_report,
            args.d3d12_output_workload_id,
            existing,
        )
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(canonical_json(payload), encoding="utf-8")
    except (
        OSError,
        subprocess.SubprocessError,
        ValueError,
        json.JSONDecodeError,
    ) as exc:
        print(f"backend evidence capture failed: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
