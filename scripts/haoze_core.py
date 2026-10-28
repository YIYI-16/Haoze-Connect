#!/usr/bin/env python3
"""Read, download, verify and extract the pinned Hiddify native core.

The build must never consume the stale ``core.version`` from
``dependencies.properties`` or whatever the ``draft`` release currently points
at. ``hiddify-core.lock.json`` is the single source of truth: exact asset URL,
SHA256 and release-API timestamp per platform. A digest mismatch is a hard
error and is never repaired automatically -- re-verify the upstream release
(e.g. through the GitHub release API) and update the lock deliberately.

Cross-platform and stdlib-only (runs on Linux, macOS and Windows with Python 3).

Usage:
    python3 scripts/haoze_core.py show
    python3 scripts/haoze_core.py fetch --platform android
    python3 scripts/haoze_core.py fetch --platform windows --cache DIR
    python3 scripts/haoze_core.py verify --platform android --archive PATH

Extraction is always into the path from the lock (or ``--dest``) and validates
tar member paths first: absolute paths, ``..`` components, symlinks, hardlinks,
devices and FIFOs are rejected. Files are written by this process, so no tar
owner/group metadata is preserved. Downloaded Windows binaries are never
executed by this script.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import sys
import tarfile
import tempfile
import urllib.request
from pathlib import Path, PurePosixPath

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_LOCK = ROOT / "hiddify-core.lock.json"
PLATFORMS = ("android", "windows")
CHUNK = 1024 * 1024
CORE_RELEASE_PREFIX = (
    "https://github.com/hiddify/hiddify-core/releases/download/draft/"
)
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
COMMIT_RE = re.compile(r"^[0-9a-f]{40}$")
TIMESTAMP_RE = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$")


class CoreLockError(RuntimeError):
    """Invalid lock data, unsafe archive or digest mismatch."""


def _require(condition: bool, message: str) -> None:
    if not condition:
        raise CoreLockError(message)


def load_lock(path: Path = DEFAULT_LOCK) -> dict:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError as exc:
        raise CoreLockError(f"lock file not found: {path}") from exc
    except json.JSONDecodeError as exc:
        raise CoreLockError(f"invalid JSON in {path}: {exc}") from exc

    _require(data.get("schema") == 1, "unsupported lock schema (expected 1)")
    app = data.get("app") or {}
    core = data.get("core") or {}
    _require(
        isinstance(app.get("commit"), str) and COMMIT_RE.fullmatch(app["commit"]),
        "lock app.commit must be a 40-char lowercase git SHA",
    )
    _require(
        isinstance(core.get("gitlink"), str)
        and COMMIT_RE.fullmatch(core["gitlink"]),
        "lock core.gitlink must be a 40-char lowercase git SHA",
    )
    _require(
        core.get("release_channel") == "draft",
        "lock core.release_channel must be 'draft' (stable v4.1.0 is incompatible)",
    )

    assets = data.get("assets") or {}
    for platform in PLATFORMS:
        asset = assets.get(platform)
        _require(isinstance(asset, dict), f"lock assets.{platform} missing")
        url = asset.get("url")
        _require(
            isinstance(url, str) and url.startswith(CORE_RELEASE_PREFIX),
            f"assets.{platform}.url must be under {CORE_RELEASE_PREFIX}",
        )
        archive = url.rsplit("/", 1)[-1]
        _require(
            asset.get("archive") == archive,
            f"assets.{platform}.archive must match the URL filename ({archive})",
        )
        sha = asset.get("sha256")
        _require(
            isinstance(sha, str) and SHA256_RE.fullmatch(sha) is not None,
            f"assets.{platform}.sha256 must be 64 lowercase hex chars",
        )
        updated = asset.get("asset_updated_at")
        _require(
            isinstance(updated, str) and TIMESTAMP_RE.fullmatch(updated) is not None,
            f"assets.{platform}.asset_updated_at must be an ISO-8601 UTC timestamp",
        )
        extract_to = asset.get("extract_to")
        _require(
            isinstance(extract_to, str) and _safe_relative_parts(extract_to) is not None,
            f"assets.{platform}.extract_to must be a safe relative path",
        )
        required = asset.get("required")
        _require(
            isinstance(required, list) and required,
            f"assets.{platform}.required must be a non-empty list",
        )
        for name in required:
            _require(
                isinstance(name, str) and _safe_relative_parts(name) is not None,
                f"assets.{platform}.required contains an unsafe path: {name!r}",
            )
    return data


def _safe_relative_parts(name: str) -> tuple[str, ...] | None:
    if not name or "\\" in name or "\x00" in name:
        return None
    path = PurePosixPath(name)
    if path.is_absolute():
        return None
    parts = path.parts
    if not parts or any(part in ("", ".", "..") for part in parts):
        return None
    return parts


def asset_for(lock: dict, platform: str) -> dict:
    _require(platform in PLATFORMS, f"unknown platform: {platform}")
    return lock["assets"][platform]


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(CHUNK), b""):
            digest.update(chunk)
    return digest.hexdigest()


def cache_filename(platform: str, sha256: str) -> str:
    # Matches the independently downloaded verification copies, e.g.
    # hiddify-core-draft-android-7ea92f0c.tar.gz
    return f"hiddify-core-draft-{platform}-{sha256[:8]}.tar.gz"


def download(url: str, target: Path) -> None:
    target.parent.mkdir(parents=True, exist_ok=True)
    partial = target.with_name(target.name + ".part")
    print(f"downloading {url}")
    request = urllib.request.Request(
        url,
        headers={"User-Agent": "haoze-core-fetch/1 (+hash-pinned build)"},
    )
    try:
        with urllib.request.urlopen(request, timeout=120) as response:
            with partial.open("wb") as handle:
                shutil.copyfileobj(response, handle, CHUNK)
        os.replace(partial, target)
    except BaseException:
        partial.unlink(missing_ok=True)
        raise


def resolve_archive(
    lock: dict, platform: str, asset: dict, archive: Path | None, cache: Path | None, temp_dir: Path
) -> Path:
    if archive is not None:
        path = archive.expanduser()
        _require(path.is_file(), f"archive not found: {path}")
        return path
    if cache is not None:
        path = cache.expanduser() / cache_filename(platform, asset["sha256"])
        if not path.is_file():
            download(asset["url"], path)
        return path
    path = temp_dir / asset["archive"]
    download(asset["url"], path)
    return path


def verify_digest(path: Path, asset: dict, platform: str) -> None:
    actual = sha256_file(path)
    expected = asset["sha256"]
    if actual != expected:
        raise CoreLockError(
            f"{platform} core archive digest mismatch: expected {expected}, got {actual}.\n"
            "The draft asset has drifted or the download is corrupt. Refusing to use it; "
            "re-verify the upstream release API and update hiddify-core.lock.json manually. "
            "New hashes are never trusted automatically."
        )
    print(
        f"verified {platform} sha256={actual} "
        f"asset_updated_at={asset['asset_updated_at']}"
    )


def archive_members(archive: Path) -> list[tuple[tarfile.TarInfo, tuple[str, ...]]]:
    members: list[tuple[tarfile.TarInfo, tuple[str, ...]]] = []
    try:
        with tarfile.open(archive, "r:gz") as tar:
            for member in tar.getmembers():
                parts = _safe_relative_parts(member.name)
                if parts is None:
                    raise CoreLockError(
                        f"unsafe tar member path rejected: {member.name!r}"
                    )
                if member.isdir():
                    continue
                if not member.isfile():
                    raise CoreLockError(
                        f"unsafe tar member type rejected: {member.name!r} "
                        "(only regular files and directories are allowed)"
                    )
                members.append((member, parts))
    except tarfile.TarError as exc:
        raise CoreLockError(f"cannot read tar archive {archive}: {exc}") from exc
    _require(bool(members), f"archive contains no regular files: {archive}")
    return members


def check_required(members: list[tuple[tarfile.TarInfo, tuple[str, ...]]], asset: dict) -> None:
    present = {"/".join(parts) for _, parts in members}
    missing = [name for name in asset["required"] if name not in present]
    _require(not missing, f"archive is missing required files: {', '.join(missing)}")


def extract_archive(archive: Path, dest: Path, asset: dict) -> None:
    members = archive_members(archive)
    check_required(members, asset)

    staging = Path(tempfile.mkdtemp(prefix="haoze-core-extract-"))
    try:
        with tarfile.open(archive, "r:gz") as tar:
            for member, parts in members:
                source = tar.extractfile(member)
                if source is None:
                    raise CoreLockError(f"cannot read tar member: {member.name!r}")
                target = staging.joinpath(*parts)
                target.parent.mkdir(parents=True, exist_ok=True)
                with source, target.open("wb") as output:
                    shutil.copyfileobj(source, output, CHUNK)
                # Keep the executable bit where the archive set it, but the
                # file is created by this process: no tar owner/group is kept.
                os.chmod(target, (member.mode & 0o777) or 0o644)
        dest.mkdir(parents=True, exist_ok=True)
        shutil.copytree(staging, dest, dirs_exist_ok=True, copy_function=shutil.copy2)
    finally:
        shutil.rmtree(staging, ignore_errors=True)

    for name in asset["required"]:
        _require((dest / PurePosixPath(name)).is_file(), f"missing after extraction: {dest / name}")
    print(f"extracted {archive.name} -> {dest}")


def cmd_show(lock: dict) -> None:
    print(f"app commit:  {lock['app']['commit']}")
    print(f"core gitlink: {lock['core']['gitlink']}")
    print(f"core channel:{lock['core']['release_channel']}")
    for platform in PLATFORMS:
        asset = lock["assets"][platform]
        print(
            f"{platform}: {asset['url']}\n"
            f"  sha256 {asset['sha256']} (asset updated {asset['asset_updated_at']})\n"
            f"  extract_to {asset['extract_to']} required {', '.join(asset['required'])}"
        )


def cmd_fetch(lock: dict, platform: str, args: argparse.Namespace) -> None:
    asset = asset_for(lock, platform)
    with tempfile.TemporaryDirectory(prefix="haoze-core-download-") as temp:
        archive = resolve_archive(lock, platform, asset, args.archive, args.cache, Path(temp))
        verify_digest(archive, asset, platform)
        dest = args.dest.expanduser() if args.dest else ROOT / asset["extract_to"]
        extract_archive(archive, dest, asset)


def cmd_verify(lock: dict, platform: str, args: argparse.Namespace) -> None:
    asset = asset_for(lock, platform)
    with tempfile.TemporaryDirectory(prefix="haoze-core-download-") as temp:
        archive = resolve_archive(lock, platform, asset, args.archive, args.cache, Path(temp))
        verify_digest(archive, asset, platform)
        members = archive_members(archive)
        check_required(members, asset)
        print(f"archive structure OK ({len(members)} files, required entries present)")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("command", choices=("show", "fetch", "verify"))
    parser.add_argument("--platform", choices=PLATFORMS)
    parser.add_argument("--lock", type=Path, default=DEFAULT_LOCK)
    parser.add_argument("--archive", type=Path, help="use an already downloaded tarball")
    parser.add_argument("--cache", type=Path, help="directory for downloaded tarballs")
    parser.add_argument("--dest", type=Path, help="override extraction destination")
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        lock = load_lock(args.lock.expanduser())
        if args.command == "show":
            cmd_show(lock)
            return 0
        if args.platform is None:
            raise CoreLockError("--platform is required for fetch/verify")
        if args.command == "fetch":
            cmd_fetch(lock, args.platform, args)
        else:
            cmd_verify(lock, args.platform, args)
        return 0
    except (CoreLockError, OSError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
