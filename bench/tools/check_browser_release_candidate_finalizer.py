#!/usr/bin/env python3
"""Check browser release-candidate finalizer reports."""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path, PurePosixPath
from typing import Any

try:
    from bench.tools._repo_import import ensure_repo_root
except ModuleNotFoundError:
    from _repo_import import ensure_repo_root

REPO_ROOT = ensure_repo_root(__file__)

try:
    from bench.tools import check_browser_release_artifact_bundle as release_check
except ModuleNotFoundError:
    import check_browser_release_artifact_bundle as release_check  # type: ignore

try:
    from bench.tools import check_browser_release_package_inputs as package_inputs_check
except ModuleNotFoundError:
    import check_browser_release_package_inputs as package_inputs_check  # type: ignore


EXPECTED_KIND = "browser_release_candidate_finalizer"
CHECK_KIND = "browser_release_candidate_finalizer_check"
ALLOWED_STATUS = {"pass", "fail"}
ALLOWED_FAILURE_PHASE = {
    "package_inputs_preflight",
    "provenance_preflight",
    "release_bundle_verification",
}
FAILURE_CODE_RE = re.compile(r"^[a-z0-9_]+$")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--report", required=True, help="browser_release_candidate_finalizer report JSON.")
    parser.add_argument(
        "--verify-files-root",
        default="",
        help="Resolve finalizer output artifact paths under this root and verify hashes.",
    )
    parser.add_argument(
        "--require-pass",
        action="store_true",
        help="Fail unless the finalizer report status is pass.",
    )
    parser.add_argument("--out", default="", help="Optional output path for the checker report.")
    parser.add_argument("--json", action="store_true", dest="emit_json")
    return parser.parse_args()


def failure(code: str, path: str, message: str) -> dict[str, str]:
    return {"code": code, "path": path, "message": message}


def load_json_object(path: Path, label: str) -> dict[str, Any]:
    payload = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(payload, dict):
        raise ValueError(f"{label} must be a JSON object: {path}")
    return payload


def resolve_artifact_path(path_text: str, verify_files_root: Path) -> Path | None:
    root = verify_files_root.resolve()
    path = Path(path_text)
    candidate = path if path.is_absolute() else root.joinpath(*PurePosixPath(path_text).parts)
    resolved = candidate.resolve()
    try:
        resolved.relative_to(root)
    except ValueError:
        return None
    return resolved


def artifact_payload(
    artifact: Any,
    path: str,
    verify_files_root: Path,
) -> tuple[dict[str, Any] | None, list[dict[str, str]]]:
    if not isinstance(artifact, dict):
        return None, [failure("invalid_artifact", path, "artifact must be object")]
    artifact_path = artifact.get("path")
    if not isinstance(artifact_path, str) or not artifact_path:
        return None, [failure("missing_artifact_path", f"{path}.path", "artifact path is required")]
    resolved = resolve_artifact_path(artifact_path, verify_files_root)
    if resolved is None:
        return None, [
            failure(
                "unsafe_artifact_path",
                f"{path}.path",
                f"artifact path must resolve under verify-files-root: {artifact_path}",
            )
        ]
    if not resolved.is_file():
        return None, [failure("artifact_file_missing", f"{path}.path", f"artifact file not found: {artifact_path}")]
    try:
        return load_json_object(resolved, path), []
    except (OSError, UnicodeError, json.JSONDecodeError, ValueError) as exc:
        return None, [
            failure(
                "invalid_artifact_payload",
                f"{path}.path",
                f"artifact payload is not valid JSON object: {exc}",
            )
        ]


def root_relative_path(path_text: str, verify_files_root: Path) -> str:
    resolved = resolve_artifact_path(path_text, verify_files_root)
    if resolved is None:
        return path_text
    try:
        return str(resolved.relative_to(verify_files_root.resolve()))
    except ValueError:
        return path_text


def artifacts_match(left: Any, right: Any, verify_files_root: Path) -> bool:
    if not isinstance(left, dict) or not isinstance(right, dict):
        return False
    if left.get("kind") != right.get("kind") or left.get("sha256") != right.get("sha256"):
        return False
    left_path = left.get("path")
    right_path = right.get("path")
    if not isinstance(left_path, str) or not isinstance(right_path, str):
        return False
    return release_check.artifact_path_matches(left_path, {right_path}, verify_files_root)


