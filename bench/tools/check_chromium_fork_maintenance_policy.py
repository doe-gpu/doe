#!/usr/bin/env python3
"""Check Chromium fork maintenance, rollback, and release artifact policy."""

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


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--policy", required=True, help="Chromium fork maintenance policy JSON.")
    parser.add_argument(
        "--root",
        default=str(REPO_ROOT),
        help="Repository root for referenced policy paths.",
    )
    parser.add_argument("--json", action="store_true", dest="emit_json")
    return parser.parse_args()


def failure(code: str, path: str, message: str) -> dict[str, str]:
    return {"code": code, "path": path, "message": message}


def _text(value: Any) -> str:
    return value.strip() if isinstance(value, str) else ""


def _safe_repo_path(path_text: str) -> bool:
    path = PurePosixPath(path_text)
    return bool(path_text) and not path.is_absolute() and ".." not in path.parts


def _resolve_repo_path(root: Path, path_text: str) -> Path:
    return root.joinpath(*PurePosixPath(path_text).parts)


def _root_prefix(root_text: str) -> str:
    return root_text if root_text.endswith("/") else f"{root_text}/"


def _path_under_root(path_text: str, root_text: str) -> bool:
    clean_root = root_text.rstrip("/")
    return path_text == clean_root or path_text.startswith(_root_prefix(clean_root))


def _path_under_any(path_text: str, roots: list[str]) -> bool:
    return any(_path_under_root(path_text, root) for root in roots)


def _check_existing_reference(
    root: Path,
    path_text: Any,
    field_path: str,
    missing_code: str,
) -> list[dict[str, str]]:
    ref = _text(path_text)
    if not ref:
        return []
    if not _safe_repo_path(ref):
        return [failure("unsafe_reference", field_path, f"path must be repo-relative: {ref}")]
    target = _resolve_repo_path(root, ref)
    if not target.exists():
        return [failure(missing_code, field_path, f"referenced path does not exist: {ref}")]
    return []


def check_policy(payload: dict[str, Any], root: Path = REPO_ROOT) -> list[dict[str, str]]:
    failures: list[dict[str, str]] = []
    isolation = payload.get("patchIsolation", {})
    rollback = payload.get("rollback", {})
    release = payload.get("releaseArtifacts", {})

    allowed_roots = isolation.get("allowedPatchRoots", []) if isinstance(isolation, dict) else []
    forbidden_roots = isolation.get("forbiddenPatchRoots", []) if isinstance(isolation, dict) else []
    allowed_root_text = [root for root in allowed_roots if isinstance(root, str) and root]
    forbidden_root_text = [root for root in forbidden_roots if isinstance(root, str) and root]
    for patch_root in forbidden_roots:
        if patch_root in allowed_roots:
            failures.append(failure("root_allowed_and_forbidden", "patchIsolation", f"patch root {patch_root!r} is both allowed and forbidden"))
    if not any(str(root).startswith("browser/chromium/") for root in allowed_roots):
        failures.append(failure("missing_browser_patch_root", "patchIsolation.allowedPatchRoots", "browser/chromium patch root must be explicit"))
    if not any(".local_volume" in str(root) for root in forbidden_roots):
        failures.append(failure("missing_local_volume_forbid", "patchIsolation.forbiddenPatchRoots", "local Chromium checkout must be forbidden"))
    if isolation.get("patchManifestRequired") is not True:
        failures.append(failure("patch_manifest_not_required", "patchIsolation.patchManifestRequired", "patch manifest must be required"))
    manifest_path = _text(isolation.get("patchManifestPath"))
    if not manifest_path:
        failures.append(
            failure(
                "missing_patch_manifest_path",
                "patchIsolation.patchManifestPath",
                "patch manifest path must be declared",
            )
        )
    elif not _safe_repo_path(manifest_path):
        failures.append(
            failure(
                "unsafe_patch_manifest_path",
                "patchIsolation.patchManifestPath",
                f"patch manifest path must be repo-relative: {manifest_path}",
            )
        )
    else:
        if not _path_under_any(manifest_path, allowed_root_text):
            failures.append(
                failure(
                    "patch_manifest_path_not_allowed",
                    "patchIsolation.patchManifestPath",
                    f"patch manifest path is outside allowed roots: {manifest_path}",
                )
            )
        if _path_under_any(manifest_path, forbidden_root_text):
            failures.append(
                failure(
                    "patch_manifest_path_forbidden",
                    "patchIsolation.patchManifestPath",
                    f"patch manifest path is under a forbidden root: {manifest_path}",
                )
            )
        if not _resolve_repo_path(root, manifest_path).is_file():
            failures.append(
                failure(
                    "missing_patch_manifest_file",
                    "patchIsolation.patchManifestPath",
                    f"patch manifest file does not exist: {manifest_path}",
                )
            )

    if rollback.get("dawnFallbackAvailable") is not True:
        failures.append(failure("dawn_fallback_missing", "rollback.dawnFallbackAvailable", "release rollback requires Dawn fallback"))
    for field in ("rollbackProcedurePath", "killSwitchPolicyPath"):
        if not rollback.get(field):
            failures.append(failure("missing_rollback_field", f"rollback.{field}", f"rollback requires {field}"))
        else:
            failures.extend(
                _check_existing_reference(
                    root,
                    rollback.get(field),
                    f"rollback.{field}",
                    "missing_rollback_reference",
                )
            )

    for field in ("browserBinaryHashRequired", "doeRuntimeHashRequired", "compilerHashRequired", "claimReportRequired"):
        if release.get(field) is not True:
            failures.append(failure("release_artifact_not_required", f"releaseArtifacts.{field}", f"release requires {field}"))
    return failures


def main() -> int:
    args = parse_args()
    failures = check_policy(load_json(Path(args.policy)), Path(args.root).resolve())
    report = {
        "schemaVersion": 1,
        "artifactKind": "chromium_fork_maintenance_policy_check",
        "status": "fail" if failures else "pass",
        "failures": failures,
    }
    if args.emit_json:
        print(json.dumps(report, indent=2))
    elif failures:
        print("FAIL: Chromium fork maintenance policy")
        for item in failures:
            print(f"- {item['code']}: {item['path']}: {item['message']}")
    else:
        print("PASS: Chromium fork maintenance policy")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
