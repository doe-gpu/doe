from __future__ import annotations

import importlib.util
import json
import subprocess
import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest import mock


REPO_ROOT = Path(__file__).resolve().parents[2]
RUNNER_DIR = REPO_ROOT / "bench" / "runners" / "csl-runners"
if str(RUNNER_DIR) not in sys.path:
    sys.path.insert(0, str(RUNNER_DIR))

spec = importlib.util.spec_from_file_location(
    "int4ple_compile_target_sim_runner",
    RUNNER_DIR / "int4ple_compile_target_sim_runner.py",
)
assert spec is not None
assert spec.loader is not None
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class PrefillGemvTileResumeTest(unittest.TestCase):
    def test_tile_output_status_accepts_loadable_f16_tile(self) -> None:
        import numpy as np

        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "output.npy"
            np.save(path, np.arange(4, dtype=np.float16))

            ready, status = runner._prefill_gemv_tile_output_status(
                path,
                expected_elements=4,
            )

        self.assertTrue(ready)
        self.assertEqual(status, "ready")

    def test_tile_output_status_rejects_partial_or_wrong_dtype_tile(self) -> None:
        import numpy as np

        with tempfile.TemporaryDirectory() as tmp:
            short_path = Path(tmp) / "short.npy"
            dtype_path = Path(tmp) / "dtype.npy"
            corrupt_path = Path(tmp) / "corrupt.npy"
            np.save(short_path, np.arange(2, dtype=np.float16))
            np.save(dtype_path, np.arange(4, dtype=np.float32))
            corrupt_path.write_bytes(b"not-npy")

            short_ready, short_status = runner._prefill_gemv_tile_output_status(
                short_path,
                expected_elements=4,
            )
            dtype_ready, dtype_status = runner._prefill_gemv_tile_output_status(
                dtype_path,
                expected_elements=4,
            )
            corrupt_ready, corrupt_status = runner._prefill_gemv_tile_output_status(
                corrupt_path,
                expected_elements=4,
            )

        self.assertFalse(short_ready)
        self.assertEqual(short_status, "size:2!=4")
        self.assertFalse(dtype_ready)
        self.assertEqual(dtype_status, "dtype:float32")
        self.assertFalse(corrupt_ready)
        self.assertTrue(corrupt_status.startswith("unreadable:"))

    def test_task_shards_are_bounded_by_jobs_and_task_count(self) -> None:
        tasks = [{"index": index} for index in range(7)]

        shards = runner._prefill_gemv_task_shards(
            tasks,
            jobs=3,
            adapter_step_budget=3,
        )

        self.assertEqual([len(shard) for shard in shards], [3, 3, 1])
        self.assertEqual(
            [item["index"] for shard in shards for item in shard],
            list(range(7)),
        )

    def test_prefill_gemv_wide_source_uses_smaller_input_tile(self) -> None:
        self.assertEqual(runner._prefill_gemv_in_dim_per_pe(5376), 512)
        self.assertEqual(runner._prefill_gemv_in_dim_per_pe(8192), 256)

    def test_prefill_gemv_splits_multirow_or_large_d2h_regions(self) -> None:
        self.assertFalse(
            runner._prefill_gemv_split_d2h_rows(
                output_tile_cols=112,
                output_region_height=1,
            )
        )
        self.assertTrue(
            runner._prefill_gemv_split_d2h_rows(
                output_tile_cols=4 * 112,
                output_region_height=4,
            )
        )
        self.assertFalse(
            runner._prefill_gemv_split_d2h_rows(
                output_tile_cols=runner.SDK_D2H_ELEMENT_COUNT_LIMIT - 1,
                output_region_height=1,
            )
        )
        self.assertTrue(
            runner._prefill_gemv_split_d2h_rows(
                output_tile_cols=runner.SDK_D2H_ELEMENT_COUNT_LIMIT,
                output_region_height=1,
            )
        )

    def test_prefill_gemv_rejects_tall_output_tiles(self) -> None:
        self.assertEqual(runner._prefill_gemv_output_pe_rows(0), 1)
        self.assertEqual(
            runner._prefill_gemv_output_pe_rows(
                runner.PREFILL_GEMV_MAX_OUTPUT_PE_ROWS
            ),
            runner.PREFILL_GEMV_MAX_OUTPUT_PE_ROWS,
        )
        with self.assertRaisesRegex(
            ValueError,
            "prefill_q4k_gemv_output_pe_rows_unsupported",
        ):
            runner._prefill_gemv_output_pe_rows(
                runner.PREFILL_GEMV_MAX_OUTPUT_PE_ROWS + 1
            )

    def test_rope_input_transform_pads_logical_matrix_heads(self) -> None:
        import numpy as np

        logical = np.arange(4 * 8192, dtype=np.float16)
        materialization = {
            "dtype": "f16",
            "sourceTransform": {
                "kind": "logical_matrix_to_rope_pe_heads",
                "sourceCols": 8192,
                "headDim": 256,
                "targetRows": 481,
            },
        }

        values, matrix_shape = runner._transform_existing_input(
            logical,
            materialization,
        )

        expected_heads = logical.reshape(4, 32, 256).reshape(128, 256)
        self.assertEqual(values.dtype, np.dtype(np.float16))
        self.assertEqual(values.size, 481 * 256)
        self.assertEqual(matrix_shape, {"rows": 4, "cols": 8192})
        np.testing.assert_array_equal(values.reshape(481, 256)[:128], expected_heads)
        np.testing.assert_array_equal(
            values.reshape(481, 256)[128:],
            np.zeros((481 - 128, 256), dtype=np.float16),
        )

    def test_attention_input_transform_pads_logical_matrix_heads(self) -> None:
        import numpy as np

        logical = np.arange(4 * 8192, dtype=np.float16)
        materialization = {
            "dtype": "f16",
            "sourceTransform": {
                "kind": "logical_matrix_to_attention_query_rows",
                "sourceCols": 8192,
                "headDim": 256,
                "targetRows": 481,
                "rowsPerPe": 9,
            },
        }

        values, matrix_shape = runner._transform_existing_input(
            logical,
            materialization,
        )

        expected_heads = logical.reshape(4, 32, 256).reshape(128, 256)
        self.assertEqual(values.dtype, np.dtype(np.float16))
        self.assertEqual(values.size, 481 * 9 * 256)
        self.assertEqual(matrix_shape, {"rows": 4, "cols": 8192})
        np.testing.assert_array_equal(
            values.reshape(481 * 9, 256)[:128],
            expected_heads,
        )
        np.testing.assert_array_equal(
            values.reshape(481 * 9, 256)[128:],
            np.zeros((481 * 9 - 128, 256), dtype=np.float16),
        )

    def test_compact_attention_input_transform_uses_required_pe_rows(self) -> None:
        import numpy as np

        logical = np.arange(4 * 8192, dtype=np.float16)
        binding = {
            "buffer": "activation:attention:query",
            "materialization": {
                "dtype": "f16",
                "elemType": "f16",
                "elementsPerPe": 9 * 256,
                "sourceTransform": {
                    "kind": "logical_matrix_to_attention_query_rows",
                    "sourceCols": 8192,
                    "headDim": 256,
                    "targetRows": 481,
                    "rowsPerPe": 9,
                },
            },
        }

        with tempfile.TemporaryDirectory() as tmpdir:
            path = Path(tmpdir) / "query.npy"
            np.save(path, logical)
            values, matrix_shape, materialization = (
                runner._load_compact_attention_input(
                    buffer_files={"activation:attention:query": path},
                    binding=binding,
                    compact_width=128,
                    launch_index=7,
                    rows_per_pe=1,
                )
            )

        expected_heads = logical.reshape(4, 32, 256).reshape(128, 256)
        self.assertEqual(values.size, 128 * 256)
        self.assertEqual(matrix_shape, {"rows": 4, "cols": 8192})
        self.assertEqual(
            materialization["sourceTransform"]["targetRows"],
            128,
        )
        self.assertEqual(
            materialization["sourceTransform"]["rowsPerPe"],
            1,
        )
        np.testing.assert_array_equal(
            values.reshape(128, 256),
            expected_heads,
        )


