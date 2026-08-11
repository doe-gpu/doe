"""Prepare and reproduce schema-backed external-project harnesses."""

from __future__ import annotations

import hashlib
import json
import os
import platform
import re
import subprocess
import sys
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import jsonschema

from bench.lib.ecosystem_registry import load_json_object


DEFAULT_REGISTRY_PATH = Path("config/ecosystem-registry.json")
DEFAULT_POLICY_PATH = Path("config/external-project-reproduction-policy.json")
HARNESS_SCHEMA_PATH = Path("config/external-project-harness.schema.json")
POLICY_SCHEMA_PATH = Path("config/external-project-reproduction-policy.schema.json")
PREPARATION_SCHEMA_PATH = Path(
    "config/external-project-preparation-receipt.schema.json"
)
REPRODUCTION_SCHEMA_PATH = Path(
    "config/external-project-reproduction-receipt.schema.json"
)
REGISTRY_SCHEMA_PATH = Path("config/ecosystem-registry.schema.json")
RUN_ID_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")
TEMPLATE_PATTERN = re.compile(
    r"\{(actorId|harnessId|runId|runRoot|upstreamRoot|preparationReceipt)\}"
)


class ReproductionError(RuntimeError):
    """Report an explicit external-project reproduction failure boundary."""

    def __init__(self, stage: str, message: str, *, unavailable: bool = False):
        super().__init__(message)
        self.stage = stage
        self.unavailable = unavailable


@dataclass(frozen=True)
class Selection:
    """Resolved registry, harness, policy, and output paths for one run."""

    root: Path
    registry_path: Path
    policy_path: Path
    manifest_path: Path
    actor: dict[str, Any]
    harness_ref: dict[str, Any]
    manifest: dict[str, Any]
    policy: dict[str, Any]
    actor_id: str
    harness_id: str
    run_id: str
    upstream_root: Path
    run_root: Path


@dataclass(frozen=True)
class ProcessResult:
    """Receipt record plus captured process output used by verification."""

    receipt: dict[str, Any]
    stdout: str
    stderr: str


class ProcessRecorder:
    """Execute shell-free commands and retain hash-bound stdout/stderr logs."""

    def __init__(self, root: Path, run_root: Path, phase: str):
        self.root = root
        self.run_root = run_root
        self.logs_root = run_root / "logs" / phase
        self.logs_root.mkdir(parents=True, exist_ok=True)
        self.sequence = 0

    def run(
        self,
        spec: dict[str, Any],
        *,
        working_directory: Path | None = None,
        environment: dict[str, str] | None = None,
    ) -> ProcessResult:
        """Run one declared command and persist its complete process evidence."""

        self.sequence += 1
        process_id = str(spec["id"])
        safe_id = re.sub(r"[^A-Za-z0-9._-]", "-", process_id)
        stem = f"{self.sequence:02d}-{safe_id}"
        stdout_path = self.logs_root / f"{stem}.stdout.log"
        stderr_path = self.logs_root / f"{stem}.stderr.log"
        command = [str(item) for item in spec["command"]]
        cwd = working_directory or _resolve_repo_path(
            self.root, str(spec["workingDirectory"])
        )
        timeout_seconds = int(spec["timeoutSeconds"])
        started_ns = time.monotonic_ns()
        stdout = b""
        stderr = b""
        exit_code = 127
        try:
            completed = subprocess.run(
                command,
                cwd=cwd,
                env=environment,
                check=False,
                capture_output=True,
                timeout=timeout_seconds,
            )
            stdout = completed.stdout
            stderr = completed.stderr
            exit_code = completed.returncode
        except FileNotFoundError as exc:
            stderr = f"command not found: {command[0]}: {exc}\n".encode()
        except subprocess.TimeoutExpired as exc:
            stdout = exc.stdout or b""
            stderr = (exc.stderr or b"") + (
                f"command timed out after {timeout_seconds} seconds\n".encode()
            )
            exit_code = 124
        elapsed_ns = time.monotonic_ns() - started_ns
        stdout_path.write_bytes(stdout)
        stderr_path.write_bytes(stderr)
        receipt = {
            "id": process_id,
            "command": command,
            "workingDirectory": _display_path(self.root, cwd),
            "exitCode": exit_code,
            "elapsedNs": elapsed_ns,
            "stdoutPath": _display_path(self.root, stdout_path),
            "stdoutSha256": _sha256_bytes(stdout),
            "stderrPath": _display_path(self.root, stderr_path),
            "stderrSha256": _sha256_bytes(stderr),
        }
        return ProcessResult(
            receipt=receipt,
            stdout=stdout.decode("utf-8", errors="replace"),
            stderr=stderr.decode("utf-8", errors="replace"),
        )


