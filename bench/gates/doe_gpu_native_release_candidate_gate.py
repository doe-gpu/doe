#!/usr/bin/env python3
"""Fail-closed verification for a complete Doe GPU native candidate bundle."""

from __future__ import annotations

import argparse
import hashlib
import json
import subprocess
import tarfile
from pathlib import Path, PurePosixPath
from typing import Any

import jsonschema


REPO_ROOT = Path(__file__).resolve().parents[2]
SCHEMA_PATH = Path("config/doe-gpu-native-release-candidate.schema.json")
REQUIRED_RUNTIMES = ("node", "bun", "electron")
EXPECTED_OUTPUT = [2, 4, 6, 8, 10, 12, 14, 16]
EXPECTED_OUTPUT_SHA256 = (
    "sha256:9d42cad41af4aaf3ae973e5a48d96f61e4708edc57bf7dd29a497ebd96f506cf"
)
PLATFORM_PACKAGES = {
    ("linux", "x64"): ("doe-gpu-linux-x64", "libwebgpu_doe.so"),
    ("darwin", "arm64"): ("doe-gpu-darwin-arm64", "libwebgpu_doe.dylib"),
}
RELIABILITY_DECISIONS = (
    "boundedCleanProcessReliability",
    "boundedSameProcessLifecycle",
    "deliberateDestroyLossSemantics",
)
ZERO_CREDIT_DECISIONS = (
    "registryPublicationCredit",
    "runtimeOwnershipCredit",
    "performanceCredit",
    "applicationPromotionCredit",
)
EXPECTED_RELIABILITY_CONTRACT = {
    "sequentialTrials": 3,
    "concurrentTrials": 2,
    "timeoutMs": 120_000,
    "maxOutputBytes": 4_194_304,
    "expectedOutputSha256": EXPECTED_OUTPUT_SHA256.removeprefix("sha256:"),
    "lifecycleCycles": 12,
    "lifecycleWarmupCycles": 2,
    "maxPostWarmupRssSpanBytes": 268_435_456,
}


