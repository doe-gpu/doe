"""Focused tests for the version-3 Doe Zig architecture analyzer."""

from __future__ import annotations

import sys
import tempfile
import unittest
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))

from check_source_layout import architecture_errors
from check_core_import_fence import (
    BACKEND_COMPOSITION_ROOTS,
    BACKEND_PRIVATE_DIRS,
    BACKEND_PROVIDER_INTEGRATION_ROOTS,
    backend_private_import_allowed,
    has_broad_provider_driver_bridge,
    has_direct_prepared_command_construction,
    has_process_global_provider_cache_state,
)
from check_line_limits import evaluate_line_policy
from source_architecture import analyze, load_manifest, matches_glob


def _manifest() -> dict[str, Any]:
    return {
        "version": 3,
        "sourceRoot": "src",
        "moduleRoot": "src/mod.zig",
        "compatibilityFacades": [],
        "architecture": {
            "layers": {
                "root": {
                    "globs": ["src/mod.zig"],
                    "mayImport": ["contracts", "root", "runtime"],
                },
                "contracts": {
                    "globs": ["src/contracts/**"],
                    "mayImport": ["contracts"],
                },
                "runtime": {
                    "globs": ["src/runtime/**"],
                    "mayImport": ["contracts", "runtime"],
                },
                "backend-metal": {
                    "globs": ["src/backend/metal/**"],
                    "mayImport": ["backend-metal"],
                },
                "backend-vulkan": {
                    "globs": ["src/backend/vulkan/**"],
                    "mayImport": ["backend-vulkan"],
                },
            },
            "productionRoots": ["src/mod.zig"],
            "reachabilityViews": {
                "shipped-runtime": {
                    "description": "fixture shipped runtime",
                    "roots": ["src/mod.zig"],
                }
            },
            "specialRoles": {
                "compatibility-facade": {"globs": []},
                "entrypoint": {"globs": ["src/mod.zig"]},
                "ffi-boundary": {"globs": []},
                "generated": {"globs": []},
                "package-root": {"globs": ["src/mod.zig"]},
            },
            "compatibilityFacadeContracts": {},
            "dependencyExceptions": [],
            "cycleExceptions": [],
            "reachabilityExceptions": [],
            "cohesiveModuleJustifications": [],
            "canonicalContracts": {},
            "generatedSourceContracts": {},
            "moduleDecisionReviews": {},
            "linePolicy": {
                "advisoryReviewLines": 800,
                "futureHardMaximumLines": 1500,
                "futureJustificationAboveLines": 1200,
                "mode": "transition",
                "transitionMaximumLines": 999,
            },
            "enforcement": {
                "cycles": "error",
                "unreachableModules": "error",
            },
        },
    }


def _write(root: Path, relative_path: str, content: str) -> None:
    path = root / relative_path
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")


