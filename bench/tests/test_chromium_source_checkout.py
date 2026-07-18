#!/usr/bin/env python3
"""Tests for Chromium source checkout readiness checks."""

from __future__ import annotations

from pathlib import Path
from typing import Any

from bench.tools import check_chromium_source_checkout as checkout


def _write_tool(bin_dir: Path, name: str) -> None:
    path = bin_dir / name
    path.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
    path.chmod(0o755)


def _check_by_id(
    report: dict[str, Any],
    check_id: str,
) -> dict[str, Any]:
    return next(
        row for row in report["checks"] if row["checkId"] == check_id
    )


def test_chromium_source_checkout_reports_missing_source_and_tools(tmp_path: Path) -> None:
    report = checkout.check_checkout(
        root=tmp_path,
        source_root_text="browser/chromium/src",
        require_ready=False,
        require_runtime_selector=False,
        path_env=str(tmp_path / "empty-bin"),
    )

    assert report["status"] == "blocked"
    assert "source_root" in report["missingRequired"]
    assert "tool:gclient" in report["missingRequired"]
    assert report["requireReady"] is False
    assert report["requireRuntimeSelector"] is False


def test_chromium_source_checkout_passes_with_markers_and_tools(tmp_path: Path) -> None:
    source_root = tmp_path / "browser" / "chromium" / "src"
    for marker in checkout.REQUIRED_MARKERS:
        marker_path = source_root / marker
        if "." in Path(marker).name:
            marker_path.parent.mkdir(parents=True, exist_ok=True)
            marker_path.write_text("", encoding="utf-8")
        else:
            marker_path.mkdir(parents=True, exist_ok=True)

    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    for command in checkout.REQUIRED_TOOLS:
        _write_tool(bin_dir, command)

    report = checkout.check_checkout(
        root=tmp_path,
        source_root_text="browser/chromium/src",
        require_ready=True,
        require_runtime_selector=False,
        path_env=str(bin_dir),
    )

    assert report["status"] == "pass"
    assert report["missingRequired"] == []
    assert report["requireReady"] is True


def test_chromium_source_checkout_rejects_parent_traversal(tmp_path: Path) -> None:
    report = checkout.check_checkout(
        root=tmp_path,
        source_root_text="../src",
        require_ready=True,
        require_runtime_selector=False,
        path_env="",
    )

    assert report["status"] == "blocked"
    assert report["checks"][0]["checkId"] == "source_root"
    assert report["checks"][0]["message"] == "Chromium source root must be repo-relative or absolute without parent traversal"


def test_chromium_source_checkout_can_require_runtime_selector_markers(tmp_path: Path) -> None:
    source_root = tmp_path / "browser" / "chromium" / "src"
    for marker in checkout.REQUIRED_MARKERS:
        marker_path = source_root / marker
        if "." in Path(marker).name:
            marker_path.parent.mkdir(parents=True, exist_ok=True)
            marker_path.write_text("", encoding="utf-8")
        else:
            marker_path.mkdir(parents=True, exist_ok=True)

    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    for command in checkout.REQUIRED_TOOLS:
        _write_tool(bin_dir, command)

    report = checkout.check_checkout(
        root=tmp_path,
        source_root_text="browser/chromium/src",
        require_ready=True,
        require_runtime_selector=True,
        path_env=str(bin_dir),
    )

    assert report["status"] == "blocked"
    assert report["requireRuntimeSelector"] is True
    assert "selector:runtime_switch" in report["missingRequired"]
    assert "selector:initialization_failure_reason" in report["missingRequired"]
    assert "selector:symbol_failure_reason" in report["missingRequired"]
    assert "selector:wire_proc_table_failure_reason" in report["missingRequired"]
    assert "selector:wire_proc_table_loader" in report["missingRequired"]
    assert "selector:doe_wire_runtime_instance" in report["missingRequired"]
    assert "selector:doe_wire_runtime_lifecycle_test" in report["missingRequired"]
    assert "selector:doe_shared_image_iosurface_bridge" in report["missingRequired"]
    assert "selector:doe_wire_device_handle_ownership" in report["missingRequired"]
    assert "selector:doe_shared_image_iosurface_representation" in report["missingRequired"]
    assert "selector:doe_shared_image_metal_fence_bridge" in report["missingRequired"]
    assert "selector:doe_shared_image_iosurface_fence_propagation" in report["missingRequired"]
    assert "selector:doe_shared_image_native_import" in report["missingRequired"]
    assert "selector:doe_shared_image_native_begin_access" in report["missingRequired"]
    assert "selector:doe_shared_image_native_end_access" in report["missingRequired"]
    assert "selector:doe_shared_image_iosurface_handle" in report["missingRequired"]
    assert "selector:doe_shared_buffer_unsupported" in report["missingRequired"]
    assert "selector:doe_shared_buffer_fails_closed" in report["missingRequired"]
    assert "selector:doe_present_shared_texture_end_access" in report["missingRequired"]
    assert "selector:render_proc_surface" in report["missingRequired"]
    assert "selector:external_texture_proc_surface" in report["missingRequired"]
    assert "selector:adapter_denylist_detail" in report["missingRequired"]
    assert "selector:adapter_denylist_vendor_id" in report["missingRequired"]
    assert "selector:adapter_denylist_blocklist_reason" in report["missingRequired"]
    assert "selector:adapter_denylist_source_fields_test" in report["missingRequired"]