def compact_artifact(value: Any) -> dict[str, str] | None:
    if not isinstance(value, dict):
        return None
    out: dict[str, str] = {}
    for key in ("path", "sha256", "kind"):
        field = value.get(key)
        if not isinstance(field, str) or not field:
            return None
        out[key] = field
    return out


def compact_artifact_bindings(value: Any, keys: tuple[str, ...]) -> dict[str, dict[str, str]] | None:
    if not isinstance(value, dict):
        return None
    bindings: dict[str, dict[str, str]] = {}
    for key in keys:
        artifact = compact_artifact(value.get(key))
        if artifact is None:
            return None
        bindings[key] = artifact
    return bindings


def package_input_row(payload: dict[str, Any], role: str) -> dict[str, Any] | None:
    inputs = payload.get("inputs")
    if not isinstance(inputs, dict):
        return None
    row = inputs.get(role)
    return row if isinstance(row, dict) else None


def check_package_inputs_binding(
    package_payload: dict[str, Any],
    release_payload: dict[str, Any],
    verify_files_root: Path,
) -> list[dict[str, str]]:
    failures: list[dict[str, str]] = []
    if package_payload.get("artifactKind") != "browser_release_package_inputs_check":
        failures.append(
            failure(
                "invalid_package_inputs_kind",
                "inputs.packageInputs.path",
                "package inputs artifactKind must be browser_release_package_inputs_check",
            )
        )
    if package_payload.get("status") != "pass":
        failures.append(
            failure(
                "package_inputs_not_pass",
                "inputs.packageInputs.status",
                "package inputs report must pass",
            )
        )
    if package_payload.get("releaseCandidateEligible") is not True:
        failures.append(
            failure(
                "package_inputs_not_release_candidate_eligible",
                "inputs.packageInputs.releaseCandidateEligible",
                "package inputs report must be release-candidate eligible",
            )
        )
    if package_payload.get("evidenceMode") != "release_candidate":
        failures.append(
            failure(
                "package_inputs_not_release_candidate_evidence",
                "inputs.packageInputs.evidenceMode",
                "package inputs report evidenceMode must be release_candidate",
            )
        )
    if package_payload.get("releaseCandidateBlockers") != []:
        failures.append(
            failure(
                "package_inputs_release_candidate_blockers_present",
                "inputs.packageInputs.releaseCandidateBlockers",
                "package inputs report must carry no release-candidate blockers",
            )
        )
    if package_payload.get("failures") != []:
        failures.append(
            failure(
                "package_inputs_failures_present",
                "inputs.packageInputs.failures",
                "passing package inputs report must carry no failures",
            )
        )
    summary = package_payload.get("summary")
    if not isinstance(summary, dict) or summary.get("packageable") is not True:
        failures.append(
            failure(
                "package_inputs_summary_not_packageable",
                "inputs.packageInputs.summary.packageable",
                "passing package inputs report summary.packageable must be true",
            )
        )
    failures.extend(
        package_inputs_check.release_candidate_binary_identity_failures(
            package_payload,
            path_prefix="inputs.packageInputs",
        )
    )
    if package_payload.get("browserProduct") != release_payload.get("browserProduct"):
        failures.append(
            failure(
                "package_inputs_product_mismatch",
                "inputs.packageInputs.browserProduct",
                "package inputs browserProduct must match the release bundle",
            )
        )
    if package_payload.get("platform") != release_payload.get("platform"):
        failures.append(
            failure(
                "package_inputs_platform_mismatch",
                "inputs.packageInputs.platform",
                "package inputs platform must match the release bundle",
            )
        )

    archive_fields = {
        "browserExecutable": "browserExecutableArchivePath",
        "appMetadata": "browserAppMetadataArchivePath",
        "doeRuntime": "doeRuntimeArchivePath",
        "dawnFallbackRuntime": "dawnFallbackRuntimeArchivePath",
    }
    for role, bundle_field in archive_fields.items():
        row = package_input_row(package_payload, role)
        archive_path = row.get("archivePath") if isinstance(row, dict) else None
        if archive_path != release_payload.get(bundle_field):
            failures.append(
                failure(
                    "package_inputs_archive_path_mismatch",
                    f"inputs.packageInputs.inputs.{role}.archivePath",
                    f"package inputs {role} archive path must match release bundle {bundle_field}",
                )
            )

    artifact_fields = {
        "browserExecutable": "browserBinary",
        "doeRuntime": "doeRuntime",
        "dawnFallbackRuntime": "dawnFallbackRuntime",
        "shaderCompiler": "shaderCompiler",
    }
    for role, bundle_field in artifact_fields.items():
        row = package_input_row(package_payload, role)
        artifact = release_payload.get(bundle_field)
        row_path = row.get("path") if isinstance(row, dict) else None
        row_hash = row.get("sha256") if isinstance(row, dict) else None
        artifact_path = artifact.get("path") if isinstance(artifact, dict) else None
        artifact_hash = artifact.get("sha256") if isinstance(artifact, dict) else None
        if not isinstance(row_path, str) or not isinstance(artifact_path, str) or not release_check.artifact_path_matches(
            artifact_path,
            {row_path},
            verify_files_root,
        ):
            failures.append(
                failure(
                    "package_inputs_artifact_path_mismatch",
                    f"inputs.packageInputs.inputs.{role}.path",
                    f"package inputs {role} path must match release bundle {bundle_field}.path",
                )
            )
        if row_hash != artifact_hash:
            failures.append(
                failure(
                    "package_inputs_artifact_hash_mismatch",
                    f"inputs.packageInputs.inputs.{role}.sha256",
                    f"package inputs {role} hash must match release bundle {bundle_field}.sha256",
                )
            )
    return failures