def _utc_now() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def default_run_id() -> str:
    """Return a collision-resistant UTC run identifier."""

    return datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")


def _sha256_bytes(content: bytes) -> str:
    return hashlib.sha256(content).hexdigest()


def _sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _payload_sha256(payload: dict[str, Any]) -> str:
    normalized = dict(payload)
    normalized.pop("receiptSha256", None)
    content = json.dumps(
        normalized,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")
    return _sha256_bytes(content)


def _display_path(root: Path, path: Path) -> str:
    resolved = path.resolve()
    try:
        return resolved.relative_to(root.resolve()).as_posix()
    except ValueError:
        return resolved.as_posix()


def _resolve_repo_path(root: Path, relative_path: str) -> Path:
    if Path(relative_path).is_absolute():
        raise ReproductionError("contract", f"absolute path is forbidden: {relative_path}")
    candidate = (root / relative_path).resolve()
    try:
        candidate.relative_to(root.resolve())
    except ValueError as exc:
        raise ReproductionError(
            "contract", f"path escapes repository root: {relative_path}"
        ) from exc
    return candidate


def _artifact(root: Path, artifact_id: str, path: Path) -> dict[str, Any]:
    if not path.is_file():
        raise ReproductionError(
            "artifact", f"required artifact is missing: {_display_path(root, path)}"
        )
    return {
        "id": artifact_id,
        "path": _display_path(root, path),
        "sha256": _sha256_file(path),
        "sizeBytes": path.stat().st_size,
    }


def _validate_payload(
    payload: dict[str, Any], schema_path: Path, *, label: str
) -> None:
    schema = load_json_object(schema_path)
    validator = jsonschema.Draft202012Validator(schema)
    errors = sorted(
        validator.iter_errors(payload),
        key=lambda item: tuple(str(part) for part in item.absolute_path),
    )
    if not errors:
        return
    first = errors[0]
    location = ".".join(str(part) for part in first.absolute_path) or "<root>"
    raise ReproductionError(
        "contract", f"{label} schema validation failed at {location}: {first.message}"
    )


def _load_validated(path: Path, schema_path: Path, *, label: str) -> dict[str, Any]:
    payload = load_json_object(path)
    _validate_payload(payload, schema_path, label=label)
    return payload


def _platform_id() -> str:
    if sys.platform.startswith("linux"):
        return "linux"
    if sys.platform == "darwin":
        return "darwin"
    if sys.platform == "win32":
        return "win32"
    raise ReproductionError(
        "host", f"unsupported reproduction host platform: {sys.platform}", unavailable=True
    )


def _render_template(template: str, values: dict[str, str]) -> str:
    unknown = re.findall(r"\{([^{}]+)\}", template)
    for token in unknown:
        if token not in values:
            raise ReproductionError("contract", f"unknown template token: {{{token}}}")
    return TEMPLATE_PATTERN.sub(lambda match: values[match.group(1)], template)


def _validate_install_steps(manifest: dict[str, Any]) -> None:
    install_steps = manifest.get("installation", {}).get("installSteps", [])
    step_ids = [step.get("id") for step in install_steps if isinstance(step, dict)]
    if len(step_ids) != len(set(step_ids)):
        raise ReproductionError(
            "contract", "installation step ids must be unique within a harness"
        )


def resolve_selection(
    root: Path,
    actor_id: str,
    harness_id: str,
    *,
    registry_path: Path = DEFAULT_REGISTRY_PATH,
    policy_path: Path = DEFAULT_POLICY_PATH,
    run_id: str | None = None,
    validate_contracts: bool = True,
) -> Selection:
    """Resolve one actor/harness selection and validate its source identity."""

    root = root.resolve()
    selected_run_id = run_id or default_run_id()
    if not RUN_ID_PATTERN.fullmatch(selected_run_id):
        raise ReproductionError(
            "contract",
            "run id must contain only letters, numbers, dot, underscore, or hyphen",
        )
    resolved_registry_path = _resolve_repo_path(root, registry_path.as_posix())
    resolved_policy_path = _resolve_repo_path(root, policy_path.as_posix())
    if validate_contracts:
        registry = _load_validated(
            resolved_registry_path,
            root / REGISTRY_SCHEMA_PATH,
            label="ecosystem registry",
        )
        policy = _load_validated(
            resolved_policy_path,
            root / POLICY_SCHEMA_PATH,
            label="external-project reproduction policy",
        )
    else:
        registry = load_json_object(resolved_registry_path)
        policy = load_json_object(resolved_policy_path)
    actor = next(
        (
            item
            for item in registry.get("actors", [])
            if isinstance(item, dict) and item.get("id") == actor_id
        ),
        None,
    )
    if actor is None:
        raise ReproductionError("selection", f"unknown ecosystem actor: {actor_id}")
    harness_ref = next(
        (
            item
            for item in actor.get("harnesses", [])
            if isinstance(item, dict) and item.get("id") == harness_id
        ),
        None,
    )
    if harness_ref is None:
        raise ReproductionError(
            "selection", f"unknown harness for {actor_id}: {harness_id}"
        )
    manifest_relative = harness_ref.get("manifestPath")
    if not isinstance(manifest_relative, str):
        raise ReproductionError(
            "selection", f"harness is not executable because it has no manifest: {harness_id}"
        )
    manifest_path = _resolve_repo_path(root, manifest_relative)
    if validate_contracts:
        manifest = _load_validated(
            manifest_path,
            root / HARNESS_SCHEMA_PATH,
            label="external-project harness",
        )
    else:
        manifest = load_json_object(manifest_path)
    _validate_install_steps(manifest)
    if manifest.get("actorId") != actor_id or manifest.get("harnessId") != harness_id:
        raise ReproductionError(
            "contract", "registry selection does not match manifest actor/harness identity"
        )
    actor_source = actor.get("source", {})
    upstream = manifest.get("upstream", {})
    if actor_source.get("repositoryUrl") != upstream.get("repositoryUrl"):
        raise ReproductionError(
            "contract", "registry and harness repository URLs do not match"
        )
    if actor_source.get("upstreamCommit") != upstream.get("commit"):
        raise ReproductionError(
            "contract", "registry and harness pinned commits do not match"
        )
    template_values = {
        "actorId": actor_id,
        "harnessId": harness_id,
        "runId": selected_run_id,
        "runRoot": "",
        "upstreamRoot": "",
        "preparationReceipt": "",
    }
    upstream_relative = _render_template(
        str(policy["upstreamRootTemplate"]), template_values
    )
    run_relative = _render_template(str(policy["runRootTemplate"]), template_values)
    return Selection(
        root=root,
        registry_path=resolved_registry_path,
        policy_path=resolved_policy_path,
        manifest_path=manifest_path,
        actor=actor,
        harness_ref=harness_ref,
        manifest=manifest,
        policy=policy,
        actor_id=actor_id,
        harness_id=harness_id,
        run_id=selected_run_id,
        upstream_root=_resolve_repo_path(root, upstream_relative),
        run_root=_resolve_repo_path(root, run_relative),
    )


def reproduction_plan(selection: Selection, *, offline: bool = False) -> dict[str, Any]:
    """Return the exact non-mutating command plan for an external harness."""

    platform_id = _platform_id()
    upstream = selection.manifest["upstream"]
    source_commands: list[list[str]] = []
    if selection.upstream_root.exists():
        source_commands.extend(
            [
                ["git", "-C", str(selection.upstream_root), "status", "--porcelain"],
                ["git", "-C", str(selection.upstream_root), "remote", "get-url", "origin"],
                ["git", "-C", str(selection.upstream_root), "rev-parse", "HEAD"],
            ]
        )
    elif not offline:
        source_commands.append(
            [
                "git",
                "clone",
                "--no-checkout",
                str(upstream["repositoryUrl"]),
                str(selection.upstream_root),
            ]
        )
    else:
        source_commands.append(["offline", "require-existing-upstream"])
    install = selection.manifest["installation"]
    reproduction = selection.manifest["reproduction"]
    values = _template_values(selection)
    workload_command = list(selection.manifest["workload"]["command"])
    workload_command.extend(
        _render_template(str(argument), values)
        for argument in reproduction["arguments"]
    )
    return {
        "schemaVersion": 1,
        "artifactKind": "external-project-reproduction-plan",
        "actorId": selection.actor_id,
        "harnessId": selection.harness_id,
        "runId": selection.run_id,
        "offline": offline,
        "upstreamRoot": _display_path(selection.root, selection.upstream_root),
        "runRoot": _display_path(selection.root, selection.run_root),
        "sourceCommands": source_commands,
        "bootstrapCommands": [
            item["command"] for item in selection.policy["bootstrapCommands"]
        ],
        "versionCommands": [item["command"] for item in selection.policy["versionCommands"]],
        "hardwareProbe": selection.policy["hardwareProbes"][platform_id]["command"]["command"],
        "installSteps": install["installSteps"],
        "doeCommands": [
            item["command"]
            for item in (
                list(selection.policy["doePreparation"]["commonCommands"])
                + list(
                    selection.policy["doePreparation"]["platformCommands"][
                        platform_id
                    ]
                )
            )
        ],
        "gateCommands": [item["command"] for item in selection.policy["gateCommands"]],
        "workloadCommand": workload_command,
        "evidenceFiles": reproduction["evidenceFiles"],
    }


def _template_values(selection: Selection) -> dict[str, str]:
    preparation_path = selection.run_root / "preparation.json"
    return {
        "actorId": selection.actor_id,
        "harnessId": selection.harness_id,
        "runId": selection.run_id,
        "runRoot": _display_path(selection.root, selection.run_root),
        "upstreamRoot": _display_path(selection.root, selection.upstream_root),
        "preparationReceipt": _display_path(selection.root, preparation_path),
    }


def _command_spec(
    process_id: str,
    command: list[str],
    working_directory: str,
    timeout_seconds: int,
) -> dict[str, Any]:
    return {
        "id": process_id,
        "command": command,
        "workingDirectory": working_directory,
        "timeoutSeconds": timeout_seconds,
    }


def _require_process(result: ProcessResult, stage: str) -> None:
    if result.receipt["exitCode"] != 0:
        detail = result.stderr.strip() or result.stdout.strip() or "no process output"
        raise ReproductionError(
            stage,
            f"{result.receipt['id']} failed with exit code "
            f"{result.receipt['exitCode']}: {detail}",
        )


def _normalized_remote(url: str) -> str:
    return url.strip().rstrip("/").removesuffix(".git")


def _ensure_upstream(
    selection: Selection,
    recorder: ProcessRecorder,
    steps: list[dict[str, Any]],
    *,
    offline: bool,
) -> tuple[str, str, bool]:
    timeout_seconds = int(selection.policy["sourceCommandTimeoutSeconds"])
    upstream = selection.manifest["upstream"]
    new_checkout = False
    if not selection.upstream_root.exists():
        if offline:
            raise ReproductionError(
                "source",
                f"offline mode requires an existing checkout: {selection.upstream_root}",
                unavailable=True,
            )
        selection.upstream_root.parent.mkdir(parents=True, exist_ok=True)
        clone = recorder.run(
            _command_spec(
                "clone-upstream",
                [
                    "git",
                    "-c",
                    "core.autocrlf=false",
                    "-c",
                    "core.fileMode=false",
                    "clone",
                    "--no-checkout",
                    str(upstream["repositoryUrl"]),
                    str(selection.upstream_root),
                ],
                ".",
                timeout_seconds,
            )
        )
        steps.append(clone.receipt)
        _require_process(clone, "source")
        new_checkout = True
    if not (selection.upstream_root / ".git").exists():
        raise ReproductionError(
            "source", f"upstream path is not a Git checkout: {selection.upstream_root}"
        )

    def git(process_id: str, *arguments: str) -> ProcessResult:
        result = recorder.run(
            _command_spec(
                process_id,
                [
                    "git",
                    "-c",
                    "core.autocrlf=false",
                    "-c",
                    "core.fileMode=false",
                    "-C",
                    str(selection.upstream_root),
                    *arguments,
                ],
                ".",
                timeout_seconds,
            )
        )
        steps.append(result.receipt)
        return result

    if not new_checkout:
        status = git(
            "verify-upstream-clean-before-checkout", "status", "--porcelain"
        )
        _require_process(status, "source")
        if status.stdout.strip():
            raise ReproductionError(
                "source",
                "upstream checkout has local changes; preserve or remove them "
                "before reproduction",
            )
    origin = git("verify-upstream-origin", "remote", "get-url", "origin")
    _require_process(origin, "source")
    actual_origin = origin.stdout.strip()
    if _normalized_remote(actual_origin) != _normalized_remote(
        str(upstream["repositoryUrl"])
    ):
        raise ReproductionError(
            "source",
            f"upstream origin mismatch: expected {upstream['repositoryUrl']}, received {actual_origin}",
        )
    requested_commit = str(upstream["commit"])
    commit_check = git(
        "verify-pinned-commit-present",
        "cat-file",
        "-e",
        f"{requested_commit}^{{commit}}",
    )
    if commit_check.receipt["exitCode"] != 0:
        if offline:
            raise ReproductionError(
                "source",
                f"pinned commit is unavailable in offline checkout: {requested_commit}",
                unavailable=True,
            )
        fetch = git("fetch-pinned-commit", "fetch", "origin", requested_commit)
        _require_process(fetch, "source")
    checkout = git("checkout-pinned-commit", "checkout", "--detach", requested_commit)
    _require_process(checkout, "source")
    head = git("verify-pinned-head", "rev-parse", "HEAD")
    _require_process(head, "source")
    actual_commit = head.stdout.strip()
    if actual_commit != requested_commit:
        raise ReproductionError(
            "source",
            f"pinned commit mismatch: expected {requested_commit}, received {actual_commit}",
        )
    final_status = git("verify-upstream-clean-after-checkout", "status", "--porcelain")
    _require_process(final_status, "source")
    clean = not final_status.stdout.strip()
    if not clean:
        raise ReproductionError("source", "upstream checkout changed during checkout")
    return actual_commit, actual_origin, clean


def _installation_root(
    selection: Selection, working: dict[str, Any]
) -> Path:
    base = selection.root if working["scope"] == "repo" else selection.upstream_root
    path = str(working["path"])
    candidate = (base / path).resolve()
    try:
        candidate.relative_to(base.resolve())
    except ValueError as exc:
        raise ReproductionError(
            "contract", f"installation path escapes {working['scope']} root: {path}"
        ) from exc
    if not candidate.is_dir():
        raise ReproductionError(
            "installation", f"installation working directory is missing: {candidate}"
        )
    return candidate


def _match_support_target(
    selection: Selection, platform_id: str, hardware_output: str
) -> dict[str, Any]:
    machine = platform.machine().lower()
    aliases = {machine}
    if machine in {"x86_64", "amd64"}:
        aliases.update({"x86_64", "amd64", "x64"})
    if machine in {"aarch64", "arm64"}:
        aliases.update({"aarch64", "arm64"})
    node_version = ""
    for target in selection.manifest.get("supportTargets", []):
        target_os = str(target.get("os", "")).lower()
        normalized_os = "darwin" if target_os in {"darwin", "macos"} else target_os
        if normalized_os != platform_id:
            continue
        if str(target.get("arch", "")).lower() not in aliases:
            continue
        runtime = str(target.get("runtime", ""))
        if runtime.startswith("node-"):
            if not node_version:
                try:
                    node_version = subprocess.run(
                        ["node", "--version"],
                        check=False,
                        capture_output=True,
                        text=True,
                        timeout=30,
                    ).stdout.strip()
                except (OSError, subprocess.SubprocessError):
                    node_version = ""
            expected_major = runtime.removeprefix("node-").split(".", 1)[0]
            if node_version.lstrip("v").split(".", 1)[0] != expected_major:
                continue
        if str(target.get("adapter", "")).lower() not in hardware_output.lower():
            continue
        if str(target.get("driver", "")).lower() not in hardware_output.lower():
            continue
        claim_eligible = target.get("status") == "promoted"
        return {
            "status": "matched",
            "targetId": target.get("id"),
            "claimEligible": claim_eligible,
        }
    return {"status": "unmatched", "targetId": None, "claimEligible": False}


def _write_receipt(
    path: Path,
    payload: dict[str, Any],
    schema_path: Path,
) -> dict[str, Any]:
    payload["receiptSha256"] = _payload_sha256(payload)
    _validate_payload(payload, schema_path, label=payload["artifactKind"])
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps(payload, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    return payload


def _preparation_base(selection: Selection) -> dict[str, Any]:
    platform_id = _platform_id()
    upstream = selection.manifest["upstream"]
    return {
        "schemaVersion": 1,
        "artifactKind": "external-project-preparation-receipt",
        "generatedAt": _utc_now(),
        "actorId": selection.actor_id,
        "harnessId": selection.harness_id,
        "runId": selection.run_id,
        "status": "failed",
        "failure": None,
        "source": {
            "repositoryUrl": upstream["repositoryUrl"],
            "requestedCommit": upstream["commit"],
            "actualCommit": None,
            "originUrl": None,
            "upstreamRoot": _display_path(selection.root, selection.upstream_root),
            "clean": None,
        },
        "contracts": [
            _artifact(selection.root, "ecosystem-registry", selection.registry_path),
            _artifact(selection.root, "harness-manifest", selection.manifest_path),
            _artifact(selection.root, "reproduction-policy", selection.policy_path),
        ],
        "host": {
            "platform": platform_id,
            "operatingSystem": platform.system(),
            "machine": platform.machine(),
            "release": platform.release(),
            "python": platform.python_version(),
        },
        "toolVersions": [],
        "hardware": {
            "status": "not-run",
            "requiredPatterns": selection.policy["hardwareProbes"][platform_id][
                "requiredPatterns"
            ],
            "prohibitedPatterns": selection.policy["hardwareProbes"][platform_id][
                "prohibitedPatterns"
            ],
            "probe": None,
        },
        "supportTarget": {
            "status": "unmatched",
            "targetId": None,
            "claimEligible": False,
        },
        "steps": [],
        "artifacts": [],
        "receiptSha256": "0" * 64,
    }


def prepare_external_project(
    selection: Selection,
    *,
    offline: bool = False,
) -> tuple[dict[str, Any], Path]:
    """Prepare upstream source and Doe, then emit a verified preparation receipt."""

    selection.run_root.mkdir(parents=True, exist_ok=True)
    receipt_path = selection.run_root / "preparation.json"
    recorder = ProcessRecorder(selection.root, selection.run_root, "preparation")
    payload = _preparation_base(selection)
    steps = payload["steps"]
    try:
        for spec in selection.policy["bootstrapCommands"]:
            result = recorder.run(spec)
            steps.append(result.receipt)
            _require_process(result, "bootstrap")

        for spec in selection.policy["versionCommands"]:
            result = recorder.run(spec)
            payload["toolVersions"].append(result.receipt)
            _require_process(result, "tool-version")

        platform_id = payload["host"]["platform"]
        hardware_policy = selection.policy["hardwareProbes"][platform_id]
        hardware_result = recorder.run(hardware_policy["command"])
        payload["hardware"]["probe"] = hardware_result.receipt
        _require_process(hardware_result, "hardware")
        hardware_output = hardware_result.stdout + "\n" + hardware_result.stderr
        missing_patterns = [
            pattern
            for pattern in hardware_policy["requiredPatterns"]
            if re.search(pattern, hardware_output, flags=re.IGNORECASE) is None
        ]
        prohibited_patterns = [
            pattern
            for pattern in hardware_policy["prohibitedPatterns"]
            if re.search(pattern, hardware_output, flags=re.IGNORECASE) is not None
        ]
        if missing_patterns or prohibited_patterns:
            payload["hardware"]["status"] = "failed"
            details = []
            if missing_patterns:
                details.append(f"missing physical evidence patterns: {missing_patterns}")
            if prohibited_patterns:
                details.append(f"prohibited fallback patterns: {prohibited_patterns}")
            raise ReproductionError(
                "hardware", "; ".join(details), unavailable=True
            )
        payload["hardware"]["status"] = "passed"
        payload["supportTarget"] = _match_support_target(
            selection, platform_id, hardware_output
        )

        actual_commit, origin_url, clean = _ensure_upstream(
            selection, recorder, steps, offline=offline
        )
        payload["source"].update(
            {
                "actualCommit": actual_commit,
                "originUrl": origin_url,
                "clean": clean,
            }
        )

        install = selection.manifest["installation"]
        for install_step in install["installSteps"]:
            install_result = recorder.run(
                _command_spec(
                    f"install-{install_step['id']}",
                    [str(item) for item in install_step["command"]],
                    ".",
                    int(install_step["timeoutSeconds"]),
                ),
                working_directory=_installation_root(
                    selection, install_step["workingDirectory"]
                ),
            )
            steps.append(install_result.receipt)
            _require_process(install_result, "installation")

        source_timeout = int(selection.policy["sourceCommandTimeoutSeconds"])
        clean_after_install = recorder.run(
            _command_spec(
                "verify-upstream-clean-after-install",
                [
                    "git",
                    "-c",
                    "core.fileMode=false",
                    "-C",
                    str(selection.upstream_root),
                    "status",
                    "--porcelain",
                ],
                ".",
                source_timeout,
            )
        )
        steps.append(clean_after_install.receipt)
        _require_process(clean_after_install, "installation")
        if clean_after_install.stdout.strip():
            raise ReproductionError(
                "installation",
                "installation modified pinned upstream source: "
                f"{clean_after_install.stdout.strip()}",
            )

        doe_policy = selection.policy["doePreparation"]
        doe_commands = list(doe_policy["commonCommands"]) + list(
            doe_policy["platformCommands"][platform_id]
        )
        for spec in doe_commands:
            result = recorder.run(spec)
            steps.append(result.receipt)
            _require_process(result, "doe-preparation")

        artifact_specs = list(doe_policy["commonArtifacts"]) + list(
            doe_policy["platformArtifacts"][platform_id]
        )
        for spec in artifact_specs:
            payload["artifacts"].append(
                _artifact(
                    selection.root,
                    str(spec["id"]),
                    _resolve_repo_path(selection.root, str(spec["path"])),
                )
            )
        provider_module_path = _resolve_repo_path(
            selection.root,
            str(selection.manifest["reproduction"]["providerModulePath"]),
        )
        if all(
            artifact["path"] != _display_path(selection.root, provider_module_path)
            for artifact in payload["artifacts"]
        ):
            payload["artifacts"].append(
                _artifact(
                    selection.root,
                    "harness-provider-module",
                    provider_module_path,
                )
            )
        payload["status"] = "passed"
    except ReproductionError as exc:
        payload["status"] = "unavailable" if exc.unavailable else "failed"
        payload["failure"] = {"stage": exc.stage, "message": str(exc)}
    payload["generatedAt"] = _utc_now()
    return (
        _write_receipt(
            receipt_path,
            payload,
            selection.root / PREPARATION_SCHEMA_PATH,
        ),
        receipt_path,
    )


def _load_preparation_receipt(
    selection: Selection, receipt_path: Path
) -> dict[str, Any]:
    payload = _load_validated(
        receipt_path,
        selection.root / PREPARATION_SCHEMA_PATH,
        label="external-project preparation receipt",
    )
    expected_hash = _payload_sha256(payload)
    if payload.get("receiptSha256") != expected_hash:
        raise ReproductionError(
            "preparation", "preparation receipt content hash does not match"
        )
    for field, expected in (
        ("actorId", selection.actor_id),
        ("harnessId", selection.harness_id),
        ("runId", selection.run_id),
    ):
        if payload.get(field) != expected:
            raise ReproductionError(
                "preparation", f"preparation receipt {field} does not match selection"
            )
    if payload.get("status") != "passed":
        raise ReproductionError(
            "preparation",
            f"preparation receipt is not passing: {payload.get('status')}",
            unavailable=payload.get("status") == "unavailable",
        )
    return payload


def _reproduction_base(
    selection: Selection,
    preparation_path: Path,
    preparation: dict[str, Any],
) -> dict[str, Any]:
    return {
        "schemaVersion": 1,
        "artifactKind": "external-project-reproduction-receipt",
        "generatedAt": _utc_now(),
        "actorId": selection.actor_id,
        "harnessId": selection.harness_id,
        "runId": selection.run_id,
        "status": "failed",
        "evidenceMaturity": "diagnostic",
        "failure": None,
        "contracts": [
            _artifact(selection.root, "ecosystem-registry", selection.registry_path),
            _artifact(selection.root, "harness-manifest", selection.manifest_path),
            _artifact(selection.root, "reproduction-policy", selection.policy_path),
        ],
        "preparation": {
            "path": _display_path(selection.root, preparation_path),
            "sha256": _sha256_file(preparation_path),
            "status": preparation["status"],
            "claimEligible": preparation["supportTarget"]["claimEligible"],
        },
        "workload": None,
        "evidence": [],
        "gates": [],
        "receiptSha256": "0" * 64,
    }


def reproduce_external_project(
    selection: Selection,
    *,
    offline: bool = False,
) -> tuple[dict[str, Any], Path]:
    """Prepare, gate, run, and evidence one external-project harness."""

    preparation, preparation_path = prepare_external_project(
        selection, offline=offline
    )
    reproduction_path = selection.run_root / "reproduction.json"
    payload = _reproduction_base(selection, preparation_path, preparation)
    recorder = ProcessRecorder(selection.root, selection.run_root, "reproduction")
    try:
        verified_preparation = _load_preparation_receipt(selection, preparation_path)
        payload["preparation"]["claimEligible"] = verified_preparation[
            "supportTarget"
        ]["claimEligible"]
        for spec in selection.policy["gateCommands"]:
            result = recorder.run(spec)
            payload["gates"].append(result.receipt)
            _require_process(result, "gate")

        values = _template_values(selection)
        command = [str(item) for item in selection.manifest["workload"]["command"]]
        command.extend(
            _render_template(str(argument), values)
            for argument in selection.manifest["reproduction"]["arguments"]
        )
        environment = os.environ.copy()
        environment["DOE_EXTERNAL_PREPARATION_RECEIPT"] = str(preparation_path)
        environment["DOE_EXTERNAL_RUN_ID"] = selection.run_id
        workload = recorder.run(
            _command_spec(
                "external-project-workload",
                command,
                ".",
                int(selection.policy["workloadCommandTimeoutSeconds"]),
            ),
            environment=environment,
        )
        payload["workload"] = workload.receipt
        _require_process(workload, "workload")

        for evidence_spec in selection.manifest["reproduction"]["evidenceFiles"]:
            evidence_path = (selection.run_root / str(evidence_spec["path"])).resolve()
            try:
                evidence_path.relative_to(selection.run_root.resolve())
            except ValueError as exc:
                raise ReproductionError(
                    "contract",
                    f"evidence path escapes run root: {evidence_spec['path']}",
                ) from exc
            payload["evidence"].append(
                _artifact(selection.root, str(evidence_spec["id"]), evidence_path)
            )
        payload["status"] = "passed"
        if payload["preparation"]["claimEligible"]:
            payload["evidenceMaturity"] = "claimable-candidate"
    except ReproductionError as exc:
        payload["status"] = "unavailable" if exc.unavailable else "failed"
        payload["failure"] = {"stage": exc.stage, "message": str(exc)}
    payload["generatedAt"] = _utc_now()
    return (
        _write_receipt(
            reproduction_path,
            payload,
            selection.root / REPRODUCTION_SCHEMA_PATH,
        ),
        reproduction_path,
    )
