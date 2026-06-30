#!/usr/bin/env python3
"""Build browser release artifact bundles from concrete artifact paths."""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
from pathlib import Path
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
    parser.add_argument("--browser-binary", required=True)
    parser.add_argument("--doe-runtime", required=True)
    parser.add_argument("--shader-compiler", required=True)
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


def require_file(path: Path, label: str) -> None:
    if not path.exists() or not path.is_file():
        raise FileNotFoundError(f"{label} must be an existing file: {path}")


def artifact(path: Path, kind: str, label: str) -> dict[str, str]:
    require_file(path, label)
    return {
        "path": repo_relative(path),
        "sha256": sha256_file(path),
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


def build_bundle(
    *,
    bundle_id: str,
    release_status: str,
    browser_binary: Path,
    doe_runtime: Path,
    shader_compiler: Path,
    contracts: list[Path],
    claim_reports: list[Path],
    promotion_receipts: list[Path],
    policies: list[Path],
) -> dict[str, Any]:
    return {
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


def bundle_verification_failures(
    bundle: dict[str, Any],
    verify_files_root: Path | None,
) -> list[dict[str, str]]:
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
    return bundle_check.check_bundle(bundle, verify_files_root)


def main() -> int:
    args = parse_args()
    verify_files_root = Path(args.verify_files_root).resolve() if args.verify_files_root else None
    bundle = build_bundle(
        bundle_id=args.bundle_id,
        release_status=args.release_status,
        browser_binary=Path(args.browser_binary),
        doe_runtime=Path(args.doe_runtime),
        shader_compiler=Path(args.shader_compiler),
        contracts=defaulted_paths(args.contract, DEFAULT_CONTRACTS),
        claim_reports=[Path(value) for value in args.claim_report],
        promotion_receipts=default_promotion_receipts(
            args.promotion_receipt,
            [Path(value) for value in args.claim_report],
        ),
        policies=defaulted_paths(args.policy, DEFAULT_POLICIES),
    )
    verification_failures = bundle_verification_failures(
        bundle,
        verify_files_root,
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
    out_path = Path(args.out)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(bundle, indent=2) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main())
