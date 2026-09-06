"""PTY Linux de un cliente móvil: attach existente, sin modificar el escritorio."""

from __future__ import annotations

import errno
import fcntl
import math
import os
import pty
import re
import select
import shlex
import signal
import struct
import subprocess
import sys
import termios
import threading
import time
import uuid
from pathlib import Path

from .transport import SSHCommand, TerminalLaunch, TmuxCommand, TransportError


class MobilePTYProcess:
    """Un PTY no bloqueante; el propietario coordina eventos y cierre.

    ``wait_ready`` must succeed before publishing any bytes. ``read`` raises
    BlockingIOError when temporarily empty and returns b'' at EOF. ``write``
    returns the accepted byte count (zero on backpressure); callers retain the
    unwritten suffix. Tests inject a TerminalLaunch targeting a private socket.
    """

    _TOKEN_ENV = "UNICONNECT_MOBILE_PTY_TOKEN"
    _MAX_PREAMBLE = 1024 * 1024

    @staticmethod
    def _tmux_argv(socket_name):
        # Remote installations may put tmux in /usr/local/bin or Homebrew.
        return ["tmux", "-N", "-L", socket_name]

    @classmethod
    def build_launch(cls, workspace, record, connect=None):
        kind = workspace.get("kind")
        if kind not in ("local", "ssh"):
            raise TransportError("mobile_pty_invalid_workspace")
        name = TmuxCommand.validate_name(record.get("tmux"))
        socket_name = TmuxCommand.validate_name(record.get("tmuxSocket") or
                                                ("uniconnect" if kind == "ssh" else "uniconnect-local"))
        pane = record.get("paneId")
        if not isinstance(pane, str):
            raise TransportError("mobile_pty_invalid_pane")
        explicit_pane = re.fullmatch(r"%[0-9]{1,20}", pane) is not None
        if not explicit_pane and re.fullmatch(r"[A-Za-z0-9_-]{1,128}", pane) is None:
            raise TransportError("mobile_pty_invalid_pane")
        token = uuid.uuid4().hex
        binary = cls._tmux_argv(socket_name)
        target = "=" + name + (":." + pane if explicit_pane else ":")
        if explicit_pane:
            pane_guard = "#{==:#{pane_id}," + pane + "}"
        else:
            # Local records keep GTK layout IDs such as main, not tmux %IDs.
            # Resolve only an unambiguous exact session, in the native queue;
            # never choose the currently selected pane among several windows.
            pane_guard = "#{&&:#{==:#{session_windows},1},#{==:#{window_panes},1}}"
            pane = "#{pane_id}"
        auxiliary = "uc-mobile-" + token
        # active-pane alone does not isolate session window selection. A
        # presentation session links the SAME target window/panes and keeps
        # this client's selection apart. Grouped new-session briefly launches
        # default-command, even when it subsequently replaces its initial pane.
        # Two explicit argv launch only our bounded sleep placeholder (no shell
        # or IA); link-window -k replaces only that privately named placeholder.
        guard = "#{&&:#{==:#{session_name}," + name + "}," + pane_guard + "}"
        # display-message -p after attach enters view-mode and consumes input;
        # write the nonce directly to this client's TTY instead (no pane input).
        ready = "printf '\\036UCPTY_READY_" + token + "\\037' > '##{client_tty}'"
        commands = [["new-session", "-E", "-f", "ignore-size,active-pane", "-s", auxiliary,
                     "-n", "uc-placeholder", "/bin/sleep", "60"],
                    ["set-option", "-t", auxiliary, "destroy-unattached", "on"],
                    ["set-option", "-t", auxiliary, "detach-on-destroy", "on"],
                    ["set-option", "-t", auxiliary, "mouse", "on"],
                    ["link-window", "-k", "-s", "#{window_id}", "-t", "=" + auxiliary + ":uc-placeholder"],
                    ["select-window", "-t", "=" + auxiliary + ":." + pane],
                    ["select-pane", "-t", "=" + auxiliary + ":." + pane],
                    ["run-shell", "-b", ready]]
        # -C expands the exact original @window ID in the validated pane
        # context, then queues native tmux commands, not another shell. The
        # doubled # defers the readiness TTY expansion until after attachment.
        native = ["run-shell", "-C", "-t", target,
                  " ; ".join(shlex.join(command) for command in commands)]
        attach = binary + ["if-shell", "-F", "-t", target, guard,
                           shlex.join(native)]
        script = "printf '\\036UCPTY_BEGIN_" + token + "\\037'; exec " + shlex.join(attach)
        argv = ["/bin/sh", "-c", script]
        if kind == "ssh":
            command = connect if isinstance(connect, SSHCommand) else SSHCommand.parse(connect or "")
            argv, env = command.argv(shlex.join(argv), tty=True, batch=True), command.environment()
        else:
            env = dict(os.environ)
            env["PATH"] = "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        for key in ("TMUX", "TMUX_PANE", "BASH_ENV", "ENV", "PROMPT_COMMAND"):
            env.pop(key, None)
        env.update(TERM="xterm-256color", **{cls._TOKEN_ENV: token})
        # A vanished saved cwd cannot turn attach into a fallback shell.
        return TerminalLaunch(argv, "/", env)

    @staticmethod
    def _size(columns, rows):
        if any(type(value) is not int or not 1 <= value <= 65535 for value in (columns, rows)):
            raise TransportError("mobile_pty_invalid_size")
        return struct.pack("HHHH", rows, columns, 0, 0)

    def __init__(self, launch, columns, rows):
        size = self._size(columns, rows)
        if (not isinstance(launch, TerminalLaunch) or not launch.argv or
                any(not isinstance(item, str) or "\0" in item for item in launch.argv) or
                not os.path.isabs(launch.argv[0])):
            raise TransportError("mobile_pty_invalid_launch")
        self._token = launch.env.get(self._TOKEN_ENV)
        self._lock = threading.Lock()
        self._buffer = bytearray()
        self._ready = False
        self._closed = threading.Event()
        master, slave = pty.openpty()
        self._master = master
        try:
            fcntl.ioctl(slave, termios.TIOCSWINSZ, size)
            os.set_blocking(master, False)
            helper = str(Path(__file__).with_name("mobile_pty_child.py"))
            self._process = subprocess.Popen([sys.executable, "-I", helper, *launch.argv],
                                             stdin=slave, stdout=slave, stderr=slave,
                                             cwd=launch.cwd, env=launch.env,
                                             close_fds=True, start_new_session=True)
        except Exception:
            os.close(master)
            self._master = -1
            raise
        finally:
            os.close(slave)

    @property
    def pid(self):
        return self._process.pid

    def fileno(self):
        return self._master

    def _read_raw(self, maximum):
        if self._master < 0:
            return b""
        try:
            return os.read(self._master, maximum)
        except OSError as error:
            if error.errno == errno.EIO:  # Linux PTY EOF after the slave closes.
                return b""
            raise

    def read(self, max_bytes=65536):
        if type(max_bytes) is not int or not 1 <= max_bytes <= 65536:
            raise ValueError("Tamaño de lectura no válido.")
        with self._lock:
            if self._buffer:
                result = bytes(self._buffer[:max_bytes])
                del self._buffer[:max_bytes]
                return result
            return self._read_raw(max_bytes)

    def wait_ready(self, timeout=5, cancelled=None):
        """Wait for this client's post-attach nonce; retain every terminal byte.

        SSH banners before BEGIN are discarded. BEGIN alone is not readiness.
        On timeout/cancellation/failed attach, close only this client's group and
        raise TransportError with a stable code; never expose diagnostic output.
        """
        if type(timeout) not in (int, float) or not math.isfinite(timeout) or not 0 < timeout <= 120:
            raise TransportError("mobile_pty_invalid_timeout")
        if self._ready:
            if self._closed.is_set() or self.poll() is not None:
                raise TransportError("mobile_pty_attach_failed")
            return True
        if not isinstance(self._token, str) or re.fullmatch(r"[0-9a-f]{32}", self._token) is None:
            raise TransportError("mobile_pty_readiness_unavailable")
        begin = ("\x1eUCPTY_BEGIN_" + self._token + "\x1f").encode("ascii")
        ready = ("\x1eUCPTY_READY_" + self._token + "\x1f").encode("ascii")
        pending = bytearray()
        begun = False
        observed = 0
        deadline = time.monotonic() + timeout
        try:
            while True:
                if self._closed.is_set() or (cancelled is not None and cancelled()):
                    raise TransportError("mobile_pty_cancelled")
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise TransportError("mobile_pty_attach_timeout")
                readable, _, _ = select.select([self._master], [], [], min(0.05, remaining))
                if not readable:
                    continue
                with self._lock:
                    try:
                        chunk = self._read_raw(65536)
                    except BlockingIOError:
                        continue
                if not chunk:
                    raise TransportError("mobile_pty_attach_failed")
                pending.extend(chunk)
                observed += len(chunk)
                if observed > self._MAX_PREAMBLE:
                    raise TransportError("mobile_pty_preamble_overflow")
                if not begun:
                    position = pending.find(begin)
                    if position < 0:
                        continue
                    del pending[:position + len(begin)]
                    begun = True
                position = pending.find(ready)
                if position >= 0:
                    del pending[position:position + len(ready)]
                    if self.poll() is not None or self._closed.is_set() or (cancelled and cancelled()):
                        raise TransportError("mobile_pty_attach_failed")
                    with self._lock:
                        self._buffer.extend(pending)
                        self._ready = True
                    return True
        except (OSError, ValueError):
            self.close()
            raise TransportError("mobile_pty_attach_failed") from None
        except Exception:
            self.close()
            raise

    def write(self, data):
        with self._lock:
            if self._master < 0:
                raise TransportError("mobile_pty_closed")
            try:
                return os.write(self._master, data)
            except BlockingIOError:
                return 0

    def resize(self, columns, rows):
        size = self._size(columns, rows)
        with self._lock:
            if self._master < 0:
                raise TransportError("mobile_pty_closed")
            fcntl.ioctl(self._master, termios.TIOCSWINSZ, size)

    def poll(self):
        return self._process.poll()

    def close(self):
        with self._lock:
            if self._closed.is_set():
                return
            self._closed.set()
            os.close(self._master)
            self._master = -1
            self._buffer.clear()
        for number in (signal.SIGTERM, signal.SIGKILL):
            if self._process.poll() is not None:
                break
            try:
                if os.getpgid(self.pid) == self.pid:
                    os.killpg(self.pid, number)
            except ProcessLookupError:
                pass
            try:
                self._process.wait(timeout=0.5)
            except subprocess.TimeoutExpired:
                continue
