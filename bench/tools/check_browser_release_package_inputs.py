#!/usr/bin/env python3
"""Check package inputs for deterministic Doe browser release archives."""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import plistlib
import stat
import struct
import sys
from pathlib import Path, PurePosixPath
from typing import Any

try:
    from bench.tools._repo_import import ensure_repo_root
except ModuleNotFoundError:
    from _repo_import import ensure_repo_root

REPO_ROOT = ensure_repo_root(__file__)
PACKER_PATH = (
    REPO_ROOT
    / "browser"
    / "chromium"
    / "scripts"
    / "package-browser-release-archive.py"
)
DEFAULT_PACKAGE_DIR = "browser/chromium/src/out/fawn_release"
DEFAULT_PACKAGE_ROOT_NAME = "Fawn-Doe-linux-x64"
DEFAULT_DOE_RUNTIME = "runtime/zig/zig-out/lib/libwebgpu_doe.so"
DEFAULT_DAWN_FALLBACK_RUNTIME = (
    "browser/chromium/src/out/fawn_release/libdawn_native.so"
)
DEFAULT_SHADER_COMPILER = "runtime/zig/zig-out/bin/doe-zig-runtime"
BROWSER_PRODUCT_BUNDLE_IDS = {
    "doe-browser": "dev.doe.doe-browser",
    "fawn-doe": "dev.doe.fawn-doe",
}
PRODUCT_CHANNELS = {"diagnostic", "release_candidate", "release"}
PLATFORM_OSES = {"macos", "linux"}
PLATFORM_ARCHES = {"arm64", "x64"}
PLATFORM_PACKAGE_FORMATS = {"zip"}
ELF_MACHINE_ARCHES = {
    0x03: "x86",
    0x3E: "x64",
    0xB7: "arm64",
}
MACHO_CPU_ARCHES = {
    7: "x86",
    12: "arm",
    0x01000007: "x64",
    0x0100000C: "arm64",
}
MACHO_MAGICS = {
    b"\xfe\xed\xfa\xce": ">",
    b"\xce\xfa\xed\xfe": "<",
    b"\xfe\xed\xfa\xcf": ">",
    b"\xcf\xfa\xed\xfe": "<",
}
MACHO_FAT_MAGICS = {
    b"\xca\xfe\xba\xbe": (">", 20),
    b"\xbe\xba\xfe\xca": ("<", 20),
    b"\xca\xfe\xba\xbf": (">", 32),
    b"\xbf\xba\xfe\xca": ("<", 32),
}
RELEASE_BUILD_PROFILE_ARGS = {
    "is_debug": "false",
    "is_official_build": "true",
    "dcheck_always_on": "false",
    "chrome_pgo_phase": "0",
    "symbol_level": "0",
    "blink_symbol_level": "0",
    "v8_symbol_level": "0",
    "is_chrome_for_testing": "false",
    "is_chrome_for_testing_branded": "false",
    "is_chrome_branded": "false",
    "use_clang_modules": "false",
    "dawn_enable_webgpu_on_webgpu": "true",
}
BUILD_PROFILE_SEARCH_DEPTH = 4


