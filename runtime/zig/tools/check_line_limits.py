from __future__ import annotations

import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
ZIG_SRC = ROOT / "zig" / "src"
LINE_LIMIT = 999
ALLOWLIST: dict[str, str] = {}


def count_lines(path: Path) -> int:
    with path.open("r", encoding="utf-8") as handle:
        return sum(1 for _ in handle)


def main() -> int:
    errors: list[str] = []
    allowlisted: list[str] = []

    for path in sorted(ZIG_SRC.rglob("*.zig")):
        line_count = count_lines(path)
        if line_count <= LINE_LIMIT:
            continue
        rel_path = path.relative_to(ZIG_SRC).as_posix()
        if rel_path in ALLOWLIST:
            allowlisted.append(
                f"{path}: {line_count} lines exceeds {LINE_LIMIT} (allowlisted: {ALLOWLIST[rel_path]})"
            )
            continue
        errors.append(f"{path}: {line_count} lines exceeds {LINE_LIMIT}")

    if allowlisted:
        print("allowlisted Zig source files still exceed the line limit:", file=sys.stderr)
        for entry in allowlisted:
            print(entry, file=sys.stderr)

    if not errors:
        return 0

    print("Zig source line-limit violations detected:", file=sys.stderr)
    for entry in errors:
        print(entry, file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
