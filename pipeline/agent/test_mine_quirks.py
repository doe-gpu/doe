#!/usr/bin/env python3
"""Tests for mine_upstream_quirks.py helper functions.

Covers schema compliance, toggle promotion, quirk ID generation,
vendor/API matching, safety class assignment, and edge cases.
Runs without Dawn source or network access.
"""

from __future__ import annotations

import hashlib
import json
import unittest
from pathlib import Path

from pipeline.agent import mine_upstream_quirks as miner

SCHEMA_PATH = Path(__file__).resolve().parent.parent.parent / "config" / "quirks.schema.json"


def _load_quirk_schema() -> dict:
    return json.loads(SCHEMA_PATH.read_text(encoding="utf-8"))


def _validate_quirk_record(record: dict) -> list[str]:
    """Lightweight check against the required fields in quirks.schema.json."""
    errors: list[str] = []
    required = [
        "schemaVersion", "quirkId", "scope", "match",
        "action", "safetyClass", "verificationMode", "proofLevel", "provenance",
    ]
    for field in required:
        if field not in record:
            errors.append(f"missing required field: {field}")

    if record.get("schemaVersion") != 2:
        errors.append(f"schemaVersion must be 2, got {record.get('schemaVersion')}")

    valid_scopes = {"alignment", "barrier", "layout", "driver_toggle", "memory"}
    if record.get("scope") not in valid_scopes:
        errors.append(f"invalid scope: {record.get('scope')}")

    match = record.get("match", {})
    if "vendor" not in match:
        errors.append("match missing vendor")
    if "api" not in match:
        errors.append("match missing api")
    valid_apis = {"vulkan", "metal", "d3d12", "webgpu"}
    if match.get("api") not in valid_apis:
        errors.append(f"invalid match.api: {match.get('api')}")

    safety = record.get("safetyClass")
    if safety not in {"low", "moderate", "high", "critical"}:
        errors.append(f"invalid safetyClass: {safety}")

    vm = record.get("verificationMode")
    if vm not in {"guard_only", "lean_preferred", "lean_required"}:
        errors.append(f"invalid verificationMode: {vm}")

    pl = record.get("proofLevel")
    if pl not in {"proven", "guarded", "rejected"}:
        errors.append(f"invalid proofLevel: {pl}")

    prov = record.get("provenance", {})
    for pf in ["sourceRepo", "sourcePath", "sourceCommit", "observedAt"]:
        if pf not in prov:
            errors.append(f"provenance missing {pf}")

    action = record.get("action", {})
    if "kind" not in action:
        errors.append("action missing kind")

    return errors


class TestSchemaCompliance(unittest.TestCase):
    """build_candidate output must conform to the quirks schema."""

    def _make_candidate(self, **overrides):
        defaults = dict(
            toggle="TestToggle",
            source_repo="dawn/main",
            source_path="src/test.cpp",
            source_commit="abc123",
            vendor="intel",
            api="vulkan",
            device_family="",
            driver_range="",
            observed_at="2026-01-01T00:00:00Z",
            toggle_context=miner.TOGGLE_CONTEXT_REFERENCE,
        )
        defaults.update(overrides)
        return miner.build_candidate(**defaults)

    def test_reference_toggle_schema(self):
        record = self._make_candidate()
        errors = _validate_quirk_record(record)
        self.assertEqual(errors, [], f"schema errors: {errors}")

    def test_promoted_toggle_schema(self):
        record = self._make_candidate(
            toggle="UseTemporaryBufferInCompressedTextureToTextureCopy",
            toggle_context=miner.TOGGLE_CONTEXT_FORCE_ON,
        )
        errors = _validate_quirk_record(record)
        self.assertEqual(errors, [], f"schema errors: {errors}")

    def test_all_api_values(self):
        for api in ["vulkan", "metal", "d3d12", "webgpu"]:
            record = self._make_candidate(api=api)
            errors = _validate_quirk_record(record)
            self.assertEqual(errors, [], f"schema errors for api={api}: {errors}")

    def test_workaround_candidate_schema(self):
        hit = miner.WorkaroundHit(
            root=Path("/fake"),
            source_path=Path("/fake/src/test.cpp"),
            line=42,
            category=miner.WORKAROUND_CATEGORY_LIMIT,
            vendor="intel",
            detail="maxBufferSize",
        )
        record = miner.build_workaround_candidate(
            hit=hit,
            source_repo="dawn/main",
            source_commit="abc123",
            api="vulkan",
            observed_at="2026-01-01T00:00:00Z",
        )
        errors = _validate_quirk_record(record)
        self.assertEqual(errors, [], f"schema errors: {errors}")

    def test_workaround_no_op_action(self):
        hit = miner.WorkaroundHit(
            root=Path("/fake"),
            source_path=Path("/fake/src/test.cpp"),
            line=10,
            category=miner.WORKAROUND_CATEGORY_FEATURE_GUARD,
            vendor="amd",
            detail="enable_SomeFeature",
        )
        record = miner.build_workaround_candidate(
            hit=hit,
            source_repo="dawn/main",
            source_commit="abc123",
            api="vulkan",
            observed_at="2026-01-01T00:00:00Z",
        )
        self.assertEqual(record["action"], {"kind": "no_op"})


