#!/usr/bin/env python3
"""Run the shared execution contract through the Doe-backed JS WebGPU lane."""

from __future__ import annotations

import argparse
import hashlib
import os
import subprocess
import sys
from pathlib import Path
from typing import Any

REPO_ROOT = Path(__file__).resolve().parents[2]
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from bench.tools.run_doe_csl_int4ple_transcript import (
    load_json,
    rel,
    resolve,
    schema_failures,
    sha256_file,
    write_json,
)
DEFAULT_SCHEMA = Path("config/doe-webgpu-transcript.schema.json")
DEFAULT_CONTRACT_SCHEMA = Path("config/doe-shared-execution-contract.schema.json")
DEFAULT_EXPORT_TOOL = Path("bench/tools/export_doppler_int4ple_reference.mjs")
DEFAULT_PROVIDER = Path("packages/doe-gpu/src/compute.js")
DEFAULT_RUNTIME_PROFILE = "profiles/production"
DEFAULT_BUN_PROVIDER = Path("packages/doe-gpu/src/bun.js")


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--shared-contract",
        required=True,
        help="Shared execution contract to consume.",
    )
    parser.add_argument(
        "--doppler-root",
        required=True,
        help="Doppler checkout used by the reference exporter.",
    )
    parser.add_argument(
        "--node",
        "--js-executable",
        dest="node",
        default=None,
        help=(
            "JavaScript executable used to run the exporter. "
            "Defaults to the shared-contract Doe WebGPU runtime host."
        ),
    )
    parser.add_argument(
        "--provider-module",
        default=None,
        help=(
            "Doe-backed WebGPU provider module passed through "
            "DOPPLER_NODE_WEBGPU_MODULE. Defaults to the shared-contract provider."
        ),
    )
    parser.add_argument(
        "--kernel-path-policy-mode",
        choices=("locked", "capability-aware"),
        default=None,
        help=(
            "Doppler runtime.inference.kernelPathPolicy.mode override. "
            "Defaults to the shared-contract runtime policy."
        ),
    )
    parser.add_argument(
        "--kernel-path-policy-on-incompatible",
        choices=("error", "remap"),
        default=None,
        help=(
            "Doppler runtime.inference.kernelPathPolicy.onIncompatible override. "
            "Defaults to the shared-contract runtime policy."
        ),
    )
    parser.add_argument(
        "--kernel-path-policy-source-scope",
        default=None,
        help=(
            "Comma-separated Doppler runtime.inference.kernelPathPolicy.sourceScope. "
            "Defaults to the shared-contract runtime policy."
        ),
    )
    parser.add_argument(
        "--export-tool",
        default=str(DEFAULT_EXPORT_TOOL),
        help="Doppler reference export tool.",
    )
    parser.add_argument(
        "--export-out-dir",
        required=True,
        help="Directory where the underlying export artifacts are written.",
    )
    parser.add_argument(
        "--schema",
        default=str(DEFAULT_SCHEMA),
        help="Output receipt schema.",
    )
    parser.add_argument(
        "--contract-schema",
        default=str(DEFAULT_CONTRACT_SCHEMA),
        help="Input contract schema.",
    )
    parser.add_argument(
        "--out",
        required=True,
        help="Output Doe WebGPU transcript receipt.",
    )
    return parser.parse_args(argv)


def hash_link(path: Path, source: str | None = None) -> dict[str, Any]:
    link: dict[str, Any] = {
        "path": rel(path),
        "sha256": sha256_file(path),
    }
    if source is not None:
        link["source"] = source
    return link


def pending_link(path_text: str, source: str) -> dict[str, Any]:
    return {
        "path": path_text,
        "sha256": "pending",
        "source": source,
    }


def fallback_source_program(contract: dict[str, Any]) -> dict[str, Any]:
    source = contract.get("sourceProgram")
    if isinstance(source, dict) and source:
        return source
    return {
        "authoringSurface": "doppler_execution_v1",
        "manifestPath": "pending",
        "manifestSha256": "pending",
        "graphPath": "pending",
        "graphSha256": "pending",
        "weightSetId": "pending",
        "weightSha256": "pending",
        "inputSetSha256": "pending",
        "executionDepth": "not_executed",
    }


