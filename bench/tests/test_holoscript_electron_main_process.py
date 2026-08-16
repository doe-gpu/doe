from __future__ import annotations

import hashlib
import json
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
HARNESS = ROOT / "bench/external-projects/holoscript-snn-webgpu"
REPORT = (
    ROOT
    / "reports/benchmarks/amd-vulkan/20260816T-current-runtime-sync-fix2"
    / "holoscript-electron-main-process-p0-diagnostic.json"
)
REVIEWED_REPORT = (
    ROOT
    / "reports/ecosystem/holoscript-snn-webgpu"
    / "holoscript-electron-main-process-p0-current-runtime-2026-08-16-diagnostic.json"
)


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


class HoloScriptElectronMainProcessTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.plan = json.loads(
            (HARNESS / "electron-main-process.plan.json").read_text()
        )
        cls.report_text = REPORT.read_text()
        cls.report = json.loads(cls.report_text)
        cls.reviewed_report = json.loads(REVIEWED_REPORT.read_text())
        cls.registry = json.loads((ROOT / "config/ecosystem-registry.json").read_text())

    def test_plan_freezes_the_narrow_electron_contract(self) -> None:
        self.assertEqual(
            self.plan["candidateId"],
            "holoscript-electron-main-process-p0-qm0-v1",
        )
        self.assertEqual(
            self.plan["runtime"],
            {
                "host": "electron",
                "version": "43.4.0",
                "mode": "main-process-node-side",
                "arguments": ["--headless", "--no-sandbox", "--disable-gpu"],
            },
        )
        self.assertEqual(
            set(self.plan["lanes"]), {"I0", "I1", "W0", "D0", "A0", "P0"}
        )
        self.assertEqual(
            self.plan["workload"]["resourceObservation"],
            {
                "platform": "linux-procfs",
                "sampleIntervalMs": 5,
                "aggregation": "sum VmRSS across the live process tree",
                "claimClass": "diagnostic-peak",
            },
        )
        self.assertEqual(self.plan["p0"]["package"], "webgpu@0.3.10")
        self.assertEqual(
            self.plan["p0"]["nodeWebgpuCommit"],
            "c7c792ba7facd9e831a52d8e2a0c1dd166654751",
        )
        self.assertEqual(
            self.plan["p0"]["dawnCommit"],
            "c5d549e250b9225744929ae860b369cb4304a767",
        )
        self.assertEqual(
            self.plan["p0"]["go"],
            {
                "version": "go1.26.6",
                "archive": "https://go.dev/dl/go1.26.6.linux-amd64.tar.gz",
                "sha256": (
                    "708effb774be8237570d0add163225abbdfaf4fca28b2611df"
                    "167beba4feef89"
                ),
            },
        )
        for credit in (
            "performanceCredit",
            "runtimeOwnershipCredit",
            "applicationPromotionCredit",
            "releaseCredit",
        ):
            self.assertFalse(self.plan["acceptance"][credit])

    def test_reviewed_report_is_hash_bound_to_current_inputs(self) -> None:
        self.assertEqual(self.report["status"], "passed")
        self.assertEqual(self.report["candidateId"], self.plan["candidateId"])
        self.assertEqual(
            self.report["plan"]["sha256"],
            sha256(ROOT / self.report["plan"]["path"]),
        )
        for reference in self.report["immutableInputs"]:
            path = Path(reference["path"])
            if not path.is_absolute():
                path = ROOT / path
            self.assertEqual(reference["sha256"], sha256(path), reference["path"])

    def test_incumbent_failure_and_doe_exactness_are_preserved(self) -> None:
        for lane_id in ("I0", "I1", "W0"):
            lane = self.report["lanes"][lane_id]
            self.assertEqual(lane["runCount"], 3)
            self.assertEqual(lane["passingRuns"], 0)
            self.assertTrue(
                all(evidence["externalBufferFailure"] for evidence in lane["evidence"])
            )

        d0 = self.report["lanes"]["D0"]
        self.assertEqual(d0["runCount"], 3)
        self.assertEqual(d0["passingRuns"], 3)
        for evidence in d0["evidence"]:
            self.assertEqual(evidence["effectiveProvider"], "doe-gpu")
            self.assertTrue(evidence["hardwareEligible"])
            self.assertEqual(len(evidence["topologies"]), 4)
            for topology in evidence["topologies"]:
                self.assertEqual(topology["maxDiff"], 0)
                self.assertEqual(topology["outputHash"], topology["oracleHash"])

        self.assertEqual(self.report["replay"]["D0"]["status"], "passed")
        self.assertEqual(
            self.report["replay"]["D0"]["expectedEvidenceSha256"],
            self.report["replay"]["D0"]["actualEvidenceSha256"],
        )

    def test_source_built_p0_closes_the_application_gap(self) -> None:
        a0 = self.report["lanes"]["A0"]
        self.assertEqual(a0["runCount"], 1)
        self.assertEqual(a0["passingRuns"], 0)
        self.assertEqual(a0["evidence"][0]["signal"], "SIGABRT")
        self.assertFalse(self.report["observations"]["applicationWorkaroundPassed"])

        p0 = self.report["lanes"]["P0"]
        self.assertEqual(p0["runCount"], 3)
        self.assertEqual(p0["passingRuns"], 3)
        self.assertGreater(p0["peakProcessTreeRssBytes"], 0)
        for evidence in p0["evidence"]:
            self.assertEqual(evidence["effectiveProvider"], "dawn-node-webgpu")
            self.assertTrue(evidence["hardwareEligible"])
            for topology in evidence["topologies"]:
                self.assertEqual(topology["maxDiff"], 0)
                self.assertEqual(topology["outputHash"], topology["oracleHash"])
        self.assertEqual(self.report["replay"]["P0"]["status"], "passed")
        self.assertEqual(
            self.report["replay"]["P0"]["expectedEvidenceSha256"],
            self.report["replay"]["P0"]["actualEvidenceSha256"],
        )
        self.assertGreater(self.report["lanes"]["D0"]["peakProcessTreeRssBytes"], 0)
        source_build = self.report["sourceBuild"]
        self.assertEqual(
            source_build["nodeWebgpuCommit"], self.plan["p0"]["nodeWebgpuCommit"]
        )
        self.assertEqual(source_build["dawnCommit"], self.plan["p0"]["dawnCommit"])
        self.assertEqual(source_build["goArchive"], self.plan["p0"]["go"])
        self.assertEqual(
            source_build["toolchain"]["go"], "go version go1.26.6 linux/amd64"
        )
        self.assertEqual(
            source_build["patch"]["sha256"],
            sha256(ROOT / source_build["patch"]["path"]),
        )
        self.assertEqual(
            self.report["packages"]["incumbentP0"]["nativeSha256"],
            "98359dec2b4778a82b61a4d6a643953bdd3995ab162e5ddfcc5d51df335479f9",
        )

    def test_claim_boundary_remains_diagnostic_only(self) -> None:
        self.assertEqual(
            self.report["tuple"]["mode"], "main-process-node-side"
        )
        self.assertFalse(self.report["tuple"]["rendererCreated"])
        self.assertEqual(
            self.report["decision"]["compatibilityEvidence"],
            "authorized-for-declared-electron-main-process-tuple",
        )
        self.assertFalse(self.report["decision"]["uniqueCorrectionObserved"])
        self.assertTrue(self.report["decision"]["boundedIncumbentPatchClosesGap"])
        self.assertEqual(
            self.report["decision"]["runtimeOwnershipDecision"],
            "rejected-for-declared-electron-main-process-tuple",
        )
        for credit in (
            "runtimeOwnershipCredit",
            "applicationPromotionCredit",
            "performanceCredit",
            "releaseCredit",
        ):
            self.assertFalse(self.report["decision"][credit])
        self.assertEqual(
            self.report["decision"]["nextGate"],
            "retain-regression-and-offer-bounded-patch-upstream",
        )
        self.assertNotIn("/tmp/doe-holoscript-electron-", self.report_text)
        self.assertEqual(
            self.report["packages"]["doe"]["modulePath"],
            "<clean-install>/node_modules/doe-gpu/src/index.js",
        )
        self.assertEqual(self.report["workaround"]["packageDir"], "<temporary-copy>")

    def test_reviewed_report_and_registry_bind_the_raw_diagnostic(self) -> None:
        reviewed = self.reviewed_report
        self.assertEqual(reviewed["review"]["status"], "reviewed")
        self.assertEqual(reviewed["evidenceMaturity"], "diagnostic")
        self.assertEqual(reviewed["outcome"], "no-material-result")
        self.assertEqual(
            reviewed["runtimeOwnershipAssessment"]["decision"],
            "carry-bounded-patch",
        )
        self.assertEqual(
            reviewed["reliability"]["baseline"]["peakMemoryBytes"],
            self.report["lanes"]["P0"]["peakProcessTreeRssBytes"],
        )
        self.assertEqual(
            reviewed["reliability"]["comparison"]["peakMemoryBytes"],
            self.report["lanes"]["D0"]["peakProcessTreeRssBytes"],
        )
        for reference in reviewed["receipts"] + reviewed["rawEvidence"]:
            self.assertEqual(reference["sha256"], sha256(ROOT / reference["path"]))

        actor = next(
            actor
            for actor in self.registry["actors"]
            if actor["id"] == "holoscript-snn-webgpu"
        )
        registry_reference = next(
            reference
            for reference in actor["reviewedReports"]
            if reference["reportId"] == reviewed["reportId"]
        )
        self.assertEqual(registry_reference["sha256"], sha256(REVIEWED_REPORT))


if __name__ == "__main__":
    unittest.main()