class TestTogglePromotionLookup(unittest.TestCase):
    """TOGGLE_PROMOTIONS table maps known toggles to expected actions."""

    def test_known_toggle_force_on_promotes(self):
        result = miner.lookup_toggle_promotion(
            "UseTemporaryBufferInCompressedTextureToTextureCopy",
            miner.TOGGLE_CONTEXT_FORCE_ON,
        )
        self.assertIsNotNone(result)
        self.assertEqual(result["action"]["kind"], "use_temporary_buffer")
        self.assertEqual(result["scope"], "alignment")
        self.assertEqual(result["safetyClass"], "high")

    def test_known_toggle_default_on_promotes(self):
        result = miner.lookup_toggle_promotion(
            "UseTemporaryBufferInCompressedTextureToTextureCopy",
            miner.TOGGLE_CONTEXT_DEFAULT_ON,
        )
        self.assertIsNotNone(result)

    def test_known_toggle_reference_does_not_promote(self):
        result = miner.lookup_toggle_promotion(
            "UseTemporaryBufferInCompressedTextureToTextureCopy",
            miner.TOGGLE_CONTEXT_REFERENCE,
        )
        self.assertIsNone(result)

    def test_known_toggle_force_off_does_not_promote(self):
        result = miner.lookup_toggle_promotion(
            "UseTemporaryBufferInCompressedTextureToTextureCopy",
            miner.TOGGLE_CONTEXT_FORCE_OFF,
        )
        self.assertIsNone(result)

    def test_known_toggle_default_off_does_not_promote(self):
        result = miner.lookup_toggle_promotion(
            "UseTemporaryBufferInCompressedTextureToTextureCopy",
            miner.TOGGLE_CONTEXT_DEFAULT_OFF,
        )
        self.assertIsNone(result)

    def test_unknown_toggle_returns_none(self):
        result = miner.lookup_toggle_promotion(
            "CompletelyUnknownToggle",
            miner.TOGGLE_CONTEXT_FORCE_ON,
        )
        self.assertIsNone(result)

    def test_metal_render_toggle_promotes(self):
        result = miner.lookup_toggle_promotion(
            "MetalRenderR8RG8UnormSmallMipToTempTexture",
            miner.TOGGLE_CONTEXT_DEFAULT_ON,
        )
        self.assertIsNotNone(result)
        self.assertEqual(result["action"]["kind"], "use_temporary_render_texture")
        self.assertEqual(result["scope"], "layout")

    def test_d3d12_depth_stencil_toggle(self):
        result = miner.lookup_toggle_promotion(
            "D3D12UseTempBufferInDepthStencilTextureAndBufferCopyWithNonZeroBufferOffset",
            miner.TOGGLE_CONTEXT_FORCE_ON,
        )
        self.assertIsNotNone(result)
        self.assertEqual(result["action"]["kind"], "use_temporary_buffer")

    def test_all_promotion_entries_have_required_fields(self):
        for toggle_key, entry in miner.TOGGLE_PROMOTIONS.items():
            self.assertIn("scope", entry, f"missing scope in {toggle_key}")
            self.assertIn("safetyClass", entry, f"missing safetyClass in {toggle_key}")
            self.assertIn("action", entry, f"missing action in {toggle_key}")
            self.assertIn("kind", entry["action"], f"missing action.kind in {toggle_key}")

    def test_promotion_normalizes_case_and_underscores(self):
        # The lookup normalizes by lowering and stripping non-alnum
        result = miner.lookup_toggle_promotion(
            "Use_Temporary_Buffer_In_Compressed_Texture_To_Texture_Copy",
            miner.TOGGLE_CONTEXT_FORCE_ON,
        )
        self.assertIsNotNone(result)


