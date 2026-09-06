"""Bracketed Linux DRM observations for application timing admission.

Only clients visible at process boundaries are observed. These records do not
establish exclusive device access or cover clients that start and exit between
snapshots. The observer runs outside the measured child process.
"""

from __future__ import annotations

import contextlib
import json
import os
import re
import time
from collections.abc import Iterator
from pathlib import Path
from typing import Any

import jsonschema

from bench.lib.hash_utils import file_sha256

DRM_CLASS = Path("/sys/class/drm")
PROC_ROOT = Path("/proc")
ACTIVITY_MODE = "reject-observed-linux-drm"
DISABLED_MODE = "off"
SIDECAR_SUFFIX = ".gpu-activity.json"
ENGINE_PREFIX = "drm-engine-"
CAPACITY_PREFIX = "drm-engine-capacity-"


def detect_target(drm_class: Path = DRM_CLASS) -> dict[str, Any]:
    """Require a single PCI render device so observations cannot bind elsewhere."""
    nodes = sorted(drm_class.glob("renderD[0-9]*"))
    if len(nodes) != 1:
        raise ValueError(
            "GPU activity observation requires exactly one Linux DRM render device"
        )
    node = nodes[0]
    device = (node / "device").resolve(strict=True)
    if not re.fullmatch(r"[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-7]", device.name):
        raise ValueError(f"GPU activity observation requires a PCI device: {device}")
    return {
        "renderNode": f"/dev/dri/{node.name}",
        "pciDevice": device.name,
        "vendorId": int((device / "vendor").read_text(encoding="utf-8").strip(), 16),
        "deviceId": int((device / "device").read_text(encoding="utf-8").strip(), 16),
    }


def read_snapshot(
    target: dict[str, Any], proc_root: Path = PROC_ROOT
) -> dict[str, Any]:
    """Retain raw matching fdinfo and visibility gaps without inspecting commands."""
    records = []
    unreadable = set()
    for process in sorted(proc_root.iterdir()):
        if not process.name.isdigit():
            continue
        pid = int(process.name)
        try:
            descriptors = list((process / "fd").iterdir())
            for descriptor in descriptors:
                try:
                    if not os.readlink(descriptor).startswith("/dev/dri/"):
                        continue
                    contents = (process / "fdinfo" / descriptor.name).read_text(
                        encoding="utf-8"
                    )
                    fields = dict(
                        line.split(":", 1)
                        for line in contents.splitlines()
                        if ":" in line
                    )
                    if fields.get("drm-pdev", "").strip() == target["pciDevice"]:
                        records.append(
                            {
                                "pid": pid,
                                "fd": int(descriptor.name),
                                "contents": contents,
                            }
                        )
                except PermissionError:
                    unreadable.add(pid)
                except (FileNotFoundError, ProcessLookupError):
                    continue
        except PermissionError:
            unreadable.add(pid)
        except (FileNotFoundError, ProcessLookupError):
            continue
    return {
        "monotonicNs": time.monotonic_ns(),
        "fdinfo": records,
        "unreadableProcesses": sorted(unreadable),
    }


def client_counters(
    snapshot: dict[str, Any], pci_device: str
) -> dict[str, dict[str, int]]:
    """Deduplicate shared DRM clients and retain each engine's largest reading."""
    clients: dict[str, dict[str, int]] = {}
    for record in snapshot["fdinfo"]:
        fields: dict[str, str] = {}
        for line in record["contents"].splitlines():
            if ":" not in line:
                continue
            key, value = line.split(":", 1)
            if key in fields:
                raise ValueError(f"Duplicate DRM fdinfo field: {key}")
            fields[key] = value.strip()
        if fields.get("drm-pdev") != pci_device:
            raise ValueError("GPU activity fdinfo belongs to a different PCI device")
        client_id = fields.get("drm-client-id", "")
        if not client_id.isdecimal() or not fields.get("drm-driver"):
            raise ValueError(
                "GPU activity fdinfo lacks a driver or unique client identity"
            )
        engines = clients.setdefault(str(int(client_id)), {})
        for key, value in fields.items():
            if not key.startswith(ENGINE_PREFIX) or key.startswith(CAPACITY_PREFIX):
                continue
            match = re.fullmatch(r"(\d+)\s+ns", value)
            if match is None:
                raise ValueError(
                    f"GPU activity counter requires nanoseconds: {key}={value}"
                )
            engine = key.removeprefix(ENGINE_PREFIX)
            engines[engine] = max(engines.get(engine, 0), int(match[1]))
    return clients


