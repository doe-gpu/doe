#!/usr/bin/env python3
"""Check whether Chromium source-dependent seam work can run."""

from __future__ import annotations

import argparse
import json
import os
import shutil
import sys
from pathlib import Path, PurePosixPath
from typing import Any


REPO_ROOT = Path(__file__).resolve().parents[2]
SelectorNeedle = str | tuple[str, ...]
REQUIRED_MARKERS = (
    ".gn",
    "DEPS",
    "build",
    "gpu",
    "third_party/blink/renderer/modules/webgpu",
)
REQUIRED_TOOLS = ("gclient", "gn", "autoninja")
OPTIONAL_TOOLS = ("fetch",)
WEBGPU_DECODER_PATH = "gpu/command_buffer/service/webgpu_decoder_impl.cc"
GPU_PROCESS_HOST_PATH = "content/browser/gpu/gpu_process_host.cc"
DAWN_WEBGPU_BACKEND_PATH = (
    "third_party/dawn/src/dawn/native/webgpu/BackendWGPU.cpp"
)
DAWN_WEBGPU_SHARED_TEXTURE_MEMORY_PATH = (
    "third_party/dawn/src/dawn/native/webgpu/SharedTextureMemoryWGPU.cpp"
)
DAWN_WEBGPU_TEXTURE_PATH = (
    "third_party/dawn/src/dawn/native/webgpu/TextureWGPU.cpp"
)
IOSURFACE_IMAGE_BACKING_PATH = (
    "gpu/command_buffer/service/shared_image/iosurface_image_backing.mm"
)
RUNTIME_SELECTOR_MARKERS = (
    (
        "selector:gpu_process_switch_propagation",
        (
            "switches::kUseWebGPURuntime",
            "switches::kDisableWebGPUDoe",
            "switches::kDoeWebGPULibraryPath",
        ),
        (GPU_PROCESS_HOST_PATH,),
    ),
    (
        "selector:runtime_switch",
        "use-webgpu-runtime",
        (
            "gpu/config/gpu_switches.cc",
            "gpu/config/gpu_switches.h",
            "gpu/command_buffer/service/service_utils.cc",
            "gpu/command_buffer/service/webgpu_decoder_impl.cc",
        ),
    ),
    (
        "selector:doe_disable_switch",
        "disable-webgpu-doe",
        (
            "gpu/config/gpu_switches.cc",
            "gpu/config/gpu_switches.h",
            "gpu/command_buffer/service/service_utils.cc",
            "gpu/command_buffer/service/webgpu_decoder_impl.cc",
        ),
    ),
    (
        "selector:doe_library_switch",
        "doe-webgpu-library-path",
        (
            "gpu/config/gpu_switches.cc",
            "gpu/config/gpu_switches.h",
            "gpu/command_buffer/service/service_utils.cc",
            "gpu/command_buffer/service/webgpu_decoder_impl.cc",
        ),
    ),
    (
        "selector:load_failure_reason",
        "runtime_artifact_load_failed",
        (
            WEBGPU_DECODER_PATH,
            DAWN_WEBGPU_BACKEND_PATH,
        ),
    ),
    (
        "selector:initialization_failure_reason",
        "runtime_initialization_failed",
        (
            WEBGPU_DECODER_PATH,
            DAWN_WEBGPU_BACKEND_PATH,
        ),
    ),
    (
        "selector:symbol_failure_reason",
        "symbol_surface_incomplete",
        (
            WEBGPU_DECODER_PATH,
            DAWN_WEBGPU_BACKEND_PATH,
        ),
    ),
    (
        "selector:wire_proc_table_failure_reason",
        "wire_proc_table_incomplete",
        (
            WEBGPU_DECODER_PATH,
            DAWN_WEBGPU_BACKEND_PATH,
        ),
    ),
    (
        "selector:wire_proc_table_loader",
        "LoadDoeWireProcTable",
        (
            WEBGPU_DECODER_PATH,
            DAWN_WEBGPU_BACKEND_PATH,
            "third_party/dawn/src/dawn/native/webgpu/BackendWGPU.h",
        ),
    ),
    (
        "selector:doe_wire_runtime_instance",
        (
            "LoadDoeWireProcTable",
            "createInstance",
        ),
        (WEBGPU_DECODER_PATH, DAWN_WEBGPU_BACKEND_PATH),
    ),
    (
        "selector:doe_wire_runtime_lifecycle_test",
        (
            "instanceRelease",
            "= nullptr",
        ),
        (WEBGPU_DECODER_PATH, DAWN_WEBGPU_BACKEND_PATH),
    ),
    (
        "selector:doe_shared_image_iosurface_bridge",
        (
            "AssociateMailboxDoeSharedImage(",
            "ProduceIOSurfaceForWebGPU(mailbox)",
            "BeginScopedAccess(usage, internal_usage)",
        ),
        (WEBGPU_DECODER_PATH,),
    ),
    (
        "selector:doe_wire_device_handle_ownership",
        (
            "Keep a Doe device raw until after runtime selection.",
            "AssociateMailboxDoeSharedImage(mailbox, flags, device_handle",
            "wgpu::Device device = device_handle;",
        ),
        (WEBGPU_DECODER_PATH,),
    ),
    (
        "selector:doe_shared_image_iosurface_representation",
        (
            "class DoeSharedImageRepresentationAndAccess",
            "WGPUSharedTextureMemoryIOSurfaceDescriptor",
            "sharedTextureMemoryBeginAccess",
            "sharedTextureMemoryEndAccess",
        ),
        (WEBGPU_DECODER_PATH,),
    ),
    (
        "selector:doe_shared_image_metal_fence_bridge",
        (
            "WGPUSharedFenceMTLSharedEventDescriptor",
            "deviceImportSharedFence",
            "sharedFenceExportInfo",
            "MTLSharedEventFence::CreateFromHandle",
        ),
        (WEBGPU_DECODER_PATH,),
    ),
    (
        "selector:doe_shared_image_iosurface_fence_propagation",
        (
            "ProcessSharedEventsForBeginAccess",
            "AddSharedEventForEndAccess",
        ),
        (IOSURFACE_IMAGE_BACKING_PATH,),
    ),
    (
        "selector:doe_shared_image_native_import",
        "deviceImportSharedTextureMemory",
        (
            WEBGPU_DECODER_PATH,
            DAWN_WEBGPU_BACKEND_PATH,
            DAWN_WEBGPU_SHARED_TEXTURE_MEMORY_PATH,
        ),
    ),
    (
        "selector:doe_shared_image_native_begin_access",
        "sharedTextureMemoryBeginAccess",
        (
            WEBGPU_DECODER_PATH,
            DAWN_WEBGPU_BACKEND_PATH,
            DAWN_WEBGPU_TEXTURE_PATH,
        ),
    ),
    (
        "selector:doe_shared_image_native_end_access",
        "sharedTextureMemoryEndAccess",
        (
            WEBGPU_DECODER_PATH,
            DAWN_WEBGPU_BACKEND_PATH,
            DAWN_WEBGPU_SHARED_TEXTURE_MEMORY_PATH,
        ),
    ),
    (
        "selector:doe_shared_image_iosurface_handle",
        (
            "io_surface_desc.ioSurface = io_surface_.get();",
            "ImportSharedTextureMemory",
        ),
        (WEBGPU_DECODER_PATH, IOSURFACE_IMAGE_BACKING_PATH),
    ),
    (
        "selector:doe_shared_buffer_unsupported",
        "doe_shared_buffer_unsupported",
        ("gpu/command_buffer/service/webgpu_decoder_impl.cc",),
    ),
    (
        "selector:doe_shared_buffer_fails_closed",
        "<< kDoeSharedBufferUnsupported;\n    return error::kInvalidArguments;",
        ("gpu/command_buffer/service/webgpu_decoder_impl.cc",),
    ),
    (
        "selector:doe_present_shared_texture_end_access",
        (
            "EndAccessForPresent()",
            "associated_shared_image_map_.erase(it);",
        ),
        ("gpu/command_buffer/service/webgpu_decoder_impl.cc",),
    ),
    (
        "selector:render_proc_surface",
        "wgpuCommandEncoderBeginRenderPass",
        (
            WEBGPU_DECODER_PATH,
            DAWN_WEBGPU_BACKEND_PATH,
        ),
    ),
    (
        "selector:external_texture_proc_surface",
        "wgpuQueueCopyExternalTextureForBrowser",
        (
            WEBGPU_DECODER_PATH,
            DAWN_WEBGPU_BACKEND_PATH,
        ),
    ),
    (
        "selector:profile_denylisted_reason",
        "profile_denylisted",
        ("gpu/command_buffer/service/webgpu_decoder_impl.cc",),
    ),
    (
        "selector:adapter_denylist_detail",
        "adapter_denylist_detail",
        ("gpu/command_buffer/service/webgpu_decoder_impl.cc",),
    ),
    (
        "selector:adapter_denylist_vendor_id",
        "vendor_id",
        ("gpu/command_buffer/service/webgpu_decoder_impl.cc",),
    ),
    (
        "selector:adapter_denylist_blocklist_reason",
        "blocklist_reason",
        ("gpu/command_buffer/service/webgpu_decoder_impl.cc",),
    ),
    (
        "selector:adapter_denylist_source_fields_test",
        "DoeAdapterDenylistDetailCarriesSourceFields",
        ("gpu/command_buffer/service/webgpu_decoder_unittest.cc",),
    ),
    (
        "selector:unknown_selection_reason",
        "unknown_selection_error",
        ("gpu/command_buffer/service/webgpu_decoder_impl.cc",),
    ),
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--source-root",
        default="browser/chromium/src",
        help="Chromium source checkout root, repo-relative or absolute.",
    )
    parser.add_argument(
        "--root",
        default=str(REPO_ROOT),
        help="Repository root used to resolve repo-relative source roots.",
    )
    parser.add_argument(
        "--require-ready",
        action="store_true",
        help="Exit non-zero when required checkout/tool checks are missing.",
    )
    parser.add_argument(
        "--require-runtime-selector",
        action="store_true",
        help="Require Chromium source markers for the fail-closed Doe runtime selector seam.",
    )
    parser.add_argument("--json", action="store_true", dest="emit_json")
    return parser.parse_args()


