#!/usr/bin/env python3
"""Bootstrap and build Dawn benchmark binaries for FAWN comparison workflows."""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Iterable


DAWN_REPO_URL = "https://dawn.googlesource.com/dawn"
DEFAULT_BINARY = "dawn_perf_tests"
DEFAULT_TEST_TARGETS = (DEFAULT_BINARY,)
PLATFORM_BUILDTOOLS_DIR = {
    "darwin": "mac",
    "linux": "linux64",
    "linux2": "linux64",
    "win32": "win",
    "cygwin": "win",
}


def parse_dawn_vars(source_dir: Path) -> dict[str, str]:
    deps_path = source_dir / "DEPS"
    if not deps_path.exists():
        raise RuntimeError(f"{deps_path} not found; run from a Dawn checkout")

    deps_text = deps_path.read_text(encoding="utf-8")
    vars_dict: dict[str, str] = {}
    for var in ("chromium_git", "dawn_gn_version"):
        value = parse_deps_value(rf"'{var}'\s*:\s*'([^']+)'", deps_text)
        if value is not None:
            vars_dict[var] = value
    return vars_dict


def run(cmd: list[str], *, cwd: Path | None = None, env: dict[str, str] | None = None) -> None:
    proc = subprocess.run(
        cmd,
        cwd=None if cwd is None else str(cwd),
        env=env,
        text=True,
        capture_output=True,
    )
    if proc.returncode != 0:
        raise RuntimeError(
            f"command failed ({' '.join(cmd)})\n"
            f"cwd={cwd}\n"
            f"stdout={proc.stdout}\n"
            f"stderr={proc.stderr}"
        )


def probe_executable(path: str) -> tuple[bool, str]:
    try:
        proc = subprocess.run(
            [path, "--version"],
            text=True,
            capture_output=True,
            check=False,
        )
    except FileNotFoundError:
        return False, "not-found"
    except OSError as exc:
        return False, str(exc)

    out = f"{proc.stdout}\n{proc.stderr}".strip()
    if proc.returncode != 0:
        if (
            "unable to find gn in your $PATH" in out.lower()
            or "python3_bin_reldir.txt not found" in out
            or "failed to locate python binary" in out.lower()
        ):
            return False, out
        # GN returning non-zero for --version is unusual but possible with wrapper
        # oddities; accept only if it at least printed a recognizable header.
        if out and "gn" not in out.lower():
            return False, out

    return True, out


def depot_tools_dir_for_gn(path: str | None) -> Path | None:
    if not path or "depot_tools" not in path:
        return None

    gn_path = Path(path).resolve()
    depot_tools_dir = gn_path.parent
    if (depot_tools_dir / "ensure_bootstrap").is_file():
        return depot_tools_dir
    return None


def bootstrap_depot_tools_dir(depot_tools_dir: Path) -> None:
    run([str(depot_tools_dir / "ensure_bootstrap")], cwd=depot_tools_dir)


def maybe_bootstrap_depot_tools(path: str, detail: str) -> bool:
    if "depot_tools" not in path:
        return False
    if "unable to find gn in your $path" not in detail.lower():
        return False

    depot_tools_dir = depot_tools_dir_for_gn(path)
    if depot_tools_dir is None:
        return False

    bootstrap_depot_tools_dir(depot_tools_dir)
    return True


def read_json(path: Path) -> dict:
    if not path.exists():
        return {}
    return json.loads(path.read_text(encoding="utf-8"))


