#!/usr/bin/env python3
"""Source-bound cross-runtime golden oracles for compute-heavy command graphs.

These exact hashes record byte-identical outputs from the Doe native Vulkan and
Dawn Vulkan execution paths. They preserve the reviewed physical graph-output
history. Independent CPU reference artifacts, when available, are owned by the
workload oracle contract rather than this consensus ledger.
"""

from __future__ import annotations

import argparse
import copy
import hashlib
import json
from pathlib import Path
from typing import Any, Iterator


REPO_ROOT = Path(__file__).resolve().parents[2]
IR_PATH = REPO_ROOT / "bench" / "ir" / "compute_heavy.json"
KERNEL_ROOT = REPO_ROOT / "bench" / "kernels"

MONTE_CARLO = "compute_monte_carlo_fixed_samples_131072paths_256samples_8bounces"
STABLE_FLUIDS = "compute_stable_fluids_multistage_256grid_18pressure_4steps"

EXPECTED_GRAPH_IDENTITIES = {
    MONTE_CARLO: "3f2a37ccacde24e1005e1546823e12d578259861be5906a0c222e864b449237e",
    STABLE_FLUIDS: "4d17928f8768bd86bb3b295ac7f1bc4cab0c9983533bc694f73300a64cc491fc",
}

EXPECTED_OUTPUT_SHA256 = {
    MONTE_CARLO: "f47066faec78e7459a09529f45ef9a09c1dd538e6688176599e545e915f78818",
    STABLE_FLUIDS: "d9d5f00c8c762f00b0539cdbf7474bb4288ef1d4c86d00297b0db0ba5a971839",
}


def _kernel_names(commands: list[dict[str, Any]]) -> Iterator[str]:
    for command in commands:
        if command.get("kind") == "kernel_dispatch":
            yield str(command["kernel"])
        elif command.get("kind") == "repeat":
            yield from _kernel_names(command["commands"])


def _scenario(workload: str) -> dict[str, Any]:
    payload = json.loads(IR_PATH.read_text(encoding="utf-8"))
    for scenario in payload["scenarios"]:
        if scenario["id"] == workload:
            result = copy.deepcopy(scenario)
            result.pop("outputOracle", None)
            return result
    raise ValueError(f"unknown compute-heavy workload: {workload}")


def graph_identity(workload: str) -> str:
    scenario = _scenario(workload)
    encoded = json.dumps(
        scenario,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")
    digest = hashlib.sha256(encoded)
    for kernel_name in sorted(set(_kernel_names(scenario["commands"]))):
        digest.update(b"\0kernel\0")
        digest.update(kernel_name.encode("utf-8"))
        digest.update(b"\0")
        digest.update((KERNEL_ROOT / kernel_name).read_bytes())
    return digest.hexdigest()


def expected_sha256(workload: str) -> str:
    expected_identity = EXPECTED_GRAPH_IDENTITIES.get(workload)
    if expected_identity is None:
        raise ValueError(f"unknown compute-heavy workload: {workload}")
    actual_identity = graph_identity(workload)
    if actual_identity != expected_identity:
        raise ValueError(
            f"compute-heavy graph identity changed for {workload}: "
            f"expected {expected_identity}, received {actual_identity}"
        )
    return EXPECTED_OUTPUT_SHA256[workload]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--workload", choices=sorted(EXPECTED_OUTPUT_SHA256), required=True)
    args = parser.parse_args()
    print(expected_sha256(args.workload))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
