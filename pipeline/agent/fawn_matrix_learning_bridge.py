#!/usr/bin/env python3
"""Route Fawn matrix failures and signed promotions into DoeLab records."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
from typing import Any

from bench.fawn_matrix.harness.live_evidence import (
    canonical_hash,
    verify_promotion_receipt,
)
from pipeline.agent.mine_upstream_quirks import build_hash_chain


def load_json(path: Path) -> dict[str, Any]:
    with path.open(encoding="utf-8") as handle:
        return json.load(handle)


def failure_records(raw: dict[str, Any], source_path: Path) -> dict[str, Any]:
    records = []
    for lane_id, lane in sorted(raw.get("lanes", {}).items()):
        for sample in lane.get("samples", []):
            if sample.get("success") and sample.get("oraclePass"):
                continue
            identity = {
                "workloadId": raw.get("workloadId"),
                "lane": lane_id,
                "phase": sample.get("phase"),
                "iteration": sample.get("iteration"),
            }
            records.append({
                "recordKind": "doe-lab-matrix-failure-v1",
                "failureId": canonical_hash(identity),
                **identity,
                "runtimeIdentity": lane.get("runtimeIdentity"),
                "adapterInfo": lane.get("adapterInfo"),
                "sample": sample,
            })
    for error in raw.get("errors", []):
        identity = {"workloadId": raw.get("workloadId"), **error}
        records.append({
            "recordKind": "doe-lab-matrix-failure-v1",
            "failureId": canonical_hash(identity),
            **identity,
        })
    records.sort(key=lambda item: item["failureId"])
    return {
        "schemaVersion": 1,
        "manifestKind": "doe-lab-fawn-matrix-learning-v1",
        "sourceArtifact": str(source_path),
        "sourceSha256": hashlib.sha256(source_path.read_bytes()).hexdigest(),
        "recordCount": len(records),
        "hashChain": build_hash_chain([
            {"quirkId": record["failureId"], **record}
            for record in records
        ]),
        "records": records,
    }


def promotion_record(suite: dict[str, Any], source_path: Path) -> dict[str, Any]:
    subject = {
        key: value
        for key, value in suite.items()
        if key not in {"promotionReceipt", "reportHash"}
    }
    verify_promotion_receipt(subject, suite["promotionReceipt"])
    return {
        "schemaVersion": 1,
        "recordKind": "doe-lab-matrix-promotion-v1",
        "sourceArtifact": str(source_path),
        "sourceSha256": hashlib.sha256(source_path.read_bytes()).hexdigest(),
        "platform": suite["platform"],
        "earnedComponents": suite["earnedComponents"],
        "promotionReceipt": suite["promotionReceipt"],
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--raw", type=Path)
    parser.add_argument("--suite", type=Path)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    if bool(args.raw) == bool(args.suite):
        parser.error("exactly one of --raw or --suite is required")
    source = args.raw or args.suite
    payload = load_json(source)
    result = failure_records(payload, source) if args.raw else promotion_record(payload, source)
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(args.out)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