def write_json(path: Path, payload: dict[str, object]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")


def check_dependency(name: str) -> str:
    binary = shutil.which(name)
    if not binary:
        raise RuntimeError(f"required dependency missing: {name}")
    return binary


def resolve_dependency(name: str, explicit: str | None, *, hint: str | None = None) -> str:
    if explicit:
        candidate = Path(explicit)
        if not candidate.exists():
            raise RuntimeError(f"explicit {name} path not found: {explicit}")
        return str(candidate.resolve())
    return check_dependency(name) if hint is None else resolve_dependency_with_hint(name, hint)


def resolve_dependency_with_hint(name: str, hint: str) -> str:
    binary = shutil.which(name)
    if binary:
        return binary
    raise RuntimeError(f"required dependency missing: {name}. {hint}")


def parse_deps_value(
    pattern: str,
    deps_text: str,
    default: str | None = None,
    *,
    flags: int = 0,
) -> str | None:
    match = re.search(pattern, deps_text, flags=flags)
    return match.group(1) if match else default


def parse_buildtools_reference(source_dir: Path) -> tuple[str, str]:
    vars_dict = parse_dawn_vars(source_dir)
    chromium_git = vars_dict.get("chromium_git", "https://chromium.googlesource.com")
    deps_text = (source_dir / "DEPS").read_text(encoding="utf-8")
    raw_url = parse_deps_value(
        r"'buildtools':\s*\{.*?'url'\s*:\s*'([^']+)'",
        deps_text,
        flags=re.S,
    )
    if not raw_url or "@" not in raw_url:
        raise RuntimeError("unable to parse buildtools reference from Dawn DEPS")

    url, revision = raw_url.rsplit("@", 1)
    if "{chromium_git}" in url:
        if chromium_git is None:
            raise RuntimeError("unable to expand {chromium_git} from Dawn DEPS")
        url = url.replace("{chromium_git}", chromium_git)
    return url, revision


def parse_gn_package_version(source_dir: Path) -> str:
    vars_dict = parse_dawn_vars(source_dir)
    version = vars_dict.get("dawn_gn_version")
    if not version:
        raise RuntimeError("unable to parse dawn_gn_version from Dawn DEPS")
    return version


def gn_cipd_platform() -> str:
    if sys.platform.startswith("darwin"):
        return "mac-arm64" if os.uname().machine == "arm64" else "mac-amd64"
    if sys.platform.startswith("linux"):
        return "linux-amd64"
    if sys.platform == "win32" or sys.platform == "cygwin":
        return "windows-amd64"
    raise RuntimeError(f"unsupported platform for cipd gn package: {sys.platform}")


def gn_buildtools_path(source_dir: Path) -> Path:
    platform_key = sys.platform.lower()
    platform_dir = PLATFORM_BUILDTOOLS_DIR.get(platform_key)
    if not platform_dir and platform_key.startswith("linux"):
        platform_dir = "linux64"
    if not platform_dir and platform_key.startswith("darwin"):
        platform_dir = "mac"
    if not platform_dir:
        raise RuntimeError(f"unsupported platform for GN buildtools path: {sys.platform}")
    buildtools_platform_dir = source_dir / "buildtools" / platform_dir
    flat = buildtools_platform_dir / "gn"
    nested = buildtools_platform_dir / "gn" / "gn"
    if flat.is_file():
        return flat
    if nested.is_file():
        return nested
    return nested


def bootstrap_dawn_buildtools(source_dir: Path) -> None:
    gn_path = gn_buildtools_path(source_dir)
    if gn_path.exists():
        return

    git_exe = check_dependency("git")
    buildtools_url, revision = parse_buildtools_reference(source_dir)
    buildtools_dir = source_dir / "buildtools"
    if buildtools_dir.exists():
        if not (buildtools_dir / ".git").is_dir():
            if any(buildtools_dir.iterdir()):
                raise RuntimeError(
                    f"{buildtools_dir} exists but is not a git checkout. "
                    "Remove it and rerun bootstrap."
                )
            shutil.rmtree(buildtools_dir)
        else:
            run([git_exe, "-C", str(buildtools_dir), "fetch", "origin", revision, "--depth", "1"])
            run([git_exe, "-C", str(buildtools_dir), "checkout", revision])
            return

    run([git_exe, "clone", "--depth", "1", buildtools_url, str(buildtools_dir)])
    run([git_exe, "-C", str(buildtools_dir), "fetch", "origin", revision, "--depth", "1"])
    run([git_exe, "-C", str(buildtools_dir), "checkout", revision])


def install_gn_from_cipd(source_dir: Path, cipd_path: str | None = None) -> None:
    gn_path = gn_buildtools_path(source_dir)
    if gn_path.exists():
        return

    cipd = cipd_path or shutil.which("cipd")
    if not cipd:
        return

    gn_version = parse_gn_package_version(source_dir)
    package = f"gn/gn/{gn_cipd_platform()}"
    root = gn_path.parent
    run([cipd, "install", package, gn_version, "-root", str(root)])

    if gn_path.exists():
        return

    # Some package shapes install into a nested `bin/` directory.
    candidate = root / "bin" / "gn"
    if candidate.exists():
        candidate.rename(gn_path)
        return

    # As a last resort, look for any gn binary directly below the package root.
    matches = sorted(
        p for p in root.rglob("gn") if p.is_file() and os.access(p, os.X_OK)
    )
    if matches:
        matches[0].rename(gn_path)
        return

    raise RuntimeError(
        f"gn package install completed, but binary is missing under {root}. "
        "Check CIPD package contents."
    )


def resolve_gn_binary(gn_path: str | None, *, fallback_to_depot: bool = True) -> str:
    # Keep explicit path authoritative, but if it is the uninitialized depot_tools wrapper,
    # keep walking candidates to find a valid standalone/installed gn.
    checked = []

    if gn_path:
        checked.append((gn_path, "explicit"))

    for entry in os.get_exec_path():
        gn_candidate = Path(entry) / "gn"
        if gn_candidate.exists():
            checked.append((str(gn_candidate), f"path:{entry}"))

    depot_candidates: list[tuple[str, str]] = []
    standalone_candidates: list[tuple[str, str]] = []
    for candidate, source in checked:
        if "depot_tools" in candidate:
            depot_candidates.append((candidate, source))
        else:
            standalone_candidates.append((candidate, source))

    ordered: list[tuple[str, str]] = []
    ordered.extend(standalone_candidates)
    ordered.extend(depot_candidates if fallback_to_depot else [])

    failures: list[str] = []
    for candidate, source in ordered:
        ok, detail = probe_executable(candidate)
        if ok and Path(candidate).exists():
            return str(Path(candidate).resolve())
        if maybe_bootstrap_depot_tools(candidate, detail):
            ok, detail = probe_executable(candidate)
            if ok and Path(candidate).exists():
                return str(Path(candidate).resolve())
        failures.append(f"{candidate} ({source}): {detail}")

    if ordered and not fallback_to_depot and gn_path:
        raise RuntimeError(
            "explicit gn is present but unusable:\n" + "\n".join(failures)
        )

    raise RuntimeError(
        "required dependency missing: gn. "
        "install a working standalone gn (brew/apt) or initialize depot_tools with python3 bootstrap."
        + ("" if not failures else f" Checked candidates:\n{chr(10).join(failures)}")
    )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Clone/update and build Dawn benchmark binaries for FAWN comparisons."
    )
    parser.add_argument("--repo-url", default=DAWN_REPO_URL)
    parser.add_argument(
        "--source-dir",
        default="bench/vendor/dawn",
        help="Where to place the Dawn git checkout.",
    )
    parser.add_argument(
        "--build-dir",
        default="bench/vendor/dawn/out/Release",
        help="Build directory used by the selected build-system.",
    )
    parser.add_argument(
        "--branch",
        default="main",
        help="Branch or commit to check out.",
    )
    parser.add_argument(
        "--targets",
        nargs="+",
        default=list(DEFAULT_TEST_TARGETS),
        help="Build target(s) to build. Default: dawn_perf_tests",
    )
    parser.add_argument(
        "--build-system",
        choices=["cmake", "gn"],
        default="gn",
        help="Build system backend for Dawn bootstrap.",
    )
    parser.add_argument(
        "--parallel",
        type=int,
        default=os.cpu_count() or 4,
        help="Build parallelism for cmake --build.",
    )
    parser.add_argument(
        "--generator",
        default=None,
        help="Optional CMake generator override (e.g. Ninja).",
    )
    parser.add_argument(
        "--gn-args",
        default="is_debug=false",
        help="Optional GN --args string when using --build-system gn.",
    )
    parser.add_argument(
        "--gn-bin",
        default=None,
        help="Path to gn executable when not on PATH.",
    )
    parser.add_argument(
        "--ninja-bin",
        default=None,
        help="Path to ninja/autoninja executable when not on PATH.",
    )
    parser.add_argument(
        "--skip-gn-bootstrap",
        action="store_true",
        help="Skip fetching Dawn buildtools/gn before GN configure.",
    )
    parser.add_argument(
        "--skip-fetch",
        action="store_true",
        help="Do not fetch/update the Dawn repository.",
    )
    parser.add_argument(
        "--sync-deps",
        action="store_true",
        help="Run Dawn gclient sync before configuring the build.",
    )
    parser.add_argument(
        "--gclient-bin",
        default=None,
        help="Path to gclient when not on PATH.",
    )
    parser.add_argument(
        "--init-existing-source-dir",
        action="store_true",
        help=(
            "Initialize --source-dir as a Dawn checkout when it already exists "
            "without .git. Existing ignored build outputs are preserved."
        ),
    )
    parser.add_argument(
        "--fetch-depth",
        type=int,
        default=0,
        help="Optional shallow fetch/clone depth. Use 0 for a full checkout.",
    )
    parser.add_argument(
        "--skip-build",
        action="store_true",
        help="Skip build after configure.",
    )
    parser.add_argument(
        "--clean-build",
        action="store_true",
        help="Delete build directory before reconfiguring.",
    )
    parser.add_argument(
        "--build-type",
        default="Release",
        help="CMake build type (Release, Debug).",
    )
    parser.add_argument(
        "--output-state",
        default="bench/fixtures/dawn_runtime_state.json",
        help="Output path for build metadata.",
    )
    parser.add_argument(
        "--manifest-only",
        action="store_true",
        help="Emit metadata only when cached binaries are present.",
    )
    return parser.parse_args()


