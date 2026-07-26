"""End-to-end Dawn/Tint intelligence orchestration."""

from __future__ import annotations

import json
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Iterable

import jsonschema

from bench.lib.config_validation import load_validated_config
from pipeline.upstream_intelligence.io import (
    HttpClient,
    sha256_json,
    sha256_text,
    write_json,
    write_text,
)
from pipeline.upstream_intelligence.llm import Enricher
from pipeline.upstream_intelligence.normalize import (
    issue_ids,
    normalize_change,
    project_gerrit_change,
)
from pipeline.upstream_intelligence.render import render_review_packet
from pipeline.upstream_intelligence.sources import (
    ChromiumIssueClient,
    GerritClient,
    IssueUnavailableError,
    utc_now,
)
from pipeline.upstream_intelligence.store import IntelligenceStore


REPO_ROOT = Path(__file__).resolve().parents[2]
ARTIFACT_SCHEMAS = {
    "finding": REPO_ROOT / "config" / "upstream-intelligence-finding.schema.json",
    "enrichment": REPO_ROOT
    / "config"
    / "upstream-intelligence-enrichment.schema.json",
    "run": REPO_ROOT / "config" / "upstream-intelligence-run.schema.json",
    "promotion": REPO_ROOT
    / "config"
    / "upstream-intelligence-promotion.schema.json",
}


def validate_artifact(kind: str, value: dict[str, Any]) -> None:
    schema = json.loads(ARTIFACT_SCHEMAS[kind].read_text(encoding="utf-8"))
    jsonschema.Draft202012Validator(schema).validate(value)


def _parse_utc(value: str) -> datetime:
    parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc)


def _date_query_value(value: datetime) -> str:
    return value.strftime("%Y-%m-%d")


def _canonical_utc(value: str) -> str:
    return _parse_utc(value).isoformat().replace("+00:00", "Z")


def _change_id(change: dict[str, Any]) -> str:
    value = change.get("_number") or change.get("id")
    if value is None:
        raise ValueError("Gerrit change lacks _number and id")
    return str(value)


def _change_version(change: dict[str, Any]) -> str:
    updated = str(change.get("updated", ""))
    revision = str(change.get("current_revision", ""))
    if not updated:
        raise ValueError(f"Gerrit change {_change_id(change)} lacks updated timestamp")
    return f"{updated}|{revision}"


def decode_json_object_stream(
    text: str,
) -> tuple[list[tuple[int, dict[str, Any]]], list[dict[str, Any]]]:
    """Decode newline-delimited objects, repairing raw newlines inside strings."""
    records: list[tuple[int, dict[str, Any]]] = []
    rejections: list[dict[str, Any]] = []
    raw: list[str] = []
    sanitized: list[str] = []
    depth = 0
    in_string = False
    escaped = False
    line = 1
    start_line = 1
    for character in text:
        if depth == 0:
            if character.isspace():
                line += int(character == "\n")
                continue
            start_line = line
            if character != "{":
                rejections.append(
                    {
                        "line": line,
                        "lineHash": sha256_text(character),
                        "error": f"expected object start, received {character!r}",
                    }
                )
                continue
        raw.append(character)
        if character == "\n" and in_string:
            sanitized.append("\\n")
            escaped = False
            line += 1
            continue
        sanitized.append(character)
        if in_string:
            if escaped:
                escaped = False
            elif character == "\\":
                escaped = True
            elif character == '"':
                in_string = False
        elif character == '"':
            in_string = True
        elif character == "{":
            depth += 1
        elif character == "}":
            depth -= 1
            if depth == 0:
                raw_value = "".join(raw)
                try:
                    value = json.loads("".join(sanitized))
                    if not isinstance(value, dict):
                        raise ValueError("expected JSON object")
                    records.append((start_line, value))
                except (json.JSONDecodeError, ValueError) as error:
                    rejections.append(
                        {
                            "line": start_line,
                            "lineHash": sha256_text(raw_value),
                            "error": str(error),
                        }
                    )
                raw.clear()
                sanitized.clear()
        line += int(character == "\n")
    if raw:
        raw_value = "".join(raw)
        rejections.append(
            {
                "line": start_line,
                "lineHash": sha256_text(raw_value),
                "error": "unterminated JSON object at end of input",
            }
        )
    return records, rejections


