#!/usr/bin/env python3
"""Gate public/internal/archive surface metadata against shipped files."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

REPO_ROOT = Path(__file__).resolve().parents[2]
BENCH_ROOT = REPO_ROOT / "bench"
for _path_entry in (str(REPO_ROOT), str(BENCH_ROOT)):
    if _path_entry not in sys.path:
        sys.path.insert(0, _path_entry)

from bench.lib.bench_utils import detect_repo_root, load_json_object


PACKAGE_EXPORT_EXTENSIONS = (".js", ".mjs", ".cjs")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--root",
        default="",
        help="Repository root. Auto-detected when omitted.",
    )
    parser.add_argument(
        "--manifest",
        default="config/tool-surfaces.json",
        help="Tool surface manifest path relative to repository root.",
    )
    parser.add_argument("--json", action="store_true", dest="emit_json")
    return parser.parse_args()


def failure(code: str, path: str, message: str) -> dict[str, str]:
    return {"code": code, "path": path, "message": message}


def unsafe_repo_path_reason(value: Any, *, allow_command_suffix: bool = False) -> str:
    if not isinstance(value, str) or not value:
        return "path must be a non-empty string"
    candidate = value.split(" ", 1)[0] if allow_command_suffix else value
    if "\\" in candidate:
        return "path must use forward slashes"
    if candidate.startswith("/"):
        return "path must be repository-relative"
    parts = candidate.split("/")
    if any(part in ("", ".", "..") for part in parts):
        return "path must not contain empty, current, or parent segments"
    return ""


def resolve_entrypoint_path(root: Path, value: str) -> Path:
    return root / value.split(" ", 1)[0]


def collect_export_targets(value: Any, package_root_rel: str) -> set[str]:
    targets: set[str] = set()
    if isinstance(value, str):
        if value.endswith(PACKAGE_EXPORT_EXTENSIONS):
            normalized = value[2:] if value.startswith("./") else value
            targets.add(f"{package_root_rel}/{normalized}")
        return targets
    if isinstance(value, dict):
        for child in value.values():
            targets.update(collect_export_targets(child, package_root_rel))
    return targets


def collect_bin_targets(value: Any, package_root_rel: str) -> set[str]:
    targets: set[str] = set()
    if isinstance(value, str):
        normalized = value[2:] if value.startswith("./") else value
        targets.add(f"{package_root_rel}/{normalized}")
        return targets
    if isinstance(value, dict):
        for child in value.values():
            targets.update(collect_bin_targets(child, package_root_rel))
    return targets


def validate_declared_paths(
    root: Path,
    surface: dict[str, Any],
    surface_path: str,
) -> list[dict[str, str]]:
    failures: list[dict[str, str]] = []
    for field in ("rootPaths", "docs"):
        values = surface.get(field, [])
        if not isinstance(values, list):
            continue
        for index, value in enumerate(values):
            path = f"{surface_path}.{field}[{index}]"
            reason = unsafe_repo_path_reason(value)
            if reason:
                failures.append(failure("unsafe_surface_path", path, reason))
                continue
            if not (root / value).exists():
                failures.append(
                    failure(
                        "missing_surface_path",
                        path,
                        f"declared path does not exist: {value}",
                    )
                )

    entrypoints = surface.get("entrypoints", [])
    if not isinstance(entrypoints, list):
        return failures
    for index, value in enumerate(entrypoints):
        path = f"{surface_path}.entrypoints[{index}]"
        reason = unsafe_repo_path_reason(value, allow_command_suffix=True)
        if reason:
            failures.append(failure("unsafe_surface_entrypoint", path, reason))
            continue
        if not resolve_entrypoint_path(root, value).exists():
            failures.append(
                failure(
                    "missing_surface_entrypoint",
                    path,
                    f"declared entrypoint does not exist: {value}",
                )
            )
    return failures


def validate_package_surface(
    root: Path,
    surface: dict[str, Any],
    surface_path: str,
) -> list[dict[str, str]]:
    failures: list[dict[str, str]] = []
    root_paths = surface.get("rootPaths")
    if not isinstance(root_paths, list) or not root_paths:
        return failures
    package_root_rel = root_paths[0]
    if not isinstance(package_root_rel, str):
        return failures
    package_json_path = root / package_root_rel / "package.json"
    if not package_json_path.exists():
        failures.append(
            failure(
                "missing_package_json",
                f"{surface_path}.rootPaths[0]",
                f"missing package.json under {package_root_rel}",
            )
        )
        return failures

    try:
        package_json = load_json_object(package_json_path)
    except (OSError, UnicodeError, json.JSONDecodeError, ValueError) as exc:
        failures.append(
            failure(
                "invalid_package_json",
                f"{surface_path}.rootPaths[0]",
                f"{package_json_path}: {exc}",
            )
        )
        return failures

    exported_targets = collect_export_targets(package_json.get("exports"), package_root_rel)
    bin_targets = collect_bin_targets(package_json.get("bin"), package_root_rel)
    declared_entrypoints = {
        item
        for item in surface.get("entrypoints", [])
        if isinstance(item, str)
    }
    for target in sorted(exported_targets - declared_entrypoints):
        failures.append(
            failure(
                "package_export_missing_from_surface",
                f"{surface_path}.entrypoints",
                f"package export target is not declared in tool surface: {target}",
            )
        )

    for target in sorted(bin_targets - declared_entrypoints):
        failures.append(
            failure(
                "package_bin_missing_from_surface",
                f"{surface_path}.entrypoints",
                f"package bin target is not declared in tool surface: {target}",
            )
        )

    public_targets = exported_targets | bin_targets
    for entrypoint in sorted(declared_entrypoints):
        if not entrypoint.startswith(f"{package_root_rel}/"):
            continue
        if entrypoint.endswith(PACKAGE_EXPORT_EXTENSIONS) and entrypoint not in public_targets:
            failures.append(
                failure(
                    "surface_entrypoint_not_exported",
                    f"{surface_path}.entrypoints",
                    f"public package entrypoint is not exported by package.json: {entrypoint}",
                )
            )
    return failures


def evaluate_manifest(manifest: dict[str, Any], root: Path) -> dict[str, Any]:
    failures: list[dict[str, str]] = []
    seen_ids: set[str] = set()
    surfaces = manifest.get("surfaces", [])
    package_surface_count = 0

    if not isinstance(surfaces, list):
        return {
            "ok": False,
            "failures": [
                failure("invalid_surfaces", "surfaces", "surfaces must be an array")
            ],
            "summary": {"surfaceCount": 0, "packageSurfaceCount": 0},
        }

    for index, surface in enumerate(surfaces):
        surface_path = f"surfaces[{index}]"
        if not isinstance(surface, dict):
            failures.append(
                failure("invalid_surface", surface_path, "surface must be an object")
            )
            continue

        surface_id = surface.get("id")
        if isinstance(surface_id, str):
            if surface_id in seen_ids:
                failures.append(
                    failure("duplicate_surface_id", f"{surface_path}.id", surface_id)
                )
            seen_ids.add(surface_id)

        failures.extend(validate_declared_paths(root, surface, surface_path))
        if surface.get("id") == "doe-gpu-package" and surface.get("kind") == "package":
            package_surface_count += 1
            failures.extend(validate_package_surface(root, surface, surface_path))

    return {
        "ok": not failures,
        "failures": failures,
        "summary": {
            "surfaceCount": len(surfaces),
            "packageSurfaceCount": package_surface_count,
        },
    }


def main() -> int:
    args = parse_args()
    try:
        root = detect_repo_root(args.root)
        manifest = load_json_object(root / args.manifest)
    except (OSError, UnicodeError, json.JSONDecodeError, ValueError) as exc:
        print(f"FAIL: tool surface gate input error: {exc}")
        return 1

    report = {
        "schemaVersion": 1,
        "artifactKind": "tool-surface-gate-report",
        **evaluate_manifest(manifest, root),
    }

    if args.emit_json:
        print(json.dumps(report, indent=2))
    elif report["failures"]:
        print("FAIL: tool surface gate")
        for item in report["failures"]:
            print(f"- {item['code']}: {item['path']}: {item['message']}")
    else:
        summary = report["summary"]
        print(
            "PASS: tool surface gate "
            f"({summary['surfaceCount']} surfaces, "
            f"{summary['packageSurfaceCount']} package surfaces)"
        )
    return 0 if report["ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