def clone_repo(
    git_exe: str,
    source_dir: Path,
    repo_url: str,
    branch: str,
    fetch_depth: int,
) -> None:
    cmd = [git_exe, "clone"]
    if fetch_depth > 0:
        cmd.extend(["--depth", str(fetch_depth), "--branch", branch])
    cmd.extend([repo_url, str(source_dir)])
    run(cmd)
    run([git_exe, "checkout", branch], cwd=source_dir)


def init_existing_repo(
    git_exe: str,
    source_dir: Path,
    repo_url: str,
    branch: str,
    fetch_depth: int,
) -> None:
    run([git_exe, "init"], cwd=source_dir)
    run([git_exe, "remote", "add", "origin", repo_url], cwd=source_dir)
    fetch_cmd = [git_exe, "fetch", "origin", branch]
    if fetch_depth > 0:
        fetch_cmd.extend(["--depth", str(fetch_depth)])
    run(fetch_cmd, cwd=source_dir)
    run([git_exe, "checkout", "-B", branch, "FETCH_HEAD"], cwd=source_dir)


def ensure_repo(
    source_dir: Path,
    repo_url: str,
    branch: str,
    skip_fetch: bool,
    *,
    init_existing_source_dir: bool = False,
    fetch_depth: int = 0,
) -> None:
    git_exe = check_dependency("git")
    if fetch_depth < 0:
        raise ValueError("--fetch-depth must be non-negative")

    if not source_dir.exists():
        clone_repo(git_exe, source_dir, repo_url, branch, fetch_depth)
        return

    if not (source_dir / ".git").exists():
        if not init_existing_source_dir:
            raise RuntimeError(
                f"{source_dir} exists but is not a git repo; pass "
                "--init-existing-source-dir to preserve ignored build outputs "
                "and initialize it as the Dawn checkout"
            )
        init_existing_repo(git_exe, source_dir, repo_url, branch, fetch_depth)
        return

    if skip_fetch:
        return

    if fetch_depth > 0:
        run(
            [git_exe, "fetch", "origin", branch, "--depth", str(fetch_depth)],
            cwd=source_dir,
        )
    else:
        run([git_exe, "fetch", "--all"], cwd=source_dir)
    run([git_exe, "checkout", branch], cwd=source_dir)
    pull_cmd = [git_exe, "pull", "origin", branch]
    if fetch_depth > 0:
        pull_cmd.insert(2, "--ff-only")
    run(pull_cmd, cwd=source_dir)