def load_source_signals(paths: Iterable[Path]) -> list[dict[str, str]]:
    signals: list[dict[str, str]] = []
    schema = json.loads(
        (REPO_ROOT / "config" / "quirk-mining-manifest.schema.json").read_text(
            encoding="utf-8"
        )
    )
    for path in sorted(paths):
        manifest = json.loads(path.read_text(encoding="utf-8"))
        jsonschema.Draft202012Validator(schema).validate(manifest)
        for field, kind_field in (
            ("toggleHits", "toggle"),
            ("workaroundHits", "category"),
        ):
            for row in manifest.get(field, []):
                source_path = row.get("sourcePath")
                kind = row.get(kind_field)
                if isinstance(source_path, str) and isinstance(kind, str):
                    signals.append(
                        {
                            "manifest": str(path),
                            "sourcePath": source_path,
                            "kind": kind,
                        }
                    )
    return sorted(
        signals,
        key=lambda value: (
            value["sourcePath"],
            value["kind"],
            value["manifest"],
        ),
    )


class IntelligencePipeline:
    def __init__(
        self,
        *,
        config_path: Path,
        database_path: Path | None = None,
        output_root: Path | None = None,
        http: HttpClient | None = None,
        require_llm: bool = False,
    ) -> None:
        self.config = load_validated_config(config_path)
        storage = self.config["storage"]
        self.database_path = database_path or Path(storage["databasePath"])
        self.output_root = output_root or Path(storage["outputRoot"])
        self.require_llm = require_llm
        transport = self.config["transport"]
        self.http = http or HttpClient(
            timeout_seconds=int(transport["timeoutSeconds"]),
            retry_count=int(transport["retryCount"]),
            retry_backoff_seconds=float(transport["retryBackoffSeconds"]),
            user_agent=str(transport["userAgent"]),
        )

    def sync(
        self,
        explicit_issue_ids: Iterable[int] = (),
        source_manifest_paths: Iterable[Path] = (),
    ) -> dict[str, Any]:
        now = utc_now()
        with IntelligenceStore(self.database_path) as store:
            cursor = store.get_cursor("gerrit", "live")
            if cursor:
                after = _parse_utc(cursor["highWatermark"]) - timedelta(
                    seconds=int(self.config["sources"]["gerrit"]["overlapSeconds"])
                )
            else:
                after = _parse_utc(self.config["sources"]["gerrit"]["initialAfter"])
            query = (
                f"project:{self.config['sources']['gerrit']['project']} "
                f"after:{_date_query_value(after)}"
            )
            changes = GerritClient(
                self.config["sources"]["gerrit"], self.http
            ).changes(query)
            return self._process(
                store,
                mode="sync",
                query=query,
                changes=changes,
                explicit_issue_ids=set(explicit_issue_ids),
                now=now,
                cursor_id="live",
                source_signals=load_source_signals(source_manifest_paths),
            )

    def backfill(
        self,
        *,
        after: str,
        before: str,
        explicit_issue_ids: Iterable[int] = (),
        source_manifest_paths: Iterable[Path] = (),
    ) -> dict[str, Any]:
        after_value = _parse_utc(f"{after}T00:00:00Z")
        before_value = _parse_utc(f"{before}T00:00:00Z")
        if before_value <= after_value:
            raise ValueError("backfill --before must be after --after")
        query = (
            f"project:{self.config['sources']['gerrit']['project']} "
            f"after:{after} before:{before}"
        )
        changes = GerritClient(
            self.config["sources"]["gerrit"], self.http
        ).changes(query)
        with IntelligenceStore(self.database_path) as store:
            return self._process(
                store,
                mode="backfill",
                query=query,
                changes=changes,
                explicit_issue_ids=set(explicit_issue_ids),
                now=utc_now(),
                cursor_id=f"{after}..{before}",
                source_signals=load_source_signals(source_manifest_paths),
            )

    def replay(
        self,
        paths: Iterable[Path],
        explicit_issue_ids: Iterable[int] = (),
        source_manifest_paths: Iterable[Path] = (),
        fail_on_rejection: bool = False,
    ) -> dict[str, Any]:
        changes: list[dict[str, Any]] = []
        rejections: list[dict[str, Any]] = []
        for path in sorted(paths):
            records, path_rejections = decode_json_object_stream(
                path.read_text(encoding="utf-8")
            )
            for rejection in path_rejections:
                rejections.append({"path": str(path), **rejection})
            for _line_number, value in records:
                changes.append(value)
        if fail_on_rejection and rejections:
            first = rejections[0]
            raise ValueError(
                f"replay rejected {len(rejections)} inputs; "
                f"first: {first['path']}:{first['line']}: {first['error']}"
            )
        with IntelligenceStore(self.database_path) as store:
            return self._process(
                store,
                mode="replay",
                query=",".join(str(path) for path in sorted(paths)),
                changes=changes,
                explicit_issue_ids=set(explicit_issue_ids),
                now=utc_now(),
                cursor_id="replay",
                fetch_issues=False,
                source_signals=load_source_signals(source_manifest_paths),
                input_rejections=rejections,
            )

    def _process(
        self,
        store: IntelligenceStore,
        *,
        mode: str,
        query: str,
        changes: list[dict[str, Any]],
        explicit_issue_ids: set[int],
        now: str,
        cursor_id: str,
        fetch_issues: bool = True,
        source_signals: list[dict[str, str]] | None = None,
        input_rejections: list[dict[str, Any]] | None = None,
    ) -> dict[str, Any]:
        allowed_statuses = set(self.config["sources"]["gerrit"]["statuses"])
        changes = [
            project_gerrit_change(change)
            for change in changes
            if str(change.get("status", "")).upper() in allowed_statuses
        ]
        inserted = 0
        for change in changes:
            inserted += int(
                store.put_event(
                    "gerrit",
                    _change_id(change),
                    _change_version(change),
                    now,
                    change,
                )
            )
        current_issue_ids = set(explicit_issue_ids)
        for change in changes:
            current_issue_ids.update(issue_ids(change))
        pending_issue_ids = {
            int(issue["id"])
            for issue in store.iter_latest_events("chromium_issue")
            if issue.get("availability") == "pending"
        }
        requested_issues = current_issue_ids | pending_issue_ids
        issue_limit = int(self.config["sources"]["chromiumIssues"]["maxIssuesPerRun"])
        issues: dict[int, dict[str, Any]] = {}
        cached_by_id: dict[int, dict[str, Any]] = {}
        failures: list[dict[str, Any]] = []
        unavailable: list[int] = []
        resolved_this_run: set[int] = set()
        issue_client = ChromiumIssueClient(
            self.config["sources"]["chromiumIssues"], self.http
        )
        for issue_id in sorted(requested_issues):
            cached = store.latest_event("chromium_issue", str(issue_id))
            if cached:
                cached_by_id[issue_id] = cached
                if cached.get("availability") != "pending":
                    issues[issue_id] = cached
        unresolved_ids = [
            issue_id
            for issue_id in sorted(requested_issues)
            if issue_id not in cached_by_id
            or cached_by_id[issue_id].get("availability") == "pending"
            or (
                cached_by_id[issue_id].get("availability") == "unavailable"
                and _parse_utc(
                    cached_by_id[issue_id].get(
                        "nextRetryAt", "1970-01-01T00:00:00Z"
                    )
                )
                <= _parse_utc(now)
            )
        ]
        refresh_ids = [
            issue_id
            for issue_id in sorted(current_issue_ids)
            if issue_id in cached_by_id
            and cached_by_id[issue_id].get("availability") == "available"
        ]
        fetch_candidates = unresolved_ids + [
            issue_id for issue_id in refresh_ids if issue_id not in unresolved_ids
        ]
        fetch_ids = fetch_candidates[:issue_limit] if fetch_issues else []
        deferred = sorted(set(unresolved_ids) - set(fetch_ids))
        for issue_id in deferred:
            if issue_id not in cached_by_id:
                store.put_event(
                    "chromium_issue",
                    str(issue_id),
                    f"{now}|pending",
                    now,
                    {
                        "id": issue_id,
                        "url": f"https://issues.chromium.org/issues/{issue_id}",
                        "availability": "pending",
                    },
                )
        for issue_id in fetch_ids:
            try:
                issue = issue_client.issue(issue_id)
                issue["availability"] = "available"
                issues[issue_id] = issue
                resolved_this_run.add(issue_id)
                version = issue["updated"] or sha256_json(issue)
                store.put_event(
                    "chromium_issue",
                    str(issue_id),
                    version,
                    now,
                    issue,
                )
            except IssueUnavailableError:
                issue = {
                    "id": issue_id,
                    "url": f"https://issues.chromium.org/issues/{issue_id}",
                    "availability": "unavailable",
                    "title": "Issue is not publicly available",
                    "description": "",
                    "nextRetryAt": (
                        _parse_utc(now)
                        + timedelta(
                            days=int(
                                self.config["sources"]["chromiumIssues"][
                                    "unavailableRetryDays"
                                ]
                            )
                        )
                    )
                    .isoformat()
                    .replace("+00:00", "Z"),
                }
                unavailable.append(issue_id)
                issues[issue_id] = issue
                resolved_this_run.add(issue_id)
                store.put_event(
                    "chromium_issue",
                    str(issue_id),
                    f"{now}|unavailable",
                    now,
                    issue,
                )
            except (RuntimeError, ValueError) as error:
                failures.append(
                    {
                        "issueId": issue_id,
                        "code": (
                            "transport_error"
                            if isinstance(error, RuntimeError)
                            else "parse_error"
                        ),
                        "error": str(error),
                    }
                )
                store.put_event(
                    "chromium_issue",
                    str(issue_id),
                    f"{now}|pending",
                    now,
                    {
                        "id": issue_id,
                        "url": f"https://issues.chromium.org/issues/{issue_id}",
                        "availability": "pending",
                        "lastError": str(error),
                    },
                )
        normalize_by_id = {_change_id(change): change for change in changes}
        if resolved_this_run:
            for historical_change in store.iter_latest_events("gerrit"):
                if set(issue_ids(historical_change)) & resolved_this_run:
                    normalize_by_id[_change_id(historical_change)] = historical_change
                    for linked_issue_id in issue_ids(historical_change):
                        if linked_issue_id in issues:
                            continue
                        linked_issue = store.latest_event(
                            "chromium_issue", str(linked_issue_id)
                        )
                        if (
                            linked_issue
                            and linked_issue.get("availability") != "pending"
                        ):
                            issues[linked_issue_id] = linked_issue
        rows: list[tuple[dict[str, Any], dict[str, Any]]] = []
        enricher = Enricher(
            self.config["enrichment"],
            self.http,
            store,
            require_model=self.require_llm,
        )
        relevant = 0
        relevant_by_id: dict[str, dict[str, Any]] = {}
        for change in sorted(normalize_by_id.values(), key=_change_id):
            finding = normalize_change(
                change,
                issues,
                self.config["relevance"],
                source_signals,
            )
            validate_artifact("finding", finding)
            store.put_finding(finding)
            if not finding["relevance"]["included"]:
                continue
            relevant += 1
            relevant_by_id[finding["findingId"]] = finding
        for finding in store.iter_findings():
            if finding["relevance"]["included"]:
                relevant_by_id[finding["findingId"]] = finding
        pending_findings = [
            finding
            for finding in relevant_by_id.values()
            if not enricher.is_cached(finding)
        ]
        pending_findings.sort(
            key=lambda finding: (
                finding["updatedAt"],
                finding["findingId"],
            ),
            reverse=True,
        )
        enrichment_limit = int(self.config["enrichment"]["maxFindingsPerRun"])
        selected_findings = pending_findings[:enrichment_limit]
        enrichment_deferred = [
            finding["findingId"] for finding in pending_findings[enrichment_limit:]
        ]
        enrichment_failures: list[dict[str, str]] = []
        for index, finding in enumerate(selected_findings):
            try:
                enrichment = enricher.enrich(finding)
                validate_artifact("enrichment", enrichment)
                rows.append((finding, enrichment))
            except (RuntimeError, ValueError, jsonschema.ValidationError) as error:
                enrichment_failures.append(
                    {
                        "findingId": finding["findingId"],
                        "error": str(error),
                    }
                )
                enrichment_deferred = [
                    candidate["findingId"]
                    for candidate in selected_findings[index:]
                ] + enrichment_deferred
                break
        high_watermark = max(
            (_canonical_utc(str(change["updated"])) for change in changes),
            default=_canonical_utc(now),
        )
        rejections = input_rejections or []
        source_coverage_complete = not failures and not deferred and not rejections
        enrichment_complete = not enrichment_deferred and not enrichment_failures
        coverage_complete = source_coverage_complete and enrichment_complete
        operational_success = (
            not failures and not rejections and not enrichment_failures
        )
        store.set_cursor(
            "gerrit",
            cursor_id,
            high_watermark,
            source_coverage_complete,
            now,
        )
        run_identity = {
            "mode": mode,
            "query": query,
            "startedAt": now,
            "inputHashes": sorted(
                sha256_json(change) for change in changes
            ),
        }
        run_id = f"{now.replace(':', '').replace('-', '')}-{sha256_json(run_identity)[:12]}"
        receipt = {
            "schemaVersion": 1,
            "runId": run_id,
            "mode": mode,
            "query": query,
            "startedAt": now,
            "completedAt": utc_now(),
            "policyId": self.config["policyId"],
            "coverageComplete": coverage_complete,
            "operationalSuccess": operational_success,
            "sourceCoverageComplete": source_coverage_complete,
            "enrichmentComplete": enrichment_complete,
            "counts": {
                "gerritObserved": len(changes),
                "eventsInserted": inserted,
                "issuesRequested": len(requested_issues),
                "issuesFetched": len(issues),
                "relevantFindings": relevant,
                "findingsEnriched": len(rows),
            },
            "issueFetchFailures": failures,
            "issueFetchDeferred": deferred,
            "issueUnavailable": unavailable,
            "inputRejections": rejections,
            "enrichmentDeferred": enrichment_deferred,
            "enrichmentFailures": enrichment_failures,
            "inputHash": sha256_json(run_identity),
        }
        validate_artifact("run", receipt)
        run_root = self.output_root / run_id
        write_json(run_root / "run.json", receipt)
        write_json(run_root / "findings.json", [row[0] for row in rows])
        write_json(run_root / "enrichments.json", [row[1] for row in rows])
        write_text(run_root / "review.md", render_review_packet(receipt, rows))
        return receipt

    def promote(
        self,
        *,
        finding_id: str,
        decision: str,
        reviewer: str,
        reason: str,
        output_path: Path,
    ) -> dict[str, Any]:
        if decision not in {"approved", "rejected"}:
            raise ValueError("decision must be approved or rejected")
        with IntelligenceStore(self.database_path) as store:
            finding = store.get_finding(finding_id)
            if finding is None:
                raise KeyError(f"finding not found: {finding_id}")
            if decision == "approved" and not finding["relevance"]["included"]:
                raise ValueError("irrelevant findings cannot be approved")
            body = {
                "findingId": finding_id,
                "findingInputHash": finding["inputHash"],
                "decision": decision,
                "reviewer": reviewer,
                "reason": reason,
                "reviewedAt": utc_now(),
                "runtimeMutationAuthorized": False,
            }
            receipt = {
                "schemaVersion": 1,
                "receiptId": f"upstream-review-{sha256_json(body)[:20]}",
                **body,
            }
            validate_artifact("promotion", receipt)
            store.put_promotion(receipt)
            write_json(output_path, receipt)
            return receipt

    def status(self) -> dict[str, Any]:
        with IntelligenceStore(self.database_path) as store:
            return {
                "schemaVersion": 1,
                "databasePath": str(self.database_path),
                "counts": store.counts(),
                "liveCursor": store.get_cursor("gerrit", "live"),
            }
