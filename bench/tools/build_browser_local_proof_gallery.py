#!/usr/bin/env python3
"""Build a local browser proof-gallery page from execution receipts."""

from __future__ import annotations

import argparse
import html
import json
import sys
from pathlib import Path
from typing import Any

try:
    from bench.tools import build_browser_public_gallery_receipt as public_gallery
except ModuleNotFoundError:
    sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
    from bench.tools import build_browser_public_gallery_receipt as public_gallery


REPO_ROOT = Path(__file__).resolve().parents[2]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--title", default="Fawn Doe Local Proof Gallery")
    parser.add_argument(
        "--category",
        choices=("compute", "rendering", "tensor", "shader_edge", "benchmark_trace"),
        required=True,
    )
    parser.add_argument("--workload-contract-path", required=True)
    parser.add_argument("--receipt-payload", action="append", required=True)
    parser.add_argument("--comparison-artifact", required=True)
    parser.add_argument("--release-archive-manifest", required=True)
    parser.add_argument("--package-inputs", required=True)
    parser.add_argument("--out", required=True)
    return parser.parse_args()


def repo_relative(path: Path) -> str:
    resolved = path.resolve()
    try:
        return str(resolved.relative_to(REPO_ROOT))
    except ValueError:
        return str(path)


def load_json(path: Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8"))


def text(value: Any) -> str:
    if value is True:
        return "true"
    if value is False:
        return "false"
    if value is None:
        return ""
    return str(value)


def tag(name: str, content: str, *, attrs: str = "") -> str:
    suffix = f" {attrs}" if attrs else ""
    return f"<{name}{suffix}>{content}</{name}>"


def row(label: str, value: Any) -> str:
    return (
        "<tr>"
        f"<th>{html.escape(label)}</th>"
        f"<td>{html.escape(text(value))}</td>"
        "</tr>"
    )


def section(title: str, body: str) -> str:
    return tag("section", tag("h2", html.escape(title)) + body)


def artifact_table(title: str, payload: dict[str, Any]) -> str:
    rows: list[str] = []
    for key in sorted(payload):
        value = payload[key]
        if isinstance(value, (dict, list)):
            value = json.dumps(value, sort_keys=True)
        rows.append(row(key, value))
    return section(title, tag("table", "\n".join(rows)))


def receipt_section(path: Path, payload: dict[str, Any]) -> str:
    source_shader = payload.get("sourceShader", {})
    driver = payload.get("driver", {})
    device = payload.get("device", {})
    timing = payload.get("timing", {})
    phases = timing.get("phases", {}) if isinstance(timing, dict) else {}
    lowering_path = payload.get("loweringPath", [])
    lowering_text = " > ".join(lowering_path) if isinstance(lowering_path, list) else ""
    values = [
        ("receiptId", payload.get("receiptId")),
        ("workloadId", payload.get("workloadId")),
        ("receiptArtifactPath", repo_relative(path)),
        ("selectedRuntime", payload.get("selectedRuntime")),
        ("backend", payload.get("backend")),
        ("sourceShader.language", source_shader.get("language")),
        ("sourceShader.entryPoint", source_shader.get("entryPoint")),
        ("sourceShader.sha256", source_shader.get("sha256")),
        ("sourceShader.source", source_shader.get("source")),
        ("loweringPath", lowering_text),
        ("driver.vendor", driver.get("vendor")),
        ("driver.api", driver.get("api")),
        ("driver.driver", driver.get("driver")),
        ("driver.deviceFamily", driver.get("deviceFamily")),
        ("driver.profileId", driver.get("profileId")),
        ("device.adapter", device.get("adapter")),
        ("device.adapterInfoSha256", device.get("adapterInfoSha256")),
        ("device.featureCount", f"featureCount={device.get('featureCount')}"),
        ("outputHash", payload.get("outputHash")),
        ("frameHash", payload.get("frameHash")),
        ("timing.timingClass", timing.get("timingClass") if isinstance(timing, dict) else ""),
        ("timing.phases.setupNs", f"setupNs={phases.get('setupNs')}"),
        ("timing.phases.encodeNs", f"encodeNs={phases.get('encodeNs')}"),
        ("timing.phases.submitWaitNs", f"submitWaitNs={phases.get('submitWaitNs')}"),
    ]
    return section(
        f"Execution Receipt {payload.get('receiptId', '')}",
        tag("table", "\n".join(row(label, value) for label, value in values)),
    )


def smoke_summary(path: Path, payload: dict[str, Any]) -> str:
    rows = [
        row("comparisonArtifactPath", repo_relative(path)),
        row("reportKind", payload.get("reportKind")),
        row("reportHash", payload.get("reportHash")),
        row("mode", payload.get("mode")),
    ]
    comparison = payload.get("comparison")
    if isinstance(comparison, dict):
        for key in sorted(comparison):
            rows.append(row(f"comparison.{key}", comparison[key]))
    mode_results = payload.get("modeResults")
    if isinstance(mode_results, list):
        for result in mode_results:
            if not isinstance(result, dict):
                continue
            mode = result.get("mode")
            rows.extend(
                [
                    row(f"{mode}.webgpuAvailable", result.get("webgpuAvailable")),
                    row(f"{mode}.adapterAvailable", result.get("adapterAvailable")),
                    row(f"{mode}.browserVersion", result.get("browserVersion")),
                ]
            )
    return section("Dawn vs Doe Smoke Comparison", tag("table", "\n".join(rows)))


def manifest_summary(path: Path, payload: dict[str, Any]) -> str:
    archive = payload.get("archive", {})
    product = payload.get("browserProduct", {})
    platform = payload.get("platform", {})
    rows = [
        row("releaseArchiveManifestPath", repo_relative(path)),
        row("releaseArchive.path", archive.get("path")),
        row("releaseArchive.sha256", archive.get("sha256")),
        row("releaseArchive.byteLength", archive.get("byteLength")),
        row("browserProduct.displayName", product.get("displayName")),
        row("browserProduct.version", product.get("version")),
        row("browserProduct.channel", product.get("channel")),
        row("platform.os", platform.get("os")),
        row("platform.arch", platform.get("arch")),
        row("platform.packageFormat", platform.get("packageFormat")),
    ]
    members = payload.get("members")
    if isinstance(members, dict):
        for role in sorted(members):
            member = members[role]
            if not isinstance(member, dict):
                continue
            rows.extend(
                [
                    row(f"{role}.archivePath", member.get("archivePath")),
                    row(f"{role}.sha256", member.get("sha256")),
                    row(f"{role}.sourcePath", member.get("sourcePath")),
                ]
            )
    return section("Release Archive", tag("table", "\n".join(rows)))


def package_inputs_summary(path: Path, payload: dict[str, Any]) -> str:
    rows = [
        row("packageInputsPath", repo_relative(path)),
        row("status", payload.get("status")),
        row("evidenceMode", payload.get("evidenceMode")),
        row("releaseCandidateEligible", payload.get("releaseCandidateEligible")),
    ]
    blockers = payload.get("releaseCandidateBlockers")
    if isinstance(blockers, list):
        for index, blocker in enumerate(blockers):
            if not isinstance(blocker, dict):
                continue
            rows.extend(
                [
                    row(f"releaseCandidateBlockers[{index}].code", blocker.get("code")),
                    row(f"releaseCandidateBlockers[{index}].message", blocker.get("message")),
                ]
            )
    return section("Package Inputs", tag("table", "\n".join(rows)))


def write_page(
    *,
    title: str,
    category: str,
    workload_contract_path: str,
    receipt_paths: list[Path],
    comparison_artifact_path: Path,
    release_archive_manifest_path: Path,
    package_inputs_path: Path,
    out_path: Path,
) -> None:
    receipts = [load_json(path) for path in receipt_paths]
    comparison = load_json(comparison_artifact_path)
    manifest = load_json(release_archive_manifest_path)
    package_inputs = load_json(package_inputs_path)
    (
        receipt_ids,
        receipt_artifact_paths,
        workload_ids,
        visible_fragments,
    ) = public_gallery.receipt_payload_evidence(receipt_paths)
    body = [
        tag("h1", html.escape(title)),
        artifact_table(
            "Gallery Identity",
            {
                "category": category,
                "workloadContractPath": workload_contract_path,
                "workloadIds": workload_ids,
                "receiptIds": receipt_ids,
                "receiptArtifactPaths": receipt_artifact_paths,
            },
        ),
        manifest_summary(release_archive_manifest_path, manifest),
        package_inputs_summary(package_inputs_path, package_inputs),
        smoke_summary(comparison_artifact_path, comparison),
    ]
    for path, payload in zip(receipt_paths, receipts, strict=True):
        if not isinstance(payload, dict):
            raise ValueError(f"receipt payload must be an object: {path}")
        body.append(receipt_section(path, payload))
    document = "\n".join(
        [
            "<!doctype html>",
            '<html lang="en">',
            "<head>",
            '<meta charset="utf-8">',
            f"<title>{html.escape(title)}</title>",
            "<style>",
            "body{font-family:system-ui,sans-serif;margin:2rem;line-height:1.4}",
            "section{margin-block:1.5rem}",
            "table{border-collapse:collapse;width:100%}",
            "th,td{border:1px solid #ccc;padding:.35rem;text-align:left;vertical-align:top}",
            "th{width:18rem;background:#f6f6f6}",
            "td{white-space:pre-wrap;word-break:break-word}",
            "</style>",
            "</head>",
            "<body>",
            *body,
            "</body>",
            "</html>",
        ]
    )
    public_gallery.validate_visible_gallery_content(
        content=document.encode("utf-8"),
        category=category,
        workload_contract_path=workload_contract_path,
        workload_ids=workload_ids,
        receipt_ids=receipt_ids,
        receipt_artifact_paths=receipt_artifact_paths,
        receipt_visible_fragments=visible_fragments,
    )
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(document + "\n", encoding="utf-8")


def main() -> int:
    args = parse_args()
    try:
        write_page(
            title=args.title,
            category=args.category,
            workload_contract_path=args.workload_contract_path,
            receipt_paths=[Path(path) for path in args.receipt_payload],
            comparison_artifact_path=Path(args.comparison_artifact),
            release_archive_manifest_path=Path(args.release_archive_manifest),
            package_inputs_path=Path(args.package_inputs),
            out_path=Path(args.out),
        )
    except Exception as exc:
        sys.stderr.write(f"build_browser_local_proof_gallery: {exc}\n")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
