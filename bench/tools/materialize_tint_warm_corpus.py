#!/usr/bin/env python3
"""Materialize Doe WGSL rows into Dawn's Tint benchmark corpus."""

from __future__ import annotations

import argparse
import ast
import datetime
import hashlib
import json
import subprocess
import sys
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_DAWN_SOURCE_DIR = "bench/vendor/dawn"
DEFAULT_DAWN_BUILD_DIR = "bench/vendor/dawn/out/Release"
DEFAULT_STATE_PATH = "bench/fixtures/dawn_tint_warm_corpus_state.json"
BENCHMARK_INPUTS_SCRIPT = "src/tint/cmd/bench/generate_benchmark_inputs.py"
MSL_WRITER_BENCH_SOURCE = "src/tint/cmd/bench/msl/writer_bench.cc"
DAWN_BENCHMARK_ROOT = Path("test/tint/benchmark/doe")
DOE_ARRAY_LENGTH_PATCH_MARKER = "Doe materialized corpus array-length coverage"


def file_sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def repo_relative(path: Path, root: Path = REPO_ROOT) -> str:
    try:
        return str(path.resolve().relative_to(root.resolve()))
    except ValueError:
        return str(path)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--workloads",
        default="bench/workloads/workloads.apple.metal.json",
        help="Workload JSON containing runnerType=compilation rows.",
    )
    parser.add_argument(
        "--wgsl-corpus-manifest",
        default="",
        help="WGSL corpus manifest to materialize instead of --workloads.",
    )
    parser.add_argument(
        "--dawn-source-dir",
        default=DEFAULT_DAWN_SOURCE_DIR,
        help="Dawn checkout directory.",
    )
    parser.add_argument(
        "--build-dir",
        default=DEFAULT_DAWN_BUILD_DIR,
        help="Dawn build directory used when --build is set.",
    )
    parser.add_argument(
        "--target",
        default="msl",
        help="Compilation target to materialize.",
    )
    parser.add_argument(
        "--workload-id",
        action="append",
        default=[],
        help="Optional workload id to materialize. Repeat for multiple rows.",
    )
    parser.add_argument(
        "--ninja-bin",
        default="ninja",
        help="Ninja executable used when --build is set.",
    )
    parser.add_argument(
        "--build",
        action="store_true",
        help="Run ninja tint_benchmark after materializing the corpus.",
    )
    parser.add_argument(
        "--output-state",
        default=DEFAULT_STATE_PATH,
        help="State JSON written after materialization.",
    )
    return parser.parse_args()


def normalize_target(value: object) -> str:
    target = str(value or "").strip().lower()
    if target in {"spv", "spir-v"}:
        return "spirv"
    return target


def load_compilation_workloads(
    workloads_path: Path,
    *,
    repo_root: Path,
    target: str,
    workload_ids: list[str],
) -> list[dict[str, object]]:
    payload = json.loads(workloads_path.read_text(encoding="utf-8"))
    requested = set(workload_ids)
    rows = []
    for row in payload.get("workloads", []):
        if row.get("runnerType") != "compilation":
            continue
        if str(row.get("compilationTarget", "msl")) != target:
            continue
        workload_id = str(row.get("id", "")).strip()
        if requested and workload_id not in requested:
            continue
        shader_rel = str(row.get("shaderPath", "")).strip()
        shader_path = repo_root / shader_rel
        if not workload_id:
            raise RuntimeError("compilation workload row is missing id")
        if not shader_rel or not shader_path.is_file():
            raise RuntimeError(f"shaderPath not found for {workload_id}: {shader_path}")
        rows.append(
            {
                "workloadId": workload_id,
                "shaderPath": shader_path,
                "shaderRepoPath": shader_rel,
                "target": target,
            }
        )

    if requested:
        found = {str(row["workloadId"]) for row in rows}
        missing = sorted(requested - found)
        if missing:
            raise RuntimeError(f"workload ids not found: {', '.join(missing)}")
    if not rows:
        raise RuntimeError(f"no {target} compilation workloads found in {workloads_path}")
    return rows


