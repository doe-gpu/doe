#!/usr/bin/env python3
"""HTML rendering helpers for the benchmark inventory dashboard."""

from __future__ import annotations

from pathlib import Path
from typing import Any

from bench.lib import visual_report_theme

safe_float = visual_report_theme.safe_float
format_delta = visual_report_theme.format_delta


def infer_matrix_lane(matrix_id: str) -> str:
    token = matrix_id.lower()
    if ".release" in token:
        return "release"
    if ".directional" in token:
        return "directional"
    if ".smoke" in token:
        return "smoke"
    if ".macro" in token:
        return "macro"
    if ".extended.comparable" in token:
        return "extended-comparable"
    if ".extended" in token:
        return "extended"
    return "default"


def metric_class(value: float | None) -> str:
    tone = visual_report_theme.delta_tone(value)
    if tone == "good":
        return "metric-positive"
    if tone == "bad":
        return "metric-negative"
    return "metric-neutral"


def build_dashboard_html(
    inventory: dict[str, Any],
    *,
    max_recent_reports: int,
    dashboard_path: str | Path | None = None,
) -> str:
    summary = inventory.get("summary", {})
    matrices = inventory.get("matrices", [])
    profiles = inventory.get("profiles", [])
    reports = inventory.get("reports", [])
    generated_at = str(inventory.get("generatedAtUtc", ""))
    inventory_path = str(inventory.get("inventoryPath", ""))

    inventory_link = ""
    if dashboard_path and inventory_path:
        href = visual_report_theme.relative_href(dashboard_path, inventory_path)
        inventory_link = f"inventory artifact: <a href='{href}'><code>{Path(inventory_path).name}</code></a>"
    elif inventory_path:
        inventory_link = f"inventory artifact: <code>{inventory_path}</code>"

    cards_html = "".join(
        [
            visual_report_theme.stat_card(
                "Reports",
                str(summary.get("includedReports", 0)),
                tone="neutral",
                detail="Conforming compare reports included in the inventory.",
            ),
            visual_report_theme.stat_card(
                "Matrices",
                str(summary.get("matrixCount", 0)),
                tone="neutral",
                detail="Distinct compare surfaces tracked by matrix ID.",
            ),
            visual_report_theme.stat_card(
                "Profiles",
                str(summary.get("uniqueProfileCount", 0)),
                tone="neutral",
                detail="Unique hardware and driver profiles represented.",
            ),
            visual_report_theme.stat_card(
                "Comparable",
                str(summary.get("comparableReportCount", 0)),
                tone="good",
                detail="Reports whose latest conformance status is comparable.",
            ),
            visual_report_theme.stat_card(
                "Claimable",
                str(summary.get("claimableReportCount", 0)),
                tone="good",
                detail="Reports whose latest claim status is claimable.",
            ),
            visual_report_theme.stat_card(
                "Comparable + claimable",
                str(summary.get("claimableComparableReportCount", 0)),
                tone="good",
                detail="Reports that are both comparable and claimable.",
            ),
        ]
    )

    matrix_rows: list[str] = []
    for matrix in matrices:
        if not isinstance(matrix, dict):
            continue
        latest = matrix.get("latest", {})
        if not isinstance(latest, dict):
            latest = {}
        matrix_id = str(matrix.get("matrixId", "unknown"))
        lane = str(matrix.get("lane", infer_matrix_lane(matrix_id)))
        comparison_status = str(latest.get("comparisonStatus", "unknown"))
        claim_status = str(latest.get("claimStatus", "unknown"))
        delta_value = safe_float(latest.get("overallP50DeltaPercent"))
        matrix_rows.append(
            "<tr>"
            f"<td><code>{matrix_id}</code></td>"
            f"<td>{visual_report_theme.badge(lane, tone='info')}</td>"
            f"<td>{str(latest.get('generatedAtUtc', ''))}</td>"
            f"<td>{visual_report_theme.badge(comparison_status, tone=visual_report_theme.status_tone(comparison_status))}</td>"
            f"<td>{visual_report_theme.badge(claim_status, tone=visual_report_theme.status_tone(claim_status, kind='claim'))}</td>"
            f"<td>{str(latest.get('workloadCount', 0))}</td>"
            f"<td>{str(latest.get('nonComparableCount', 0))}</td>"
            f"<td>{str(latest.get('nonClaimableCount', 0))}</td>"
            f"<td class='{metric_class(delta_value)}'>{format_delta(delta_value)}</td>"
            f"<td><code>{str(latest.get('sourcePath', ''))}</code></td>"
            "</tr>"
        )

    profile_rows: list[str] = []
    for profile in profiles:
        if not isinstance(profile, dict):
            continue
        family = str(profile.get("deviceFamily", "")) or "-"
        profile_rows.append(
            "<tr>"
            f"<td><code>{str(profile.get('vendor', ''))} / {str(profile.get('api', ''))} / {family} / {str(profile.get('driver', ''))}</code></td>"
            f"<td>{str(profile.get('reportCount', 0))}</td>"
            f"<td>{str(profile.get('sampleCount', 0))}</td>"
            f"<td>{', '.join(str(x) for x in profile.get('sides', []))}</td>"
            f"<td>{str(profile.get('matrixCount', 0))}</td>"
            f"<td>{str(profile.get('firstSeenUtc', ''))}</td>"
            f"<td>{str(profile.get('lastSeenUtc', ''))}</td>"
            "</tr>"
        )

    recent_rows: list[str] = []
    recent_count = 0
    for report in reports:
        if recent_count >= max_recent_reports:
            break
        if not isinstance(report, dict):
            continue
        matrix_id = str(report.get("matrixId", "unknown"))
        lane = str(report.get("lane", infer_matrix_lane(matrix_id)))
        comparison_status = str(report.get("comparisonStatus", "unknown"))
        claim_status = str(report.get("claimStatus", "unknown"))
        delta_value = safe_float(report.get("overallP50DeltaPercent"))
        recent_rows.append(
            "<tr>"
            f"<td>{str(report.get('generatedAtUtc', ''))}</td>"
            f"<td><code>{matrix_id}</code></td>"
            f"<td>{visual_report_theme.badge(lane, tone='info')}</td>"
            f"<td>{visual_report_theme.badge(comparison_status, tone=visual_report_theme.status_tone(comparison_status))}</td>"
            f"<td>{visual_report_theme.badge(claim_status, tone=visual_report_theme.status_tone(claim_status, kind='claim'))}</td>"
            f"<td class='{metric_class(delta_value)}'>{format_delta(delta_value)}</td>"
            f"<td>{str(report.get('workloadCount', 0))}</td>"
            f"<td><code>{str(report.get('sourcePath', ''))}</code></td>"
            "</tr>"
        )
        recent_count += 1

    body_html = (
        "<section class='section'>"
        "<div class='section-head'>"
        "<div>"
        "<h2>Inventory pulse</h2>"
        "<div class='section-copy'>A quick read on how much of the benchmark corpus is comparable, claimable, and represented across real driver profiles.</div>"
        "</div>"
        "</div>"
        f"<div class='stat-grid'>{cards_html}</div>"
        "</section>"
        "<section class='section'>"
        "<div class='section-head'>"
        "<div>"
        "<h2>Latest matrix status</h2>"
        "<div class='section-copy'>Latest report per matrix, lane, and host profile. Positive deltas mean Doe is faster because Doe remains the baseline side in compare reports.</div>"
        "</div>"
        "</div>"
        "<div class='table-shell'><table><thead><tr>"
        "<th>Matrix</th><th>Lane</th><th>Latest UTC</th><th>Comparison</th><th>Claim</th><th>Workloads</th><th>Non-comparable</th><th>Non-claimable</th><th>p50 delta</th><th>Source</th>"
        "</tr></thead><tbody>"
        + ("".join(matrix_rows) if matrix_rows else "<tr><td colspan='10'>No matrix rows.</td></tr>")
        + "</tbody></table></div>"
        "</section>"
        "<section class='section'>"
        "<div class='section-head'>"
        "<div>"
        "<h2>Tested hardware and driver profiles</h2>"
        "<div class='section-copy'>Profiles aggregate across all included compare reports, which makes it easy to see where the current evidence base is thin or concentrated.</div>"
        "</div>"
        "</div>"
        "<div class='table-shell'><table><thead><tr>"
        "<th>Profile</th><th>Reports</th><th>Samples</th><th>Sides</th><th>Matrices</th><th>First seen</th><th>Last seen</th>"
        "</tr></thead><tbody>"
        + ("".join(profile_rows) if profile_rows else "<tr><td colspan='7'>No profile rows.</td></tr>")
        + "</tbody></table></div>"
        "</section>"
        "<section class='section'>"
        "<div class='section-head'>"
        "<div>"
        "<h2>Recent reports</h2>"
        "<div class='section-copy'>A chronological slice for quickly spotting when a lane flips status or when a new report lands with materially different p50 behavior.</div>"
        "</div>"
        "</div>"
        "<div class='table-shell'><table><thead><tr>"
        "<th>Generated UTC</th><th>Matrix</th><th>Lane</th><th>Comparison</th><th>Claim</th><th>p50 delta</th><th>Workloads</th><th>Source</th>"
        "</tr></thead><tbody>"
        + ("".join(recent_rows) if recent_rows else "<tr><td colspan='8'>No recent reports.</td></tr>")
        + "</tbody></table></div>"
        "</section>"
    )

    meta_parts = [f"generated: <code>{generated_at}</code>"]
    if inventory_link:
        meta_parts.append(inventory_link)

    return visual_report_theme.render_page(
        title="Doe benchmark inventory",
        eyebrow="Doe evidence inventory",
        headline="Inventory dashboard",
        intro=(
            "A repository-wide view of comparable and claimable benchmark coverage across "
            "native, Node, and Bun surfaces."
        ),
        meta_html=" | ".join(meta_parts),
        body_html=body_html,
    )
