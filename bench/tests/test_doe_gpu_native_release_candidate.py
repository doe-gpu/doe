from __future__ import annotations

import copy
import hashlib
import io
import json
import subprocess
import tarfile
import tempfile
import unittest
from pathlib import Path

import jsonschema

from bench.gates.doe_gpu_native_release_candidate_gate import (
    EXPECTED_OUTPUT_SHA256,
    validate_candidate_set,
)


ROOT = Path(__file__).resolve().parents[2]
REPORT_DIR = ROOT / "reports/benchmarks/amd-vulkan/20260828T152721Z"
SCHEMA_PATH = ROOT / "config/doe-gpu-native-release-candidate.schema.json"
RUNTIMES = ("node", "bun", "electron")
RECORDED_IMPLEMENTATION_COMMIT = "cbb9be04b03f52358521c67bd7f014619fc4fe5c"
REPORTS = {
    runtime: REPORT_DIR / f"doe-gpu-{runtime}-native-release-candidate.json"
    for runtime in RUNTIMES
}


def sha256(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def git_blob(commit: str, path: str) -> bytes:
    return subprocess.run(
        ["git", "show", f"{commit}:{path}"],
        cwd=ROOT,
        check=True,
        capture_output=True,
    ).stdout


def write_tarball(path: Path, members: dict[str, bytes]) -> None:
    with tarfile.open(path, mode="w:gz") as archive:
        for name, payload in sorted(members.items()):
            member = tarfile.TarInfo(name)
            member.size = len(payload)
            member.mode = 0o644
            member.mtime = 0
            archive.addfile(member, io.BytesIO(payload))


def write_json(path: Path, payload: object) -> None:
    path.write_text(f"{json.dumps(payload, indent=2)}\n", encoding="utf-8")


def build_retained_bundle(bundle_root: Path) -> dict[str, Path]:
    reports = {
        runtime: json.loads(path.read_text(encoding="utf-8"))
        for runtime, path in REPORTS.items()
    }
    commit = RECORDED_IMPLEMENTATION_COMMIT
    packages_root = bundle_root / "packages"
    packages_root.mkdir(parents=True)
    wrapper_path = packages_root / "doe-gpu-0.5.0.tgz"
    platform_path = packages_root / "doe-gpu-linux-x64-0.5.0.tgz"
    wrapper_members = {
        "package/package.json": git_blob(commit, "packages/doe-gpu/package.json"),
        **{
            f"package/examples/{runtime}-first-kernel.mjs": git_blob(
                commit,
                f"packages/doe-gpu/examples/{runtime}-first-kernel.mjs",
            )
            for runtime in RUNTIMES
        },
    }
    addon = b"synthetic-doe-addon\n"
    metadata = b'{"synthetic":true}\n'
    library = b"synthetic-doe-runtime\n"
    platform_members = {
        "package/package.json": git_blob(
            commit,
            "packages/doe-gpu-linux-x64/package.json",
        ),
        "package/bin/doe_napi.node": addon,
        "package/bin/doe-build-metadata.json": metadata,
        "package/bin/libwebgpu_doe.so": library,
    }
    write_tarball(wrapper_path, wrapper_members)
    write_tarball(platform_path, platform_members)
    wrapper_package = {
        "id": "doe-gpu@0.5.0",
        "bytes": wrapper_path.stat().st_size,
        "sha256": sha256(wrapper_path.read_bytes()),
        "artifactPath": "packages/doe-gpu-0.5.0.tgz",
    }
    platform_package = {
        "id": "doe-gpu-linux-x64@0.5.0",
        "bytes": platform_path.stat().st_size,
        "sha256": sha256(platform_path.read_bytes()),
        "artifactPath": "packages/doe-gpu-linux-x64-0.5.0.tgz",
        "stagedLibrarySha256": sha256(library),
    }

    candidate_paths: dict[str, Path] = {}
    for runtime, report in reports.items():
        report["schemaVersion"] = 2
        report["sourceCommit"] = commit
        report["packages"] = {
            "wrapper": copy.deepcopy(wrapper_package),
            "platform": copy.deepcopy(platform_package),
        }
        report["implementation"]["stagedAddon"]["sha256"] = sha256(addon)
        report["implementation"]["stagedBuildMetadata"]["sha256"] = sha256(metadata)

        old_reliability_path = ROOT / report["reliabilityEvidence"]["path"]
        reliability = json.loads(old_reliability_path.read_text(encoding="utf-8"))
        reliability["packages"] = {
            "wrapper": {
                key: wrapper_package[key] for key in ("id", "bytes", "sha256")
            },
            "platform": {
                key: platform_package[key]
                for key in ("id", "bytes", "sha256", "stagedLibrarySha256")
            },
        }
        reliability_path = (
            bundle_root / f"doe-gpu-{runtime}-native-release-candidate.reliability.json"
        )
        write_json(reliability_path, reliability)
        report["reliabilityEvidence"] = {
            "path": reliability_path.name,
            "sha256": sha256(reliability_path.read_bytes()),
            "artifactKind": reliability["artifactKind"],
            "status": reliability["status"],
        }
        candidate_path = bundle_root / f"doe-gpu-{runtime}-native-release-candidate.json"
        write_json(candidate_path, report)
        candidate_paths[runtime] = candidate_path
    return candidate_paths


class DoeGpuNativeReleaseCandidateTests(unittest.TestCase):
    def test_retained_candidate_set_passes_independent_gate(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            candidates = build_retained_bundle(Path(temporary))
            failures = validate_candidate_set(
                ROOT,
                list(candidates.values()),
                "linux",
                "x64",
            )
            self.assertEqual(failures, [])

    def test_gate_rejects_missing_retained_package_bytes(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            bundle_root = Path(temporary)
            candidates = build_retained_bundle(bundle_root)
            (bundle_root / "packages/doe-gpu-0.5.0.tgz").unlink()
            failures = validate_candidate_set(
                ROOT,
                list(candidates.values()),
                "linux",
                "x64",
            )
            self.assertTrue(any("referenced file is missing" in item for item in failures))

    def test_gate_rejects_receipt_digest_drift(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            candidates = build_retained_bundle(Path(temporary))
            node_path = candidates["node"]
            node = json.loads(node_path.read_text(encoding="utf-8"))
            node["governedReplay"]["primaryReceipt"]["execution"]["durationMs"] += 1
            write_json(node_path, node)
            failures = validate_candidate_set(
                ROOT,
                list(candidates.values()),
                "linux",
                "x64",
            )
            self.assertIn(
                "doe-gpu-node-native-release-candidate.json: primary receipt digest mismatch",
                failures,
            )

    def test_gate_rejects_incomplete_runtime_set(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            candidates = build_retained_bundle(Path(temporary))
            failures = validate_candidate_set(
                ROOT,
                [candidates["node"], candidates["bun"]],
                "linux",
                "x64",
            )
            self.assertTrue(any("candidate set runtime mismatch" in item for item in failures))

    def test_gate_rejects_source_commit_drift(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            candidates = build_retained_bundle(Path(temporary))
            for candidate_path in candidates.values():
                candidate = json.loads(candidate_path.read_text(encoding="utf-8"))
                candidate["sourceCommit"] = "d255ff815530daae5254dc05e3a98f52d224f442"
                write_json(candidate_path, candidate)
            failures = validate_candidate_set(
                ROOT,
                list(candidates.values()),
                "linux",
                "x64",
            )
            self.assertTrue(any("runner: SHA-256 mismatch" in item for item in failures))
            self.assertTrue(
                any("candidateFixture: source path is absent" in item for item in failures)
            )

    def test_gate_rejects_reliability_join_drift(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            bundle_root = Path(temporary)
            candidates = build_retained_bundle(bundle_root)
            node_path = candidates["node"]
            node = json.loads(node_path.read_text(encoding="utf-8"))
            reliability_path = bundle_root / node["reliabilityEvidence"]["path"]
            reliability = json.loads(reliability_path.read_text(encoding="utf-8"))
            reliability["packages"]["wrapper"]["sha256"] = "0" * 64
            write_json(reliability_path, reliability)
            node["reliabilityEvidence"]["sha256"] = sha256(reliability_path.read_bytes())
            write_json(node_path, node)
            failures = validate_candidate_set(
                ROOT,
                list(candidates.values()),
                "linux",
                "x64",
            )
            self.assertIn(
                "doe-gpu-node-native-release-candidate.json: reliability: "
                "wrapper sha256 mismatch",
                failures,
            )

    def test_gate_rejects_hidden_reliability_trial_failure(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            bundle_root = Path(temporary)
            candidates = build_retained_bundle(bundle_root)
            node_path = candidates["node"]
            node = json.loads(node_path.read_text(encoding="utf-8"))
            reliability_path = bundle_root / node["reliabilityEvidence"]["path"]
            reliability = json.loads(reliability_path.read_text(encoding="utf-8"))
            reliability["trials"][0]["exitCode"] = 1
            write_json(reliability_path, reliability)
            node["reliabilityEvidence"]["sha256"] = sha256(reliability_path.read_bytes())
            write_json(node_path, node)
            failures = validate_candidate_set(
                ROOT,
                list(candidates.values()),
                "linux",
                "x64",
            )
            self.assertIn(
                "doe-gpu-node-native-release-candidate.json: reliability: "
                "bounded process trial failed: sequential-0",
                failures,
            )

    def test_legacy_candidates_remain_schema_readable_but_lack_custody(self) -> None:
        schema = json.loads(SCHEMA_PATH.read_text(encoding="utf-8"))
        for runtime, path in REPORTS.items():
            with self.subTest(runtime=runtime):
                report = json.loads(path.read_text(encoding="utf-8"))
                jsonschema.validate(report, schema)
                self.assertEqual(report["schemaVersion"], 1)
                self.assertNotIn("artifactPath", report["packages"]["wrapper"])
                self.assertNotIn("artifactPath", report["packages"]["platform"])
                self.assertNotEqual(
                    report["implementation"]["runner"]["sha256"],
                    sha256(
                        git_blob(
                            report["sourceCommit"],
                            report["implementation"]["runner"]["path"],
                        )
                    ),
                )
                self.assertEqual(report["runtime"]["host"], runtime)
                self.assertEqual(
                    report["governedReplay"]["outputSha256"],
                    EXPECTED_OUTPUT_SHA256,
                )
                self.assertTrue(all(report["governedReplay"]["matches"].values()))
                self.assertFalse(report["decision"]["registryPublicationCredit"])
                self.assertFalse(report["decision"]["runtimeOwnershipCredit"])
                self.assertFalse(report["decision"]["performanceCredit"])
                self.assertFalse(report["decision"]["applicationPromotionCredit"])


if __name__ == "__main__":
    unittest.main()