def resolve_gclient_binary(
    gclient_path: str | None,
    depot_tools_dir: Path | None,
) -> str:
    if gclient_path:
        candidate = Path(gclient_path)
        if not candidate.exists():
            raise RuntimeError(f"explicit gclient path not found: {gclient_path}")
        return str(candidate.resolve())
    if depot_tools_dir is not None:
        candidate = depot_tools_dir / "gclient"
        if candidate.exists():
            return str(candidate)
    return resolve_dependency_with_hint(
        "gclient",
        hint="Install depot_tools or pass --gclient-bin.",
    )


def repair_originless_dependency_remotes(source_dir: Path) -> list[Path]:
    """Make Dawn's lightweight dependency checkouts consumable by gclient."""
    repaired: list[Path] = []
    git_exe = check_dependency("git")
    for git_dir in sorted(path for path in source_dir.rglob(".git") if path.is_dir()):
        checkout = git_dir.parent
        remote = subprocess.run(
            [git_exe, "-C", str(checkout), "remote", "get-url", "origin"],
            text=True,
            capture_output=True,
            check=False,
        )
        if remote.returncode == 0:
            continue

        fetch_head = git_dir / "FETCH_HEAD"
        if not fetch_head.is_file():
            continue
        first_line = fetch_head.read_text(encoding="utf-8").splitlines()[0]
        separator = " of "
        if separator not in first_line:
            continue
        origin_url = first_line.rpartition(separator)[2].strip()
        if not origin_url:
            continue
        run([git_exe, "-C", str(checkout), "remote", "add", "origin", origin_url])
        repaired.append(checkout)
    return repaired


