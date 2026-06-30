#!/usr/bin/env python3
"""Validate Doe public claim/reporting surfaces."""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CLAIM_INDEX = ROOT / "reports" / "claim-index.json"

PUBLIC_DOCS = [
    ROOT / "README.md",
    ROOT / "packages" / "README.md",
    ROOT / "packages" / "doe-gpu" / "README.md",
    ROOT / "docs" / "internal-tooling.md",
    ROOT / "docs" / "public-claim-boundary.md",
    ROOT / "docs" / "runtime-surface-boundary.md",
    ROOT / "docs" / "backend-evidence-matrix.md",
]

STALE_ASSET_PATTERNS = [
    "assets/readme/package-claims.svg",
    "assets/readme/ort-claims.svg",
    "assets/readme/this-machine-results.svg",
    "assets/readme/benchmark-claims.json",
    "packages/doe-gpu/assets/package-results.svg",
    "./assets/package-results.svg",
]
STALE_ASSET_POLICY_DOCS = {"docs/public-claim-boundary.md"}

CLAIM_STATES = {"claim-indexed", "diagnostic", "status-only", "scaffolded"}
METRIC_DIRECTIONS = {"lower-is-better", "higher-is-better", "status-only"}
REQUIRED_ENTRY_FIELDS = {"id", "surface", "backend", "comparison", "metricDirection", "claimState"}
PERCENT_PATTERN = re.compile(r"(?<![A-Za-z0-9_])[+-]\d+(?:\.\d+)?%")


def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def fail(errors: list[str], message: str) -> None:
    errors.append(message)


def validate_claim_index(errors: list[str]) -> None:
    data = json.loads(read_text(CLAIM_INDEX))
    if data.get("kind") != "doe-claim-index":
        fail(errors, "reports/claim-index.json kind must be doe-claim-index")

    entries = data.get("entries")
    if not isinstance(entries, list) or not entries:
        fail(errors, "reports/claim-index.json entries must be a non-empty list")
        return

    seen_ids: set[str] = set()
    for index, entry in enumerate(entries):
        label = f"reports/claim-index.json entries[{index}]"
        if not isinstance(entry, dict):
            fail(errors, f"{label} must be an object")
            continue

        missing = sorted(field for field in REQUIRED_ENTRY_FIELDS if not entry.get(field))
        if missing:
            fail(errors, f"{label} missing required fields: {', '.join(missing)}")

        entry_id = entry.get("id")
        if entry_id in seen_ids:
            fail(errors, f"{label} duplicate id: {entry_id}")
        if isinstance(entry_id, str):
            seen_ids.add(entry_id)

        claim_state = entry.get("claimState")
        if claim_state not in CLAIM_STATES:
            fail(errors, f"{label} has invalid claimState: {claim_state}")

        metric_direction = entry.get("metricDirection")
        if metric_direction not in METRIC_DIRECTIONS:
            fail(errors, f"{label} has invalid metricDirection: {metric_direction}")

        report_path = entry.get("reportPath")
        if claim_state in {"claim-indexed", "diagnostic"} and not report_path:
            fail(errors, f"{label} with claimState={claim_state} must include reportPath")
        if isinstance(report_path, str):
            if Path(report_path).is_absolute() or ".." in Path(report_path).parts:
                fail(errors, f"{label} reportPath must be repo-relative and not traverse parents")
            if not report_path.endswith(".json"):
                fail(errors, f"{label} reportPath must point at a JSON artifact")

        if claim_state in {"claim-indexed", "diagnostic"}:
            if not entry.get("comparisonStatus"):
                fail(errors, f"{label} must include comparisonStatus for measured evidence")
            if not entry.get("claimStatus"):
                fail(errors, f"{label} must include claimStatus for measured evidence")

        claim_path = entry.get("claimPath")
        if claim_state == "claim-indexed" and not claim_path:
            fail(errors, f"{label} with claimState=claim-indexed must include claimPath")
        if isinstance(claim_path, str):
            if Path(claim_path).is_absolute() or ".." in Path(claim_path).parts:
                fail(errors, f"{label} claimPath must be repo-relative and not traverse parents")
            if not claim_path.endswith(".json"):
                fail(errors, f"{label} claimPath must point at a JSON artifact")


def validate_public_docs(errors: list[str]) -> None:
    for path in PUBLIC_DOCS:
        if not path.exists():
            fail(errors, f"{path.relative_to(ROOT)} is missing")
            continue
        text = read_text(path)
        rel = path.relative_to(ROOT)

        if rel.as_posix() not in STALE_ASSET_POLICY_DOCS:
            for stale in STALE_ASSET_PATTERNS:
                if stale in text:
                    fail(errors, f"{rel} references stale claim/report asset: {stale}")

        if rel.as_posix() == "packages/doe-gpu/README.md":
            for match in PERCENT_PATTERN.finditer(text):
                fail(errors, f"{rel} hardcodes package benchmark percentage: {match.group(0)}")

    readme = read_text(ROOT / "README.md")
    if "assets/readme/backend-evidence-summary.svg" not in readme:
        fail(errors, "README.md must reference assets/readme/backend-evidence-summary.svg")
    if "reports/claim-index.json" not in readme:
        fail(errors, "README.md must reference reports/claim-index.json")

    package_readme = read_text(ROOT / "packages" / "doe-gpu" / "README.md")
    if "claim-indexed" not in package_readme or "diagnostic" not in package_readme:
        fail(errors, "packages/doe-gpu/README.md must explain claim-indexed and diagnostic evidence")
    if "browser's incumbent WebGPU" not in package_readme:
        fail(errors, "packages/doe-gpu/README.md must keep doe-gpu/browser boundary explicit")


def main() -> int:
    errors: list[str] = []
    validate_claim_index(errors)
    validate_public_docs(errors)

    if errors:
        for error in errors:
            print(f"public-claim-surface check failed: {error}", file=sys.stderr)
        return 1

    print("public-claim-surface check passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