def failure_check(
    check_id: str,
    message: str,
    *,
    required: bool = True,
    path: str | None = None,
    command: str | None = None,
    resolved_path: str | None = None,
) -> dict[str, Any]:
    return check_row(
        check_id,
        "fail",
        message,
        required=required,
        path=path,
        command=command,
        resolved_path=resolved_path,
    )


def pass_check(
    check_id: str,
    message: str,
    *,
    required: bool = True,
    path: str | None = None,
    command: str | None = None,
    resolved_path: str | None = None,
) -> dict[str, Any]:
    return check_row(
        check_id,
        "pass",
        message,
        required=required,
        path=path,
        command=command,
        resolved_path=resolved_path,
    )


def check_row(
    check_id: str,
    status: str,
    message: str,
    *,
    required: bool,
    path: str | None = None,
    command: str | None = None,
    resolved_path: str | None = None,
) -> dict[str, Any]:
    row: dict[str, Any] = {
        "checkId": check_id,
        "status": status,
        "required": required,
        "message": message,
    }
    if path is not None:
        row["path"] = path
    if command is not None:
        row["command"] = command
    if resolved_path is not None:
        row["resolvedPath"] = resolved_path
    return row


def safe_repo_path(path_text: str) -> bool:
    path = PurePosixPath(path_text)
    return bool(path_text) and not path.is_absolute() and ".." not in path.parts


