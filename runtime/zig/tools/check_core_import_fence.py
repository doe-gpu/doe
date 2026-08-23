from __future__ import annotations

import re
import sys
from collections.abc import Iterator
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
ZIG_SRC = ROOT / "zig" / "src"
LEAN_ROOT = ROOT / "lean" / "Fawn"
ZIG_IMPORT_RE = re.compile(r'@import\("([^"]+)"\)')
BACKEND_IMPL_DIRS = tuple(
    ZIG_SRC / "backend" / name for name in ("metal", "vulkan", "d3d12")
)
SYNTHETIC_RUNTIME_STATE_SUFFIX = "_runtime_state.zig"
FORBIDDEN_STUB_SUFFIX = "_stub.zig"
FORBIDDEN_SYNTHETIC_IMPORTS = {
    "metal_runtime_state.zig",
    "vulkan_runtime_state.zig",
}
FORBIDDEN_COMPAT_IMPORTS = {
    "doe_native_base.zig",
    "doe_native_types.zig",
    "doe_native_helpers.zig",
    "model.zig",
    "model_transfer_types.zig",
    "model_runtime_types.zig",
    "model_webgpu_types.zig",
    "model_surface_types.zig",
    "webgpu_ffi.zig",
    "wgpu_base_types.zig",
    "wgpu_descriptor_types.zig",
    "wgpu_types.zig",
}
BACKEND_PRIVATE_DIRS = (
    (ZIG_SRC / "backend" / "metal").resolve(),
    (ZIG_SRC / "backend" / "vulkan").resolve(),
    (ZIG_SRC / "backend" / "d3d12").resolve(),
)
BACKEND_COMPOSITION_ROOTS = {
    (ZIG_SRC / "composition" / "backend_factory.zig").resolve(),
}
BACKEND_PROVIDER_INTEGRATION_ROOTS = {
    (ZIG_SRC / "backend" / path).resolve()
    for path in (
        "dropin_capabilities.zig",
        "dropin_external_texture.zig",
        "dropin_lifecycle.zig",
        "dropin_pipeline_cache.zig",
        "dropin_queue_submit.zig",
        "dropin_render_state.zig",
        "dropin_resource_ops.zig",
        "dropin_surface_ops.zig",
        "metal_package_pipeline_cache.zig",
    )
}
BACKEND_PROVIDER_OWNERS = BACKEND_COMPOSITION_ROOTS | BACKEND_PROVIDER_INTEGRATION_ROOTS
PROVIDER_ADAPTER = ZIG_SRC / "backend" / "ports" / "provider_adapter.zig"
PROVIDER_DRIVER_FILES = (
    ZIG_SRC / "backend" / "dawn_delegate_backend.zig",
    ZIG_SRC / "backend" / "metal" / "mod.zig",
    ZIG_SRC / "backend" / "vulkan" / "mod.zig",
    ZIG_SRC / "backend" / "d3d12" / "mod.zig",
)
PROVIDER_CACHE_FILES = (
    ZIG_SRC / "backend" / "metal" / "metal_pipeline_cache.zig",
    ZIG_SRC / "backend" / "vulkan" / "vk_pipeline_cache_persistent.zig",
)
PREPARED_OPERATION_OWNER = ZIG_SRC / "app" / "prepare.zig"


def is_stub_file(candidate: Path) -> bool:
    return candidate.suffix == ".zig" and candidate.name.endswith(FORBIDDEN_STUB_SUFFIX)


def is_synthetic_runtime_state_file(candidate: Path) -> bool:
    return candidate.name in FORBIDDEN_SYNTHETIC_IMPORTS or candidate.name.endswith(
        SYNTHETIC_RUNTIME_STATE_SUFFIX
    )


def is_within(path: Path, root: Path) -> bool:
    try:
        path.relative_to(root)
        return True
    except ValueError:
        return False


def backend_private_owner(path: Path) -> Path | None:
    """Return the concrete provider subtree that owns *path*, when any."""
    resolved = path.resolve(strict=False)
    return next(
        (root for root in BACKEND_PRIVATE_DIRS if is_within(resolved, root)),
        None,
    )


def backend_private_import_allowed(source: Path, target: Path) -> bool:
    """Enforce leaf-provider isolation and the unique composition root.

    Provider-private imports are legal from the unique composition root or
    from another file in the same provider subtree. Backend-common modules do
    not receive a blanket exemption: that would allow provider policy to leak
    back into shared runtime code.
    """
    target_owner = backend_private_owner(target)
    if target_owner is None:
        return True
    if source.resolve(strict=False) in BACKEND_PROVIDER_OWNERS:
        return True
    return backend_private_owner(source) == target_owner


def has_broad_provider_driver_bridge(source: str) -> bool:
    return "Driver.executeCommand" in source or re.search(
        r"pub\s+const\s+executeCommand\s*=", source
    ) is not None


def has_direct_prepared_command_construction(source: str) -> bool:
    return re.search(r"\bprepared(?:_contract)?\.fromCommand\s*\(", source) is not None


def has_process_global_provider_cache_state(source: str) -> bool:
    forbidden_names = (
        "process_active_cache",
        "process_cache_handle",
        "process_cache_state",
        "process_cache_disabled",
        "process_pipeline_cache_disabled",
        "set_process_pipeline_cache",
    )
    return any(name in source for name in forbidden_names)


def iter_zig_imports(root: Path) -> Iterator[tuple[Path, int, str, Path]]:
    """Yield (source_path, line_number, import_target, resolved_candidate) tuples
    for every `@import("…")` under *root*.
    """
    for path in sorted(root.rglob("*.zig")):
        for line_no, line in enumerate(path.read_text().splitlines(), start=1):
            for match in ZIG_IMPORT_RE.finditer(line):
                import_path = match.group(1)
                candidate = (path.parent / import_path).resolve(strict=False)
                yield path, line_no, import_path, candidate