def _load_launch_step_adapter_module():
    name = "int4ple_launch_step_adapter_for_tests"
    if name in sys.modules:
        return sys.modules[name]
    fake = types.ModuleType("sdkruntimepybind")

    class _MemcpyDataType:
        MEMCPY_32BIT = "MEMCPY_32BIT"
        MEMCPY_16BIT = "MEMCPY_16BIT"

    class _MemcpyOrder:
        ROW_MAJOR = "ROW_MAJOR"

    class _SdkRuntime:
        pass

    fake.MemcpyDataType = _MemcpyDataType
    fake.MemcpyOrder = _MemcpyOrder
    fake.SdkRuntime = _SdkRuntime
    sys.modules.setdefault("cerebras", types.ModuleType("cerebras"))
    sys.modules.setdefault("cerebras.sdk", types.ModuleType("cerebras.sdk"))
    sys.modules.setdefault(
        "cerebras.sdk.runtime",
        types.ModuleType("cerebras.sdk.runtime"),
    )
    sys.modules["cerebras.sdk.runtime.sdkruntimepybind"] = fake
    adapter_spec = importlib.util.spec_from_file_location(
        name,
        RUNNER_DIR / "int4ple_launch_step_adapter.py",
    )
    assert adapter_spec is not None
    assert adapter_spec.loader is not None
    mod = importlib.util.module_from_spec(adapter_spec)
    sys.modules[name] = mod
    adapter_spec.loader.exec_module(mod)
    return mod


