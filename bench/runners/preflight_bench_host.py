#!/usr/bin/env python3
"""Local host preflight for Dawn-vs-Doe benchmark execution."""

from __future__ import annotations

import argparse
import json
import os
import platform
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path

ADAPTER_HEADER_RE = re.compile(r'^\s*-\s+"(?P<name>[^"]+)"\s+-\s+"(?P<driver>.*)"\s*$')
ADAPTER_FIELD_RE = re.compile(r'^\s*(?P<key>\w+):\s*(?P<value>.+?)\s*$')
INCOMPATIBLE_DRIVER_RE = re.compile(r"Could not open device (?P<device>/dev/dri/[^:]+): Permission denied")
VULKANINFO_GPU_RE = re.compile(r"^GPU(?P<ordinal>\d+):\s*$")
REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_VULKAN_PROFILE_POLICY = REPO_ROOT / "config" / "vulkan-host-profiles.json"


@dataclass(frozen=True)
class VulkanHostProfile:
    """Resolved config contract for one strict Vulkan benchmark host."""

    id: str
    display_name: str
    cube_host_profile: str
    os: str
    arch: str
    vendor_id: str
    icd_paths: tuple[Path, ...]
    device_ids: tuple[str, ...]
    driver_versions: tuple[str, ...]
    runtime_vendor: str
    runtime_api: str
    runtime_family: str
    runtime_driver: str
    backend_lane: str

    @property
    def icd_path(self) -> Path:
        """Return the first configured ICD candidate installed on this host."""

        for candidate in self.icd_paths:
            if candidate.is_file():
                return candidate
        return self.icd_paths[0]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    strict_group = parser.add_mutually_exclusive_group()
    strict_group.add_argument(
        "--strict-amd-vulkan",
        action="store_true",
        help="Compatibility alias for --strict-vulkan-profile linux_amd_vulkan.",
    )
    strict_group.add_argument(
        "--strict-vulkan-profile",
        default="",
        help="Named profile from config/vulkan-host-profiles.json.",
    )
    parser.add_argument(
        "--vulkan-profile-policy",
        type=Path,
        default=DEFAULT_VULKAN_PROFILE_POLICY,
        help="Schema-backed Vulkan host-profile policy path.",
    )
    parser.add_argument("--json", action="store_true", dest="emit_json")
    return parser.parse_args()


def normalize_pci_id(value: object) -> str:
    """Normalize a Vulkan or Dawn PCI identifier to lower-case hexadecimal."""

    text = str(value).strip().lower()
    try:
        return f"0x{int(text, 0):04x}"
    except ValueError:
        return text


def normalize_arch(value: str) -> str:
    normalized = value.strip().lower()
    if normalized in {"x86_64", "amd64"}:
        return "x64"
    if normalized in {"aarch64", "arm64"}:
        return "arm64"
    return normalized


def load_vulkan_host_profiles(path: Path) -> dict[str, VulkanHostProfile]:
    """Load named Vulkan host profiles from the versioned policy."""

    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except OSError as error:
        raise ValueError(f"unable to read Vulkan host-profile policy {path}: {error}") from error
    except json.JSONDecodeError as error:
        raise ValueError(f"invalid Vulkan host-profile policy JSON {path}: {error}") from error

    rows = payload.get("profiles") if isinstance(payload, dict) else None
    if not isinstance(rows, list):
        raise ValueError(f"Vulkan host-profile policy has no profiles array: {path}")

    profiles: dict[str, VulkanHostProfile] = {}
    for row in rows:
        if not isinstance(row, dict):
            raise ValueError(f"Vulkan host-profile row must be an object: {row!r}")
        runtime = row.get("runtimeProfile")
        if not isinstance(runtime, dict):
            raise ValueError(f"Vulkan host profile {row.get('id', '<missing>')} has no runtimeProfile")
        profile_id = str(row.get("id", "")).strip()
        if not profile_id:
            raise ValueError("Vulkan host profile id must be non-empty")
        if profile_id in profiles:
            raise ValueError(f"duplicate Vulkan host profile id: {profile_id}")
        icd_paths = tuple(
            Path(str(value).strip()) for value in row.get("icdPaths", [])
        )
        if not icd_paths or any(not str(path) for path in icd_paths):
            raise ValueError(
                f"Vulkan host profile {profile_id} has no ICD path candidates"
            )
        profiles[profile_id] = VulkanHostProfile(
            id=profile_id,
            display_name=str(row.get("displayName", "")).strip(),
            cube_host_profile=str(row.get("cubeHostProfile", "")).strip(),
            os=str(row.get("os", "")).strip(),
            arch=str(row.get("arch", "")).strip(),
            vendor_id=normalize_pci_id(row.get("vendorId", "")),
            icd_paths=icd_paths,
            device_ids=tuple(normalize_pci_id(value) for value in row.get("deviceIds", [])),
            driver_versions=tuple(
                str(value).strip() for value in row.get("driverVersions", [])
            ),
            runtime_vendor=str(runtime.get("vendor", "")).strip(),
            runtime_api=str(runtime.get("api", "")).strip(),
            runtime_family=str(runtime.get("family", "")).strip(),
            runtime_driver=str(runtime.get("driver", "")).strip(),
            backend_lane=str(row.get("backendLane", "")).strip(),
        )
    return profiles