def sync_dawn_deps(
    source_dir: Path,
    gclient_path: str | None,
    depot_tools_dir: Path | None,
    *,
    no_history: bool,
) -> None:
    gclient_file = source_dir / ".gclient"
    if not gclient_file.exists():
        template = source_dir / "scripts" / "standalone.gclient"
        if not template.is_file():
            raise FileNotFoundError(
                f"standalone gclient template not found: {template}"
            )
        gclient_file.write_text(template.read_text(encoding="utf-8"), encoding="utf-8")

    repaired = repair_originless_dependency_remotes(source_dir)
    for checkout in repaired:
        print(f"info: restored origin remote for {checkout.relative_to(source_dir)}")

    gclient = resolve_gclient_binary(gclient_path, depot_tools_dir)
    env = os.environ.copy()
    if depot_tools_dir is not None:
        env["DEPOT_TOOLS_DIR"] = str(depot_tools_dir)
        env["PATH"] = f"{depot_tools_dir}{os.pathsep}{env.get('PATH', '')}"

    cmd = [gclient, "sync"]
    if no_history:
        cmd.append("--no-history")
    run(cmd, cwd=source_dir, env=env)


def configure_build(
    source_dir: Path,
    build_dir: Path,
    build_type: str,
    generator: str | None,
    cmake_defs: Iterable[tuple[str, str]] | None = None,
) -> None:
    cmake = check_dependency("cmake")
    if not build_dir.exists():
        build_dir.mkdir(parents=True, exist_ok=True)

    args = [
        cmake,
        "-S",
        str(source_dir),
        "-B",
        str(build_dir),
        f"-DCMAKE_BUILD_TYPE={build_type}",
        "-DDAWN_FETCH_DEPENDENCIES=ON",
        "-DDAWN_BUILD_TESTS=ON",
    ]
    if generator:
        args.extend(["-G", generator])

    if cmake_defs:
        for key, value in cmake_defs:
            args.append(f"-D{key}={value}")

    run(args)


def build_targets_cmake(build_dir: Path, targets: list[str], parallel: int) -> None:
    cmake = check_dependency("cmake")
    run([cmake, "--build", str(build_dir), "--parallel", str(parallel), "--target", *targets])


