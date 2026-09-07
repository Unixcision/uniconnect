#!/usr/bin/env python3
"""UniConnect recovery supervisor.

Keeps every tmux window listed in the manifest alive with the AI it was running, and brings them
all back after the machine reboots or the tmux server dies. Every agent is relaunched with its
no-prompt flag, because a recovered session that stops to ask for permission is a dead session.

The manifest is not a fixed list: `snapshot` learns the sessions that exist right now (name,
folder, agent and conversation id read from the running process), so a window created after the
install is protected too. A window the user closed on purpose is forgotten rather than resurrected:
one session missing while the machine and its tmux server are the same ones that saw it alive was
a deliberate close; every session missing at once, or a new boot, means a crash or a reboot.

Actions: validate, snapshot, ensure, supervise, launch <tmux>, status, forget <tmux>.
"""
import argparse, fcntl, json, os, re, shlex, shutil, sqlite3, subprocess, sys, time
from pathlib import Path

NO_PROMPT = {
    "claude": ["--dangerously-skip-permissions"],
    "codex": ["--dangerously-bypass-approvals-and-sandbox"],
    "agy": ["--dangerously-skip-permissions"],
}
UUID = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")


def load_manifest(path):
    data = json.loads(path.read_text(encoding="utf-8"))
    data.setdefault("tmuxSocket", "default")
    data.setdefault("windows", [])
    return data


def save_manifest(path, data):
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    os.chmod(tmp, 0o600)
    tmp.replace(path)


def boot_id():
    return Path("/proc/sys/kernel/random/boot_id").read_text().strip()


def project_folder(cwd):
    return Path.home() / ".claude/projects" / re.sub(r"[/_]", "-", os.path.realpath(cwd))


# ---------------------------------------------------------------- agents

def claude_executable(entry):
    for candidate in (entry.get("executable"), str(Path.home() / ".local/bin/claude"), shutil.which("claude")):
        if candidate and os.access(candidate, os.X_OK):
            return candidate
    raise ValueError("claude is not installed")


def environment_for(entry):
    """Claude refuses its no-prompt flag as root unless the environment says it is sandboxed;
    the sessions this recovers were all started that way, so the relaunch has to be too."""
    env = dict(os.environ)
    if entry["agent"] == "claude" and os.geteuid() == 0:
        env["IS_SANDBOX"] = "1"
    return env


def trust_folder_for_claude(cwd):
    """Claude stops at "Do you trust this folder?" the first time it opens a directory. Nobody
    is there to answer during a recovery, so the answer the user gave is written ahead of time."""
    config = Path.home() / ".claude.json"
    try:
        data = json.loads(config.read_text(encoding="utf-8")) if config.is_file() else {}
    except (OSError, ValueError):
        return
    projects = data.setdefault("projects", {})
    project = projects.setdefault(os.path.realpath(cwd), {})
    if project.get("hasTrustDialogAccepted"):
        return
    project["hasTrustDialogAccepted"] = True
    tmp = config.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(data, indent=2, ensure_ascii=False), encoding="utf-8")
    os.chmod(tmp, 0o600)
    tmp.replace(config)


def command_for(entry):
    agent = entry["agent"]
    if agent == "command":
        return ["bash", "-lc", entry["command"]]
    if agent == "claude":
        return [claude_executable(entry), *NO_PROMPT["claude"], "--resume", entry["sessionId"]]
    executable = shutil.which("codex" if agent == "codex" else "agy")
    if executable is None:
        raise ValueError("The original agent client is not installed or is absent from PATH")
    if agent == "codex":
        command = [executable, "resume", "-C", entry["cwd"]]
        if entry.get("model"):
            command.extend(["-m", entry["model"]])
        if entry.get("reasoningEffort"):
            command.extend(["-c", "model_reasoning_effort=" + json.dumps(entry["reasoningEffort"])])
        return command + NO_PROMPT["codex"] + [entry["sessionId"]]
    return [executable, *NO_PROMPT["agy"], "--conversation", entry["sessionId"]]


