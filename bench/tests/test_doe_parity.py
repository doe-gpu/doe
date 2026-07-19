"""Unit tests for the Doe parity harness CLI (bench/tools/doe_parity.py)."""

from __future__ import annotations

import hashlib
import json
import struct
import sys
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from bench.tools import doe_parity  # noqa: E402


def _write_input_doc(
    tmp_path: Path,
    kernel: str,
    inputs: dict[str, dict[str, object]],
    parameters: dict[str, object] | None = None,
) -> Path:
    path = tmp_path / f"{kernel}.oracle-inputs.json"
    payload = {
        "kernel": kernel,
        "inputs": inputs,
        "parameters": parameters or {},
    }
    path.write_text(json.dumps(payload, sort_keys=True), encoding="utf-8")
    return path


def _sha256_hex(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


class TestParityScaffolding(unittest.TestCase):
    def test_valid_exactness_set_matches_rdrr_taxonomy(self) -> None:
        self.assertEqual(
            doe_parity.VALID_EXACTNESS,
            frozenset(
                {"bit_exact_solo", "algorithm_exact", "tolerance_bounded"}
            ),
        )

    def test_rejection_reasons_match_tsir_taxonomy(self) -> None:
        self.assertEqual(
            doe_parity.REJECTION_REASONS,
            frozenset(
                {
                    "tsir_subgroup_unlowerable",
                    "tsir_pe_budget_exhausted",
                    "tsir_collective_not_representable",
                    "tsir_dependence_unanalyzable",
                    "tsir_source_not_affine",
                    "tsir_target_unfit",
                }
            ),
        )

    def test_rejection_taxonomy_is_consistent_across_schemas(self) -> None:
        """Lockstep check across the four JSON schemas that carry the TSIR
        rejection taxonomy plus the Python CLI's `REJECTION_REASONS`.

        Catches drift where someone adds or renames a reason in one place
        and forgets another — the taxonomy must move in lockstep or not at
        all, since it's a single wire contract shared across semantic,
        realization, manifest-lowering, and parity-receipt artifacts. The
        Zig canonical enum `runtime/zig/src/compiler/tsir/schema.zig::RejectionReason`
        is verified separately by `tests/wgsl/tsir_scaffold_test.zig` test
        'rejection taxonomy is exhaustive and enumerable'.
        """

        def find_tsir_enum(obj: object) -> frozenset[str] | None:
            """Return the first enum list containing tsir_* entries."""
            if isinstance(obj, dict):
                enum = obj.get("enum")
                if (
                    isinstance(enum, list)
                    and any(
                        isinstance(v, str) and v.startswith("tsir_")
                        for v in enum
                    )
                ):
                    return frozenset(v for v in enum if isinstance(v, str))
                for v in obj.values():
                    found = find_tsir_enum(v)
                    if found is not None:
                        return found
            elif isinstance(obj, list):
                for v in obj:
                    found = find_tsir_enum(v)
                    if found is not None:
                        return found
            return None

        config_dir = REPO_ROOT / "config"
        schema_files = (
            "doe-parity-receipt.schema.json",
            "doe-tsir-semantic.schema.json",
            "doe-tsir-realization.schema.json",
            "doe-tsir-manifest-lowering.schema.json",
        )
        schema_sets: dict[str, frozenset[str]] = {}
        for name in schema_files:
            with (config_dir / name).open(encoding="utf-8") as handle:
                doc = json.load(handle)
            enum = find_tsir_enum(doc)
            self.assertIsNotNone(enum, f"no tsir_* enum found in {name}")
            schema_sets[name] = enum  # type: ignore[assignment]

        canonical = doe_parity.REJECTION_REASONS
        for name, enum in schema_sets.items():
            self.assertEqual(
                enum,
                canonical,
                f"{name} rejection taxonomy drifted from doe_parity.REJECTION_REASONS",
            )

    def test_reference_interpreter_is_not_implemented(self) -> None:
        outcome = doe_parity.run_reference_interpreter("rmsnorm", "abc")
        self.assertEqual(outcome.backend, "reference")
        self.assertEqual(outcome.status, "not_implemented")

    def test_reference_interpreter_runs_fused_gemv_bootstrap_inputs(self) -> None:
        semantic = (
            REPO_ROOT
            / "runtime"
            / "zig"
            / "tests"
            / "tsir"
            / "bootstrap"
            / "fused_gemv.tsir-semantic.json"
        )
        realization = (
            REPO_ROOT
            / "runtime"
            / "zig"
            / "tests"
            / "tsir"
            / "bootstrap"
            / "fused_gemv.tsir-realization.webgpu-generic.json"
        )
        with tempfile.TemporaryDirectory() as tmp:
            inputs_path = _write_input_doc(
                Path(tmp),
                "fused_gemv",
                {
                    "W": {
                        "elem": "f32",
                        "shape": [2, 2],
                        "values": [1.0, 2.0, 4.0, 8.0],
                    },
                    "x": {
                        "elem": "f32",
                        "shape": [2],
                        "values": [1.0, 2.0],
                    },
                },
            )
            outcome = doe_parity.run_reference_interpreter(
                "fused_gemv",
                "abc",
                inputs_path=inputs_path,
                semantic_path=semantic,
                realization_path=realization,
            )
        expected = _sha256_hex(struct.pack("<ff", 5.0, 20.0))
        self.assertEqual(outcome.backend, "reference")
        self.assertEqual(outcome.status, "pass")
        self.assertEqual(outcome.backend_hash, expected)
        self.assertEqual(outcome.detail, "zig bootstrap TSIR oracle executed")

    def test_reference_interpreter_runs_gather_bootstrap_inputs(self) -> None:
        semantic = (
            REPO_ROOT
            / "runtime"
            / "zig"
            / "tests"
            / "tsir"
            / "bootstrap"
            / "gather.tsir-semantic.json"
        )
        realization = (
            REPO_ROOT
            / "runtime"
            / "zig"
            / "tests"
            / "tsir"
            / "bootstrap"
            / "gather.tsir-realization.webgpu-generic.json"
        )
        with tempfile.TemporaryDirectory() as tmp:
            inputs_path = _write_input_doc(
                Path(tmp),
                "gather",
                {
                    "indices": {
                        "elem": "u32",
                        "shape": [2],
                        "values": [1, 0],
                    },
                    "table": {
                        "elem": "f32",
                        "shape": [2, 2],
                        "values": [1.5, 2.5, 3.5, 4.5],
                    },
                },
            )
            outcome = doe_parity.run_reference_interpreter(
                "gather",
                "abc",
                inputs_path=inputs_path,
                semantic_path=semantic,
                realization_path=realization,
            )
        expected = _sha256_hex(struct.pack("<ffff", 3.5, 4.5, 1.5, 2.5))
        self.assertEqual(outcome.status, "pass")
        self.assertEqual(outcome.backend_hash, expected)

    def test_reference_interpreter_runs_rms_norm_with_uniform_epsilon(
        self,
    ) -> None:
        semantic = (
            REPO_ROOT
            / "runtime"
            / "zig"
            / "tests"
            / "tsir"
            / "bootstrap"
            / "rms_norm.tsir-semantic.json"
        )
        realization = (
            REPO_ROOT
            / "runtime"
            / "zig"
            / "tests"
            / "tsir"
            / "bootstrap"
            / "rms_norm.tsir-realization.webgpu-generic.json"
        )
        with tempfile.TemporaryDirectory() as tmp:
            inputs_path = _write_input_doc(
                Path(tmp),
                "rms_norm",
                {
                    "input": {
                        "elem": "f32",
                        "shape": [2],
                        "values": [2.0, 2.0],
                    },
                    "weight": {
                        "elem": "f32",
                        "shape": [2],
                        "values": [3.0, 4.0],
                    },
                    "u": {
                        "elem": "u32",
                        "shape": [2],
                        "bytesHex": "0000000000000000",
                    },
                },
            )
            outcome = doe_parity.run_reference_interpreter(
                "rms_norm",
                "abc",
                inputs_path=inputs_path,
                semantic_path=semantic,
                realization_path=realization,
            )
        expected = _sha256_hex(struct.pack("<ff", 3.0, 4.0))
        self.assertEqual(outcome.status, "pass")
        self.assertEqual(outcome.backend_hash, expected)

    def test_reference_interpreter_declines_manifest_fixture_inputs(self) -> None:
        fixture = (
            REPO_ROOT
            / "bench"
            / "fixtures"
            / "tsir-manifest-entries"
            / "fused_gemv.webgpu-generic.json"
        )
        outcome = doe_parity.run_reference_interpreter(
            "fused_gemv",
            "abc",
            inputs_path=fixture,
        )
        self.assertEqual(outcome.status, "not_implemented")
        self.assertIn("unsupported or missing kernel/inputs", outcome.detail or "")

    def test_reference_interpreter_declines_gather_oob_inputs(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            inputs_path = _write_input_doc(
                Path(tmp),
                "gather",
                {
                    "indices": {
                        "elem": "u32",
                        "shape": [1],
                        "values": [2],
                    },
                    "table": {
                        "elem": "f32",
                        "shape": [2, 1],
                        "values": [1.0, 2.0],
                    },
                },
            )
            outcome = doe_parity.run_reference_interpreter(
                "gather",
                "abc",
                inputs_path=inputs_path,
            )
        self.assertEqual(outcome.status, "not_implemented")
        self.assertIn("cannot execute this input", outcome.detail or "")

    def test_reference_interpreter_reports_rejected_tsir(self) -> None:
        outcome = doe_parity.run_reference_interpreter(
            "rmsnorm",
            "abc",
            ["tsir_collective_not_representable", "tsir_target_unfit"],
        )
        self.assertEqual(outcome.backend, "reference")
        self.assertEqual(outcome.status, "rejected")
        self.assertIn("tsir_collective_not_representable", outcome.detail or "")

    def test_backend_lanes_are_not_implemented(self) -> None:
        for backend in ("webgpu", "csl-simfabric"):
            with self.subTest(backend=backend):
                outcome = doe_parity.run_backend(backend)
                self.assertEqual(outcome.status, "not_implemented")

    def test_compare_defers_when_reference_missing(self) -> None:
        reference = doe_parity.ComparisonOutcome(
            backend="reference", status="not_implemented"
        )
        backend = doe_parity.ComparisonOutcome(
            backend="webgpu", status="not_implemented"
        )
        result = doe_parity.compare(reference, backend, "bit_exact_solo")
        self.assertEqual(result.status, "deferred")

    def test_compare_defers_when_backend_missing_after_reference_executes(
        self,
    ) -> None:
        reference = doe_parity.ComparisonOutcome(
            backend="reference", status="pass", backend_hash="abc"
        )
        backend = doe_parity.ComparisonOutcome(
            backend="webgpu", status="not_implemented"
        )
        result = doe_parity.compare(reference, backend, "bit_exact_solo")
        self.assertEqual(result.status, "deferred")
        self.assertIn("reference=pass", result.detail or "")

    def test_compare_marks_backend_rejected_when_reference_rejects(self) -> None:
        reference = doe_parity.ComparisonOutcome(
            backend="reference",
            status="rejected",
            detail="TSIR rejected before execution: tsir_target_unfit",
        )
        backend = doe_parity.ComparisonOutcome(
            backend="webgpu", status="not_implemented"
        )
        result = doe_parity.compare(reference, backend, "bit_exact_solo")
        self.assertEqual(result.status, "rejected")
        self.assertIn("reference=rejected", result.detail or "")

    def test_compare_rejects_unknown_exactness_class(self) -> None:
        reference = doe_parity.ComparisonOutcome(backend="reference", status="ok")
        backend = doe_parity.ComparisonOutcome(backend="webgpu", status="ok")
        with self.assertRaises(ValueError):
            doe_parity.compare(reference, backend, "looks_good_to_me")

    def test_tolerance_bounded_defers_without_policy(self) -> None:
        reference = doe_parity.ComparisonOutcome(
            backend="reference", status="ok", backend_hash="abc"
        )
        backend = doe_parity.ComparisonOutcome(
            backend="webgpu", status="ok", backend_hash="abc"
        )
        result = doe_parity.compare(reference, backend, "tolerance_bounded")
        self.assertEqual(result.status, "deferred")
        self.assertIn("tolerance_bounded", result.detail or "")

    def test_bit_exact_pass_and_fail(self) -> None:
        ref = doe_parity.ComparisonOutcome(
            backend="reference", status="ok", backend_hash="deadbeef"
        )
        ok = doe_parity.ComparisonOutcome(
            backend="webgpu", status="ok", backend_hash="deadbeef"
        )
        self.assertEqual(
            doe_parity.compare(ref, ok, "bit_exact_solo").status, "pass"
        )
        bad = doe_parity.ComparisonOutcome(
            backend="webgpu", status="ok", backend_hash="cafef00d"
        )
        self.assertEqual(
            doe_parity.compare(ref, bad, "bit_exact_solo").status, "fail"
        )

    def test_exact_classes_defer_on_missing_hash_payloads(self) -> None:
        ref = doe_parity.ComparisonOutcome(backend="reference", status="pass")
        backend = doe_parity.ComparisonOutcome(backend="webgpu", status="pass")
        for exactness in ("bit_exact_solo", "algorithm_exact"):
            with self.subTest(exactness=exactness):
                result = doe_parity.compare(ref, backend, exactness)
                self.assertEqual(result.status, "deferred")
                self.assertIn("missing referenceHash", result.detail or "")

    def test_algorithm_exact_uses_backend_hash(self) -> None:
        ref = doe_parity.ComparisonOutcome(
            backend="reference", status="pass", backend_hash="f" * 64
        )
        ok = doe_parity.ComparisonOutcome(
            backend="webgpu", status="pass", backend_hash="f" * 64
        )
        bad = doe_parity.ComparisonOutcome(
            backend="webgpu", status="pass", backend_hash="0" * 64
        )
        self.assertEqual(doe_parity.compare(ref, ok, "algorithm_exact").status, "pass")
        self.assertEqual(doe_parity.compare(ref, bad, "algorithm_exact").status, "fail")

    def test_tolerance_bounded_exact_hash_passes_with_zero_metric(self) -> None:
        policy = doe_parity.TolerancePolicy(metric="max_abs", epsilon=1.0e-6)
        ref = doe_parity.ComparisonOutcome(
            backend="reference", status="pass", backend_hash="a" * 64
        )
        backend = doe_parity.ComparisonOutcome(
            backend="webgpu", status="pass", backend_hash="a" * 64
        )
        result = doe_parity.compare(ref, backend, "tolerance_bounded", policy)
        self.assertEqual(result.status, "pass")
        self.assertEqual(result.metric, "max_abs")
        self.assertEqual(result.metric_value, 0.0)
        self.assertEqual(result.metric_epsilon, 1.0e-6)

    def test_tolerance_bounded_numeric_metric_pass_and_fail(self) -> None:
        policy = doe_parity.TolerancePolicy(metric="max_abs", epsilon=1.0e-6)
        ref = doe_parity.ComparisonOutcome(
            backend="reference", status="pass", backend_hash="a" * 64
        )
        within = doe_parity.ComparisonOutcome(
            backend="webgpu",
            status="pass",
            backend_hash="b" * 64,
            metric="max_abs",
            metric_value=5.0e-7,
        )
        outside = doe_parity.ComparisonOutcome(
            backend="webgpu",
            status="pass",
            backend_hash="c" * 64,
            metric="max_abs",
            metric_value=2.0e-6,
        )
        self.assertEqual(
            doe_parity.compare(ref, within, "tolerance_bounded", policy).status,
            "pass",
        )
        self.assertEqual(
            doe_parity.compare(ref, outside, "tolerance_bounded", policy).status,
            "fail",
        )

    def test_tolerance_bounded_defers_when_numeric_payload_missing(self) -> None:
        policy = doe_parity.TolerancePolicy(metric="max_abs", epsilon=1.0e-6)
        ref = doe_parity.ComparisonOutcome(
            backend="reference", status="pass", backend_hash="a" * 64
        )
        backend = doe_parity.ComparisonOutcome(
            backend="webgpu", status="pass", backend_hash="b" * 64
        )
        result = doe_parity.compare(ref, backend, "tolerance_bounded", policy)
        self.assertEqual(result.status, "deferred")
        self.assertIn("no numeric metric payload", result.detail or "")

    def test_schema_is_well_formed(self) -> None:
        schema_path = REPO_ROOT / "config" / "doe-parity-receipt.schema.json"
        parsed = json.loads(schema_path.read_text(encoding="utf-8"))
        self.assertEqual(parsed["$id"], "doe-parity-receipt.schema.json")
        self.assertEqual(parsed["properties"]["schemaVersion"]["const"], 2)
        self.assertIn("bit_exact_solo", parsed["properties"]["exactnessClass"]["enum"])

    def test_generated_receipt_validates_against_schema(self) -> None:
        receipt = doe_parity.ParityReceipt(
            schema_version=2,
            artifact_kind="doe_parity_receipt",
            kernel="rmsnorm",
            exactness_class="bit_exact_solo",
            reference_hash=None,
            inputs_digest="0" * 64,
            comparisons=[
                doe_parity.ComparisonOutcome(
                    backend="reference",
                    status="pass",
                    backend_hash="1" * 64,
                    detail="oracle executed",
                ),
                doe_parity.ComparisonOutcome(
                    backend="webgpu",
                    status="deferred",
                    detail="backend pending",
                    metric="max_abs",
                    metric_value=0.0,
                    metric_epsilon=1.0e-6,
                ),
            ],
            rejection_reasons=[],
        )
        doe_parity.validate_receipt_doc(receipt.to_json())

    def test_receipt_schema_rejects_invalid_comparison_status(self) -> None:
        receipt = doe_parity.ParityReceipt(
            schema_version=2,
            artifact_kind="doe_parity_receipt",
            kernel="rmsnorm",
            exactness_class="bit_exact_solo",
            reference_hash=None,
            inputs_digest="0" * 64,
            comparisons=[
                doe_parity.ComparisonOutcome(
                    backend="reference",
                    status="not_implemented",
                ),
            ],
            rejection_reasons=[],
        )
        doc = receipt.to_json()
        doc["comparisons"][0]["status"] = "looks_green"
        with self.assertRaisesRegex(ValueError, "schema validation failed"):
            doe_parity.validate_receipt_doc(doc)

    def test_lowering_identity_from_manifest_fixture(self) -> None:
        fixture = (
            REPO_ROOT
            / "bench"
            / "fixtures"
            / "tsir-manifest-entries"
            / "fused_gemv.webgpu-generic.json"
        )
        entry = json.loads(fixture.read_text(encoding="utf-8"))
        identity = doe_parity.lowering_identity_from_manifest_entry(
            fixture,
            "algorithm_exact",
        )
        self.assertIsNotNone(identity)
        self.assertEqual(
            identity.to_json(),
            {
                "emitterDigest": entry["emitterDigest"],
                "targetDescriptorCorrectnessHash": (
                    entry["targetDescriptorCorrectnessHash"]
                ),
                "tsirRealizationDigest": entry["tsirRealizationDigest"],
                "tsirSemanticDigest": entry["tsirSemanticDigest"],
            },
        )

    def test_manifest_fixture_identity_receipt_stays_non_claimable(self) -> None:
        fixture = (
            REPO_ROOT
            / "bench"
            / "fixtures"
            / "tsir-manifest-entries"
            / "fused_gemv.webgpu-generic.json"
        )
        identity = doe_parity.lowering_identity_from_manifest_entry(
            fixture,
            "algorithm_exact",
        )
        receipt = doe_parity.ParityReceipt(
            schema_version=2,
            artifact_kind="doe_parity_receipt",
            kernel="fused_gemv",
            exactness_class="algorithm_exact",
            reference_hash=None,
            inputs_digest="0" * 64,
            comparisons=[
                doe_parity.ComparisonOutcome(
                    backend="reference",
                    status="not_implemented",
                ),
                doe_parity.ComparisonOutcome(
                    backend="webgpu",
                    status="deferred",
                    detail="backend pending",
                ),
            ],
            rejection_reasons=[],
            lowering_identity=identity,
        )
        doc = receipt.to_json()
        self.assertIn("loweringIdentity", doc)
        doe_parity.validate_receipt_doc(doc)
        self.assertNotIn("pass", {row["status"] for row in doc["comparisons"]})

    def test_manifest_lowering_exactness_mismatch_rejects(self) -> None:
        fixture = (
            REPO_ROOT
            / "bench"
            / "fixtures"
            / "tsir-manifest-entries"
            / "fused_gemv.webgpu-generic.json"
        )
        with self.assertRaisesRegex(ValueError, "exactness class"):
            doe_parity.lowering_identity_from_manifest_entry(
                fixture,
                "bit_exact_solo",
            )

    def test_extract_rejection_reasons_deduplicates_and_validates(self) -> None:
        reasons = doe_parity.extract_rejection_reasons(
            {
                "rejections": [
                    {"reason": "tsir_target_unfit"},
                    {"reason": "tsir_target_unfit"},
                ]
            },
            {
                "rejections": [
                    {"reason": "tsir_collective_not_representable"},
                ]
            },
        )
        self.assertEqual(
            reasons,
            ["tsir_target_unfit", "tsir_collective_not_representable"],
        )

    def test_extract_rejection_reasons_rejects_unknown_reason(self) -> None:
        with self.assertRaises(ValueError):
            doe_parity.extract_rejection_reasons(
                {"rejections": [{"reason": "looks_fine"}]},
                {"rejections": []},
            )


def _write_doppler_transcript(
    tmp_path: Path,
    execution_graph_hash: str = "sha256:" + "a" * 64,
    source_hash: str = "sha256:" + "b" * 64,
) -> Path:
    path = tmp_path / "reference-transcript.json"
    doc = {
        "schema": doe_parity.REFERENCE_TRANSCRIPT_SCHEMA_ID,
        "executionGraphHash": execution_graph_hash,
        "source": {
            "kind": "browser-report",
            "path": "inline",
            "hash": source_hash,
        },
        "prompt": {"identity": "The color of the sky is"},
        "output": {"tokensGenerated": 1, "stopReason": "max_tokens"},
        "tokens": {"ids": [1]},
    }
    path.write_text(json.dumps(doc), encoding="utf-8")
    return path


class TestReferenceSourceInversion(unittest.TestCase):
    """Move 1: parity CLI routes real kernels to Doppler transcripts."""

    def test_doppler_transcript_rejects_invalid_schema(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "bad.json"
            path.write_text(json.dumps({"schema": "wrong"}), encoding="utf-8")
            with self.assertRaises(doe_parity.DopplerTranscriptInvalid):
                doe_parity.load_doppler_transcript(path)

    def test_doppler_transcript_requires_execution_graph_hash(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "bad.json"
            path.write_text(
                json.dumps(
                    {
                        "schema": doe_parity.REFERENCE_TRANSCRIPT_SCHEMA_ID,
                        "source": {"hash": "sha256:" + "0" * 64},
                    }
                ),
                encoding="utf-8",
            )
            with self.assertRaises(doe_parity.DopplerTranscriptInvalid):
                doe_parity.load_doppler_transcript(path)

    def test_doppler_reference_without_probe_defers(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            transcript = _write_doppler_transcript(Path(tmp))
            outcome, source = doe_parity.run_doppler_reference(
                "attn_head256",
                rejection_reasons=None,
                transcript_path=transcript,
                probe_hash=None,
            )
        self.assertEqual(outcome.status, "not_implemented")
        self.assertIsNone(outcome.backend_hash)
        self.assertEqual(source.kind, doe_parity.REFERENCE_SOURCE_DOPPLER)
        self.assertEqual(source.execution_graph_hash, "sha256:" + "a" * 64)
        self.assertEqual(source.source_hash, "sha256:" + "b" * 64)

    def test_doppler_reference_with_probe_passes(self) -> None:
        probe_hash = "c" * 64
        with tempfile.TemporaryDirectory() as tmp:
            transcript = _write_doppler_transcript(Path(tmp))
            outcome, source = doe_parity.run_doppler_reference(
                "attn_head256",
                rejection_reasons=None,
                transcript_path=transcript,
                probe_hash=probe_hash,
            )
        self.assertEqual(outcome.status, "pass")
        self.assertEqual(outcome.backend_hash, probe_hash)
        self.assertEqual(source.kind, doe_parity.REFERENCE_SOURCE_DOPPLER)

    def test_doppler_reference_rejects_malformed_probe(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            transcript = _write_doppler_transcript(Path(tmp))
            with self.assertRaises(doe_parity.DopplerTranscriptInvalid):
                doe_parity.run_doppler_reference(
                    "attn_head256",
                    rejection_reasons=None,
                    transcript_path=transcript,
                    probe_hash="not-hex",
                )

    def test_reference_source_zig_serializes_minimally(self) -> None:
        source = doe_parity.ReferenceSource(
            kind=doe_parity.REFERENCE_SOURCE_ZIG,
        )
        self.assertEqual(source.to_json(), {"kind": "zig-tsir-oracle"})

    def test_reference_source_doppler_requires_identity_fields(self) -> None:
        source = doe_parity.ReferenceSource(
            kind=doe_parity.REFERENCE_SOURCE_DOPPLER,
        )
        with self.assertRaises(ValueError):
            source.to_json()


class TestReceiptWithReferenceSource(unittest.TestCase):
    """Receipts carry the reference-source taxonomy per the re-scope."""

    def test_receipt_embeds_doppler_reference_source(self) -> None:
        source = doe_parity.ReferenceSource(
            kind=doe_parity.REFERENCE_SOURCE_DOPPLER,
            execution_graph_hash="sha256:" + "d" * 64,
            source_hash="sha256:" + "e" * 64,
            transcript_path="/tmp/t.json",
        )
        receipt = doe_parity.ParityReceipt(
            schema_version=2,
            artifact_kind="doe_parity_receipt",
            kernel="attn_head256",
            exactness_class="tolerance_bounded",
            reference_hash=None,
            inputs_digest="0" * 64,
            comparisons=[
                doe_parity.ComparisonOutcome(
                    backend="reference",
                    status="not_implemented",
                    detail="per-kernel probe not supplied",
                ),
            ],
            rejection_reasons=[],
            reference_source=source,
        )
        doc = receipt.to_json()
        self.assertIn("referenceSource", doc)
        self.assertEqual(doc["referenceSource"]["kind"], "doppler-reference-transcript")
        self.assertEqual(
            doc["referenceSource"]["executionGraphHash"], "sha256:" + "d" * 64
        )
        # Receipt must still validate against the live schema.
        doe_parity.validate_receipt_doc(doc)

    def test_receipt_embeds_zig_reference_source(self) -> None:
        receipt = doe_parity.ParityReceipt(
            schema_version=2,
            artifact_kind="doe_parity_receipt",
            kernel="fused_gemv",
            exactness_class="algorithm_exact",
            reference_hash="0" * 64,
            inputs_digest="1" * 64,
            comparisons=[
                doe_parity.ComparisonOutcome(
                    backend="reference",
                    status="pass",
                    backend_hash="0" * 64,
                ),
            ],
            rejection_reasons=[],
            reference_source=doe_parity.ReferenceSource(
                kind=doe_parity.REFERENCE_SOURCE_ZIG,
            ),
        )
        doc = receipt.to_json()
        self.assertEqual(doc["referenceSource"], {"kind": "zig-tsir-oracle"})
        doe_parity.validate_receipt_doc(doc)


class TestCslRunnerResolution(unittest.TestCase):
    """Pin _resolve_csl_runner's preference order.

    The canary lane prefers the TSIR-emit runner pair
    (_tsir_sim_runner.py + csl-real-canary-compile-tsir/<kernel>/<kernel>/)
    over the hand-authored pair (_sim_runner.py + csl-real-canary-compile/
    <kernel>/<kernel>/) when both are present, so the attention-canary attention
    canary actually exercises the TSIR-CSL emit body. Hand-authored
    stays as the fallback for kernels without a TSIR-emit runner or
    when the TSIR compile-dir hasn't been materialized in this
    environment.
    """

    def _layout_runners(
        self, root: Path, kernel: str, *, tsir: bool, handauth: bool
    ) -> Path:
        runners_root = root / "runners"
        runners_root.mkdir(parents=True, exist_ok=True)
        if tsir:
            (runners_root / f"{kernel}_tsir_sim_runner.py").write_text(
                "# stub", encoding="utf-8"
            )
        if handauth:
            (runners_root / f"{kernel}_sim_runner.py").write_text(
                "# stub", encoding="utf-8"
            )
        return runners_root

    def _layout_compile_dir(
        self, root: Path, kernel: str, *, tsir: bool, handauth: bool
    ) -> tuple[Path, Path]:
        handauth_root = root / "compile-handauth"
        tsir_root = root / "compile-tsir"
        if handauth:
            (handauth_root / kernel / kernel).mkdir(parents=True, exist_ok=True)
        if tsir:
            (tsir_root / kernel / kernel).mkdir(parents=True, exist_ok=True)
        return handauth_root, tsir_root

    def test_prefers_tsir_when_both_pairs_present(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            runners_root = self._layout_runners(
                root, "attention_head256_f16kv", tsir=True, handauth=True
            )
            handauth_root, tsir_root = self._layout_compile_dir(
                root, "attention_head256_f16kv", tsir=True, handauth=True
            )
            runner, compile_dir, route = doe_parity._resolve_csl_runner(
                "attention_head256_f16kv",
                runners_root=runners_root,
                handauth_compile_root=handauth_root,
                tsir_compile_root=tsir_root,
            )
            self.assertEqual(route, "tsir")
            self.assertEqual(runner.name, "attention_head256_f16kv_tsir_sim_runner.py")
            self.assertEqual(
                compile_dir,
                tsir_root / "attention_head256_f16kv" / "attention_head256_f16kv",
            )

    def test_falls_back_to_handauth_when_tsir_compile_dir_missing(self) -> None:
        # The TSIR runner exists but no one has run cslc against the
        # TSIR-emit source yet. The canary must keep working off the
        # hand-authored compile-dir so 24/24 doesn't regress.
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            runners_root = self._layout_runners(
                root, "attention_head512_f16kv", tsir=True, handauth=True
            )
            handauth_root, tsir_root = self._layout_compile_dir(
                root, "attention_head512_f16kv", tsir=False, handauth=True
            )
            runner, compile_dir, route = doe_parity._resolve_csl_runner(
                "attention_head512_f16kv",
                runners_root=runners_root,
                handauth_compile_root=handauth_root,
                tsir_compile_root=tsir_root,
            )
            self.assertEqual(route, "handauth")
            self.assertEqual(runner.name, "attention_head512_f16kv_sim_runner.py")
            self.assertEqual(
                compile_dir,
                handauth_root
                / "attention_head512_f16kv"
                / "attention_head512_f16kv",
            )

    def test_falls_back_to_handauth_when_no_tsir_runner(self) -> None:
        # Non-attention kernels (no TSIR-emit canary path yet) must
        # keep routing through the hand-authored pair.
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            runners_root = self._layout_runners(
                root, "rms_norm", tsir=False, handauth=True
            )
            handauth_root, tsir_root = self._layout_compile_dir(
                root, "rms_norm", tsir=False, handauth=True
            )
            runner, _, route = doe_parity._resolve_csl_runner(
                "rms_norm",
                runners_root=runners_root,
                handauth_compile_root=handauth_root,
                tsir_compile_root=tsir_root,
            )
            self.assertEqual(route, "handauth")
            self.assertEqual(runner.name, "rms_norm_sim_runner.py")

    def test_returns_handauth_paths_even_when_neither_exists(self) -> None:
        # _resolve_csl_runner does not check for handauth presence on
        # the fallback path — it returns the canonical names so the
        # caller's existence check produces a useful deferred message.
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            runners_root = root / "runners"
            runners_root.mkdir()
            handauth_root = root / "compile-handauth"
            tsir_root = root / "compile-tsir"
            runner, _, route = doe_parity._resolve_csl_runner(
                "ghost_kernel",
                runners_root=runners_root,
                handauth_compile_root=handauth_root,
                tsir_compile_root=tsir_root,
            )
            self.assertEqual(route, "handauth")
            self.assertEqual(runner.name, "ghost_kernel_sim_runner.py")
            self.assertFalse(runner.exists())


if __name__ == "__main__":
    unittest.main()
