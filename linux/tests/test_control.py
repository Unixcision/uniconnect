"""Black-box desktop/CLI crash recovery against a private local tmux fixture."""

import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import unittest
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from uniconnect.state import StateStore
from uniconnect.transport import Transport
from uniconnect.vault import Vault


@unittest.skipUnless(os.environ.get("DISPLAY") and shutil.which("tmux") and os.geteuid() == 0,
                     "Needs private display, tmux, and automatic host credential backend")
class DesktopControlTests(unittest.TestCase):
    def test_real_desktop_crash_keeps_tmux_and_reopens_without_password(self):
        source = Path(__file__).resolve().parents[1]
        socket_name = "uc-cli-test-" + uuid.uuid4().hex[:10]
        processes = []
        with tempfile.TemporaryDirectory(prefix="uc-control-") as folder:
            root = Path(folder) / "state"
            vault = Vault(root)
            vault.initialize()
            store = StateStore(root, vault=vault)
            record = {"id": "test-window", "name": "Control fixture", "agent": "shell", "tmux": "control",
                      "tmuxSocket": socket_name, "cwd": folder}
            workspace = {"id": "test-workspace", "name": "Test", "kind": "local", "cwd": folder,
                         "windows": [record], "selectedWindowId": record["id"]}
            store.workspaces.append(workspace)
            store.data["selectedWorkspaceId"] = workspace["id"]
            store.save()
            transport = Transport(socket_name=socket_name)
            transport.ensure_session(record)
            initial_pid = transport.list_sessions()[0]["name"]

            def request(command, **extra):
                with socket.socket(socket.AF_UNIX) as client:
                    client.settimeout(2)
                    client.connect(str(root / "control.sock"))
                    client.sendall(json.dumps({"command": command, **extra}).encode() + b"\n")
                    buffer = b""
                    while b"\n" not in buffer:
                        part = client.recv(65536)
                        if not part:
                            raise RuntimeError("Desktop closed its socket")
                        buffer += part
                result = json.loads(buffer)
                self.assertTrue(result["ok"], result)
                return result["result"]

            def start():
                process = subprocess.Popen([str(source / "uniconnect-linux"), "--state-dir", str(root)],
                                           stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
                processes.append(process)
                deadline = time.monotonic() + 12
                while time.monotonic() < deadline:
                    if process.poll() is not None:
                        self.fail(process.stderr.read().decode())
                    try:
                        if request("list-surfaces")[0]["status"] == "Running":
                            return process
                    except (OSError, RuntimeError):
                        pass
                    time.sleep(0.05)
                self.fail("The live desktop did not publish a ready terminal")

            try:
                process = start()
                self.assertFalse(request("ping")["locked"])
                self.assertEqual(request("list-workspaces")[0]["name"], "Test")
                request("send", text="printf 'UC_CONTROL_VERIFIED\\n'\n")
                deadline = time.monotonic() + 5
                while "UC_CONTROL_VERIFIED" not in request("read-screen"):
                    self.assertLess(time.monotonic(), deadline)
                    time.sleep(0.05)
                pane_before = subprocess.check_output(["tmux", "-L", socket_name, "display-message", "-p",
                                                       "-t", "=control:", "#{pane_pid}"], text=True).strip()
                request("persist")
                process.kill()
                process.wait(timeout=5)
                start()
                pane_after = subprocess.check_output(["tmux", "-L", socket_name, "display-message", "-p",
                                                      "-t", "=control:", "#{pane_pid}"], text=True).strip()
                self.assertEqual(pane_before, pane_after)
                self.assertFalse(request("ping")["locked"])
                self.assertEqual(request("identify")["surface"], record["id"])
                deadline = time.monotonic() + 5
                while "UC_CONTROL_VERIFIED" not in request("read-screen"):
                    self.assertLess(time.monotonic(), deadline)
                    time.sleep(0.05)
            finally:
                for process in processes:
                    if process.poll() is None:
                        process.terminate()
                        process.wait(timeout=5)
                    process.stderr.close()
                subprocess.run(["tmux", "-L", socket_name, "kill-server"], capture_output=True)
                (Path.home() / ".local/state/uniconnect" / ("tmux-create-" + socket_name + ".lock")).unlink(missing_ok=True)


if __name__ == "__main__":
    unittest.main()