def resolve_vulkan_host_profile(
    path: Path,
    profile_id: str,
) -> VulkanHostProfile:
    profiles = load_vulkan_host_profiles(path)
    try:
        return profiles[profile_id]
    except KeyError as error:
        available = ", ".join(sorted(profiles))
        raise ValueError(
            f"unknown Vulkan host profile {profile_id!r}; available: {available}"
        ) from error


def check_file(path: Path) -> tuple[bool, str]:
    if path.exists() and path.is_file():
        return True, "ok"
    return False, f"missing file: {path}"


def check_readwrite(path: Path) -> tuple[bool, str]:
    if not path.exists():
        return False, f"missing device node: {path}"
    readable = os.access(path, os.R_OK)
    writable = os.access(path, os.W_OK)
    if readable and writable:
        return True, "ok"
    return False, f"insufficient permissions on {path} (read={readable}, write={writable})"


def parse_dawn_adapters(output: str) -> list[dict[str, str]]:
    adapters: list[dict[str, str]] = []
    current: dict[str, str] | None = None
    for raw_line in output.splitlines():
        header = ADAPTER_HEADER_RE.match(raw_line)
        if header:
            if current is not None:
                adapters.append(current)
            current = {
                "name": header.group("name").strip(),
                "driver": header.group("driver").strip(),
            }
            continue

        field = ADAPTER_FIELD_RE.match(raw_line)
        if field is None or current is None:
            continue
        key = field.group("key").strip()
        value = field.group("value").strip()
        current[key] = value
        if "," in value:
            for segment in value.split(", "):
                nested_field = ADAPTER_FIELD_RE.match(segment)
                if nested_field is None:
                    continue
                current[nested_field.group("key").strip()] = nested_field.group("value").strip()

    if current is not None:
        adapters.append(current)
    return adapters


def find_matching_adapter(adapters: list[dict[str, str]], backend: str, vendor_id: str) -> bool:
    backend_norm = backend.lower()
    vendor_norm = normalize_pci_id(vendor_id)
    for adapter in adapters:
        adapter_backend = str(adapter.get("backend", "")).strip().lower()
        adapter_vendor = normalize_pci_id(
            str(adapter.get("vendorId", "")).split(",")[0]
        )
        if adapter_backend == backend_norm and adapter_vendor == vendor_norm:
            return True
    return False


def format_adapter_summary(adapters: list[dict[str, str]]) -> str:
    if not adapters:
        return "  (no adapters reported)"
    lines: list[str] = []
    for adapter in adapters:
        lines.append(
            "  - "
            f"{adapter.get('name', '')} "
            f"(backend={adapter.get('backend', '')}, "
            f"vendorId={adapter.get('vendorId', '')}, "
            f"type={adapter.get('type', '')}, "
            f"architecture={adapter.get('architecture', '')})"
        )
    return "\n".join(lines)


def vulkan_device_matches_profile(
    device: dict[str, str],
    profile: VulkanHostProfile,
) -> bool:
    vendor_matches = normalize_pci_id(device.get("vendorID", "")) == profile.vendor_id
    device_id = normalize_pci_id(device.get("deviceID", ""))
    device_matches = not profile.device_ids or device_id in profile.device_ids
    driver_version = str(device.get("driverVersion", "")).strip()
    driver_matches = (
        not profile.driver_versions or driver_version in profile.driver_versions
    )
    return vendor_matches and device_matches and driver_matches