def load_wgsl_corpus_rows(
    manifest_path: Path,
    *,
    repo_root: Path,
    target: str,
    workload_ids: list[str],
) -> list[dict[str, object]]:
    payload = json.loads(manifest_path.read_text(encoding="utf-8"))
    requested = set(workload_ids)
    normalized_target = normalize_target(target)
    rows = []
    for row in payload.get("rows", []):
        shader_id = str(row.get("shaderId", "")).strip()
        if requested and shader_id not in requested:
            continue
        if row.get("expectedValidity", "valid") != "valid":
            continue
        expected_targets = [
            normalize_target(value)
            for value in row.get("expectedBackendTargets", [])
            if str(value or "").strip()
        ]
        if expected_targets and normalized_target not in expected_targets:
            continue
        shader_rel = str(row.get("sourcePath", "")).strip()
        shader_path = repo_root / shader_rel
        if not shader_id:
            raise RuntimeError("WGSL corpus row is missing shaderId")
        if not shader_rel or not shader_path.is_file():
            raise RuntimeError(f"sourcePath not found for {shader_id}: {shader_path}")
        rows.append(
            {
                "workloadId": shader_id,
                "shaderPath": shader_path,
                "shaderRepoPath": shader_rel,
                "target": normalized_target,
                "sourceKind": "wgsl_corpus",
                "corpusCategory": row.get("category", "wgsl_corpus"),
            }
        )

    if requested:
        found = {str(row["workloadId"]) for row in rows}
        missing = sorted(requested - found)
        if missing:
            raise RuntimeError(f"WGSL corpus ids not found: {', '.join(missing)}")
    if not rows:
        raise RuntimeError(f"no {normalized_target} WGSL corpus rows found in {manifest_path}")
    return rows


def extract_benchmark_files(script_text: str) -> tuple[list[str], int, int]:
    marker = "kBenchmarkFiles = ["
    start = script_text.find(marker)
    if start < 0:
        raise RuntimeError("failed to locate kBenchmarkFiles")
    end = script_text.find("]\n\n\ndef main", start)
    if end < 0:
        raise RuntimeError("failed to locate end of kBenchmarkFiles")
    try:
        values = ast.literal_eval(script_text[start + len("kBenchmarkFiles = "):end + 1])
    except (SyntaxError, ValueError) as exc:
        raise RuntimeError(f"failed to parse kBenchmarkFiles: {exc}") from exc
    return [str(value) for value in values], start, end + 1


def render_benchmark_files(values: list[str]) -> str:
    lines = ["kBenchmarkFiles = ["]
    for value in values:
        lines.append(f'    "{value}",')
    lines.append("]")
    return "\n".join(lines)


def patch_benchmark_inputs_script(script_path: Path, benchmark_paths: list[str]) -> list[str]:
    script_text = script_path.read_text(encoding="utf-8")
    existing, start, end = extract_benchmark_files(script_text)
    merged = existing[:]
    seen = set(existing)
    for benchmark_path in benchmark_paths:
        if benchmark_path in seen:
            continue
        merged.append(benchmark_path)
        seen.add(benchmark_path)
    next_text = script_text[:start] + render_benchmark_files(merged) + script_text[end:]
    if next_text != script_text:
        script_path.write_text(next_text, encoding="utf-8")
    return merged


def patch_msl_writer_bench(source_path: Path) -> bool:
    text = source_path.read_text(encoding="utf-8")
    if DOE_ARRAY_LENGTH_PATCH_MARKER in text:
        return False
    start = text.find("    gen_options.array_length_from_constants.bindpoint_to_size_index.emplace(")
    if start < 0:
        raise RuntimeError("failed to locate MSL writer benchmark bindpoint setup")
    end_marker = "\n\n    for (auto _ : state) {"
    end = text.find(end_marker, start)
    if end < 0:
        raise RuntimeError("failed to locate end of MSL writer benchmark bindpoint setup")
    replacement = """    // Doe materialized corpus array-length coverage.
    // Dawn's stock benchmark corpus only needs group 0. The Doe compilation
    // corpus includes storage arrays across multiple bind groups, so the local
    // benchmark harness must seed all bindpoints it may see.
    for (auto group = 0u; group < 4u; group++) {
        for (auto binding = 0u; binding < 64u; binding++) {
            gen_options.array_length_from_constants.bindpoint_to_size_index.emplace(
                tint::BindingPoint{group, binding}, group * 64u + binding);
        }
    }"""
    source_path.write_text(text[:start] + replacement + text[end:], encoding="utf-8")
    return True


def materialize_rows(
    rows: list[dict[str, object]],
    *,
    dawn_source_dir: Path,
) -> list[dict[str, object]]:
    copied_rows = []
    dest_root = dawn_source_dir / DAWN_BENCHMARK_ROOT
    dest_root.mkdir(parents=True, exist_ok=True)
    for row in rows:
        workload_id = str(row["workloadId"])
        shader_path = Path(row["shaderPath"])
        dest_rel = DAWN_BENCHMARK_ROOT / f"{workload_id}.wgsl"
        dest_path = dawn_source_dir / dest_rel
        ascii_normalized = copy_shader_for_tint_benchmark(shader_path, dest_path)
        copied_row = {
            "workloadId": workload_id,
            "shaderPath": str(row["shaderRepoPath"]),
            "target": str(row["target"]),
            "dawnBenchmarkPath": dest_rel.as_posix(),
            "benchmarkName": dest_rel.name,
            "sourceSha256": file_sha256(shader_path),
            "asciiNormalized": ascii_normalized,
        }
        for key in ("sourceKind", "corpusCategory"):
            value = row.get(key)
            if value:
                copied_row[key] = value
        copied_rows.append(copied_row)
    return copied_rows


