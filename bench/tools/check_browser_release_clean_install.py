#!/usr/bin/env python3
"""Verify a browser release archive from an isolated clean extraction."""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
import stat
import subprocess
import sys
import tempfile
import time
import zipfile
from pathlib import Path, PurePosixPath
from typing import Any, Callable


REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_POLICY = REPO_ROOT / "config" / "browser-release-platform-policy.json"
DEFAULT_SMOKE_SCRIPT = REPO_ROOT / "browser" / "chromium" / "scripts" / "webgpu-playwright-smoke.mjs"
DEFAULT_TIMEOUT_SECONDS = 180
OUTPUT_CAPTURE_LIMIT = 16_384
VERIFICATION_LEVELS = ("launch_probe", "webgpu_smoke")
RunCommand = Callable[[list[str], int], dict[str, Any]]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Extract a Fawn release zip into a fresh directory and verify only its packaged bytes."
    )
    parser.add_argument("--archive", required=True)
    parser.add_argument("--manifest", required=True)
    parser.add_argument("--platform-policy", default=str(DEFAULT_POLICY))
    parser.add_argument("--verification-level", choices=VERIFICATION_LEVELS, default="webgpu_smoke")
    parser.add_argument("--smoke-script", default=str(DEFAULT_SMOKE_SCRIPT))
    parser.add_argument("--smoke-out", default="")
    parser.add_argument("--timeout-seconds", type=int, default=DEFAULT_TIMEOUT_SECONDS)
    parser.add_argument("--out", required=True)
    return parser.parse_args()


def observed_at_now() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def repo_relative(path: Path) -> str:
    resolved = path.resolve()
    try:
        return resolved.relative_to(REPO_ROOT).as_posix()
    except ValueError:
        return str(resolved)


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def artifact(path: Path, kind: str) -> dict[str, Any]:
    return {
        "path": repo_relative(path),
        "sha256": sha256_file(path),
        "byteLength": path.stat().st_size,
        "kind": kind,
    }


def failure(code: str, path: str, message: str) -> dict[str, str]:
    return {"code": code, "path": path, "message": message}


def load_json(path: Path, label: str) -> dict[str, Any]:
    if not path.is_file():
        raise FileNotFoundError(f"{label} does not exist: {path}")
    payload = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(payload, dict):
        raise ValueError(f"{label} must be a JSON object")
    return payload


def normalized_member_path(path_text: Any) -> PurePosixPath | None:
    if not isinstance(path_text, str) or not path_text or "\\" in path_text:
        return None
    path = PurePosixPath(path_text)
    if path.is_absolute() or any(part in ("", ".", "..") for part in path.parts):
        return None
    return path


def zip_mode(info: zipfile.ZipInfo) -> int:
    return (info.external_attr >> 16) & 0o177777


def zip_records(archive_path: Path) -> tuple[dict[str, dict[str, Any]], list[dict[str, str]]]:
    records: dict[str, dict[str, Any]] = {}
    failures: list[dict[str, str]] = []
    try:
        archive = zipfile.ZipFile(archive_path)
    except (OSError, zipfile.BadZipFile) as exc:
        return records, [failure("invalid_release_archive", "releaseArchive.path", str(exc))]
    with archive:
        for index, info in enumerate(archive.infolist()):
            path = normalized_member_path(info.filename.rstrip("/"))
            field_path = f"releaseArchive.members[{index}]"
            if path is None:
                failures.append(
                    failure("unsafe_archive_member_path", field_path, f"unsafe zip member path: {info.filename}")
                )
                continue
            path_text = path.as_posix()
            if path_text in records:
                failures.append(
                    failure("duplicate_archive_member_path", field_path, f"duplicate zip member path: {path_text}")
                )
                continue
            mode = zip_mode(info)
            if stat.S_ISLNK(mode):
                failures.append(
                    failure("archive_symlink_forbidden", field_path, f"zip symlinks are forbidden: {path_text}")
                )
                continue
            file_type = stat.S_IFMT(mode)
            if file_type and not (stat.S_ISREG(mode) or stat.S_ISDIR(mode)):
                failures.append(
                    failure("archive_special_file_forbidden", field_path, f"zip special files are forbidden: {path_text}")
                )
                continue
            if info.is_dir():
                continue
            data = archive.read(info)
            records[path_text] = {
                "archivePath": path_text,
                "sha256": hashlib.sha256(data).hexdigest(),
                "byteLength": len(data),
                "executable": bool(mode & stat.S_IXUSR),
                "mode": mode & 0o777,
            }
    return records, failures


