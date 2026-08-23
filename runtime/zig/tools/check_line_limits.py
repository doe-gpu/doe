from __future__ import annotations

import sys
from pathlib import Path
from typing import Any

from source_architecture import load_manifest, matches_glob


ROOT = Path(__file__).resolve().parents[1]
ZIG_SRC = ROOT / "src"
MANIFEST = ROOT / "source-layout.json"


def count_lines(path: Path) -> int:
    with path.open("r", encoding="utf-8") as handle:
        return sum(1 for _ in handle)


def evaluate_line_policy(
    source_root: Path,
    config: dict[str, Any],
) -> tuple[list[str], list[str]]:
    """Return blocking errors and advisory reviews for handwritten Zig files."""

    architecture = config["architecture"]
    policy = architecture["linePolicy"]
    generated_contract = architecture["specialRoles"]["generated"]
    generated_globs = generated_contract["globs"]
    if not isinstance(generated_globs, list) or not all(
        isinstance(pattern, str) and pattern for pattern in generated_globs
    ):
        raise ValueError(
            "architecture.specialRoles.generated.globs must be a string list"
        )
    justifications = {
        entry["path"]: entry
        for entry in architecture["cohesiveModuleJustifications"]
    }
    errors: list[str] = []
    advisories: list[str] = []

    for path in sorted(source_root.rglob("*.zig")):
        manifest_path = path.relative_to(source_root.parent).as_posix()
        if any(matches_glob(manifest_path, glob) for glob in generated_globs):
            continue
        line_count = count_lines(path)
        if policy["mode"] == "transition":
            if line_count > policy["transitionMaximumLines"]:
                errors.append(
                    f"{manifest_path}: {line_count} lines exceeds transition maximum "
                    f"{policy['transitionMaximumLines']}"
                )
            continue
        if line_count > policy["futureHardMaximumLines"]:
            errors.append(
                f"{manifest_path}: {line_count} lines exceeds handwritten hard maximum "
                f"{policy['futureHardMaximumLines']}"
            )
        elif (
            line_count > policy["futureJustificationAboveLines"]
            and manifest_path not in justifications
        ):
            errors.append(
                f"{manifest_path}: {line_count} lines requires a cohesive-module justification"
            )
        elif line_count > policy["advisoryReviewLines"]:
            advisories.append(
                f"{manifest_path}: {line_count} lines exceeds advisory review signal "
                f"{policy['advisoryReviewLines']}"
            )

    return errors, advisories


def main() -> int:
    try:
        config = load_manifest(MANIFEST)
        errors, advisories = evaluate_line_policy(ZIG_SRC, config)
    except (KeyError, OSError, TypeError, ValueError) as exc:
        print(f"Zig source line-policy setup failed: {exc}", file=sys.stderr)
        return 1

    if advisories:
        print("Zig source architecture review signals:", file=sys.stderr)
        for entry in advisories:
            print(entry, file=sys.stderr)

    if not errors:
        return 0

    print("Zig source architecture line-policy violations detected:", file=sys.stderr)
    for entry in errors:
        print(entry, file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
