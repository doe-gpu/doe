#!/usr/bin/env python3
"""Run a configured WebGPU CTS subset and emit machine-readable trend artifacts."""

from __future__ import annotations

import argparse
import json
import re
import shlex
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

SCRIPT_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parent.parent
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from bench.lib.bench_utils import load_json_object, write_json_object

CTS_REPORT_SCHEMA_VERSION = 2
IDENTITY_ARTIFACT_KIND = "webgpu_cts_adapter_identity"
CTS_SUMMARY_RE = re.compile(
    r"^(Passed\s+w/o\s+warnings|Passed\s+with\s+warnings|Skipped|Failed)\s*=\s*(\d+)\s*/\s*(\d+)",
    re.IGNORECASE,
)


def normalize_label(value: str) -> str:
    return "".join(ch if ch.isalnum() else "_" for ch in value).strip("_") or "query"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--config",
        default="bench/fixtures/cts_subset.fawn-node.json",
        help="CTS subset config JSON.",
    )
    parser.add_argument(
        "--out-json",
        default="bench/out/cts_subset_report.json",
        help="JSON output path.",
    )
    parser.add_argument(
        "--out-md",
        default="bench/out/cts_subset_report.md",
        help="Markdown output path.",
    )
    parser.add_argument(
        "--max-queries",
        type=int,
        default=0,
        help="Optional max number of queries to execute (>0 limits execution).",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Do not execute commands; emit planned runs only.",
    )
    parser.add_argument(
        "--stop-on-fail",
        action="store_true",
        help="Stop after first failing query.",
    )
    return parser.parse_args()


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def ensure_string_list(value: Any, *, field: str) -> list[str]:
    if not isinstance(value, list):
        raise ValueError(f"invalid {field}: expected string[]")
    out: list[str] = []
    for index, item in enumerate(value):
        if not isinstance(item, str) or not item.strip():
            raise ValueError(f"invalid {field}[{index}]: expected non-empty string")
        out.append(item.strip())
    if not out:
        raise ValueError(f"invalid {field}: expected at least one query")
    return out


def ensure_optional_string_list(value: Any, *, field: str) -> list[str]:
    if value is None:
        return []
    if not isinstance(value, list):
        raise ValueError(f"invalid {field}: expected string[]")
    out: list[str] = []
    for index, item in enumerate(value):
        if not isinstance(item, str) or not item.strip():
            raise ValueError(f"invalid {field}[{index}]: expected non-empty string")
        out.append(item.strip())
    return out


def load_identity_probe(value: Any) -> dict[str, Any] | None:
    if value is None:
        return None
    if not isinstance(value, dict):
        raise ValueError("invalid identityProbe: expected object")
    command_template = value.get("commandTemplate")
    required = value.get("required")
    if not isinstance(command_template, str) or not command_template.strip():
        raise ValueError("invalid identityProbe.commandTemplate: expected non-empty string")
    if not isinstance(required, bool):
        raise ValueError("invalid identityProbe.required: expected boolean")
    return {
        "commandTemplate": command_template.strip(),
        "required": required,
    }


def parse_adapter_identity(stdout_lines: list[str]) -> dict[str, Any]:
    for line in reversed(stdout_lines):
        try:
            payload = json.loads(line)
        except json.JSONDecodeError:
            continue
        if not isinstance(payload, dict):
            continue
        if payload.get("artifactKind") != IDENTITY_ARTIFACT_KIND:
            continue
        adapter_info = payload.get("adapterInfo")
        if not isinstance(adapter_info, dict):
            raise ValueError("identity probe adapterInfo must be an object")
        required_fields = ("vendor", "device", "description")
        missing = [
            field
            for field in required_fields
            if not isinstance(adapter_info.get(field), str) or not adapter_info[field].strip()
        ]
        if missing:
            raise ValueError(
                "identity probe adapterInfo missing non-empty fields: " + ", ".join(missing)
            )
        return payload
    raise ValueError("identity probe stdout did not contain a valid identity artifact")