def test_chromium_source_checkout_accepts_dawn_backend_runtime_markers(tmp_path: Path) -> None:
    source_root = tmp_path / "browser" / "chromium" / "src"
    for marker in checkout.REQUIRED_MARKERS:
        marker_path = source_root / marker
        if "." in Path(marker).name:
            marker_path.parent.mkdir(parents=True, exist_ok=True)
            marker_path.write_text("", encoding="utf-8")
        else:
            marker_path.mkdir(parents=True, exist_ok=True)
    backend = (
        source_root
        / "third_party"
        / "dawn"
        / "src"
        / "dawn"
        / "native"
        / "webgpu"
        / "BackendWGPU.cpp"
    )
    backend.parent.mkdir(parents=True, exist_ok=True)
    backend.write_text(
        "\n".join(
            [
                "runtime_artifact_load_failed",
                "runtime_initialization_failed",
                "symbol_surface_incomplete",
                "wire_proc_table_incomplete",
                "LoadDoeWireProcTable",
                "mExternalRuntimeLib.Open",
                "mInnerInstance = mDawnProcs.createInstance(&instanceDesc);",
                'load_proc(&mDawnProcs.instanceRelease, "wgpuInstanceRelease")',
                "Backend::~Backend()",
                "mDawnProcs.instanceRelease(mInnerInstance);",
                "mInnerInstance = nullptr;",
                "deviceImportSharedTextureMemory",
                "sharedTextureMemoryBeginAccess",
                "sharedTextureMemoryEndAccess",
                "wgpuCommandEncoderBeginRenderPass",
                "wgpuQueueCopyExternalTextureForBrowser",
            ]
        ),
        encoding="utf-8",
    )

    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    for command in checkout.REQUIRED_TOOLS:
        _write_tool(bin_dir, command)

    report = checkout.check_checkout(
        root=tmp_path,
        source_root_text="browser/chromium/src",
        require_ready=True,
        require_runtime_selector=True,
        path_env=str(bin_dir),
    )

    assert report["status"] == "blocked"
    assert "selector:runtime_switch" in report["missingRequired"]
    assert "selector:load_failure_reason" not in report["missingRequired"]
    assert "selector:initialization_failure_reason" not in report["missingRequired"]
    assert "selector:symbol_failure_reason" not in report["missingRequired"]
    assert "selector:wire_proc_table_failure_reason" not in report["missingRequired"]
    assert "selector:wire_proc_table_loader" not in report["missingRequired"]
    assert "selector:doe_wire_runtime_instance" not in report["missingRequired"]
    assert (
        "selector:doe_wire_runtime_lifecycle_test"
        not in report["missingRequired"]
    )
    assert "selector:doe_shared_image_native_import" not in report["missingRequired"]
    assert "selector:doe_shared_image_native_begin_access" not in report["missingRequired"]
    assert "selector:doe_shared_image_native_end_access" not in report["missingRequired"]
    assert "selector:render_proc_surface" not in report["missingRequired"]
    assert "selector:external_texture_proc_surface" not in report["missingRequired"]
    for check_id in (
        "selector:load_failure_reason",
        "selector:initialization_failure_reason",
        "selector:symbol_failure_reason",
        "selector:wire_proc_table_failure_reason",
        "selector:wire_proc_table_loader",
        "selector:doe_wire_runtime_instance",
        "selector:doe_wire_runtime_lifecycle_test",
        "selector:doe_shared_image_native_import",
        "selector:doe_shared_image_native_begin_access",
        "selector:doe_shared_image_native_end_access",
        "selector:render_proc_surface",
        "selector:external_texture_proc_surface",
    ):
        row = _check_by_id(report, check_id)
        assert row["status"] == "pass"
        assert row["path"].endswith("BackendWGPU.cpp")


