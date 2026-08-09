"""Capture a reproducible structural baseline for Zig recomposition work."""

from __future__ import annotations

import argparse
import copy
import hashlib
import json
import platform
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
from pathlib import Path
from typing import Any

from ast_inventory import capture_ast_inventory
from generate_architecture_reports import architecture_observations
from source_architecture import (
    Analysis,
    analyze,
    canonical_json,
    load_manifest,
    sha256_file,
)
from verify_semantic_fixtures import load_verified_fixture_set


ROOT = Path(__file__).resolve().parents[1]
CONFIG_PATH = ROOT / "source-layout.json"
OUTPUT_ROOT = ROOT / "reports" / "recomposition"


def _run(command: list[str], cwd: Path) -> str:
    result = subprocess.run(
        command,
        cwd=cwd,
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        detail = result.stderr.strip() or result.stdout.strip()
        raise RuntimeError(f"command failed ({' '.join(command)}): {detail}")
    return result.stdout


def _git_state(root: Path) -> dict[str, Any]:
    repository_root = root.parents[1]
    base_commit = _run(["git", "rev-parse", "HEAD"], repository_root).strip()
    relative_root = root.relative_to(repository_root).as_posix()
    status = _run(
        ["git", "status", "--porcelain=v1", "--", f"{relative_root}/src"],
        repository_root,
    )
    dirty_paths = sorted(
        line[3:].split(" -> ")[-1] for line in status.splitlines() if line
    )
    return {
        "baseCommit": base_commit,
        "dirtyPaths": dirty_paths,
        "isClean": not dirty_paths,
    }


def _materialize_git_source(
    root: Path,
    git_ref: str,
    destination: Path,
) -> tuple[Path, dict[str, Any]]:
    repository_root = root.parents[1]
    commit = _run(
        ["git", "rev-parse", f"{git_ref}^{{commit}}"], repository_root
    ).strip()
    relative_source = (root / "src").relative_to(repository_root).as_posix()
    result = subprocess.run(
        ["git", "archive", "--format=tar", commit, relative_source],
        cwd=repository_root,
        check=False,
        capture_output=True,
    )
    if result.returncode != 0:
        detail = result.stderr.decode("utf-8", errors="replace").strip()
        raise RuntimeError(f"could not materialize Git source {git_ref}: {detail}")
    archive_path = destination / "source.tar"
    archive_path.write_bytes(result.stdout)
    with tarfile.open(archive_path, mode="r:") as archive:
        archive.extractall(destination, filter="data")
    archive_path.unlink()
    snapshot_root = destination / root.relative_to(repository_root)
    if not (snapshot_root / "src").is_dir():
        raise RuntimeError(f"Git source snapshot missing runtime/zig/src at {commit}")
    return snapshot_root, {
        "baseCommit": commit,
        "dirtyPaths": [],
        "isClean": True,
        "requestedRef": git_ref,
        "snapshotKind": "git-archive",
    }


def _baseline_manifest(
    config: dict[str, Any],
    snapshot_root: Path,
    base_commit: str,
) -> tuple[dict[str, Any], dict[str, Any]]:
    frozen = copy.deepcopy(config)
    adjustments: list[dict[str, Any]] = []
    historical_experimental = snapshot_root / "src" / "experimental"
    layers = frozen["architecture"]["layers"]
    if historical_experimental.is_dir() and "experimental" not in layers:
        layers["experimental"] = {
            "globs": ["src/experimental/**"],
            "mayImport": [
                "command",
                "contracts",
                "experimental",
                "full",
                "runtime",
            ],
        }
        adjustments.append(
            {
                "reason": (
                    "the named baseline predates promotion/removal of the experimental "
                    "subsystem and the version-2 manifest was introduced after that "
                    "commit"
                ),
                "type": "restore-historical-experimental-layer",
            }
        )
    decision_reviews = frozen["architecture"].get("moduleDecisionReviews", {})
    if decision_reviews:
        frozen["architecture"]["moduleDecisionReviews"] = {}
        adjustments.append(
            {
                "reason": (
                    "module decision reviews are SHA-bound to the live "
                    "recomposition tree and cannot be projected backward onto "
                    "the named baseline snapshot"
                ),
                "removedReviewCount": len(decision_reviews),
                "type": "remove-live-module-decision-reviews",
            }
        )
    wrapper = {
        "adjustments": adjustments,
        "baseCommit": base_commit,
        "manifest": frozen,
        "schemaVersion": 1,
        "status": "frozen-baseline-architecture-manifest",
    }
    return frozen, wrapper


def _zig_identity(root: Path) -> dict[str, Any]:
    workspace_root = root.parents[2]
    repository_root = root.parents[1]
    candidates = sorted((repository_root / ".tooling").glob("zig-*/zig"))
    candidates.extend(sorted((workspace_root / ".tooling").glob("zig-*/zig")))
    system_zig = shutil.which("zig")
    if system_zig:
        candidates.append(Path(system_zig))
    if not candidates:
        return {"path": None, "status": "not-found", "version": None}
    executable = candidates[-1].resolve()
    version = _run([str(executable), "version"], root).strip()
    return {
        "path": executable.relative_to(workspace_root).as_posix()
        if executable.is_relative_to(workspace_root)
        else str(executable),
        "status": "captured",
        "version": version,
    }


def _discover_libraries(root: Path) -> list[Path]:
    library_root = root / "zig-out" / "lib"
    if not library_root.is_dir():
        return []
    promoted_prefixes = ("libonnxruntime_doe_ep", "libwebgpu_doe")
    return sorted(
        path
        for path in library_root.iterdir()
        if path.is_file() and path.name.startswith(promoted_prefixes)
    )


def _extract_symbols(path: Path) -> list[str]:
    nm = shutil.which("nm")
    if nm is None:
        raise RuntimeError("nm is required to capture exported shared-library symbols")
    attempts = (
        [nm, "-D", "--defined-only", str(path)],
        [nm, "-g", "--defined-only", str(path)],
        [nm, "-gU", str(path)],
    )
    failures: list[str] = []
    for command in attempts:
        result = subprocess.run(command, check=False, capture_output=True, text=True)
        if result.returncode != 0:
            failures.append(result.stderr.strip())
            continue
        symbols: set[str] = set()
        for line in result.stdout.splitlines():
            fields = line.split()
            if fields:
                symbols.add(fields[-1])
        return sorted(symbols)
    raise RuntimeError(
        f"could not extract symbols from {path}: " + "; ".join(failures)
    )


def _artifact_records(
    root: Path,
    libraries: list[Path],
) -> tuple[list[dict[str, Any]], str]:
    records: list[dict[str, Any]] = []
    symbol_lines: list[str] = []
    for path in libraries:
        symbols = _extract_symbols(path)
        relative_path = path.relative_to(root).as_posix()
        digest = sha256_file(path)
        records.append(
            {
                "path": relative_path,
                "sha256": digest,
                "sizeBytes": path.stat().st_size,
                "symbolCount": len(symbols),
            }
        )
        symbol_lines.append(f"# {relative_path} sha256={digest}")
        symbol_lines.extend(symbols)
        symbol_lines.append("")
    if not symbol_lines:
        symbol_lines.append("# no promoted shared-library artifacts were present")
    return records, "\n".join(symbol_lines).rstrip() + "\n"


def _semantic_fixture_capture(
    root: Path,
    base_commit: str,
) -> dict[str, Any]:
    fixture_root = root / "reports" / "recomposition" / "semantic-fixtures"
    manifest_path = fixture_root / "manifest.json"
    if not manifest_path.is_file():
        return {"status": "not-captured"}
    manifest, files = load_verified_fixture_set(fixture_root)
    if manifest.get("git", {}).get("baseCommit") != base_commit:
        return {
            "capturedBaseCommit": manifest.get("git", {}).get("baseCommit"),
            "requestedBaseCommit": base_commit,
            "status": "not-captured-commit-mismatch",
        }
    return {
        "captureToolSha256": manifest.get("captureToolSha256"),
        "fileCount": len(files),
        "irDigestInstrumentation": manifest.get("irDigestInstrumentation"),
        "manifestSha256": sha256_file(manifest_path),
        "replayStatus": manifest["replay"]["status"],
        "sharedLibraries": manifest.get("sharedLibraries", []),
        "status": manifest["status"],
        "wgslIrDigest": manifest["wgsl"]["irDigest"],
    }


def _semantic_artifact_records(
    root: Path,
    semantic_fixtures: dict[str, Any],
    *,
    fixture_root: Path | None = None,
    source_label: str = "git-snapshot",
) -> tuple[list[dict[str, Any]], str]:
    fixture_root = fixture_root or (
        root / "reports" / "recomposition" / "semantic-fixtures"
    )
    records: list[dict[str, Any]] = []
    symbol_lines: list[str] = []
    for library in semantic_fixtures.get("sharedLibraries", []):
        symbol_path = fixture_root / library["symbols"]
        symbols = symbol_path.read_text(encoding="utf-8").splitlines()
        if len(symbols) != library["symbolCount"]:
            raise RuntimeError(
                f"shared-library symbol count mismatch: {library['path']}"
            )
        records.append(
            {
                "path": library["path"],
                "sha256": library["sha256"],
                "sizeBytes": library["sizeBytes"],
                "symbolCount": library["symbolCount"],
            }
        )
        symbol_lines.append(
            f"# {library['path']} sha256={library['sha256']} "
            f"source={source_label}"
        )
        symbol_lines.extend(symbols)
        symbol_lines.append("")
    if not records:
        raise RuntimeError("semantic fixtures contain no promoted shared libraries")
    return records, "\n".join(symbol_lines).rstrip() + "\n"


PUBLIC_MODULE_IMPORT_RE = re.compile(
    r'(?:return|=)\s*@import\("([^"\n]+\.zig)"\)'
)


def _exported_module_paths(
    analysis_root: Path,
    module_root: str,
    ast_inventory: dict[str, Any] | None,
) -> set[str]:
    ast_by_path = {
        record["path"]: record
        for record in (ast_inventory or {}).get("files", [])
    }
    reached: set[str] = set()
    pending = [module_root]
    while pending:
        path = pending.pop()
        if path in reached:
            continue
        reached.add(path)
        record = ast_by_path.get(path)
        if record is None:
            continue
        source_path = analysis_root / path
        lines = source_path.read_text(encoding="utf-8").splitlines()
        targets: set[str] = set()
        for declaration in record["declarations"]:
            if not declaration["public"]:
                continue
            declaration_source = "\n".join(
                lines[declaration["startLine"] - 1 : declaration["endLine"]]
            )
            for import_text in PUBLIC_MODULE_IMPORT_RE.findall(declaration_source):
                target = (source_path.parent / import_text).resolve(strict=False)
                try:
                    relative_target = target.relative_to(analysis_root).as_posix()
                except ValueError:
                    continue
                if relative_target in ast_by_path:
                    targets.add(relative_target)
        pending.extend(sorted(targets - reached, reverse=True))
    return reached


def _public_api(
    analysis_root: Path,
    analysis: Analysis,
    provenance: dict[str, Any],
    module_root: str,
    ast_inventory: dict[str, Any] | None,
) -> dict[str, Any]:
    reachable = _exported_module_paths(
        analysis_root,
        module_root,
        ast_inventory,
    )
    ast_by_path = {
        record["path"]: record
        for record in (ast_inventory or {}).get("files", [])
    }
    modules = [
        {
            "declarations": [
                {
                    "contractTokenSha256": declaration.get(
                        "contractTokenSha256"
                    ),
                    "kind": declaration["kind"],
                    "name": declaration["name"],
                }
                for declaration in ast_by_path[module["path"]]["declarations"]
                if declaration["public"] and declaration["name"] is not None
            ]
            if module["path"] in ast_by_path
            else module["publicDeclarations"],
            "path": module["path"],
            "sha256": module["sha256"],
        }
        for module in analysis.modules
        if module["path"] in reachable
        and (
            module["publicDeclarations"]
            or any(
                declaration["public"] and declaration["name"] is not None
                for declaration in ast_by_path.get(module["path"], {}).get(
                    "declarations", []
                )
            )
        )
    ]
    return {
        **provenance,
        "modules": modules,
        "rootModule": module_root,
        "schemaVersion": 1,
    }


def build_baseline(
    root: Path,
    config_path: Path,
    config: dict[str, Any],
    analysis: Analysis,
    libraries: list[Path],
    *,
    analysis_root: Path | None = None,
    ast_inventory: dict[str, Any] | None = None,
    git_state: dict[str, Any] | None = None,
    manifest_sha256: str | None = None,
) -> dict[str, str]:
    """Build canonical baseline, public API, and exported-symbol artifacts."""

    git_state = git_state or _git_state(root)
    analysis_root = (analysis_root or root).resolve()
    semantic_fixtures = _semantic_fixture_capture(
        root,
        git_state["baseCommit"],
    )
    artifact_source_binding = "unverified-unbound-artifacts"
    if semantic_fixtures.get("sharedLibraries"):
        artifacts, exported_symbols = _semantic_artifact_records(
            root,
            semantic_fixtures,
        )
        artifact_source_binding = "verified-git-snapshot"
    else:
        artifacts, exported_symbols = _artifact_records(root, libraries)
    provenance = {
        "manifestSha256": manifest_sha256 or sha256_file(config_path),
        "sourceTreeSha256": analysis.source_tree_sha256,
    }
    architecture_observations_payload = {
        "captureStatus": "captured",
        "observations": architecture_observations(
            analysis,
            {
                "commitsConsidered": 0,
                "historyHead": None,
                "pairs": [],
                "status": "not-captured-at-frozen-source",
            },
            None,
        ),
        "schemaVersion": 1,
        "sourceTreeSha256": analysis.source_tree_sha256,
    }
    architecture_observations_text = canonical_json(
        architecture_observations_payload
    )
    public_api = canonical_json(
        _public_api(
            analysis_root,
            analysis,
            provenance,
            config["moduleRoot"],
            ast_inventory,
        )
    )
    identity = hashlib.sha256()
    identity.update(git_state["baseCommit"].encode("ascii"))
    identity.update(b"\0")
    identity.update(analysis.source_tree_sha256.encode("ascii"))
    identity.update(b"\0")
    identity.update(public_api.encode("utf-8"))
    identity.update(b"\0")
    identity.update(exported_symbols.encode("utf-8"))
    identity.update(b"\0")
    identity.update(canonical_json(semantic_fixtures).encode("utf-8"))
    semantic_status = semantic_fixtures["status"] == "captured"
    ir_digest = semantic_fixtures.get("wgslIrDigest")
    ir_digest_captured = (
        semantic_status
        and isinstance(ir_digest, str)
        and len(ir_digest) == 64
        and all(character in "0123456789abcdef" for character in ir_digest)
    )
    baseline = {
        **provenance,
        "artifactCapture": {
            "artifacts": artifacts,
            "sourceBinding": artifact_source_binding,
            "status": "captured" if artifacts else "not-captured",
        },
        "architectureObservationCapture": "captured",
        "baselineKind": "structural-recomposition",
        "baselineId": identity.hexdigest(),
        "behaviorCapture": {
            "backendCapabilities": "not-captured",
            "commandNormalization": "captured" if semantic_status else "not-captured",
            "errorClassifications": "captured" if semantic_status else "not-captured",
            "performance": "not-captured",
            "semanticFixtures": "captured" if semantic_status else "not-captured",
            "traceAndReceiptIdentity": (
                "captured" if semantic_status else "not-captured"
            ),
            "wgslLoweringDigests": (
                "ir-and-target-outputs-captured"
                if ir_digest_captured
                else (
                    "target-outputs-captured-ir-not-captured"
                    if semantic_status
                    else "not-captured"
                )
            ),
        },
        "git": git_state,
        "frozen": True,
        "host": {
            "machine": platform.machine(),
            "operatingSystem": platform.system(),
            "release": platform.release(),
        },
        "moduleCount": len(analysis.modules),
        "policyHashes": {
            "architectureChecker": sha256_file(
                root / "tools" / "check_source_layout.py"
            ),
            "architectureReportIntegrity": sha256_file(
                root / "tools" / "check_recomposition_reports.py"
            ),
            "architectureAnalyzer": sha256_file(
                root / "tools" / "source_architecture.py"
            ),
            "astInventoryRunner": sha256_file(root / "tools" / "ast_inventory.py"),
            "architectureReportGenerator": sha256_file(
                root / "tools" / "generate_architecture_reports.py"
            ),
            "buildMeasurementCapture": sha256_file(
                root / "tools" / "capture_build_measurements.py"
            ),
            "semanticFixtureCapture": sha256_file(
                root / "tools" / "capture_semantic_fixtures.py"
            ),
            "semanticFixtureVerifier": sha256_file(
                root / "tools" / "verify_semantic_fixtures.py"
            ),
            "astInventory": sha256_file(root / "tools" / "source_ast_inventory.zig"),
            "baselineVerifier": sha256_file(
                root / "tools" / "verify_recomposition_baseline.py"
            ),
            "sourceLayout": sha256_file(config_path),
            "styleGuide": sha256_file(root / "STYLE.md"),
        },
        "publicApiCapture": "captured",
        "schemaVersion": 1,
        "semanticFixtureCapture": semantic_fixtures,
        "toolchain": {
            "python": platform.python_version(),
            "zig": _zig_identity(root),
        },
    }
    return {
        "architecture-observations.json": architecture_observations_text,
        "baseline.json": canonical_json(baseline),
        "exported-symbols.txt": exported_symbols,
        "public-api.json": public_api,
    }


def write_or_check(
    artifacts: dict[str, str],
    output_root: Path,
    *,
    check: bool,
) -> list[str]:
    """Write baseline artifacts or return freshness violations."""

    errors: list[str] = []
    if check:
        for name, expected in sorted(artifacts.items()):
            path = output_root / name
            if not path.is_file():
                errors.append(f"missing recomposition baseline artifact: {path}")
            elif path.read_text(encoding="utf-8") != expected:
                errors.append(f"stale recomposition baseline artifact: {path}")
        return errors
    output_root.mkdir(parents=True, exist_ok=True)
    for name, content in sorted(artifacts.items()):
        (output_root / name).write_text(content, encoding="utf-8")
    return errors


def parse_args() -> argparse.Namespace:
    """Parse baseline-capture arguments."""

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=ROOT, help="runtime/zig root")
    parser.add_argument(
        "--config", type=Path, default=CONFIG_PATH, help="source-layout manifest"
    )
    parser.add_argument(
        "--output-root",
        type=Path,
        default=OUTPUT_ROOT,
        help="recomposition baseline artifact directory",
    )
    parser.add_argument(
        "--library",
        action="append",
        type=Path,
        default=[],
        help="shared library to inventory; repeat for multiple artifacts",
    )
    parser.add_argument(
        "--git-ref",
        default="HEAD",
        help=(
            "named Git commit/ref whose runtime/zig/src tree becomes the frozen "
            "baseline"
        ),
    )
    parser.add_argument(
        "--check", action="store_true", help="fail when baseline artifacts are stale"
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        config = load_manifest(args.config)
        with tempfile.TemporaryDirectory(
            prefix="doe-recomposition-baseline-"
        ) as temporary:
            snapshot_root, git_state = _materialize_git_source(
                args.root,
                args.git_ref,
                Path(temporary),
            )
            baseline_config, baseline_manifest = _baseline_manifest(
                config,
                snapshot_root,
                git_state["baseCommit"],
            )
            baseline_manifest_text = canonical_json(baseline_manifest)
            baseline_manifest_sha256 = hashlib.sha256(
                baseline_manifest_text.encode("utf-8")
            ).hexdigest()
            analysis = analyze(snapshot_root, baseline_config)
            if analysis.manifest_errors or analysis.unresolved_imports:
                for error in analysis.manifest_errors:
                    print(error, file=sys.stderr)
                for unresolved in analysis.unresolved_imports:
                    print(unresolved, file=sys.stderr)
                return 1
            libraries = [path.resolve() for path in args.library]
            if not libraries:
                libraries = _discover_libraries(args.root)
            artifacts = build_baseline(
                args.root,
                args.config,
                baseline_config,
                analysis,
                libraries,
                analysis_root=snapshot_root,
                ast_inventory=capture_ast_inventory(
                    snapshot_root,
                    analysis,
                    tool_root=args.root,
                ),
                git_state=git_state,
                manifest_sha256=baseline_manifest_sha256,
            )
            artifacts["source-layout.baseline.json"] = baseline_manifest_text
        errors = write_or_check(artifacts, args.output_root, check=args.check)
    except (FileNotFoundError, KeyError, OSError, RuntimeError, ValueError) as exc:
        print(f"recomposition baseline capture failed: {exc}", file=sys.stderr)
        return 1
    if not errors:
        return 0
    for error in errors:
        print(error, file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
