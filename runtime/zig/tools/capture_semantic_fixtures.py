"""Capture hardware-free semantic fixtures from one named Doe Git snapshot."""

from __future__ import annotations

import argparse
import hashlib
import json
import platform
import shutil
import subprocess
import sys
import tarfile
import tempfile
from pathlib import Path, PurePosixPath
from typing import Any

from source_architecture import (
    analyze,
    canonical_json,
    load_manifest,
    sha256_file,
)


ROOT = Path(__file__).resolve().parents[1]
OUTPUT_ROOT = ROOT / "reports" / "recomposition" / "semantic-fixtures"
WGSL_FIXTURE = "examples/wgsl/csl-gelu-smoke.wgsl"
COMMAND_FIXTURE = "examples/copy_buffer_to_buffer_4kb_commands.json"
IR_DIGEST_OBSERVER_PATHS = (
    "src/cli/entrypoints/main_emit_ir_digest.zig",
    "src/compiler/wgsl/ir/ir_digest.zig",
)
WEBGPU_ABI_SOURCE_CONFIG = "config/webgpu-abi-source.json"
LEGACY_WEBGPU_HEADER_PATH = Path(
    "bench/vendor/dawn/third_party/webgpu-headers/src/webgpu.h"
)
SEMANTIC_BUILD_STEPS = (
    "doe-runtime",
    "dropin",
    "emit-ir-digest",
    "emit-csl",
    "emit-hlsl",
    "emit-msl",
    "emit-spirv",
    "ort-plugin-ep",
)


def _run(
    command: list[str],
    cwd: Path,
    *,
    require_success: bool = True,
) -> subprocess.CompletedProcess[bytes]:
    result = subprocess.run(command, cwd=cwd, check=False, capture_output=True)
    if require_success and result.returncode != 0:
        detail = result.stderr.decode("utf-8", errors="replace").strip()
        if not detail:
            detail = result.stdout.decode("utf-8", errors="replace").strip()
        raise RuntimeError(
            f"command failed at {' '.join(command[:3])}: {detail[-4096:]}"
        )
    return result


def _find_zig(root: Path) -> Path:
    repository_root = root.parents[1]
    workspace_root = root.parents[2]
    candidates = sorted((repository_root / ".tooling").glob("zig-*/zig"))
    candidates.extend(sorted((workspace_root / ".tooling").glob("zig-*/zig")))
    system_zig = shutil.which("zig")
    if system_zig:
        candidates.append(Path(system_zig))
    if not candidates:
        raise RuntimeError("Zig executable not found")
    return candidates[-1].resolve()


def _semantic_build_commands(
    zig: Path,
    cache: Path,
    prefix: Path,
) -> list[list[str]]:
    """Build semantic tools in fixed, independently diagnosable steps."""

    return [
        [
            str(zig),
            "build",
            step,
            "-Doptimize=ReleaseSafe",
            "-j1",
            "--seed",
            "0",
            "--summary",
            "none",
            "--cache-dir",
            str(cache),
            "--prefix",
            str(prefix),
        ]
        for step in SEMANTIC_BUILD_STEPS
    ]


def _extract_git_archive(archive_path: Path, destination: Path) -> None:
    """Extract a local Git archive without version-dependent tar filters."""

    with tarfile.open(archive_path, mode="r:") as archive:
        members = archive.getmembers()
        for member in members:
            member_path = PurePosixPath(member.name)
            if (
                member_path.is_absolute()
                or ".." in member_path.parts
                or member_path.as_posix() != member.name
            ):
                raise RuntimeError(f"unsafe Git archive path: {member.name!r}")
            if not member.isdir() and not member.isfile():
                raise RuntimeError(f"unsupported Git archive entry: {member.name!r}")
        destination.mkdir(parents=True, exist_ok=True)
        for member in members:
            target = destination / member.name
            if member.isdir():
                target.mkdir(parents=True, exist_ok=True)
                continue
            target.parent.mkdir(parents=True, exist_ok=True)
            source = archive.extractfile(member)
            if source is None:
                raise RuntimeError(f"Git archive file has no content: {member.name!r}")
            with source, target.open("wb") as output:
                shutil.copyfileobj(source, output)
            target.chmod(member.mode & 0o777)


