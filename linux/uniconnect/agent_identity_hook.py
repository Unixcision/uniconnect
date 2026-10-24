"""Self-contained, metadata-only hook executed inside one managed tmux pane.

This file is passed to Python at launch, locally or over the existing SSH
transport. It does not install files or read provider transcripts/configuration.
"""

import json
import math
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import time
import uuid


BOOTSTRAP = 'import base64,os,zlib;exec(zlib.decompress(base64.b64decode(os.environ["UNICONNECT_NATIVE_HELPER"])))'
GENERATION = "@uniconnect_native_generation"
IDENTITY = "@uniconnect_native_identity"
REVISION = "@uniconnect_native_revision"


def compact(value):
    return json.dumps(value, ensure_ascii=True, separators=(",", ":"))


def proc_identity(pid):
    fields = Path("/proc/%d/stat" % pid).read_text().rsplit(")", 1)[1].split()
    return int(fields[1]), fields[19]


def native_id(agent, payload, event=None):
    if agent == "claude" and payload.get("hook_event_name") == "SessionStart":
        value = payload.get("session_id")
    elif agent == "codex" and payload.get("type") == "agent-turn-complete":
        value = payload.get("thread-id")
    elif agent in ("agy", "antigravity") and event == "statusline":
        value = payload.get("conversation_id") or payload.get("session_id")
    elif agent in ("agy", "antigravity") and event in ("SessionStart", "PreInvocation", "PostInvocation", "Stop"):
        value = payload.get("conversationId")
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


def _process(pid):
    """Read only the identity material needed to bind one statusLine child."""
    base = Path("/proc") / str(pid)
    parent, started = proc_identity(pid)
    argv = [part.decode(errors="replace") for part in (base / "cmdline").read_bytes().split(b"\0") if part]
    environ = dict(item.split("=", 1) for item in
                   (base / "environ").read_bytes().decode(errors="replace").split("\0") if "=" in item)
    return {"pid": pid, "parent": parent, "start": started, "argv": argv, "environ": environ,
            "cwd": os.readlink(base / "cwd")}


