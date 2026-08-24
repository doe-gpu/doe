#!/usr/bin/env python3
"""Generate browser projection manifest from core Dawn-vs-Doe workloads."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

REPO_ROOT = Path(__file__).resolve().parents[3]
VALID_PROJECTION_CLASSES = {"high", "medium", "non_projectable"}
VALID_LAYER_TARGETS = {"l1_browser_api", "l0_only"}
VALID_COMPARABILITY = {"strict", "component", "none"}
VALID_REQUIRED_STATUS = {"ok", "not_applicable"}
VALID_CLAIM_SCOPE = {"l1_strict_candidate", "l1_component_only", "l0_only_no_claim"}
MAX_BROWSER_EXACT_UPLOAD_BYTES = 16 * 1024 * 1024
PROJECTION_MANIFEST_SCHEMA_VERSION = 7
SOURCE_KERNEL_BIND_GROUP_LAYOUT_MODE = "explicit_min_binding_size_v1"
SOURCE_KERNEL_READBACK_BINDING_POLICY = "first_writable_storage_binding_v1"
SOURCE_KERNEL_OUTPUT_ORACLE_KIND = "sha256_exact_v1"
SOURCE_KERNEL_OUTPUT_ORACLE_INITIALIZATION = "zero_fill_v1"
COMPUTE_PROJECTION_DIRECT_DISPATCH = "generic_direct_dispatch_component"
COMPUTE_PROJECTION_EMPTY_DISPATCH = "generic_empty_dispatch_component"
COMPUTE_PROJECTION_INDIRECT_DISPATCH = "generic_indirect_dispatch_component"
COMPUTE_PROJECTION_SOURCE_KERNEL = "source_kernel_dispatch_v1"
COMPUTE_PROJECTION_SOURCE_KERNEL_ORACLE = "source_kernel_dispatch_oracle_v2"
RENDER_OUTPUT_ORACLE_KIND = "rgba8_exact_rect_v1"
RENDER_OUTPUT_ORACLE_WIDTH = 64
RENDER_OUTPUT_ORACLE_HEIGHT = 64
RENDER_OUTPUT_ORACLE_BYTES_PER_ROW = 256
RENDER_OUTPUT_ORACLE_RECT = {"x": 16, "y": 16, "width": 32, "height": 32}
RENDER_OUTPUT_ORACLE_INSIDE_RGBA = [255, 0, 0, 255]
RENDER_OUTPUT_ORACLE_OUTSIDE_RGBA = [0, 0, 0, 255]
DIRECT_DISPATCH_COMMAND_KINDS = {"dispatch", "dispatch_workgroups"}
SIZE_UNITS = {
    "b": 1,
    "kb": 1024,
    "mb": 1024 * 1024,
    "gb": 1024 * 1024 * 1024,
}


def parse_args() -> argparse.Namespace:
    repo_root = Path(__file__).resolve().parents[3]
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--workloads",
        default="bench/workloads/specialized/workloads.amd.vulkan.superset.json",
        help="Path to core workload JSON.",
    )
    parser.add_argument(
        "--rules",
        default="browser/chromium/bench/projection-rules.json",
        help="Path to projection-rules.json.",
    )
    parser.add_argument(
        "--out",
        default="browser/chromium/bench/generated/browser_projection_manifest.json",
        help="Output manifest path.",
    )
    parser.add_argument(
        "--check-only",
        action="store_true",
        help="Validate inputs and print summary without writing output.",
    )
    parser.add_argument(
        "--verify",
        action="store_true",
        help="Fail when the existing output differs from the generated manifest.",
    )
    args = parser.parse_args()
    if args.check_only and args.verify:
        parser.error("--check-only and --verify are mutually exclusive")
    return args


def load_json(path: Path) -> dict[str, Any]:
    payload = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(payload, dict):
        raise ValueError(f"invalid JSON object: {path}")
    return payload


def resolve_path(value: str, repo_root: Path) -> Path:
    candidate = Path(value)
    if candidate.is_absolute():
        return candidate.resolve()
    return (repo_root / candidate).resolve()


def display_path(path: Path, repo_root: Path) -> str:
    try:
        return path.relative_to(repo_root).as_posix()
    except ValueError:
        return str(path)


def file_sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def payload_sha256(value: Any) -> str:
    canonical = json.dumps(value, sort_keys=True, separators=(",", ":")).encode("utf-8")
    return hashlib.sha256(canonical).hexdigest()


def render_output_oracle() -> dict[str, Any]:
    payload = bytearray(RENDER_OUTPUT_ORACLE_BYTES_PER_ROW * RENDER_OUTPUT_ORACLE_HEIGHT)
    rect = RENDER_OUTPUT_ORACLE_RECT
    for y in range(RENDER_OUTPUT_ORACLE_HEIGHT):
        for x in range(RENDER_OUTPUT_ORACLE_WIDTH):
            inside = (
                rect["x"] <= x < rect["x"] + rect["width"]
                and rect["y"] <= y < rect["y"] + rect["height"]
            )
            rgba = (
                RENDER_OUTPUT_ORACLE_INSIDE_RGBA
                if inside
                else RENDER_OUTPUT_ORACLE_OUTSIDE_RGBA
            )
            offset = y * RENDER_OUTPUT_ORACLE_BYTES_PER_ROW + x * 4
            payload[offset : offset + 4] = bytes(rgba)
    return {
        "schemaVersion": 1,
        "kind": RENDER_OUTPUT_ORACLE_KIND,
        "width": RENDER_OUTPUT_ORACLE_WIDTH,
        "height": RENDER_OUTPUT_ORACLE_HEIGHT,
        "bytesPerRow": RENDER_OUTPUT_ORACLE_BYTES_PER_ROW,
        "rect": dict(RENDER_OUTPUT_ORACLE_RECT),
        "insideRgba": list(RENDER_OUTPUT_ORACLE_INSIDE_RGBA),
        "outsideRgba": list(RENDER_OUTPUT_ORACLE_OUTSIDE_RGBA),
        "expectedSha256": hashlib.sha256(payload).hexdigest(),
        "referenceId": "fullscreen_triangle_viewport_scissor_rgba8_v1",
    }


def require_string(value: Any, label: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise ValueError(f"missing non-empty string: {label}")
    return value


def require_rule_shape(rule: dict[str, Any], label: str) -> dict[str, str]:
    projection_class = require_string(rule.get("projectionClass"), f"{label}.projectionClass")
    layer_target = require_string(rule.get("layerTarget"), f"{label}.layerTarget")
    scenario_template = require_string(rule.get("scenarioTemplate"), f"{label}.scenarioTemplate")
    comparability = require_string(
        rule.get("comparabilityExpectation"), f"{label}.comparabilityExpectation"
    )
    required_status = require_string(rule.get("requiredStatus"), f"{label}.requiredStatus")
    claim_scope = require_string(rule.get("claimScope"), f"{label}.claimScope")
    claim_language = require_string(rule.get("claimLanguage"), f"{label}.claimLanguage")
    projection_note = require_string(rule.get("projectionNote"), f"{label}.projectionNote")

    if projection_class not in VALID_PROJECTION_CLASSES:
        raise ValueError(f"invalid {label}.projectionClass: {projection_class}")
    if layer_target not in VALID_LAYER_TARGETS:
        raise ValueError(f"invalid {label}.layerTarget: {layer_target}")
    if comparability not in VALID_COMPARABILITY:
        raise ValueError(f"invalid {label}.comparabilityExpectation: {comparability}")
    if required_status not in VALID_REQUIRED_STATUS:
        raise ValueError(f"invalid {label}.requiredStatus: {required_status}")
    if claim_scope not in VALID_CLAIM_SCOPE:
        raise ValueError(f"invalid {label}.claimScope: {claim_scope}")

    if projection_class in {"high", "medium"}:
        if layer_target != "l1_browser_api":
            raise ValueError(
                f"{label} must target l1_browser_api for projectionClass={projection_class}"
            )
        if scenario_template == "none":
            raise ValueError(
                f"{label} must provide non-none scenarioTemplate for projectionClass={projection_class}"
            )
        if required_status != "ok":
            raise ValueError(
                f"{label} requiredStatus must be ok for projectionClass={projection_class}"
            )
    if projection_class == "non_projectable":
        if layer_target != "l0_only":
            raise ValueError(f"{label} must target l0_only for non_projectable")
        if required_status != "not_applicable":
            raise ValueError(f"{label} requiredStatus must be not_applicable for non_projectable")
        if claim_scope != "l0_only_no_claim":
            raise ValueError(f"{label} claimScope must be l0_only_no_claim for non_projectable")
        if comparability != "none":
            raise ValueError(
                f"{label} comparabilityExpectation must be none for non_projectable"
            )
    if comparability == "strict" and claim_scope != "l1_strict_candidate":
        raise ValueError(f"{label} strict comparability requires claimScope=l1_strict_candidate")
    if comparability == "component" and claim_scope != "l1_component_only":
        raise ValueError(f"{label} component comparability requires claimScope=l1_component_only")
    if comparability == "none" and claim_scope != "l0_only_no_claim":
        raise ValueError(f"{label} none comparability requires claimScope=l0_only_no_claim")

    return {
        "projectionClass": projection_class,
        "layerTarget": layer_target,
        "scenarioTemplate": scenario_template,
        "comparabilityExpectation": comparability,
        "requiredStatus": required_status,
        "claimScope": claim_scope,
        "claimLanguage": claim_language,
        "projectionNote": projection_note,
    }


def parse_size_bytes(text: str) -> int | None:
    match = re.search(r"(?P<count>[0-9]+)\s*(?P<unit>gb|mb|kb|b)\b", text, flags=re.I)
    if match is None:
        return None
    count = int(match.group("count"))
    unit = match.group("unit").lower()
    multiplier = SIZE_UNITS.get(unit)
    if multiplier is None:
        return None
    return count * multiplier


def source_strict_comparable(browser_workload: dict[str, Any]) -> bool:
    return (
        browser_workload.get("sourceComparable") is True
        and browser_workload.get("sourceClaimEligible") is True
        and browser_workload.get("benchmarkClass") == "comparable"
    )


def resolve_kernel_path(kernel_name: str, repo_root: Path) -> Path | None:
    kernel_path = Path(kernel_name)
    candidates: list[Path] = []
    if kernel_path.suffix:
        candidates.append(repo_root / "bench/kernels" / kernel_path.name)
        candidates.append(resolve_path(kernel_name, repo_root))
    else:
        candidates.append(repo_root / "bench/kernels" / f"{kernel_name}.wgsl")
        candidates.append(repo_root / "bench/kernels" / kernel_name)
    for candidate in candidates:
        resolved = candidate.resolve()
        if resolved.is_file() and resolved.suffix == ".wgsl":
            return resolved
    return None


def webgpu_buffer_binding_type(buffer_type: Any) -> str | None:
    if buffer_type in {"readonly", "read-only-storage"}:
        return "read-only-storage"
    if buffer_type in {None, "storage"}:
        return "storage"
    return None


def source_output_oracle(
    command: dict[str, Any],
    storage_bindings: list[dict[str, Any]],
) -> dict[str, Any] | None:
    oracle = command.get("output_oracle")
    if oracle is None:
        return None
    if not isinstance(oracle, dict):
        raise ValueError("strict source kernel command output_oracle must be an object")
    if oracle.get("schema_version") != 1:
        raise ValueError("strict source kernel output_oracle.schema_version must be 1")
    kind = require_string(oracle.get("kind"), "output_oracle.kind")
    if kind != SOURCE_KERNEL_OUTPUT_ORACLE_KIND:
        raise ValueError(
            f"output_oracle.kind must be {SOURCE_KERNEL_OUTPUT_ORACLE_KIND}"
        )
    initialization = require_string(
        oracle.get("initialization"), "output_oracle.initialization"
    )
    if initialization != SOURCE_KERNEL_OUTPUT_ORACLE_INITIALIZATION:
        raise ValueError(
            "output_oracle.initialization must be "
            f"{SOURCE_KERNEL_OUTPUT_ORACLE_INITIALIZATION}"
        )
    binding_group = oracle.get("binding_group")
    binding = oracle.get("binding")
    dispatch_count = oracle.get("dispatch_count")
    if not isinstance(binding_group, int) or isinstance(binding_group, bool) or binding_group < 0:
        raise ValueError("output_oracle.binding_group must be a non-negative integer")
    if not isinstance(binding, int) or isinstance(binding, bool) or binding < 0:
        raise ValueError("output_oracle.binding must be a non-negative integer")
    if not isinstance(dispatch_count, int) or isinstance(dispatch_count, bool) or dispatch_count <= 0:
        raise ValueError("output_oracle.dispatch_count must be a positive integer")
    matching_binding = next(
        (
            candidate
            for candidate in storage_bindings
            if candidate["group"] == binding_group
            and candidate["binding"] == binding
            and candidate["bufferBindingType"] == "storage"
        ),
        None,
    )
    if matching_binding is None:
        raise ValueError("output_oracle must reference a writable storage binding")
    expected_sha256 = require_string(
        oracle.get("expected_sha256"), "output_oracle.expected_sha256"
    ).lower()
    if re.fullmatch(r"[0-9a-f]{64}", expected_sha256) is None:
        raise ValueError("output_oracle.expected_sha256 must be lowercase SHA-256 hex")
    reference_id = require_string(
        oracle.get("reference_id"), "output_oracle.reference_id"
    )
    return {
        "schemaVersion": 1,
        "kind": kind,
        "initialization": initialization,
        "bindingGroup": binding_group,
        "binding": binding,
        "dispatchCount": dispatch_count,
        "expectedSha256": expected_sha256,
        "referenceId": reference_id,
    }


def compute_source_projection(
    workload: dict[str, Any],
    browser_workload: dict[str, Any],
    repo_root: Path,
) -> dict[str, Any] | None:
    if not source_strict_comparable(browser_workload):
        return None
    commands_rel = workload.get("commandsPath")
    if not isinstance(commands_rel, str) or not commands_rel.strip():
        return None
    commands_path = resolve_path(commands_rel, repo_root)
    if not commands_path.is_file():
        return None
    commands_payload = json.loads(commands_path.read_text(encoding="utf-8"))
    if not isinstance(commands_payload, list) or len(commands_payload) != 1:
        return None
    command = commands_payload[0]
    if not isinstance(command, dict) or command.get("kind") != "kernel_dispatch":
        return None
    kernel_name = command.get("kernel")
    if not isinstance(kernel_name, str) or not kernel_name.strip():
        return None
    kernel_path = resolve_kernel_path(kernel_name, repo_root)
    if kernel_path is None:
        return None

    bindings_raw = command.get("bindings")
    if not isinstance(bindings_raw, list) or not bindings_raw:
        return None
    storage_bindings: list[dict[str, Any]] = []
    for binding_raw in bindings_raw:
        if not isinstance(binding_raw, dict):
            return None
        if binding_raw.get("kind") != "buffer":
            return None
        buffer_size = binding_raw.get("buffer_size")
        group = binding_raw.get("group")
        binding = binding_raw.get("binding")
        if not isinstance(buffer_size, int) or buffer_size <= 0:
            return None
        if not isinstance(group, int) or group < 0:
            return None
        if not isinstance(binding, int) or binding < 0:
            return None
        buffer_binding_type = webgpu_buffer_binding_type(binding_raw.get("buffer_type"))
        if buffer_binding_type is None:
            return None
        storage_bindings.append(
            {
                "group": group,
                "binding": binding,
                "bufferSize": buffer_size,
                "minBindingSize": buffer_size,
                "bufferType": str(binding_raw.get("buffer_type", "storage")),
                "bufferBindingType": buffer_binding_type,
            }
        )

    if not any(binding["bufferBindingType"] == "storage" for binding in storage_bindings):
        return None

    output_oracle = source_output_oracle(command, storage_bindings)

    projection = {
        "computeProjection": (
            COMPUTE_PROJECTION_SOURCE_KERNEL_ORACLE
            if output_oracle is not None
            else COMPUTE_PROJECTION_SOURCE_KERNEL
        ),
        "bindGroupLayoutMode": SOURCE_KERNEL_BIND_GROUP_LAYOUT_MODE,
        "readbackBindingPolicy": SOURCE_KERNEL_READBACK_BINDING_POLICY,
        "commandsPath": display_path(commands_path, repo_root),
        "commandsSha256": file_sha256(commands_path),
        "kernelPath": display_path(kernel_path, repo_root),
        "kernelSha256": file_sha256(kernel_path),
        "dispatchX": int(command.get("x", 1)),
        "dispatchY": int(command.get("y", 1)),
        "dispatchZ": int(command.get("z", 1)),
        "dispatchRepeat": int(command.get("repeat", 1)),
        "warmupDispatchCount": int(command.get("warmup_dispatch_count", 1)),
        "storageBindings": storage_bindings,
    }
    if output_oracle is not None:
        projection["outputOracle"] = output_oracle
    return projection


def compute_indirect_component_projection(
    workload: dict[str, Any],
    repo_root: Path,
) -> dict[str, Any] | None:
    commands_rel = workload.get("commandsPath")
    if not isinstance(commands_rel, str) or not commands_rel.strip():
        return None
    commands_path = resolve_path(commands_rel, repo_root)
    if not commands_path.is_file():
        return None
    commands_payload = json.loads(commands_path.read_text(encoding="utf-8"))
    if not isinstance(commands_payload, list) or not commands_payload:
        return None

    indirect_args: list[dict[str, int]] = []
    for command in commands_payload:
        if not isinstance(command, dict) or command.get("kind") != "dispatch_indirect":
            return None
        x = command.get("x")
        y = command.get("y")
        z = command.get("z")
        if not isinstance(x, int) or x <= 0:
            return None
        if not isinstance(y, int) or y <= 0:
            return None
        if not isinstance(z, int) or z <= 0:
            return None
        indirect_args.append({"x": x, "y": y, "z": z})

    return {
        "computeProjection": COMPUTE_PROJECTION_INDIRECT_DISPATCH,
        "commandsPath": display_path(commands_path, repo_root),
        "commandsSha256": file_sha256(commands_path),
        "indirectDispatchArgs": indirect_args,
    }


def compute_direct_component_projection(
    workload: dict[str, Any],
    repo_root: Path,
) -> dict[str, Any] | None:
    commands_rel = workload.get("commandsPath")
    if not isinstance(commands_rel, str) or not commands_rel.strip():
        return None
    commands_path = resolve_path(commands_rel, repo_root)
    if not commands_path.is_file():
        return None
    commands_payload = json.loads(commands_path.read_text(encoding="utf-8"))
    if not isinstance(commands_payload, list) or not commands_payload:
        return None

    direct_args: list[dict[str, int]] = []
    for command in commands_payload:
        if (
            not isinstance(command, dict)
            or command.get("kind") not in DIRECT_DISPATCH_COMMAND_KINDS
        ):
            return None
        x = command.get("x")
        y = command.get("y")
        z = command.get("z")
        if not isinstance(x, int) or x <= 0:
            return None
        if not isinstance(y, int) or y <= 0:
            return None
        if not isinstance(z, int) or z <= 0:
            return None
        direct_args.append({"x": x, "y": y, "z": z})

    return {
        "computeProjection": COMPUTE_PROJECTION_DIRECT_DISPATCH,
        "commandsPath": display_path(commands_path, repo_root),
        "commandsSha256": file_sha256(commands_path),
        "directDispatchArgs": direct_args,
    }


def browser_workload_metadata(workload: dict[str, Any], domain: str) -> dict[str, Any]:
    metadata: dict[str, Any] = {
        "sourceComparable": bool(workload.get("comparable")),
        "sourceClaimEligible": bool(workload.get("claimEligible")),
    }
    benchmark_class = workload.get("benchmarkClass")
    if isinstance(benchmark_class, str) and benchmark_class.strip():
        metadata["benchmarkClass"] = benchmark_class
    elif metadata["sourceComparable"] and metadata["sourceClaimEligible"]:
        metadata["benchmarkClass"] = "comparable"
    else:
        metadata["benchmarkClass"] = "directional"

    if domain == "upload":
        search_text = " ".join(
            str(workload.get(key, ""))
            for key in ("id", "name", "description", "dawnFilter")
        )
        upload_bytes = parse_size_bytes(search_text)
        if upload_bytes is None:
            raise ValueError(f"upload workload missing parseable byte size: {workload.get('id')}")
        metadata["uploadBytes"] = upload_bytes
    elif domain == "compute":
        source_projection = compute_source_projection(workload, metadata, REPO_ROOT)
        if source_projection is not None:
            metadata.update(source_projection)
        else:
            indirect_projection = compute_indirect_component_projection(workload, REPO_ROOT)
            if indirect_projection is not None:
                metadata.update(indirect_projection)
            else:
                direct_projection = compute_direct_component_projection(workload, REPO_ROOT)
                if direct_projection is not None:
                    metadata.update(direct_projection)
                else:
                    metadata["computeProjection"] = COMPUTE_PROJECTION_EMPTY_DISPATCH
    elif domain == "render":
        metadata["renderOutputOracle"] = render_output_oracle()
    elif domain == "texture-contract":
        workload_id = str(workload.get("id", ""))
        metadata["textureWidth"] = 128
        metadata["textureHeight"] = 128
        metadata["mipLevelCount"] = 8 if workload_id.endswith("_mip8") else 1

    return metadata


def component_compute_rule() -> dict[str, str]:
    return {
        "projectionClass": "medium",
        "layerTarget": "l1_browser_api",
        "scenarioTemplate": "compute_dispatch_basic",
        "comparabilityExpectation": "component",
        "requiredStatus": "ok",
        "claimScope": "l1_component_only",
        "claimLanguage": (
            "Component-level browser compute dispatch diagnostic only; "
            "no source-shader parity claim language."
        ),
        "projectionNote": (
            "Browser compute projection currently measures generic empty dispatch overhead, "
            "not the source workload shader semantics."
        ),
    }


def component_indirect_compute_rule() -> dict[str, str]:
    return {
        "projectionClass": "medium",
        "layerTarget": "l1_browser_api",
        "scenarioTemplate": "compute_dispatch_indirect_basic",
        "comparabilityExpectation": "component",
        "requiredStatus": "ok",
        "claimScope": "l1_component_only",
        "claimLanguage": (
            "Component-level browser compute indirect-dispatch diagnostic only; "
            "no source-shader parity claim language."
        ),
        "projectionNote": (
            "Browser compute projection measures WebGPU dispatchWorkgroupsIndirect command shape "
            "from the source command contract, not source shader semantics."
        ),
    }


def component_direct_compute_rule() -> dict[str, str]:
    return {
        "projectionClass": "medium",
        "layerTarget": "l1_browser_api",
        "scenarioTemplate": "compute_dispatch_direct_basic",
        "comparabilityExpectation": "component",
        "requiredStatus": "ok",
        "claimScope": "l1_component_only",
        "claimLanguage": (
            "Component-level browser compute direct-dispatch diagnostic only; "
            "no source-shader parity claim language."
        ),
        "projectionNote": (
            "Browser compute projection measures WebGPU dispatchWorkgroups command shape "
            "from direct source command contracts, not source shader semantics."
        ),
    }


def component_source_diagnostic_rule(rule: dict[str, str]) -> dict[str, str]:
    return {
        **rule,
        "comparabilityExpectation": "component",
        "claimScope": "l1_component_only",
        "claimLanguage": "Component-level browser API diagnostic only; source workload is not strict-claim eligible.",
        "projectionNote": (
            f"{rule['projectionNote']} Source workload metadata prevents strict "
            "browser comparison; keep this row as a directional/component diagnostic."
        ),
    }


def non_projectable_browser_upload_rule(upload_bytes: int) -> dict[str, str]:
    return {
        "projectionClass": "non_projectable",
        "layerTarget": "l0_only",
        "scenarioTemplate": "none",
        "comparabilityExpectation": "none",
        "requiredStatus": "not_applicable",
        "claimScope": "l0_only_no_claim",
        "claimLanguage": "Oversized upload row remains an L0 runtime contract; no browser-layer claim language is allowed.",
        "projectionNote": (
            "Exact browser upload projection is disabled because uploadBytes="
            f"{upload_bytes} exceeds maxBrowserExactUploadBytes={MAX_BROWSER_EXACT_UPLOAD_BYTES}."
        ),
    }


def build_manifest(
    workloads_payload: dict[str, Any],
    rules_payload: dict[str, Any],
    workloads_path: str,
    rules_path: str,
    workloads_sha256: str,
    rules_sha256: str,
    generated_at: str,
) -> dict[str, Any]:
    workloads_raw = workloads_payload.get("workloads")
    if not isinstance(workloads_raw, list) or not workloads_raw:
        raise ValueError("invalid workloads payload: missing non-empty workloads[]")

    default_rule_raw = rules_payload.get("defaultRule")
    if not isinstance(default_rule_raw, dict):
        raise ValueError("invalid rules payload: missing defaultRule object")
    default_rule = require_rule_shape(default_rule_raw, "defaultRule")

    domain_rules_raw = rules_payload.get("domainRules")
    if not isinstance(domain_rules_raw, dict):
        raise ValueError("invalid rules payload: missing domainRules object")

    domain_rules: dict[str, dict[str, str]] = {}
    for domain, value in domain_rules_raw.items():
        if not isinstance(domain, str) or not domain.strip():
            raise ValueError(f"invalid domain rule key: {domain}")
        if not isinstance(value, dict):
            raise ValueError(f"invalid domain rule object: {domain}")
        domain_rules[domain] = require_rule_shape(value, f"domainRules.{domain}")

    seen_ids: set[str] = set()
    rows: list[dict[str, Any]] = []

    for index, workload_raw in enumerate(workloads_raw):
        if not isinstance(workload_raw, dict):
            raise ValueError(f"invalid workload object at index {index}")
        workload_id = require_string(workload_raw.get("id"), f"workloads[{index}].id")
        workload_name = require_string(workload_raw.get("name"), f"workloads[{index}].name")
        domain = require_string(workload_raw.get("domain"), f"workloads[{index}].domain")

        if workload_id in seen_ids:
            raise ValueError(f"duplicate workload id: {workload_id}")
        seen_ids.add(workload_id)

        rule = domain_rules.get(domain, default_rule)
        browser_workload = browser_workload_metadata(workload_raw, domain)
        if (
            domain == "upload"
            and browser_workload.get("uploadBytes", 0) > MAX_BROWSER_EXACT_UPLOAD_BYTES
        ):
            rule = non_projectable_browser_upload_rule(int(browser_workload["uploadBytes"]))
        elif (
            domain == "compute"
            and browser_workload.get("computeProjection") == COMPUTE_PROJECTION_INDIRECT_DISPATCH
        ):
            rule = component_indirect_compute_rule()
        elif (
            domain == "compute"
            and browser_workload.get("computeProjection") == COMPUTE_PROJECTION_DIRECT_DISPATCH
        ):
            rule = component_direct_compute_rule()
        elif (
            domain == "compute"
            and browser_workload.get("computeProjection") not in {
                COMPUTE_PROJECTION_SOURCE_KERNEL,
                COMPUTE_PROJECTION_SOURCE_KERNEL_ORACLE,
            }
        ):
            rule = component_compute_rule()
        elif (
            rule["comparabilityExpectation"] == "strict"
            and not source_strict_comparable(browser_workload)
        ):
            rule = component_source_diagnostic_rule(rule)
        if rule["comparabilityExpectation"] != "strict":
            browser_workload["benchmarkClass"] = "directional"

        row = {
            "sourceWorkloadId": workload_id,
            "sourceWorkloadName": workload_name,
            "domain": domain,
            "projectionClass": rule["projectionClass"],
            "layerTarget": rule["layerTarget"],
            "scenarioTemplate": rule["scenarioTemplate"],
            "comparabilityExpectation": rule["comparabilityExpectation"],
            "requiredStatus": rule["requiredStatus"],
            "claimScope": rule["claimScope"],
            "claimLanguage": rule["claimLanguage"],
            "projectionNote": rule["projectionNote"],
            "browserWorkload": browser_workload,
        }
        rows.append(row)

    projection_contract_hash = payload_sha256(
        {
            "sourceWorkloadsSha256": workloads_sha256,
            "rulesSha256": rules_sha256,
            "rows": rows,
        }
    )

    return {
        "schemaVersion": PROJECTION_MANIFEST_SCHEMA_VERSION,
        "generatedAt": generated_at,
        "sourceWorkloadsPath": workloads_path,
        "sourceWorkloadsSha256": workloads_sha256,
        "rulesPath": rules_path,
        "rulesSha256": rules_sha256,
        "projectionContractHash": projection_contract_hash,
        "sourceWorkloadCount": len(rows),
        "rows": rows,
    }


def generated_at_now() -> str:
    return datetime.now(UTC).isoformat().replace("+00:00", "Z")


def existing_generated_at(out_path: Path) -> str | None:
    if not out_path.is_file():
        return None
    payload = load_json(out_path)
    value = payload.get("generatedAt")
    if not isinstance(value, str) or not value.strip():
        raise ValueError(f"existing manifest has invalid generatedAt: {out_path}")
    return value


def render_manifest(manifest: dict[str, Any]) -> str:
    return f"{json.dumps(manifest, indent=2)}\n"


def summarize(manifest: dict[str, Any]) -> str:
    rows = manifest["rows"]
    by_class: dict[str, int] = {"high": 0, "medium": 0, "non_projectable": 0}
    by_target: dict[str, int] = {"l1_browser_api": 0, "l0_only": 0}
    for row in rows:
        by_class[row["projectionClass"]] = by_class.get(row["projectionClass"], 0) + 1
        by_target[row["layerTarget"]] = by_target.get(row["layerTarget"], 0) + 1
    return (
        f"rows={len(rows)} "
        f"high={by_class['high']} medium={by_class['medium']} "
        f"non_projectable={by_class['non_projectable']} "
        f"l1={by_target['l1_browser_api']} l0_only={by_target['l0_only']}"
    )


def main() -> int:
    args = parse_args()
    repo_root = Path(__file__).resolve().parents[3]
    workloads_path = resolve_path(args.workloads, repo_root)
    rules_path = resolve_path(args.rules, repo_root)
    out_path = resolve_path(args.out, repo_root)

    workloads_payload = load_json(workloads_path)
    rules_payload = load_json(rules_path)
    workloads_sha256 = file_sha256(workloads_path)
    rules_sha256 = file_sha256(rules_path)

    prior_generated_at = existing_generated_at(out_path)
    manifest = build_manifest(
        workloads_payload,
        rules_payload,
        display_path(workloads_path, repo_root),
        display_path(rules_path, repo_root),
        workloads_sha256,
        rules_sha256,
        prior_generated_at or generated_at_now(),
    )
    summary = summarize(manifest)

    if args.check_only:
        print(f"[projection-manifest] check-only ok: {summary}")
        return 0


    rendered = render_manifest(manifest)
    if args.verify:
        if not out_path.is_file():
            print(f"[projection-manifest] verify failed: output missing: {out_path}")
            return 1
        if out_path.read_text(encoding="utf-8") != rendered:
            print(f"[projection-manifest] verify failed: output is stale: {out_path}")
            return 1
        print(f"[projection-manifest] verify ok: {summary}")
        return 0

    out_path.parent.mkdir(parents=True, exist_ok=True)
    if out_path.is_file() and out_path.read_text(encoding="utf-8") == rendered:
        print(f"[projection-manifest] unchanged {out_path}")
    else:
        manifest["generatedAt"] = generated_at_now()
        out_path.write_text(render_manifest(manifest), encoding="utf-8")
        print(f"[projection-manifest] wrote {out_path}")
    print(f"[projection-manifest] {summary}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
