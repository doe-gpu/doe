#!/usr/bin/env python3
"""Build a cross-backend matrix keyed by the same WGSL source."""

from __future__ import annotations

import argparse
import hashlib
import json
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import jsonschema

try:
    from bench.tools._repo_import import ensure_repo_root
except ModuleNotFoundError:
    from _repo_import import ensure_repo_root

REPO_ROOT = ensure_repo_root(__file__)
from bench.lib.bench_utils import detect_repo_root, load_json_object


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", default="", help="Repository root. Auto-detected when omitted.")
    parser.add_argument("--registry", default="config/csl-runtime-fixtures.json")
    parser.add_argument("--registry-schema", default="config/csl-runtime-fixtures.schema.json")
    parser.add_argument("--report-schema", default="config/wgsl-backend-matrix-report.schema.json")
    parser.add_argument("--out", default="bench/out/cross-backend-matrix/wgsl-backend-matrix.json")
    parser.add_argument("--emit-msl-executable", default="")
    parser.add_argument("--emit-hlsl-executable", default="")
    parser.add_argument("--emit-dxil-executable", default="")
    parser.add_argument("--artifact-root", default="bench/out/cross-backend-matrix")
    parser.add_argument("--markdown-out", default="")
    return parser.parse_args()


def resolve(root: Path, raw_path: str) -> Path:
    path = Path(raw_path)
    if path.is_absolute():
        return path
    return (root / path).resolve()


def rel(root: Path, path: Path) -> str:
    try:
        return str(path.resolve().relative_to(root))
    except ValueError:
        return str(path.resolve())


def sha256_file(path: Path) -> str:
    hasher = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1024 * 1024), b""):
            hasher.update(chunk)
    return hasher.hexdigest()


def validate_payload(schema_path: Path, payload: dict[str, Any]) -> list[str]:
    schema = load_json_object(schema_path)
    errors = sorted(
        jsonschema.Draft202012Validator(schema).iter_errors(payload),
        key=lambda error: tuple(str(part) for part in error.absolute_path),
    )
    return [f"{'.'.join(str(part) for part in error.absolute_path) or '<root>'}: {error.message}" for error in errors]


def ready_artifact(root: Path, path: Path, reason: str) -> dict[str, Any]:
    return {
        "status": "ready",
        "reason": reason,
        "artifactPath": rel(root, path),
        "artifactSha256": sha256_file(path),
    }


def missing_artifact(reason: str) -> dict[str, Any]:
    return {"status": "missing", "reason": reason}


def run_emitter(
    *,
    root: Path,
    executable: str,
    source_path: Path,
    out_path: Path,
    ready_reason: str,
) -> dict[str, Any]:
    if not executable:
        return {"status": "not_wired", "reason": "emitter executable not provided"}
    exe_path = resolve(root, executable)
    if not exe_path.exists():
        return {"status": "not_wired", "reason": f"emitter executable missing: {executable}"}
    out_path.parent.mkdir(parents=True, exist_ok=True)
    proc = subprocess.run(
        [
            str(exe_path),
            "--shader-path",
            str(source_path),
            "--out",
            str(out_path),
        ],
        cwd=root,
        text=True,
        capture_output=True,
        check=False,
    )
    if proc.returncode != 0:
        detail = (proc.stderr or proc.stdout or "").strip().splitlines()
        reason = detail[-1] if detail else f"emitter exited {proc.returncode}"
        return {"status": "failed", "reason": reason[:240]}
    return ready_artifact(root, out_path, ready_reason)


def find_spirv_artifact(root: Path, evidence: dict[str, Any]) -> dict[str, Any]:
    evidence_dir = evidence.get("sourceEvidenceDir")
    if not isinstance(evidence_dir, str):
        return missing_artifact("sourceEvidenceDir is not declared")
    spirv_dir = resolve(root, evidence_dir) / "spirv"
    if not spirv_dir.is_dir():
        return missing_artifact(f"SPIR-V directory missing: {rel(root, spirv_dir)}")
    artifacts = sorted(spirv_dir.glob("*.spv"))
    if not artifacts:
        return missing_artifact(f"no .spv files under {rel(root, spirv_dir)}")
    return ready_artifact(root, artifacts[0], "SPIR-V artifact exists")


def csl_backend(root: Path, evidence: dict[str, Any]) -> dict[str, Any]:
    report_raw = evidence.get("governedLaneReportPath")
    if not isinstance(report_raw, str):
        return {"status": "blocked", "reason": "no governed lane report declared"}
    report_path = resolve(root, report_raw)
    if not report_path.is_file():
        return missing_artifact(f"governed lane report missing: {report_raw}")
    try:
        report = load_json_object(report_path)
    except (OSError, UnicodeError, json.JSONDecodeError, ValueError) as exc:
        return {"status": "failed", "reason": f"governed lane report parse failed: {exc}"}
    if report.get("laneStatus") != "ready":
        return {"status": "blocked", "reason": f"laneStatus={report.get('laneStatus')!r}"}
    run_status = report.get("run", {}).get("status")
    if run_status != "succeeded":
        return {"status": "blocked", "reason": f"run.status={run_status!r}"}
    backend = ready_artifact(root, report_path, "CSL governed lane report is ready")
    trace_raw = evidence.get("tracePath")
    if isinstance(trace_raw, str):
        trace_path = resolve(root, trace_raw)
        if trace_path.is_file():
            try:
                trace = load_json_object(trace_path)
            except (OSError, UnicodeError, json.JSONDecodeError, ValueError):
                trace = {}
            if isinstance(trace.get("runtimeMaxAbsErr"), (int, float)):
                backend["traceMaxAbsErr"] = trace["runtimeMaxAbsErr"]
            else:
                kernel_result_path = trace_path.with_suffix(".kernel-result.json")
                if kernel_result_path.is_file():
                    try:
                        kernel_result = load_json_object(kernel_result_path)
                    except (OSError, UnicodeError, json.JSONDecodeError, ValueError):
                        kernel_result = {}
                    if isinstance(kernel_result.get("maxAbsErr"), (int, float)):
                        backend["traceMaxAbsErr"] = kernel_result["maxAbsErr"]
    return backend