def _agy_binding(payload, session):
    """Adopt only the AGY process that emitted this exact pane's native statusLine.

    Older Antigravity processes may predate UniConnect's pane binding while still
    inheriting the exact UNICONNECT_WINDOW_ID and TMUX_PANE set by its SSH
    launcher. A statusLine child can safely establish that binding if its
    ancestor chain reaches the tmux pane process, the native conversation ID
    agrees with any explicit --conversation argument, and the pane has no
    competing UniConnect identity.
    """
    pane = os.environ.get("TMUX_PANE", "")
    window_id = os.environ.get("UNICONNECT_WINDOW_ID", "")
    if (not re.fullmatch(r"%[0-9]+", pane) or not re.fullmatch(r"[A-Za-z0-9_-]{1,160}", window_id)
            or not isinstance(session, str) or not re.fullmatch(r"[A-Za-z0-9_-]{1,160}", session)):
        return None
    try:
        end_marker = "|UNICONNECT_END"
        formatted = tmux("display-message", "-p", "-t", pane,
                      "#{pane_id}\t#{pane_pid}\t#{session_id}\t#{@uniconnect_native_generation}"
                      "\t#{@uniconnect_native_identity}\t#{@uniconnect_native_revision}" + end_marker)
        if not formatted.endswith(end_marker):
            return None
        fields = formatted[:-len(end_marker)].split("\t", 5)
        if len(fields) != 6 or fields[0] != pane or not fields[1].isdigit():
            return None
        pane_pid = int(fields[1])
        if not fields[2].startswith("$") or not fields[2][1:].isdigit():
            return None

        existing = None
        if any(fields[index] for index in (3, 4, 5)):
            # Reuse only a complete binding for this exact window/pane. A
            # partial or foreign set of options is never overwritten.
            if not (re.fullmatch(r"[a-f0-9]{32}", fields[3])
                    and re.fullmatch(r"[a-f0-9]{32}", fields[5]) and fields[4]):
                return None
            proof = json.loads(fields[4])
            keys = ("version", "window_id", "agent", "generation", "tmux_pane", "pane_pid",
                    "tmux_session_id", "agent_pid", "agent_start")
            existing = {key: proof.get(key) for key in keys}
            if (existing["version"] != 1 or existing["window_id"] != window_id or existing["agent"] != "agy"
                    or existing["generation"] != fields[3] or existing["tmux_pane"] != pane
                    or existing["pane_pid"] != pane_pid or existing["tmux_session_id"] != fields[2]
                    or not isinstance(existing["agent_pid"], int)
                    or not isinstance(existing["agent_start"], str)):
                return None

        pid, visited, matches = os.getppid(), set(), []
        reached_pane = False
        while pid > 1 and pid not in visited and len(visited) < 64:
            visited.add(pid)
            current = _process(pid)
            if current["environ"].get("TMUX_PANE") != pane:
                return None
            if current["environ"].get("UNICONNECT_WINDOW_ID") != window_id:
                return None
            argv = current["argv"]
            if argv and Path(argv[0]).name == "agy":
                explicit, index = [], 1
                while index < len(argv):
                    option, separator, inline = argv[index].partition("=")
                    if option == "--conversation":
                        value = inline if separator else argv[index + 1] if index + 1 < len(argv) else ""
                        explicit.append(value)
                        index += 1 if separator else 2
                    else:
                        index += 1
                if (len(explicit) <= 1 and (not explicit or explicit[0] == session)
                        and current["cwd"] == payload.get("cwd")):
                    matches.append(current)
            if pid == pane_pid:
                reached_pane = True
                break
            pid = current["parent"]
        if not reached_pane or len(matches) != 1:
            return None
        process = matches[0]
        if existing is not None:
            if process["pid"] != existing["agent_pid"] or process["start"] != existing["agent_start"]:
                return None
            binding = existing
        else:
            binding = {"version": 1, "window_id": window_id, "agent": "agy", "generation": uuid.uuid4().hex,
                       "tmux_pane": pane, "pane_pid": pane_pid, "tmux_session_id": fields[2],
                       "agent_pid": process["pid"], "agent_start": process["start"]}
            command = (shlex.join(["set-option", "-p", "-t", pane, GENERATION, binding["generation"]]) + " ; " +
                       shlex.join(["set-option", "-p", "-t", pane, IDENTITY, compact(binding)]) + " ; " +
                       shlex.join(["set-option", "-p", "-t", pane, REVISION, uuid.uuid4().hex]) +
                       " ; display-message -p UC_ADOPTED")
            condition = ("#{&&:#{==:#{" + GENERATION + "},},#{==:#{" + IDENTITY + "},},"
                         "#{==:#{" + REVISION + "},}}")
            if tmux("if-shell", "-F", "-t", pane, condition, command,
                    "display-message -p UC_REJECTED") != "UC_ADOPTED":
                return None
        return binding
    except (OSError, ValueError, KeyError, IndexError, subprocess.SubprocessError):
        return None