def _materialize_runtime(
    root: Path,
    git_ref: str,
    temporary_root: Path,
) -> tuple[Path, str, dict[str, Any]]:
    repository_root = root.parents[1]
    commit = _run(
        ["git", "rev-parse", f"{git_ref}^{{commit}}"],
        repository_root,
    ).stdout.decode("ascii").strip()
    relative_runtime = root.relative_to(repository_root).as_posix()
    archive = _run(
        [
            "git",
            "archive",
            "--format=tar",
            commit,
            relative_runtime,
            "bench/kernels",
            "config",
            COMMAND_FIXTURE,
            "pipeline/lean",
            "runtime/bridge/onnxruntime-ep",
        ],
        repository_root,
    ).stdout
    archive_path = temporary_root / "runtime.tar"
    archive_path.write_bytes(archive)
    _extract_git_archive(archive_path, temporary_root)
    archive_path.unlink()
    abi_source_config = json.loads(
        (repository_root / WEBGPU_ABI_SOURCE_CONFIG).read_text(encoding="utf-8")
    )
    abi_source = abi_source_config["source"]
    header_relative = Path(abi_source["path"])
    header_source = repository_root / header_relative
    if not header_source.is_file():
        raise RuntimeError(f"pinned WebGPU ABI header is missing: {header_source}")
    if sha256_file(header_source) != abi_source["sha256"]:
        raise RuntimeError("pinned WebGPU ABI header hash does not match config")
    header_destination = temporary_root / header_relative
    header_destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(header_source, header_destination)
    legacy_header_destination = temporary_root / LEGACY_WEBGPU_HEADER_PATH
    legacy_header_destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(header_source, legacy_header_destination)
    snapshot = temporary_root / relative_runtime
    if not (snapshot / "build.zig").is_file():
        raise RuntimeError("materialized runtime snapshot has no build.zig")
    instrumentation = _install_ir_digest_observer(snapshot, root)
    return snapshot, commit, instrumentation


def _install_ir_digest_observer(
    snapshot: Path,
    tool_source_root: Path,
) -> dict[str, Any]:
    """Install the current pure IR observer when the frozen source predates it."""

    build_path = snapshot / "build.zig"
    build_source = build_path.read_text(encoding="utf-8")
    if "emit-ir-digest" in build_source:
        return {
            "kind": "native-snapshot",
            "observers": _ir_digest_observer_records(snapshot),
            "status": "present",
        }
    observer_records = _ir_digest_observer_records(tool_source_root)
    for relative_path in IR_DIGEST_OBSERVER_PATHS:
        source = tool_source_root / relative_path
        destination = snapshot / relative_path
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, destination)
    wgsl_module_path = snapshot / "src/compiler/wgsl/mod.zig"
    wgsl_module = wgsl_module_path.read_text(encoding="utf-8")
    module_marker = 'pub const ir = @import("ir/ir.zig");\n'
    if module_marker not in wgsl_module:
        raise RuntimeError("frozen WGSL module has no canonical IR export marker")
    wgsl_module_path.write_text(
        wgsl_module.replace(
            module_marker,
            module_marker + 'pub const ir_digest = @import("ir/ir_digest.zig");\n',
            1,
        ),
        encoding="utf-8",
    )
    build_marker = "    const emit_csl_exe = b.addExecutable(.{\n"
    if build_marker not in build_source:
        raise RuntimeError("frozen build has no canonical CSL emitter marker")
    build_instrumentation = """    const emit_ir_digest_exe = b.addExecutable(.{
        .name = "doe-emit-ir-digest",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cli/entrypoints/main_emit_ir_digest.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "build_options", .module = build_options_module },
                .{ .name = "doe", .module = doe_module },
            },
        }),
    });
    const install_emit_ir_digest = b.addInstallArtifact(emit_ir_digest_exe, .{});
    const emit_ir_digest_step = b.step(
        "emit-ir-digest",
        "Build the canonical WGSL IR digest observer",
    );
    emit_ir_digest_step.dependOn(&install_emit_ir_digest.step);

"""
    build_path.write_text(
        build_source.replace(
            build_marker,
            build_instrumentation + build_marker,
            1,
        ),
        encoding="utf-8",
    )
    return {
        "kind": "post-hoc-pure-observer",
        "observers": observer_records,
        "status": "installed",
    }