def platform_contract(policy: dict[str, Any], platform: Any) -> dict[str, Any] | None:
    if not isinstance(platform, dict):
        return None
    rows = policy.get("releasePlatforms")
    if not isinstance(rows, list):
        return None
    return next(
        (
            row
            for row in rows
            if isinstance(row, dict)
            and all(row.get(key) == platform.get(key) for key in ("os", "arch", "packageFormat"))
        ),
        None,
    )


def manifest_record_map(manifest: dict[str, Any]) -> dict[str, dict[str, Any]]:
    rows = manifest.get("archiveMembers")
    if not isinstance(rows, list):
        return {}
    return {
        row["archivePath"]: row
        for row in rows
        if isinstance(row, dict) and isinstance(row.get("archivePath"), str)
    }


def check_static_contract(
    archive_path: Path,
    manifest: dict[str, Any],
    policy: dict[str, Any],
    records: dict[str, dict[str, Any]],
) -> list[dict[str, str]]:
    failures: list[dict[str, str]] = []
    if manifest.get("schemaVersion") != 1:
        failures.append(failure("invalid_manifest_schema_version", "releaseArchiveManifest.schemaVersion", "expected 1"))
    if manifest.get("artifactKind") != "browser_release_archive_manifest":
        failures.append(
            failure(
                "invalid_manifest_artifact_kind",
                "releaseArchiveManifest.artifactKind",
                "expected browser_release_archive_manifest",
            )
        )
    archive = manifest.get("archive")
    if not isinstance(archive, dict):
        failures.append(failure("missing_manifest_archive", "releaseArchiveManifest.archive", "archive object is required"))
    else:
        actual_hash = sha256_file(archive_path)
        if archive.get("sha256") != actual_hash:
            failures.append(
                failure("archive_hash_mismatch", "releaseArchiveManifest.archive.sha256", f"expected {actual_hash}")
            )
        if archive.get("byteLength") != archive_path.stat().st_size:
            failures.append(
                failure("archive_length_mismatch", "releaseArchiveManifest.archive.byteLength", "archive byteLength mismatch")
            )
    contract = platform_contract(policy, manifest.get("platform"))
    if contract is None:
        failures.append(
            failure("unsupported_release_platform", "releaseArchiveManifest.platform", "platform is not admitted by policy")
        )
    manifest_records = manifest_record_map(manifest)
    if len(manifest_records) != len(manifest.get("archiveMembers", [])):
        failures.append(
            failure("invalid_manifest_member_index", "releaseArchiveManifest.archiveMembers", "member paths must be unique strings")
        )
    for path_text, expected in manifest_records.items():
        actual = records.get(path_text)
        if actual is None:
            failures.append(
                failure("manifest_member_missing", "releaseArchiveManifest.archiveMembers", f"archive lacks {path_text}")
            )
            continue
        for key in ("sha256", "byteLength", "executable"):
            if actual.get(key) != expected.get(key):
                failures.append(
                    failure(
                        "manifest_member_identity_mismatch",
                        "releaseArchiveManifest.archiveMembers",
                        f"{path_text} {key} does not match the zip",
                    )
                )
    extra_paths = sorted(set(records) - set(manifest_records))
    if extra_paths:
        failures.append(
            failure(
                "unmanifested_archive_members",
                "releaseArchiveManifest.archiveMembers",
                f"zip contains unmanifested members: {', '.join(extra_paths)}",
            )
        )
    members = manifest.get("members")
    if not isinstance(members, dict):
        failures.append(failure("missing_manifest_members", "releaseArchiveManifest.members", "members object is required"))
        return failures
    for role in ("browserExecutable", "appMetadata", "doeRuntime", "dawnFallbackRuntime"):
        row = members.get(role)
        if not isinstance(row, dict) or row.get("archivePath") not in records:
            failures.append(
                failure("missing_required_manifest_role", f"releaseArchiveManifest.members.{role}", f"{role} is required")
            )
    browser = members.get("browserExecutable")
    if isinstance(browser, dict) and browser.get("executable") is not True:
        failures.append(
            failure("browser_not_executable", "releaseArchiveManifest.members.browserExecutable", "browser must be executable")
        )
    root_name = manifest.get("appBundleName")
    if not isinstance(root_name, str) or normalized_member_path(root_name) is None:
        failures.append(failure("invalid_package_root", "releaseArchiveManifest.appBundleName", "safe package root is required"))
    elif contract is not None:
        required = contract.get("requiredPackageMembers")
        if isinstance(required, list):
            for index, row in enumerate(required):
                if not isinstance(row, dict) or not isinstance(row.get("path"), str):
                    continue
                archive_member = f"{root_name}/{row['path']}"
                actual = records.get(archive_member)
                policy_path = f"platformPolicy.requiredPackageMembers[{index}]"
                if actual is None:
                    failures.append(
                        failure("missing_platform_support_member", policy_path, f"archive lacks {archive_member}")
                    )
                elif row.get("executable") is True and actual.get("executable") is not True:
                    failures.append(
                        failure("platform_support_member_not_executable", policy_path, f"{archive_member} must be executable")
                    )
    return failures


