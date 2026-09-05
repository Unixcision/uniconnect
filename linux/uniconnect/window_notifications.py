"""Notification actions over the desktop's existing, mobile-visible history."""

import time
import uuid

from gi.repository import Gio, GLib, Gtk


class WindowNotifications:
    @property
    def notifications(self):
        return self.store.data.get("notificationHistory", [])

    def notification_records(self, workspace_id=None, surface_id=None):
        return [record for workspace in self.store.workspaces
                if workspace_id is None or workspace["id"] == workspace_id
                for record in workspace.get("windows", [])
                if surface_id is None or record["id"] == surface_id]

    def notifications_unread(self, workspace_id=None, surface_id=None):
        return (any(not item.get("is_read", False) for item in self.notifications
                    if (workspace_id is None or item["workspace_id"] == workspace_id)
                    and (surface_id is None or item.get("surface_id") == surface_id))
                or any(record.get("unread", False) for record in self.notification_records(workspace_id, surface_id)))

    def notification_target(self, item):
        workspace = next((value for value in self.store.workspaces if value["id"] == item["workspace_id"]), None)
        if workspace is None:
            return None
        record = next((value for value in workspace.get("windows", []) if value["id"] == item.get("surface_id")), None)
        return (workspace, record) if record else None

    def latest_unread_notification(self):
        values = (item for item in self.notifications if not item.get("is_read", False) and self.notification_target(item))
        return max(values, key=lambda item: (item["created_at_ms"], item["id"]), default=None)

    def change_notifications(self, change, *, allow_locked=False):
        if self.locked and not allow_locked:
            return False
        history = self.store.data.setdefault("notificationHistory", [])
        before = [dict(item) for item in history]
        records = [(record, "unread" in record, record.get("unread")) for record in self.notification_records()]
        try:
            change(history)
            if history == before and all(record.get("unread") == value for record, _, value in records):
                return False
            self.store.save()
        except Exception as error:
            history[:] = before
            for record, existed, value in records:
                if existed:
                    record["unread"] = value
                else:
                    record.pop("unread", None)
            raise RuntimeError(self._("No se pudieron guardar los cambios de notificaciones")) from error
        self.refresh_sidebar()
        self.refresh_actions()
        app = self.get_application() if hasattr(self, "get_application") else None
        if app:
            prior_surfaces = {item.get("surface_id") for item in before if not item.get("is_read", False)}
            for surface_id in prior_surfaces:
                if surface_id and not self.notifications_unread(surface_id=surface_id):
                    app.withdraw_notification(surface_id)
        render = getattr(self, "_notification_render", None)
        if render:
            GLib.idle_add(render)  # Let the button/focus signal unwind before replacing rows.
        return True

    def set_notifications_read(self, is_read, workspace_id=None, surface_id=None):
        def change(history):
            for item in history:
                if ((workspace_id is None or item["workspace_id"] == workspace_id)
                        and (surface_id is None or item.get("surface_id") == surface_id)):
                    item["is_read"] = is_read
            for record in self.notification_records(workspace_id, surface_id):
                record["unread"] = not is_read
        changed = self.change_notifications(change)
        surface = self.focused_surface
        if changed and surface and surface.record in self.notification_records(workspace_id, surface_id):
            self._notification_preserve_focus_id = None if is_read else surface.record["id"]
        return changed

    def mark_notifications_read(self, window_id):
        if getattr(self, "_notification_context_selection", False):
            return
        if getattr(self, "_notification_preserve_focus_id", None) == window_id:
            return  # Returning from a menu must not undo an explicit unread mark.
        self._notification_preserve_focus_id = None
        try:
            self.set_notifications_read(True, surface_id=window_id)
        except RuntimeError as error:
            # A focus signal must not open another modal dialog or mark a failed
            # save as successful. The mutation has already rolled back.
            if hasattr(self, "status_label"):
                self.status_label.set_text(str(error))

    def action_notifications_mark_all_read(self):
        self.set_notifications_read(True)

    def action_notifications_toggle_workspace(self):
        workspace = self.current_workspace()
        if workspace:
            self.set_notifications_read(self.notifications_unread(workspace["id"]), workspace_id=workspace["id"])

    def action_notifications_toggle_window(self):
        surface = self.focused_surface
        if surface:
            self.set_notifications_read(self.notifications_unread(surface_id=surface.record["id"]),
                                        surface_id=surface.record["id"])

    def action_notifications_latest_unread(self):
        item = self.latest_unread_notification()
        if item:
            self.notification_action(item["id"], "open")

    def action_notifications_dismiss_all(self):
        def change(history):
            history.clear()
            for record in self.notification_records():
                record["unread"] = False
        self.change_notifications(change)

    def notification_action(self, identifier, action):
        if self.locked:
            return False
        item = next((value for value in self.notifications if value["id"] == identifier), None)
        if item is None:
            return False
        if action == "open":
            target = self.notification_target(item)
            if target is None:
                return False  # A closed target must not select some other workspace.
            workspace, record = target
            workspace["selectedWindowId"] = record["id"]
            if workspace.get("maximizedPaneId"):
                workspace["maximizedPaneId"] = record.get("paneId", "main")
            self.select_workspace(workspace["id"])
            surface = self.surfaces.get(record["id"])
            if surface is None:
                return False
            self.apply_pane_visibility(workspace)
            self.select_surface(surface)
            self.set_notifications_read(True, surface_id=record["id"])
            return True
        if action not in ("toggle_read", "dismiss"):
            return False
        def change(history):
            if action == "dismiss":
                history.remove(item)
            else:
                item["is_read"] = not item.get("is_read", False)
            for record in self.notification_records(item["workspace_id"], item.get("surface_id")):
                record["unread"] = any(not value.get("is_read", False) for value in history
                                       if value.get("surface_id") == record["id"])
        changed = self.change_notifications(change)
        if changed and action == "toggle_read" and not item["is_read"] and self.focused_surface:
            if item.get("surface_id") == self.focused_surface.record["id"]:
                self._notification_preserve_focus_id = item["surface_id"]
        return changed

    def notify_window(self, workspace, window):
        from .mobile_rpc import notification_record
        item = notification_record(workspace, window, time.time(), str(uuid.uuid4()))
        item["body"] = self._("Session needs attention")
        def change(history):
            window["unread"] = True
            history.append(item)
            del history[:-1000]
        try:
            if not self.change_notifications(change, allow_locked=True):
                return
        except RuntimeError as error:
            if hasattr(self, "status_label"):
                self.status_label.set_text(str(error))
            return
        if hasattr(self, "mobile"):
            self.mobile.notification_created(item)
        notification = Gio.Notification.new(window["name"])
        notification.set_body(workspace["name"] + " · " + self._("Session needs attention"))
        self.get_application().send_notification(window["id"], notification)

    def action_notifications(self):
        dialog = Gtk.Dialog(title=self._("Notifications"), transient_for=self, modal=True)
        dialog.add_button(self._("Close"), Gtk.ResponseType.CLOSE)
        dialog.set_default_size(660, 440)
        content = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8, margin=12)
        scroll = Gtk.ScrolledWindow()
        scroll.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        scroll.add(content)
        dialog.get_content_area().pack_start(scroll, True, True, 0)
        def invoke(identifier, action):
            try:
                if self.notification_action(identifier, action) and action == "open":
                    dialog.response(Gtk.ResponseType.CLOSE)
            except Exception as error:
                self.error(error)
        def button(label, icon, callback, sensitive=True, destructive=False):
            result = Gtk.Button(label=self._(label))
            result.set_image(Gtk.Image.new_from_icon_name(icon, Gtk.IconSize.BUTTON))
            result.set_always_show_image(True)
            result.set_sensitive(sensitive)
            if destructive:
                result.get_style_context().add_class("destructive-action")
            result.connect("clicked", lambda *_: callback())
            return result
        def render():
            if self._notification_render is not render:
                return False
            for child in content.get_children():
                child.destroy()
            toolbar = Gtk.Box(spacing=6)
            for name, icon in (("notifications_latest_unread", "go-jump-symbolic"),
                               ("notifications_mark_all_read", "mail-mark-read-symbolic"),
                               ("notifications_dismiss_all", "edit-delete-symbolic")):
                toolbar.pack_start(button(self.action_label(name), icon, lambda n=name: self.run_action(n),
                                          self.action_enabled(name), name == "notifications_dismiss_all"), False, False, 0)
            content.pack_start(toolbar, False, False, 0)
            for item in sorted(self.notifications, key=lambda value: (value["created_at_ms"], value["id"]), reverse=True):
                row = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6, margin_top=8)
                stamp = time.strftime("%H:%M", time.localtime(item["created_at_ms"] / 1000))
                title = ("●  " if not item.get("is_read", False) else "") + stamp + "  " + item["title"]
                row.pack_start(Gtk.Label(label=title, xalign=0), False, False, 0)
                actions = Gtk.Box(spacing=6)
                for name, label, icon in (("open", "Open", "go-jump-symbolic"),
                                          ("toggle_read", "Marcar como no leída" if item.get("is_read", False) else "Marcar como leída",
                                           "mail-mark-unread-symbolic" if item.get("is_read", False) else "mail-mark-read-symbolic"),
                                          ("dismiss", "Descartar", "edit-delete-symbolic")):
                    actions.pack_start(button(label, icon, lambda n=name, i=item["id"]: invoke(i, n),
                                              not self.locked and (name != "open" or bool(self.notification_target(item))),
                                              name == "dismiss"), False, False, 0)
                row.pack_start(actions, False, False, 0)
                content.pack_start(row, False, False, 0)
            if not self.notifications:
                content.pack_start(Gtk.Label(label=self._("No notifications"), margin=20), False, False, 0)
            content.show_all()
            return False
        self._notification_render = render
        try:
            render()
            dialog.show_all()
            dialog.run()
        finally:
            self._notification_render = None
            dialog.destroy()
