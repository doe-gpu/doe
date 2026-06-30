#!/usr/bin/env python3
"""Build browser runtime identity evidence from Chromium runtime-selection reports."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

try:
    from bench.tools._repo_import import ensure_repo_root
except ModuleNotFoundError:
    from _repo_import import ensure_repo_root

REPO_ROOT = ensure_repo_root(__file__)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--report",
        required=True,
        help="Browser smoke, ORT, or layered report carrying runtime selection evidence.",
    )
    parser.add_argument(
        "--mode",
        default="doe",
        choices=["dawn", "doe"],
        help="Requested runtime mode to extract.",
    )
    parser.add_argument("--out", default="", help="Optional output identity path.")
    parser.add_argument("--json", action="store_true", dest="emit_json")
    return parser.parse_args()


def load_json(path: Path) -> dict[str, Any]:
    payload = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(payload, dict):
        raise ValueError(f"expected JSON object: {path}")
    return payload


def find_mode_entry(report: dict[str, Any], mode: str) -> dict[str, Any]:
    for key in ("modeResults", "modeRunDetails"):
        entries = report.get(key)
        if not isinstance(entries, list):
            continue
        for entry in entries:
            if isinstance(entry, dict) and entry.get("mode") == mode:
                return entry
    raise ValueError(f"runtime mode not found in report: {mode}")


def runtime_selection_from_entry(entry: dict[str, Any]) -> dict[str, Any]:
    selection = entry.get("runtimeSelection")
    if isinstance(selection, dict):
        return selection
    evidence = entry.get("runtimeEvidence")
    if isinstance(evidence, dict) and isinstance(evidence.get("runtimeSelection"), dict):
        return evidence["runtimeSelection"]
    raise ValueError("runtimeSelection missing from selected report entry")


def runtime_probe_from_entry(entry: dict[str, Any]) -> dict[str, Any]:
    probe = entry.get("runtimeProbe")
    if isinstance(probe, dict):
        return probe
    return {
        "webgpuAvailable": entry.get("webgpuAvailable"),
        "adapterAvailable": entry.get("adapterAvailable"),
        "adapterIdentity": entry.get("adapterIdentity"),
        "errors": entry.get("errors", []),
    }


def report_path_text(path: Path) -> str:
    try:
        return path.resolve().relative_to(REPO_ROOT).as_posix()
    except ValueError:
        return str(path)


def build_identity(report: dict[str, Any], *, report_path: Path, mode: str) -> dict[str, Any]:
    entry = find_mode_entry(report, mode)
    runtime_selection = runtime_selection_from_entry(entry)
    runtime_probe = runtime_probe_from_entry(entry)
    selected_runtime = runtime_selection.get("selectedRuntime")
    fallback_applied = runtime_selection.get("fallbackApplied")
    hidden_fallback_allowed = runtime_selection.get("hiddenFallbackAllowed")
    webgpu_available = runtime_probe.get("webgpuAvailable")
    if not isinstance(webgpu_available, bool):
        raise ValueError("selected report entry must carry boolean webgpuAvailable")

    evidence = entry.get("runtimeEvidence")
    provider: dict[str, Any] = {
        "sourceReport": report_path_text(report_path),
        "sourceReportKind": str(report.get("reportKind", "")),
        "mode": mode,
        "adapterAvailable": runtime_probe.get("adapterAvailable")
        if isinstance(runtime_probe.get("adapterAvailable"), bool)
        else None,
        "adapterIdentity": runtime_probe.get("adapterIdentity")
        if isinstance(runtime_probe.get("adapterIdentity"), dict)
        else {},
        "artifactIdentity": runtime_selection.get("artifactIdentity")
        if isinstance(runtime_selection.get("artifactIdentity"), dict)
        else {},
    }
    if isinstance(evidence, dict):
        for key in ("browserVersion", "userAgent", "pageTargetKind"):
            if isinstance(evidence.get(key), str):
                provider[key] = evidence[key]
    if isinstance(entry.get("shaderCompilerIdentity"), dict):
        provider["shaderCompilerIdentity"] = entry["shaderCompilerIdentity"]

    return {
        "schemaVersion": 1,
        "artifactKind": "browser_runtime_identity",
        "surface": "doe-gpu/browser",
        "evidenceSource": "runtime_selection_artifact",
        "selectedRuntime": selected_runtime,
        "executionOwner": "chromium_runtime_selector",
        "doeRuntimeActive": (
            selected_runtime == "doe"
            and fallback_applied is False
            and hidden_fallback_allowed is False
        ),
        "webgpuAvailable": webgpu_available,
        "provider": provider,
        "runtimeSelection": runtime_selection,
    }


def main() -> int:
    args = parse_args()
    report_path = Path(args.report)
    try:
        identity = build_identity(load_json(report_path), report_path=report_path, mode=args.mode)
    except (OSError, UnicodeError, json.JSONDecodeError, ValueError) as exc:
        print(f"FAIL: browser runtime identity build: {exc}", file=sys.stderr)
        return 1
    if args.out:
        out_path = Path(args.out)
        out_path.parent.mkdir(parents=True, exist_ok=True)
        out_path.write_text(json.dumps(identity, indent=2) + "\n", encoding="utf-8")
    if args.emit_json:
        print(json.dumps(identity, indent=2))
    else:
        print("PASS: browser runtime identity build")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