def normalize_gn_args(raw_args: str, build_type: str) -> str:
    if re.search(r"\bis_debug\s*=", raw_args):
        return raw_args
    requested_debug = "false" if build_type.lower() == "release" else "true"
    if raw_args:
        return f"{raw_args} is_debug={requested_debug}"
    return f"is_debug={requested_debug}"


def configure_build_gn(
    source_dir: Path,
    build_dir: Path,
    build_type: str,
    gn_args: str,
    gn_path: str | None,
    skip_gn_bootstrap: bool,
) -> None:
    build_config = source_dir / "build" / "config" / "BUILDCONFIG.gn"
    if not build_config.is_file():
        raise RuntimeError(
            f"required Dawn GN dependency missing: {build_config}. "
            "Run this bootstrap with --sync-deps and a working gclient binary. "
            "Dawn's tools/fetch_dawn_dependencies.py only fetches the embedder "
            "dependency subset and does not populate Chromium's GN build tree."
        )

    depot_tools_dir = depot_tools_dir_for_gn(gn_path)
    cipd_path = None
    if depot_tools_dir is not None:
        bootstrap_depot_tools_dir(depot_tools_dir)
        depot_cipd = depot_tools_dir / "cipd"
        if depot_cipd.is_file():
            cipd_path = str(depot_cipd)

    if not skip_gn_bootstrap:
        bootstrap_dawn_buildtools(source_dir)
        install_gn_from_cipd(source_dir, cipd_path)

    buildtools_gn = gn_buildtools_path(source_dir)
    preferred_path = buildtools_gn if buildtools_gn.exists() else None

    if gn_path:
        gn = resolve_gn_binary(gn_path, fallback_to_depot=not skip_gn_bootstrap)
        if "depot_tools" in gn and not skip_gn_bootstrap:
            # We can still proceed if this is only source, but capture and report quickly if it fails.
            pass
    elif preferred_path and preferred_path.exists():
        gn = preferred_path.as_posix()
    else:
        gn = resolve_gn_binary(None)
        if skip_gn_bootstrap:
            raise RuntimeError(
                "gn executable was not found in Dawn checkout. "
                "Pass --skip-gn-bootstrap only when --gn-bin points to a valid standalone gn."
            )

    if not Path(gn).exists():
        raise RuntimeError(f"unable to resolve gn executable: {gn}")

    try:
        run([gn, "gen", str(build_dir), f"--args={normalize_gn_args(gn_args, build_type)}"], cwd=source_dir)
    except RuntimeError as exc:
        message = str(exc)
        if "Unable to find gn in your $PATH" in message and "depot_tools" in Path(gn).as_posix():
            if not skip_gn_bootstrap:
                install_gn_from_cipd(source_dir)
                if preferred_path and preferred_path.as_posix() != gn and preferred_path.exists():
                    run(
                        [
                            preferred_path.as_posix(),
                            "gen",
                            str(build_dir),
                            f"--args={normalize_gn_args(gn_args, build_type)}",
                        ],
                        cwd=source_dir,
                    )
                    return
            raise RuntimeError(
                f"{message}\n"
                "depot_tools gn is not initialized. Run: cd ~/depot_tools && ./ensure_bootstrap "
                "or avoid --gn-bin/depot_tools and install standalone gn."
            ) from exc
        if "Could not find gn executable at:" in message and not skip_gn_bootstrap:
            raise RuntimeError(
                f"{message}\n"
                "Buildtools bootstrap may have failed. Re-run with --skip-gn-bootstrap "
                "and --gn-bin pointing to a standalone gn, or run again after network fetch completes."
            ) from exc
        raise


def resolve_ninja(ninja_path: str | None) -> str:
    if ninja_path:
        candidate = Path(ninja_path)
        if not candidate.exists():
            raise RuntimeError(f"explicit ninja path not found: {ninja_path}")
        return str(candidate)
    if auto := shutil.which("autoninja"):
        return auto
    return resolve_dependency_with_hint(
        "ninja",
        hint="Install ninja (for GN builds) or set --ninja-bin.",
    )