def parse_vulkaninfo_summary(output: str) -> list[dict[str, str]]:
    gpus: list[dict[str, str]] = []
    current: dict[str, str] | None = None
    for raw_line in output.splitlines():
        header = VULKANINFO_GPU_RE.match(raw_line.strip())
        if header:
            if current is not None:
                gpus.append(current)
            current = {"ordinal": header.group("ordinal")}
            continue
        if current is None:
            continue
        if "=" not in raw_line:
            continue
        key, value = raw_line.split("=", 1)
        current[key.strip()] = value.strip()
    if current is not None:
        gpus.append(current)
    return gpus


def profile_environment(profile: VulkanHostProfile) -> dict[str, str]:
    """Return an environment pinned to the profile's Vulkan ICD."""

    environment = os.environ.copy()
    environment["VK_DRIVER_FILES"] = str(profile.icd_path)
    environment["VK_ICD_FILENAMES"] = str(profile.icd_path)
    return environment


def probe_vulkaninfo_gpus(
    profile: VulkanHostProfile,
) -> tuple[list[dict[str, str]], str]:
    command = ["vulkaninfo", "--summary"]
    try:
        completed = subprocess.run(
            command,
            text=True,
            capture_output=True,
            check=False,
            env=profile_environment(profile),
        )
    except OSError as error:
        return [], f"failed to execute vulkaninfo: {error}"
    if completed.returncode != 0:
        return [], f"vulkaninfo failed (rc={completed.returncode})"
    return parse_vulkaninfo_summary(completed.stdout), "ok"


