"""Self-contained Linux target adapter, executed over an existing SSH transport.

Private per-pane journals and a target-side flock arbitrate *all* viewing hosts.
No login/permission edits, tmux destruction, generic control keys or --last.
Only freshly proved native Claude/Codex processes can be stopped. Everything
else is explicitly excluded until a provider-specific evidence adapter exists.
"""

import base64
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import select
import shlex
import signal
import stat
import subprocess
import sys
import time
import uuid


class Unavailable(Exception):
    def __init__(self, cause):
        self.cause = cause


class TmuxOutputEvents:
    """Read-only control attachment: wait for real pane output, not sleep/poll."""
    def __init__(self, binary, session):
        self.process = subprocess.Popen([*binary, "-C", "attach-session", "-t", "=" + session,
                                         "-f", "read-only,ignore-size"], stdin=subprocess.PIPE,
                                        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, bufsize=0)

    def wait(self, deadline, clock):
        remaining = deadline - clock()
        if remaining <= 0:
            raise Unavailable("dialogo_desconocido")
        ready, _, _ = select.select([self.process.stdout], [], [], remaining)
        if not ready or not os.read(self.process.stdout.fileno(), 65536):
            raise Unavailable("dialogo_desconocido")

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

    def native_id(self, agent, process, hook, pane):
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

    def quiescent_configuration(self, provider, process, identifier, hook):
        """Require a native completed turn AND explicit matching launch policy.

        A visible prompt can coexist with active work. Until an adapter can prove
        lifecycle and effective settings, identity alone does not authorize exit.
        Reads metadata only; no transcript contents leave the target.
        """
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
            offset = max(handle.tell(), info.st_size - 4 * 1024 * 1024)
            handle.seek(offset)
            if offset > 65536:
                handle.readline()  # Discard partial first record of a bounded tail.
            rows = []
            for line in handle.read(4 * 1024 * 1024).splitlines():
                if len(line) <= 65536:
                    try:
                        rows.append(json.loads(line))
                    except ValueError:
                        raise Unavailable("no_soportado") from None
        self.validate_quiescence(rows, process)

    @staticmethod
    def validate_quiescence(rows, process):
        context, settings, completed, active_turn = None, None, False, None
        for row in rows:
            payload = row.get("payload", {})
            if row.get("type") == "turn_context":
                context = payload
                settings = None
                active_turn, completed = payload.get("turn_id"), False
            if row.get("type") == "event_msg":
                kind = payload.get("type")
                if kind == "task_started":
                    active_turn, completed = payload.get("turn_id"), False
                elif kind in ("task_complete", "turn_aborted"):
                    if (isinstance(active_turn, str) and active_turn and payload.get("turn_id") == active_turn
                            and context and context.get("turn_id") == active_turn):
                        completed = True
                elif kind == "thread_settings_applied":
                    settings = payload.get("thread_settings", {})
            if row.get("type") == "response_item" and payload.get("role") == "user":
                completed = False
        if not context or not completed:
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
        actual_sandbox = context.get("sandbox_policy", {}).get("type")
        if (((not model) and not bypass) or (model and model != context.get("model"))
                or not sandbox or not approval
                or sandbox != actual_sandbox or approval != context.get("approval_policy")
                or context.get("cwd") != process["cwd"]):
            raise Unavailable("no_soportado")
        if context.get("effort") != effort or (settings and settings.get("reasoning_effort") != effort):
            raise Unavailable("no_soportado")
        if settings and (settings.get("model") != model or settings.get("approval_policy") != approval
                         or settings.get("cwd") != process["cwd"]):
            raise Unavailable("no_soportado")
        # Expanded writable roots and profile changes cannot be reconstructed
        # safely from just the three CLI flags. Reject, don't widen permissions.
        if sandbox not in ("read-only", "danger-full-access"):
            raise Unavailable("no_soportado")
        if settings and settings.get("permission_profile"):
            profile = settings["permission_profile"]
            if profile != {"type": "disabled"} or sandbox != "danger-full-access":
                raise Unavailable("no_soportado")

    @staticmethod
    def resume_arguments(provider, argv, identifier, catalog):
        """Retain explicit options, remove ONLY the previous conversation selector.

        Unknown positional inputs or noninteractive subcommands are excluded;
        never replay the original prompt, fork, exec, login, or --last.
        """
        arguments = list(argv[1:])
        resumed = provider == "codex" and arguments[:1] == ["resume"]
        removed_id = False
        if resumed:
            arguments.pop(0)
            if arguments and not arguments[0].startswith("-"):
                arguments.pop(0)
                removed_id = True
        values = ({"-c", "--config", "-m", "--model", "-C", "--cd", "-s", "--sandbox", "-a", "--ask-for-approval",
                   "-p", "--profile", "--add-dir", "--enable", "--disable"} if provider == "codex" else
                  {"--model", "--permission-mode", "--settings", "--setting-sources", "--add-dir", "--allowedTools",
                   "--disallowedTools", "--mcp-config", "--tools", "--system-prompt", "--append-system-prompt"})
        switches = ({"--no-alt-screen", "--search", "--full-auto", "--dangerously-bypass-approvals-and-sandbox", "--yolo"}
                    if provider == "codex" else {"--dangerously-skip-permissions", "--verbose", "--strict-mcp-config"})
        kept, index = [], 0
        while index < len(arguments):
            arg = arguments[index]
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
        substitutions = {"{executable}": [argv[0]], "{sessionId}": [identifier], "{arguments}": kept}
        return [part for token in catalog[provider]["resume"] for part in substitutions.get(token, [token])]

    @staticmethod
    def managed_hook(provider, option, value):
        bootstrap = 'import base64,os;exec(base64.b64decode(os.environ["UNICONNECT_NATIVE_HELPER"]))'
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
        if provider not in ("codex", "claude") or provider not in self.request["catalog"]:
            raise Unavailable("no_soportado")
        if mode != "0":
            raise Unavailable("dialogo_desconocido")
        children = self.descendants(root["pid"])
        matches = [p for p in children.values() if Path(p["argv"][0]).name == provider]
        if len(matches) != 1:
            raise Unavailable("identidad_ambigua")
        process = matches[0]
        effective = self.native_id(provider, process, hook, pane)
        self.quiescent_configuration(provider, process, effective, hook)
        # The root must remain as an interactive shell after its agent exits.
        # Supervisors/custom shell scripts can restart independently: excluded.
        if Path(root["argv"][0]).name.lstrip("-") not in ("bash", "zsh", "sh"):
            raise Unavailable("no_soportado")
        if any(arg not in ("-l", "-i", "--login", "--noprofile", "--norc") for arg in root["argv"][1:]):
            # Only our known bootstrap ends deterministically in an interactive
            # shell. Do not stop an agent owned by a recovery/custom supervisor.
            if not (len(root["argv"]) == 3 and root["argv"][1] == "-lc"
                    and "UNICONNECT_NATIVE_HELPER=" in root["argv"][2]
                    and root["argv"][2].endswith('exec "${SHELL:-/bin/sh}" -l')):
                raise Unavailable("no_soportado")
        resume = self.resume_arguments(provider, [process["executable"], *process["argv"][1:]], effective, self.request["catalog"])
        generation = int(self.digest({"pane": pane, "pid": process["pid"], "start": process["start"], "id": effective})[:12], 16)
        proof = {"key": "linux:" + self.digest(pane) + "|gen:" + str(generation), "generation": generation,
                 "pane": pane, "pid": process["pid"], "start": process["start"], "effective_id": effective,
                 "configuration": self.digest({"cwd": process["cwd"], "argv": resume})}
        if runtime:
            return proof, root, process, resume
        return proof

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
            if self.inspect() != expected:
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
                self.perform(journal)
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
        if proof != self.request["expected"]:
            raise Unavailable("generacion_cambiada")
        self.require_empty_composer(proof)
        # pidfd binds the signal to this exact process, not a potentially reused PID.
        if not hasattr(os, "pidfd_open") or not hasattr(signal, "pidfd_send_signal"):
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
        # Reuse the checked-in hook rather than executing source from a pane.
        helper = self.request.get("identity_helper")
        if not isinstance(helper, str) or len(helper) > 32768:
            raise Unavailable("no_soportado")
        env["UNICONNECT_NATIVE_HELPER"] = helper
        original = process["argv"]
        managed = any(self.managed_hook(self.request["provider"], option.split("=", 1)[0],
                      option.split("=", 1)[1] if "=" in option else (original[index + 1] if index + 1 < len(original) else ""))
                      for index, option in enumerate(original) if option.split("=", 1)[0] in ("-c", "--config", "--settings"))
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

    def restart(self, proof, root, process, capsule_path, journal, events):
        descriptor = os.pidfd_open(process["pid"])
        try:
            if self.inspect() != proof:
                raise Unavailable("generacion_cambiada")
            self.require_empty_composer(proof)
            owned = self.descendants(process["pid"])
            self.write(journal, {"state": "cerrando"})
            signal.pidfd_send_signal(descriptor, signal.SIGTERM)
            ready, _, _ = select.select([descriptor], [], [], 15)
            if not ready:
                raise Unavailable("dialogo_desconocido")  # Never escalate to SIGKILL.
        finally:
            os.close(descriptor)
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
        launcher = ('import os,json,sys,base64; p=sys.argv[1]; '
                    'f=open(p); d=json.load(f); f.close(); '
                    'os.chdir(d["cwd"]); os.environ.clear(); os.environ.update(d["env"]); '
                    'n={"__name__":"uniconnect_launch"}; '
                    'exec(base64.b64decode(os.environ["UNICONNECT_NATIVE_HELPER"]),n); '
                    'n["launch"](d) if d["managed_identity"] else os.execvpe(d["argv"][0],d["argv"],os.environ)')
        command = shlex.join([sys.executable, "-c", launcher, str(capsule_path)])
        if self.pane()[0] != proof["pane"] or self.descendants(root["pid"]):
            raise Unavailable("generacion_cambiada")
        self.tmux("send-keys", "-t", proof["pane"]["pane"], "-l", "--", command + "\n")
        deadline = self.clock() + 45
        while self.clock() < deadline:
            try:
                current = self.inspect()
                if (current["effective_id"] == proof["effective_id"] and current["generation"] != proof["generation"]
                        and current["pane"] == proof["pane"] and current["configuration"] == proof["configuration"]):
                    self.require_empty_composer(current)
                    self.write(journal, {"state": "verificado", "effective_id": proof["effective_id"]})
                    return
            except (Unavailable, OSError):
                pass
            events.wait(deadline, self.clock)
        raise Unavailable("dialogo_desconocido")

    def same_process(self, process):
        try:
            return self.process(process["pid"])["start"] == process["start"]
        except OSError:
            return False

    def require_empty_composer(self, proof):
        """Fail closed on drafts/dialogs; never use a footer as ready evidence."""
        pane = proof["pane"]["pane"]
        row = int(self.tmux("display-message", "-p", "-t", pane, "#{cursor_y}"))
        lines = self.tmux("capture-pane", "-p", "-t", pane).splitlines()
        if row >= len(lines) or re.fullmatch(r"\s*[›❯>]\s*", lines[row]) is None:
            raise Unavailable("dialogo_desconocido")
        visible = "\n".join(lines).lower()
        if any(value in visible for value in ("do you trust", "trust this", "allow once", "allow execution",
                    "would you like to run", "do you want to proceed", "[y/n]", "sign in", "log in")):
            raise Unavailable("permisos")

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