def extract_archive(archive_path: Path, destination: Path, records: dict[str, dict[str, Any]]) -> None:
    with zipfile.ZipFile(archive_path) as archive:
        infos = {info.filename.rstrip("/"): info for info in archive.infolist() if not info.is_dir()}
        for path_text, record in records.items():
            destination_path = destination.joinpath(*PurePosixPath(path_text).parts)
            destination_path.parent.mkdir(parents=True, exist_ok=True)
            with archive.open(infos[path_text], "r") as source, destination_path.open("wb") as target:
                while chunk := source.read(1024 * 1024):
                    target.write(chunk)
            os.chmod(destination_path, record["mode"] or 0o644)


def default_run_command(command: list[str], timeout_seconds: int) -> dict[str, Any]:
    started = time.monotonic()
    try:
        completed = subprocess.run(
            command,
            check=False,
            capture_output=True,
            text=True,
            timeout=timeout_seconds,
        )
        return {
            "attempted": True,
            "exitCode": completed.returncode,
            "timedOut": False,
            "durationMs": round((time.monotonic() - started) * 1000),
            "stdout": completed.stdout[-OUTPUT_CAPTURE_LIMIT:],
            "stderr": completed.stderr[-OUTPUT_CAPTURE_LIMIT:],
        }
    except subprocess.TimeoutExpired as exc:
        def captured_text(value: str | bytes | None) -> str:
            if isinstance(value, bytes):
                return value.decode("utf-8", errors="replace")
            return value or ""

        return {
            "attempted": True,
            "exitCode": None,
            "timedOut": True,
            "durationMs": round((time.monotonic() - started) * 1000),
            "stdout": captured_text(exc.stdout)[-OUTPUT_CAPTURE_LIMIT:],
            "stderr": captured_text(exc.stderr)[-OUTPUT_CAPTURE_LIMIT:],
        }


def unattempted_process() -> dict[str, Any]:
    return {"attempted": False, "exitCode": None, "timedOut": False, "durationMs": 0, "stdout": "", "stderr": ""}