def probe_doe_adapter(
    runtime_bin: Path,
    profile: VulkanHostProfile,
) -> tuple[dict[str, object] | None, str]:
    if not runtime_bin.exists():
        return None, f"missing Doe runtime: {runtime_bin}"

    with tempfile.TemporaryDirectory(prefix="fawn-doe-preflight-") as tmpdir:
        tmp_path = Path(tmpdir)
        commands_path = tmp_path / "commands.json"
        trace_meta_path = tmp_path / "trace-meta.json"
        commands_path.write_text(
            json.dumps([{"kind": "barrier", "dependency_count": 1}], ensure_ascii=True),
            encoding="utf-8",
        )
        command = [
            "env",
            "LD_LIBRARY_PATH=bench/vendor/dawn/out/Release:" + os.environ.get("LD_LIBRARY_PATH", ""),
            f"VK_DRIVER_FILES={profile.icd_path}",
            f"VK_ICD_FILENAMES={profile.icd_path}",
            str(runtime_bin),
            "--commands",
            str(commands_path),
            "--vendor",
            profile.runtime_vendor,
            "--api",
            profile.runtime_api,
            "--family",
            profile.runtime_family,
            "--driver",
            profile.runtime_driver,
            "--backend",
            "native",
            "--backend-lane",
            profile.backend_lane,
            "--execute",
            "--trace-meta",
            str(trace_meta_path),
        ]
        try:
            completed = subprocess.run(command, text=True, capture_output=True, check=False)
        except OSError as error:
            return None, f"failed to execute Doe adapter probe: {error}"
        if completed.returncode != 0:
            return None, f"Doe adapter probe failed (rc={completed.returncode}): {shlex.join(command)}"
        try:
            payload = json.loads(trace_meta_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as error:
            return None, f"failed to read Doe trace-meta probe: {error}"
        if not isinstance(payload, dict):
            return None, "Doe trace-meta probe did not produce an object"
        return payload, "ok"


def resolve_doe_vulkan_identity(
    runtime_bin: Path,
    profile: VulkanHostProfile,
) -> tuple[dict[str, str] | None, dict[str, object] | None, str]:
    trace_meta, probe_message = probe_doe_adapter(runtime_bin, profile)
    if trace_meta is None:
        return None, None, probe_message

    adapter_ordinal = trace_meta.get("adapterOrdinal")
    if not isinstance(adapter_ordinal, int) or adapter_ordinal < 0:
        return None, trace_meta, "Doe adapter probe did not emit adapterOrdinal"

    gpus, vulkaninfo_message = probe_vulkaninfo_gpus(profile)
    if not gpus:
        return None, trace_meta, vulkaninfo_message

    ordinal_text = str(adapter_ordinal)
    for gpu in gpus:
        if gpu.get("ordinal") == ordinal_text:
            return gpu, trace_meta, "ok"
    return None, trace_meta, f"vulkaninfo did not report GPU ordinal {adapter_ordinal}"


def probe_dawn_adapter(
    dawn_binary: Path,
    backend: str,
    vendor_id: str,
    profile: VulkanHostProfile,
) -> tuple[bool, str]:
    if not dawn_binary.exists():
        return False, f"missing dawn binary: {dawn_binary}"
    command = [
        str(dawn_binary),
        "--gtest_list_tests",
        f"--backend={backend}",
        f"--adapter-vendor-id={vendor_id}",
    ]
    try:
        completed = subprocess.run(
            command,
            text=True,
            capture_output=True,
            check=False,
            env=profile_environment(profile),
        )
    except OSError as error:
        return False, f"failed to execute Dawn adapter probe: {error}"

    combined_output = f"{completed.stdout}\n{completed.stderr}"
    adapters = parse_dawn_adapters(combined_output)
    adapter_found = find_matching_adapter(adapters, backend, vendor_id)
    permission_denied = bool(INCOMPATIBLE_DRIVER_RE.search(combined_output))

    if completed.returncode != 0:
        return (
            False,
            "Dawn adapter probe failed "
            f"(rc={completed.returncode}): {shlex.join(command)}",
        )
    if adapter_found:
        return True, "ok"

    reason = (
        "requested Dawn adapter is unavailable "
        f"(backend={backend}, vendor-id={vendor_id})\n"
        f"Detected adapters:\n{format_adapter_summary(adapters)}"
    )
    if permission_denied:
        reason += "\nHint: Vulkan reported permission denied opening /dev/dri render nodes."
    return False, reason


def probe_dawn_adapters(
    dawn_binary: Path,
    backend: str,
    vendor_id: str,
    profile: VulkanHostProfile,
) -> tuple[list[dict[str, str]], str]:
    if not dawn_binary.exists():
        return [], f"missing dawn binary: {dawn_binary}"
    command = [
        str(dawn_binary),
        "--gtest_list_tests",
        f"--backend={backend}",
        f"--adapter-vendor-id={vendor_id}",
    ]
    try:
        completed = subprocess.run(
            command,
            text=True,
            capture_output=True,
            check=False,
            env=profile_environment(profile),
        )
    except OSError as error:
        return [], f"failed to execute Dawn adapter probe: {error}"
    if completed.returncode != 0:
        return [], f"Dawn adapter probe failed (rc={completed.returncode}): {shlex.join(command)}"
    return parse_dawn_adapters(f"{completed.stdout}\n{completed.stderr}"), "ok"


def main() -> int:
    args = parse_args()

    selected_profile_id = (
        "linux_amd_vulkan" if args.strict_amd_vulkan else args.strict_vulkan_profile.strip()
    )
    selected_profile: VulkanHostProfile | None = None
    if selected_profile_id:
        try:
            selected_profile = resolve_vulkan_host_profile(
                args.vulkan_profile_policy,
                selected_profile_id,
            )
        except ValueError as error:
            print(f"FAIL: {error}")
            return 2

    checks: list[dict[str, object]] = []

    runtime_bin = Path("runtime/zig/zig-out/bin/doe-zig-runtime")
    dawn_bin = Path("bench/vendor/dawn/out/Release/dawn_perf_tests")
    # Dawn's shared library is emitted as `libwebgpu_dawn.so` in current Dawn
    # builds (GN + CMake). The Zig runtime's dlopen loader in
    # `runtime/zig/src/core/abi/wgpu_loader.zig` tries `libwebgpu_dawn.so` as
    # the first Dawn candidate, so this is the authoritative preflight name.
    # The older `libwebgpu.so` alias and the unrelated `libwgpu_native.so`
    # (wgpu-native, a different implementation) were previously checked but
    # neither exists in current vendored Dawn output and neither is required
    # for the Dawn-vs-Doe comparison path.
    lib_webgpu_dawn = Path("bench/vendor/dawn/out/Release/libwebgpu_dawn.so")

    for name, path in (
        ("doeRuntime", runtime_bin),
        ("dawnPerfTests", dawn_bin),
        ("libwebgpuDawn", lib_webgpu_dawn),
    ):
        ok, message = check_file(path)
        checks.append({"name": name, "ok": ok, "message": message})

    render_node = Path("/dev/dri/renderD128")
    ok_render, msg_render = check_readwrite(render_node)
    checks.append({"name": "renderNodeAccess", "ok": ok_render, "message": msg_render})

    groups = set(os.getgroups())
    groups.add(os.getgid())
    groups.add(os.getegid())
    render_gid = None
    try:
        import grp

        render_gid = grp.getgrnam("render").gr_gid
    except Exception:
        render_gid = None

    in_render_group = render_gid is not None and render_gid in groups
    checks.append(
        {
            "name": "renderGroupMembership",
            "ok": in_render_group,
            "message": "ok" if in_render_group else "user is not in render group",
        }
    )

    if selected_profile is not None:
        host_os = "linux" if sys.platform.startswith("linux") else sys.platform
        host_arch = normalize_arch(platform.machine())
        checks.append(
            {
                "name": "strictVulkanHostOperatingSystem",
                "ok": host_os == selected_profile.os,
                "message": (
                    "ok"
                    if host_os == selected_profile.os
                    else f"host os {host_os} does not match {selected_profile.os}"
                ),
            }
        )
        checks.append(
            {
                "name": "strictVulkanHostArchitecture",
                "ok": host_arch == selected_profile.arch,
                "message": (
                    "ok"
                    if host_arch == selected_profile.arch
                    else f"host architecture {host_arch} does not match {selected_profile.arch}"
                ),
            }
        )

        vulkaninfo_path = shutil.which("vulkaninfo")
        checks.append(
            {
                "name": "strictVulkanInfoAvailable",
                "ok": vulkaninfo_path is not None,
                "message": "ok" if vulkaninfo_path else "missing vulkaninfo binary",
            }
        )
        icd_exists = selected_profile.icd_path.is_file()
        checks.append(
            {
                "name": "strictVulkanIcdFile",
                "ok": icd_exists,
                "message": (
                    "ok"
                    if icd_exists
                    else (
                        "missing Vulkan ICD file; tried: "
                        + ", ".join(
                            str(path) for path in selected_profile.icd_paths
                        )
                    )
                ),
            }
        )
        profile_devices: list[dict[str, str]] = []
        profile_probe_message = "vulkaninfo or configured ICD is unavailable"
        if vulkaninfo_path is not None and icd_exists:
            profile_devices, profile_probe_message = probe_vulkaninfo_gpus(
                selected_profile
            )
        profile_hardware_matches = any(
            vulkan_device_matches_profile(device, selected_profile)
            for device in profile_devices
        )
        checks.append(
            {
                "name": "strictVulkanProfileAdapter",
                "ok": profile_hardware_matches,
                "message": (
                    "ok"
                    if profile_hardware_matches
                    else (
                        "configured ICD did not expose an adapter matching "
                        f"vendorId={selected_profile.vendor_id}, "
                        f"deviceIds={list(selected_profile.device_ids)}, "
                        f"driverVersions={list(selected_profile.driver_versions)}: "
                        f"{profile_probe_message}"
                    )
                ),
            }
        )

        backend = "vulkan"
        vendor_id = selected_profile.vendor_id
        ok_adapter_probe, msg_adapter_probe = probe_dawn_adapter(
            dawn_bin,
            backend,
            vendor_id,
            selected_profile,
        )
        dawn_adapters, dawn_adapters_message = probe_dawn_adapters(
            dawn_bin,
            backend,
            vendor_id,
            selected_profile,
        )
        doe_identity, _, doe_probe_message = resolve_doe_vulkan_identity(
            runtime_bin,
            selected_profile,
        )
        doe_vendor_matches = (
            doe_identity is not None
            and normalize_pci_id(doe_identity.get("vendorID", "")) == vendor_id
        )
        doe_device_id = (
            normalize_pci_id(doe_identity.get("deviceID", ""))
            if doe_identity is not None
            else ""
        )
        doe_device_matches = (
            doe_identity is not None
            and (
                not selected_profile.device_ids
                or doe_device_id in selected_profile.device_ids
            )
        )
        doe_driver_version = (
            str(doe_identity.get("driverVersion", "")).strip()
            if doe_identity is not None
            else ""
        )
        doe_driver_matches = (
            doe_identity is not None
            and (
                not selected_profile.driver_versions
                or doe_driver_version in selected_profile.driver_versions
            )
        )
        doe_profile_matches = (
            doe_vendor_matches and doe_device_matches and doe_driver_matches
        )
        dawn_identity_match = False
        dawn_identity_message = dawn_adapters_message
        checks.append(
            {
                "name": "strictVulkanDawnAdapterProbe",
                "ok": ok_adapter_probe,
                "message": msg_adapter_probe,
            }
        )
        checks.append(
            {
                "name": "strictVulkanDoeAdapterProbe",
                "ok": doe_identity is not None,
                "message": (
                    "ok"
                    if doe_identity is not None
                    else doe_probe_message
                ),
            }
        )
        checks.append(
            {
                "name": "strictVulkanDoeAdapterIdentity",
                "ok": doe_profile_matches,
                "message": (
                    "ok"
                    if doe_profile_matches
                    else (
                        "Doe selected a Vulkan adapter outside the named profile "
                        f"(vendorId={vendor_id}, deviceIds={list(selected_profile.device_ids)}, "
                        f"driverVersions={list(selected_profile.driver_versions)})"
                        if doe_identity is not None
                        else "Doe adapter identity unavailable"
                    )
                ),
            }
        )
        if doe_identity is not None and dawn_adapters:
            doe_vendor = normalize_pci_id(doe_identity.get("vendorID", ""))
            doe_device = normalize_pci_id(doe_identity.get("deviceID", ""))
            doe_name = str(doe_identity.get("deviceName", "")).strip()
            dawn_identity_match = any(
                str(adapter.get("backend", "")).strip().lower() == backend
                and normalize_pci_id(str(adapter.get("vendorId", "")).split(",")[0])
                == doe_vendor
                and normalize_pci_id(str(adapter.get("deviceId", "")).split(",")[0])
                == doe_device
                for adapter in dawn_adapters
            )
            dawn_identity_message = (
                    "ok"
                    if dawn_identity_match
                    else (
                    "strict Vulkan comparability requires Doe and Dawn to resolve to the same "
                    f"vendor/device identity; Doe selected {doe_name} "
                    f"(vendorId={doe_vendor}, deviceId={doe_device})"
                )
            )
            checks.append(
                {
                    "name": "strictVulkanDoeDawnIdentityMatch",
                    "ok": dawn_identity_match,
                    "message": dawn_identity_message,
                }
            )
        strict_identity_ok = (
            ok_render
            and in_render_group
            and vulkaninfo_path is not None
            and icd_exists
            and profile_hardware_matches
            and ok_adapter_probe
            and doe_profile_matches
            and dawn_identity_match
        )
        checks.append(
            {
                "name": "strictVulkanIdentityRequirement",
                "ok": strict_identity_ok,
                "message": (
                    "ok"
                    if strict_identity_ok
                    else (
                        "strict Vulkan runs require vulkaninfo, accessible render node, render group, "
                        "the configured ICD, and matching Doe/Dawn adapter identity for profile "
                        f"{selected_profile.id}"
                    )
                ),
            }
        )

    failed = [entry for entry in checks if not bool(entry["ok"])]
    status = {
        "ok": len(failed) == 0,
        "checkCount": len(checks),
        "failedCount": len(failed),
        "profile": (
            {
                "id": selected_profile.id,
                "displayName": selected_profile.display_name,
                "cubeHostProfile": selected_profile.cube_host_profile,
                "vendorId": selected_profile.vendor_id,
                "icdPath": str(selected_profile.icd_path),
                "deviceIds": list(selected_profile.device_ids),
                "driverVersions": list(selected_profile.driver_versions),
                "runtimeProfile": {
                    "vendor": selected_profile.runtime_vendor,
                    "api": selected_profile.runtime_api,
                    "family": selected_profile.runtime_family,
                    "driver": selected_profile.runtime_driver,
                },
                "backendLane": selected_profile.backend_lane,
            }
            if selected_profile is not None
            else None
        ),
        "checks": checks,
        "recommendations": [
            "Set LD_LIBRARY_PATH=bench/vendor/dawn/out/Release:$LD_LIBRARY_PATH for native Fawn runs.",
            "If /dev/dri/renderD128 is denied, add your user to group render and re-login.",
            "Install vulkan-tools so strict Vulkan profiles can bind Doe adapter ordinals to PCI identities.",
            "Use only workload/config lanes whose declared vendor and adapter contract matches the selected host profile.",
        ],
    }

    if args.emit_json:
        print(json.dumps(status, indent=2))
    else:
        print(f"preflight ok={status['ok']} failed={status['failedCount']}")
        for entry in checks:
            state = "ok" if bool(entry["ok"]) else "fail"
            print(f"[{state}] {entry['name']}: {entry['message']}")

    return 0 if status["ok"] else 2


if __name__ == "__main__":
    raise SystemExit(main())
