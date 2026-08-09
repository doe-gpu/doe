"""Validate Doe Zig source ownership and architecture boundaries."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path
from typing import Any

from generate_source_layout_docs import render_source_map
from source_architecture import (
    Analysis,
    ZIG_IMPORT_RE,
    analyze,
    exception_for_cycle,
    load_manifest,
    reachability_exception,
)


ROOT = Path(__file__).resolve().parents[1]
CONFIG_PATH = ROOT / "source-layout.json"


def relative_files(directory: Path) -> set[str]:
    """Return direct child file names for a required layout directory."""

    return {path.name for path in directory.iterdir() if path.is_file()}


def _check_directory_inventory(
    root: Path,
    config: dict[str, Any],
    errors: list[str],
    check_generated_readme: bool,
) -> None:
    source_root = root / config["sourceRoot"]
    if check_generated_readme:
        generated_readme = source_root / "README.md"
        expected_readme = render_source_map(config)
        if generated_readme.read_text(encoding="utf-8") != expected_readme:
            errors.append(
                "src/README.md is stale; run "
                "python3 tools/generate_source_layout_docs.py --write"
            )
    module_root = root / config["moduleRoot"]
    if not module_root.is_file():
        errors.append(f"missing production module root: {config['moduleRoot']}")
    expected_owners = set(config["topLevelOwners"])
    actual_owners = {path.name for path in source_root.iterdir() if path.is_dir()}
    if actual_owners != expected_owners:
        missing = sorted(expected_owners - actual_owners)
        unexpected = sorted(actual_owners - expected_owners)
        if missing:
            errors.append(f"missing top-level source owners: {', '.join(missing)}")
        if unexpected:
            errors.append(
                f"unexpected top-level source owners: {', '.join(unexpected)}"
            )
    allowed_root_files = set(config["allowedRootFiles"])
    actual_root_files = relative_files(source_root)
    if actual_root_files != allowed_root_files:
        missing = sorted(allowed_root_files - actual_root_files)
        unexpected = sorted(actual_root_files - allowed_root_files)
        if missing:
            errors.append(f"missing source-root files: {', '.join(missing)}")
        if unexpected:
            errors.append(
                f"source-root files must move to an owner: {', '.join(unexpected)}"
            )
    wgsl_root = source_root / "compiler" / "wgsl"
    wgsl_directories = {path.name for path in wgsl_root.iterdir() if path.is_dir()}
    expected_wgsl_directories = set(config["wgslStageDirectories"])
    if wgsl_directories != expected_wgsl_directories:
        errors.append(
            "WGSL stage directories differ: "
            f"expected={sorted(expected_wgsl_directories)} "
            f"actual={sorted(wgsl_directories)}"
        )
    wgsl_root_files = relative_files(wgsl_root)
    expected_wgsl_root_files = set(config["wgslRootFiles"])
    if wgsl_root_files != expected_wgsl_root_files:
        errors.append(
            "WGSL root files differ: "
            f"expected={sorted(expected_wgsl_root_files)} "
            f"actual={sorted(wgsl_root_files)}"
        )
    native_root = source_root / "native"
    native_root_files = relative_files(native_root)
    expected_native_root_files = set(config["nativeRootFiles"])
    if native_root_files != expected_native_root_files:
        errors.append(
            "native root files differ: "
            f"expected={sorted(expected_native_root_files)} "
            f"actual={sorted(native_root_files)}"
        )
    expected_facades = {
        (root / path).resolve() for path in config["compatibilityFacades"]
    }
    actual_facades = {
        path.resolve() for path in (source_root / "compat").rglob("*.zig")
    }
    if actual_facades != expected_facades:
        errors.append(
            "compatibility facade set differs: "
            "expected="
            f"{sorted(str(path.relative_to(root)) for path in expected_facades)} "
            f"actual={sorted(str(path.relative_to(root)) for path in actual_facades)}"
        )
    facade_contracts = config["architecture"]["compatibilityFacadeContracts"]
    for facade_path, contract in facade_contracts.items():
        test_path = root / contract["test"]
        if not test_path.is_file():
            errors.append(
                f"compatibility facade test does not exist: {contract['test']}"
            )
            continue
        imported_paths: set[Path] = set()
        for match in ZIG_IMPORT_RE.finditer(test_path.read_text(encoding="utf-8")):
            import_text = match.group(1)
            if import_text.startswith(".") or import_text.endswith(".zig"):
                imported_paths.add(
                    (test_path.parent / import_text).resolve(strict=False)
                )
        if (root / facade_path).resolve() not in imported_paths:
            errors.append(
                f"compatibility facade test {contract['test']} does not directly "
                f"exercise {facade_path}"
            )


def _check_repository_only_imports(
    root: Path,
    config: dict[str, Any],
    errors: list[str],
) -> None:
    source_root = (root / config["sourceRoot"]).resolve()
    for relative_root in config["repositoryOnlyZigRoots"]:
        repository_root = root / relative_root
        if not repository_root.is_dir():
            errors.append(f"missing repository-only Zig root: {relative_root}")
            continue
        for path in sorted(repository_root.rglob("*.zig")):
            for line_number, line in enumerate(
                path.read_text(encoding="utf-8").splitlines(), start=1
            ):
                for match in ZIG_IMPORT_RE.finditer(line):
                    import_text = match.group(1)
                    if not (
                        import_text.startswith(".") or import_text.endswith(".zig")
                    ):
                        continue
                    target = (path.parent / import_text).resolve(strict=False)
                    if target == source_root or source_root in target.parents:
                        errors.append(
                            f"{path.relative_to(root)}:{line_number}: repository-only "
                            "code must import production source through "
                            '@import("doe")'
                        )


def architecture_errors(
    analysis: Analysis,
    config: dict[str, Any],
) -> list[str]:
    """Return blocking errors derived from one architecture analysis."""

    errors: list[str] = []
    errors.extend(analysis.manifest_errors)
    if analysis.manifest_errors:
        return errors
    module_by_path = {module["path"]: module for module in analysis.modules}
    for registry_name, contract in sorted(
        config["architecture"].get("canonicalContracts", {}).items()
    ):
        path = contract["path"]
        module = module_by_path.get(path)
        if module is None:
            errors.append(f"canonical {registry_name} contract is missing: {path}")
        else:
            declarations = {
                declaration["name"] for declaration in module["publicDeclarations"]
            }
            missing_declarations = sorted(
                set(contract["requiredPublicDeclarations"]) - declarations
            )
            if missing_declarations:
                errors.append(
                    f"canonical {registry_name} contract {path} is incomplete: "
                    + ", ".join(missing_declarations)
                )
        for forbidden_path in contract.get("forbiddenLegacyPaths", []):
            if forbidden_path in module_by_path:
                errors.append(
                    f"legacy {registry_name} contract must not exist: {forbidden_path}"
                )
    for unresolved in analysis.unresolved_imports:
        target = f" -> {unresolved['target']}" if "target" in unresolved else ""
        errors.append(
            f"{unresolved['source']}:{unresolved['line']}: "
            f"{unresolved['reason']}: {unresolved['import']}{target}"
        )
    for edge in analysis.forbidden_edges:
        if edge["allowedByException"]:
            continue
        errors.append(
            f"{edge['source']}:{edge['line']}: {edge['reason']}: "
            f"{edge['sourceLayer']} -> {edge['targetLayer']} via {edge['target']}"
        )
    if analysis.stale_dependency_exceptions:
        for entry in analysis.stale_dependency_exceptions:
            errors.append(
                "stale dependency exception: "
                f"{entry['source']} -> {entry['target']}"
            )
    for entry in analysis.stale_cycle_exceptions:
        errors.append(
            "stale cycle exception: " + ", ".join(sorted(entry["members"]))
        )
    for entry in analysis.stale_reachability_exceptions:
        errors.append(f"stale reachability exception: {entry['path']}")
    enforcement = config["architecture"]["enforcement"]
    if enforcement["cycles"] == "error":
        for cycle in analysis.cycles:
            if exception_for_cycle(cycle, config) is None:
                errors.append("unapproved import cycle: " + " -> ".join(cycle))
    if enforcement["unreachableModules"] == "error":
        for path in analysis.unreachable:
            if reachability_exception(path, config) is None:
                errors.append(f"unapproved unreachable production module: {path}")
    line_policy = config["architecture"]["linePolicy"]
    justifications = {
        entry["path"]: entry
        for entry in config["architecture"]["cohesiveModuleJustifications"]
    }
    for module in analysis.modules:
        if "generated" in module["roles"]:
            continue
        line_count = module["lineCount"]
        if line_policy["mode"] == "transition":
            if line_count > line_policy["transitionMaximumLines"]:
                errors.append(
                    f"{module['path']}: {line_count} lines exceeds transition maximum "
                    f"{line_policy['transitionMaximumLines']}"
                )
            continue
        if line_count > line_policy["futureHardMaximumLines"]:
            errors.append(
                f"{module['path']}: {line_count} lines exceeds handwritten "
                "hard maximum "
                f"{line_policy['futureHardMaximumLines']}"
            )
        elif (
            line_count > line_policy["futureJustificationAboveLines"]
            and module["path"] not in justifications
        ):
            errors.append(
                f"{module['path']}: {line_count} lines requires a cohesive-module "
                "justification"
            )
    return errors


def check_layout(
    root: Path,
    config: dict[str, Any],
    *,
    check_generated_readme: bool = True,
) -> tuple[list[str], Analysis]:
    """Return all layout violations and the underlying architecture analysis."""

    root = root.resolve()
    errors: list[str] = []
    _check_directory_inventory(root, config, errors, check_generated_readme)
    _check_repository_only_imports(root, config, errors)
    analysis = analyze(root, config)
    errors.extend(architecture_errors(analysis, config))
    return errors, analysis


def parse_args() -> argparse.Namespace:
    """Parse source-layout checker arguments."""

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--root",
        type=Path,
        default=ROOT,
        help="runtime/zig root containing src/ and source-layout.json",
    )
    parser.add_argument(
        "--config",
        type=Path,
        default=CONFIG_PATH,
        help="version-2 source-layout manifest",
    )
    parser.add_argument(
        "--skip-generated-readme",
        action="store_true",
        help="skip the generated src/README.md freshness check",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        config = load_manifest(args.config)
        errors, _ = check_layout(
            args.root,
            config,
            check_generated_readme=not args.skip_generated_readme,
        )
    except (FileNotFoundError, KeyError, OSError, ValueError) as exc:
        print(f"source layout validation failed: {exc}", file=sys.stderr)
        return 1
    if not errors:
        return 0
    print("source layout violations detected:", file=sys.stderr)
    for error in errors:
        print(error, file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
