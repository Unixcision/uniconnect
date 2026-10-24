"""Self-contained Linux target adapter, executed over an existing SSH transport.

Private per-pane journals and a target-side flock arbitrate *all* viewing hosts.
No login/permission edits, tmux destruction, generic control keys or --last.
Only freshly proved native Claude/Codex processes can be stopped (D7: Codex by its
open rollout, Claude by its ~/.claude/sessions/<pid>.json in ``idle``). Everything
else is explicitly excluded until a provider-specific evidence adapter exists.

It travels as source text: RelaunchAgents puts resume_catalog.py in front of it, so
the no-prompt rule is the very same ``AgentResumeCatalog.apply_policy`` as on the desktop.
"""

import base64
from datetime import datetime
import fcntl
import hashlib
import json
import math
import os
from pathlib import Path
import re
import select
import shlex
import stat
import subprocess
import sys
import time
import uuid

try:
    from .resume_catalog import AgentResumeCatalog
except ImportError:
    # Sent as text (python3 -c): resume_catalog.py travels in front of this file.
    AgentResumeCatalog = globals()["AgentResumeCatalog"]

UUID = re.compile(r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}")
# The CLI changelog says v1.2.17 fixed task_count to include timers,
# recurring jobs and non-shell background work. Earlier versions cannot prove
# quiescence from the statusline, so they remain visible but not relaunchable.
AGY_MIN_SAFE_VERSION = (1, 2, 17)
AGY_STATUS_MAX_AGE_SECONDS = 15
# Claude's prompt line, with or without the box border of older versions.
CLAUDE_EXIT_LINE = re.compile(r"\s*│?\s*[›❯>]\s*/exit\s*│?\s*")
EMPTY_PROMPT_LINE = re.compile(r"\s*│?\s*[›❯>]\s*│?\s*")


class Unavailable(Exception):
    def __init__(self, cause):
        self.cause = cause


class TmuxOutputEvents:
    """Read-only control attachment: wait for real pane output, not sleep/poll."""
    def __init__(self, binary, session):
        self.process = subprocess.Popen([*binary, "-C", "attach-session", "-t", "=" + session,
                                         "-f", "read-only,ignore-size"], stdin=subprocess.PIPE,
                                        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, bufsize=0)

    def wait(self, deadline, clock, also=None):
        """Wait for pane output; True instead when ``also`` (a pidfd) becomes readable first."""
        remaining = deadline - clock()
        if remaining <= 0:
            raise Unavailable("dialogo_desconocido")
        ready, _, _ = select.select([self.process.stdout] + ([also] if also is not None else []), [], [], remaining)
        if also is not None and also in ready:
            return True
        if not ready or not os.read(self.process.stdout.fileno(), 65536):
            raise Unavailable("dialogo_desconocido")
        return False

    def close(self):
        self.process.stdin.close()
        try:
            self.process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            self.process.terminate()  # Only our own read-only control client.
            self.process.wait(timeout=2)
        self.process.stdout.close()


