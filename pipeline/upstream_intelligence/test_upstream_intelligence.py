#!/usr/bin/env python3
"""Offline contract tests for the Dawn/Tint intelligence pipeline."""

from __future__ import annotations

import io
import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from pipeline.upstream_intelligence.io import HttpClient
from pipeline.upstream_intelligence.cli import main as cli_main
from pipeline.upstream_intelligence.llm import Enricher, validate_model_output
from pipeline.upstream_intelligence.normalize import (
    gerrit_files,
    gerrit_message,
    issue_ids,
    normalize_change,
)
from pipeline.upstream_intelligence.pipeline import (
    IntelligencePipeline,
    _canonical_utc,
    _parse_utc,
    decode_json_object_stream,
)
from pipeline.upstream_intelligence.sources import GerritClient, parse_chromium_issue
from pipeline.upstream_intelligence.sources import IssueUnavailableError
from pipeline.upstream_intelligence.store import IntelligenceStore


REPO_ROOT = Path(__file__).resolve().parents[2]
FIXTURES = Path(__file__).resolve().parent / "fixtures"
CONFIG = REPO_ROOT / "config" / "upstream-intelligence.json"


def fixture_changes() -> list[dict]:
    return [
        json.loads(line)
        for line in (FIXTURES / "gerrit_changes.jsonl")
        .read_text(encoding="utf-8")
        .splitlines()
        if line
    ]


class FakePageHttp:
    def __init__(self, pages: list[list[dict]]) -> None:
        self.pages = iter(pages)
        self.urls: list[str] = []

    def get_json(self, url: str, *, gerrit_prefix: bool = False) -> object:
        self.urls.append(url)
        if not gerrit_prefix:
            raise AssertionError("Gerrit anti-XSSI handling must be requested")
        return next(self.pages)


class FakeLlmHttp:
    def __init__(self, output: dict) -> None:
        self.output = output
        self.calls = 0

    def post_json(self, url: str, value: object, bearer_token: str) -> object:
        self.calls += 1
        if not url.startswith("https://"):
            raise AssertionError("provider endpoint must use HTTPS")
        if bearer_token != "test-key":
            raise AssertionError("wrong API key")
        request = value
        if request["response_format"]["type"] != "json_schema":
            raise AssertionError("strict schema response was not requested")
        return {
            "choices": [
                {"message": {"content": json.dumps(self.output)}}
            ]
        }


class FakeIntelligenceHttp:
    def __init__(self, pages: list[list[dict]], issue_page: str) -> None:
        self.pages = iter(pages)
        self.issue_page = issue_page

    def get_json(self, _url: str, *, gerrit_prefix: bool = False) -> object:
        if not gerrit_prefix:
            raise AssertionError("expected Gerrit response")
        return next(self.pages)

    def request(
        self,
        url: str,
        *,
        method: str = "GET",
        body: bytes | None = None,
        headers: dict[str, str] | None = None,
    ) -> bytes:
        del method, body, headers
        issue_id = int(url.rsplit("/", 1)[1])
        return self.issue_page.replace("538691038", str(issue_id)).encode("utf-8")


class SourceTests(unittest.TestCase):
    def test_gerrit_paginates_until_more_changes_is_absent(self) -> None:
        first = fixture_changes()
        first[-1]["_more_changes"] = True
        second = [{**fixture_changes()[0], "_number": 123458}]
        http = FakePageHttp([first, second])
        config = {
            "baseUrl": "https://example.invalid",
            "pageSize": 2,
            "maxPages": 3,
        }
        changes = GerritClient(config, http).changes("project:dawn")
        self.assertEqual(len(changes), 3)
        self.assertIn("S=0", http.urls[0])
        self.assertIn("S=2", http.urls[1])
        self.assertIn("o=CURRENT_COMMIT", http.urls[0])
        self.assertIn("o=CURRENT_FILES", http.urls[0])

    def test_gerrit_truncation_fails_closed(self) -> None:
        page = fixture_changes()
        page[-1]["_more_changes"] = True
        with self.assertRaisesRegex(RuntimeError, "pagination incomplete"):
            GerritClient(
                {
                    "baseUrl": "https://example.invalid",
                    "pageSize": 2,
                    "maxPages": 1,
                },
                FakePageHttp([page]),
            ).changes("project:dawn")

    def test_chromium_issue_balanced_assignment_parser(self) -> None:
        page = (FIXTURES / "chromium_issue.html").read_text(encoding="utf-8")
        issue = parse_chromium_issue(page, 538691038)
        self.assertEqual(issue["componentId"], 1571063)
        self.assertEqual(issue["title"], "CTS: alias_analysis failures")
        self.assertIn("; and ]", issue["description"])
        self.assertTrue(issue["created"].endswith("Z"))

    def test_non_public_issue_has_typed_result(self) -> None:
        page = "<script>var defrostedResourcesJspb = [null,true];</script>"
        with self.assertRaises(IssueUnavailableError):
            parse_chromium_issue(page, 443079848)


