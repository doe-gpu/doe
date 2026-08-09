"""Focused tests for deterministic architecture and baseline reports."""

from __future__ import annotations

import hashlib
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent))

from capture_semantic_fixtures import (
    _install_ir_digest_observer,
    _publish_fixture_set,
)
from check_recomposition_reports import _candidate_errors
from generate_architecture_reports import (
    _cochange_report,
    build_reports,
    write_or_check,
)
from generate_recomposition_baseline import (
    _baseline_manifest,
    _semantic_artifact_records,
    build_baseline,
)
from source_architecture import analyze
from test_source_architecture import _manifest, _write
from verify_recomposition_baseline import classify
from verify_semantic_fixtures import classify as classify_semantic_fixtures
from verify_semantic_fixtures import load_verified_fixture_set


class ArchitectureReportTests(unittest.TestCase):
    def test_cochange_history_head_ignores_report_only_commits(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            repository = Path(temporary_directory) / "doe"
            runtime_root = repository / "runtime" / "zig"
            _write(runtime_root, "src/mod.zig", "pub const value = 1;\n")
            subprocess.run(["git", "init", "-q"], cwd=repository, check=True)
            subprocess.run(
                ["git", "config", "user.email", "test@example.com"],
                cwd=repository,
                check=True,
            )
            subprocess.run(
                ["git", "config", "user.name", "Test"],
                cwd=repository,
                check=True,
            )
            subprocess.run(["git", "add", "."], cwd=repository, check=True)
            subprocess.run(
                ["git", "commit", "-qm", "source"],
                cwd=repository,
                check=True,
            )
            source_commit = subprocess.run(
                ["git", "rev-parse", "HEAD"],
                cwd=repository,
                check=True,
                capture_output=True,
                text=True,
            ).stdout.strip()
            _write(
                runtime_root,
                "reports/architecture/co-change.json",
                "{}\n",
            )
            subprocess.run(["git", "add", "."], cwd=repository, check=True)
            subprocess.run(
                ["git", "commit", "-qm", "report"],
                cwd=repository,
                check=True,
            )
            config = _manifest()
            analysis = analyze(runtime_root, config)
            report = _cochange_report(runtime_root, analysis)
            self.assertEqual(report["historyHead"], source_commit)

    def test_frozen_snapshot_ir_observer_is_explicitly_instrumented(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            snapshot = root / "snapshot"
            source = root / "source"
            _write(
                snapshot,
                "build.zig",
                "pub fn build() void {\n"
                "    const emit_csl_exe = b.addExecutable(.{\n"
                "}\n",
            )
            _write(
                snapshot,
                "src/compiler/wgsl/mod.zig",
                'pub const ir = @import("ir/ir.zig");\n',
            )
            _write(
                source,
                "src/cli/entrypoints/main_emit_ir_digest.zig",
                "pub fn main() void {}\n",
            )
            _write(
                source,
                "src/compiler/wgsl/ir/ir_digest.zig",
                "pub fn compute() void {}\n",
            )
            receipt = _install_ir_digest_observer(snapshot, source)
            self.assertEqual(receipt["kind"], "post-hoc-pure-observer")
            self.assertEqual(receipt["status"], "installed")
            self.assertIn(
                'pub const ir_digest = @import("ir/ir_digest.zig");',
                (snapshot / "src/compiler/wgsl/mod.zig").read_text(
                    encoding="utf-8"
                ),
            )
            self.assertIn(
                "emit-ir-digest",
                (snapshot / "build.zig").read_text(encoding="utf-8"),
            )

    def test_semantic_fixture_publication_replaces_only_complete_set(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            destination = root / "semantic-current"
            staging = root / "staging"
            _write(destination, "old.txt", "old\n")
            _write(staging, "manifest.json", "{}\n")
            _write(staging, "new.txt", "new\n")
            _publish_fixture_set(staging, destination)
            self.assertFalse(staging.exists())
            self.assertFalse((destination / "old.txt").exists())
            self.assertEqual(
                (destination / "new.txt").read_text(encoding="utf-8"),
                "new\n",
            )
            self.assertEqual(
                list(root.glob(".semantic-current.previous-*")),
                [],
            )

    def test_semantic_candidate_must_match_source_and_receipt(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            baseline_root = root / "recomposition"
            source_hash = "a" * 64
            fixture = b"stable\n"
            _write(root, "tools/capture_semantic_fixtures.py", "# capture\n")
            capture_tool_sha256 = hashlib.sha256(b"# capture\n").hexdigest()

            def write_fixture_set(
                path: Path,
                commit: str,
                capture_tool: str | None = None,
            ) -> None:
                _write(path, "fixture.txt", fixture.decode("utf-8"))
                _write(
                    path,
                    "manifest.json",
                    json.dumps(
                        {
                            "files": [
                                {
                                    "path": "fixture.txt",
                                    "sha256": hashlib.sha256(fixture).hexdigest(),
                                    "sizeBytes": len(fixture),
                                }
                            ],
                            "git": {"baseCommit": commit},
                            "captureToolSha256": capture_tool,
                        }
                    ),
                )

            write_fixture_set(
                baseline_root / "semantic-fixtures",
                "b" * 40,
            )
            write_fixture_set(
                baseline_root / "semantic-current",
                f"WORKTREE:{source_hash}",
                capture_tool_sha256,
            )
            _write(
                baseline_root,
                "semantic-current-verification.json",
                json.dumps(
                    {
                        "baselineCommit": "b" * 40,
                        "candidateCommit": f"WORKTREE:{source_hash}",
                        "classification": "exact-semantic-equivalence",
                        "schemaVersion": 1,
                    }
                ),
            )
            self.assertEqual(
                _candidate_errors(root, baseline_root, source_hash),
                [],
            )
            self.assertIn(
                "semantic candidate is not bound to the architecture source digest",
                _candidate_errors(root, baseline_root, "c" * 64),
            )

    def test_snapshot_bound_abi_symbols_become_baseline_artifacts(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            _write(
                root,
                "reports/recomposition/semantic-fixtures/abi/lib.symbols.txt",
                "symbol_a\nsymbol_b\n",
            )
            records, symbols = _semantic_artifact_records(
                root,
                {
                    "sharedLibraries": [
                        {
                            "path": "lib.so",
                            "sha256": "a" * 64,
                            "sizeBytes": 100,
                            "symbolCount": 2,
                            "symbols": "abi/lib.symbols.txt",
                        }
                    ]
                },
            )
            self.assertEqual(records[0]["symbolCount"], 2)
            self.assertIn("source=git-snapshot", symbols)

    def test_frozen_manifest_restores_only_historical_experimental_layer(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            _write(root, "src/experimental/mod.zig", "pub const value = 1;\n")
            config = _manifest()
            config["architecture"]["moduleDecisionReviews"] = {
                "src/current.zig": {
                    "decision": "Keep",
                    "moduleSha256": "a" * 64,
                    "reason": "current source review",
                    "reviewer": "fixture",
                }
            }
            frozen, wrapper = _baseline_manifest(config, root, "a" * 40)
            self.assertIn("experimental", frozen["architecture"]["layers"])
            self.assertEqual(
                wrapper["adjustments"][0]["type"],
                "restore-historical-experimental-layer",
            )
            self.assertNotIn("experimental", config["architecture"]["layers"])
            self.assertEqual(
                frozen["architecture"]["moduleDecisionReviews"],
                {},
            )
            self.assertEqual(
                wrapper["adjustments"][1]["type"],
                "remove-live-module-decision-reviews",
            )

    def test_report_write_and_check_detects_stale_content(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary_root = Path(temporary_directory)
            runtime_root = temporary_root / "runtime" / "zig"
            _write(runtime_root, "src/mod.zig", "pub const value = 1;\n")
            config = _manifest()
            config_path = runtime_root / "source-layout.json"
            config_path.write_text(json.dumps(config), encoding="utf-8")
            analysis = analyze(runtime_root, config)
            reports = build_reports(analysis, config, config_path)
            decisions = json.loads(reports["module-decisions.json"])
            self.assertEqual(decisions["totalCount"], 1)
            self.assertEqual(decisions["pendingCount"], 1)
            self.assertEqual(decisions["entries"][0]["suggestedDecision"], "Keep")
            reachability = json.loads(reports["reachability-views.json"])
            self.assertEqual(reachability["classifiedModuleCount"], 1)
            self.assertEqual(reachability["facadeOnlyFiles"], [])
            self.assertEqual(reachability["unclassifiedFiles"], [])
            self.assertEqual(
                reachability["views"][0]["name"],
                "shipped-runtime",
            )
            output_root = runtime_root / "reports" / "architecture"
            self.assertEqual(
                write_or_check(reports, output_root, check=False),
                [],
            )
            self.assertEqual(write_or_check(reports, output_root, check=True), [])
            (output_root / "modules.json").write_text("{}\n", encoding="utf-8")
            errors = write_or_check(reports, output_root, check=True)
            self.assertEqual(len(errors), 1)
            self.assertIn("stale architecture report", errors[0])

    def test_structural_baseline_marks_uncaptured_behavior_explicitly(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary_root = Path(temporary_directory)
            runtime_root = temporary_root / "workspace" / "doe" / "runtime" / "zig"
            _write(runtime_root, "src/mod.zig", "pub const value = 1;\n")
            _write(runtime_root, "STYLE.md", "# Fixture style\n")
            _write(
                runtime_root,
                "tools/check_source_layout.py",
                "# fixture checker\n",
            )
            _write(
                runtime_root,
                "tools/check_recomposition_reports.py",
                "# fixture report integrity\n",
            )
            _write(
                runtime_root,
                "tools/capture_build_measurements.py",
                "# fixture measurement capture\n",
            )
            _write(
                runtime_root,
                "tools/capture_semantic_fixtures.py",
                "# fixture semantic capture\n",
            )
            _write(
                runtime_root,
                "tools/verify_semantic_fixtures.py",
                "# fixture semantic verifier\n",
            )
            _write(runtime_root, "tools/source_architecture.py", "# fixture analyzer\n")
            _write(runtime_root, "tools/ast_inventory.py", "# fixture AST runner\n")
            _write(
                runtime_root,
                "tools/generate_architecture_reports.py",
                "# fixture report generator\n",
            )
            _write(runtime_root, "tools/source_ast_inventory.zig", "// fixture AST\n")
            _write(
                runtime_root,
                "tools/verify_recomposition_baseline.py",
                "# fixture verifier\n",
            )
            config = _manifest()
            config_path = runtime_root / "source-layout.json"
            config_path.write_text(json.dumps(config), encoding="utf-8")
            analysis = analyze(runtime_root, config)
            with (
                patch(
                    "generate_recomposition_baseline._git_state",
                    return_value={
                        "baseCommit": "a" * 40,
                        "dirtyPaths": [],
                        "isClean": True,
                    },
                ),
                patch(
                    "generate_recomposition_baseline._artifact_records",
                    return_value=([], "# no artifacts\n"),
                ),
                patch(
                    "generate_recomposition_baseline._zig_identity",
                    return_value={
                        "path": None,
                        "status": "not-found",
                        "version": None,
                    },
                ),
            ):
                artifacts = build_baseline(
                    runtime_root,
                    config_path,
                    config,
                    analysis,
                    [],
                )
            baseline = json.loads(artifacts["baseline.json"])
            self.assertEqual(baseline["baselineKind"], "structural-recomposition")
            self.assertEqual(
                baseline["behaviorCapture"]["semanticFixtures"],
                "not-captured",
            )
            self.assertEqual(baseline["architectureObservationCapture"], "captured")
            observations = json.loads(artifacts["architecture-observations.json"])
            self.assertEqual(observations["captureStatus"], "captured")
            self.assertEqual(observations["observations"]["moduleCount"], 1)
            public_api = json.loads(artifacts["public-api.json"])
            self.assertEqual(public_api["modules"][0]["path"], "src/mod.zig")

    def test_baseline_verifier_requires_explicit_contract_approval(self) -> None:
        baseline = {
            "public-api.json": json.dumps(
                {
                    "modules": [
                        {
                            "declarations": [
                                {"kind": "const", "line": 1, "name": "old"}
                            ],
                            "path": "src/mod.zig",
                        }
                    ]
                }
            ),
            "exported-symbols.txt": "symbol_a\n",
        }
        current = {
            "public-api.json": json.dumps(
                {
                    "modules": [
                        {
                            "declarations": [
                                {"kind": "const", "line": 1, "name": "new"}
                            ],
                            "path": "src/mod.zig",
                        }
                    ]
                }
            ),
            "exported-symbols.txt": "symbol_a\n",
        }
        exit_code, receipt = classify(baseline, current, set(), None)
        self.assertEqual(exit_code, 1)
        self.assertEqual(receipt["classification"], "failure")
        self.assertEqual(receipt["failureBoundary"], "public-api")
        exit_code, receipt = classify(
            baseline,
            current,
            {"public-api"},
            "intentional fixture rename",
        )
        self.assertEqual(exit_code, 0)
        self.assertEqual(receipt["classification"], "approved-contract-change")

    def test_semantic_verifier_requires_explicit_category_approval(self) -> None:
        baseline_manifest = {
            "git": {"baseCommit": "a" * 40},
            "commandNormalization": {"input": "command-input.json"},
        }
        candidate_manifest = {
            "git": {"baseCommit": "b" * 40},
            "commandNormalization": {"input": "command-input.json"},
        }
        baseline_files = {"command-normalized.jsonl": b"old\n"}
        candidate_files = {"command-normalized.jsonl": b"new\n"}
        exit_code, receipt = classify_semantic_fixtures(
            baseline_manifest,
            baseline_files,
            candidate_manifest,
            candidate_files,
            set(),
            None,
        )
        self.assertEqual(exit_code, 1)
        self.assertEqual(receipt["failureBoundary"], "command-normalization")
        exit_code, receipt = classify_semantic_fixtures(
            baseline_manifest,
            baseline_files,
            candidate_manifest,
            candidate_files,
            {"command-normalization"},
            "intentional fixture change",
        )
        self.assertEqual(exit_code, 0)
        self.assertEqual(receipt["classification"], "approved-contract-change")

    def test_semantic_verifier_classifies_exported_symbol_changes_as_abi(self) -> None:
        baseline_manifest = {
            "git": {"baseCommit": "a" * 40},
            "sharedLibraries": [{"path": "lib.so", "sha256": "a" * 64}],
        }
        candidate_manifest = {
            "git": {"baseCommit": "b" * 40},
            "sharedLibraries": [{"path": "lib.so", "sha256": "b" * 64}],
        }
        baseline_files = {"abi/lib.symbols.txt": b"old_symbol\n"}
        candidate_files = {"abi/lib.symbols.txt": b"new_symbol\n"}
        exit_code, receipt = classify_semantic_fixtures(
            baseline_manifest,
            baseline_files,
            candidate_manifest,
            candidate_files,
            set(),
            None,
        )
        self.assertEqual(exit_code, 1)
        self.assertEqual(receipt["failureBoundary"], "abi-surface")
        self.assertEqual(
            {difference["category"] for difference in receipt["differences"]},
            {"abi-surface"},
        )
        self.assertEqual(len(receipt["differences"]), 1)
        self.assertEqual(
            receipt["differences"][0]["path"],
            "abi/lib.symbols.txt",
        )

    def test_semantic_verifier_requires_same_ir_digest_observer(self) -> None:
        baseline_manifest = {
            "git": {"baseCommit": "a" * 40},
            "irDigestInstrumentation": {
                "observers": [{"path": "digest.zig", "sha256": "a" * 64}]
            },
        }
        candidate_manifest = {
            "git": {"baseCommit": "b" * 40},
            "irDigestInstrumentation": {
                "observers": [{"path": "digest.zig", "sha256": "b" * 64}]
            },
        }
        exit_code, receipt = classify_semantic_fixtures(
            baseline_manifest,
            {},
            candidate_manifest,
            {},
            set(),
            None,
        )
        self.assertEqual(exit_code, 1)
        self.assertEqual(receipt["failureBoundary"], "wgsl-lowering")
        self.assertEqual(
            receipt["differences"][0]["path"],
            "manifest:irDigestObserver",
        )

    def test_semantic_fixture_integrity_rejects_tampering(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            content = b"stable\n"
            _write(root, "fixture.txt", content.decode("utf-8"))
            (root / "manifest.json").write_text(
                json.dumps(
                    {
                        "files": [
                            {
                                "path": "fixture.txt",
                                "sha256": hashlib.sha256(content).hexdigest(),
                                "sizeBytes": len(content),
                            }
                        ]
                    }
                ),
                encoding="utf-8",
            )
            _, files = load_verified_fixture_set(root)
            self.assertEqual(files["fixture.txt"], content)
            _write(root, "fixture.txt", "changed\n")
            with self.assertRaisesRegex(RuntimeError, "size mismatch"):
                load_verified_fixture_set(root)

    def test_semantic_fixture_integrity_rejects_untracked_and_escaping_paths(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            content = b"stable\n"
            _write(root, "fixture.txt", content.decode("utf-8"))
            manifest_path = root / "manifest.json"
            manifest_path.write_text(
                json.dumps(
                    {
                        "files": [
                            {
                                "path": "fixture.txt",
                                "sha256": hashlib.sha256(content).hexdigest(),
                                "sizeBytes": len(content),
                            }
                        ]
                    }
                ),
                encoding="utf-8",
            )
            _write(root, "untracked.txt", "untracked\n")
            with self.assertRaisesRegex(RuntimeError, "inventory mismatch"):
                load_verified_fixture_set(root)
            (root / "untracked.txt").unlink()
            payload = json.loads(manifest_path.read_text(encoding="utf-8"))
            payload["files"][0]["path"] = "../fixture.txt"
            manifest_path.write_text(json.dumps(payload), encoding="utf-8")
            with self.assertRaisesRegex(RuntimeError, "invalid semantic fixture path"):
                load_verified_fixture_set(root)

    def test_baseline_verifier_ignores_provenance_only_changes(self) -> None:
        baseline = {
            "public-api.json": json.dumps(
                {
                    "modules": [
                        {
                            "declarations": [
                                {"kind": "const", "line": 1, "name": "stable"}
                            ],
                            "path": "src/mod.zig",
                        }
                    ],
                    "sourceTreeSha256": "old",
                }
            ),
            "exported-symbols.txt": "# old artifact\nsymbol_a\n",
        }
        current = {
            "public-api.json": json.dumps(
                {
                    "modules": [
                        {
                            "declarations": [
                                {"kind": "const", "line": 9, "name": "stable"}
                            ],
                            "path": "src/mod.zig",
                        }
                    ],
                    "sourceTreeSha256": "new",
                }
            ),
            "exported-symbols.txt": "# new artifact\nsymbol_a\n",
        }
        exit_code, receipt = classify(baseline, current, set(), None)
        self.assertEqual(exit_code, 0)
        self.assertEqual(receipt["classification"], "exact-semantic-equivalence")

    def test_baseline_verifier_detects_public_contract_hash_change(self) -> None:
        def public_api(contract_hash: str) -> str:
            return json.dumps(
                {
                    "modules": [
                        {
                            "declarations": [
                                {
                                    "contractTokenSha256": contract_hash,
                                    "kind": "function",
                                    "name": "run",
                                }
                            ],
                            "path": "src/mod.zig",
                        }
                    ]
                }
            )

        baseline = {
            "public-api.json": public_api("a" * 64),
            "exported-symbols.txt": "symbol_a\n",
        }
        current = {
            "public-api.json": public_api("b" * 64),
            "exported-symbols.txt": "symbol_a\n",
        }
        exit_code, receipt = classify(baseline, current, set(), None)
        self.assertEqual(exit_code, 1)
        self.assertEqual(receipt["differences"][0]["surface"], "public-api")

    def test_zig_ast_inventory_emits_normalized_declarations(self) -> None:
        runtime_root = Path(__file__).resolve().parents[1]
        zig = sorted((runtime_root.parents[1] / ".tooling").glob("zig-*/zig"))[-1]
        tool = runtime_root / "tools" / "source_ast_inventory.zig"
        with tempfile.TemporaryDirectory() as temporary_directory:
            source = Path(temporary_directory) / "fixture.zig"
            source.write_text(
                "pub const Mode = enum { fast, safe };\n"
                "pub fn select(mode: Mode) u8 {\n"
                "    return switch (mode) { .fast => 1, .safe => 2 };\n"
                "}\n",
                encoding="utf-8",
            )
            result = subprocess.run(
                [str(zig), "run", str(tool), "--", str(source)],
                cwd=runtime_root,
                check=True,
                capture_output=True,
                text=True,
            )
        payload = json.loads(result.stdout)
        self.assertEqual(payload[0]["parseErrorCount"], 0)
        self.assertEqual(payload[0]["declarations"][0]["kind"], "enum")
        self.assertEqual(
            payload[0]["declarations"][1]["switchTags"],
            ["fast", "safe"],
        )
        self.assertEqual(
            payload[0]["declarations"][1]["literalTokens"],
            ["1", "2"],
        )
        self.assertIsNotNone(
            payload[0]["declarations"][1]["literalTokenSha256"]
        )


if __name__ == "__main__":
    unittest.main()
