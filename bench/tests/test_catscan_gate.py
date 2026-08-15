#!/usr/bin/env python3
"""Tests for recursive CATSCAN charter validation."""

from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from bench.gates import catscan_gate as gate


REPO_ROOT = Path(__file__).resolve().parents[2]


def charter_text(
    component: str,
    *,
    parent: str,
    evidence: str,
    target: str = "Produce one governed outcome.",
) -> str:
    return f"""# CATSCAN: {component}

Parent: {parent}

## Target

{target}

## Authority

- Owns its declared component.

## Scope

- Includes files beneath this component directory.

## Contracts

- Input: [{evidence}]({evidence}).
- One governed output.

## Invariants

- Failure remains explicit.

## Acceptance

- The evidence exists.
- Evidence: [{evidence}]({evidence}).

## Non-goals

- Adjacent ownership.

## Freedom

Any mechanism is permitted if it preserves these boundaries and passes the acceptance evidence.
"""


def write_fixture(root: Path) -> None:
    (root / "evidence.txt").write_text("ok", encoding="utf-8")
    (root / "CATSCAN.md").write_text(
        charter_text("Root", parent="none", evidence="evidence.txt"),
        encoding="utf-8",
    )
    child = root / "child"
    child.mkdir()
    (child / "evidence.txt").write_text("ok", encoding="utf-8")
    (child / "CATSCAN.md").write_text(
        charter_text(
            "Child",
            parent="[Root](../CATSCAN.md)",
            evidence="evidence.txt",
        ),
        encoding="utf-8",
    )
    gate.write_component_index(root, Path("docs/component-index.md"))


class CatscanGateTests(unittest.TestCase):
    def test_tracked_charters_and_index_pass(self) -> None:
        result = gate.evaluate_repository(
            REPO_ROOT,
            Path("docs/component-index.md"),
        )

        self.assertTrue(result["ok"], result["failures"])
        self.assertGreater(result["summary"]["charterCount"], 1)

    def test_valid_recursive_fixture_passes(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            write_fixture(root)

            result = gate.evaluate_repository(root, Path("docs/component-index.md"))

        self.assertTrue(result["ok"], result["failures"])

    def test_child_must_name_nearest_parent(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            write_fixture(root)
            nested = root / "child" / "nested"
            nested.mkdir()
            (nested / "evidence.txt").write_text("ok", encoding="utf-8")
            (nested / "CATSCAN.md").write_text(
                charter_text(
                    "Nested",
                    parent="[Root](../../CATSCAN.md)",
                    evidence="evidence.txt",
                ),
                encoding="utf-8",
            )
            gate.write_component_index(root, Path("docs/component-index.md"))

            result = gate.evaluate_repository(root, Path("docs/component-index.md"))

        self.assertIn(
            "incorrect_parent_charter",
            {item["code"] for item in result["failures"]},
        )

    def test_duplicate_component_identifier_fails(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            write_fixture(root)
            path = root / "child" / "CATSCAN.md"
            path.write_text(
                charter_text(
                    "Root",
                    parent="[Root](../CATSCAN.md)",
                    evidence="evidence.txt",
                ),
                encoding="utf-8",
            )
            gate.write_component_index(root, Path("docs/component-index.md"))

            result = gate.evaluate_repository(root, Path("docs/component-index.md"))

        self.assertIn(
            "duplicate_component_identifier",
            {item["code"] for item in result["failures"]},
        )

    def test_missing_required_section_fails_generation(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            write_fixture(root)
            path = root / "child" / "CATSCAN.md"
            path.write_text(
                path.read_text(encoding="utf-8").replace("## Non-goals", "## Other"),
                encoding="utf-8",
            )

            with self.assertRaisesRegex(ValueError, "missing_required_section"):
                gate.write_component_index(root, Path("docs/component-index.md"))

    def test_missing_acceptance_evidence_fails(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            write_fixture(root)
            path = root / "child" / "CATSCAN.md"
            text = path.read_text(encoding="utf-8")
            text = text.replace(
                "- Evidence: [evidence.txt](evidence.txt).",
                "- Evidence is reviewed manually.",
                1,
            )
            path.write_text(text, encoding="utf-8")

            result = gate.evaluate_repository(root, Path("docs/component-index.md"))

        self.assertIn(
            "missing_acceptance_evidence",
            {item["code"] for item in result["failures"]},
        )

    def test_missing_link_target_fails(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            write_fixture(root)
            path = root / "child" / "CATSCAN.md"
            path.write_text(
                path.read_text(encoding="utf-8").replace(
                    "evidence.txt", "missing.txt"
                ),
                encoding="utf-8",
            )
            gate.write_component_index(root, Path("docs/component-index.md"))

            result = gate.evaluate_repository(root, Path("docs/component-index.md"))

        self.assertIn(
            "missing_charter_link_target",
            {item["code"] for item in result["failures"]},
        )

    def test_stale_index_fails(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            write_fixture(root)
            index = root / "docs" / "component-index.md"
            index.write_text("stale\n", encoding="utf-8")

            result = gate.evaluate_repository(root, Path("docs/component-index.md"))

        self.assertIn(
            "stale_component_index",
            {item["code"] for item in result["failures"]},
        )

    def test_charter_word_ceiling_is_enforced(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            write_fixture(root)
            path = root / "child" / "CATSCAN.md"
            path.write_text(
                path.read_text(encoding="utf-8")
                + "\n"
                + " ".join("excess" for _ in range(gate.MAX_WORDS)),
                encoding="utf-8",
            )

            result = gate.evaluate_repository(root, Path("docs/component-index.md"))

        self.assertIn(
            "charter_too_large",
            {item["code"] for item in result["failures"]},
        )


if __name__ == "__main__":
    unittest.main()
