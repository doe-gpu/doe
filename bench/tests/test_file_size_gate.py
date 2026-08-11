from __future__ import annotations

import importlib.util
import json
import sys
from pathlib import Path


MODULE_PATH = Path(__file__).parents[1] / "gates" / "file_size_gate.py"
SPEC = importlib.util.spec_from_file_location("file_size_gate", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
file_size_gate = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = file_size_gate
SPEC.loader.exec_module(file_size_gate)


def _write_lines(path: Path, count: int) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("line\n" * count, encoding="utf-8")


def test_python_scan_ignores_output_and_vendor_trees(tmp_path: Path) -> None:
    _write_lines(tmp_path / "bench" / "owned.py", 1201)
    _write_lines(tmp_path / "bench" / "out" / "generated.py", 1201)
    _write_lines(tmp_path / "bench" / "vendor" / "third_party.py", 1201)

    findings = file_size_gate.scan_directory(
        tmp_path,
        "bench",
        ".py",
        file_size_gate.PYTHON_LINE_LIMIT,
        "python",
        set(),
    )

    assert [finding.path for finding in findings] == ["bench/owned.py"]


def test_zig_scan_uses_manifest_limits_and_generated_roles(tmp_path: Path) -> None:
    runtime_root = tmp_path / "runtime" / "zig"
    manifest = {
        "architecture": {
            "linePolicy": {
                "futureHardMaximumLines": 5,
                "futureJustificationAboveLines": 3,
            },
            "specialRoles": {"generated": ["src/generated/*.zig"]},
            "cohesiveModuleJustifications": [{"path": "src/justified.zig"}],
        }
    }
    runtime_root.mkdir(parents=True)
    (runtime_root / "source-layout.json").write_text(
        json.dumps(manifest), encoding="utf-8"
    )
    _write_lines(runtime_root / "src" / "needs_review.zig", 4)
    _write_lines(runtime_root / "src" / "justified.zig", 4)
    _write_lines(runtime_root / "src" / "too_large.zig", 6)
    _write_lines(runtime_root / "src" / "generated" / "large.zig", 20)

    findings = file_size_gate.scan_zig_sources(tmp_path, set())

    assert [(finding.path, finding.limit) for finding in findings] == [
        ("runtime/zig/src/needs_review.zig", 3),
        ("runtime/zig/src/too_large.zig", 5),
    ]
