"""Metal pipeline cache manifest reader and workload-membership detector.

The Doe Metal native runtime can open an MTLBinaryArchive at startup
(`runtime/zig/src/backend/metal/metal_native_runtime.zig:380-402`) when running
on macOS, pre-warming PSOs for the kernels enumerated in
`bench/kernels/doe_pipeline_archive.manifest`. The Dawn delegate path does not
have an equivalent cache, so cache-enabled Apple Metal diagnostics whose
dispatched kernel is in the manifest must surface the asymmetry.

Default Apple Metal Doe-vs-Dawn compare lanes are fair-cold and pass
`--no-pipeline-cache`; in those lanes trace metadata reports
`pipelineCache.state=disabled`, so manifest membership alone does not create a
path-asymmetry flag. See `bench/docs/metal-pipeline-cache-policy.md`.

Manifest format (line-oriented):
    R:N           # N render entries (not enumerated)
    C:<name>      # one compute kernel base name (without .wgsl)

This module provides:

- `load_compute_kernel_set(manifest_path)` -> set[str]
- `workload_dispatches_cached_kernel(workload_dict, cache_set)` -> bool
- `auto_path_asymmetry_note()` -> str (the canonical disclosure note)
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_MANIFEST_PATH = REPO_ROOT / "bench" / "kernels" / "doe_pipeline_archive.manifest"
DEFAULT_ARCHIVE_PATH = REPO_ROOT / "bench" / "kernels" / "doe_pipeline_archive.metallib"

# Kept in sync with metal_native_runtime.zig:380 (HAS_PIPELINE_CACHE gate).
APPLE_METAL_API = "metal"
APPLE_METAL_VENDOR = "apple"

PATH_ASYMMETRY_NOTE = (
    "Doe Metal cache opt-in lane serves PSO from pre-built MTLBinaryArchive "
    "(bench/kernels/doe_pipeline_archive.metallib, opened by "
    "runtime/zig/src/backend/metal/metal_native_runtime.zig); the Dawn "
    "delegate path does not have an equivalent archive. Treat this as "
    "cache-specific diagnostic evidence, not apples-to-apples Dawn-vs-Doe "
    "speed evidence."
)


def auto_path_asymmetry_note() -> str:
    """Canonical disclosure note for cache-membership-derived path asymmetry."""
    return PATH_ASYMMETRY_NOTE


def load_compute_kernel_set(manifest_path: str | Path | None = None) -> set[str]:
    """Read the manifest and return the set of compute kernel base names.

    Returns the empty set if the manifest is missing or unreadable; callers
    treat an empty set as "no cache asymmetry to flag" (non-Mac builds, deleted
    manifest, etc.).
    """
    path = Path(manifest_path) if manifest_path is not None else DEFAULT_MANIFEST_PATH
    if not path.is_file():
        return set()
    try:
        text = path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError):
        return set()
    kernels: set[str] = set()
    for raw_line in text.splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("C:"):
            name = line[2:].strip()
            if name:
                kernels.add(name)
    return kernels


def _kernel_base_name(value: Any) -> str:
    """Extract the base kernel name from a kernel reference.

    Manifest entries are bare base names like 'workgroup_atomic'. Command JSON
    references are filenames like 'workgroup_atomic.wgsl'. This strips the
    .wgsl extension if present and trims any path components.
    """
    if not isinstance(value, str):
        return ""
    stem = value.strip()
    if not stem:
        return ""
    # strip directory prefix
    last_slash = max(stem.rfind("/"), stem.rfind("\\"))
    if last_slash >= 0:
        stem = stem[last_slash + 1 :]
    if stem.endswith(".wgsl"):
        stem = stem[: -len(".wgsl")]
    return stem


def commands_dispatched_kernel_names(commands: list[dict[str, Any]]) -> set[str]:
    """Walk a command list and return the set of dispatched compute kernel base names.

    Recognizes both 'kernel' and 'kernel_name' fields per
    `runtime/zig/src/command/command_parse_dispatch.zig` aliasing.
    """
    names: set[str] = set()
    if not isinstance(commands, list):
        return names
    for entry in commands:
        if not isinstance(entry, dict):
            continue
        kind = entry.get("kind") or entry.get("command") or entry.get("command_kind")
        if not isinstance(kind, str) or kind != "kernel_dispatch":
            continue
        kernel_field = entry.get("kernel") or entry.get("kernel_name")
        base = _kernel_base_name(kernel_field)
        if base:
            names.add(base)
    return names


def is_apple_metal_workload(workload_api: str, workload_vendor: str) -> bool:
    """True for workloads that route through Doe's Metal native runtime."""
    api = (workload_api or "").strip().lower()
    vendor = (workload_vendor or "").strip().lower()
    return api == APPLE_METAL_API and vendor == APPLE_METAL_VENDOR


def workload_dispatches_cached_kernel(
    workload_api: str,
    workload_vendor: str,
    commands_path: str | Path | None,
    cache_set: set[str] | None = None,
    repo_root: Path | None = None,
) -> bool:
    """True iff this is an Apple Metal workload whose commands.json dispatches
    at least one kernel in the manifest set.

    Non-Metal lanes always return False because the cache code path is gated
    by `if (builtin.os.tag == .macos)` in metal_native_runtime.zig:380.
    """
    if not is_apple_metal_workload(workload_api, workload_vendor):
        return False
    if cache_set is None:
        cache_set = load_compute_kernel_set()
    if not cache_set:
        return False
    if commands_path is None:
        return False
    root = repo_root or REPO_ROOT
    cmd_path_str = str(commands_path).strip()
    if not cmd_path_str:
        return False
    cmd_path = Path(cmd_path_str)
    if not cmd_path.is_absolute():
        cmd_path = root / cmd_path
    if not cmd_path.is_file():
        return False
    try:
        commands = json.loads(cmd_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError):
        return False
    dispatched = commands_dispatched_kernel_names(commands)
    return bool(dispatched & cache_set)
