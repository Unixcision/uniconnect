"""Compact workspace cards and one non-modal, identity-bound GTK flyout."""

from collections import Counter

import gi

gi.require_version("Gtk", "3.0")
gi.require_version("Gdk", "3.0")
from gi.repository import Gdk, GLib, Gtk, Pango


class WorkspaceSidebar:
    """Present value snapshots; only explicit click/keyboard actions select a pane."""

    def __init__(self, window, translate, select, context, *, schedule=None, cancel=None):
        self.window, self._ = window, translate
        self.select, self.context = select, context
        self.schedule = schedule or GLib.timeout_add
        self.cancel = cancel or GLib.source_remove
        self.rows, self.snapshots = {}, {}
        self.visible_id = self.hovered_id = None
        self.show_source = self.hide_source = 0
        self.inside_panel = self.inside_corridor = self.persistent = False
        self.popover = Gtk.Popover(position=Gtk.PositionType.RIGHT)
        # A hover must not grab focus, keyboard or the desktop's selected surface.
        self.popover.set_modal(False)
        self.popover.set_can_focus(False)
        self.popover.get_style_context().add_class("uc-sidebar-flyout")
        self.popover.add_events(Gdk.EventMask.ENTER_NOTIFY_MASK | Gdk.EventMask.LEAVE_NOTIFY_MASK)
        self.popover.connect("enter-notify-event", self.panel_enter)
        self.popover.connect("leave-notify-event", self.panel_leave)
        self.popover.connect("key-press-event", self.key_press)
        self.click_controller = Gtk.GestureMultiPress.new(window)
        self.click_controller.set_button(0)
        self.click_controller.set_propagation_phase(Gtk.PropagationPhase.CAPTURE)
        self.click_controller.connect("pressed", self.captured_click)
        self.key_controller = Gtk.EventControllerKey.new(window)
        self.key_controller.set_propagation_phase(Gtk.PropagationPhase.CAPTURE)
        self.key_controller.connect("key-pressed", self.captured_key)
        window.add_events(Gdk.EventMask.POINTER_MOTION_MASK)
        self.handlers = [window.connect("key-press-event", self.key_press),
                         window.connect("button-press-event", self.outside_click),
                         window.connect("motion-notify-event", self.pointer_motion),
                         window.connect("focus-out-event", self.window_unfocused)]

    def update(self, listing, snapshots, compact):
        """Reconcile existing rows so status/unread updates do not reset hover."""
        wanted = [value["id"] for value in snapshots]
        if wanted != [row.workspace_id for row in listing.get_children()]:
            self.hide()
            for row in listing.get_children():
                listing.remove(row)
            self.rows = {}
        previous = self.snapshots
        self.snapshots = {value["id"]: value for value in snapshots}
        for value in snapshots:
            identifier = value["id"]
            row = self.rows.get(identifier)
            if row is None:
                row = Gtk.ListBoxRow()
                row.workspace_id = identifier
                row.get_style_context().add_class("uc-workspace")
                row.add_events(Gdk.EventMask.ENTER_NOTIFY_MASK | Gdk.EventMask.LEAVE_NOTIFY_MASK)
                row.connect("enter-notify-event", self.row_enter, identifier)
                row.connect("leave-notify-event", self.row_leave, identifier)
                row.connect("key-press-event", self.row_key, identifier)
                listing.add(row)
                self.rows[identifier] = row
            signature = (value, compact)
            if getattr(row, "card_snapshot", None) != signature:
                child = row.get_child()
                if child:
                    row.remove(child)
                row.add(self.card(value, compact))
                row.card_snapshot = signature
                row.set_tooltip_text(value["name"] + " · " + self._("Mostrar ventanas"))
            row.show_all()
        if self.visible_id and previous.get(self.visible_id) != self.snapshots.get(self.visible_id):
            self.render_panel(self.snapshots[self.visible_id])

    def metadata(self, snapshot):
        text = f'{snapshot["kind"].upper()} · {len(snapshot["windows"])}'
        unread = sum(value["unread"] for value in snapshot["windows"])
        if unread:
            text += f' · {self._("No leídas")}: {unread}'
        return text

    def status(self, snapshot):
        counts = Counter(value["status"] for value in snapshot["windows"] if value["status"])
        return " · ".join(f"{self._(name)}: {count}" for name, count in counts.items())

    def indicator(self, state):
        """Gtk.Spinner mientras trabaja, icono ámbar mientras espera; nada para idle/unknown."""
        if state == "working":
            spinner = Gtk.Spinner()
            spinner.set_size_request(14, 14)
            spinner.set_tooltip_text(self._("Trabajando"))
            spinner.start()
            return spinner
        if state == "waiting":
            icon = Gtk.Image.new_from_icon_name("dialog-question-symbolic", Gtk.IconSize.MENU)
            icon.get_style_context().add_class("uc-activity-waiting")
            icon.set_tooltip_text(self._("Esperando tu respuesta"))
            return icon
        return None

    def card(self, snapshot, compact):
        box = Gtk.Box(spacing=9, margin=8)
        color = Gdk.RGBA()
        if not color.parse(snapshot["color"]):
            color.parse("#66b9ff")
        stripe = Gtk.Box(width_request=3)
        provider = Gtk.CssProvider()
        provider.load_from_data(f"* {{ background-color: {color.to_string()}; border-radius: 2px; }}".encode())
        stripe.get_style_context().add_provider(provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)
        box.pack_start(stripe, False, False, 0)
        body = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
        title = Gtk.Label(xalign=0, ellipsize=Pango.EllipsizeMode.END)
        name = snapshot["name"][:2].upper() if compact else snapshot["name"]
        if snapshot.get("pinned"):
            name = "★ " + name
        title.set_markup(f"<b>{GLib.markup_escape_text(name)}</b>")
        title.get_style_context().add_class("uc-workspace-title")
        heading = Gtk.Box(spacing=4)
        heading.pack_start(title, True, True, 0)
        indicator = self.indicator(snapshot.get("activity"))
        if indicator is not None:
            heading.pack_start(indicator, False, False, 0)
        body.pack_start(heading, False, False, 0)
        if compact:
            count = len(snapshot["windows"])
            unread = sum(value["unread"] for value in snapshot["windows"])
            detail = str(count) + (f" · ●{unread}" if unread else "")
        else:
            detail = self.metadata(snapshot)
        badge = Gtk.Label(label=detail, xalign=0, ellipsize=Pango.EllipsizeMode.END)
        badge.get_style_context().add_class("dim-label")
        body.pack_start(badge, False, False, 0)
        if not compact and self.status(snapshot):
            status = Gtk.Label(label=self.status(snapshot), xalign=0, ellipsize=Pango.EllipsizeMode.END)
            status.get_style_context().add_class("dim-label")
            body.pack_start(status, False, False, 0)
        box.pack_start(body, True, True, 0)
        return box

    def row_enter(self, row, event, identifier):
        if event.detail == Gdk.NotifyType.INFERIOR:
            return False
        self.hovered_id = identifier
        self.stop_timer("hide_source")
        self.stop_timer("show_source")
        if self.persistent:
            return False
        if self.visible_id:
            self.show(identifier)
        else:
            # The intentional hover delay is injected for deterministic testing.
            self.show_source = self.schedule(260, self.show_elapsed, identifier)
        return False

    def row_leave(self, row, event, identifier):
        if event.detail == Gdk.NotifyType.INFERIOR:
            return False
        if self.hovered_id == identifier:
            self.hovered_id = None
        self.stop_timer("show_source")
        self.schedule_hide()
        return False

    def show_elapsed(self, identifier):
        self.show_source = 0
        if self.hovered_id == identifier:
            self.show(identifier)
        return False

    def show(self, identifier, keyboard=False):
        if identifier not in self.rows:
            return
        self.stop_timer("hide_source")
        self.visible_id = identifier
        self.popover.set_relative_to(self.rows[identifier])
        self.render_panel(self.snapshots[identifier])
        self.popover.show_all()
        if keyboard:
            self.persistent = True
            self.popover.child_focus(Gtk.DirectionType.TAB_FORWARD)

    def render_panel(self, snapshot):
        context = self.popover.get_style_context()
        if self.window.get_style_context().has_class("uc-dark"):
            context.add_class("uc-dark")
        else:
            context.remove_class("uc-dark")
        child = self.popover.get_child()
        if child:
            self.popover.remove(child)
        content = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8, margin=12)
        heading = Gtk.Label(xalign=0, ellipsize=Pango.EllipsizeMode.END)
        heading.set_markup(f'<b>{GLib.markup_escape_text(snapshot["name"])}</b>')
        content.pack_start(heading, False, False, 0)
        content.pack_start(Gtk.Label(label=self.metadata(snapshot), xalign=0), False, False, 0)
        listing = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=3)
        self.window_buttons = {}
        for value in snapshot["windows"]:
            row = Gtk.Box(spacing=3)
            button = Gtk.Button()
            button.set_relief(Gtk.ReliefStyle.NONE)
            selected = value["id"] == snapshot["selected"]
            text = ("✓ " if selected else "") + ("★ " if value.get("pinned") else "") + value["name"] + ("  ●" if value["unread"] else "")
            label = Gtk.Label(label=text, xalign=0, ellipsize=Pango.EllipsizeMode.END)
            inner = Gtk.Box(spacing=4)
            inner.pack_start(label, True, True, 0)
            indicator = self.indicator(value.get("activity"))
            if indicator is not None:
                inner.pack_start(indicator, False, False, 0)
            button.add(inner)
            button.set_tooltip_text(value["name"] + (" · " + self._(value["status"]) if value["status"] else ""))
            button.connect("clicked", self.select_clicked, snapshot["id"], value["id"])
            button.connect("button-press-event", self.window_context, snapshot["id"], value["id"])
            row.pack_start(button, True, True, 0)
            self.window_buttons[value["id"]] = button
            if value["reconnect"]:
                reconnect = Gtk.Button.new_from_icon_name("view-refresh-symbolic", Gtk.IconSize.MENU)
                reconnect.set_tooltip_text(self._("Reconnect"))
                reconnect.connect("clicked", self.reconnect_clicked, snapshot["id"], value["id"])
                row.pack_start(reconnect, False, False, 0)
            listing.pack_start(row, False, False, 0)
        if not snapshot["windows"]:
            listing.pack_start(Gtk.Label(label=self._("Sin ventanas"), xalign=0), False, False, 0)
        monitor = self.window.get_display().get_monitor_at_window(self.window.get_window())
        area = monitor.get_workarea() if monitor else self.window.get_allocation()
        content.set_size_request(min(340, max(100, min(area.width, self.window.get_allocated_width()) - 48)), -1)
        scroll = Gtk.ScrolledWindow()
        scroll.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        scroll.set_min_content_width(min(310, max(100, area.width - 48)))
        scroll.set_max_content_height(max(70, min(420, area.height - 130, self.window.get_allocated_height() - 130)))
        scroll.set_propagate_natural_height(True)
        scroll.add(listing)
        content.pack_start(scroll, True, True, 0)
        self.popover.add(content)
        content.show_all()

    def select_clicked(self, button, workspace_id, surface_id):
        self.hide()
        self.select(workspace_id, surface_id)

    def window_context(self, button, event, workspace_id, surface_id):
        if event.button != 3:
            return False
        self.hide()
        self.context(workspace_id, surface_id, event, None)
        return True

    def reconnect_clicked(self, button, workspace_id, surface_id):
        self.hide()
        self.context(workspace_id, surface_id, None, "reconnect")

    def panel_enter(self, widget, event):
        self.inside_panel = True
        self.inside_corridor = False
        self.stop_timer("hide_source")
        return False

    def panel_leave(self, widget, event):
        if event.detail != Gdk.NotifyType.INFERIOR:
            self.inside_panel = False
            self.schedule_hide()
        return False

    def schedule_hide(self):
        if not self.persistent and not self.hovered_id and not self.inside_panel and not self.inside_corridor:
            self.stop_timer("hide_source")
            # Popover's arrow touches its source; this grace period bridges both.
            self.hide_source = self.schedule(140, self.hide_elapsed)

    def hide_elapsed(self):
        self.hide_source = 0
        if not self.hovered_id and not self.inside_panel and not self.inside_corridor and not self.persistent:
            self.hide()
        return False

    def bounds(self, widget):
        position = widget.translate_coordinates(self.window, 0, 0)
        if position is None:
            return None
        _, root_x, root_y = self.window.get_window().get_origin()
        x, y = position
        return (root_x + x, root_y + y, widget.get_allocated_width(), widget.get_allocated_height())

    def corridor_contains(self, x, y):
        source = self.rows.get(self.visible_id)
        if source is None or not self.popover.get_visible():
            return False
        a, b = self.bounds(source), self.bounds(self.popover)
        if a is None or b is None:
            return False
        # A narrow bridge, not the bounding box of both cards: movement away
        # from their adjacent edges must still dismiss the panel.
        left, right = sorted((a, b), key=lambda value: value[0])
        x1, x2 = left[0] + left[2] - 8, right[0] + 8
        y1, y2 = min(a[1], b[1]), max(a[1] + a[3], b[1] + b[3])
        return x1 <= x <= max(x1, x2) and y1 <= y <= y2

    def pointer_motion(self, widget, event):
        inside = self.corridor_contains(event.x_root, event.y_root)
        if inside:
            self.stop_timer("hide_source")
        changed = inside != self.inside_corridor
        self.inside_corridor = inside
        if changed and not inside:
            self.schedule_hide()
        return False

    def row_key(self, row, event, identifier):
        if event.keyval in (Gdk.KEY_Right, Gdk.KEY_KP_Right):
            self.show(identifier, keyboard=True)
            return True
        return self.key_press(row, event)

    def key_press(self, widget, event):
        return self.dismiss_key(event.keyval)

    def captured_key(self, controller, keyval, keycode, state):
        return self.dismiss_key(keyval)

    def dismiss_key(self, keyval):
        if keyval == Gdk.KEY_Escape and (self.visible_id or self.show_source):
            source = self.rows.get(self.visible_id) if self.persistent else None
            self.hide()
            if source:
                source.grab_focus()
            return True
        return False

    def captured_click(self, gesture, presses, x, y):
        event = gesture.get_last_event(gesture.get_current_sequence())
        if event is not None:
            self.outside_click(self.window, event)

    def outside_click(self, widget, event):
        target = Gtk.get_event_widget(event)
        if self.visible_id and target is not None:
            if target is self.popover or target.is_ancestor(self.popover):
                return False
            self.hide()
        return False

    def window_unfocused(self, widget, event):
        self.hide()
        return False

    def stop_timer(self, name):
        source = getattr(self, name)
        if source:
            self.cancel(source)
            setattr(self, name, 0)

    def hide(self):
        self.stop_timer("show_source")
        self.stop_timer("hide_source")
        self.visible_id = self.hovered_id = None
        self.inside_panel = self.inside_corridor = self.persistent = False
        self.popover.hide()

    def close(self):
        self.hide()
        self.popover.destroy()
        self.click_controller.set_propagation_phase(Gtk.PropagationPhase.NONE)
        self.key_controller.set_propagation_phase(Gtk.PropagationPhase.NONE)
        for handler in self.handlers:
            self.window.disconnect(handler)
        self.handlers = []
