#!/usr/bin/env python3
"""Stage candidate proof-surface and launch provenance around a public download receipt."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path, PurePosixPath
from typing import Any

try:
    from bench.tools import build_browser_release_artifact_bundle as bundle_builder
    from bench.tools import build_browser_proof_page_receipt as proof_page_builder
    from bench.tools import build_browser_published_proof_surface as proof_surface_builder
    from bench.tools import build_browser_release_launch_receipt as launch_builder
    from bench.tools import check_browser_published_proof_surface as proof_surface_check
    from bench.tools import check_browser_release_candidate_provenance as provenance_check
except ModuleNotFoundError:
    import build_browser_release_artifact_bundle as bundle_builder  # type: ignore
    import build_browser_proof_page_receipt as proof_page_builder  # type: ignore
    import build_browser_published_proof_surface as proof_surface_builder  # type: ignore
    import build_browser_release_launch_receipt as launch_builder  # type: ignore
    import check_browser_published_proof_surface as proof_surface_check  # type: ignore
    import check_browser_release_candidate_provenance as provenance_check  # type: ignore


PRODUCT_DISPLAY_NAMES = {
    "doe-browser": "Doe Browser",
    "fawn-doe": "Fawn Doe",
}
GALLERY_CATEGORIES = ("compute", "rendering", "tensor", "shader_edge", "benchmark_trace")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--surface-template", required=True)
    parser.add_argument("--release-archive", required=True)
    parser.add_argument("--release-archive-url", required=True)
    parser.add_argument("--release-archive-manifest", required=True)
    parser.add_argument("--public-download-receipt", required=True)
    parser.add_argument("--proof-page-artifact", required=True)
    parser.add_argument("--proof-page-url", default="about:doe")
    parser.add_argument("--proof-page-receipt-id", required=True)
    parser.add_argument("--browser-launch-receipt-id", required=True)
    parser.add_argument(
        "--package-inputs",
        default="",
        help=(
            "Required browser_release_package_inputs_check report used as the "
            "release-candidate source of truth for product/platform/member paths."
        ),
    )
    parser.add_argument("--product-id", choices=tuple(PRODUCT_DISPLAY_NAMES), default="fawn-doe")
    parser.add_argument("--product-name", choices=tuple(PRODUCT_DISPLAY_NAMES.values()), default="Fawn Doe")
    parser.add_argument("--product-version", default="")
    parser.add_argument("--product-channel", choices=("release_candidate",), default="release_candidate")
    parser.add_argument("--platform-os", choices=("macos", "linux"), default="macos")
    parser.add_argument("--platform-arch", choices=("arm64", "x64"), default="arm64")
    parser.add_argument("--package-format", choices=("zip",), default="zip")
    parser.add_argument("--browser-executable-archive-path", default="")
    parser.add_argument("--browser-app-metadata-archive-path", default="")
    parser.add_argument("--doe-runtime-archive-path", default="")
    parser.add_argument("--dawn-fallback-runtime-archive-path", default="")
    parser.add_argument("--active-backend", default="webgpu-doe")
    parser.add_argument("--compiler-path", default="")
    parser.add_argument("--tsir-status", required=True)
    parser.add_argument("--host-plan-status", required=True)
    parser.add_argument("--csl-status", required=True)
    parser.add_argument("--gallery-category", choices=GALLERY_CATEGORIES, default="compute")
    parser.add_argument("--surface-id", default="")
    parser.add_argument("--capture-policy-path", default="")
    parser.add_argument("--runtime-identity-path", default="")
    parser.add_argument("--observed-at", default="")
    parser.add_argument("--proof-page-receipt-out", required=True)
    parser.add_argument("--proof-surface-out", required=True)
    parser.add_argument("--proof-surface-check-out", required=True)
    parser.add_argument("--browser-launch-receipt-out", required=True)
    parser.add_argument("--provenance-report-out", required=True)
    parser.add_argument("--verify-files-root", default="")
    parser.add_argument("--json", action="store_true", dest="emit_json")
    return parser.parse_args()


def load_json_object(path: Path, label: str) -> dict[str, Any]:
    payload = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(payload, dict):
        raise ValueError(f"{label} must be a JSON object: {path}")
    return payload


def write_json(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")


def resolve_stage_path(path_text: str, artifact_root: Path | None) -> Path:
    path = Path(path_text)
    if path.is_absolute() or artifact_root is None:
        return path
    return artifact_root.joinpath(*PurePosixPath(path_text).parts)


def proof_surface_artifact_path(path_text: str, artifact_root: Path | None) -> str:
    return proof_surface_builder.repo_relative(resolve_stage_path(path_text, artifact_root))


def gallery_entries_from_surface(
    surface: dict[str, Any],
    artifact_root: Path | None,
) -> list[dict[str, Any]]:
    rows = surface.get("galleryPages")
    if not isinstance(rows, list) or not rows:
        raise ValueError("surface template must include galleryPages")
    entries: list[dict[str, Any]] = []
    for row in rows:
        if not isinstance(row, dict):
            raise ValueError("surface template galleryPages entries must be objects")
        artifact = row.get("artifact")
        public_receipt = row.get("publicReceipt")
        receipt_artifacts = row.get("receiptArtifacts")
        if (
            not isinstance(artifact, dict)
            or not isinstance(public_receipt, dict)
            or not isinstance(receipt_artifacts, list)
        ):
            raise ValueError("surface template gallery page is missing artifact links")
        entries.append(
            {
                "category": row.get("category"),
                "url": row.get("url"),
                "artifact": str(resolve_stage_path(artifact.get("path"), artifact_root)),
                "publicReceipt": str(resolve_stage_path(public_receipt.get("path"), artifact_root)),
                "workloadContractPath": row.get("workloadContractPath"),
                "receiptPayloads": [
                    str(resolve_stage_path(artifact_row.get("path"), artifact_root))
                    for artifact_row in receipt_artifacts
                    if isinstance(artifact_row, dict)
                ],
            }
        )
    return entries


def comparison_entries_from_surface(
    surface: dict[str, Any],
    artifact_root: Path | None,
) -> list[dict[str, Any]]:
    rows = surface.get("comparisonReceipts")
    if not isinstance(rows, list) or not rows:
        raise ValueError("surface template must include comparisonReceipts")
    entries: list[dict[str, Any]] = []
    for row in rows:
        if not isinstance(row, dict):
            raise ValueError("surface template comparisonReceipts entries must be objects")
        runner = row.get("runner")
        comparison_artifact = row.get("comparisonArtifact")
        dawn_receipt = row.get("dawnReceipt")
        doe_receipt = row.get("doeReceipt")
        if (
            not isinstance(runner, dict)
            or not isinstance(comparison_artifact, dict)
            or not isinstance(dawn_receipt, dict)
            or not isinstance(doe_receipt, dict)
        ):
            raise ValueError("surface template comparison receipt is missing artifact links")
        entries.append(
            {
                "comparisonId": row.get("comparisonId"),
                "workloadId": row.get("workloadId"),
                "pageArtifactPath": proof_surface_artifact_path(
                    runner.get("pageArtifactPath"),
                    artifact_root,
                ),
                "comparisonArtifact": str(resolve_stage_path(comparison_artifact.get("path"), artifact_root)),
                "dawnReceipt": str(resolve_stage_path(dawn_receipt.get("path"), artifact_root)),
                "doeReceipt": str(resolve_stage_path(doe_receipt.get("path"), artifact_root)),
            }
        )
    return entries


def proof_receipt_payloads_from_surface(
    surface: dict[str, Any],
    artifact_root: Path | None,
) -> list[Path]:
    proof_page = surface.get("proofPage")
    if not isinstance(proof_page, dict):
        raise ValueError("surface template must include proofPage")
    receipt_payloads = proof_page.get("receiptPayloads")
    if not isinstance(receipt_payloads, list) or not receipt_payloads:
        raise ValueError("surface template proofPage.receiptPayloads must be non-empty")
    paths: list[Path] = []
    for row in receipt_payloads:
        if not isinstance(row, dict) or not isinstance(row.get("path"), str):
            raise ValueError("surface template proofPage receipt payload paths are required")
        paths.append(resolve_stage_path(row["path"], artifact_root))
    return paths


def select_gallery(surface: dict[str, Any], category: str) -> dict[str, Any]:
    rows = surface.get("galleryPages")
    if not isinstance(rows, list):
        raise ValueError("proof surface must include galleryPages")
    for row in rows:
        if isinstance(row, dict) and row.get("category") == category:
            return row
    raise ValueError(f"proof surface has no gallery category: {category}")


def select_comparison(surface: dict[str, Any], gallery_artifact_path: str) -> dict[str, Any]:
    rows = surface.get("comparisonReceipts")
    if not isinstance(rows, list):
        raise ValueError("proof surface must include comparisonReceipts")
    for row in rows:
        if not isinstance(row, dict):
            continue
        runner = row.get("runner")
        if isinstance(runner, dict) and runner.get("pageArtifactPath") == gallery_artifact_path:
            return row
    raise ValueError("proof surface has no same-page comparison for selected gallery")


def artifact_path(row: dict[str, Any], label: str) -> str:
    artifact = row.get(label)
    if not isinstance(artifact, dict) or not isinstance(artifact.get("path"), str):
        raise ValueError(f"proof surface {label}.path is required")
    return artifact["path"]


def receipt_id_from_artifact(path_text: str, artifact_root: Path | None) -> str:
    payload = load_json_object(resolve_stage_path(path_text, artifact_root), "receipt artifact")
    receipt_id = payload.get("receiptId")
    if not isinstance(receipt_id, str) or not receipt_id:
        raise ValueError(f"receipt artifact missing receiptId: {path_text}")
    return receipt_id


def dedupe(values: list[str]) -> list[str]:
    seen: set[str] = set()
    result: list[str] = []
    for value in values:
        if value in seen:
            continue
        seen.add(value)
        result.append(value)
    return result


def build_stage(args: argparse.Namespace) -> dict[str, Any]:
    template = load_json_object(Path(args.surface_template), "surface template")
    artifact_root = Path(args.verify_files_root).resolve() if args.verify_files_root else None
    identity_root = artifact_root or provenance_check.REPO_ROOT
    if not args.package_inputs:
        raise ValueError("release-candidate provenance staging requires --package-inputs")
    package_inputs, package_inputs_path, package_input_failures = provenance_check.load_package_inputs_report(
        args.package_inputs,
        identity_root,
    )
    if package_input_failures:
        raise ValueError(package_input_failures[0]["message"])
    if package_inputs is None:
        raise ValueError("release-candidate provenance staging requires --package-inputs")
    browser_product, platform, members = provenance_check.candidate_identity(
        product_id=args.product_id,
        product_name=args.product_name,
        product_version=args.product_version,
        product_channel=args.product_channel,
        platform_os=args.platform_os,
        platform_arch=args.platform_arch,
        package_format=args.package_format,
        browser_executable_archive_path=args.browser_executable_archive_path,
        browser_app_metadata_archive_path=args.browser_app_metadata_archive_path,
        doe_runtime_archive_path=args.doe_runtime_archive_path,
        dawn_fallback_runtime_archive_path=args.dawn_fallback_runtime_archive_path,
        package_inputs=package_inputs,
    )
    package_compiler_path = bundle_builder.package_input_path(
        package_inputs,
        "shaderCompiler",
    )
    if args.compiler_path and not provenance_check.path_matches(
        args.compiler_path,
        package_compiler_path,
        identity_root,
    ):
        raise ValueError("--compiler-path must match package inputs role shaderCompiler")
    compiler_path = args.compiler_path or package_compiler_path
    if not compiler_path:
        compiler_path = "runtime/zig/zig-out/bin/doe-zig-runtime"
    diagnostics = {
        "activeRuntime": "doe",
        "activeBackend": args.active_backend,
        "webgpuAvailable": True,
        "compilerPath": compiler_path,
        "tsirStatus": args.tsir_status,
        "hostPlanStatus": args.host_plan_status,
        "cslStatus": args.csl_status,
        "fallbackPolicyState": "hidden_fallback_disabled",
    }
    runtime_identity_path = args.runtime_identity_path or template.get("runtimeIdentityPath")
    if not isinstance(runtime_identity_path, str) or not runtime_identity_path:
        raise ValueError("runtime identity path is required")
    capture_policy_path = args.capture_policy_path or template.get("capturePolicyPath")
    if not isinstance(capture_policy_path, str) or not capture_policy_path:
        raise ValueError("capture policy path is required")
    surface_id = args.surface_id or template.get("surfaceId")
    if not isinstance(surface_id, str) or not surface_id:
        raise ValueError("surface id is required")
    release_provenance = proof_page_builder.build_release_provenance(
        release_archive=Path(args.release_archive),
        release_archive_url=args.release_archive_url,
        release_archive_manifest=Path(args.release_archive_manifest),
        public_download_receipt=Path(args.public_download_receipt),
        browser_product=browser_product,
        platform=platform,
        browser_executable_archive_path=members["browserExecutable"],
        browser_app_metadata_archive_path=members["appMetadata"],
        doe_runtime_archive_path=members["doeRuntime"],
        dawn_fallback_runtime_archive_path=members["dawnFallbackRuntime"],
    )
    comparison_entries = comparison_entries_from_surface(template, artifact_root)
    selected_template_gallery = select_gallery(template, args.gallery_category)
    selected_template_gallery_artifact = selected_template_gallery.get("artifact")
    if not isinstance(selected_template_gallery_artifact, dict) or not isinstance(selected_template_gallery_artifact.get("path"), str):
        raise ValueError("selected template gallery artifact path is required")
    selected_template_comparison = select_comparison(
        template,
        selected_template_gallery_artifact["path"],
    )
    dawn_receipt = selected_template_comparison.get("dawnReceipt")
    doe_receipt = selected_template_comparison.get("doeReceipt")
    if not isinstance(dawn_receipt, dict) or not isinstance(doe_receipt, dict):
        raise ValueError("selected comparison must include Dawn and Doe receipts")
    recent_receipt_ids = [
        str(dawn_receipt.get("receiptId")),
        str(doe_receipt.get("receiptId")),
    ]
    proof_receipt = proof_page_builder.build_receipt(
        receipt_id=args.proof_page_receipt_id,
        url=args.proof_page_url,
        proof_artifact=Path(args.proof_page_artifact),
        proof_artifact_path=proof_page_builder.repo_relative(Path(args.proof_page_artifact)),
        runtime_identity_path=runtime_identity_path,
        diagnostics=diagnostics,
        release_provenance=release_provenance,
        recent_receipt_ids=recent_receipt_ids,
        observed_at=args.observed_at or proof_page_builder.observed_at_now(),
    )
    proof_page_receipt_out = Path(args.proof_page_receipt_out)
    write_json(proof_page_receipt_out, proof_receipt)
    proof_surface = proof_surface_builder.build_surface(
        surface_id=surface_id,
        capture_policy_path=capture_policy_path,
        runtime_identity_path=runtime_identity_path,
        proof_artifact=Path(args.proof_page_artifact),
        proof_receipt=proof_page_receipt_out,
        proof_receipt_payloads=proof_receipt_payloads_from_surface(template, artifact_root),
        gallery_entries=gallery_entries_from_surface(template, artifact_root),
        comparison_entries=comparison_entries,
    )
    proof_surface_out = Path(args.proof_surface_out)
    write_json(proof_surface_out, proof_surface)
    proof_surface_check_out = Path(args.proof_surface_check_out)
    write_json(
        proof_surface_check_out,
        proof_surface_check.build_report(
            proof_surface_out,
            verify_files_root=artifact_root,
            require_public_urls=True,
        ),
    )

    selected_gallery = select_gallery(proof_surface, args.gallery_category)
    selected_gallery_artifact_path = artifact_path(selected_gallery, "artifact")
    selected_comparison = select_comparison(proof_surface, selected_gallery_artifact_path)
    gallery_receipt_path = artifact_path(selected_gallery, "publicReceipt")
    gallery_receipt_id = receipt_id_from_artifact(gallery_receipt_path, artifact_root)
    launch_receipt = launch_builder.build_receipt(
        receipt_id=args.browser_launch_receipt_id,
        observed_at=args.observed_at or launch_builder.observed_at_now(),
        release_archive=Path(args.release_archive),
        release_archive_url=args.release_archive_url,
        release_archive_manifest=Path(args.release_archive_manifest),
        proof_surface=proof_surface_out,
        browser_product=browser_product,
        platform=platform,
        browser_executable_archive_path=members["browserExecutable"],
        browser_app_metadata_archive_path=members["appMetadata"],
        doe_runtime_archive_path=members["doeRuntime"],
        dawn_fallback_runtime_archive_path=members["dawnFallbackRuntime"],
        active_backend=args.active_backend,
        proof_page_url=proof_surface["proofPage"]["url"],
        proof_page_artifact_path=proof_surface["proofPage"]["artifact"]["path"],
        proof_page_receipt_id=args.proof_page_receipt_id,
        gallery_url=selected_gallery["url"],
        gallery_category=selected_gallery["category"],
        gallery_artifact_path=selected_gallery_artifact_path,
        gallery_receipt_id=gallery_receipt_id,
        comparison_id=selected_comparison["comparisonId"],
        comparison_workload_id=selected_comparison["workloadId"],
        comparison_page_artifact_path=selected_comparison["runner"]["pageArtifactPath"],
        comparison_artifact_path=selected_comparison["comparisonArtifact"]["path"],
        comparison_dawn_receipt_id=selected_comparison["dawnReceipt"]["receiptId"],
        comparison_doe_receipt_id=selected_comparison["doeReceipt"]["receiptId"],
        observed_receipt_ids=dedupe(
            [
                args.proof_page_receipt_id,
                gallery_receipt_id,
                selected_comparison["dawnReceipt"]["receiptId"],
                selected_comparison["doeReceipt"]["receiptId"],
            ]
        ),
    )
    browser_launch_receipt_out = Path(args.browser_launch_receipt_out)
    write_json(browser_launch_receipt_out, launch_receipt)
    provenance_report = provenance_check.build_report(
        release_archive=Path(args.release_archive),
        release_archive_url=args.release_archive_url,
        release_archive_manifest=Path(args.release_archive_manifest),
        public_download_receipt=Path(args.public_download_receipt),
        proof_surface=proof_surface_out,
        proof_surface_check=proof_surface_check_out,
        browser_launch_receipt=browser_launch_receipt_out,
        browser_product=browser_product,
        platform=platform,
        browser_executable_archive_path=members["browserExecutable"],
        browser_app_metadata_archive_path=members["appMetadata"],
        doe_runtime_archive_path=members["doeRuntime"],
        dawn_fallback_runtime_archive_path=members["dawnFallbackRuntime"],
        package_inputs=package_inputs_path,
        verify_files_root=Path(args.verify_files_root) if args.verify_files_root else None,
    )
    write_json(Path(args.provenance_report_out), provenance_report)
    return {
        "schemaVersion": 1,
        "artifactKind": "browser_release_candidate_provenance_stage",
        "status": provenance_report["status"],
        "outputs": {
            "proofPageReceipt": str(proof_page_receipt_out),
            "proofSurface": str(proof_surface_out),
            "proofSurfaceCheck": str(proof_surface_check_out),
            "browserLaunchReceipt": str(browser_launch_receipt_out),
            "provenanceReport": args.provenance_report_out,
        },
        "provenanceSummary": provenance_report["summary"],
    }


def main() -> int:
    args = parse_args()
    try:
        summary = build_stage(args)
    except Exception as exc:
        sys.stderr.write(f"stage_browser_release_candidate_provenance: {exc}\n")
        return 1
    if args.emit_json:
        print(json.dumps(summary, indent=2))
    return 0 if summary["status"] == "pass" else 1


if __name__ == "__main__":
    sys.exit(main())
