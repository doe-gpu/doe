"""Verify semantic-fixture integrity and classify candidate behavior changes."""

from __future__ import annotations

import argparse
import hashlib
import sys
from pathlib import Path, PurePosixPath
from typing import Any

from source_architecture import canonical_json, load_json_strict, sha256_file


ROOT = Path(__file__).resolve().parents[1]
BASELINE_ROOT = ROOT / "reports" / "recomposition" / "semantic-fixtures"


def load_verified_fixture_set(root: Path) -> tuple[dict[str, Any], dict[str, bytes]]:
    """Load one fixture set and reject every missing or digest-mismatched file."""

    manifest_path = root / "manifest.json"
    manifest = load_json_strict(manifest_path)
    if not isinstance(manifest, dict):
        raise RuntimeError("semantic fixture manifest must be an object")
    files: dict[str, bytes] = {}
    for record in manifest["files"]:
        relative_path = record["path"]
        if not isinstance(relative_path, str):
            raise RuntimeError(f"invalid semantic fixture path: {relative_path!r}")
        pure_path = PurePosixPath(relative_path)
        if (
            pure_path.is_absolute()
            or ".." in pure_path.parts
            or pure_path.as_posix() != relative_path
        ):
            raise RuntimeError(f"invalid semantic fixture path: {relative_path!r}")
        if relative_path in files:
            raise RuntimeError(f"duplicate semantic fixture path: {relative_path}")
        path = root / relative_path
        if not path.is_file():
            raise RuntimeError(f"missing semantic fixture: {relative_path}")
        content = path.read_bytes()
        if len(content) != record["sizeBytes"]:
            raise RuntimeError(f"semantic fixture size mismatch: {relative_path}")
        if hashlib.sha256(content).hexdigest() != record["sha256"]:
            raise RuntimeError(f"semantic fixture digest mismatch: {relative_path}")
        files[relative_path] = content
    actual_paths = {
        path.relative_to(root).as_posix()
        for path in root.rglob("*")
        if path.is_file() and path != manifest_path
    }
    if actual_paths != set(files):
        untracked = sorted(actual_paths - set(files))
        missing = sorted(set(files) - actual_paths)
        raise RuntimeError(
            "semantic fixture inventory mismatch: "
            f"untracked={untracked}, missing={missing}"
        )
    return manifest, files


def _category(path: str) -> str:
    if path.startswith("abi/"):
        return "abi-surface"
    if path.startswith("command-") or path.startswith("embedded-command-"):
        return "command-normalization"
    if path.startswith("trace-"):
        return "trace-and-replay"
    if path.startswith("wgsl-"):
        return "wgsl-lowering"
    return "semantic-fixture"