def test_chromium_source_checkout_rejects_partial_dawn_lifecycle_markers(
    tmp_path: Path,
) -> None:
    source_root = tmp_path / "browser" / "chromium" / "src"
    for marker in checkout.REQUIRED_MARKERS:
        marker_path = source_root / marker
        if "." in Path(marker).name:
            marker_path.parent.mkdir(parents=True, exist_ok=True)
            marker_path.write_text("", encoding="utf-8")
        else:
            marker_path.mkdir(parents=True, exist_ok=True)
    backend = (
        source_root
        / "third_party"
        / "dawn"
        / "src"
        / "dawn"
        / "native"
        / "webgpu"
        / "BackendWGPU.cpp"
    )
    backend.parent.mkdir(parents=True, exist_ok=True)
    backend.write_text(
        "\n".join(
            [
                "LoadDoeWireProcTable",
                "mInnerInstance = mDawnProcs.createInstance(&instanceDesc);",
                "Backend::~Backend()",
                "mInnerInstance = nullptr;",
            ]
        ),
        encoding="utf-8",
    )

    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    for command in checkout.REQUIRED_TOOLS:
        _write_tool(bin_dir, command)

    report = checkout.check_checkout(
        root=tmp_path,
        source_root_text="browser/chromium/src",
        require_ready=True,
        require_runtime_selector=True,
        path_env=str(bin_dir),
    )

    assert report["status"] == "blocked"
    assert "selector:doe_wire_runtime_instance" not in report["missingRequired"]
    assert "selector:doe_wire_runtime_lifecycle_test" in report["missingRequired"]