def sha256_bytes(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def sha256_file(path: Path) -> str:
    return sha256_bytes(path.read_bytes())


def sha256_json(payload: Any) -> str:
    encoded = json.dumps(
        payload,
        ensure_ascii=False,
        separators=(",", ":"),
    ).encode("utf-8")
    return sha256_bytes(encoded)


def _safe_relative_path(value: object, label: str, failures: list[str]) -> str | None:
    if not isinstance(value, str) or not value:
        failures.append(f"{label}: path must be a non-empty string")
        return None
    path = PurePosixPath(value)
    if path.is_absolute() or ".." in path.parts:
        failures.append(f"{label}: path must remain relative and contained: {value}")
        return None
    return value


def _bundle_path(
    report_path: Path,
    value: object,
    label: str,
    failures: list[str],
) -> Path | None:
    relative_path = _safe_relative_path(value, label, failures)
    if relative_path is None:
        return None
    bundle_root = report_path.parent.resolve()
    resolved = (bundle_root / relative_path).resolve()
    if not resolved.is_relative_to(bundle_root):
        failures.append(f"{label}: path escaped candidate bundle: {value}")
        return None
    if not resolved.is_file():
        failures.append(f"{label}: referenced file is missing: {value}")
        return None
    return resolved


class SourceTree:
    def __init__(self, root: Path) -> None:
        self.root = root.resolve()
        self._cache: dict[tuple[str, str], bytes | None] = {}

    def blob(
        self,
        commit: str,
        source_path: object,
        label: str,
        failures: list[str],
    ) -> bytes | None:
        relative_path = _safe_relative_path(source_path, label, failures)
        if relative_path is None:
            return None
        cache_key = (commit, relative_path)
        if cache_key not in self._cache:
            result = subprocess.run(
                ["git", "show", f"{commit}:{relative_path}"],
                cwd=self.root,
                check=False,
                capture_output=True,
            )
            self._cache[cache_key] = result.stdout if result.returncode == 0 else None
        payload = self._cache[cache_key]
        if payload is None:
            failures.append(
                f"{label}: source path is absent from commit {commit}: {relative_path}"
            )
        return payload


class Tarballs:
    def __init__(self) -> None:
        self._cache: dict[tuple[Path, str], bytes | None] = {}

    def member(
        self,
        tarball: Path,
        member_name: str,
        label: str,
        failures: list[str],
    ) -> bytes | None:
        cache_key = (tarball, member_name)
        if cache_key in self._cache:
            return self._cache[cache_key]
        try:
            with tarfile.open(tarball, mode="r:gz") as archive:
                matches = [member for member in archive.getmembers() if member.name == member_name]
                if len(matches) != 1 or not matches[0].isfile():
                    failures.append(
                        f"{label}: expected exactly one regular member {member_name}"
                    )
                    self._cache[cache_key] = None
                    return None
                extracted = archive.extractfile(matches[0])
                payload = extracted.read() if extracted is not None else None
        except (OSError, tarfile.TarError) as exc:
            failures.append(f"{label}: unreadable package artifact: {exc}")
            payload = None
        self._cache[cache_key] = payload
        return payload


def _check_hash(
    actual_payload: bytes | None,
    expected: object,
    label: str,
    failures: list[str],
) -> None:
    if actual_payload is not None and sha256_bytes(actual_payload) != expected:
        failures.append(f"{label}: SHA-256 mismatch")


def _check_source_reference(
    source: SourceTree,
    commit: str,
    reference: object,
    label: str,
    failures: list[str],
) -> None:
    if not isinstance(reference, dict):
        failures.append(f"{label}: reference must be an object")
        return
    payload = source.blob(commit, reference.get("path"), label, failures)
    _check_hash(payload, reference.get("sha256"), label, failures)


def _load_json(path: Path, label: str, failures: list[str]) -> dict[str, Any] | None:
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        failures.append(f"{label}: JSON load failed: {exc}")
        return None
    if not isinstance(payload, dict):
        failures.append(f"{label}: JSON root must be an object")
        return None
    return payload


def _validate_schema(
    report: dict[str, Any],
    schema: dict[str, Any],
    label: str,
    failures: list[str],
) -> bool:
    validator = jsonschema.Draft202012Validator(
        schema,
        format_checker=jsonschema.Draft202012Validator.FORMAT_CHECKER,
    )
    errors = sorted(
        validator.iter_errors(report),
        key=lambda error: tuple(str(part) for part in error.absolute_path),
    )
    for error in errors:
        location = ".".join(str(part) for part in error.absolute_path) or "<root>"
        failures.append(f"{label}: schema {location}: {error.message}")
    return not errors


def _validate_package_artifact(
    report_path: Path,
    package: dict[str, Any],
    label: str,
    failures: list[str],
) -> Path | None:
    artifact = _bundle_path(report_path, package.get("artifactPath"), label, failures)
    if artifact is None:
        return None
    if artifact.stat().st_size != package.get("bytes"):
        failures.append(f"{label}: retained byte count mismatch")
    if sha256_file(artifact) != package.get("sha256"):
        failures.append(f"{label}: retained SHA-256 mismatch")
    return artifact


def _validate_governed_replay(
    report: dict[str, Any],
    label: str,
    failures: list[str],
) -> None:
    governed = report["governedReplay"]
    primary = governed["primaryReceipt"]
    replay = governed["replayReceipt"]
    if sha256_json(primary) != governed["primaryReceiptSha256"]:
        failures.append(f"{label}: primary receipt digest mismatch")
    if sha256_json(replay) != governed["replayReceiptSha256"]:
        failures.append(f"{label}: replay receipt digest mismatch")
    if sha256_json(governed["adapterInfo"]) != governed["adapterInfoSha256"]:
        failures.append(f"{label}: adapter digest mismatch")
    for receipt_name, receipt in (("primary", primary), ("replay", replay)):
        oracle = receipt["oracle"]
        if oracle["expectedOutputSha256"] != EXPECTED_OUTPUT_SHA256:
            failures.append(f"{label}: {receipt_name} expected oracle drift")
        if oracle["actualOutputSha256"] != EXPECTED_OUTPUT_SHA256:
            failures.append(f"{label}: {receipt_name} actual oracle drift")
        if receipt["replay"]["workloadSha256"] != governed["workloadSha256"]:
            failures.append(f"{label}: {receipt_name} workload replay mismatch")
        if receipt["replay"]["executionSha256"] != governed["executionSha256"]:
            failures.append(f"{label}: {receipt_name} execution replay mismatch")
        if receipt["adapterInfo"] != governed["adapterInfo"]:
            failures.append(f"{label}: {receipt_name} adapter mismatch")
    if governed["outputSha256"] != EXPECTED_OUTPUT_SHA256:
        failures.append(f"{label}: governed output digest drift")
    if not all(governed["matches"].values()):
        failures.append(f"{label}: governed replay does not match")


def _validate_reliability(
    report_path: Path,
    report: dict[str, Any],
    runtime: str,
    source: SourceTree,
    failures: list[str],
) -> None:
    label = f"{report_path.name}: reliability"
    reference = report["reliabilityEvidence"]
    path = _bundle_path(report_path, reference.get("path"), label, failures)
    if path is None:
        return
    if sha256_file(path) != reference.get("sha256"):
        failures.append(f"{label}: evidence digest mismatch")
        return
    reliability = _load_json(path, label, failures)
    if reliability is None:
        return
    if reliability.get("artifactKind") != reference.get("artifactKind"):
        failures.append(f"{label}: artifact kind mismatch")
    if reliability.get("status") != reference.get("status"):
        failures.append(f"{label}: status mismatch")
    expected_tuple = {"runtime": runtime, **report["tuple"]}
    if reliability.get("tuple") != expected_tuple:
        failures.append(f"{label}: runtime tuple mismatch")
    if reliability.get("runtime") != report["runtime"]:
        failures.append(f"{label}: runtime executable identity mismatch")
    expected_launch = {
        "node": "node-process",
        "bun": "bun-process",
        "electron": "electron-main-process-node-side",
    }[runtime]
    if reliability.get("launch", {}).get("mode") != expected_launch:
        failures.append(f"{label}: launch mode mismatch")
    expected_installation = {
        "lifecycleScripts": "disabled",
        "optionalDependencies": "omitted",
        "workspaceLibraryResolution": False,
        "sharedAcrossTrials": True,
    }
    if reliability.get("installation") != expected_installation:
        failures.append(f"{label}: clean-install contract mismatch")
    if reliability.get("contract") != EXPECTED_RELIABILITY_CONTRACT:
        failures.append(f"{label}: bounded reliability contract mismatch")
    for package_name in ("wrapper", "platform"):
        expected = report["packages"][package_name]
        actual = reliability.get("packages", {}).get(package_name, {})
        for field in ("id", "bytes", "sha256"):
            if actual.get(field) != expected.get(field):
                failures.append(f"{label}: {package_name} {field} mismatch")
    decision = reliability.get("decision", {})
    for field in RELIABILITY_DECISIONS:
        if decision.get(field) != "authorized-for-declared-runtime-tuple":
            failures.append(f"{label}: decision {field} is not authorized")
    trials = reliability.get("trials")
    expected_trial_count = (
        EXPECTED_RELIABILITY_CONTRACT["sequentialTrials"]
        + EXPECTED_RELIABILITY_CONTRACT["concurrentTrials"]
    )
    if not isinstance(trials, list) or len(trials) != expected_trial_count:
        failures.append(f"{label}: bounded process trial count mismatch")
    else:
        trial_ids = {trial.get("id") for trial in trials if isinstance(trial, dict)}
        expected_ids = {
            *(f"sequential-{index}" for index in range(3)),
            *(f"concurrent-{index}" for index in range(2)),
        }
        if trial_ids != expected_ids:
            failures.append(f"{label}: bounded process trial identities mismatch")
        for trial in trials:
            if not isinstance(trial, dict):
                failures.append(f"{label}: bounded process trial must be an object")
                continue
            trial_receipt = trial.get("receipt", {})
            if (
                trial.get("exitCode") != 0
                or trial.get("signal") is not None
                or trial.get("timedOut") is not False
                or trial.get("outputLimitExceeded") is not False
                or trial_receipt.get("runtimeHost") != runtime
                or trial_receipt.get("providerModule") != "doe-gpu"
                or trial_receipt.get("libraryFlavor") != "doe-dropin"
                or trial_receipt.get("buildMetadataSource") != "prebuild"
                or trial_receipt.get("outputSha256")
                != EXPECTED_RELIABILITY_CONTRACT["expectedOutputSha256"]
            ):
                failures.append(
                    f"{label}: bounded process trial failed: {trial.get('id')}"
                )
    lifecycle = reliability.get("sameProcessLifecycle")
    if not isinstance(lifecycle, dict):
        failures.append(f"{label}: same-process lifecycle evidence is missing")
    else:
        lifecycle_failed = (
            lifecycle.get("exitCode") != 0
            or lifecycle.get("signal") is not None
            or lifecycle.get("timedOut") is not False
            or lifecycle.get("outputLimitExceeded") is not False
            or lifecycle.get("cycleCount")
            != EXPECTED_RELIABILITY_CONTRACT["lifecycleCycles"]
            or lifecycle.get("warmupCycles")
            != EXPECTED_RELIABILITY_CONTRACT["lifecycleWarmupCycles"]
            or lifecycle.get("maxPostWarmupRssSpanBytes")
            != EXPECTED_RELIABILITY_CONTRACT["maxPostWarmupRssSpanBytes"]
            or not isinstance(lifecycle.get("postWarmupRssSpanBytes"), int)
            or lifecycle.get("postWarmupRssSpanBytes", -1)
            > EXPECTED_RELIABILITY_CONTRACT["maxPostWarmupRssSpanBytes"]
        )
        if lifecycle_failed:
            failures.append(f"{label}: same-process lifecycle contract mismatch")
        samples = lifecycle.get("samples")
        if not isinstance(samples, list) or len(samples) != 12:
            failures.append(f"{label}: same-process lifecycle sample count mismatch")
        else:
            for index, sample in enumerate(samples):
                if (
                    not isinstance(sample, dict)
                    or sample.get("index") != index
                    or sample.get("outputSha256")
                    != EXPECTED_RELIABILITY_CONTRACT["expectedOutputSha256"]
                    or sample.get("deviceDestroyed") is not True
                    or sample.get("lostReason") != "destroyed"
                    or sample.get("postDestroyRejected") is not True
                ):
                    failures.append(
                        f"{label}: same-process lifecycle sample failed: {index}"
                    )
    implementation = reliability.get("implementation")
    if not isinstance(implementation, dict):
        failures.append(f"{label}: implementation references are missing")
    else:
        for reference_name, reference in implementation.items():
            _check_source_reference(
                source,
                report["sourceCommit"],
                reference,
                f"{label}: {reference_name}",
                failures,
            )


def _validate_candidate(
    report_path: Path,
    report: dict[str, Any],
    expected_platform: str,
    expected_arch: str,
    source: SourceTree,
    tarballs: Tarballs,
    failures: list[str],
) -> None:
    label = report_path.name
    runtime = report["runtime"]["host"]
    commit = report["sourceCommit"]
    platform_key = (expected_platform, expected_arch)
    platform_package_name, library_name = PLATFORM_PACKAGES[platform_key]
    if report["tuple"] != {"platform": expected_platform, "arch": expected_arch}:
        failures.append(f"{label}: declared tuple does not match requested tuple")
    if report["host"]["platform"] != expected_platform:
        failures.append(f"{label}: host platform mismatch")
    if report["host"]["arch"] != expected_arch:
        failures.append(f"{label}: host architecture mismatch")
    if report["receipt"]["runtimeHost"] != runtime:
        failures.append(f"{label}: first-kernel runtime mismatch")
    if report["receipt"].get("result", {}).get("output") != EXPECTED_OUTPUT:
        failures.append(f"{label}: first-kernel output mismatch")
    provider = report["receipt"].get("provider", {})
    if provider.get("loaded") is not True or provider.get("doeNative") is not True:
        failures.append(f"{label}: first-kernel provider is not Doe native")
    if provider.get("buildMetadataSource") != "prebuild":
        failures.append(f"{label}: first-kernel provider did not load a prebuild")
    if f"/node_modules/{platform_package_name}/" not in provider.get(
        "doeLibraryPath", ""
    ):
        failures.append(f"{label}: first-kernel native library escaped the package")
    expected_launch = {
        "node": "node-process",
        "bun": "bun-process",
        "electron": "electron-main-process-node-side",
    }[runtime]
    if report["launch"]["mode"] != expected_launch:
        failures.append(f"{label}: launch mode mismatch")
    if runtime == "electron" and report["launch"].get("rendererCreated") is not False:
        failures.append(f"{label}: Electron renderer boundary is not explicit")

    wrapper = report["packages"]["wrapper"]
    platform = report["packages"]["platform"]
    if not wrapper["id"].startswith("doe-gpu@"):
        failures.append(f"{label}: wrapper package identity mismatch")
        version = ""
    else:
        version = wrapper["id"].split("@", 1)[1]
    if platform["id"] != f"{platform_package_name}@{version}":
        failures.append(f"{label}: platform package identity mismatch")
    wrapper_tarball = _validate_package_artifact(
        report_path, wrapper, f"{label}: wrapper package", failures
    )
    platform_tarball = _validate_package_artifact(
        report_path, platform, f"{label}: platform package", failures
    )

    implementation = report["implementation"]
    expected_paths = {
        "runner": "packages/doe-gpu/test/integration/test-integration-native-clean-install.js",
        "candidateFixture": "packages/doe-gpu/test/fixtures/native-release-candidate.mjs",
        "firstKernel": f"packages/doe-gpu/examples/{runtime}-first-kernel.mjs",
        "wrapperManifest": "packages/doe-gpu/package.json",
        "platformManifest": f"packages/{platform_package_name}/package.json",
        "stagedAddon": f"packages/{platform_package_name}/bin/doe_napi.node",
        "stagedBuildMetadata": (
            f"packages/{platform_package_name}/bin/doe-build-metadata.json"
        ),
    }
    for reference_name, expected_path in expected_paths.items():
        if implementation[reference_name]["path"] != expected_path:
            failures.append(f"{label}: {reference_name} source path mismatch")
    for reference_name in (
        "runner",
        "candidateFixture",
        "firstKernel",
        "wrapperManifest",
        "platformManifest",
    ):
        _check_source_reference(
            source,
            commit,
            implementation[reference_name],
            f"{label}: {reference_name}",
            failures,
        )

    if wrapper_tarball is not None:
        wrapper_members = {
            "wrapperManifest": "package/package.json",
            "firstKernel": f"package/examples/{runtime}-first-kernel.mjs",
        }
        for reference_name, member_name in wrapper_members.items():
            payload = tarballs.member(
                wrapper_tarball,
                member_name,
                f"{label}: wrapper package",
                failures,
            )
            _check_hash(
                payload,
                implementation[reference_name]["sha256"],
                f"{label}: packed {reference_name}",
                failures,
            )
    if platform_tarball is not None:
        platform_members = {
            "platformManifest": "package/package.json",
            "stagedAddon": "package/bin/doe_napi.node",
            "stagedBuildMetadata": "package/bin/doe-build-metadata.json",
        }
        for reference_name, member_name in platform_members.items():
            payload = tarballs.member(
                platform_tarball,
                member_name,
                f"{label}: platform package",
                failures,
            )
            _check_hash(
                payload,
                implementation[reference_name]["sha256"],
                f"{label}: packed {reference_name}",
                failures,
            )
        library = tarballs.member(
            platform_tarball,
            f"package/bin/{library_name}",
            f"{label}: platform package",
            failures,
        )
        _check_hash(
            library,
            platform["stagedLibrarySha256"],
            f"{label}: packed native library",
            failures,
        )

    _validate_governed_replay(report, label, failures)
    if report["governedReplay"]["adapterInfo"].get("isFallbackAdapter") is True:
        failures.append(f"{label}: fallback adapter is not candidate-eligible")
    _validate_reliability(report_path, report, runtime, source, failures)
    decision = report["decision"]
    for field in ZERO_CREDIT_DECISIONS:
        if decision[field] is not False:
            failures.append(f"{label}: decision {field} must remain false")


def validate_candidate_set(
    repo_root: Path,
    candidate_paths: list[Path],
    expected_platform: str,
    expected_arch: str,
    required_runtimes: tuple[str, ...] = REQUIRED_RUNTIMES,
) -> list[str]:
    failures: list[str] = []
    repo_root = repo_root.resolve()
    if (expected_platform, expected_arch) not in PLATFORM_PACKAGES:
        return [f"unsupported candidate tuple: {expected_platform}-{expected_arch}"]
    schema = _load_json(repo_root / SCHEMA_PATH, "candidate schema", failures)
    if schema is None:
        return failures
    source = SourceTree(repo_root)
    tarballs = Tarballs()
    loaded: list[tuple[Path, dict[str, Any]]] = []
    for candidate_path in candidate_paths:
        path = candidate_path.resolve()
        report = _load_json(path, str(path), failures)
        if report is None or not _validate_schema(report, schema, path.name, failures):
            continue
        if report.get("schemaVersion") != 2:
            failures.append(
                f"{path.name}: schemaVersion 2 is required for retained package custody"
            )
            continue
        loaded.append((path, report))
        _validate_candidate(
            path,
            report,
            expected_platform,
            expected_arch,
            source,
            tarballs,
            failures,
        )

    runtimes = [report["runtime"]["host"] for _, report in loaded]
    if sorted(runtimes) != sorted(required_runtimes):
        failures.append(
            "candidate set runtime mismatch: "
            f"expected {sorted(required_runtimes)}, received {sorted(runtimes)}"
        )
    if loaded:
        bundle_roots = {path.parent for path, _ in loaded}
        if len(bundle_roots) != 1:
            failures.append("candidate set must share one self-contained bundle directory")
        source_commits = {report["sourceCommit"] for _, report in loaded}
        if len(source_commits) != 1:
            failures.append("candidate set source commits differ")
        package_identities = {
            (
                report["packages"]["wrapper"]["id"],
                report["packages"]["wrapper"]["bytes"],
                report["packages"]["wrapper"]["sha256"],
                report["packages"]["platform"]["id"],
                report["packages"]["platform"]["bytes"],
                report["packages"]["platform"]["sha256"],
                report["packages"]["platform"]["stagedLibrarySha256"],
            )
            for _, report in loaded
        }
        if len(package_identities) != 1:
            failures.append("candidate set package identities differ")
        adapter_fields = (
            "vendor",
            "architecture",
            "device",
            "description",
            "vendorID",
            "deviceID",
            "driverVersion",
        )
        adapter_identities = {
            tuple(
                report["governedReplay"]["adapterInfo"][field]
                for field in adapter_fields
            )
            for _, report in loaded
        }
        if len(adapter_identities) != 1:
            failures.append("candidate set adapter identities differ")
    return failures


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("candidates", nargs="+", type=Path)
    parser.add_argument("--repo-root", type=Path, default=REPO_ROOT)
    parser.add_argument("--expected-platform", required=True, choices=("linux", "darwin"))
    parser.add_argument("--expected-arch", required=True, choices=("x64", "arm64"))
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    failures = validate_candidate_set(
        args.repo_root,
        args.candidates,
        args.expected_platform,
        args.expected_arch,
    )
    if failures:
        print("doe-gpu native release candidate gate: failed")
        for failure in failures:
            print(f"- {failure}")
        return 1
    print(
        "doe-gpu native release candidate gate: passed "
        f"{args.expected_platform}-{args.expected_arch} "
        f"({', '.join(REQUIRED_RUNTIMES)})"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
