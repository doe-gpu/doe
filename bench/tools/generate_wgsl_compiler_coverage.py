#!/usr/bin/env python3
"""Generate the admitted AMD Vulkan WGSL coverage ledger and Markdown view."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import jsonschema

REPO_ROOT = Path(__file__).resolve().parents[2]
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from bench.lib.bench_utils import load_json_object, write_json_object


DEFAULT_PLAN = Path("config/wgsl-compiler-coverage-plan.json")
DEFAULT_PLAN_SCHEMA = Path("config/wgsl-compiler-coverage-plan.schema.json")
DEFAULT_LEDGER_SCHEMA = Path("config/wgsl-compiler-coverage-ledger.schema.json")
DEFAULT_OUT_JSON = Path("bench/out/qualification/gemma270m-amd/wgsl-compiler-coverage.json")
DEFAULT_OUT_MD = Path("bench/out/qualification/gemma270m-amd/wgsl-compiler-coverage.md")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--plan", default=str(DEFAULT_PLAN))
    parser.add_argument("--plan-schema", default=str(DEFAULT_PLAN_SCHEMA))
    parser.add_argument("--ledger-schema", default=str(DEFAULT_LEDGER_SCHEMA))
    parser.add_argument("--out-json", default=str(DEFAULT_OUT_JSON))
    parser.add_argument("--out-md", default=str(DEFAULT_OUT_MD))
    return parser.parse_args()


def resolve_path(raw: str | Path) -> Path:
    path = Path(raw)
    return path.resolve() if path.is_absolute() else (REPO_ROOT / path).resolve()


def display_path(path: Path) -> str:
    resolved = path.resolve()
    try:
        resolved.relative_to(REPO_ROOT.parent)
    except ValueError:
        return resolved.as_posix()
    return Path(os.path.relpath(resolved, REPO_ROOT)).as_posix()


def sha256_file(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def validate_payload(payload: dict[str, Any], schema: dict[str, Any], label: str) -> None:
    errors = sorted(
        jsonschema.Draft202012Validator(schema).iter_errors(payload),
        key=lambda error: tuple(str(part) for part in error.absolute_path),
    )
    if not errors:
        return
    details = "; ".join(
        f"{'.'.join(str(part) for part in error.absolute_path) or '<root>'}: {error.message}"
        for error in errors
    )
    raise ValueError(f"{label} schema validation failed: {details}")


def command_result(entry: dict[str, Any]) -> dict[str, Any]:
    workdir = resolve_path(entry["workdir"])
    command = list(entry["command"])
    try:
        run = subprocess.run(
            command,
            cwd=workdir,
            text=True,
            capture_output=True,
            check=False,
        )
        passed = run.returncode == 0
        return {
            "id": entry["id"],
            "workdir": display_path(workdir),
            "command": command,
            "exitCode": run.returncode,
            "stdoutTail": run.stdout.splitlines()[-40:],
            "stderrTail": run.stderr.splitlines()[-40:],
            "pass": passed,
            "reason": "command passed" if passed else f"command exited with code {run.returncode}",
        }
    except OSError as exc:
        return {
            "id": entry["id"],
            "workdir": display_path(workdir),
            "command": command,
            "exitCode": 127,
            "stdoutTail": [],
            "stderrTail": [str(exc)],
            "pass": False,
            "reason": f"command could not start: {exc}",
        }


def spirv_report_pass(payload: dict[str, Any]) -> tuple[bool, str]:
    discovered = payload.get("discovered")
    if not isinstance(discovered, dict):
        return False, "SPIR-V report is missing discovered-WGSL coverage"
    failed = payload.get("failed")
    if failed != 0:
        return False, f"SPIR-V report contains {failed!r} failed validation(s)"
    required_zero = ("validationFailed", "emitSkipped", "subgroupSkipped")
    nonzero = [field for field in required_zero if discovered.get(field) != 0]
    if nonzero:
        return False, "SPIR-V discovered coverage is incomplete: " + ", ".join(nonzero)
    if not isinstance(discovered.get("validated"), int) or discovered["validated"] < 1:
        return False, "SPIR-V report contains no discovered WGSL validation"
    if not isinstance(discovered.get("subgroupValidated"), int) or discovered["subgroupValidated"] < 1:
        return False, "SPIR-V report contains no subgroup WGSL validation"
    return True, (
        f"{payload.get('passed', 0)} SPIR-V artifacts passed; "
        f"{discovered['validated']} discovered WGSL and "
        f"{discovered['subgroupValidated']} subgroup shaders validated"
    )


def validate_spirv_report(entry: dict[str, Any]) -> dict[str, Any]:
    report_path = resolve_path(entry["reportPath"])
    emitter_path = resolve_path(entry["emitterPath"])
    validator_path = resolve_path(entry["validatorPath"])
    expected_hash = entry["reportSha256"]
    tools = {
        "emitter": {
            "path": display_path(emitter_path),
            "sha256": sha256_file(emitter_path) if emitter_path.is_file() else "0" * 64,
        },
        "validator": {
            "path": display_path(validator_path),
            "sha256": sha256_file(validator_path) if validator_path.is_file() else "0" * 64,
        },
    }
    if not emitter_path.is_file() or not validator_path.is_file():
        return {
            "pass": False,
            "reason": "SPIR-V emitter or validator is missing",
            "report": {"path": display_path(report_path), "sha256": expected_hash},
            **tools,
        }
    if not report_path.is_file():
        return {
            "pass": False,
            "reason": "SPIR-V validation report is missing",
            "report": {"path": display_path(report_path), "sha256": expected_hash},
            **tools,
        }
    actual_hash = sha256_file(report_path)
    if actual_hash != expected_hash:
        return {
            "pass": False,
            "reason": "SPIR-V validation report hash does not match the plan",
            "report": {"path": display_path(report_path), "sha256": actual_hash},
            **tools,
        }
    payload = load_json_object(report_path)
    passed, reason = spirv_report_pass(payload)
    return {
        "pass": passed,
        "reason": reason,
        "report": {"path": display_path(report_path), "sha256": actual_hash},
        **tools,
        "validated": payload.get("passed", 0),
        "failed": payload.get("failed", 0),
        "discovered": payload.get("discovered", {}),
    }


def validate_admitted_shader(
    entry: dict[str, Any],
    validator: dict[str, Any],
    artifact_dir: Path,
) -> dict[str, Any]:
    source = resolve_path(entry["path"])
    source_ref = {"path": display_path(source), "sha256": entry["sha256"]}
    base = {"id": entry["id"], "source": source_ref}
    if not source.is_file():
        return {**base, "pass": False, "reason": "admitted shader source is missing"}
    actual_hash = sha256_file(source)
    source_ref["sha256"] = actual_hash
    if actual_hash != entry["sha256"]:
        return {**base, "pass": False, "reason": "admitted shader source hash changed"}

    emitter = resolve_path(validator["emitterPath"])
    validator_path = resolve_path(validator["validatorPath"])
    artifact_dir.mkdir(parents=True, exist_ok=True)
    artifact = artifact_dir / f"{entry['id']}.{actual_hash[:16]}.spv"
    emit = subprocess.run(
        [
            str(emitter),
            "--shader-path",
            str(source),
            "--out",
            str(artifact),
            "--mode",
            "vulkan-compute-runtime",
        ],
        text=True,
        capture_output=True,
        check=False,
    )
    if emit.returncode != 0 or not artifact.is_file():
        return {
            **base,
            "pass": False,
            "reason": f"Doe SPIR-V emitter exited with code {emit.returncode}",
        }
    validation = subprocess.run(
        [str(validator_path), str(artifact)],
        text=True,
        capture_output=True,
        check=False,
    )
    artifact_ref = {"path": display_path(artifact), "sha256": sha256_file(artifact)}
    if validation.returncode != 0:
        detail = validation.stderr.strip() or validation.stdout.strip()
        return {
            **base,
            "artifact": artifact_ref,
            "pass": False,
            "reason": f"spirv-val failed: {detail or validation.returncode}",
        }
    return {
        **base,
        "artifact": artifact_ref,
        "pass": True,
        "reason": "hash-bound shader emitted and passed spirv-val",
    }


def cts_report_pass(
    payload: dict[str, Any], required_query_ids: list[str]
) -> tuple[bool, str, list[str]]:
    summary = payload.get("summary")
    rows = payload.get("rows")
    if not isinstance(summary, dict) or not isinstance(rows, list):
        return False, "CTS report is missing summary or rows", []
    query_ids = [row.get("id") for row in rows if isinstance(row, dict) and isinstance(row.get("id"), str)]
    missing = sorted(set(required_query_ids) - set(query_ids))
    failed_rows = [row.get("id", "<unknown>") for row in rows if not isinstance(row, dict) or row.get("pass") is not True]
    passed = (
        summary.get("identityBound") is True
        and summary.get("dryRun") is False
        and summary.get("failCount") == 0
        and summary.get("passCount") == summary.get("queryCount")
        and not missing
        and not failed_rows
    )
    if missing:
        reason = "CTS report is missing required queries: " + ", ".join(missing)
    elif failed_rows:
        reason = "CTS report contains failing rows: " + ", ".join(str(item) for item in failed_rows)
    elif summary.get("identityBound") is not True:
        reason = "CTS report is not bound to a physical adapter identity"
    elif passed:
        reason = f"{summary.get('passCount', 0)} identity-bound CTS queries passed"
    else:
        reason = "CTS summary does not represent a complete passing run"
    return passed, reason, query_ids


def validate_cts_report(entry: dict[str, Any]) -> dict[str, Any]:
    report_path = resolve_path(entry["path"])
    expected_hash = entry["sha256"]
    report_ref = {"path": display_path(report_path), "sha256": expected_hash}
    base = {
        "lane": entry["lane"],
        "report": report_ref,
        "queryIds": list(entry["requiredQueryIds"]),
        "adapterIdentity": {},
    }
    if not report_path.is_file():
        return {**base, "pass": False, "reason": "CTS report is missing"}
    actual_hash = sha256_file(report_path)
    report_ref["sha256"] = actual_hash
    if actual_hash != expected_hash:
        return {**base, "pass": False, "reason": "CTS report hash does not match the plan"}
    payload = load_json_object(report_path)
    passed, reason, query_ids = cts_report_pass(payload, entry["requiredQueryIds"])
    return {
        **base,
        "queryIds": query_ids,
        "adapterIdentity": payload.get("identityProbe", {}).get("identity", {}),
        "pass": passed,
        "reason": reason,
    }


def iter_search_files(path: Path) -> list[Path]:
    if path.is_file():
        return [path]
    if not path.is_dir():
        return []
    return sorted(
        candidate
        for candidate in path.rglob("*")
        if candidate.is_file() and candidate.suffix in {".c", ".h", ".js", ".json", ".zig"}
    )


def find_workaround_matches(pattern: str, raw_paths: list[str]) -> list[str]:
    matches: list[str] = []
    seen: set[Path] = set()
    for raw_path in raw_paths:
        for path in iter_search_files(resolve_path(raw_path)):
            resolved = path.resolve()
            if resolved in seen:
                continue
            seen.add(resolved)
            try:
                text = path.read_text(encoding="utf-8")
            except (OSError, UnicodeError):
                continue
            for line_number, line in enumerate(text.splitlines(), start=1):
                if pattern in line:
                    matches.append(f"{display_path(path)}:{line_number}")
    return matches


def validate_workaround(entry: dict[str, Any]) -> dict[str, Any]:
    matches = find_workaround_matches(entry["forbiddenPattern"], entry["searchPaths"])
    return {
        "id": entry["id"],
        "forbiddenPattern": entry["forbiddenPattern"],
        "searchPaths": list(entry["searchPaths"]),
        "matches": matches,
        "pass": not matches,
        "reason": "workaround is absent" if not matches else "forbidden workaround remains present",
    }


def markdown(ledger: dict[str, Any]) -> str:
    lines = [
        "# WGSL compiler coverage",
        "",
        "Generated by `bench/tools/generate_wgsl_compiler_coverage.py`. Do not edit by hand.",
        "",
        f"- Scope: `{ledger['claimScope']}`",
        f"- Status: `{ledger['supportStatus'].upper()}`",
        f"- Full support allowed: `{str(ledger['fullSupportAllowed']).lower()}`",
        f"- Source plan: `{ledger['sourcePlan']['path']}` (`{ledger['sourcePlan']['sha256']}`)",
        "- Boundary: `FULL` covers only the hash-bound Gemma 270M AMD Vulkan compute corpus; it is not universal WGSL or WebGPU conformance.",
        "",
        "| Check | Pass | Evidence |",
        "|---|---:|---|",
    ]
    for row in ledger["testCommands"]:
        lines.append(f"| `{row['id']}` | {row['pass']} | {row['reason']} |")
    spirv = ledger["spirvValidation"]
    lines.append(f"| `spirv-val-corpus` | {spirv['pass']} | {spirv['reason']} |")
    for row in ledger["ctsReports"]:
        lines.append(f"| `cts-{row['lane'].lower()}` | {row['pass']} | {row['reason']} |")
    for row in ledger["workarounds"]:
        lines.append(f"| `workaround-{row['id']}` | {row['pass']} | {row['reason']} |")

    lines.extend(["", "## Admitted Doppler shaders", "", "| Shader | Source SHA-256 | SPIR-V | Pass |", "|---|---|---|---:|"])
    for row in ledger["admittedShaders"]:
        artifact = row.get("artifact", {})
        lines.append(
            f"| `{row['id']}` | `{row['source']['sha256']}` | `{artifact.get('path', '<missing>')}` | {row['pass']} |"
        )
    if ledger["blockers"]:
        lines.extend(["", "## Blocking failures", ""])
        lines.extend(f"- {blocker}" for blocker in ledger["blockers"])
    lines.append("")
    return "\n".join(lines)


def main() -> int:
    args = parse_args()
    plan_path = resolve_path(args.plan)
    plan = load_json_object(plan_path)
    validate_payload(plan, load_json_object(resolve_path(args.plan_schema)), "coverage plan")

    out_json = resolve_path(args.out_json)
    out_md = resolve_path(args.out_md)
    artifact_dir = out_json.parent / "wgsl-compiler-artifacts"
    tests = [command_result(entry) for entry in plan["testCommands"]]
    spirv = validate_spirv_report(plan["spirvValidator"])
    shaders = [
        validate_admitted_shader(entry, plan["spirvValidator"], artifact_dir)
        for entry in plan["admittedShaders"]
    ]
    cts = [validate_cts_report(entry) for entry in plan["ctsReports"]]
    workarounds = [validate_workaround(entry) for entry in plan["workarounds"]]

    checks = [*tests, spirv, *shaders, *cts, *workarounds]
    blockers = [check["reason"] for check in checks if check["pass"] is not True]
    pass_count = sum(check["pass"] is True for check in checks)
    ledger = {
        "schemaVersion": 1,
        "artifactKind": "wgsl_compiler_coverage_ledger",
        "ledgerId": plan["ledgerId"],
        "claimScope": plan["claimScope"],
        "generatedAtUtc": utc_now(),
        "sourcePlan": {"path": display_path(plan_path), "sha256": sha256_file(plan_path)},
        "supportStatus": "full" if not blockers else "partial",
        "fullSupportAllowed": not blockers,
        "summary": {
            "checkCount": len(checks),
            "passCount": pass_count,
            "failCount": len(checks) - pass_count,
        },
        "testCommands": tests,
        "spirvValidation": spirv,
        "admittedShaders": shaders,
        "ctsReports": cts,
        "workarounds": workarounds,
        "blockers": blockers,
    }
    validate_payload(ledger, load_json_object(resolve_path(args.ledger_schema)), "coverage ledger")
    write_json_object(out_json, ledger)
    view = markdown(ledger)
    out_md.parent.mkdir(parents=True, exist_ok=True)
    out_md.write_text(view, encoding="utf-8")
    support_view = resolve_path(plan["supportViewPath"])
    support_view.write_text(view, encoding="utf-8")
    print(json.dumps({
        "outJson": display_path(out_json),
        "outMarkdown": display_path(out_md),
        "supportView": display_path(support_view),
        "supportStatus": ledger["supportStatus"],
        "checkCount": len(checks),
        "failCount": ledger["summary"]["failCount"],
    }, indent=2))
    return 0 if ledger["fullSupportAllowed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