def run_identity_probe(
    probe: dict[str, Any] | None,
    *,
    config_path: Path,
    workdir: Path,
    dry_run: bool,
) -> dict[str, Any]:
    if probe is None:
        return {
            "configured": False,
            "required": False,
            "pass": False,
            "command": [],
            "exitCode": None,
            "wallMs": None,
            "stdoutTail": [],
            "stderrTail": [],
            "error": "identity probe is not configured",
            "identity": None,
        }
    rendered = probe["commandTemplate"].format(
        repo_root=str(REPO_ROOT),
        config_dir=str(config_path.resolve().parent),
    )
    command = shlex.split(rendered)
    if dry_run:
        return {
            "configured": True,
            "required": probe["required"],
            "pass": None,
            "command": command,
            "exitCode": None,
            "wallMs": None,
            "stdoutTail": [],
            "stderrTail": [],
            "error": "",
            "identity": None,
        }
    run = run_query(command, workdir)
    identity = None
    error = ""
    if run["exitCode"] == 0:
        try:
            identity = parse_adapter_identity(run["stdoutTail"])
        except ValueError as exc:
            error = str(exc)
    else:
        error = f"identity probe exited with code {run['exitCode']}"
    return {
        "configured": True,
        "required": probe["required"],
        "pass": run["exitCode"] == 0 and identity is not None,
        "command": command,
        "exitCode": run["exitCode"],
        "wallMs": run["wallMs"],
        "stdoutTail": run["stdoutTail"],
        "stderrTail": run["stderrTail"],
        "error": error,
        "identity": identity,
    }


def load_query_entries(value: Any) -> list[dict[str, str]]:
    if not isinstance(value, list):
        raise ValueError("invalid queries: expected string[] or query object[]")
    out: list[dict[str, str]] = []
    for index, item in enumerate(value):
        if isinstance(item, str):
            query = item.strip()
            if not query:
                raise ValueError(f"invalid queries[{index}]: expected non-empty string")
            out.append(
                {
                    "id": normalize_label(query),
                    "query": query,
                    "bucket": "",
                    "notes": "",
                }
            )
            continue
        if not isinstance(item, dict):
            raise ValueError(f"invalid queries[{index}]: expected string or object")
        query = item.get("query")
        if not isinstance(query, str) or not query.strip():
            raise ValueError(f"invalid queries[{index}].query: expected non-empty string")
        raw_id = item.get("id")
        raw_bucket = item.get("bucket")
        raw_notes = item.get("notes")
        entry_id = raw_id.strip() if isinstance(raw_id, str) and raw_id.strip() else normalize_label(query)
        bucket = raw_bucket.strip() if isinstance(raw_bucket, str) and raw_bucket.strip() else ""
        notes = raw_notes.strip() if isinstance(raw_notes, str) and raw_notes.strip() else ""
        out.append(
            {
                "id": entry_id,
                "query": query.strip(),
                "bucket": bucket,
                "notes": notes,
            }
        )
    if not out:
        raise ValueError("invalid queries: expected at least one query")
    return out


def summarize_buckets(rows: list[dict[str, Any]]) -> dict[str, dict[str, int]]:
    summary: dict[str, dict[str, int]] = {}
    for row in rows:
        bucket_raw = row.get("bucket")
        bucket = bucket_raw if isinstance(bucket_raw, str) and bucket_raw else "unbucketed"
        item = summary.setdefault(
            bucket,
            {
                "queryCount": 0,
                "passCount": 0,
                "failCount": 0,
            },
        )
        item["queryCount"] += 1
        passed = row.get("pass")
        if passed is True:
            item["passCount"] += 1
        elif passed is False:
            item["failCount"] += 1
    return summary


def parse_cts_text_summary(stdout: str, stderr: str) -> dict[str, int] | None:
    counts: dict[str, int] = {}
    total = None
    for line in f"{stdout}\n{stderr}".splitlines():
        match = CTS_SUMMARY_RE.match(line.strip())
        if match is None:
            continue
        label = " ".join(match.group(1).lower().split())
        key = {
            "passed w/o warnings": "passedWithoutWarnings",
            "passed with warnings": "passedWithWarnings",
            "skipped": "skipped",
            "failed": "failed",
        }[label]
        counts[key] = int(match.group(2))
        row_total = int(match.group(3))
        total = row_total if total is None else max(total, row_total)
    required = {"passedWithoutWarnings", "passedWithWarnings", "skipped", "failed"}
    if not required.issubset(counts) or total is None:
        return None
    counts["total"] = total
    return counts


