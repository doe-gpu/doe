"""Classify every owned Zig test root by its verification responsibility."""

from __future__ import annotations

import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
INVENTORY_PATH = ROOT.parents[1] / "config" / "zig-test-inventory.json"


def classify(path: str) -> str:
    if path.startswith("src/"):
        return "inline"
    name = path.lower()
    if "cross_backend" in name or "cross-backend" in name:
        return "cross-backend"
    if any(token in name for token in ("webgpu_ffi", "dropin", "abi_", "_abi")):
        return "abi"
    if any(token in name for token in ("timing_semantics", "characterization")):
        return "characterization"
    if any(token in name for token in ("golden", "codegen", "translation")):
        return "golden"
    if path.startswith("tests/backend/") or any(
        segment in name for segment in ("/metal/", "/vulkan/", "/d3d12/")
    ):
        return "backend"
    return "integration"


def main() -> int:
    inventory = json.loads(INVENTORY_PATH.read_text(encoding="utf-8"))
    inventory["schemaVersion"] = 2
    for suite in inventory["suites"].values():
        for entry in suite["entries"]:
            entry["kind"] = classify(entry["path"])
    support_paths = [
        entry if isinstance(entry, str) else entry["path"]
        for entry in inventory["supportFiles"]
    ]
    test_paths = sorted(
        path.relative_to(ROOT).as_posix()
        for path in (ROOT / "tests").rglob("*.zig")
    )
    inventory["supportFiles"] = []
    for support_path in support_paths:
        basename = Path(support_path).name
        consumers = [
            path
            for path in test_paths
            if path != support_path
            and basename in (ROOT / path).read_text(encoding="utf-8")
        ]
        inventory["supportFiles"].append(
            {
                "path": support_path,
                "kind": (
                    "domain-fixture"
                    if "support" in Path(support_path).stem
                    else "test-shard"
                ),
                "consumers": consumers,
            }
        )
    INVENTORY_PATH.write_text(
        json.dumps(inventory, indent=2, sort_keys=False) + "\n",
        encoding="utf-8",
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