def fallback_decode_request(contract: dict[str, Any]) -> dict[str, Any]:
    decode = contract.get("decodeRequest")
    if isinstance(decode, dict) and decode:
        return decode
    return {
        "requestedDecodeSteps": 0,
        "expectedActualDecodeSteps": 0,
        "expectedStopReason": "pending",
        "samplingSha256": "pending",
        "inputSetSha256": "pending",
        "sampling": {},
    }


def prompt_text(contract: dict[str, Any]) -> str:
    prompt = (contract.get("promptInput") or {}).get("prompt") or {}
    prompt_path = prompt.get("path")
    if not isinstance(prompt_path, str) or not prompt_path:
        raise ValueError("shared contract is missing promptInput.prompt.path")
    path = resolve(prompt_path)
    if not path.is_file():
        raise FileNotFoundError(f"prompt file missing: {path}")
    return path.read_text(encoding="utf-8")


def default_provider_module_for_host(host: str) -> Path:
    return DEFAULT_BUN_PROVIDER if host == "bun" else DEFAULT_PROVIDER


def normalize_source_scope(value: Any) -> str:
    if isinstance(value, str) and value.strip():
        return value
    if isinstance(value, list):
        entries = [str(entry).strip() for entry in value if str(entry).strip()]
        if entries:
            return ",".join(entries)
    return "model,manifest,config"


def resolve_runtime_settings(
    *,
    args: argparse.Namespace,
    contract: dict[str, Any],
) -> dict[str, str]:
    runtime = contract.get("doeWebgpuRuntime")
    if not isinstance(runtime, dict):
        runtime = {}
    kernel_policy = runtime.get("kernelPathPolicy")
    if not isinstance(kernel_policy, dict):
        kernel_policy = {}
    host = runtime.get("host")
    if not isinstance(host, str) or host not in {"node", "bun"}:
        requested_executable = args.node or runtime.get("hostExecutable")
        host = "bun" if Path(str(requested_executable or "node")).name == "bun" else "node"
    js_executable = args.node or runtime.get("hostExecutable") or host
    provider_module = (
        args.provider_module
        or runtime.get("providerModule")
        or str(default_provider_module_for_host(host))
    )
    runtime_profile = runtime.get("runtimeProfile")
    if not isinstance(runtime_profile, str) or not runtime_profile:
        runtime_profile = DEFAULT_RUNTIME_PROFILE
    settings = {
        "host": host,
        "jsExecutable": str(js_executable),
        "providerModule": str(provider_module),
        "runtimeProfile": runtime_profile,
        "kernelPathPolicyMode": (
            args.kernel_path_policy_mode
            or kernel_policy.get("mode")
            or "capability-aware"
        ),
        "kernelPathPolicyOnIncompatible": (
            args.kernel_path_policy_on_incompatible
            or kernel_policy.get("onIncompatible")
            or "remap"
        ),
        "kernelPathPolicySourceScope": (
            args.kernel_path_policy_source_scope
            or normalize_source_scope(
                kernel_policy.get("sourceScope") or kernel_policy.get("allowSources")
            )
        ),
    }
    return settings


