"""Unified correctness-bearing workload execution and receipt emission."""

from __future__ import annotations

import hashlib
import json
import shutil
import subprocess
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import jsonschema


SUITE_SCHEMA_PATH = Path("config/doe-workload-suite.schema.json")
LEDGER_SCHEMA_PATH = Path("config/doe-workload-ledger.schema.json")


def _canonical_bytes(value: Any) -> bytes:
    return json.dumps(
        value,
        separators=(",", ":"),
        sort_keys=True,
    ).encode("utf-8")


def _sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def _sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _resolve_inside(root: Path, raw_path: str) -> Path:
    resolved = (root / raw_path).resolve()
    try:
        resolved.relative_to(root)
    except ValueError as exc:
        raise ValueError(f"path escapes repository root: {raw_path}") from exc
    return resolved


def _tree_items(root: Path, tree: Path) -> list[dict[str, str]]:
    items: list[dict[str, str]] = []
    for path in sorted(tree.rglob("*")):
        relative_path = path.relative_to(root).as_posix()
        if path.is_symlink():
            target = path.readlink().as_posix().encode("utf-8")
            items.append(
                {
                    "kind": "symlink",
                    "path": relative_path,
                    "sha256": _sha256_bytes(target),
                }
            )
            continue
        if path.is_dir():
            continue
        if not path.is_file():
            raise ValueError(f"unsupported input kind: {relative_path}")
        items.append(
            {
                "kind": "file",
                "path": relative_path,
                "sha256": _sha256_file(path),
            }
        )
    return items


def _repository_tree_items(root: Path, tree: Path) -> list[dict[str, str]]:
    relative_tree = tree.relative_to(root).as_posix()
    pathspec = "." if relative_tree == "." else relative_tree
    listed = subprocess.run(
        [
            "git",
            "ls-files",
            "--cached",
            "--others",
            "--exclude-standard",
            "-z",
            "--",
            pathspec,
        ],
        cwd=root,
        check=False,
        capture_output=True,
    )
    if listed.returncode != 0:
        detail = listed.stderr.decode("utf-8", errors="replace").strip()
        raise ValueError(f"failed to enumerate repository inputs: {detail}")

    items: list[dict[str, str]] = []
    raw_paths = sorted(
        {
            item.decode("utf-8")
            for item in listed.stdout.split(b"\0")
            if item
        }
    )
    for raw_path in raw_paths:
        repository_path = Path(raw_path)
        if repository_path.is_absolute() or ".." in repository_path.parts:
            raise ValueError(f"invalid repository input path: {raw_path}")
        path = root / repository_path
        try:
            path.relative_to(tree)
        except ValueError as exc:
            raise ValueError(
                f"repository input escapes declared tree: {raw_path}"
            ) from exc
        relative_path = raw_path
        if path.is_symlink():
            items.append(
                {
                    "kind": "symlink",
                    "path": relative_path,
                    "sha256": _sha256_bytes(path.readlink().as_posix().encode("utf-8")),
                }
            )
            continue
        resolved_path = _resolve_inside(root, raw_path)
        if resolved_path.is_file():
            items.append(
                {
                    "kind": "file",
                    "path": relative_path,
                    "sha256": _sha256_file(resolved_path),
                }
            )
        elif not resolved_path.exists():
            items.append(
                {
                    "kind": "deleted",
                    "path": relative_path,
                    "sha256": _sha256_bytes(f"deleted\0{relative_path}".encode("utf-8")),
                }
            )
        else:
            raise ValueError(f"unsupported repository input kind: {relative_path}")
    return items


def _build_input_manifest(
    repo_root: Path,
    inputs: list[dict[str, str]],
) -> dict[str, Any]:
    items: list[dict[str, str]] = []
    for input_spec in inputs:
        raw_path = input_spec["path"]
        path = _resolve_inside(repo_root, raw_path)
        if not path.exists():
            raise FileNotFoundError(f"workload input does not exist: {raw_path}")
        if input_spec["kind"] == "file":
            if not path.is_file():
                raise ValueError(f"workload input is not a file: {raw_path}")
            items.append(
                {
                    "kind": "file",
                    "path": path.relative_to(repo_root).as_posix(),
                    "sha256": _sha256_file(path),
                }
            )
            continue
        if not path.is_dir():
            raise ValueError(f"workload input is not a tree: {raw_path}")
        if input_spec["kind"] == "repository-tree":
            items.extend(_repository_tree_items(repo_root, path))
        else:
            items.extend(_tree_items(repo_root, path))
    if not items:
        raise ValueError("workload input manifest is empty")
    return {
        "algorithm": "sha256",
        "items": items,
        "sha256": _sha256_bytes(_canonical_bytes(items)),
    }


