"""SSH and durable tmux transport for the native Linux application.

Connection strings are parsed once and are never executed by a local shell.
Reconnection is attach-only; session creation is an explicit, idempotent operation.
"""

from __future__ import annotations

import dataclasses
import getpass
import os
import re
import shlex
import subprocess
import unicodedata
import uuid
from pathlib import Path
from typing import Mapping


class TransportError(RuntimeError):
    """A transport operation failed; code is stable and suitable for UI translation."""

    def __init__(self, code: str, detail: str = ""):
        self.code = code
        self.detail = detail
        super().__init__(f"{code}: {detail}" if detail else code)


@dataclasses.dataclass(frozen=True, repr=False)
class SSHCommand:
    """A validated connection, with passwords excluded from argv and repr."""

    destination: str
    options: tuple[str, ...] = ()
    password: str | None = dataclasses.field(default=None, repr=False)
    password_prompt: str | None = None

    _NO_VALUE = frozenset("46aCgkqtvx y".replace(" ", ""))
    _WITH_VALUE = frozenset("Bbce iJlmop".replace(" ", ""))
    _FORBIDDEN_CONFIG = frozenset({
        "addkeystoagent", "batchmode", "clearallforwardings", "controlmaster",
        "controlpath", "controlpersist", "dynamicforward", "exitonforwardfailure",
        "forkafterauthentication", "forwardagent", "forwardx11", "forwardx11trusted",
        "gssapidelegatecredentials", "include", "knownhostscommand", "localcommand",
        "localforward", "permitlocalcommand", "pkcs11provider", "proxycommand",
        "remotecommand", "remoteforward", "requesttty", "securitykeyprovider",
        "sendenv", "sessiontype", "setenv", "stdioforward",
    })
    _BASE = (
        "-o", "ServerAliveInterval=20", "-o", "ServerAliveCountMax=3",
        "-o", "ConnectTimeout=15", "-o", "ForwardAgent=no",
        "-o", "ForwardX11=no", "-o", "ForwardX11Trusted=no",
        "-o", "PermitLocalCommand=no", "-o", "ClearAllForwardings=yes",
        "-o", "ControlMaster=no", "-o", "ControlPath=none",
    )

    def __repr__(self) -> str:
        return f"SSHCommand(destination={self.destination!r}, password={'<redacted>' if self.password is not None else None})"

    @staticmethod
    def _destination(value: str) -> str:
        if not value or value.startswith("-") or value.count("@") > 1:
            raise TransportError("invalid_destination")
        parts = value.split("@")
        if len(parts) == 2 and not re.fullmatch(r"[A-Za-z0-9._+%\-]+", parts[0]):
            raise TransportError("invalid_destination")
        if not re.fullmatch(r"[A-Za-z0-9._+:%\[\]\-]+", parts[-1]):
            raise TransportError("invalid_destination")
        return value

    @classmethod
    def parse(cls, command: str) -> "SSHCommand":
        if not isinstance(command, str) or not command.strip():
            raise TransportError("empty_ssh_command")
        if any(c in command for c in ("\n", "\r", "\0", "`", "$(")):
            raise TransportError("unsafe_ssh_command")
        try:
            words = shlex.split(command, posix=True)
        except ValueError as exc:
            raise TransportError("invalid_ssh_quoting") from exc
        password = prompt = None
        if words[0] in ("sshpass", "/usr/bin/sshpass", "/usr/local/bin/sshpass"):
            words = words[1:]
            while words and words[0].startswith("-"):
                option = words.pop(0)
                if option == "--":
                    break
                if option == "-v":
                    continue
                if option[:2] not in ("-p", "-P"):
                    raise TransportError("invalid_password_wrapper")
                value = option[2:] if len(option) > 2 else (words.pop(0) if words else None)
                if value is None:
                    raise TransportError("invalid_password_wrapper")
                if option[:2] == "-p":
                    if password is not None:
                        raise TransportError("invalid_password_wrapper")
                    password = value
                else:
                    prompt = value
            if password is None:
                raise TransportError("invalid_password_wrapper")
        if not words or words.pop(0) not in ("ssh", "/usr/bin/ssh"):
            raise TransportError("unsupported_ssh_executable")
        options: list[str] = []
        while words:
            token = words.pop(0)
            if token == "--":
                if len(words) != 1:
                    raise TransportError("missing_destination" if not words else "remote_command_not_allowed")
                return cls(cls._destination(words[0]), tuple(options), password, prompt)
            if not token.startswith("-"):
                if words:
                    raise TransportError("remote_command_not_allowed")
                return cls(cls._destination(token), tuple(options), password, prompt)
            if len(token) < 2:
                raise TransportError("unsupported_ssh_option")
            flag = token[1]
            if flag in cls._WITH_VALUE:
                value = token[2:] if len(token) > 2 else (words.pop(0) if words else "")
                if not value or "\0" in value:
                    raise TransportError("unsupported_ssh_option")
                if flag == "p" and (not value.isdecimal() or not 1 <= int(value) <= 65535):
                    raise TransportError("invalid_ssh_port")
                if flag == "J":
                    for jump in value.split(","):
                        cls._destination(jump)
                if flag == "i":
                    value = os.path.expanduser(value)
                if flag == "o":
                    pair = re.split(r"[=\s]+", value, maxsplit=1)
                    if len(pair) != 2 or not re.fullmatch(r"[A-Za-z0-9]+", pair[0]) or not pair[1]:
                        raise TransportError("unsupported_ssh_option")
                    key = pair[0].lower()
                    if key in cls._FORBIDDEN_CONFIG:
                        raise TransportError("unsafe_ssh_option", pair[0])
                    if key == "proxyjump":
                        for jump in pair[1].split(","):
                            cls._destination(jump)
                options.extend(("-" + flag, value))
            elif all(flag in cls._NO_VALUE for flag in token[1:]):
                options.append(token)
            else:
                raise TransportError("unsafe_ssh_option", token)
        raise TransportError("missing_destination")

    def environment(self) -> dict[str, str]:
        env = dict(os.environ)
        for key in ("SSHPASS", "SSH_ASKPASS", "SSH_ASKPASS_REQUIRE", "LD_PRELOAD", "LD_LIBRARY_PATH"):
            env.pop(key, None)
        env["TERM"] = "xterm-256color"
        # ProxyJump launches another ssh through PATH.
        env["PATH"] = "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        if self.password is not None:
            env["SSHPASS"] = self.password
        return env

    def argv(self, remote_command: str | None = None, *, tty: bool = False,
             batch: bool = False, extra: tuple[str, ...] = ()) -> list[str]:
        """Return executable argv; injected client flags always precede the destination."""
        args = ["/usr/bin/ssh", *self._BASE]
        if not any(self.options[i] == "-o" and self.options[i + 1].lower().startswith("stricthostkeychecking")
                   for i in range(len(self.options) - 1)):
            args.extend(("-o", "StrictHostKeyChecking=accept-new"))
        args.extend(("-o", "BatchMode=" + ("yes" if batch and self.password is None else "no")))
        args.extend(("-o", "NumberOfPasswordPrompts=1", "-tt" if tty else "-T"))
        args.extend(extra)
        args.extend(self.options)
        args.append(self.destination)
        if remote_command is not None:
            args.append(remote_command)
        if self.password is not None:
            wrapper = next((path for path in ("/usr/bin/sshpass", "/usr/local/bin/sshpass")
                            if os.access(path, os.X_OK)), None)
            if wrapper is None:
                raise TransportError("sshpass_missing")
            prefix = [wrapper, "-e"]
            if self.password_prompt:
                prefix.extend(("-P", self.password_prompt))
            args = prefix + args
        return args

    def endpoint_key(self, *, resolve: bool = True) -> tuple[str, str, str]:
        """Resolve ssh config aliases to user/hostname/port, with a lexical fallback."""
        user, _, host = self.destination.rpartition("@")
        if not host:
            host = self.destination
        result = {"user": user or getpass.getuser(), "hostname": host, "port": "22"}
        for index, option in enumerate(self.options[:-1]):
            if option == "-p":
                result["port"] = self.options[index + 1]
            elif option == "-l":
                result["user"] = self.options[index + 1]
            elif option == "-o":
                pair = re.split(r"[=\s]+", self.options[index + 1], maxsplit=1)
                if len(pair) == 2 and pair[0].lower() in result:
                    result[pair[0].lower()] = pair[1]
        if resolve:
            args = ["/usr/bin/ssh", "-G", "-o", "PermitLocalCommand=no", *self.options, self.destination]
            try:
                process = subprocess.run(args, capture_output=True, text=True, timeout=5, env=self.environment())
                if process.returncode == 0:
                    for line in process.stdout.splitlines():
                        key, _, value = line.partition(" ")
                        if key in result:
                            result[key] = value.strip()
            except (OSError, subprocess.TimeoutExpired):
                pass
        return result["user"], result["hostname"].rstrip(".").lower().strip("[]"), result["port"]