def markdown(payload: dict[str, Any]) -> str:
    lines: list[str] = []
    lines.append("# CTS Subset Report")
    lines.append("")
    lines.append(f"- Generated: `{payload.get('generatedAtUtc', '')}`")
    lines.append(f"- Config: `{payload.get('configPath', '')}`")
    lines.append(f"- Workdir: `{payload.get('workdir', '')}`")
    lines.append(f"- Command template: `{payload.get('commandTemplate', '')}`")
    identity_probe = payload.get("identityProbe")
    if isinstance(identity_probe, dict):
        lines.append(f"- Adapter identity bound: `{identity_probe.get('pass') is True}`")
    lines.append("")
    summary = payload.get("summary", {})
    if not isinstance(summary, dict):
        summary = {}
    lines.append(f"- Query count: `{summary.get('queryCount', 0)}`")
    lines.append(f"- Pass count: `{summary.get('passCount', 0)}`")
    lines.append(f"- Fail count: `{summary.get('failCount', 0)}`")
    requirement_note = payload.get("requirementsNote")
    if isinstance(requirement_note, str) and requirement_note.strip():
        lines.append(f"- Requirements: `{requirement_note.strip()}`")
    bucket_summary = summary.get("bucketSummary")
    if isinstance(bucket_summary, dict) and bucket_summary:
        lines.append("")
        lines.append("| Bucket | Queries | Pass | Fail |")
        lines.append("|---|---:|---:|---:|")
        for bucket, stats in bucket_summary.items():
            if not isinstance(stats, dict):
                continue
            lines.append(
                f"| `{bucket}` | {stats.get('queryCount', 0)} | {stats.get('passCount', 0)} | {stats.get('failCount', 0)} |"
            )
    lines.append("")
    lines.append("| Id | Bucket | Query | Exit | Wall ms | Pass |")
    lines.append("|---|---|---|---:|---:|---:|")
    rows = payload.get("rows", [])
    if not isinstance(rows, list):
        rows = []
    for row in rows:
        if not isinstance(row, dict):
            continue
        lines.append(
            f"| `{row.get('id', '')}` | `{row.get('bucket', '')}` | `{row.get('query', '')}` | {row.get('exitCode', '')} | "
            f"{row.get('wallMs', '')} | {row.get('pass', False)} |"
        )
    lines.append("")
    return "\n".join(lines) + "\n"


def run_query(command: list[str], workdir: Path) -> dict[str, Any]:
    start = time.perf_counter()
    proc = subprocess.run(
        command,
        cwd=str(workdir),
        text=True,
        capture_output=True,
        check=False,
    )
    wall_ms = (time.perf_counter() - start) * 1000.0
    return {
        "exitCode": proc.returncode,
        "wallMs": wall_ms,
        "ctsSummary": parse_cts_text_summary(proc.stdout or "", proc.stderr or ""),
        "stdoutTail": (proc.stdout or "").splitlines()[-20:],
        "stderrTail": (proc.stderr or "").splitlines()[-20:],
    }


