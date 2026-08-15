#!/usr/bin/env python3
"""Package a Chromium-family Doe browser directory into a release zip."""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import hashlib
import json
import stat
import sys
import zipfile
from pathlib import Path, PurePosixPath
from typing import Any


REPO_ROOT = Path(__file__).resolve().parents[3]
FIXED_ZIP_DATE_TIME = (1980, 1, 1, 0, 0, 0)
DEFAULT_MACOS_BROWSER_EXECUTABLE_PACKAGE_PATH = "Contents/MacOS/Chromium"
DEFAULT_MACOS_APP_METADATA_PACKAGE_PATH = "Contents/Info.plist"
DEFAULT_LINUX_BROWSER_EXECUTABLE_PACKAGE_PATH = "chrome-wrapper"
DEFAULT_LINUX_APP_METADATA_PACKAGE_PATH = "browser-product.json"
DEFAULT_DOE_RUNTIME_NAME = "libwebgpu_doe.so"
DEFAULT_DAWN_RUNTIME_NAME = "libdawn_native.so"
PRODUCT_DISPLAY_NAMES = {
    "doe-browser": "Doe Browser",
    "fawn-doe": "Fawn Doe",
}


@dataclass(frozen=True)
class MemberSource:
    data: bytes
    mode: int
    source_path: Path | None


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--package-dir", "--app-dir", dest="package_dir", default="")
    parser.add_argument("--out", required=True)
    parser.add_argument("--manifest-out", required=True)
    parser.add_argument(
        "--package-inputs",
        default="",
        help=(
            "Optional browser_release_package_inputs_check report used as the "
            "source of truth for package directory, product/platform identity, "
            "runtime inputs, and archive member paths."
        ),
    )
    parser.add_argument(
        "--package-inputs-root",
        default="",
        help="Root used to resolve relative paths stored in --package-inputs.",
    )
    parser.add_argument(
        "--required-members-only",
        action="store_true",
        help=(
            "Package only browser executable, metadata, and required runtime "
            "members. This is restricted to diagnostic product channels for "
            "compact sample archives."
        ),
    )
    parser.add_argument("--doe-runtime", default="")
    parser.add_argument("--dawn-fallback-runtime", default="")
    parser.add_argument("--package-root-name", "--app-bundle-name", dest="package_root_name", default="")
    parser.add_argument(
        "--browser-executable-package-path",
        "--browser-executable-app-path",
        dest="browser_executable_package_path",
        default="",
    )
    parser.add_argument(
        "--browser-app-metadata-package-path",
        "--browser-app-metadata-app-path",
        dest="browser_app_metadata_package_path",
        default="",
    )
    parser.add_argument("--doe-runtime-archive-path", default="")
    parser.add_argument("--dawn-fallback-runtime-archive-path", default="")
    parser.add_argument("--product-id", choices=("doe-browser", "fawn-doe"), default="fawn-doe")
    parser.add_argument("--product-name", choices=("Doe Browser", "Fawn Doe"), default="Fawn Doe")
    parser.add_argument("--product-version", default="")
    parser.add_argument(
        "--product-channel",
        choices=("diagnostic", "release_candidate", "release"),
        default="release_candidate",
    )
    parser.add_argument("--platform-os", choices=("macos", "linux"), default="macos")
    parser.add_argument("--platform-arch", choices=("arm64", "x64"), default="")
    return parser.parse_args()


def repo_relative(path: Path) -> str:
    resolved = path.resolve()
    try:
        return str(resolved.relative_to(REPO_ROOT))
    except ValueError:
        return str(path)