def _ir_digest_observer_records(root: Path) -> list[dict[str, str]]:
    records: list[dict[str, str]] = []
    for relative_path in IR_DIGEST_OBSERVER_PATHS:
        path = root / relative_path
        if not path.is_file():
            raise RuntimeError(f"IR digest observer source is missing: {path}")
        records.append({"path": relative_path, "sha256": sha256_file(path)})
    return records


def _canonical_jsonl(rows: list[dict[str, Any]]) -> bytes:
    return "".join(
        json.dumps(row, separators=(",", ":"), sort_keys=True) + "\n"
        for row in rows
    ).encode("utf-8")


def _normalize_trace(trace_path: Path) -> bytes:
    rows: list[dict[str, Any]] = []
    for line in trace_path.read_text(encoding="utf-8").splitlines():
        row = json.loads(line)
        row.pop("timestampMonoNs", None)
        rows.append(row)
    return _canonical_jsonl(rows)


def _normalize_trace_meta(meta_path: Path) -> bytes:
    payload = json.loads(meta_path.read_text(encoding="utf-8"))
    volatile_fields = sorted(
        key
        for key in payload
        if key.startswith("host") and key.endswith("Ns")
    )
    for key in volatile_fields:
        payload.pop(key)
    payload["excludedVolatileFields"] = volatile_fields
    return canonical_json(payload).encode("utf-8")


def _normalize_diagnostic(content: bytes, temporary_root: Path) -> bytes:
    text = content.decode("utf-8", errors="replace")
    return text.replace(str(temporary_root), "$FIXTURE_ROOT").encode("utf-8")


def _write_fixture(
    destination: Path,
    relative_path: str,
    content: bytes,
) -> dict[str, Any]:
    path = destination / relative_path
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(content)
    return {
        "path": relative_path,
        "sha256": hashlib.sha256(content).hexdigest(),
        "sizeBytes": len(content),
    }


def _exported_symbols(path: Path) -> bytes:
    nm = shutil.which("nm")
    if nm is None:
        raise RuntimeError("nm is required for shared-library symbol capture")
    attempts = (
        [nm, "-D", "--defined-only", str(path)],
        [nm, "-g", "--defined-only", str(path)],
        [nm, "-gU", str(path)],
    )
    failures: list[str] = []
    for command in attempts:
        result = subprocess.run(command, check=False, capture_output=True, text=True)
        if result.returncode != 0:
            failures.append(result.stderr.strip())
            continue
        symbols: set[str] = set()
        for line in result.stdout.splitlines():
            fields = line.split()
            if fields:
                symbols.add(fields[-1])
        ordered_symbols = sorted(symbols)
        return ("\n".join(ordered_symbols) + "\n").encode("utf-8")
    raise RuntimeError(
        f"could not extract symbols from {path.name}: " + "; ".join(failures)
    )


