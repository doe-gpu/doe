#!/usr/bin/env python3
"""Finalize a browser release-candidate bundle after provenance staging."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

try:
    from bench.tools import build_browser_release_artifact_bundle as bundle_builder
except ModuleNotFoundError:
    import build_browser_release_artifact_bundle as bundle_builder  # type: ignore

try:
    from bench.tools import check_browser_release_candidate_provenance as provenance_check
except ModuleNotFoundError:
    import check_browser_release_candidate_provenance as provenance_check  # type: ignore

try:
    from bench.tools import check_browser_release_artifact_bundle as release_check
except ModuleNotFoundError:
    import check_browser_release_artifact_bundle as release_check  # type: ignore

try:
    from bench.tools import check_browser_release_package_inputs as package_inputs_check
except ModuleNotFoundError:
    import check_browser_release_package_inputs as package_inputs_check  # type: ignore


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--bundle-id", required=True)
    parser.add_argument("--provenance-report", required=True)
    parser.add_argument("--release-archive", required=True)
    parser.add_argument("--release-archive-url", required=True)
    parser.add_argument("--release-archive-manifest", required=True)
    parser.add_argument("--public-download-receipt", required=True)
    parser.add_argument("--proof-surface", required=True)
    parser.add_argument("--proof-surface-check", required=True)
    parser.add_argument("--browser-launch-receipt", required=True)
    parser.add_argument("--chromium-source-checkout", required=True)
    parser.add_argument("--runtime-identity", required=True)
    parser.add_argument("--runtime-frontier-bundle-out", required=True)
    parser.add_argument(
        "--package-inputs",
        default="",
        help=(
            "Required browser_release_package_inputs_check report used as the "
            "release-candidate source of truth for package identity and binary paths."
        ),
    )
    parser.add_argument("--browser-binary", default="")
    parser.add_argument("--doe-runtime", default="")
    parser.add_argument("--dawn-fallback-runtime", default="")
    parser.add_argument("--shader-compiler", default="")
    parser.add_argument("--claim-report", action="append", required=True)
    parser.add_argument("--promotion-receipt", action="append", required=True)
    parser.add_argument("--contract", action="append", default=[])
    parser.add_argument("--policy", action="append", default=[])
    parser.add_argument("--product-id", choices=("doe-browser", "fawn-doe"), default="fawn-doe")
    parser.add_argument("--product-name", choices=("Doe Browser", "Fawn Doe"), default="Fawn Doe")
    parser.add_argument("--product-version", default="")
    parser.add_argument("--browser-executable-archive-path", default="")
    parser.add_argument("--browser-app-metadata-archive-path", default="")
    parser.add_argument("--doe-runtime-archive-path", default="")
    parser.add_argument("--dawn-fallback-runtime-archive-path", default="")
    parser.add_argument("--verify-files-root", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--report-out", required=True)
    parser.add_argument("--json", action="store_true", dest="emit_json")
    return parser.parse_args()


def load_json_object(path: Path, label: str) -> dict[str, Any]:
    payload = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(payload, dict):
        raise ValueError(f"{label} must be a JSON object: {path}")
    return payload


def failure(code: str, path: str, message: str) -> dict[str, str]:
    return {"code": code, "path": path, "message": message}


def fail_report(phase: str, failures: list[dict[str, str]]) -> dict[str, Any]:
    return {
        "schemaVersion": 1,
        "artifactKind": "browser_release_candidate_finalizer",
        "status": "fail",
        "phase": phase,
        "failures": failures,
    }


def string_map(value: Any) -> dict[str, str] | None:
    if not isinstance(value, dict):
        return None
    result: dict[str, str] = {}
    for key, item in value.items():
        if not isinstance(key, str) or not isinstance(item, str):
            return None
        result[key] = item
    return result


def load_package_inputs_report(
    path_text: str,
    root: Path,
) -> tuple[dict[str, Any] | None, Path | None, list[dict[str, str]]]:
    if not path_text:
        return None, None, [
            failure(
                "missing_package_inputs",
                "packageInputs",
                "release-candidate finalizer requires --package-inputs",
            )
        ]
    resolved_path = resolve_under_root(path_text, root)
    if resolved_path is None:
        return None, None, [
            failure(
                "unsafe_package_inputs_path",
                "packageInputs.path",
                f"package inputs report must resolve under --verify-files-root: {path_text}",
            )
        ]
    try:
        payload = bundle_builder.package_inputs_descriptor(str(resolved_path))
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        return None, resolved_path, [
            failure(
                "package_inputs_report_invalid",
                "packageInputs",
                f"package inputs report must be a passing browser_release_package_inputs_check: {exc}",
            )
        ]
    failures: list[dict[str, str]] = []
    if payload.get("releaseCandidateEligible") is not True:
        failures.append(
            failure(
                "package_inputs_not_release_candidate_eligible",
                "packageInputs.releaseCandidateEligible",
                "package inputs must be release-candidate eligible before final bundle assembly",
            )
        )
    if payload.get("evidenceMode") != "release_candidate":
        failures.append(
            failure(
                "package_inputs_not_release_candidate_evidence",
                "packageInputs.evidenceMode",
                "package inputs evidenceMode must be release_candidate before final bundle assembly",
            )
        )
    if payload.get("releaseCandidateBlockers") != []:
        failures.append(
            failure(
                "package_inputs_release_candidate_blockers_present",
                "packageInputs.releaseCandidateBlockers",
                "package inputs must carry no release-candidate blockers before final bundle assembly",
            )
        )
    if payload.get("failures") != []:
        failures.append(
            failure(
                "package_inputs_failures_present",
                "packageInputs.failures",
                "package inputs must carry no failures before final bundle assembly",
            )
        )
    summary = payload.get("summary")
    if not isinstance(summary, dict) or summary.get("packageable") is not True:
        failures.append(
            failure(
                "package_inputs_summary_not_packageable",
                "packageInputs.summary.packageable",
                "package inputs summary.packageable must be true before final bundle assembly",
            )
        )
    failures.extend(
        package_inputs_check.release_candidate_binary_identity_failures(
            payload,
            path_prefix="packageInputs",
        )
    )
    return payload, resolved_path, failures


def package_browser_product(
    package_inputs: dict[str, Any] | None,
    args: argparse.Namespace,
) -> tuple[dict[str, str], list[dict[str, str]]]:
    if package_inputs is not None:
        product = string_map(package_inputs.get("browserProduct"))
        if product is None:
            return {}, [
                failure(
                    "package_inputs_product_invalid",
                    "packageInputs.browserProduct",
                    "package inputs browserProduct must be a string object",
                )
            ]
        return product, []
    if not args.product_version:
        return {}, [
            failure(
                "missing_product_version",
                "productVersion",
                "--product-version is required when --package-inputs is not provided",
            )
        ]
    return {
        "productId": args.product_id,
        "displayName": args.product_name,
        "version": args.product_version,
        "channel": "release_candidate",
    }, []


def resolve_under_root(path_text: str, root: Path) -> Path | None:
    return provenance_check.resolve_path(path_text, root)


def resolve_file_input(
    *,
    explicit_path: str,
    package_inputs: dict[str, Any] | None,
    role: str,
    option: str,
    root: Path,
) -> tuple[Path | None, list[dict[str, str]]]:
    failures: list[dict[str, str]] = []
    derived_path = ""
    if package_inputs is not None:
        try:
            derived_path = bundle_builder.package_input_path(package_inputs, role)
        except ValueError as exc:
            failures.append(
                failure(
                    "package_inputs_missing_path",
                    f"packageInputs.inputs.{role}.path",
                    str(exc),
                )
            )
    if explicit_path and derived_path and not provenance_check.path_matches(
        explicit_path,
        derived_path,
        root,
    ):
        failures.append(
            failure(
                "package_inputs_path_mismatch",
                option,
                f"{option} must match package inputs role {role}",
            )
        )
    path_text = explicit_path or derived_path
    if not path_text:
        failures.append(
            failure(
                "missing_finalizer_input_path",
                option,
                f"{option} is required when --package-inputs does not provide {role}",
            )
        )
        return None, failures
    resolved = resolve_under_root(path_text, root)
    if resolved is None:
        failures.append(
            failure(
                "unsafe_finalizer_input_path",
                option,
                f"{option} must resolve under --verify-files-root: {path_text}",
            )
        )
        return None, failures
    return resolved, failures


def resolve_archive_input(
    *,
    explicit_path: str,
    package_inputs: dict[str, Any] | None,
    role: str,
    option: str,
) -> tuple[str, list[dict[str, str]]]:
    failures: list[dict[str, str]] = []
    derived_path = ""
    if package_inputs is not None:
        try:
            derived_path = bundle_builder.package_input_archive_path(package_inputs, role)
        except ValueError as exc:
            failures.append(
                failure(
                    "package_inputs_missing_archive_path",
                    f"packageInputs.inputs.{role}.archivePath",
                    str(exc),
                )
            )
    if explicit_path and derived_path and explicit_path != derived_path:
        failures.append(
            failure(
                "package_inputs_archive_path_mismatch",
                option,
                f"{option} must match package inputs role {role}",
            )
        )
    path_text = explicit_path or derived_path
    if not path_text:
        failures.append(
            failure(
                "missing_finalizer_archive_path",
                option,
                f"{option} is required when --package-inputs does not provide {role}",
            )
        )
    return path_text, failures


def resolve_finalizer_package_inputs(
    args: argparse.Namespace,
    package_inputs: dict[str, Any] | None,
    verify_files_root: Path,
) -> tuple[dict[str, Any], list[dict[str, str]]]:
    failures: list[dict[str, str]] = []
    file_specs = {
        "browser_binary": ("browserExecutable", "--browser-binary", args.browser_binary),
        "doe_runtime": ("doeRuntime", "--doe-runtime", args.doe_runtime),
        "dawn_fallback_runtime": (
            "dawnFallbackRuntime",
            "--dawn-fallback-runtime",
            args.dawn_fallback_runtime,
        ),
        "shader_compiler": ("shaderCompiler", "--shader-compiler", args.shader_compiler),
    }
    resolved: dict[str, Any] = {}
    for key, (role, option, explicit_path) in file_specs.items():
        path, path_failures = resolve_file_input(
            explicit_path=explicit_path,
            package_inputs=package_inputs,
            role=role,
            option=option,
            root=verify_files_root,
        )
        failures.extend(path_failures)
        if path is not None:
            resolved[key] = path

    archive_specs = {
        "browser_executable_archive_path": (
            "browserExecutable",
            "--browser-executable-archive-path",
            args.browser_executable_archive_path,
        ),
        "browser_app_metadata_archive_path": (
            "appMetadata",
            "--browser-app-metadata-archive-path",
            args.browser_app_metadata_archive_path,
        ),
        "doe_runtime_archive_path": (
            "doeRuntime",
            "--doe-runtime-archive-path",
            args.doe_runtime_archive_path,
        ),
        "dawn_fallback_runtime_archive_path": (
            "dawnFallbackRuntime",
            "--dawn-fallback-runtime-archive-path",
            args.dawn_fallback_runtime_archive_path,
        ),
    }
    for key, (role, option, explicit_path) in archive_specs.items():
        path_text, path_failures = resolve_archive_input(
            explicit_path=explicit_path,
            package_inputs=package_inputs,
            role=role,
            option=option,
        )
        failures.extend(path_failures)
        if path_text:
            resolved[key] = path_text
    return resolved, failures


def artifact_matches(
    report_artifact: Any,
    path: Path,
    kind: str,
    *,
    root: Path,
    download_url: str = "",
) -> bool:
    if not isinstance(report_artifact, dict):
        return False
    if not provenance_check.path_matches(
        report_artifact.get("path"),
        bundle_builder.repo_relative(path),
        root,
    ):
        return False
    if report_artifact.get("sha256") != bundle_builder.sha256_file(path):
        return False
    if report_artifact.get("kind") != kind:
        return False
    if download_url and report_artifact.get("downloadUrl") != download_url:
        return False
    return True


def check_provenance_report(
    report: dict[str, Any],
    *,
    release_archive: Path,
    release_archive_manifest: Path,
    public_download_receipt: Path,
    proof_surface: Path,
    proof_surface_check: Path,
    browser_launch_receipt: Path,
    browser_product: dict[str, str],
    platform: dict[str, str],
    release_archive_url: str,
    package_inputs: Path | None,
    verify_files_root: Path,
) -> list[dict[str, str]]:
    failures: list[dict[str, str]] = []
    if report.get("artifactKind") != "browser_release_candidate_provenance_report":
        failures.append(
            {
                "code": "provenance_report_wrong_kind",
                "path": "provenanceReport.artifactKind",
                "message": "provenance report artifactKind must be browser_release_candidate_provenance_report",
            }
        )
    if report.get("status") != "pass":
        failures.append(
            {
                "code": "provenance_report_not_pass",
                "path": "provenanceReport.status",
                "message": "release-candidate provenance report must pass before final bundle assembly",
            }
        )
    if report.get("releaseStatus") != "release_candidate":
        failures.append(
            {
                "code": "provenance_report_status_mismatch",
                "path": "provenanceReport.releaseStatus",
                "message": "provenance report releaseStatus must be release_candidate",
            }
        )
    if report.get("browserProduct") != browser_product:
        failures.append(
            {
                "code": "provenance_report_product_mismatch",
                "path": "provenanceReport.browserProduct",
                "message": "provenance report browserProduct must match final bundle product",
            }
        )
    if report.get("platform") != platform:
        failures.append(
            {
                "code": "provenance_report_platform_mismatch",
                "path": "provenanceReport.platform",
                "message": "provenance report platform must match final bundle platform",
            }
        )
    component_artifacts = report.get("componentArtifacts")
    if not isinstance(component_artifacts, dict):
        return failures + [
            {
                "code": "provenance_report_missing_components",
                "path": "provenanceReport.componentArtifacts",
                "message": "provenance report componentArtifacts are required",
            }
        ]
    expected = (
        ("releaseArchive", release_archive, "browser_release_archive", release_archive_url),
        ("releaseArchiveManifest", release_archive_manifest, "browser_release_archive_manifest", ""),
        ("publicDownloadReceipt", public_download_receipt, "browser_public_download_receipt", ""),
        ("proofSurface", proof_surface, "browser_published_proof_surface", ""),
        ("proofSurfaceCheck", proof_surface_check, "browser_published_proof_surface_check", ""),
        ("browserLaunchReceipt", browser_launch_receipt, "browser_release_launch_receipt", ""),
    )
    for field, path, kind, download_url in expected:
        if not artifact_matches(
            component_artifacts.get(field),
            path,
            kind,
            root=verify_files_root,
            download_url=download_url,
        ):
            failures.append(
                {
                    "code": "provenance_report_component_mismatch",
                    "path": f"provenanceReport.componentArtifacts.{field}",
                    "message": f"provenance report component must match final bundle input: {field}",
                }
            )
    if package_inputs is not None and not artifact_matches(
        component_artifacts.get("packageInputs"),
        package_inputs,
        "browser_release_package_inputs_check",
        root=verify_files_root,
    ):
        failures.append(
            {
                "code": "provenance_report_component_mismatch",
                "path": "provenanceReport.componentArtifacts.packageInputs",
                "message": "provenance report component must match final bundle input: packageInputs",
            }
        )
    return failures


def build_final_bundle(args: argparse.Namespace) -> tuple[dict[str, Any], dict[str, Any], dict[str, Any]]:
    verify_files_root = Path(args.verify_files_root).resolve()
    out_path = Path(args.out)
    runtime_frontier_bundle = Path(args.runtime_frontier_bundle_out)
    release_archive = Path(args.release_archive)
    release_archive_manifest = Path(args.release_archive_manifest)
    public_download_receipt = Path(args.public_download_receipt)
    proof_surface = Path(args.proof_surface)
    proof_surface_check = Path(args.proof_surface_check)
    browser_launch_receipt = Path(args.browser_launch_receipt)
    package_inputs, package_inputs_path, package_input_failures = load_package_inputs_report(
        args.package_inputs,
        verify_files_root,
    )
    platform = (
        string_map(package_inputs.get("platform"))
        if package_inputs is not None
        else None
    )
    browser_product, product_failures = package_browser_product(package_inputs, args)
    resolved_inputs, input_failures = resolve_finalizer_package_inputs(
        args,
        package_inputs,
        verify_files_root,
    )
    preflight_failures = package_input_failures + product_failures + input_failures
    if platform is None or package_inputs_check.release_platform_contract(platform) is None:
        preflight_failures.append(
            failure(
                "package_inputs_platform_unsupported",
                "packageInputs.platform",
                (
                    "release-candidate finalizer requires a platform declared in "
                    "config/browser-release-platform-policy.json"
                ),
            )
        )
    if browser_product and browser_product.get("channel") != "release_candidate":
        preflight_failures.append(
            failure(
                "package_inputs_channel_mismatch",
                "browserProduct.channel",
                "release-candidate finalizer requires browserProduct.channel=release_candidate",
            )
        )
    if preflight_failures or platform is None:
        return {}, {}, fail_report("package_inputs_preflight", preflight_failures)

    provenance_report = load_json_object(Path(args.provenance_report), "provenance report")
    provenance_failures = check_provenance_report(
        provenance_report,
        release_archive=release_archive,
        release_archive_manifest=release_archive_manifest,
        public_download_receipt=public_download_receipt,
        proof_surface=proof_surface,
        proof_surface_check=proof_surface_check,
        browser_launch_receipt=browser_launch_receipt,
        browser_product=browser_product,
        platform=platform,
        release_archive_url=args.release_archive_url,
        package_inputs=package_inputs_path,
        verify_files_root=verify_files_root,
    )
    if provenance_failures:
        return {}, {}, fail_report("provenance_preflight", provenance_failures)

    claim_reports = [Path(value) for value in args.claim_report]
    promotion_receipts = [Path(value) for value in args.promotion_receipt]
    bundle = bundle_builder.build_bundle(
        bundle_id=args.bundle_id,
        release_status="release_candidate",
        release_archive=release_archive,
        release_archive_url=args.release_archive_url,
        release_archive_manifest=release_archive_manifest,
        public_download_receipt=public_download_receipt,
        package_inputs=package_inputs_path,
        browser_product=browser_product,
        platform=platform,
        browser_binary_archive_path=resolved_inputs["browser_executable_archive_path"],
        browser_app_metadata_archive_path=resolved_inputs["browser_app_metadata_archive_path"],
        doe_runtime_archive_path=resolved_inputs["doe_runtime_archive_path"],
        dawn_fallback_runtime_archive_path=resolved_inputs["dawn_fallback_runtime_archive_path"],
        browser_binary=resolved_inputs["browser_binary"],
        doe_runtime=resolved_inputs["doe_runtime"],
        dawn_fallback_runtime=resolved_inputs["dawn_fallback_runtime"],
        shader_compiler=resolved_inputs["shader_compiler"],
        proof_surface=proof_surface,
        proof_surface_check=proof_surface_check,
        chromium_source_checkout=Path(args.chromium_source_checkout),
        browser_launch_receipt=browser_launch_receipt,
        contracts=bundle_builder.defaulted_paths(args.contract, bundle_builder.DEFAULT_CONTRACTS),
        claim_reports=claim_reports,
        promotion_receipts=promotion_receipts,
        policies=bundle_builder.defaulted_paths(args.policy, bundle_builder.DEFAULT_POLICIES),
    )
    promotion_receipt = bundle_builder.runtime_frontier_promotion_receipt_path(
        "",
        promotion_receipts,
    )
    final_bundle, frontier_report, verification_failures = (
        bundle_builder.bootstrap_runtime_frontier_bundle(
            bundle,
            out_path=out_path,
            runtime_frontier_bundle=runtime_frontier_bundle,
            runtime_identity=Path(args.runtime_identity),
            claim_promotion_receipt=promotion_receipt,
            verify_files_root=verify_files_root,
        )
    )
    if verification_failures:
        return final_bundle, frontier_report, fail_report(
            "release_bundle_verification",
            verification_failures,
        )
    bundle_builder.write_json(out_path, final_bundle)
    report = {
        "schemaVersion": 1,
        "artifactKind": "browser_release_candidate_finalizer",
        "status": "pass",
        "inputs": {
            "packageInputs": bundle_builder.artifact(
                package_inputs_path,
                "browser_release_package_inputs_check",
                "browser release package inputs check",
            ),
            "provenanceReport": bundle_builder.artifact(
                Path(args.provenance_report),
                "browser_release_candidate_provenance_report",
                "browser release-candidate provenance report",
            ),
        },
        "outputs": {
            "releaseArtifactBundle": bundle_builder.artifact(
                out_path,
                "browser_release_artifact_bundle",
                "browser release artifact bundle",
            ),
            "runtimeFrontierBundle": bundle_builder.artifact(
                runtime_frontier_bundle,
                "browser_runtime_frontier_bundle",
                "browser runtime frontier bundle",
            ),
        },
        "summary": {
            "claimabilityStatus": frontier_report.get("claimabilityStatus"),
            "releaseBundleIdentitySha256": release_check.release_bundle_identity_sha256(
                final_bundle
            ),
            "failureCount": 0,
        },
    }
    return final_bundle, frontier_report, report


def main() -> int:
    args = parse_args()
    try:
        _bundle, _frontier, report = build_final_bundle(args)
    except Exception as exc:
        sys.stderr.write(f"finalize_browser_release_candidate_bundle: {exc}\n")
        return 1
    bundle_builder.write_json(Path(args.report_out), report)
    if args.emit_json or report.get("status") != "pass":
        print(json.dumps(report, indent=2))
    return 0 if report.get("status") == "pass" else 1


if __name__ == "__main__":
    sys.exit(main())
