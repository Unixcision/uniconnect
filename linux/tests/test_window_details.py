"""Detalles de ventana (window_details.v1): JSON del contrato, filas del modal y los tres menús."""

import calendar
import json
from pathlib import Path
import sys
import tempfile
import time
from types import SimpleNamespace
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
sys.path.insert(0, str(Path(__file__).resolve().parent))

from uniconnect.resume_catalog import AgentResumeCatalog
from uniconnect.transport import SSHCommand
from uniconnect.window_details import LIVE_REASONS, WindowDetails

CONTRACT = Path(__file__).resolve().parents[2] / "contracts" / "window-details-v1"
CLAUDE_ID = "473ed1de-4397-45ef-b00b-6b17fd7382b0"
LOCAL_ID = "714b0eae-b568-4e0c-a70b-c87c0d0a801a"
CATALOG_FIXTURE = {"schemaVersion": 1, "providers": {
    "claude": {"executable": "claude", "resume": ["{executable}", "--resume", "{sessionId}", "{arguments}"],
               "noPrompt": {"suffix": ["--dangerously-skip-permissions"], "rootEnvironment": {"IS_SANDBOX": "1"}}},
    "codex": {"executable": "codex", "resume": ["{executable}", "resume", "{sessionId}", "{arguments}"],
              "noPrompt": {"prefix": ["--yolo"], "legacy": ["--dangerously-bypass-approvals-and-sandbox"]}},
    "grok": {"executable": "grok", "resume": ["{executable}", "-r", "{sessionId}", "{arguments}"]}}}


def epoch(value):
    return calendar.timegm(time.strptime(value, "%Y-%m-%dT%H:%M:%SZ"))


def fixture_catalog():
    directory = tempfile.TemporaryDirectory(prefix="uc-details-catalog-")
    path = Path(directory.name) / "catalog.json"
    path.write_text(json.dumps(CATALOG_FIXTURE))
    try:
        return AgentResumeCatalog(path)
    finally:
        directory.cleanup()


SSH_EXPECTED = {
    "version": 1, "workspace_id": "5d6f2c1e-8a4b-4f0e-9c3d-2b1a0e9f8c7d",
    "terminal_id": "9a8b7c6d-5e4f-4a3b-8c2d-1e0f9a8b7c6d", "checked_at": "2026-09-24T14:30:05Z",
    "workspace": {"name": "XUNISSCRAPPER", "kind": "ssh", "host": {"user": "root", "hostname": "167.233.192.135", "port": 22},
                  "host_label": "root@167.233.192.135:22"},
    "window": {"name": "claudebets"},
    "tmux": {"socket": "default", "session": "claudebets", "session_id": "$0", "pane_id": "%0", "live": True},
    "agent": {"provider": "claude", "display_name": "Claude Code", "session_id": CLAUDE_ID, "cwd": "/root/xunis",
              "as_root": True, "source": "ficha", "state": "activo", "observed_at": "2026-09-24T14:30:04Z",
              "resume": {"argv": ["claude", "--resume", CLAUDE_ID, "--dangerously-skip-permissions"],
                         "environment": {"IS_SANDBOX": "1"},
                         "command": "cd -- '/root/xunis' && IS_SANDBOX=1 claude --resume " + CLAUDE_ID + " --dangerously-skip-permissions",
                         "no_prompt_verified": True}},
    "reason": None}
LOCAL_EXPECTED = {
    "version": 1, "workspace_id": "3c2b1a09-8f7e-4d6c-9b5a-4f3e2d1c0b9a", "terminal_id": "e86e9114-031c-4752-941d-1079c170a639",
    "checked_at": "2026-09-24T14:30:05Z",
    "workspace": {"name": "PROYECTOS", "kind": "local", "host": None, "host_label": None},
    "window": {"name": "MULTIGRAM-CLAUDE"},
    "tmux": {"socket": "uniconnect-local", "session": "uc-e86e9114031c4752941d1079c170a639", "session_id": "$12",
             "pane_id": "%14", "live": True},
    "agent": {"provider": "claude", "display_name": "Claude Code", "session_id": LOCAL_ID,
              "cwd": "/Users/danielgomezmartin/Desktop/PROYECTOS/MULTIGRAM", "as_root": False, "source": "ficha",
              "state": "activo", "observed_at": "2026-09-24T14:30:04Z",
              "resume": {"argv": ["claude", "--resume", LOCAL_ID, "--dangerously-skip-permissions"], "environment": {},
                         "command": "cd -- '/Users/danielgomezmartin/Desktop/PROYECTOS/MULTIGRAM' && claude --resume "
                                    + LOCAL_ID + " --dangerously-skip-permissions",
                         "no_prompt_verified": True}},
    "reason": None}
NO_AGENT_EXPECTED = dict(SSH_EXPECTED, window={"name": "hgabot"},
                         tmux={"socket": "default", "session": "hgabot", "session_id": "$3", "pane_id": "%3", "live": True},
                         agent=None, reason="sin_ia")