class RopeOutputTransformTest(unittest.TestCase):
    def test_chunked_f16_output_requires_resolved_symbol_id(self) -> None:
        adapter = _load_launch_step_adapter_module()

        class MissingChunkRunner:
            def get_id(self, symbol: str) -> object:
                del symbol
                return None

        class PresentChunkRunner:
            def get_id(self, symbol: str) -> object:
                del symbol
                return 7

        self.assertFalse(
            adapter._chunked_f16_output_available(MissingChunkRunner(), "input")
        )
        self.assertTrue(
            adapter._chunked_f16_output_available(PresentChunkRunner(), "input")
        )

    def test_rope_output_transform_restores_logical_matrix(self) -> None:
        import numpy as np

        adapter = _load_launch_step_adapter_module()
        logical = np.arange(4 * 8192, dtype=np.float32)
        host = np.zeros(481 * 256, dtype=np.float32)
        host.reshape(481, 256)[:128] = logical.reshape(4, 32, 256).reshape(
            128,
            256,
        )

        restored = adapter._rope_pe_heads_to_logical_matrix(
            host,
            {
                "rows": 4,
                "cols": 8192,
                "headDim": 256,
                "targetRows": 481,
            },
        )

        np.testing.assert_array_equal(restored, logical)

    def test_attention_output_transform_restores_logical_matrix(self) -> None:
        import numpy as np

        adapter = _load_launch_step_adapter_module()
        logical = np.arange(4 * 8192, dtype=np.float32)
        host = np.zeros(15 * 9 * 256, dtype=np.float32)
        host.reshape(15 * 9, 256)[:128] = logical.reshape(4, 32, 256).reshape(
            128,
            256,
        )

        restored = adapter._attention_query_rows_to_logical_matrix(
            host,
            {
                "rows": 4,
                "cols": 8192,
                "headDim": 256,
                "targetRows": 481,
                "rowsPerPe": 9,
            },
        )

        np.testing.assert_array_equal(restored, logical)

    def test_attention_output_transform_accepts_full_surface_copyback(self) -> None:
        import numpy as np

        adapter = _load_launch_step_adapter_module()
        logical = np.arange(4 * 8192, dtype=np.float32)
        host = np.zeros(481 * 9 * 256, dtype=np.float32)
        host.reshape(481 * 9, 256)[:128] = logical.reshape(4, 32, 256).reshape(
            128,
            256,
        )

        restored = adapter._attention_query_rows_to_logical_matrix(
            host,
            {
                "rows": 4,
                "cols": 8192,
                "headDim": 256,
                "targetRows": 481,
                "rowsPerPe": 9,
            },
        )

        np.testing.assert_array_equal(restored, logical)


def _load_embed_roi_adapter_module():
    name = "int4ple_embed_roi_adapter_for_tests"
    if name in sys.modules:
        return sys.modules[name]
    fake = types.ModuleType("sdkruntimepybind")

    class _MemcpyDataType:
        MEMCPY_32BIT = "MEMCPY_32BIT"

    class _MemcpyOrder:
        ROW_MAJOR = "ROW_MAJOR"

    class _SdkRuntime:
        pass

    fake.MemcpyDataType = _MemcpyDataType
    fake.MemcpyOrder = _MemcpyOrder
    fake.SdkRuntime = _SdkRuntime
    sys.modules.setdefault("cerebras", types.ModuleType("cerebras"))
    sys.modules.setdefault("cerebras.sdk", types.ModuleType("cerebras.sdk"))
    sys.modules.setdefault(
        "cerebras.sdk.runtime",
        types.ModuleType("cerebras.sdk.runtime"),
    )
    sys.modules["cerebras.sdk.runtime.sdkruntimepybind"] = fake
    adapter_spec = importlib.util.spec_from_file_location(
        name,
        RUNNER_DIR / "int4ple_embed_roi_adapter.py",
    )
    assert adapter_spec is not None
    assert adapter_spec.loader is not None
    mod = importlib.util.module_from_spec(adapter_spec)
    sys.modules[name] = mod
    adapter_spec.loader.exec_module(mod)
    return mod


