#!/usr/bin/env python3
"""Validate the Doe dylib proc surface required by Chromium forced-Doe mode."""

from __future__ import annotations

import argparse
import ctypes
import json
import re
import sys
from pathlib import Path, PurePosixPath
from typing import Any, Callable


try:
    from bench.tools._repo_import import ensure_repo_root
except ModuleNotFoundError:
    from _repo_import import ensure_repo_root

REPO_ROOT = ensure_repo_root(__file__)
from bench.lib.bench_utils import load_json_object as load_json

DEFAULT_CONFIG = "config/doe-chromium-proc-surface.json"
EXPECTED_SURFACE_ID = "doe-chromium-proc-surface"

SymbolChecker = Callable[[str], bool]
WireProcChecker = Callable[[str], bool]
LocalProcChecker = Callable[[str], bool]
InstanceBootstrapChecker = Callable[[], tuple[bool, str]]
BrowserSharedMemoryBehaviorChecker = Callable[[], tuple[bool, str]]
PROC_TABLE_PATTERN = re.compile(
    r"\s+WGPUProc(?P<suffix>[A-Za-z0-9]+)\s+(?P<field>[a-zA-Z0-9_]+);"
)
LOCAL_PROC_PATTERN = re.compile(
    r'symbolViewEq\(name,\s*"(?P<symbol>wgpu[A-Za-z0-9]+)"\)'
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--config",
        default=DEFAULT_CONFIG,
        help="Doe Chromium proc-surface config, repo-relative or absolute.",
    )
    parser.add_argument(
        "--library",
        default="",
        help="Optional Doe WebGPU library path override, repo-relative or absolute.",
    )
    parser.add_argument(
        "--root",
        default=str(REPO_ROOT),
        help="Repository root used to resolve repo-relative paths.",
    )
    parser.add_argument(
        "--require-ready",
        action="store_true",
        help="Exit non-zero when the library is missing or lacks required symbols.",
    )
    parser.add_argument("--json", action="store_true", dest="emit_json")
    return parser.parse_args()


def safe_repo_path(path_text: str) -> bool:
    path = PurePosixPath(path_text)
    return bool(path_text) and not path.is_absolute() and ".." not in path.parts


def resolve_path(root: Path, path_text: str) -> Path | None:
    raw = Path(path_text)
    if raw.is_absolute():
        return raw
    if not safe_repo_path(path_text):
        return None
    return root.joinpath(*PurePosixPath(path_text).parts)


def check_row(
    check_id: str,
    status: str,
    message: str,
    *,
    required: bool = True,
    symbol: str | None = None,
    domain: str | None = None,
    path: str | None = None,
    resolved_path: str | None = None,
) -> dict[str, Any]:
    row: dict[str, Any] = {
        "checkId": check_id,
        "status": status,
        "required": required,
        "message": message,
    }
    if symbol is not None:
        row["symbol"] = symbol
    if domain is not None:
        row["domain"] = domain
    if path is not None:
        row["path"] = path
    if resolved_path is not None:
        row["resolvedPath"] = resolved_path
    return row