class TargetWorker:
    def __init__(self, request, *, proc=Path("/proc"), run=subprocess.run, clock=time.monotonic):
        self.request, self.proc, self.run, self.clock = request, proc, run, clock
        for field in ("session", "socket"):
            if not isinstance(request.get(field), str) or not re.fullmatch(r"[A-Za-z0-9_-]{1,40}", request[field]):
                raise Unavailable("no_soportado")
        self.binary = ["tmux", "-L", request["socket"]]

    def tmux(self, *args):
        result = self.run(self.binary + list(args), stdin=subprocess.DEVNULL, capture_output=True,
                          text=True, timeout=3)
        if result.returncode or len(result.stdout) > 262144:
            raise Unavailable("host_inaccesible")
        return result.stdout.rstrip("\n")

    def process(self, pid):
        path = self.proc / str(pid)
        if path.stat().st_uid != os.geteuid():
            raise Unavailable("sin_autoridad")
        fields = (path / "stat").read_text().rsplit(")", 1)[1].split()
        if fields[0] in ("Z", "X", "x"):
            raise ProcessLookupError()
        argv = (path / "cmdline").read_bytes().decode().rstrip("\0").split("\0")
        if len(argv) > 256 or sum(map(len, argv)) > 65536:
            raise Unavailable("no_soportado")
        return {"pid": pid, "parent": int(fields[1]), "group": int(fields[2]),
                "foreground": int(fields[5]), "start": fields[19], "argv": argv,
                "cwd": os.readlink(path / "cwd"), "executable": os.readlink(path / "exe")}

    def descendants(self, pid):
        found, queue = {}, [pid]
        while queue:
            parent = queue.pop()
            tasks = (self.proc / str(parent) / "task").glob("*/children")
            for task in tasks:
                try:
                    children = task.read_text().split()
                except OSError:
                    continue
                for child in children:
                    child = int(child)
                    if child in found:
                        continue
                    try:
                        found[child] = self.process(child)
                    except OSError:
                        continue
                    queue.append(child)
                    if len(found) > 256:
                        raise Unavailable("no_soportado")
        return found

    def pane(self):
        lines = self.tmux("list-panes", "-s", "-t", "=" + self.request["session"], "-F",
            "#{pane_id}\t#{pane_pid}\t#{session_id}\t#{socket_path}\t#{pid}\t#{pane_dead}\t#{pane_in_mode}\t#{@uniconnect_native_identity}").splitlines()
        if len(lines) != 1:
            raise Unavailable("identidad_ambigua")
        fields = lines[0].split("\t", 7)
        if len(fields) != 8 or fields[5] != "0":
            raise Unavailable("host_inaccesible")
        root = self.process(int(fields[1]))
        server = self.process(int(fields[4]))
        socket = Path(fields[3]).stat()
        if not stat.S_ISSOCK(socket.st_mode) or socket.st_uid != os.geteuid():
            raise Unavailable("sin_autoridad")
        identity = {"boot": (self.proc / "sys/kernel/random/boot_id").read_text().strip(),
                    "uid": os.geteuid(), "socket": fields[3], "server_start": server["start"],
                    "socket_inode": socket.st_ino, "pane": fields[0], "pane_pid": root["pid"],
                    "pane_start": root["start"], "session": fields[2]}
        return identity, root, fields[6], fields[7]

    @staticmethod
    def digest(value):
        return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":")).encode()).hexdigest()

    @staticmethod
    def is_provider(provider, argv):
        """Native process of ``provider``: Claude by name or its versions path, the rest by name."""
        first = argv[0] if argv else ""
        if provider == "claude":
            return Path(first).name == "claude" or "/claude/versions/" in first
        return Path(first).name == provider

    def claude_ficha(self, process):
        """``<CLAUDE_CONFIG_DIR or ~/.claude>/sessions/<pid>.json`` of this very process, or None.

        A ficha whose inner ``pid`` is another process (copied or restored) is not its own.
        """
        pid = process["pid"]
        try:
            raw = (self.proc / str(pid) / "environ").read_bytes()[:1048576]
            environ = dict(item.split("=", 1) for item in raw.decode(errors="replace").split("\0") if "=" in item)
        except OSError:
            environ = {}
        base = Path(environ.get("CLAUDE_CONFIG_DIR") or Path.home() / ".claude")
        try:
            descriptor = os.open(base / "sessions" / ("%d.json" % pid), os.O_RDONLY | os.O_NOFOLLOW)
        except OSError:
            return None
        with os.fdopen(descriptor, "rb") as handle:
            info = os.fstat(handle.fileno())
            if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid() or info.st_size > 65536:
                return None
            try:
                data = json.loads(handle.read(65537))
            except ValueError:
                return None
        if not isinstance(data, dict) or data.get("pid") not in (None, pid, str(pid)):
            return None
        return data

    def native_id(self, agent, process, hook, pane):
        if agent == "claude":
            # D7: only the ficha proves which conversation a live Claude has; argv lies after /clear.
            ficha = self.claude_ficha(process)
            identifier = ficha.get("sessionId") if ficha else None
            if not isinstance(identifier, str) or not re.fullmatch(r"[A-Za-z0-9_-]{1,160}", identifier):
                raise Unavailable("identidad_ambigua")
            return identifier
        identifiers = set()
        if hook:
            try:
                proof = json.loads(hook)
                if (proof.get("version") == 1 and proof.get("agent") == agent
                        and proof.get("tmux_pane") == pane["pane"] and proof.get("pane_pid") == pane["pane_pid"]
                        and proof.get("agent_pid") == process["pid"] and proof.get("agent_start") == process["start"]
                        and proof.get("session_id")):
                    identifiers.add(proof["session_id"])
            except (ValueError, TypeError):
                pass
        # Open writable transcript / held writer-lock belong to the live native
        # process, unlike a filename lying next to its cwd or a --resume argument.
        for fd in (self.proc / str(process["pid"]) / "fd").iterdir():
            try:
                target = os.readlink(fd)
                info = (self.proc / str(process["pid"]) / "fdinfo" / fd.name).read_text()
                if agent == "codex" and "/thread-writer-locks/" in target and "lock:" in info:
                    identifiers.add(Path(target).stem)
                elif target.endswith(".jsonl") and ((agent == "codex" and "/sessions/" in target and "rollout-" in target)
                                                      or (agent == "claude" and "/.claude/projects/" in target)):
                    flags = next((line.split()[1] for line in info.splitlines() if line.startswith("flags:")), "0")
                    if int(flags, 8) & os.O_ACCMODE not in (os.O_WRONLY, os.O_RDWR):
                        continue
                    with open(fd, "rb") as handle:
                        header = json.loads(handle.readline(65537))
                    value = header.get("payload", {}).get("id") if agent == "codex" else header.get("sessionId")
                    if value:
                        identifiers.add(value)
            except (OSError, ValueError, TypeError):
                continue
        if len(identifiers) != 1:
            raise Unavailable("identidad_ambigua")
        identifier = identifiers.pop()
        if not isinstance(identifier, str) or not re.fullmatch(r"[A-Za-z0-9_-]{1,160}", identifier):
            raise Unavailable("identidad_ambigua")
        return identifier

    def quiescent_configuration(self, provider, process, identifier, hook, *, allow_active=False):
        """Require native effective configuration and, by default, a completed turn.

        ``allow_active`` admits a known working Codex turn into a relaunch plan;
        its effective settings still have to match. A confirmed plan interrupts
        that turn and observes its native end before submitting /exit.
        Reads metadata only; no transcript contents leave the target.
        Claude (D7): its own ficha says ``idle`` for that same conversation.
        """
        if provider == "claude":
            ficha = self.claude_ficha(process)
            if not ficha or ficha.get("sessionId") != identifier:
                raise Unavailable("identidad_ambigua")
            if ficha.get("status") != "idle":
                raise Unavailable("dialogo_desconocido")
            return
        if provider in ("agy", "antigravity"):
            return self.antigravity_configuration(process, identifier, hook)
        if provider != "codex":
            raise Unavailable("no_soportado")
        paths = set()
        for fd in (self.proc / str(process["pid"]) / "fd").iterdir():
            try:
                target = Path(os.readlink(fd))
                if "rollout-" in target.name and target.suffix == ".jsonl":
                    paths.add(target)
                if target.parent.name == "thread-writer-locks" and target.stem == identifier:
                    # The effective id was already attributed to the held lock.
                    # Filename lookup only locates its transcript, never chooses id.
                    paths.update((target.parent.parent / "sessions").glob("*/*/*/*" + identifier + ".jsonl"))
            except OSError:
                continue
        if len(paths) != 1:
            raise Unavailable("no_soportado")
        path = paths.pop()
        descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
        with os.fdopen(descriptor, "rb") as handle:
            info = os.fstat(handle.fileno())
            if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid():
                raise Unavailable("sin_autoridad")
            header = json.loads(handle.readline(65537))
            if header.get("type") != "session_meta" or header.get("payload", {}).get("id") != identifier:
                raise Unavailable("identidad_ambigua")
            rows = self.codex_turn_metadata(handle, handle.tell(), info.st_size)
            latest = os.fstat(handle.fileno())
            if (latest.st_size, latest.st_mtime_ns) != (info.st_size, info.st_mtime_ns):
                # Do not omit a newly appended user/turn while reading backwards.
                raise Unavailable("dialogo_desconocido")
        return self.validate_quiescence(rows, process, allow_active=allow_active,
                                        process_birth=self.process_birth_bounds(process))

    @staticmethod
    def process_birth_bounds(process):
        """Conservative realtime interval for this Linux process' start tick.

        /proc/stat btime loses up to a second. Sample the realtime/boottime
        offset instead, including sampling duration and start-tick rounding.
        Unavailable or anomalous clocks disable only the fresh-instance proof.
        """
        try:
            before = time.time()
            boot = time.clock_gettime(time.CLOCK_BOOTTIME)
            after = time.time()
            ticks, frequency = int(process["start"]), os.sysconf("SC_CLK_TCK")
            if not 0 <= after - before <= 1 or frequency <= 0 or not 0 < ticks / frequency <= boot:
                return None
            return before - boot + ticks / frequency, after - boot + (ticks + 1) / frequency
        except (AttributeError, KeyError, OSError, TypeError, ValueError):
            return None

    @staticmethod
    def native_timestamp(value):
        if not isinstance(value, str):
            return None
        try:
            parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
            return parsed.timestamp() if parsed.tzinfo is not None else None
        except (ValueError, OverflowError):
            return None

    @staticmethod
    def codex_turn_metadata(handle, start, end):
        """Read the latest native context, however far back, without retaining transcript text.

        Keep only the newest event of each relevant kind, in file order. Older
        starts/settings/users are superseded; an older completion can at most
        make an ambiguous trace fail closed. Memory holds blocks, one JSON
        record and this small metadata set, never the complete history. Large
        completion records are parsed too: their message may exceed 64 KiB.
        """
        def backwards():
            position, fragments = end, []
            while position > start:
                previous = max(start, position - 65536)
                handle.seek(previous)
                block = handle.read(position - previous)
                if len(block) != position - previous:
                    raise Unavailable("dialogo_desconocido")
                position = previous
                pieces = block.split(b"\n")
                fragments.append(pieces.pop())
                while pieces:
                    yield b"".join(reversed(fragments))
                    fragments = [pieces.pop()]
            yield b"".join(reversed(fragments))

        rows, seen = [], set()
        for line in backwards():
            if not line:
                continue
            try:
                row = json.loads(line)
            except (ValueError, UnicodeError):
                raise Unavailable("no_soportado") from None
            if not isinstance(row, dict) or not isinstance(row.get("payload"), dict):
                raise Unavailable("no_soportado")
            kind, payload = row.get("type"), row["payload"]
            if kind == "turn_context":
                rows.append({"type": kind, "timestamp": row.get("timestamp"), "payload": {key: payload[key] for key in
                    ("turn_id", "model", "effort", "cwd", "approval_policy", "sandbox_policy") if key in payload}})
                break
            event = payload.get("type") if kind == "event_msg" else None
            if event in ("task_started", "task_complete", "turn_aborted"):
                key = event
                projected = {"type": event, "turn_id": payload.get("turn_id")}
            elif event == "thread_settings_applied":
                key = event
                projected = {"type": event, "thread_settings": payload.get("thread_settings")}
            elif event == "user_message" or (kind == "response_item" and payload.get("role") == "user"):
                key = "user_input"
                projected = {"type": event, "role": "user"}
            else:
                # A new instance must not have produced/received any other
                # native record either, even a dialect without task_started.
                key, kind, projected = "instance_activity", "instance_activity", {}
            if key not in seen:
                rows.append({"type": kind, "timestamp": row.get("timestamp"), "payload": projected})
                seen.add(key)
        rows.reverse()
        return rows

    @staticmethod
    def validate_quiescence(rows, process, *, allow_active=False, process_birth=None):
        context, settings, completed, active_turn, pending_input = None, None, False, None, False
        for row in rows:
            payload = row.get("payload", {})
            if row.get("type") == "turn_context":
                context = payload
                settings = None
                active_turn, completed = payload.get("turn_id"), False
                pending_input = False
            if row.get("type") == "event_msg":
                kind = payload.get("type")
                if kind == "task_started":
                    active_turn, completed = payload.get("turn_id"), False
                elif kind in ("task_complete", "turn_aborted"):
                    if (isinstance(active_turn, str) and active_turn and payload.get("turn_id") == active_turn
                            and context and context.get("turn_id") == active_turn):
                        completed = True
                        pending_input = False
                    else:
                        # A terminal event for another/unknown turn cannot
                        # leave an earlier active/completed proof in force.
                        active_turn, completed = None, False
                elif kind == "thread_settings_applied":
                    settings = payload.get("thread_settings")
                    if not isinstance(settings, dict):
                        raise Unavailable("no_soportado")
            if ((row.get("type") == "response_item" and payload.get("role") == "user")
                    or (row.get("type") == "event_msg" and payload.get("type") == "user_message")):
                # Codex may record the accepted user item just AFTER its turn
                # context. That is not an unsent draft. Only a user after a
                # completed turn needs a new context before an active proof.
                pending_input = pending_input or completed
                completed = False
        known_active = bool(allow_active and not pending_input and active_turn and context and context.get("turn_id") == active_turn)
        if known_active and process_birth:
            context_row = next(row for row in reversed(rows) if row.get("type") == "turn_context")
            context_time = TargetWorker.native_timestamp(context_row.get("timestamp"))
            known_active = context_time is not None and context_time >= process_birth[1]
        fresh_instance = False
        if process_birth and settings:
            lower, upper = process_birth
            timestamps = [TargetWorker.native_timestamp(row.get("timestamp")) for row in rows]
            if all(value is not None for value in timestamps) and timestamps == sorted(timestamps):
                fresh_settings = [stamp for row, stamp in zip(rows, timestamps)
                    if row.get("type") == "event_msg" and row.get("payload", {}).get("type") == "thread_settings_applied"]
                other = [stamp for row, stamp in zip(rows, timestamps)
                    if not (row.get("type") == "event_msg" and row.get("payload", {}).get("type") == "thread_settings_applied")]
                fresh_instance = bool(fresh_settings and fresh_settings[-1] >= upper
                                      and fresh_settings[-1] <= time.time()
                                      and all(stamp < lower for stamp in other))
        if not fresh_instance and (not context or (not completed and not known_active)):
            raise Unavailable("dialogo_desconocido")
        # Do not silently convert an in-UI model/permission change back to argv.
        # Profiles/defaults need a richer effective-settings adapter; exclude now.
        argv = process["argv"][1:]
        explicit, effort = {}, None
        for index, value in enumerate(argv):
            option, _, inline = value.partition("=")
            if option in ("--model", "-m", "--sandbox", "-s", "--ask-for-approval", "-a"):
                explicit[option] = inline if "=" in value else (argv[index + 1] if index + 1 < len(argv) else None)
            if option in ("--cd", "-C"):
                directory = inline if "=" in value else (argv[index + 1] if index + 1 < len(argv) else None)
                if directory != process["cwd"]:
                    raise Unavailable("no_soportado")
            if option in ("--profile", "-p"):
                raise Unavailable("no_soportado")
            if option in ("--config", "-c"):
                config = inline if "=" in value else (argv[index + 1] if index + 1 < len(argv) else "")
                if config.startswith("model_reasoning_effort="):
                    try:
                        effort = json.loads(config.partition("=")[2])
                    except ValueError:
                        raise Unavailable("no_soportado") from None
        model = explicit.get("--model", explicit.get("-m"))
        sandbox = explicit.get("--sandbox", explicit.get("-s"))
        approval = explicit.get("--ask-for-approval", explicit.get("-a"))
        # Codex exposes ``--yolo`` as the concise spelling of the same
        # full-access/never-ask policy.  The Linux launcher uses this form;
        # treating it as an ordinary unknown switch made the relaunch action
        # reject otherwise identical, quiescent sessions as unsupported.
        bypass = ("--dangerously-bypass-approvals-and-sandbox" in argv
                  or "--yolo" in argv)
        if bypass:
            sandbox, approval = "danger-full-access", "never"
        # A resume emits current settings without creating another turn_context.
        # The old completed turn proves inactivity, not today's launch settings.
        effective = context
        if settings is not None:
            if not all(key in settings for key in ("model", "reasoning_effort", "cwd", "approval_policy", "permission_profile")):
                raise Unavailable("no_soportado")
            if settings.get("permission_profile") != {"type": "disabled"}:
                raise Unavailable("no_soportado")
            effective = {"model": settings.get("model"), "effort": settings.get("reasoning_effort"),
                         "cwd": settings.get("cwd"), "approval_policy": settings.get("approval_policy"),
                         "sandbox_policy": {"type": "danger-full-access"}}
        actual_sandbox = effective.get("sandbox_policy", {}).get("type")
        if (((not model) and not bypass) or (model and model != effective.get("model"))
                or not sandbox or not approval
                or sandbox != actual_sandbox or approval != effective.get("approval_policy")
                or effective.get("cwd") != process["cwd"]):
            raise Unavailable("no_soportado")
        if effective.get("effort") != effort and not (effort is None and settings is not None):
            raise Unavailable("no_soportado")
        if not isinstance(effective.get("model"), str) or not effective["model"]:
            raise Unavailable("no_soportado")
        # Expanded writable roots and profile changes cannot be reconstructed
        # safely from just the three CLI flags. Reject, don't widen permissions.
        if sandbox not in ("read-only", "danger-full-access"):
            raise Unavailable("no_soportado")
        if settings is not None and settings.get("permission_profile"):
            profile = settings["permission_profile"]
            if profile != {"type": "disabled"} or sandbox != "danger-full-access":
                raise Unavailable("no_soportado")
        return {key: effective.get(key) for key in ("model", "effort", "cwd", "approval_policy", "sandbox_policy")}

    def antigravity_configuration(self, process, identifier, hook):
        """Require pane/process-bound recent native idle evidence before AGY exit."""
        try:
            proof = json.loads(hook)
            runtime = proof.get("runtime_status")
            version = runtime.get("version") if isinstance(runtime, dict) else None
            version_tuple = tuple(int(part) for part in version.split(".")) if isinstance(version, str) else ()
            observed = proof.get("observed_at")
            birth = self.process_birth_bounds(process)
            now = time.time()
            if (proof.get("version") != 1 or proof.get("window_id") != self.request.get("window_id")
                    or proof.get("agent") not in ("agy", "antigravity")
                    or proof.get("agent_pid") != process["pid"] or proof.get("agent_start") != process["start"]
                    or proof.get("session_id") != identifier or not isinstance(runtime, dict)
                    or len(version_tuple) != 3 or version_tuple < AGY_MIN_SAFE_VERSION
                    or not isinstance(observed, (int, float)) or isinstance(observed, bool) or not math.isfinite(observed)
                    or observed > now + 2 or now - observed > AGY_STATUS_MAX_AGE_SECONDS
                    or (birth and observed < birth[0])):
                raise Unavailable("no_soportado")
        except (ValueError, TypeError, AttributeError, OverflowError):
            raise Unavailable("identidad_ambigua") from None
        if (runtime.get("state") != "idle" or runtime.get("pending_input_count") != 0
                or runtime.get("tool_confirmation_pending") is not False or runtime.get("task_count") != 0
                or not isinstance(runtime.get("sandbox_enabled"), bool)):
            raise Unavailable("dialogo_desconocido")
        model_id = runtime.get("model_id")
        if not isinstance(model_id, str) or not model_id.strip() or len(model_id) > 160 or "\0" in model_id:
            raise Unavailable("no_soportado")
        effort = runtime.get("effort")
        if effort is not None and effort not in ("low", "medium", "high", "max"):
            raise Unavailable("no_soportado")
        cycle_mode = runtime.get("cycle_mode")
        if cycle_mode is not None and cycle_mode not in ("accept-edits", "auto", "plan"):
            raise Unavailable("no_soportado")
        return {"model": model_id, "effort": effort, "cycle_mode": cycle_mode,
                "sandbox_enabled": runtime["sandbox_enabled"], "version": version}

    @staticmethod
    def preserve_antigravity_configuration(argv, configuration):
        """Resume the observed model/mode/sandbox state; never infer a permission upgrade."""
        if not isinstance(configuration, dict):
            raise Unavailable("no_soportado")
        arguments = list(argv[1:])
        values = {"--model": configuration.get("model"), "--effort": configuration.get("effort"),
                  "--mode": configuration.get("cycle_mode")}
        actual, index = {}, 0
        sandbox = False
        while index < len(arguments):
            token = arguments[index]
            option, separator, inline = token.partition("=")
            if option in values:
                value = inline if separator else (arguments[index + 1] if index + 1 < len(arguments) else None)
                if option in actual:
                    raise Unavailable("no_soportado")
                actual[option] = value
                index += 1 if separator else 2
                continue
            if token == "--sandbox":
                sandbox = True
            index += 1
        added = []
        for option, expected in values.items():
            if expected is None:
                if option in actual:
                    raise Unavailable("no_soportado")
            elif option in actual:
                if actual[option] != expected:
                    raise Unavailable("no_soportado")
            else:
                added.extend((option, expected))
        sandbox_enabled = configuration.get("sandbox_enabled")
        if sandbox and sandbox_enabled is not True:
            raise Unavailable("no_soportado")
        if sandbox_enabled is True and not sandbox:
            added.append("--sandbox")
        elif sandbox_enabled is not False:
            raise Unavailable("no_soportado")
        # Resume selectors can safely follow options; keeping them adjacent
        # makes the effective command easy to reason about and test.
        return [argv[0], *added, *arguments]

    def managed_antigravity(self, env, process, pane, hook):
        """Rewrap only a pane whose current native proof matches its live launch binding."""
        try:
            binding = json.loads(env.get("UNICONNECT_NATIVE_BINDING", ""))
            proof = json.loads(hook)
        except (ValueError, TypeError):
            return False
        required = ("version", "window_id", "agent", "generation", "tmux_pane", "pane_pid",
                    "tmux_session_id", "agent_pid", "agent_start")
        return (all(key in binding and proof.get(key) == binding[key] for key in required)
                and binding.get("agent") == "agy" and binding.get("window_id") == self.request.get("window_id")
                and binding.get("tmux_pane") == pane.get("pane")
                and binding.get("pane_pid") == pane.get("pane_pid")
                and binding.get("agent_pid") == process.get("pid")
                and binding.get("agent_start") == process.get("start"))

    @staticmethod
    def preserve_resume_permissions(provider, native_configuration, resume):
        """Reject when Codex's forced no-prompt dialect would widen its access."""
        if (provider == "codex" and native_configuration is not None and "--yolo" in resume
                and (native_configuration.get("sandbox_policy", {}).get("type") != "danger-full-access"
                     or native_configuration.get("approval_policy") != "never")):
            raise Unavailable("no_soportado")

    @staticmethod
    def resume_arguments(provider, argv, identifier, catalog):
        """Retain explicit options, remove ONLY the previous conversation selector.

        Unknown positional inputs or noninteractive subcommands are excluded;
        never replay the original prompt, fork, exec, login, or --last.
        """
        if provider in ("agy", "antigravity"):
            return TargetWorker.antigravity_resume_arguments(argv, identifier, catalog)

        arguments = list(argv[1:])
        resumed = removed_id = False
        values = ({"-c", "--config", "-m", "--model", "-C", "--cd", "-s", "--sandbox", "-a", "--ask-for-approval",
                   "-p", "--profile", "--add-dir", "--enable", "--disable"} if provider == "codex" else
                  {"--model", "--permission-mode", "--settings", "--setting-sources", "--add-dir", "--allowedTools",
                   "--disallowedTools", "--mcp-config", "--tools", "--system-prompt", "--append-system-prompt"})
        switches = ({"--no-alt-screen", "--search", "--full-auto", "--dangerously-bypass-approvals-and-sandbox", "--yolo"}
                    if provider == "codex" else {"--dangerously-skip-permissions", "--verbose", "--strict-mcp-config"})
        kept, index = [], 0
        while index < len(arguments):
            arg = arguments[index]
            if provider == "codex" and not resumed and arg == "resume":
                # The subcommand may follow global switches: ``codex --yolo resume <id>``.
                resumed = True
                index += 1
                continue
            if resumed and not removed_id and not arg.startswith("-") and re.fullmatch(r"[A-Za-z0-9_-]{1,160}", arg):
                removed_id = True
                index += 1
                continue
            if provider == "claude" and arg in ("--resume", "-r", "--session-id"):
                if index + 1 >= len(arguments) or arguments[index + 1].startswith("-"):
                    raise Unavailable("no_soportado")
                index += 2
                continue
            if arg in ("--last", "--all", "--continue", "-c") and (provider == "claude" or arg != "-c"):
                if arg == "--all" and provider != "codex":
                    raise Unavailable("no_soportado")
                index += 1
                continue
            option = arg.split("=", 1)[0]
            if option in values:
                value = arg.split("=", 1)[1] if "=" in arg else (arguments[index + 1] if index + 1 < len(arguments) else "")
                if TargetWorker.managed_hook(provider, option, value):
                    index += 1 if "=" in arg else 2
                    continue
                kept.append(arg)
                if "=" not in arg:
                    if index + 1 >= len(arguments):
                        raise Unavailable("no_soportado")
                    kept.append(arguments[index + 1])
                    index += 1
            elif arg in switches:
                kept.append(arg)
            else:
                raise Unavailable("no_soportado")
            index += 1
        # Preserve terminal scrollback across the Linux relaunch, even when the
        # old Codex instance used its own alternate-screen transcript.
        if provider == "codex" and "--no-alt-screen" not in kept:
            kept.append("--no-alt-screen")
        substitutions = {"{executable}": [argv[0]], "{sessionId}": [identifier], "{arguments}": kept}
        return TargetWorker.no_prompt(provider, [part for token in catalog[provider]["resume"]
                                                 for part in substitutions.get(token, [token])], catalog)

    @staticmethod
    def antigravity_resume_arguments(argv, identifier, catalog):
        """Build an AGY resume without replaying a prompt or widening permissions.

        Antigravity's no-prompt catalog flag is a launch default, not proof that
        an existing session used it. Keep it only when it was present in that
        exact process's argv; never add it during a resume.
        """
        provider = next((value for value in catalog.values()
                         if "agy" in value.get("aliases", []) or value.get("executable") == "agy"), None)
        if not provider or not isinstance(identifier, str) or not identifier:
            raise Unavailable("no_soportado")

        arguments = list(argv[1:])
        value_options = {"--model", "--effort", "--mode", "--project", "--agent", "--add-dir"}
        boolean_options = {"--sandbox", "--remote-control", "--dangerously-skip-permissions"}
        kept, seen_conversation, seen_single, index = [], False, set(), 0
        seen_boolean = set()
        while index < len(arguments):
            arg = arguments[index]
            option, separator, inline_value = arg.partition("=")
            if option == "--conversation":
                value = inline_value if separator else (arguments[index + 1] if index + 1 < len(arguments) else "")
                if seen_conversation or value != identifier:
                    raise Unavailable("identidad_ambigua")
                seen_conversation = True
                index += 1 if separator else 2
                continue
            if option in value_options:
                value = inline_value if separator else (arguments[index + 1] if index + 1 < len(arguments) else "")
                if not value or value.startswith("-"):
                    raise Unavailable("no_soportado")
                if option != "--add-dir" and option in seen_single:
                    raise Unavailable("no_soportado")
                if option != "--add-dir":
                    seen_single.add(option)
                kept.append(arg)
                if not separator:
                    kept.append(value)
                    index += 1
                index += 1
                continue
            if arg in boolean_options:
                if arg in seen_boolean:
                    raise Unavailable("no_soportado")
                seen_boolean.add(arg)
                kept.append(arg)
            else:
                # Includes --continue, prompts, subcommands, and options whose
                # semantics this adapter has not explicitly verified.
                raise Unavailable("no_soportado")
            index += 1
        if not seen_conversation:
            raise Unavailable("identidad_ambigua")

        substitutions = {"{executable}": [argv[0]], "{sessionId}": [identifier], "{arguments}": kept}
        return [part for token in provider["resume"] for part in substitutions.get(token, [token])]

    @staticmethod
    def no_prompt(provider, argv, catalog):
        """Relaunch always without questions (Dani, 24-09), with the shared catalogue's ``noPrompt``.

        The very same function as the desktop (AgentResumeCatalog.apply_policy), fed with
        the catalogue received in the request: ``supersedes`` (Codex: -a/-s/--full-auto,
        which its CLI rejects next to --yolo) comes from there, never from a list here.
        """
        if provider in ("agy", "antigravity"):
            # Do not turn a previously restricted live Antigravity process into
            # --dangerously-skip-permissions merely because its catalogue has a
            # default for newly-created windows. resume_arguments preserves the
            # flag only if it was already present in the original argv.
            return list(argv)
        return AgentResumeCatalog.apply_policy((catalog.get(provider) or {}).get("noPrompt"), argv)

    @staticmethod
    def managed_hook(provider, option, value):
        bootstrap = 'import base64,os,zlib;exec(zlib.decompress(base64.b64decode(os.environ["UNICONNECT_NATIVE_HELPER"])))'
        try:
            if provider == "codex" and option in ("-c", "--config") and value.startswith("notify="):
                hook = json.loads(value.removeprefix("notify="))
                return isinstance(hook, list) and len(hook) == 4 and hook[1:] == ["-c", bootstrap, "signal"]
            if provider == "claude" and option == "--settings":
                settings = json.loads(value)
                events = settings["hooks"]["SessionStart"]
                hook = events[0]["hooks"][0]
                command = shlex.split(hook["command"])
                return (set(settings) == {"hooks"} and set(settings["hooks"]) == {"SessionStart"}
                        and len(events) == 1 and len(events[0]["hooks"]) == 1
                        and hook["type"] == "command" and len(command) == 4 and command[1:] == ["-c", bootstrap, "signal"])
        except (ValueError, KeyError, TypeError, IndexError):
            pass
        return False

    def inspect(self, *, runtime=False):
        pane, root, mode, hook = self.pane()
        if self.request.get("verb") == "transport.reconnect":
            generation = int(self.digest(pane)[:12], 16)
            return {"key": "linux:" + self.digest(pane), "generation": generation, "pane": pane}
        provider = self.request.get("provider")
        if provider not in ("codex", "claude", "agy") or provider not in self.request["catalog"]:
            raise Unavailable("no_soportado")
        if self.request.get("verb") in ("agent.continue", "agent.recover") and provider != "codex":
            raise Unavailable("no_soportado")
        if mode != "0":
            raise Unavailable("dialogo_desconocido")
        children = self.descendants(root["pid"])
        matches = [p for p in children.values() if self.is_provider(provider, p["argv"])]
        if len(matches) != 1:
            raise Unavailable("identidad_ambigua")
        process = matches[0]
        effective = self.native_id(provider, process, hook, pane)
        activity = {}
        native_configuration = None
        if provider == "codex":
            activity = self.codex_activity(self.tmux("capture-pane", "-p", "-t", pane["pane"]).splitlines())
            # Only a relaunch plan or its confirmed active target may admit work.
            # Identity and effective configuration are still proved natively.
            allow_active = (self.request.get("verb") == "agent.relaunch"
                            or self.request.get("expected", {}).get("active") is True)
            if any(activity.values()) and not allow_active:
                raise Unavailable("tareas_de_fondo")
            native_configuration = self.quiescent_configuration(provider, process, effective, hook,
                                                                allow_active=allow_active and activity["working"])
            lines = self.tmux("capture-pane", "-p", "-t", pane["pane"]).splitlines()
            needs_quota = self.request.get("verb") in ("agent.continue", "agent.recover") and not self.request.get("resumed")
            if needs_quota and not self.codex_quota_pause(lines):
                raise Unavailable("no_soportado")
        else:
            self.quiescent_configuration(provider, process, effective, hook)
        if self.request.get("action") == "inspect":
            self.require_empty_composer({"pane": pane}, allow_active=provider == "codex"
                                         and self.request.get("verb") == "agent.relaunch")
        launcher = None
        # Only the exact bundled recovery launcher has a known wait/restart
        # protocol. All other supervisors remain excluded.
        if Path(root["argv"][0]).name.lstrip("-") not in ("bash", "zsh", "sh"):
            launcher = self.recovery_launcher(root, process, effective)
        elif any(arg not in ("-l", "-i", "--login", "--noprofile", "--norc") for arg in root["argv"][1:]):
            # Only our known bootstrap ends deterministically in an interactive
            # shell. Do not stop an agent owned by a recovery/custom supervisor.
            if not (len(root["argv"]) == 3 and root["argv"][1] == "-lc"
                    and "UNICONNECT_NATIVE_HELPER=" in root["argv"][2]
                    and root["argv"][2].endswith('exec "${SHELL:-/bin/sh}" -l')):
                raise Unavailable("no_soportado")
        resume = self.resume_arguments(provider, [process["executable"], *process["argv"][1:]], effective, self.request["catalog"])
        if provider == "agy":
            resume = self.preserve_antigravity_configuration(resume, native_configuration)
        self.preserve_resume_permissions(provider, native_configuration, resume)
        generation = int(self.digest({"pane": pane, "pid": process["pid"], "start": process["start"], "id": effective})[:12], 16)
        configuration = {"cwd": process["cwd"], "argv": resume}
        if native_configuration is not None:
            configuration.update({key: native_configuration.get(key) for key in ("model", "effort")})
        proof = {"key": "linux:" + self.digest(pane) + "|gen:" + str(generation), "generation": generation,
                 "pane": pane, "pid": process["pid"], "start": process["start"], "effective_id": effective,
                 "configuration": self.digest(configuration)}
        if launcher:
            proof["launcher"] = launcher
        if native_configuration is not None:
            # UI model/effort changes can leave argv untouched. Revalidate the
            # native effective settings before closing, separately from resume argv.
            proof["native_configuration"] = self.digest(native_configuration)
        if any(activity.values()):
            proof["active"] = True
        if provider == "codex" and self.request.get("verb") in ("agent.continue", "agent.recover"):
            proof["quota_paused"] = True
        if runtime:
            return proof, root, process, resume
        return proof

    def recovery_launcher(self, root, process, effective):
        """Recognize code and manifest; never execute a supervisor to probe it."""
        args = root["argv"]
        # Dos formas del lanzador: la de siempre (6 argumentos) y la de recovery.launch_command,
        # que añade --socket S (8). El socket explícito tiene que ser el de esta petición.
        if len(args) == 8 and args[4] == "--socket":
            socket, tail = args[5], args[6:]
        elif len(args) == 6:
            socket, tail = None, args[4:]
        else:
            raise Unavailable("no_soportado")
        if (self.request.get("provider") != "codex"
                or Path(args[0]).name not in ("python", "python3")
                or args[2] != "--manifest" or tail != ["launch", self.request["session"]]
                or (socket is not None and socket != self.request["socket"])):
            raise Unavailable("no_soportado")
        expected = self.request.get("recovery_sha256")
        if not isinstance(expected, str) or not re.fullmatch(r"[a-f0-9]{64}", expected):
            raise Unavailable("no_soportado")
        descriptor = os.open(args[1], os.O_RDONLY | os.O_NOFOLLOW)
        with os.fdopen(descriptor, "rb") as handle:
            info = os.fstat(handle.fileno())
            if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid()
                    or info.st_mode & 0o022 or info.st_size > 262144):
                raise Unavailable("sin_autoridad")
            if hashlib.sha256(handle.read()).hexdigest() != expected:
                raise Unavailable("no_soportado")
        data = self.read(Path(args[3]))
        entries = [w for w in data.get("windows", []) if w.get("tmux") == self.request["session"]]
        # Con varios sockets vigilados, cada entrada puede llevar el suyo; si no, manda el del manifiesto.
        if len(entries) != 1 or (entries[0].get("tmuxSocket") or data.get("tmuxSocket")) != self.request["socket"]:
            raise Unavailable("identidad_ambigua")
        entry = entries[0]
        if entry.get("agent") != "codex" or entry.get("sessionId") != effective or entry.get("cwd") != process["cwd"]:
            raise Unavailable("identidad_ambigua")
        # Match what this reviewed launcher would run with what is actually
        # running. A stale/on-disk-only manifest is not sufficient authority.
        options = ["-C", entry["cwd"]]
        if entry.get("model"):
            options += ["-m", entry["model"]]
        if entry.get("reasoningEffort"):
            options += ["-c", "model_reasoning_effort=" + json.dumps(entry["reasoningEffort"])]
        # Keep the previous launch forms and the Linux inline form produced by command_for.
        forms = (["resume", *options, "--dangerously-bypass-approvals-and-sandbox", effective],
                 ["--yolo", "resume", effective, *options],
                 ["--yolo", "resume", effective, *options, "--no-alt-screen"])
        if process["argv"][1:] not in forms:
            raise Unavailable("no_soportado")
        return {"source": expected, "manifest": self.digest(entry), "session_id": effective}

    def paths(self):
        operation = self.request.get("operation_id")
        if not isinstance(operation, str) or str(uuid.UUID(operation)) != operation:
            raise Unavailable("sin_autoridad")
        expected = self.request["expected"]
        key = self.digest(expected["pane"])
        root = Path.home() / ".local/state/uniconnect/relaunch-v1"
        root.mkdir(parents=True, exist_ok=True, mode=0o700)
        info = root.lstat()
        if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.geteuid() or info.st_mode & 0o077:
            raise Unavailable("sin_autoridad")
        return root / (key + ".lock"), root / (key + ".json"), root / (key + "-" + operation + ".json")

    @staticmethod
    def write(path, value):
        temporary = path.with_name(path.name + "." + uuid.uuid4().hex)
        descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        try:
            with os.fdopen(descriptor, "w") as handle:
                json.dump(value, handle)
                handle.flush()
                os.fsync(handle.fileno())
            os.replace(temporary, path)
        finally:
            temporary.unlink(missing_ok=True)

    @staticmethod
    def read(path):
        descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
        with os.fdopen(descriptor) as handle:
            info = os.fstat(handle.fileno())
            if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid() or info.st_size > 65536:
                raise Unavailable("sin_autoridad")
            return json.load(handle)

    def start(self):
        lock_path, claim_path, journal = self.paths()
        fd = os.open(lock_path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
        try:
            info = os.fstat(fd)
            if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid():
                raise Unavailable("sin_autoridad")
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            os.close(fd)
            if journal.exists():
                return self.read(journal)
            return {"state": "omitido", "cause": "duplicado"}
        expected = self.request["expected"]
        try:
            if journal.exists():
                return self.read(journal)
            if claim_path.exists() and self.read(claim_path).get("generation") == expected["generation"]:
                result = {"state": "omitido", "cause": "duplicado"}
                self.write(journal, result)
                return result
            if not self.same_target(self.inspect(), expected):
                result = {"state": "omitido", "cause": "generacion_cambiada"}
                self.write(journal, result)
                return result
            self.write(claim_path, {"generation": expected["generation"], "operation_id": self.request["operation_id"]})
            self.write(journal, {"state": "planificado"})
            child = os.fork()
            if child:
                return {"state": "planificado"}
            os.setsid()
            null = os.open(os.devnull, os.O_RDWR)
            for target in (0, 1, 2):
                os.dup2(null, target)
            os.close(null)
            try:
                # Codex clients share SQLite databases. Serialize the bounded
                # close/start transaction on the destination, across viewers,
                # rather than starting every pane concurrently after login.
                account = os.open(lock_path.with_name("account-startup.lock"),
                                  os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
                try:
                    info = os.fstat(account)
                    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid():
                        raise Unavailable("sin_autoridad")
                    fcntl.flock(account, fcntl.LOCK_EX)
                    self.perform(journal)
                finally:
                    os.close(account)
            except BaseException as error:
                if self.read(journal).get("state") == "planificado":
                    # No close was attempted. Allow a NEW confirmed plan once
                    # the draft/permission problem is resolved by the person.
                    self.write(claim_path, {"released": True, "operation_id": self.request["operation_id"]})
                self.write(journal, {"state": "necesita_usuario", "cause": getattr(error, "cause", "host_inaccesible")})
            finally:
                os.close(fd)
                os._exit(0)
        finally:
            os.close(fd)

    def perform(self, journal):
        proof, root, process, resume = self.inspect(runtime=True)
        if not self.same_target(proof, self.request["expected"]):
            raise Unavailable("generacion_cambiada")
        if self.request.get("verb") == "agent.recover" and self.request.get("provider") != "codex":
            raise Unavailable("no_soportado")
        # Keep the consent from the confirmed plan if the turn has just finished.
        proof = self.request["expected"]
        self.require_empty_composer(proof, allow_active=proof.get("active") is True)
        if self.request.get("verb") == "agent.continue":
            if not self.codex_quota_pause(self.tmux("capture-pane", "-p", "-t", proof["pane"]["pane"]).splitlines()):
                raise Unavailable("generacion_cambiada")
            self.continue_codex(proof, process, journal)
            return
        if proof.get("launcher"):
            events = TmuxOutputEvents(self.binary, self.request["session"])
            try:
                self.restart_recovery(proof, root, process, journal, events)
            finally:
                events.close()
            if self.request.get("verb") == "agent.recover":
                self.continue_after_reopen(proof, journal)
            return
        # pidfd binds the signal to this exact process, not a potentially reused PID.
        if not hasattr(os, "pidfd_open"):
            raise Unavailable("no_soportado")
        # Capture before closing; the capsule is an anonymous sealed memory fd,
        # never a disk file, shell argument, journal or RPC result.
        raw = (self.proc / str(process["pid"]) / "environ").read_bytes()
        if len(raw) > 1048576:
            raise Unavailable("no_soportado")
        env = dict(item.split("=", 1) for item in raw.decode().split("\0") if "=" in item)
        if not Path(process["cwd"]).is_dir() or not os.access(resume[0], os.X_OK):
            raise Unavailable("no_soportado")
        for key in ("CODEX_THREAD_ID", "CODEX_SESSION_ID", "UNICONNECT_NATIVE_BINDING"):
            env.pop(key, None)
        # Claude refuses its no-prompt flag as root unless told it is sandboxed (IS_SANDBOX=1):
        # rootEnvironment of the shared policy, only when this pane's agent runs as root.
        if os.geteuid() == 0:
            policy = (self.request["catalog"].get(self.request["provider"]) or {}).get("noPrompt") or {}
            env.update(policy.get("rootEnvironment", {}))
        # Reuse the checked-in hook rather than executing source from a pane.
        helper = self.request.get("identity_helper")
        if not isinstance(helper, str) or len(helper) > 32768:
            raise Unavailable("no_soportado")
        env["UNICONNECT_NATIVE_HELPER"] = helper
        original = process["argv"]
        managed = any(self.managed_hook(self.request["provider"], option.split("=", 1)[0],
                      option.split("=", 1)[1] if "=" in option else (original[index + 1] if index + 1 < len(original) else ""))
                      for index, option in enumerate(original) if option.split("=", 1)[0] in ("-c", "--config", "--settings"))
        if self.request["provider"] == "agy":
            managed = self.managed_antigravity(env, process, proof["pane"], hook=self.pane()[3])
        capsule = {"argv": resume, "env": env, "cwd": process["cwd"],
                   "agent": self.request["provider"], "window_id": self.request["window_id"], "managed_identity": managed}
        if not hasattr(os, "memfd_create"):
            raise Unavailable("no_soportado")
        descriptor = os.memfd_create("uniconnect-relaunch", os.MFD_CLOEXEC | os.MFD_ALLOW_SEALING)
        os.fchmod(descriptor, 0o600)
        raw = json.dumps(capsule).encode()
        with os.fdopen(os.dup(descriptor), "wb") as handle:
            handle.write(raw)
        os.lseek(descriptor, 0, os.SEEK_SET)
        fcntl.fcntl(descriptor, fcntl.F_ADD_SEALS, fcntl.F_SEAL_WRITE | fcntl.F_SEAL_GROW | fcntl.F_SEAL_SHRINK | fcntl.F_SEAL_SEAL)
        capsule_path = self.proc / str(os.getpid()) / "fd" / str(descriptor)
        events = TmuxOutputEvents(self.binary, self.request["session"])
        try:
            self.restart(proof, root, process, capsule_path, journal, events)
        finally:
            events.close()
            os.close(descriptor)
        if self.request.get("verb") == "agent.recover":
            self.continue_after_reopen(proof, journal)

    def continue_after_reopen(self, previous, journal):
        """Revalidate the resumed native conversation before the one exact continuation."""
        current, _, process, _ = self.inspect(runtime=True)
        if (current["pane"] != previous["pane"] or current["generation"] == previous["generation"]
                or current["effective_id"] != previous["effective_id"]
                or current["configuration"] != previous["configuration"]
                or current.get("native_configuration") != previous.get("native_configuration")):
            raise Unavailable("generacion_cambiada")
        self.continue_codex(current, process, journal)

    def restart(self, proof, root, process, capsule_path, journal, events):
        owned = self.descendants(process["pid"])
        if self.request.get("provider") == "claude":
            self.exit_claude(proof, process, journal, events)
        elif self.request.get("provider") == "agy":
            self.exit_antigravity(proof, process, journal)
        else:
            self.exit_codex(proof, process, journal, events)
        deadline = self.clock() + 5
        while self.clock() < deadline:
            after = self.process(root["pid"])
            if (after["start"] == root["start"] and after["foreground"] == after["group"]
                    and not self.descendants(root["pid"]) and not any(self.same_process(p) for p in owned.values())):
                break
            events.wait(deadline, self.clock)
        else:
            raise Unavailable("dialogo_desconocido")
        if any(arg not in ("-l", "-i", "--login", "--noprofile", "--norc") for arg in after["argv"][1:]):
            raise Unavailable("dialogo_desconocido")
        self.write(journal, {"state": "reabriendo"})
        # Only the fixed launcher and an anonymous memory descriptor enter the
        # proved shell. No credential or provider argument appears in scrollback.
        launcher = ('import os,json,sys,base64,zlib; p=sys.argv[1]; '
                    'f=open(p); d=json.load(f); f.close(); '
                    'os.chdir(d["cwd"]); os.environ.clear(); os.environ.update(d["env"]); '
                    'n={"__name__":"uniconnect_launch"}; '
                    'exec(zlib.decompress(base64.b64decode(os.environ["UNICONNECT_NATIVE_HELPER"])),n) if d["managed_identity"] else None; '
                    'n["launch"](d) if d["managed_identity"] else os.execvpe(d["argv"][0],d["argv"],os.environ)')
        command = shlex.join([sys.executable, "-c", launcher, str(capsule_path)])
        if self.pane()[0] != proof["pane"] or self.descendants(root["pid"]):
            raise Unavailable("generacion_cambiada")
        self.tmux("send-keys", "-t", proof["pane"]["pane"], "-l", "--", command + "\n")
        self.request["resumed"] = True
        deadline = self.clock() + 45
        while self.clock() < deadline:
            try:
                current = self.inspect()
                if (current["effective_id"] == proof["effective_id"] and current["generation"] != proof["generation"]
                        and current["pane"] == proof["pane"] and current["configuration"] == proof["configuration"]
                        and current.get("native_configuration") == proof.get("native_configuration")):
                    self.require_empty_composer(current)
                    if self.request.get("verb") != "agent.recover":
                        self.write(journal, {"state": "verificado", "effective_id": proof["effective_id"]})
                    return current
            except (Unavailable, OSError):
                pass
            events.wait(deadline, self.clock)

    @staticmethod
    def codex_quota_pause(lines):
        """Recognize only an explicit, recent Codex usage-limit notice near its composer."""
        prompts = [index for index, line in enumerate(lines) if line.startswith("›")]
        if not prompts:
            return False
        row = prompts[-1]
        recent = " ".join(line.strip() for line in lines[max(0, row - 16):row]).casefold()
        return any(marker in recent for marker in (
            "you’ve hit your usage limit", "you've hit your usage limit",
            "you have hit your usage limit", "usage limit reached"))

    def continue_codex(self, proof, process, journal):
        """Send one fixed continuation only to a verified, empty quota-paused Codex composer."""
        pane = proof["pane"]["pane"]
        lines = self.tmux("capture-pane", "-p", "-t", pane).splitlines()
        if not self.codex_quota_pause(lines) or not self.same_target(self.inspect(), proof):
            raise Unavailable("generacion_cambiada")
        original = self.tmux("capture-pane", "-p", "-t", pane).splitlines()
        composer = self.require_empty_composer(proof)
        row = int(self.tmux("display-message", "-p", "-t", pane, "#{cursor_y}"))
        self.write(journal, {"state": "entregando"})
        self.tmux("send-keys", "-t", pane, "-l", "--", "continua")
        typed = self.tmux("capture-pane", "-p", "-t", pane).splitlines()
        if (row >= len(typed) or typed[row].strip() != "› continua"
                or TargetWorker.codex_composer_tail(typed[row + 1:])
                != TargetWorker.codex_composer_tail(composer["tail"])):
            raise Unavailable("dialogo_desconocido")
        # Recheck identity and exact composer immediately before submission.
        if not self.same_target(self.inspect(), proof):
            raise Unavailable("generacion_cambiada")
        typed = self.tmux("capture-pane", "-p", "-t", pane).splitlines()
        row = int(self.tmux("display-message", "-p", "-t", pane, "#{cursor_y}"))
        if (row >= len(typed) or typed[row].strip() != "› continua"
                or TargetWorker.codex_composer_tail(typed[row + 1:])
                != TargetWorker.codex_composer_tail(composer["tail"])):
            raise Unavailable("dialogo_desconocido")
        self.tmux("send-keys", "-t", pane, "Enter")
        # Codex's own activity indicator is the receipt. A queued keystroke or
        # a changed placeholder alone is never reported as accepted work.
        deadline = self.clock() + 30
        while self.clock() < deadline:
            if not self.same_live_agent(proof, process):
                raise Unavailable("generacion_cambiada")
            screen = self.tmux("capture-pane", "-p", "-t", pane).splitlines()
            activity = self.codex_activity(screen)
            new_prompt = (any(line.strip() in ("› continua", "continua") for line in screen[-40:])
                          and not any(line.strip() in ("› continua", "continua") for line in original[-40:]))
            if activity["working"] and new_prompt:
                self.write(journal, {"state": "verificado", "effective_id": proof["effective_id"]})
                return
            if not self.codex_quota_pause(screen):
                # The explicit quota notice disappeared but Codex did not
                # acknowledge by starting. Keep the operation unresolved.
                raise Unavailable("dialogo_desconocido")
            time.sleep(0.25)
        raise Unavailable("dialogo_desconocido")

    def same_live_agent(self, proof, expected_process):
        """After submission, pin to the same pane and Codex PID without requiring an idle transcript."""
        pane, root, mode, hook = self.pane()
        if pane != proof["pane"] or mode != "0":
            return False
        matches = [item for item in self.descendants(root["pid"]).values()
                   if self.is_provider("codex", item["argv"])]
        if len(matches) != 1 or (matches[0]["pid"], matches[0]["start"]) != (
                expected_process["pid"], expected_process["start"]):
            return False
        return self.native_id("codex", matches[0], hook, pane) == proof["effective_id"]

    def same_process(self, process):
        try:
            return self.process(process["pid"])["start"] == process["start"]
        except OSError:
            return False

    def exit_codex(self, proof, process, journal, events):
        """Submit a recognized exit command; observe death without force-killing."""
        if self.request.get("provider") != "codex":
            raise Unavailable("no_soportado")
        if not hasattr(os, "pidfd_open"):
            raise Unavailable("no_soportado")
        descriptor = os.pidfd_open(process["pid"])
        try:
            if not self.same_target(self.inspect(), proof):
                raise Unavailable("generacion_cambiada")
            approved_active = (proof.get("active") is True
                               and self.request.get("expected", {}).get("active") is True)
            self.require_empty_composer(proof, allow_active=approved_active)
            self.interrupt_codex(proof, process, journal, events, approved_active=approved_active)
            if not self.same_target(self.inspect(), proof):
                raise Unavailable("generacion_cambiada")
            composer = self.require_empty_composer(proof, allow_active=approved_active)
            self.write(journal, {"state": "cerrando"})
            pane = proof["pane"]["pane"]
            self.tmux("send-keys", "-t", pane, "-l", "--", "/exit")
            deadline = self.clock() + 8
            while True:
                row = int(self.tmux("display-message", "-p", "-t", pane, "#{cursor_y}"))
                lines = self.tmux("capture-pane", "-p", "-t", pane).splitlines()
                if self.codex_exit_composer(lines, row, composer):
                    break
                events.wait(deadline, self.clock)
            if not self.same_target(self.inspect(), proof):
                raise Unavailable("generacion_cambiada")
            # inspect reads native state and can take time. Recheck the entire
            # input after it, immediately before submission, including continuation lines.
            row = int(self.tmux("display-message", "-p", "-t", pane, "#{cursor_y}"))
            if not self.codex_exit_composer(self.tmux("capture-pane", "-p", "-t", pane).splitlines(), row, composer):
                raise Unavailable("dialogo_desconocido")
            self.tmux("send-keys", "-t", pane, "Enter")
            ready, _, _ = select.select([descriptor], [], [], 75)
            if not ready:
                raise Unavailable("dialogo_desconocido")
        finally:
            os.close(descriptor)

    @staticmethod
    def same_target(current, expected):
        """A confirmed active turn may finish; identity, generation and configuration may not change."""
        if expected.get("active") is not True:
            return current == expected
        return ({key: value for key, value in current.items() if key != "active"}
                == {key: value for key, value in expected.items() if key != "active"})

    @staticmethod
    def codex_exit_composer(lines, row, original):
        """Only /exit and the same composer tail, allowing the warning hint hidden by its menu."""
        prompts = [index for index, line in enumerate(lines) if line.startswith("›")]
        return (bool(prompts) and row == prompts[-1] and lines[row] == "› /exit"
                and TargetWorker.codex_composer_tail(lines[row + 1:])
                == TargetWorker.codex_composer_tail(original["tail"]))

    @staticmethod
    def codex_composer_tail(lines):
        """Normalize only the observed footer warning hint; never remove an input line or blank."""
        return [re.sub(r" {2,}⚠ [1-9][0-9]* warnings? · f2 to view$", "", line)
                if re.match(r"^  (?:GPT|gpt)-[A-Za-z0-9._-]+(?: [a-z]+)? · ", line) else line
                for line in lines]

    def interrupt_codex(self, proof, process, journal, events, *, approved_active):
        """Interrupt only a recognized working turn after confirmation, then observe its native end."""
        pane = proof["pane"]["pane"]
        activity = self.codex_activity(self.tmux("capture-pane", "-p", "-t", pane).splitlines())
        if any(activity.values()) and not approved_active:
            raise Unavailable("tareas_de_fondo")
        if not activity["working"]:
            return
        if not self.same_target(self.inspect(), proof):
            raise Unavailable("generacion_cambiada")
        self.require_empty_composer(proof, allow_active=True)
        self.write(journal, {"state": "cerrando"})
        self.tmux("send-keys", "-t", pane, "Escape")
        deadline = self.clock() + 30
        while True:
            try:
                if not self.same_target(self.inspect(), proof):
                    raise Unavailable("generacion_cambiada")
            except Unavailable as error:
                if error.cause != "dialogo_desconocido":
                    raise
                # The status line and the native turn-aborted record can arrive
                # separately. Wait for output; never manufacture a completed turn.
                events.wait(deadline, self.clock)
                continue
            activity = self.codex_activity(self.tmux("capture-pane", "-p", "-t", pane).splitlines())
            if not activity["working"]:
                try:
                    self.quiescent_configuration("codex", process, proof["effective_id"], "")
                    self.require_empty_composer(proof, allow_active=True)
                    return
                except Unavailable as error:
                    if error.cause != "dialogo_desconocido":
                        raise
            events.wait(deadline, self.clock)

    @staticmethod
    def claude_exit_option(screen):
        """Number of Claude's «Exit and stop tasks» option, read from its own text (never its position)."""
        for line in screen.splitlines():
            if "Exit and stop tasks" in line:
                digits = re.search(r"(\d+)", line)
                return int(digits.group(1)) if digits else None
        return None

    # Un hijo directo de Claude que no es un servidor MCP es trabajo suyo en marcha: una orden en
    # segundo plano o un monitor (la sonda del árbol IA los cuenta igual).
    MCP_SERVER = re.compile(r"mcp|_server|server\.(py|js)")

    @classmethod
    def is_background_task(cls, argv):
        """True si este hijo directo de Claude es una tarea o un monitor, no un servidor MCP."""
        return not cls.MCP_SERVER.search(" ".join(argv))

    def claude_background_work(self, pid):
        """Tareas y monitores vivos de este Claude: sus hijos directos que no son servidores MCP."""
        return [child for child in self.descendants(pid).values()
                if child["parent"] == pid and self.is_background_task(child["argv"])]

    @staticmethod
    def claude_printed_id(screen):
        """The conversation Claude prints on its way out («Resume this session with»), or None."""
        _, found, after = screen.partition("Resume this session with")
        match = UUID.search(after) if found else None
        return match.group(0).lower() if match else None

    def exit_antigravity(self, proof, process, journal):
        """Use documented Ctrl+D only after proving the exact AGY pane is idle and empty."""
        if self.request.get("provider") != "agy" or not hasattr(os, "pidfd_open"):
            raise Unavailable("no_soportado")
        descriptor = os.pidfd_open(process["pid"])
        try:
            if not self.same_target(self.inspect(), proof):
                raise Unavailable("generacion_cambiada")
            self.require_empty_composer(proof)
            # The first read can race a state change. Revalidate identity and
            # composer immediately before Ctrl+D; never send it into a draft.
            if not self.same_target(self.inspect(), proof):
                raise Unavailable("generacion_cambiada")
            self.require_empty_composer(proof)
            self.write(journal, {"state": "cerrando"})
            self.tmux("send-keys", "-t", proof["pane"]["pane"], "C-d")
            ready, _, _ = select.select([descriptor], [], [], 75)
            if not ready:
                raise Unavailable("dialogo_desconocido")
        finally:
            os.close(descriptor)

    def exit_claude(self, proof, process, journal, events):
        """D7: type /exit literally, check the line, Enter, and wait for Claude to leave by itself.

        Never Ctrl+C and never force-killing: the process must die by itself (≤ 75 s). Never with
        work running either: a Claude with tasks or monitors is not closed (tareas_de_fondo), because
        both answers of its «Background work is running» dialog lose them (stopped, or stranded
        outside the conversation). Dani's rule: monitors are saved before a close, never killed.
        """
        if self.request.get("provider") != "claude" or not hasattr(os, "pidfd_open"):
            raise Unavailable("no_soportado")
        if self.claude_background_work(process["pid"]):
            raise Unavailable("tareas_de_fondo")
        descriptor = os.pidfd_open(process["pid"])
        try:
            if self.inspect() != proof:
                raise Unavailable("generacion_cambiada")
            self.require_empty_composer(proof)
            self.write(journal, {"state": "cerrando"})
            pane = proof["pane"]["pane"]
            self.tmux("send-keys", "-t", pane, "-l", "--", "/exit")
            deadline = self.clock() + 8
            while True:
                row = int(self.tmux("display-message", "-p", "-t", pane, "#{cursor_y}"))
                lines = self.tmux("capture-pane", "-p", "-t", pane).splitlines()
                if row < len(lines) and CLAUDE_EXIT_LINE.fullmatch(lines[row]):
                    break
                events.wait(deadline, self.clock)
            if self.inspect() != proof:
                raise Unavailable("generacion_cambiada")
            self.tmux("send-keys", "-t", pane, "Enter")
            deadline = self.clock() + 75
            while not events.wait(deadline, self.clock, also=descriptor):
                screen = self.tmux("capture-pane", "-p", "-t", pane)
                if "Yes, I trust this folder" in screen:
                    raise Unavailable("confianza_carpeta")
                if "Background work is running" in screen:
                    # Work started between the check and the /exit. Neither answer is safe: Escape
                    # cancels the close, Claude stays as it was, and a person decides.
                    self.tmux("send-keys", "-t", pane, "Escape")
                    raise Unavailable("tareas_de_fondo")
            printed = self.claude_printed_id(self.tmux("capture-pane", "-p", "-t", pane))
            if printed is not None and printed != proof["effective_id"].lower():
                # It left on another conversation than its ficha said: never resume a guess.
                raise Unavailable("identidad_ambigua")
        finally:
            os.close(descriptor)

    def restart_recovery(self, proof, root, process, journal, events):
        """Use the reviewed launcher's normal exit/wait path, not respawn-pane."""
        self.exit_codex(proof, process, journal, events)
        pane = proof["pane"]["pane"]
        deadline = self.clock() + 10
        while True:
            if not self.same_process(root) or self.pane()[0] != proof["pane"]:
                raise Unavailable("generacion_cambiada")
            lines = self.tmux("capture-pane", "-p", "-t", pane).splitlines()
            if (not self.descendants(root["pid"]) and lines
                    and lines[-1].strip() == "Sesión cerrada. Pulsa Intro para recuperar el mismo historial:"):
                break
            # A non-zero exit may trigger the launcher's existing retry. Do
            # not inject Enter into a new agent or an unknown failure screen.
            events.wait(deadline, self.clock)
        self.recovery_launcher(root, process, proof["effective_id"])
        self.write(journal, {"state": "reabriendo"})
        tty = self.tmux("display-message", "-p", "-t", pane, "#{pane_tty}")
        if not re.fullmatch(r"/dev/pts/[0-9]+", tty):
            raise Unavailable("no_soportado")
        # A clean Codex exit can leave raw input behind. Only repair it after
        # proving the launcher is alone and at its exact known input prompt.
        self.run(["stty", "sane", "-F", tty], check=True, timeout=3, capture_output=True)
        if self.descendants(root["pid"]) or not self.same_process(root):
            raise Unavailable("generacion_cambiada")
        self.tmux("send-keys", "-t", pane, "C-j")
        self.request["resumed"] = True
        deadline = self.clock() + 120
        while True:
            try:
                current = self.inspect()
                if (current["pane"] == proof["pane"] and current["generation"] != proof["generation"]
                        and current["effective_id"] == proof["effective_id"]
                        and current["configuration"] == proof["configuration"]
                        and current.get("native_configuration") == proof.get("native_configuration")
                        and current.get("launcher") == proof["launcher"]):
                    self.require_empty_composer(current)
                    if self.request.get("verb") != "agent.recover":
                        self.write(journal, {"state": "verificado", "effective_id": proof["effective_id"]})
                    return current
            except (Unavailable, OSError):
                pass
            events.wait(deadline, self.clock)

    @staticmethod
    def codex_activity(lines):
        """Read known activity near the composer; absence is never proof of native quiescence."""
        working = background = False
        for line in lines[-12:]:
            working |= bool(re.match(r"^\s*[•◦·*]?\s*(?:Working|Waiting for background terminal)\s*\([^)]*\besc to interrupt\)", line))
            background |= bool(re.search(r"(?:^\s*[•◦·*]?\s*|·\s*)[1-9][0-9]* background terminals? running\b", line))
        return {"working": working, "background": background}

    @staticmethod
    def codex_placeholder(styled):
        """Require dim or neutral-gray foreground on every placeholder character, not just an SGR."""
        plain, muted = "", []
        dim = gray = reverse = hidden = False
        for part in re.split(r"(\x1b\[[0-9;]*m)", styled):
            if not part.startswith("\x1b["):
                plain += part
                muted.extend([bool((dim or gray) and not reverse and not hidden)] * len(part))
                continue
            codes = [int(code or 0) for code in part[2:-1].split(";")]
            index = 0
            while index < len(codes):
                code = codes[index]
                if code == 0:
                    dim = gray = reverse = hidden = False
                elif code in (2, 22):
                    dim = code == 2
                elif code in (7, 27):
                    reverse = code == 7
                elif code in (8, 28):
                    hidden = code == 8
                elif code in (38, 48, 58):
                    # Consume background/underline colors too: their RGB values
                    # must never be mistaken for SGR 2 (dim).
                    mode = codes[index + 1] if index + 1 < len(codes) else None
                    count = 1 if mode == 5 else 3 if mode == 2 else 0
                    color = codes[index + 2:index + 2 + count]
                    if not count or len(color) != count or any(value > 255 for value in color):
                        return False
                    if code == 38:
                        gray = (color[0] == 8 or 232 <= color[0] <= 254) if count == 1 else (
                            color[0] == color[1] == color[2] and 0 < color[0] < 255)
                    index += count + 1
                elif code == 39 or 30 <= code <= 37 or 90 <= code <= 97:
                    gray = code == 90
                index += 1
        return plain == "› Ask Codex to do anything" and all(muted[2:])

    def require_empty_composer(self, proof, *, allow_active=False):
        """Fail closed on drafts/dialogs; a styled placeholder, not a footer, proves empty input."""
        pane = proof["pane"]["pane"]
        lines = self.tmux("capture-pane", "-p", "-t", pane).splitlines()
        empty = False
        if self.request.get("provider") == "codex":
            if any(self.codex_activity(lines).values()) and not allow_active:
                raise Unavailable("tareas_de_fondo")
            # The final prompt is the composer. A prompt quoted in older output
            # cannot authorize a close over a later draft or an unknown dialog.
            prompts = [index for index, line in enumerate(lines) if line.startswith("›")]
            if prompts:
                row = prompts[-1]
                trailing = lines[row + 1:]
                footer = all(not line.strip() or re.fullmatch(r"  (?:GPT|gpt)-[A-Za-z0-9._-]+(?: [a-z]+)? · \S.* · \S.*|  \? for shortcuts.*", line)
                             for line in trailing)
                if all(not line.strip() for line in trailing) and lines[row].strip() == "›":
                    empty = True
                elif footer and lines[row] == "› Ask Codex to do anything":
                    styled = self.tmux("capture-pane", "-e", "-p", "-t", pane).splitlines()
                    # Separate reads can race a new draft: require the full same
                    # screen before trusting the style of that particular row.
                    if [re.sub(r"\x1b\[[0-9;]*m", "", line) for line in styled] == lines:
                        empty = self.codex_placeholder(styled[row])
        else:
            row = int(self.tmux("display-message", "-p", "-t", pane, "#{cursor_y}"))
            empty = 0 <= row < len(lines) and EMPTY_PROMPT_LINE.fullmatch(lines[row]) is not None
        visible = "\n".join(lines).lower()
        if "yes, i trust this folder" in visible or "do you trust the files in this folder" in visible:
            raise Unavailable("confianza_carpeta")  # A person answers it; never on their behalf.
        if not empty:
            raise Unavailable("dialogo_desconocido")
        if any(value in visible for value in ("do you trust", "trust this", "allow once", "allow execution",
                    "would you like to run", "do you want to proceed", "[y/n]", "sign in", "log in")):
            raise Unavailable("permisos")
        return {"tail": lines[row + 1:]}

    def dispatch(self):
        action = self.request["action"]
        if action == "inspect":
            return self.inspect()
        if action == "start":
            return self.start()
        if action == "status":
            lock_path, _, journal = self.paths()
            try:
                value = self.read(journal)
            except FileNotFoundError:
                value = {"state": "planificado", "cause": "sin_autoridad"}
            if value["state"] in ("verificado", "omitido", "fallido", "necesita_usuario"):
                return value
            descriptor = os.open(lock_path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
            try:
                info = os.fstat(descriptor)
                if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid():
                    raise Unavailable("sin_autoridad")
                try:
                    fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
                except BlockingIOError:
                    return value  # Its live owner may be writing acceptance now.
                # Re-read under the SAME target lock used by start. Missing is
                # NOT proof of no effects. Seal this operation as unresolved so
                # a delayed start cannot close it after we returned a final result.
                # No native inspection, restart or generation claim is made here.
                if journal.exists():
                    value = self.read(journal)
                    if value["state"] in ("verificado", "omitido", "fallido", "necesita_usuario"):
                        return value
                value = {"state": "necesita_usuario", "cause": "sin_autoridad"}
                self.write(journal, value)
                return value
            finally:
                os.close(descriptor)
        raise Unavailable("no_soportado")


if __name__ == "__main__":
    try:
        payload = base64.b64decode(sys.argv[1], validate=True)
        if len(payload) > 65536:
            raise Unavailable("no_soportado")
        result = TargetWorker(json.loads(payload)).dispatch()
    except Exception as error:
        result = {"error": getattr(error, "cause", "host_inaccesible")}
    print("UC_RELAUNCH_V1 " + json.dumps(result), flush=True)