def inputs_from(expected):
    """Ventana guardada, lectura viva y conexión que deben producir exactamente ``expected``."""
    box = expected["workspace"]
    workspace = {"id": expected["workspace_id"], "name": box["name"], "kind": box["kind"]}
    connection = None
    if box["kind"] == "ssh":
        if box["host"]:
            host = box["host"]
            connection = SSHCommand.parse("ssh -p %s %s@%s" % (host["port"], host["user"], host["hostname"]))
        else:
            workspace["hostLabel"] = box["host_label"]
    record = {"id": expected["terminal_id"], "name": expected["window"]["name"], "agent": "shell", "cwd": "/"}
    tmux, agent = expected["tmux"], expected["agent"]
    if tmux:
        record.update(tmux=tmux["session"], tmuxSocket=tmux["socket"])
    live = None
    if tmux and tmux["live"]:
        entry = {"name": tmux["session"], "session_id": tmux["session_id"], "pane_id": tmux["pane_id"],
                 "reason": expected["reason"] if expected["reason"] in LIVE_REASONS else None, "agent": None}
        if agent and agent["state"] == "activo":
            entry["agent"] = {key: agent[key] for key in ("provider", "session_id", "cwd", "as_root", "source")}
        live = {"ok": True, "error": None, "checked_at": agent["observed_at"] if agent else expected["checked_at"],
                "session": entry}
    elif agent:
        record.update(agent=agent["provider"], sessionId=agent["session_id"], resumeCwd=agent["cwd"],
                      asRoot=agent["as_root"], interrupted=agent["state"] == "interrumpido")
        if agent["observed_at"]:
            record["agentObservedAt"] = epoch(agent["observed_at"])
    return workspace, record, live, connection, lambda: epoch(expected["checked_at"])