def _write_extension(
    repo_root: Path,
    extension_dir: Path,
    workload_id: str,
    extension_type: str,
    data: bytes,
    suffix: str,
) -> dict[str, str]:
    extension_dir.mkdir(parents=True, exist_ok=True)
    path = extension_dir / f"{workload_id}.{extension_type}.{suffix}"
    path.write_bytes(data)
    return {
        "extensionType": extension_type,
        "path": path.relative_to(repo_root).as_posix(),
        "sha256": _sha256_bytes(data),
    }


def _extension_path(
    extension_dir: Path,
    workload_id: str,
    extension_type: str,
    suffix: str,
) -> Path:
    extension_dir.mkdir(parents=True, exist_ok=True)
    return extension_dir / f"{workload_id}.{extension_type}.{suffix}"


def _extension_ref(
    repo_root: Path,
    path: Path,
    extension_type: str,
) -> dict[str, str]:
    return {
        "extensionType": extension_type,
        "path": path.relative_to(repo_root).as_posix(),
        "sha256": _sha256_file(path),
    }


def _executor_identity(
    repo_root: Path,
    executor: dict[str, Any],
) -> tuple[dict[str, Any], Path]:
    working_directory = _resolve_inside(repo_root, executor["workingDirectory"])
    if not working_directory.is_dir():
        raise ValueError(
            "executor working directory does not exist: "
            f"{executor['workingDirectory']}"
        )
    command = executor["command"]
    executable_raw = command[0]
    if "/" in executable_raw:
        executable_path = (working_directory / executable_raw).resolve()
    else:
        resolved = shutil.which(executable_raw)
        if resolved is None:
            raise FileNotFoundError(
                f"executor executable not found: {executable_raw}"
            )
        executable_path = Path(resolved).resolve()
    if not executable_path.is_file():
        raise FileNotFoundError(
            f"executor executable is not a file: {executable_path}"
        )
    command_identity = {
        "command": command,
        "executorKind": executor["executorKind"],
        "workingDirectory": working_directory.relative_to(repo_root).as_posix(),
    }
    return (
        {
            "commandHash": _sha256_bytes(_canonical_bytes(command_identity)),
            "executableHash": _sha256_file(executable_path),
            "executorId": executor["executorId"],
            "executorKind": executor["executorKind"],
        },
        working_directory,
    )


def _extension_dir(output_path: Path) -> Path:
    return output_path.parent / f"{output_path.stem}.extensions"


def _run_workload(
    repo_root: Path,
    output_path: Path,
    workload: dict[str, Any],
) -> dict[str, Any]:
    workload_id = workload["workloadId"]
    input_manifest = _build_input_manifest(repo_root, workload["inputs"])
    executor_identity, working_directory = _executor_identity(
        repo_root,
        workload["executor"],
    )
    extension_dir = _extension_dir(output_path)
    input_extension = _write_extension(
        repo_root,
        extension_dir,
        workload_id,
        "input_manifest",
        json.dumps(input_manifest, indent=2, sort_keys=True).encode("utf-8") + b"\n",
        "json",
    )

    stdout_path = _extension_path(
        extension_dir,
        workload_id,
        "process_stdout",
        "txt",
    )
    stderr_path = _extension_path(
        extension_dir,
        workload_id,
        "process_stderr",
        "txt",
    )
    started_ns = time.monotonic_ns()
    with stdout_path.open("wb") as stdout_handle, stderr_path.open(
        "wb"
    ) as stderr_handle:
        process = subprocess.run(
            workload["executor"]["command"],
            cwd=working_directory,
            check=False,
            stderr=stderr_handle,
            stdout=stdout_handle,
        )
    elapsed_ns = time.monotonic_ns() - started_ns

    evidence_extensions = [input_extension]
    process_result_extension = _write_extension(
        repo_root,
        extension_dir,
        workload_id,
        "process_result",
        json.dumps(
            {"returnCode": process.returncode},
            indent=2,
            sort_keys=True,
        ).encode("utf-8")
        + b"\n",
        "json",
    )
    evidence_extensions.append(process_result_extension)
    evidence_extensions.append(
        _extension_ref(
            repo_root,
            stdout_path,
            "process_stdout",
        )
    )
    evidence_extensions.append(
        _extension_ref(
            repo_root,
            stderr_path,
            "process_stderr",
        )
    )

    oracle = workload["oracle"]
    oracle_passed = process.returncode == oracle["expectedExitCode"]
    first_failing_boundary: str | None = None
    reason_code = "oracle_passed"
    if not oracle_passed:
        first_failing_boundary = "oracle"
        reason_code = "unexpected_process_exit"

    declared_extensions: list[dict[str, str]] = []
    if oracle_passed:
        for extension in workload.get("evidenceExtensions", []):
            extension_path = _resolve_inside(repo_root, extension["path"])
            if not extension_path.is_file():
                if extension["required"]:
                    first_failing_boundary = "evidence_extension"
                    reason_code = "required_evidence_extension_missing"
                    break
                continue
            declared_extensions.append(
                {
                    "extensionType": extension["extensionType"],
                    "path": extension_path.relative_to(repo_root).as_posix(),
                    "sha256": _sha256_file(extension_path),
                }
            )
    evidence_extensions.extend(declared_extensions)

    correctness_status = "pass" if first_failing_boundary is None else "fail"
    return {
        "correctness": {
            "firstFailingBoundary": first_failing_boundary,
            "reasonCode": reason_code,
            "status": correctness_status,
        },
        "evidenceExtensions": evidence_extensions,
        "executorIdentity": executor_identity,
        "expectedOutcome": {
            "expectedExitCode": oracle["expectedExitCode"],
            "kind": oracle["kind"],
            "oracleId": oracle["oracleId"],
        },
        "inputIdentity": {
            "algorithm": "sha256",
            "hash": input_manifest["sha256"],
        },
        "measuredTiming": {"elapsedNs": elapsed_ns},
        "policyId": workload["policy"]["policyId"],
        "workloadId": workload_id,
    }