def validate_config(payload: dict[str, Any]) -> list[str]:
    failures: list[str] = []
    if payload.get("schemaVersion") != 1:
        failures.append("schemaVersion must be 1")
    if payload.get("surfaceId") != EXPECTED_SURFACE_ID:
        failures.append(f"surfaceId must be {EXPECTED_SURFACE_ID}")
    if payload.get("selectionMode") != "forced_doe_source_selector":
        failures.append("selectionMode must be forced_doe_source_selector")
    instance_bootstrap = payload.get("instanceBootstrap")
    if not isinstance(instance_bootstrap, dict):
        failures.append("instanceBootstrap must be an object")
    elif instance_bootstrap.get("required") is not True:
        failures.append("instanceBootstrap.required must be true")
    wire_proc_table = payload.get("wireProcTable")
    if not isinstance(wire_proc_table, dict):
        failures.append("wireProcTable must be an object")
    else:
        if wire_proc_table.get("required") is not True:
            failures.append("wireProcTable.required must be true")
        if wire_proc_table.get("lookupSymbol") != "wgpuGetProcAddress":
            failures.append("wireProcTable.lookupSymbol must be wgpuGetProcAddress")
        header_path = wire_proc_table.get("tableHeaderPath")
        if not isinstance(header_path, str) or not safe_repo_path(header_path):
            failures.append("wireProcTable.tableHeaderPath must be a safe repo-relative path")
    local_wire_proc_surface = payload.get("localWireProcSurface")
    if not isinstance(local_wire_proc_surface, dict):
        failures.append("localWireProcSurface must be an object")
    else:
        if local_wire_proc_surface.get("required") is not True:
            failures.append("localWireProcSurface.required must be true")
        resolver_source_path = local_wire_proc_surface.get("resolverSourcePath")
        if not isinstance(resolver_source_path, str) or not safe_repo_path(resolver_source_path):
            failures.append("localWireProcSurface.resolverSourcePath must be a safe repo-relative path")
        local_required_symbols = local_wire_proc_surface.get("requiredSymbols")
        if not isinstance(local_required_symbols, list) or not local_required_symbols:
            failures.append("localWireProcSurface.requiredSymbols must be a non-empty array")
        else:
            local_seen: set[str] = set()
            for index, row in enumerate(local_required_symbols):
                if not isinstance(row, dict):
                    failures.append(f"localWireProcSurface.requiredSymbols[{index}] must be an object")
                    continue
                symbol = row.get("symbol")
                domain = row.get("domain")
                if not isinstance(symbol, str) or not symbol:
                    failures.append(f"localWireProcSurface.requiredSymbols[{index}].symbol must be non-empty")
                    continue
                if symbol in local_seen:
                    failures.append(f"duplicate local wire proc symbol: {symbol}")
                local_seen.add(symbol)
                if not isinstance(domain, str) or not domain:
                    failures.append(f"localWireProcSurface.requiredSymbols[{index}].domain must be non-empty")
    browser_shared_memory_behavior = payload.get("browserSharedMemoryBehavior")
    if not isinstance(browser_shared_memory_behavior, dict):
        failures.append("browserSharedMemoryBehavior must be an object")
    else:
        if browser_shared_memory_behavior.get("required") is not True:
            failures.append("browserSharedMemoryBehavior.required must be true")
        implementation_source_path = browser_shared_memory_behavior.get("implementationSourcePath")
        if not isinstance(implementation_source_path, str) or not safe_repo_path(implementation_source_path):
            failures.append("browserSharedMemoryBehavior.implementationSourcePath must be a safe repo-relative path")
    required_symbols = payload.get("requiredSymbols")
    if not isinstance(required_symbols, list) or not required_symbols:
        failures.append("requiredSymbols must be a non-empty array")
        return failures
    seen: set[str] = set()
    for index, row in enumerate(required_symbols):
        if not isinstance(row, dict):
            failures.append(f"requiredSymbols[{index}] must be an object")
            continue
        symbol = row.get("symbol")
        domain = row.get("domain")
        if not isinstance(symbol, str) or not symbol:
            failures.append(f"requiredSymbols[{index}].symbol must be non-empty")
            continue
        if symbol in seen:
            failures.append(f"duplicate required symbol: {symbol}")
        seen.add(symbol)
        if not isinstance(domain, str) or not domain:
            failures.append(f"requiredSymbols[{index}].domain must be non-empty")
    return failures


def load_ctypes_library(library_path: Path) -> tuple[Any | None, str | None]:
    try:
        library = ctypes.CDLL(str(library_path))
    except OSError as exc:
        return None, str(exc)
    return library, None


def ctypes_symbol_checker(library: Any) -> SymbolChecker:
    def symbol_exists(symbol: str) -> bool:
        try:
            getattr(library, symbol)
        except AttributeError:
            return False
        return True

    return symbol_exists


class WGPUStringView(ctypes.Structure):
    _fields_ = [("data", ctypes.c_char_p), ("length", ctypes.c_size_t)]


def ctypes_wire_proc_checker(library: Any, lookup_symbol: str) -> WireProcChecker | None:
    try:
        get_proc = getattr(library, lookup_symbol)
    except AttributeError:
        return None
    get_proc.argtypes = [WGPUStringView]
    get_proc.restype = ctypes.c_void_p

    def proc_exists(symbol: str) -> bool:
        encoded = symbol.encode("ascii")
        return bool(get_proc(WGPUStringView(encoded, len(encoded))))

    return proc_exists


def parse_dawn_proc_table_symbols(header_path: Path) -> tuple[list[str], str | None]:
    try:
        text = header_path.read_text(encoding="utf-8")
    except OSError as exc:
        return [], str(exc)
    symbols: list[str] = []
    seen: set[str] = set()
    for match in PROC_TABLE_PATTERN.finditer(text):
        symbol = f"wgpu{match.group('suffix')}"
        if symbol in seen:
            continue
        seen.add(symbol)
        symbols.append(symbol)
    if not symbols:
        return [], "DawnProcTable header did not contain WGPUProc fields"
    return symbols, None