def agy_status(payload, event):
    """Project documented AGY metadata; never persist prompts or transcript content."""
    if event == "statusline":
        state = payload.get("agent_state")
        model = payload.get("model") if isinstance(payload.get("model"), dict) else {}
        model_id = model.get("id")
        model_name = model.get("display_name") or model.get("id")
        effort = model.get("effort")
        # Antigravity omits pending/task counts when they are zero, and omits
        # tool_confirmation_pending unless a confirmation is visible.
        pending = payload.get("pending_input_count", 0)
        tasks = payload.get("task_count", 0)
        confirmation = payload.get("tool_confirmation_pending", False)
        quota = payload.get("quota")
        buckets = list(quota.values()) if isinstance(quota, dict) else []
        exhausted = []
        for bucket in buckets:
            if not isinstance(bucket, dict):
                exhausted.append(None)
                continue
            if bucket.get("disabled") is True:
                exhausted.append(True)
                continue
            values = [bucket.get(key) for key in ("remaining_fraction", "remaining_amount")
                      if isinstance(bucket.get(key), (int, float)) and not isinstance(bucket.get(key), bool)
                      and math.isfinite(bucket.get(key))]
            exhausted.append(any(value <= 0 for value in values) if values else None)
        # One depleted model bucket is not proof that the account is blocked if
        # another bucket can still accept work. Unknown buckets fail closed.
        quota_paused = (True if exhausted and all(value is True for value in exhausted) else
                        False if any(value is False for value in exhausted) else None)
        sandbox = payload.get("sandbox") if isinstance(payload.get("sandbox"), dict) else {}
        sandbox_enabled = sandbox.get("enabled")
        cycle_mode = payload.get("cycle_mode")
        version = payload.get("version")
    else:
        model_id, model_name, effort = None, payload.get("modelName"), None
        pending, confirmation, tasks, quota_paused = None, None, None, None
        sandbox_enabled, cycle_mode, version = None, None, None
        if event == "PreInvocation":
            state = "working"
        elif event == "PostInvocation":
            # A finished model call may be followed by tools or another invocation.
            state = "working"
        elif event == "Stop":
            if payload.get("fullyIdle") is True and not payload.get("error"):
                state, tasks = "idle", 0
            elif payload.get("error"):
                state = "error"
            else:
                state = "working"
        else:
            state = "initializing"
    if state not in ("idle", "working", "tool_use", "reviewing", "authenticating", "initializing", "error"):
        state = "unknown"
    if not isinstance(model_name, str) or not model_name.strip() or len(model_name) > 160:
        model_name = None
    if not isinstance(model_id, str) or not re.fullmatch(r"[A-Za-z0-9._:/-]{1,160}", model_id):
        model_id = None
    if not isinstance(effort, str) or len(effort) > 32:
        effort = None
    if not isinstance(pending, int) or isinstance(pending, bool) or not 0 <= pending <= 10000:
        pending = None
    if not isinstance(tasks, int) or isinstance(tasks, bool) or not 0 <= tasks <= 10000:
        tasks = None
    if not isinstance(confirmation, bool):
        confirmation = None
    if not isinstance(sandbox_enabled, bool):
        sandbox_enabled = None
    if cycle_mode not in ("accept-edits", "auto", "plan"):
        cycle_mode = None
    if not isinstance(version, str) or not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version):
        version = None
    return {"state": state, "model": model_name, "model_id": model_id, "effort": effort, "pending_input_count": pending,
            "tool_confirmation_pending": confirmation, "task_count": tasks, "quota_paused": quota_paused,
            "fully_idle": payload.get("fullyIdle") is True if event == "Stop" else None,
            "sandbox_enabled": sandbox_enabled, "cycle_mode": cycle_mode, "version": version}


def signal(payload, event=None):
    emitted = time.time_ns()
    session = native_id("agy", payload, event)
    try:
        binding = json.loads(os.environ["UNICONNECT_NATIVE_BINDING"])
    except (KeyError, ValueError):
        if event != "statusline" or not session:
            return
        binding = _agy_binding(payload, session)
        if binding is None:
            return
        # The existing TUI cannot have its process environment edited in place.
        # Keep the adopted binding only in this statusLine child; subsequent
        # calls validate it against the pane options and the same process.
        os.environ["UNICONNECT_NATIVE_BINDING"] = compact(binding)
    session = native_id(binding["agent"], payload, event)
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
            # For AGY only SessionStart/statusline provide a current-ID boundary.
            if binding["agent"] == "claude" and payload.get("source") != "clear":
                return
            if binding["agent"] in ("agy", "antigravity") and event not in ("SessionStart", "statusline"):
                return
            retired = [*retired, old][-64:]
        runtime = agy_status(payload, event) if binding["agent"] in ("agy", "antigravity") else None
        if old == session and previous.get("runtime_status") == runtime:
            if binding["agent"] not in ("agy", "antigravity") or event != "statusline":
                return
            # Refresh an unchanged statusLine snapshot occasionally. Otherwise a quiet
            # pane could retain an old `idle` observation indefinitely and later appear
            # eligible for a close even if Antigravity stopped rendering updates.
            last_observed = previous.get("observed_at")
            if (isinstance(last_observed, (int, float)) and not isinstance(last_observed, bool)
                    and math.isfinite(last_observed) and time.time() - last_observed < 10):
                return
        proof = {**binding, "session_id": session, "retired_ids": retired,
                 "observed_at": time.time(), "emitted_at_ns": emitted}
        if runtime is not None:
            proof["runtime_status"] = runtime
        command = shlex.join(["set-option", "-p", "-t", pane, IDENTITY, compact(proof)])
        if runtime is not None:
            command += " ; " + shlex.join(["set-option", "-p", "-t", pane,
                                            "@uniconnect_native_status", compact({"generation": binding["generation"],
                                                "session_id": session, **runtime})])
        command += " ; " + shlex.join(["set-option", "-p", "-t", pane, REVISION, uuid.uuid4().hex])
        command += " ; " + shlex.join(["set-option", "-t", binding["tmux_session_id"],
                                       "@uniconnect_agent_owner", binding["agent"] + ":" + session.lower()])
        command += " ; display-message -p UC_PUBLISHED"
        # Compare-and-set both the launcher nonce and the previous revision at
        # the actual tmux mutation. A late hook cannot overwrite a newer signal.
        condition = "#{&&:#{==:#{" + GENERATION + "}," + binding["generation"] + "},#{==:#{" + REVISION + "}," + current[2] + "}}"
        if tmux("if-shell", "-F", "-t", pane, condition, command) == "UC_PUBLISHED":
            return


