from pathlib import Path

import pytest

from bench.gates.split_coverage_gate import extract_scoped_kinds


def write_contract(tmp_path: Path, metadata: str) -> Path:
    path = tmp_path / "command.zig"
    path.write_text(
        """
pub const Kind = enum(u8) {
    upload,
    render_draw,
};

pub const metadata = [2]Metadata{
"""
        + metadata
        + "\n};\n",
        encoding="utf-8",
    )
    return path


def test_extracts_scopes_from_canonical_command_metadata(tmp_path: Path) -> None:
    contract = write_contract(
        tmp_path,
        '    .{ .scope = .core, .trace_name = "upload" },\n'
        '    .{ .scope = .full, .trace_name = "render_draw" },',
    )

    assert extract_scoped_kinds(contract) == {
        "core": ["upload"],
        "full": ["render_draw"],
    }


def test_rejects_missing_command_metadata(tmp_path: Path) -> None:
    contract = write_contract(
        tmp_path,
        '    .{ .scope = .core, .trace_name = "upload" },',
    )

    with pytest.raises(ValueError, match="missing=\\['render_draw'\\]"):
        extract_scoped_kinds(contract)
