"""Generate deterministic reports for the Doe Zig architecture graph."""

from __future__ import annotations

import argparse
import itertools
import json
import statistics
import subprocess
import sys
from collections import Counter
from pathlib import Path
from typing import Any

from ast_inventory import capture_ast_inventory
from source_architecture import (
    Analysis,
    analyze,
    canonical_json,
    exception_for_cycle,
    load_manifest,
    reachability_exception,
    sha256_file,
)


ROOT = Path(__file__).resolve().parents[1]
CONFIG_PATH = ROOT / "source-layout.json"
OUTPUT_ROOT = ROOT / "reports" / "architecture"


def _provenance(analysis: Analysis, config_path: Path) -> dict[str, Any]:
    analyzer_path = Path(__file__).with_name("source_architecture.py")
    return {
        "architectureAnalyzerSha256": sha256_file(analyzer_path),
        "manifestPath": "runtime/zig/source-layout.json",
        "manifestSha256": sha256_file(config_path),
        "reportGeneratorSha256": sha256_file(Path(__file__)),
        "sourceLayoutVersion": 2,
        "sourceTreeSha256": analysis.source_tree_sha256,
    }


def _cycle_records(
    analysis: Analysis,
    config: dict[str, Any],
) -> list[dict[str, Any]]:
    records: list[dict[str, Any]] = []
    for members in analysis.cycles:
        exception = exception_for_cycle(members, config)
        record: dict[str, Any] = {
            "allowedByException": exception is not None,
            "members": list(members),
        }
        if exception is not None:
            record["reason"] = exception["reason"]
            record["removalCondition"] = exception["removalCondition"]
        records.append(record)
    return records


def _unreachable_records(
    analysis: Analysis,
    config: dict[str, Any],
) -> list[dict[str, Any]]:
    records: list[dict[str, Any]] = []
    for path in analysis.unreachable:
        exception = reachability_exception(path, config)
        record: dict[str, Any] = {
            "allowedByException": exception is not None,
            "path": path,
        }
        if exception is not None:
            record["reason"] = exception["reason"]
            record["removalCondition"] = exception["removalCondition"]
        records.append(record)
    return records


def _merge_candidates(analysis: Analysis) -> list[dict[str, Any]]:
    module_by_path = {module["path"]: module for module in analysis.modules}
    return [
        {
            "consumer": module["reverseImports"][0],
            "lineCount": module["lineCount"],
            "owner": module["owner"],
            "path": module["path"],
            "reason": (
                "one production consumer, no public declaration, no local test, "
                "and no special role"
            ),
        }
        for module in analysis.modules
        if module["fanIn"] == 1
        and module["publicDeclarationCount"] == 0
        and module["testBlockCount"] == 0
        and not module["roles"]
        and not module["isProductionRoot"]
        and module_by_path[module["reverseImports"][0]]["owner"] == module["owner"]
    ]


def _split_candidates(analysis: Analysis) -> list[dict[str, Any]]:
    return [
        {
            "fanIn": module["fanIn"],
            "fanOut": module["fanOut"],
            "lineCount": module["lineCount"],
            "path": module["path"],
            "reason": (
                "handwritten module exceeds the 800-line architecture review signal"
            ),
        }
        for module in analysis.modules
        if module["lineCount"] > 800 and "generated" not in module["roles"]
    ]


def _module_decisions(
    analysis: Analysis,
    config: dict[str, Any],
) -> dict[str, Any]:
    unreachable = set(analysis.unreachable)
    elevation_targets = {edge["target"] for edge in analysis.forbidden_edges}
    module_by_path = {module["path"]: module for module in analysis.modules}
    reviews = config["architecture"]["moduleDecisionReviews"]
    entries: list[dict[str, Any]] = []
    for module in analysis.modules:
        evidence: list[str] = []
        if module["path"] in unreachable:
            suggestion = "Delete"
            evidence.append("not reachable from a declared production root")
        elif module["path"] in elevation_targets:
            suggestion = "Elevate"
            evidence.append("target of a declared cross-layer dependency exception")
        elif module["lineCount"] > 800 and "generated" not in module["roles"]:
            suggestion = "Recompose"
            evidence.append("exceeds the 800-line architecture review signal")
        elif (
            module["fanIn"] == 1
            and module["publicDeclarationCount"] == 0
            and module["testBlockCount"] == 0
            and not module["roles"]
            and not module["isProductionRoot"]
            and module_by_path[module["reverseImports"][0]]["owner"]
            == module["owner"]
        ):
            suggestion = "Merge"
            evidence.append(
                "one production consumer with no public declaration, local test, "
                "or special role"
            )
        else:
            suggestion = "Keep"
            if module["isProductionRoot"]:
                evidence.append("declared production root")
            if module["roles"]:
                evidence.append("special roles: " + ", ".join(module["roles"]))
            if not evidence:
                evidence.append(
                    "no mechanical merge, elevation, deletion, or split signal"
                )
        review = reviews.get(module["path"])
        entry: dict[str, Any] = {
            "evidence": evidence,
            "moduleSha256": module["sha256"],
            "path": module["path"],
            "reviewStatus": "pending",
            "suggestedDecision": suggestion,
        }
        if review is not None:
            entry.update(
                {
                    "decision": review["decision"],
                    "reason": review["reason"],
                    "reviewStatus": "reviewed",
                    "reviewer": review["reviewer"],
                }
            )
        entries.append(entry)
    reviewed = sum(entry["reviewStatus"] == "reviewed" for entry in entries)
    return {
        "entries": entries,
        "pendingCount": len(entries) - reviewed,
        "reviewedCount": reviewed,
        "status": "complete" if reviewed == len(entries) else "review-required",
        "totalCount": len(entries),
    }