class SourceArchitectureTests(unittest.TestCase):
    def test_line_policy_excludes_declared_generated_sources(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            _write(
                root,
                "src/generated.zig",
                "pub const generated = 1;\n" * 1001,
            )
            _write(root, "src/handwritten.zig", "pub const value = 1;\n" * 801)
            config = _manifest()
            config["architecture"]["linePolicy"]["mode"] = "future"
            config["architecture"]["specialRoles"]["generated"]["globs"] = [
                "src/generated.zig"
            ]

            errors, advisories = evaluate_line_policy(root / "src", config)

            self.assertEqual(errors, [])
            self.assertEqual(
                advisories,
                [
                    "src/handwritten.zig: 801 lines exceeds advisory review "
                    "signal 800"
                ],
            )

    def test_process_global_provider_cache_state_is_rejected(self) -> None:
        self.assertTrue(has_process_global_provider_cache_state("var process_cache_handle: u64 = 0;"))
        self.assertTrue(has_process_global_provider_cache_state("pub fn set_process_pipeline_cache_disabled(value: bool) void {}"))
        self.assertFalse(has_process_global_provider_cache_state("pipeline_cache: VulkanPipelineCache"))

    def test_direct_prepared_command_construction_is_rejected(self) -> None:
        self.assertTrue(has_direct_prepared_command_construction("return prepared.fromCommand(command, id);"))
        self.assertTrue(has_direct_prepared_command_construction("return prepared_contract.fromCommand(command, id);"))
        self.assertFalse(has_direct_prepared_command_construction("return app.prepareCommand(command, id);"))

    def test_broad_provider_driver_bridge_is_rejected(self) -> None:
        self.assertTrue(has_broad_provider_driver_bridge("return Driver.executeCommand(ctx, command);"))
        self.assertTrue(has_broad_provider_driver_bridge("pub const executeCommand = execute_command;"))
        self.assertFalse(has_broad_provider_driver_bridge("pub const executePreparedRender = execute_render;"))

    def test_provider_private_imports_require_explicit_owners(self) -> None:
        metal_root, vulkan_root, _ = BACKEND_PRIVATE_DIRS
        composition_root = next(iter(BACKEND_COMPOSITION_ROOTS))
        integration_root = next(iter(BACKEND_PROVIDER_INTEGRATION_ROOTS))
        common_module = metal_root.parent / "backend_runtime_telemetry.zig"

        self.assertTrue(
            backend_private_import_allowed(
                metal_root / "mod.zig",
                metal_root / "metal_native_runtime.zig",
            )
        )
        self.assertTrue(
            backend_private_import_allowed(
                composition_root,
                vulkan_root / "mod.zig",
            )
        )
        self.assertTrue(
            backend_private_import_allowed(
                integration_root,
                metal_root / "metal_bridge_decls.zig",
            )
        )
        self.assertFalse(
            backend_private_import_allowed(
                metal_root / "mod.zig",
                vulkan_root / "mod.zig",
            )
        )
        self.assertFalse(
            backend_private_import_allowed(
                common_module,
                metal_root / "mod.zig",
            )
        )
        self.assertNotIn(common_module.resolve(), BACKEND_COMPOSITION_ROOTS)

    def test_manifest_loader_rejects_duplicate_json_keys(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            path = Path(temporary_directory) / "source-layout.json"
            path.write_text('{"version": 1, "version": 2}\n', encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "duplicate JSON object key"):
                load_manifest(path)

    def test_recursive_glob_does_not_cross_owner_prefix(self) -> None:
        self.assertTrue(matches_glob("src/contracts/model/a.zig", "src/contracts/**"))
        self.assertFalse(matches_glob("src/core/a.zig", "src/contracts/**"))
        self.assertTrue(matches_glob("src/backend/a.zig", "src/backend/*.zig"))
        self.assertFalse(
            matches_glob("src/backend/metal/a.zig", "src/backend/*.zig")
        )

    def test_forbidden_contract_edge_requires_exact_exception(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            _write(root, "src/mod.zig", 'const c = @import("contracts/a.zig");\n')
            _write(
                root,
                "src/contracts/a.zig",
                'const r = @import("../runtime/b.zig");\n',
            )
            _write(root, "src/runtime/b.zig", "pub const value = 1;\n")
            config = _manifest()
            analysis = analyze(root, config)
            self.assertEqual(len(analysis.forbidden_edges), 1)
            self.assertFalse(analysis.forbidden_edges[0]["allowedByException"])
            config["architecture"]["dependencyExceptions"].append(
                {
                    "source": "src/contracts/a.zig",
                    "target": "src/runtime/b.zig",
                    "reason": "fixture debt",
                    "removalCondition": "remove fixture debt",
                }
            )
            excepted = analyze(root, config)
            self.assertTrue(excepted.forbidden_edges[0]["allowedByException"])
            self.assertEqual(excepted.stale_dependency_exceptions, ())

    def test_backend_sibling_import_is_always_forbidden(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            _write(root, "src/mod.zig", "pub const value = 1;\n")
            _write(
                root,
                "src/backend/metal/a.zig",
                'const vk = @import("../vulkan/b.zig");\n',
            )
            _write(root, "src/backend/vulkan/b.zig", "pub const value = 1;\n")
            config = _manifest()
            config["architecture"]["layers"]["backend-metal"]["mayImport"].append(
                "backend-vulkan"
            )
            analysis = analyze(root, config)
            self.assertEqual(
                analysis.forbidden_edges[0]["reason"],
                "concrete-backend-sibling-import",
            )

    def test_cycles_and_unreachable_modules_are_deterministic(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            _write(root, "src/mod.zig", 'const a = @import("runtime/a.zig");\n')
            _write(root, "src/runtime/a.zig", 'const b = @import("b.zig");\n')
            _write(root, "src/runtime/b.zig", 'const a = @import("a.zig");\n')
            _write(root, "src/runtime/orphan.zig", "pub const orphan = true;\n")
            analysis = analyze(root, _manifest())
            self.assertEqual(
                analysis.cycles,
                (("src/runtime/a.zig", "src/runtime/b.zig"),),
            )
            self.assertEqual(analysis.unreachable, ("src/runtime/orphan.zig",))

    def test_named_reachability_views_do_not_change_aggregate_gate(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            _write(root, "src/mod.zig", 'const a = @import("runtime/a.zig");\n')
            _write(root, "src/runtime/a.zig", "pub const value = 1;\n")
            _write(root, "src/runtime/tool.zig", "pub const tool = true;\n")
            config = _manifest()
            config["architecture"]["productionRoots"].append(
                "src/runtime/tool.zig"
            )
            config["architecture"]["reachabilityViews"]["tooling"] = {
                "description": "fixture tooling",
                "roots": ["src/runtime/tool.zig"],
            }
            analysis = analyze(root, config)
            self.assertEqual(analysis.unreachable, ())
            self.assertEqual(
                analysis.modules[1]["reachabilityViews"],
                ["shipped-runtime"],
            )
            self.assertEqual(
                analysis.modules[2]["reachabilityViews"],
                ["tooling"],
            )

    def test_reachability_view_root_must_match_source(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            _write(root, "src/mod.zig", "pub const value = 1;\n")
            config = _manifest()
            config["architecture"]["reachabilityViews"]["shipped-runtime"][
                "roots"
            ] = ["src/missing.zig"]
            analysis = analyze(root, config)
            self.assertIn(
                "reachability view 'shipped-runtime' root matches no Zig source: "
                "src/missing.zig",
                analysis.manifest_errors,
            )

    def test_overlapping_layer_globs_fail_manifest_analysis(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            _write(root, "src/mod.zig", "pub const value = 1;\n")
            config = _manifest()
            config["architecture"]["layers"]["runtime"]["globs"].append(
                "src/mod.zig"
            )
            analysis = analyze(root, config)
            self.assertIn(
                "src/mod.zig: expected exactly one layer, got ['root', 'runtime']",
                analysis.manifest_errors,
            )

    def test_transition_and_future_line_policies_fail_explicitly(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            _write(root, "src/mod.zig", "pub const value = 1;\n" * 1000)
            config = _manifest()
            analysis = analyze(root, config)
            self.assertTrue(
                any(
                    "exceeds transition maximum 999" in error
                    for error in architecture_errors(analysis, config)
                )
            )
            config["architecture"]["linePolicy"]["mode"] = "future"
            config["architecture"]["linePolicy"]["futureJustificationAboveLines"] = 900
            future_errors = architecture_errors(analyze(root, config), config)
            self.assertTrue(
                any(
                    "requires a cohesive-module justification" in error
                    for error in future_errors
                )
            )
            config["architecture"]["cohesiveModuleJustifications"] = [
                {
                    "path": "src/mod.zig",
                    "reason": "fixture cohesion",
                    "responsibility": "fixture root",
                }
            ]
            justified_errors = architecture_errors(analyze(root, config), config)
            self.assertFalse(
                any(
                    "cohesive-module justification" in error
                    for error in justified_errors
                )
            )

    def test_exception_contract_requires_removal_condition(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            _write(root, "src/mod.zig", "pub const value = 1;\n")
            config = _manifest()
            config["architecture"]["dependencyExceptions"] = [
                {
                    "source": "src/mod.zig",
                    "target": "src/mod.zig",
                    "reason": "invalid fixture exception",
                }
            ]
            analysis = analyze(root, config)
            self.assertIn(
                "every dependency exception requires source, target, reason, "
                "and removalCondition",
                analysis.manifest_errors,
            )

    def test_stale_cycle_and_reachability_exceptions_are_blocking(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            _write(root, "src/mod.zig", 'const a = @import("runtime/a.zig");\n')
            _write(root, "src/runtime/a.zig", "pub const value = 1;\n")
            config = _manifest()
            config["architecture"]["cycleExceptions"] = [
                {
                    "members": ["src/runtime/a.zig", "src/runtime/b.zig"],
                    "reason": "resolved fixture cycle",
                    "removalCondition": "remove when the fixture cycle is gone",
                }
            ]
            config["architecture"]["reachabilityExceptions"] = [
                {
                    "path": "src/runtime/a.zig",
                    "reason": "resolved fixture orphan",
                    "removalCondition": "remove when the fixture is reachable",
                }
            ]
            errors = architecture_errors(analyze(root, config), config)
            self.assertTrue(any("stale cycle exception" in error for error in errors))
            self.assertTrue(
                any("stale reachability exception" in error for error in errors)
            )

    def test_generated_contract_requires_reproducible_commands(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            _write(root, "src/mod.zig", "pub const value = 1;\n")
            config = _manifest()
            config["architecture"]["specialRoles"]["generated"]["globs"] = [
                "src/mod.zig"
            ]
            config["architecture"]["generatedSourceContracts"] = {
                "src/mod.zig": {
                    "owner": "fixture",
                    "reason": "fixture generated source",
                }
            }
            analysis = analyze(root, config)
            self.assertIn(
                "generated source contract 'src/mod.zig' missing: check, "
                "generator, inputs",
                analysis.manifest_errors,
            )

    def test_canonical_contract_gate_rejects_missing_symbols_and_legacy_paths(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            _write(
                root,
                "src/mod.zig",
                'const command = @import("contracts/command.zig");\n',
            )
            _write(
                root,
                "src/contracts/command.zig",
                "pub const Kind = enum { upload };\n",
            )
            _write(
                root,
                "src/runtime/command_partition.zig",
                "pub const legacy = true;\n",
            )
            config = _manifest()
            config["architecture"]["canonicalContracts"] = {
                "command-registry": {
                    "path": "src/contracts/command.zig",
                    "requiredPublicDeclarations": ["Command", "Kind"],
                    "forbiddenLegacyPaths": ["src/runtime/command_partition.zig"],
                }
            }
            errors = architecture_errors(analyze(root, config), config)
            self.assertIn(
                "canonical command-registry contract src/contracts/command.zig "
                "is incomplete: Command",
                errors,
            )
            self.assertIn(
                "legacy command-registry contract must not exist: "
                "src/runtime/command_partition.zig",
                errors,
            )

    def test_canonical_contract_manifest_requires_complete_shape(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            _write(root, "src/mod.zig", "pub const value = 1;\n")
            config = _manifest()
            config["architecture"]["canonicalContracts"] = {
                "command-registry": {"path": "src/contracts/command.zig"}
            }
            analysis = analyze(root, config)
            self.assertIn(
                "canonical contract 'command-registry' missing: "
                "forbiddenLegacyPaths, requiredPublicDeclarations",
                analysis.manifest_errors,
            )

    def test_module_decision_review_is_bound_to_module_content(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            _write(root, "src/mod.zig", "pub const value = 1;\n")
            config = _manifest()
            initial = analyze(root, config)
            config["architecture"]["moduleDecisionReviews"] = {
                "src/mod.zig": {
                    "decision": "Keep",
                    "moduleSha256": initial.modules[0]["sha256"],
                    "reason": "fixture package root",
                    "reviewer": "fixture-reviewer",
                }
            }
            self.assertEqual(analyze(root, config).manifest_errors, ())
            _write(root, "src/mod.zig", "pub const value = 2;\n")
            stale = analyze(root, config)
            self.assertTrue(
                any(
                    "module decision review is stale" in error
                    for error in stale.manifest_errors
                )
            )


if __name__ == "__main__":
    unittest.main()
