"""Audit Doe's WebGPU ABI ownership against the pinned upstream header."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
import sys
from collections import defaultdict
from pathlib import Path
from typing import Any

from source_architecture import canonical_json
from generate_webgpu_abi import generate as generate_webgpu_abi


ROOT = Path(__file__).resolve().parents[1]
REPOSITORY_ROOT = ROOT.parents[1]
POLICY_PATH = REPOSITORY_ROOT / "config" / "webgpu-abi-source.json"
OUTPUT_PATH = ROOT / "reports" / "recomposition" / "abi-audit.json"

ZIG_DECLARATION = re.compile(
    r"^pub\s+const\s+(WGPU[A-Za-z0-9_]+)\s*=\s*(.+)$", re.MULTILINE
)
HEADER_NAME = re.compile(r"\b(WGPU[A-Za-z0-9_]+)\b")
HEADER_PROC = re.compile(r"\b(wgpu[A-Za-z0-9_]+)\s*\(")
MANUAL_PREFIXES = (
    "enum",
    "extern struct",
    "opaque",
    "u8",
    "u16",
    "u32",
    "u64",
    "i8",
    "i16",
    "i32",
    "i64",
    "?*anyopaque",
    "*anyopaque",
    "*const fn",
)


def _sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _git_output(directory: Path, *arguments: str) -> str:
    result = subprocess.run(
        ["git", "-C", str(directory), *arguments],
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or "git command failed")
    return result.stdout.strip()


def _symbol_contract(path: Path) -> list[str]:
    return sorted(
        line.strip()
        for line in path.read_text(encoding="utf-8").splitlines()
        if line.strip() and not line.lstrip().startswith("#")
    )


def audit(root: Path, policy_path: Path) -> dict[str, Any]:
    policy = json.loads(policy_path.read_text(encoding="utf-8"))
    source = policy["source"]
    header_path = REPOSITORY_ROOT / source["path"]
    if not header_path.is_file():
        raise RuntimeError(f"pinned WebGPU header is missing: {header_path}")
    actual_header_sha = _sha256(header_path)
    dawn_root = REPOSITORY_ROOT / "bench" / "vendor" / "dawn"
    actual_dawn_commit = _git_output(dawn_root, "rev-parse", "HEAD")
    deps = (dawn_root / "DEPS").read_text(encoding="utf-8")
    deps_match = re.search(
        r"webgpu-headers@([0-9a-f]{40})", deps
    )
    actual_headers_commit = deps_match.group(1) if deps_match else None

    header_text = header_path.read_text(encoding="utf-8")
    header_names = set(HEADER_NAME.findall(header_text))
    header_procs = set(HEADER_PROC.findall(header_text))
    symbol_path = REPOSITORY_ROOT / policy["ownership"]["exportedSymbolContract"]
    symbols = _symbol_contract(symbol_path)

    declarations: list[dict[str, Any]] = []
    by_name: dict[str, list[str]] = defaultdict(list)
    for path in sorted((root / "src" / "core" / "abi").rglob("*.zig")):
        relative = path.relative_to(root).as_posix()
        for match in ZIG_DECLARATION.finditer(path.read_text(encoding="utf-8")):
            name, expression = match.groups()
            expression = expression.strip()
            ownership = (
                "doe-extension"
                if name not in header_names
                else "manual-upstream-definition"
                if expression.startswith(MANUAL_PREFIXES)
                else "upstream-alias"
            )
            declarations.append(
                {
                    "expressionHead": expression[:96],
                    "name": name,
                    "ownership": ownership,
                    "path": relative,
                }
            )
            by_name[name].append(relative)

    manual = [
        item for item in declarations
        if item["ownership"] == "manual-upstream-definition"
    ]
    duplicate_names = [
        {"name": name, "paths": sorted(paths)}
        for name, paths in sorted(by_name.items())
        if len(paths) > 1
    ]
    pin_errors = []
    if actual_header_sha != source["sha256"]:
        pin_errors.append("header-sha256")
    if actual_dawn_commit != source["dawnCommit"]:
        pin_errors.append("dawn-commit")
    if actual_headers_commit != source["webgpuHeadersCommit"]:
        pin_errors.append("webgpu-headers-commit")
    missing_symbols = sorted(set(symbols) - header_procs)
    generated_path = root / "src" / "core" / "abi" / "generated" / "webgpu_upstream.zig"
    rendered_generated = generate_webgpu_abi(root, policy_path, symbol_path)
    generated_current = (
        generated_path.is_file()
        and generated_path.read_text(encoding="utf-8") == rendered_generated
    )
    return {
        "declarations": {
            "doeExtensionCount": sum(
                item["ownership"] == "doe-extension" for item in declarations
            ),
            "duplicateNames": duplicate_names,
            "manualUpstreamDefinitionCount": len(manual),
            "manualUpstreamDefinitions": manual,
            "totalCount": len(declarations),
            "upstreamAliasCount": sum(
                item["ownership"] == "upstream-alias" for item in declarations
            ),
        },
        "generation": {
            "domains": policy["generationPolicy"]["generatedDomains"],
            "generatedPath": generated_path.relative_to(root).as_posix(),
            "outputCurrent": generated_current,
            "required": bool(manual) or not generated_current,
            "status": "complete" if not manual and generated_current else "required",
        },
        "pin": {
            "actualDawnCommit": actual_dawn_commit,
            "actualHeaderSha256": actual_header_sha,
            "actualWebgpuHeadersCommit": actual_headers_commit,
            "errors": pin_errors,
            "path": source["path"],
            "status": "verified" if not pin_errors else "failure",
        },
        "schemaVersion": 1,
        "symbolContract": {
            "count": len(symbols),
            "missingFromPinnedHeader": missing_symbols,
            "path": policy["ownership"]["exportedSymbolContract"],
            "status": "verified" if not missing_symbols else "failure",
        },
        "status": (
            "audited-generation-required"
            if not pin_errors and not missing_symbols and (manual or not generated_current)
            else "audited-generated"
            if not pin_errors and not missing_symbols and generated_current
            else "failure"
        ),
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=ROOT)
    parser.add_argument("--policy", type=Path, default=POLICY_PATH)
    parser.add_argument("--output", type=Path, default=OUTPUT_PATH)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        result = audit(args.root.resolve(), args.policy.resolve())
    except (KeyError, OSError, RuntimeError, ValueError) as exc:
        print(f"WebGPU ABI audit failed: {exc}", file=sys.stderr)
        return 1
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(canonical_json(result), encoding="utf-8")
    if result["status"] == "failure":
        print(canonical_json(result), file=sys.stderr, end="")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