def scan_zig_core(errors: list[str]) -> None:
    core_dir = ZIG_SRC / "core"
    full_dir = ZIG_SRC / "full"
    if not core_dir.is_dir():
        return
    for path, line_no, import_path, candidate in iter_zig_imports(core_dir):
        if is_within(candidate, full_dir):
            errors.append(f"{path}:{line_no}: core import reaches full: {import_path}")


def scan_lean_core(errors: list[str]) -> None:
    core_dir = LEAN_ROOT / "Core"
    if not core_dir.is_dir():
        return

    for path in sorted(core_dir.rglob("*.lean")):
        for line_no, line in enumerate(path.read_text().splitlines(), start=1):
            if line.strip().startswith("import ") and "Fawn.Full" in line:
                errors.append(f"{path}:{line_no}: Lean Core import reaches Full: {line.strip()}")


def scan_synthetic_state_imports(errors: list[str]) -> None:
    for path, line_no, import_path, candidate in iter_zig_imports(ZIG_SRC):
        if is_synthetic_runtime_state_file(candidate) or is_stub_file(candidate):
            errors.append(f"{path}:{line_no}: synthetic runtime-state import not allowed: {import_path}")


def scan_stub_file_presence(errors: list[str]) -> None:
    for file_path in sorted(ZIG_SRC.rglob("*_stub.zig")):
        if file_path.is_file():
            errors.append(f"forbidden stub file present: {file_path}")


def scan_stub_imports(errors: list[str]) -> None:
    for path, line_no, import_path, candidate in iter_zig_imports(ZIG_SRC):
        if is_stub_file(candidate):
            errors.append(f"{path}:{line_no}: stub import not allowed: {import_path}")


_COMPAT_FACADE_ABI_EXEMPT_TYPES = {
    "model_transfer_types.zig",
    "model_runtime_types.zig",
    "model_surface_types.zig",
}
_COMPAT_FACADE_ABI_EXEMPT_MODULE = Path("core/abi/mod.zig")


def scan_compat_facade_imports(errors: list[str]) -> None:
    for path, line_no, import_path, candidate in iter_zig_imports(ZIG_SRC):
        if candidate.name not in FORBIDDEN_COMPAT_IMPORTS:
            continue
        rel_path = path.relative_to(ZIG_SRC)
        if (
            candidate.name in _COMPAT_FACADE_ABI_EXEMPT_TYPES
            and rel_path == _COMPAT_FACADE_ABI_EXEMPT_MODULE
        ):
            continue
        errors.append(f"{path}:{line_no}: compatibility facade import not allowed: {import_path}")


def scan_backend_private_imports(errors: list[str]) -> None:
    for path, line_no, import_path, candidate in iter_zig_imports(ZIG_SRC):
        if not backend_private_import_allowed(path, candidate):
            errors.append(
                f"{path}:{line_no}: provider-private import crosses its owner boundary: "
                f"{import_path}"
            )


def scan_backend_impl_imports(errors: list[str]) -> None:
    for path, line_no, import_path, candidate in iter_zig_imports(ZIG_SRC):
        rel_path = path.relative_to(ZIG_SRC)
        if (
            rel_path.parts
            and rel_path.parts[0] == "backend"
            or path.resolve() in BACKEND_COMPOSITION_ROOTS
        ):
            continue
        if any(is_within(candidate, backend_dir) for backend_dir in BACKEND_IMPL_DIRS):
            errors.append(
                f"{path}:{line_no}: non-backend file imports backend implementation directly: {import_path}"
            )


def scan_provider_driver_escape_hatches(errors: list[str]) -> None:
    for path in (PROVIDER_ADAPTER, *PROVIDER_DRIVER_FILES):
        if path.is_file() and has_broad_provider_driver_bridge(path.read_text()):
            errors.append(
                f"{path}: provider driver exposes broad executeCommand escape hatch"
            )


def scan_prepared_operation_construction(errors: list[str]) -> None:
    for path in sorted(ZIG_SRC.rglob("*.zig")):
        if path == PREPARED_OPERATION_OWNER:
            continue
        if has_direct_prepared_command_construction(path.read_text()):
            errors.append(
                f"{path}: canonical commands must be prepared by app/prepare.zig"
            )


def scan_provider_cache_ownership(errors: list[str]) -> None:
    for path in PROVIDER_CACHE_FILES:
        if path.is_file() and has_process_global_provider_cache_state(path.read_text()):
            errors.append(f"{path}: provider cache state/configuration must be instance-owned")


def scan_forbidden_runtime_state_files(errors: list[str]) -> None:
    for file_path in sorted(ZIG_SRC.rglob("*.zig")):
        if is_synthetic_runtime_state_file(file_path):
            errors.append(f"forbidden synthetic runtime-state file present: {file_path}")


def main() -> int:
    errors: list[str] = []
    scan_zig_core(errors)
    scan_lean_core(errors)
    scan_synthetic_state_imports(errors)
    scan_forbidden_runtime_state_files(errors)
    scan_stub_file_presence(errors)
    scan_stub_imports(errors)
    scan_compat_facade_imports(errors)
    scan_backend_private_imports(errors)
    scan_backend_impl_imports(errors)
    scan_provider_driver_escape_hatches(errors)
    scan_prepared_operation_construction(errors)
    scan_provider_cache_ownership(errors)
    if not errors:
        return 0

    print("core/full import fence violations detected:", file=sys.stderr)
    for entry in errors:
        print(entry, file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