def export_command(
    *,
    args: argparse.Namespace,
    contract: dict[str, Any],
    export_out_dir: Path,
    runtime: dict[str, str] | None = None,
) -> list[str]:
    runtime = runtime or resolve_runtime_settings(args=args, contract=contract)
    source = contract.get("sourceProgram") or {}
    decode = contract.get("decodeRequest") or {}
    prompt = prompt_text(contract)
    manifest_path = resolve(source["manifestPath"])
    command = [
        runtime["jsExecutable"],
        str(resolve(args.export_tool)),
        "--doppler-root",
        str(resolve(args.doppler_root)),
        "--model-dir",
        str(manifest_path.parent),
        "--model-id",
        contract["modelId"],
        "--prompt",
        prompt,
        "--runtime-profile",
        runtime["runtimeProfile"],
        "--out-dir",
        rel(export_out_dir),
        "--decode-steps",
        str(int(decode.get("requestedDecodeSteps") or 0)),
        "--kernel-path-policy-mode",
        runtime["kernelPathPolicyMode"],
        "--kernel-path-policy-on-incompatible",
        runtime["kernelPathPolicyOnIncompatible"],
        "--kernel-path-policy-source-scope",
        runtime["kernelPathPolicySourceScope"],
    ]
    sampling = decode.get("sampling") or {}
    temperature = sampling.get("temperature")
    if isinstance(temperature, (int, float)) and not isinstance(temperature, bool):
        command.extend(["--temperature", str(temperature)])
    top_k = sampling.get("topK")
    if isinstance(top_k, int) and not isinstance(top_k, bool):
        command.extend(["--top-k", str(top_k)])
    top_p = sampling.get("topP")
    if isinstance(top_p, (int, float)) and not isinstance(top_p, bool):
        command.extend(["--top-p", str(top_p)])
    repetition_penalty = sampling.get("repetitionPenalty")
    if isinstance(repetition_penalty, (int, float)) and not isinstance(
        repetition_penalty,
        bool,
    ):
        command.extend(["--repetition-penalty", str(repetition_penalty)])
    seed = sampling.get("seed")
    if isinstance(seed, int) and not isinstance(seed, bool):
        command.extend(["--seed", str(seed)])
    use_chat_template = (contract.get("promptInput") or {}).get(
        "inputSetComponents",
        {},
    ).get("useChatTemplate")
    if use_chat_template is False:
        command.append("--no-chat-template")
    return command


def kv_cache_evidence(exporter_receipt: dict[str, Any]) -> dict[str, Any]:
    evidence = exporter_receipt.get("kvCacheEvidence")
    if isinstance(evidence, dict):
        if (
            evidence.get("status") == "output_ready"
            and evidence.get("realKvCache") is True
            and kv_evidence_has_nonzero_bytes(evidence)
        ):
            return evidence
        preserved = dict(evidence)
        preserved["status"] = "not_captured"
        preserved["realKvCache"] = False
        preserved["blocker"] = preserved.get("blocker") or (
            "KV/cache byte proof contains only zero key/value buffers; "
            "cache writes were not proven."
        )
        return preserved
    return {
        "status": "not_captured",
        "realKvCache": False,
        "blocker": (
            "Doe WebGPU exporter did not emit KV/cache byte-digest evidence "
            "for the shared execution contract."
        ),
    }


def positive_int(value: Any) -> int:
    if isinstance(value, bool):
        return 0
    try:
        parsed = int(value)
    except (TypeError, ValueError):
        return 0
    return parsed if parsed > 0 else 0


def normalize_digest(value: Any) -> str:
    text = str(value or "")
    return text[7:] if text.startswith("sha256:") else text


def zero_digest(byte_length: int) -> str:
    return hashlib.sha256(bytes(byte_length)).hexdigest()


def digest_proves_nonzero(digest: Any, byte_length: Any) -> bool:
    size = positive_int(byte_length)
    if size == 0:
        return False
    text = normalize_digest(digest)
    return bool(text) and text != "pending" and text != zero_digest(size)


def kv_evidence_has_nonzero_bytes(evidence: dict[str, Any]) -> bool:
    byte_digests = evidence.get("byteDigests")
    if not isinstance(byte_digests, list):
        return False
    for layer in byte_digests:
        if not isinstance(layer, dict):
            continue
        if digest_proves_nonzero(layer.get("keyDigest"), layer.get("keyBytes")):
            return True
        if digest_proves_nonzero(layer.get("valueDigest"), layer.get("valueBytes")):
            return True
    return False


