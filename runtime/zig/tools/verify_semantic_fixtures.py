"""Verify semantic-fixture integrity and classify candidate behavior changes."""

from __future__ import annotations

import argparse
import hashlib
import subprocess
import sys
from pathlib import Path, PurePosixPath
from typing import Any

from source_architecture import canonical_json, load_json_strict, sha256_file


ROOT = Path(__file__).resolve().parents[1]
BASELINE_ROOT = ROOT / "reports" / "recomposition" / "semantic-fixtures"
ABI_APPROVAL_PATH = (
    ROOT / "reports" / "recomposition" / "abi-contract-approval.json"
)
NON_ABI_APPROVAL_CATEGORIES = (
    "command-normalization",
    "error-classification",
    "semantic-fixture",
    "trace-and-replay",
    "wgsl-lowering",
)
PCI_IDENTITY_TARGET = {
    "cSignature": (
        "void doeNativeAdapterGetPciIdentity(void *adapter, "
        "uint32_t *out_vendor_id, uint32_t *out_device_id, "
        "uint32_t *out_driver_version)"
    ),
    "callingConvention": "c",
    "parameters": [
        {
            "direction": "in",
            "name": "adapter",
            "nullable": True,
            "type": "opaque-pointer",
        },
        {
            "direction": "out",
            "name": "out_vendor_id",
            "nullable": False,
            "type": "u32-pointer",
        },
        {
            "direction": "out",
            "name": "out_device_id",
            "nullable": False,
            "type": "u32-pointer",
        },
        {
            "direction": "out",
            "name": "out_driver_version",
            "nullable": False,
            "type": "u32-pointer",
        },
    ],
    "returnType": "void",
    "symbol": "doeNativeAdapterGetPciIdentity",
    "symbolFile": "abi/libwebgpu_doe.so.symbols.txt",
}


def load_verified_fixture_set(root: Path) -> tuple[dict[str, Any], dict[str, bytes]]:
    """Load one fixture set and reject every missing or digest-mismatched file."""

    manifest_path = root / "manifest.json"
    manifest = load_json_strict(manifest_path)
    if not isinstance(manifest, dict):
        raise RuntimeError("semantic fixture manifest must be an object")
    files: dict[str, bytes] = {}
    for record in manifest["files"]:
        relative_path = record["path"]
        if not isinstance(relative_path, str):
            raise RuntimeError(f"invalid semantic fixture path: {relative_path!r}")
        pure_path = PurePosixPath(relative_path)
        if (
            pure_path.is_absolute()
            or ".." in pure_path.parts
            or pure_path.as_posix() != relative_path
        ):
            raise RuntimeError(f"invalid semantic fixture path: {relative_path!r}")
        if relative_path in files:
            raise RuntimeError(f"duplicate semantic fixture path: {relative_path}")
        path = root / relative_path
        if not path.is_file():
            raise RuntimeError(f"missing semantic fixture: {relative_path}")
        content = path.read_bytes()
        if len(content) != record["sizeBytes"]:
            raise RuntimeError(f"semantic fixture size mismatch: {relative_path}")
        if hashlib.sha256(content).hexdigest() != record["sha256"]:
            raise RuntimeError(f"semantic fixture digest mismatch: {relative_path}")
        files[relative_path] = content
    actual_paths = {
        path.relative_to(root).as_posix()
        for path in root.rglob("*")
        if path.is_file() and path != manifest_path
    }
    if actual_paths != set(files):
        untracked = sorted(actual_paths - set(files))
        missing = sorted(set(files) - actual_paths)
        raise RuntimeError(
            "semantic fixture inventory mismatch: "
            f"untracked={untracked}, missing={missing}"
        )
    return manifest, files


def _category(path: str) -> str:
    if path.startswith("abi/"):
        return "abi-surface"
    if path.startswith("command-") or path.startswith("embedded-command-"):
        return "command-normalization"
    if path.startswith("trace-"):
        return "trace-and-replay"
    if path.startswith("wgsl-"):
        return "wgsl-lowering"
    return "semantic-fixture"