class SnapshotTests(unittest.TestCase):
    def check(self, expected, catalog):
        workspace, record, live, connection, clock = inputs_from(expected)
        self.assertEqual(WindowDetails.snapshot(workspace, record, live, catalog, clock, connection=connection), expected)

    def test_contract_examples_from_the_agreed_design(self):
        catalog = fixture_catalog()
        for name, expected in (("ssh", SSH_EXPECTED), ("local", LOCAL_EXPECTED), ("sin IA", NO_AGENT_EXPECTED)):
            with self.subTest(name=name):
                self.check(expected, catalog)

    def test_shared_contract_files(self):
        for name in ("details-response-ssh.json", "details-response-local.json", "details-response-no-agent.json"):
            path = CONTRACT / name
            with self.subTest(name=name):
                self.assertTrue(path.is_file(), "Falta %s (CONTRATO-1)." % path)
                self.check(json.loads(path.read_text(encoding="utf-8")), AgentResumeCatalog())

    def test_saved_values_when_the_probe_fails_or_nothing_is_saved(self):
        catalog = fixture_catalog()
        workspace = {"id": "box", "name": "XUNIS", "kind": "ssh", "hostLabel": "('root', '167.233.192.135', '22')"}
        record = {"id": "w", "name": "claudebets", "tmux": "claudebets", "tmuxSocket": "default", "agent": "claude",
                  "sessionId": CLAUDE_ID, "resumeCwd": "/root/xunis", "interrupted": True, "agentObservedAt": 1790260204}
        details = WindowDetails.snapshot(workspace, record, {"ok": False, "error": "connection_timeout"}, catalog, lambda: 1790260205)
        self.assertEqual(details["workspace"], {"name": "XUNIS", "kind": "ssh", "host": None,
                                                "host_label": "root@167.233.192.135:22"})
        self.assertEqual((details["agent"]["state"], details["agent"]["source"], details["agent"]["observed_at"],
                          details["agent"]["as_root"], details["reason"]),
                         ("interrumpido", "registro", "2026-09-24T14:30:04Z", False, None))
        self.assertEqual(details["tmux"]["live"], False)
        self.assertEqual(details["agent"]["resume"]["command"],
                         "cd -- '/root/xunis' && claude --resume " + CLAUDE_ID + " --dangerously-skip-permissions")
        shell = {"id": "s", "name": "hgabot", "tmux": "hgabot", "agent": "shell", "cwd": "/root"}
        failed = WindowDetails.snapshot(workspace, shell, {"ok": False}, catalog, lambda: 0)
        self.assertEqual((failed["agent"], failed["reason"]), (None, "host_inaccesible"))
        legacy = WindowDetails.snapshot({"id": "l", "name": "L", "kind": "local"}, {"id": "p", "name": "pty", "cwd": "/"},
                                        None, catalog, lambda: 0)
        self.assertEqual((legacy["tmux"], legacy["reason"]), (None, "sin_tmux"))

    def test_live_ambiguity_missing_id_and_unverified_policy(self):
        catalog = fixture_catalog()
        workspace = {"id": "box", "name": "PROYECTOS", "kind": "local"}
        record = {"id": "w", "name": "grok", "tmux": "uc-w", "agent": "shell", "cwd": "/w"}
        live = {"ok": True, "checked_at": "2026-09-24T14:30:04Z",
                "session": {"name": "uc-w", "session_id": "$1", "pane_id": "%1", "reason": "identidad_ambigua", "agent": None}}
        self.assertEqual(WindowDetails.snapshot(workspace, record, live, catalog, lambda: 0)["reason"], "identidad_ambigua")
        live["session"].update(reason="sin_id", agent={"provider": "codex", "session_id": None, "cwd": "/w",
                                                      "as_root": False, "source": None})
        details = WindowDetails.snapshot(workspace, record, live, catalog, lambda: 0)
        self.assertEqual((details["reason"], details["agent"]["resume"]), ("sin_id", None))
        live["session"].update(reason=None, agent={"provider": "grok", "session_id": "conv_1", "cwd": "/w",
                                                  "as_root": False, "source": "argv"})
        details = WindowDetails.snapshot(workspace, record, live, catalog, lambda: 0)
        self.assertEqual(details["agent"]["resume"], {"argv": ["grok", "-r", "conv_1"], "environment": {},
                                                      "command": "cd -- '/w' && grok -r conv_1", "no_prompt_verified": False})
        rows = dict((key, value) for key, _, value in WindowDetails.rows(details))
        self.assertEqual(rows["no_prompt"], "Sin modo sin preguntas verificado para esta IA")

    def test_old_tuple_host_label_is_formatted(self):
        self.assertEqual(WindowDetails.host_label("('ec2-user', 'host.example', '2222')"), "ec2-user@host.example:2222")
        self.assertEqual(WindowDetails.host_label("root@h:22"), "root@h:22")
        self.assertEqual(WindowDetails.host_label("(roto"), "(roto")
        self.assertIsNone(WindowDetails.host_label(None))

    def test_modal_rows_are_spanish_and_in_the_agreed_order(self):
        rows = WindowDetails.rows(SSH_EXPECTED)
        self.assertEqual([label for _, label, _ in rows],
                         ["Espacio de trabajo", "Tipo", "Ventana", "Socket tmux", "Sesión tmux", "ID tmux", "IA", "Estado",
                          "ID de conversación", "Carpeta", "Como root", "Origen del dato", "Orden para reanudarla"])
        values = dict((key, value) for key, _, value in rows)
        self.assertEqual((values["kind"], values["socket"], values["tmux_id"], values["agent"], values["state"],
                          values["as_root"], values["source"]),
                         ("VPS (root@167.233.192.135:22)", "Servidor tmux por defecto", "$0 · %0", "Claude Code",
                          "En marcha", "Sí", "Ficha de sesión de Claude"))
        local = dict((key, value) for key, _, value in WindowDetails.rows(LOCAL_EXPECTED))
        self.assertEqual((local["kind"], local["socket"]), ("Local", "uniconnect-local"))
        self.assertNotIn("as_root", local)
        empty = dict((key, value) for key, _, value in WindowDetails.rows(NO_AGENT_EXPECTED))
        self.assertEqual(empty["agent"], "Sin IA detectada")
        self.assertNotIn("command", empty)


try:
    from test_new_conversation import GTK_AVAILABLE
    if GTK_AVAILABLE:
        from test_new_conversation import ConversationDesktop
        from uniconnect.terminal import TerminalSurface
        from uniconnect.window import MainWindow
except Exception:
    GTK_AVAILABLE = False


@unittest.skipUnless(GTK_AVAILABLE, "GTK display required for the three context menus")
class DetailsMenuTests(unittest.TestCase):
    def test_terminal_tab_and_sidebar_menus_offer_details_and_run_the_shared_action(self):
        class DetailsDesktop(ConversationDesktop):
            sidebar_surface_context = MainWindow.sidebar_surface_context

            def select_sidebar_surface(self, workspace_id, surface_id):
                return True

            def show_window_details(self, surface):
                self.shown = surface

        desktop = DetailsDesktop()
        desktop.tab_context(None, SimpleNamespace(button=3), desktop.focused_surface)
        desktop.sidebar_surface_context("box", "original-window", SimpleNamespace(button=3), None)
        TerminalSurface.on_button(SimpleNamespace(on_focus=lambda: None, owner=desktop), None, SimpleNamespace(button=3))
        self.assertEqual(len(desktop.contexts), 3)
        for names in desktop.contexts:
            self.assertIn("window_details", names)
        self.assertTrue(desktop.action_enabled("window_details"))
        desktop.run_action("window_details")
        self.assertIs(desktop.shown, desktop.focused_surface)
        self.assertEqual(desktop.action_label("window_details"), "Detalles…")


if __name__ == "__main__":
    unittest.main()
