"""Shared menu/palette notification behavior; isolated model and GTK widgets in CI."""

import copy
from pathlib import Path
import sys
from types import SimpleNamespace
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

try:
    import gi
    gi.require_version("Gtk", "3.0")
    from gi.repository import Gio, Gtk
    from uniconnect.actions import ACTIONS
    from uniconnect.i18n import Translator
    from uniconnect.mobile_rpc import MobileRPC
    from uniconnect.window import MainWindow
    from uniconnect.window_commands import WindowCommands
    from uniconnect.window_notifications import WindowNotifications
    GTK_AVAILABLE = Gtk.init_check()[0]
except (ImportError, ValueError):
    GTK_AVAILABLE = False


if GTK_AVAILABLE:
    class NotificationDesktop(WindowCommands, WindowNotifications):
        run_action = MainWindow.run_action
        activate_action = MainWindow.activate_action
        command_menu_item = MainWindow.command_menu_item
        workspace_context = MainWindow.workspace_context
        tab_context = MainWindow.tab_context

        def __init__(self):
            self._ = Translator()
            self.action_map = {action.name: action for action in ACTIONS}
            self.locked, self.failed_save = False, False
            self.saved, self.errors, self.selected, self.contexts, self.withdrawn = [], [], [], [], []
            self.records = [{"id": name, "name": name, "paneId": "main", "unread": name != "c"}
                            for name in ("a", "b", "c")]
            workspaces = [{"id": "first", "name": "First", "kind": "local", "windows": self.records[:2], "selectedWindowId": "a"},
                          {"id": "second", "name": "Second", "kind": "ssh", "windows": self.records[2:], "selectedWindowId": "c"}]
            history = [{"id": "n" + str(index), "workspace_id": "second" if name == "c" else "first",
                        "surface_id": name, "is_read": name == "c", "created_at_ms": index, "title": name}
                       for index, name in enumerate(("a", "b", "c"), 1)]
            self.store = SimpleNamespace(workspaces=workspaces, closed=[], save=self.save,
                                          data={"workspaces": workspaces, "notificationHistory": history,
                                                "settings": {}, "selectedWorkspaceId": "first"})
            self.surfaces = {record["id"]: SimpleNamespace(record=record, workspace=workspace,
                terminal=SimpleNamespace(get_has_selection=lambda: False),
                search=SimpleNamespace(get_search_mode=lambda: False))
                for workspace in workspaces for record in workspace["windows"]}
            self.focused_surface = self.surfaces["a"]
            self.notebooks = {}
            self.menu_items = []
            self.gio_actions = {}
            for action in ACTIONS:
                item = Gio.SimpleAction.new(action.name, None)
                item.connect("activate", self.activate_action, action.name)
                self.gio_actions[action.name] = item

        def save(self):
            if self.failed_save:
                raise OSError("fixture failure")
            self.saved.append(copy.deepcopy(self.store.data))

        def current_workspace(self):
            return next(value for value in self.store.workspaces if value["id"] == self.store.data["selectedWorkspaceId"])

        def lookup_action(self, name):
            return self.gio_actions[name]

        def refresh_sidebar(self):
            pass

        def get_application(self):
            return SimpleNamespace(withdraw_notification=self.withdrawn.append)

        def error(self, issue):
            self.errors.append(issue)

        def select_workspace(self, identifier):
            self.store.data["selectedWorkspaceId"] = identifier
            self.focused_surface = self.surfaces[self.current_workspace()["selectedWindowId"]]
            self.mark_notifications_read(self.focused_surface.record["id"])
            self.selected.append((identifier, self.focused_surface.record["id"]))

        def select_surface(self, surface):
            self.focused_surface = surface
            self.store.data["selectedWorkspaceId"] = surface.workspace["id"]
            self.mark_notifications_read(surface.record["id"])

        def apply_pane_visibility(self, workspace):
            pass

        def context_menu(self, names, event):
            self.contexts.append(names)