def validate_smoke_report(
    report: dict[str, Any],
    browser_path: Path,
    doe_runtime_path: Path,
    expected_browser_hash: str,
    expected_doe_hash: str,
) -> list[dict[str, str]]:
    failures: list[dict[str, str]] = []
    if report.get("schemaVersion") != 2 or report.get("reportKind") != "chromium-webgpu-playwright-smoke":
        failures.append(failure("invalid_smoke_report", "webgpuSmoke.report", "expected schema v2 Playwright smoke report"))
        return failures
    if report.get("mode") != "both":
        failures.append(failure("smoke_modes_mismatch", "webgpuSmoke.report.mode", "clean install requires mode=both"))
    if Path(str(report.get("chromePath", ""))).resolve() != browser_path.resolve():
        failures.append(
            failure("smoke_browser_path_mismatch", "webgpuSmoke.report.chromePath", "smoke must use extracted browser")
        )
    results = report.get("modeResults")
    by_mode = {
        row.get("mode"): row
        for row in results
        if isinstance(row, dict) and isinstance(row.get("mode"), str)
    } if isinstance(results, list) else {}
    for mode in ("dawn", "doe"):
        row = by_mode.get(mode)
        path = f"webgpuSmoke.report.modeResults.{mode}"
        if not isinstance(row, dict):
            failures.append(failure("missing_smoke_mode", path, f"missing {mode} result"))
            continue
        if row.get("webgpuAvailable") is not True:
            failures.append(failure("smoke_webgpu_unavailable", path, f"WebGPU unavailable in {mode} mode"))
        selection = row.get("runtimeSelection")
        if not isinstance(selection, dict):
            failures.append(failure("missing_runtime_selection", path, f"missing {mode} runtime selection"))
            continue
        if selection.get("selectedRuntime") != mode or selection.get("forcedMode") != mode:
            failures.append(failure("runtime_selection_mismatch", path, f"{mode} was not forced and selected"))
        if selection.get("fallbackApplied") is not False or selection.get("hiddenFallbackAllowed") is not False:
            failures.append(failure("runtime_fallback_detected", path, f"fallback policy failed in {mode} mode"))
        identity = selection.get("artifactIdentity")
        if not isinstance(identity, dict) or identity.get("browserExecutableSha256") != expected_browser_hash:
            failures.append(failure("smoke_browser_hash_mismatch", path, "runtime selection did not bind extracted browser hash"))
        if mode == "doe":
            if not isinstance(identity, dict) or identity.get("doeLibSha256") != expected_doe_hash:
                failures.append(failure("smoke_doe_hash_mismatch", path, "runtime selection did not bind extracted Doe runtime hash"))
            if not isinstance(identity, dict) or Path(str(identity.get("doeLibPath", ""))).resolve() != doe_runtime_path.resolve():
                failures.append(failure("smoke_doe_path_mismatch", path, "runtime selection did not use extracted Doe runtime"))
        proof = row.get("activeRuntimeProof")
        if not isinstance(proof, dict) or proof.get("matchesRequestedMode") is not True:
            failures.append(failure("active_runtime_proof_failed", path, f"active runtime proof failed for {mode}"))
    return failures


