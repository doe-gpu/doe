#!/usr/bin/env python3
"""Check the browser responsibility map contract."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path, PurePosixPath
from typing import Any


try:
    from bench.tools._repo_import import ensure_repo_root
except ModuleNotFoundError:
    from _repo_import import ensure_repo_root

REPO_ROOT = ensure_repo_root(__file__)
from bench.lib.bench_utils import load_json_object as load_json

REQUIRED_CPU_ENTRIES = {
    "networking",
    "cache",
    "html_parsing",
    "css_parsing",
    "cascade",
    "dom",
    "style_tree",
    "layout",
    "javascript_execution",
    "event_loop",
    "accessibility_tree",
    "permissions",
    "origin_policy",
    "scheduling",
    "lifecycle",
    "workers",
    "service_workers",
    "developer_tooling",
}

REQUIRED_GPU_ENTRIES = {
    "rasterization",
    "compositing",
    "canvas_2d",
    "webgl",
    "webgpu",
    "image_filters",
    "css_effects",
    "transforms",
    "texture_upload",
    "readback",
    "video_presentation",
    "swapchain_surface_presentation",
    "gpu_memory_residency",
    "command_submission",
    "pipeline_cache",
    "shader_compilation",
    "frame_pacing",
}

CLAIM_BINDING_FIELDS = {
    "contractPath",
    "schemaPath",
    "workloadPath",
    "gatePath",
    "artifactPath",
}

VALID_SCOPE_STATUSES = {
    "not_doe_scope",
    "webgpu_seam",
    "doe_observable",
    "doe_schedulable",
    "doe_claim_candidate",
    "blocked_by_browser_policy",
}

PATH_META_CHARS = set("*?[{")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--map",
        default=str(REPO_ROOT / "config/browser-responsibility-map.json"),
        help="Browser responsibility map JSON.",
    )
    parser.add_argument(
        "--root",
        default=str(REPO_ROOT),
        help="Repository root for claim-binding path checks.",
    )
    parser.add_argument("--json", action="store_true", dest="emit_json")
    return parser.parse_args()


def failure(code: str, path: str, message: str) -> dict[str, str]:
    return {"code": code, "path": path, "message": message}


def has_path_meta(path_text: str) -> bool:
    return any(char in path_text for char in PATH_META_CHARS)


def safe_repo_path(path_text: str) -> bool:
    path = PurePosixPath(path_text)
    return bool(path_text) and not path.is_absolute() and ".." not in path.parts


def resolve_path(root: Path, path_text: str) -> Path:
    return root.joinpath(*PurePosixPath(path_text).parts)


def artifact_anchor(root: Path, path_text: str) -> Path:
    if has_path_meta(path_text):
        prefix = []
        for part in PurePosixPath(path_text).parts:
            if any(char in part for char in PATH_META_CHARS):
                break
            prefix.append(part)
        return root.joinpath(*prefix) if prefix else root
    path = resolve_path(root, path_text)
    if path.suffix:
        return path.parent
    return path


def check_binding_path(root: Path, path_text: Any, path: str, *, artifact: bool = False) -> list[dict[str, str]]:
    if not isinstance(path_text, str) or not path_text:
        return [failure("unbound_claim_candidate", path, "claim binding path is required")]
    if not safe_repo_path(path_text):
        return [
            failure(
                "unsafe_claim_binding_path",
                path,
                f"claim binding path must be repo-relative: {path_text}",
            )
        ]
    target = artifact_anchor(root, path_text) if artifact else resolve_path(root, path_text)
    if not target.exists():
        return [failure("stale_reference", path, f"claim binding target does not exist: {path_text}")]
    if not artifact and not target.is_file():
        return [failure("stale_reference", path, f"claim binding target is not a file: {path_text}")]
    return []


def check_claim_binding(root: Path, item: dict[str, Any], item_path: str) -> list[dict[str, str]]:
    failures: list[dict[str, str]] = []
    binding = item.get("claimBinding")
    if not isinstance(binding, dict):
        return [failure("unbound_claim_candidate", f"{item_path}.claimBinding", "claim candidate requires claimBinding")]

    missing = sorted(field for field in CLAIM_BINDING_FIELDS if not binding.get(field))
    for field in missing:
        failures.append(
            failure(
                "unbound_claim_candidate",
                f"{item_path}.claimBinding.{field}",
                f"claim binding missing {field}",
            )
        )
    if missing:
        return failures

    failures.extend(check_binding_path(root, binding.get("contractPath"), f"{item_path}.claimBinding.contractPath"))
    failures.extend(check_binding_path(root, binding.get("schemaPath"), f"{item_path}.claimBinding.schemaPath"))
    failures.extend(check_binding_path(root, binding.get("workloadPath"), f"{item_path}.claimBinding.workloadPath"))
    failures.extend(check_binding_path(root, binding.get("gatePath"), f"{item_path}.claimBinding.gatePath"))
    failures.extend(
        check_binding_path(
            root,
            binding.get("artifactPath"),
            f"{item_path}.claimBinding.artifactPath",
            artifact=True,
        )
    )
    return failures


def check_entries(root: Path, payload: dict[str, Any]) -> tuple[dict[str, dict[str, Any]], list[dict[str, str]]]:
    failures: list[dict[str, str]] = []
    entries: dict[str, dict[str, Any]] = {}
    for index, entry in enumerate(payload.get("entries", [])):
        entry_path = f"entries[{index}]"
        if not isinstance(entry, dict):
            failures.append(failure("missing_entry", entry_path, "entry must be an object"))
            continue
        entry_id = entry.get("entryId")
        if not isinstance(entry_id, str) or not entry_id:
            failures.append(failure("missing_entry", f"{entry_path}.entryId", "entryId is required"))
            continue
        if entry_id in entries:
            failures.append(failure("duplicate_entry", f"{entry_path}.entryId", f"duplicate entry {entry_id}"))
        entries[entry_id] = entry
        if entry.get("scopeStatus") not in VALID_SCOPE_STATUSES:
            failures.append(
                failure(
                    "invalid_scope_status",
                    f"{entry_path}.scopeStatus",
                    f"invalid scopeStatus for {entry_id}",
                )
            )
        if entry.get("scopeStatus") == "doe_claim_candidate":
            failures.extend(check_claim_binding(root, entry, entry_path))

    for entry_id in sorted(REQUIRED_CPU_ENTRIES - set(entries)):
        failures.append(failure("missing_entry", "entries", f"missing CPU entry {entry_id}"))
    for entry_id in sorted(REQUIRED_GPU_ENTRIES - set(entries)):
        failures.append(failure("missing_entry", "entries", f"missing GPU entry {entry_id}"))
    for entry_id in sorted(REQUIRED_CPU_ENTRIES & set(entries)):
        if entries[entry_id].get("owner") != "cpu":
            failures.append(failure("wrong_owner", f"entries.{entry_id}.owner", f"{entry_id} must be CPU-owned"))
    for entry_id in sorted(REQUIRED_GPU_ENTRIES & set(entries)):
        if entries[entry_id].get("owner") != "gpu":
            failures.append(failure("wrong_owner", f"entries.{entry_id}.owner", f"{entry_id} must be GPU-owned"))
    return entries, failures


def check_boundaries(root: Path, payload: dict[str, Any], entries: dict[str, dict[str, Any]]) -> list[dict[str, str]]:
    failures: list[dict[str, str]] = []
    seen: set[str] = set()
    for index, boundary in enumerate(payload.get("boundaries", [])):
        boundary_path = f"boundaries[{index}]"
        if not isinstance(boundary, dict):
            failures.append(failure("missing_boundary", boundary_path, "boundary must be an object"))
            continue
        boundary_id = boundary.get("boundaryId")
        if isinstance(boundary_id, str) and boundary_id:
            if boundary_id in seen:
                failures.append(
                    failure("duplicate_boundary", f"{boundary_path}.boundaryId", f"duplicate boundary {boundary_id}")
                )
            seen.add(boundary_id)
        for endpoint in ("fromEntryId", "toEntryId"):
            entry_id = boundary.get(endpoint)
            if entry_id not in entries:
                failures.append(
                    failure(
                        "stale_reference",
                        f"{boundary_path}.{endpoint}",
                        f"boundary references missing entry {entry_id!r}",
                    )
                )
        if boundary.get("scopeStatus") not in VALID_SCOPE_STATUSES:
            failures.append(
                failure(
                    "invalid_scope_status",
                    f"{boundary_path}.scopeStatus",
                    f"invalid scopeStatus for {boundary_id}",
                )
            )
        if boundary.get("scopeStatus") == "doe_claim_candidate":
            failures.extend(check_claim_binding(root, boundary, boundary_path))
    return failures


def check_responsibility_map(payload: dict[str, Any], root: Path = REPO_ROOT) -> list[dict[str, str]]:
    entries, entry_failures = check_entries(root, payload)
    return entry_failures + check_boundaries(root, payload, entries)


def main() -> int:
    args = parse_args()
    failures = check_responsibility_map(load_json(Path(args.map)), Path(args.root).resolve())
    report = {
        "schemaVersion": 1,
        "artifactKind": "browser_responsibility_map_check",
        "status": "fail" if failures else "pass",
        "failures": failures,
    }
    if args.emit_json:
        print(json.dumps(report, indent=2))
    elif failures:
        print("FAIL: browser responsibility map")
        for item in failures:
            print(f"- {item['code']}: {item['path']}: {item['message']}")
    else:
        print("PASS: browser responsibility map")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
