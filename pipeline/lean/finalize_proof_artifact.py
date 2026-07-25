"""Finalize Lean extraction with hash-bound theorem/runtime metadata."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
from pathlib import Path
from typing import Any


RUNTIME_REFERENCE_SPLIT = re.compile(r",(?=[^,]+?\.(?:zig|py):)")


def _sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _resolve_source_path(root: Path, value: str) -> Path:
    relative = Path(value)
    if relative.is_absolute() or ".." in relative.parts:
        raise ValueError(f"unsafe runtime mirror path: {value}")
    candidates = [root / relative]
    if relative.parts and relative.parts[0] == "quirk":
        candidates.append(root / "runtime" / "zig" / "src" / relative)
    for candidate in candidates:
        if candidate.is_file():
            return candidate
    raise ValueError(f"runtime mirror source does not exist: {value}")


def _mirror_sources(root: Path, runtime_path: str) -> list[dict[str, Any]]:
    mirrors: list[dict[str, Any]] = []
    for reference in RUNTIME_REFERENCE_SPLIT.split(runtime_path):
        source_text, separator, symbols_text = reference.partition(":")
        if not separator or not source_text or not symbols_text:
            raise ValueError(f"invalid runtime mirror reference: {reference}")
        source = _resolve_source_path(root, source_text)
        symbols = [symbol for symbol in symbols_text.split(",") if symbol]
        if not symbols:
            raise ValueError(f"runtime mirror has no symbol: {reference}")
        content = source.read_text(encoding="utf-8")
        for symbol in symbols:
            if symbol not in content:
                raise ValueError(
                    f"runtime mirror symbol {symbol!r} is absent from "
                    f"{source.relative_to(root).as_posix()}"
                )
        mirrors.append(
            {
                "path": source.relative_to(root).as_posix(),
                "symbols": symbols,
                "sourceSha256": _sha256(source),
            }
        )
    return mirrors


def finalize_artifact(root: Path, artifact: dict[str, Any]) -> dict[str, Any]:
    theorems = artifact.get("theorems")
    if not isinstance(theorems, list) or not theorems:
        raise ValueError("proof artifact must contain a non-empty theorem registry")

    theorem_by_name: dict[str, dict[str, str]] = {}
    for theorem in theorems:
        name = theorem.get("name")
        if not isinstance(name, str) or not name:
            raise ValueError("theorem registry entry is missing name")
        if name in theorem_by_name:
            raise ValueError(f"duplicate theorem registry name: {name}")
        theorem_by_name[name] = theorem

    runtime_targets: dict[str, list[dict[str, Any]]] = {}
    obligation_categories: dict[str, str] = {}
    for field, obligation in (
        ("eliminationTargets", "runtime_elimination"),
        ("boundsEliminations", "bounds_elimination"),
    ):
        for target in artifact.get(field, []):
            theorem_name = target.get("theorem")
            if theorem_name not in theorem_by_name:
                raise ValueError(f"{field} references unknown theorem: {theorem_name}")
            mirrors = _mirror_sources(root, target["runtimePath"])
            runtime_targets.setdefault(theorem_name, []).extend(mirrors)
            obligation_categories[theorem_name] = obligation

    metadata: list[dict[str, Any]] = []
    for theorem in theorems:
        name = theorem["name"]
        category = theorem["category"]
        mirrors = runtime_targets.get(name, [])
        obligation = obligation_categories.get(
            name,
            "fixture_obligation" if category == "lean_fixture" else "proof_contract",
        )
        metadata.append(
            {
                "theoremId": f"{theorem['module']}.{name}",
                "name": name,
                "module": theorem["module"],
                "classification": category,
                "obligationCategory": obligation,
                "extractionStatus": (
                    "runtime_branch_eliminated"
                    if mirrors
                    else "fixture_evaluated"
                    if category == "lean_fixture"
                    else "verified"
                ),
                "mirrorSources": mirrors,
            }
        )

    finalized = dict(artifact)
    finalized["provenance"] = dict(artifact["provenance"])
    finalized["provenance"]["theoremMetadataGeneratorSha256"] = _sha256(
        Path(__file__).resolve()
    )
    finalized["theoremMetadata"] = metadata
    return finalized


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--artifact", type=Path, required=True)
    return parser.parse_args()


def main() -> None:
    args = _parse_args()
    root = args.root.resolve()
    artifact_path = args.artifact.resolve()
    artifact = json.loads(artifact_path.read_text(encoding="utf-8"))
    finalized = finalize_artifact(root, artifact)
    artifact_path.write_text(
        json.dumps(finalized, indent=2, sort_keys=False) + "\n",
        encoding="utf-8",
    )


if __name__ == "__main__":
    main()
