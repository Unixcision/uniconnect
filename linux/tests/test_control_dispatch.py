"""Socket de control sin GTK: «save» contesta cuando ya está guardado y «details» da el JSON común."""

import importlib
import json
from pathlib import Path
import sys
import types
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
sys.path.insert(0, str(Path(__file__).resolve().parent))

from contracts_dir import contract


def import_control():
    """uniconnect.control con GLib real si existe; si no, con un GLib vacío solo para importarlo."""
    try:
        import gi  # noqa: F401
        return importlib.import_module("uniconnect.control")
    except ImportError:
        pass
    fake_gi = types.ModuleType("gi")
    fake_repository = types.ModuleType("gi.repository")
    fake_repository.GLib = types.SimpleNamespace()
    fake_gi.repository = fake_repository
    saved = {name: sys.modules.get(name) for name in ("gi", "gi.repository")}
    sys.modules.update({"gi": fake_gi, "gi.repository": fake_repository})
    try:
        return importlib.import_module("uniconnect.control")
    finally:
        for name, module in saved.items():
            if module is None:
                sys.modules.pop(name, None)
            else:
                sys.modules[name] = module


control = import_control()


class Window:
    def __init__(self):
        self.locked = False
        self.relaunch = object()
        self.saves = []
        record = {"id": "w", "name": "hgabot", "tmux": "hgabot", "tmuxSocket": "default", "agent": "shell", "cwd": "/root"}
        self.store = types.SimpleNamespace(
            workspaces=[{"id": "box", "name": "XUNIS", "kind": "ssh", "hostLabel": "root@10.0.0.2", "windows": [record]}],
            data={"selectedWorkspaceId": "box"})

    def action_save(self, done=None):
        self.saves.append(done)

    def details_inputs(self, workspace, record):
        return ({key: value for key, value in workspace.items() if key != "windows"}, dict(record), None, None)

    @staticmethod
    def _details_catalog():
        return None

    @staticmethod
    def background(work, done):
        done(work())


class ControlDispatchTests(unittest.TestCase):
    def setUp(self):
        self.server = object.__new__(control.ControlServer)
        self.server.window = Window()
        self.replies = []

    def test_save_answers_only_once_it_is_on_disk(self):
        self.server.dispatch_later({"command": "save"}, self.replies.append)
        self.assertEqual(self.replies, [])  # Antes respondía «saved» sin haber guardado nada.
        self.server.window.saves[0]()
        self.assertEqual(self.replies, [{"ok": True, "result": "saved"}])
        self.server.dispatch_later({"command": "persist"}, self.replies.append)
        self.server.window.saves[1](OSError("disco lleno"))
        self.assertEqual(self.replies[-1], {"ok": False, "error": "disco lleno"})
        self.server.window.locked = True
        self.server.dispatch_later({"command": "save"}, self.replies.append)
        self.assertFalse(self.replies[-1]["ok"])
        self.assertEqual(len(self.server.window.saves), 2)

    def test_details_is_the_shared_json_and_never_fails_because_of_the_probe(self):
        self.server.dispatch_later({"command": "details", "surface": "w"}, self.replies.append)
        reply = self.replies[-1]
        self.assertTrue(reply["ok"])
        details = reply["result"]
        self.assertEqual((details["terminal_id"], details["workspace"]["host_label"], details["reason"]),
                         ("w", "root@10.0.0.2:22", "host_inaccesible"))
        self.server.dispatch_later({"command": "details", "surface": "nope"}, self.replies.append)
        self.assertFalse(self.replies[-1]["ok"])

    def test_ping_announces_the_relaunch_cells_of_the_contract(self):
        cells = json.loads(contract("relaunch-v1", "proveedores.json").read_text(encoding="utf-8"))["capacidades"]["linux"]
        self.assertEqual(self.server.dispatch({"command": "ping"})["capabilities"], cells)


if __name__ == "__main__":
    unittest.main()
