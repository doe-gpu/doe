#!/usr/bin/env python3
"""Gate the Qwen Cerebras lane's no-hardware readiness classification."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any


REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_SNAPSHOT = REPO_ROOT / "bench/out/r3-cerebras-status/snapshot.json"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--snapshot",
        type=Path,
        default=DEFAULT_SNAPSHOT,
        help="Snapshot JSON emitted by bench/tools/cerebras_status_snapshot.py.",
    )
    return parser.parse_args()


def load_json(path: Path) -> dict[str, Any]:
    if not path.is_file():
        raise FileNotFoundError(
            f"snapshot not found: {path}. "
            "Run python3 bench/tools/cerebras_status_snapshot.py first."
        )
    payload = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(payload, dict):
        raise ValueError(f"snapshot must be a JSON object: {path}")
    return payload


def row_lanes(rows: list[Any]) -> set[str]:
    lanes = set()
    for row in rows:
        if isinstance(row, dict) and isinstance(row.get("lane"), str):
            lanes.add(row["lane"])
    return lanes


def validate_readiness(snapshot: dict[str, Any]) -> list[str]:
    errors: list[str] = []
    readiness = snapshot.get("localReadiness")
    if not isinstance(readiness, dict):
        return ["snapshot.localReadiness is missing"]

    if readiness.get("schemaVersion") != 1:
        errors.append("localReadiness.schemaVersion must be 1")
    if readiness.get("lane") != "qwen.no_hardware_readiness":
        errors.append("localReadiness.lane must be qwen.no_hardware_readiness")
    if readiness.get("verdict") != "classified":
        errors.append(
            "localReadiness.verdict must be classified; "
            f"got {readiness.get('verdict')!r}"
        )
    if readiness.get("notHardwareClaim") is not True:
        errors.append("localReadiness.notHardwareClaim must be true")
    if readiness.get("errors"):
        errors.append(f"localReadiness.errors must be empty: {readiness['errors']!r}")
    next_commands = readiness.get("nextCommands")
    if not isinstance(next_commands, list) or not next_commands:
        errors.append("localReadiness.nextCommands must be a non-empty list")
        next_commands = []
    next_command_lanes = row_lanes(next_commands)
    required_next_command_lanes = {
        "qwen.doppler_csl_splice.selected_logit",
        "qwen.frozen_reference_validation",
        "qwen.simfabric_cells",
        "qwen.no_hardware_readiness",
        "qwen.hardware_full_prompt",
    }
    missing_next_command_lanes = sorted(
        required_next_command_lanes - next_command_lanes
    )
    if missing_next_command_lanes:
        errors.append(
            "nextCommands missing lanes: "
            f"{', '.join(missing_next_command_lanes)}"
        )
    for command in next_commands:
        if not isinstance(command, dict):
            errors.append("nextCommands entries must be objects")
            continue
        if not isinstance(command.get("command"), str) or not command["command"]:
            errors.append(
                f"nextCommands command missing for {command.get('lane')!r}"
            )
        if not isinstance(command.get("purpose"), str) or not command["purpose"]:
            errors.append(
                f"nextCommands purpose missing for {command.get('lane')!r}"
            )
        if not isinstance(command.get("hardwareRequired"), bool):
            errors.append(
                "nextCommands hardwareRequired must be boolean "
                f"for {command.get('lane')!r}"
            )

    accepted_lanes = row_lanes(readiness.get("acceptedLocalRows") or [])
    typed_lanes = row_lanes(readiness.get("typedLocalBlockers") or [])
    hardware_lanes = row_lanes(readiness.get("hardwareRequiredRows") or [])
    required_positive = {
        "compile.cross_model_parity",
        "qwen.doppler_csl_splice.selected_logit",
        "qwen.simfabric_cells",
    }
    missing_positive = sorted(required_positive - accepted_lanes)
    if missing_positive:
        errors.append(f"acceptedLocalRows missing: {', '.join(missing_positive)}")

    required_typed = {
        "qwen.frozen_reference_validation",
        "qwen.per_kernel.summary",
        "qwen.local_simfabric_ceiling",
        "qwen.multi_token_decode",
    }
    missing_typed = sorted(required_typed - accepted_lanes - typed_lanes)
    if missing_typed:
        errors.append(f"typed local blocker rows missing: {', '.join(missing_typed)}")

    if "qwen.hardware_full_prompt" not in hardware_lanes | accepted_lanes:
        errors.append("qwen.hardware_full_prompt must be bound or hardware_required")
    for row in readiness.get("hardwareRequiredRows") or []:
        if not isinstance(row, dict):
            errors.append("hardwareRequiredRows entries must be objects")
            continue
        if row.get("blocker") != "hardware_endpoint_required":
            errors.append(
                "hardwareRequiredRows blocker must be hardware_endpoint_required "
                f"for {row.get('lane')!r}"
            )
    return errors


def main() -> int:
    args = parse_args()
    try:
        snapshot = load_json(args.snapshot)
    except (FileNotFoundError, json.JSONDecodeError, ValueError) as exc:
        sys.stderr.write(f"cerebras-no-hardware-readiness: {exc}\n")
        return 1
    errors = validate_readiness(snapshot)
    if errors:
        for error in errors:
            sys.stderr.write(f"cerebras-no-hardware-readiness: {error}\n")
        return 1
    readiness = snapshot["localReadiness"]
    sys.stdout.write(
        "cerebras-no-hardware-readiness: "
        f"{readiness['verdict']} ({readiness['summary']})\n"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