def parse_local_proc_symbols(source_path: Path) -> tuple[set[str], str | None]:
    try:
        text = source_path.read_text(encoding="utf-8")
    except OSError as exc:
        return set(), str(exc)
    symbols = {match.group("symbol") for match in LOCAL_PROC_PATTERN.finditer(text)}
    if not symbols:
        return set(), "resolver source did not contain symbolViewEq local proc mappings"
    return symbols, None


def _extract_zig_function(text: str, symbol: str) -> str | None:
    start = text.find(f"pub fn {symbol}(")
    if start == -1:
        return None
    end = text.find("\npub fn ", start + 1)
    if end == -1:
        end = len(text)
    return text[start:end]


def check_browser_shared_memory_behavior_source(source_path: Path) -> tuple[bool, str]:
    try:
        text = source_path.read_text(encoding="utf-8")
    except OSError as exc:
        return False, str(exc)

    expectations = {
        "wgpuDeviceCreateErrorBuffer": [
            "native.make(native.DoeBuffer)",
            ".error_object = true",
            "labelOwnedObject(raw, d.label);",
            "return raw;",
        ],
        "wgpuDeviceCreateErrorTexture": [
            "native.make(native.DoeTexture)",
            ".error_object = true",
            "labelOwnedObject(raw, d.label);",
            "return raw;",
        ],
    }
    failures: list[str] = []
    for symbol, markers in expectations.items():
        body = _extract_zig_function(text, symbol)
        if body is None:
            failures.append(f"{symbol} missing")
            continue
        for marker in markers:
            if marker not in body:
                failures.append(f"{symbol} missing {marker}")

    whole_file_markers = [
        "STYPE_SHARED_TEXTURE_MEMORY_IOSURFACE_DESCRIPTOR",
        "WGPUSharedTextureMemoryIOSurfaceDescriptor",
        "const DoeSharedTextureMemory = struct",
        "extern fn CFRetain",
        "extern fn CFRelease",
    ]
    for marker in whole_file_markers:
        if marker not in text:
            failures.append(f"shared texture memory missing {marker}")

    shared_texture_expectations = {
        "wgpuDeviceImportSharedTextureMemory": [
            "findIOSurfaceDescriptor(desc)",
            "external_texture_ops.importIOSurface(dev.mtl_device, iosurface)",
            "native.make(DoeSharedTextureMemory)",
            "labelOwnedObject(raw, desc.label);",
            "return raw;",
        ],
        "wgpuSharedTextureMemoryCreateTexture": [
            "external_texture_ops.importIOSurface(",
            "native.make(native.DoeTexture)",
            ".error_object = false",
            ".mtl = imported.plane0",
            "labelOwnedObject(raw, desc.label);",
            "return raw;",
        ],
        "wgpuSharedTextureMemoryBeginAccess": [
            "shared_memory.in_access = true",
            "return abi_core.WGPUStatus_Success;",
        ],
        "wgpuSharedTextureMemoryEndAccess": [
            "state.initialized = abi_core.WGPU_TRUE;",
            "shared_memory.in_access = false",
            "return abi_core.WGPUStatus_Success;",
        ],
        "wgpuSharedTextureMemoryGetProperties": [
            "out.usage = shared_memory.usage;",
            "out.format = shared_memory.format;",
            "return abi_core.WGPUStatus_Success;",
        ],
    }
    for symbol, markers in shared_texture_expectations.items():
        body = _extract_zig_function(text, symbol)
        if body is None:
            failures.append(f"{symbol} missing")
            continue
        for marker in markers:
            if marker not in body:
                failures.append(f"{symbol} missing {marker}")

    if "logUnsupported(\"wgpuDeviceImportSharedBufferMemory\");" not in text:
        failures.append("shared buffer import does not log explicit unsupported")

    if failures:
        return False, "; ".join(failures)
    return (
        True,
        "error-object procs allocate tagged Doe handles, IOSurface shared texture import is native, and shared buffer import fails explicitly",
    )


