#!/usr/bin/env python3
"""Cooperative Mac-wide oMLX inference lock wrapper.

Acquires ~/.omlx/locks/mac-inference.lock with the same BSD flock(2) that
/usr/bin/lockf uses, writes inspection metadata, then runs a command.
Releases the lock when the command exits, including crash of this wrapper
via kernel fd close. This is not a daemon.

This wrapper does not read credentials and does not call oMLX. Pods does
an authenticated GET /api/status after it acquires the same lock.

A shell-only wrapper cannot both:
- keep metadata (pid, owner, purpose, model, started_at) accurate, and
- exec the command with exact argv (no shell word split) while holding
  the lock fd with FD_CLOEXEC so the child cannot unlock the parent.

macOS has /usr/bin/lockf, not util-linux flock. lockf can run a command
under flock(2), but it cannot write and clear metadata around that exec.

This file uses only the Python standard library.

WARNING: PODS_OMLX_LOCK=0 disables the cooperative lock. Unsafe for normal use.
"""
from __future__ import annotations

import argparse
import fcntl
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
from datetime import datetime, timezone

LOCK_FILE_NAME = "mac-inference.lock"
METADATA_FILE_NAME = "mac-inference.json"
EX_TEMPFAIL = 75
EX_USAGE = 64
METADATA_FIELDS = ("pid", "owner", "purpose", "model", "started_at")


def canonical_lock_dir() -> Path:
    override = os.environ.get("PODS_OMLX_LOCK_DIR")
    if override:
        return Path(override)
    home = os.environ.get("HOME")
    if not home:
        raise RuntimeError("HOME is unset")
    return Path(home) / ".omlx" / "locks"


def lock_enabled() -> bool:
    return os.environ.get("PODS_OMLX_LOCK") != "0"


def validate_token(field: str, value: str) -> str:
    if not value or len(value) > 120:
        raise ValueError(f"invalid {field}")
    lower = value.lower()
    if (
        "http" in lower
        or "prompt" in lower
        or "transcript" in lower
        or "bearer" in lower
        or lower.startswith("sk-")
        or any(ch in value for ch in "/\\ \n:")
        or not all(ch.isalnum() or ch in "-_." for ch in value)
    ):
        raise ValueError(f"invalid {field}")
    return value


def write_metadata(path: Path, owner: str, purpose: str, model: str) -> None:
    body = {
        "pid": os.getpid(),
        "owner": validate_token("owner", owner),
        "purpose": validate_token("purpose", purpose),
        "model": validate_token("model", model),
        "started_at": datetime.now(timezone.utc).replace(microsecond=0).strftime("%Y-%m-%dT%H:%M:%SZ"),
    }
    if tuple(body) != METADATA_FIELDS:
        raise RuntimeError("metadata field set is fixed")
    temp = path.with_suffix(".json.tmp")
    temp.write_text(json.dumps(body, indent=2) + "\n")
    temp.replace(path)


def metadata_pid(path: Path) -> int | None:
    try:
        pid = json.loads(path.read_text()).get("pid")
    except (OSError, json.JSONDecodeError, TypeError):
        return None
    return pid if isinstance(pid, int) else None


def inspection_metadata(path: Path) -> dict:
    try:
        raw = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError, TypeError):
        return {}
    if not isinstance(raw, dict):
        return {}
    return {key: raw[key] for key in METADATA_FIELDS if key in raw}


