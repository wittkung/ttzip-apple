#!/usr/bin/env python3
# Copyright 2026 MetastudyLine. All rights reserved.
# SPDX-License-Identifier: MIT OR Apache-2.0

"""Developer install and launch session isolation for TTZip (#189).

Owns three invariants shared by `products/ttzip/build_and_run.command` and
`products/ttzip/apple/scripts/bundle_app.sh`:

1. Path-targeted instance termination: never run global `pgrep -x TTZip` or
   `pkill -x TTZip`. Match and terminate only processes whose executable path
   resolves to `<resolved-DEST_APP>/Contents/MacOS/TTZip`.
2. Destination lock holder identity (`<DEST_APP>.install.lock/owner.json`):
   record `pid`, `start_time`, `candidate`, and `destination`; recover a held
   lock only when valid holder metadata proves the recorded `(pid, start_time)`
   process is no longer running; never delete an unknown or active lock.
3. Honest session data boundary disclosure in deployment/launch receipts:
   record that `TTZIP_INSTALL_PATH` isolates bundle replacement, lock
   serialization, and process termination only, while macOS App Group
   (`group.com.metastudyline.ttzip`), Application Support (`Reader`,
   `SemanticIndex`), and standard `UserDefaults` remain shared across sessions
   under the same macOS user account.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shlex
import shutil
import signal
import subprocess
import sys
import time
from pathlib import Path
from typing import Any, Optional

LOCK_SUFFIX = ".install.lock"
OWNER_FILENAME = "owner.json"

LOCK_ABSENT = "absent"
LOCK_ACTIVE_HOLDER = "active_holder"
LOCK_STALE_DEAD_HOLDER = "stale_dead_holder"
LOCK_UNKNOWN_LOCKED = "unknown_locked"
LOCK_RECOVERED_STALE = "recovered_stale"

INTERPRETER_BASENAMES = frozenset({
    "sh",
    "bash",
    "zsh",
    "dash",
    "python",
    "python3",
    "Python",
    "env",
})

BOUNDARY_NOTE = (
    "TTZIP_INSTALL_PATH isolates bundle replacement, destination lock "
    "serialization, and path-targeted process termination only; macOS App "
    "Group (group.com.metastudyline.ttzip), Application Support (Reader, "
    "SemanticIndex), and standard UserDefaults remain shared across sessions "
    "under the same user account."
)


def resolve_bundle_path(destination: str) -> str:
    """Resolve a bundle path canonically even when the leaf does not exist yet."""
    abs_path = Path(os.path.abspath(destination))
    if abs_path.exists():
        return os.path.realpath(str(abs_path))
    parent_real = os.path.realpath(str(abs_path.parent))
    return os.path.join(parent_real, abs_path.name)


def candidate_executable_paths(destination: str) -> set[str]:
    """Return all canonical and unresolved paths for <destination>/Contents/MacOS/TTZip."""
    abs_dest = Path(os.path.abspath(destination))
    resolved_dest = Path(resolve_bundle_path(destination))
    parent_real_dest = Path(os.path.realpath(str(abs_dest.parent))) / abs_dest.name
    paths = {
        str(abs_dest / "Contents/MacOS/TTZip"),
        str(resolved_dest / "Contents/MacOS/TTZip"),
        str(parent_real_dest / "Contents/MacOS/TTZip"),
    }
    if abs_dest.exists():
        paths.add(str(Path(os.path.realpath(str(abs_dest))) / "Contents/MacOS/TTZip"))
    return paths


def lock_dir_for(destination: str) -> Path:
    """Return the destination lock directory `<DEST_APP>.install.lock`."""
    return Path(f"{os.path.abspath(destination)}{LOCK_SUFFIX}")


def _ps_env() -> dict[str, str]:
    env = dict(os.environ)
    env["LC_ALL"] = "C"
    env["TZ"] = "UTC"
    return env


def process_start_time(pid: int) -> str:
    """Query the deterministic kernel start timestamp of `pid`, or '' if gone."""
    if pid <= 0:
        return ""
    try:
        res = subprocess.run(
            ["/bin/ps", "-p", str(pid), "-o", "lstart="],
            capture_output=True,
            text=True,
            env=_ps_env(),
            timeout=5,
        )
    except OSError:
        return ""
    if res.returncode != 0:
        return ""
    return " ".join(res.stdout.strip().split())


def pid_is_alive(pid: int) -> bool:
    """Return True if `pid` exists and is not a zombie process."""
    if pid <= 0:
        return False
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    except OSError:
        return True
    try:
        res = subprocess.run(
            ["/bin/ps", "-p", str(pid), "-o", "stat="],
            capture_output=True,
            text=True,
            env=_ps_env(),
            timeout=5,
        )
        if res.returncode != 0:
            return False
        stat = res.stdout.strip()
        if not stat or stat.startswith("Z"):
            return False
    except OSError:
        pass
    return True


def write_lock_owner(
    destination: str,
    pid: int,
    candidate: str,
    start_time: Optional[str] = None,
) -> dict[str, Any]:
    """Atomically write holder identity metadata to `<DEST_APP>.install.lock/owner.json`."""
    lock_dir = lock_dir_for(destination)
    if not lock_dir.is_dir() or lock_dir.is_symlink():
        raise OSError(f"Lock directory does not exist: {lock_dir}")
    resolved_dest = resolve_bundle_path(destination)
    resolved_start = (
        " ".join(start_time.strip().split())
        if start_time and start_time.strip()
        else process_start_time(pid)
    )
    if not resolved_start:
        resolved_start = f"epoch-{int(time.time())}"
    payload: dict[str, Any] = {
        "acquired_at_utc": time.strftime("%Y-%m-%dT%H:%M:%S+00:00", time.gmtime()),
        "candidate": candidate,
        "destination": resolved_dest,
        "executable_target": os.path.join(resolved_dest, "Contents", "MacOS", "TTZip"),
        "pid": pid,
        "start_time": resolved_start,
    }
    tmp_path = lock_dir / f".{OWNER_FILENAME}.tmp.{os.getpid()}.{time.monotonic_ns()}"
    owner_path = lock_dir / OWNER_FILENAME
    tmp_path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    os.replace(tmp_path, owner_path)
    return payload


def _read_lock_owner_payload(lock_dir: Path) -> Optional[dict[str, Any]]:
    owner_path = lock_dir / OWNER_FILENAME
    if owner_path.is_symlink() or not owner_path.is_file():
        return None
    try:
        data = json.loads(owner_path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    return data if isinstance(data, dict) else None


def _is_valid_lock_owner_schema(data: dict[str, Any]) -> bool:
    pid = data.get("pid")
    if not isinstance(pid, int) or isinstance(pid, bool) or pid <= 0:
        return False
    for key in ("start_time", "candidate", "destination"):
        val = data.get(key)
        if not isinstance(val, str) or not val.strip():
            return False
    return True


def inspect_lock(destination: str) -> tuple[str, Optional[dict[str, Any]]]:
    """Classify the state of `<DEST_APP>.install.lock` without mutating it."""
    lock_dir = lock_dir_for(destination)
    if not lock_dir.exists() and not lock_dir.is_symlink():
        return LOCK_ABSENT, None
    if lock_dir.is_symlink() or not lock_dir.is_dir():
        return LOCK_UNKNOWN_LOCKED, None
    data = _read_lock_owner_payload(lock_dir)
    if data is None:
        return LOCK_UNKNOWN_LOCKED, None
    if not _is_valid_lock_owner_schema(data):
        return LOCK_UNKNOWN_LOCKED, data

    pid = int(data["pid"])
    start_time = str(data["start_time"])
    recorded_dest = str(data["destination"])
    if resolve_bundle_path(recorded_dest) != resolve_bundle_path(destination) and os.path.abspath(
        recorded_dest
    ) != os.path.abspath(destination):
        return LOCK_UNKNOWN_LOCKED, data
    if not pid_is_alive(pid):
        return LOCK_STALE_DEAD_HOLDER, data

    live_start = process_start_time(pid)
    if live_start and live_start != " ".join(start_time.strip().split()):
        return LOCK_STALE_DEAD_HOLDER, data
    return LOCK_ACTIVE_HOLDER, data


def _remove_lock_directory(lock_dir: Path, compat_lock: Optional[str] = None) -> bool:
    try:
        for entry in lock_dir.iterdir():
            if entry.is_symlink() or entry.is_file():
                entry.unlink(missing_ok=True)
        lock_dir.rmdir()
    except OSError:
        return False
    if compat_lock:
        compat_path = Path(compat_lock)
        if compat_path.is_dir() and not compat_path.is_symlink():
            try:
                compat_path.rmdir()
            except OSError:
                pass
    return True


def reconcile_lock(destination: str, compat_lock: Optional[str] = None) -> str:
    """Recover `<DEST_APP>.install.lock` if and only if its recorded holder is provably stale."""
    state, _ = inspect_lock(destination)
    if state != LOCK_STALE_DEAD_HOLDER:
        return state
    lock_dir = lock_dir_for(destination)
    if _remove_lock_directory(lock_dir, compat_lock=compat_lock):
        return LOCK_RECOVERED_STALE
    return state


def acquire_destination_lock(
    destination: str,
    pid: int,
    candidate: str,
    max_attempts: int = 60,
    retry_seconds: float = 0.5,
    compat_lock: Optional[str] = None,
) -> Path:
    """Acquire `<DEST_APP>.install.lock` with stale-holder recovery and write `owner.json`."""
    lock_dir = lock_dir_for(destination)
    lock_dir.parent.mkdir(parents=True, exist_ok=True)
    attempts = 0
    while True:
        reconcile_lock(destination, compat_lock=compat_lock)
        try:
            lock_dir.mkdir(exist_ok=False)
        except FileExistsError:
            if attempts >= max_attempts:
                raise RuntimeError(
                    f"Another installation is holding '{lock_dir}'; remove it if no build is running."
                )
            time.sleep(retry_seconds)
            attempts += 1
            continue
        try:
            write_lock_owner(destination, pid=pid, candidate=candidate)
        except Exception:
            _remove_lock_directory(lock_dir, compat_lock=compat_lock)
            raise
        if compat_lock:
            try:
                Path(compat_lock).mkdir(exist_ok=False)
            except FileExistsError:
                pass
        return lock_dir


def release_destination_lock(destination: str, compat_lock: Optional[str] = None) -> None:
    """Release `<DEST_APP>.install.lock` and optional compatibility lock directory."""
    lock_dir = lock_dir_for(destination)
    if lock_dir.is_dir() and not lock_dir.is_symlink():
        _remove_lock_directory(lock_dir, compat_lock=compat_lock)
    elif compat_lock:
        compat_path = Path(compat_lock)
        if compat_path.is_dir() and not compat_path.is_symlink():
            try:
                compat_path.rmdir()
            except OSError:
                pass


def _is_interpreter_token(token: str) -> bool:
    base = os.path.basename(token)
    return base in INTERPRETER_BASENAMES or base.startswith("python3.")


def _extract_candidate_tokens(tokens: list[str]) -> list[str]:
    candidates = [tokens[0]]
    if _is_interpreter_token(tokens[0]):
        for tok in tokens[1:]:
            if not tok.startswith("-") and not _is_interpreter_token(tok):
                candidates.append(tok)
                break
    return candidates


def _command_matches_target_executables(command: str, target_executables: set[str]) -> bool:
    if any(command == exe or command.startswith(exe + " ") for exe in target_executables):
        return True
    try:
        tokens = shlex.split(command)
    except ValueError:
        tokens = command.split()
    if not tokens:
        return False

    for tok in _extract_candidate_tokens(tokens):
        if not tok.endswith("/Contents/MacOS/TTZip"):
            continue
        abs_tok = os.path.abspath(tok)
        if {tok, abs_tok, os.path.realpath(abs_tok)} & target_executables:
            return True
    return False


def find_bundle_pids(
    destination: str,
    exclude_pids: Optional[set[int]] = None,
) -> list[int]:
    """Return live PIDs whose executable path resolves to `<destination>/Contents/MacOS/TTZip`."""
    excluded = {os.getpid(), os.getppid()}
    if exclude_pids:
        excluded.update(exclude_pids)
    target_executables = candidate_executable_paths(destination)
    try:
        res = subprocess.run(
            ["/bin/ps", "-axww", "-o", "pid=,stat=,command="],
            capture_output=True,
            text=True,
            env=_ps_env(),
            timeout=10,
        )
    except OSError:
        return []
    if res.returncode != 0:
        return []

    matched: list[int] = []
    for raw_line in res.stdout.splitlines():
        parts = raw_line.strip().split(None, 2)
        if len(parts) < 3:
            continue
        try:
            pid = int(parts[0])
        except ValueError:
            continue
        stat, command = parts[1], parts[2]
        if pid in excluded or stat.startswith("Z"):
            continue
        if "dev_install_isolation.py" in command:
            continue
        if _command_matches_target_executables(command, target_executables):
            matched.append(pid)
    return matched


def terminate_bundle_processes(
    destination: str,
    grace_seconds: float = 5.0,
    exclude_pids: Optional[set[int]] = None,
) -> list[int]:
    """Terminate only processes running `<resolved-DEST_APP>/Contents/MacOS/TTZip`."""
    initial_pids = find_bundle_pids(destination, exclude_pids=exclude_pids)
    if not initial_pids:
        return []

    for pid in initial_pids:
        try:
            os.kill(pid, signal.SIGTERM)
        except OSError:
            pass

    deadline = time.monotonic() + max(0.05, grace_seconds)
    while time.monotonic() < deadline:
        remaining = find_bundle_pids(destination, exclude_pids=exclude_pids)
        if not remaining:
            return initial_pids
        time.sleep(0.05)

    remaining = find_bundle_pids(destination, exclude_pids=exclude_pids)
    for pid in remaining:
        try:
            os.kill(pid, signal.SIGKILL)
        except OSError:
            pass

    kill_deadline = time.monotonic() + 1.0
    while time.monotonic() < kill_deadline:
        if not find_bundle_pids(destination, exclude_pids=exclude_pids):
            break
        time.sleep(0.02)

    return initial_pids


def build_session_isolation_boundary(
    destination: str,
    launch_target: str,
    candidate: str,
    installed: bool,
) -> dict[str, Any]:
    """Construct the candidate session data boundary disclosure dictionary."""
    resolved_dest = resolve_bundle_path(destination)
    executable_target = os.path.join(resolved_dest, "Contents", "MacOS", "TTZip")
    lock_path = str(lock_dir_for(destination))
    return {
        "boundary_note": BOUNDARY_NOTE,
        "candidate": candidate,
        "data_isolation_complete": False,
        "destination": destination,
        "executable_target": executable_target,
        "install_path": destination,
        "installed": installed,
        "isolated_resources": {
            "bundle_executable_path": executable_target,
            "install_transaction_lock": lock_path,
            "process_termination_scope": "destination_bundle_executable_only",
            "system_registration_scope": "system_applications_only",
        },
        "isolation_scope": "process_and_bundle_path_only",
        "launch_target": launch_target,
        "resolved_install_path": resolved_dest,
        "shared_macos_state": {
            "app_group_container": {
                "identifier": "group.com.metastudyline.ttzip",
                "isolated_by_install_path": False,
                "owner": "AppGroupSpoolManager",
            },
            "application_support": {
                "isolated_by_install_path": False,
                "owners": [
                    "ReaderPersistenceBridge",
                    "LocalSemanticPluginPreferences",
                ],
                "subdirectories": [
                    "Reader",
                    "SemanticIndex",
                ],
            },
            "user_defaults": {
                "domain": "com.metastudyline.ttzip",
                "isolated_by_install_path": False,
                "owner": "RootFolderAccessManager",
            },
        },
    }


def _sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(65536), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _atomic_write_json(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp_path = path.parent / f".{path.name}.tmp.{os.getpid()}"
    tmp_path.write_text(
        json.dumps(payload, indent=2, sort_keys=True, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )
    os.replace(tmp_path, path)


def write_session_receipt(
    receipt_path: Path,
    destination: str,
    launch_target: str,
    candidate: str,
    installed: bool,
    record_path: Optional[Path] = None,
    manifest_path: Optional[Path] = None,
    channel: str = "direct",
    build_config: str = "opt",
) -> dict[str, Any]:
    """Write `dev-session-receipt.json` and optionally write/update `dev-build-record.json`."""
    recorded_at = time.strftime("%Y-%m-%dT%H:%M:%S+00:00", time.gmtime())
    boundary = build_session_isolation_boundary(
        destination=destination,
        launch_target=launch_target,
        candidate=candidate,
        installed=installed,
    )
    receipt_payload: dict[str, Any] = {
        "candidate": candidate,
        "recorded_at_utc": recorded_at,
        "session_isolation": boundary,
    }
    _atomic_write_json(receipt_path, receipt_payload)

    if record_path is not None and manifest_path is not None and manifest_path.is_file():
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        snapshot = manifest.get("source_snapshot") or {}
        record = {
            "app_bundle_path": manifest.get("app_bundle_path"),
            "archive_path": manifest.get("archive_path"),
            "archive_sha256": manifest.get("archive_sha256"),
            "bazel_raw_archive_path": manifest.get("bazel_raw_archive_path"),
            "bazel_raw_archive_sha256": manifest.get("bazel_raw_archive_sha256"),
            "build_command": manifest.get("build_command"),
            "build_config": build_config,
            "channel": channel,
            "executables_sha256": manifest.get("executables_sha256"),
            "git_commit": snapshot.get("git_head_commit"),
            "install_target": destination,
            "installed": installed,
            "launch_target": launch_target,
            "manifest_path": os.path.abspath(str(manifest_path)),
            "manifest_sha256": _sha256_file(manifest_path),
            "recorded_at_utc": recorded_at,
            "run_id": candidate,
            "session_isolation": boundary,
            "source_snapshot_sha256": snapshot.get("composite_snapshot_sha256"),
        }
        _atomic_write_json(record_path, record)
    elif record_path is not None and record_path.is_file():
        try:
            record = json.loads(record_path.read_text(encoding="utf-8"))
            if isinstance(record, dict):
                record["session_isolation"] = boundary
                _atomic_write_json(record_path, record)
        except (OSError, ValueError):
            pass

    return receipt_payload


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="dev_install_isolation",
        description="Isolate TTZip developer install and launch sessions across worktrees.",
    )
    sub = parser.add_subparsers(dest="command", required=True)

    term = sub.add_parser("terminate", help="terminate only the target bundle executable")
    term.add_argument("--destination", required=True)
    term.add_argument("--grace-seconds", type=float, default=5.0)

    rec = sub.add_parser("reconcile-lock", help="recover stale dead-holder lock if safe")
    rec.add_argument("--destination", required=True)
    rec.add_argument("--compat-lock", default="")

    own = sub.add_parser("write-owner", help="write holder metadata into destination lock")
    own.add_argument("--destination", required=True)
    own.add_argument("--pid", type=int, required=True)
    own.add_argument("--candidate", required=True)
    own.add_argument("--start-time", default="")

    acq = sub.add_parser("acquire-lock", help="acquire destination lock and write owner metadata")
    acq.add_argument("--destination", required=True)
    acq.add_argument("--pid", type=int, required=True)
    acq.add_argument("--candidate", required=True)
    acq.add_argument("--max-attempts", type=int, default=60)
    acq.add_argument("--retry-seconds", type=float, default=0.5)
    acq.add_argument("--compat-lock", default="")

    rel = sub.add_parser("release-lock", help="release destination lock")
    rel.add_argument("--destination", required=True)
    rel.add_argument("--compat-lock", default="")

    insp = sub.add_parser("inspect-lock", help="inspect destination lock state")
    insp.add_argument("--destination", required=True)

    rcpt = sub.add_parser("write-receipt", help="write candidate session isolation receipt")
    rcpt.add_argument("--receipt-path", required=True)
    rcpt.add_argument("--destination", required=True)
    rcpt.add_argument("--launch-target", default="")
    rcpt.add_argument("--candidate", required=True)
    rcpt.add_argument("--installed", default="false")
    rcpt.add_argument("--record-path", default="")
    rcpt.add_argument("--manifest-path", default="")
    rcpt.add_argument("--channel", default="direct")
    rcpt.add_argument("--build-config", default="opt")

    return parser


def main(argv: Optional[list[str]] = None) -> int:
    args = _build_parser().parse_args(argv)
    if args.command == "terminate":
        pids = terminate_bundle_processes(args.destination, grace_seconds=args.grace_seconds)
        exe = os.path.join(resolve_bundle_path(args.destination), "Contents", "MacOS", "TTZip")
        print(f"EXECUTABLE_TARGET={exe}")
        print(f"TERMINATED_PIDS={','.join(str(p) for p in pids)}")
        return 0
    if args.command == "reconcile-lock":
        state = reconcile_lock(args.destination, compat_lock=args.compat_lock or None)
        print(f"LOCK_STATE={state}")
        return 0
    if args.command == "write-owner":
        payload = write_lock_owner(
            args.destination,
            pid=args.pid,
            candidate=args.candidate,
            start_time=args.start_time or None,
        )
        print(f"OWNER_PID={payload['pid']}")
        return 0
    if args.command == "acquire-lock":
        lock_dir = acquire_destination_lock(
            args.destination,
            pid=args.pid,
            candidate=args.candidate,
            max_attempts=args.max_attempts,
            retry_seconds=args.retry_seconds,
            compat_lock=args.compat_lock or None,
        )
        print(f"LOCK_DIR={lock_dir}")
        return 0
    if args.command == "release-lock":
        release_destination_lock(args.destination, compat_lock=args.compat_lock or None)
        return 0
    if args.command == "inspect-lock":
        state, owner = inspect_lock(args.destination)
        print(json.dumps({"state": state, "owner": owner}, sort_keys=True))
        return 0
    if args.command == "write-receipt":
        installed = str(args.installed).lower() == "true"
        record_path = Path(args.record_path) if args.record_path else None
        manifest_path = Path(args.manifest_path) if args.manifest_path else None
        write_session_receipt(
            receipt_path=Path(args.receipt_path),
            destination=args.destination,
            launch_target=args.launch_target,
            candidate=args.candidate,
            installed=installed,
            record_path=record_path,
            manifest_path=manifest_path,
            channel=args.channel,
            build_config=args.build_config,
        )
        print(f"RECEIPT_PATH={args.receipt_path}")
        return 0
    return 2


if __name__ == "__main__":
    sys.exit(main())
