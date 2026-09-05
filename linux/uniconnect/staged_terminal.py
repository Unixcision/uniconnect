"""Linux UI adapter for provisional, independently verified tmux attachments."""

import copy
import threading
import uuid
from types import SimpleNamespace

from gi.repository import GLib

from .terminal import TerminalSurface
from .transport import SSHCommand, Transport


class StagedTerminal:
    """Keep candidate state and ownership isolated until the transaction publishes."""

    def __init__(self, owner, workspace, record, *, connection=None, registry=None,
                 probe_factory=None):
        self.readiness_token = uuid.uuid4().hex
        self.record = copy.deepcopy(record)
        self.workspace = copy.deepcopy(workspace)
        self._owner = owner
        self._connection = connection
        self._probe_factory = probe_factory
        self._observers = []
        self._cancel = threading.Event()
        self._adopted = False
        self._probe_thread = None
        self._staging_owner = SimpleNamespace(
            store=owner.store, font_scale=owner.font_scale, _=owner._,
            _terminal_owners=registry if registry is not None else {},
            _building_workspace=1, refresh_sidebar=lambda: None,
            persist=lambda: None, notify_window=lambda *args: None,
            connection=lambda workspace: self._connection,
        )
        self.surface = TerminalSurface(
            self._staging_owner, self.workspace, self.record, auto_launch=False,
            launch_preparer=self._prepare,
        )
        self._unsubscribe = self.surface.subscribe_lifecycle(self._on_lifecycle)

    @property
    def generation(self):
        return self.surface.generation

    @property
    def pid(self):
        return self.surface.pid

    def _prepare(self, workspace, record, connection, create):
        launch, keys = TerminalSurface._build_launch(workspace, record, connection, False)
        if workspace["kind"] == "ssh":
            launch.argv[-1] = "env UNICONNECT_ATTACH_TOKEN=" + self.readiness_token + " " + launch.argv[-1]
        else:
            launch.env["UNICONNECT_ATTACH_TOKEN"] = self.readiness_token
        return launch, keys

    def subscribe_lifecycle(self, callback):
        self._observers.append(callback)
        def unsubscribe():
            if callback in self._observers:
                self._observers.remove(callback)
        return unsubscribe

    def _emit(self, event):
        for callback in tuple(self._observers):
            callback(event)

    def start_candidate(self):
        if self._cancel.is_set():
            raise RuntimeError("candidate-cancelled")
        self.surface.launch(False)
        return self.generation

    def is_candidate_alive(self, generation, pid):
        if self._cancel.is_set() or self.surface.disposed or self.generation != generation or self.pid != pid or pid <= 0:
            return False
        # The GTK exit signal may still be queued when commit runs synchronously.
        # Linux /proc distinguishes a live child from an unreaped zombie.
        from pathlib import Path
        try:
            state = Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()[0]
            return state not in ("Z", "X")
        except (OSError, IndexError):
            return False

    def _on_lifecycle(self, event):
        self._emit(event)
        if event["kind"] != "spawned" or self._cancel.is_set():
            return
        # Staging has one attempt and its own deadline; it must not silently enter
        # the ordinary interactive window's automatic reconnect loop.
        self.surface._allow_auto_retry = False
        generation, pid = event["generation"], event["pid"]
        def observe():
            try:
                from .readiness import TmuxAttachmentProbe
                factory = self._probe_factory or TmuxAttachmentProbe
                transport = Transport(self._connection, socket_name=self.record.get("tmuxSocket", "uniconnect" if self.workspace["kind"] == "ssh" else "uniconnect-local"))
                proof = factory(transport, self.record, self.readiness_token, self._cancel).wait(timeout=20)
                event = {"kind": "ready", "generation": generation, "pid": pid, "proof": proof}
            except Exception as error:
                event = {"kind": "failed", "generation": generation, "pid": pid,
                         "reason": getattr(error, "code", "attachment-unverified")}
            def deliver():
                if self.is_candidate_alive(generation, pid):
                    self._emit(event)
                return False
            GLib.idle_add(deliver)
        self._probe_thread = threading.Thread(target=observe, name="uniconnect-readiness", daemon=True)
        self._probe_thread.start()

    def adopt(self, workspace, record):
        """Switch only ownership/model references; keep the proven VTE child alive."""
        command = SSHCommand.parse(self._connection) if self._connection else None
        endpoint = command.endpoint_key() if command else ("local",)
        keys = [("tmux", endpoint, record.get("tmuxSocket", "uniconnect" if command else "uniconnect-local"), record["tmux"])]
        if record.get("sessionId"):
            session = record["sessionId"]
            try:
                session = str(uuid.UUID(session))
            except ValueError:
                pass
            keys.append(("agent", endpoint, record.get("agent"), session))
        registry = getattr(self._owner, "_terminal_owners", None)
        if registry is None:
            registry = self._owner._terminal_owners = {}
        for key in keys:
            existing = registry.get(key)
            if existing and existing.record["id"] != record["id"]:
                raise RuntimeError("duplicate-owner")
        self._unsubscribe()
        self.surface._release_ownership()
        self.surface.workspace, self.surface.record = workspace, record
        self.surface.owner = self._owner
        for key in keys:
            registry[key] = self.surface
        self.surface._ownership_keys = keys
        self.surface._allow_auto_retry = True
        self._adopted = True
        return self.surface

    def stop_candidate(self):
        self._cancel.set()
        self._unsubscribe()
        if self._adopted:
            # Late VTE signals must never mutate committed/restored model records.
            self.surface.workspace = copy.deepcopy(self.surface.workspace)
            self.surface.record = copy.deepcopy(self.surface.record)
        self.surface.dispose()

    def release(self):
        """Release staging-only references after durable adoption."""
        self._observers.clear()
        self._connection = None