def build_targets_gn(build_dir: Path, targets: list[str], parallel: int, ninja_path: str | None) -> None:
    ninja = resolve_ninja(ninja_path)
    cmd = [ninja, "-C", str(build_dir)]
    if Path(ninja).name == "ninja":
        cmd.extend(["-j", str(parallel)])
    cmd.extend(targets)
    run(cmd)


def find_binaries(build_dir: Path, targets: Iterable[str]) -> dict[str, str]:
    binaries: dict[str, str] = {}
    for target in targets:
        candidates = [build_dir / target]
        if target == "webgpu_dawn_shared":
            if os.name == "nt":
                candidates.append(build_dir / "webgpu_dawn.dll")
            elif sys.platform == "darwin":
                candidates.append(build_dir / "libwebgpu_dawn.dylib")
            else:
                candidates.append(build_dir / "libwebgpu_dawn.so")
        elif os.name == "nt":
            candidates.append((build_dir / target).with_suffix(".exe"))

        for candidate in candidates:
            if candidate.exists():
                binaries[target] = str(candidate)
                break
        else:
            expected = ", ".join(str(candidate) for candidate in candidates)
            raise FileNotFoundError(f"build target output not found; checked: {expected}")
    return binaries


def expanded_gn_targets(requested_targets: list[str]) -> list[str]:
    targets = list(dict.fromkeys(requested_targets))
    if sys.platform == "darwin" and "dawn_perf_tests" in targets and "webgpu_dawn_shared" not in targets:
        targets.append("webgpu_dawn_shared")
    return targets


def main() -> int:
    args = parse_args()
    source_dir = Path(args.source_dir).resolve()
    build_dir = Path(args.build_dir).resolve()
    out_state = Path(args.output_state).resolve()

    if (
        not args.manifest_only
        and not args.skip_build
        and args.build_system == "cmake"
        and "dawn_perf_tests" in args.targets
    ):
        raise RuntimeError(
            "dawn_perf_tests is not exposed as a CMake target here. Use --build-system gn with --build-type Release."
        )

    if not args.manifest_only and not args.skip_build:
        if args.clean_build and build_dir.exists():
            for child in build_dir.iterdir():
                if child.is_dir():
                    shutil.rmtree(child)
                else:
                    child.unlink()

        ensure_repo(
            source_dir,
            args.repo_url,
            args.branch,
            args.skip_fetch,
            init_existing_source_dir=args.init_existing_source_dir,
            fetch_depth=args.fetch_depth,
        )
        depot_tools_dir = depot_tools_dir_for_gn(args.gn_bin)
        if args.sync_deps:
            if depot_tools_dir is not None:
                bootstrap_depot_tools_dir(depot_tools_dir)
            sync_dawn_deps(
                source_dir,
                args.gclient_bin,
                depot_tools_dir,
                no_history=args.fetch_depth > 0,
            )
        if args.build_system == "cmake":
            configure_build(source_dir, build_dir, args.build_type, args.generator)
            build_targets_cmake(build_dir, args.targets, args.parallel)
        else:
            gn_targets = expanded_gn_targets(args.targets)
            if gn_targets != args.targets:
                print(
                    "info: adding GN target webgpu_dawn_shared for macOS native runtime library loading"
                )
            configure_build_gn(
                source_dir,
                build_dir,
                args.build_type,
                args.gn_args,
                args.gn_bin,
                args.skip_gn_bootstrap,
            )
            build_targets_gn(build_dir, gn_targets, args.parallel, args.ninja_bin)
    elif args.manifest_only and not build_dir.exists():
        raise RuntimeError("manifest-only requested but build directory does not exist")

    binaries = {}
    for target in args.targets:
        binaries[target] = str(find_binaries(build_dir, [target])[target])

    manifest = {
        "repo": str(source_dir),
        "buildDir": str(build_dir),
        "branch": args.branch,
        "buildType": args.build_type,
        "buildSystem": args.build_system,
        "generator": args.generator,
        "gnArgs": args.gn_args if args.build_system == "gn" else "",
        "binaries": binaries,
    }
    write_json(out_state, manifest)

    print(json.dumps(manifest, indent=2))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        raise SystemExit(1)
