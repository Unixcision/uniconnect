"""An ephemeral, key-only SSH server for CI; never uses user SSH sessions."""

import os
from pathlib import Path
import secrets
import signal
import shlex
import socket
import subprocess
import tempfile
import time
import uuid


class SSHCopyFixture:
    def __enter__(self):
        self.directory = tempfile.TemporaryDirectory(prefix="uc-copy-sshd-")
        root = Path(self.directory.name)
        self.pid_file = root / "pid"
        self.config_file = root / "sshd_config"
        self.log_file = root / "sshd.log"
        self.user = "uc-copy-" + uuid.uuid4().hex[:8]
        self.user_created = False
        for name in ("host", "client"):
            subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(root / name)], check=True)
        with socket.socket() as reservation:
            reservation.bind(("127.0.0.1", 0))
            port = reservation.getsockname()[1]
        # A dedicated unlocked CI account avoids relying on a locked runner
        # account, while StrictModes still checks a conventional owned ~/.ssh.
        home = Path("/home") / self.user
        secret = secrets.token_urlsafe(32).encode()
        password_hash = subprocess.run(
            ["openssl", "passwd", "-6", "-salt", uuid.uuid4().hex[:16], "-stdin"],
            input=secret, capture_output=True, check=True).stdout.decode().strip()
        try:
            subprocess.run(["sudo", "-n", "useradd", "--no-create-home", "--no-user-group",
                            "--gid", "nogroup", "--home-dir", str(home), "--shell", "/bin/sh",
                            "--password", password_hash, self.user], check=True, timeout=10)
            self.user_created = True
            subprocess.run(["sudo", "-n", "install", "-d", "-m", "755", "-o", self.user,
                            "-g", "nogroup", str(home)], check=True, timeout=10)
            key_dir = home / ".ssh"
            subprocess.run(["sudo", "-n", "install", "-d", "-m", "700", "-o", self.user,
                            "-g", "nogroup", str(key_dir)], check=True, timeout=10)
            subprocess.run(["sudo", "-n", "install", "-m", "600", "-o", self.user,
                            "-g", "nogroup", str(root / "client.pub"), str(key_dir / "authorized_keys")],
                           check=True, timeout=10)
        except Exception:
            if subprocess.run(["getent", "passwd", self.user], check=False, capture_output=True).returncode == 0:
                self.user_created = True
            self._remove_user()
            self.directory.cleanup()
            raise
        (root / "known_hosts").write_text(f"[127.0.0.1]:{port} " + (root / "host.pub").read_text())
        self.config_file.write_text(f"""Port {port}
ListenAddress 127.0.0.1
HostKey {root / 'host'}
PidFile {self.pid_file}
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
UsePAM no
StrictModes yes
PermitRootLogin prohibit-password
AllowUsers {self.user}
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
            self._remove_user()
            self.directory.cleanup()
            raise RuntimeError("Isolated SSH server did not become ready: " + server_log)
        self.command = shlex.join(["ssh", "-p", str(port), "-i", str(root / "client"),
                                   "-o", "IdentitiesOnly=yes", "-o", "StrictHostKeyChecking=yes",
                                   "-o", "UserKnownHostsFile=" + str(root / "known_hosts"),
                                   self.user + "@127.0.0.1"])
        probe = subprocess.run(shlex.split(self.command) + ['true'], capture_output=True, text=True, timeout=8)
        if probe.returncode:
            server_log = self._stop_server()
            self._remove_user()
            self.directory.cleanup()
            raise RuntimeError('CI SSH authentication failed: ' + probe.stderr + server_log)
        return self

    def __exit__(self, *_):
        self._stop_server()
        self._remove_user()
        if getattr(self, "directory", None):
            self.directory.cleanup()

    def _remove_user(self):
        if getattr(self, "user_created", False) and getattr(self, "user", None):
            subprocess.run(["sudo", "-n", "userdel", "--remove", self.user],
                           check=False, capture_output=True)
            self.user = None
            self.user_created = False

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