def _symbol_set(content: bytes) -> set[str]:
    """Parse one canonical exported-symbol fixture."""

    try:
        lines = content.decode("utf-8").splitlines()
    except UnicodeDecodeError as exc:
        raise RuntimeError("ABI symbol fixture is not UTF-8") from exc
    symbols = {line for line in lines if line}
    if len(symbols) != len([line for line in lines if line]):
        raise RuntimeError("ABI symbol fixture contains duplicate symbols")
    return symbols


def _repository_path(root: Path, relative_path: str) -> Path:
    pure_path = PurePosixPath(relative_path)
    if (
        pure_path.is_absolute()
        or ".." in pure_path.parts
        or pure_path.as_posix() != relative_path
    ):
        raise RuntimeError(f"invalid repository-relative path: {relative_path!r}")
    return root / relative_path


def _git_blob_sha256(
    repository_root: Path,
    commit: str,
    relative_path: str,
) -> str:
    _repository_path(repository_root, relative_path)
    result = subprocess.run(
        ["git", "show", f"{commit}:{relative_path}"],
        cwd=repository_root,
        check=False,
        capture_output=True,
    )
    if result.returncode != 0:
        raise RuntimeError(
            f"ABI approval source is absent from reviewed commit: {relative_path}"
        )
    return hashlib.sha256(result.stdout).hexdigest()