class TestQuirkIdGeneration(unittest.TestCase):
    """QuirkId generation must be deterministic."""

    def test_same_input_same_id(self):
        id1 = miner.candidate_quirk_id(
            vendor="intel", api="vulkan",
            toggle="Foo", source_path="src/a.cpp",
        )
        id2 = miner.candidate_quirk_id(
            vendor="intel", api="vulkan",
            toggle="Foo", source_path="src/a.cpp",
        )
        self.assertEqual(id1, id2)

    def test_different_toggle_different_id(self):
        id1 = miner.candidate_quirk_id(
            vendor="intel", api="vulkan",
            toggle="Foo", source_path="src/a.cpp",
        )
        id2 = miner.candidate_quirk_id(
            vendor="intel", api="vulkan",
            toggle="Bar", source_path="src/a.cpp",
        )
        self.assertNotEqual(id1, id2)

    def test_different_vendor_different_id(self):
        id1 = miner.candidate_quirk_id(
            vendor="intel", api="vulkan",
            toggle="Foo", source_path="src/a.cpp",
        )
        id2 = miner.candidate_quirk_id(
            vendor="amd", api="vulkan",
            toggle="Foo", source_path="src/a.cpp",
        )
        self.assertNotEqual(id1, id2)

    def test_different_source_path_different_id(self):
        id1 = miner.candidate_quirk_id(
            vendor="intel", api="vulkan",
            toggle="Foo", source_path="src/a.cpp",
        )
        id2 = miner.candidate_quirk_id(
            vendor="intel", api="vulkan",
            toggle="Foo", source_path="src/b.cpp",
        )
        self.assertNotEqual(id1, id2)

    def test_id_prefix_format(self):
        qid = miner.candidate_quirk_id(
            vendor="intel", api="vulkan",
            toggle="TestToggle", source_path="src/a.cpp",
        )
        self.assertTrue(qid.startswith("auto.intel.vulkan.toggle.testtoggle."))

    def test_workaround_quirk_id_deterministic(self):
        id1 = miner.workaround_quirk_id(
            vendor="amd", api="vulkan",
            category="limit_override", detail="maxBufferSize",
            source_path="src/test.cpp",
        )
        id2 = miner.workaround_quirk_id(
            vendor="amd", api="vulkan",
            category="limit_override", detail="maxBufferSize",
            source_path="src/test.cpp",
        )
        self.assertEqual(id1, id2)

    def test_workaround_quirk_id_prefix(self):
        qid = miner.workaround_quirk_id(
            vendor="nvidia", api="d3d12",
            category="alignment", detail="align_256",
            source_path="src/test.cpp",
        )
        self.assertTrue(qid.startswith("auto.nvidia.d3d12.alignment.align_256."))

    def test_id_min_length(self):
        """Schema requires quirkId minLength: 3."""
        qid = miner.candidate_quirk_id(
            vendor="x", api="vulkan",
            toggle="Y", source_path="z",
        )
        self.assertGreaterEqual(len(qid), 3)