@unittest.skipUnless(GTK_AVAILABLE, "GTK display required for notification menu behavior")
class NotificationActionsTests(unittest.TestCase):
    def setUp(self):
        self.desktop = NotificationDesktop()

    def test_menu_gio_shortcut_and_palette_dispatch_share_the_same_history(self):
        desktop = self.desktop
        history = desktop.notifications
        menu = desktop.command_menu_item("notifications_mark_all_read")
        menu.connect("activate", lambda *_: desktop.run_action("notifications_mark_all_read"))
        menu.activate()
        self.assertTrue(all(item["is_read"] for item in history))
        self.assertFalse(any(record["unread"] for record in desktop.records))
        self.assertFalse(desktop.action_enabled("notifications_mark_all_read"))
        desktop.lookup_action("notifications_toggle_workspace").activate(None)
        self.assertTrue(desktop.notifications_unread("first"))
        self.assertFalse(desktop.notifications_unread("second"))
        self.assertEqual(desktop.action_label("notifications_toggle_workspace"), "Marcar caja como leída")
        desktop.run_action("notifications_mark_all_read")  # The same path used by the command palette.
        rpc = MobileRPC(desktop, None, lambda callback: callback())
        self.assertTrue(all(item["is_read"] for item in rpc.notifications({})["notifications"]))
        self.assertIs(history, desktop.store.data["notificationHistory"])
        self.assertEqual(desktop.errors, [])
        self.assertEqual(desktop.store.data["selectedWorkspaceId"], "first")

    def test_individual_read_and_dismiss_keep_other_notifications_and_badges(self):
        desktop = self.desktop
        desktop.notifications.append({**desktop.notifications[0], "id": "another", "created_at_ms": 5})
        desktop.notification_action("n1", "toggle_read")
        self.assertTrue(desktop.records[0]["unread"])
        desktop.notification_action("another", "dismiss")
        self.assertFalse(desktop.records[0]["unread"])
        self.assertTrue(desktop.records[1]["unread"])
        self.assertEqual([item["id"] for item in desktop.notifications], ["n1", "n2", "n3"])
        self.assertIn("a", desktop.withdrawn)
        desktop.run_action("notifications_dismiss_all")
        self.assertEqual(desktop.notifications, [])
        self.assertFalse(desktop.action_enabled("notifications_dismiss_all"))
        self.assertFalse(desktop.notifications_unread())

    def test_latest_unread_opens_exact_live_target_and_ignores_closed_destinations(self):
        desktop = self.desktop
        desktop.notifications.append({**desktop.notifications[0], "id": "closed", "workspace_id": "deleted", "created_at_ms": 99})
        desktop.run_action("notifications_latest_unread")
        self.assertEqual(desktop.selected, [("first", "b")])
        self.assertTrue(desktop.records[0]["unread"])
        self.assertFalse(desktop.records[1]["unread"])
        before = list(desktop.selected)
        self.assertFalse(desktop.notification_action("closed", "open"))
        self.assertEqual(desktop.selected, before)
        desktop.run_action("notifications_mark_all_read")
        self.assertFalse(desktop.action_enabled("notifications_latest_unread"))

    def test_workspace_and_terminal_context_do_not_consume_unread_or_undo_manual_marks(self):
        desktop = self.desktop
        event = SimpleNamespace(button=3)
        desktop.tab_context(None, event, desktop.surfaces["b"])
        self.assertTrue(desktop.notifications_unread(surface_id="b"))
        self.assertIn("notifications_toggle_window", desktop.contexts[-1])
        desktop.run_action("notifications_toggle_window")
        self.assertFalse(desktop.notifications_unread(surface_id="b"))
        desktop.run_action("notifications_toggle_window")
        desktop.mark_notifications_read("b")  # Focus returns from its contextual menu.
        self.assertTrue(desktop.notifications_unread(surface_id="b"))
        desktop.mark_notifications_read("a")
        desktop.mark_notifications_read("b")
        self.assertFalse(desktop.notifications_unread(surface_id="b"))
        desktop.set_notifications_read(False, workspace_id="first")
        desktop.workspace_context(None, event, desktop.store.workspaces[0])
        self.assertTrue(desktop.notifications_unread("first"))
        self.assertIn("notifications_toggle_workspace", desktop.contexts[-1])

    def test_failed_persistence_rolls_back_history_and_badges_without_publishing_success(self):
        desktop = self.desktop
        before = copy.deepcopy(desktop.store.data)
        desktop.failed_save = True
        with self.assertRaises(RuntimeError):
            desktop.set_notifications_read(True)
        self.assertEqual(desktop.store.data, before)
        with self.assertRaises(RuntimeError):
            desktop.notification_action("n1", "dismiss")
        self.assertEqual(desktop.store.data, before)
        self.assertEqual(desktop.withdrawn, [])
        self.assertEqual(desktop.saved, [])

    def test_locked_actions_do_not_change_history(self):
        desktop = self.desktop
        before = copy.deepcopy(desktop.store.data)
        desktop.locked = True
        for name in ("notifications_latest_unread", "notifications_mark_all_read", "notifications_toggle_workspace",
                     "notifications_toggle_window", "notifications_dismiss_all"):
            self.assertFalse(desktop.action_enabled(name))
            desktop.run_action(name)
        self.assertFalse(desktop.notification_action("n1", "dismiss"))
        self.assertEqual(desktop.store.data, before)


if __name__ == "__main__":
    unittest.main()