class InferenceLock:
    def __init__(self, directory: Path, owner: str, purpose: str, model: str):
        self.directory = directory
        self.lock_path = directory / LOCK_FILE_NAME
        self.metadata_path = directory / METADATA_FILE_NAME
        self.owner = owner
        self.purpose = purpose
        self.model = model
        self.fd = None
        self.wrote_metadata = False

    def acquire(self, block: bool = False) -> None:
        self.directory.mkdir(parents=True, exist_ok=True)
        self.fd = os.open(self.lock_path, os.O_RDWR | os.O_CREAT | os.O_CLOEXEC, 0o644)
        flags = fcntl.LOCK_EX
        if not block:
            flags |= fcntl.LOCK_NB
        try:
            fcntl.flock(self.fd, flags)
        except BlockingIOError as exc:
            os.close(self.fd)
            self.fd = None
            raise Locked() from exc
        except OSError:
            os.close(self.fd)
            self.fd = None
            raise
        write_metadata(self.metadata_path, self.owner, self.purpose, self.model)
        self.wrote_metadata = True

    def release(self) -> None:
        if self.wrote_metadata and self.metadata_path.is_file():
            if metadata_pid(self.metadata_path) == os.getpid():
                try:
                    self.metadata_path.unlink()
                except OSError:
                    pass
        self.wrote_metadata = False
        if self.fd is not None:
            try:
                fcntl.flock(self.fd, fcntl.LOCK_UN)
            finally:
                os.close(self.fd)
                self.fd = None

    def __enter__(self):
        self.acquire()
        return self

    def __exit__(self, exc_type, exc, tb):
        self.release()
        return False


class Locked(Exception):
    """The cooperative lock is held."""


def available(directory: Path) -> bool:
    directory.mkdir(parents=True, exist_ok=True)
    path = directory / LOCK_FILE_NAME
    fd = os.open(path, os.O_RDWR | os.O_CREAT | os.O_CLOEXEC, 0o644)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        fcntl.flock(fd, fcntl.LOCK_UN)
        return True
    except BlockingIOError:
        return False
    finally:
        os.close(fd)


def split_wrapper_args(argv: list[str]) -> tuple[list[str], list[str]]:
    if "--" in argv:
        index = argv.index("--")
        return argv[:index], argv[index + 1 :]
    return argv, []


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Acquire the Mac-wide cooperative oMLX lock, then run a command.",
        epilog="Put the command after -- so flags stay with that command.",
    )
    parser.add_argument("--owner", default="script", help="metadata owner (default: script)")
    parser.add_argument("--purpose", default="chat", help="metadata purpose (default: chat)")
    parser.add_argument("--model", default="unspecified", help="metadata model token")
    parser.add_argument("--lock-dir", help="lock directory override (tests)")
    parser.add_argument(
        "--check",
        action="store_true",
        help="print available or busy and exit; do not keep the lock",
    )
    return parser


def run_command(command: list[str]) -> int:
    try:
        proc = subprocess.Popen(command)
    except OSError:
        return 127
    def forward(signum, _frame):
        try:
            proc.send_signal(signum)
        except OSError:
            pass
    signal.signal(signal.SIGINT, forward)
    signal.signal(signal.SIGTERM, forward)
    signal.signal(signal.SIGHUP, forward)
    status = proc.wait()
    if status < 0:
        return 128 + (-status)
    return status


def main(argv: list[str] | None = None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    wrapper_args, command = split_wrapper_args(argv)
    args = build_parser().parse_args(wrapper_args)
    directory = Path(args.lock_dir) if args.lock_dir else canonical_lock_dir()
    if not lock_enabled():
        print(
            "WARNING: PODS_OMLX_LOCK=0 disables the cooperative oMLX lock. Unsafe for normal use.",
            file=sys.stderr,
        )
        if args.check:
            print("available")
            return 0
        if not command:
            print("usage: omlx_inference_lock.py [options] -- command [args...]", file=sys.stderr)
            return EX_USAGE
        return run_command(command)
    if args.check:
        if available(directory):
            print("available")
            return 0
        print("busy")
        meta = directory / METADATA_FILE_NAME
        if meta.is_file():
            safe = inspection_metadata(meta)
            if safe:
                sys.stdout.write(json.dumps(safe, indent=2) + "\n")
        return EX_TEMPFAIL
    if not command:
        print("usage: omlx_inference_lock.py [options] -- command [args...]", file=sys.stderr)
        return EX_USAGE
    lock = InferenceLock(directory, args.owner, args.purpose, args.model)
    try:
        lock.acquire()
    except Locked:
        print("omlx_busy", file=sys.stderr)
        return EX_TEMPFAIL
    try:
        return run_command(command)
    finally:
        lock.release()


if __name__ == "__main__":
    sys.exit(main())
