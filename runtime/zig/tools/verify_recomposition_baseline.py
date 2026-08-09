"""Classify current public surfaces against the recomposition baseline."""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
from pathlib import Path
from typing import Any

from ast_inventory import capture_ast_inventory
from generate_recomposition_baseline import (
    _discover_libraries,
    _semantic_artifact_records,
    build_baseline,
)
from source_architecture import analyze, canonical_json, load_manifest
from verify_semantic_fixtures import load_verified_fixture_set


ROOT = Path(__file__).resolve().parents[1]
CONFIG_PATH = ROOT / "source-layout.json"
BASELINE_ROOT = ROOT / "reports" / "recomposition"


def _sha256_text(content: str) -> str:
    return hashlib.sha256(content.encode("utf-8")).hexdigest()


def _public_declarations(
    content: str,
) -> set[tuple[str, str, str, str | None]]:
    payload = json.loads(content)
    return {
        (
            module["path"],
            declaration["kind"],
            declaration["name"],
            declaration.get("contractTokenSha256"),
        )
        for module in payload["modules"]
        for declaration in module["declarations"]
    }


def _symbols(content: str) -> set[str]:
    return {
        line
        for line in content.splitlines()
        if line and not line.startswith("#")
    }


def _surface_diff(
    name: str,
    baseline: str,
    current: str,
) -> dict[str, Any] | None:
    if baseline == current:
        return None
    if name == "public-api.json":
        old = _public_declarations(baseline)
        new = _public_declarations(current)
        if old == new:
            return None
        return {
            "added": [list(item) for item in sorted(new - old)],
            "baselineSha256": _sha256_text(baseline),
            "currentSha256": _sha256_text(current),
            "removed": [list(item) for item in sorted(old - new)],
            "surface": "public-api",
        }
    old_symbols = _symbols(baseline)
    new_symbols = _symbols(current)
    if old_symbols == new_symbols:
        return None
    return {
        "added": sorted(new_symbols - old_symbols),
        "baselineSha256": _sha256_text(baseline),
        "currentSha256": _sha256_text(current),
        "removed": sorted(old_symbols - new_symbols),
        "surface": "exported-symbols",
    }


def classify(
    baseline_artifacts: dict[str, str],
    current_artifacts: dict[str, str],
    approved_surfaces: set[str],
    approval_reason: str | None,
) -> tuple[int, dict[str, Any]]:
    """Classify exact equivalence, approved contract change, or failure."""

    differences = [
        difference
        for name in ("public-api.json", "exported-symbols.txt")
        if (
            difference := _surface_diff(
                name,
                baseline_artifacts[name],
                current_artifacts[name],
            )
        )
        is not None
    ]
    changed_surfaces = {difference["surface"] for difference in differences}
    if not differences:
        classification = "exact-semantic-equivalence"
        exit_code = 0
    elif changed_surfaces <= approved_surfaces and approval_reason:
        classification = "approved-contract-change"
        exit_code = 0
    else:
        classification = "failure"
        exit_code = 1
    receipt = {
        "approval": {
            "reason": approval_reason,
            "surfaces": sorted(approved_surfaces),
        },
        "classification": classification,
        "differences": differences,
        "schemaVersion": 1,
    }
    if classification == "failure":
        receipt["failureBoundary"] = "+".join(sorted(changed_surfaces))
    return exit_code, receipt


def parse_args() -> argparse.Namespace:
    """Parse baseline-verifier arguments."""

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=ROOT, help="runtime/zig root")
    parser.add_argument(
        "--config", type=Path, default=CONFIG_PATH, help="source-layout manifest"
    )
    parser.add_argument(
        "--baseline-root",
        type=Path,
        default=BASELINE_ROOT,
        help="directory containing baseline artifacts",
    )
    parser.add_argument(
        "--candidate-semantic-root",
        type=Path,
        help=(
            "worktree-snapshot semantic fixture directory used to bind current "
            "exported ABI symbols to the analyzed source"
        ),
    )
    parser.add_argument(
        "--approve-surface",
        action="append",
        choices=("exported-symbols", "public-api"),
        default=[],
        help="explicitly approve one changed contract surface",
    )
    parser.add_argument(
        "--approval-reason",
        help="required non-empty reason when any changed surface is approved",
    )
    parser.add_argument(
        "--output", type=Path, help="optional path for the classification receipt"
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.approve_surface and not args.approval_reason:
        print("--approval-reason is required with --approve-surface", file=sys.stderr)
        return 1
    try:
        config = load_manifest(args.config)
        analysis = analyze(args.root, config)
        if analysis.manifest_errors or analysis.unresolved_imports:
            detail = list(analysis.manifest_errors) + list(analysis.unresolved_imports)
            raise RuntimeError(f"current architecture is not analyzable: {detail}")
        current = build_baseline(
            args.root,
            args.config,
            config,
            analysis,
            _discover_libraries(args.root),
            analysis_root=args.root,
            ast_inventory=capture_ast_inventory(
                args.root,
                analysis,
                tool_root=args.root,
            ),
        )
        final_analysis = analyze(args.root, config)
        if final_analysis.source_tree_sha256 != analysis.source_tree_sha256:
            raise RuntimeError(
                "Zig source tree changed during baseline verification; "
                "retry from one coherent snapshot"
            )
        baseline = {
            name: (args.baseline_root / name).read_text(encoding="utf-8")
            for name in ("public-api.json", "exported-symbols.txt")
        }
        baseline_public_api = json.loads(baseline["public-api.json"])
        if args.candidate_semantic_root is not None:
            candidate_manifest, _ = load_verified_fixture_set(
                args.candidate_semantic_root
            )
            expected_candidate = f"WORKTREE:{analysis.source_tree_sha256}"
            actual_candidate = candidate_manifest.get("git", {}).get("baseCommit")
            if actual_candidate != expected_candidate:
                raise RuntimeError(
                    "candidate semantic fixtures are not bound to the analyzed "
                    f"source: expected {expected_candidate}, got {actual_candidate}"
                )
            _, current_symbols = _semantic_artifact_records(
                args.root,
                candidate_manifest,
                fixture_root=args.candidate_semantic_root,
                source_label="worktree-snapshot",
            )
            current["exported-symbols.txt"] = current_symbols
        elif (
            baseline_public_api.get("sourceTreeSha256")
            != analysis.source_tree_sha256
        ):
            raise RuntimeError(
                "changed source requires --candidate-semantic-root so current "
                "ABI symbols are snapshot-bound"
            )
        exit_code, receipt = classify(
            baseline,
            current,
            set(args.approve_surface),
            args.approval_reason,
        )
    except (FileNotFoundError, KeyError, OSError, RuntimeError, ValueError) as exc:
        diagnostic = f"recomposition baseline verification failed: {exc}"
        receipt = {
            "approval": {
                "reason": args.approval_reason,
                "surfaces": sorted(set(args.approve_surface)),
            },
            "classification": "failure",
            "diagnostic": diagnostic,
            "failureBoundary": "structural-baseline-verification",
            "schemaVersion": 1,
        }
        rendered = canonical_json(receipt)
        if args.output:
            args.output.parent.mkdir(parents=True, exist_ok=True)
            args.output.write_text(rendered, encoding="utf-8")
        print(diagnostic, file=sys.stderr)
        return 1
    rendered = canonical_json(receipt)
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(rendered, encoding="utf-8")
    sys.stdout.write(rendered)
    return exit_code


if __name__ == "__main__":
    raise SystemExit(main())
