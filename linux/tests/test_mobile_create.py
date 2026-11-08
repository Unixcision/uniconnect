"""Crear desde el móvil (y desde el escritorio, por el mismo guardado), probado de punta a punta el 08-11.

Lo que fallaba: SSH sin sesión tmux o con la carpeta local (un 72), adjuntar antes de que la sesión
existiera, IAs no ofrecidas en SSH y ofrecidas en local aunque no estuvieran instaladas, y la ventana
nueva sin su IA ni sus opciones en `agent-tree.json` hasta el siguiente ciclo.
"""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import types
import unittest
from unittest import mock

try:
    import gi
    gi.require_version("Gtk", "3.0")
    from gi.repository import Gtk
    GTK_AVAILABLE = Gtk.init_check()[0]
except (ImportError, ValueError):
    GTK_AVAILABLE = False

from uniconnect.agent_tree_document import build
from uniconnect.mobile_protocol import RPCError
from uniconnect.mobile_rpc import MobileRPC
from uniconnect.transport import Transport, TransportError

if GTK_AVAILABLE:
    from uniconnect.window import MainWindow


class Completed:
    def __init__(self, returncode=0, stdout="", stderr=""):
        self.returncode, self.stdout, self.stderr = returncode, stdout, stderr


class TreeOnCreationTests(unittest.TestCase):
    """Dani: la ventana nueva, al instante en el árbol con su IA pedida y sus opciones."""

    LAUNCH = {"options": ["--dangerously-skip-permissions"], "isSandbox": True, "source": "policy", "capturedAt": 1}

    def window(self, **record):
        data = {"workspaces": [{"id": "b", "name": "B", "kind": "local", "windows": [
            dict({"id": "w", "name": "W", "tmux": "uc-w", "agent": "claude", "launchOptions": self.LAUNCH}, **record)]}]}
        return build(data, machine_id="MINIPC", now=1)["workspaces"][0]["windows"][0]

    def test_a_new_ai_window_is_saved_as_pending_with_its_launch_options(self):
        window = self.window()
        self.assertEqual(window["state"], "agent")
        self.assertEqual(window["agent"]["provider"], "claude")
        self.assertIsNone(window["agent"]["session_id"])
        self.assertIsNone(window["agent"]["source"])
        self.assertEqual(window["agent"]["state"], "pendiente")
        self.assertEqual(window["agent"]["launch"]["arguments"], ["--dangerously-skip-permissions"])
        self.assertEqual(window["agent"]["launch"]["environment"], {"IS_SANDBOX": "1"})
        self.assertEqual(window["tmux"]["session"], "uc-w")

    def test_once_identified_it_is_a_saved_conversation(self):
        window = self.window(sessionId="c1")
        self.assertEqual((window["agent"]["session_id"], window["agent"]["state"]), ("c1", "guardado"))

    def test_a_window_whose_ai_already_closed_is_not_faked_as_pending(self):
        self.assertIsNone(self.window(runtimeState="shell")["agent"])
        self.assertIsNone(self.window(history=[{"agent": "claude", "sessionId": "c0"}])["agent"])
        self.assertIsNone(self.window(agent="shell")["agent"])


@unittest.skipUnless(GTK_AVAILABLE, "GTK required")
class CreateWindowTests(unittest.TestCase):
    """create_mobile_window + commit_new_window: lo que queda guardado antes de arrancar nada."""

    def setUp(self):
        self.folder = tempfile.TemporaryDirectory(prefix="uc-create-")
        self.saved = []
        store = types.SimpleNamespace(_active_transaction=None, journal_path=Path(self.folder.name) / "nada")
        desktop = types.SimpleNamespace(store=store, _=lambda text: text, _runtime_operation=None)
        store.save = lambda: self.saved.append([dict(item) for box in self.boxes for item in box["windows"]])
        desktop.build_workspace = lambda *args, **kwargs: None
        desktop.refresh_sidebar = lambda: None
        desktop.select_workspace = lambda *args: None
        desktop.commit_new_window = lambda *args, **kwargs: MainWindow.commit_new_window(desktop, *args, **kwargs)
        self.desktop = desktop
        self.local = {"id": "l", "kind": "local", "cwd": self.folder.name, "windows": []}
        self.ssh = {"id": "s", "kind": "ssh", "windows": []}
        self.boxes = [self.local, self.ssh]

    def tearDown(self):
        self.folder.cleanup()

    def create(self, box, **params):
        return MainWindow.create_mobile_window(self.desktop, box, dict({"name": "Nueva"}, **params))

    def test_a_local_ai_is_saved_at_once_with_the_policy_options(self):
        record = self.create(self.local, agent="claude")
        self.assertEqual(self.saved[-1][0]["id"], record["id"])  # Ya en disco al volver.
        self.assertEqual(self.saved[-1][0]["launchOptions"]["source"], "policy")
        self.assertIn("--dangerously-skip-permissions", record["launchOptions"]["options"])
        self.assertEqual(record["launchOptions"]["isSandbox"], os.geteuid() == 0)
        self.assertEqual(record["tmuxSocket"], "uniconnect-local")

    def test_a_terminal_or_a_resumed_conversation_gets_no_invented_options(self):
        self.assertNotIn("launchOptions", self.create(self.local))
        record = {"id": "x", "agent": "codex", "sessionId": "c1", "cwd": "/tmp", "tmux": "uc-x"}
        MainWindow.creation_launch_options(self.local, record)
        self.assertNotIn("launchOptions", record)

    def test_ssh_without_a_session_name_gets_a_new_one_and_never_the_local_home(self):
        with self.assertRaises(RPCError) as caught:
            self.create(self.ssh)
        self.assertEqual(caught.exception.code, "invalid_params")  # Nunca el $HOME del MINIPC.
        record = self.create(self.ssh, agent="claude", directory="/home/ec2-user")
        self.assertRegex(record["tmux"], r"^uc-[0-9a-f]{12}$")
        self.assertEqual((record["cwd"], record["agent"], record["tmuxSocket"]), ("/home/ec2-user", "claude", "uniconnect"))
        self.assertNotIn("launchOptions", record)  # En SSH las da la sonda en el destino.