def capture(root: Path, git_ref: str, destination: Path) -> dict[str, Any]:
    """Build and run semantic fixtures from one isolated Git snapshot."""

    capture_tool_sha256 = sha256_file(Path(__file__))
    zig = _find_zig(root)
    with tempfile.TemporaryDirectory(prefix="doe-semantic-fixtures-") as temporary:
        temporary_root = Path(temporary)
        if git_ref == "WORKTREE":
            snapshot = root
            execution_root = root.parents[1]
            config = load_manifest(root / "source-layout.json")
            snapshot_analysis = analyze(root, config)
            if snapshot_analysis.manifest_errors or snapshot_analysis.unresolved_imports:
                raise RuntimeError("worktree architecture is not valid before capture")
            commit = f"WORKTREE:{snapshot_analysis.source_tree_sha256}"
            snapshot_kind = "live-worktree"
        else:
            snapshot, commit, ir_digest_instrumentation = _materialize_runtime(
                root,
                git_ref,
                temporary_root,
            )
            execution_root = temporary_root
            snapshot_kind = "git-archive"
            config = load_manifest(snapshot / "source-layout.json")
            snapshot_analysis = analyze(snapshot, config)
            if (
                snapshot_analysis.manifest_errors
                or snapshot_analysis.unresolved_imports
            ):
                raise RuntimeError("Git snapshot architecture is not valid before capture")
        if git_ref == "WORKTREE":
            ir_digest_instrumentation = {
                "kind": "native-worktree",
                "observers": _ir_digest_observer_records(root),
                "status": "present",
            }
        cache = temporary_root / "cache"
        prefix = temporary_root / "prefix"
        for build_command in _semantic_build_commands(zig, cache, prefix):
            _run(build_command, snapshot)
        binary_root = prefix / "bin"
        runtime = binary_root / "doe-zig-runtime"
        input_path = snapshot / WGSL_FIXTURE
        command_input_path = execution_root / COMMAND_FIXTURE
        trace_path = temporary_root / "trace.jsonl"
        trace_meta_path = temporary_root / "trace-meta.json"

        embedded_normalized = _run(
            [str(runtime), "--emit-normalized"],
            execution_root,
        ).stdout
        normalized = _run(
            [
                str(runtime),
                "--commands",
                str(command_input_path),
                "--emit-normalized",
            ],
            execution_root,
        ).stdout
        trace_run = _run(
            [
                str(runtime),
                "--trace",
                "--trace-jsonl",
                str(trace_path),
                "--trace-meta",
                str(trace_meta_path),
            ],
            execution_root,
        )
        trace_meta = json.loads(trace_meta_path.read_text(encoding="utf-8"))
        replay = _run(
            [str(runtime), "--replay", str(trace_path)],
            execution_root,
        )
        invalid_args = _run(
            [str(runtime), "--command-repeat", "0"],
            execution_root,
            require_success=False,
        )
        invalid_commands = temporary_root / "invalid-commands.json"
        invalid_commands.write_text(
            '[{"kind":"definitely_invalid"}]\n',
            encoding="utf-8",
        )
        invalid_command_json = _run(
            [str(runtime), "--commands", str(invalid_commands)],
            execution_root,
            require_success=False,
        )

        emitted: dict[str, bytes] = {}
        ir_digest = _run(
            [
                str(binary_root / "doe-emit-ir-digest"),
                "--shader-path",
                str(input_path),
            ],
            snapshot,
        ).stdout.decode("ascii").strip()
        if len(ir_digest) != 64 or any(
            character not in "0123456789abcdef" for character in ir_digest
        ):
            raise RuntimeError("WGSL IR digest tool emitted a non-canonical digest")
        emitter_specs = {
            "wgsl-output.csl": "doe-emit-csl",
            "wgsl-output.hlsl": "doe-emit-hlsl",
            "wgsl-output.msl": "doe-emit-msl",
            "wgsl-output.spv": "doe-emit-spirv",
        }
        for output_name, executable_name in emitter_specs.items():
            executable = binary_root / executable_name
            result = _run(
                [str(executable), "--shader-path", str(input_path)],
                snapshot,
            )
            emitted[output_name] = result.stdout

        invalid_wgsl = temporary_root / "invalid.wgsl"
        invalid_wgsl.write_text("@compute fn main( {\n", encoding="utf-8")
        unsupported_wgsl = temporary_root / "unsupported.wgsl"
        unsupported_wgsl.write_text(
            "@compute @workgroup_size(1)\n"
            "fn main() {\n"
            "    let value = transpose(1.0);\n"
            "}\n",
            encoding="utf-8",
        )
        emitter_errors: dict[str, dict[str, Any]] = {}
        emitter_unsupported: dict[str, dict[str, Any]] = {}
        for _, executable_name in emitter_specs.items():
            result = _run(
                [
                    str(binary_root / executable_name),
                    "--shader-path",
                    str(invalid_wgsl),
                ],
                snapshot,
                require_success=False,
            )
            diagnostic = _normalize_diagnostic(result.stderr, temporary_root)
            emitter_errors[executable_name] = {
                "exitCode": result.returncode,
                "failureBoundary": "wgsl-parser",
                "stderrSha256": hashlib.sha256(diagnostic).hexdigest(),
                "stderrText": diagnostic.decode("utf-8", errors="replace"),
            }
            unsupported_result = _run(
                [
                    str(binary_root / executable_name),
                    "--shader-path",
                    str(unsupported_wgsl),
                ],
                snapshot,
                require_success=False,
            )
            unsupported_diagnostic = _normalize_diagnostic(
                unsupported_result.stderr,
                temporary_root,
            )
            if (
                unsupported_result.returncode == 0
                or b"UnsupportedBuiltin" not in unsupported_diagnostic
            ):
                raise RuntimeError(
                    f"{executable_name} did not preserve UnsupportedBuiltin"
                )
            emitter_unsupported[executable_name] = {
                "errorName": "UnsupportedBuiltin",
                "exitCode": unsupported_result.returncode,
                "failureBoundary": "wgsl-sema",
                "stderrSha256": hashlib.sha256(
                    unsupported_diagnostic
                ).hexdigest(),
                "stderrText": unsupported_diagnostic.decode(
                    "utf-8",
                    errors="replace",
                ),
            }

        destination.mkdir(parents=True, exist_ok=True)
        records = [
            _write_fixture(
                destination,
                "command-input.json",
                command_input_path.read_bytes(),
            ),
            _write_fixture(destination, "command-normalized.jsonl", normalized),
            _write_fixture(
                destination,
                "embedded-command-normalized.jsonl",
                embedded_normalized,
            ),
            _write_fixture(
                destination,
                "trace-normalized.jsonl",
                _normalize_trace(trace_path),
            ),
            _write_fixture(
                destination,
                "trace-meta-normalized.json",
                _normalize_trace_meta(trace_meta_path),
            ),
            _write_fixture(destination, "wgsl-input.wgsl", input_path.read_bytes()),
            _write_fixture(
                destination,
                "wgsl-unsupported-input.wgsl",
                unsupported_wgsl.read_bytes(),
            ),
        ]
        records.extend(
            _write_fixture(destination, name, content)
            for name, content in sorted(emitted.items())
        )
        library_records: list[dict[str, Any]] = []
        promoted_prefixes = ("libonnxruntime_doe_ep", "libwebgpu_doe")
        libraries = sorted(
            path
            for path in (prefix / "lib").iterdir()
            if path.is_file() and path.name.startswith(promoted_prefixes)
        )
        if len(libraries) != len(promoted_prefixes):
            raise RuntimeError(
                "isolated build did not produce both promoted shared libraries"
        )
        for library in libraries:
            symbol_path = f"abi/{library.name}.symbols.txt"
            symbol_content = _exported_symbols(library)
            symbol_record = _write_fixture(
                destination,
                symbol_path,
                symbol_content,
            )
            records.append(symbol_record)
            library_records.append(
                {
                    "path": library.name,
                    "sha256": sha256_file(library),
                    "sizeBytes": library.stat().st_size,
                    "symbolCount": len(symbol_content.splitlines()),
                    "symbols": symbol_path,
                }
            )
        manifest = {
            "build": {
                "optimize": "ReleaseSafe",
                "strategy": "ordered-independent-steps",
                "steps": list(SEMANTIC_BUILD_STEPS),
            },
            "captureToolSha256": capture_tool_sha256,
            "commandNormalization": {
                "input": "command-input.json",
                "output": "command-normalized.jsonl",
            },
            "errorClassifications": {
                "invalidCommandArguments": {
                    "exitCode": invalid_args.returncode,
                    "failureBoundary": "argument-validation",
                    "stdout": invalid_args.stdout.decode("utf-8", errors="replace"),
                },
                "invalidCommandJson": {
                    "exitCode": invalid_command_json.returncode,
                    "failureBoundary": "command-json-parse",
                    "stderr": _normalize_diagnostic(
                        invalid_command_json.stderr,
                        temporary_root,
                    ).decode("utf-8", errors="replace"),
                    "stdout": _normalize_diagnostic(
                        invalid_command_json.stdout,
                        temporary_root,
                    ).decode("utf-8", errors="replace"),
                },
                "invalidWgslByEmitter": emitter_errors,
                "unsupportedWgslByEmitter": emitter_unsupported,
            },
            "files": sorted(records, key=lambda record: record["path"]),
            "git": {
                "baseCommit": commit,
                "requestedRef": git_ref,
                "snapshotKind": snapshot_kind,
            },
            "host": {
                "machine": platform.machine(),
                "operatingSystem": platform.system(),
                "release": platform.release(),
            },
            "irDigestInstrumentation": ir_digest_instrumentation,
            "replay": {
                "exitCode": replay.returncode,
                "stderrBytes": len(replay.stderr),
                "stdoutBytes": len(replay.stdout),
                "status": "passed" if replay.returncode == 0 else "failed",
            },
            "schemaVersion": 1,
            "sharedLibraries": library_records,
            "sourceTreeSha256": snapshot_analysis.source_tree_sha256,
            "status": "captured",
            "trace": {
                "normalizedOutput": "trace-normalized.jsonl",
                "previousHash": trace_meta["previousHash"],
                "rawStdoutMatchesTraceFile": (
                    trace_run.stdout == trace_path.read_bytes()
                ),
                "rowCount": trace_meta["rowCount"],
                "terminalHash": trace_meta["hash"],
                "volatileFieldsExcluded": ["timestampMonoNs", "host*Ns"],
            },
            "wgsl": {
                "input": "wgsl-input.wgsl",
                "irDigest": ir_digest,
                "outputs": sorted(emitted),
            },
            "zigVersion": _run([str(zig), "version"], snapshot).stdout.decode(
                "ascii"
            ).strip(),
            "zigExecutableSha256": sha256_file(zig),
        }
        if git_ref == "WORKTREE":
            final_analysis = analyze(root, config)
            if (
                final_analysis.source_tree_sha256
                != snapshot_analysis.source_tree_sha256
            ):
                raise RuntimeError(
                    "worktree source changed during semantic fixture capture"
                )
        if sha256_file(Path(__file__)) != capture_tool_sha256:
            raise RuntimeError(
                "semantic fixture capture tool changed during capture"
            )
    return manifest


