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

from source_architecture import canonical_json


ROOT = Path(__file__).resolve().parents[1]
OUTPUT_PATH = ROOT / "reports" / "recomposition" / "backend-evidence.json"


def _field(content: str, name: str) -> str | None:
    match = re.search(rf"^\s*{re.escape(name)}\s*=\s*(.+?)\s*$", content, re.MULTILINE)
    return match.group(1) if match else None


def _vulkan() -> dict[str, Any]:
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
    return {
        "availability": "physical-adapter-accessible" if eligible else "diagnostic-only",
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


def capture() -> dict[str, Any]:
    system = platform.system()
    backends = {
        "d3d12": {
            "availability": (
                "eligible-not-run" if system == "Windows" else "not-available-host-os"
            ),
            "representativeOutput": "not-captured",
            "requiredHostOs": "Windows",
        },
        "metal": {
            "availability": (
                "eligible-not-run" if system == "Darwin" else "not-available-host-os"
            ),
            "representativeOutput": "not-captured",
            "requiredHostOs": "Darwin",
        },
        "vulkan": _vulkan(),
    }
    outputs_captured = all(
        backend["representativeOutput"] == "captured"
        for backend in backends.values()
    )
    return {
        "backends": backends,
        "claimable": outputs_captured,
        "evidenceMaturity": "comparable" if outputs_captured else "diagnostic",
        "host": {
            "machine": platform.machine(),
            "operatingSystem": system,
            "release": platform.release(),
        },
        "policy": {
            "physicalHardwareRequired": True,
            "softwareFallbackProhibited": True,
        },
        "schemaVersion": 1,
        "status": "captured" if outputs_captured else "hardware-evidence-incomplete",
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=OUTPUT_PATH)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        payload = capture()
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(canonical_json(payload), encoding="utf-8")
    except (OSError, subprocess.SubprocessError, ValueError, json.JSONDecodeError) as exc:
        print(f"backend evidence capture failed: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