class EmbedRoiPartialCheckpointTest(unittest.TestCase):
    def test_embed_roi_launch_timeout_writes_typed_receipt(self) -> None:
        launch = {
            "launchIndex": 7,
            "function": "compute",
            "resolvedOutputs": [
                {"symbol": "output", "buffer": "activation:embed"}
            ],
        }

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            compile_dir = root / "compile"
            compile_dir.mkdir()
            progress_path = root / "progress.jsonl"

            with (
                mock.patch.object(
                    runner,
                    "build_embed_roi_spec",
                    return_value=(
                        {
                            "prompt": {"tokenCount": 1},
                            "sublaunches": [{}],
                        },
                        "roi-digest-before-compile-dir",
                    ),
                ),
                mock.patch.object(
                    runner,
                    "_compile_embed_roi_target",
                    return_value=compile_dir,
                ),
                mock.patch.object(
                    runner,
                    "_tokenized_prompt_path",
                    return_value=root / "prompt.u32",
                ),
                mock.patch.object(
                    runner,
                    "cs_python_executable",
                    return_value="/usr/bin/python3",
                ),
                mock.patch.object(
                    runner.subprocess,
                    "run",
                    side_effect=subprocess.TimeoutExpired(
                        cmd=["adapter"],
                        timeout=3,
                        output="phase:run\n",
                        stderr="stalled\n",
                    ),
                ),
            ):
                with self.assertRaisesRegex(
                    ValueError,
                    "embed_roi_launch_timeout",
                ):
                    runner._execute_embed_roi_launch(
                        runtime_dir=root,
                        launch=launch,
                        buffer_files={},
                        export={},
                        progress_path=progress_path,
                        cmaddr=None,
                        timeout_seconds=3,
                    )

            receipt_path = root / "launch-receipts" / "launch-0007.json"
            receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
            self.assertEqual(receipt["status"], "blocked")
            self.assertEqual(receipt["blockers"], ["embed_roi_launch_timeout"])
            self.assertEqual(receipt["timeoutSeconds"], 3)
            self.assertEqual(receipt["stdoutTail"], ["phase:run"])
            self.assertEqual(receipt["stderrTail"], ["stalled"])
            self.assertIn(
                "embed_roi_launch_timeout",
                progress_path.read_text(encoding="utf-8"),
            )

    def test_partial_checkpoint_round_trips_by_spec_hash(self) -> None:
        adapter = _load_embed_roi_adapter_module()
        import numpy as np

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            array_path = root / "activation.npy.partial.npy"
            state_path = root / "activation.npy.partial.json"
            compact = np.arange(12, dtype=np.float32).reshape(3, 4)
            completed = [{"sublaunchIndex": 0}, {"sublaunchIndex": 1}]

            adapter.write_embed_roi_partial(
                partial_array_path=array_path,
                partial_state_path=state_path,
                compact=compact,
                spec_sha256="abc123",
                token_count=3,
                hidden_size=4,
                completed_sublaunches=completed,
            )
            loaded, loaded_completed = adapter.load_embed_roi_partial(
                partial_array_path=array_path,
                partial_state_path=state_path,
                spec_sha256="abc123",
                token_count=3,
                hidden_size=4,
            )

        self.assertEqual(loaded_completed, completed)
        self.assertEqual(loaded.dtype, np.float32)
        self.assertEqual(loaded.tolist(), compact.tolist())

    def test_partial_checkpoint_rejects_identity_mismatch(self) -> None:
        adapter = _load_embed_roi_adapter_module()
        import numpy as np

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            array_path = root / "activation.npy.partial.npy"
            state_path = root / "activation.npy.partial.json"
            adapter.write_embed_roi_partial(
                partial_array_path=array_path,
                partial_state_path=state_path,
                compact=np.zeros((1, 2), dtype=np.float32),
                spec_sha256="abc123",
                token_count=1,
                hidden_size=2,
                completed_sublaunches=[],
            )
            with self.assertRaisesRegex(
                ValueError,
                "embed_roi_partial_identity_mismatch",
            ):
                adapter.load_embed_roi_partial(
                    partial_array_path=array_path,
                    partial_state_path=state_path,
                    spec_sha256="def456",
                    token_count=1,
                    hidden_size=2,
                )


