"""Self-contained, metadata-only hook executed inside one managed tmux pane.

This file is passed to Python at launch, locally or over the existing SSH
transport. It does not install files or read provider transcripts/configuration.
"""

import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import time
import uuid


BOOTSTRAP = 'import base64,os;exec(base64.b64decode(os.environ["UNICONNECT_NATIVE_HELPER"]))'
GENERATION = "@uniconnect_native_generation"
IDENTITY = "@uniconnect_native_identity"
REVISION = "@uniconnect_native_revision"


def compact(value):
    return json.dumps(value, ensure_ascii=True, separators=(",", ":"))


def proc_identity(pid):
    fields = Path("/proc/%d/stat" % pid).read_text().rsplit(")", 1)[1].split()
    return int(fields[1]), fields[19]


def native_id(agent, payload):
    if agent == "claude" and payload.get("hook_event_name") == "SessionStart":
        value = payload.get("session_id")
    elif agent == "codex" and payload.get("type") == "agent-turn-complete":
        value = payload.get("thread-id")
    else:
        return None
    if not isinstance(value, str) or not re.fullmatch(r"[A-Za-z0-9_-]{1,160}", value):
        return None
    try:
        return str(uuid.UUID(value))
    except ValueError:
        return value


def tmux(*args):
    socket = os.environ["TMUX"].rsplit(",", 2)[0]
    return subprocess.run(["tmux", "-S", socket, *args], capture_output=True,
                          text=True, timeout=0.5, check=True).stdout.strip()


def signal(payload):
    emitted = time.time_ns()
    binding = json.loads(os.environ["UNICONNECT_NATIVE_BINDING"])
    session = native_id(binding["agent"], payload)
    pane = os.environ.get("TMUX_PANE", "")
    if not session or pane != binding["tmux_pane"] or not re.fullmatch(r"%[0-9]+", pane):
        return
    # An inherited environment alone is not proof: the emitting hook must still
    # descend from the precise launcher process, including its PID generation.
    pid = os.getppid()
    for _ in range(64):
        parent, started = proc_identity(pid)
        if pid == binding["agent_pid"]:
            if started != binding["agent_start"]:
                return
            break
        if parent <= 1 or parent == pid:
            return
        pid = parent
    else:
        return
    for _ in range(2):
        current = tmux("display-message", "-p", "-t", pane,
                       "#{pane_pid}\t#{" + GENERATION + "}\t#{" + REVISION + "}\t#{" + IDENTITY + "}").split("\t", 3)
        if (len(current) != 4 or current[0] != str(binding["pane_pid"])
                or current[1] != binding["generation"] or not re.fullmatch(r"[a-f0-9]{32}", current[2])):
            return
        previous = json.loads(current[3])
        if any(previous.get(key) != value for key, value in binding.items()) or previous.get("emitted_at_ns", 0) > emitted:
            return
        retired = previous.get("retired_ids", [])
        if session in retired:
            return
        old = previous.get("session_id")
        if old and old != session:
            # Startup/resume/compact may arrive late; only an explicit clear can
            # replace a confirmed Claude thread within this launcher generation.
            if binding["agent"] == "claude" and payload.get("source") != "clear":
                return
            retired = [*retired, old][-64:]
        if old == session:
            return
        proof = {**binding, "session_id": session, "retired_ids": retired,
                 "observed_at": time.time(), "emitted_at_ns": emitted}
        command = shlex.join(["set-option", "-p", "-t", pane, IDENTITY, compact(proof)])
        command += " ; " + shlex.join(["set-option", "-p", "-t", pane, REVISION, uuid.uuid4().hex])
        command += " ; " + shlex.join(["set-option", "-t", binding["tmux_session_id"],
                                       "@uniconnect_agent_owner", binding["agent"] + ":" + session.lower()])
        command += " ; display-message -p UC_PUBLISHED"
        # Compare-and-set both the launcher nonce and the previous revision at
        # the actual tmux mutation. A late hook cannot overwrite a newer signal.
        condition = "#{&&:#{==:#{" + GENERATION + "}," + binding["generation"] + "},#{==:#{" + REVISION + "}," + current[2] + "}}"
        if tmux("if-shell", "-F", "-t", pane, condition, command) == "UC_PUBLISHED":
            return


def launch(request):
    argv = request["argv"]
    original = list(argv)
    # tmux creation precedes the VTE client's environment scrub. Do not let a
    # parent coding-agent terminal donate its thread/window identity to this one.
    for key in ("CODEX_THREAD_ID", "CMUX_SURFACE_ID", "CMUX_WORKSPACE_ID", "UNICONNECT_NATIVE_BINDING"):
        os.environ.pop(key, None)
    os.environ["UNICONNECT_WINDOW_ID"] = request["window_id"]
    try:
        pane = os.environ.get("TMUX_PANE", "")
        if request["agent"] not in ("claude", "codex") or not re.fullmatch(r"%[0-9]+", pane):
            raise ValueError("unmanaged-pane")
        binding = {"version": 1, "window_id": request["window_id"], "agent": request["agent"],
                   "generation": uuid.uuid4().hex, "tmux_pane": pane,
                   "pane_pid": int(tmux("display-message", "-p", "-t", pane, "#{pane_pid}")),
                   "tmux_session_id": tmux("display-message", "-p", "-t", pane, "#{session_id}"),
                   "agent_pid": os.getpid(), "agent_start": proc_identity(os.getpid())[1]}
        tmux("set-option", "-p", "-t", pane, GENERATION, binding["generation"], ";",
             "set-option", "-p", "-t", pane, IDENTITY, compact(binding), ";",
             "set-option", "-p", "-t", pane, REVISION, uuid.uuid4().hex)
        os.environ["UNICONNECT_NATIVE_BINDING"] = compact(binding)
        hook = [sys.executable, "-c", BOOTSTRAP, "signal"]
        if binding["agent"] == "claude":
            settings = {"hooks": {"SessionStart": [{"matcher": "", "hooks": [
                {"type": "command", "command": shlex.join(hook), "timeout": 3}]}]}}
            argv += ["--settings", compact(settings)]
        else:
            # notify is scoped to this invocation. No global TOML is rewritten.
            argv += ["-c", "notify=" + compact(hook)]
    except Exception:
        # Identity integration is optional. A missing Python/tmux facility must
        # never prevent the user's agent from running in its existing terminal.
        argv = original
    os.execvpe(argv[0], argv, os.environ)


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "launch":
        launch(json.loads(sys.argv[2]))
    else:
        try:
            raw = sys.argv[2] if len(sys.argv) == 3 else sys.stdin.read(1024 * 1024 + 1)
            if len(raw) <= 1024 * 1024:
                signal(json.loads(raw))
        except Exception:
            pass  # No payload, prompt, error output, or blocking agent decision.
