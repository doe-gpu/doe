"""Command line interface for Dawn/Tint upstream intelligence."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Sequence

from pipeline.upstream_intelligence.pipeline import IntelligencePipeline


REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_CONFIG = REPO_ROOT / "config" / "upstream-intelligence.json"


def _issue_ids(value: str) -> list[int]:
    if not value:
        return []
    return [int(item.strip()) for item in value.split(",") if item.strip()]


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Synchronize and review Dawn/Tint upstream intelligence."
    )
    parser.add_argument("--config", type=Path, default=DEFAULT_CONFIG)
    parser.add_argument("--database", type=Path)
    parser.add_argument("--output-root", type=Path)
    parser.add_argument(
        "--require-llm",
        action="store_true",
        help="Fail if the configured model credential is unavailable.",
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    sync = subparsers.add_parser("sync")
    sync.add_argument("--issue-ids", default="")
    sync.add_argument("--source-manifest", action="append", type=Path, default=[])

    backfill = subparsers.add_parser("backfill")
    backfill.add_argument("--after", required=True)
    backfill.add_argument("--before", required=True)
    backfill.add_argument("--issue-ids", default="")
    backfill.add_argument("--source-manifest", action="append", type=Path, default=[])

    replay = subparsers.add_parser("replay")
    replay.add_argument("inputs", nargs="+", type=Path)
    replay.add_argument("--issue-ids", default="")
    replay.add_argument("--source-manifest", action="append", type=Path, default=[])
    replay.add_argument("--fail-on-rejection", action="store_true")

    gate = subparsers.add_parser("gate")
    gate.add_argument("--finding-id", required=True)
    gate.add_argument("--decision", choices=("approved", "rejected"), required=True)
    gate.add_argument("--reviewer", required=True)
    gate.add_argument("--reason", required=True)
    gate.add_argument("--output", type=Path, required=True)

    subparsers.add_parser("status")
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    pipeline = IntelligencePipeline(
        config_path=args.config,
        database_path=args.database,
        output_root=args.output_root,
        require_llm=args.require_llm,
    )
    if args.command == "sync":
        result = pipeline.sync(
            _issue_ids(args.issue_ids),
            source_manifest_paths=args.source_manifest,
        )
    elif args.command == "backfill":
        result = pipeline.backfill(
            after=args.after,
            before=args.before,
            explicit_issue_ids=_issue_ids(args.issue_ids),
            source_manifest_paths=args.source_manifest,
        )
    elif args.command == "replay":
        result = pipeline.replay(
            args.inputs,
            explicit_issue_ids=_issue_ids(args.issue_ids),
            source_manifest_paths=args.source_manifest,
            fail_on_rejection=args.fail_on_rejection,
        )
    elif args.command == "gate":
        result = pipeline.promote(
            finding_id=args.finding_id,
            decision=args.decision,
            reviewer=args.reviewer,
            reason=args.reason,
            output_path=args.output,
        )
    else:
        result = pipeline.status()
    print(json.dumps(result, indent=2, sort_keys=True))
    if args.command in {"sync", "backfill", "replay"}:
        return 0 if result["operationalSuccess"] else 2
    return 0
