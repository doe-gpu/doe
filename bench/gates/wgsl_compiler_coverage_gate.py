#!/usr/bin/env python3
"""Fail closed when the generated WGSL compiler coverage view is stale or partial."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

import jsonschema


REPO_ROOT = Path(__file__).resolve().parents[2]
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from bench.lib.bench_utils import load_json_object
from bench.tools import generate_wgsl_compiler_coverage as coverage


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--ledger",
        default="bench/out/qualification/gemma270m-amd/wgsl-compiler-coverage.json",
    )
    parser.add_argument(
        "--schema",
        default="config/wgsl-compiler-coverage-ledger.schema.json",
    )
    parser.add_argument(
        "--support-view",
        default="runtime/zig/src/compiler/wgsl/WGSL_COVERAGE.md",
    )
    return parser.parse_args()


def artifact_failure(reference: Any, label: str) -> str | None:
    if not isinstance(reference, dict):
        return f"{label} reference is missing"
    raw_path = reference.get("path")
    expected_hash = reference.get("sha256")
    if not isinstance(raw_path, str) or not isinstance(expected_hash, str):
        return f"{label} reference is invalid"
    path = coverage.resolve_path(raw_path)
    if not path.is_file():
        return f"{label} is missing: {raw_path}"
    actual_hash = coverage.sha256_file(path)
    if actual_hash != expected_hash:
        return f"{label} hash changed: {raw_path}"
    return None


def validate_schema(payload: dict[str, Any], schema: dict[str, Any]) -> list[str]:
    return [
        f"{'.'.join(str(part) for part in error.absolute_path) or '<root>'}: {error.message}"
        for error in sorted(
            jsonschema.Draft202012Validator(schema).iter_errors(payload),
            key=lambda error: tuple(str(part) for part in error.absolute_path),
        )
    ]


def evaluate(ledger: dict[str, Any], support_view: Path) -> list[str]:
    failures: list[str] = []
    if ledger.get("supportStatus") != "full" or ledger.get("fullSupportAllowed") is not True:
        failures.append("coverage ledger does not allow Full support")
    summary = ledger.get("summary")
    if not isinstance(summary, dict) or summary.get("failCount") != 0:
        failures.append("coverage ledger contains failing checks")
    blockers = ledger.get("blockers")
    if not isinstance(blockers, list) or blockers:
        failures.append("coverage ledger contains blockers")

    references: list[tuple[Any, str]] = [(ledger.get("sourcePlan"), "source plan")]
    spirv = ledger.get("spirvValidation")
    if isinstance(spirv, dict):
        references.extend([
            (spirv.get("report"), "SPIR-V report"),
            (spirv.get("emitter"), "SPIR-V emitter"),
            (spirv.get("validator"), "SPIR-V validator"),
        ])
    for row in ledger.get("admittedShaders", []):
        if isinstance(row, dict):
            references.extend([
                (row.get("source"), f"admitted shader {row.get('id', '<unknown>')}"),
                (row.get("artifact"), f"SPIR-V artifact {row.get('id', '<unknown>')}"),
            ])
    for row in ledger.get("ctsReports", []):
        if isinstance(row, dict):
            references.append((row.get("report"), f"CTS report {row.get('lane', '<unknown>')}"))
    for reference, label in references:
        failure = artifact_failure(reference, label)
        if failure:
            failures.append(failure)

    for row in ledger.get("workarounds", []):
        if not isinstance(row, dict):
            continue
        matches = coverage.find_workaround_matches(
            str(row.get("forbiddenPattern", "")),
            list(row.get("searchPaths", [])),
        )
        if matches:
            failures.append(
                f"workaround {row.get('id', '<unknown>')} returned: " + ", ".join(matches)
            )

    expected_view = coverage.markdown(ledger)
    if not support_view.is_file():
        failures.append(f"generated support view is missing: {coverage.display_path(support_view)}")
    elif support_view.read_text(encoding="utf-8") != expected_view:
        failures.append(f"generated support view is stale: {coverage.display_path(support_view)}")
    return failures


def main() -> int:
    args = parse_args()
    try:
        ledger = load_json_object(coverage.resolve_path(args.ledger))
        schema = load_json_object(coverage.resolve_path(args.schema))
    except (OSError, UnicodeError, json.JSONDecodeError, ValueError) as exc:
        print(f"FAIL: WGSL compiler coverage gate: {exc}")
        return 1
    failures = validate_schema(ledger, schema)
    failures.extend(evaluate(ledger, coverage.resolve_path(args.support_view)))
    if failures:
        print("FAIL: WGSL compiler coverage gate")
        for failure in failures:
            print(f"  {failure}")
        return 1
    print(
        "PASS: WGSL compiler coverage gate "
        f"({ledger['summary']['passCount']}/{ledger['summary']['checkCount']} checks)"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
