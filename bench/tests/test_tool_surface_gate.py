#!/usr/bin/env python3
"""Tests for the tool surface manifest gate."""

from __future__ import annotations

import copy
import json
import tempfile
from pathlib import Path

from bench.gates import tool_surface_gate as gate


REPO_ROOT = Path(__file__).resolve().parents[2]
MANIFEST_PATH = REPO_ROOT / "config" / "tool-surfaces.json"


def _surface() -> dict:
    return {
        "id": "doe-gpu-package",
        "audience": "public",
        "kind": "package",
        "stability": "semver",
        "shipped": True,
        "summary": "unit",
        "rootPaths": ["packages/doe-gpu"],
        "entrypoints": [
            "packages/doe-gpu/src/index.js",
        ],
        "docs": ["packages/doe-gpu/README.md"],
    }


def _manifest(surface: dict) -> dict:
    return {
        "schemaVersion": 1,
        "surfaces": [surface],
    }


def _write_json(path: Path, payload: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload), encoding="utf-8")


def _write_package_fixture(root: Path) -> None:
    _write_json(
        root / "packages/doe-gpu/package.json",
        {
            "name": "doe-gpu",
            "type": "module",
            "exports": {
                ".": {
                    "types": "./src/index.d.ts",
                    "default": "./src/index.js",
                },
                "./node-webgpu": {
                    "types": "./src/node-webgpu.d.ts",
                    "default": "./src/node-webgpu.js",
                },
            },
        },
    )
    for path in (
        "packages/doe-gpu/src/index.js",
        "packages/doe-gpu/src/node-webgpu.js",
        "packages/doe-gpu/README.md",
    ):
        file_path = root / path
        file_path.parent.mkdir(parents=True, exist_ok=True)
        file_path.write_text("", encoding="utf-8")


def test_tracked_tool_surfaces_match_package_exports() -> None:
    manifest = json.loads(MANIFEST_PATH.read_text(encoding="utf-8"))

    result = gate.evaluate_manifest(manifest, REPO_ROOT)

    assert result["ok"], result["failures"]


def test_package_export_missing_from_surface_fails() -> None:
    with tempfile.TemporaryDirectory() as tmpdir:
        root = Path(tmpdir)
        _write_package_fixture(root)

        result = gate.evaluate_manifest(_manifest(_surface()), root)

    assert {
        "code": "package_export_missing_from_surface",
        "path": "surfaces[0].entrypoints",
        "message": (
            "package export target is not declared in tool surface: "
            "packages/doe-gpu/src/node-webgpu.js"
        ),
    } in result["failures"]


def test_complete_package_exports_pass() -> None:
    surface = _surface()
    surface["entrypoints"].append("packages/doe-gpu/src/node-webgpu.js")
    with tempfile.TemporaryDirectory() as tmpdir:
        root = Path(tmpdir)
        _write_package_fixture(root)

        result = gate.evaluate_manifest(_manifest(surface), root)

    assert result["ok"], result["failures"]


def test_package_bin_must_be_declared_and_then_passes() -> None:
    surface = _surface()
    surface["entrypoints"].append("packages/doe-gpu/src/node-webgpu.js")
    with tempfile.TemporaryDirectory() as tmpdir:
        root = Path(tmpdir)
        _write_package_fixture(root)
        package_path = root / "packages/doe-gpu/package.json"
        package = json.loads(package_path.read_text(encoding="utf-8"))
        package["bin"] = {"doe-proof-node": "./bin/doe-proof-node.js"}
        _write_json(package_path, package)
        bin_path = root / "packages/doe-gpu/bin/doe-proof-node.js"
        bin_path.parent.mkdir(parents=True, exist_ok=True)
        bin_path.write_text("", encoding="utf-8")

        missing = gate.evaluate_manifest(_manifest(surface), root)
        surface["entrypoints"].append("packages/doe-gpu/bin/doe-proof-node.js")
        complete = gate.evaluate_manifest(_manifest(surface), root)

    assert any(
        item["code"] == "package_bin_missing_from_surface"
        for item in missing["failures"]
    )
    assert complete["ok"], complete["failures"]


def test_missing_declared_entrypoint_fails() -> None:
    surface = _surface()
    surface["entrypoints"].append("packages/doe-gpu/src/missing.js")
    with tempfile.TemporaryDirectory() as tmpdir:
        root = Path(tmpdir)
        _write_package_fixture(root)

        result = gate.evaluate_manifest(_manifest(surface), root)

    codes = {item["code"] for item in result["failures"]}

    assert "missing_surface_entrypoint" in codes
    assert "surface_entrypoint_not_exported" in codes


def test_duplicate_surface_id_fails() -> None:
    surface = _surface()
    duplicate = copy.deepcopy(surface)
    manifest = _manifest(surface)
    manifest["surfaces"].append(duplicate)
    with tempfile.TemporaryDirectory() as tmpdir:
        root = Path(tmpdir)
        _write_package_fixture(root)

        result = gate.evaluate_manifest(manifest, root)

    assert any(item["code"] == "duplicate_surface_id" for item in result["failures"])
