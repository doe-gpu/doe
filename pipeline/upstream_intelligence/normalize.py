"""Deterministic Dawn/Tint finding normalization."""

from __future__ import annotations

import re
from typing import Any

from pipeline.upstream_intelligence.io import sha256_json


ISSUE_FOOTER_PATTERN = re.compile(
    r"(?im)^(?:bug|fixed|fixes|issue):\s*(.+)$"
)
ISSUE_TOKEN_PATTERN = re.compile(
    r"(?:chromium:|dawn:|crbug\.com/|b/)?(\d+)\b",
    re.IGNORECASE,
)


def current_revision(change: dict[str, Any]) -> dict[str, Any]:
    revision_id = change.get("current_revision")
    revisions = change.get("revisions", {})
    if not isinstance(revisions, dict) or revision_id not in revisions:
        return {}
    revision = revisions[revision_id]
    return revision if isinstance(revision, dict) else {}


def gerrit_message(change: dict[str, Any]) -> str:
    revision = current_revision(change)
    commit = revision.get("commit", {})
    if isinstance(commit, dict) and isinstance(commit.get("message"), str):
        return str(commit["message"])
    return str(change.get("subject", ""))


def gerrit_files(change: dict[str, Any]) -> list[str]:
    files = current_revision(change).get("files", {})
    if not isinstance(files, dict):
        return []
    return sorted(str(path) for path in files)


def project_gerrit_change(change: dict[str, Any]) -> dict[str, Any]:
    """Retain execution-relevant Gerrit data while excluding account metadata."""
    revision_id = str(change.get("current_revision", ""))
    revision = current_revision(change)
    commit = revision.get("commit", {})
    files = revision.get("files", {})
    return {
        "_number": change.get("_number"),
        "id": change.get("id"),
        "project": change.get("project"),
        "branch": change.get("branch"),
        "status": change.get("status"),
        "subject": change.get("subject"),
        "updated": change.get("updated"),
        "current_revision": revision_id,
        "revisions": {
            revision_id: {
                "commit": {
                    "message": (
                        commit.get("message", "")
                        if isinstance(commit, dict)
                        else ""
                    )
                },
                "files": files if isinstance(files, dict) else {},
            }
        },
    }


def issue_ids(change: dict[str, Any]) -> list[int]:
    return sorted(
        {
            issue_id
            for footer in ISSUE_FOOTER_PATTERN.findall(gerrit_message(change))
            for match in ISSUE_TOKEN_PATTERN.findall(footer)
            if (issue_id := int(match)) > 0
        }
    )


def _matches(text: str, terms: list[str]) -> list[str]:
    lowered = text.lower()
    return sorted({term for term in terms if term.lower() in lowered})


def normalize_change(
    change: dict[str, Any],
    issues: dict[int, dict[str, Any]],
    policy: dict[str, Any],
    source_signals: list[dict[str, str]] | None = None,
) -> dict[str, Any]:
    change_id = str(change.get("_number") or change.get("id"))
    message = gerrit_message(change)
    files = gerrit_files(change)
    linked_ids = issue_ids(change)
    linked_issues = [issues[value] for value in linked_ids if value in issues]
    issue_text = "\n".join(
        f"{issue.get('title', '')}\n{issue.get('description', '')}"
        for issue in linked_issues
    )
    all_text = "\n".join([str(change.get("subject", "")), message, *files, issue_text])
    term_hits = _matches(all_text, list(policy["terms"]))
    vendor_hits = _matches(all_text, list(policy["vendors"]))
    backend_hits = _matches(all_text, list(policy["backends"]))
    file_hits = [
        path
        for path in files
        if any(path.startswith(prefix) for prefix in policy["filePrefixes"])
    ]
    corroboration = [
        signal
        for signal in (source_signals or [])
        if any(
            path.endswith(signal["sourcePath"])
            or signal["sourcePath"].endswith(path)
            for path in files
        )
    ]
    score = (
        len(term_hits) * int(policy["termWeight"])
        + len(vendor_hits) * int(policy["vendorWeight"])
        + len(backend_hits) * int(policy["backendWeight"])
        + len(file_hits) * int(policy["fileWeight"])
        + len(linked_issues) * int(policy["linkedIssueWeight"])
    )
    evidence = {
        "gerritChange": change_id,
        "gerritUrl": f"https://dawn-review.googlesource.com/c/dawn/+/{change_id}",
        "revision": str(change.get("current_revision", "")),
        "files": files,
        "issueIds": linked_ids,
        "issues": linked_issues,
        "sourceCorroboration": corroboration,
    }
    input_hash = sha256_json(evidence)
    return {
        "schemaVersion": 1,
        "findingId": f"dawn-cl-{change_id}",
        "kind": "dawn_change",
        "title": str(change.get("subject", "")).strip(),
        "status": str(change.get("status", "")).lower(),
        "updatedAt": str(change.get("updated", "")),
        "relevance": {
            "score": score,
            "threshold": int(policy["minimumScore"]),
            "included": score >= int(policy["minimumScore"]),
            "termHits": term_hits,
            "vendorHits": vendor_hits,
            "backendHits": backend_hits,
            "fileHits": file_hits,
        },
        "evidence": evidence,
        "inputHash": input_hash,
    }


def deterministic_summary(finding: dict[str, Any]) -> dict[str, Any]:
    relevance = finding["relevance"]
    evidence = finding["evidence"]
    areas = relevance["backendHits"] + relevance["vendorHits"]
    scope = ", ".join(areas) if areas else "Dawn/Tint"
    return {
        "summary": f"{finding['title']} ({finding['status']}); scope signals: {scope}.",
        "doeImpact": (
            "Review changed files and linked issue evidence against Doe compiler, "
            "runtime, CTS, and quirk behavior before promotion."
        ),
        "failureMechanism": "Not established by deterministic normalization.",
        "recommendedAction": "triage",
        "confidence": "unassessed",
        "citations": [
            evidence["gerritUrl"],
            *[
                f"https://issues.chromium.org/issues/{issue_id}"
                for issue_id in evidence["issueIds"]
            ],
        ],
    }