def verify_session(entry):
    if not Path(entry["cwd"]).is_dir() or (entry.get("repo") and not Path(entry["repo"]).is_dir()):
        raise ValueError("Workspace directory is missing")
    agent = entry["agent"]
    if agent == "command":
        return
    if agent == "claude":
        if not (project_folder(entry["cwd"]) / (entry["sessionId"] + ".jsonl")).is_file():
            raise ValueError("The original Claude conversation is missing")
    elif agent == "codex":
        dbpath = Path.home() / ".codex/state_5.sqlite"
        with sqlite3.connect("file:" + str(dbpath) + "?mode=ro", uri=True) as db:
            row = db.execute("SELECT rollout_path FROM threads WHERE id = ?", (entry["sessionId"],)).fetchone()
        if row is None or not Path(row[0]).is_file():
            raise ValueError("The original Codex session cannot be verified")
    else:
        if not (Path.home() / ".gemini/antigravity-cli/conversations" / (entry["sessionId"] + ".db")).is_file():
            raise ValueError("The original Gemini conversation is missing")


def processes():
    """(pid, argv) for every process of this user that can be read."""
    for pid in os.listdir("/proc"):
        if not pid.isdigit():
            continue
        try:
            argv = Path("/proc", pid, "cmdline").read_bytes().decode(errors="replace").split("\0")
        except OSError:
            continue
        if argv and argv[0]:
            yield int(pid), [a for a in argv if a]


def native_lock_path(entry):
    if entry["agent"] == "codex":
        return Path.home() / ".codex/thread-writer-locks" / (entry["sessionId"] + ".lock")
    return Path.home() / ".gemini/antigravity-cli/presence" / (entry["sessionId"] + ".lock")


def lock_owners(path):
    """PIDs holding a kernel lock on `path`. An existing lock file alone proves nothing."""
    try:
        stat = path.stat()
    except FileNotFoundError:
        return []
    target = (os.major(stat.st_dev), os.minor(stat.st_dev), stat.st_ino)
    owners = []
    try:
        lines = Path("/proc/locks").read_text().splitlines()
    except OSError:
        return []
    for line in lines:
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
    """False while another process already holds this conversation open."""
    if entry.get("agent") == "command":
        return True
    if entry.get("agent") == "claude":
        return not any(entry["sessionId"] in argv for _, argv in processes())
    lock = native_lock_path(entry)
    if lock_owners(lock):
        return False
    try:
        with lock.open("rb") as handle:
            try:
                fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                return False
            fcntl.flock(handle, fcntl.LOCK_UN)
    except FileNotFoundError:
        pass
    return True


# ---------------------------------------------------------------- tmux

def tmux(data, *args, check=True):
    return subprocess.run(["tmux", "-L", data["tmuxSocket"], *args],
                          text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=check, timeout=15)


def live_sessions(data):
    """{session: (pane_id, pane_pid, cwd, dead)} for the socket the manifest watches."""
    result = tmux(data, "list-panes", "-a", "-F", "#{session_name}\t#{pane_id}\t#{pane_pid}\t#{pane_current_path}\t#{pane_dead}", check=False)
    out = {}
    for line in result.stdout.splitlines():
        sess, pane, pid, cwd, dead = line.split("\t")
        out.setdefault(sess, (pane, int(pid), cwd, dead == "1"))
    return out


def detect_agent(pane_pid):
    """(agent, sessionId, extra) read from the process running in the pane, or None."""
    try:
        children = subprocess.run(["pgrep", "-P", str(pane_pid)], capture_output=True, text=True).stdout.split()
    except OSError:
        return None
    for child in children:
        try:
            argv = [a for a in Path("/proc", child, "cmdline").read_bytes().decode(errors="replace").split("\0") if a]
        except OSError:
            continue
        exe = os.path.basename(argv[0]) if argv else ""
        ids = [a for a in argv if UUID.match(a)]
        if "claude" in exe and ids:
            return "claude", ids[0], {}
        if exe == "codex" and "resume" in argv and ids:
            extra = {}
            if "-m" in argv:
                extra["model"] = argv[argv.index("-m") + 1]
            for i, a in enumerate(argv):
                if a == "-c" and argv[i + 1].startswith("model_reasoning_effort="):
                    extra["reasoningEffort"] = json.loads(argv[i + 1].split("=", 1)[1])
            return "codex", ids[0], extra
        if exe == "agy" and ids:
            return "agy", ids[0], {}
    return None


