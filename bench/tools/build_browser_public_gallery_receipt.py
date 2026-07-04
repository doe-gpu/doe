#!/usr/bin/env python3
"""Build browser public gallery receipts from hosted page bytes."""

from __future__ import annotations

import argparse
from dataclasses import dataclass
from datetime import datetime, timezone
import hashlib
import html
import json
import sys
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any

try:
    from bench.tools._public_url import is_public_https_url
except ModuleNotFoundError:
    from _public_url import is_public_https_url


REPO_ROOT = Path(__file__).resolve().parents[2]
GALLERY_CATEGORIES = (
    "compute",
    "rendering",
    "tensor",
    "shader_edge",
    "benchmark_trace",
)
REQUIRED_DRIVER_FIELDS = ("vendor", "api", "driver", "deviceFamily")
REQUIRED_TIMING_PHASES = ("setupNs", "encodeNs", "submitWaitNs")


@dataclass(frozen=True)
class DownloadResult:
    status_code: int
    content: bytes


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--url", required=True)
    parser.add_argument("--receipt-id", required=True)
    parser.add_argument("--category", choices=GALLERY_CATEGORIES, required=True)
    parser.add_argument("--gallery-artifact", default="")
    parser.add_argument("--gallery-artifact-path", default="")
    parser.add_argument("--workload-contract-path", required=True)
    parser.add_argument(
        "--receipt-payload",
        action="append",
        dest="receipt_payloads",
        required=True,
        help="Execution receipt payload linked by the hosted gallery page.",
    )
    parser.add_argument("--workload-id", action="append", dest="workload_ids", default=[])
    parser.add_argument("--observed-at", default="")
    parser.add_argument("--out", required=True)
    return parser.parse_args()


def repo_relative(path: Path) -> str:
    resolved = path.resolve()
    try:
        return str(resolved.relative_to(REPO_ROOT))
    except ValueError:
        return str(path)


