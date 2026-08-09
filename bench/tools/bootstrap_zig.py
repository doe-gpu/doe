#!/usr/bin/env python3
"""Install the schema-pinned Zig toolchain into Doe's ignored tooling cache."""

from __future__ import annotations

import argparse
import hashlib
import json
import platform
import subprocess
import sys
import tarfile
import tempfile
import urllib.request
from pathlib import Path
from typing import Any


REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_CONFIG = REPO_ROOT / "config" / "toolchains.json"


def host_platform_key() -> str:
    machine = platform.machine().lower()
    architectures = {
        "amd64": "x86_64",
        "x86_64": "x86_64",
        "aarch64": "aarch64",
        "arm64": "aarch64",
    }
    systems = {
        "linux": "linux",
        "darwin": "macos",
        "win32": "windows",
    }
    architecture = architectures.get(machine)
    system = systems.get(sys.platform)
    if architecture is None or system is None:
        raise ValueError(f"unsupported Zig bootstrap host: {machine}-{sys.platform}")
    return f"{architecture}-{system}"


def load_contract(config_path: Path, platform_key: str) -> tuple[str, dict[str, Any]]:
    payload = json.loads(config_path.read_text(encoding="utf-8"))
    zig = payload["toolchains"]["zig"]
    version = zig["version"]
    archive = zig.get("archives", {}).get(platform_key)
    if archive is None:
        raise ValueError(
            f"config/toolchains.json has no Zig archive for {platform_key}"
        )
    return version, archive


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def download_archive(url: str, destination: Path) -> None:
    request = urllib.request.Request(url, headers={"User-Agent": "doe-zig-bootstrap/1"})
    with urllib.request.urlopen(request) as response, destination.open("wb") as output:
        while chunk := response.read(1024 * 1024):
            output.write(chunk)


def verify_archive(path: Path, contract: dict[str, Any]) -> None:
    actual_size = path.stat().st_size
    if actual_size != contract["sizeBytes"]:
        raise ValueError(
            f"Zig archive size mismatch: expected {contract['sizeBytes']}, "
            f"received {actual_size}"
        )
    actual_sha256 = sha256_file(path)
    if actual_sha256 != contract["sha256"]:
        raise ValueError(
            f"Zig archive hash mismatch: expected {contract['sha256']}, "
            f"received {actual_sha256}"
        )


def extract_archive(archive_path: Path, destination: Path) -> Path:
    with tarfile.open(archive_path, mode="r:xz") as archive:
        members = archive.getmembers()
        roots = {
            Path(member.name).parts[0]
            for member in members
            if member.name and Path(member.name).parts
        }
        if len(roots) != 1:
            raise ValueError(f"Zig archive must have one root directory, found {sorted(roots)}")
        archive.extractall(destination, filter="data")
    extracted_root = destination / next(iter(roots))
    if not extracted_root.is_dir():
        raise ValueError(f"Zig archive root is missing: {extracted_root}")
    return extracted_root


def installed_version(zig_path: Path) -> str:
    result = subprocess.run(
        [str(zig_path), "version"],
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        raise ValueError(f"installed Zig failed version probe: {result.stderr.strip()}")
    return result.stdout.strip()


def install(config_path: Path, platform_key: str, install_dir: Path) -> dict[str, Any]:
    version, archive_contract = load_contract(config_path, platform_key)
    zig_name = "zig.exe" if platform_key.endswith("-windows") else "zig"
    zig_path = install_dir / zig_name
    if install_dir.exists():
        if not zig_path.is_file():
            raise ValueError(
                f"existing Zig install is incomplete; move it aside before retrying: {install_dir}"
            )
        actual_version = installed_version(zig_path)
        if actual_version != version:
            raise ValueError(
                f"existing Zig version mismatch: expected {version}, received {actual_version}"
            )
        return {
            "status": "already-installed",
            "platform": platform_key,
            "version": version,
            "zigPath": str(zig_path),
            "archive": archive_contract,
        }

    install_dir.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(
        prefix="zig-bootstrap-",
        dir=install_dir.parent,
    ) as temporary:
        temporary_dir = Path(temporary)
        archive_path = temporary_dir / "zig.tar.xz"
        download_archive(archive_contract["url"], archive_path)
        verify_archive(archive_path, archive_contract)
        extracted_root = extract_archive(archive_path, temporary_dir / "extract")
        extracted_root.replace(install_dir)

    actual_version = installed_version(zig_path)
    if actual_version != version:
        raise ValueError(
            f"installed Zig version mismatch: expected {version}, received {actual_version}"
        )
    return {
        "status": "installed",
        "platform": platform_key,
        "version": version,
        "zigPath": str(zig_path),
        "archive": archive_contract,
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, default=DEFAULT_CONFIG)
    parser.add_argument("--platform", default=host_platform_key())
    parser.add_argument("--install-dir", type=Path)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        version, _ = load_contract(args.config, args.platform)
        install_dir = args.install_dir or REPO_ROOT / ".tooling" / f"zig-{version}"
        result = install(args.config, args.platform, install_dir.resolve())
    except (KeyError, OSError, ValueError, tarfile.TarError) as error:
        print(f"Zig bootstrap failed: {error}", file=sys.stderr)
        return 1
    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
