"""Validate cross-report integrity for Doe Zig recomposition evidence."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path
from typing import Any

from source_architecture import load_json_strict, load_manifest, sha256_file
from verify_semantic_fixtures import load_verified_fixture_set


ROOT = Path(__file__).resolve().parents[1]
ARCHITECTURE_ROOT = ROOT / "reports" / "architecture"
BASELINE_ROOT = ROOT / "reports" / "recomposition"


def _load(path: Path) -> dict[str, Any]:
    payload = load_json_strict(path)
    if not isinstance(payload, dict):
        raise ValueError(f"report must be a JSON object: {path}")
    if payload.get("schemaVersion") != 1:
        raise ValueError(f"report schemaVersion must be 1: {path}")
    return payload


def _architecture_errors(
    root: Path,
    architecture_root: Path,
) -> list[str]:
    errors: list[str] = []
    report_names = (
        "ast-declarations.json",
        "co-change.json",
        "constant-families.json",
        "cycles.json",
        "duplicate-declarations.json",
        "forbidden-edges.json",
        "merge-candidates.json",
        "module-decisions.json",
        "modules.json",
        "observations.json",
        "reachability-views.json",
        "repeated-literal-tables.json",
        "split-candidates.json",
        "unreachable-files.json",
    )
    reports = {name: _load(architecture_root / name) for name in report_names}
    source_hashes = {report["sourceTreeSha256"] for report in reports.values()}
    if len(source_hashes) != 1:
        errors.append("architecture reports do not share one sourceTreeSha256")
    manifest_hashes = {report["manifestSha256"] for report in reports.values()}
    expected_manifest_hash = sha256_file(root / "source-layout.json")
    if manifest_hashes != {expected_manifest_hash}:
        errors.append("architecture report manifest hashes are stale or inconsistent")
    modules = reports["modules.json"]["modules"]
    module_paths = {module["path"] for module in modules}
    ast_paths = {
        record["path"]
        for record in reports["ast-declarations.json"]["files"]
    }
    if ast_paths != module_paths:
        errors.append("AST inventory paths do not exactly match module inventory")
    decisions = reports["module-decisions.json"]
    decision_paths = {entry["path"] for entry in decisions["entries"]}
    if decision_paths != module_paths:
        errors.append("module decision paths do not exactly match module inventory")
    if decisions["totalCount"] != len(modules):
        errors.append("module decision totalCount does not match module inventory")
    reviewed = sum(
        entry["reviewStatus"] == "reviewed" for entry in decisions["entries"]
    )
    if decisions["reviewedCount"] != reviewed:
        errors.append("module decision reviewedCount is inconsistent")
    observations = reports["observations.json"]["observations"]
    if observations["moduleCount"] != len(modules):
        errors.append("architecture observation moduleCount is inconsistent")
    build = observations["buildMeasurements"]
    if build.get("status") != "captured":
        errors.append(f"build measurements are not current: {build.get('status')}")
    elif build.get("sourceTreeSha256") not in source_hashes:
        errors.append("build measurement source does not match architecture reports")
    reachability = reports["reachability-views.json"]
    classified_paths = {
        module["path"]
        for module in modules
        if module["reachabilityViews"]
    }
    unclassified_paths = {
        entry["path"] for entry in reachability["unclassifiedFiles"]
    }
    facade_only_paths = {
        entry["path"] for entry in reachability["facadeOnlyFiles"]
    }
    if classified_paths | facade_only_paths | unclassified_paths != module_paths:
        errors.append(
            "reachability view classification does not cover module inventory"
        )
    if (
        classified_paths & facade_only_paths
        or classified_paths & unclassified_paths
        or facade_only_paths & unclassified_paths
    ):
        errors.append(
            "reachability view path classifications overlap"
        )
    if reachability["classifiedModuleCount"] != len(classified_paths):
        errors.append("reachability view classifiedModuleCount is inconsistent")
    view_names = {view["name"] for view in reachability["views"]}
    module_view_names = {
        name for module in modules for name in module["reachabilityViews"]
    }
    if module_view_names - view_names:
        errors.append("module inventory references an unknown reachability view")
    cycles = reports["cycles.json"]
    if cycles["staleExceptions"]:
        errors.append("cycle report contains stale exceptions")
    if any(not entry["allowedByException"] for entry in cycles["cycles"]):
        errors.append("cycle report contains an unapproved cycle")
    forbidden = reports["forbidden-edges.json"]
    if forbidden["staleExceptions"]:
        errors.append("forbidden-edge report contains stale exceptions")
    if any(not entry["allowedByException"] for entry in forbidden["edges"]):
        errors.append("forbidden-edge report contains an unapproved edge")
    unreachable = reports["unreachable-files.json"]
    if unreachable["staleExceptions"]:
        errors.append("unreachable-file report contains stale exceptions")
    if any(not entry["allowedByException"] for entry in unreachable["files"]):
        errors.append("unreachable-file report contains an unapproved module")
    if not (architecture_root / "import-graph.dot").is_file():
        errors.append("architecture import graph is missing")
    return errors


def _baseline_errors(root: Path, baseline_root: Path) -> list[str]:
    errors: list[str] = []
    baseline = _load(baseline_root / "baseline.json")
    public_api = _load(baseline_root / "public-api.json")
    frozen_manifest = _load(baseline_root / "source-layout.baseline.json")
    semantic_manifest, semantic_files = load_verified_fixture_set(
        baseline_root / "semantic-fixtures"
    )
    if not baseline.get("frozen"):
        errors.append("recomposition baseline is not frozen")
    if baseline["git"]["baseCommit"] != frozen_manifest["baseCommit"]:
        errors.append("baseline commit does not match frozen architecture manifest")
    if baseline["git"]["baseCommit"] != semantic_manifest["git"]["baseCommit"]:
        errors.append("baseline commit does not match semantic fixture snapshot")
    if baseline["sourceTreeSha256"] != public_api["sourceTreeSha256"]:
        errors.append("public API source digest does not match baseline")
    if baseline["manifestSha256"] != public_api["manifestSha256"]:
        errors.append("public API manifest digest does not match baseline")
    if baseline["artifactCapture"]["sourceBinding"] != "verified-git-snapshot":
        errors.append("baseline ABI artifacts are not bound to the Git snapshot")
    if baseline["semanticFixtureCapture"]["fileCount"] != len(semantic_files):
        errors.append("semantic fixture count does not match baseline")
    semantic_manifest_sha256 = sha256_file(
        baseline_root / "semantic-fixtures" / "manifest.json"
    )
    if (
        baseline["semanticFixtureCapture"]["manifestSha256"]
        != semantic_manifest_sha256
    ):
        errors.append("semantic fixture manifest digest does not match baseline")
    if (
        baseline["semanticFixtureCapture"].get("captureToolSha256")
        != semantic_manifest.get("captureToolSha256")
    ):
        errors.append("semantic fixture capture-tool digest does not match baseline")
    if (
        baseline["semanticFixtureCapture"].get("wgslIrDigest")
        != semantic_manifest.get("wgsl", {}).get("irDigest")
    ):
        errors.append("semantic fixture IR digest does not match baseline")
    if baseline["semanticFixtureCapture"]["replayStatus"] != "passed":
        errors.append("baseline semantic replay did not pass")
    symbol_headers = [
        line
        for line in (baseline_root / "exported-symbols.txt")
        .read_text(encoding="utf-8")
        .splitlines()
        if line.startswith("# ")
    ]
    if len(symbol_headers) != len(baseline["artifactCapture"]["artifacts"]):
        errors.append("exported-symbol sections do not match baseline artifacts")
    verification_path = baseline_root / "verification.json"
    if verification_path.is_file():
        verification = _load(verification_path)
        if verification["classification"] not in {
            "approved-contract-change",
            "exact-semantic-equivalence",
            "failure",
        }:
            errors.append("structural verification has an unknown classification")
    return errors


def _candidate_errors(
    root: Path,
    baseline_root: Path,
    source_tree_sha256: str,
) -> list[str]:
    """Validate an optional worktree-bound semantic candidate and its receipt."""

    candidate_root = baseline_root / "semantic-current"
    if not candidate_root.is_dir():
        return []
    errors: list[str] = []
    baseline_manifest, _ = load_verified_fixture_set(
        baseline_root / "semantic-fixtures"
    )
    candidate_manifest, _ = load_verified_fixture_set(candidate_root)
    expected_commit = f"WORKTREE:{source_tree_sha256}"
    candidate_commit = candidate_manifest.get("git", {}).get("baseCommit")
    if candidate_commit != expected_commit:
        errors.append(
            "semantic candidate is not bound to the architecture source digest"
        )
    current_capture_tool = sha256_file(
        root / "tools" / "capture_semantic_fixtures.py"
    )
    if candidate_manifest.get("captureToolSha256") != current_capture_tool:
        errors.append("semantic candidate was produced by a stale capture tool")
    receipt_path = baseline_root / "semantic-current-verification.json"
    if not receipt_path.is_file():
        errors.append("semantic candidate verification receipt is missing")
        return errors
    receipt = _load(receipt_path)
    if receipt.get("baselineCommit") != baseline_manifest["git"]["baseCommit"]:
        errors.append("semantic candidate receipt names the wrong baseline commit")
    if receipt.get("candidateCommit") != candidate_commit:
        errors.append("semantic candidate receipt names the wrong candidate commit")
    if receipt.get("classification") not in {
        "approved-contract-change",
        "exact-semantic-equivalence",
        "failure",
    }:
        errors.append("semantic candidate receipt has an unknown classification")
    return errors


def check(
    root: Path,
    architecture_root: Path,
    baseline_root: Path,
) -> list[str]:
    """Return every cross-report integrity violation."""

    load_manifest(root / "source-layout.json")
    architecture_errors = _architecture_errors(root, architecture_root)
    source_tree_sha256 = _load(architecture_root / "modules.json")[
        "sourceTreeSha256"
    ]
    return (
        architecture_errors
        + _baseline_errors(root, baseline_root)
        + _candidate_errors(root, baseline_root, source_tree_sha256)
    )


def parse_args() -> argparse.Namespace:
    """Parse report-integrity arguments."""

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=ROOT)
    parser.add_argument(
        "--architecture-root", type=Path, default=ARCHITECTURE_ROOT
    )
    parser.add_argument("--baseline-root", type=Path, default=BASELINE_ROOT)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        errors = check(
            args.root.resolve(),
            args.architecture_root.resolve(),
            args.baseline_root.resolve(),
        )
    except (KeyError, OSError, RuntimeError, ValueError) as exc:
        errors = [f"report integrity setup failed: {exc}"]
    if not errors:
        return 0
    print("recomposition report integrity violations:", file=sys.stderr)
    for error in errors:
        print(error, file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