def sha256_bytes(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def sha256_file(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def observed_at_now() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def fetch_url(url: str) -> DownloadResult:
    request = urllib.request.Request(
        url,
        method="GET",
        headers={"User-Agent": "DoeBrowserPublicGalleryReceipt/1"},
    )
    try:
        with urllib.request.urlopen(request) as response:
            return DownloadResult(
                status_code=int(response.getcode()),
                content=response.read(),
            )
    except urllib.error.HTTPError as exc:
        return DownloadResult(status_code=int(exc.code), content=exc.read())


def validate_expected_artifact(download: DownloadResult, expected_artifact: Path | None) -> None:
    if expected_artifact is None:
        return
    if not expected_artifact.is_file():
        raise FileNotFoundError(f"gallery artifact must be an existing file: {expected_artifact}")
    expected_hash = sha256_file(expected_artifact)
    actual_hash = sha256_bytes(download.content)
    if actual_hash != expected_hash:
        raise ValueError(
            f"hosted gallery sha256 {actual_hash} does not match {expected_artifact}"
        )
    expected_size = expected_artifact.stat().st_size
    actual_size = len(download.content)
    if actual_size != expected_size:
        raise ValueError(
            f"hosted gallery byte length {actual_size} does not match {expected_artifact}"
        )


def require_non_empty(value: str, label: str) -> None:
    if not isinstance(value, str) or not value:
        raise ValueError(f"{label} is required")


def validate_workload_ids(workload_ids: list[str]) -> list[str]:
    if not isinstance(workload_ids, list) or not workload_ids:
        raise ValueError("at least one workload ID is required")
    normalized: list[str] = []
    seen: set[str] = set()
    for index, workload_id in enumerate(workload_ids):
        if not isinstance(workload_id, str) or not workload_id:
            raise ValueError(f"workload ID {index} must be a non-empty string")
        if workload_id in seen:
            continue
        seen.add(workload_id)
        normalized.append(workload_id)
    return normalized


def validate_string_list(values: list[str], label: str) -> list[str]:
    if not isinstance(values, list) or not values:
        raise ValueError(f"at least one {label} is required")
    normalized: list[str] = []
    seen: set[str] = set()
    for index, value in enumerate(values):
        if not isinstance(value, str) or not value:
            raise ValueError(f"{label} {index} must be a non-empty string")
        if value in seen:
            continue
        seen.add(value)
        normalized.append(value)
    return normalized


def nonnegative_int(value: Any) -> bool:
    return isinstance(value, int) and not isinstance(value, bool) and value >= 0


def visible_fragment_present(text: str, fragment: str) -> bool:
    escaped = html.escape(fragment, quote=False)
    return fragment in text or escaped in text


def receipt_visibility_fragments(payload: dict[str, Any]) -> list[tuple[str, str]]:
    fragments: list[tuple[str, str]] = []
    for field in ("receiptId", "workloadId", "backend"):
        value = payload.get(field)
        if isinstance(value, str) and value:
            fragments.append((field, value))
    source_shader = payload.get("sourceShader")
    if isinstance(source_shader, dict):
        for field in ("language", "entryPoint", "source", "sha256", "sourceSha256"):
            value = source_shader.get(field)
            if isinstance(value, str) and value:
                fragments.append((f"sourceShader.{field}", value))
    lowering_path = payload.get("loweringPath")
    if isinstance(lowering_path, list) and all(isinstance(item, str) and item for item in lowering_path):
        fragments.append(("loweringPath", " > ".join(lowering_path)))
    driver = payload.get("driver")
    if isinstance(driver, dict):
        for field in (*REQUIRED_DRIVER_FIELDS, "profileId"):
            value = driver.get(field)
            if isinstance(value, str) and value:
                fragments.append((f"driver.{field}", value))
    device = payload.get("device")
    if isinstance(device, dict):
        for field in ("adapter", "adapterInfoSha256"):
            value = device.get(field)
            if isinstance(value, str) and value:
                fragments.append((f"device.{field}", value))
        feature_count = device.get("featureCount")
        if nonnegative_int(feature_count):
            fragments.append(("device.featureCount", f"featureCount={feature_count}"))
    for field in ("outputHash", "frameHash"):
        value = payload.get(field)
        if isinstance(value, str) and value:
            fragments.append((field, value))
    timing = payload.get("timing")
    if isinstance(timing, dict):
        timing_class = timing.get("timingClass")
        if isinstance(timing_class, str) and timing_class:
            fragments.append(("timing.timingClass", timing_class))
        phases = timing.get("phases")
        if isinstance(phases, dict):
            for field in REQUIRED_TIMING_PHASES:
                value = phases.get(field)
                if nonnegative_int(value):
                    fragments.append((f"timing.phases.{field}", f"{field}={value}"))
    return fragments


def validate_visible_gallery_content(
    *,
    content: bytes,
    category: str,
    workload_contract_path: str,
    workload_ids: list[str],
    receipt_ids: list[str],
    receipt_artifact_paths: list[str],
    receipt_visible_fragments: list[tuple[str, str]],
) -> None:
    try:
        text = content.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise ValueError("public gallery content must be UTF-8 text") from exc
    required_fragments: list[tuple[str, str]] = [
        ("category", category),
        ("workload contract path", workload_contract_path),
    ]
    required_fragments.extend(("workload ID", value) for value in workload_ids)
    required_fragments.extend(("receipt ID", value) for value in receipt_ids)
    required_fragments.extend(
        ("receipt artifact path", value) for value in receipt_artifact_paths
    )
    required_fragments.extend(
        (f"receipt {label}", fragment)
        for label, fragment in receipt_visible_fragments
    )
    for label, fragment in required_fragments:
        if not visible_fragment_present(text, fragment):
            raise ValueError(f"public gallery content must show {label}: {fragment}")


def load_json(path: Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8"))


def receipt_payload_evidence(
    paths: list[Path],
) -> tuple[list[str], list[str], list[str], list[tuple[str, str]]]:
    receipt_ids: list[str] = []
    receipt_artifact_paths: list[str] = []
    workload_ids: list[str] = []
    receipt_visible_fragments: list[tuple[str, str]] = []
    for path in paths:
        payload = load_json(path)
        if not isinstance(payload, dict):
            raise ValueError(f"receipt payload must be a JSON object: {path}")
        if payload.get("artifactKind") != "browser_execution_receipt":
            raise ValueError(f"receipt payload artifactKind must be browser_execution_receipt: {path}")
        receipt_id = payload.get("receiptId")
        if not isinstance(receipt_id, str) or not receipt_id:
            raise ValueError(f"receipt payload receiptId is required: {path}")
        workload_id = payload.get("workloadId")
        if not isinstance(workload_id, str) or not workload_id:
            raise ValueError(f"receipt payload workloadId is required: {path}")
        receipt_ids.append(receipt_id)
        receipt_artifact_paths.append(repo_relative(path))
        workload_ids.append(workload_id)
        receipt_visible_fragments.extend(receipt_visibility_fragments(payload))
    return (
        validate_string_list(receipt_ids, "receipt ID"),
        validate_string_list(receipt_artifact_paths, "receipt artifact path"),
        validate_workload_ids(workload_ids),
        receipt_visible_fragments,
    )


def build_receipt(
    *,
    receipt_id: str,
    category: str,
    url: str,
    download: DownloadResult,
    gallery_artifact_path: str,
    workload_contract_path: str,
    workload_ids: list[str],
    receipt_ids: list[str],
    receipt_artifact_paths: list[str],
    receipt_visible_fragments: list[tuple[str, str]],
    observed_at: str,
    expected_artifact: Path | None = None,
) -> dict[str, Any]:
    require_non_empty(receipt_id, "receipt ID")
    require_non_empty(gallery_artifact_path, "gallery artifact path")
    require_non_empty(workload_contract_path, "workload contract path")
    require_non_empty(observed_at, "observedAt")
    if category not in GALLERY_CATEGORIES:
        raise ValueError(f"unsupported gallery category: {category}")
    if not is_public_https_url(url):
        raise ValueError("public gallery URL must be public HTTPS")
    if download.status_code != 200:
        raise ValueError(f"public gallery GET returned status {download.status_code}")
    if not download.content:
        raise ValueError("public gallery content must not be empty")
    validate_expected_artifact(download, expected_artifact)
    normalized_workload_ids = validate_workload_ids(workload_ids)
    normalized_receipt_ids = validate_string_list(receipt_ids, "receipt ID")
    normalized_receipt_artifact_paths = validate_string_list(
        receipt_artifact_paths,
        "receipt artifact path",
    )
    validate_visible_gallery_content(
        content=download.content,
        category=category,
        workload_contract_path=workload_contract_path,
        workload_ids=normalized_workload_ids,
        receipt_ids=normalized_receipt_ids,
        receipt_artifact_paths=normalized_receipt_artifact_paths,
        receipt_visible_fragments=receipt_visible_fragments,
    )
    return {
        "schemaVersion": 1,
        "artifactKind": "browser_public_gallery_receipt",
        "receiptId": receipt_id,
        "category": category,
        "url": url,
        "method": "GET",
        "statusCode": download.status_code,
        "contentSha256": sha256_bytes(download.content),
        "contentLengthBytes": len(download.content),
        "galleryArtifactPath": gallery_artifact_path,
        "workloadContractPath": workload_contract_path,
        "workloadIds": normalized_workload_ids,
        "receiptIds": normalized_receipt_ids,
        "receiptArtifactPaths": normalized_receipt_artifact_paths,
        "observedAt": observed_at,
    }


def gallery_artifact_path_arg(args: argparse.Namespace) -> tuple[str, Path | None]:
    expected_artifact = Path(args.gallery_artifact) if args.gallery_artifact else None
    if args.gallery_artifact_path:
        return args.gallery_artifact_path, expected_artifact
    if expected_artifact is not None:
        return repo_relative(expected_artifact), expected_artifact
    raise ValueError("--gallery-artifact-path is required when --gallery-artifact is omitted")


def main() -> int:
    args = parse_args()
    try:
        gallery_artifact_path, expected_artifact = gallery_artifact_path_arg(args)
        receipt_paths = [Path(path) for path in args.receipt_payloads]
        (
            receipt_ids,
            receipt_artifact_paths,
            receipt_workload_ids,
            receipt_visible_fragments,
        ) = receipt_payload_evidence(
            receipt_paths
        )
        workload_ids = validate_workload_ids(args.workload_ids) if args.workload_ids else receipt_workload_ids
        if workload_ids != receipt_workload_ids:
            raise ValueError("workload IDs must match receipt payload workloadIds")
        receipt = build_receipt(
            receipt_id=args.receipt_id,
            category=args.category,
            url=args.url,
            download=fetch_url(args.url),
            gallery_artifact_path=gallery_artifact_path,
            workload_contract_path=args.workload_contract_path,
            workload_ids=workload_ids,
            receipt_ids=receipt_ids,
            receipt_artifact_paths=receipt_artifact_paths,
            receipt_visible_fragments=receipt_visible_fragments,
            observed_at=args.observed_at or observed_at_now(),
            expected_artifact=expected_artifact,
        )
        out_path = Path(args.out)
        out_path.parent.mkdir(parents=True, exist_ok=True)
        out_path.write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8")
    except Exception as exc:
        sys.stderr.write(f"build_browser_public_gallery_receipt: {exc}\n")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
