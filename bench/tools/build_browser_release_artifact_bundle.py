#!/usr/bin/env python3
"""Build browser release artifact bundles from concrete artifact paths."""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
from pathlib import Path, PurePosixPath
from typing import Any

try:
    from bench.tools import check_browser_release_artifact_bundle as bundle_check
except ModuleNotFoundError:
    import check_browser_release_artifact_bundle as bundle_check  # type: ignore


REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_CONTRACTS = (
    "browser/chromium/contracts/browser-benchmark-superset.contract.md",
    "browser/chromium/contracts/browser-canvas-webgpu-fusion.contract.md",
    "browser/chromium/contracts/browser-claim-methodology.contract.md",
    "browser/chromium/contracts/browser-cts-subset.contract.md",
    "browser/chromium/contracts/browser-fallback-explanations.contract.md",
    "browser/chromium/contracts/browser-gpu-flight-recorder.contract.md",
    "browser/chromium/contracts/browser-gpu-scheduler.contract.md",
    "browser/chromium/contracts/browser-local-ai-workloads.contract.md",
    "browser/chromium/contracts/browser-media-path-probe.contract.md",
    "browser/chromium/contracts/browser-pipeline-cache-receipts.contract.md",
    "browser/chromium/contracts/browser-published-release.contract.md",
    "browser/chromium/contracts/browser-recovery-parity.contract.md",
    "browser/chromium/contracts/browser-responsibility-map.contract.md",
    "browser/chromium/contracts/browser-shader-links.contract.md",
    "browser/chromium/contracts/browser-webgpu-effect-experiment.contract.md",
    "browser/chromium/contracts/runtime-selector-and-fallback.contract.md",
)
DEFAULT_POLICIES = (
    "config/browser-runtime-selector-policy.json",
    "config/chromium-fork-maintenance-policy.json",
    "config/chromium-patch-manifest.json",
    "config/browser-claim-policy.json",
    "config/browser-capture-policy.json",
    "config/browser-artifact-identity-coverage.json",
    "config/browser-unsupported-reason-taxonomy.json",
)
POLICY_KINDS = {
    "browser-runtime-selector-policy.json": "runtime_selector_policy",
    "chromium-fork-maintenance-policy.json": "fork_maintenance_policy",
    "chromium-patch-manifest.json": "chromium_patch_manifest",
    "browser-claim-policy.json": "browser_claim_policy",
    "browser-capture-policy.json": "browser_capture_policy",
    "browser-artifact-identity-coverage.json": "browser_artifact_identity_coverage",
    "browser-unsupported-reason-taxonomy.json": "browser_unsupported_reason_taxonomy",
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--bundle-id", default="browser-release-diagnostic")
    parser.add_argument("--release-status", choices=("diagnostic", "release_candidate"), default="diagnostic")
    parser.add_argument("--release-archive", default="")
    parser.add_argument("--release-archive-url", default="")
    parser.add_argument("--release-archive-manifest", default="")
    parser.add_argument("--public-download-receipt", default="")
    parser.add_argument(
        "--package-inputs",
        default="",
        help=(
            "Optional browser_release_package_inputs_check report used as the "
            "source of truth for product/platform/member paths and package inputs."
        ),
    )
    parser.add_argument("--product-id", default="fawn-doe")
    parser.add_argument("--product-name", default="Fawn Doe")
    parser.add_argument("--product-version", default="0.0.0-sample")
    parser.add_argument("--product-channel", default="")
    parser.add_argument("--platform-os", choices=("macos", "linux", "windows"), default="")
    parser.add_argument("--platform-arch", choices=("arm64", "x64"), default="")
    parser.add_argument("--package-format", choices=("zip",), default="zip")
    parser.add_argument("--browser-binary-archive-path", default="")
    parser.add_argument("--browser-app-metadata-archive-path", default="")
    parser.add_argument("--doe-runtime-archive-path", default="")
    parser.add_argument("--dawn-fallback-runtime-archive-path", default="")
    parser.add_argument("--browser-binary", default="")
    parser.add_argument("--doe-runtime", default="")
    parser.add_argument("--dawn-fallback-runtime", default="")
    parser.add_argument("--shader-compiler", default="")
    parser.add_argument("--proof-surface", default="")
    parser.add_argument("--proof-surface-check", default="")
    parser.add_argument("--chromium-source-checkout", default="")
    parser.add_argument("--browser-launch-receipt", default="")
    parser.add_argument("--runtime-frontier-bundle", default="")
    parser.add_argument(
        "--bootstrap-runtime-frontier",
        action="store_true",
        help=(
            "Treat --runtime-frontier-bundle as an output path, build it from "
            "a provisional release bundle, then bind its hash into the final bundle."
        ),
    )
    parser.add_argument(
        "--runtime-identity",
        default="",
        help="Browser runtime identity path used with --bootstrap-runtime-frontier.",
    )
    parser.add_argument(
        "--runtime-frontier-promotion-receipt",
        default="",
        help=(
            "Promotion receipt path used with --bootstrap-runtime-frontier. "
            "Defaults to the sole resolved promotion receipt."
        ),
    )
    parser.add_argument("--contract", action="append", default=[])
    parser.add_argument("--claim-report", action="append", required=True)
    parser.add_argument("--promotion-receipt", action="append", default=[])
    parser.add_argument("--policy", action="append", default=[])
    parser.add_argument(
        "--verify-files-root",
        default="",
        help=(
            "Resolve artifact paths under this root and verify hashes before writing. "
            "Required for release_candidate bundles."
        ),
    )
    parser.add_argument("--out", required=True)
    return parser.parse_args()


def sha256_file(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def repo_relative(path: Path) -> str:
    resolved = path.resolve()
    try:
        return str(resolved.relative_to(REPO_ROOT))
    except ValueError:
        return str(path)


def root_relative(path: Path, root: Path) -> str:
    resolved = path.resolve()
    try:
        return str(resolved.relative_to(root.resolve()))
    except ValueError:
        return str(path)


def require_file(path: Path, label: str) -> None:
    if not path.exists() or not path.is_file():
        raise FileNotFoundError(f"{label} must be an existing file: {path}")


def artifact(
    path: Path,
    kind: str,
    label: str,
    *,
    download_url: str = "",
) -> dict[str, str]:
    require_file(path, label)
    payload = {
        "path": repo_relative(path),
        "sha256": sha256_file(path),
        "kind": kind,
    }
    if download_url:
        payload["downloadUrl"] = download_url
    return payload


def future_artifact(path: Path, kind: str) -> dict[str, str]:
    return {
        "path": repo_relative(path),
        "sha256": "0" * 64,
        "kind": kind,
    }


def policy_kind(path: Path) -> str:
    return POLICY_KINDS.get(path.name, "policy")


def defaulted_paths(values: list[str], defaults: tuple[str, ...]) -> list[Path]:
    if values:
        return [Path(value) for value in values]
    return [REPO_ROOT / value for value in defaults]


def default_promotion_receipts(values: list[str], claim_reports: list[Path]) -> list[Path]:
    if values:
        return [Path(value) for value in values]
    return [Path(f"{path.with_suffix('')}.promotion-receipt.json") for path in claim_reports]


def load_json(path: Path) -> dict[str, Any]:
    with path.open("r", encoding="utf-8") as handle:
        payload = json.load(handle)
    if not isinstance(payload, dict):
        raise ValueError(f"expected JSON object: {path}")
    return payload


def package_input_row(payload: dict[str, Any], role: str) -> dict[str, Any]:
    inputs = payload.get("inputs")
    if not isinstance(inputs, dict):
        raise ValueError("package inputs report must carry inputs object")
    row = inputs.get(role)
    if not isinstance(row, dict):
        raise ValueError(f"package inputs report missing input row: {role}")
    return row


def package_input_path(payload: dict[str, Any], role: str) -> str:
    path = package_input_row(payload, role).get("path")
    if not isinstance(path, str) or not path:
        raise ValueError(f"package inputs report missing {role}.path")
    return path


def package_input_archive_path(payload: dict[str, Any], role: str) -> str:
    archive_path = package_input_row(payload, role).get("archivePath")
    if not isinstance(archive_path, str) or not archive_path:
        raise ValueError(f"package inputs report missing {role}.archivePath")
    return archive_path


def package_inputs_descriptor(package_inputs_path: str) -> dict[str, Any] | None:
    if not package_inputs_path:
        return None
    payload = load_json(Path(package_inputs_path))
    if payload.get("artifactKind") != "browser_release_package_inputs_check":
        raise ValueError("package inputs report artifactKind must be browser_release_package_inputs_check")
    if payload.get("status") != "pass":
        raise ValueError("package inputs report must pass before building a release bundle")
    browser_product = payload.get("browserProduct")
    if not isinstance(browser_product, dict):
        raise ValueError("package inputs report missing browserProduct")
    platform = payload.get("platform")
    if not isinstance(platform, dict):
        raise ValueError("package inputs report missing platform")
    return payload


def require_path_text(path_text: str, label: str) -> str:
    if not path_text:
        raise ValueError(f"{label} is required")
    return path_text


def resolve_path_text(path_text: str) -> Path:
    path = Path(path_text)
    if path.is_absolute():
        return path.resolve()
    pure = PurePosixPath(path_text.replace("\\", "/"))
    if pure.is_absolute() or ".." in pure.parts or not pure.parts:
        raise ValueError(f"path must be repo-relative without parent traversal: {path_text}")
    return REPO_ROOT.joinpath(*pure.parts).resolve()


def path_texts_match(left: str, right: str) -> bool:
    if left == right:
        return True
    try:
        return resolve_path_text(left) == resolve_path_text(right)
    except ValueError:
        return False


def explicit_path_must_match(
    *,
    explicit_path: str,
    derived_path: str,
    label: str,
) -> None:
    if explicit_path and not path_texts_match(explicit_path, derived_path):
        raise ValueError(f"{label} must match --package-inputs")


def explicit_value_must_match(
    *,
    explicit_value: str,
    derived_value: str,
    label: str,
) -> None:
    if explicit_value and explicit_value != derived_value:
        raise ValueError(f"{label} must match --package-inputs")


def resolved_input_path(
    *,
    explicit_path: str,
    package_inputs: dict[str, Any] | None,
    role: str,
    label: str,
    required: bool,
) -> str:
    if package_inputs is not None:
        derived_path = package_input_path(package_inputs, role)
        explicit_path_must_match(
            explicit_path=explicit_path,
            derived_path=derived_path,
            label=label,
        )
        return derived_path
    if explicit_path:
        return explicit_path
    if required:
        return require_path_text(explicit_path, label)
    return ""


def resolved_archive_path(
    *,
    explicit_path: str,
    package_inputs: dict[str, Any] | None,
    role: str,
    label: str,
) -> str:
    if package_inputs is not None:
        derived_path = package_input_archive_path(package_inputs, role)
        explicit_value_must_match(
            explicit_value=explicit_path,
            derived_value=derived_path,
            label=label,
        )
        return derived_path
    if explicit_path:
        return explicit_path
    return ""


def build_bundle(
    *,
    bundle_id: str,
    release_status: str,
    release_archive: Path | None = None,
    release_archive_url: str = "",
    release_archive_manifest: Path | None = None,
    public_download_receipt: Path | None = None,
    package_inputs: Path | None = None,
    browser_product: dict[str, str] | None = None,
    platform: dict[str, str] | None = None,
    browser_binary_archive_path: str = "",
    browser_app_metadata_archive_path: str = "",
    doe_runtime_archive_path: str = "",
    dawn_fallback_runtime_archive_path: str = "",
    browser_binary: Path,
    doe_runtime: Path,
    dawn_fallback_runtime: Path | None = None,
    shader_compiler: Path,
    proof_surface: Path | None = None,
    proof_surface_check: Path | None = None,
    chromium_source_checkout: Path | None = None,
    browser_launch_receipt: Path | None = None,
    runtime_frontier_bundle: Path | None = None,
    contracts: list[Path],
    claim_reports: list[Path],
    promotion_receipts: list[Path],
    policies: list[Path],
) -> dict[str, Any]:
    bundle = {
        "schemaVersion": 1,
        "artifactKind": "browser_release_artifact_bundle",
        "bundleId": bundle_id,
        "releaseStatus": release_status,
        "browserBinary": artifact(browser_binary, "browser_binary", "browser binary"),
        "doeRuntime": artifact(doe_runtime, "doe_runtime", "Doe runtime"),
        "shaderCompiler": artifact(shader_compiler, "shader_compiler", "shader compiler"),
        "contracts": [artifact(path, "contract", "contract") for path in contracts],
        "claimReports": [artifact(path, "browser_claim_report", "browser claim report") for path in claim_reports],
        "promotionReceipts": [
            artifact(path, "browser_claim_promotion_receipt", "browser claim promotion receipt")
            for path in promotion_receipts
        ],
        "policies": [artifact(path, policy_kind(path), "policy") for path in policies],
        "failureCodes": [],
    }
    if release_archive is not None:
        bundle["releaseArchive"] = artifact(
            release_archive,
            "browser_release_archive",
            "browser release archive",
            download_url=release_archive_url,
        )
    if public_download_receipt is not None:
        bundle["publicDownloadReceipt"] = artifact(
            public_download_receipt,
            "browser_public_download_receipt",
            "browser public download receipt",
        )
    if package_inputs is not None:
        bundle["packageInputs"] = artifact(
            package_inputs,
            "browser_release_package_inputs_check",
            "browser release package inputs",
        )
    if release_archive_manifest is not None:
        bundle["releaseArchiveManifest"] = artifact(
            release_archive_manifest,
            "browser_release_archive_manifest",
            "browser release archive manifest",
        )
    if browser_product is not None:
        bundle["browserProduct"] = browser_product
    if browser_binary_archive_path:
        bundle["browserExecutableArchivePath"] = browser_binary_archive_path
    if browser_app_metadata_archive_path:
        bundle["browserAppMetadataArchivePath"] = browser_app_metadata_archive_path
    if doe_runtime_archive_path:
        bundle["doeRuntimeArchivePath"] = doe_runtime_archive_path
    if dawn_fallback_runtime_archive_path:
        bundle["dawnFallbackRuntimeArchivePath"] = dawn_fallback_runtime_archive_path
    if platform is not None:
        bundle["platform"] = platform
    if dawn_fallback_runtime is not None:
        bundle["dawnFallbackRuntime"] = artifact(
            dawn_fallback_runtime,
            "dawn_fallback_runtime",
            "Dawn fallback runtime",
        )
    if proof_surface is not None:
        bundle["proofSurface"] = artifact(
            proof_surface,
            "browser_published_proof_surface",
            "browser published proof surface",
        )
    if proof_surface_check is not None:
        bundle["proofSurfaceCheck"] = artifact(
            proof_surface_check,
            "browser_published_proof_surface_check",
            "browser published proof surface check",
        )
    if chromium_source_checkout is not None:
        bundle["chromiumSourceCheckout"] = artifact(
            chromium_source_checkout,
            "chromium_source_checkout_check",
            "Chromium source checkout check",
        )
    if browser_launch_receipt is not None:
        bundle["browserLaunchReceipt"] = artifact(
            browser_launch_receipt,
            "browser_release_launch_receipt",
            "browser release launch receipt",
        )
    if runtime_frontier_bundle is not None:
        bundle["runtimeFrontierBundle"] = artifact(
            runtime_frontier_bundle,
            "browser_runtime_frontier_bundle",
            "browser runtime frontier bundle",
        )
    return bundle


def platform_descriptor(
    *,
    release_archive: Path | None,
    platform_os: str,
    platform_arch: str,
    package_format: str,
) -> dict[str, str] | None:
    if release_archive is None and not platform_os and not platform_arch:
        return None
    return {
        "os": platform_os,
        "arch": platform_arch,
        "packageFormat": package_format,
    }


def product_descriptor(
    *,
    product_id: str,
    product_name: str,
    product_version: str,
    product_channel: str,
    release_status: str,
    release_archive: Path | None,
) -> dict[str, str] | None:
    if release_archive is None and not any((product_id, product_name, product_version, product_channel)):
        return None
    return {
        "productId": product_id,
        "displayName": product_name,
        "version": product_version,
        "channel": product_channel or release_status,
    }


def bundle_verification_failures(
    bundle: dict[str, Any],
    verify_files_root: Path | None,
    *,
    bundle_path: str | None = None,
    skip_runtime_frontier_bundle_artifact: bool = False,
) -> list[dict[str, str]]:
    structural_failures = bundle_check.check_release_archive_surface(
        bundle,
        None,
        require_release_candidate=False,
    )
    if structural_failures:
        return structural_failures
    if verify_files_root is None:
        if bundle.get("releaseStatus") != "release_candidate":
            return []
        return [
            bundle_check.failure(
                "release_candidate_requires_verification",
                "verifyFilesRoot",
                "release_candidate browser release bundles require --verify-files-root",
            )
        ]
    return bundle_check.check_bundle(
        bundle,
        verify_files_root,
        bundle_path=bundle_path,
        skip_runtime_frontier_bundle_artifact=skip_runtime_frontier_bundle_artifact,
    )


def load_runtime_frontier_builder() -> Any:
    try:
        from bench.tools import check_browser_runtime_frontier_bundle as frontier
    except ModuleNotFoundError:
        import check_browser_runtime_frontier_bundle as frontier  # type: ignore
    return frontier


def write_json(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")


def provisional_bundle_path(out_path: Path) -> Path:
    return out_path.with_name(f".{out_path.name}.provisional")


def bootstrap_runtime_frontier_bundle(
    bundle: dict[str, Any],
    *,
    out_path: Path,
    runtime_frontier_bundle: Path,
    runtime_identity: Path,
    claim_promotion_receipt: Path,
    verify_files_root: Path,
) -> tuple[dict[str, Any], dict[str, Any], list[dict[str, str]]]:
    bundle["runtimeFrontierBundle"] = future_artifact(
        runtime_frontier_bundle,
        "browser_runtime_frontier_bundle",
    )
    final_bundle_path_text = root_relative(out_path, verify_files_root)
    provisional_failures = bundle_verification_failures(
        bundle,
        verify_files_root,
        bundle_path=final_bundle_path_text,
        skip_runtime_frontier_bundle_artifact=True,
    )
    if provisional_failures:
        return bundle, {}, provisional_failures

    frontier = load_runtime_frontier_builder()
    provisional_path = provisional_bundle_path(out_path)
    write_json(provisional_path, bundle)
    frontier_report = frontier.build_report(
        runtime_identity_path=root_relative(runtime_identity, verify_files_root),
        claim_promotion_receipt_path=root_relative(
            claim_promotion_receipt,
            verify_files_root,
        ),
        release_artifact_bundle_path=root_relative(
            provisional_path,
            verify_files_root,
        ),
        release_artifact_bundle_summary_path=final_bundle_path_text,
        root=verify_files_root,
        verify_files_root=verify_files_root,
    )
    write_json(runtime_frontier_bundle, frontier_report)
    bundle["runtimeFrontierBundle"] = artifact(
        runtime_frontier_bundle,
        "browser_runtime_frontier_bundle",
        "browser runtime frontier bundle",
    )
    final_failures = bundle_verification_failures(
        bundle,
        verify_files_root,
        bundle_path=final_bundle_path_text,
    )
    return bundle, frontier_report, final_failures


def runtime_frontier_promotion_receipt_path(
    explicit_path: str,
    promotion_receipts: list[Path],
) -> Path:
    if explicit_path:
        return Path(explicit_path)
    if len(promotion_receipts) != 1:
        raise ValueError(
            "--runtime-frontier-promotion-receipt is required when multiple promotion receipts are present"
        )
    return promotion_receipts[0]


def main() -> int:
    args = parse_args()
    verify_files_root = Path(args.verify_files_root).resolve() if args.verify_files_root else None
    claim_reports = [Path(value) for value in args.claim_report]
    promotion_receipts = default_promotion_receipts(
        args.promotion_receipt,
        claim_reports,
    )
    try:
        package_inputs = package_inputs_descriptor(args.package_inputs)
        browser_binary_path = resolved_input_path(
            explicit_path=args.browser_binary,
            package_inputs=package_inputs,
            role="browserExecutable",
            label="--browser-binary",
            required=True,
        )
        doe_runtime_path = resolved_input_path(
            explicit_path=args.doe_runtime,
            package_inputs=package_inputs,
            role="doeRuntime",
            label="--doe-runtime",
            required=True,
        )
        dawn_fallback_runtime_path = resolved_input_path(
            explicit_path=args.dawn_fallback_runtime,
            package_inputs=package_inputs,
            role="dawnFallbackRuntime",
            label="--dawn-fallback-runtime",
            required=False,
        )
        shader_compiler_path = resolved_input_path(
            explicit_path=args.shader_compiler,
            package_inputs=package_inputs,
            role="shaderCompiler",
            label="--shader-compiler",
            required=True,
        )
        browser_binary_archive_path = resolved_archive_path(
            explicit_path=args.browser_binary_archive_path,
            package_inputs=package_inputs,
            role="browserExecutable",
            label="--browser-binary-archive-path",
        )
        browser_app_metadata_archive_path = resolved_archive_path(
            explicit_path=args.browser_app_metadata_archive_path,
            package_inputs=package_inputs,
            role="appMetadata",
            label="--browser-app-metadata-archive-path",
        )
        doe_runtime_archive_path = resolved_archive_path(
            explicit_path=args.doe_runtime_archive_path,
            package_inputs=package_inputs,
            role="doeRuntime",
            label="--doe-runtime-archive-path",
        )
        dawn_fallback_runtime_archive_path = resolved_archive_path(
            explicit_path=args.dawn_fallback_runtime_archive_path,
            package_inputs=package_inputs,
            role="dawnFallbackRuntime",
            label="--dawn-fallback-runtime-archive-path",
        )
    except ValueError as exc:
        print(str(exc), file=sys.stderr)
        return 1
    package_browser_product = (
        package_inputs.get("browserProduct") if package_inputs is not None else None
    )
    package_platform = package_inputs.get("platform") if package_inputs is not None else None
    bundle = build_bundle(
        bundle_id=args.bundle_id,
        release_status=args.release_status,
        release_archive=Path(args.release_archive) if args.release_archive else None,
        release_archive_url=args.release_archive_url,
        release_archive_manifest=Path(args.release_archive_manifest) if args.release_archive_manifest else None,
        public_download_receipt=Path(args.public_download_receipt) if args.public_download_receipt else None,
        package_inputs=Path(args.package_inputs) if args.package_inputs else None,
        browser_product=package_browser_product if isinstance(package_browser_product, dict) else product_descriptor(
            product_id=args.product_id,
            product_name=args.product_name,
            product_version=args.product_version,
            product_channel=args.product_channel,
            release_status=args.release_status,
            release_archive=Path(args.release_archive) if args.release_archive else None,
        ),
        platform=package_platform if isinstance(package_platform, dict) else platform_descriptor(
            release_archive=Path(args.release_archive) if args.release_archive else None,
            platform_os=args.platform_os,
            platform_arch=args.platform_arch,
            package_format=args.package_format,
        ),
        browser_binary_archive_path=browser_binary_archive_path,
        browser_app_metadata_archive_path=browser_app_metadata_archive_path,
        doe_runtime_archive_path=doe_runtime_archive_path,
        dawn_fallback_runtime_archive_path=dawn_fallback_runtime_archive_path,
        browser_binary=Path(browser_binary_path),
        doe_runtime=Path(doe_runtime_path),
        dawn_fallback_runtime=Path(dawn_fallback_runtime_path) if dawn_fallback_runtime_path else None,
        shader_compiler=Path(shader_compiler_path),
        proof_surface=Path(args.proof_surface) if args.proof_surface else None,
        proof_surface_check=Path(args.proof_surface_check) if args.proof_surface_check else None,
        chromium_source_checkout=Path(args.chromium_source_checkout) if args.chromium_source_checkout else None,
        browser_launch_receipt=Path(args.browser_launch_receipt) if args.browser_launch_receipt else None,
        runtime_frontier_bundle=Path(args.runtime_frontier_bundle)
        if args.runtime_frontier_bundle and not args.bootstrap_runtime_frontier
        else None,
        contracts=defaulted_paths(args.contract, DEFAULT_CONTRACTS),
        claim_reports=claim_reports,
        promotion_receipts=promotion_receipts,
        policies=defaulted_paths(args.policy, DEFAULT_POLICIES),
    )
    out_path = Path(args.out)
    if args.bootstrap_runtime_frontier:
        if not args.runtime_frontier_bundle:
            raise SystemExit("--bootstrap-runtime-frontier requires --runtime-frontier-bundle")
        if not args.runtime_identity:
            raise SystemExit("--bootstrap-runtime-frontier requires --runtime-identity")
        if verify_files_root is None:
            raise SystemExit("--bootstrap-runtime-frontier requires --verify-files-root")
        try:
            promotion_receipt = runtime_frontier_promotion_receipt_path(
                args.runtime_frontier_promotion_receipt,
                promotion_receipts,
            )
        except ValueError as exc:
            print(str(exc), file=sys.stderr)
            return 1
        bundle, _frontier_report, verification_failures = (
            bootstrap_runtime_frontier_bundle(
                bundle,
                out_path=out_path,
                runtime_frontier_bundle=Path(args.runtime_frontier_bundle),
                runtime_identity=Path(args.runtime_identity),
                claim_promotion_receipt=promotion_receipt,
                verify_files_root=verify_files_root,
            )
        )
    else:
        verification_failures = bundle_verification_failures(
            bundle,
            verify_files_root,
            bundle_path=args.out,
        )
    if verification_failures:
        report = {
            "schemaVersion": 1,
            "artifactKind": "browser_release_artifact_bundle_builder_check",
            "status": "fail",
            "failures": verification_failures,
        }
        print(json.dumps(report, indent=2))
        return 1
    write_json(out_path, bundle)
    return 0


if __name__ == "__main__":
    sys.exit(main())
