"""Run the Zig std.zig.Ast declaration inventory over one source snapshot."""

from __future__ import annotations

import json
import subprocess
from pathlib import Path
from typing import Any

from source_architecture import Analysis, sha256_file


def _find_zig(tool_root: Path) -> Path:
    candidates = sorted((tool_root.parents[1] / ".tooling").glob("zig-*/zig"))
    candidates.extend(
        sorted((tool_root.parents[2] / ".tooling").glob("zig-*/zig"))
    )
    if not candidates:
        raise RuntimeError("Zig toolchain not found for std.zig.Ast inventory")
    return candidates[-1].resolve()


def capture_ast_inventory(
    source_root: Path,
    analysis: Analysis,
    *,
    tool_root: Path,
) -> dict[str, Any]:
    """Capture normalized AST declarations from an immutable source snapshot."""

    zig = _find_zig(tool_root)
    tool = tool_root / "tools" / "source_ast_inventory.zig"
    paths = [module["path"] for module in analysis.modules]
    result = subprocess.run(
        [str(zig), "run", str(tool), "--", *paths],
        cwd=source_root,
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        detail = result.stderr.strip() or result.stdout.strip()
        raise RuntimeError(f"std.zig.Ast inventory failed: {detail}")
    payload = json.loads(result.stdout)
    payload.sort(key=lambda item: item["path"])
    parse_errors = [
        {"errorCount": record["parseErrorCount"], "path": record["path"]}
        for record in payload
        if record["parseErrorCount"]
    ]
    if parse_errors:
        raise RuntimeError(f"std.zig.Ast parse errors: {parse_errors}")
    return {
        "files": payload,
        "status": "captured",
        "tool": "tools/source_ast_inventory.zig",
        "toolSha256": sha256_file(tool),
    }