def _cochange_report(root: Path, analysis: Analysis) -> dict[str, Any]:
    repository_root = root.parents[1]
    relative_source = (root / "src").relative_to(repository_root).as_posix()
    result = subprocess.run(
        [
            "git",
            "log",
            "--format=COMMIT %H",
            "--name-status",
            "--",
            relative_source,
        ],
        cwd=repository_root,
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        detail = result.stderr.strip() or result.stdout.strip()
        raise RuntimeError(f"git co-change scan failed: {detail}")
    head_result = subprocess.run(
        ["git", "rev-parse", "HEAD"],
        cwd=repository_root,
        check=False,
        capture_output=True,
        text=True,
    )
    if head_result.returncode != 0:
        detail = head_result.stderr.strip() or head_result.stdout.strip()
        raise RuntimeError(f"git history identity failed: {detail}")
    history_head = head_result.stdout.strip()
    current_modules = {module["path"] for module in analysis.modules}
    generated_modules = {
        module["path"] for module in analysis.modules if "generated" in module["roles"]
    }
    commits: list[list[tuple[str, str]]] = []
    current: list[tuple[str, str]] = []
    for line in result.stdout.splitlines():
        if line.startswith("COMMIT "):
            if current:
                commits.append(current)
            current = []
            continue
        if not line.strip():
            continue
        fields = line.split("\t")
        if len(fields) < 2:
            continue
        status = fields[0]
        repository_path = fields[-1]
        if not repository_path.endswith(".zig"):
            continue
        try:
            runtime_path = (
                (repository_root / repository_path).relative_to(root).as_posix()
            )
        except ValueError:
            continue
        current.append((status, runtime_path))
    if current:
        commits.append(current)
    change_counts: Counter[str] = Counter()
    pair_counts: Counter[tuple[str, str]] = Counter()
    excluded_mass_change = 0
    excluded_pure_rename = 0
    considered = 0
    for changes in commits:
        statuses = [status for status, _ in changes]
        paths = sorted(
            {
                path
                for _, path in changes
                if path in current_modules and path not in generated_modules
            }
        )
        if statuses and all(status.startswith("R") for status in statuses):
            excluded_pure_rename += 1
            continue
        if len(paths) > 200:
            excluded_mass_change += 1
            continue
        if not paths:
            continue
        considered += 1
        change_counts.update(paths)
        pair_counts.update(itertools.combinations(paths, 2))
    pairs = [
        {
            "coChangeCount": count,
            "coupling": round(
                count / min(change_counts[left], change_counts[right]),
                6,
            ),
            "left": left,
            "right": right,
        }
        for (left, right), count in pair_counts.items()
        if count >= 3
    ]
    pairs.sort(
        key=lambda item: (
            -item["coChangeCount"],
            -item["coupling"],
            item["left"],
            item["right"],
        )
    )
    return {
        "commitsConsidered": considered,
        "commitsExcludedAsMassChange": excluded_mass_change,
        "commitsExcludedAsPureRename": excluded_pure_rename,
        "historyHead": history_head,
        "minimumPairCount": 3,
        "pairs": pairs[:1000],
        "pairTruncationLimit": 1000,
        "status": "diagnostic-only",
    }


def _duplicate_declarations(ast_inventory: dict[str, Any]) -> dict[str, Any]:
    if ast_inventory["status"] != "captured":
        return {
            "analysisStatus": "requires-std-zig-ast-normalized-token-hashes",
            "candidates": [],
            "diagnostic": (
                "declaration-name collisions are not semantic duplicates and are "
                "intentionally not reported as candidates"
            ),
        }
    groups: dict[str, list[dict[str, Any]]] = {}
    for file_record in ast_inventory["files"]:
        for declaration in file_record["declarations"]:
            groups.setdefault(declaration["normalizedTokenSha256"], []).append(
                {
                    "endLine": declaration["endLine"],
                    "kind": declaration["kind"],
                    "name": declaration["name"],
                    "path": file_record["path"],
                    "startLine": declaration["startLine"],
                    "tokenCount": declaration["tokenCount"],
                }
            )
    candidates = [
        {
            "locations": sorted(
                locations,
                key=lambda item: (
                    item["path"],
                    item["startLine"],
                    item["endLine"],
                ),
            ),
            "normalizedTokenSha256": digest,
            "reason": "identical normalized Zig declaration token stream",
        }
        for digest, locations in sorted(groups.items())
        if len(locations) > 1
    ]
    return {
        "analysisStatus": "captured",
        "candidates": candidates,
        "diagnostic": (
            "candidate equality is lexical after comment and whitespace removal; "
            "semantic ownership still requires review"
        ),
    }


def _constant_families(ast_inventory: dict[str, Any]) -> list[dict[str, Any]]:
    families: dict[str, list[dict[str, Any]]] = {}
    if ast_inventory["status"] != "captured":
        return []
    for file_record in ast_inventory["files"]:
        for declaration in file_record["declarations"]:
            name = declaration["name"]
            if declaration["kind"] != "constant" or not name or "_" not in name:
                continue
            prefix = name.split("_", 1)[0]
            families.setdefault(prefix, []).append(
                {
                    "name": name,
                    "path": file_record["path"],
                    "startLine": declaration["startLine"],
                }
            )
    return [
        {
            "members": sorted(
                members,
                key=lambda item: (item["path"], item["startLine"], item["name"]),
            ),
            "prefix": prefix,
            "reason": (
                "shared constant-name prefix; ownership and value similarity "
                "require review"
            ),
        }
        for prefix, members in sorted(families.items())
        if len(members) >= 3
    ]


def _repeated_literal_tables(
    ast_inventory: dict[str, Any],
) -> list[dict[str, Any]]:
    groups: dict[str, list[dict[str, Any]]] = {}
    if ast_inventory["status"] != "captured":
        return []
    for file_record in ast_inventory["files"]:
        for declaration in file_record["declarations"]:
            digest = declaration["literalTokenSha256"]
            literals = declaration["literalTokens"]
            if digest is None or len(literals) < 4:
                continue
            groups.setdefault(digest, []).append(
                {
                    "endLine": declaration["endLine"],
                    "literalCount": len(literals),
                    "name": declaration["name"],
                    "path": file_record["path"],
                    "startLine": declaration["startLine"],
                }
            )
    return [
        {
            "literalTokenSha256": digest,
            "locations": sorted(
                locations,
                key=lambda item: (
                    item["path"],
                    item["startLine"],
                    item["endLine"],
                ),
            ),
            "reason": "identical ordered sequence of at least four literal tokens",
        }
        for digest, locations in sorted(groups.items())
        if len(locations) > 1
    ]


def _distribution(values: list[int]) -> dict[str, Any]:
    ordered = sorted(values)
    quartiles = (
        statistics.quantiles(ordered, n=4, method="inclusive")
        if len(ordered) > 1
        else [ordered[0], ordered[0], ordered[0]]
    )
    return {
        "maximum": ordered[-1],
        "mean": round(statistics.fmean(ordered), 3),
        "median": statistics.median(ordered),
        "minimum": ordered[0],
        "p25": quartiles[0],
        "p75": quartiles[2],
        "populationStdDev": round(statistics.pstdev(ordered), 3),
    }


def architecture_observations(
    analysis: Analysis,
    cochange: dict[str, Any],
    baseline: dict[str, Any] | None,
    build_measurements: dict[str, Any] | None = None,
) -> dict[str, Any]:
    """Build non-blocking architecture observations and baseline deltas."""

    public_by_layer: Counter[str] = Counter()
    for module in analysis.modules:
        public_by_layer[module["layer"]] += module["publicDeclarationCount"]
    observations = {
        "buildMeasurements": build_measurements
        or {
            "cleanCompile": "not-captured",
            "incrementalCompile": "not-captured",
            "status": "not-captured",
        },
        "coChange": {
            "commitsConsidered": cochange["commitsConsidered"],
            "reportedPairCount": len(cochange["pairs"]),
            "status": cochange["status"],
        },
        "fileSizeDistribution": _distribution(
            [module["lineCount"] for module in analysis.modules]
        ),
        "moduleCount": len(analysis.modules),
        "oneConsumerModuleCount": sum(
            module["fanIn"] == 1 for module in analysis.modules
        ),
        "publicDeclarationsByLayer": dict(sorted(public_by_layer.items())),
        "reexportOnlyModuleCount": sum(
            module["onlyReexports"] for module in analysis.modules
        ),
        "fanInDistribution": _distribution(
            [module["fanIn"] for module in analysis.modules]
        ),
        "fanOutDistribution": _distribution(
            [module["fanOut"] for module in analysis.modules]
        ),
        "status": "diagnostic-only",
    }
    if baseline is None:
        observations["baselineComparison"] = {"status": "not-captured"}
        return observations
    baseline_observations = baseline.get("observations", {})
    observations["baselineComparison"] = {
        "moduleCountDelta": observations["moduleCount"]
        - baseline_observations.get("moduleCount", observations["moduleCount"]),
        "oneConsumerModuleCountDelta": observations["oneConsumerModuleCount"]
        - baseline_observations.get(
            "oneConsumerModuleCount",
            observations["oneConsumerModuleCount"],
        ),
        "reexportOnlyModuleCountDelta": observations["reexportOnlyModuleCount"]
        - baseline_observations.get(
            "reexportOnlyModuleCount",
            observations["reexportOnlyModuleCount"],
        ),
        "sourceTreeSha256": baseline.get("sourceTreeSha256"),
        "status": "diagnostic-only",
    }
    return observations


def _load_observation_baseline(root: Path) -> dict[str, Any] | None:
    path = root / "reports" / "recomposition" / "architecture-observations.json"
    if not path.is_file():
        return None
    return json.loads(path.read_text(encoding="utf-8"))


def _load_build_measurements(
    root: Path,
    analysis: Analysis,
) -> dict[str, Any] | None:
    path = root / "reports" / "architecture" / "build-measurements.json"
    if not path.is_file():
        return None
    payload = json.loads(path.read_text(encoding="utf-8"))
    if payload.get("sourceTreeSha256") != analysis.source_tree_sha256:
        return {
            "capturedSourceTreeSha256": payload.get("sourceTreeSha256"),
            "currentSourceTreeSha256": analysis.source_tree_sha256,
            "status": "stale-source-mismatch",
        }
    return payload


def _dot_graph(analysis: Analysis) -> str:
    lines = ["digraph doe_zig_architecture {", "  rankdir=LR;"]
    for module in analysis.modules:
        path = module["path"]
        layer = module["layer"]
        lines.append(f'  "{path}" [label="{path}\\n{layer}"];')
    for edge in analysis.edges:
        lines.append(f'  "{edge.source}" -> "{edge.target}";')
    lines.append("}")
    return "\n".join(lines) + "\n"


def build_reports(
    analysis: Analysis,
    config: dict[str, Any],
    config_path: Path,
    *,
    ast_inventory: dict[str, Any] | None = None,
    observation_baseline: dict[str, Any] | None = None,
    cochange: dict[str, Any] | None = None,
    build_measurements: dict[str, Any] | None = None,
) -> dict[str, str]:
    """Build every tracked architecture report as canonical text."""

    provenance = _provenance(analysis, config_path)
    cochange = cochange or {
        "commitsConsidered": 0,
        "commitsExcludedAsMassChange": 0,
        "commitsExcludedAsPureRename": 0,
        "historyHead": None,
        "minimumPairCount": 3,
        "pairs": [],
        "pairTruncationLimit": 1000,
        "status": "not-captured",
    }
    ast_inventory = ast_inventory or {
        "files": [],
        "status": "not-captured",
        "tool": "tools/source_ast_inventory.zig",
        "toolSha256": None,
    }
    duplicate_declarations = _duplicate_declarations(ast_inventory)
    reports: dict[str, Any] = {
        "ast-declarations.json": {
            **provenance,
            **ast_inventory,
            "schemaVersion": 1,
        },
        "co-change.json": {
            **provenance,
            **cochange,
            "schemaVersion": 1,
        },
        "cycles.json": {
            **provenance,
            "cycles": _cycle_records(analysis, config),
            "schemaVersion": 1,
            "staleExceptions": list(analysis.stale_cycle_exceptions),
        },
        "duplicate-declarations.json": {
            **provenance,
            **duplicate_declarations,
            "schemaVersion": 1,
        },
        "constant-families.json": {
            **provenance,
            "families": _constant_families(ast_inventory),
            "schemaVersion": 1,
            "status": ast_inventory["status"],
        },
        "forbidden-edges.json": {
            **provenance,
            "edges": list(analysis.forbidden_edges),
            "schemaVersion": 1,
            "staleExceptions": list(analysis.stale_dependency_exceptions),
        },
        "merge-candidates.json": {
            **provenance,
            "candidates": _merge_candidates(analysis),
            "schemaVersion": 1,
        },
        "module-decisions.json": {
            **provenance,
            **_module_decisions(analysis, config),
            "schemaVersion": 1,
        },
        "modules.json": {
            **provenance,
            "modules": list(analysis.modules),
            "schemaVersion": 1,
        },
        "observations.json": {
            **provenance,
            "observations": architecture_observations(
                analysis,
                cochange,
                observation_baseline,
                build_measurements,
            ),
            "schemaVersion": 1,
        },
        "repeated-literal-tables.json": {
            **provenance,
            "candidates": _repeated_literal_tables(ast_inventory),
            "schemaVersion": 1,
            "status": ast_inventory["status"],
        },
        "split-candidates.json": {
            **provenance,
            "candidates": _split_candidates(analysis),
            "schemaVersion": 1,
        },
        "unreachable-files.json": {
            **provenance,
            "files": _unreachable_records(analysis, config),
            "schemaVersion": 1,
            "staleExceptions": list(analysis.stale_reachability_exceptions),
        },
    }
    rendered = {name: canonical_json(payload) for name, payload in reports.items()}
    rendered["import-graph.dot"] = _dot_graph(analysis)
    return rendered


def write_or_check(
    reports: dict[str, str],
    output_root: Path,
    *,
    check: bool,
) -> list[str]:
    """Write reports or return deterministic freshness violations."""

    errors: list[str] = []
    if check:
        for name, expected in sorted(reports.items()):
            path = output_root / name
            if not path.is_file():
                errors.append(f"missing architecture report: {path}")
            elif path.read_text(encoding="utf-8") != expected:
                errors.append(f"stale architecture report: {path}")
        supplemental_reports = {"build-measurements.json"}
        unexpected = sorted(
            path.name
            for path in output_root.iterdir()
            if path.is_file()
            and path.name not in reports
            and path.name not in supplemental_reports
        ) if output_root.is_dir() else []
        for name in unexpected:
            errors.append(f"unexpected architecture report: {output_root / name}")
        return errors
    output_root.mkdir(parents=True, exist_ok=True)
    for name, content in sorted(reports.items()):
        (output_root / name).write_text(content, encoding="utf-8")
    return errors


def parse_args() -> argparse.Namespace:
    """Parse report-generator arguments."""

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=ROOT, help="runtime/zig root")
    parser.add_argument(
        "--config", type=Path, default=CONFIG_PATH, help="source-layout manifest"
    )
    parser.add_argument(
        "--output-root",
        type=Path,
        default=OUTPUT_ROOT,
        help="architecture report directory",
    )
    parser.add_argument(
        "--check", action="store_true", help="fail when tracked reports are stale"
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        config = load_manifest(args.config)
        analysis = analyze(args.root, config)
        if analysis.manifest_errors or analysis.unresolved_imports:
            for error in analysis.manifest_errors:
                print(error, file=sys.stderr)
            for unresolved in analysis.unresolved_imports:
                print(unresolved, file=sys.stderr)
            return 1
        reports = build_reports(
            analysis,
            config,
            args.config,
            ast_inventory=capture_ast_inventory(
                args.root,
                analysis,
                tool_root=args.root,
            ),
            observation_baseline=_load_observation_baseline(args.root),
            cochange=_cochange_report(args.root, analysis),
            build_measurements=_load_build_measurements(args.root, analysis),
        )
        final_analysis = analyze(args.root, config)
        if final_analysis.source_tree_sha256 != analysis.source_tree_sha256:
            raise RuntimeError(
                "Zig source tree changed during architecture report capture; "
                "retry from one coherent snapshot"
            )
        errors = write_or_check(
            reports,
            args.output_root,
            check=args.check,
        )
    except (FileNotFoundError, KeyError, OSError, RuntimeError, ValueError) as exc:
        print(f"architecture report generation failed: {exc}", file=sys.stderr)
        return 1
    if not errors:
        return 0
    for error in errors:
        print(error, file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
