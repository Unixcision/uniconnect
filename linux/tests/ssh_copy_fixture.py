"""An ephemeral, key-only SSH server for CI; never uses user SSH sessions."""

import getpass
import os
from pathlib import Path
import shlex
import socket
import subprocess
import tempfile


class SSHCopyFixture:
    def __enter__(self):
        self.directory = tempfile.TemporaryDirectory(prefix="uc-copy-sshd-")
        root = Path(self.directory.name)
        for name in ("host", "client"):
            subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(root / name)], check=True)
        with socket.socket() as reservation:
            reservation.bind(("127.0.0.1", 0))
            port = reservation.getsockname()[1]
        (root / "authorized_keys").write_bytes((root / "client.pub").read_bytes())
        (root / "known_hosts").write_text(f"[127.0.0.1]:{port} " + (root / "host.pub").read_text())
        config = root / "sshd_config"
        config.write_text(f"""Port {port}
ListenAddress 127.0.0.1
HostKey {root / 'host'}
PidFile {root / 'pid'}
AuthorizedKeysFile {root / 'authorized_keys'}
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
UsePAM yes
PermitRootLogin prohibit-password
AllowUsers {getpass.getuser()}
LogLevel VERBOSE
""")
        self.server = subprocess.Popen(["sudo", "-n", "/usr/sbin/sshd", "-D", "-e", "-f", str(config)], stderr=subprocess.PIPE, text=True)
        # sshd reports readiness explicitly. CI has an outer job deadline.
        line = self.server.stderr.readline()
        if "Server listening" not in line:
            self.__exit__(None, None, None)
            raise RuntimeError("Isolated SSH server did not become ready: " + line)
        self.command = shlex.join(["ssh", "-p", str(port), "-i", str(root / "client"),
                                   "-o", "IdentitiesOnly=yes", "-o", "StrictHostKeyChecking=yes",
                                   "-o", "UserKnownHostsFile=" + str(root / "known_hosts"),
                                   getpass.getuser() + "@127.0.0.1"])
        probe = subprocess.run(shlex.split(self.command) + ['true'], capture_output=True, text=True, timeout=8)
        if probe.returncode:
            self.__exit__(None, None, None)
            raise RuntimeError('CI SSH authentication failed: ' + probe.stderr)
        return self

    def __exit__(self, *_):
        if getattr(self, "server", None):
            self.server.terminate()
            self.server.wait(timeout=5)
            self.server.stderr.close()
        self.directory.cleanup()