def load_abi_contract_approval(
    path: Path,
    repository_root: Path,
) -> tuple[dict[str, Any], dict[str, set[str]]]:
    """Load one reviewed ABI approval and its established predecessor receipt."""

    payload = load_json_strict(path)
    if not isinstance(payload, dict):
        raise RuntimeError("ABI approval must be a JSON object")
    if payload.get("artifactKind") != "recomposition-abi-contract-approval":
        raise RuntimeError("ABI approval has the wrong artifactKind")
    if payload.get("schemaVersion") != 1 or payload.get("status") != "approved":
        raise RuntimeError("ABI approval is not an approved schemaVersion 1 artifact")
    if payload.get("category") != "abi-surface":
        raise RuntimeError("ABI approval category must be abi-surface")
    if payload.get("approvalScope") != "internal-extension":
        raise RuntimeError("PCI identity approval must remain an internal extension")

    target = payload.get("target")
    reviewed_code = payload.get("reviewedCode")
    evidence = payload.get("evidence")
    if not isinstance(target, dict) or not isinstance(reviewed_code, dict):
        raise RuntimeError("ABI approval target and reviewedCode must be objects")
    if not isinstance(evidence, dict):
        raise RuntimeError("ABI approval evidence must be an object")
    if target != PCI_IDENTITY_TARGET:
        raise RuntimeError("ABI approval target does not match the exact PCI contract")
    symbol_file = target.get("symbolFile")
    symbol = target.get("symbol")
    source_tree_sha256 = reviewed_code.get("sourceTreeSha256")
    reviewed_commit = reviewed_code.get("commit")
    if not isinstance(symbol_file, str) or not isinstance(symbol, str):
        raise RuntimeError("ABI approval target must name one symbol file and symbol")
    if not isinstance(source_tree_sha256, str) or len(source_tree_sha256) != 64:
        raise RuntimeError("ABI approval must bind one analyzed source-tree digest")
    if not isinstance(reviewed_commit, str) or len(reviewed_commit) != 40:
        raise RuntimeError("ABI approval must bind one reviewed code commit")
    compatibility = payload.get("compatibility")
    semantics = payload.get("semantics")
    non_claims = payload.get("nonClaims")
    if not isinstance(compatibility, dict) or (
        compatibility.get("kind") != "additive"
        or compatibility.get("dynamicLookup") != "optional"
        or compatibility.get("olderLibrariesRemainLoadable") is not True
        or compatibility.get("changedSymbols") != []
        or compatibility.get("removedSymbols") != []
    ):
        raise RuntimeError("ABI approval compatibility contract is not bounded additive")
    if not isinstance(semantics, dict) or (
        semantics.get("identityValues") != "raw-backend-reported-u32"
        or semantics.get("invalidAdapter") != "all-outputs-zero"
        or semantics.get("unavailableValue") != 0
        or semantics.get("driverVersion")
        != "raw-backend-value-not-cross-backend-comparable"
    ):
        raise RuntimeError("ABI approval identity semantics are invalid")
    if non_claims != [
        "hardware-attestation",
        "cross-backend-driver-normalization",
        "performance-evidence",
        "physical-device-qualification",
    ]:
        raise RuntimeError("ABI approval non-claims are incomplete or reordered")

    declaration = evidence.get("declaration")
    optional_consumers = evidence.get("optionalConsumers")
    source_records = [declaration]
    if isinstance(optional_consumers, list):
        source_records.extend(optional_consumers)
    else:
        raise RuntimeError("ABI approval optionalConsumers must be an array")
    for source_record in source_records:
        if not isinstance(source_record, dict):
            raise RuntimeError("ABI approval source evidence must be an object")
        source_path = source_record.get("path")
        source_sha256 = source_record.get("sha256")
        if not isinstance(source_path, str) or not isinstance(source_sha256, str):
            raise RuntimeError("ABI approval source evidence fields are invalid")
        if _git_blob_sha256(repository_root, reviewed_commit, source_path) != source_sha256:
            raise RuntimeError(
                f"ABI approval source digest does not match reviewed commit: {source_path}"
            )

    allowed_symbols: dict[str, set[str]] = {symbol_file: {symbol}}
    prior_approvals = evidence.get("priorApprovals")
    if not isinstance(prior_approvals, list):
        raise RuntimeError("ABI approval priorApprovals must be an array")
    prior_receipts: list[dict[str, Any]] = []
    for prior in prior_approvals:
        if not isinstance(prior, dict):
            raise RuntimeError("ABI prior approval must be an object")
        receipt_path_value = prior.get("receiptPath")
        receipt_sha256 = prior.get("receiptSha256")
        prior_symbol_file = prior.get("symbolFile")
        prior_symbols = prior.get("symbols")
        if (
            not isinstance(receipt_path_value, str)
            or not isinstance(receipt_sha256, str)
            or not isinstance(prior_symbol_file, str)
            or not isinstance(prior_symbols, list)
            or not prior_symbols
            or any(not isinstance(item, str) for item in prior_symbols)
        ):
            raise RuntimeError("ABI prior approval fields are invalid")
        receipt_path = _repository_path(repository_root, receipt_path_value)
        if sha256_file(receipt_path) != receipt_sha256:
            raise RuntimeError("ABI prior approval receipt digest does not match")
        receipt = load_json_strict(receipt_path)
        if (
            not isinstance(receipt, dict)
            or receipt.get("classification") != "approved-contract-change"
        ):
            raise RuntimeError("ABI prior approval receipt is not approved")
        exported_differences = [
            difference
            for difference in receipt.get("differences", [])
            if isinstance(difference, dict)
            and difference.get("surface") == "exported-symbols"
        ]
        receipt_added = {
            item
            for difference in exported_differences
            for item in difference.get("added", [])
            if isinstance(item, str)
        }
        receipt_removed = {
            item
            for difference in exported_differences
            for item in difference.get("removed", [])
            if isinstance(item, str)
        }
        if receipt_removed or receipt_added != set(prior_symbols):
            raise RuntimeError(
                "ABI prior approval does not establish the declared additive symbols"
            )
        allowed_symbols.setdefault(prior_symbol_file, set()).update(prior_symbols)
        prior_receipts.append(
            {
                "path": receipt_path_value,
                "sha256": receipt_sha256,
                "symbols": sorted(prior_symbols),
            }
        )

    artifact_path = path.resolve()
    try:
        artifact_label = artifact_path.relative_to(repository_root.resolve()).as_posix()
    except ValueError:
        artifact_label = str(artifact_path)
    receipt_contract = {
        "approvedSymbols": [
            {"path": approved_path, "symbols": sorted(symbols)}
            for approved_path, symbols in sorted(allowed_symbols.items())
        ],
        "artifactPath": artifact_label,
        "artifactSha256": sha256_file(path),
        "priorReceipts": prior_receipts,
        "reviewedCodeCommit": reviewed_commit,
        "reviewedSourceTreeSha256": source_tree_sha256,
    }
    return receipt_contract, allowed_symbols