def load_packer_module() -> Any:
    spec = importlib.util.spec_from_file_location(
        "doe_browser_release_archive_packer",
        PACKER_PATH,
    )
    if spec is None or spec.loader is None:
        raise RuntimeError(f"failed to load browser release packer: {PACKER_PATH}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


PACKER = load_packer_module()


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--package-dir", default=DEFAULT_PACKAGE_DIR)
    parser.add_argument("--package-root-name", default=DEFAULT_PACKAGE_ROOT_NAME)
    parser.add_argument("--browser-executable-package-path", default="")
    parser.add_argument("--browser-app-metadata-package-path", default="")
    parser.add_argument("--doe-runtime", default=DEFAULT_DOE_RUNTIME)
    parser.add_argument(
        "--dawn-fallback-runtime",
        default=DEFAULT_DAWN_FALLBACK_RUNTIME,
    )
    parser.add_argument("--shader-compiler", default=DEFAULT_SHADER_COMPILER)
    parser.add_argument("--doe-runtime-archive-path", default="")
    parser.add_argument("--dawn-fallback-runtime-archive-path", default="")
    parser.add_argument("--product-id", choices=("doe-browser", "fawn-doe"), default="fawn-doe")
    parser.add_argument(
        "--product-name",
        choices=("Doe Browser", "Fawn Doe"),
        default="Fawn Doe",
    )
    parser.add_argument("--product-version", default="0.0.0-sample")
    parser.add_argument(
        "--product-channel",
        choices=("diagnostic", "release_candidate", "release"),
        default="diagnostic",
    )
    parser.add_argument("--platform-os", choices=("macos", "linux"), default="linux")
    parser.add_argument("--platform-arch", choices=("arm64", "x64"), default="x64")
    parser.add_argument(
        "--root",
        default=str(REPO_ROOT),
        help="Repository root used to resolve repo-relative inputs.",
    )
    parser.add_argument(
        "--require-release-candidate-eligible",
        action="store_true",
        help="Exit non-zero unless the inputs satisfy the initial macOS arm64 release-candidate lane.",
    )
    parser.add_argument("--out", default="", help="Optional report output path.")
    parser.add_argument("--json", action="store_true", dest="emit_json")
    return parser.parse_args()


def failure(code: str, path: str, message: str) -> dict[str, str]:
    return {"code": code, "path": path, "message": message}


def sha256_bytes(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def sha256_file(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def parse_gn_args(path: Path) -> dict[str, str]:
    args: dict[str, str] = {}
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.split("#", 1)[0].strip()
        if not line or "=" not in line:
            continue
        key, value = line.split("=", 1)
        key = key.strip()
        value = value.strip().strip('"')
        if key:
            args[key] = value
    return args


def find_args_gn(package_dir: Path | None) -> Path | None:
    if package_dir is None:
        return None
    current = package_dir
    for _ in range(BUILD_PROFILE_SEARCH_DEPTH):
        candidate = current / "args.gn"
        if candidate.is_file():
            return candidate
        parent = current.parent
        if parent == current:
            break
        current = parent
    return None


def build_profile_record(
    *,
    package_dir: Path | None,
    root: Path,
) -> dict[str, Any]:
    args_gn = find_args_gn(package_dir)
    parsed_args = parse_gn_args(args_gn) if args_gn is not None else {}
    checks = []
    for arg, expected in RELEASE_BUILD_PROFILE_ARGS.items():
        actual = parsed_args.get(arg)
        checks.append(
            {
                "arg": arg,
                "expected": expected,
                "actual": actual,
                "matched": actual == expected,
            }
        )
    return {
        "available": args_gn is not None,
        "argsGn": {
            "path": display_path(args_gn, root) if args_gn is not None else "",
            "exists": args_gn is not None,
        },
        "args": {arg: parsed_args[arg] for arg in sorted(parsed_args)},
        "checks": checks,
        "releaseProfileMatched": bool(args_gn is not None)
        and all(check["matched"] for check in checks),
    }


def unique_arches(arches: list[str]) -> list[str]:
    return sorted({arch for arch in arches if arch})


def detect_elf_arches(header: bytes) -> list[str]:
    if len(header) < 20:
        return ["unknown"]
    endian = "<" if header[5] == 1 else ">" if header[5] == 2 else "<"
    machine = struct.unpack(f"{endian}H", header[18:20])[0]
    return [ELF_MACHINE_ARCHES.get(machine, "unknown")]


def detect_macho_arches(header: bytes) -> list[str]:
    magic = header[:4]
    endian = MACHO_MAGICS.get(magic)
    if endian is not None and len(header) >= 8:
        cpu_type = struct.unpack(f"{endian}i", header[4:8])[0]
        return [MACHO_CPU_ARCHES.get(cpu_type, "unknown")]
    fat = MACHO_FAT_MAGICS.get(magic)
    if fat is None or len(header) < 8:
        return ["unknown"]
    endian, entry_size = fat
    fat_count = struct.unpack(f"{endian}I", header[4:8])[0]
    arches: list[str] = []
    offset = 8
    for _ in range(min(fat_count, 32)):
        if len(header) < offset + 4:
            break
        cpu_type = struct.unpack(f"{endian}i", header[offset : offset + 4])[0]
        arches.append(MACHO_CPU_ARCHES.get(cpu_type, "unknown"))
        offset += entry_size
    return unique_arches(arches) or ["unknown"]


def detect_file_identity_bytes(payload: bytes, kind: str) -> dict[str, Any]:
    header = payload[:4096]
    if header.startswith(b"#!"):
        return {"detectedFormat": "script", "detectedArchitectures": []}
    if header.startswith(b"\x7fELF"):
        return {
            "detectedFormat": "elf",
            "detectedArchitectures": detect_elf_arches(header),
        }
    if header[:4] in MACHO_MAGICS or header[:4] in MACHO_FAT_MAGICS:
        return {
            "detectedFormat": "macho",
            "detectedArchitectures": detect_macho_arches(header),
        }
    if kind == "browser_app_metadata":
        if header.startswith(b"bplist") or b"<plist" in header[:256]:
            return {"detectedFormat": "plist", "detectedArchitectures": []}
        if header.lstrip().startswith(b"{"):
            return {"detectedFormat": "json", "detectedArchitectures": []}
    return {"detectedFormat": "unknown", "detectedArchitectures": []}


def detect_file_identity(path: Path, kind: str) -> dict[str, Any]:
    return detect_file_identity_bytes(path.read_bytes(), kind)


def safe_repo_path(path_text: str) -> bool:
    path = PurePosixPath(path_text.replace("\\", "/"))
    return bool(path_text) and not path.is_absolute() and ".." not in path.parts


def resolve_input_path(root: Path, path_text: str) -> Path | None:
    if not path_text:
        return None
    path = Path(path_text)
    if path.is_absolute():
        return path
    if not safe_repo_path(path_text):
        return None
    return root.joinpath(*PurePosixPath(path_text.replace("\\", "/")).parts)


def display_path(path: Path, root: Path) -> str:
    resolved = path.resolve()
    for base in (REPO_ROOT.resolve(), root.resolve()):
        try:
            return str(resolved.relative_to(base))
        except ValueError:
            continue
    return str(path)


def input_path_record(
    *,
    path_text: str,
    resolved: Path | None,
    root: Path,
    path_key: str,
    failures: list[dict[str, str]],
) -> tuple[str, Path | None]:
    if resolved is None:
        failures.append(
            failure(
                "unsafe_input_path",
                path_key,
                "input path must be repo-relative, absolute, and without parent traversal",
            )
        )
        return path_text, None
    return display_path(resolved, root), resolved


def file_input_record(
    *,
    role: str,
    kind: str,
    path_text: str,
    root: Path,
    archive_path: str = "",
    require_executable: bool = False,
    failures: list[dict[str, str]],
) -> dict[str, Any]:
    resolved = resolve_input_path(root, path_text)
    display, resolved = input_path_record(
        path_text=path_text,
        resolved=resolved,
        root=root,
        path_key=f"inputs.{role}.path",
        failures=failures,
    )
    record: dict[str, Any] = {
        "kind": kind,
        "path": display,
        "exists": bool(resolved is not None and resolved.is_file()),
        "generated": False,
    }
    if archive_path:
        record["archivePath"] = archive_path
    if resolved is None or not resolved.is_file():
        failures.append(
            failure(
                "missing_input_file",
                f"inputs.{role}.path",
                f"{role} must be an existing file",
            )
        )
        return record

    mode = stat.S_IMODE(resolved.stat().st_mode)
    executable = bool(mode & stat.S_IXUSR)
    record.update(
        {
            "sha256": sha256_file(resolved),
            "byteLength": resolved.stat().st_size,
            "executable": executable,
            **detect_file_identity(resolved, kind),
        }
    )
    if require_executable and not executable:
        failures.append(
            failure(
                "non_executable_input_file",
                f"inputs.{role}.executable",
                f"{role} must be executable",
            )
        )
    return record


def package_dir_record(
    *,
    package_dir_text: str,
    platform_os: str,
    root: Path,
    failures: list[dict[str, str]],
) -> tuple[dict[str, Any], Path | None]:
    resolved = resolve_input_path(root, package_dir_text)
    display, resolved = input_path_record(
        path_text=package_dir_text,
        resolved=resolved,
        root=root,
        path_key="packageDir.path",
        failures=failures,
    )
    record = {
        "path": display,
        "exists": bool(resolved is not None and resolved.is_dir()),
    }
    if resolved is None or not resolved.is_dir():
        failures.append(
            failure(
                "missing_package_dir",
                "packageDir.path",
                "package-dir must be an existing directory",
            )
        )
        return record, resolved
    if platform_os == "macos" and not resolved.name.endswith(".app"):
        failures.append(
            failure(
                "invalid_macos_package_dir",
                "packageDir.path",
                "macOS package-dir must point at a .app bundle",
            )
        )
    return record, resolved


def normalize_member_path(
    path_text: str,
    *,
    field: str,
    failures: list[dict[str, str]],
) -> str:
    try:
        return PACKER.normalize_member_path(path_text)
    except ValueError as exc:
        failures.append(failure("invalid_archive_member_path", field, str(exc)))
        return path_text.strip().replace("\\", "/")


def package_member_path(
    package_root_name: str,
    package_relative_path: str,
    *,
    field: str,
    failures: list[dict[str, str]],
) -> str:
    try:
        return PACKER.package_member_path(package_root_name, package_relative_path)
    except ValueError as exc:
        failures.append(failure("invalid_archive_member_path", field, str(exc)))
        return f"{package_root_name}/{package_relative_path}".strip("/")


def runtime_member_path(
    *,
    explicit_path: str,
    package_root_name: str,
    runtime_name: str,
    platform_os: str,
    field: str,
    failures: list[dict[str, str]],
) -> str:
    if explicit_path:
        return normalize_member_path(explicit_path, field=field, failures=failures)
    try:
        return PACKER.default_runtime_member_path(
            package_root_name,
            runtime_name,
            platform_os,
        )
    except ValueError as exc:
        failures.append(failure("invalid_archive_member_path", field, str(exc)))
        if platform_os == "macos":
            return f"{package_root_name}/Contents/Frameworks/{runtime_name}".strip("/")
        return f"{package_root_name}/{runtime_name}".strip("/")


def package_source_path(package_dir: Path | None, package_relative_path: str) -> Path | None:
    if package_dir is None:
        return None
    try:
        normalized = PACKER.normalize_member_path(package_relative_path)
    except ValueError:
        return None
    return package_dir.joinpath(*PurePosixPath(normalized).parts)


def generated_metadata_record(
    *,
    path_text: str,
    archive_path: str,
    product: dict[str, str],
    platform: dict[str, str],
    browser_member: str,
    doe_member: str,
    dawn_member: str,
    root: Path,
) -> dict[str, Any]:
    path = Path(path_text)
    display = display_path(path, root) if path.is_absolute() else path_text
    source = PACKER.generated_metadata_source(
        product=product,
        platform=platform,
        browser_member=browser_member,
        doe_member=doe_member,
        dawn_member=dawn_member,
    )
    return {
        "kind": "browser_app_metadata",
        "path": display,
        "archivePath": archive_path,
        "exists": False,
        "generated": True,
        "sha256": sha256_bytes(source.data),
        "byteLength": len(source.data),
        "executable": bool(source.mode & stat.S_IXUSR),
        "detectedFormat": "json",
        "detectedArchitectures": [],
    }


def check_product_identity(
    product: dict[str, str],
    failures: list[dict[str, str]],
) -> None:
    expected_name = PACKER.PRODUCT_DISPLAY_NAMES.get(product["productId"])
    if expected_name is None:
        failures.append(
            failure(
                "invalid_product_id",
                "browserProduct.productId",
                "product-id must be doe-browser or fawn-doe",
            )
        )
    if not product["version"]:
        failures.append(
            failure(
                "missing_product_version",
                "browserProduct.version",
                "product-version is required",
            )
        )
    if product["channel"] not in PRODUCT_CHANNELS:
        failures.append(
            failure(
                "invalid_product_channel",
                "browserProduct.channel",
                "product-channel must be diagnostic, release_candidate, or release",
            )
        )
    if expected_name is not None and product["displayName"] != expected_name:
        failures.append(
            failure(
                "product_identity_mismatch",
                "browserProduct.displayName",
                (
                    f"product-name must be {expected_name!r} for "
                    f"product-id {product['productId']!r}"
                ),
            )
        )


def check_platform_identity(
    platform: dict[str, str],
    failures: list[dict[str, str]],
) -> None:
    if platform["os"] not in PLATFORM_OSES:
        failures.append(
            failure(
                "invalid_platform_os",
                "platform.os",
                "platform-os must be macos or linux",
            )
        )
    if platform["arch"] not in PLATFORM_ARCHES:
        failures.append(
            failure(
                "invalid_platform_arch",
                "platform.arch",
                "platform-arch must be arm64 or x64",
            )
        )
    if platform["packageFormat"] not in PLATFORM_PACKAGE_FORMATS:
        failures.append(
            failure(
                "invalid_platform_package_format",
                "platform.packageFormat",
                "platform packageFormat must be zip",
            )
        )


def check_package_root_identity(
    *,
    package_dir: Path | None,
    package_root_name: str,
    platform_os: str,
    failures: list[dict[str, str]],
) -> None:
    if platform_os != "macos":
        return
    if not package_root_name.endswith(".app"):
        failures.append(
            failure(
                "invalid_macos_package_root_name",
                "packageRootName",
                "macOS packageRootName must name a .app bundle",
            )
        )
    if package_dir is not None and package_dir.name and package_root_name != package_dir.name:
        failures.append(
            failure(
                "macos_package_root_name_mismatch",
                "packageRootName",
                "macOS packageRootName must match package-dir bundle name",
            )
        )


def check_duplicate_members(
    members: dict[str, str],
    failures: list[dict[str, str]],
) -> None:
    seen: dict[str, str] = {}
    for role, member_path in members.items():
        if member_path not in seen:
            seen[member_path] = role
            continue
        failures.append(
            failure(
                "duplicate_required_archive_member",
                f"inputs.{role}.archivePath",
                f"{role} archive path duplicates {seen[member_path]}",
            )
        )


def check_macos_app_metadata(
    *,
    metadata_path: Path,
    product: dict[str, str],
    browser_member: str,
    failures: list[dict[str, str]],
) -> None:
    try:
        with metadata_path.open("rb") as handle:
            plist = plistlib.load(handle)
    except (OSError, plistlib.InvalidFileException, ValueError) as exc:
        failures.append(
            failure(
                "invalid_macos_app_metadata",
                "inputs.appMetadata.path",
                f"macOS app metadata must be a valid Info.plist: {exc}",
            )
        )
        return
    if not isinstance(plist, dict):
        failures.append(
            failure(
                "invalid_macos_app_metadata",
                "inputs.appMetadata.path",
                "macOS app metadata must be a plist dictionary",
            )
        )
        return
    display_name = product["displayName"]
    for field in ("CFBundleName", "CFBundleDisplayName"):
        if plist.get(field) != display_name:
            failures.append(
                failure(
                    "macos_app_metadata_product_mismatch",
                    f"inputs.appMetadata.{field}",
                    f"app metadata {field} must match browserProduct.displayName",
                )
            )
    bundle_id = BROWSER_PRODUCT_BUNDLE_IDS.get(product["productId"])
    if bundle_id is not None and plist.get("CFBundleIdentifier") != bundle_id:
        failures.append(
            failure(
                "macos_app_metadata_bundle_id_mismatch",
                "inputs.appMetadata.CFBundleIdentifier",
                "app metadata CFBundleIdentifier must match browserProduct.productId",
            )
        )
    for field in ("CFBundleShortVersionString", "CFBundleVersion"):
        if plist.get(field) != product["version"]:
            failures.append(
                failure(
                    "macos_app_metadata_version_mismatch",
                    f"inputs.appMetadata.{field}",
                    f"app metadata {field} must match browserProduct.version",
                )
            )
    executable_name = PurePosixPath(browser_member).name
    if plist.get("CFBundleExecutable") != executable_name:
        failures.append(
            failure(
                "macos_app_metadata_executable_mismatch",
                "inputs.appMetadata.CFBundleExecutable",
                "app metadata CFBundleExecutable must match browser executable archive path",
            )
        )
    if plist.get("CFBundlePackageType") != "APPL":
        failures.append(
            failure(
                "macos_app_metadata_package_type_mismatch",
                "inputs.appMetadata.CFBundlePackageType",
                "app metadata CFBundlePackageType must be APPL",
            )
        )


def check_macos_binary_identity(
    *,
    inputs: dict[str, dict[str, Any]],
    platform: dict[str, str],
    failures: list[dict[str, str]],
) -> None:
    if platform["os"] != "macos":
        return
    expected_arch = platform["arch"]
    for role in ("browserExecutable", "doeRuntime", "dawnFallbackRuntime", "shaderCompiler"):
        row = inputs.get(role)
        if not isinstance(row, dict):
            continue
        if row.get("detectedFormat") != "macho":
            failures.append(
                failure(
                    "macos_binary_format_mismatch",
                    f"inputs.{role}.detectedFormat",
                    f"{role} must be a Mach-O binary for macOS packages",
                )
            )
        arches = row.get("detectedArchitectures")
        if not isinstance(arches, list) or expected_arch not in arches:
            failures.append(
                failure(
                    "macos_binary_arch_mismatch",
                    f"inputs.{role}.detectedArchitectures",
                    f"{role} must include {expected_arch} code for macOS packages",
                )
            )


def release_candidate_binary_identity_failures(
    payload: dict[str, Any],
    *,
    path_prefix: str = "packageInputs",
) -> list[dict[str, str]]:
    platform = payload.get("platform")
    if not isinstance(platform, dict) or platform.get("os") != "macos":
        return []
    expected_arch = platform.get("arch")
    if not isinstance(expected_arch, str) or not expected_arch:
        return []
    inputs = payload.get("inputs")
    if not isinstance(inputs, dict):
        return []

    failures: list[dict[str, str]] = []
    for role in ("browserExecutable", "doeRuntime", "dawnFallbackRuntime", "shaderCompiler"):
        row = inputs.get(role)
        if not isinstance(row, dict):
            continue
        if row.get("detectedFormat") != "macho":
            failures.append(
                failure(
                    "package_inputs_macos_binary_format_mismatch",
                    f"{path_prefix}.inputs.{role}.detectedFormat",
                    f"release-candidate package inputs {role} must be Mach-O for macOS",
                )
            )
        arches = row.get("detectedArchitectures")
        if not isinstance(arches, list) or expected_arch not in arches:
            failures.append(
                failure(
                    "package_inputs_macos_binary_arch_mismatch",
                    f"{path_prefix}.inputs.{role}.detectedArchitectures",
                    f"release-candidate package inputs {role} must include {expected_arch} code",
                )
            )
    return failures


def package_member_existing_source(
    *,
    package_dir: Path | None,
    package_root_name: str,
    archive_path: str,
) -> Path | None:
    if package_dir is None:
        return None
    prefix = f"{package_root_name}/"
    if not archive_path.startswith(prefix):
        return None
    relative = archive_path[len(prefix):]
    source = package_source_path(package_dir, relative)
    if source is not None and source.is_file():
        return source
    return None


def replacement_rows(
    *,
    package_dir: Path | None,
    package_root_name: str,
    root: Path,
    inputs: dict[str, dict[str, Any]],
) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    for role in ("doeRuntime", "dawnFallbackRuntime"):
        row = inputs[role]
        archive_path = row.get("archivePath")
        input_path = resolve_input_path(root, row.get("path", ""))
        if not isinstance(archive_path, str):
            continue
        source = package_member_existing_source(
            package_dir=package_dir,
            package_root_name=package_root_name,
            archive_path=archive_path,
        )
        if source is None:
            continue
        same_source = input_path is not None and source.resolve() == input_path.resolve()
        rows.append(
            {
                "role": role,
                "archivePath": archive_path,
                "sourcePath": display_path(source, root),
                "sourceSha256": sha256_file(source),
                "inputPath": row["path"],
                "inputSha256": row.get("sha256", ""),
                "matchesInput": same_source,
            }
        )
    return rows


def release_candidate_blockers(
    *,
    status: str,
    product: dict[str, str],
    platform: dict[str, str],
    build_profile: dict[str, Any],
) -> list[dict[str, str]]:
    blockers: list[dict[str, str]] = []
    if status != "pass":
        blockers.append(
            failure(
                "package_inputs_not_passing",
                "status",
                "package inputs must pass before release-candidate eligibility",
            )
        )
    if product["channel"] != "release_candidate":
        blockers.append(
            failure(
                "release_candidate_channel_required",
                "browserProduct.channel",
                "initial browser release artifact must use release_candidate channel",
            )
        )
    if platform != {"os": "macos", "arch": "arm64", "packageFormat": "zip"}:
        blockers.append(
            failure(
                "initial_macos_arm64_release_required",
                "platform",
                "initial browser release artifact must be macOS arm64 zip",
            )
        )
    if product["channel"] == "release_candidate":
        if not build_profile.get("available"):
            blockers.append(
                failure(
                    "browser_release_build_profile_missing",
                    "buildProfile.argsGn.path",
                    "release-candidate browser inputs must include args.gn build profile evidence",
                )
            )
        for check in build_profile.get("checks", []):
            if not isinstance(check, dict) or check.get("matched") is True:
                continue
            blockers.append(
                failure(
                    "browser_release_build_profile_mismatch",
                    f"buildProfile.args.{check.get('arg', '')}",
                    (
                        "release-candidate browser build profile requires "
                        f"{check.get('arg')}={check.get('expected')}"
                    ),
                )
            )
    return blockers


def build_report(
    *,
    package_dir: str = DEFAULT_PACKAGE_DIR,
    package_root_name: str = DEFAULT_PACKAGE_ROOT_NAME,
    browser_executable_package_path: str = "",
    browser_app_metadata_package_path: str = "",
    doe_runtime: str = DEFAULT_DOE_RUNTIME,
    dawn_fallback_runtime: str = DEFAULT_DAWN_FALLBACK_RUNTIME,
    shader_compiler: str = DEFAULT_SHADER_COMPILER,
    doe_runtime_archive_path: str = "",
    dawn_fallback_runtime_archive_path: str = "",
    product_id: str = "fawn-doe",
    product_name: str = "Fawn Doe",
    product_version: str = "0.0.0-sample",
    product_channel: str = "diagnostic",
    platform_os: str = "linux",
    platform_arch: str = "x64",
    root: Path = REPO_ROOT,
) -> dict[str, Any]:
    failures: list[dict[str, str]] = []
    product = {
        "productId": product_id,
        "displayName": product_name,
        "version": product_version,
        "channel": product_channel,
    }
    platform = {
        "os": platform_os,
        "arch": platform_arch,
        "packageFormat": "zip",
    }
    package_dir_info, package_dir_path = package_dir_record(
        package_dir_text=package_dir,
        platform_os=platform_os,
        root=root,
        failures=failures,
    )
    check_product_identity(product, failures)
    check_platform_identity(platform, failures)
    check_package_root_identity(
        package_dir=package_dir_path,
        package_root_name=package_root_name,
        platform_os=platform_os,
        failures=failures,
    )

    browser_package_path = (
        browser_executable_package_path
        or PACKER.default_browser_executable_package_path(platform_os)
    )
    app_metadata_package_path = (
        browser_app_metadata_package_path
        or PACKER.default_app_metadata_package_path(platform_os)
    )
    browser_member = package_member_path(
        package_root_name,
        browser_package_path,
        field="inputs.browserExecutable.archivePath",
        failures=failures,
    )
    metadata_member = package_member_path(
        package_root_name,
        app_metadata_package_path,
        field="inputs.appMetadata.archivePath",
        failures=failures,
    )
    doe_member = runtime_member_path(
        explicit_path=doe_runtime_archive_path,
        package_root_name=package_root_name,
        runtime_name=PACKER.DEFAULT_DOE_RUNTIME_NAME,
        platform_os=platform_os,
        field="inputs.doeRuntime.archivePath",
        failures=failures,
    )
    dawn_member = runtime_member_path(
        explicit_path=dawn_fallback_runtime_archive_path,
        package_root_name=package_root_name,
        runtime_name=PACKER.DEFAULT_DAWN_RUNTIME_NAME,
        platform_os=platform_os,
        field="inputs.dawnFallbackRuntime.archivePath",
        failures=failures,
    )
    check_duplicate_members(
        {
            "browserExecutable": browser_member,
            "appMetadata": metadata_member,
            "doeRuntime": doe_member,
            "dawnFallbackRuntime": dawn_member,
        },
        failures,
    )

    browser_source = package_source_path(package_dir_path, browser_package_path)
    metadata_source = package_source_path(package_dir_path, app_metadata_package_path)
    inputs: dict[str, dict[str, Any]] = {
        "browserExecutable": file_input_record(
            role="browserExecutable",
            kind="browser_binary",
            path_text=str(browser_source) if browser_source is not None else browser_package_path,
            root=root,
            archive_path=browser_member,
            require_executable=True,
            failures=failures,
        ),
        "doeRuntime": file_input_record(
            role="doeRuntime",
            kind="doe_runtime",
            path_text=doe_runtime,
            root=root,
            archive_path=doe_member,
            failures=failures,
        ),
        "dawnFallbackRuntime": file_input_record(
            role="dawnFallbackRuntime",
            kind="dawn_fallback_runtime",
            path_text=dawn_fallback_runtime,
            root=root,
            archive_path=dawn_member,
            failures=failures,
        ),
        "shaderCompiler": file_input_record(
            role="shaderCompiler",
            kind="shader_compiler",
            path_text=shader_compiler,
            root=root,
            require_executable=True,
            failures=failures,
        ),
    }
    if metadata_source is not None and metadata_source.is_file():
        inputs["appMetadata"] = file_input_record(
            role="appMetadata",
            kind="browser_app_metadata",
            path_text=str(metadata_source),
            root=root,
            archive_path=metadata_member,
            failures=failures,
        )
        metadata_source_mode = "package"
        if platform_os == "macos":
            check_macos_app_metadata(
                metadata_path=metadata_source,
                product=product,
                browser_member=browser_member,
                failures=failures,
            )
    elif platform_os == "linux":
        metadata_path = (
            package_dir_path / app_metadata_package_path
            if package_dir_path is not None
            else Path(app_metadata_package_path)
        )
        inputs["appMetadata"] = generated_metadata_record(
            path_text=display_path(metadata_path, root),
            archive_path=metadata_member,
            product=product,
            platform=platform,
            browser_member=browser_member,
            doe_member=doe_member,
            dawn_member=dawn_member,
            root=root,
        )
        metadata_source_mode = "generated"
    else:
        inputs["appMetadata"] = file_input_record(
            role="appMetadata",
            kind="browser_app_metadata",
            path_text=str(metadata_source) if metadata_source is not None else app_metadata_package_path,
            root=root,
            archive_path=metadata_member,
            failures=failures,
        )
        metadata_source_mode = "missing"

    ordered_inputs = {
        "browserExecutable": inputs["browserExecutable"],
        "appMetadata": inputs["appMetadata"],
        "doeRuntime": inputs["doeRuntime"],
        "dawnFallbackRuntime": inputs["dawnFallbackRuntime"],
        "shaderCompiler": inputs["shaderCompiler"],
    }
    check_macos_binary_identity(
        inputs=ordered_inputs,
        platform=platform,
        failures=failures,
    )
    replacements = replacement_rows(
        package_dir=package_dir_path,
        package_root_name=package_root_name,
        root=root,
        inputs=ordered_inputs,
    )
    build_profile = build_profile_record(package_dir=package_dir_path, root=root)
    status = "fail" if failures else "pass"
    candidate_blockers = release_candidate_blockers(
        status=status,
        product=product,
        platform=platform,
        build_profile=build_profile,
    )
    release_candidate_eligible = not candidate_blockers
    return {
        "schemaVersion": 1,
        "artifactKind": "browser_release_package_inputs_check",
        "packageDir": package_dir_info,
        "packageRootName": package_root_name,
        "browserProduct": product,
        "platform": platform,
        "evidenceMode": "release_candidate"
        if release_candidate_eligible
        else "diagnostic",
        "releaseCandidateEligible": release_candidate_eligible,
        "releaseCandidateBlockers": candidate_blockers,
        "buildProfile": build_profile,
        "inputs": ordered_inputs,
        "overwrittenPackageMembers": replacements,
        "status": status,
        "failures": failures,
        "summary": {
            "packageable": status == "pass",
            "metadataSource": metadata_source_mode,
            "requiredArchiveMemberCount": 4,
            "runtimeReplacementCount": len(replacements),
        },
    }


def main() -> int:
    args = parse_args()
    report = build_report(
        package_dir=args.package_dir,
        package_root_name=args.package_root_name,
        browser_executable_package_path=args.browser_executable_package_path,
        browser_app_metadata_package_path=args.browser_app_metadata_package_path,
        doe_runtime=args.doe_runtime,
        dawn_fallback_runtime=args.dawn_fallback_runtime,
        shader_compiler=args.shader_compiler,
        doe_runtime_archive_path=args.doe_runtime_archive_path,
        dawn_fallback_runtime_archive_path=args.dawn_fallback_runtime_archive_path,
        product_id=args.product_id,
        product_name=args.product_name,
        product_version=args.product_version,
        product_channel=args.product_channel,
        platform_os=args.platform_os,
        platform_arch=args.platform_arch,
        root=Path(args.root).resolve(),
    )
    if args.out:
        out_path = Path(args.out)
        out_path.parent.mkdir(parents=True, exist_ok=True)
        out_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    if args.emit_json:
        print(json.dumps(report, indent=2))
    elif report["status"] == "pass":
        print("PASS: browser release package inputs are packageable")
        if not report["releaseCandidateEligible"]:
            print("DIAGNOSTIC: release-candidate eligibility is blocked")
            for item in report["releaseCandidateBlockers"]:
                print(f"- {item['code']}: {item['path']}: {item['message']}")
    else:
        print("FAIL: browser release package inputs are not packageable")
        for item in report["failures"]:
            print(f"- {item['code']}: {item['path']}: {item['message']}")
    if report["status"] != "pass":
        return 1
    if args.require_release_candidate_eligible and not report["releaseCandidateEligible"]:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
