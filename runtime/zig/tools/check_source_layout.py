from __future__ import annotations

import json
import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CONFIG_PATH = ROOT / "source-layout.json"
ZIG_IMPORT_RE = re.compile(r'@import\("([^"]+)"\)')


def relative_files(directory: Path) -> set[str]:
    return {path.name for path in directory.iterdir() if path.is_file()}


def main() -> int:
    config = json.loads(CONFIG_PATH.read_text())
    source_root = ROOT / config["sourceRoot"]
    errors: list[str] = []

    module_root = ROOT / config["moduleRoot"]
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
            errors.append(f"unexpected top-level source owners: {', '.join(unexpected)}")

    allowed_root_files = set(config["allowedRootFiles"])
    actual_root_files = relative_files(source_root)
    if actual_root_files != allowed_root_files:
        missing = sorted(allowed_root_files - actual_root_files)
        unexpected = sorted(actual_root_files - allowed_root_files)
        if missing:
            errors.append(f"missing source-root files: {', '.join(missing)}")
        if unexpected:
            errors.append(f"source-root files must move to an owner: {', '.join(unexpected)}")

    wgsl_root = source_root / "compiler" / "wgsl"
    wgsl_directories = {path.name for path in wgsl_root.iterdir() if path.is_dir()}
    expected_wgsl_directories = set(config["wgslStageDirectories"])
    if wgsl_directories != expected_wgsl_directories:
        errors.append(
            "WGSL stage directories differ: "
            f"expected={sorted(expected_wgsl_directories)} actual={sorted(wgsl_directories)}"
        )
    wgsl_root_files = relative_files(wgsl_root)
    expected_wgsl_root_files = set(config["wgslRootFiles"])
    if wgsl_root_files != expected_wgsl_root_files:
        errors.append(
            "WGSL root files differ: "
            f"expected={sorted(expected_wgsl_root_files)} actual={sorted(wgsl_root_files)}"
        )

    native_root = source_root / "native"
    native_root_files = relative_files(native_root)
    expected_native_root_files = set(config["nativeRootFiles"])
    if native_root_files != expected_native_root_files:
        errors.append(
            "native root files differ: "
            f"expected={sorted(expected_native_root_files)} actual={sorted(native_root_files)}"
        )

    compatibility_facades = {
        (ROOT / path).resolve() for path in config["compatibilityFacades"]
    }
    actual_facades = {
        path.resolve() for path in (source_root / "compat").rglob("*.zig")
    }
    if actual_facades != compatibility_facades:
        errors.append(
            "compatibility facade set differs: "
            f"expected={sorted(str(path.relative_to(ROOT)) for path in compatibility_facades)} "
            f"actual={sorted(str(path.relative_to(ROOT)) for path in actual_facades)}"
        )

    compat_root = (source_root / "compat").resolve()
    for path in sorted(source_root.rglob("*.zig")):
        resolved_path = path.resolve()
        if resolved_path == compat_root or compat_root in resolved_path.parents:
            continue
        for line_number, line in enumerate(path.read_text().splitlines(), start=1):
            for match in ZIG_IMPORT_RE.finditer(line):
                target = (path.parent / match.group(1)).resolve(strict=False)
                if match.group(1).startswith(".") and not (
                    target == source_root.resolve()
                    or source_root.resolve() in target.parents
                ):
                    errors.append(
                        f"{path.relative_to(ROOT)}:{line_number}: "
                        f"production import leaves src/: {match.group(1)}"
                    )
                if target == compat_root or compat_root in target.parents:
                    errors.append(
                        f"{path.relative_to(ROOT)}:{line_number}: "
                        f"implementation imports compatibility facade {match.group(1)}"
                    )

    for relative_root in config["repositoryOnlyZigRoots"]:
        repository_root = ROOT / relative_root
        if not repository_root.is_dir():
            errors.append(f"missing repository-only Zig root: {relative_root}")
            continue
        for path in sorted(repository_root.rglob("*.zig")):
            for line_number, line in enumerate(path.read_text().splitlines(), start=1):
                for match in ZIG_IMPORT_RE.finditer(line):
                    if not match.group(1).startswith("."):
                        continue
                    target = (path.parent / match.group(1)).resolve(strict=False)
                    if target == source_root.resolve() or source_root.resolve() in target.parents:
                        errors.append(
                            f"{path.relative_to(ROOT)}:{line_number}: repository-only code "
                            f"must import production source through @import(\"doe\")"
                        )

    if not errors:
        return 0
    print("source layout violations detected:", file=sys.stderr)
    for error in errors:
        print(error, file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