class TestVendorApiMatching(unittest.TestCase):
    """Match spec construction and vendor normalization."""

    def test_minimal_match(self):
        match = miner.build_match_object(
            vendor="intel", api="vulkan",
            device_family="", driver_range="",
        )
        self.assertEqual(match, {"vendor": "intel", "api": "vulkan"})

    def test_match_with_device_family(self):
        match = miner.build_match_object(
            vendor="amd", api="d3d12",
            device_family="RDNA2", driver_range="",
        )
        self.assertEqual(match["deviceFamily"], "RDNA2")
        self.assertNotIn("driverRange", match)

    def test_match_with_driver_range(self):
        match = miner.build_match_object(
            vendor="nvidia", api="vulkan",
            device_family="", driver_range=">=525.0",
        )
        self.assertEqual(match["driverRange"], ">=525.0")
        self.assertNotIn("deviceFamily", match)

    def test_match_with_all_fields(self):
        match = miner.build_match_object(
            vendor="qualcomm", api="vulkan",
            device_family="Adreno7xx", driver_range=">=42",
        )
        self.assertEqual(match["vendor"], "qualcomm")
        self.assertEqual(match["api"], "vulkan")
        self.assertEqual(match["deviceFamily"], "Adreno7xx")
        self.assertEqual(match["driverRange"], ">=42")

    def test_normalize_vendor_known(self):
        self.assertEqual(miner.normalize_vendor("Intel"), "intel")
        self.assertEqual(miner.normalize_vendor("AMD"), "amd")
        self.assertEqual(miner.normalize_vendor("NVIDIA"), "nvidia")
        self.assertEqual(miner.normalize_vendor("Qualcomm"), "qualcomm")
        self.assertEqual(miner.normalize_vendor("ARM"), "arm")
        self.assertEqual(miner.normalize_vendor("Mali"), "arm")
        self.assertEqual(miner.normalize_vendor("SwiftShader"), "google")

    def test_normalize_vendor_unknown(self):
        self.assertIsNone(miner.normalize_vendor("UnknownVendorXYZ"))

    def test_normalize_vendor_gen_variants(self):
        self.assertEqual(miner.normalize_vendor("IntelGen9"), "intel")
        self.assertEqual(miner.normalize_vendor("IntelGen12LP"), "intel")
        self.assertEqual(miner.normalize_vendor("IntelGen12"), "intel")

    def test_detect_vendor_on_line_gpu_info(self):
        line = "if (gpu_info::IsIntel(vendorId)) {"
        self.assertEqual(miner.detect_vendor_on_line(line), "intel")

    def test_detect_vendor_on_line_mesa(self):
        line = "if (IsAMDMesa()) {"
        self.assertEqual(miner.detect_vendor_on_line(line), "amd")

    def test_detect_vendor_on_line_none(self):
        line = "int x = 42;"
        self.assertIsNone(miner.detect_vendor_on_line(line))


class TestSafetyClassAssignment(unittest.TestCase):
    """Safety class logic for different quirk types."""

    def test_reference_toggle_moderate(self):
        record = miner.build_candidate(
            toggle="SomeToggle",
            source_repo="dawn/main",
            source_path="src/test.cpp",
            source_commit="abc",
            vendor="intel",
            api="vulkan",
            device_family="",
            driver_range="",
            observed_at="2026-01-01T00:00:00Z",
            toggle_context=miner.TOGGLE_CONTEXT_REFERENCE,
        )
        self.assertEqual(record["safetyClass"], "moderate")

    def test_promoted_toggle_safety_class(self):
        record = miner.build_candidate(
            toggle="UseTemporaryBufferInCompressedTextureToTextureCopy",
            source_repo="dawn/main",
            source_path="src/test.cpp",
            source_commit="abc",
            vendor="intel",
            api="vulkan",
            device_family="",
            driver_range="",
            observed_at="2026-01-01T00:00:00Z",
            toggle_context=miner.TOGGLE_CONTEXT_FORCE_ON,
        )
        self.assertEqual(record["safetyClass"], "high")

    def test_unpromoted_toggle_defaults_moderate(self):
        record = miner.build_candidate(
            toggle="UnknownNewToggle",
            source_repo="dawn/main",
            source_path="src/test.cpp",
            source_commit="abc",
            vendor="intel",
            api="vulkan",
            device_family="",
            driver_range="",
            observed_at="2026-01-01T00:00:00Z",
            toggle_context=miner.TOGGLE_CONTEXT_FORCE_ON,
        )
        self.assertEqual(record["safetyClass"], "moderate")
        self.assertEqual(record["scope"], "driver_toggle")

    def test_workaround_safety_class_moderate(self):
        for cat in [
            miner.WORKAROUND_CATEGORY_LIMIT,
            miner.WORKAROUND_CATEGORY_ALIGNMENT,
            miner.WORKAROUND_CATEGORY_FEATURE_GUARD,
        ]:
            hit = miner.WorkaroundHit(
                root=Path("/fake"),
                source_path=Path("/fake/src/test.cpp"),
                line=1,
                category=cat,
                vendor="intel",
                detail="test_detail",
            )
            record = miner.build_workaround_candidate(
                hit=hit,
                source_repo="dawn/main",
                source_commit="abc",
                api="vulkan",
                observed_at="2026-01-01T00:00:00Z",
            )
            self.assertEqual(record["safetyClass"], "moderate", f"cat={cat}")