class NormalizationTests(unittest.TestCase):
    def test_current_revision_commit_and_files_are_authoritative(self) -> None:
        change = fixture_changes()[0]
        self.assertIn("Bug: chromium:538691038", gerrit_message(change))
        self.assertEqual(issue_ids(change), [538691038])
        self.assertEqual(
            gerrit_files(change),
            [
                "src/tint/lang/wgsl/resolver/validator.cc",
                "test/tint/bug/538691038.wgsl",
            ],
        )

    def test_zero_bug_sentinel_is_not_an_issue(self) -> None:
        change = fixture_changes()[0]
        change["revisions"]["abc123"]["commit"]["message"] = (
            "A change without a tracker issue.\n\nBug: 0\n"
        )
        self.assertEqual(issue_ids(change), [])

    def test_multiple_issue_ids_in_one_footer_are_preserved(self) -> None:
        change = fixture_changes()[0]
        change["revisions"]["abc123"]["commit"]["message"] = (
            "A multi-issue fix.\n\nBug: chromium:538691038, dawn:538691039, 0\n"
        )
        self.assertEqual(issue_ids(change), [538691038, 538691039])

    def test_normalization_is_relevant_and_hash_stable(self) -> None:
        config = json.loads(CONFIG.read_text(encoding="utf-8"))
        issue = {
            "id": 538691038,
            "title": "CTS alias analysis failures",
            "description": "Tint validation regression",
        }
        first = normalize_change(
            fixture_changes()[0],
            {538691038: issue},
            config["relevance"],
        )
        second = normalize_change(
            fixture_changes()[0],
            {538691038: issue},
            config["relevance"],
        )
        self.assertTrue(first["relevance"]["included"])
        self.assertEqual(first["inputHash"], second["inputHash"])
        self.assertIn("src/tint/", first["relevance"]["fileHits"][0])