def _load_validated(path: Path, schema_path: Path) -> dict[str, Any]:
    value = json.loads(path.read_text(encoding="utf-8"))
    schema = json.loads(schema_path.read_text(encoding="utf-8"))
    try:
        jsonschema.Draft202012Validator(schema).validate(value)
    except jsonschema.ValidationError as exc:
        raise ValueError(f"schema validation failed for {path}: {exc.message}") from exc
    return value


def _validate_semantics(suite: dict[str, Any]) -> None:
    seen: set[str] = set()
    for workload in suite["workloads"]:
        workload_id = workload["workloadId"]
        if workload_id in seen:
            raise ValueError(f"duplicate workload id: {workload_id}")
        seen.add(workload_id)
        policy = workload["policy"]
        if policy["kind"] == "claim-bearing" and not workload.get(
            "evidenceExtensions"
        ):
            raise ValueError(
                "claim-bearing workload requires evidence extensions: "
                f"{workload_id}"
            )


def run_suite(
    suite_path: Path,
    output_path: Path,
    repo_root: Path,
    workload_id: str = "",
) -> dict[str, Any]:
    """Execute selected workloads and write one consolidated ledger."""

    repo_root = repo_root.resolve()
    suite_path = suite_path.resolve()
    output_path = output_path.resolve()
    try:
        output_path.relative_to(repo_root)
    except ValueError as exc:
        raise ValueError(f"output path escapes repository root: {output_path}") from exc
    extension_dir = _extension_dir(output_path)
    if output_path.exists():
        raise FileExistsError(f"workload ledger already exists: {output_path}")
    if extension_dir.exists():
        raise FileExistsError(
            f"workload extension directory already exists: {extension_dir}"
        )
    suite = _load_validated(suite_path, repo_root / SUITE_SCHEMA_PATH)
    _validate_semantics(suite)
    selected = [
        workload
        for workload in suite["workloads"]
        if not workload_id or workload["workloadId"] == workload_id
    ]
    if not selected:
        raise ValueError(f"workload not found in suite: {workload_id}")

    results = [
        _run_workload(repo_root, output_path, workload) for workload in selected
    ]
    passed = sum(result["correctness"]["status"] == "pass" for result in results)
    failed = len(results) - passed
    ledger = {
        "artifactKind": "doe-workload-ledger",
        "generatedAt": datetime.now(timezone.utc).isoformat(),
        "results": results,
        "schemaVersion": 1,
        "suiteId": suite["suiteId"],
        "suiteIdentity": {
            "algorithm": "sha256",
            "hash": _sha256_bytes(_canonical_bytes(suite)),
        },
        "summary": {
            "failed": failed,
            "passed": passed,
            "status": "pass" if failed == 0 else "fail",
            "total": len(results),
        },
    }
    ledger_schema = json.loads(
        (repo_root / LEDGER_SCHEMA_PATH).read_text(encoding="utf-8")
    )
    jsonschema.Draft202012Validator(ledger_schema).validate(ledger)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(
        json.dumps(ledger, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    return ledger