def copy_shader_for_tint_benchmark(source_path: Path, dest_path: Path) -> bool:
    text = source_path.read_text(encoding="utf-8")
    normalized = text.encode("ascii", "replace").decode("ascii")
    dest_path.write_text(normalized, encoding="ascii", newline="\n")
    return normalized != text


def run_ninja(ninja_bin: str, build_dir: Path) -> None:
    subprocess.run(
        [ninja_bin, "-C", str(build_dir), "tint_benchmark"],
        check=True,
    )


def write_state(
    *,
    path: Path,
    input_path: Path,
    source_kind: str,
    dawn_source_dir: Path,
    build_dir: Path,
    target: str,
    copied_rows: list[dict[str, object]],
    built: bool,
    repo_root: Path = REPO_ROOT,
) -> None:
    script_path = dawn_source_dir / BENCHMARK_INPUTS_SCRIPT
    msl_writer_bench_path = dawn_source_dir / MSL_WRITER_BENCH_SOURCE
    tint_benchmark_path = build_dir / "tint_benchmark"
    payload = {
        "schemaVersion": 1,
        "artifactKind": "tint-warm-corpus-materialization",
        "generatedAt": datetime.datetime.now(datetime.timezone.utc)
        .isoformat()
        .replace("+00:00", "Z"),
        "sourceKind": source_kind,
        "dawnSourceDir": repo_relative(dawn_source_dir, repo_root),
        "dawnBuildDir": repo_relative(build_dir, repo_root),
        "target": target,
        "benchmarkInputsScriptPath": repo_relative(script_path, repo_root),
        "benchmarkInputsScriptSha256": file_sha256(script_path),
        "mslWriterBenchPath": repo_relative(msl_writer_bench_path, repo_root),
        "mslWriterBenchSha256": file_sha256(msl_writer_bench_path),
        "tintBenchmarkPath": repo_relative(tint_benchmark_path, repo_root),
        "tintBenchmarkSha256": file_sha256(tint_benchmark_path)
        if tint_benchmark_path.is_file()
        else None,
        "built": built,
        "rows": copied_rows,
    }
    if source_kind == "wgsl_corpus":
        payload["wgslCorpusManifestPath"] = repo_relative(input_path, repo_root)
    else:
        payload["workloadsPath"] = repo_relative(input_path, repo_root)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")


def main() -> int:
    args = parse_args()
    source_kind = "wgsl_corpus" if args.wgsl_corpus_manifest else "compilation_workloads"
    input_path = (
        (REPO_ROOT / args.wgsl_corpus_manifest).resolve()
        if args.wgsl_corpus_manifest
        else (REPO_ROOT / args.workloads).resolve()
    )
    dawn_source_dir = (REPO_ROOT / args.dawn_source_dir).resolve()
    build_dir = (REPO_ROOT / args.build_dir).resolve()
    script_path = dawn_source_dir / BENCHMARK_INPUTS_SCRIPT
    if not script_path.is_file():
        print(f"error: Tint benchmark input script not found: {script_path}", file=sys.stderr)
        return 1

    if source_kind == "wgsl_corpus":
        rows = load_wgsl_corpus_rows(
            input_path,
            repo_root=REPO_ROOT,
            target=args.target,
            workload_ids=args.workload_id,
        )
    else:
        rows = load_compilation_workloads(
            input_path,
            repo_root=REPO_ROOT,
            target=args.target,
            workload_ids=args.workload_id,
        )
    copied_rows = materialize_rows(rows, dawn_source_dir=dawn_source_dir)
    patch_benchmark_inputs_script(
        script_path,
        [str(row["dawnBenchmarkPath"]) for row in copied_rows],
    )
    patch_msl_writer_bench(dawn_source_dir / MSL_WRITER_BENCH_SOURCE)
    if args.build:
        run_ninja(args.ninja_bin, build_dir)
    state_path = REPO_ROOT / args.output_state
    write_state(
        path=state_path,
        input_path=input_path,
        source_kind=source_kind,
        dawn_source_dir=dawn_source_dir,
        build_dir=build_dir,
        target=normalize_target(args.target),
        copied_rows=copied_rows,
        built=bool(args.build),
    )
    print(
        f"materialized {len(copied_rows)} Tint warm benchmark inputs "
        f"and wrote {repo_relative(state_path)}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