def classify(
    baseline_manifest: dict[str, Any],
    baseline_files: dict[str, bytes],
    candidate_manifest: dict[str, Any],
    candidate_files: dict[str, bytes],
    approved_categories: set[str],
    approval_reason: str | None,
) -> tuple[int, dict[str, Any]]:
    """Classify exact equivalence, approved behavior change, or failure."""

    differences: list[dict[str, Any]] = []
    for path in sorted(set(baseline_files) | set(candidate_files)):
        baseline = baseline_files.get(path)
        candidate = candidate_files.get(path)
        if baseline == candidate:
            continue
        differences.append(
            {
                "baselineSha256": (
                    hashlib.sha256(baseline).hexdigest()
                    if baseline is not None
                    else None
                ),
                "candidateSha256": (
                    hashlib.sha256(candidate).hexdigest()
                    if candidate is not None
                    else None
                ),
                "category": _category(path),
                "path": path,
            }
        )
    semantic_sections = (
        "commandNormalization",
        "errorClassifications",
        "replay",
        "trace",
        "wgsl",
    )
    for section in semantic_sections:
        if baseline_manifest.get(section) == candidate_manifest.get(section):
            continue
        category = {
            "commandNormalization": "command-normalization",
            "errorClassifications": "error-classification",
            "replay": "trace-and-replay",
            "trace": "trace-and-replay",
            "wgsl": "wgsl-lowering",
        }[section]
        differences.append(
            {
                "baselineSha256": hashlib.sha256(
                    canonical_json(baseline_manifest.get(section)).encode("utf-8")
                ).hexdigest(),
                "candidateSha256": hashlib.sha256(
                    canonical_json(candidate_manifest.get(section)).encode("utf-8")
                ).hexdigest(),
                "category": category,
                "path": f"manifest:{section}",
            }
        )
    baseline_observers = baseline_manifest.get(
        "irDigestInstrumentation",
        {},
    ).get("observers")
    candidate_observers = candidate_manifest.get(
        "irDigestInstrumentation",
        {},
    ).get("observers")
    if baseline_observers != candidate_observers:
        differences.append(
            {
                "baselineSha256": hashlib.sha256(
                    canonical_json(baseline_observers).encode("utf-8")
                ).hexdigest(),
                "candidateSha256": hashlib.sha256(
                    canonical_json(candidate_observers).encode("utf-8")
                ).hexdigest(),
                "category": "wgsl-lowering",
                "path": "manifest:irDigestObserver",
            }
        )
    changed_categories = {difference["category"] for difference in differences}
    if not differences:
        classification = "exact-semantic-equivalence"
        exit_code = 0
    elif changed_categories <= approved_categories and approval_reason:
        classification = "approved-contract-change"
        exit_code = 0
    else:
        classification = "failure"
        exit_code = 1
    receipt = {
        "approval": {
            "categories": sorted(approved_categories),
            "reason": approval_reason,
        },
        "baselineCommit": baseline_manifest["git"]["baseCommit"],
        "candidateCommit": candidate_manifest["git"]["baseCommit"],
        "classification": classification,
        "differences": differences,
        "schemaVersion": 1,
    }
    if classification == "failure":
        receipt["failureBoundary"] = "+".join(sorted(changed_categories))
    return exit_code, receipt


def parse_args() -> argparse.Namespace:
    """Parse semantic verification arguments."""

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--baseline-root",
        type=Path,
        default=BASELINE_ROOT,
        help="frozen semantic fixture directory",
    )
    parser.add_argument(
        "--candidate-root",
        type=Path,
        help="candidate semantic fixture directory; omit for integrity-only mode",
    )
    parser.add_argument(
        "--approve-category",
        action="append",
        choices=(
            "abi-surface",
            "command-normalization",
            "error-classification",
            "semantic-fixture",
            "trace-and-replay",
            "wgsl-lowering",
        ),
        default=[],
    )
    parser.add_argument("--approval-reason")
    parser.add_argument("--output", type=Path)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.approve_category and not args.approval_reason:
        print("--approval-reason is required with --approve-category", file=sys.stderr)
        return 1
    try:
        baseline_manifest, baseline_files = load_verified_fixture_set(
            args.baseline_root
        )
        if args.candidate_root is None:
            exit_code = 0
            receipt = {
                "classification": "integrity-verified",
                "fileCount": len(baseline_files),
                "manifestSha256": sha256_file(args.baseline_root / "manifest.json"),
                "schemaVersion": 1,
            }
        else:
            candidate_manifest, candidate_files = load_verified_fixture_set(
                args.candidate_root
            )
            exit_code, receipt = classify(
                baseline_manifest,
                baseline_files,
                candidate_manifest,
                candidate_files,
                set(args.approve_category),
                args.approval_reason,
            )
    except (KeyError, OSError, RuntimeError, ValueError) as exc:
        exit_code = 1
        receipt = {
            "classification": "failure",
            "diagnostic": str(exc),
            "failureBoundary": "semantic-fixture-integrity",
            "schemaVersion": 1,
        }
    rendered = canonical_json(receipt)
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(rendered, encoding="utf-8")
    sys.stdout.write(rendered)
    return exit_code


if __name__ == "__main__":
    raise SystemExit(main())