def failed_receipt(
    *,
    contract: dict[str, Any],
    contract_path: Path,
    out_path: Path,
    args: argparse.Namespace,
    status: str,
    blocker: str,
    runtime: dict[str, str] | None = None,
) -> dict[str, Any]:
    runtime = runtime or resolve_runtime_settings(args=args, contract=contract)
    log_dir = out_path.parent
    stdout_log = log_dir / "doe-webgpu-export.stdout.log"
    stderr_log = log_dir / "doe-webgpu-export.stderr.log"
    for path in (stdout_log, stderr_log):
        if not path.exists():
            path.write_text("", encoding="utf-8")
    return {
        "schemaVersion": 1,
        "artifactKind": "doe_webgpu_transcript",
        "status": status,
        "modelId": contract.get("modelId", "pending"),
        "sourceProgram": fallback_source_program(contract),
        "sharedExecutionContract": (
            hash_link(contract_path, "doe_shared_execution_contract")
            if contract_path.is_file()
            else pending_link(str(contract_path), "doe_shared_execution_contract")
        ),
        "decodeRequest": fallback_decode_request(contract),
        "webgpuTranscript": {
            "status": "not_run",
            "producer": "not_run",
            "exporterReceipt": {
                "path": "pending",
                "sha256": "pending",
                "source": "doppler_reference_export",
            },
            "tensorDigest": {
                "status": "pending",
                "path": "pending",
                "sha256": "pending",
            },
        },
        "kvCacheEvidence": {
            "status": "not_captured",
            "realKvCache": False,
            "blocker": blocker,
        },
        "runtimeRun": {
            "runner": rel(Path(__file__)),
            "jsHost": runtime["host"],
            "jsExecutable": runtime["jsExecutable"],
            "providerModule": rel(resolve(runtime["providerModule"])),
            "exportTool": rel(resolve(args.export_tool)),
            "exporterCommand": [],
            "exitCode": 1,
            "stdoutLog": hash_link(stdout_log, "doe_webgpu_export_stdout"),
            "stderrLog": hash_link(stderr_log, "doe_webgpu_export_stderr"),
        },
        "inputsSynthetic": False,
        "weightsSynthetic": False,
        "blocker": blocker,
    }


def build_receipt(
    *,
    contract: dict[str, Any],
    contract_path: Path,
    exporter_receipt: dict[str, Any],
    exporter_receipt_path: Path,
    args: argparse.Namespace,
    command: list[str],
    exit_code: int,
    stdout_log: Path,
    stderr_log: Path,
    runtime: dict[str, str] | None = None,
) -> dict[str, Any]:
    runtime = runtime or resolve_runtime_settings(args=args, contract=contract)
    producer = exporter_receipt.get("producer") or {}
    return {
        "schemaVersion": 1,
        "artifactKind": "doe_webgpu_transcript",
        "status": "output_ready"
        if exporter_receipt.get("exportStatus") == "output_ready"
        else "failed",
        "modelId": contract["modelId"],
        "sourceProgram": contract["sourceProgram"],
        "sharedExecutionContract": hash_link(
            contract_path,
            "doe_shared_execution_contract",
        ),
        "decodeRequest": contract["decodeRequest"],
        "webgpuTranscript": {
            "status": (exporter_receipt.get("decodeTranscript") or {}).get(
                "status",
                exporter_receipt.get("exportStatus", "unknown"),
            ),
            "producer": "doppler_js_webgpu_on_doe",
            "exporterReceipt": hash_link(
                exporter_receipt_path,
                "doppler_reference_export",
            ),
            "tensorDigest": exporter_receipt.get("tensorDigest") or {},
            "decodeTranscript": exporter_receipt.get("decodeTranscript") or {},
        },
        "kvCacheEvidence": kv_cache_evidence(exporter_receipt),
        "runtimeRun": {
            "runner": rel(Path(__file__)),
            "jsHost": runtime["host"],
            "jsExecutable": runtime["jsExecutable"],
            "providerModule": rel(resolve(runtime["providerModule"])),
            "exportTool": rel(resolve(args.export_tool)),
            "exporterCommand": command,
            "exitCode": exit_code,
            "stdoutLog": hash_link(stdout_log, "doe_webgpu_export_stdout"),
            "stderrLog": hash_link(stderr_log, "doe_webgpu_export_stderr"),
            "observedProvider": producer.get("webgpuProvider", "pending"),
        },
        "inputsSynthetic": False,
        "weightsSynthetic": False,
        "blocker": "",
    }


