#!/usr/bin/env python3
"""Validate Chromium patch isolation manifest semantics."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path, PurePosixPath
from typing import Any


REPO_ROOT = Path(__file__).resolve().parents[2]
BENCH_ROOT = REPO_ROOT / "bench"
for _path_entry in (str(REPO_ROOT), str(BENCH_ROOT)):
    if _path_entry not in sys.path:
        sys.path.insert(0, _path_entry)

from bench.lib.bench_utils import load_json_object as load_json

EXPECTED_ARTIFACT_KIND = "chromium_patch_manifest"
EXPECTED_SURFACE_ID = "doe-chromium"
VALID_PATCH_KINDS = {
    "app_wrapper",
    "release_artifact_sync",
    "runtime_selector_tool",
    "runtime_selector_contract",
    "runtime_selector_policy",
    "integration_overlay",
    "responsibility_contract",
    "responsibility_map",
}
VALID_STATUSES = {"active", "retired", "planned"}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", required=True, help="Chromium patch manifest JSON.")
    parser.add_argument("--policy", required=True, help="Chromium fork maintenance policy JSON.")
    parser.add_argument(
        "--root",
        default=str(REPO_ROOT),
        help="Repository root used for path and evidence checks.",
    )
    parser.add_argument("--json", action="store_true", dest="emit_json")
    return parser.parse_args()


def failure(code: str, path: str, message: str) -> dict[str, str]:
    return {"code": code, "path": path, "message": message}


def text(value: Any) -> str:
    return value.strip() if isinstance(value, str) else ""


def safe_repo_path(path_text: str) -> bool:
    path = PurePosixPath(path_text)
    return bool(path_text) and not path.is_absolute() and ".." not in path.parts


def resolve_repo_path(root: Path, path_text: str) -> Path:
    return root.joinpath(*PurePosixPath(path_text).parts)


def root_prefix(root_text: str) -> str:
    return root_text if root_text.endswith("/") else f"{root_text}/"


def path_under_root(path_text: str, root_text: str) -> bool:
    clean_root = root_text.rstrip("/")
    return path_text == clean_root or path_text.startswith(root_prefix(clean_root))


def path_under_any(path_text: str, roots: list[str]) -> bool:
    return any(path_under_root(path_text, root) for root in roots)


def check_reference(root: Path, path_text: Any, path: str, missing_code: str) -> list[dict[str, str]]:
    ref = text(path_text)
    if not ref:
        return [failure("missing_reference", path, "reference path is required")]
    if not safe_repo_path(ref):
        return [failure("unsafe_reference", path, f"reference path must be repo-relative: {ref}")]
    if not resolve_repo_path(root, ref).exists():
        return [failure(missing_code, path, f"missing referenced path: {ref}")]
    return []


def check_manifest(
    payload: dict[str, Any],
    policy: dict[str, Any],
    *,
    root: Path = REPO_ROOT,
    manifest_path: Path | None = None,
    policy_path: Path | None = None,
) -> list[dict[str, str]]:
    failures: list[dict[str, str]] = []
    if payload.get("schemaVersion") != 1:
        failures.append(failure("invalid_schema_version", "schemaVersion", "schemaVersion must be 1"))
    if payload.get("artifactKind") != EXPECTED_ARTIFACT_KIND:
        failures.append(
            failure(
                "invalid_artifact_kind",
                "artifactKind",
                f"artifactKind must be {EXPECTED_ARTIFACT_KIND}",
            )
        )
    if payload.get("surfaceId") != EXPECTED_SURFACE_ID:
        failures.append(
            failure("invalid_surface_id", "surfaceId", f"surfaceId must be {EXPECTED_SURFACE_ID}")
        )

    isolation = policy.get("patchIsolation") if isinstance(policy.get("patchIsolation"), dict) else {}
    allowed_roots = isolation.get("allowedPatchRoots", []) if isinstance(isolation, dict) else []
    forbidden_roots = isolation.get("forbiddenPatchRoots", []) if isinstance(isolation, dict) else []
    if not isinstance(allowed_roots, list):
        allowed_roots = []
    if not isinstance(forbidden_roots, list):
        forbidden_roots = []
    allowed_root_text = [root for root in allowed_roots if isinstance(root, str) and root]
    forbidden_root_text = [root for root in forbidden_roots if isinstance(root, str) and root]

    if isolation.get("patchManifestRequired") is not True:
        failures.append(
            failure(
                "patch_manifest_not_required",
                "policy.patchIsolation.patchManifestRequired",
                "policy must require a Chromium patch manifest",
            )
        )

    expected_manifest = text(isolation.get("patchManifestPath"))
    if not expected_manifest:
        failures.append(
            failure(
                "missing_policy_manifest_path",
                "policy.patchIsolation.patchManifestPath",
                "policy must name the Chromium patch manifest",
            )
        )
    elif manifest_path is not None and safe_repo_path(expected_manifest):
        expected_path = resolve_repo_path(root, expected_manifest).resolve()
        if expected_path != manifest_path.resolve():
            failures.append(
                failure(
                    "manifest_path_mismatch",
                    "policy.patchIsolation.patchManifestPath",
                    f"policy points at {expected_manifest}, not {manifest_path}",
                )
            )

    manifest_policy_path = text(payload.get("policyPath"))
    if not manifest_policy_path:
        failures.append(failure("missing_policy_path", "policyPath", "manifest must name its policy path"))
    elif not safe_repo_path(manifest_policy_path):
        failures.append(
            failure("unsafe_policy_path", "policyPath", f"policyPath must be repo-relative: {manifest_policy_path}")
        )
    elif policy_path is not None:
        expected_policy_path = resolve_repo_path(root, manifest_policy_path).resolve()
        if expected_policy_path != policy_path.resolve():
            failures.append(
                failure(
                    "policy_path_mismatch",
                    "policyPath",
                    f"manifest points at {manifest_policy_path}, not {policy_path}",
                )
            )

    patches = payload.get("patches")
    if not isinstance(patches, list) or not patches:
        return failures + [failure("missing_patches", "patches", "patches must be a non-empty array")]

    seen_ids: set[str] = set()
    active_count = 0
    for index, patch in enumerate(patches):
        patch_path = f"patches[{index}]"
        if not isinstance(patch, dict):
            failures.append(failure("invalid_patch_row", patch_path, "patch row must be an object"))
            continue

        patch_id = text(patch.get("patchId"))
        if not patch_id:
            failures.append(failure("missing_patch_id", f"{patch_path}.patchId", "patchId is required"))
        elif patch_id in seen_ids:
            failures.append(
                failure("duplicate_patch_id", f"{patch_path}.patchId", f"duplicate patchId {patch_id}")
            )
        else:
            seen_ids.add(patch_id)

        status = patch.get("status")
        if status not in VALID_STATUSES:
            failures.append(
                failure("invalid_status", f"{patch_path}.status", "status must be active, retired, or planned")
            )
        if status == "active":
            active_count += 1

        patch_kind = patch.get("patchKind")
        if patch_kind not in VALID_PATCH_KINDS:
            failures.append(
                failure("invalid_patch_kind", f"{patch_path}.patchKind", f"invalid patchKind {patch_kind!r}")
            )

        path_text = text(patch.get("path"))
        declared_root = text(patch.get("allowedRoot"))
        if not path_text:
            failures.append(failure("missing_patch_path", f"{patch_path}.path", "patch path is required"))
        elif not safe_repo_path(path_text):
            failures.append(
                failure("unsafe_patch_path", f"{patch_path}.path", f"patch path must be repo-relative: {path_text}")
            )
        else:
            if not path_under_any(path_text, allowed_root_text):
                failures.append(
                    failure(
                        "patch_path_not_allowed",
                        f"{patch_path}.path",
                        f"patch path is outside allowed roots: {path_text}",
                    )
                )
            if path_under_any(path_text, forbidden_root_text):
                failures.append(
                    failure(
                        "patch_path_forbidden",
                        f"{patch_path}.path",
                        f"patch path is under a forbidden root: {path_text}",
                    )
                )
            if status == "active" and not resolve_repo_path(root, path_text).is_file():
                failures.append(
                    failure("missing_patch_file", f"{patch_path}.path", f"active patch path must exist: {path_text}")
                )

        if not declared_root:
            failures.append(failure("missing_allowed_root", f"{patch_path}.allowedRoot", "allowedRoot is required"))
        elif declared_root not in allowed_root_text:
            failures.append(
                failure(
                    "unknown_allowed_root",
                    f"{patch_path}.allowedRoot",
                    f"allowedRoot is not declared by policy: {declared_root}",
                )
            )
        elif path_text and safe_repo_path(path_text) and not path_under_root(path_text, declared_root):
            failures.append(
                failure(
                    "patch_path_not_under_declared_root",
                    f"{patch_path}.allowedRoot",
                    f"{path_text} is not under declared root {declared_root}",
                )
            )

        if not text(patch.get("ownership")):
            failures.append(failure("missing_ownership", f"{patch_path}.ownership", "ownership is required"))
        if not text(patch.get("notes")):
            failures.append(failure("missing_notes", f"{patch_path}.notes", "notes are required"))
        if not isinstance(patch.get("chromiumSourceRequired"), bool):
            failures.append(
                failure(
                    "invalid_chromium_source_required",
                    f"{patch_path}.chromiumSourceRequired",
                    "chromiumSourceRequired must be a boolean",
                )
            )
        elif patch.get("chromiumSourceRequired") is True and status == "active":
            if not (root / "browser/chromium/src").exists():
                failures.append(
                    failure(
                        "missing_chromium_source_checkout",
                        f"{patch_path}.chromiumSourceRequired",
                        "active Chromium-source patch requires browser/chromium/src",
                    )
                )

        failures.extend(
            check_reference(
                root,
                patch.get("rollbackPath"),
                f"{patch_path}.rollbackPath",
                "missing_rollback_path",
            )
        )
        evidence_paths = patch.get("evidencePaths")
        if not isinstance(evidence_paths, list) or not evidence_paths:
            failures.append(
                failure("missing_evidence_paths", f"{patch_path}.evidencePaths", "evidencePaths must be non-empty")
            )
        else:
            for evidence_index, evidence_path in enumerate(evidence_paths):
                failures.extend(
                    check_reference(
                        root,
                        evidence_path,
                        f"{patch_path}.evidencePaths[{evidence_index}]",
                        "missing_evidence_path",
                    )
                )

    if active_count == 0:
        failures.append(failure("missing_active_patch", "patches", "manifest must contain at least one active patch"))
    return failures


def main() -> int:
    args = parse_args()
    root = Path(args.root).resolve()
    manifest_path = Path(args.manifest)
    policy_path = Path(args.policy)
    failures = check_manifest(
        load_json(manifest_path),
        load_json(policy_path),
        root=root,
        manifest_path=manifest_path.resolve(),
        policy_path=policy_path.resolve(),
    )
    report = {
        "schemaVersion": 1,
        "artifactKind": "chromium_patch_manifest_check",
        "manifestPath": str(manifest_path),
        "policyPath": str(policy_path),
        "status": "fail" if failures else "pass",
        "failures": failures,
    }
    if args.emit_json:
        print(json.dumps(report, indent=2))
    elif failures:
        print("FAIL: Chromium patch manifest")
        for item in failures:
            print(f"- {item['code']}: {item['path']}: {item['message']}")
    else:
        print("PASS: Chromium patch manifest")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
