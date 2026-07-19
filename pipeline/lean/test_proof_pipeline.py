"""End-to-end tests for the Lean proof pipeline artifact.

Pipeline flow:
  1. Lean source in pipeline/lean/Doe/*.lean
  2. Extract script: pipeline/lean/extract.sh
  3. Produces: pipeline/lean/artifacts/proven-conditions.json
  4. Schema: config/proof-artifact.schema.json
  5. Consumed by: runtime/zig/src/verification/lean_proof.zig at comptime via build.zig
"""

import json
import hashlib
import stat
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
ARTIFACT_PATH = REPO_ROOT / "pipeline" / "lean" / "artifacts" / "proven-conditions.json"
SCHEMA_PATH = REPO_ROOT / "config" / "proof-artifact.schema.json"
PATTERN_SPEC_PATH = REPO_ROOT / "config" / "lean-proof-patterns.json"
EXTRACT_SCRIPT = REPO_ROOT / "pipeline" / "lean" / "extract.sh"
LEAN_SOURCE_DIR = REPO_ROOT / "pipeline" / "lean" / "Doe"

# Categories defined in the schema enum.
SCHEMA_CATEGORIES = {
    "tautological",
    "comptime_verified",
    "lean_verified",
    "lean_fixture",
    "lean_required",
}

# Categories observed in practice (must match schema).
KNOWN_CATEGORIES = SCHEMA_CATEGORIES


def _load_artifact():
    with open(ARTIFACT_PATH) as f:
        return json.load(f)


def _load_schema():
    with open(SCHEMA_PATH) as f:
        return json.load(f)


def _load_pattern_spec():
    with open(PATTERN_SPEC_PATH) as f:
        return json.load(f)