def provenance_artifact_matches(
    actual: Any,
    expected: Any,
    verify_files_root: Path,
) -> bool:
    if not artifacts_match(actual, expected, verify_files_root):
        return False
    if (
        isinstance(actual, dict)
        and isinstance(expected, dict)
        and "downloadUrl" in expected
        and actual.get("downloadUrl") != expected.get("downloadUrl")
    ):
        return False
    return True


def check_provenance_report_binding(
    provenance_payload: dict[str, Any],
    release_payload: dict[str, Any],
    package_inputs_artifact: Any,
    verify_files_root: Path,
) -> list[dict[str, str]]:
    failures: list[dict[str, str]] = []
    if provenance_payload.get("artifactKind") != "browser_release_candidate_provenance_report":
        failures.append(
            failure(
                "invalid_provenance_report_kind",
                "inputs.provenanceReport.artifactKind",
                "provenance report artifactKind must be browser_release_candidate_provenance_report",
            )
        )
    if provenance_payload.get("status") != "pass":
        failures.append(
            failure(
                "provenance_report_not_pass",
                "inputs.provenanceReport.status",
                "provenance report must pass before finalizer promotion",
            )
        )
    if provenance_payload.get("releaseStatus") != "release_candidate":
        failures.append(
            failure(
                "provenance_report_release_status_mismatch",
                "inputs.provenanceReport.releaseStatus",
                "provenance report releaseStatus must be release_candidate",
            )
        )
    if provenance_payload.get("failures") != []:
        failures.append(
            failure(
                "provenance_report_failures_present",
                "inputs.provenanceReport.failures",
                "passing provenance report must carry no failures",
            )
        )
    summary = provenance_payload.get("summary")
    if isinstance(summary, dict) and summary.get("failureCount") != 0:
        failures.append(
            failure(
                "provenance_report_summary_failure_count_nonzero",
                "inputs.provenanceReport.summary.failureCount",
                "passing provenance report summary.failureCount must be 0",
            )
        )
    if provenance_payload.get("browserProduct") != release_payload.get("browserProduct"):
        failures.append(
            failure(
                "provenance_report_product_mismatch",
                "inputs.provenanceReport.browserProduct",
                "provenance report browserProduct must match the release bundle",
            )
        )
    if provenance_payload.get("platform") != release_payload.get("platform"):
        failures.append(
            failure(
                "provenance_report_platform_mismatch",
                "inputs.provenanceReport.platform",
                "provenance report platform must match the release bundle",
            )
        )

    expected_provenance = provenance_payload.get("expectedProvenance")
    if not isinstance(expected_provenance, dict):
        failures.append(
            failure(
                "missing_provenance_expected_provenance",
                "inputs.provenanceReport.expectedProvenance",
                "provenance report must bind expected release provenance",
            )
        )
    else:
        expected_fields = {
            "browserProduct": release_payload.get("browserProduct"),
            "platform": release_payload.get("platform"),
            "browserExecutableArchivePath": release_payload.get("browserExecutableArchivePath"),
            "browserAppMetadataArchivePath": release_payload.get("browserAppMetadataArchivePath"),
            "doeRuntimeArchivePath": release_payload.get("doeRuntimeArchivePath"),
            "dawnFallbackRuntimeArchivePath": release_payload.get("dawnFallbackRuntimeArchivePath"),
        }
        for field, expected in expected_fields.items():
            if expected_provenance.get(field) != expected:
                failures.append(
                    failure(
                        "provenance_report_expected_provenance_mismatch",
                        f"inputs.provenanceReport.expectedProvenance.{field}",
                        f"provenance report expectedProvenance.{field} must match the release bundle",
                    )
                )
        artifact_fields = {
            "releaseArchive": release_payload.get("releaseArchive"),
            "releaseArchiveManifest": release_payload.get("releaseArchiveManifest"),
            "publicDownloadReceipt": release_payload.get("publicDownloadReceipt"),
        }
        for field, expected in artifact_fields.items():
            if not provenance_artifact_matches(
                expected_provenance.get(field),
                expected,
                verify_files_root,
            ):
                failures.append(
                    failure(
                        "provenance_report_expected_provenance_mismatch",
                        f"inputs.provenanceReport.expectedProvenance.{field}",
                        f"provenance report expectedProvenance.{field} must match the release bundle",
                    )
                )

    component_artifacts = provenance_payload.get("componentArtifacts")
    if not isinstance(component_artifacts, dict):
        failures.append(
            failure(
                "missing_provenance_components",
                "inputs.provenanceReport.componentArtifacts",
                "provenance report componentArtifacts are required",
            )
        )
        return failures
    component_fields = {
        "releaseArchive": release_payload.get("releaseArchive"),
        "releaseArchiveManifest": release_payload.get("releaseArchiveManifest"),
        "publicDownloadReceipt": release_payload.get("publicDownloadReceipt"),
        "proofSurface": release_payload.get("proofSurface"),
        "proofSurfaceCheck": release_payload.get("proofSurfaceCheck"),
        "browserLaunchReceipt": release_payload.get("browserLaunchReceipt"),
        "packageInputs": package_inputs_artifact,
    }
    for field, expected in component_fields.items():
        if not provenance_artifact_matches(
            component_artifacts.get(field),
            expected,
            verify_files_root,
        ):
            failures.append(
                failure(
                    "provenance_report_component_mismatch",
                    f"inputs.provenanceReport.componentArtifacts.{field}",
                    f"provenance report componentArtifacts.{field} must match finalizer inputs",
                )
            )
    return failures