def _publish_fixture_set(staging: Path, destination: Path) -> None:
    """Publish one complete fixture set while preserving the prior set on error."""

    destination.parent.mkdir(parents=True, exist_ok=True)
    if not destination.exists():
        staging.rename(destination)
        return
    backup = Path(
        tempfile.mkdtemp(
            prefix=f".{destination.name}.previous-",
            dir=destination.parent,
        )
    )
    backup.rmdir()
    destination.rename(backup)
    try:
        staging.rename(destination)
    except OSError:
        backup.rename(destination)
        raise
    shutil.rmtree(backup)


def parse_args() -> argparse.Namespace:
    """Parse semantic-fixture capture arguments."""

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=ROOT, help="runtime/zig root")
    source = parser.add_mutually_exclusive_group()
    source.add_argument("--git-ref", default="HEAD", help="Git snapshot to capture")
    source.add_argument(
        "--worktree",
        action="store_true",
        help="capture the live worktree and refuse source changes during the run",
    )
    parser.add_argument(
        "--output-root",
        type=Path,
        default=OUTPUT_ROOT,
        help="semantic fixture directory",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    output_root = args.output_root.resolve()
    output_root.parent.mkdir(parents=True, exist_ok=True)
    try:
        with tempfile.TemporaryDirectory(
            prefix=f".{output_root.name}.staging-",
            dir=output_root.parent,
        ) as temporary:
            staging = Path(temporary)
            manifest = capture(
                args.root.resolve(),
                "WORKTREE" if args.worktree else args.git_ref,
                staging,
            )
            (staging / "manifest.json").write_text(
                canonical_json(manifest),
                encoding="utf-8",
            )
            _publish_fixture_set(staging, output_root)
    except (OSError, RuntimeError, subprocess.SubprocessError, ValueError) as exc:
        print(f"semantic fixture capture failed: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