class AgentNotInstalledTests(unittest.TestCase):
    def test_a_missing_ai_is_its_own_error_and_nothing_touches_tmux(self):
        scripts = []

        class Recording(Transport):
            def run(self, script, *, timeout=25, check=True):
                scripts.append(script)
                return Completed(75)

        with tempfile.TemporaryDirectory(prefix="uc-noai-") as folder:
            with self.assertRaises(TransportError) as caught:
                Recording(socket_name="uc-test-noai").ensure_session(
                    {"id": "w", "tmux": "uc-w", "agent": "grok", "cwd": folder})
            self.assertEqual(caught.exception.code, "agent_not_installed")
            self.assertEqual(caught.exception.detail, "grok")
            bin_dir = Path(folder) / "bin"
            bin_dir.mkdir()
            marker = Path(folder) / "tmux-tocado"
            fake_tmux = bin_dir / "tmux"
            fake_tmux.write_text("#!/bin/sh\ntouch %s\n" % marker)
            fake_tmux.chmod(0o755)
            # El mismo guion, de verdad, con un PATH sin la IA: sale con 75 antes de tocar tmux.
            done = subprocess.run(["/bin/bash", "-c", scripts[0]], text=True, capture_output=True,
                                  env={"PATH": str(bin_dir), "HOME": folder}, cwd=folder)
            touched = marker.exists()
        self.assertEqual(done.returncode, 75, done.stderr)
        self.assertFalse(touched)


@unittest.skipUnless(GTK_AVAILABLE, "GTK required")
class MobileCreateRPCTests(unittest.TestCase):
    def setUp(self):
        self.boxes = [{"id": "l", "name": "LOCAL", "kind": "local", "cwd": "/", "windows": [
                          {"id": "w", "name": "W", "agent": "claude", "tmux": "uc-w", "tmuxSocket": "uniconnect-local"}]},
                      {"id": "s", "name": "VPS", "kind": "ssh", "cwd": "/home/x", "windows": []}]
        self.surfaces = {}
        self.window = types.SimpleNamespace(store=types.SimpleNamespace(workspaces=self.boxes, data={}),
                                            locked=False, surfaces=self.surfaces, focused_surface=None,
                                            connection=lambda box: "ssh x@example.com")
        self.now = [0.0]
        self.answers = []
        self.rpc = MobileRPC(self.window, types.SimpleNamespace(machine_id="fixture"), lambda callback: callback(),
                             transport_factory=lambda *args, **kwargs: types.SimpleNamespace(
                                 run=lambda *a, **k: self.answers.pop(0)),
                             clock=lambda: self.now[0], wait=lambda seconds: self.now.__setitem__(0, self.now[0] + seconds))

    def test_local_boxes_offer_only_installed_ais_and_ssh_offers_all(self):
        installed = {"claude": "/usr/bin/claude", "codex": "/usr/bin/codex"}
        with mock.patch.object(shutil, "which", side_effect=lambda name, *args, **kwargs: installed.get(name)):
            listing = self.rpc.workspace_list({})
        targets = {box["id"]: [item["id"] for item in box["available_agent_targets"]] for box in listing["workspaces"]}
        self.assertEqual(targets["l"], ["terminal", "claude", "codex"])
        self.assertEqual(targets["s"], ["terminal", "claude", "codex", "agy", "grok"])

    def test_the_reply_waits_for_the_session_and_gives_the_exact_cause(self):
        self.answers = [Completed(1), Completed(0)]
        self.rpc.wait_for_session("l", "w")  # A la segunda la sesión existe: entonces responde.
        self.assertEqual(self.answers, [])
        self.surfaces["w"] = types.SimpleNamespace(status="Disconnected", status_label=types.SimpleNamespace(
            get_text=lambda: "Desconectado · agent_not_installed: agy"))
        with self.assertRaises(RPCError) as caught:
            self.rpc.wait_for_session("l", "w")
        self.assertEqual(caught.exception.code, "create_failed")
        self.assertIn("no está instalada en esa máquina (agy)", str(caught.exception))
        self.surfaces.clear()
        self.answers = [Completed(1)] * 200
        with self.assertRaises(RPCError) as caught:
            self.rpc.wait_for_session("l", "w")
        self.assertEqual(caught.exception.code, "create_failed")  # Acotado: no cuelga al móvil.
        with self.assertRaises(RPCError) as caught:
            self.rpc.wait_for_session("l", "nope")
        self.assertEqual(caught.exception.code, "not_found")

    def test_remote_home_is_the_servers_never_the_local_one(self):
        self.answers = [Completed(0, "/home/ec2-user\n")]
        self.assertEqual(self.rpc.remote_home("ssh x@example.com"), "/home/ec2-user")
        for answer in (Completed(255, ""), Completed(0, "relativa"), Completed(0, "")):
            self.answers = [answer]
            with self.subTest(answer=answer.stdout), self.assertRaises(RPCError) as caught:
                self.rpc.remote_home("ssh x@example.com")
            self.assertEqual(caught.exception.code, "create_failed")


if __name__ == "__main__":
    unittest.main()