def check_failure_rows(value: Any, path: str) -> list[dict[str, str]]:
    if not isinstance(value, list) or not value:
        return [
            failure(
                "missing_finalizer_failures",
                path,
                "failed finalizer reports must carry at least one failure",
            )
        ]
    failures: list[dict[str, str]] = []
    for index, item in enumerate(value):
        row_path = f"{path}[{index}]"
        if not isinstance(item, dict):
            failures.append(
                failure(
                    "invalid_finalizer_failure",
                    row_path,
                    "finalizer failure entries must be objects",
                )
            )
            continue
        for field in ("code", "path", "message"):
            field_value = item.get(field)
            if not isinstance(field_value, str) or not field_value:
                failures.append(
                    failure(
                        "invalid_finalizer_failure",
                        f"{row_path}.{field}",
                        f"finalizer failure {field} is required",
                    )
                )
        code = item.get("code")
        if isinstance(code, str) and code and FAILURE_CODE_RE.fullmatch(code) is None:
            failures.append(
                failure(
                    "invalid_finalizer_failure",
                    f"{row_path}.code",
                    "finalizer failure code must match ^[a-z0-9_]+$",
                )
            )
    return failures


def check_failed_report(report: dict[str, Any]) -> list[dict[str, str]]:
    failures: list[dict[str, str]] = []
    phase = report.get("phase")
    if phase not in ALLOWED_FAILURE_PHASE:
        failures.append(
            failure(
                "invalid_finalizer_failure_phase",
                "phase",
                f"finalizer failure phase must be one of {sorted(ALLOWED_FAILURE_PHASE)}",
            )
        )
    if "outputs" in report:
        failures.append(
            failure(
                "failed_finalizer_has_outputs",
                "outputs",
                "failed finalizer reports must not bind output artifacts",
            )
        )
    failures.extend(check_failure_rows(report.get("failures"), "failures"))
    return failures