class TestEdgeCases(unittest.TestCase):
    """Edge cases: empty toggle name, unknown vendor, missing fields."""

    def test_empty_toggle_name_produces_valid_id(self):
        qid = miner.candidate_quirk_id(
            vendor="intel", api="vulkan",
            toggle="", source_path="src/a.cpp",
        )
        # Should still produce a string with the expected prefix structure
        self.assertTrue(qid.startswith("auto.intel.vulkan.toggle.."))

    def test_short_path_hash_deterministic(self):
        h1 = miner.short_path_hash("src/foo.cpp")
        h2 = miner.short_path_hash("src/foo.cpp")
        self.assertEqual(h1, h2)
        self.assertEqual(len(h1), 10)

    def test_short_path_hash_different_paths(self):
        h1 = miner.short_path_hash("src/foo.cpp")
        h2 = miner.short_path_hash("src/bar.cpp")
        self.assertNotEqual(h1, h2)

    def test_normalize_suffixes_empty(self):
        result = miner.normalize_suffixes([])
        self.assertEqual(result, miner.DEFAULT_ALLOWED_SUFFIXES)

    def test_normalize_suffixes_custom(self):
        result = miner.normalize_suffixes([".cc", "hpp"])
        self.assertIn(".cc", result)
        self.assertIn(".hpp", result)
        self.assertNotIn(".zig", result)

    def test_normalize_suffixes_strips_whitespace(self):
        result = miner.normalize_suffixes(["  .cc  ", "  "])
        self.assertIn(".cc", result)

    def test_canonical_json_stable(self):
        val = {"b": 2, "a": 1}
        j1 = miner.canonical_json(val)
        j2 = miner.canonical_json(val)
        self.assertEqual(j1, j2)
        # Keys sorted
        self.assertEqual(j1, '{"a":1,"b":2}')

    def test_build_hash_chain_empty(self):
        chain = miner.build_hash_chain([])
        self.assertEqual(chain["rowCount"], 0)
        self.assertEqual(chain["finalHash"], miner.HASH_SEED)
        self.assertEqual(chain["rows"], [])

    def test_build_hash_chain_single(self):
        candidates = [{"quirkId": "test.1"}]
        chain = miner.build_hash_chain(candidates)
        self.assertEqual(chain["rowCount"], 1)
        self.assertNotEqual(chain["finalHash"], miner.HASH_SEED)
        self.assertEqual(chain["rows"][0]["previousHash"], miner.HASH_SEED)

    def test_build_hash_chain_deterministic(self):
        candidates = [{"quirkId": "a"}, {"quirkId": "b"}]
        chain1 = miner.build_hash_chain(candidates)
        chain2 = miner.build_hash_chain(candidates)
        self.assertEqual(chain1["finalHash"], chain2["finalHash"])

    def test_build_hash_chain_linked(self):
        candidates = [{"quirkId": "a"}, {"quirkId": "b"}, {"quirkId": "c"}]
        chain = miner.build_hash_chain(candidates)
        rows = chain["rows"]
        for i in range(1, len(rows)):
            self.assertEqual(rows[i]["previousHash"], rows[i - 1]["hash"])

    def test_bool_token_to_context(self):
        self.assertEqual(
            miner._bool_token_to_context("true", "on", "off"), "on"
        )
        self.assertEqual(
            miner._bool_token_to_context("false", "on", "off"), "off"
        )
        self.assertEqual(
            miner._bool_token_to_context("1", "on", "off"), "on"
        )
        self.assertEqual(
            miner._bool_token_to_context("0", "on", "off"), "off"
        )

    def test_find_nearby_bug_ref(self):
        lines = [
            "// some code",
            "// crbug.com/12345",
            "limits->maxBufferSize = 256;",
            "// more code",
        ]
        self.assertEqual(miner.find_nearby_bug_ref(lines, 2), "crbug.com/12345")

    def test_find_nearby_bug_ref_none(self):
        lines = ["int x = 1;", "int y = 2;", "int z = 3;"]
        self.assertEqual(miner.find_nearby_bug_ref(lines, 1), "")

    def test_category_to_scope_mapping(self):
        self.assertEqual(miner.CATEGORY_TO_SCOPE["limit_override"], "memory")
        self.assertEqual(miner.CATEGORY_TO_SCOPE["alignment"], "alignment")
        self.assertEqual(miner.CATEGORY_TO_SCOPE["feature_guard"], "driver_toggle")