def build_row(root: Path, fixture: dict[str, Any], args: argparse.Namespace) -> dict[str, Any]:
    evidence = fixture.get("evidence")
    if not isinstance(evidence, dict):
        raise ValueError(f"{fixture.get('id')}: evidence must be an object")
    source_raw = evidence.get("sourceWgslPath")
    if not isinstance(source_raw, str):
        raise ValueError(f"{fixture.get('id')}: sourceWgslPath missing")
    source_path = resolve(root, source_raw)
    artifact_root = resolve(root, args.artifact_root)
    fixture_id = str(fixture["id"])

    return {
        "fixtureId": fixture_id,
        "kernelPattern": str(fixture["kernelPattern"]),
        "sourceWgslPath": rel(root, source_path),
        "sourceWgslSha256": sha256_file(source_path),
        "backends": {
            "vulkan_spirv": find_spirv_artifact(root, evidence),
            "metal_msl": run_emitter(
                root=root,
                executable=args.emit_msl_executable,
                source_path=source_path,
                out_path=artifact_root / "msl" / f"{fixture_id}.msl",
                ready_reason="MSL emitter completed",
            ),
            "d3d12_hlsl": run_emitter(
                root=root,
                executable=args.emit_hlsl_executable,
                source_path=source_path,
                out_path=artifact_root / "hlsl" / f"{fixture_id}.hlsl",
                ready_reason="HLSL emitter completed",
            ),
            "d3d12_dxil": run_emitter(
                root=root,
                executable=args.emit_dxil_executable,
                source_path=source_path,
                out_path=artifact_root / "dxil" / f"{fixture_id}.dxil",
                ready_reason="DXIL emitter completed",
            ),
            "csl": csl_backend(root, evidence),
        },
    }


def count_ready(rows: list[dict[str, Any]], backend_key: str) -> int:
    return sum(1 for row in rows if row["backends"][backend_key]["status"] == "ready")


def render_markdown(report: dict[str, Any]) -> str:
    lines = [
        "# WGSL backend matrix",
        "",
        "| fixture | classifier | Vulkan SPIR-V | Metal MSL | D3D12 HLSL | D3D12 DXIL | CSL |",
        "| --- | --- | --- | --- | --- | --- | --- |",
    ]
    for row in report["rows"]:
        backends = row["backends"]
        lines.append(
            "| "
            + " | ".join(
                [
                    row["fixtureId"],
                    row["kernelPattern"],
                    backends["vulkan_spirv"]["status"],
                    backends["metal_msl"]["status"],
                    backends["d3d12_hlsl"]["status"],
                    backends["d3d12_dxil"]["status"],
                    backends["csl"]["status"],
                ]
            )
            + " |"
        )
    return "\n".join(lines) + "\n"


def main() -> int:
    args = parse_args()
    try:
        root = detect_repo_root(args.root)
        registry = load_json_object(resolve(root, args.registry))
    except (OSError, UnicodeError, json.JSONDecodeError, ValueError) as exc:
        print(f"FAIL: build WGSL backend matrix: {exc}")
        return 1

    registry_errors = validate_payload(resolve(root, args.registry_schema), registry)
    if registry_errors:
        print("FAIL: build WGSL backend matrix")
        for error in registry_errors:
            print(f"  registry: {error}")
        return 1

    try:
        fixtures = registry["fixtures"]
        rows = [build_row(root, fixture, args) for fixture in fixtures if isinstance(fixture, dict)]
    except (OSError, ValueError) as exc:
        print(f"FAIL: build WGSL backend matrix: {exc}")
        return 1

    report = {
        "schemaVersion": 1,
        "artifactKind": "wgsl_backend_matrix_report",
        "generatedAtUtc": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        "sourceRegistryPath": args.registry,
        "summary": {
            "rowCount": len(rows),
            "vulkanReady": count_ready(rows, "vulkan_spirv"),
            "metalReady": count_ready(rows, "metal_msl"),
            "d3d12Ready": min(count_ready(rows, "d3d12_hlsl"), count_ready(rows, "d3d12_dxil")),
            "cslRuntimeReady": count_ready(rows, "csl"),
        },
        "rows": rows,
    }

    report_errors = validate_payload(resolve(root, args.report_schema), report)
    if report_errors:
        print("FAIL: build WGSL backend matrix")
        for error in report_errors:
            print(f"  report: {error}")
        return 1

    out_path = resolve(root, args.out)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    if args.markdown_out:
        markdown_path = resolve(root, args.markdown_out)
        markdown_path.parent.mkdir(parents=True, exist_ok=True)
        markdown_path.write_text(render_markdown(report), encoding="utf-8")

    print(f"wrote {rel(root, out_path)} ({len(rows)} rows)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
