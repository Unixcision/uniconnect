"""Read-only OS proof that one nonce-bearing tmux client really attached.

The domain coordinator decides whether this proof may commit a candidate. This
adapter only observes tmux clients and Linux process metadata; it never creates
sessions, captures terminals, sends keys, or changes a tmux option.
"""

from __future__ import annotations

import json
import math
import os
import re
import selectors
import shlex
import signal
import subprocess
import time

from .transport import TmuxCommand, TransportError


class ReadinessError(RuntimeError):
    """Stable failure code without connection arguments, environment or output."""

    def __init__(self, code):
        self.code = code
        super().__init__(code)


class TmuxAttachmentProbe:
    """Wait for the exact live tmux client carrying a candidate's random nonce.

    ``record`` supplies ``tmux`` and optionally ``tmuxSocket``. ``cancel_event``
    is a threading.Event-compatible object. One cancellable diagnostic process
    uses the existing Transport's SSH arguments/environment; the same Python
    script runs locally or through one SSH connection. No SSH polling occurs.
    Cancellation kills only that newly created diagnostic process group. Closing
    its stdin also tells the remote observer to exit; its own deadline is bounded.
    """

    # The remote host's existing python3 can be 3.9. Keep this script stdlib-only.
    _SCRIPT = r'''
import json
import os
import select
import subprocess
import sys
import time

def emit_error(code):
    print(json.dumps({"error": code}), flush=True)
    return 1

def main():
    name, socket_name, token, duration = sys.argv[1:]
    deadline = time.monotonic() + float(duration)
    binary = ["tmux", "-L", socket_name]
    expected = b"UNICONNECT_ATTACH_TOKEN=" + token.encode("ascii")
    denied = False

    def clients():
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            return []
        result = subprocess.run(binary + ["list-clients", "-F", "#{client_pid}\t#{client_session}"],
                                stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                stderr=subprocess.DEVNULL, timeout=min(1.0, remaining))
        if result.returncode:
            return []
        # This is metadata only; never request pane contents or environment output.
        if len(result.stdout) > 262144:
            raise ValueError()
        found = []
        for line in result.stdout.decode("utf-8", "strict").splitlines():
            parts = line.split("\t")
            if len(parts) == 2 and parts[1] == name and parts[0].isdigit():
                pid = int(parts[0])
                if pid > 0:
                    found.append(pid)
        return found

    def identity(pid):
        with open("/proc/{}/stat".format(pid), "rb") as handle:
            fields = handle.read(8192).rsplit(b") ", 1)[1].split()
        # State and start time protect against dead clients and PID reuse.
        return fields[0], fields[19]

    while time.monotonic() < deadline:
        try:
            for pid in clients():
                try:
                    before = identity(pid)
                    if before[0] in (b"Z", b"X", b"x"):
                        continue
                    with open("/proc/{}/environ".format(pid), "rb") as handle:
                        environment = handle.read(1048577)
                    if len(environment) > 1048576 or expected not in environment.split(b"\0"):
                        continue
                    # Recheck both authorities after reading the private environment.
                    if pid in clients() and identity(pid) == before:
                        print(json.dumps({"kind": "tmux-client-attached", "token": token,
                                          "tmux": name, "clientPid": pid}), flush=True)
                        return 0
                except PermissionError:
                    denied = True
                except (FileNotFoundError, ProcessLookupError, IndexError):
                    continue
        except FileNotFoundError:
            return emit_error("readiness_tmux_unavailable")
        except subprocess.TimeoutExpired:
            pass
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            break
        # Bounded observation interval, with immediate EOF cancellation from SSH/stdin.
        readable, _, _ = select.select([sys.stdin], [], [], min(0.1, remaining))
        if readable and not os.read(sys.stdin.fileno(), 1):
            return emit_error("readiness_cancelled")
    return emit_error("readiness_inspection_denied" if denied else "readiness_timeout")

try:
    sys.exit(main())
except Exception:
    sys.exit(emit_error("readiness_probe_failed"))
'''

    _REMOTE_CODES = frozenset({"readiness_tmux_unavailable", "readiness_cancelled",
                               "readiness_inspection_denied", "readiness_timeout", "readiness_probe_failed"})

    def __init__(self, transport, record, token, cancel_event):
        if not isinstance(token, str) or re.fullmatch(r"[0-9a-fA-F]{16,128}", token) is None:
            raise ReadinessError("readiness_invalid_token")
        try:
            self.tmux = TmuxCommand.validate_name(record["tmux"])
            self.socket_name = TmuxCommand.validate_name(record.get("tmuxSocket") or transport.socket_name)
        except (KeyError, TypeError, AttributeError, TransportError):
            raise ReadinessError("readiness_invalid_target") from None
        if not callable(getattr(cancel_event, "is_set", None)):
            raise ReadinessError("readiness_invalid_cancellation")
        self.transport, self.token, self.cancel_event = transport, token, cancel_event

    def _launch(self, timeout):
        script = shlex.join(["python3", "-c", self._SCRIPT, self.tmux, self.socket_name, self.token, str(timeout)])
        args = ["/bin/bash", "-lc", "exec " + script]
        command = self.transport.command
        if command is not None:
            args = command.argv(shlex.join(args), batch=True)
            env = command.environment()
        else:
            env = dict(os.environ)
            env.pop("TMUX", None)
            env["TERM"] = "xterm-256color"
        # New session/group isolates cancellation from the user's VTE/SSH/tmux client.
        return subprocess.Popen(args, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                stderr=subprocess.DEVNULL, env=env, start_new_session=True)

    @staticmethod
    def _stop(process):
        if process.stdin and not process.stdin.closed:
            try:
                process.stdin.close()
            except OSError:
                pass
        if process.poll() is None:
            try:
                os.killpg(process.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                process.wait(timeout=0.5)
            except subprocess.TimeoutExpired:
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                process.wait(timeout=0.5)
        if process.stdout:
            process.stdout.close()

    @staticmethod
    def _unique_pairs(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError("duplicate proof field")
            result[key] = value
        return result

    def wait(self, timeout=20):
        """Return a live-client proof or raise ReadinessError with a stable code."""
        if type(timeout) not in (int, float) or not math.isfinite(timeout) or not 0 < timeout <= 120:
            raise ReadinessError("readiness_invalid_timeout")
        if self.cancel_event.is_set():
            raise ReadinessError("readiness_cancelled")
        deadline = time.monotonic() + timeout
        try:
            process = self._launch(timeout)
        except (OSError, ValueError, TransportError):
            raise ReadinessError("readiness_transport_failed") from None
        output = bytearray()
        selector = selectors.DefaultSelector()
        try:
            selector.register(process.stdout, selectors.EVENT_READ)
            while True:
                if self.cancel_event.is_set():
                    raise ReadinessError("readiness_cancelled")
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise ReadinessError("readiness_timeout")
                for key, _ in selector.select(min(0.05, remaining)):
                    chunk = os.read(key.fd, 4097)
                    if not chunk:
                        selector.unregister(key.fileobj)
                    else:
                        output.extend(chunk)
                    if len(output) > 4096:
                        raise ReadinessError("readiness_invalid_proof")
                if process.poll() is not None and not selector.get_map():
                    break
            try:
                proof = json.loads(output, object_pairs_hook=self._unique_pairs)
            except (ValueError, UnicodeError, RecursionError):
                raise ReadinessError("readiness_transport_failed" if process.returncode else "readiness_invalid_proof") from None
            if (isinstance(proof, dict) and set(proof) == {"error"}
                    and isinstance(proof["error"], str) and proof["error"] in self._REMOTE_CODES):
                raise ReadinessError(proof["error"])
            if process.returncode:
                raise ReadinessError("readiness_transport_failed")
            if (not isinstance(proof, dict) or set(proof) != {"kind", "token", "tmux", "clientPid"}
                    or proof["kind"] != "tmux-client-attached" or proof["token"] != self.token
                    or proof["tmux"] != self.tmux or type(proof["clientPid"]) is not int or proof["clientPid"] <= 0):
                raise ReadinessError("readiness_invalid_proof")
            if self.cancel_event.is_set():
                raise ReadinessError("readiness_cancelled")
            return proof
        except OSError:
            raise ReadinessError("readiness_transport_failed") from None
        finally:
            selector.close()
            self._stop(process)