def reject_activity(snapshots: list[dict[str, Any]], pci_device: str) -> None:
    """Reject positive foreign work and counters whose continuity is unknown."""
    before, after = snapshots
    if after["monotonicNs"] <= before["monotonicNs"]:
        raise ValueError("GPU activity snapshots are not ordered")
    previous = client_counters(before, pci_device)
    current = client_counters(after, pci_device)
    for client_id in previous.keys() - current.keys():
        raise ValueError(f"GPU activity coverage lost foreign DRM client {client_id}")
    for client_id, engines in current.items():
        old = previous.get(client_id, {})
        if old.keys() - engines.keys():
            raise ValueError(
                f"GPU activity counters disappeared for DRM client {client_id}"
            )
        for engine, value in engines.items():
            delta = value - old.get(engine, 0)
            if delta < 0:
                raise ValueError(
                    f"GPU activity counter regressed for DRM client {client_id}/{engine}"
                )
            if delta > 0:
                raise ValueError(
                    f"Unrelated GPU activity: DRM client {client_id}/{engine} advanced {delta} ns"
                )


def requires_observation(policy: dict[str, Any], phase: str) -> bool:
    return (
        phase == "measure" and policy.get("gpuActivity", DISABLED_MODE) == ACTIVITY_MODE
    )


@contextlib.contextmanager
def capture_activity(
    output: Path, policy: dict[str, Any], policy_hash: str, backend: str, phase: str
) -> Iterator[None]:
    """Retain boundary observations even when a child fails or times out."""
    if not requires_observation(policy, phase):
        yield
        return
    if backend != "vulkan":
        raise ValueError(
            "Linux DRM GPU activity observation requires the Vulkan backend"
        )
    target = detect_target()
    before = read_snapshot(target)
    try:
        yield
    finally:
        after = read_snapshot(target)
        record = {
            "schemaVersion": 1,
            "kind": "compute_program_gpu_activity",
            "scope": "readable-clients-at-process-boundaries",
            "policyHash": policy_hash,
            "target": target,
            "evaluationHash": file_sha256(output) if output.exists() else None,
            "snapshots": [before, after],
        }
        Path(f"{output}{SIDECAR_SUFFIX}").write_text(
            json.dumps(record, indent=2, sort_keys=True) + "\n", encoding="utf-8"
        )


def validate_activity(
    path: Path, root: Path, policy: dict[str, Any], report: dict[str, Any]
) -> None:
    """Bind required observations to the exact run before admitting its timings."""
    if not requires_observation(policy, report["phase"]):
        return
    sidecar = Path(f"{path}{SIDECAR_SUFFIX}")
    record = json.loads(sidecar.read_text(encoding="utf-8"))
    schema = json.loads(
        (root / "config/compute-program-gpu-activity.schema.json").read_text(
            encoding="utf-8"
        )
    )
    jsonschema.Draft202012Validator(schema).validate(record)
    if report["backend"] != "vulkan" or record["policyHash"] != report["policyHash"]:
        raise ValueError(f"{sidecar}: GPU activity policy or backend mismatch")
    if record["evaluationHash"] != file_sha256(path):
        raise ValueError(f"{sidecar}: GPU activity belongs to a different evaluation")
    if report["provider"] != "dawn":
        adapter = report["adapter"]
        vendor = (
            adapter["vendorID"]
            if adapter["vendorID"] is not None
            else int(adapter["vendor"])
        )
        device = (
            adapter["deviceID"]
            if adapter["deviceID"] is not None
            else int(adapter["device"])
        )
        if (vendor, device) != (
            record["target"]["vendorId"],
            record["target"]["deviceId"],
        ):
            raise ValueError(f"{sidecar}: GPU activity belongs to a different adapter")
    reject_activity(record["snapshots"], record["target"]["pciDevice"])
