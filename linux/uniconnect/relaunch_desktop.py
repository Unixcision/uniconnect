"""GTK/model boundary for one relaunch path shared by desktop, CLI and mobile."""

import copy
from concurrent.futures import Future
import threading
import uuid

from .mobile_protocol import RPCError
from .relaunch import RelaunchService
from .relaunch_agents import RelaunchAgents, RelaunchUnavailable
from .relaunch_history import RelaunchHistory
from .transport import SSHCommand, Transport


class RelaunchDesktop:
    def __init__(self, window, schedule, *, service=None):
        self.window, self.schedule = window, schedule
        self.main_thread = threading.get_ident()
        self.machine_id = window.mobile.access.machine_id if hasattr(window, "mobile") else "local"
        self.service = service or RelaunchService(window.store.root / "relaunch-v1",
            RelaunchAgents(reconnect=self.reconnect, validate=lambda candidate: self.main(lambda: self.current(candidate)),
                           resolve=lambda target: self.main(lambda: self.resolve(target))))
        self.history = RelaunchHistory(window.store.root / "relaunch-receipts-v1")

    def main(self, action):
        if threading.get_ident() == self.main_thread:
            return action()
        future = Future()
        def deliver():
            if future.set_running_or_notify_cancel():
                try:
                    future.set_result(action())
                except Exception as error:
                    future.set_exception(error)
            return False
        self.schedule(deliver)
        try:
            return future.result(timeout=5)
        except TimeoutError:
            future.cancel()
            raise RPCError("busy", "El escritorio está ocupado") from None

    def allowed(self):
        window = self.window
        operation = getattr(window, "_runtime_operation", None)
        return not (window.locked or window._closed or (operation and operation.active)
                    or getattr(window.store, "_active_transaction", None))

    def snapshot(self, scope):
        if not self.allowed():
            raise RPCError("busy", "Espera a que termine la operación del escritorio o desbloquéalo")
        selected = self.service.scope(scope, self.machine_id, self.window.store.workspaces)
        result = []
        for workspace, record in selected:
            try:
                connection = self.window.connection(workspace) if workspace["kind"] == "ssh" else None
            except Exception:
                connection = None
            result.append({"workspace": copy.deepcopy(workspace), "record": copy.deepcopy(record),
                           "connection": connection, "provider": record.get("agent", "terminal"),
                           "label": workspace["name"] + " · " + record["name"]})
        return result

    def current(self, candidate):
        if not self.allowed():
            return False
        workspace = next((box for box in self.window.store.workspaces if box["id"] == candidate["workspace"]["id"]), None)
        record = next((row for row in workspace.get("windows", []) if row["id"] == candidate["record"]["id"]), None) if workspace else None
        fields = ("tmux", "tmuxSocket", "agent", "cwd", "sessionId")
        return bool(record and all(record.get(key) == candidate["record"].get(key) for key in fields)
                    and workspace.get("credentialId") == candidate["workspace"].get("credentialId"))

    def resolve(self, target):
        candidates = self.snapshot({"kind": "window", "id": target["record"]["id"]})
        for candidate in candidates:
            if (candidate["workspace"]["id"] == target["workspace_id"]
                    and candidate["workspace"].get("credentialId") == target["credential_id"]
                    and all(candidate["record"].get(key) == value for key, value in target["record"].items())):
                return candidate
        raise RelaunchUnavailable("generacion_cambiada")

    def dispatch(self, method, params, owner="desktop", authorized=lambda: True):
        def check():
            return authorized() and self.main(self.allowed)
        if method == "relaunch.plan":
            candidates = self.main(lambda: self.snapshot(params.get("scope")))
            # Missing credentials must never downgrade an SSH objective to local.
            for candidate in candidates:
                if candidate["workspace"]["kind"] == "ssh" and candidate["connection"] is None:
                    candidate["record"]["tmux"] = None
            return self.service.plan(params.get("verb"), candidates, owner, check)
        if method == "relaunch.apply":
            return self.service.apply(params.get("operation_id"), params.get("token"), owner, check)
        if method == "relaunch.status":
            return self.service.status(params.get("operation_id"), owner, check)
        raise RPCError("invalid_params", "Operación de relanzado no válida")

    def reconnect(self, candidate, proof, authorized):
        """Attach with a per-attempt nonce; prove the actual client, never a shell."""
        from .terminal import TerminalSurface
        from .readiness import TmuxAttachmentProbe
        token, cancel = uuid.uuid4().hex, threading.Event()
        def start():
            if not authorized() or not self.current(candidate):
                raise RelaunchUnavailable("generacion_cambiada")
            surface = self.window.surfaces.get(candidate["record"]["id"])
            if surface is None:
                raise RelaunchUnavailable("no_soportado")
            original = surface._launch_preparer
            def prepare(workspace, record, connection, create):
                launch, keys = TerminalSurface._build_launch(workspace, record, connection, False)
                if launch.notice:
                    raise RelaunchUnavailable("host_inaccesible")
                if connection:
                    launch.argv = SSHCommand.parse(connection).argv(
                        "env UNICONNECT_ATTACH_TOKEN=" + token + " " + launch.argv[-1], tty=True, batch=True)
                else:
                    launch.env["UNICONNECT_ATTACH_TOKEN"] = token
                return launch, keys
            surface._launch_preparer = prepare
            surface.launch(False)
            return surface, original, prepare
        surface, original, prepare = self.main(start)
        try:
            transport = Transport(candidate["connection"], socket_name=candidate["record"].get("tmuxSocket"))
            TmuxAttachmentProbe(transport, candidate["record"], token, cancel).wait(timeout=20)
        finally:
            def restore():
                if surface._launch_preparer is prepare:
                    surface._launch_preparer = original
            self.main(restore)

    def show(self, kind):
        window = self.window
        if kind == "global":
            from .relaunch_fleet import RelaunchFleet
            peers = window.mobile.access.snapshot()[0] if hasattr(window, "mobile") else []
            own = getattr(getattr(window, "mobile", None), "host", None)
            peers = [p for p in peers if p["address"] != getattr(own, "address", None)]
            window.status_label.set_text(window._("Preparando el plan de relanzado…"))
            window.background(RelaunchFleet(self, peers).plan, self.preview)
            return
        if kind == "window":
            identifier = window.focused_surface.record["id"]
        elif kind == "workspace":
            identifier = window.current_workspace()["id"]
        else:
            identifier = self.machine_id
        scope = {"kind": kind, "id": identifier}
        window.status_label.set_text(window._("Preparando el plan de relanzado…"))
        window.background(lambda: self.dispatch("relaunch.plan", {"verb": "agent.relaunch", "scope": scope}), self.preview)

    def preview(self, plan):
        from gi.repository import Gtk
        window = self.window
        names = ["• " + target["label"] for target in plan["targets"]]
        names += ["— " + target["label"] + ": " + window._("uniconnect.relaunch.cause." + target["cause"]) for target in plan["excluded"]]
        detail = window._("Se cerrará y reabrirá la IA conservando su conversación. tmux y tus archivos no se borran.")
        detail += "\n\n" + "\n".join(names)
        window.status_label.set_text(window._("Plan de relanzado preparado"))
        if not plan["targets"]:
            window.error(window._("No hay agentes que puedan relanzarse con seguridad") + "\n\n" + "\n".join(names))
            return
        if not window.confirm("Relanzar las IA seleccionadas", detail):
            return
        def apply():
            self.history.remember(plan)
            if "fleet" in plan:
                return plan["fleet"].operation("relaunch.apply")
            return self.dispatch("relaunch.apply", {"operation_id": plan["operation_id"], "token": plan["token"]})
        window.background(apply, lambda value: self.result_window(plan, value))

    def show_history(self):
        from gi.repository import Gtk
        import datetime
        window = self.window
        def show(receipts):
            if not receipts:
                window.error(window._("No hay relanzados guardados en este equipo"))
                return
            dialog = Gtk.Dialog(title=window._("Resultados de relanzados"), transient_for=window, modal=True)
            dialog.add_buttons(window._("Cancel"), Gtk.ResponseType.CANCEL, window._("Ver resultado"), Gtk.ResponseType.OK)
            choices = Gtk.ComboBoxText()
            for receipt in receipts:
                date = datetime.datetime.fromtimestamp(receipt["created_at"]).strftime("%d/%m %H:%M")
                choices.append_text(date + " · " + ", ".join(t["label"] for t in receipt["targets"])[:160])
            choices.set_active(0)
            dialog.get_content_area().pack_start(choices, True, True, 12)
            dialog.show_all()
            response, index = dialog.run(), choices.get_active()
            dialog.destroy()
            if response != Gtk.ResponseType.OK or index < 0:
                return
            plan = receipts[index]
            def status():
                if "hosts" in plan:
                    from .relaunch_fleet import RelaunchFleet
                    plan["fleet"] = RelaunchFleet.restore(self, plan["hosts"])
                    return plan["fleet"].operation("relaunch.status")
                return self.dispatch("relaunch.status", {"operation_id": plan["operation_id"]})
            window.background(status, lambda value: self.result_window(plan, value))
        window.background(self.history.recent, show)

    def result_window(self, plan, response):
        from gi.repository import GLib, Gtk
        window = self.window
        dialog = Gtk.Dialog(title=window._("Resultado del relanzado"), transient_for=window, modal=False)
        dialog.set_default_size(660, 420)
        dialog.add_button(window._("Close"), Gtk.ResponseType.CLOSE)
        dialog.add_button(window._("Actualizar estado"), Gtk.ResponseType.APPLY)
        text = Gtk.TextView(editable=False, cursor_visible=False, wrap_mode=Gtk.WrapMode.WORD_CHAR)
        scroll = Gtk.ScrolledWindow()
        scroll.add(text)
        dialog.get_content_area().pack_start(scroll, True, True, 8)
        live = [True]
        labels = {target["key"]: target["label"] for target in plan["targets"]}
        def update(value):
            if not live[0]:
                return
            lines = [labels.get(item["key"], item["key"]) + " — " + window._("uniconnect.relaunch.state." + item["state"]) +
                     (": " + window._("uniconnect.relaunch.cause." + item["cause"]) if item.get("cause") else "") for item in value["results"]]
            lines += [item["label"] + " — " + window._("uniconnect.relaunch.cause." + item["cause"]) for item in plan["excluded"]]
            text.get_buffer().set_text("\n".join(lines))
            if value["operation_state"] == "en_curso":
                GLib.timeout_add(750, refresh)
        def refresh():
            if live[0]:
                def status():
                    return (plan["fleet"].operation("relaunch.status") if "fleet" in plan else
                            self.dispatch("relaunch.status", {"operation_id": plan["operation_id"]}))
                window.background(status, update)
            return False
        def closed(_, response):
            if response == Gtk.ResponseType.APPLY:
                refresh()
                return
            live[0] = False
            dialog.destroy()
        dialog.connect("response", closed)
        dialog.connect("destroy", lambda *_: live.__setitem__(0, False))
        dialog.show_all()
        update(response)