def statusline(payload):
    """Emit a concise statusline and update only a bound UniConnect pane."""
    state = agy_status(payload, "statusline")
    session = native_id("agy", payload, "statusline")
    if session:
        try:
            signal(payload, "statusline")
        except Exception:
            pass
    model = state.get("model") or "Antigravity"
    effort = " · " + state["effort"] if state.get("effort") else ""
    return "%s · %s%s · %s" % (state["state"], model, effort, session[:8] if session else "sin ID")


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
        if request["agent"] not in ("claude", "codex", "agy") or not re.fullmatch(r"%[0-9]+", pane):
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
        elif binding["agent"] == "codex":
            # Codex notify is scoped to this invocation. No global TOML is rewritten.
            argv += ["-c", "notify=" + compact(hook)]
        # Antigravity CLI hooks/statusLine are loaded from its documented
        # global/workspace config files, not an invocation flag. Keep the
        # pane-bound identity in the process environment and let its opt-in
        # statusLine publish metadata; never pass Codex's notify syntax to agy.
    except Exception:
        # Identity integration is optional. A missing Python/tmux facility must
        # never prevent a first launch from running in its existing terminal.
        # During a managed relaunch, however, silently falling back would start
        # an unbound process after the old one was closed. Fail visibly instead
        # of leaving UniConnect with stale identity and runtime metadata.
        if request.get("managed_identity") is True:
            raise
        argv = original
    os.execvpe(argv[0], argv, os.environ)


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "launch":
        launch(json.loads(sys.argv[2]))
    elif len(sys.argv) == 2 and sys.argv[1] == "statusline":
        try:
            raw = sys.stdin.read(1024 * 1024 + 1)
            if len(raw) <= 1024 * 1024:
                payload = json.loads(raw)
                print(statusline(payload))
        except Exception:
            pass
    elif len(sys.argv) == 3 and sys.argv[1] == "signal" and sys.argv[2] in (
            "SessionStart", "PreInvocation", "PostInvocation", "Stop"):
        try:
            raw = sys.stdin.read(1024 * 1024 + 1)
            if len(raw) <= 1024 * 1024:
                signal(json.loads(raw), sys.argv[2])
        except Exception:
            pass  # No payload, prompt, error output, or blocking agent decision.
    elif len(sys.argv) == 3 and sys.argv[1] == "signal":
        # Codex appends its notify payload as the final argv item. Keep that
        # provider protocol separate from stdin-based Claude/Antigravity hooks.
        try:
            raw = sys.argv[2]
            if len(raw) <= 1024 * 1024:
                signal(json.loads(raw))
        except Exception:
            pass
    else:
        try:
            raw = sys.stdin.read(1024 * 1024 + 1)
            if len(raw) <= 1024 * 1024:
                signal(json.loads(raw))
        except Exception:
            pass