def classify(
    baseline_manifest: dict[str, Any],
    baseline_files: dict[str, bytes],
    candidate_manifest: dict[str, Any],
    candidate_files: dict[str, bytes],
    approved_categories: set[str],
    approval_reason: str | None,
    abi_approval: tuple[dict[str, Any], dict[str, set[str]]] | None = None,
) -> tuple[int, dict[str, Any]]:
    """Classify exact equivalence, approved behavior change, or failure."""

    differences: list[dict[str, Any]] = []
    for path in sorted(set(baseline_files) | set(candidate_files)):
        baseline = baseline_files.get(path)
        candidate = candidate_files.get(path)
        if baseline == candidate:
            continue
        difference = {
            "baselineSha256": (
                hashlib.sha256(baseline).hexdigest()
                if baseline is not None
                else None
            ),
            "candidateSha256": (
                hashlib.sha256(candidate).hexdigest()
                if candidate is not None
                else None
            ),
            "category": _category(path),
            "path": path,
        }
        if difference["category"] == "abi-surface":
            baseline_symbols = _symbol_set(baseline or b"")
            candidate_symbols = _symbol_set(candidate or b"")
            difference["addedSymbols"] = sorted(
                candidate_symbols - baseline_symbols
            )
            difference["removedSymbols"] = sorted(
                baseline_symbols - candidate_symbols
            )
        differences.append(difference)
    semantic_sections = (
        "commandNormalization",
        "errorClassifications",
        "replay",
        "trace",
        "wgsl",
    )
    for section in semantic_sections:
        if baseline_manifest.get(section) == candidate_manifest.get(section):
            continue
        category = {
            "commandNormalization": "command-normalization",
            "errorClassifications": "error-classification",
            "replay": "trace-and-replay",
            "trace": "trace-and-replay",
            "wgsl": "wgsl-lowering",
        }[section]
        differences.append(
            {
                "baselineSha256": hashlib.sha256(
                    canonical_json(baseline_manifest.get(section)).encode("utf-8")
                ).hexdigest(),
                "candidateSha256": hashlib.sha256(
                    canonical_json(candidate_manifest.get(section)).encode("utf-8")
                ).hexdigest(),
                "category": category,
                "path": f"manifest:{section}",
            }
        )
    baseline_observers = baseline_manifest.get(
        "irDigestInstrumentation",
        {},
    ).get("observers")
    candidate_observers = candidate_manifest.get(
        "irDigestInstrumentation",
        {},
    ).get("observers")
    if baseline_observers != candidate_observers:
        differences.append(
            {
                "baselineSha256": hashlib.sha256(
                    canonical_json(baseline_observers).encode("utf-8")
                ).hexdigest(),
                "candidateSha256": hashlib.sha256(
                    canonical_json(candidate_observers).encode("utf-8")
                ).hexdigest(),
                "category": "wgsl-lowering",
                "path": "manifest:irDigestObserver",
            }
        )
    changed_categories = {difference["category"] for difference in differences}
    if "abi-surface" in approved_categories:
        raise RuntimeError(
            "abi-surface requires a symbol-scoped ABI approval artifact"
        )
    abi_differences = [
        difference
        for difference in differences
        if difference["category"] == "abi-surface"
    ]
    abi_contract = (
        abi_approval[0]
        if abi_differences and abi_approval is not None
        else None
    )
    abi_approved = not abi_differences
    if abi_differences and abi_approval is not None:
        candidate_source = candidate_manifest.get("sourceTreeSha256")
        approved_source = abi_contract["reviewedSourceTreeSha256"]
        actual_additions = {
            difference["path"]: set(difference["addedSymbols"])
            for difference in abi_differences
            if difference["addedSymbols"]
        }
        has_removals = any(
            difference["removedSymbols"] for difference in abi_differences
        )
        abi_approved = (
            candidate_source == approved_source
            and not has_removals
            and actual_additions == abi_approval[1]
        )
    non_abi_changes = changed_categories - {"abi-surface"}
    non_abi_approved = not non_abi_changes or (
        non_abi_changes <= approved_categories and bool(approval_reason)
    )
    if not differences:
        classification = "exact-semantic-equivalence"
        exit_code = 0
    elif abi_approved and non_abi_approved:
        classification = "approved-contract-change"
        exit_code = 0
    else:
        classification = "failure"
        exit_code = 1
    receipt = {
        "approval": {
            "abiContract": abi_contract,
            "categories": sorted(approved_categories),
            "reason": approval_reason,
        },
        "baselineCommit": baseline_manifest["git"]["baseCommit"],
        "candidateCommit": candidate_manifest["git"]["baseCommit"],
        "classification": classification,
        "differences": differences,
        "schemaVersion": 1,
    }
    if classification == "failure":
        receipt["failureBoundary"] = "+".join(sorted(changed_categories))
    return exit_code, receipt


