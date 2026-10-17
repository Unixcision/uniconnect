"""An ephemeral, key-only SSH server for CI; never uses user SSH sessions."""

import getpass
import os
from pathlib import Path
import signal
import shlex
import socket
import subprocess
import tempfile
import time


class SSHCopyFixture:
    def __enter__(self):
        self.directory = tempfile.TemporaryDirectory(prefix="uc-copy-sshd-")
        root = Path(self.directory.name)
        self.pid_file = root / "pid"
        self.config_file = root / "sshd_config"
        self.log_file = root / "sshd.log"
        for name in ("host", "client"):
            subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(root / name)], check=True)
        with socket.socket() as reservation:
            reservation.bind(("127.0.0.1", 0))
            port = reservation.getsockname()[1]
        (root / "authorized_keys").write_bytes((root / "client.pub").read_bytes())
        (root / "known_hosts").write_text(f"[127.0.0.1]:{port} " + (root / "host.pub").read_text())
        self.config_file.write_text(f"""Port {port}
ListenAddress 127.0.0.1
HostKey {root / 'host'}
PidFile {self.pid_file}
AuthorizedKeysFile {root / 'authorized_keys'}
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
UsePAM no
StrictModes no
PermitRootLogin prohibit-password
AllowUsers {getpass.getuser()}
LogLevel DEBUG2
""")
        # sshd (or sudo's child) may retain inherited stderr after the direct
        # process exits. Keep diagnostics in the dedicated log file so cleanup
        # cannot block reading a pipe whose writer is an orphaned child.
        self.server = subprocess.Popen(["sudo", "-n", "/usr/sbin/sshd", "-D", "-E", str(self.log_file),
                                        "-f", str(self.config_file)], stderr=subprocess.DEVNULL,
                                       stdout=subprocess.DEVNULL, start_new_session=True)
        # Probe the bound loopback port instead of reading a particular first log
        # line; DEBUG logging differs between the supported Ubuntu OpenSSH builds.
        deadline = time.monotonic() + 5
        ready = False
        while self.server.poll() is None and time.monotonic() < deadline:
            try:
                with socket.create_connection(("127.0.0.1", port), timeout=0.2):
                    ready = True
                    break
            except OSError:
                time.sleep(0.05)
        if not ready:
            server_log = self._stop_server()
            raise RuntimeError("Isolated SSH server did not become ready: " + server_log)
        self.command = shlex.join(["ssh", "-p", str(port), "-i", str(root / "client"),
                                   "-o", "IdentitiesOnly=yes", "-o", "StrictHostKeyChecking=yes",
                                   "-o", "UserKnownHostsFile=" + str(root / "known_hosts"),
                                   getpass.getuser() + "@127.0.0.1"])
        probe = subprocess.run(shlex.split(self.command) + ['true'], capture_output=True, text=True, timeout=8)
        if probe.returncode:
            server_log = self._stop_server()
            raise RuntimeError('CI SSH authentication failed: ' + probe.stderr + server_log)
        return self

    def __exit__(self, *_):
        self._stop_server()
        if getattr(self, "directory", None):
            self.directory.cleanup()

    def _stop_server(self):
        """Stop only this fixture's isolated process group, including sudo's sshd child."""
        if not getattr(self, "server", None):
            return ""
        try:
            os.killpg(self.server.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        if self.server.poll() is None:
            try:
                self.server.wait(timeout=5)
            except subprocess.TimeoutExpired:
                try:
                    os.killpg(self.server.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                self.server.wait(timeout=5)
        log = ""
        if getattr(self, "log_file", None):
            try:
                log = "\nsshd log:\n" + self.log_file.read_text(errors="replace")[-6000:]
            except OSError:
                pass
        return log