class StoreTests(unittest.TestCase):
    def test_event_versions_and_cursor_are_update_aware(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            with IntelligenceStore(Path(directory) / "state.sqlite3") as store:
                self.assertTrue(
                    store.put_event(
                        "gerrit",
                        "1",
                        "2026-01-01T00:00:00Z|a",
                        "2026-01-01T00:00:01Z",
                        {"revision": "a"},
                    )
                )
                self.assertFalse(
                    store.put_event(
                        "gerrit",
                        "1",
                        "2026-01-01T00:00:00Z|a",
                        "2026-01-01T00:00:02Z",
                        {"revision": "a"},
                    )
                )
                self.assertTrue(
                    store.put_event(
                        "gerrit",
                        "1",
                        "2026-01-02T00:00:00Z|b",
                        "2026-01-02T00:00:01Z",
                        {"revision": "b"},
                    )
                )
                self.assertEqual(len(store.event_versions("gerrit", "1")), 2)
                store.set_cursor(
                    "gerrit", "live", "2026-01-02T00:00:00Z", True, "now"
                )
                store.set_cursor(
                    "gerrit", "live", "2026-01-01T00:00:00Z", True, "later"
                )
                self.assertEqual(
                    store.get_cursor("gerrit", "live")["highWatermark"],
                    "2026-01-02T00:00:00Z",
                )


class EnrichmentTests(unittest.TestCase):
    def test_model_output_is_closed(self) -> None:
        with self.assertRaisesRegex(ValueError, "unknown fields"):
            validate_model_output(
                {
                    "summary": "s",
                    "doeImpact": "i",
                    "failureMechanism": "m",
                    "recommendedAction": "test",
                    "confidence": "high",
                    "citations": [],
                    "surprise": True,
                }
            )

    def test_model_citations_must_come_from_evidence(self) -> None:
        with self.assertRaisesRegex(ValueError, "outside supplied evidence"):
            validate_model_output(
                {
                    "summary": "s",
                    "doeImpact": "i",
                    "failureMechanism": "m",
                    "recommendedAction": "test",
                    "confidence": "high",
                    "citations": ["https://example.invalid/invented"],
                },
                allowed_citations={
                    "https://dawn-review.googlesource.com/c/dawn/+/123456"
                },
            )

    def test_llm_result_is_cached_by_input_prompt_and_model(self) -> None:
        output = {
            "summary": "A validation regression is fixed.",
            "doeImpact": "Add a parity workload.",
            "failureMechanism": "Alias classification diverged.",
            "recommendedAction": "test",
            "confidence": "high",
            "citations": [
                "https://dawn-review.googlesource.com/c/dawn/+/123456"
            ],
        }
        finding = json.loads(
            (REPO_ROOT / "examples" / "upstream-intelligence-finding.sample.json")
            .read_text(encoding="utf-8")
        )
        config = json.loads(CONFIG.read_text(encoding="utf-8"))["enrichment"]
        http = FakeLlmHttp(output)
        with tempfile.TemporaryDirectory() as directory:
            with IntelligenceStore(Path(directory) / "state.sqlite3") as store:
                enricher = Enricher(config, http, store)
                with mock.patch.dict(
                    os.environ, {"OPENAI_API_KEY": "test-key"}, clear=False
                ):
                    first = enricher.enrich(finding)
                    second = enricher.enrich(finding)
        self.assertEqual(first, second)
        self.assertEqual(http.calls, 1)


class PipelineTests(unittest.TestCase):
    def test_gerrit_naive_timestamp_is_interpreted_as_utc(self) -> None:
        parsed = _parse_utc("2026-07-25 12:00:00.123456789")
        self.assertEqual(parsed.utcoffset().total_seconds(), 0)
        self.assertEqual(parsed.hour, 12)
        self.assertEqual(
            _canonical_utc("2026-07-25 12:00:00.123456789"),
            "2026-07-25T12:00:00.123456Z",
        )

    def test_backfill_cli_routes_only_backfill_arguments(self) -> None:
        with mock.patch.object(
            IntelligencePipeline,
            "backfill",
            return_value={"operationalSuccess": True},
        ) as backfill:
            with mock.patch("sys.stdout", new=io.StringIO()):
                exit_code = cli_main(
                    ["backfill", "--after", "2026-01-01", "--before", "2026-01-02"]
                )
        self.assertEqual(exit_code, 0)
        backfill.assert_called_once()

    def test_replay_repairs_raw_newline_inside_json_string(self) -> None:
        records, rejections = decode_json_object_stream(
            '{"message":"first line\nsecond line"}\n{"id":2}\n'
        )
        self.assertEqual(rejections, [])
        self.assertEqual(records[0][1]["message"], "first line\nsecond line")
        self.assertEqual(records[1][1], {"id": 2})

    def test_replay_records_corrupt_rows_and_can_fail_strictly(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            input_path = root / "corrupt.jsonl"
            input_path.write_text('{"unterminated": "\\n', encoding="utf-8")
            pipeline = IntelligencePipeline(
                config_path=CONFIG,
                database_path=root / "state.sqlite3",
                output_root=root / "runs",
            )
            receipt = pipeline.replay([input_path])
            self.assertFalse(receipt["coverageComplete"])
            self.assertEqual(len(receipt["inputRejections"]), 1)
            with self.assertRaisesRegex(ValueError, "rejected 1 inputs"):
                pipeline.replay([input_path], fail_on_rejection=True)

    def test_issue_queue_is_bounded_durable_and_resumed(self) -> None:
        first_change = fixture_changes()[0]
        second_change = json.loads(json.dumps(first_change))
        second_change["_number"] = 123458
        second_change["id"] = "dawn~main~Isecond"
        second_change["updated"] = "2026-07-25T12:02:00Z"
        second_change["revisions"]["abc123"]["commit"]["message"] = (
            "tint: second regression\n\nBug: chromium:538691039\n"
        )
        issue_page = (FIXTURES / "chromium_issue.html").read_text(encoding="utf-8")
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            pipeline = IntelligencePipeline(
                config_path=CONFIG,
                database_path=root / "state.sqlite3",
                output_root=root / "runs",
                http=FakeIntelligenceHttp(
                    [[first_change, second_change], []],
                    issue_page,
                ),
            )
            pipeline.config["sources"]["chromiumIssues"]["maxIssuesPerRun"] = 1
            with mock.patch.dict(os.environ, {}, clear=True):
                first = pipeline.sync()
                second = pipeline.sync()
            self.assertFalse(first["coverageComplete"])
            self.assertEqual(first["issueFetchDeferred"], [538691039])
            self.assertTrue(second["coverageComplete"])
            self.assertEqual(second["issueFetchDeferred"], [])

    def test_replay_packet_status_and_promotion_gate(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            database = root / "state.sqlite3"
            output = root / "runs"
            pipeline = IntelligencePipeline(
                config_path=CONFIG,
                database_path=database,
                output_root=output,
                http=HttpClient(
                    timeout_seconds=1,
                    retry_count=0,
                    retry_backoff_seconds=0,
                    user_agent="offline-test",
                ),
            )
            with mock.patch.dict(os.environ, {}, clear=True):
                receipt = pipeline.replay(
                    [FIXTURES / "gerrit_changes.jsonl"],
                    source_manifest_paths=[FIXTURES / "source_manifest.json"],
                )
            self.assertEqual(receipt["counts"]["gerritObserved"], 2)
            self.assertEqual(receipt["counts"]["relevantFindings"], 1)
            run_root = output / receipt["runId"]
            self.assertTrue((run_root / "review.md").exists())
            review = (run_root / "review.md").read_text(encoding="utf-8")
            self.assertIn("Model output is triage evidence only", review)
            findings = json.loads(
                (run_root / "findings.json").read_text(encoding="utf-8")
            )
            self.assertEqual(
                findings[0]["evidence"]["sourceCorroboration"][0]["kind"],
                "feature_guard",
            )
            gate = pipeline.promote(
                finding_id="dawn-cl-123456",
                decision="approved",
                reviewer="test-reviewer",
                reason="Fixture reproduces the relevant compiler path.",
                output_path=root / "promotion.json",
            )
            self.assertFalse(gate["runtimeMutationAuthorized"])
            status = pipeline.status()
            self.assertEqual(status["counts"]["promotions"], 1)
            self.assertEqual(status["counts"]["findings"], 2)


if __name__ == "__main__":
    unittest.main()
