from __future__ import annotations

import importlib.util
import json
import tempfile
import unittest
from pathlib import Path
from typing import Any


MODULE_PATH = (
    Path(__file__).resolve().parents[1]
    / "native-compare"
    / "compare_doe_vs_tint_compilation.py"
)


def _load_module() -> Any:
    spec = importlib.util.spec_from_file_location(
        "compare_doe_vs_tint_compilation",
        MODULE_PATH,
    )
    if spec is None or spec.loader is None:
        raise RuntimeError(f"failed to load module: {MODULE_PATH}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class TestCompareDoeVsTintCompilation(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.module = _load_module()

    def test_command_version_uses_fallback_on_probe_failure(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            script = Path(tmpdir) / "tool"
            script.write_text(
                "#!/bin/sh\n"
                "echo usage >&2\n"
                "exit 2\n",
                encoding="utf-8",
            )
            script.chmod(script.stat().st_mode | 0o111)

            version = self.module.command_version([str(script)], "fallback-version")

        self.assertEqual(version, "fallback-version")

    def test_command_version_reads_first_success_line(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            script = Path(tmpdir) / "tool"
            script.write_text(
                "#!/bin/sh\n"
                "echo tool-version\n"
                "echo detail\n",
                encoding="utf-8",
            )
            script.chmod(script.stat().st_mode | 0o111)

            version = self.module.command_version([str(script)], "fallback-version")

        self.assertEqual(version, "tool-version")

    def test_tint_warm_alias_map_includes_materialized_workload_name(self) -> None:
        aliases = self.module.build_tint_warm_alias_map(
            [
                {
                    "name": "compilation_alpha_msl",
                    "workloadId": "compilation_alpha_msl",
                    "path": "/repo/bench/kernels/alpha.wgsl",
                }
            ]
        )

        self.assertEqual(aliases["compilation_alpha_msl"], "compilation_alpha_msl")
        self.assertEqual(aliases["compilation_alpha_msl.wgsl"], "compilation_alpha_msl")
        self.assertEqual(aliases["alpha.wgsl"], "compilation_alpha_msl")

    def test_preferred_tint_warm_benchmark_name_uses_materialized_workload(self) -> None:
        name = self.module.preferred_tint_warm_benchmark_name(
            {
                "name": "compilation_alpha_msl",
                "workloadId": "compilation_alpha_msl",
                "path": "/repo/bench/kernels/alpha.wgsl",
            }
        )

        self.assertEqual(name, "compilation_alpha_msl.wgsl")

    def test_parse_google_benchmark_json_skips_warning_prefix(self) -> None:
        payload = self.module.parse_google_benchmark_json(
            "warning text\n"
            "{\n"
            "  \"benchmarks\": []\n"
            "}\n"
        )

        self.assertEqual(payload, {"benchmarks": []})

    def test_google_benchmark_filter_literal_keeps_hyphen_plain(self) -> None:
        escaped = self.module.google_benchmark_filter_literal("atan2-const-eval.wgsl")

        self.assertEqual(escaped, "atan2-const-eval\\.wgsl")

    def test_wgsl_corpus_manifest_loader_preserves_manifest_metadata(self) -> None:
        shaders = self.module.discover_wgsl_corpus_rows(
            "config/wgsl-browser-corpus.json",
            ["webgpu-prefix-sum"],
            ["spirv"],
        )

        self.assertEqual(len(shaders), 1)
        shader = shaders[0]
        self.assertEqual(shader["workloadId"], "webgpu-prefix-sum")
        self.assertEqual(shader["name"], "webgpu-prefix-sum")
        self.assertEqual(shader["corpusCategory"], "webgpu_sample")
        self.assertEqual(shader["expectedValidity"], "valid")
        self.assertIn("spirv", shader["expectedBackendTargets"])
        self.assertEqual(shader["shaderStage"], "compute")
        self.assertTrue(shader["path"].endswith("bench/fixtures/wgsl-corpus/webgpu/sample-prefix-sum.wgsl"))

    def test_tint_benchmark_rows_preserve_configured_backend_targets(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            dawn = root / "dawn"
            script = dawn / "src" / "tint" / "cmd" / "bench" / "generate_benchmark_inputs.py"
            shader = dawn / "test" / "tint" / "benchmark" / "alpha.wgsl"
            script.parent.mkdir(parents=True)
            shader.parent.mkdir(parents=True)
            script.write_text(
                "kBenchmarkFiles = [\n"
                "    \"test/tint/benchmark/alpha.wgsl\",\n"
                "]\n\n\n"
                "def main():\n"
                "    pass\n",
                encoding="utf-8",
            )
            shader.write_text("@compute @workgroup_size(1)\nfn main() {}\n", encoding="utf-8")

            rows = self.module.discover_tint_benchmark_rows(
                script,
                ["alpha.wgsl"],
                ["spirv"],
            )

        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["expectedBackendTargets"], ["spirv"])
        self.assertNotIn("target", rows[0])

    def test_tint_phase_benchmark_timings_extracts_named_scopes(self) -> None:
        payload = {
            "benchmarks": [
                {
                    "name": "ParseWGSL/shader.wgsl",
                    "run_type": "iteration",
                    "real_time": 10,
                    "time_unit": "ns",
                },
                {
                    "name": "ValidateIR/shader.wgsl",
                    "run_type": "iteration",
                    "real_time": 20,
                    "time_unit": "ns",
                },
                {
                    "name": "GenerateSPIRV/shader.wgsl",
                    "run_type": "iteration",
                    "real_time": 30,
                    "time_unit": "ns",
                },
                {
                    "name": "GenerateSPIRV/other.wgsl",
                    "run_type": "iteration",
                    "real_time": 99,
                    "time_unit": "ns",
                },
            ]
        }

        timings = self.module.tint_phase_benchmark_timings(
            payload,
            "GenerateSPIRV",
            {"shader.wgsl"},
        )

        self.assertEqual(
            timings,
            {
                "generateBackend": 30,
                "parseWgsl": 10,
                "validateIr": 20,
            },
        )

    def test_evidence_report_uses_wgsl_corpus_manifest_path_and_stage(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            evidence_out = Path(tmpdir) / "tint-compiler-evidence.json"
            args = type(
                "Args",
                (),
                {
                    "evidence_out": str(evidence_out),
                    "doe_emit_binary": "missing/doe-runtime-compile-report",
                    "dry_run": True,
                },
            )()
            shaders = self.module.discover_wgsl_corpus_rows(
                "config/wgsl-browser-corpus.json",
                ["webgpu-prefix-sum"],
                ["spirv"],
            )

            report = self.module.build_evidence_report(
                {
                    "_configPath": "bench/native-compare/compare_doe_vs_tint.browser-corpus.config.json",
                    "_evidenceManifestPath": "config/wgsl-browser-corpus.json",
                    "_sourceLabel": "config/wgsl-browser-corpus.json",
                    "run": {"outStem": "doe-vs-tint-browser-corpus"},
                    "comparison": {"binaryPath": "missing/tint"},
                },
                shaders,
                "spirv",
                [],
                None,
                args,
            )

        self.assertEqual(report["corpus"]["manifestPath"], "config/wgsl-browser-corpus.json")
        self.assertEqual(report["corpus"]["source"], "config/wgsl-browser-corpus.json")
        self.assertEqual(report["rows"][0]["shaderId"], "webgpu-prefix-sum")
        self.assertEqual(report["rows"][0]["corpusCategory"], "webgpu_sample")
        self.assertEqual(report["rows"][0]["shaderStage"], "compute")
        self.assertIn("spirv", report["rows"][0]["expectedBackendTargets"])

    def test_toolchain_info_includes_tint_warm_binary(self) -> None:
        cfg = {
            "comparison": {
                "binaryPath": "missing/tint",
                "warmBinaryPath": "missing/tint_benchmark",
            }
        }
        args = type("Args", (), {"doe_emit_binary": "missing/doe-runtime-compile-report"})()

        toolchains = self.module.build_toolchain_info(cfg, args)

        self.assertIn("tintWarm", toolchains)
        self.assertEqual(toolchains["tintWarm"]["name"], "tint-benchmark")
        self.assertEqual(toolchains["tintWarm"]["artifactSha256"], None)
        self.assertEqual(
            toolchains["tintWarm"]["command"],
            ["missing/tint_benchmark", "--benchmark_format=json"],
        )

    def test_toolchain_info_uses_requested_backend_target(self) -> None:
        cfg = {
            "comparison": {
                "binaryPath": "missing/tint",
            }
        }
        args = type("Args", (), {"doe_emit_binary": "missing/doe-runtime-compile-report"})()

        toolchains = self.module.build_toolchain_info(cfg, args, "spirv")

        self.assertEqual(
            toolchains["doe"]["command"],
            ["missing/doe-runtime-compile-report", "--target", "spirv", "--emit-spirv"],
        )
        self.assertEqual(
            toolchains["tint"]["command"],
            ["missing/tint", "--format=spirv"],
        )

    def test_comparability_rejects_whole_compile_only_phase_evidence(self) -> None:
        record = {
            "status": "compared",
            "comparison": {"warm": {"p50_ns": 10}},
        }
        doe_result = self.module.make_compiler_result(
            status="ok",
            diagnostic_code="",
            output_sha256="1" * 64,
            ir_sha256="2" * 64,
            validation_status="passed",
            validation_tool="validator",
            phase_total_ns=10,
            receipt_path="bench/out/scratch/doe.json",
        )
        tint_result = self.module.make_compiler_result(
            status="ok",
            diagnostic_code="",
            output_sha256="3" * 64,
            validation_status="passed",
            validation_tool="validator",
            phase_total_ns=10,
            receipt_path="bench/out/scratch/tint.json",
        )

        comparability = self.module.build_row_comparability(
            record,
            doe_result,
            tint_result,
            self.module.CLAIMABLE_REQUIRED_PHASES,
        )

        self.assertEqual(comparability["status"], "diagnostic")
        self.assertIn("doe missing phase timing: parse", comparability["reasons"])
        self.assertIn("tint missing phase timing: emit", comparability["reasons"])

    def test_compile_doe_evidence_output_reads_compile_report_phase_timings(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            shader_path = root / "shader.wgsl"
            shader_path.write_text(
                "@compute @workgroup_size(1)\nfn main() {}\n",
                encoding="utf-8",
            )
            script = root / "doe-runtime-compile-report"
            script.write_text(
                "#!/usr/bin/env python3\n"
                "import json, sys\n"
                "args = sys.argv[1:]\n"
                "emit_path = args[args.index('--emit-msl') + 1]\n"
                "out_path = args[args.index('--out') + 1]\n"
                "open(emit_path, 'w', encoding='utf-8').write('// msl\\n')\n"
                "payload = {\n"
                "  'kind': 'runtime_compile_report',\n"
                "  'phaseTimingsNs': {\n"
                "    'parse': 11,\n"
                "    'sema': 12,\n"
                "    'lower': 13,\n"
                "    'emit': 14,\n"
                "    'total': 60,\n"
                "  },\n"
                "}\n"
                "open(out_path, 'w', encoding='utf-8').write(json.dumps(payload) + '\\n')\n",
                encoding="utf-8",
            )
            script.chmod(script.stat().st_mode | 0o111)
            evidence_dir = root / "evidence"

            original_validate = self.module.validate_msl_output
            self.module.validate_msl_output = lambda _path: {
                "status": "passed",
                "tool": "test-validator",
                "reason": "",
            }
            try:
                result = self.module.compile_doe_evidence_output(
                    {
                        "name": "shader",
                        "path": str(shader_path),
                    },
                    "msl",
                    {
                        "status": "compared",
                        "baseline": {"p50_ns": 100},
                    },
                    evidence_dir,
                    str(script),
                    False,
                )
            finally:
                self.module.validate_msl_output = original_validate

        self.assertEqual(result["status"], "ok")
        self.assertEqual(
            result["phaseTimingsNs"],
            {
                "parse": 11,
                "sema": 12,
                "lower": 13,
                "emit": 14,
                "total": 60,
            },
        )

    def test_compile_doe_evidence_output_supports_spirv_target(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            shader_path = root / "shader.wgsl"
            shader_path.write_text(
                "@compute @workgroup_size(1)\nfn main() {}\n",
                encoding="utf-8",
            )
            script = root / "doe-runtime-compile-report"
            script.write_text(
                "#!/usr/bin/env python3\n"
                "import json, sys\n"
                "args = sys.argv[1:]\n"
                "assert args[args.index('--target') + 1] == 'spirv'\n"
                "emit_path = args[args.index('--emit-spirv') + 1]\n"
                "out_path = args[args.index('--out') + 1]\n"
                "open(emit_path, 'wb').write(b'\\x03\\x02\\x23\\x07')\n"
                "payload = {\n"
                "  'kind': 'runtime_compile_report',\n"
                "  'target': 'spirv',\n"
                "  'phaseTimingsNs': {\n"
                "    'parse': 21,\n"
                "    'sema': 22,\n"
                "    'lower': 23,\n"
                "    'emit': 24,\n"
                "    'total': 90,\n"
                "  },\n"
                "}\n"
                "open(out_path, 'w', encoding='utf-8').write(json.dumps(payload) + '\\n')\n",
                encoding="utf-8",
            )
            script.chmod(script.stat().st_mode | 0o111)
            evidence_dir = root / "evidence"

            original_validate = self.module.validate_shader_output
            self.module.validate_shader_output = lambda _path, target: {
                "status": "passed" if target == "spirv" else "failed",
                "tool": "test-spirv-val",
                "reason": "",
            }
            try:
                result = self.module.compile_doe_evidence_output(
                    {
                        "name": "shader",
                        "path": str(shader_path),
                    },
                    "spirv",
                    {
                        "status": "compared",
                        "baseline": {"p50_ns": 100},
                    },
                    evidence_dir,
                    str(script),
                    False,
                )
            finally:
                self.module.validate_shader_output = original_validate

        self.assertEqual(result["status"], "ok")
        self.assertEqual(result["validationTool"], "test-spirv-val")
        self.assertTrue(result["outputPath"].endswith("evidence/shader/doe/output.spv"))
        self.assertEqual(
            result["phaseTimingsNs"],
            {
                "parse": 21,
                "sema": 22,
                "lower": 23,
                "emit": 24,
                "total": 90,
            },
        )

    def test_compile_doe_evidence_output_preserves_compile_diagnostic(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            shader_path = root / "shader.wgsl"
            shader_path.write_text(
                "@compute @workgroup_size(1)\nfn main() {}\n",
                encoding="utf-8",
            )
            script = root / "doe-runtime-compile-report"
            script.write_text(
                "#!/usr/bin/env python3\n"
                "import sys\n"
                "sys.stderr.write('missing Doe lowering for textureBarrier\\n')\n"
                "sys.exit(3)\n",
                encoding="utf-8",
            )
            script.chmod(script.stat().st_mode | 0o111)

            result = self.module.compile_doe_evidence_output(
                {
                    "name": "shader",
                    "path": str(shader_path),
                },
                "spirv",
                {
                    "status": "compared",
                    "baseline": {"p50_ns": 100},
                },
                root / "evidence",
                str(script),
                False,
            )

        self.assertEqual(result["status"], "failed")
        self.assertEqual(result["diagnosticCode"], "doe_compile_failed")
        self.assertIn("missing Doe lowering for textureBarrier", result["diagnosticMessage"])
        self.assertEqual(result["validationMessage"], "")

    def test_compile_tint_evidence_output_supports_spirv_target(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            shader_path = root / "shader.wgsl"
            shader_path.write_text(
                "@compute @workgroup_size(1)\nfn main() {}\n",
                encoding="utf-8",
            )
            script = root / "tint"
            script.write_text(
                "#!/usr/bin/env python3\n"
                "import sys\n"
                "assert '--format=spirv' in sys.argv[1:]\n"
                "sys.stdout.buffer.write(b'\\x03\\x02\\x23\\x07')\n",
                encoding="utf-8",
            )
            script.chmod(script.stat().st_mode | 0o111)
            evidence_dir = root / "evidence"

            original_validate = self.module.validate_shader_output
            self.module.validate_shader_output = lambda _path, target: {
                "status": "passed" if target == "spirv" else "failed",
                "tool": "test-spirv-val",
                "reason": "",
            }
            try:
                result = self.module.compile_tint_evidence_output(
                    {
                        "comparison": {
                            "binaryPath": str(script.relative_to(self.module.REPO_ROOT))
                            if script.is_relative_to(self.module.REPO_ROOT)
                            else str(script),
                        }
                    },
                    {
                        "name": "shader",
                        "path": str(shader_path),
                    },
                    "spirv",
                    {
                        "status": "compared",
                        "comparison": {
                            "warm": {"p50_ns": 200},
                        },
                    },
                    evidence_dir,
                    False,
                )
            finally:
                self.module.validate_shader_output = original_validate

        self.assertEqual(result["status"], "ok")
        self.assertEqual(result["validationTool"], "test-spirv-val")
        self.assertTrue(result["outputPath"].endswith("evidence/shader/tint/output.spv"))
        self.assertEqual(result["phaseTimingsNs"], {"total": 200})

    def test_compile_tint_evidence_output_splits_multi_entry_spirv_outputs(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            shader_path = root / "shader.wgsl"
            shader_path.write_text(
                "@vertex fn vs_main() -> @builtin(position) vec4f { return vec4f(); }\n"
                "@fragment fn fs_main() -> @location(0) vec4f { return vec4f(); }\n"
                "@workgroup_size(1) @compute fn cs_main() {}\n",
                encoding="utf-8",
            )
            script = root / "tint"
            script.write_text(
                "#!/usr/bin/env python3\n"
                "from pathlib import Path\n"
                "import sys\n"
                "argv = sys.argv[1:]\n"
                "entry = ''\n"
                "for item in argv:\n"
                "    if item.startswith('--entry-point='):\n"
                "        entry = item.split('=', 1)[1]\n"
                "if '--output-name' in argv:\n"
                "    output = Path(argv[argv.index('--output-name') + 1])\n"
                "    output.write_bytes(b'\\x03\\x02\\x23\\x07' + entry.encode())\n"
                "else:\n"
                "    sys.stdout.buffer.write(b'//\\n// vs_main\\n//\\nnot-raw-spirv')\n",
                encoding="utf-8",
            )
            script.chmod(script.stat().st_mode | 0o111)
            evidence_dir = root / "evidence"

            original_validate = self.module.validate_shader_output

            def validate(path: Path, target: str) -> dict[str, str]:
                if target == "spirv" and Path(path).read_bytes().startswith(b"\x03\x02\x23\x07"):
                    return {"status": "passed", "tool": "test-spirv-val", "reason": ""}
                return {
                    "status": "failed",
                    "tool": "test-spirv-val",
                    "reason": "invalid SPIR-V magic number",
                }

            self.module.validate_shader_output = validate
            try:
                result = self.module.compile_tint_evidence_output(
                    {
                        "comparison": {
                            "binaryPath": str(script),
                        }
                    },
                    {
                        "name": "shader",
                        "path": str(shader_path),
                    },
                    "spirv",
                    {
                        "status": "compared",
                        "comparison": {
                            "warm": {
                                "p50_ns": 200,
                                "phaseBenchmarkTimingsNs": {"parseWgsl": 11},
                            },
                        },
                    },
                    evidence_dir,
                    False,
                )
            finally:
                self.module.validate_shader_output = original_validate
            manifest = json.loads(Path(result["outputPath"]).read_text(encoding="utf-8"))

        self.assertEqual(result["status"], "ok")
        self.assertTrue(result["outputPath"].endswith("evidence/shader/tint/output.spv.manifest.json"))
        self.assertEqual(result["receiptPath"], result["outputPath"])
        self.assertEqual(result["validationStatus"], "passed")
        self.assertEqual(result["validationTool"], "spirv-val")
        self.assertEqual(result["phaseTimingsNs"], {"total": 200})
        self.assertEqual(result["phaseBenchmarkTimingsNs"], {"parseWgsl": 11})
        self.assertEqual(
            {artifact["entryPoint"] for artifact in result["outputArtifacts"]},
            {"vs_main", "fs_main", "cs_main"},
        )
        self.assertEqual(
            {artifact["shaderStage"] for artifact in result["outputArtifacts"]},
            {"vertex", "fragment", "compute"},
        )
        self.assertEqual(manifest["artifactKind"], "tint_spirv_entry_outputs")
        self.assertEqual(len(manifest["artifacts"]), 3)

    def test_compile_tint_evidence_output_preserves_validation_diagnostic(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            shader_path = root / "shader.wgsl"
            shader_path.write_text(
                "@compute @workgroup_size(1)\nfn main() {}\n",
                encoding="utf-8",
            )
            script = root / "tint"
            script.write_text(
                "#!/usr/bin/env python3\n"
                "import sys\n"
                "sys.stdout.buffer.write(b'not-spirv')\n",
                encoding="utf-8",
            )
            script.chmod(script.stat().st_mode | 0o111)
            evidence_dir = root / "evidence"

            original_validate = self.module.validate_shader_output
            self.module.validate_shader_output = lambda _path, target: {
                "status": "failed",
                "tool": "test-spirv-val",
                "reason": "invalid SPIR-V magic number",
            }
            try:
                result = self.module.compile_tint_evidence_output(
                    {
                        "comparison": {
                            "binaryPath": str(script),
                        }
                    },
                    {
                        "name": "shader",
                        "path": str(shader_path),
                    },
                    "spirv",
                    {
                        "status": "compared",
                        "comparison": {
                            "warm": {"p50_ns": 200},
                        },
                    },
                    evidence_dir,
                    False,
                )
            finally:
                self.module.validate_shader_output = original_validate

        self.assertEqual(result["status"], "failed")
        self.assertEqual(result["diagnosticCode"], "tint_spirv_validation_failed")
        self.assertEqual(result["validationStatus"], "failed")
        self.assertEqual(result["validationTool"], "test-spirv-val")
        self.assertEqual(result["diagnosticMessage"], "invalid SPIR-V magic number")
        self.assertEqual(result["validationMessage"], "invalid SPIR-V magic number")

    def test_build_evidence_report_hashes_string_shader_paths(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            shader_path = root / "shader.wgsl"
            shader_path.write_text(
                "@compute @workgroup_size(1)\nfn main() {}\n",
                encoding="utf-8",
            )
            expected_sha = self.module.file_sha256(shader_path)
            evidence_out = root / "tint-compiler-evidence.json"
            args = type(
                "Args",
                (),
                {
                    "evidence_out": str(evidence_out),
                    "doe_emit_binary": "missing/doe-runtime-compile-report",
                    "dry_run": True,
                },
            )()

            report = self.module.build_evidence_report(
                {
                    "run": {"outStem": "string-path-test"},
                    "comparison": {"binaryPath": "missing/tint"},
                },
                [
                    {
                        "name": "shader",
                        "workloadId": "shader",
                        "path": str(shader_path),
                    }
                ],
                "msl",
                [],
                None,
                args,
            )

        self.assertEqual(report["summary"]["rowCount"], 1)
        self.assertEqual(report["rows"][0]["sourceSha256"], expected_sha)
        self.assertEqual(report["comparisonStatus"], "diagnostic")

    def test_claim_report_explains_missing_warm_config(self) -> None:
        report = self.module.build_claim_report(
            cfg={
                "baseline": {"binaryPath": "missing/doe-compilation-bench"},
                "comparison": {"binaryPath": "missing/tint"},
                "run": {"iterations": 7},
            },
            shaders=[],
            target="msl",
            records=[
                {
                    "status": "compared",
                    "shader": "shader",
                    "baseline": {"p50_ns": 10, "iterations": 7},
                    "comparison": {
                        "p50_ns": 20,
                        "iterations": 7,
                        "warm": {},
                    },
                    "warmDeltaPercent": {"p50": None, "p95": None, "p99": None},
                }
            ],
            calibration=None,
            claim_mode="local",
        )

        self.assertIn(
            "no warm in-process Tint samples (config lacks warmBinaryPath)",
            report["workloads"][0]["reasons"],
        )

    def test_claim_report_carries_compare_report_reference(self) -> None:
        report = self.module.build_claim_report(
            cfg={
                "baseline": {"binaryPath": "missing/doe-compilation-bench"},
                "comparison": {"binaryPath": "missing/tint"},
                "run": {"iterations": 7},
                "_compareReport": {
                    "path": "bench/out/compilation/doe-vs-tint.msl.ndjson",
                    "sha256": "a" * 64,
                },
            },
            shaders=[],
            target="msl",
            records=[
                {
                    "status": "compared",
                    "shader": "shader",
                    "baseline": {"p50_ns": 10, "iterations": 7},
                    "comparison": {
                        "p50_ns": 20,
                        "iterations": 7,
                        "warm": {},
                    },
                    "warmDeltaPercent": {"p50": None, "p95": None, "p99": None},
                }
            ],
            calibration=None,
            claim_mode="local",
        )

        self.assertEqual(
            report["compareReport"],
            {
                "path": "bench/out/compilation/doe-vs-tint.msl.ndjson",
                "sha256": "a" * 64,
            },
        )

    def test_claim_report_explains_missing_matching_warm_samples(self) -> None:
        report = self.module.build_claim_report(
            cfg={
                "baseline": {"binaryPath": "missing/doe-compilation-bench"},
                "comparison": {
                    "binaryPath": "missing/tint",
                    "warmBinaryPath": "missing/tint_benchmark",
                },
                "run": {"iterations": 7},
            },
            shaders=[],
            target="msl",
            records=[
                {
                    "status": "compared",
                    "shader": "shader",
                    "baseline": {"p50_ns": 10, "iterations": 7},
                    "comparison": {
                        "p50_ns": 20,
                        "iterations": 7,
                        "warm": {},
                    },
                    "warmDeltaPercent": {"p50": None, "p95": None, "p99": None},
                }
            ],
            calibration=None,
            claim_mode="local",
        )

        self.assertIn(
            "no warm in-process Tint samples (no matching or successful tint_benchmark row)",
            report["workloads"][0]["reasons"],
        )


if __name__ == "__main__":
    unittest.main()
