from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

from bench.tools import materialize_tint_warm_corpus as warm_corpus


class TestMaterializeTintWarmCorpus(unittest.TestCase):
    def test_materializes_workload_shaders_and_patches_inputs(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            repo = root / "repo"
            dawn = repo / "bench" / "vendor" / "dawn"
            script = dawn / warm_corpus.BENCHMARK_INPUTS_SCRIPT
            shader = repo / "bench" / "kernels" / "alpha.wgsl"
            workloads = repo / "bench" / "workloads" / "workloads.apple.metal.json"
            script.parent.mkdir(parents=True)
            shader.parent.mkdir(parents=True)
            workloads.parent.mkdir(parents=True)
            script.write_text(
                "kBenchmarkFiles = [\n"
                "    \"test/tint/benchmark/existing.wgsl\",\n"
                "]\n\n\n"
                "def main():\n"
                "    pass\n",
                encoding="utf-8",
            )
            shader.write_text("@compute @workgroup_size(1)\nfn main() {}\n", encoding="utf-8")
            workloads.write_text(
                json.dumps(
                    {
                        "workloads": [
                            {
                                "id": "compilation_alpha_msl",
                                "runnerType": "compilation",
                                "shaderPath": "bench/kernels/alpha.wgsl",
                                "compilationTarget": "msl",
                            }
                        ]
                    }
                ),
                encoding="utf-8",
            )

            rows = warm_corpus.load_compilation_workloads(
                workloads,
                repo_root=repo,
                target="msl",
                workload_ids=[],
            )
            copied = warm_corpus.materialize_rows(rows, dawn_source_dir=dawn)
            merged = warm_corpus.patch_benchmark_inputs_script(
                script,
                [str(row["dawnBenchmarkPath"]) for row in copied],
            )

            copied_shader = dawn / "test" / "tint" / "benchmark" / "doe" / "compilation_alpha_msl.wgsl"
            self.assertTrue(copied_shader.is_file())
            self.assertEqual(copied_shader.read_text(encoding="utf-8"), shader.read_text(encoding="utf-8"))
            self.assertIn("test/tint/benchmark/existing.wgsl", merged)
            self.assertIn("test/tint/benchmark/doe/compilation_alpha_msl.wgsl", merged)

    def test_patch_is_idempotent(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            script = Path(tmpdir) / "generate_benchmark_inputs.py"
            script.write_text(
                "kBenchmarkFiles = [\n"
                "    \"test/tint/benchmark/doe/compilation_alpha_msl.wgsl\",\n"
                "]\n\n\n"
                "def main():\n"
                "    pass\n",
                encoding="utf-8",
            )

            first = warm_corpus.patch_benchmark_inputs_script(
                script,
                ["test/tint/benchmark/doe/compilation_alpha_msl.wgsl"],
            )
            second = warm_corpus.patch_benchmark_inputs_script(
                script,
                ["test/tint/benchmark/doe/compilation_alpha_msl.wgsl"],
            )

        self.assertEqual(first, second)
        self.assertEqual(first.count("test/tint/benchmark/doe/compilation_alpha_msl.wgsl"), 1)

    def test_materializes_wgsl_corpus_rows_and_records_source_manifest(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            repo = root / "repo"
            dawn = repo / "bench" / "vendor" / "dawn"
            build = dawn / "out" / "Release"
            script = dawn / warm_corpus.BENCHMARK_INPUTS_SCRIPT
            writer_bench = dawn / warm_corpus.MSL_WRITER_BENCH_SOURCE
            shader = repo / "bench" / "fixtures" / "wgsl-corpus" / "sample-prefix-sum.wgsl"
            manifest = repo / "config" / "wgsl-browser-corpus.json"
            state_path = repo / "bench" / "fixtures" / "browser_tint_warm_corpus_state.json"
            script.parent.mkdir(parents=True)
            writer_bench.parent.mkdir(parents=True)
            shader.parent.mkdir(parents=True)
            manifest.parent.mkdir(parents=True)
            state_path.parent.mkdir(parents=True, exist_ok=True)
            script.write_text(
                "kBenchmarkFiles = [\n"
                "]\n\n\n"
                "def main():\n"
                "    pass\n",
                encoding="utf-8",
            )
            writer_bench.write_text("writer benchmark source\n", encoding="utf-8")
            shader.write_text("@compute @workgroup_size(1)\nfn main() {}\n", encoding="utf-8")
            manifest.write_text(
                json.dumps(
                    {
                        "rows": [
                            {
                                "shaderId": "webgpu-prefix-sum",
                                "category": "webgpu_sample",
                                "sourcePath": "bench/fixtures/wgsl-corpus/sample-prefix-sum.wgsl",
                                "expectedValidity": "valid",
                                "expectedBackendTargets": ["msl", "spirv"],
                            }
                        ]
                    }
                ),
                encoding="utf-8",
            )

            rows = warm_corpus.load_wgsl_corpus_rows(
                manifest,
                repo_root=repo,
                target="spirv",
                workload_ids=["webgpu-prefix-sum"],
            )
            copied = warm_corpus.materialize_rows(rows, dawn_source_dir=dawn)
            merged = warm_corpus.patch_benchmark_inputs_script(
                script,
                [str(row["dawnBenchmarkPath"]) for row in copied],
            )
            warm_corpus.write_state(
                path=state_path,
                input_path=manifest,
                source_kind="wgsl_corpus",
                dawn_source_dir=dawn,
                build_dir=build,
                target="spirv",
                copied_rows=copied,
                built=False,
                repo_root=repo,
            )

            copied_shader = dawn / "test" / "tint" / "benchmark" / "doe" / "webgpu-prefix-sum.wgsl"
            state = json.loads(state_path.read_text(encoding="utf-8"))
            self.assertTrue(copied_shader.is_file())
            self.assertIn("test/tint/benchmark/doe/webgpu-prefix-sum.wgsl", merged)
            self.assertEqual(copied[0]["benchmarkName"], "webgpu-prefix-sum.wgsl")
            self.assertEqual(copied[0]["sourceKind"], "wgsl_corpus")
            self.assertEqual(copied[0]["corpusCategory"], "webgpu_sample")
            self.assertEqual(state["sourceKind"], "wgsl_corpus")
            self.assertEqual(state["wgslCorpusManifestPath"], "config/wgsl-browser-corpus.json")
            self.assertNotIn("workloadsPath", state)

    def test_wgsl_corpus_rows_require_requested_shader_id(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            repo = Path(tmpdir) / "repo"
            shader = repo / "bench" / "fixtures" / "wgsl-corpus" / "sample-prefix-sum.wgsl"
            manifest = repo / "config" / "wgsl-browser-corpus.json"
            shader.parent.mkdir(parents=True)
            manifest.parent.mkdir(parents=True)
            shader.write_text("@compute @workgroup_size(1)\nfn main() {}\n", encoding="utf-8")
            manifest.write_text(
                json.dumps(
                    {
                        "rows": [
                            {
                                "shaderId": "webgpu-prefix-sum",
                                "sourcePath": "bench/fixtures/wgsl-corpus/sample-prefix-sum.wgsl",
                                "expectedValidity": "valid",
                                "expectedBackendTargets": ["spirv"],
                            }
                        ]
                    }
                ),
                encoding="utf-8",
            )

            with self.assertRaisesRegex(RuntimeError, "WGSL corpus ids not found: missing-row"):
                warm_corpus.load_wgsl_corpus_rows(
                    manifest,
                    repo_root=repo,
                    target="spirv",
                    workload_ids=["missing-row"],
                )

    def test_copy_shader_normalizes_non_ascii_comments_for_dawn_header(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            source = Path(tmpdir) / "source.wgsl"
            dest = Path(tmpdir) / "dest.wgsl"
            source.write_text("// copy path \u2014 comment\n@compute @workgroup_size(1)\nfn main() {}\n", encoding="utf-8")

            normalized = warm_corpus.copy_shader_for_tint_benchmark(source, dest)

            self.assertTrue(normalized)
            self.assertEqual(
                dest.read_text(encoding="ascii"),
                "// copy path ? comment\n@compute @workgroup_size(1)\nfn main() {}\n",
            )

    def test_patch_msl_writer_bench_widens_bindpoint_setup(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            source = Path(tmpdir) / "writer_bench.cc"
            source.write_text(
                "void GenerateMSL() {\n"
                "    tint::msl::writer::Options gen_options = {};\n"
                "    gen_options.array_length_from_constants.ubo_binding = 30;\n"
                "    gen_options.array_length_from_constants.bindpoint_to_size_index.emplace(\n"
                "        tint::BindingPoint{0, 0}, 0);\n"
                "\n"
                "    for (auto _ : state) {\n"
                "    }\n"
                "}\n",
                encoding="utf-8",
            )

            patched = warm_corpus.patch_msl_writer_bench(source)
            second = warm_corpus.patch_msl_writer_bench(source)
            text = source.read_text(encoding="utf-8")

        self.assertTrue(patched)
        self.assertFalse(second)
        self.assertIn(warm_corpus.DOE_ARRAY_LENGTH_PATCH_MARKER, text)
        self.assertIn("group < 4u", text)
        self.assertIn("binding < 64u", text)


if __name__ == "__main__":
    unittest.main()
