"""Behavioral GTK sidebar tests on the VM's private Xvfb display."""

import copy
import sys
import unittest
from pathlib import Path
from types import SimpleNamespace

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

try:
    import gi
    gi.require_version("Gtk", "3.0")
    gi.require_version("Gdk", "3.0")
    from gi.repository import Gdk, Gtk
    from uniconnect.sidebar import WorkspaceSidebar
    GTK_AVAILABLE = Gtk.init_check()[0]
except (ImportError, ValueError):
    GTK_AVAILABLE = False


class ManualDelays:
    def __init__(self):
        self.next_id, self.callbacks = 0, {}

    def schedule(self, milliseconds, callback, *args):
        self.next_id += 1
        self.callbacks[self.next_id] = (milliseconds, callback, args)
        return self.next_id

    def cancel(self, source):
        self.callbacks.pop(source, None)

    def fire(self, source):
        milliseconds, callback, args = self.callbacks.pop(source)
        return callback(*args)


@unittest.skipUnless(GTK_AVAILABLE, "GTK display required")
class WorkspaceSidebarTests(unittest.TestCase):
    def setUp(self):
        self.window = Gtk.Window()
        self.window.set_default_size(780, 600)
        body = Gtk.Box()
        self.window.add(body)
        self.listing = Gtk.ListBox(width_request=255)
        body.pack_start(self.listing, False, False, 0)
        self.terminal = Gtk.Entry(text="unchanged terminal focus")
        body.pack_start(self.terminal, True, True, 0)
        self.clock, self.selections, self.actions = ManualDelays(), [], []
        self.sidebar = WorkspaceSidebar(self.window, lambda value: value,
                                       lambda *args: self.selections.append(args),
                                       lambda *args: self.actions.append(args),
                                       schedule=self.clock.schedule, cancel=self.clock.cancel)
        self.snapshots = [{"id": "space-a", "name": "Servidor A", "kind": "ssh", "color": "#aabbcc",
                           "selected": "window-a", "windows": (
                               {"id": "window-a", "name": "First terminal", "unread": False, "status": "Running", "reconnect": True},
                               {"id": "window-b", "name": "Second terminal", "unread": True, "status": "Guardada", "reconnect": True})},
                          {"id": "space-b", "name": "Local", "kind": "local", "color": "invalid color",
                           "selected": None, "windows": ()}]
        self.sidebar.update(self.listing, self.snapshots, False)
        self.window.show_all()
        self.terminal.grab_focus()
        self.drain()
        self.crossing = SimpleNamespace(detail=Gdk.NotifyType.NONLINEAR)

    def tearDown(self):
        self.sidebar.close()
        self.window.destroy()
        self.drain()

    def drain(self):
        while Gtk.events_pending():
            Gtk.main_iteration_do(False)

    def labels(self, widget):
        result = [widget.get_text()] if isinstance(widget, Gtk.Label) else []
        if isinstance(widget, Gtk.Container):
            for child in widget.get_children():
                result.extend(self.labels(child))
        return result

    def hover(self, identifier="space-a"):
        row = self.sidebar.rows[identifier]
        self.sidebar.row_enter(row, self.crossing, identifier)
        source = self.sidebar.show_source
        self.assertEqual(self.clock.callbacks[source][0], 260)
        self.assertFalse(self.sidebar.popover.get_visible())
        self.clock.fire(source)
        self.drain()

    def test_cards_have_counts_real_states_color_and_no_permanent_terminal_rows(self):
        labels = self.labels(self.listing)
        self.assertEqual(len(self.listing.get_children()), 2)
        self.assertIn("Servidor A", labels)
        self.assertIn("SSH · 2 · No leídas: 1", labels)
        self.assertIn("Running: 1 · Guardada: 1", labels)
        self.assertNotIn("First terminal", labels)
        self.assertNotIn("Second terminal", labels)
        stripe = self.sidebar.rows["space-a"].get_child().get_children()[0]
        self.assertEqual(stripe.get_size_request().width, 3)
        self.sidebar.update(self.listing, self.snapshots, True)
        self.assertIn("SE", self.labels(self.listing))
        self.assertNotIn("First terminal", self.labels(self.listing))

    def test_hover_opens_one_panel_without_focus_or_selection_then_exact_click(self):
        focus, selected = self.window.get_focus(), self.listing.get_selected_row()
        self.hover()
        self.assertTrue(self.sidebar.popover.get_visible())
        self.assertIs(self.window.get_focus(), focus)
        self.assertIs(self.listing.get_selected_row(), selected)
        self.assertEqual(self.selections, [])
        self.assertIn("✓ First terminal", self.labels(self.sidebar.popover))
        self.sidebar.window_buttons["window-b"].clicked()
        self.assertEqual(self.selections, [("space-a", "window-b")])
        self.assertFalse(self.sidebar.popover.get_visible())

    def test_crossing_into_panel_cancels_close_and_leaving_waits_140_ms(self):
        self.hover()
        self.sidebar.row_leave(self.sidebar.rows["space-a"], self.crossing, "space-a")
        source = self.sidebar.hide_source
        self.assertEqual(self.clock.callbacks[source][0], 140)
        self.sidebar.panel_enter(self.sidebar.popover, self.crossing)
        self.assertNotIn(source, self.clock.callbacks)
        self.assertTrue(self.sidebar.popover.get_visible())
        self.sidebar.panel_leave(self.sidebar.popover, self.crossing)
        self.clock.fire(self.sidebar.hide_source)
        self.assertFalse(self.sidebar.popover.get_visible())

    def test_switch_hover_reuses_panel_and_updates_status_without_destroying_source(self):
        self.hover()
        popover, row = self.sidebar.popover, self.sidebar.rows["space-a"]
        changed = copy.deepcopy(self.snapshots)
        changed[0]["windows"][1]["unread"] = False
        self.sidebar.update(self.listing, changed, False)
        self.assertIs(self.sidebar.rows["space-a"], row)
        self.assertTrue(popover.get_visible())
        self.assertNotIn("Second terminal  ●", self.labels(popover))
        self.sidebar.row_enter(self.sidebar.rows["space-b"], self.crossing, "space-b")
        self.assertIs(self.sidebar.popover, popover)
        self.assertEqual(self.sidebar.visible_id, "space-b")
        self.assertIn("Sin ventanas", self.labels(popover))
        self.assertEqual(self.selections, [])

    def test_keyboard_escape_and_removed_source_close_without_selection(self):
        row = self.sidebar.rows["space-a"]
        self.sidebar.row_key(row, SimpleNamespace(keyval=Gdk.KEY_Right), "space-a")
        self.assertTrue(self.sidebar.persistent)
        self.assertTrue(self.sidebar.key_press(row, SimpleNamespace(keyval=Gdk.KEY_Escape)))
        self.assertFalse(self.sidebar.popover.get_visible())
        self.assertIs(self.window.get_focus(), row)
        self.hover()
        self.sidebar.update(self.listing, self.snapshots[1:], False)
        self.assertFalse(self.sidebar.popover.get_visible())
        self.assertFalse(self.clock.callbacks)
        self.assertEqual(self.selections, [])

    def test_corridor_keeps_panel_open_until_pointer_moves_away(self):
        self.hover()
        a = self.sidebar.bounds(self.sidebar.rows["space-a"])
        b = self.sidebar.bounds(self.sidebar.popover)
        left, right = sorted((a, b), key=lambda value: value[0])
        x1, x2 = left[0] + left[2] - 8, right[0] + 8
        x = (x1 + max(x1, x2)) / 2
        y = (max(a[1], b[1]) + min(a[1] + a[3], b[1] + b[3])) / 2
        self.sidebar.row_leave(self.sidebar.rows["space-a"], self.crossing, "space-a")
        source = self.sidebar.hide_source
        self.sidebar.pointer_motion(self.window, SimpleNamespace(x_root=x, y_root=y))
        self.assertTrue(self.sidebar.inside_corridor)
        self.assertNotIn(source, self.clock.callbacks)
        self.sidebar.pointer_motion(self.window, SimpleNamespace(x_root=-100, y_root=-100))
        self.assertFalse(self.sidebar.inside_corridor)
        self.clock.fire(self.sidebar.hide_source)
        self.assertFalse(self.sidebar.popover.get_visible())

    def test_capture_escape_dismisses_before_focused_terminal_can_consume_it(self):
        self.hover()
        self.assertTrue(self.sidebar.key_controller.emit("key-pressed", Gdk.KEY_Escape, 9, Gdk.ModifierType(0)))
        self.assertFalse(self.sidebar.popover.get_visible())
        self.assertIs(self.window.get_focus(), self.terminal)

    def test_many_windows_scroll_within_screen_and_reconnect_is_explicit(self):
        changed = copy.deepcopy(self.snapshots)
        changed[0]["windows"] = tuple({"id": f"window-{index}", "name": f"Window {index}",
                                        "status": "Guardada", "unread": False, "reconnect": True}
                                       for index in range(100))
        self.sidebar.update(self.listing, changed, False)
        self.hover()
        self.assertLessEqual(self.sidebar.popover.get_allocated_height(), self.window.get_allocated_height())
        self.assertEqual(len(self.sidebar.window_buttons), 100)
        self.assertEqual(self.actions, [])
        button = self.sidebar.window_buttons["window-99"]
        button.get_parent().get_children()[1].clicked()
        self.assertEqual(self.actions, [("space-a", "window-99", None, "reconnect")])
        self.assertFalse(self.sidebar.popover.get_visible())

    def test_real_gtk_outside_click_dismisses_and_pending_hover_cancels(self):
        self.hover()
        event = Gdk.Event.new(Gdk.EventType.BUTTON_PRESS)
        event.window = self.terminal.get_window()
        event.button = 1
        self.sidebar.outside_click(self.window, event)
        self.assertFalse(self.sidebar.popover.get_visible())
        row = self.sidebar.rows["space-a"]
        self.sidebar.row_enter(row, self.crossing, "space-a")
        source = self.sidebar.show_source
        self.sidebar.row_leave(row, self.crossing, "space-a")
        self.assertNotIn(source, self.clock.callbacks)
        self.assertFalse(self.sidebar.popover.get_visible())


if __name__ == "__main__":
    unittest.main()