def check_passed_report(
    report: dict[str, Any],
    verify_files_root: Path | None,
) -> list[dict[str, str]]:
    failures: list[dict[str, str]] = []
    if verify_files_root is None:
        return [
            failure(
                "finalizer_pass_requires_verification",
                "verifyFilesRoot",
                "passing finalizer reports require --verify-files-root to verify output files and hashes",
            )
        ]
    if "phase" in report:
        failures.append(
            failure(
                "pass_finalizer_has_phase",
                "phase",
                "passing finalizer reports must not carry a failure phase",
            )
        )
    report_failures = report.get("failures")
    if isinstance(report_failures, list) and report_failures:
        failures.append(
            failure(
                "pass_finalizer_has_failures",
                "failures",
                "passing finalizer reports must not carry failures",
            )
        )

    outputs = report.get("outputs")
    if not isinstance(outputs, dict):
        return [failure("missing_finalizer_outputs", "outputs", "passing finalizer reports must bind output artifacts")]

    release_artifact = outputs.get("releaseArtifactBundle")
    runtime_artifact = outputs.get("runtimeFrontierBundle")
    failures.extend(
        release_check.check_artifact(
            release_artifact,
            "outputs.releaseArtifactBundle",
            "browser_release_artifact_bundle",
            verify_files_root,
        )
    )
    failures.extend(
        release_check.check_artifact(
            runtime_artifact,
            "outputs.runtimeFrontierBundle",
            "browser_runtime_frontier_bundle",
            verify_files_root,
        )
    )
    if failures:
        return failures

    release_payload, load_failures = artifact_payload(
        release_artifact,
        "outputs.releaseArtifactBundle",
        verify_files_root,
    )
    failures.extend(load_failures)
    runtime_payload, runtime_load_failures = artifact_payload(
        runtime_artifact,
        "outputs.runtimeFrontierBundle",
        verify_files_root,
    )
    failures.extend(runtime_load_failures)
    if release_payload is None or runtime_payload is None:
        return failures

    bundle_path = root_relative_path(str(release_artifact["path"]), verify_files_root)
    for item in release_check.check_bundle(
        release_payload,
        verify_files_root=verify_files_root,
        require_release_candidate=True,
        bundle_path=bundle_path,
    ):
        failures.append(
            failure(
                item["code"],
                f"outputs.releaseArtifactBundle.{item['path']}",
                item["message"],
            )
        )

    embedded_frontier = release_payload.get("runtimeFrontierBundle")
    if not artifacts_match(runtime_artifact, embedded_frontier, verify_files_root):
        failures.append(
            failure(
                "finalizer_runtime_frontier_output_mismatch",
                "outputs.runtimeFrontierBundle",
                "finalizer runtime frontier output must match the release bundle runtimeFrontierBundle artifact",
            )
        )

    if runtime_payload.get("artifactKind") != "browser_runtime_frontier_bundle":
        failures.append(
            failure(
                "invalid_runtime_frontier_output_kind",
                "outputs.runtimeFrontierBundle.path",
                "runtime frontier output artifactKind must be browser_runtime_frontier_bundle",
            )
        )

    inputs = report.get("inputs")
    if not isinstance(inputs, dict):
        failures.append(
            failure(
                "missing_finalizer_inputs",
                "inputs",
                "passing finalizer reports must bind input artifacts",
            )
        )
    else:
        package_inputs_artifact = inputs.get("packageInputs")
        provenance_report_artifact = inputs.get("provenanceReport")
        package_artifact_failures = release_check.check_artifact(
            package_inputs_artifact,
            "inputs.packageInputs",
            "browser_release_package_inputs_check",
            verify_files_root,
        )
        failures.extend(package_artifact_failures)
        provenance_artifact_failures: list[dict[str, str]] = []
        if not isinstance(provenance_report_artifact, dict):
            provenance_artifact_failures.append(
                failure(
                    "missing_finalizer_provenance_report",
                    "inputs.provenanceReport",
                    "passing finalizer reports must bind inputs.provenanceReport",
                )
            )
        else:
            provenance_artifact_failures.extend(
                release_check.check_artifact(
                    provenance_report_artifact,
                    "inputs.provenanceReport",
                    "browser_release_candidate_provenance_report",
                    verify_files_root,
                )
            )
        failures.extend(provenance_artifact_failures)
        package_payload: dict[str, Any] | None = None
        if not package_artifact_failures:
            package_payload, package_load_failures = artifact_payload(
                package_inputs_artifact,
                "inputs.packageInputs",
                verify_files_root,
            )
            failures.extend(package_load_failures)
            if package_payload is not None:
                failures.extend(
                    check_package_inputs_binding(
                        package_payload,
                        release_payload,
                        verify_files_root,
                    )
                )
        if not provenance_artifact_failures:
            provenance_payload, provenance_load_failures = artifact_payload(
                provenance_report_artifact,
                "inputs.provenanceReport",
                verify_files_root,
            )
            failures.extend(provenance_load_failures)
            if provenance_payload is not None:
                failures.extend(
                    check_provenance_report_binding(
                        provenance_payload,
                        release_payload,
                        package_inputs_artifact,
                        verify_files_root,
                    )
                )
    summary = report.get("summary")
    if not isinstance(summary, dict):
        failures.append(failure("missing_finalizer_summary", "summary", "passing finalizer reports must carry summary"))
        return failures
    if summary.get("claimabilityStatus") != runtime_payload.get("claimabilityStatus"):
        failures.append(
            failure(
                "finalizer_summary_claimability_mismatch",
                "summary.claimabilityStatus",
                "finalizer summary claimabilityStatus must match the runtime frontier output",
            )
        )
    if summary.get("releaseBundleIdentitySha256") != release_check.release_bundle_identity_sha256(
        release_payload
    ):
        failures.append(
            failure(
                "finalizer_summary_release_identity_mismatch",
                "summary.releaseBundleIdentitySha256",
                "finalizer summary releaseBundleIdentitySha256 must match the release bundle output identity",
            )
        )
    if summary.get("failureCount") != 0:
        failures.append(
            failure(
                "finalizer_summary_failure_count_nonzero",
                "summary.failureCount",
                "passing finalizer reports must have summary.failureCount=0",
            )
        )
    return failures