def parse_args() -> argparse.Namespace:
    """Parse semantic verification arguments."""

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--baseline-root",
        type=Path,
        default=BASELINE_ROOT,
        help="frozen semantic fixture directory",
    )
    parser.add_argument(
        "--candidate-root",
        type=Path,
        help="candidate semantic fixture directory; omit for integrity-only mode",
    )
    parser.add_argument(
        "--approve-category",
        action="append",
        choices=NON_ABI_APPROVAL_CATEGORIES,
        default=[],
    )
    parser.add_argument(
        "--abi-approval",
        type=Path,
        default=ABI_APPROVAL_PATH,
        help=(
            "reviewed symbol-scoped ABI approval; category-wide ABI approval "
            "is forbidden"
        ),
    )
    parser.add_argument("--approval-reason")
    parser.add_argument("--output", type=Path)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.approve_category and not args.approval_reason:
        print("--approval-reason is required with --approve-category", file=sys.stderr)
        return 1
    try:
        baseline_manifest, baseline_files = load_verified_fixture_set(
            args.baseline_root
        )
        if args.candidate_root is None:
            exit_code = 0
            receipt = {
                "classification": "integrity-verified",
                "fileCount": len(baseline_files),
                "manifestSha256": sha256_file(args.baseline_root / "manifest.json"),
                "schemaVersion": 1,
            }
        else:
            candidate_manifest, candidate_files = load_verified_fixture_set(
                args.candidate_root
            )
            abi_approval = None
            if args.abi_approval is not None:
                abi_approval = load_abi_contract_approval(
                    args.abi_approval.resolve(),
                    ROOT.parents[1],
                )
            exit_code, receipt = classify(
                baseline_manifest,
                baseline_files,
                candidate_manifest,
                candidate_files,
                set(args.approve_category),
                args.approval_reason,
                abi_approval,
            )
    except (KeyError, OSError, RuntimeError, ValueError) as exc:
        exit_code = 1
        receipt = {
            "classification": "failure",
            "diagnostic": str(exc),
            "failureBoundary": "semantic-fixture-integrity",
            "schemaVersion": 1,
        }
    rendered = canonical_json(receipt)
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(rendered, encoding="utf-8")
    sys.stdout.write(rendered)
    return exit_code


if __name__ == "__main__":
    raise SystemExit(main())
