"""CLI for Cloudflare Browser Run plus Kitesurf K0 execution."""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any

import jsonschema

from bench.fawn_matrix.k0 import execute_k0_suite


REPO_ROOT = Path(__file__).resolve().parents[2]
POLICY_PATH = REPO_ROOT / "config" / "fawn-k0-workloads.json"
BINDINGS_SCHEMA_PATH = REPO_ROOT / "config" / "fawn-k0-bindings.schema.json"
RESULT_SCHEMA_PATH = REPO_ROOT / "config" / "fawn-k0-result.schema.json"
CDP_EXECUTOR_PATH = Path(__file__).parent / "executors" / "k0_cdp.mjs"


def _load_json(path: Path) -> dict[str, Any]:
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise ValueError(f"{path} must contain a JSON object")
    return value


def _validate(value: dict[str, Any], schema_path: Path) -> None:
    schema = _load_json(schema_path)
    errors = sorted(
        jsonschema.Draft202012Validator(schema).iter_errors(value),
        key=lambda error: list(error.absolute_path),
    )
    if errors:
        raise ValueError(errors[0].message)


class CloudflareKitesurfTransport:
    """Call only the admitted Browser Run Quick Action endpoints."""

    def __init__(
        self,
        policy: dict[str, Any],
        account_id: str,
        api_token: str,
    ) -> None:
        self._api = policy["api"]
        self._account_id = account_id
        self._api_token = api_token
        self._paths = {
            endpoint["action"]: endpoint["path"]
            for endpoint in self._api["endpoints"]
        }

    def __call__(self, action: str, binding: dict[str, Any]) -> dict[str, Any]:
        if action.startswith("cdp-"):
            return self._call_cdp(action, binding)
        if action not in self._paths:
            raise ValueError(f"K0 action is not admitted: {action}")
        url = binding["url"]
        account = urllib.parse.quote(self._account_id, safe="")
        endpoint = (
            f"{self._api['baseUrl']}/{account}/{self._paths[action]}"
            f"?browser={urllib.parse.quote(self._api['browser'], safe='')}"
        )
        request = urllib.request.Request(
            endpoint,
            data=json.dumps({"url": url}).encode("utf-8"),
            method="POST",
            headers={
                "Authorization": f"Bearer {self._api_token}",
                "Content-Type": "application/json",
            },
        )
        try:
            with urllib.request.urlopen(request, timeout=120) as response:
                return {
                    "body": response.read(),
                    "headers": dict(response.headers.items()),
                    "httpStatus": response.status,
                }
        except urllib.error.HTTPError as error:
            return {
                "body": error.read(),
                "headers": dict(error.headers.items()),
                "httpStatus": error.code,
            }

    def _call_cdp(
        self,
        action: str,
        binding: dict[str, Any],
    ) -> dict[str, Any]:
        environment = os.environ.copy()
        environment["K0_CLOUDFLARE_ACCOUNT_ID"] = self._account_id
        environment["K0_CLOUDFLARE_API_TOKEN"] = self._api_token
        environment["K0_CLOUDFLARE_CDP_PATH"] = self._api["cdpPath"]
        completed = subprocess.run(
            [
                "node",
                str(CDP_EXECUTOR_PATH),
                "--action",
                action,
                "--binding-json",
                json.dumps(binding, separators=(",", ":"), sort_keys=True),
            ],
            cwd=REPO_ROOT,
            env=environment,
            check=False,
            capture_output=True,
        )
        if completed.returncode != 0:
            detail = completed.stderr.decode("utf-8", errors="replace").strip()
            raise RuntimeError("K0 CDP executor failed: " + detail[-2000:])
        return {
            "body": completed.stdout,
            "headers": {"Content-Type": "application/json"},
            "httpStatus": 200,
        }


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Execute the external K0 browser comparator",
    )
    subparsers = parser.add_subparsers(dest="command", required=True)
    inspect_parser = subparsers.add_parser(
        "inspect",
        help="Print admitted and explicitly ineligible K0 tasks",
    )
    inspect_parser.add_argument("--policy", type=Path, default=POLICY_PATH)
    run_parser = subparsers.add_parser(
        "run",
        help="Execute every admitted K0 task under an exact response oracle",
    )
    run_parser.add_argument("--policy", type=Path, default=POLICY_PATH)
    run_parser.add_argument("--bindings", type=Path, required=True)
    run_parser.add_argument("--out", type=Path, required=True)
    return parser.parse_args()


def main() -> int:
    args = _parse_args()
    policy = _load_json(args.policy)
    if args.command == "inspect":
        print(json.dumps({
            "comparatorId": policy["comparatorId"],
            "taskAdmission": policy["taskAdmission"],
            "claimAllowed": False,
        }, indent=2, sort_keys=True))
        return 0
    bindings = _load_json(args.bindings)
    _validate(bindings, BINDINGS_SCHEMA_PATH)
    account_id = os.environ.get(policy["api"]["accountIdEnvironment"])
    api_token = os.environ.get(policy["api"]["apiTokenEnvironment"])
    if not account_id or not api_token:
        raise ValueError(
            "K0 execution requires CLOUDFLARE_ACCOUNT_ID and "
            "CLOUDFLARE_API_TOKEN"
        )
    report = execute_k0_suite(
        policy,
        bindings,
        args.out,
        CloudflareKitesurfTransport(policy, account_id, api_token),
    )
    _validate(report, RESULT_SCHEMA_PATH)
    print(json.dumps({
        "evidenceStatus": report["evidenceStatus"],
        "reportPath": str(args.out),
        "claimAllowed": False,
    }, indent=2, sort_keys=True))
    return 0 if report["evidenceStatus"] == "passed-unpromoted" else 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(1) from None
