#!/usr/bin/env python3
"""Keep named SSH workspaces available without taking over a live agent session."""

import argparse
import fcntl
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import sqlite3
import subprocess
import sys
import time


def load_manifest(path):
    data = json.loads(path.read_text())
    if data.get("schema") != "uniconnect-recovery/v1":
        raise ValueError("Unsupported recovery manifest")
    if data.get("tmuxSocket") != "uniconnect":
        raise ValueError("Recovery must use the dedicated uniconnect tmux socket")
    names, ids = set(), set()
    for entry in data["windows"]:
        if len(entry["tmux"]) > 40 or not re.fullmatch(r"uc-[a-z0-9-]+", entry["tmux"]):
            raise ValueError("Invalid tmux session name")
        if not re.fullmatch(r"[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}", entry["sessionId"]):
            raise ValueError("Invalid agent session UUID")
        if entry["tmux"] in names or entry["sessionId"] in ids:
            raise ValueError("Duplicate recovery target")
        if entry["agent"] not in ("codex", "agy"):
            raise ValueError("Unsupported engine for automatic recovery")
        if not Path(entry["cwd"]).is_absolute():
            raise ValueError("Recovery cwd must be absolute")
        names.add(entry["tmux"])
        ids.add(entry["sessionId"])
    return data


def native_lock_path(entry):
    if entry["agent"] == "codex":
        return Path.home() / ".codex/thread-writer-locks" / (entry["sessionId"] + ".lock")
    return Path.home() / ".gemini/antigravity-cli/presence" / (entry["sessionId"] + ".lock")


def lock_owners(path):
    """Read kernel lock ownership. An existing lock file alone proves nothing."""
    try:
        stat = path.stat()
    except FileNotFoundError:
        return []
    target = (os.major(stat.st_dev), os.minor(stat.st_dev), stat.st_ino)
    owners = []
    for line in Path("/proc/locks").read_text().splitlines():
        fields = line.split()
        for index, value in enumerate(fields):
            parts = value.split(":")
            if len(parts) != 3:
                continue
            try:
                identity = (int(parts[0], 16), int(parts[1], 16), int(parts[2]))
            except ValueError:
                continue
            if identity == target:
                owners.append(int(fields[index - 1]))
    return sorted(set(owners))


def native_session_available(entry):
    path = native_lock_path(entry)
    if lock_owners(path):
        return False
    try:
        with path.open("rb") as handle:
            try:
                fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                return False
            fcntl.flock(handle, fcntl.LOCK_UN)
    except FileNotFoundError:
        pass
    return True


def verify_session(entry):
    if not Path(entry["cwd"]).is_dir() or (entry.get("repo") and not Path(entry["repo"]).is_dir()):
        raise ValueError("Workspace directory is missing")
    if entry["agent"] == "codex":
        dbpath = Path.home() / ".codex/state_5.sqlite"
        with sqlite3.connect("file:" + str(dbpath) + "?mode=ro", uri=True) as db:
            row = db.execute("SELECT rollout_path FROM threads WHERE id = ?", (entry["sessionId"],)).fetchone()
        if row is None or not Path(row[0]).is_file():
            raise ValueError("The original Codex session cannot be verified")
    else:
        conversation = Path.home() / ".gemini/antigravity-cli/conversations" / (entry["sessionId"] + ".db")
        if not conversation.is_file():
            raise ValueError("The original Gemini conversation is missing")


def command_for(entry):
    executable = shutil.which("codex" if entry["agent"] == "codex" else "agy")
    if executable is None:
        raise ValueError("The original agent client is not installed or is absent from PATH")
    if entry["agent"] == "codex":
        # No prompt is passed: restore the existing thread and let the user steer it.
        command = [executable, "resume", "-C", entry["cwd"]]
        if entry.get("model"):
            command.extend(["-m", entry["model"]])
        if entry.get("reasoningEffort"):
            command.extend(["-c", "model_reasoning_effort=" + json.dumps(entry["reasoningEffort"])])
        return command + [entry["sessionId"]]
    return [executable, "--conversation", entry["sessionId"]]


def tmux(data, *args, check=True):
    return subprocess.run(["tmux", "-L", data["tmuxSocket"], *args],
                          text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                          check=check, timeout=15)