def build_check(
    *,
    archive_path: Path,
    manifest_path: Path,
    policy_path: Path,
    verification_level: str,
    smoke_script: Path,
    smoke_out: Path,
    timeout_seconds: int,
    run_command: RunCommand = default_run_command,
) -> dict[str, Any]:
    if verification_level not in VERIFICATION_LEVELS:
        raise ValueError(f"verification_level must be one of {', '.join(VERIFICATION_LEVELS)}")
    if timeout_seconds <= 0:
        raise ValueError("timeout_seconds must be positive")
    manifest = load_json(manifest_path, "release archive manifest")
    policy = load_json(policy_path, "browser release platform policy")
    records, failures = zip_records(archive_path)
    failures.extend(check_static_contract(archive_path, manifest, policy, records))
    launch_probe = unattempted_process()
    smoke_process = unattempted_process()
    smoke_artifact: dict[str, Any] | None = None
    extracted_count = 0
    members = manifest.get("members") if isinstance(manifest.get("members"), dict) else {}
    browser_member = members.get("browserExecutable") if isinstance(members, dict) else None
    doe_member = members.get("doeRuntime") if isinstance(members, dict) else None
    with tempfile.TemporaryDirectory(prefix="doe-fawn-clean-install-") as temporary_directory:
        extraction_root = Path(temporary_directory)
        if not failures and isinstance(browser_member, dict) and isinstance(doe_member, dict):
            extract_archive(archive_path, extraction_root, records)
            extracted_count = len(records)
            browser_path = extraction_root.joinpath(*PurePosixPath(browser_member["archivePath"]).parts)
            doe_runtime_path = extraction_root.joinpath(*PurePosixPath(doe_member["archivePath"]).parts)
            launch_probe = run_command([str(browser_path), "--version"], timeout_seconds)
            if launch_probe.get("exitCode") != 0 or launch_probe.get("timedOut") is True:
                failures.append(
                    failure("browser_launch_probe_failed", "launchProbe", "extracted browser failed its --version launch probe")
                )
            if verification_level == "webgpu_smoke" and not failures:
                if not smoke_script.is_file():
                    failures.append(failure("smoke_script_missing", "webgpuSmoke.script", f"missing {smoke_script}"))
                else:
                    command = [
                        "node",
                        str(smoke_script),
                        "--mode",
                        "both",
                        "--chrome",
                        str(browser_path),
                        "--doe-lib",
                        str(doe_runtime_path),
                        "--out",
                        str(smoke_out),
                        "--headless",
                        "true",
                        "--suite-timeout-ms",
                        str(timeout_seconds * 1000),
                        "--strict",
                    ]
                    smoke_process = run_command(command, timeout_seconds * 3)
                    if smoke_process.get("exitCode") != 0 or smoke_process.get("timedOut") is True:
                        failures.append(failure("webgpu_smoke_process_failed", "webgpuSmoke.process", "strict smoke failed"))
                    if smoke_out.is_file():
                        smoke_artifact = artifact(smoke_out, "chromium-webgpu-playwright-smoke")
                        try:
                            smoke_report = load_json(smoke_out, "WebGPU smoke report")
                        except (OSError, ValueError, json.JSONDecodeError) as exc:
                            failures.append(failure("invalid_smoke_report", "webgpuSmoke.report", str(exc)))
                        else:
                            failures.extend(
                                validate_smoke_report(
                                    smoke_report,
                                    browser_path,
                                    doe_runtime_path,
                                    browser_member["sha256"],
                                    doe_member["sha256"],
                                )
                            )
                    else:
                        failures.append(failure("smoke_report_missing", "webgpuSmoke.report", "smoke did not emit its report"))
    status = "pass" if not failures else "fail"
    return {
        "schemaVersion": 1,
        "artifactKind": "browser_release_clean_install_check",
        "observedAt": observed_at_now(),
        "verificationLevel": verification_level,
        "sourceMode": "release_archive",
        "verifier": artifact(Path(__file__), "browser_release_clean_install_verifier"),
        "releaseArchive": artifact(archive_path, "browser_release_archive"),
        "releaseArchiveManifest": artifact(manifest_path, "browser_release_archive_manifest"),
        "browserProduct": manifest.get("browserProduct"),
        "platform": manifest.get("platform"),
        "platformPolicy": {
            "policyId": policy.get("policyId"),
            **artifact(policy_path, "browser_release_platform_policy"),
        },
        "extraction": {
            "isolation": "fresh_temporary_directory",
            "archiveMemberCount": len(records),
            "extractedMemberCount": extracted_count,
            "borrowedMemberCount": 0,
            "browserExecutableArchivePath": browser_member.get("archivePath", "") if isinstance(browser_member, dict) else "",
            "doeRuntimeArchivePath": doe_member.get("archivePath", "") if isinstance(doe_member, dict) else "",
        },
        "launchProbe": launch_probe,
        "webgpuSmoke": {
            "required": verification_level == "webgpu_smoke",
            "script": artifact(smoke_script, "browser_webgpu_smoke_runner") if smoke_script.is_file() else None,
            "process": smoke_process,
            "report": smoke_artifact,
            "modes": ["dawn", "doe"],
        },
        "releaseCandidateEligible": status == "pass" and verification_level == "webgpu_smoke",
        "status": status,
        "failures": failures,
    }


def main() -> int:
    args = parse_args()
    out_path = Path(args.out)
    smoke_out = Path(args.smoke_out) if args.smoke_out else out_path.with_name(f"{out_path.stem}.playwright-smoke.json")
    try:
        payload = build_check(
            archive_path=Path(args.archive),
            manifest_path=Path(args.manifest),
            policy_path=Path(args.platform_policy),
            verification_level=args.verification_level,
            smoke_script=Path(args.smoke_script),
            smoke_out=smoke_out,
            timeout_seconds=args.timeout_seconds,
        )
    except Exception as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"status": payload["status"], "out": repo_relative(out_path), "failures": payload["failures"]}, indent=2))
    return 0 if payload["status"] == "pass" else 1


if __name__ == "__main__":
    sys.exit(main())
