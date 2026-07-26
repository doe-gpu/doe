"""Human-readable packets and machine run receipts."""

from __future__ import annotations

from typing import Any


def render_review_packet(
    run: dict[str, Any],
    rows: list[tuple[dict[str, Any], dict[str, Any]]],
) -> str:
    lines = [
        "# Dawn/Tint upstream intelligence",
        "",
        f"- Run: `{run['runId']}`",
        f"- Mode: `{run['mode']}`",
        f"- Gerrit events observed: {run['counts']['gerritObserved']}",
        f"- New event versions: {run['counts']['eventsInserted']}",
        f"- Relevant findings: {run['counts']['relevantFindings']}",
        f"- Findings enriched: {run['counts']['findingsEnriched']}",
        f"- Issue enrichments: {run['counts']['issuesFetched']}",
        f"- Issue failures: {len(run['issueFetchFailures'])}",
        f"- Issue IDs deferred: {len(run['issueFetchDeferred'])}",
        f"- Issue IDs unavailable: {len(run['issueUnavailable'])}",
        f"- Rejected input rows: {len(run['inputRejections'])}",
        f"- Enrichments deferred: {len(run['enrichmentDeferred'])}",
        f"- Enrichment failures: {len(run['enrichmentFailures'])}",
        f"- Operational success: `{str(run['operationalSuccess']).lower()}`",
        f"- Source coverage complete: `{str(run['sourceCoverageComplete']).lower()}`",
        f"- Enrichment complete: `{str(run['enrichmentComplete']).lower()}`",
        f"- Overall coverage complete: `{str(run['coverageComplete']).lower()}`",
        "",
        (
            "Model output is triage evidence only. Runtime behavior requires a "
            "separate promotion receipt."
        ),
        "",
    ]
    for finding, enrichment in rows:
        output = enrichment["output"]
        relevance = finding["relevance"]
        evidence = finding["evidence"]
        lines.extend(
            [
                f"## {finding['findingId']}: {finding['title']}",
                "",
                f"- Status: `{finding['status']}`",
                f"- Score: {relevance['score']} / {relevance['threshold']}",
                f"- Enrichment: `{enrichment['provider']}/{enrichment['model']}`",
                f"- Action: `{output['recommendedAction']}`",
                f"- Confidence: `{output['confidence']}`",
                f"- Gerrit: {evidence['gerritUrl']}",
                f"- Issues: {', '.join(str(value) for value in evidence['issueIds']) or 'none'}",
                f"- Backends: {', '.join(relevance['backendHits']) or 'none'}",
                f"- Vendors: {', '.join(relevance['vendorHits']) or 'none'}",
                (
                    "- Source corroboration: "
                    + (
                        ", ".join(
                            signal["sourcePath"]
                            for signal in evidence["sourceCorroboration"]
                        )
                        or "none"
                    )
                ),
                "",
                output["summary"],
                "",
                f"**Doe impact:** {output['doeImpact']}",
                "",
                f"**Mechanism:** {output['failureMechanism']}",
                "",
            ]
        )
    if run["issueFetchFailures"]:
        lines.extend(["## Issue enrichment failures", ""])
        for failure in run["issueFetchFailures"]:
            lines.append(
                f"- `{failure['issueId']}` ({failure['code']}): {failure['error']}"
            )
        lines.append("")
    if run["issueUnavailable"]:
        lines.extend(
            [
                "## Non-public or missing issues",
                "",
                *[f"- `{issue_id}`" for issue_id in run["issueUnavailable"]],
                "",
            ]
        )
    if run["issueFetchDeferred"]:
        lines.extend(
            [
                "## Deferred issue queue",
                "",
                *[f"- `{issue_id}`" for issue_id in run["issueFetchDeferred"]],
                "",
            ]
        )
    if run["inputRejections"]:
        lines.extend(["## Rejected input rows", ""])
        for rejection in run["inputRejections"]:
            lines.append(
                f"- `{rejection['path']}:{rejection['line']}` "
                f"(`{rejection['lineHash']}`): {rejection['error']}"
            )
        lines.append("")
    if run["enrichmentDeferred"]:
        lines.extend(["## Deferred enrichment queue", ""])
        for finding_id in run["enrichmentDeferred"]:
            lines.append(f"- `{finding_id}`")
        lines.append("")
    if run["enrichmentFailures"]:
        lines.extend(["## Enrichment failures", ""])
        for failure in run["enrichmentFailures"]:
            lines.append(f"- `{failure['findingId']}`: {failure['error']}")
        lines.append("")
    return "\n".join(lines)
