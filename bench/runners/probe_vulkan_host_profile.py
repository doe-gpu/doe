#!/usr/bin/env python3
"""Emit physical Vulkan evidence for one declared host profile."""

from __future__ import annotations

import argparse
import json
import os
import platform
import shutil
from pathlib import Path
from typing import Any

from bench.runners.preflight_bench_host import (
    DEFAULT_VULKAN_PROFILE_POLICY,
    normalize_arch,
    probe_vulkaninfo_gpus,
    resolve_vulkan_host_profile,
    vulkan_device_matches_profile,
)


DEFAULT_RENDER_NODE = Path("/dev/dri/renderD128")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--profile",
        required=True,
        help="Named profile from config/vulkan-host-profiles.json.",
    )
    parser.add_argument(
        "--vulkan-profile-policy",
        type=Path,
        default=DEFAULT_VULKAN_PROFILE_POLICY,
        help="Schema-backed Vulkan host-profile policy path.",
    )
    return parser.parse_args()


def probe_profile(
    *,
    profile_id: str,
    policy_path: Path,
    render_node: Path = DEFAULT_RENDER_NODE,
) -> dict[str, Any]:
    """Probe only the ICD and physical adapter declared by a host profile."""

    profile = resolve_vulkan_host_profile(policy_path, profile_id)
    host_os = "linux" if os.sys.platform.startswith("linux") else os.sys.platform
    host_arch = normalize_arch(platform.machine())
    render_accessible = (
        render_node.is_char_device()
        and os.access(render_node, os.R_OK)
        and os.access(render_node, os.W_OK)
    )
    vulkaninfo_available = shutil.which("vulkaninfo") is not None
    icd_available = profile.icd_path.is_file()
    devices: list[dict[str, str]] = []
    probe_message = "vulkaninfo or configured ICD is unavailable"
    if vulkaninfo_available and icd_available:
        devices, probe_message = probe_vulkaninfo_gpus(profile)
    matching_devices = [
        device
        for device in devices
        if vulkan_device_matches_profile(device, profile)
    ]
    ok = (
        host_os == profile.os
        and host_arch == profile.arch
        and render_accessible
        and vulkaninfo_available
        and icd_available
        and bool(matching_devices)
    )
    return {
        "schemaVersion": 1,
        "artifactKind": "vulkan-host-profile-probe",
        "ok": ok,
        "profileId": profile.id,
        "host": {"os": host_os, "arch": host_arch},
        "renderNode": {
            "path": str(render_node),
            "readableWritable": render_accessible,
        },
        "icdPath": str(profile.icd_path),
        "vendorId": profile.vendor_id,
        "matchingDevices": matching_devices,
        "probeMessage": probe_message,
    }


def main() -> int:
    args = parse_args()
    try:
        receipt = probe_profile(
            profile_id=args.profile,
            policy_path=args.vulkan_profile_policy,
        )
    except ValueError as error:
        print(json.dumps({"ok": False, "error": str(error)}, sort_keys=True))
        return 2
    print(json.dumps(receipt, indent=2, sort_keys=True))
    return 0 if receipt["ok"] else 2


if __name__ == "__main__":
    raise SystemExit(main())
