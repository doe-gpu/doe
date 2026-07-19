#!/usr/bin/env python3
"""Audit the Qwen 3.6 27B smoke config against the registered op + binding contract.

Mitigates "Real-weight pin + smoke-contract audit" from the Qwen
north-star checklist. Walks
``runtime/zig/examples/execution-v1/qwen-3-6-27b-smoke.json`` and
verifies, per step:

  - ``op`` is registered in the WGSL→CSL exec-v1 ``opToSpec`` map
    (``runtime/zig/src/compiler/wgsl/emit/csl/emit_csl_exec_v1.zig``);
  - ``phase`` is one of ``prefill`` / ``decode``;
  - the registered op spec allows the cited phase;
  - ``kernelKey`` is one of the named compile targets the host plan
    knows how to materialize;
  - when ``weightsKey`` is present, it follows the
    ``layer.<i>.<module>.<tile>`` naming pattern the manifest tile map
    uses (or the singleton ``embed_tokens``/``output``/``norm`` path);
  - per-step ``namedBlocker`` strings, when present, match the
    ``scopeRestrictions`` keys at the top of the smoke config so the
    blocker references are not orphaned.

Optionally compares against a real-weight pin file (e.g.
``config/qwen-3-6-27b-real-weight-fixture.json``) when one is provided
via ``--pin``: each smoke-config ``weightsKey`` must resolve to a
declared tile in the pin.

Receipt at ``bench/out/r3-2-27b-smoke-contract-audit/receipt.json``;
``verdict=bound`` iff every step passes every check, else
``verdict=blocked`` with per-step diagnostics in ``violations[]``.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from pathlib import Path
from typing import Any

REPO_ROOT = Path(__file__).resolve().parents[2]
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from bench.tools._receipt_hash_guard import (  # noqa: E402
    ReceiptHashSpineError,
    enforce_receipt_hash_spine,
)

DEFAULT_SMOKE_CONFIG = (
    REPO_ROOT
    / "runtime/zig/examples/execution-v1/qwen-3-6-27b-smoke.json"
)
DEFAULT_OPTOSPEC_SOURCE = (
    REPO_ROOT / "runtime/zig/src/compiler/wgsl/emit/csl/emit_csl_exec_v1.zig"
)
DEFAULT_OUT = (
    REPO_ROOT
    / "bench/out/r3-2-27b-smoke-contract-audit/receipt.json"
)

VALID_PHASES = ("prefill", "decode")
KNOWN_KERNEL_KEYS = {
    "embed",
    "rmsnorm",
    "tiled",
    "rope_partial",
    "residual",
    "silu",
    "attn_prefill",
    "attn_decode",
    "kv_write",
    "gemv",
    "sample",
    "gated",
    "linear_attention",
    "conv1d",
    "l2_normalize",
}

WEIGHTS_KEY_LAYERED = re.compile(
    r"^layer\.\d+\.[A-Za-z_][A-Za-z0-9_]*"
    r"(?:\.[A-Za-z_][A-Za-z0-9_]*)*$"
)
WEIGHTS_KEY_SINGLETON = re.compile(
    r"^(embed_tokens|output|final_norm|lm_head)$"
)


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument(
        "--smoke-config", type=Path, default=DEFAULT_SMOKE_CONFIG
    )
    p.add_argument(
        "--optospec-source",
        type=Path,
        default=DEFAULT_OPTOSPEC_SOURCE,
        help=(
            "Path to emit_csl_exec_v1.zig — parsed for the registered "
            "op set so the audit stays in sync with the live classifier."
        ),
    )
    p.add_argument("--pin", type=Path, default=None)
    p.add_argument("--out", type=Path, default=DEFAULT_OUT)
    return p.parse_args()


def _sha256_file(path: Path) -> str | None:
    if not path.is_file():
        return None
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def _rel(path: Path) -> str:
    try:
        return str(path.resolve().relative_to(REPO_ROOT))
    except ValueError:
        return str(path)


_OP_SPEC_LINE = re.compile(
    r'\.op\s*=\s*"(?P<op>[A-Za-z_][A-Za-z0-9_]*)"\s*,'
    r'\s*\.spec\s*=\s*\.\{\s*\.pattern\s*=\s*"(?P<pattern>[A-Za-z_][A-Za-z0-9_]*)"'
    r'(?:[^}]*?\.allow_prefill\s*=\s*(?P<allow_prefill>true|false))?'
    r'(?:[^}]*?\.allow_decode\s*=\s*(?P<allow_decode>true|false))?'
)


def parse_optospec(source: Path) -> dict[str, dict[str, Any]]:
    """Parse `.{ .op = "X", .spec = .{ .pattern = "Y", ... } }` literals
    out of emit_csl_exec_v1.zig. Source-of-truth: the live classifier
    table. The audit never invents an op set; if a step's op is missing
    from this parse, the audit reports it as `unregistered_op` and the
    user must update the classifier first."""
    if not source.is_file():
        raise FileNotFoundError(f"opToSpec source not found: {source}")
    text = source.read_text(encoding="utf-8")
    out: dict[str, dict[str, Any]] = {}
    for match in _OP_SPEC_LINE.finditer(text):
        op = match.group("op")
        out[op] = {
            "pattern": match.group("pattern"),
            "allow_prefill": (match.group("allow_prefill") or "true") == "true",
            "allow_decode": (match.group("allow_decode") or "true") == "true",
        }
    return out


def _is_valid_weights_key(raw: str) -> bool:
    if WEIGHTS_KEY_LAYERED.match(raw):
        return True
    if WEIGHTS_KEY_SINGLETON.match(raw):
        return True
    return False


def _audit_step(
    *,
    step: dict,
    index: int,
    optospec: dict[str, dict[str, Any]],
    scope_keys: set[str],
    pin_tiles: set[str] | None,
) -> list[str]:
    violations: list[str] = []
    name = step.get("name", f"<step-{index}>")
    op = step.get("op")
    phase = step.get("phase")
    kernel = step.get("kernelKey")
    weights = step.get("weightsKey")
    blocker = step.get("namedBlocker")

    if not isinstance(op, str):
        violations.append(f"step[{index}].name={name!r}: op missing or not a string")
        return violations
    spec = optospec.get(op)
    if spec is None:
        violations.append(
            f"step[{index}].name={name!r}: op={op!r} unregistered in "
            f"emit_csl_exec_v1.zig opToSpec"
        )
    if phase not in VALID_PHASES:
        violations.append(
            f"step[{index}].name={name!r}: phase={phase!r} not in {VALID_PHASES}"
        )
    elif spec is not None:
        if phase == "prefill" and not spec["allow_prefill"]:
            violations.append(
                f"step[{index}].name={name!r}: op={op!r} disallowed in prefill"
            )
        if phase == "decode" and not spec["allow_decode"]:
            violations.append(
                f"step[{index}].name={name!r}: op={op!r} disallowed in decode"
            )
    if kernel is not None and kernel not in KNOWN_KERNEL_KEYS:
        violations.append(
            f"step[{index}].name={name!r}: kernelKey={kernel!r} not in known set"
        )
    if weights is not None:
        if not isinstance(weights, str) or not _is_valid_weights_key(weights):
            violations.append(
                f"step[{index}].name={name!r}: weightsKey={weights!r} does not "
                f"match layer.<i>.<module>.<tile> or singleton pattern"
            )
        elif pin_tiles is not None and weights not in pin_tiles:
            violations.append(
                f"step[{index}].name={name!r}: weightsKey={weights!r} not "
                f"declared in real-weight pin"
            )
    if blocker is not None:
        if blocker not in scope_keys:
            violations.append(
                f"step[{index}].name={name!r}: namedBlocker={blocker!r} not "
                f"present in scopeRestrictions keys"
            )
    return violations


def main() -> int:
    args = parse_args()
    if not args.smoke_config.is_file():
        sys.stderr.write(f"smoke-config not found at {args.smoke_config}\n")
        return 2
    smoke = json.loads(args.smoke_config.read_text(encoding="utf-8"))
    steps = smoke.get("steps", [])
    if not isinstance(steps, list) or not steps:
        sys.stderr.write("smoke-config has no steps\n")
        return 2

    try:
        optospec = parse_optospec(args.optospec_source)
    except FileNotFoundError as err:
        sys.stderr.write(f"{err}\n")
        return 2

    scope = smoke.get("scopeRestrictions") or {}
    scope_keys: set[str] = set()
    if isinstance(scope, dict):
        scope_keys = {
            re.sub(r"(?<!^)(?=[A-Z])", "_", k).lower() for k in scope.keys()
        } | set(scope.keys())

    pin_tiles: set[str] | None = None
    pin_path: Path | None = None
    pin_hash: str | None = None
    if args.pin is not None:
        if not args.pin.is_file():
            sys.stderr.write(f"--pin file not found: {args.pin}\n")
            return 2
        pin_path = args.pin
        pin_hash = _sha256_file(args.pin)
        try:
            pin = json.loads(args.pin.read_text(encoding="utf-8"))
        except json.JSONDecodeError as err:
            sys.stderr.write(f"--pin is not valid JSON: {err}\n")
            return 2
        tiles = pin.get("weightTileMap") or pin.get("tiles") or {}
        if isinstance(tiles, dict):
            pin_tiles = set(tiles.keys())
        elif isinstance(tiles, list):
            pin_tiles = {
                t.get("key") if isinstance(t, dict) else t
                for t in tiles
                if t
            }

    violations: list[str] = []
    per_step: list[dict] = []
    for idx, step in enumerate(steps):
        if not isinstance(step, dict):
            violations.append(f"step[{idx}] not an object")
            per_step.append({"index": idx, "ok": False, "violations": ["not an object"]})
            continue
        step_violations = _audit_step(
            step=step,
            index=idx,
            optospec=optospec,
            scope_keys=scope_keys,
            pin_tiles=pin_tiles,
        )
        per_step.append({
            "index": idx,
            "name": step.get("name"),
            "op": step.get("op"),
            "phase": step.get("phase"),
            "kernelKey": step.get("kernelKey"),
            "weightsKey": step.get("weightsKey"),
            "ok": not step_violations,
            "violations": step_violations,
        })
        violations.extend(step_violations)

    bound = not violations
    receipt: dict = {
        "schemaVersion": 1,
        "artifactKind": "doe_qwen_3_6_27b_smoke_contract_audit_receipt",
        "modelId": smoke.get("modelId", "qwen-3-6-27b-q4k-ehaf16"),
        "modelFamily": smoke.get("modelFamily", "qwen3"),
        "smokeConfigPath": _rel(args.smoke_config),
        "smokeConfigHash": _sha256_file(args.smoke_config),
        "optoSpecSourcePath": _rel(args.optospec_source),
        "optoSpecSourceHash": _sha256_file(args.optospec_source),
        "registeredOpCount": len(optospec),
        "stepCount": len(steps),
        "perStep": per_step,
        "violationCount": len(violations),
        "bound": bound,
        "verdict": "bound" if bound else "blocked",
        "claim": {
            "scope": (
                "Qwen 3.6 27B smoke config conforms to the WGSL→CSL "
                "exec-v1 opToSpec contract. Every step's op is "
                "registered, every phase is allowed, every kernelKey is "
                "in the known compile-target set, every weightsKey "
                "matches the layered/singleton naming pattern, and "
                "every namedBlocker references a declared "
                "scopeRestrictions entry. When --pin is provided, every "
                "weightsKey resolves to a tile in the real-weight pin."
            ),
            "notWhat": (
                "Not a numerical or hardware claim. Not a parity "
                "claim. The audit only checks shape conformance against "
                "the live classifier; it does not invoke the host-plan "
                "tool and does not verify per-step compileParams."
            ),
        },
    }
    if pin_path is not None:
        receipt["realWeightPinPath"] = _rel(pin_path)
        receipt["realWeightPinHash"] = pin_hash
        receipt["realWeightPinTileCount"] = len(pin_tiles or [])

    try:
        enforce_receipt_hash_spine(receipt, repo_root=REPO_ROOT)
    except ReceiptHashSpineError as err:
        sys.stderr.write(
            "audit_qwen_3_6_27b_smoke_contract: receipt hash spine "
            f"rejected emit:\n  {err}\n"
        )
        return 2

    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(
        json.dumps(receipt, indent=2) + "\n", encoding="utf-8"
    )
    print(
        f"wrote {_rel(args.out)} verdict={receipt['verdict']} "
        f"steps={len(steps)} violations={len(violations)}"
    )
    return 0 if bound else 1


if __name__ == "__main__":
    sys.exit(main())