def ensure_windows(data, manifest_path):
    for entry in data["windows"]:
        target = "=" + entry["tmux"]
        launch = shlex.join([sys.executable, str(Path(__file__).resolve()),
                             "--manifest", str(manifest_path), "launch", entry["tmux"]])
        if tmux(data, "has-session", "-t", target, check=False).returncode == 0:
            owner = tmux(data, "show-option", "-v", "-t", target + ":",
                         "@uniconnect_session_id", check=False)
            if owner.stdout.strip() != entry["sessionId"]:
                raise RuntimeError("Existing tmux target has different ownership: " + entry["tmux"])
            # Old tmux + newer ncurses can segfault on OSC 52 selection export.
            # Scope this to our dedicated server; VTE clipboard copying remains local.
            tmux(data, "set-option", "-s", "set-clipboard", "off")
            panes = tmux(data, "list-panes", "-t", target + ":", "-F", "#{pane_id}\t#{pane_dead}").stdout.splitlines()
            if len(panes) == 1 and panes[0].endswith("\t1"):
                # No -k: tmux refuses to replace a live pane if it changes during this check.
                tmux(data, "respawn-pane", "-t", panes[0].split("\t")[0], "exec " + launch)
            continue
        verify_session(entry)
        command_for(entry)
        result = tmux(data, "new-session", "-d", "-s", entry["tmux"], "-n", entry["name"],
                      "-c", entry["cwd"], "-x", "120", "-y", "36", "exec " + launch,
                      ";", "set-option", "-s", "set-clipboard", "off",
                      check=False)
        if result.returncode != 0:
            if tmux(data, "has-session", "-t", target, check=False).returncode == 0:
                continue
            raise RuntimeError("tmux could not create " + entry["tmux"] + ": " + result.stderr.strip())
        for option, value in (("@uniconnect_session_id", entry["sessionId"]),
                              ("@uniconnect_workspace", entry["workspace"]),
                              ("@uniconnect_repo", entry.get("repo") or entry["cwd"]), ("mouse", "on")):
            tmux(data, "set-option", "-t", target + ":", option, value)
        tmux(data, "set-window-option", "-t", target + ":", "automatic-rename", "off")
        tmux(data, "set-window-option", "-t", target + ":", "remain-on-exit", "on")
        print("Created " + entry["tmux"], flush=True)


def launch(entry, manifest_path):
    # New launchers also enforce this while an older supervisor remains alive.
    tmux(load_manifest(manifest_path), "set-option", "-s", "set-clipboard", "off")
    verify_session(entry)
    lease_dir = manifest_path.parent / "launcher-locks"
    lease_dir.mkdir(mode=0o700, exist_ok=True)
    # This private lease serializes our launchers; the agent retains its native lock.
    with (lease_dir / (entry["sessionId"] + ".lock")).open("a") as lease:
        try:
            fcntl.flock(lease, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise RuntimeError("Another UniConnect launcher already owns this window")
        while True:
            waiting = False
            while not native_session_available(entry):
                if not waiting:
                    print("La sesión original sigue abierta. Esta ventana la recuperará cuando salga.", flush=True)
                    waiting = True
                time.sleep(5)
            if waiting:
                print("La sesión original se ha cerrado. Recuperando el mismo historial…", flush=True)
            verify_session(entry)
            child = subprocess.Popen(command_for(entry), cwd=entry["cwd"])
            while True:
                try:
                    code = child.wait()
                    break
                except KeyboardInterrupt:
                    # Ctrl-C also reaches the foreground agent; never kill it from here.
                    continue
            if code:
                print("El cliente ha terminado con código " + str(code) +
                      ". Reintento en 30 segundos; el historial se conserva.", flush=True)
                time.sleep(30)
                continue
            try:
                input("Sesión cerrada. Pulsa Intro para recuperar el mismo historial: ")
            except (EOFError, KeyboardInterrupt):
                return


def status(data):
    windows = []
    for entry in data["windows"]:
        pane = tmux(data, "list-panes", "-t", "=" + entry["tmux"] + ":", "-F",
                    "#{pane_id}\t#{pane_pid}\t#{pane_dead}\t#{pane_current_command}", check=False)
        windows.append({"name": entry["name"], "tmux": entry["tmux"],
                        "sessionId": entry["sessionId"], "agent": entry["agent"],
                        "native_lock_owners": lock_owners(native_lock_path(entry)),
                        "tmux_exists": pane.returncode == 0,
                        "panes": pane.stdout.strip().splitlines() if pane.returncode == 0 else []})
    print(json.dumps({"tmuxSocket": data["tmuxSocket"], "windows": windows}, indent=2, ensure_ascii=False))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("action", choices=("validate", "ensure", "supervise", "launch", "status"))
    parser.add_argument("name", nargs="?")
    args = parser.parse_args()
    manifest_path = args.manifest.resolve()
    data = load_manifest(manifest_path)
    if args.action == "validate":
        for entry in data["windows"]:
            verify_session(entry)
            command_for(entry)
        print("Verified " + str(len(data["windows"])) + " existing agent sessions; no sessions started.")
    elif args.action == "launch":
        entry = next((row for row in data["windows"] if row["tmux"] == args.name), None)
        if entry is None:
            raise ValueError("Unknown recovery window")
        launch(entry, manifest_path)
    elif args.action == "status":
        status(data)
    elif args.action == "ensure":
        ensure_windows(data, manifest_path)
    else:
        while True:
            try:
                ensure_windows(data, manifest_path)
            except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
                print("Recovery needs attention: " + str(error), file=sys.stderr, flush=True)
            time.sleep(15)


if __name__ == "__main__":
    main()
