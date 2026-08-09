"""Generate Doe Zig test-suite roots from the owned test inventory."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
REPOSITORY_ROOT = ROOT.parents[1]
INVENTORY_PATH = REPOSITORY_ROOT / "config" / "zig-test-inventory.json"
SUPPORTED_PLATFORMS = {"linux", "macos", "windows"}
TEST_KINDS = {
    "abi",
    "backend",
    "characterization",
    "cross-backend",
    "golden",
    "inline",
    "integration",
}


def _identifier(prefix: str, value: str) -> str:
    stem = re.sub(r"[^A-Za-z0-9_]", "_", value)
    digest = hashlib.sha256(value.encode("utf-8")).hexdigest()[:8]
    return f"{prefix}_{stem}_{digest}"


def _validate(inventory: dict[str, Any]) -> list[str]:
    errors: list[str] = []
    if inventory.get("schemaVersion") != 2:
        errors.append("zig test inventory schemaVersion must be 2")
    suites = inventory.get("suites")
    if not isinstance(suites, dict) or not suites:
        return errors + ["zig test inventory suites must be a non-empty object"]
    outputs: set[str] = set()
    owned_test_files: set[str] = set()
    for suite_name, suite in sorted(suites.items()):
        output = suite.get("output")
        if not isinstance(output, str) or not output.endswith(".zig"):
            errors.append(f"suite {suite_name} has an invalid output")
        elif output in outputs:
            errors.append(f"duplicate suite output: {output}")
        else:
            outputs.add(output)
        includes = suite.get("includes", [])
        for included in includes:
            if included not in suites:
                errors.append(f"suite {suite_name} includes unknown suite {included}")
            elif included == suite_name:
                errors.append(f"suite {suite_name} includes itself")
        seen: set[str] = set()
        for entry in suite.get("entries", []):
            path = entry.get("path")
            if not isinstance(path, str) or not path.endswith(".zig"):
                errors.append(f"suite {suite_name} has an invalid entry path")
                continue
            if path in seen:
                errors.append(f"suite {suite_name} repeats entry {path}")
            seen.add(path)
            if not (ROOT / path).is_file():
                errors.append(f"suite {suite_name} entry does not exist: {path}")
            kind = entry.get("kind")
            if kind not in TEST_KINDS:
                errors.append(f"suite {suite_name} entry {path} has invalid kind: {kind}")
            elif path.startswith("src/") and kind != "inline":
                errors.append(f"source-local test entry must have kind inline: {path}")
            elif path.startswith("tests/") and kind == "inline":
                errors.append(f"external test entry may not have kind inline: {path}")
            if path.startswith("tests/"):
                owned_test_files.add(path)
            platforms = set(entry.get("platforms", []))
            unknown = platforms - SUPPORTED_PLATFORMS
            if unknown:
                errors.append(
                    f"suite {suite_name} entry {path} has unknown platforms: "
                    + ", ".join(sorted(unknown))
                )
    support_entries = inventory.get("supportFiles", [])
    support_files = [entry.get("path") for entry in support_entries]
    if len(support_files) != len(set(support_files)):
        errors.append("zig test inventory repeats support files")
    for entry in support_entries:
        path = entry.get("path")
        if not isinstance(path, str):
            errors.append("test support entry has an invalid path")
            continue
        if not (ROOT / path).is_file():
            errors.append(f"test support file does not exist: {path}")
        if path in owned_test_files:
            errors.append(f"test file is both a suite root and support file: {path}")
        if entry.get("kind") not in {"domain-fixture", "test-shard"}:
            errors.append(f"test support file has invalid kind: {path}")
        consumers = entry.get("consumers")
        if not isinstance(consumers, list) or not consumers:
            errors.append(f"test support file has no declared consumers: {path}")
            continue
        for consumer in consumers:
            consumer_path = ROOT / consumer
            if not consumer_path.is_file():
                errors.append(f"test support consumer does not exist: {consumer}")
                continue
            if Path(path).name not in consumer_path.read_text(encoding="utf-8"):
                errors.append(f"declared consumer {consumer} does not import {path}")
    discovered = {
        path.relative_to(ROOT).as_posix()
        for path in (ROOT / "tests").rglob("*.zig")
    }
    classified = owned_test_files | set(support_files)
    for path in sorted(discovered - classified):
        errors.append(f"unowned Zig test file: {path}")
    for path in sorted(classified - discovered):
        errors.append(f"inventory path is not under tests/: {path}")
    return errors


def _render_suite(name: str, suite: dict[str, Any], suites: dict[str, Any]) -> str:
    lines = [
        "// Generated by tools/generate_test_suites.py from config/zig-test-inventory.json.",
        "// Do not edit this file directly.",
    ]
    needs_builtin = any(entry.get("platforms") for entry in suite.get("entries", []))
    if needs_builtin:
        lines.append('const builtin = @import("builtin");')
    aliases: list[str] = []
    for included in suite.get("includes", []):
        alias = _identifier("suite", included)
        output = suites[included]["output"]
        lines.append(f'const {alias} = @import("{output}");')
        aliases.append(alias)
    for entry in suite.get("entries", []):
        path = entry["path"]
        alias = _identifier("test", path)
        platforms = entry.get("platforms", [])
        if platforms:
            condition = " or ".join(
                f"builtin.os.tag == .{platform}" for platform in platforms
            )
            lines.append(
                f'const {alias} = if ({condition}) @import("{path}") else struct {{}};'
            )
        else:
            lines.append(f'const {alias} = @import("{path}");')
        aliases.append(alias)
    lines.extend(["", "comptime {"])
    lines.extend(f"    _ = {alias};" for alias in aliases)
    lines.extend(["}", ""])
    return "\n".join(lines)


def generate(inventory: dict[str, Any]) -> dict[Path, str]:
    suites = inventory["suites"]
    return {
        ROOT / suite["output"]: _render_suite(name, suite, suites)
        for name, suite in sorted(suites.items())
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        inventory = json.loads(INVENTORY_PATH.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        print(f"could not load Zig test inventory: {exc}", file=sys.stderr)
        return 1
    errors = _validate(inventory)
    if errors:
        for error in errors:
            print(error, file=sys.stderr)
        return 1
    outputs = generate(inventory)
    if args.check:
        stale = [path for path, content in outputs.items() if not path.is_file() or path.read_text(encoding="utf-8") != content]
        for path in stale:
            print(f"stale generated Zig test suite: {path}", file=sys.stderr)
        return 1 if stale else 0
    for path, content in outputs.items():
        path.write_text(content, encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