def main() -> int:
    args = parse_args()
    out_path = resolve(args.out)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    contract_path = resolve(args.shared_contract)
    if not contract_path.is_file():
        receipt = failed_receipt(
            contract={"modelId": "pending", "sourceProgram": {}, "decodeRequest": {}},
            contract_path=contract_path,
            out_path=out_path,
            args=args,
            status="blocked_missing_contract",
            blocker=f"shared execution contract not found: {contract_path}",
        )
        write_json(out_path, receipt)
        return 1
    contract = load_json(contract_path)
    contract_schema = load_json(resolve(args.contract_schema))
    contract_failures = schema_failures(contract, contract_schema)
    if contract_failures:
        raise ValueError(
            "shared execution contract schema validation failed: "
            + "; ".join(contract_failures[:4])
        )
    runtime = resolve_runtime_settings(args=args, contract=contract)
    provider_module = resolve(runtime["providerModule"])
    if not provider_module.is_file():
        receipt = failed_receipt(
            contract=contract,
            contract_path=contract_path,
            out_path=out_path,
            args=args,
            status="blocked_missing_provider",
            blocker=f"provider module missing: {provider_module}",
            runtime=runtime,
        )
        write_json(out_path, receipt)
        return 1

    export_out_dir = resolve(args.export_out_dir)
    export_out_dir.mkdir(parents=True, exist_ok=True)
    command = export_command(
        args=args,
        contract=contract,
        export_out_dir=export_out_dir,
        runtime=runtime,
    )
    stdout_log = out_path.parent / "doe-webgpu-export.stdout.log"
    stderr_log = out_path.parent / "doe-webgpu-export.stderr.log"
    env = dict(os.environ)
    env["DOPPLER_NODE_WEBGPU_MODULE"] = str(provider_module)
    proc = subprocess.run(
        command,
        cwd=REPO_ROOT,
        capture_output=True,
        text=True,
        check=False,
        env=env,
    )
    stdout_log.write_text(proc.stdout, encoding="utf-8")
    stderr_log.write_text(proc.stderr, encoding="utf-8")
    exporter_receipt_path = export_out_dir / "doppler_int4ple_reference_export.json"
    if proc.returncode != 0 or not exporter_receipt_path.is_file():
        receipt = failed_receipt(
            contract=contract,
            contract_path=contract_path,
            out_path=out_path,
            args=args,
            status="failed",
            blocker=(
                f"Doe WebGPU exporter failed with exit code {proc.returncode}"
                if proc.returncode != 0
                else "Doe WebGPU exporter did not write the export receipt"
            ),
            runtime=runtime,
        )
        receipt["runtimeRun"]["exporterCommand"] = command
        receipt["runtimeRun"]["exitCode"] = proc.returncode
        write_json(out_path, receipt)
        return 1

    exporter_receipt = load_json(exporter_receipt_path)
    receipt = build_receipt(
        contract=contract,
        contract_path=contract_path,
        exporter_receipt=exporter_receipt,
        exporter_receipt_path=exporter_receipt_path,
        args=args,
        command=command,
        exit_code=proc.returncode,
        stdout_log=stdout_log,
        stderr_log=stderr_log,
        runtime=runtime,
    )
    schema = load_json(resolve(args.schema))
    failures = schema_failures(receipt, schema)
    if failures:
        raise ValueError(
            "Doe WebGPU transcript schema validation failed: "
            + "; ".join(failures[:4])
        )
    write_json(out_path, receipt)
    return 0 if receipt["status"] == "output_ready" else 1


if __name__ == "__main__":
    raise SystemExit(main())