@dataclasses.dataclass
class TerminalLaunch:
    argv: list[str]
    cwd: str
    env: dict[str, str]
    notice: str | None = None


class TmuxCommand:
    """Pure command construction; tmux targets use exact-match syntax."""

    @staticmethod
    def validate_name(name: str) -> str:
        if not isinstance(name, str) or re.fullmatch(r"[A-Za-z0-9_-]{1,40}", name) is None:
            raise TransportError("invalid_tmux_name")
        return name

    @staticmethod
    def suggested_name(name: str) -> str:
        folded = unicodedata.normalize("NFKD", name).encode("ascii", "ignore").decode().lower()
        slug = re.sub(r"[^a-z0-9_-]+", "-", folded).strip("-") or "window"
        return "uc-" + slug[:28] + "-" + uuid.uuid4().hex[:8]

    @staticmethod
    def validate_window(window: Mapping) -> dict:
        result = dict(window)
        result["tmux"] = TmuxCommand.validate_name(result.get("tmux", ""))
        cwd = result.get("cwd")
        if not isinstance(cwd, str) or not cwd.startswith("/") or any(c in cwd for c in ("\0", "\n", "\r")):
            raise TransportError("invalid_directory")
        agent = result.get("agent") or "terminal"
        if agent not in ("terminal", "shell", "codex", "claude", "agy", "grok", "custom"):
            raise TransportError("unsupported_agent", str(agent))
        session = result.get("sessionId")
        if session is not None and (not isinstance(session, str) or not re.fullmatch(r"[A-Za-z0-9_-]{1,160}", session)):
            raise TransportError("invalid_agent_session")
        if agent in ("terminal", "shell") and session:
            raise TransportError("session_without_agent")
        result["agent"] = agent
        socket_name = result.get("tmuxSocket")
        if socket_name is not None:
            TmuxCommand.validate_name(socket_name)
        model = result.get("model")
        if model is not None and (not isinstance(model, str) or not re.fullmatch(r"[A-Za-z0-9._:/-]{1,120}", model)):
            raise TransportError("invalid_agent_model")
        return result

    @staticmethod
    def agent_argv(window: Mapping) -> list[str]:
        window = TmuxCommand.validate_window(window)
        agent, session, model = window["agent"], window.get("sessionId"), window.get("model")
        if agent in ("terminal", "shell"):
            return []
        if agent == "custom":
            args = window.get("commandArgv")
            if not isinstance(args, list) or not args or not all(isinstance(arg, str) and "\0" not in arg for arg in args):
                raise TransportError("invalid_custom_command")
            return list(args)
        if agent == "codex":
            args = ["codex"] + (["resume", session] if session else []) + ["-C", window["cwd"]]
            if model:
                args += ["-m", model]
            return args
        option = {"claude": "--resume", "agy": "--conversation", "grok": "-r"}[agent]
        args = [agent] + ([option, session] if session else [])
        if model:
            if agent == "agy":
                raise TransportError("unsupported_agent_model", agent)
            args += ["--model", model]
        return args

    @staticmethod
    def pane_command(window: Mapping) -> str:
        window = TmuxCommand.validate_window(window)
        args = TmuxCommand.agent_argv(window)
        script = "cd -- " + shlex.quote(window["cwd"]) + " || exit 72; "
        # Running the agent as a child leaves a usable shell when the agent exits.
        if args:
            script += shlex.join(args) + "; "
        script += 'exec "${SHELL:-/bin/sh}" -l'
        return shlex.join(["/bin/bash", "-lc", script])

    @staticmethod
    def _binary(socket_name: str | None = None) -> str:
        if socket_name is None:
            return "tmux"
        return shlex.join(["tmux", "-L", TmuxCommand.validate_name(socket_name)])

    @staticmethod
    def attach(window: Mapping, *, create: bool = False, socket_name: str | None = None) -> str:
        window = TmuxCommand.validate_window(window)
        socket_name = window.get("tmuxSocket", socket_name)
        binary = TmuxCommand._binary(socket_name)
        # OSC52 crashes tmux 3.2a with recent ncurses. Apply only to UniConnect's
        # dedicated servers, never to the user's default or custom tmux socket.
        clipboard = "set-option -s set-clipboard off" if socket_name in ("uniconnect", "uniconnect-local") else ""
        name = shlex.quote(window["tmux"])
        target = shlex.quote("=" + window["tmux"])
        option_target = shlex.quote("=" + window["tmux"] + ":")
        if create:
            # -A passes the initial command only on creation, never into an existing pane.
            return (f"test -d {shlex.quote(window['cwd'])} || exit 72; exec {binary} new-session -A -s {name} "
                    f"-c {shlex.quote(window['cwd'])} {shlex.quote(TmuxCommand.pane_command(window))} "
                    f"\\; set-option -t {option_target} mouse on \\; set-option -t {option_target} history-limit 50000"
                    + (f" \\; {clipboard}" if clipboard else ""))
        return (f"command -v tmux >/dev/null 2>&1 || exit 127; "
                f"{binary} has-session -t {target} 2>/dev/null || exit 72; "
                f"{binary} set-option -t {option_target} mouse on; "
                f"{binary} set-option -t {option_target} history-limit 50000; "
                + (f"{binary} {clipboard}; " if clipboard else "") +
                f"exec {binary} attach-session -t {target}")


