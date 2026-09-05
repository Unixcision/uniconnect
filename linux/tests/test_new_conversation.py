"""New conversations use the existing creation action without replacing a live pane."""

import copy
from pathlib import Path
import sys
from types import SimpleNamespace
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

try:
    import gi
    gi.require_version("Gtk", "3.0")
    from gi.repository import Gio, Gtk
    from uniconnect.actions import ACTIONS
    from uniconnect.i18n import Translator
    from uniconnect.transport import TmuxCommand
    from uniconnect.window import MainWindow
    from uniconnect.window_commands import WindowCommands
    GTK_AVAILABLE = Gtk.init_check()[0]
except (ImportError, ValueError):
    GTK_AVAILABLE = False


if GTK_AVAILABLE:
    class ConversationDesktop(WindowCommands):
        run_action = MainWindow.run_action
        activate_action = MainWindow.activate_action
        action_new_window = MainWindow.action_new_window
        commit_new_window = MainWindow.commit_new_window
        command_menu_item = MainWindow.command_menu_item
        tab_context = MainWindow.tab_context

        def __init__(self, kind="local"):
            self._ = Translator()
            self.action_map = {action.name: action for action in ACTIONS}
            self.locked = False
            self.response, self.cancel = {}, False
            self.saved, self.created, self.errors, self.contexts = [], [], [], []
            self.record = {"id": "original-window", "name": "Trabajo", "agent": "claude",
                           "sessionId": "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee", "cwd": "/project/current",
                           "tmux": "original-tmux", "tmuxSocket": "project-socket", "paneId": "right",
                           "history": [{"sessionId": "previous-conversation"}]}
            self.workspace = {"id": "box", "name": "Caja", "kind": kind, "credentialRef": "fixture-key",
                              "cwd": "/project", "windows": [self.record], "selectedWindowId": self.record["id"]}
            self.store = SimpleNamespace(workspaces=[self.workspace], closed=[],
                data={"settings": {}, "workspaces": [self.workspace]}, save=self.save)
            self.focused_surface = SimpleNamespace(record=self.record, workspace=self.workspace)
            self.action = Gio.SimpleAction.new("new_conversation_window", None)
            self.action.connect("activate", self.activate_action, "new_conversation_window")

        def current_workspace(self):
            return self.workspace

        def fields_dialog(self, title, fields, accept):
            self.dialog = (title, fields, accept)
            if self.cancel:
                return None
            return {**{key: value for key, _, value, _ in fields}, **self.response}

        def save(self):
            self.saved.append(copy.deepcopy(self.store.data))

        def build_workspace(self, workspace, *, create_ids):
            self.created.extend(create_ids)

        def refresh_sidebar(self):
            pass

        def select_workspace(self, identifier):
            assert identifier == self.workspace["id"]

        def select_surface(self, surface):
            self.focused_surface = surface

        def context_menu(self, names, event):
            self.contexts.append(names)

        def connection(self, workspace):
            assert workspace is self.workspace
            return "ssh fixture@example.invalid"

        def background(self, work, done):
            done(work())

        def error(self, error):
            self.errors.append(error)


@unittest.skipUnless(GTK_AVAILABLE, "GTK display required for conversation actions")
class NewConversationTests(unittest.TestCase):
    def test_menu_gio_palette_and_tab_context_preserve_current_conversation(self):
        desktop = ConversationDesktop()
        before = copy.deepcopy(desktop.record)
        menu = desktop.command_menu_item("new_conversation_window")
        menu.connect("activate", lambda *_: desktop.run_action("new_conversation_window"))
        menu.activate()
        desktop.action.activate(None)
        desktop.run_action("new_conversation_window")  # Command-palette dispatcher.
        desktop.tab_context(None, SimpleNamespace(button=3), desktop.focused_surface)
        self.assertIn("new_conversation_window", desktop.contexts[-1])
        self.assertEqual(desktop.record, before)
        self.assertEqual(desktop.errors, [])
        self.assertEqual(len(desktop.saved), 3)
        records = desktop.workspace["windows"][1:]
        self.assertEqual(len({record["tmux"] for record in records}), 3)
        self.assertEqual(desktop.created, [record["id"] for record in records])
        for record in records:
            self.assertEqual((record["cwd"], record["paneId"], record["agent"]), ("/project/current", "right", "claude"))
            self.assertEqual(record["tmuxSocket"], "uniconnect-local")
            self.assertNotIn("sessionId", record)
            self.assertNotIn("history", record)
            self.assertNotIn("--resume", TmuxCommand.agent_argv(record))
        self.assertNotIn("sessionId", [field[0] for field in desktop.dialog[1]])

    def test_ssh_inherits_connection_and_socket_but_refuses_existing_tmux(self):
        desktop = ConversationDesktop("ssh")
        before = copy.deepcopy(desktop.record)
        desktop.response = {"tmux": "new-conversation", "sessionId": before["sessionId"]}
        with patch("uniconnect.window.Transport") as transport:
            transport.return_value.ensure_session.return_value = {"created": True}
            desktop.run_action("new_conversation_window")
            self.assertEqual(transport.call_args.kwargs["socket_name"], "project-socket")
            self.assertEqual(transport.call_args.args[0].destination, "fixture@example.invalid")
            new = transport.return_value.ensure_session.call_args.args[0]
            self.assertEqual(new["tmux"], "new-conversation")
            self.assertNotIn("sessionId", new)
            desktop.response = {"tmux": "original-tmux"}
            desktop.run_action("new_conversation_window")
            self.assertEqual(transport.return_value.ensure_session.call_count, 1)
            desktop.response = {"tmux": "exists-outside-app"}
            transport.return_value.ensure_session.return_value = {"created": False}
            desktop.run_action("new_conversation_window")
        self.assertEqual(len(desktop.saved), 1)
        self.assertEqual(len(desktop.errors), 2)
        self.assertEqual(desktop.record, before)

    def test_custom_command_is_explicit_argv_and_never_copied_from_current_agent(self):
        desktop = ConversationDesktop()
        desktop.record.update(agent="custom", commandArgv=["claude", "--resume", "existing"])
        before = copy.deepcopy(desktop.record)
        desktop.run_action("new_conversation_window")
        self.assertEqual(len(desktop.errors), 1)
        self.assertEqual(desktop.saved, [])
        desktop.response = {"agent": "custom", "customCommand": 'my-agent --prompt "two words; $(literal)"'}
        desktop.run_action("new_conversation_window")
        record = desktop.workspace["windows"][-1]
        self.assertEqual(TmuxCommand.agent_argv(record), ["my-agent", "--prompt", "two words; $(literal)"])
        self.assertNotIn("customCommand", record)
        self.assertEqual(desktop.record, before)
        desktop.response = {"agent": "shell", "customCommand": "ignored"}
        desktop.run_action("new_conversation_window")
        self.assertNotIn("commandArgv", desktop.workspace["windows"][-1])

    def test_cancel_and_locked_actions_do_not_create_or_save(self):
        desktop = ConversationDesktop()
        before = copy.deepcopy(desktop.store.data)
        desktop.cancel = True
        desktop.run_action("new_conversation_window")
        desktop.cancel, desktop.locked = False, True
        desktop.run_action("new_conversation_window")
        self.assertEqual(desktop.store.data, before)
        self.assertEqual(desktop.created, [])
        self.assertEqual(desktop.saved, [])
        self.assertEqual(desktop.errors, [])


if __name__ == "__main__":
    unittest.main()