def resolve_source_root(root: Path, source_root: str) -> Path | None:
    raw = Path(source_root)
    if raw.is_absolute():
        return raw
    if not safe_repo_path(source_root):
        return None
    return root.joinpath(*PurePosixPath(source_root).parts)


def tool_check(command: str, *, required: bool, path_env: str | None = None) -> dict[str, Any]:
    found = shutil.which(command, path=path_env)
    if found:
        return pass_check(
            f"tool:{command}",
            "Chromium tool found on PATH",
            required=required,
            command=command,
            resolved_path=found,
        )
    return failure_check(
        f"tool:{command}",
        "required Chromium tool is missing from PATH" if required else "optional Chromium bootstrap tool is missing from PATH",
        required=required,
        command=command,
    )


def file_contains(path: Path, needle: SelectorNeedle) -> bool:
    try:
        text = path.read_text(encoding="utf-8", errors="ignore")
    except OSError:
        return False
    if isinstance(needle, str):
        return needle in text
    return all(required in text for required in needle)


def describe_needle(needle: SelectorNeedle) -> str:
    if isinstance(needle, str):
        return needle
    return " + ".join(needle)


def selector_marker_check(
    source_root: Path,
    check_id: str,
    needle: SelectorNeedle,
    candidate_paths: tuple[str, ...],
) -> dict[str, Any]:
    for candidate in candidate_paths:
        path = source_root.joinpath(*PurePosixPath(candidate).parts)
        if file_contains(path, needle):
            return pass_check(
                check_id,
                "Chromium runtime selector source marker exists",
                path=str(PurePosixPath(candidate)),
                resolved_path=str(path),
            )
    return failure_check(
        check_id,
        "Chromium runtime selector source marker is missing: "
        f"{describe_needle(needle)}",
        path=", ".join(candidate_paths),
        resolved_path=str(source_root),
    )