def sha256_file(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def artifact(path: Path, kind: str) -> dict[str, str]:
    require_file(path, kind)
    return {
        "path": repo_relative(path),
        "sha256": sha256_file(path),
        "kind": kind,
    }


def require_file(path: Path, label: str) -> None:
    if not path.is_file():
        raise FileNotFoundError(f"{label} must be an existing file: {path}")


def require_executable_file(path: Path, label: str) -> None:
    require_file(path, label)
    if not stat.S_IMODE(path.stat().st_mode) & stat.S_IXUSR:
        raise ValueError(f"{label} must be executable: {path}")


def require_package_dir(path: Path, platform_os: str) -> None:
    if not path.is_dir():
        raise FileNotFoundError(f"package-dir must be an existing directory: {path}")
    if platform_os != "macos" or path.name.endswith(".app"):
        return
    raise ValueError(f"macOS package-dir must point at a .app bundle: {path}")


def require_product_identity(product_id: str, display_name: str) -> None:
    expected_name = PRODUCT_DISPLAY_NAMES[product_id]
    if display_name != expected_name:
        raise ValueError(
            f"product-name must be {expected_name!r} for product-id {product_id!r}"
        )


def load_json_object(path: Path) -> dict[str, Any]:
    payload = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(payload, dict):
        raise ValueError(f"expected JSON object: {path}")
    return payload


def package_input_row(payload: dict[str, Any], role: str) -> dict[str, Any]:
    inputs = payload.get("inputs")
    if not isinstance(inputs, dict):
        raise ValueError("package inputs report must carry inputs object")
    row = inputs.get(role)
    if not isinstance(row, dict):
        raise ValueError(f"package inputs report missing input row: {role}")
    return row


def package_input_path(payload: dict[str, Any], role: str) -> str:
    path = package_input_row(payload, role).get("path")
    if not isinstance(path, str) or not path:
        raise ValueError(f"package inputs report missing {role}.path")
    return path


def package_input_archive_path(payload: dict[str, Any], role: str) -> str:
    archive_path = package_input_row(payload, role).get("archivePath")
    if not isinstance(archive_path, str) or not archive_path:
        raise ValueError(f"package inputs report missing {role}.archivePath")
    return archive_path


def string_map(value: Any, label: str) -> dict[str, str]:
    if not isinstance(value, dict):
        raise ValueError(f"package inputs report missing {label}")
    result: dict[str, str] = {}
    for key, item in value.items():
        if not isinstance(key, str) or not isinstance(item, str):
            raise ValueError(f"package inputs {label} must be a string object")
        result[key] = item
    return result


def load_package_inputs(path_text: str) -> dict[str, Any] | None:
    if not path_text:
        return None
    payload = load_json_object(Path(path_text))
    if payload.get("artifactKind") != "browser_release_package_inputs_check":
        raise ValueError("package inputs report artifactKind must be browser_release_package_inputs_check")
    if payload.get("status") != "pass":
        raise ValueError("package inputs report must pass before archive packaging")
    return payload


def resolve_package_input_path(path_text: str, root: Path) -> Path:
    if not path_text:
        raise ValueError("package input path must not be empty")
    path = Path(path_text)
    if path.is_absolute():
        return path.resolve()
    pure = PurePosixPath(path_text.replace("\\", "/"))
    if pure.is_absolute() or ".." in pure.parts or not pure.parts:
        raise ValueError(f"package input path must be relative without parent traversal: {path_text}")
    resolved = root.joinpath(*pure.parts).resolve()
    try:
        resolved.relative_to(root.resolve())
    except ValueError as exc:
        raise ValueError(f"package input path must resolve under package-inputs-root: {path_text}") from exc
    return resolved


def paths_match(left: str, right: str, root: Path) -> bool:
    if left == right:
        return True
    try:
        return resolve_package_input_path(left, root) == resolve_package_input_path(right, root)
    except ValueError:
        return False


def normalize_member_path(path: str) -> str:
    normalized = path.strip().replace("\\", "/")
    if not normalized or normalized.startswith("/") or normalized.endswith("/"):
        raise ValueError(f"archive member path must be relative and normalized: {path}")
    parts = normalized.split("/")
    if any(part in {"", ".", ".."} for part in parts):
        raise ValueError(f"archive member path must be relative and normalized: {path}")
    return "/".join(parts)


def require_distinct_required_members(members: dict[str, str]) -> None:
    seen: dict[str, str] = {}
    for role, member_path in members.items():
        normalized = normalize_member_path(member_path)
        previous_role = seen.get(normalized)
        if previous_role is not None:
            raise ValueError(
                f"{role} archive path duplicates {previous_role}: {normalized}"
            )
        seen[normalized] = role


def package_member_path(package_root_name: str, package_relative_path: str) -> str:
    return normalize_member_path(f"{package_root_name}/{package_relative_path}")


def default_browser_executable_package_path(platform_os: str) -> str:
    if platform_os == "macos":
        return DEFAULT_MACOS_BROWSER_EXECUTABLE_PACKAGE_PATH
    return DEFAULT_LINUX_BROWSER_EXECUTABLE_PACKAGE_PATH


def default_app_metadata_package_path(platform_os: str) -> str:
    if platform_os == "macos":
        return DEFAULT_MACOS_APP_METADATA_PACKAGE_PATH
    return DEFAULT_LINUX_APP_METADATA_PACKAGE_PATH


def default_runtime_member_path(
    package_root_name: str,
    runtime_name: str,
    platform_os: str,
) -> str:
    if platform_os == "macos":
        return package_member_path(package_root_name, f"Contents/Frameworks/{runtime_name}")
    return package_member_path(package_root_name, runtime_name)


def package_relative_member_path(package_root_name: str, archive_path: str) -> str:
    normalized_root = normalize_member_path(package_root_name)
    normalized_archive_path = normalize_member_path(archive_path)
    prefix = f"{normalized_root}/"
    if not normalized_archive_path.startswith(prefix):
        raise ValueError(
            f"archive path must be under package root {normalized_root}: {archive_path}"
        )
    return normalized_archive_path[len(prefix):]


def required_arg(value: str, label: str) -> str:
    if not value:
        raise ValueError(f"{label} is required when --package-inputs is not provided")
    return value


def explicit_path_must_match(
    *,
    explicit_path: str,
    derived_path: str,
    label: str,
    root: Path,
) -> None:
    if explicit_path and not paths_match(explicit_path, derived_path, root):
        raise ValueError(f"{label} must match --package-inputs")


def explicit_value_must_match(
    *,
    explicit_value: str,
    derived_value: str,
    label: str,
) -> None:
    if explicit_value and explicit_value != derived_value:
        raise ValueError(f"{label} must match --package-inputs")


def resolved_package_config(args: argparse.Namespace) -> dict[str, Any]:
    package_inputs = load_package_inputs(args.package_inputs)
    package_inputs_root = (
        Path(args.package_inputs_root).resolve()
        if args.package_inputs_root
        else REPO_ROOT
    )
    if package_inputs is not None:
        package_dir_record = package_inputs.get("packageDir")
        if not isinstance(package_dir_record, dict) or not isinstance(package_dir_record.get("path"), str):
            raise ValueError("package inputs report missing packageDir.path")
        package_root_name = package_inputs.get("packageRootName")
        if not isinstance(package_root_name, str) or not package_root_name:
            raise ValueError("package inputs report missing packageRootName")
        product = string_map(package_inputs.get("browserProduct"), "browserProduct")
        platform = string_map(package_inputs.get("platform"), "platform")
        if platform.get("packageFormat") != "zip":
            raise ValueError("package inputs platform.packageFormat must be zip")
        if (
            product.get("channel") == "release_candidate"
            and package_inputs.get("releaseCandidateEligible") is not True
        ):
            raise ValueError(
                "release-candidate packaging requires eligible --package-inputs"
            )

        package_dir = resolve_package_input_path(package_dir_record["path"], package_inputs_root)
        doe_runtime = resolve_package_input_path(
            package_input_path(package_inputs, "doeRuntime"),
            package_inputs_root,
        )
        dawn_fallback_runtime = resolve_package_input_path(
            package_input_path(package_inputs, "dawnFallbackRuntime"),
            package_inputs_root,
        )
        browser_member = package_input_archive_path(package_inputs, "browserExecutable")
        metadata_member = package_input_archive_path(package_inputs, "appMetadata")
        doe_member = package_input_archive_path(package_inputs, "doeRuntime")
        dawn_member = package_input_archive_path(package_inputs, "dawnFallbackRuntime")
        browser_executable_package_path = package_relative_member_path(package_root_name, browser_member)
        app_metadata_package_path = package_relative_member_path(package_root_name, metadata_member)

        explicit_path_must_match(
            explicit_path=args.package_dir,
            derived_path=package_dir_record["path"],
            label="--package-dir",
            root=package_inputs_root,
        )
        explicit_path_must_match(
            explicit_path=args.doe_runtime,
            derived_path=package_input_path(package_inputs, "doeRuntime"),
            label="--doe-runtime",
            root=package_inputs_root,
        )
        explicit_path_must_match(
            explicit_path=args.dawn_fallback_runtime,
            derived_path=package_input_path(package_inputs, "dawnFallbackRuntime"),
            label="--dawn-fallback-runtime",
            root=package_inputs_root,
        )
        explicit_value_must_match(
            explicit_value=args.package_root_name,
            derived_value=package_root_name,
            label="--package-root-name",
        )
        explicit_value_must_match(
            explicit_value=args.browser_executable_package_path,
            derived_value=browser_executable_package_path,
            label="--browser-executable-package-path",
        )
        explicit_value_must_match(
            explicit_value=args.browser_app_metadata_package_path,
            derived_value=app_metadata_package_path,
            label="--browser-app-metadata-package-path",
        )
        explicit_value_must_match(
            explicit_value=args.doe_runtime_archive_path,
            derived_value=doe_member,
            label="--doe-runtime-archive-path",
        )
        explicit_value_must_match(
            explicit_value=args.dawn_fallback_runtime_archive_path,
            derived_value=dawn_member,
            label="--dawn-fallback-runtime-archive-path",
        )
        explicit_value_must_match(
            explicit_value=args.product_version,
            derived_value=product["version"],
            label="--product-version",
        )
        explicit_value_must_match(
            explicit_value=args.platform_arch,
            derived_value=platform["arch"],
            label="--platform-arch",
        )
        return {
            "package_dir": package_dir,
            "package_root_name": package_root_name,
            "browser_executable_package_path": browser_executable_package_path,
            "app_metadata_package_path": app_metadata_package_path,
            "doe_member": doe_member,
            "dawn_member": dawn_member,
            "doe_runtime": doe_runtime,
            "dawn_fallback_runtime": dawn_fallback_runtime,
            "product": product,
            "platform": platform,
            "source_package_inputs": artifact(
                Path(args.package_inputs),
                "browser_release_package_inputs_check",
            ),
        }

    if args.product_channel == "release_candidate" and args.platform_os == "linux":
        raise ValueError(
            "Linux release-candidate packaging requires --package-inputs from "
            "the browser release package preflight"
        )
    package_dir = Path(required_arg(args.package_dir, "--package-dir"))
    package_root_name = args.package_root_name or package_dir.name
    platform_arch = required_arg(args.platform_arch, "--platform-arch")
    browser_executable_package_path = (
        args.browser_executable_package_path
        or default_browser_executable_package_path(args.platform_os)
    )
    app_metadata_package_path = (
        args.browser_app_metadata_package_path
        or default_app_metadata_package_path(args.platform_os)
    )
    return {
        "package_dir": package_dir,
        "package_root_name": package_root_name,
        "browser_executable_package_path": browser_executable_package_path,
        "app_metadata_package_path": app_metadata_package_path,
        "doe_member": args.doe_runtime_archive_path or default_runtime_member_path(
            package_root_name,
            DEFAULT_DOE_RUNTIME_NAME,
            args.platform_os,
        ),
        "dawn_member": args.dawn_fallback_runtime_archive_path or default_runtime_member_path(
            package_root_name,
            DEFAULT_DAWN_RUNTIME_NAME,
            args.platform_os,
        ),
        "doe_runtime": Path(required_arg(args.doe_runtime, "--doe-runtime")),
        "dawn_fallback_runtime": Path(required_arg(args.dawn_fallback_runtime, "--dawn-fallback-runtime")),
        "product": {
            "productId": args.product_id,
            "displayName": args.product_name,
            "version": required_arg(args.product_version, "--product-version"),
            "channel": args.product_channel,
        },
        "platform": {
            "os": args.platform_os,
            "arch": platform_arch,
            "packageFormat": "zip",
        },
        "source_package_inputs": None,
    }


def file_member_source(path: Path) -> MemberSource:
    return MemberSource(
        data=path.read_bytes(),
        mode=stat.S_IMODE(path.stat().st_mode) or 0o644,
        source_path=path,
    )


def generated_metadata_source(
    *,
    product: dict[str, str],
    platform: dict[str, str],
    browser_member: str,
    doe_member: str,
    dawn_member: str,
) -> MemberSource:
    payload = {
        "browserProduct": product,
        "platform": platform,
        "browserExecutableArchivePath": browser_member,
        "doeRuntimeArchivePath": doe_member,
        "dawnFallbackRuntimeArchivePath": dawn_member,
    }
    return MemberSource(
        data=json.dumps(payload, indent=2).encode("utf-8") + b"\n",
        mode=0o644,
        source_path=None,
    )


def collect_member_sources(
    *,
    package_dir: Path,
    package_root_name: str,
    platform_os: str,
    browser_executable_package_path: str,
    app_metadata_package_path: str,
    doe_runtime_archive_path: str,
    dawn_fallback_runtime_archive_path: str,
    doe_runtime: Path,
    dawn_fallback_runtime: Path,
    product: dict[str, str],
    platform: dict[str, str],
    required_members_only: bool,
) -> dict[str, MemberSource]:
    browser_source = package_dir / browser_executable_package_path
    metadata_source = package_dir / app_metadata_package_path
    require_executable_file(browser_source, "browser executable inside package")
    if platform_os == "macos":
        require_file(metadata_source, "browser app metadata inside package")
    require_file(doe_runtime, "Doe runtime")
    require_file(dawn_fallback_runtime, "Dawn fallback runtime")

    member_sources: dict[str, MemberSource] = {}
    if not required_members_only:
        for source in sorted(package_dir.rglob("*")):
            if not source.is_file():
                continue
            relative = source.relative_to(package_dir).as_posix()
            member_sources[package_member_path(package_root_name, relative)] = file_member_source(source)

    browser_member = package_member_path(package_root_name, browser_executable_package_path)
    metadata_member = package_member_path(package_root_name, app_metadata_package_path)
    doe_member = normalize_member_path(doe_runtime_archive_path)
    dawn_member = normalize_member_path(dawn_fallback_runtime_archive_path)
    member_sources[browser_member] = file_member_source(browser_source)
    if platform_os == "macos" or metadata_source.is_file():
        member_sources[metadata_member] = file_member_source(metadata_source)
    else:
        member_sources[metadata_member] = generated_metadata_source(
            product=product,
            platform=platform,
            browser_member=browser_member,
            doe_member=doe_member,
            dawn_member=dawn_member,
        )
    member_sources[doe_member] = file_member_source(doe_runtime)
    member_sources[dawn_member] = file_member_source(dawn_fallback_runtime)
    return member_sources


def write_zip(archive_path: Path, member_sources: dict[str, MemberSource]) -> None:
    archive_path.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(
        archive_path,
        "w",
        compression=zipfile.ZIP_DEFLATED,
        compresslevel=9,
    ) as archive:
        for member_path in sorted(member_sources):
            source = member_sources[member_path]
            info = zipfile.ZipInfo(member_path, FIXED_ZIP_DATE_TIME)
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = source.mode << 16
            archive.writestr(info, source.data)


def archive_artifact(path: Path) -> dict[str, Any]:
    return {
        "path": repo_relative(path),
        "sha256": sha256_file(path),
        "byteLength": path.stat().st_size,
        "kind": "browser_release_archive",
    }


def member_record(member_path: str, source: MemberSource) -> dict[str, Any]:
    record = {
        "archivePath": member_path,
        "sha256": hashlib.sha256(source.data).hexdigest(),
        "byteLength": len(source.data),
        "executable": bool(source.mode & stat.S_IXUSR),
    }
    if source.source_path is not None:
        record["sourcePath"] = repo_relative(source.source_path)
    return record


def build_manifest(
    *,
    archive_path: Path,
    package_root_name: str,
    browser_member: str,
    metadata_member: str,
    doe_member: str,
    dawn_member: str,
    member_sources: dict[str, MemberSource],
    product: dict[str, str],
    platform: dict[str, str],
    source_package_inputs: dict[str, str] | None,
) -> dict[str, Any]:
    archive_members = [
        member_record(member_path, member_sources[member_path])
        for member_path in sorted(member_sources)
    ]
    payload = {
        "schemaVersion": 1,
        "artifactKind": "browser_release_archive_manifest",
        "archive": archive_artifact(archive_path),
        "browserProduct": product,
        "platform": platform,
        "appBundleName": package_root_name,
        "members": {
            "browserExecutable": member_record(browser_member, member_sources[browser_member]),
            "appMetadata": member_record(metadata_member, member_sources[metadata_member]),
            "doeRuntime": member_record(doe_member, member_sources[doe_member]),
            "dawnFallbackRuntime": member_record(dawn_member, member_sources[dawn_member]),
        },
        "archiveMembers": archive_members,
    }
    if source_package_inputs is not None:
        payload["sourcePackageInputs"] = source_package_inputs
    return payload


def main() -> int:
    args = parse_args()
    if args.required_members_only and args.product_channel != "diagnostic":
        raise ValueError("--required-members-only is restricted to diagnostic product channels")
    config = resolved_package_config(args)
    package_dir = config["package_dir"]
    product = config["product"]
    platform = config["platform"]
    platform_os = platform["os"]
    if args.required_members_only and product["channel"] != "diagnostic":
        raise ValueError("--required-members-only is restricted to diagnostic product channels")
    require_package_dir(package_dir, platform_os)
    archive_path = Path(args.out)
    manifest_path = Path(args.manifest_out)
    package_root_name = config["package_root_name"]
    browser_executable_package_path = config["browser_executable_package_path"]
    app_metadata_package_path = config["app_metadata_package_path"]
    doe_member = normalize_member_path(config["doe_member"])
    dawn_member = normalize_member_path(config["dawn_member"])
    browser_member = package_member_path(package_root_name, browser_executable_package_path)
    metadata_member = package_member_path(package_root_name, app_metadata_package_path)
    require_distinct_required_members(
        {
            "browserExecutable": browser_member,
            "appMetadata": metadata_member,
            "doeRuntime": doe_member,
            "dawnFallbackRuntime": dawn_member,
        }
    )
    require_product_identity(product["productId"], product["displayName"])
    member_sources = collect_member_sources(
        package_dir=package_dir,
        package_root_name=package_root_name,
        platform_os=platform_os,
        browser_executable_package_path=browser_executable_package_path,
        app_metadata_package_path=app_metadata_package_path,
        doe_runtime_archive_path=doe_member,
        dawn_fallback_runtime_archive_path=dawn_member,
        doe_runtime=config["doe_runtime"],
        dawn_fallback_runtime=config["dawn_fallback_runtime"],
        product=product,
        platform=platform,
        required_members_only=args.required_members_only,
    )
    write_zip(archive_path, member_sources)
    manifest = build_manifest(
        archive_path=archive_path,
        package_root_name=package_root_name,
        browser_member=browser_member,
        metadata_member=metadata_member,
        doe_member=doe_member,
        dawn_member=dawn_member,
        member_sources=member_sources,
        product=product,
        platform=platform,
        source_package_inputs=config["source_package_inputs"],
    )
    manifest_path.parent.mkdir(parents=True, exist_ok=True)
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main())