class TestToggleExtraction(unittest.TestCase):
    """Test extraction of toggle hits from source text using temp files."""

    def test_extract_toggle_reference(self, tmp_path=None):
        import tempfile
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            src = root / "test.cpp"
            src.write_text("if (Toggle::FooBar) {}\n", encoding="utf-8")
            hits = miner.extract_toggle_hits(root=root, candidate_files=[src])
            self.assertEqual(len(hits), 1)
            self.assertEqual(hits[0].toggle, "FooBar")
            self.assertEqual(hits[0].toggle_context, miner.TOGGLE_CONTEXT_REFERENCE)

    def test_extract_toggle_default_on(self):
        import tempfile
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            src = root / "test.cpp"
            src.write_text("->Default(Toggle::MyToggle, true)\n", encoding="utf-8")
            hits = miner.extract_toggle_hits(root=root, candidate_files=[src])
            self.assertEqual(len(hits), 1)
            self.assertEqual(hits[0].toggle, "MyToggle")
            self.assertEqual(hits[0].toggle_context, miner.TOGGLE_CONTEXT_DEFAULT_ON)

    def test_extract_toggle_force_enable(self):
        import tempfile
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            src = root / "test.cpp"
            src.write_text("->ForceEnable(Toggle::Robust)\n", encoding="utf-8")
            hits = miner.extract_toggle_hits(root=root, candidate_files=[src])
            self.assertEqual(len(hits), 1)
            self.assertEqual(hits[0].toggle, "Robust")
            self.assertEqual(hits[0].toggle_context, miner.TOGGLE_CONTEXT_FORCE_ON)

    def test_extract_toggle_force_disable(self):
        import tempfile
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            src = root / "test.cpp"
            src.write_text("->ForceDisable(Toggle::Broken)\n", encoding="utf-8")
            hits = miner.extract_toggle_hits(root=root, candidate_files=[src])
            self.assertEqual(len(hits), 1)
            self.assertEqual(hits[0].toggle, "Broken")
            self.assertEqual(hits[0].toggle_context, miner.TOGGLE_CONTEXT_FORCE_OFF)

    def test_extract_toggle_deduplicates_same_line(self):
        import tempfile
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            src = root / "test.cpp"
            # ForceSet consumes the Toggle:: match so only one hit should appear
            src.write_text("->ForceSet(Toggle::X, true)\n", encoding="utf-8")
            hits = miner.extract_toggle_hits(root=root, candidate_files=[src])
            self.assertEqual(len(hits), 1)
            self.assertEqual(hits[0].toggle_context, miner.TOGGLE_CONTEXT_FORCE_ON)


if __name__ == "__main__":
    unittest.main()
