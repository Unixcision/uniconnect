"""GTK composition and local approval UI for the personal Tailscale adapter."""

from gi.repository import GLib, Gtk

from .mobile_access import MobileAccess
from .mobile_host import MobileHost
from .mobile_rpc import MobileRPC


class MobileDesktop:
    def __init__(self, window, header):
        self.window = window
        self.access = MobileAccess(window.store.root)
        self.rpc = MobileRPC(window, self.access, GLib.idle_add)
        self.host = MobileHost(self.access, self.rpc, translate=window._)
        self.rpc.host = self.host
        self.dialog = None
        self.refresh_source = None
        self.terminal_source = None
        self.dirty_terminals = set()
        self.button = Gtk.Button.new_from_icon_name("smartphone-symbolic", Gtk.IconSize.BUTTON)
        self.button.set_tooltip_text(window._("Mobile access"))
        self.button.connect("clicked", lambda *_: self.show())
        header.pack_end(self.button)
        self.access.on_change = self.schedule_refresh
        self.host.on_change = self.schedule_refresh
        if window.store.data.get("settings", {}).get("mobileHostEnabled", False):
            self.host.start()

    def schedule_refresh(self):
        GLib.idle_add(self.refresh)

    def refresh(self):
        if self.window._closed:
            return False
        approved, pending = self.access.snapshot()
        self.button.set_tooltip_text(self.window._("Pending mobile access requests") if pending else self.window._("Mobile access"))
        context = self.button.get_style_context()
        if pending:
            context.add_class("suggested-action")
        else:
            context.remove_class("suggested-action")
        if self.dialog:
            self.render_dialog(approved, pending)
        return False

    def show(self):
        if self.dialog:
            self.dialog.present()
            return
        self.dialog = Gtk.Dialog(title=self.window._("Mobile access"), transient_for=self.window, modal=False)
        self.dialog.add_button(self.window._("Close"), Gtk.ResponseType.CLOSE)
        self.dialog.set_default_size(580, 340)
        self.dialog.connect("response", lambda *_: self.close_dialog())
        self.dialog.connect("delete-event", lambda *_: self.close_dialog())
        self.refresh_source = GLib.timeout_add_seconds(1, lambda: self.refresh() or self.dialog is not None)
        self.refresh()
        self.dialog.show_all()

    def render_dialog(self, approved, pending):
        content = self.dialog.get_content_area()
        for child in content.get_children():
            child.destroy()
        enable = Gtk.CheckButton(label=self.window._("Enable mobile access over Tailscale"))
        enable.set_active(self.window.store.data.get("settings", {}).get("mobileHostEnabled", False))
        enable.connect("toggled", self.toggle)
        content.pack_start(enable, False, False, 8)
        status = self.host.error or (f"{self.host.address}:{self.host.port}" if self.host.address else self.window._("Mobile access is disabled"))
        content.pack_start(Gtk.Label(label=self.window._(status), xalign=0), False, False, 8)
        warning = Gtk.Label(label=self.window._("Approved devices can control your terminals. Only approve your own Tailscale devices."), xalign=0)
        warning.set_line_wrap(True)
        content.pack_start(warning, False, False, 8)
        for peer in pending:
            row = Gtk.Box(spacing=8)
            row.pack_start(Gtk.Label(label=peer["label"] + " · " + peer["address"], xalign=0), True, True, 0)
            for label, callback in (("Approve", self.access.approve), ("Reject", self.access.reject)):
                button = Gtk.Button(label=self.window._(label))
                button.connect("clicked", lambda _, address=peer["address"], action=callback: self.permission_action(action, address))
                row.pack_end(button, False, False, 0)
            content.pack_start(row, False, False, 5)
        for peer in approved:
            row = Gtk.Box(spacing=8)
            row.pack_start(Gtk.Label(label=peer["label"] + " · " + peer["address"], xalign=0), True, True, 0)
            button = Gtk.Button(label=self.window._("Revoke access"))
            button.connect("clicked", lambda _, address=peer["address"]: self.permission_action(self.access.revoke, address))
            row.pack_end(button, False, False, 0)
            content.pack_start(row, False, False, 5)
        content.show_all()

    def permission_action(self, action, address):
        try:
            action(address)
        except Exception:
            self.window.error(self.window._("Could not save mobile access permissions"))
        self.schedule_refresh()

    def toggle(self, button):
        settings = self.window.store.data.setdefault("settings", {})
        previous = settings.get("mobileHostEnabled", False)
        settings["mobileHostEnabled"] = button.get_active()
        try:
            self.window.store.save()
        except Exception:
            settings["mobileHostEnabled"] = previous
            self.window.error(self.window._("Could not save mobile access permissions"))
            self.schedule_refresh()
            return
        if settings["mobileHostEnabled"]:
            self.host.start()
        else:
            self.host.stop()
        self.schedule_refresh()

    def workspace_changed(self):
        self.host.emit("workspace.updated")

    def notification_created(self, item):
        if not self.window.locked:
            self.host.emit("notification.created", item)

    def terminal_changed(self, panel_id):
        self.rpc.invalidate_terminal(panel_id)
        self.dirty_terminals.add(panel_id)
        if self.terminal_source is None:
            self.terminal_source = GLib.timeout_add(100, self.flush_terminals)

    def flush_terminals(self):
        self.terminal_source = None
        self.dirty_terminals.clear()
        self.host.emit("terminal.updated")
        return False

    def close_dialog(self):
        if self.refresh_source:
            GLib.source_remove(self.refresh_source)
            self.refresh_source = None
        if self.dialog:
            dialog, self.dialog = self.dialog, None
            dialog.destroy()
        return True

    def close(self):
        self.close_dialog()
        if self.terminal_source:
            GLib.source_remove(self.terminal_source)
            self.terminal_source = None
        self.host.stop()