def test_chromium_source_checkout_passes_with_runtime_selector_markers(tmp_path: Path) -> None:
    source_root = tmp_path / "browser" / "chromium" / "src"
    for marker in checkout.REQUIRED_MARKERS:
        marker_path = source_root / marker
        if "." in Path(marker).name:
            marker_path.parent.mkdir(parents=True, exist_ok=True)
            marker_path.write_text("", encoding="utf-8")
        else:
            marker_path.mkdir(parents=True, exist_ok=True)
    decoder = source_root / "gpu" / "command_buffer" / "service" / "webgpu_decoder_impl.cc"
    decoder.parent.mkdir(parents=True, exist_ok=True)
    decoder.write_text(
        "\n".join(
            [
                "use-webgpu-runtime",
                "disable-webgpu-doe",
                "doe-webgpu-library-path",
                "runtime_artifact_load_failed",
                "runtime_initialization_failed",
                "symbol_surface_incomplete",
                "wire_proc_table_incomplete",
                "LoadDoeWireProcTable",
                "doe_wire_procs.createInstance(nullptr)",
                "runtime->procs.instanceRelease(runtime->instance)",
                "runtime->instance = nullptr",
                "AssociateMailboxDoeSharedImage(",
                "ProduceIOSurfaceForWebGPU(mailbox)",
                "BeginScopedAccess(usage, internal_usage)",
                "Keep a Doe device raw until after runtime selection.",
                "AssociateMailboxDoeSharedImage(mailbox, flags, device_handle",
                "wgpu::Device device = device_handle;",
                "class DoeSharedImageRepresentationAndAccess",
                "WGPUSharedTextureMemoryIOSurfaceDescriptor",
                "deviceImportSharedTextureMemory",
                "sharedTextureMemoryBeginAccess",
                "sharedTextureMemoryEndAccess",
                "WGPUSharedFenceMTLSharedEventDescriptor",
                "deviceImportSharedFence",
                "sharedFenceExportInfo",
                "MTLSharedEventFence::CreateFromHandle",
                "io_surface_desc.ioSurface = io_surface_.get();",
                "doe_shared_buffer_unsupported",
                "<< kDoeSharedBufferUnsupported;\n    return error::kInvalidArguments;",
                "bool EndAccessForPresent() override",
                "associated_shared_image_map_.erase(it);",
                "wgpuCommandEncoderBeginRenderPass",
                "wgpuQueueCopyExternalTextureForBrowser",
                "profile_denylisted",
                "adapter_denylist_detail",
                "vendor_id",
                "blocklist_reason",
                "unknown_selection_error",
            ]
        ),
        encoding="utf-8",
    )
    gpu_process_host = source_root / "content" / "browser" / "gpu" / "gpu_process_host.cc"
    gpu_process_host.parent.mkdir(parents=True, exist_ok=True)
    gpu_process_host.write_text(
        "\n".join(
            [
                "switches::kUseWebGPURuntime",
                "switches::kDisableWebGPUDoe",
                "switches::kDoeWebGPULibraryPath",
            ]
        ),
        encoding="utf-8",
    )
    iosurface = (
        source_root
        / "gpu"
        / "command_buffer"
        / "service"
        / "shared_image"
        / "iosurface_image_backing.mm"
    )
    iosurface.parent.mkdir(parents=True, exist_ok=True)
    iosurface.write_text(
        "\n".join(
            [
                "class IOSurfaceImageBacking::DawnRepresentation final",
                "backend_type == wgpu::BackendType::WebGPU",
                "std::make_unique<DawnRepresentation>",
                "wgpu::SharedTextureMemoryIOSurfaceDescriptor io_surface_desc",
                "io_surface_desc.ioSurface = io_surface_.get();",
                "device.ImportSharedTextureMemory(&desc)",
                "ProcessSharedEventsForBeginAccess",
                "AddSharedEventForEndAccess",
            ]
        ),
        encoding="utf-8",
    )
    backend = (
        source_root
        / "third_party"
        / "dawn"
        / "src"
        / "dawn"
        / "native"
        / "webgpu"
        / "BackendWGPU.cpp"
    )
    backend.parent.mkdir(parents=True, exist_ok=True)
    backend.write_text(
        "\n".join(
            [
                "LoadDoeWireProcTable",
                "mExternalRuntimeLib.Open",
                "mInnerInstance = mDawnProcs.createInstance(&instanceDesc);",
                'load_proc(&mDawnProcs.instanceRelease, "wgpuInstanceRelease")',
                "Backend::~Backend()",
                "mDawnProcs.instanceRelease(mInnerInstance);",
                "mInnerInstance = nullptr;",
            ]
        ),
        encoding="utf-8",
    )
    test_source = source_root / "gpu" / "command_buffer" / "service" / "webgpu_decoder_unittest.cc"
    test_source.write_text(
        "\n".join(
            [
                "DoeWireRuntimeOwnsAndReleasesInstanceLifecycle",
                "DoeAdapterDenylistDetailCarriesSourceFields",
            ]
        ),
        encoding="utf-8",
    )

    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    for command in checkout.REQUIRED_TOOLS:
        _write_tool(bin_dir, command)

    report = checkout.check_checkout(
        root=tmp_path,
        source_root_text="browser/chromium/src",
        require_ready=True,
        require_runtime_selector=True,
        path_env=str(bin_dir),
    )

    assert report["status"] == "pass"
    assert report["missingRequired"] == []
