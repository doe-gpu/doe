from __future__ import annotations

import tempfile
import unittest
from unittest import mock
from pathlib import Path

from bench.tools.build_doppler_shared_execution_contract import (
    build_contract,
    load_json,
    schema_failures,
    write_json,
)


class TestBuildDopplerSharedExecutionContract(unittest.TestCase):
    def test_build_contract_without_hostplan_projection(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            manifest_path = tmp_path / "manifest.json"
            graph_path = tmp_path / "execution_graph.json"
            prompt_path = tmp_path / "prompt.txt"
            tokenized_path = tmp_path / "tokenized_prompt.u32"
            transcript_path = tmp_path / "decode_transcript.json"
            reference_export_path = tmp_path / "reference_export.json"
            shard_path = tmp_path / "shard_00000.bin"
            shard_path.write_bytes(b"\x00" * 64)
            prompt_path.write_text("hello", encoding="utf-8")
            tokenized_path.write_bytes((1).to_bytes(4, "little"))
            manifest = {
                "architecture": {
                    "hiddenSize": 16,
                    "numAttentionHeads": 1,
                    "headDim": 16,
                    "globalHeadDim": 16,
                    "numKeyValueHeads": 1,
                    "numLayers": 1,
                    "vocabSize": 32,
                    "intermediateSize": 64,
                    "hiddenSizePerLayerInput": 16,
                    "vocabSizePerLayerInput": 32,
                },
                "shards": [
                    {
                        "index": 0,
                        "filename": "shard_00000.bin",
                        "sha256": "0" * 64,
                        "sizeBytes": 64,
                    }
                ],
                "tensors": {
                    "model.language_model.embed_tokens_per_layer.weight": {
                        "dtype": "Q4_K_M",
                        "shape": [32, 16],
                        "size": 64,
                        "shard": 0,
                        "offset": 0,
                        "role": "weight",
                        "layout": "row_major",
                    },
                    "model.language_model.embed_tokens.weight": {
                        "dtype": "Q4_K_M",
                        "shape": [32, 16],
                        "size": 64,
                        "shard": 0,
                        "offset": 0,
                        "role": "weight",
                        "layout": "row_major",
                    },
                    "model.language_model.layers.0.self_attn.q_proj.weight": {
                        "dtype": "Q4_K_M",
                        "shape": [16, 16],
                        "size": 64,
                        "shard": 0,
                        "offset": 0,
                        "role": "weight",
                        "layout": "row_major",
                    },
                    "model.language_model.lm_head.weight": {
                        "dtype": "Q4_K_M",
                        "shape": [16, 32],
                        "size": 64,
                        "shard": 0,
                        "offset": 0,
                        "role": "weight",
                        "layout": "row_major",
                    },
                },
            }
            graph = {
                "execution": {
                    "kernels": {
                        "embed": {
                            "kernel": "embed.wgsl",
                            "entry": "main",
                            "digest": "sha256:" + ("1" * 64),
                        },
                        "attn_decode": {
                            "kernel": "attn.wgsl",
                            "entry": "main",
                            "digest": "sha256:" + ("2" * 64),
                        },
                        "lm_head_gemv": {
                            "kernel": "lm_head.wgsl",
                            "entry": "main",
                            "digest": "sha256:" + ("3" * 64),
                        },
                    },
                    "preLayer": [["embed_tokens", "embed"]],
                    "prefill": [
                        {
                            "layers": [0],
                            "steps": [["attn", "attn_decode", "layer.0.self_attn.q_proj"]],
                        }
                    ],
                    "decode": [["attn", "attn_decode", "layer.0.self_attn.q_proj"]],
                    "postLayer": [["lm_head", "lm_head_gemv", "lm_head"]],
                }
            }
            transcript = {
                "requestedDecodeSteps": 2,
                "actualDecodeSteps": 2,
                "stopReason": "decode_steps_exhausted",
                "generatedTokenIdsSha256": "4" * 64,
                "logitsDigests": [],
                "sourceReferenceTranscript": {
                    "kvCache": {
                        "mode": "not_captured",
                        "byteDigestMode": "not_captured",
                        "byteDigest": "pending",
                        "byteDigests": [],
                        "seqLen": 3,
                        "kvDtype": "pending",
                    }
                },
            }
            write_json(manifest_path, manifest)
            write_json(graph_path, graph)
            write_json(transcript_path, transcript)
            reference_export = {
                "modelId": "gemma-test",
                "manifestPath": str(manifest_path),
                "manifestSha256": "a" * 64,
                "executionGraphSha256": "b" * 64,
                "executionGraph": {
                    "path": str(graph_path),
                    "sha256": "b" * 64,
                },
                "weightSetId": "weights",
                "weightSetSha256": "c" * 64,
                "shardIdentities": [
                    {
                        "index": 0,
                        "filename": "shard_00000.bin",
                        "sha256": "0" * 64,
                    }
                ],
                "inputSetSha256": "d" * 64,
                "inputSetComponents": {
                    "samplingSha256": "e" * 64,
                    "tokenCount": 1,
                },
                "prompt": {
                    "path": str(prompt_path),
                    "sha256": "f" * 64,
                    "source": "test",
                },
                "tokenizedPrompt": {
                    "path": "not_captured_by_doppler_program_bundle",
                    "sha256": "not_captured_by_doppler_program_bundle",
                    "dtype": "uint32",
                    "tokenCount": 1,
                    "preview": [],
                },
                "decodeTranscript": {
                    "status": "output_ready",
                    "transcript": {
                        "path": str(transcript_path),
                        "sha256": "2" * 64,
                    },
                    "requestedDecodeSteps": 2,
                    "actualDecodeSteps": 2,
                    "stopReason": "decode_steps_exhausted",
                    "generatedTokenIds": {"sha256": "4" * 64},
                    "sampling": {"temperature": 0, "topK": 1, "topP": 1},
                    "logitsDigests": [],
                },
            }
            write_json(reference_export_path, reference_export)
            contract = build_contract(
                export=reference_export,
                export_path=reference_export_path,
                out_path=tmp_path / "shared_contract.json",
                program_bundle_path=None,
                hostplan_bundle_root=None,
            )
            schema = load_json(
                Path("config/doe-shared-execution-contract.schema.json").resolve()
            )
            self.assertEqual(schema_failures(contract, schema), [])
            self.assertEqual(contract["hostPlanProjection"]["status"], "not_bound")
            self.assertEqual(contract["stateInputs"]["status"], "not_bound")
            self.assertEqual(contract["weightMappings"]["status"], "complete")
            self.assertEqual(contract["weightMappings"]["declaredShardCount"], 1)
            self.assertEqual(contract["decodeRequest"]["requestedDecodeSteps"], 2)
            self.assertEqual(contract["doeWebgpuRuntime"]["host"], "node")
            self.assertEqual(
                contract["doeWebgpuRuntime"]["providerModule"],
                "packages/doe-gpu/src/compute.js",
            )
            self.assertEqual(contract["normalizedExecution"]["stepCount"], 4)

    def test_build_contract_binds_state_inputs_and_hostplan_projection(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            manifest_path = tmp_path / "manifest.json"
            graph_path = tmp_path / "execution_graph.json"
            prompt_path = tmp_path / "prompt.txt"
            tokenized_path = tmp_path / "tokenized_prompt.u32"
            transcript_path = tmp_path / "decode_transcript.json"
            reference_export_path = tmp_path / "reference_export.json"
            hostplan_root = tmp_path / "hostplan"
            hostplan_root.mkdir(parents=True, exist_ok=True)
            prompt_path.write_text("hello", encoding="utf-8")
            tokenized_path.write_bytes((1).to_bytes(4, "little"))
            write_json(
                manifest_path,
                {
                    "architecture": {
                        "hiddenSize": 16,
                        "numAttentionHeads": 1,
                        "headDim": 16,
                        "globalHeadDim": 16,
                        "numKeyValueHeads": 1,
                        "numLayers": 1,
                        "vocabSize": 32,
                        "intermediateSize": 64,
                        "hiddenSizePerLayerInput": 16,
                        "vocabSizePerLayerInput": 32,
                    },
                    "inference": {"attention": {"slidingWindow": 32}},
                    "tensors": {
                        "model.language_model.embed_tokens_per_layer.weight": {
                            "dtype": "Q4_K_M",
                            "shape": [32, 16],
                            "size": 64,
                            "shard": 0,
                            "offset": 0,
                            "role": "weight",
                            "layout": "row_major",
                        },
                        "model.language_model.layers.0.self_attn.q_proj.weight": {
                            "dtype": "Q4_K_M",
                            "shape": [16, 16],
                            "size": 64,
                            "shard": 0,
                            "offset": 0,
                            "role": "weight",
                            "layout": "row_major",
                        },
                        "model.language_model.embed_tokens.weight": {
                            "dtype": "Q4_K_M",
                            "shape": [32, 16],
                            "size": 64,
                            "shard": 0,
                            "offset": 0,
                            "role": "weight",
                            "layout": "row_major",
                        },
                    },
                },
            )
            write_json(
                graph_path,
                {
                    "execution": {
                        "kernels": {
                            "embed": {
                                "kernel": "embed.wgsl",
                                "entry": "main",
                                "digest": "sha256:" + ("1" * 64),
                            },
                            "attn_decode": {
                                "kernel": "attn.wgsl",
                                "entry": "main",
                                "digest": "sha256:" + ("2" * 64),
                            },
                            "lm_head_gemv": {
                                "kernel": "lm_head.wgsl",
                                "entry": "main",
                                "digest": "sha256:" + ("3" * 64),
                            },
                        },
                        "preLayer": [["embed_tokens", "embed"]],
                        "prefill": [
                            {
                                "layers": [0],
                                "steps": [
                                    [
                                        "attn",
                                        "attn_decode",
                                        "layer.0.self_attn.q_proj",
                                    ]
                                ],
                            }
                        ],
                        "decode": [["attn", "attn_decode", "layer.0.self_attn.q_proj"]],
                        "postLayer": [["lm_head", "lm_head_gemv", "lm_head"]],
                    }
                },
            )
            write_json(
                transcript_path,
                {
                    "requestedDecodeSteps": 2,
                    "actualDecodeSteps": 2,
                    "stopReason": "decode_steps_exhausted",
                    "generatedTokenIdsSha256": "4" * 64,
                    "logitsDigests": [],
                    "sourceReferenceTranscript": {
                        "kvCache": {
                            "mode": "not_captured",
                            "byteDigestMode": "not_captured",
                            "byteDigest": "pending",
                            "byteDigests": [],
                            "seqLen": 3,
                            "kvDtype": "pending",
                        }
                    },
                },
            )
            reference_export = {
                "modelId": "gemma-test",
                "manifestPath": str(manifest_path),
                "manifestSha256": "a" * 64,
                "executionGraphSha256": "b" * 64,
                "executionGraph": {
                    "path": str(graph_path),
                    "sha256": "b" * 64,
                },
                "weightSetId": "weights",
                "weightSetSha256": "c" * 64,
                "shardIdentities": [
                    {
                        "index": 0,
                        "filename": "shard_00000.bin",
                        "sha256": "0" * 64,
                    }
                ],
                "inputSetSha256": "d" * 64,
                "inputSetComponents": {
                    "samplingSha256": "e" * 64,
                    "tokenCount": 1,
                },
                "prompt": {
                    "path": str(prompt_path),
                    "sha256": "f" * 64,
                    "source": "test",
                },
                "tokenizedPrompt": {
                    "path": str(tokenized_path),
                    "sha256": "1" * 64,
                    "dtype": "uint32",
                    "tokenCount": 1,
                    "preview": [1],
                },
                "decodeTranscript": {
                    "status": "output_ready",
                    "transcript": {
                        "path": str(transcript_path),
                        "sha256": "2" * 64,
                    },
                    "requestedDecodeSteps": 2,
                    "actualDecodeSteps": 2,
                    "stopReason": "decode_steps_exhausted",
                    "generatedTokenIds": {"sha256": "4" * 64},
                    "sampling": {"temperature": 0, "topK": 1, "topP": 1},
                    "logitsDigests": [],
                },
            }
            write_json(reference_export_path, reference_export)
            write_json(hostplan_root / "host-plan.json", {"hostPlan": {"phases": {}}})
            write_json(
                hostplan_root / "normalized-execution-v1.json",
                {"sourceGraphSha256": "b" * 64, "modelConfig": {}, "steps": []},
            )
            write_json(
                hostplan_root / "runtime-config.json",
                {
                    "stateBuffers": [
                        {"name": "kv_cache", "kind": "kv_cache", "bytesPerPe": 8}
                    ],
                    "hostIoLayout": [
                        {
                            "name": "state:kv_cache",
                            "bufferRole": "state",
                            "hostAction": "allocate_device",
                            "dtype": "bytes",
                            "peGrid": {"width": 1, "height": 1},
                            "roi": {
                                "x": 0,
                                "y": 0,
                                "width": 1,
                                "height": 1,
                                "peStart": 0,
                                "peEnd": 0,
                            },
                            "order": "row_major_pe_range",
                            "elementsPerPe": 8,
                            "bytesPerPe": 8,
                            "totalElements": 8,
                            "totalBytes": 8,
                            "sourceIdentity": {
                                "kind": "runtime_state_buffer",
                                "source": "kv_cache",
                                "synthetic": False,
                            },
                        }
                    ],
                },
            )
            write_json(hostplan_root / "memory-plan.json", {"memoryPlan": {}})
            write_json(hostplan_root / "simulator-plan.json", {"runtime": {}})
            write_json(
                hostplan_root / "doppler-program-bundle.json",
                {"schema": "doppler.program-bundle/v1"},
            )

            with mock.patch(
                "bench.tools.build_doppler_shared_execution_contract.load_host_plan_phase_summary"
            ) as load_summary:
                load_summary.return_value = lambda *args, **kwargs: {
                    "launchSchedule": {"status": "bound", "launchCount": 1}
                }
                contract = build_contract(
                    export=reference_export,
                    export_path=reference_export_path,
                    out_path=tmp_path / "shared_contract.json",
                    program_bundle_path=hostplan_root / "doppler-program-bundle.json",
                    hostplan_bundle_root=hostplan_root,
                )

            schema = load_json(
                Path("config/doe-shared-execution-contract.schema.json").resolve()
            )
            self.assertEqual(schema_failures(contract, schema), [])
            self.assertEqual(contract["hostPlanProjection"]["status"], "bound")
            self.assertEqual(contract["stateInputs"]["status"], "bound")
            self.assertEqual(contract["stateInputs"]["stateBufferCount"], 1)
            self.assertEqual(contract["stateInputs"]["hostStateEntryCount"], 1)
            self.assertIn("normalizedExecution", contract["hostPlanProjection"])
            self.assertIn("programBundle", contract["hostPlanProjection"])

    def test_transcript_schema_accepts_shared_execution_contract_link(self) -> None:
        transcript_schema = load_json(
            Path("config/doe-csl-int4ple-transcript.schema.json").resolve()
        )
        receipt = load_json(
            Path("examples/doe-csl-int4ple-transcript.blocked.sample.json").resolve()
        )
        receipt["hostPlanBundle"]["sharedExecutionContract"] = {
            "path": "bench/out/doppler-reference/shared-execution-contract.json",
            "sha256": "f" * 64,
            "source": "doe_shared_execution_contract",
        }
        self.assertEqual(schema_failures(receipt, transcript_schema), [])


if __name__ == "__main__":
    unittest.main()