# ---------------------------------------------------------------- actions

def snapshot(data, manifest_path):
    """Learns the sessions alive now. Adds new ones, refreshes known ones, never deletes."""
    known = {w["tmux"]: w for w in data["windows"]}
    changed = False
    for sess, (pane, pid, cwd, dead) in live_sessions(data).items():
        if dead:
            continue
        found = detect_agent(pid)
        if found is None:
            continue
        agent, session_id, extra = found
        entry = known.get(sess)
        if entry is None:
            entry = {"name": sess, "tmux": sess, "agent": agent, "sessionId": session_id, "cwd": cwd, "workspace": data.get("workspace", "")}
            entry.update(extra)
            data["windows"].append(entry); known[sess] = entry; changed = True
            print("Learned " + sess + " (" + agent + " " + session_id[:8] + ")", flush=True)
        else:
            fresh = {"agent": agent, "sessionId": session_id, "cwd": cwd, **extra}
            if any(entry.get(k) != v for k, v in fresh.items()):
                entry.update(fresh); changed = True
                print("Updated " + sess, flush=True)
    seen = {"bootId": boot_id(), "at": time.time(), "sessions": sorted(live_sessions(data))}
    if data.get("seen") != seen:
        data["seen"] = seen; changed = True
    if changed:
        save_manifest(manifest_path, data)


def missing_is_deliberate(data, missing):
    """A close by hand: same boot, tmux still up, and only some of the windows are gone."""
    seen = data.get("seen") or {}
    if seen.get("bootId") != boot_id():
        return False                      # rebooted: everything died, bring it all back
    if tmux(data, "list-sessions", check=False).returncode != 0:
        return False                      # tmux server itself is gone: crash, bring it back
    return len(missing) < len(data["windows"])


def ensure_windows(data, manifest_path):
    # One `has-session` per window first: it decides what is missing before anything is touched,
    # and a session with this name owned by someone else is never replaced.
    exists = {entry["tmux"]: tmux(data, "has-session", "-t", "=" + entry["tmux"], check=False).returncode == 0
              for entry in data["windows"]}
    missing = [entry for entry in data["windows"] if not exists[entry["tmux"]]]
    if missing and missing_is_deliberate(data, missing):
        for entry in missing:
            print("Forgetting " + entry["tmux"] + ": closed on purpose", flush=True)
            data["windows"].remove(entry)
        save_manifest(manifest_path, data)
    for entry in list(data["windows"]):
        target = "=" + entry["tmux"]
        launch = shlex.join([sys.executable, str(Path(__file__).resolve()), "--manifest", str(manifest_path), "launch", entry["tmux"]])
        if exists[entry["tmux"]]:
            owner = tmux(data, "show-option", "-v", "-t", target + ":", "@uniconnect_session_id", check=False).stdout.strip()
            if owner != entry.get("sessionId", ""):
                raise RuntimeError("Existing tmux target has different ownership: " + entry["tmux"])
            # Old tmux + newer ncurses can segfault on OSC 52 selection export; scope it to our server.
            tmux(data, "set-option", "-s", "set-clipboard", "off")
            panes = tmux(data, "list-panes", "-t", target + ":", "-F", "#{pane_id}\t#{pane_dead}").stdout.splitlines()
            if len(panes) == 1 and panes[0].endswith("\t1"):
                # No -k: tmux refuses to replace a live pane if it changes during this check.
                tmux(data, "respawn-pane", "-t", panes[0].split("\t")[0], "exec " + launch)
                print("Respawned " + entry["tmux"], flush=True)
            continue
        verify_session(entry)
        command_for(entry)
        result = tmux(data, "new-session", "-d", "-s", entry["tmux"], "-n", entry.get("name", entry["tmux"]),
                      "-c", entry["cwd"], "-x", "160", "-y", "45", "exec " + launch,
                      ";", "set-option", "-s", "set-clipboard", "off", check=False)
        if result.returncode != 0:
            if tmux(data, "has-session", "-t", target, check=False).returncode == 0:
                continue
            raise RuntimeError("tmux could not create " + entry["tmux"] + ": " + result.stderr.strip())
        for option, value in (("@uniconnect_session_id", entry.get("sessionId", "")),
                              ("@uniconnect_workspace", entry.get("workspace", "")), ("mouse", "on")):
            tmux(data, "set-option", "-t", target + ":", option, value)
        tmux(data, "set-window-option", "-t", target + ":", "automatic-rename", "off")
        tmux(data, "set-window-option", "-t", target + ":", "remain-on-exit", "on")
        print("Created " + entry["tmux"], flush=True)