class LaunchStepAdapterMemcpyPackingTest(unittest.TestCase):
    def test_f16_h2d_uses_writeable_mmap_payload_when_layout_matches(self) -> None:
        adapter = _load_launch_step_adapter_module()
        import numpy as np

        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "x.npy"
            source = np.lib.format.open_memmap(
                path,
                mode="w+",
                dtype=np.float16,
                shape=(4,),
            )
            source[:] = [1.0, 2.0, 3.0, 4.0]
            source.flush()
            del source
            payload, memcpy_dtype, memcpy_elements_per_pe = (
                adapter._memcpy_payload_for_h2d(
                    path=path,
                    dtype="f16",
                    elements_per_pe=2,
                    total_elements=4,
                )
            )
        self.assertIsInstance(payload, np.memmap)
        self.assertEqual(payload.dtype, np.uint32)
        self.assertTrue(payload.flags.writeable)
        self.assertEqual(
            memcpy_dtype,
            adapter.MemcpyDataType.MEMCPY_32BIT,
        )
        self.assertEqual(memcpy_elements_per_pe, 1)
        self.assertEqual(payload.view(np.float16).tolist(), [1.0, 2.0, 3.0, 4.0])

    def test_f16_h2d_copies_read_only_payload(self) -> None:
        adapter = _load_launch_step_adapter_module()
        import numpy as np

        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "x.npy"
            np.save(path, np.array([1.0, 2.0, 3.0, 4.0], dtype=np.float16))
            with mock.patch.object(
                adapter,
                "_load_writeable_mmap_or_copy",
                return_value=np.load(path, mmap_mode="r").ravel(),
            ):
                payload, memcpy_dtype, memcpy_elements_per_pe = (
                    adapter._memcpy_payload_for_h2d(
                        path=path,
                        dtype="f16",
                        elements_per_pe=2,
                        total_elements=4,
                    )
                )
        self.assertEqual(payload.dtype, np.uint32)
        self.assertTrue(payload.flags.writeable)
        self.assertEqual(
            memcpy_dtype,
            adapter.MemcpyDataType.MEMCPY_32BIT,
        )
        self.assertEqual(memcpy_elements_per_pe, 1)
        self.assertEqual(payload.view(np.float16).tolist(), [1.0, 2.0, 3.0, 4.0])

    def test_dense_gemv_transform_accepts_sink_column_copyback(self) -> None:
        adapter = _load_launch_step_adapter_module()
        import numpy as np

        transform = {
            "kind": "dense_gemv_row_shards_to_logits",
            "width": 4,
            "height": 3,
            "outDim": 20,
            "outDimPerPe": 8,
        }
        compact = np.arange(24, dtype=np.float32)
        logits = adapter._dense_gemv_row_shards_to_logits(compact, transform)
        self.assertEqual(logits.tolist(), list(np.arange(20, dtype=np.float32)))

    def test_dense_gemv_output_uses_sink_column_region(self) -> None:
        adapter = _load_launch_step_adapter_module()

        region = adapter._d2h_region_for_output(
            output_transform={
                "kind": "dense_gemv_row_shards_to_logits",
                "width": 4,
                "height": 3,
                "outDim": 20,
                "outDimPerPe": 8,
            },
            width=4,
            height=3,
        )

        self.assertEqual(region, {
            "x": 3,
            "y": 0,
            "width": 1,
            "height": 3,
        })

    def test_summa_output_uses_compact_logical_region(self) -> None:
        adapter = _load_launch_step_adapter_module()

        region = adapter._d2h_region_for_output(
            output_transform={
                "kind": "summa_tiles_to_logical_matrix",
                "rows": 19,
                "cols": 4,
                "gridHeight": 16,
                "gridWidth": 16,
                "tileRows": 16,
                "tileCols": 16,
            },
            width=16,
            height=16,
        )

        self.assertEqual(region, {
            "x": 0,
            "y": 0,
            "width": 1,
            "height": 2,
        })

    def test_summa_output_splits_multi_row_copyback(self) -> None:
        adapter = _load_launch_step_adapter_module()

        regions = adapter._d2h_regions_for_output(
            output_transform={
                "kind": "summa_tiles_to_logical_matrix",
                "rows": 19,
                "cols": 4,
                "gridHeight": 16,
                "gridWidth": 16,
                "tileRows": 16,
                "tileCols": 16,
            },
            width=16,
            height=16,
        )

        self.assertEqual(regions, [
            {
                "x": 0,
                "y": 0,
                "width": 1,
                "height": 1,
            },
            {
                "x": 0,
                "y": 1,
                "width": 1,
                "height": 1,
            },
        ])

    def test_pe_rows_output_splits_multi_pe_copyback(self) -> None:
        adapter = _load_launch_step_adapter_module()

        regions = adapter._d2h_regions_for_output(
            output_transform={
                "kind": "pe_rows_to_logical_matrix",
                "rows": 4,
                "cols": 5376,
            },
            width=481,
            height=1,
        )

        self.assertEqual(regions, [
            {"x": 0, "y": 0, "width": 1, "height": 1},
            {"x": 1, "y": 0, "width": 1, "height": 1},
            {"x": 2, "y": 0, "width": 1, "height": 1},
            {"x": 3, "y": 0, "width": 1, "height": 1},
        ])

    def test_attention_output_splits_wide_copyback(self) -> None:
        adapter = _load_launch_step_adapter_module()

        regions = adapter._d2h_regions_for_output(
            output_transform={
                "kind": "attention_query_rows_to_logical_matrix",
                "rows": 4,
                "cols": 8192,
                "headDim": 256,
                "targetRows": 481,
                "rowsPerPe": 9,
            },
            width=481,
            height=1,
        )

        self.assertEqual(len(regions), 15)
        self.assertEqual(regions[0], {"x": 0, "y": 0, "width": 1, "height": 1})
        self.assertEqual(regions[-1], {"x": 14, "y": 0, "width": 1, "height": 1})

    def test_attention_output_keeps_compact_row_copyback_together(self) -> None:
        adapter = _load_launch_step_adapter_module()

        regions = adapter._d2h_regions_for_output(
            output_transform={
                "kind": "attention_query_rows_to_logical_matrix",
                "rows": 4,
                "cols": 8192,
                "headDim": 256,
                "targetRows": 128,
                "rowsPerPe": 1,
            },
            width=128,
            height=1,
        )

        self.assertEqual(regions, [
            {
                "x": 0,
                "y": 0,
                "width": 128,
                "height": 1,
            },
        ])

    def test_summa_transform_accepts_compact_region_copyback(self) -> None:
        adapter = _load_launch_step_adapter_module()
        import numpy as np

        transform = {
            "kind": "summa_tiles_to_logical_matrix",
            "rows": 19,
            "cols": 4,
            "paddedRows": 256,
            "paddedCols": 256,
            "gridHeight": 16,
            "gridWidth": 16,
            "tileRows": 16,
            "tileCols": 16,
        }
        region = {
            "x": 0,
            "y": 0,
            "width": 1,
            "height": 2,
        }
        host = np.arange(2 * 1 * 16 * 16, dtype=np.float32)
        logical = adapter._summa_c_tiles_to_logical(
            host,
            transform,
            region=region,
        )

        expected = host.reshape(2, 1, 16, 16).transpose(0, 3, 1, 2).reshape(32, 16)
        self.assertEqual(logical.tolist(), expected[:19, :4].reshape(-1).tolist())