def bootstrap_ctypes_instance(library: Any) -> tuple[bool, str]:
    try:
        create_instance = library.wgpuCreateInstance
        release_instance = library.wgpuInstanceRelease
    except AttributeError as exc:
        return False, f"missing instance lifecycle proc: {exc}"

    create_instance.argtypes = [ctypes.c_void_p]
    create_instance.restype = ctypes.c_void_p
    release_instance.argtypes = [ctypes.c_void_p]
    release_instance.restype = None

    instance = create_instance(None)
    if not instance:
        return False, "wgpuCreateInstance returned null"
    release_instance(instance)
    return True, "Doe WGPU instance created and released"


def check_proc_surface(
    payload: dict[str, Any],
    *,
    root: Path,
    config_path_text: str = DEFAULT_CONFIG,
    library_override: str = "",
    symbol_checker: SymbolChecker | None = None,
    wire_proc_checker: WireProcChecker | None = None,
    local_proc_checker: LocalProcChecker | None = None,
    instance_bootstrap_checker: InstanceBootstrapChecker | None = None,
    browser_shared_memory_behavior_checker: BrowserSharedMemoryBehaviorChecker | None = None,
) -> dict[str, Any]:
    checks: list[dict[str, Any]] = []
    config_failures = validate_config(payload)
    for index, message in enumerate(config_failures):
        checks.append(
            check_row(
                f"config:{index}",
                "fail",
                message,
            )
        )

    library_path_text = library_override or str(payload.get("libraryPath", ""))
    library_path = resolve_path(root, library_path_text)
    if library_path is None:
        checks.append(
            check_row(
                "library_path",
                "fail",
                "libraryPath must be repo-relative or absolute without parent traversal",
                path=library_path_text,
            )
        )
    elif not library_path.is_file():
        checks.append(
            check_row(
                "library_path",
                "fail",
                "Doe WebGPU library is missing",
                path=library_path_text,
                resolved_path=str(library_path),
            )
        )
    else:
        checks.append(
            check_row(
                "library_path",
                "pass",
                "Doe WebGPU library exists",
                path=library_path_text,
                resolved_path=str(library_path),
            )
        )

    ctypes_library: Any | None = None
    active_symbol_checker = symbol_checker
    if active_symbol_checker is None and library_path is not None and library_path.is_file():
        ctypes_library, load_error = load_ctypes_library(library_path)
        if load_error is not None:
            checks.append(
                check_row(
                    "library_load",
                    "fail",
                    f"Doe WebGPU library failed to load: {load_error}",
                    path=library_path_text,
                    resolved_path=str(library_path),
                )
            )
        else:
            active_symbol_checker = ctypes_symbol_checker(ctypes_library)
            checks.append(
                check_row(
                    "library_load",
                    "pass",
                    "Doe WebGPU library loaded",
                    path=library_path_text,
                    resolved_path=str(library_path),
                )
            )

    required_symbols = payload.get("requiredSymbols")
    if isinstance(required_symbols, list):
        for row in required_symbols:
            if not isinstance(row, dict):
                continue
            symbol = row.get("symbol")
            domain = row.get("domain")
            if not isinstance(symbol, str) or not isinstance(domain, str):
                continue
            if active_symbol_checker is None:
                checks.append(
                    check_row(
                        f"symbol:{symbol}",
                        "fail",
                        "required symbol could not be checked",
                        symbol=symbol,
                        domain=domain,
                    )
                )
                continue
            if active_symbol_checker(symbol):
                checks.append(
                    check_row(
                        f"symbol:{symbol}",
                        "pass",
                        "required Chromium WebGPU symbol is exported",
                        symbol=symbol,
                        domain=domain,
                    )
                )
            else:
                checks.append(
                    check_row(
                        f"symbol:{symbol}",
                        "fail",
                        "required Chromium WebGPU symbol is missing",
                        symbol=symbol,
                        domain=domain,
                    )
            )

    wire_proc_table = payload.get("wireProcTable")
    wire_proc_symbols: list[str] = []
    active_wire_proc_checker = wire_proc_checker
    if isinstance(wire_proc_table, dict) and wire_proc_table.get("required") is True:
        table_header_path_text = str(wire_proc_table.get("tableHeaderPath", ""))
        table_header_path = resolve_path(root, table_header_path_text)
        if table_header_path is None:
            checks.append(
                check_row(
                    "wire_proc_table_header",
                    "fail",
                    "wireProcTable.tableHeaderPath must be repo-relative or absolute without parent traversal",
                    path=table_header_path_text,
                )
            )
        elif not table_header_path.is_file():
            checks.append(
                check_row(
                    "wire_proc_table_header",
                    "fail",
                    "DawnProcTable header is missing",
                    path=table_header_path_text,
                    resolved_path=str(table_header_path),
                )
            )
        else:
            wire_proc_symbols, parse_error = parse_dawn_proc_table_symbols(table_header_path)
            checks.append(
                check_row(
                    "wire_proc_table_header",
                    "fail" if parse_error else "pass",
                    parse_error or "DawnProcTable header parsed",
                    path=table_header_path_text,
                    resolved_path=str(table_header_path),
                )
            )
        if active_wire_proc_checker is None and ctypes_library is not None:
            active_wire_proc_checker = ctypes_wire_proc_checker(
                ctypes_library,
                str(wire_proc_table.get("lookupSymbol", "")),
            )
        if active_wire_proc_checker is None:
            checks.append(
                check_row(
                    "wire_proc_table_lookup",
                    "fail",
                    "wgpuGetProcAddress wire proc lookup could not be checked",
                    symbol=str(wire_proc_table.get("lookupSymbol", "")),
                    domain="wire_proc_table",
                )
            )
        elif wire_proc_symbols:
            checks.append(
                check_row(
                    "wire_proc_table_lookup",
                    "pass",
                    "wgpuGetProcAddress wire proc lookup is available",
                    symbol=str(wire_proc_table.get("lookupSymbol", "")),
                    domain="wire_proc_table",
                )
            )
            for symbol in wire_proc_symbols:
                if active_wire_proc_checker(symbol):
                    checks.append(
                        check_row(
                            f"wire_proc:{symbol}",
                            "pass",
                            "required Dawn wire proc resolves through wgpuGetProcAddress",
                            symbol=symbol,
                            domain="wire_proc_table",
                        )
                    )
                else:
                    checks.append(
                        check_row(
                            f"wire_proc:{symbol}",
                            "fail",
                            "required Dawn wire proc is missing from wgpuGetProcAddress",
                            symbol=symbol,
                            domain="wire_proc_table",
                        )
                    )

    local_wire_proc_surface = payload.get("localWireProcSurface")
    active_local_proc_checker = local_proc_checker
    if isinstance(local_wire_proc_surface, dict) and local_wire_proc_surface.get("required") is True:
        resolver_source_path_text = str(local_wire_proc_surface.get("resolverSourcePath", ""))
        if active_local_proc_checker is None:
            resolver_source_path = resolve_path(root, resolver_source_path_text)
            if resolver_source_path is None:
                checks.append(
                    check_row(
                        "local_wire_proc_source",
                        "fail",
                        "localWireProcSurface.resolverSourcePath must be repo-relative or absolute without parent traversal",
                        path=resolver_source_path_text,
                    )
                )
            elif not resolver_source_path.is_file():
                checks.append(
                    check_row(
                        "local_wire_proc_source",
                        "fail",
                        "Doe local proc resolver source is missing",
                        path=resolver_source_path_text,
                        resolved_path=str(resolver_source_path),
                    )
                )
            else:
                local_proc_symbols, parse_error = parse_local_proc_symbols(resolver_source_path)
                checks.append(
                    check_row(
                        "local_wire_proc_source",
                        "fail" if parse_error else "pass",
                        parse_error or "Doe local proc resolver source parsed",
                        path=resolver_source_path_text,
                        resolved_path=str(resolver_source_path),
                    )
                )
                if not parse_error:
                    active_local_proc_checker = lambda symbol: symbol in local_proc_symbols
        else:
            checks.append(
                check_row(
                    "local_wire_proc_source",
                    "pass",
                    "Doe local proc resolver source provided by test checker",
                    path=resolver_source_path_text,
                )
            )

        local_required_symbols = local_wire_proc_surface.get("requiredSymbols")
        if isinstance(local_required_symbols, list):
            for row in local_required_symbols:
                if not isinstance(row, dict):
                    continue
                symbol = row.get("symbol")
                domain = row.get("domain")
                if not isinstance(symbol, str) or not isinstance(domain, str):
                    continue
                if active_local_proc_checker is None:
                    checks.append(
                        check_row(
                            f"local_wire_proc:{symbol}",
                            "fail",
                            "required local wire proc could not be checked",
                            symbol=symbol,
                            domain=domain,
                        )
                    )
                    continue
                if active_local_proc_checker(symbol):
                    checks.append(
                        check_row(
                            f"local_wire_proc:{symbol}",
                            "pass",
                            "required browser interop proc has a Doe-local wgpuGetProcAddress mapping",
                            symbol=symbol,
                            domain=domain,
                        )
                    )
                else:
                    checks.append(
                        check_row(
                            f"local_wire_proc:{symbol}",
                            "fail",
                            "required browser interop proc would fall through to native fallback",
                            symbol=symbol,
                            domain=domain,
                        )
                    )

    browser_shared_memory_behavior = payload.get("browserSharedMemoryBehavior")
    if (
        isinstance(browser_shared_memory_behavior, dict)
        and browser_shared_memory_behavior.get("required") is True
    ):
        active_browser_shared_memory_behavior_checker = browser_shared_memory_behavior_checker
        implementation_source_path_text = str(browser_shared_memory_behavior.get("implementationSourcePath", ""))
        if active_browser_shared_memory_behavior_checker is None:
            implementation_source_path = resolve_path(root, implementation_source_path_text)
            if implementation_source_path is None:
                checks.append(
                    check_row(
                        "browser_shared_memory_behavior_source",
                        "fail",
                        "browserSharedMemoryBehavior.implementationSourcePath must be repo-relative or absolute without parent traversal",
                        path=implementation_source_path_text,
                    )
                )
            elif not implementation_source_path.is_file():
                checks.append(
                    check_row(
                        "browser_shared_memory_behavior_source",
                        "fail",
                        "Doe browser shared-memory implementation source is missing",
                        path=implementation_source_path_text,
                        resolved_path=str(implementation_source_path),
                    )
                )
            else:
                checks.append(
                    check_row(
                        "browser_shared_memory_behavior_source",
                        "pass",
                        "Doe browser shared-memory implementation source exists",
                        path=implementation_source_path_text,
                        resolved_path=str(implementation_source_path),
                    )
                )
                active_browser_shared_memory_behavior_checker = lambda: check_browser_shared_memory_behavior_source(
                    implementation_source_path
                )
        else:
            checks.append(
                check_row(
                    "browser_shared_memory_behavior_source",
                    "pass",
                    "Doe browser shared-memory implementation source provided by test checker",
                    path=implementation_source_path_text,
                )
            )

        if active_browser_shared_memory_behavior_checker is None:
            checks.append(
                check_row(
                    "browser_shared_memory_behavior",
                    "fail",
                    "browser shared-memory behavior could not be checked",
                )
            )
        else:
            behavior_ok, behavior_message = active_browser_shared_memory_behavior_checker()
            checks.append(
                check_row(
                    "browser_shared_memory_behavior",
                    "pass" if behavior_ok else "fail",
                    behavior_message,
                )
            )

    instance_bootstrap = payload.get("instanceBootstrap")
    if isinstance(instance_bootstrap, dict) and instance_bootstrap.get("required") is True:
        active_bootstrap_checker = instance_bootstrap_checker
        if active_bootstrap_checker is None and ctypes_library is not None:
            active_bootstrap_checker = lambda: bootstrap_ctypes_instance(ctypes_library)
        if active_bootstrap_checker is None:
            checks.append(
                check_row(
                    "instance_bootstrap",
                    "fail",
                    "Doe WGPU instance bootstrap could not be checked",
                )
            )
        else:
            bootstrap_ok, bootstrap_message = active_bootstrap_checker()
            checks.append(
                check_row(
                    "instance_bootstrap",
                    "pass" if bootstrap_ok else "fail",
                    bootstrap_message,
                )
            )

    missing_required = [
        row["checkId"]
        for row in checks
        if row.get("required") is True and row.get("status") != "pass"
    ]
    return {
        "schemaVersion": 1,
        "artifactKind": "doe_chromium_proc_surface_check",
        "configPath": config_path_text,
        "libraryPath": library_path_text,
        "status": "blocked" if missing_required else "pass",
        "checks": checks,
        "missingRequired": missing_required,
    }


def main() -> int:
    args = parse_args()
    root = Path(args.root).resolve()
    config_path = resolve_path(root, args.config)
    if config_path is None:
        raise SystemExit("config path must be repo-relative or absolute without parent traversal")
    payload = load_json(config_path)
    report = check_proc_surface(
        payload,
        root=root,
        config_path_text=args.config,
        library_override=args.library,
    )
    if args.emit_json:
        print(json.dumps(report, indent=2))
    elif report["status"] == "pass":
        print("PASS: Doe Chromium proc surface is ready")
    else:
        print("BLOCKED: Doe Chromium proc surface is not ready")
        for check_id in report["missingRequired"]:
            print(f"- {check_id}")
    return 1 if args.require_ready and report["status"] != "pass" else 0


if __name__ == "__main__":
    sys.exit(main())