def main() -> int:
    args = parse_args()
    config_path = Path(args.config)
    if not config_path.exists():
        print(f"FAIL: missing CTS config: {config_path}")
        return 1

    try:
        config = load_json_object(config_path)
    except (OSError, json.JSONDecodeError, ValueError) as exc:
        print(f"FAIL: {exc}")
        return 1

    workdir_raw = config.get("workdir")
    command_template = config.get("commandTemplate")
    requirement_note = config.get("requirementsNote")
    require_text_summary = config.get("requireTextSummary", False)
    if not isinstance(workdir_raw, str) or not workdir_raw.strip():
        print("FAIL: invalid config workdir")
        return 1
    if not isinstance(command_template, str) or "{query}" not in command_template:
        print("FAIL: invalid config commandTemplate (must include {query})")
        return 1
    if not isinstance(require_text_summary, bool):
        print("FAIL: invalid config requireTextSummary")
        return 1
    try:
        queries = load_query_entries(config.get("queries"))
        required_paths = ensure_optional_string_list(config.get("requiredPaths"), field="requiredPaths")
        identity_probe_config = load_identity_probe(config.get("identityProbe"))
    except ValueError as exc:
        print(f"FAIL: {exc}")
        return 1

    if args.max_queries > 0:
        queries = queries[: args.max_queries]

    workdir = Path(workdir_raw)
    if not workdir.is_absolute():
        workdir = (REPO_ROOT / workdir).resolve()
    if not workdir.exists():
        print(f"FAIL: configured CTS workdir does not exist: {workdir}")
        return 1
    missing_required_paths = [item for item in required_paths if not (workdir / item).exists()]
    if missing_required_paths and not args.dry_run:
        print("FAIL: CTS preflight missing required paths:")
        for item in missing_required_paths:
            print(f"  - {workdir / item}")
        if isinstance(requirement_note, str) and requirement_note.strip():
            print(f"hint: {requirement_note.strip()}")
        return 1

    rows: list[dict[str, Any]] = []
    fail_count = 0
    pass_count = 0

    identity_probe = run_identity_probe(
        identity_probe_config,
        config_path=config_path,
        workdir=workdir,
        dry_run=args.dry_run,
    )
    identity_blocked = identity_probe["required"] and identity_probe["pass"] is False

    for entry in [] if identity_blocked else queries:
        rendered = command_template.format(
            query=entry["query"],
            id=entry["id"],
            bucket=entry["bucket"],
            notes=entry["notes"],
            repo_root=str(REPO_ROOT),
            config_dir=str(config_path.resolve().parent),
        )
        command = shlex.split(rendered)
        if args.dry_run:
            rows.append(
                {
                    "id": entry["id"],
                    "bucket": entry["bucket"],
                    "query": entry["query"],
                    "notes": entry["notes"],
                    "command": command,
                    "exitCode": None,
                    "wallMs": None,
                    "pass": None,
                    "stdoutTail": [],
                    "stderrTail": [],
                }
            )
            continue

        run = run_query(command, workdir)
        cts_summary = run["ctsSummary"]
        summary_pass = cts_summary is not None and cts_summary["failed"] == 0
        is_pass = run["exitCode"] == 0 and (
            summary_pass if require_text_summary else cts_summary is None or summary_pass
        )
        if is_pass:
            pass_count += 1
        else:
            fail_count += 1
        rows.append(
            {
                "id": entry["id"],
                "bucket": entry["bucket"],
                "query": entry["query"],
                "notes": entry["notes"],
                "command": command,
                "exitCode": run["exitCode"],
                "wallMs": run["wallMs"],
                "pass": is_pass,
                "ctsSummary": cts_summary,
                "stdoutTail": run["stdoutTail"],
                "stderrTail": run["stderrTail"],
            }
        )
        if args.stop_on_fail and not is_pass:
            break

    summary = {
        "queryCount": len(rows),
        "passCount": pass_count,
        "failCount": fail_count,
        "dryRun": bool(args.dry_run),
        "bucketSummary": summarize_buckets(rows),
        "identityBound": identity_probe["pass"] is True,
    }
    payload = {
        "schemaVersion": CTS_REPORT_SCHEMA_VERSION,
        "generatedAtUtc": utc_now(),
        "configPath": str(config_path),
        "workdir": str(workdir),
        "commandTemplate": command_template,
        "requirementsNote": requirement_note if isinstance(requirement_note, str) else "",
        "requireTextSummary": require_text_summary,
        "identityProbe": identity_probe,
        "summary": summary,
        "rows": rows,
    }

    out_json = Path(args.out_json)
    out_md = Path(args.out_md)
    out_md.parent.mkdir(parents=True, exist_ok=True)
    write_json_object(out_json, payload)
    out_md.write_text(markdown(payload), encoding="utf-8")
    print(
        json.dumps(
            {
                "outJson": str(out_json),
                "outMd": str(out_md),
                "queryCount": summary["queryCount"],
                "passCount": summary["passCount"],
                "failCount": summary["failCount"],
                "dryRun": summary["dryRun"],
                "identityBound": summary["identityBound"],
            },
            indent=2,
        )
    )
    if args.dry_run:
        return 0
    if identity_blocked:
        return 2
    return 0 if fail_count == 0 else 2


if __name__ == "__main__":
    raise SystemExit(main())
