"""Physical hardware identity checks for strict package comparisons."""

from __future__ import annotations

import re
from typing import Any

from native_compare_modules.reporting import parse_int, safe_int


_DRIVER_VERSION_PATTERN = re.compile(r"(?<!\d)(\d+)\.(\d+)\.(\d+)(?!\d)")
_HARDWARE_TEXT_PATTERN = re.compile(r"[^a-z0-9]+")


def _vulkan_driver_version(raw_version: int) -> str:
    if raw_version <= 0:
        return ""
    major = raw_version >> 22
    minor = (raw_version >> 12) & 0x3FF
    patch = raw_version & 0xFFF
    return f"{major}.{minor}.{patch}"


def _text_driver_version(adapter_info: dict[str, Any]) -> str:
    for field_name in ("driver", "driverDescription", "description"):
        match = _DRIVER_VERSION_PATTERN.search(str(adapter_info.get(field_name, "")))
        if match:
            return ".".join(match.groups())
    return ""


def _adapter_identities(samples: list[dict[str, Any]]) -> list[dict[str, Any]]:
    identities: dict[tuple[int, int, str], dict[str, Any]] = {}
    for sample in samples:
        if not isinstance(sample, dict):
            continue
        trace_meta = sample.get("traceMeta", {})
        if not isinstance(trace_meta, dict):
            continue
        adapter_info = trace_meta.get("adapterInfo", {})
        if not isinstance(adapter_info, dict):
            continue
        raw_driver_version = safe_int(adapter_info.get("driverVersion"), default=0)
        driver_version = _vulkan_driver_version(raw_driver_version) or _text_driver_version(
            adapter_info
        )
        vendor_id = safe_int(adapter_info.get("vendorID"), default=0)
        device_id = safe_int(adapter_info.get("deviceID"), default=0)
        if vendor_id <= 0:
            vendor_id = parse_int(adapter_info.get("vendor")) or 0
        if device_id <= 0:
            device_id = parse_int(adapter_info.get("device")) or 0
        key = (vendor_id, device_id, driver_version)
        identities[key] = {
            "vendor": str(adapter_info.get("vendor", "")).strip(),
            "vendorID": vendor_id,
            "device": str(adapter_info.get("device", "")).strip(),
            "deviceID": device_id,
            "architecture": str(adapter_info.get("architecture", "")).strip(),
            "driverVersion": driver_version,
            "rawDriverVersion": raw_driver_version,
        }
    return [identities[key] for key in sorted(identities)]


def _is_vulkan_identity(identity: dict[str, Any]) -> bool:
    architecture = str(identity.get("architecture", "")).lower()
    device = str(identity.get("device", "")).lower()
    return architecture == "vulkan" or "radv" in device


def _normalized_hardware_text(value: Any) -> str:
    return _HARDWARE_TEXT_PATTERN.sub("", str(value).strip().lower())


def _physical_identity_match(
    left: dict[str, Any],
    right: dict[str, Any],
) -> tuple[bool, str]:
    left_numeric = left["vendorID"] > 0 and left["deviceID"] > 0
    right_numeric = right["vendorID"] > 0 and right["deviceID"] > 0
    driver_match = bool(left["driverVersion"]) and (
        left["driverVersion"] == right["driverVersion"]
    )
    if left_numeric and right_numeric:
        return (
            driver_match
            and left["vendorID"] == right["vendorID"]
            and left["deviceID"] == right["deviceID"],
            "numeric_vendor_device_driver",
        )

    left_vendor = _normalized_hardware_text(left["vendor"])
    right_vendor = _normalized_hardware_text(right["vendor"])
    left_device = _normalized_hardware_text(left["device"])
    right_device = _normalized_hardware_text(right["device"])
    return (
        driver_match
        and bool(left_vendor)
        and left_vendor not in {"generic", "unknown"}
        and left_vendor == right_vendor
        and bool(left_device)
        and left_device == right_device,
        "webgpu_reported_vendor_device_driver",
    )


def record_hardware_path_obligation(
    *,
    record_obligation: Any,
    obligations: list[dict[str, Any]],
    reasons: list[str],
    comparability_mode: str,
    is_dawn_vs_doe: bool,
    package_execution_applies: bool,
    workload_path_asymmetry: bool,
    workload_path_asymmetry_note: str,
    left_samples: list[dict[str, Any]],
    right_samples: list[dict[str, Any]],
) -> None:
    left_identities = _adapter_identities(left_samples)
    right_identities = _adapter_identities(right_samples)
    vulkan_package_identity_applies = (
        package_execution_applies
        and any(_is_vulkan_identity(identity) for identity in left_identities + right_identities)
    )
    identity_match = True
    identity_match_basis = "not_applicable"
    identity_failure = ""
    if vulkan_package_identity_applies:
        identity_match = len(left_identities) == 1 and len(right_identities) == 1
        if identity_match:
            identity_match, identity_match_basis = _physical_identity_match(
                left_identities[0], right_identities[0]
            )
        if not identity_match:
            identity_failure = (
                "strict Vulkan package comparison requires one matching physical "
                "identity reported by both runtimes: use vendorID/deviceID/driverVersion "
                "when both expose numeric IDs, otherwise require exact normalized "
                "vendor/device/driverVersion text: "
                f"baseline={left_identities} comparison={right_identities}"
            )

    hardware_path_match_applies = comparability_mode == "strict" and (
        is_dawn_vs_doe or package_execution_applies
    )
    path_failure = ""
    if workload_path_asymmetry:
        path_failure = (
            "workload contract marks pathAsymmetry=true: baseline/comparison use "
            "hardware-specific execution paths that are not structurally equivalent"
        )
        if workload_path_asymmetry_note:
            path_failure += f" ({workload_path_asymmetry_note})"
    failure_reason = "; ".join(reason for reason in (path_failure, identity_failure) if reason)
    record_obligation(
        obligations,
        reasons,
        obligation_id="baseline_comparison_hardware_path_match",
        blocking=True,
        applicable=hardware_path_match_applies,
        passes=not workload_path_asymmetry and identity_match,
        failure_reason=failure_reason,
        details={
            "comparabilityMode": comparability_mode,
            "isDawnVsDoe": is_dawn_vs_doe,
            "packageExecutionApplies": package_execution_applies,
            "workloadPathAsymmetry": bool(workload_path_asymmetry),
            "workloadPathAsymmetryNote": workload_path_asymmetry_note,
            "vulkanPackageIdentityApplies": vulkan_package_identity_applies,
            "baselineAdapterIdentities": left_identities,
            "comparisonAdapterIdentities": right_identities,
            "physicalAdapterIdentityMatch": identity_match,
            "physicalAdapterIdentityMatchBasis": identity_match_basis,
        },
    )
