import tempfile
import unittest
from pathlib import Path

from bench.runners.export_numeric_fragility_corpus import build_rows
from bench.runners.export_numeric_fragility_corpus import LM_HEAD_REPORT_ROOT
from bench.runners.export_numeric_fragility_corpus import write_outputs


@unittest.skipUnless(
    LM_HEAD_REPORT_ROOT.exists(),
    "requires materialized Apple Metal LM-head hunt reports",
)
class ExportNumericFragilityCorpusTests(unittest.TestCase):
    def test_build_rows_includes_red_light_surprisal_metrics(self):
        rows = build_rows()
        red_light = next(
            row
            for row in rows
            if row["entryType"] == "prompt-lm-head-flip"
            and row["scenarioStem"] == "At a red traffic light, cars should"
        )
        bounded = red_light["boundedAnswerMetrics"]
        self.assertIsNotNone(bounded)
        self.assertTrue(bounded["available"])
        self.assertAlmostEqual(bounded["referenceProbability"], 0.50542619, places=6)
        self.assertAlmostEqual(bounded["referenceSurprisalNats"], 0.68235325, places=6)
        self.assertTrue(red_light["divergenceMetrics"]["fastVsReferenceFlip"])

        global_metrics = red_light["globalDecisionMetrics"]
        self.assertIsNotNone(global_metrics)
        self.assertTrue(global_metrics["available"])
        self.assertEqual(global_metrics["globalGreedyTokenText"], " go")
        self.assertLess(global_metrics["outsiderLeadVsPairMaxLogit"], 0.0)
        self.assertEqual(global_metrics["referenceTokenGlobalSurprisalStatus"], "unavailable_no_full_logits")
        self.assertEqual(red_light["routeDecision"], "prefer-stable")
        self.assertEqual(red_light["routeExpectation"]["status"], "realized-in-promotion")
        self.assertIn("red_go_stop_answer.real-lm-head-slice-hunt.json", red_light["sourceArtifactPath"])
        self.assertIn("generated_choice_scout.real-lm-head-slice-hunt.json", red_light["sourceSearchArtifactPath"])

    def test_write_outputs_emits_manifest_and_curated_top_prefix_rows(self):
        rows = build_rows()
        with tempfile.TemporaryDirectory() as tmp_dir:
            jsonl_path, manifest_path = write_outputs(
                rows,
                output_root=Path(tmp_dir),
                timestamp="20260329T180000Z",
            )
            self.assertTrue(jsonl_path.exists())
            self.assertTrue(manifest_path.exists())
            with jsonl_path.open("r", encoding="utf-8") as handle:
                line_count = sum(1 for _ in handle)
            self.assertEqual(line_count, len(rows))
            top_prefix_count = sum(1 for row in rows if row["entryType"] == "prompt-top-prefix-flip")
            self.assertEqual(top_prefix_count, 5)

    def test_hypothetical_route_expectation_is_not_a_realized_route(self):
        rows = build_rows()
        billing_export = next(
            row
            for row in rows
            if row["entryType"] == "prompt-lm-head-flip"
            and row["scenarioStem"] == "A customer billing export should remain"
        )
        self.assertIsNone(billing_export["routeDecision"])
        self.assertEqual(billing_export["routeExpectation"]["decision"], "prefer-stable")
        self.assertEqual(billing_export["routeExpectation"]["status"], "hypothetical-from-hunt")
        self.assertFalse(billing_export["routeExpectation"]["hasPromotionEvidence"])


if __name__ == "__main__":
    unittest.main()