def terminal_launch(workspace: Mapping, window: Mapping, connect_command: str | SSHCommand | None = None,
                    *, create: bool = False) -> TerminalLaunch:
    """Build VTE spawn arguments; closing this process cannot kill the tmux server."""
    effective = dict(window)
    effective["cwd"] = window.get("cwd") or workspace.get("cwd") or str(Path.home())
    if workspace.get("kind") == "ssh":
        effective.setdefault("tmuxSocket", "uniconnect")
        command = connect_command if isinstance(connect_command, SSHCommand) else SSHCommand.parse(connect_command or "")
        script = TmuxCommand.attach(effective, create=create)
        return TerminalLaunch(command.argv(shlex.join(["/bin/bash", "-lc", script]), tty=True),
                              str(Path.home()), command.environment())
    env = dict(os.environ)
    env.pop("TMUX", None)
    env["TERM"] = "xterm-256color"
    cwd = effective["cwd"]
    if not os.path.isdir(cwd):
        fallback = str(Path.home()) if Path.home().is_dir() else "/"
        for key in ("BASH_ENV", "ENV", "PROMPT_COMMAND"):
            env.pop(key, None)
        # Deliberately omit profile/rc startup: this recovery surface cannot start
        # an agent from an unrelated root through a startup file or saved command.
        script = "printf '%s\\n' " + shlex.quote("[UniConnect] " + cwd) + "; exec /bin/bash --noprofile --norc -i"
        return TerminalLaunch(["/bin/bash", "--noprofile", "--norc", "-c", script], fallback, env, cwd)
    if effective.get("tmux"):
        effective.setdefault("tmuxSocket", "uniconnect-local")
        return TerminalLaunch(["/bin/bash", "-lc", TmuxCommand.attach(effective, create=create)], cwd, env)
    # Local windows can be plain terminals, but persisted tmux windows remain attach-only.
    effective.setdefault("tmux", "local")
    return TerminalLaunch(["/bin/bash", "-lc", TmuxCommand.pane_command(effective)], cwd, env)


