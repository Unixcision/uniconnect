#!/usr/bin/env python3
"""Read-only repository watcher; deliver stable, retryable local change events.

Delivery is at-least-once: notify_argv must deduplicate eventId across crashes.
No checkout, fetch, merge, model invocation, or repository write occurs here.
"""

import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import tempfile

REPOSITORY = "Unixcision/uniconnect"
SHA = re.compile(r"(?:[0-9a-f]{40}|[0-9a-f]{64})\Z")


class MonitorError(RuntimeError):
    """Non-secret diagnostic code, safe for systemd's journal."""


def encoded(value):
    return (json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True) + "\n").encode()


def fingerprint(value):
    return hashlib.sha256(encoded(value)).hexdigest()


def read_json(path):
    if path.is_symlink():
        raise MonitorError("unsafe-state-file")
    try:
        content = path.read_bytes()
        if len(content) > 8 * 1024 * 1024:
            raise ValueError()
        return json.loads(content)
    except (OSError, ValueError):
        raise MonitorError("invalid-json-file") from None


def atomic_json(path, value):
    descriptor, temporary = tempfile.mkstemp(prefix=".monitor-", dir=path.parent)
    try:
        with os.fdopen(descriptor, "wb") as output:
            output.write(encoded(value))
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, path)
        sync_directory(path.parent)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def sync_directory(path):
    descriptor = os.open(path, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def run_command(argv, *, cwd):
    try:
        result = subprocess.run(argv, cwd=cwd, capture_output=True, text=True, timeout=45, check=True)
        if len(result.stdout) > 8 * 1024 * 1024:
            raise MonitorError("source-output-too-large")
        return result.stdout
    except (OSError, subprocess.SubprocessError, UnicodeError):
        raise MonitorError("source-unavailable") from None


def notify_command(argv):
    try:
        return subprocess.run(argv, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                              stderr=subprocess.DEVNULL, timeout=60).returncode
    except (OSError, subprocess.SubprocessError):
        return 1


class BranchMonitor:
    def __init__(self, config, *, runner=run_command, notifier=notify_command):
        try:
            if config["repository"] != REPOSITORY:
                raise ValueError()
            repo, root = Path(config["repo_path"]), Path(config["state_dir"])
            if not repo.is_absolute() or not root.is_absolute():
                raise ValueError()
            self.repo, self.root = repo.resolve(), root.resolve()
            self.notify_argv = config["notify_argv"]
            if (not self.repo.is_dir() or self.root in (Path("/"), Path.home().resolve(), self.repo)
                    or self.root in self.repo.parents or self.repo in self.root.parents
                    or not isinstance(self.notify_argv, list) or not self.notify_argv
                    or any(not isinstance(arg, str) or not arg or "\0" in arg for arg in self.notify_argv)):
                raise ValueError()
        except (KeyError, TypeError, ValueError, OSError, RuntimeError):
            raise MonitorError("invalid-config") from None
        self.runner, self.notifier = runner, notifier
        self.snapshot = self.root / "snapshot.json"
        self.pending = self.root / "pending.json"
        self.candidate = self.root / "pending-snapshot.json"

    def validate_remote(self):
        remote = self.runner(["git", "remote", "get-url", "origin"], cwd=self.repo).strip()
        if not re.fullmatch(r"(?:https://github\.com/|git@github\.com:|ssh://git@github\.com/)"
                            r"Unixcision/uniconnect(?:\.git)?", remote, flags=re.IGNORECASE):
            raise MonitorError("unexpected-origin")

    def observe(self):
        branches = {}
        for line in self.runner(["git", "ls-remote", "--heads", "origin"], cwd=self.repo).splitlines():
            fields = line.split()
            if (len(fields) != 2 or not SHA.fullmatch(fields[0]) or not fields[1].startswith("refs/heads/")
                    or fields[1][11:] in branches or not fields[1][11:]):
                raise MonitorError("invalid-branch-response")
            branches[fields[1][11:]] = fields[0]
        try:
            runs = json.loads(self.runner(["gh", "run", "list", "--repo", REPOSITORY, "--limit", "30", "--json",
                "databaseId,headBranch,headSha,name,status,conclusion,url"], cwd=self.repo))
            if not isinstance(runs, list) or len(runs) > 30:
                raise ValueError()
            ci = {}
            for run in runs:
                if (not isinstance(run, dict) or type(run.get("databaseId")) is not int or run["databaseId"] <= 0
                        or any(not isinstance(run.get(field), str) for field in ("headBranch", "headSha", "name", "status", "url"))
                        or not SHA.fullmatch(run["headSha"]) or not (run.get("conclusion") is None or isinstance(run["conclusion"], str))
                        or run["url"].lower() != f"https://github.com/{REPOSITORY}/actions/runs/{run['databaseId']}".lower()
                        or str(run["databaseId"]) in ci):
                    raise ValueError()
                ci[str(run["databaseId"])] = {field: run[field] for field in
                    ("databaseId", "headBranch", "headSha", "name", "status", "conclusion", "url")}
        except (ValueError, TypeError, KeyError):
            raise MonitorError("invalid-ci-response") from None
        return {"version": 1, "repository": REPOSITORY, "branches": branches, "ci": ci}

    @staticmethod
    def validate_snapshot(snapshot):
        if (not isinstance(snapshot, dict) or set(snapshot) != {"version", "repository", "branches", "ci"}
                or type(snapshot["version"]) is not int or snapshot["version"] != 1 or snapshot["repository"] != REPOSITORY
                or not isinstance(snapshot["branches"], dict) or not isinstance(snapshot["ci"], dict) or len(snapshot["ci"]) > 30
                or not all(isinstance(name, str) and name and not any(ord(char) < 33 for char in name)
                           and isinstance(sha, str) and SHA.fullmatch(sha) for name, sha in snapshot["branches"].items())):
            raise MonitorError("invalid-snapshot")
        for key, run in snapshot["ci"].items():
            if (not isinstance(run, dict) or set(run) != {"databaseId", "headBranch", "headSha", "name", "status", "conclusion", "url"}
                    or type(run["databaseId"]) is not int or run["databaseId"] <= 0 or key != str(run["databaseId"])
                    or any(not isinstance(run[field], str) or not run[field] for field in ("headBranch", "headSha", "name", "status", "url"))
                    or not SHA.fullmatch(run["headSha"]) or not (run["conclusion"] is None or isinstance(run["conclusion"], str))
                    or run["url"].lower() != f"https://github.com/{REPOSITORY}/actions/runs/{run['databaseId']}".lower()):
                raise MonitorError("invalid-snapshot")
        return snapshot

    @staticmethod
    def event(previous, current):
        old = previous["branches"] if previous else {}
        branches = [{"branch": name, "kind": "created" if name not in old else "deleted" if name not in current["branches"] else "updated",
                     "oldSha": old.get(name), "newSha": current["branches"].get(name)}
                    for name in sorted(set(old) | set(current["branches"])) if old.get(name) != current["branches"].get(name)]
        old_ci = previous["ci"] if previous else {}
        ci = [run for key, run in sorted(current["ci"].items(), key=lambda item: int(item[0]))
              if run["status"] == "completed" and run["conclusion"]
              and (old_ci.get(key, {}).get("status"), old_ci.get(key, {}).get("conclusion")) != ("completed", run["conclusion"])]
        if not branches and not ci:
            return None
        event = {"version": 1, "repository": REPOSITORY, "snapshotHash": fingerprint(current), "branches": branches, "ci": ci}
        return {**event, "eventId": fingerprint(event)}

    def deliver(self):
        event = read_json(self.pending)
        if not isinstance(event, dict) or event.get("repository") != REPOSITORY or event.get("version") != 1:
            raise MonitorError("invalid-pending-event")
        unsigned = dict(event)
        identifier = unsigned.pop("eventId", None)
        if identifier != fingerprint(unsigned):
            raise MonitorError("invalid-pending-event")
        # A crash after baseline fsync but before cleanup must not redeliver.
        already_saved = self.snapshot.exists() and fingerprint(read_json(self.snapshot)) == event["snapshotHash"]
        if not already_saved:
            candidate = self.validate_snapshot(read_json(self.candidate))
            if event.get("snapshotHash") != fingerprint(candidate):
                raise MonitorError("invalid-pending-event")
            try:
                delivered = self.notifier([*self.notify_argv, str(self.pending)]) == 0
            except Exception:
                delivered = False
            if not delivered:
                raise MonitorError("notification-failed")
            atomic_json(self.snapshot, candidate)
        self.pending.unlink()
        self.candidate.unlink(missing_ok=True)
        sync_directory(self.root)
        return "delivered"

    def once(self, *, baseline=False, notify_initial=False):
        if self.root.is_symlink():
            raise MonitorError("unsafe-state-directory")
        self.root.mkdir(parents=True, exist_ok=True, mode=0o700)
        metadata = self.root.lstat()
        if not stat.S_ISDIR(metadata.st_mode) or metadata.st_uid != os.getuid() or stat.S_IMODE(metadata.st_mode) != 0o700:
            raise MonitorError("unsafe-state-directory")
        descriptor = os.open(self.root / "monitor.lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        try:
            os.fchmod(descriptor, 0o600)
            try:
                fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                return "busy"
            self.validate_remote()
            if baseline and (self.pending.exists() or self.candidate.exists()):
                raise MonitorError("pending-delivery-required")
            if self.pending.exists():
                return self.deliver()
            previous = self.validate_snapshot(read_json(self.snapshot)) if self.snapshot.exists() else None
            if self.candidate.exists():
                # A crash can leave an observed snapshot durable before its event.
                # Recover that observation before consulting a newer remote state.
                candidate = self.validate_snapshot(read_json(self.candidate))
                event = self.event(previous, candidate)
                if event is not None:
                    atomic_json(self.pending, event)
                    return self.deliver()
                if previous is None:
                    atomic_json(self.snapshot, candidate)
                self.candidate.unlink()
                sync_directory(self.root)
                return "baseline" if previous is None else "unchanged"
            current = self.validate_snapshot(self.observe())
            if baseline or (previous is None and not notify_initial):
                atomic_json(self.snapshot, current)
                return "baseline"
            event = self.event(previous, current)
            if event is None:
                if previous is None:
                    atomic_json(self.snapshot, current)
                    return "baseline"
                return "unchanged"
            atomic_json(self.candidate, current)
            atomic_json(self.pending, event)
            return self.deliver()
        finally:
            os.close(descriptor)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, required=True)
    parser.add_argument("--once", action="store_true", required=True)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--baseline", action="store_true")
    mode.add_argument("--notify-initial", action="store_true")
    args = parser.parse_args()
    try:
        status = BranchMonitor(read_json(args.config)).once(baseline=args.baseline, notify_initial=args.notify_initial)
        print(status)
        return 0
    except (MonitorError, OSError) as error:
        print(str(error) if isinstance(error, MonitorError) else "monitor-storage-failed", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
