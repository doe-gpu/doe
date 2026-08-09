from __future__ import annotations

import fnmatch
import json
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
ZIG_SRC = ROOT / "src"
MANIFEST = ROOT / "source-layout.json"


def count_lines(path: Path) -> int:
    with path.open("r", encoding="utf-8") as handle:
        return sum(1 for _ in handle)


def main() -> int:
    config = json.loads(MANIFEST.read_text(encoding="utf-8"))
    architecture = config["architecture"]
    policy = architecture["linePolicy"]
    generated_globs = architecture["specialRoles"]["generated"]
    justifications = {
        entry["path"]: entry
        for entry in architecture["cohesiveModuleJustifications"]
    }
    errors: list[str] = []
    advisories: list[str] = []

    for path in sorted(ZIG_SRC.rglob("*.zig")):
        manifest_path = path.relative_to(ROOT).as_posix()
        if any(fnmatch.fnmatchcase(manifest_path, glob) for glob in generated_globs):
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