class HostPlanRuntimeTimeout(unittest.TestCase):
    def test_compact_ple_proj_mode_only_intercepts_ple_proj(self) -> None:
        self.assertTrue(
            runner._is_compact_ple_proj_launch(
                {"targetName": "ple_proj"},
                "compact_summa_session",
            )
        )
        self.assertFalse(
            runner._is_compact_ple_proj_launch(
                {"targetName": "ple_proj"},
                "monolithic_summa",
            )
        )
        self.assertFalse(
            runner._is_compact_ple_proj_launch(
                {"targetName": "tiled"},
                "compact_summa_session",
            )
        )

    def test_compact_ple_proj_transforms_match_compiled_shape(self) -> None:
        a_transform = runner._compact_ple_proj_source_transform(
            matrix_role="a",
            source_cols=256,
        )
        b_transform = runner._compact_ple_proj_source_transform(
            matrix_role="b",
            source_cols=256,
            source_rows=4,
        )
        output_transform = runner._compact_ple_proj_output_transform(
            rows=19,
            cols=4,
        )

        self.assertEqual(a_transform["gridWidth"], 2)
        self.assertEqual(a_transform["gridHeight"], 2)
        self.assertEqual(a_transform["tileRows"], 16)
        self.assertEqual(a_transform["tileReduction"], 128)
        self.assertEqual(b_transform["paddedCols"], 32)
        self.assertEqual(b_transform["tileCols"], 16)
        self.assertEqual(output_transform["paddedRows"], 32)
        self.assertEqual(output_transform["paddedCols"], 32)

    def test_session_lm_head_tiled_mode_intercepts_launch(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            tmp = Path(tmpdir)
            progress_path = tmp / "progress.jsonl"
            trace_path = tmp / "trace.json"
            output_path = tmp / "hostplan-runtime" / "buffers" / "logits.npy"
            bootstrap = {
                "launches": [
                    {
                        "launchIndex": 4,
                        "targetName": "lm_head_prefill",
                        "launchFunction": "compute",
                        "compileDir": str(tmp / "compile" / "compiled" / "lm_head_prefill"),
                        "compileParams": {
                            "width": 160,
                            "height": 512,
                            "out_dim": 262144,
                            "out_dim_per_pe": 512,
                            "in_dim_per_pe": 32,
                        },
                        "targetGeometry": {"width": 160, "height": 512},
                    }
                ],
                "targetSessions": [],
            }

            def fake_stage_launch_arrays(**_kwargs: object) -> tuple[list[dict], list[dict]]:
                return [
                    {
                        "symbol": "activation",
                        "buffer": "activation:prefill:0003:global:final_norm",
                        "path": str(tmp / "activation.npy"),
                        "dtype": "f16",
                        "elemType": "f16",
                        "elementsPerPe": 32,
                    },
                    {
                        "symbol": "weight",
                        "buffer": "weight:lm_head",
                        "path": str(tmp / "weight.npy"),
                        "dtype": "f16",
                        "elemType": "f16",
                        "elementsPerPe": 16384,
                    },
                ], [
                    {
                        "symbol": "output",
                        "buffer": "activation:prefill:0004:global:lm_head",
                        "path": str(output_path),
                        "dtype": "f32",
                        "elemType": "f32",
                        "elementsPerPe": 512,
                    }
                ]

            def fake_session_tiled_launch(**_kwargs: object) -> dict:
                output_path.parent.mkdir(parents=True, exist_ok=True)
                output_path.write_bytes(b"NUMPY")
                return {
                    "schemaVersion": 1,
                    "artifactKind": "int4ple_launch_step_receipt",
                    "status": "succeeded",
                    "blockers": [],
                    "launchIndex": 4,
                    "targetName": "lm_head_prefill",
                    "dispatchMode": "dense_gemv_width_tiled_session",
                    "outputs": [
                        {
                            "symbol": "output",
                            "buffer": "activation:prefill:0004:global:lm_head",
                            "path": str(output_path),
                        }
                    ],
                }

            with (
                mock.patch.object(
                    runner,
                    "_stage_launch_arrays",
                    side_effect=fake_stage_launch_arrays,
                ),
                mock.patch.object(
                    runner,
                    "_execute_dense_gemv_tiled_session_launch",
                    side_effect=fake_session_tiled_launch,
                ) as tiled_mock,
                mock.patch.object(runner.subprocess, "run") as run_mock,
            ):
                result = runner.execute_hostplan_runtime(
                    bootstrap=bootstrap,
                    export={},
                    progress_path=progress_path,
                    cmaddr=None,
                    trace_path=trace_path,
                    session_lm_head_dispatch_mode="dense_gemv_width_tiled_session",
                )

            self.assertEqual(result["status"], "succeeded")
            self.assertEqual(result["executedLaunchCount"], 1)
            self.assertEqual(
                result["launches"][0]["dispatchMode"],
                "dense_gemv_width_tiled_session",
            )
            self.assertEqual(
                result["sessionLmHeadDispatch"]["mode"],
                "dense_gemv_width_tiled_session",
            )
            receipt_path = (
                trace_path.parent
                / "hostplan-runtime"
                / "launch-receipts"
                / "launch-0004.json"
            )
            receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
            self.assertEqual(
                receipt["dispatchMode"],
                "dense_gemv_width_tiled_session",
            )
            self.assertEqual(tiled_mock.call_count, 1)
            run_mock.assert_not_called()

    def test_independent_embed_roi_launches_can_run_as_parallel_group(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            tmp = Path(tmpdir)
            progress_path = tmp / "progress.jsonl"
            trace_path = tmp / "trace.json"
            checkpoint_dir = tmp / "checkpoints"
            runner._init_checkpoint(checkpoint_dir, {"test": "identity"})

            def launch(idx: int) -> dict:
                return {
                    "launchIndex": idx,
                    "targetName": "ple_embed",
                    "compileParams": {
                        "rows_per_pe": 1,
                        "hidden_size": 2,
                        "hidden_per_pe": 1,
                        "tokens_per_chunk": 1,
                    },
                    "inputBindings": [
                        {
                            "role": "tokenized_prompt",
                            "buffer": "input:prompt_token_ids",
                        },
                        {
                            "role": "weight",
                            "buffer": f"weight:layer{idx}",
                        },
                    ],
                    "resolvedOutputs": [
                        {
                            "symbol": "output",
                            "buffer": f"activation:prefill:{idx:04d}:layer{idx}",
                        }
                    ],
                }

            bootstrap = {"launches": [launch(0), launch(1)], "targetSessions": []}

            def fake_embed_roi_launch(**kwargs: object) -> dict:
                launch_spec = kwargs["launch"]
                runtime_dir = Path(str(kwargs["runtime_dir"]))
                buffer_files = kwargs["buffer_files"]
                idx = int(launch_spec["launchIndex"])
                output_buffer = launch_spec["resolvedOutputs"][0]["buffer"]
                output_path = runtime_dir / "buffers" / f"out-{idx}.bin"
                output_path.parent.mkdir(parents=True, exist_ok=True)
                output_path.write_bytes(f"out-{idx}".encode("utf-8"))
                buffer_files[output_buffer] = output_path
                return {
                    "schemaVersion": 1,
                    "artifactKind": "int4ple_embed_roi_launch_receipt",
                    "status": "succeeded",
                    "blockers": [],
                    "launchIndex": idx,
                    "targetName": "ple_embed",
                    "output": {
                        "buffer": output_buffer,
                        "path": str(output_path),
                        "dtype": "f32",
                        "shape": [1, 2],
                    },
                }

            with mock.patch.object(
                runner,
                "_execute_embed_roi_launch",
                side_effect=fake_embed_roi_launch,
            ) as embed_mock:
                result = runner.execute_hostplan_runtime(
                    bootstrap=bootstrap,
                    export={},
                    progress_path=progress_path,
                    cmaddr=None,
                    trace_path=trace_path,
                    checkpoint_dir=checkpoint_dir,
                    session_embed_roi_jobs=2,
                )

            self.assertEqual(result["status"], "succeeded")
            self.assertEqual(result["executedLaunchCount"], 2)
            self.assertEqual(result["sessionEmbedRoi"]["jobs"], 2)
            self.assertEqual(embed_mock.call_count, 2)

            manifest = json.loads(
                (checkpoint_dir / "manifest.json").read_text(encoding="utf-8")
            )
            self.assertEqual(
                [entry["launchIndex"] for entry in manifest["completedLaunches"]],
                [0, 1],
            )

            phases = [
                json.loads(line)["phase"]
                for line in progress_path.read_text(encoding="utf-8").splitlines()
            ]
            self.assertIn("hostplan_embed_roi_parallel_group_start", phases)
            self.assertIn("hostplan_embed_roi_parallel_group_complete", phases)

    def test_launch_step_timeout_is_typed_and_writes_receipt(self) -> None:
        import numpy as np

        with tempfile.TemporaryDirectory() as tmpdir:
            tmp = Path(tmpdir)
            progress_path = tmp / "progress.jsonl"
            trace_path = tmp / "trace.json"
            input_path = tmp / "hostplan-runtime" / "buffers" / "input.npy"
            bootstrap = {
                "launches": [
                    {
                        "launchIndex": 0,
                        "targetName": "ple_embed",
                        "launchFunction": "compute",
                        "compileDir": str(tmp / "compiled"),
                        "targetGeometry": {"width": 1, "height": 1},
                    }
                ],
                "targetSessions": [],
            }

            def fake_stage_launch_arrays(**kwargs: object) -> tuple[list[dict], list[dict]]:
                runtime_dir = Path(str(kwargs["runtime_dir"]))
                input_path.parent.mkdir(parents=True, exist_ok=True)
                np.save(input_path, np.array([1.0, 2.0], dtype=np.float32))
                output_path = runtime_dir / "buffers" / "output.npy"
                return [
                    {
                        "symbol": "activation",
                        "buffer": "activation:prefill:0000:global:embed_tokens",
                        "role": "activation",
                        "path": str(input_path),
                        "dtype": "f32",
                        "elemType": "f32",
                        "elementsPerPe": 2,
                    }
                ], [
                    {
                        "symbol": "output",
                        "buffer": "activation:prefill:0000:global:ple_embed",
                        "path": str(output_path),
                        "dtype": "f16",
                    }
                ]

            timeout = subprocess.TimeoutExpired(
                cmd=["cs_python", "int4ple_launch_step_adapter.py"],
                timeout=7,
                output="stdout tail\n",
                stderr="stderr tail\n",
            )
            with (
                mock.patch.object(
                    runner,
                    "_stage_launch_arrays",
                    side_effect=fake_stage_launch_arrays,
                ),
                mock.patch.object(runner, "cs_python_executable", return_value=sys.executable),
                mock.patch.object(runner.subprocess, "run", side_effect=timeout) as run_mock,
            ):
                result = runner.execute_hostplan_runtime(
                    bootstrap=bootstrap,
                    export={},
                    progress_path=progress_path,
                    cmaddr=None,
                    trace_path=trace_path,
                    launch_timeout_seconds=7,
                )

            self.assertEqual(result["status"], "blocked")
            self.assertEqual(
                result["blockers"],
                ["launch[0]_blocked:launch_step_timeout"],
            )
            self.assertEqual(result["launchTimeoutSeconds"], 7)
            self.assertEqual(result["launches"][0]["status"], "blocked")
            self.assertEqual(result["launches"][0]["blockers"], ["launch_step_timeout"])
            self.assertEqual(result["launches"][0]["stdoutTail"], ["stdout tail"])
            self.assertEqual(result["launches"][0]["stderrTail"], ["stderr tail"])
            self.assertEqual(run_mock.call_args.kwargs["timeout"], 7)

            receipt_path = (
                trace_path.parent
                / "hostplan-runtime"
                / "launch-receipts"
                / "launch-0000.json"
            )
            receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
            self.assertEqual(receipt["blockers"], ["launch_step_timeout"])
            self.assertEqual(
                receipt["inputBuffers"][0]["name"],
                "activation:prefill:0000:global:embed_tokens",
            )
            self.assertEqual(receipt["inputBuffers"][0]["role"], "activation")
            self.assertEqual(receipt["inputBuffers"][0]["totalElements"], 2)

            phases = [
                json.loads(line)["phase"]
                for line in progress_path.read_text(encoding="utf-8").splitlines()
            ]
            self.assertIn("hostplan_launch_timeout", phases)


class HostPlanRuntimeLaunchHelperTest(unittest.TestCase):
    def test_helper_generic_launch_preserves_checkpoint_status_shape(self) -> None:
        helper = runner._runtime_launch

        def unused_launch_hook(**_kwargs: object) -> dict:
            raise AssertionError("unexpected launch hook")

        with tempfile.TemporaryDirectory() as tmpdir:
            tmp = Path(tmpdir)
            progress_path = tmp / "progress.jsonl"
            trace_path = tmp / "trace.json"
            output_path = tmp / "hostplan-runtime" / "buffers" / "output.npy"
            bootstrap = {
                "launches": [
                    {
                        "launchIndex": 2,
                        "targetName": "generic_target",
                        "launchFunction": "compute",
                        "compileDir": str(tmp / "compiled"),
                        "targetGeometry": {"width": 1, "height": 1},
                    }
                ],
                "targetSessions": [{"targetName": "generic_target"}],
            }

            def fake_stage_launch_arrays(
                **_kwargs: object,
            ) -> tuple[list[dict], list[dict]]:
                return [], [
                    {
                        "symbol": "output",
                        "buffer": "activation:generic",
                        "path": str(output_path),
                        "dtype": "f16",
                    }
                ]

            hooks = helper.HostPlanRuntimeLaunchHooks(
                execute_embed_roi_launch=unused_launch_hook,
                stage_launch_arrays=fake_stage_launch_arrays,
                execute_tiled_q4k_gemv_launch=unused_launch_hook,
                execute_compact_ple_proj_launch=unused_launch_hook,
                execute_compact_attention_prefill_launch=unused_launch_hook,
                execute_rmsnorm_roi_launch=unused_launch_hook,
                execute_residual_prefill_roi_launch=unused_launch_hook,
                execute_compact_gated_prefill_launch=unused_launch_hook,
                execute_dense_gemv_tiled_session_launch=unused_launch_hook,
            )

            def fake_run(
                command: list[str],
                **_kwargs: object,
            ) -> subprocess.CompletedProcess[str]:
                receipt_path = Path(command[command.index("--receipt-out") + 1])
                receipt_path.parent.mkdir(parents=True, exist_ok=True)
                output_path.parent.mkdir(parents=True, exist_ok=True)
                output_path.write_bytes(b"out")
                receipt_path.write_text(
                    json.dumps(
                        {
                            "schemaVersion": 1,
                            "artifactKind": "int4ple_launch_step_receipt",
                            "status": "succeeded",
                            "blockers": [],
                            "launchIndex": 2,
                            "targetName": "generic_target",
                        }
                    ),
                    encoding="utf-8",
                )
                return subprocess.CompletedProcess(
                    command,
                    0,
                    stdout="stdout line\n",
                    stderr="stderr line\n",
                )

            with (
                mock.patch.object(helper, "cs_python_executable", return_value=sys.executable),
                mock.patch.object(helper.subprocess, "run", side_effect=fake_run),
            ):
                result = helper.execute_hostplan_runtime(
                    bootstrap=bootstrap,
                    export={},
                    progress_path=progress_path,
                    cmaddr=None,
                    trace_path=trace_path,
                    hooks=hooks,
                    stop_after_launch=2,
                )

            self.assertEqual(result["status"], "stopped_at_checkpoint")
            self.assertEqual(result["blockers"], [])
            self.assertEqual(result["executedLaunchCount"], 1)
            self.assertEqual(result["launchCount"], 1)
            self.assertEqual(result["targetSessions"], bootstrap["targetSessions"])
            self.assertTrue(result["stoppedAtCheckpoint"])
            self.assertEqual(result["launches"][0]["status"], "succeeded")
            self.assertEqual(result["launches"][0]["stdoutTail"], ["stdout line"])
            self.assertEqual(result["launches"][0]["stderrTail"], ["stderr line"])


if __name__ == "__main__":
    unittest.main()
