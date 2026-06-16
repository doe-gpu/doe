#!/usr/bin/env python3
"""Build developer-visible fallback explanations from browser artifacts."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any


REPO_ROOT = Path(__file__).resolve().parents[3]
DEFAULT_TAXONOMY_PATH = "config/browser-unsupported-reason-taxonomy.json"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--report", required=True, help="Playwright smoke report JSON path.")
    parser.add_argument("--out", help="Write browser_fallback_explanations JSON to this path.")
    parser.add_argument("--mode", default="doe", choices=("dawn", "doe"), help="Mode result to extract.")
    parser.add_argument("--explanation-set-id", default="browser-fallback-smoke")
    parser.add_argument(
        "--taxonomy",
        default=DEFAULT_TAXONOMY_PATH,
        help="Browser unsupported/fallback reason taxonomy path.",
    )
    parser.add_argument("--canvas-webgpu-fusion", default="")
    parser.add_argument("--media-path-probe", default="")
    parser.add_argument("--gpu-scheduler", default="")
    parser.add_argument("--webgpu-effect-experiment", default="")
    parser.add_argument("--local-ai-workloads", default="")
    parser.add_argument("--pipeline-cache-receipts", default="")
    parser.add_argument("--shader-links", default="")
    return parser.parse_args()


def load_json(path: Path) -> dict[str, Any]:
    payload = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(payload, dict):
        raise ValueError(f"expected JSON object: {path}")
    return payload


def maybe_load_json(path_text: str) -> dict[str, Any] | None:
    if not path_text:
        return None
    path = Path(path_text)
    if not path.exists():
        return None
    return load_json(path)


def repo_relative(path: Path | str) -> str:
    resolved = Path(path).resolve()
    try:
        return str(resolved.relative_to(REPO_ROOT))
    except ValueError:
        return str(path)


def repo_path(path_text: str) -> Path:
    path = Path(path_text)
    if path.is_absolute():
        return path
    return REPO_ROOT / path


def load_browser_reason_taxonomy(path_text: str) -> dict[str, Any]:
    return load_json(repo_path(path_text))


def attach_evidence_blocker_codes(artifact: dict[str, Any], taxonomy: dict[str, Any]) -> dict[str, Any]:
    evidence_blocker_map = taxonomy.get("evidenceBlockerMap", {})
    if not isinstance(evidence_blocker_map, dict):
        evidence_blocker_map = {}
    evidence_blocker_taxonomy_path = taxonomy.get("evidenceBlockerTaxonomyPath")
    artifact["evidenceBlockerTaxonomyPath"] = (
        str(evidence_blocker_taxonomy_path)
        if isinstance(evidence_blocker_taxonomy_path, str) and evidence_blocker_taxonomy_path
        else "config/evidence-blocker-taxonomy.json"
    )
    for row in artifact.get("explanations", []):
        if not isinstance(row, dict):
            continue
        reason_code = row.get("reasonCode")
        blocker_code = evidence_blocker_map.get(reason_code)
        row["evidenceBlockerCode"] = str(blocker_code) if isinstance(blocker_code, str) else "runtime_incomplete"
    return artifact


def find_mode_result(report: dict[str, Any], mode: str) -> dict[str, Any]:
    for result in report.get("modeResults", []):
        if isinstance(result, dict) and result.get("mode") == mode:
            return result
    raise ValueError(f"mode result not found in smoke report: {mode}")


def selected_runtime(mode_result: dict[str, Any]) -> str:
    runtime_selection = mode_result.get("runtimeSelection")
    if isinstance(runtime_selection, dict):
        selected = runtime_selection.get("selectedRuntime")
        if selected in {"dawn", "doe", "auto"}:
            return str(selected)
    mode = mode_result.get("mode")
    if mode in {"dawn", "doe", "auto"}:
        return str(mode)
    return "unknown"


def runtime_fallback(mode_result: dict[str, Any]) -> bool:
    runtime_selection = mode_result.get("runtimeSelection")
    if isinstance(runtime_selection, dict):
        return runtime_selection.get("fallbackApplied") is True
    return False


def explanation(
    explanation_id: str,
    capability: str,
    surface: str,
    status: str,
    reason_code: str,
    fallback_applied: bool,
    developer_action: str,
    evidence_path: str,
) -> dict[str, Any]:
    return {
        "explanationId": explanation_id,
        "capability": capability,
        "surface": surface,
        "status": status,
        "reasonCode": reason_code,
        "fallbackApplied": fallback_applied,
        "hiddenFallbackAllowed": False,
        "developerAction": developer_action,
        "evidencePath": evidence_path,
    }


def runtime_explanation(mode_result: dict[str, Any], report_ref: str, mode: str) -> dict[str, Any]:
    runtime_selection = mode_result.get("runtimeSelection")
    hidden_allowed = isinstance(runtime_selection, dict) and runtime_selection.get("hiddenFallbackAllowed") is True
    fallback_applied = runtime_fallback(mode_result)
    if hidden_allowed:
        status = "blocked"
        reason_code = "hidden_fallback_allowed"
    elif fallback_applied:
        status = "fallback"
        reason_code = str(runtime_selection.get("fallbackReasonCode") or "fallback_applied") if isinstance(runtime_selection, dict) else "fallback_applied"
    elif mode_result.get("webgpuAvailable") is False or mode_result.get("adapterAvailable") is False:
        status = "blocked"
        reason_code = "webgpu_runtime_unavailable"
    else:
        status = "supported"
        reason_code = "runtime_available"
    return explanation(
        "fallback:webgpu-runtime",
        "webgpu_runtime",
        "navigator.gpu",
        status,
        reason_code,
        fallback_applied,
        "attach the runtimeSelection block from the browser smoke report",
        f"{report_ref}#modeResults[{mode}].runtimeSelection",
    )


def artifact_missing(capability: str, surface: str, flag: str, report_ref: str) -> dict[str, Any]:
    return explanation(
        f"fallback:{capability.replace('_', '-')}",
        capability,
        surface,
        "unsupported",
        f"{capability}_artifact_missing",
        False,
        f"run browser smoke with {flag}",
        report_ref,
    )


def canvas_fusion_explanation(path_text: str, report_ref: str) -> dict[str, Any]:
    payload = maybe_load_json(path_text)
    if payload is None:
        return artifact_missing("canvas_fusion", "GPUCanvasContext", "--canvas-webgpu-fusion-out", report_ref)
    fallback_reasons = payload.get("fallbackReasons", [])
    supported = payload.get("artifactKind") == "browser_canvas_webgpu_fusion_probe" and not fallback_reasons
    return explanation(
        "fallback:canvas-fusion",
        "canvas_fusion",
        "GPUCanvasContext",
        "supported" if supported else "unsupported",
        "canvas_fusion_probe_attached" if supported else "canvas_fusion_fallback_reasons_present",
        False,
        "inspect the canvas/WebGPU fusion probe fallbackReasons",
        repo_relative(path_text),
    )


def media_path_explanation(path_text: str, report_ref: str) -> dict[str, Any]:
    payload = maybe_load_json(path_text)
    if payload is None:
        return artifact_missing("external_texture", "GPUExternalTexture", "--media-path-probe-out", report_ref)
    probes = {
        probe.get("probeKind"): probe
        for probe in payload.get("probes", [])
        if isinstance(probe, dict)
    }
    required = ("gpu_external_texture", "copy_external_image_to_texture")
    supported = payload.get("artifactKind") == "browser_media_path_probe" and all(
        probes.get(kind, {}).get("status") == "pass" for kind in required
    )
    return explanation(
        "fallback:external-texture",
        "external_texture",
        "GPUExternalTexture",
        "supported" if supported else "unsupported",
        "media_path_probe_attached" if supported else "media_path_probe_incomplete",
        False,
        "inspect media path probe rows for unsupported reason codes",
        repo_relative(path_text),
    )


def scheduler_explanation(path_text: str, report_ref: str) -> dict[str, Any]:
    payload = maybe_load_json(path_text)
    if payload is None:
        return artifact_missing("scheduler", "browser GPU scheduler", "--gpu-scheduler-out", report_ref)
    probes = {
        probe.get("probeKind"): probe
        for probe in payload.get("probes", [])
        if isinstance(probe, dict)
    }
    fallback_probe = probes.get("fallback_behavior", {})
    supported = payload.get("artifactKind") == "browser_gpu_scheduler_probe" and fallback_probe.get("status") == "pass"
    return explanation(
        "fallback:scheduler",
        "scheduler",
        "browser GPU scheduler",
        "supported" if supported else "blocked",
        "scheduler_probe_attached" if supported else str(fallback_probe.get("reasonCode") or "scheduler_probe_incomplete"),
        False,
        "inspect scheduler probe rows for diagnostic scheduler coverage",
        repo_relative(path_text),
    )


def webgpu_effect_explanation(path_text: str, report_ref: str) -> dict[str, Any]:
    payload = maybe_load_json(path_text)
    if payload is None:
        return artifact_missing("webgpu_effect", "WebGPU-backed visual effect", "--webgpu-effect-experiment-out", report_ref)
    probes = {
        probe.get("probeKind"): probe
        for probe in payload.get("probes", [])
        if isinstance(probe, dict)
    }
    supported = (
        payload.get("artifactKind") == "browser_webgpu_effect_experiment"
        and probes.get("output_hash", {}).get("status") == "pass"
        and probes.get("fallback_behavior", {}).get("status") == "pass"
    )
    return explanation(
        "fallback:webgpu-effect",
        "webgpu_effect",
        "WebGPU-backed visual effect",
        "supported" if supported else "blocked",
        "webgpu_effect_probe_attached" if supported else "webgpu_effect_probe_incomplete",
        False,
        "inspect WebGPU effect experiment output and fallback probes",
        repo_relative(path_text),
    )


def local_ai_explanation(path_text: str, report_ref: str) -> dict[str, Any]:
    payload = maybe_load_json(path_text)
    if payload is None:
        return artifact_missing("local_ai", "browser local AI workload set", "--local-ai-workloads-out", report_ref)
    workloads = [row for row in payload.get("workloads", []) if isinstance(row, dict)]
    fallback_rows = [
        row for row in workloads
        if row.get("fallbackStatus", {}).get("fallbackApplied") is True
    ]
    supported = payload.get("artifactKind") == "browser_local_ai_workloads" and workloads and not fallback_rows
    return explanation(
        "fallback:local-ai",
        "local_ai",
        "browser local AI workload set",
        "supported" if supported else "fallback",
        "local_ai_workloads_attached" if supported else "local_ai_workload_fallback_applied",
        bool(fallback_rows),
        "inspect local AI workload fallbackStatus rows",
        repo_relative(path_text),
    )


def pipeline_cache_explanation(path_text: str, report_ref: str) -> dict[str, Any]:
    payload = maybe_load_json(path_text)
    if payload is None:
        return artifact_missing("pipeline_cache", "browser pipeline cache", "--pipeline-cache-receipts-out", report_ref)
    supported = payload.get("artifactKind") == "browser_pipeline_cache_receipts" and payload.get("receiptStatus") == "pass"
    return explanation(
        "fallback:pipeline-cache",
        "pipeline_cache",
        "browser pipeline cache",
        "supported" if supported else "blocked",
        "pipeline_cache_receipts_attached" if supported else "pipeline_cache_receipts_failed",
        False,
        "inspect pipeline cache receipt failureCodes",
        repo_relative(path_text),
    )


def shader_link_explanation(path_text: str, report_ref: str) -> dict[str, Any]:
    payload = maybe_load_json(path_text)
    if payload is None:
        return artifact_missing("shader_link", "developer shader links", "--shader-links-out", report_ref)
    supported = payload.get("artifactKind") == "browser_shader_links" and payload.get("linkStatus") == "pass"
    return explanation(
        "fallback:shader-link",
        "shader_link",
        "developer shader links",
        "supported" if supported else "blocked",
        "shader_links_attached" if supported else "shader_links_failed",
        False,
        "inspect shader link failureCodes",
        repo_relative(path_text),
    )


def build_explanations(
    report: dict[str, Any],
    report_path: Path,
    args: argparse.Namespace,
) -> dict[str, Any]:
    mode_result = find_mode_result(report, args.mode)
    report_ref = repo_relative(report_path)
    artifact = {
        "schemaVersion": 1,
        "artifactKind": "browser_fallback_explanations",
        "explanationSetId": args.explanation_set_id,
        "taxonomyPath": repo_relative(args.taxonomy),
        "runtimeIdentity": {
            "runtimeIdentityPath": report_ref,
            "selectedRuntime": selected_runtime(mode_result),
            "fallbackApplied": runtime_fallback(mode_result),
        },
        "explanations": [
            runtime_explanation(mode_result, report_ref, args.mode),
            canvas_fusion_explanation(args.canvas_webgpu_fusion, report_ref),
            media_path_explanation(args.media_path_probe, report_ref),
            scheduler_explanation(args.gpu_scheduler, report_ref),
            webgpu_effect_explanation(args.webgpu_effect_experiment, report_ref),
            local_ai_explanation(args.local_ai_workloads, report_ref),
            pipeline_cache_explanation(args.pipeline_cache_receipts, report_ref),
            shader_link_explanation(args.shader_links, report_ref),
        ],
        "privacy": {
            "originScoped": True,
            "rawPageDataIncluded": False,
        },
    }
    return attach_evidence_blocker_codes(artifact, load_browser_reason_taxonomy(args.taxonomy))


def main() -> int:
    args = parse_args()
    report_path = Path(args.report)
    artifact = build_explanations(load_json(report_path), report_path, args)
    encoded = json.dumps(artifact, indent=2)
    if args.out:
        out_path = Path(args.out)
        out_path.parent.mkdir(parents=True, exist_ok=True)
        out_path.write_text(encoded + "\n", encoding="utf-8")
    else:
        print(encoded)
    return 0


if __name__ == "__main__":
    sys.exit(main())
