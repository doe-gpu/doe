#!/usr/bin/env python3
"""Check browser capture and replay privacy policy discipline."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any


REPO_ROOT = Path(__file__).resolve().parents[2]
BENCH_ROOT = REPO_ROOT / "bench"
for _path_entry in (str(REPO_ROOT), str(BENCH_ROOT)):
    if _path_entry not in sys.path:
        sys.path.insert(0, _path_entry)

from bench.lib.bench_utils import load_json_object as load_json


REQUIRED_SURFACES = {
    "gpu_flight_recorder",
    "flight_replay",
    "shader_links",
    "media_path_probe",
    "pipeline_cache_receipts",
    "unsupported_explanations",
}
VALID_PERMISSION_GATES = {"devtools_opt_in", "secure_context_devtools_opt_in", "disabled"}
VALID_RAW_PAGE_DATA_POLICIES = {"hash", "redact", "forbid"}
VALID_ARTIFACT_DATA_POLICIES = {"metadata_only", "hashes_and_redacted_metadata"}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--policy", required=True, help="Browser capture policy JSON.")
    parser.add_argument("--json", action="store_true", dest="emit_json")
    return parser.parse_args()


def failure(code: str, path: str, message: str) -> dict[str, str]:
    return {"code": code, "path": path, "message": message}


def check_policy(payload: dict[str, Any]) -> list[dict[str, str]]:
    failures: list[dict[str, str]] = []
    surfaces = [row for row in payload.get("surfaces", []) if isinstance(row, dict)]
    seen: set[str] = set()
    for index, row in enumerate(surfaces):
        row_path = f"surfaces[{index}]"
        surface_id = str(row.get("surfaceId", ""))
        if surface_id in seen:
            failures.append(failure("duplicate_surface", f"{row_path}.surfaceId", f"duplicate surface {surface_id!r}"))
        seen.add(surface_id)
        if row.get("originScoped") is not True:
            failures.append(failure("not_origin_scoped", f"{row_path}.originScoped", "capture surfaces must be origin-scoped"))
        if row.get("permissionGate") not in VALID_PERMISSION_GATES:
            failures.append(failure("invalid_permission_gate", f"{row_path}.permissionGate", "permissionGate must use the browser capture policy taxonomy"))
        if row.get("permissionGate") == "disabled" and row.get("developerVisible") is True:
            failures.append(failure("visible_surface_disabled", f"{row_path}.permissionGate", "developer-visible surfaces need a permission gate"))
        if row.get("rawPageDataPolicy") not in VALID_RAW_PAGE_DATA_POLICIES:
            failures.append(failure("invalid_raw_page_data_policy", f"{row_path}.rawPageDataPolicy", "raw page data must be hashed, redacted, or forbidden"))
        if row.get("artifactDataPolicy") not in VALID_ARTIFACT_DATA_POLICIES:
            failures.append(failure("invalid_artifact_data_policy", f"{row_path}.artifactDataPolicy", "artifact data must be metadata-only or hashed/redacted metadata"))
        if row.get("replayAllowed") is True and row.get("permissionGate") != "secure_context_devtools_opt_in":
            failures.append(failure("replay_without_secure_gate", f"{row_path}.permissionGate", "replay surfaces require secure-context devtools opt-in"))
        if row.get("replayAllowed") is True and row.get("developerVisible") is not True:
            failures.append(failure("replay_not_developer_visible", f"{row_path}.developerVisible", "replay surfaces must be developer-visible"))
        if row.get("replayAllowed") is False and not row.get("reasonCode"):
            failures.append(failure("missing_non_replay_reason", f"{row_path}.reasonCode", "non-replay surfaces require reasonCode"))

    for surface_id in sorted(REQUIRED_SURFACES - seen):
        failures.append(failure("missing_surface", "surfaces", f"missing capture policy surface {surface_id}"))
    return failures


def main() -> int:
    args = parse_args()
    failures = check_policy(load_json(Path(args.policy)))
    report = {
        "schemaVersion": 1,
        "artifactKind": "browser_capture_policy_check",
        "status": "fail" if failures else "pass",
        "failures": failures,
    }
    if args.emit_json:
        print(json.dumps(report, indent=2))
    elif failures:
        print("FAIL: browser capture policy")
        for item in failures:
            print(f"- {item['code']}: {item['path']}: {item['message']}")
    else:
        print("PASS: browser capture policy")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
