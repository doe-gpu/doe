#!/usr/bin/env python3
"""Run every promoted external-project harness as a blocking release suite."""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

REPO_ROOT = Path(__file__).resolve().parents[2]
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from bench.gates.external_project_release_gate import evaluate
from bench.external_project_reproduction import (
    ReproductionError,
    reproduction_plan,
    reproduce_external_project,
    resolve_selection,
)
from bench.lib.ecosystem_registry import load_json_object


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", default=str(REPO_ROOT))
    parser.add_argument("--registry", default="config/ecosystem-registry.json")
    parser.add_argument(
        "--policy", default="config/external-project-promotion-policy.json"
    )
    parser.add_argument(
        "--out", default="bench/out/external-projects/release-suite.json"
    )
    parser.add_argument("--require-promoted", action="store_true")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument(
        "--offline",
        action="store_true",
        help="Require pinned upstream commits to exist locally",
    )
    return parser.parse_args()


def promoted_harnesses(registry: dict[str, Any]) -> list[tuple[str, str]]:
    harnesses: list[tuple[str, str]] = []
    for actor in registry.get("actors", []):
        if not isinstance(actor, dict) or actor.get("promotionStatus") != "promoted":
            continue
        for harness in actor.get("harnesses", []):
            if not isinstance(harness, dict) or not isinstance(harness.get("manifestPath"), str):
                continue
            manifest = load_json_object(root / harness["manifestPath"])
            release_policy = manifest.get("releasePolicy", {})
            if release_policy.get("promotionState") != "promoted":
                continue
            command = release_policy.get("command", [])
            if isinstance(command, list) and all(
                isinstance(item, str) for item in command
            ):
                harnesses.append((str(actor.get("id")), str(harness.get("id"))))
    return harnesses


def main() -> int:
    args = parse_args()
    root = Path(args.root).resolve()
    try:
        registry = load_json_object(root / args.registry)
        policy = load_json_object(root / args.policy)
        check = evaluate(root, registry, policy)
        harnesses = promoted_harnesses(registry)
    except (OSError, UnicodeError, json.JSONDecodeError, ValueError) as exc:
        print(f"FAIL: external project release input error: {exc}")
        return 1
    if not check["ok"]:
        for item in check["failures"]:
            print(f"FAIL [{item['code']}] {item['path']}: {item['message']}")
        return 1
    if args.require_promoted and not harnesses:
        print("FAIL: no promoted external-project harnesses")
        return 1

    results: list[dict[str, Any]] = []
    failed = False
    release_id = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    for actor_id, harness_id in harnesses:
        run_id = f"release-{release_id}-{actor_id}-{harness_id}"
        try:
            selection = resolve_selection(
                root,
                actor_id,
                harness_id,
                run_id=run_id,
            )
            plan = reproduction_plan(selection, offline=args.offline)
            print(
                f"[external-release] {actor_id}/{harness_id}: "
                f"{' '.join(plan['workloadCommand'])}",
                flush=True,
            )
            if args.dry_run:
                status = "planned"
                return_code = 0
                receipt_path = None
                receipt_sha256 = None
            else:
                receipt, resolved_receipt_path = reproduce_external_project(
                    selection,
                    offline=args.offline,
                )
                status = receipt["status"]
                return_code = 0 if status == "passed" else 1
                receipt_path = str(resolved_receipt_path.relative_to(root))
                receipt_sha256 = receipt["receiptSha256"]
        except (
            OSError,
            UnicodeError,
            json.JSONDecodeError,
            ValueError,
            ReproductionError,
        ) as exc:
            status = "failed"
            return_code = 1
            receipt_path = None
            receipt_sha256 = None
            print(
                f"FAIL: external release reproduction {actor_id}/{harness_id}: {exc}",
                flush=True,
            )
        results.append(
            {
                "actorId": actor_id,
                "harnessId": harness_id,
                "status": status,
                "returnCode": return_code,
                "reproductionReceiptPath": receipt_path,
                "reproductionReceiptSha256": receipt_sha256,
            }
        )
        failed = failed or return_code != 0

    payload = {
        "schemaVersion": 1,
        "artifactKind": "external-project-release-suite-run",
        "generatedAt": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        "promotionPolicyVersion": policy.get("policyVersion"),
        "dryRun": args.dry_run,
        "status": "failed" if failed else "passed",
        "promotedHarnessCount": len(harnesses),
        "results": results,
    }
    if not args.dry_run:
        out_path = root / args.out
        out_path.parent.mkdir(parents=True, exist_ok=True)
        out_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
    if failed:
        print("FAIL: promoted external-project release suite")
        return 1
    print(f"PASS: promoted external-project release suite ({len(harnesses)} harnesses)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