def launch(entry, manifest_path):
    while True:
        try:
            return launch_once(entry, manifest_path)
        except Exception as error:  # noqa: BLE001 - the window must never die silently
            print("No se pudo lanzar: " + str(error) + ". Reintento en 30 segundos.", flush=True)
            time.sleep(30)


def launch_once(entry, manifest_path):
    verify_session(entry)
    lease_dir = manifest_path.parent / "launcher-locks"
    lease_dir.mkdir(mode=0o700, exist_ok=True)
    with (lease_dir / ((entry.get("sessionId") or entry["tmux"]) + ".lock")).open("a") as lease:
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
            if entry["agent"] == "claude":
                trust_folder_for_claude(entry["cwd"])
            child = subprocess.Popen(command_for(entry), cwd=entry["cwd"], env=environment_for(entry))
            while True:
                try:
                    code = child.wait(); break
                except KeyboardInterrupt:
                    continue
            if code:
                print("El cliente ha terminado con código " + str(code) + ". Reintento en 30 segundos; el historial se conserva.", flush=True)
                time.sleep(30)
                continue
            try:
                input("Sesión cerrada. Pulsa Intro para recuperar el mismo historial: ")
            except (EOFError, KeyboardInterrupt):
                return


def status(data):
    live = live_sessions(data)
    rows = []
    for entry in data["windows"]:
        alive = entry["tmux"] in live
        rows.append({"tmux": entry["tmux"], "agent": entry["agent"], "sessionId": entry.get("sessionId"),
                     "alive": alive, "dead_pane": live[entry["tmux"]][3] if alive else None,
                     "open_elsewhere": not native_session_available(entry) if entry["agent"] != "command" else None})
    print(json.dumps({"tmuxSocket": data["tmuxSocket"], "seen": data.get("seen"), "windows": rows}, indent=2, ensure_ascii=False))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("action", choices=("validate", "snapshot", "ensure", "supervise", "launch", "status", "forget"))
    parser.add_argument("name", nargs="?")
    args = parser.parse_args()
    manifest_path = args.manifest.resolve()
    data = load_manifest(manifest_path)
    if args.action == "validate":
        for entry in data["windows"]:
            verify_session(entry); command_for(entry)
        print("Verified " + str(len(data["windows"])) + " sessions; nothing started.")
    elif args.action == "snapshot":
        snapshot(data, manifest_path)
    elif args.action == "launch":
        entry = next((w for w in data["windows"] if w["tmux"] == args.name), None)
        if entry is None:
            raise ValueError("Unknown recovery window")
        launch(entry, manifest_path)
    elif args.action == "forget":
        data["windows"] = [w for w in data["windows"] if w["tmux"] != args.name]
        save_manifest(manifest_path, data)
    elif args.action == "status":
        status(data)
    elif args.action == "ensure":
        ensure_windows(data, manifest_path)
    else:
        while True:
            try:
                ensure_windows(data, manifest_path)
                snapshot(data, manifest_path)
            except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
                print("Recovery needs attention: " + str(error), file=sys.stderr, flush=True)
            time.sleep(15)


if __name__ == "__main__":
    main()