def check_checkout(
    *,
    root: Path,
    source_root_text: str,
    require_ready: bool,
    require_runtime_selector: bool = False,
    path_env: str | None = None,
) -> dict[str, Any]:
    checks: list[dict[str, Any]] = []
    source_root = resolve_source_root(root, source_root_text)
    if source_root is None:
        checks.append(
            failure_check(
                "source_root",
                "Chromium source root must be repo-relative or absolute without parent traversal",
                path=source_root_text,
            )
        )
    elif source_root.is_dir():
        checks.append(
            pass_check(
                "source_root",
                "Chromium source root exists",
                path=source_root_text,
                resolved_path=str(source_root),
            )
        )
        for marker in REQUIRED_MARKERS:
            marker_path = source_root / marker
            if marker_path.exists():
                checks.append(
                    pass_check(
                        f"marker:{marker}",
                        "Chromium source marker exists",
                        path=f"{source_root_text.rstrip('/')}/{marker}",
                        resolved_path=str(marker_path),
                    )
                )
            else:
                checks.append(
                    failure_check(
                        f"marker:{marker}",
                        "Chromium source marker is missing",
                        path=f"{source_root_text.rstrip('/')}/{marker}",
                        resolved_path=str(marker_path),
                    )
                )
        if require_runtime_selector:
            for check_id, needle, candidate_paths in RUNTIME_SELECTOR_MARKERS:
                checks.append(
                    selector_marker_check(
                        source_root,
                        check_id,
                        needle,
                        candidate_paths,
                    )
                )
    else:
        checks.append(
            failure_check(
                "source_root",
                "Chromium source root is missing",
                path=source_root_text,
                resolved_path=str(source_root),
            )
        )

    for command in REQUIRED_TOOLS:
        checks.append(tool_check(command, required=True, path_env=path_env))
    for command in OPTIONAL_TOOLS:
        checks.append(tool_check(command, required=False, path_env=path_env))

    missing_required = [
        row["checkId"]
        for row in checks
        if row.get("required") is True and row.get("status") != "pass"
    ]
    return {
        "schemaVersion": 1,
        "artifactKind": "chromium_source_checkout_check",
        "sourceRoot": source_root_text,
        "requireReady": require_ready,
        "requireRuntimeSelector": require_runtime_selector,
        "status": "blocked" if missing_required else "pass",
        "checks": checks,
        "missingRequired": missing_required,
    }


def main() -> int:
    args = parse_args()
    report = check_checkout(
        root=Path(args.root).resolve(),
        source_root_text=args.source_root,
        require_ready=args.require_ready,
        require_runtime_selector=args.require_runtime_selector,
        path_env=os.environ.get("PATH"),
    )
    if args.emit_json:
        print(json.dumps(report, indent=2))
    elif report["status"] == "pass":
        print("PASS: Chromium source checkout is ready")
    else:
        print("BLOCKED: Chromium source checkout is not ready")
        for check_id in report["missingRequired"]:
            print(f"- {check_id}")
    return 1 if args.require_ready and report["status"] != "pass" else 0


if __name__ == "__main__":
    sys.exit(main())