def _sha256_file(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _sha256_lean_tree(root: Path) -> str:
    digest = hashlib.sha256()
    for path in sorted(root.rglob("*.lean")):
        relative = path.relative_to(REPO_ROOT).as_posix()
        digest.update(relative.encode("utf-8"))
        digest.update(b"\n")
        digest.update(path.read_bytes())
        digest.update(b"\n")
    return digest.hexdigest()


def _load_lean_toolchain_ref() -> str:
    with open(REPO_ROOT / "config" / "toolchains.json") as f:
        toolchains = json.load(f)
    version = toolchains["toolchains"]["lean"]["version"]
    return f"leanprover/lean4:{version}" if version.startswith("v") else f"leanprover/lean4:v{version}"


class TestArtifactExistsAndValid(unittest.TestCase):
    """Artifact exists and is valid JSON."""

    def test_artifact_file_exists(self):
        self.assertTrue(
            ARTIFACT_PATH.exists(),
            f"Artifact not found at {ARTIFACT_PATH}",
        )

    def test_artifact_parses_as_json(self):
        artifact = _load_artifact()
        self.assertIsInstance(artifact, dict)

    def test_artifact_nonempty(self):
        self.assertGreater(
            ARTIFACT_PATH.stat().st_size,
            2,
            "Artifact file is empty or trivially small",
        )


class TestArtifactMatchesSchema(unittest.TestCase):
    """Validate artifact against config/proof-artifact.schema.json."""

    def setUp(self):
        self.artifact = _load_artifact()
        self.schema = _load_schema()

    def test_schema_file_exists(self):
        self.assertTrue(
            SCHEMA_PATH.exists(),
            f"Schema not found at {SCHEMA_PATH}",
        )

    def test_all_required_top_level_fields_present(self):
        required = self.schema.get("required", [])
        for field in required:
            self.assertIn(
                field,
                self.artifact,
                f"Required top-level field '{field}' missing from artifact",
            )

    def test_schema_version_matches(self):
        expected = self.schema["properties"]["schemaVersion"].get("const")
        if expected is not None:
            self.assertEqual(self.artifact["schemaVersion"], expected)

    def test_status_is_valid_enum(self):
        allowed = self.schema["properties"]["status"]["enum"]
        self.assertIn(self.artifact["status"], allowed)

    def test_no_extra_top_level_fields(self):
        if self.schema.get("additionalProperties") is False:
            allowed_keys = set(self.schema["properties"].keys())
            actual_keys = set(self.artifact.keys())
            extra = actual_keys - allowed_keys
            self.assertFalse(
                extra,
                f"Unexpected top-level fields: {extra}",
            )

    def test_jsonschema_full_validation(self):
        """Full jsonschema validation if the library is available."""
        try:
            import jsonschema
        except ImportError:
            self.skipTest("jsonschema library not installed; skipping full validation")
        try:
            jsonschema.validate(instance=self.artifact, schema=self.schema)
        except jsonschema.ValidationError as exc:
            self.fail(f"Artifact fails schema validation: {exc.message}")


class TestRequiredFields(unittest.TestCase):
    """Each theorem entry has the required fields per schema."""

    def setUp(self):
        self.artifact = _load_artifact()
        self.schema = _load_schema()

    def test_theorems_have_required_fields(self):
        theorem_schema = self.schema["properties"]["theorems"]["items"]
        required = theorem_schema.get("required", [])
        for i, thm in enumerate(self.artifact["theorems"]):
            for field in required:
                self.assertIn(
                    field,
                    thm,
                    f"Theorem [{i}] ({thm.get('name', '?')}) missing required field '{field}'",
                )

    def test_theorem_fields_are_strings(self):
        for i, thm in enumerate(self.artifact["theorems"]):
            for key in ("name", "module", "category"):
                if key in thm:
                    self.assertIsInstance(
                        thm[key],
                        str,
                        f"Theorem [{i}] field '{key}' is not a string",
                    )

    def test_elimination_targets_have_required_fields(self):
        et_schema = self.schema["properties"]["eliminationTargets"]["items"]
        required = et_schema.get("required", [])
        for i, et in enumerate(self.artifact.get("eliminationTargets", [])):
            for field in required:
                self.assertIn(
                    field,
                    et,
                    f"eliminationTargets[{i}] missing required field '{field}'",
                )


class TestCategoriesValid(unittest.TestCase):
    """All categories are from the known set."""

    def test_all_categories_known(self):
        artifact = _load_artifact()
        for i, thm in enumerate(artifact["theorems"]):
            self.assertIn(
                thm["category"],
                KNOWN_CATEGORIES,
                f"Theorem [{i}] ({thm['name']}) has unknown category '{thm['category']}'",
            )

    def test_categories_match_schema_enum(self):
        """Strict check: every category appears in the schema enum."""
        artifact = _load_artifact()
        schema = _load_schema()
        schema_enum = set(
            schema["properties"]["theorems"]["items"]["properties"]["category"]["enum"]
        )
        found_categories = {thm["category"] for thm in artifact["theorems"]}
        extra = found_categories - schema_enum
        self.assertFalse(
            extra,
            f"Artifact uses categories not in schema enum: {extra}",
        )


class TestBlockingTheoremsHaveProofs(unittest.TestCase):
    """Any theorem with isBlocking=true must have adequate proof level.

    The current artifact does not embed per-theorem isBlocking / proofLevel
    fields. This test checks that lean_required theorems appear in the
    artifact with status=verified, which is the current blocking gate.
    """

    def test_lean_required_theorems_in_verified_artifact(self):
        artifact = _load_artifact()
        self.assertEqual(
            artifact["status"],
            "verified",
            "Artifact status is not 'verified'; blocking theorems may not be proven",
        )
        lean_required = [
            thm for thm in artifact["theorems"] if thm["category"] == "lean_required"
        ]
        # lean_required theorems exist and are non-empty
        self.assertGreater(
            len(lean_required),
            0,
            "No lean_required theorems found in artifact",
        )

    def test_lean_verified_theorems_present(self):
        artifact = _load_artifact()
        lean_verified = [
            thm for thm in artifact["theorems"] if thm["category"] == "lean_verified"
        ]
        self.assertGreater(
            len(lean_verified),
            0,
            "No lean_verified theorems found in artifact",
        )


class TestContractHashes(unittest.TestCase):
    """If contractHashes field exists, verify it's a dict of hex strings."""

    def setUp(self):
        self.artifact = _load_artifact()

    def test_contract_hashes_is_dict(self):
        hashes = self.artifact.get("contractHashes")
        if hashes is None:
            self.skipTest("No contractHashes field in artifact")
        self.assertIsInstance(hashes, dict)

    def test_contract_hash_values_are_hex_strings(self):
        hashes = self.artifact.get("contractHashes")
        if hashes is None:
            self.skipTest("No contractHashes field in artifact")
        import re

        hex_pattern = re.compile(r"^[0-9a-f]{64}$")
        for key, value in hashes.items():
            self.assertIsInstance(
                value,
                str,
                f"contractHashes['{key}'] is not a string",
            )
            self.assertRegex(
                value,
                hex_pattern,
                f"contractHashes['{key}'] is not a 64-char lowercase hex string",
            )

    def test_required_contract_hash_present(self):
        """Schema requires comparabilityObligationsSha256."""
        hashes = self.artifact.get("contractHashes")
        if hashes is None:
            self.skipTest("No contractHashes field in artifact")
        self.assertIn(
            "comparabilityObligationsSha256",
            hashes,
            "Required hash 'comparabilityObligationsSha256' missing",
        )


class TestProvenance(unittest.TestCase):
    """Artifact provenance must match the current Lean tree and toolchain contract."""

    def setUp(self):
        self.artifact = _load_artifact()
        self.provenance = self.artifact.get("provenance", {})

    def test_provenance_is_dict(self):
        self.assertIsInstance(self.provenance, dict)

    def test_provenance_hash_fields_are_hex(self):
        import re

        hex_pattern = re.compile(r"^[0-9a-f]{64}$")
        for key in (
            "extractProgramSha256",
            "leanSourceTreeSha256",
            "generatedComparabilityContractSha256",
            "proofPatternSpecSha256",
        ):
            self.assertIn(key, self.provenance, f"Missing provenance field '{key}'")
            self.assertRegex(
                self.provenance[key],
                hex_pattern,
                f"provenance['{key}'] is not a 64-char lowercase hex string",
            )

    def test_lean_toolchain_ref_matches_current_config(self):
        self.assertEqual(
            self.provenance.get("leanToolchainRef"),
            _load_lean_toolchain_ref(),
            "Artifact Lean toolchain ref does not match config/toolchains.json",
        )

    def test_extract_program_hash_matches_current_source(self):
        self.assertEqual(
            self.provenance.get("extractProgramSha256"),
            _sha256_file(REPO_ROOT / "pipeline" / "lean" / "Doe" / "Extract.lean"),
            "Artifact extractProgramSha256 is stale",
        )

    def test_generated_contract_hash_matches_current_source(self):
        self.assertEqual(
            self.provenance.get("generatedComparabilityContractSha256"),
            _sha256_file(
                REPO_ROOT / "pipeline" / "lean" / "Doe" / "Generated" / "ComparabilityContract.lean"
            ),
            "Artifact generatedComparabilityContractSha256 is stale",
        )

    def test_proof_pattern_spec_hash_matches_current_source(self):
        self.assertEqual(
            self.provenance.get("proofPatternSpecSha256"),
            _sha256_file(PATTERN_SPEC_PATH),
            "Artifact proofPatternSpecSha256 is stale",
        )

    def test_lean_source_tree_hash_matches_current_tree(self):
        self.assertEqual(
            self.provenance.get("leanSourceTreeSha256"),
            _sha256_lean_tree(LEAN_SOURCE_DIR),
            "Artifact leanSourceTreeSha256 does not match the current Lean source tree",
        )


class TestBoundsEliminations(unittest.TestCase):
    """If boundsEliminations array exists, verify each entry has required fields."""

    def setUp(self):
        self.artifact = _load_artifact()
        self.schema = _load_schema()

    def test_bounds_eliminations_is_list(self):
        be = self.artifact.get("boundsEliminations")
        if be is None:
            self.skipTest("No boundsEliminations field in artifact")
        self.assertIsInstance(be, list)

    def test_bounds_elimination_required_fields(self):
        be = self.artifact.get("boundsEliminations")
        if not be:
            self.skipTest("boundsEliminations is empty or absent")
        schema_required = self.schema["properties"]["boundsEliminations"]["items"].get(
            "required", []
        )
        for i, entry in enumerate(be):
            for field in schema_required:
                self.assertIn(
                    field,
                    entry,
                    f"boundsEliminations[{i}] missing required field '{field}'",
                )

    def test_bounds_elimination_fields_are_strings(self):
        be = self.artifact.get("boundsEliminations")
        if not be:
            self.skipTest("boundsEliminations is empty or absent")
        string_fields = ["theorem", "pattern", "precondition", "eliminates", "runtimePath"]
        for i, entry in enumerate(be):
            for field in string_fields:
                if field in entry:
                    self.assertIsInstance(
                        entry[field],
                        str,
                        f"boundsEliminations[{i}]['{field}'] is not a string",
                    )

    def test_bounds_elimination_theorems_exist_in_theorems_list(self):
        """Every boundsElimination theorem should appear in the theorems array."""
        be = self.artifact.get("boundsEliminations")
        if not be:
            self.skipTest("boundsEliminations is empty or absent")
        theorem_names = {thm["name"] for thm in self.artifact.get("theorems", [])}
        for i, entry in enumerate(be):
            self.assertIn(
                entry["theorem"],
                theorem_names,
                f"boundsEliminations[{i}] theorem '{entry['theorem']}' "
                "not found in theorems array",
            )


class TestNoDuplicateQuirkIds(unittest.TestCase):
    """All theorem names (the quirkId equivalent) are unique."""

    def test_theorem_names_unique(self):
        artifact = _load_artifact()
        names = [thm["name"] for thm in artifact["theorems"]]
        seen = set()
        duplicates = []
        for name in names:
            if name in seen:
                duplicates.append(name)
            seen.add(name)
        self.assertFalse(
            duplicates,
            f"Duplicate theorem names: {duplicates}",
        )

    def test_elimination_target_theorems_unique(self):
        artifact = _load_artifact()
        et_theorems = [
            et["theorem"] for et in artifact.get("eliminationTargets", [])
        ]
        seen = set()
        duplicates = []
        for name in et_theorems:
            if name in seen:
                duplicates.append(name)
            seen.add(name)
        self.assertFalse(
            duplicates,
            f"Duplicate eliminationTarget theorem names: {duplicates}",
        )


class TestLeanSourceFilesExist(unittest.TestCase):
    """For each module referenced in the artifact, verify the .lean file exists."""

    def test_theorem_modules_have_source_files(self):
        artifact = _load_artifact()
        missing = []
        for thm in artifact["theorems"]:
            module = thm["module"]
            # Convert Lean module path (Doe.Core.Model) to file path
            # (pipeline/lean/Doe/Core/Model.lean)
            rel_path = module.replace(".", "/") + ".lean"
            full_path = REPO_ROOT / "pipeline" / "lean" / rel_path
            if not full_path.exists():
                missing.append((module, str(full_path)))
        self.assertFalse(
            missing,
            f"Missing .lean source files for modules: {missing}",
        )

    def test_bounds_elimination_modules_have_source_files(self):
        artifact = _load_artifact()
        be = artifact.get("boundsEliminations", [])
        missing = []
        for entry in be:
            module = entry.get("module")
            if module is None:
                continue
            rel_path = module.replace(".", "/") + ".lean"
            full_path = REPO_ROOT / "pipeline" / "lean" / rel_path
            if not full_path.exists():
                missing.append((module, str(full_path)))
        self.assertFalse(
            missing,
            f"Missing .lean source files for boundsElimination modules: {missing}",
        )


class TestExtractScript(unittest.TestCase):
    """pipeline/lean/extract.sh is present and has +x."""

    def test_extract_script_exists(self):
        self.assertTrue(
            EXTRACT_SCRIPT.exists(),
            f"Extract script not found at {EXTRACT_SCRIPT}",
        )

    def test_extract_script_is_executable(self):
        mode = EXTRACT_SCRIPT.stat().st_mode
        self.assertTrue(
            mode & stat.S_IXUSR,
            f"Extract script is not executable (mode: {oct(mode)})",
        )

    def test_extract_script_has_shebang(self):
        with open(EXTRACT_SCRIPT, "rb") as f:
            first_line = f.readline()
        self.assertTrue(
            first_line.startswith(b"#!"),
            "Extract script does not start with a shebang line",
        )

    def test_extract_script_uses_bash(self):
        with open(EXTRACT_SCRIPT) as f:
            first_line = f.readline()
        self.assertIn(
            "bash",
            first_line,
            "Extract script shebang does not reference bash",
        )


class TestProofPatternSpec(unittest.TestCase):
    """Shared proof-pattern spec stays aligned with the extracted artifact."""

    def setUp(self):
        self.artifact = _load_artifact()
        self.spec = _load_pattern_spec()

    def test_pattern_spec_exists(self):
        self.assertTrue(
            PATTERN_SPEC_PATH.exists(),
            f"Pattern spec not found at {PATTERN_SPEC_PATH}",
        )

    def test_bounds_pattern_ids_are_unique(self):
        ids = [entry["id"] for entry in self.spec["boundsPatterns"]]
        self.assertEqual(len(ids), len(set(ids)), "Duplicate bounds pattern ids in spec")

    def test_validator_elision_ids_are_unique(self):
        ids = [entry["id"] for entry in self.spec["validatorElisions"]]
        self.assertEqual(len(ids), len(set(ids)), "Duplicate validator elision ids in spec")

    def test_spec_bounds_theorems_exist_in_artifact_bounds_eliminations(self):
        artifact_theorems = {
            entry["theorem"] for entry in self.artifact.get("boundsEliminations", [])
        }
        missing = []
        for entry in self.spec["boundsPatterns"]:
            if entry["theorem"] not in artifact_theorems:
                missing.append((entry["id"], entry["theorem"]))
        self.assertFalse(
            missing,
            f"Shared proof-pattern spec references bounds theorems missing from artifact: {missing}",
        )

    def test_stride_pattern_uses_matcher_contract_theorem(self):
        stride_pattern = next(
            (
                entry
                for entry in self.spec["boundsPatterns"]
                if entry["id"] == "gid_1d_storage_buffer_stride"
            ),
            None,
        )
        self.assertIsNotNone(stride_pattern, "Missing gid_1d_storage_buffer_stride pattern")
        self.assertEqual(
            stride_pattern["theorem"],
            "gid_stride_offset_matcher_contract_sound",
        )

        bounds_entries = {
            entry["theorem"]: entry for entry in self.artifact.get("boundsEliminations", [])
        }
        self.assertIn(
            "gid_stride_offset_matcher_contract_sound",
            bounds_entries,
            "Matcher contract theorem is missing from boundsEliminations",
        )
        self.assertEqual(
            bounds_entries["gid_stride_offset_matcher_contract_sound"].get("module"),
            "Doe.Shader.BoundsElisionMatcher",
        )

    def test_spec_validator_theorems_exist_in_artifact_theorem_inventory(self):
        artifact_theorems = {thm["name"] for thm in self.artifact.get("theorems", [])}
        missing = []
        for entry in self.spec["validatorElisions"]:
            for theorem in entry["requiredTheorems"]:
                if theorem not in artifact_theorems:
                    missing.append((entry["id"], theorem))
        self.assertFalse(
            missing,
            f"Shared proof-pattern spec references validator theorems missing from artifact: {missing}",
        )


class TestEvaluatedConditions(unittest.TestCase):
    """Sanity checks on evaluatedConditions."""

    def setUp(self):
        self.artifact = _load_artifact()

    def test_evaluated_conditions_is_dict(self):
        ec = self.artifact.get("evaluatedConditions")
        if ec is None:
            self.skipTest("No evaluatedConditions field in artifact")
        self.assertIsInstance(ec, dict)

    def test_evaluated_condition_values_are_bool_or_int(self):
        ec = self.artifact.get("evaluatedConditions", {})
        for key, value in ec.items():
            self.assertIsInstance(
                value,
                (bool, int),
                f"evaluatedConditions['{key}'] has type {type(value).__name__}, "
                "expected bool or int",
            )

    def test_evaluated_condition_keys_are_dotted_strings(self):
        ec = self.artifact.get("evaluatedConditions", {})
        for key in ec:
            self.assertIsInstance(key, str)
            self.assertGreater(len(key), 0, "Empty key in evaluatedConditions")


class TestEliminationTargets(unittest.TestCase):
    """Sanity checks on eliminationTargets."""

    def setUp(self):
        self.artifact = _load_artifact()

    def test_elimination_targets_is_list(self):
        et = self.artifact.get("eliminationTargets")
        if et is None:
            self.skipTest("No eliminationTargets field in artifact")
        self.assertIsInstance(et, list)

    def test_elimination_target_theorems_exist_in_theorems_list(self):
        et = self.artifact.get("eliminationTargets", [])
        theorem_names = {thm["name"] for thm in self.artifact.get("theorems", [])}
        missing = []
        for i, entry in enumerate(et):
            if entry["theorem"] not in theorem_names:
                missing.append((i, entry["theorem"]))
        self.assertFalse(
            missing,
            f"eliminationTargets reference theorems not in the theorems array: {missing}",
        )


if __name__ == "__main__":
    unittest.main()