def check_report(
    report: dict[str, Any],
    *,
    verify_files_root: Path | None = None,
    require_pass: bool = False,
) -> list[dict[str, str]]:
    failures: list[dict[str, str]] = []
    if report.get("artifactKind") != EXPECTED_KIND:
        failures.append(
            failure(
                "wrong_artifact_kind",
                "artifactKind",
                f"artifactKind must be {EXPECTED_KIND}",
            )
        )
    status = report.get("status")
    if status not in ALLOWED_STATUS:
        failures.append(
            failure(
                "invalid_finalizer_status",
                "status",
                f"finalizer status must be one of {sorted(ALLOWED_STATUS)}",
            )
        )
        return failures
    if require_pass and status != "pass":
        failures.append(
            failure(
                "finalizer_report_not_pass",
                "status",
                "browser release-candidate finalizer report must pass",
            )
        )
    if status == "fail":
        failures.extend(check_failed_report(report))
    else:
        failures.extend(check_passed_report(report, verify_files_root))
    return failures


def main() -> int:
    args = parse_args()
    report_path = Path(args.report)
    try:
        report_payload = load_json_object(report_path, "finalizer report")
    except Exception as exc:
        sys.stderr.write(f"check_browser_release_candidate_finalizer: {exc}\n")
        return 1
    verify_files_root = Path(args.verify_files_root).resolve() if args.verify_files_root else None
    failures = check_report(
        report_payload,
        verify_files_root=verify_files_root,
        require_pass=args.require_pass,
    )
    raw_finalizer_status = report_payload.get("status")
    finalizer_status = (
        raw_finalizer_status
        if raw_finalizer_status in ALLOWED_STATUS
        else "unknown"
    )
    check = {
        "schemaVersion": 1,
        "artifactKind": CHECK_KIND,
        "status": "fail" if failures else "pass",
        "finalizerStatus": finalizer_status,
        "finalizerReportPath": str(report_path),
        "finalizerReportSha256": release_check.sha256_file(report_path),
        "verifyFilesRootProvided": verify_files_root is not None,
        "requirePass": args.require_pass,
        "failures": failures,
    }
    if not failures and finalizer_status == "pass":
        outputs = compact_artifact_bindings(
            report_payload.get("outputs"),
            ("releaseArtifactBundle", "runtimeFrontierBundle"),
        )
        inputs = compact_artifact_bindings(
            report_payload.get("inputs"),
            ("packageInputs", "provenanceReport"),
        )
        if outputs is not None:
            check["outputs"] = outputs
        if inputs is not None:
            check["inputs"] = inputs
    if args.out:
        out_path = Path(args.out)
        out_path.parent.mkdir(parents=True, exist_ok=True)
        out_path.write_text(json.dumps(check, indent=2) + "\n", encoding="utf-8")
    if args.emit_json:
        print(json.dumps(check, indent=2))
    elif failures:
        print("FAIL: browser release-candidate finalizer")
        for item in failures:
            print(f"- {item['code']}: {item['path']}: {item['message']}")
    else:
        print("PASS: browser release-candidate finalizer")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