class Transport:
    """Bounded process I/O, safe to invoke from a GUI worker thread."""

    def __init__(self, command: SSHCommand | str | None = None, *, socket_name: str | None = None):
        self.command = SSHCommand.parse(command) if isinstance(command, str) else command
        self.socket_name = socket_name or ("uniconnect" if self.command else "uniconnect-local")

    def run(self, script: str, *, timeout: float = 25, check: bool = True) -> subprocess.CompletedProcess:
        args = ["/bin/bash", "-lc", script]
        env = dict(os.environ)
        env.pop("TMUX", None)
        env["TERM"] = "xterm-256color"
        if self.command:
            args = self.command.argv(shlex.join(args), batch=True)
            env = self.command.environment()
        try:
            result = subprocess.run(args, text=True, capture_output=True, timeout=timeout, env=env)
        except subprocess.TimeoutExpired as exc:
            raise TransportError("connection_timeout") from exc
        except OSError as exc:
            raise TransportError("process_unavailable", str(exc)) from exc
        if check and result.returncode != 0:
            raise TransportError("remote_command_failed", result.stderr.strip()[-2000:] or str(result.returncode))
        return result

    def probe(self) -> dict:
        script = ("printf 'UC_HOST\\t'; hostname; "
                  "printf 'UC_USER\\t'; id -un; "
                  "printf 'UC_HOME\\t%s\\n' \"$HOME\"; "
                  "for uc_tool in tmux codex claude agy grok python3; do "
                  'uc_location=$(command -v "$uc_tool" 2>/dev/null || true); '
                  "printf 'UC_TOOL\\t%s\\t%s\\n' \"$uc_tool\" \"$uc_location\"; done")
        result = self.run(script)
        output = {"tools": {}}
        for line in result.stdout.splitlines():
            values = line.split("\t")
            if values[0] == "UC_TOOL" and len(values) >= 2:
                output["tools"][values[1]] = (values[2] if len(values) > 2 else "") or None
            elif len(values) == 2 and values[0].startswith("UC_"):
                output[values[0][3:].lower()] = values[1]
        return output

    def preflight(self, window: Mapping) -> dict:
        window = TmuxCommand.validate_window(window)
        binary = TmuxCommand._binary(window.get("tmuxSocket", self.socket_name))
        target = shlex.quote("=" + window["tmux"])
        script = (f"test -d {shlex.quote(window['cwd'])}; printf 'directory=%s\\n' \"$?\"; "
                  "command -v tmux >/dev/null 2>&1; printf 'tmux=%s\\n' \"$?\"; "
                  f"{binary} has-session -t {target} 2>/dev/null; printf 'session=%s\\n' \"$?\"; ")
        args = TmuxCommand.agent_argv(window)
        if args:
            script += f"command -v {shlex.quote(args[0])} >/dev/null 2>&1; printf 'agent=%s\\n' \"$?\"; "
        result = self.run(script)
        statuses = dict(line.split("=", 1) for line in result.stdout.splitlines() if "=" in line)
        return {"tmux": window["tmux"], "directoryExists": statuses.get("directory") == "0",
                "tmuxInstalled": statuses.get("tmux") == "0", "sessionExists": statuses.get("session") == "0",
                "agentInstalled": not args or statuses.get("agent") == "0"}

    def list_sessions(self) -> list[dict]:
        binary = TmuxCommand._binary(self.socket_name)
        result = self.run(f"{binary} list-sessions -F '#{{session_name}}\t#{{session_attached}}\t#{{session_windows}}'",
                          check=False)
        if result.returncode:
            if "no server running" in result.stderr or "No such file" in result.stderr:
                return []
            raise TransportError("tmux_list_failed", result.stderr.strip())
        sessions = []
        for line in result.stdout.splitlines():
            fields = line.split("\t")
            if len(fields) == 3:
                sessions.append({"name": fields[0], "clients": int(fields[1]), "windows": int(fields[2])})
        return sessions

    def capture(self, session: str, *, lines: int = 200) -> str:
        name = TmuxCommand.validate_name(session)
        lines = min(max(int(lines), 1), 50000)
        return self.run(f"{TmuxCommand._binary(self.socket_name)} capture-pane -p -S -{lines} -t {shlex.quote('=' + name + ':')}").stdout

    def ensure_session(self, window: Mapping) -> dict:
        """Explicitly create a missing session; existing panes receive no commands.

        tmux's atomic create chooses one winner under concurrent calls. A marker
        identifies the native conversation, preventing duplicate session owners.
        """
        window = TmuxCommand.validate_window(window)
        socket_name = window.get("tmuxSocket", self.socket_name)
        binary = TmuxCommand._binary(socket_name)
        name = shlex.quote(window["tmux"])
        target = shlex.quote("=" + window["tmux"])
        option_target = shlex.quote("=" + window["tmux"] + ":")
        args = TmuxCommand.agent_argv(window)
        session_id = window.get("sessionId")
        # A lock on the remote host serializes creation across different tmux names.
        # flock's kernel lifetime avoids stale lock directories after a crash/reboot.
        script = f"command -v tmux >/dev/null 2>&1 || exit 127; test -d {shlex.quote(window['cwd'])} || exit 72; "
        if args:
            script += f"command -v {shlex.quote(args[0])} >/dev/null 2>&1 || exit 127; "
        body = (f"if {binary} has-session -t {target} 2>/dev/null; then "
                "printf 'UC_EXISTS\\n'; exit 0; fi; ")
        if session_id:
            owner = shlex.quote(window["agent"] + ":" + session_id.lower())
            body += (f"uc_owner={owner}; "
                     f"if {binary} list-sessions -F '#{{@uniconnect_agent_owner}}' 2>/dev/null | "
                     "grep -Fx -- \"$uc_owner\" >/dev/null; then exit 73; fi; ")
        body += (f"if {binary} new-session -d -s {name} -c {shlex.quote(window['cwd'])} "
                 f"{shlex.quote(TmuxCommand.pane_command(window))}; then "
                 f"{binary} set-option -t {option_target} mouse on; "
                 f"{binary} set-option -t {option_target} history-limit 50000; ")
        if socket_name in ("uniconnect", "uniconnect-local"):
            body += f"{binary} set-option -s set-clipboard off; "
        if session_id:
            body += f"{binary} set-option -t {option_target} @uniconnect_agent_owner \"$uc_owner\"; "
        body += ("printf 'UC_CREATED\\n'; "
                 f"elif {binary} has-session -t {target} 2>/dev/null; then printf 'UC_EXISTS\\n'; else exit 74; fi")
        lock_suffix = "-" + socket_name if socket_name else ""
        script += ("command -v flock >/dev/null 2>&1 || exit 127; "
                   'umask 077; mkdir -p "$HOME/.local/state/uniconnect" || exit 74; '
                   # Close the lock descriptor in the child: a newly daemonized tmux
                   # server must not inherit it and hold the creation lock forever.
                   f"exec flock --close -w 20 \"$HOME/.local/state/uniconnect/tmux-create{lock_suffix}.lock\" "
                   + shlex.join(["/bin/bash", "-lc", body]))
        result = self.run(script, check=False)
        if result.returncode == 73:
            raise TransportError("duplicate_agent_owner", session_id or "")
        if result.returncode != 0:
            raise TransportError("tmux_create_failed", result.stderr.strip() or str(result.returncode))
        return {"tmux": window["tmux"], "created": "UC_CREATED" in result.stdout.splitlines()}
