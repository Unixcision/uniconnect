"""Recuperación explícita de sesiones tmux perdidas: al arrancar y cuando un cliente sale con 72.

Es una operación aparte: la reconexión sigue siendo solo enganchar. Por grupo (caja SSH o
equipo local, socket) se lista tmux una vez y cada ventana guardada cuya sesión falte se
recrea con ``Transport.ensure_session``: si la IA estaba activa (o interrumpida) y hay id,
con la orden de reanudar sin preguntas y la guarda de conversación abierta; si no, como
shell en su carpeta. Nunca toca sesiones vivas ni ventanas cerradas por el usuario, y en
un servidor tmux que ya existía solo hace ``new-session -d`` (D4, en ensure_session).

Cajas SSH (D6, contracts/agent-tree-v1/LEEME.md): la IA solo se reanuda sola si una
lectura viva vio esa sesión hace ≤ 2 ticks y nadie la cerró a propósito (desde UniConnect,
o el servidor sigue vivo con otras sesiones y falta solo esta). Si no, se recrea el shell.
"""

import logging

from .agent_tree import AgentTree
from .resume_catalog import AgentResumeCatalog
from .transport import Transport, TransportError

RESUMABLE = ("claude", "codex", "agy", "grok")
FIELDS = ("runtimeState", "interrupted", "agent", "sessionId", "resumeCwd")
LOG = logging.getLogger("uniconnect.recovery")


class SessionRecovery:
    def __init__(self, owner, *, transport=Transport, catalog=None):
        self.owner, self.transport = owner, transport
        self._catalog = catalog
        self.inflight = {}
        self.attempted = {}
        self.events = []

    @staticmethod
    def snapshot(store):
        """Copia de lo leído del disco, tomada antes de lanzar ninguna superficie."""
        return {record["id"]: {key: record.get(key) for key in FIELDS}
                for workspace in store.workspaces for record in workspace.get("windows", [])}

    @staticmethod
    def effective(record, saved=None, *, allowed=True):
        """Ventana con la que se recrea la sesión: la IA si estaba activa o interrumpida (y ``allowed``),
        si no un shell en su carpeta."""
        saved = saved if saved is not None else {key: record.get(key) for key in FIELDS}
        window = dict(record)
        resumable = bool(allowed and (saved.get("runtimeState") == "agent" or saved.get("interrupted"))
                         and saved.get("sessionId") and saved.get("agent") in RESUMABLE)
        if resumable:
            window.update(agent=saved["agent"], sessionId=saved["sessionId"])
            if saved.get("resumeCwd"):
                window["resumeCwd"] = saved["resumeCwd"]
            else:
                window.pop("resumeCwd", None)
        else:
            window["agent"] = "shell"
            # Un comando personalizado puede llevar un --resume viejo: se recrea un shell limpio.
            for key in ("sessionId", "resumeCwd", "model", "commandArgv"):
                window.pop(key, None)
        return window, resumable

    def display_name(self, agent):
        """``displayName`` del catálogo compartido (sin tabla propia); el id si no se puede leer."""
        try:
            if self._catalog is None:
                self._catalog = AgentResumeCatalog()
            return self._catalog.display_name(agent)
        except Exception:
            return agent

    def notice(self, window, resumable):
        if resumable:
            return "Sesión tmux recreada; reanudando %s %s" % (self.display_name(window["agent"]), window["sessionId"][:8])
        return "Sesión tmux recreada como terminal"

    def tree_allows(self, workspace, record):
        """D6 en memoria (hilo GTK): en local siempre; en SSH, vista viva hace ≤ 2 ticks y sin marca."""
        if workspace.get("kind") != "ssh":
            return True
        tree = getattr(self.owner, "agent_tree", None)
        return bool(tree is not None and tree.remote_resume_allowed(record))

    @staticmethod
    def still_allowed(workspace, record, allowed, alive):
        """D6 con la lista de sesiones de ahora: servidor vivo con otras y falta esta -> cierre deliberado."""
        if workspace.get("kind") != "ssh" or not allowed:
            return allowed
        return alive is not None and not (alive and record["tmux"] not in alive)

    def closed_ids(self):
        identifiers = set()
        for entry in getattr(self.owner.store, "closed", []):
            if entry.get("kind") == "window":
                identifiers.add((entry.get("window") or {}).get("id"))
            elif entry.get("kind") == "workspace":
                identifiers.update(item.get("id") for item in (entry.get("workspace") or {}).get("windows", []))
        return identifiers

    def transport_for(self, key, workspace):
        # Mismo criterio que el árbol vivo: una caja SSH solo con la bóveda ya abierta, sin preguntar.
        return AgentTree.open_transport(self.owner, self.transport, key, workspace)

    def record_event(self, window_id, code, detail=""):
        self.events.append((window_id, code, detail))
        del self.events[:-64]
        LOG.warning("recuperación %s: %s %s", window_id, code, detail)

    def finish(self, window_id):
        for callback in self.inflight.pop(window_id, []):
            try:
                if callback is not None:
                    callback()
            except Exception as error:
                self.record_event(window_id, "callback_failed", type(error).__name__)

    def show_notice(self, window_id, text):
        surface = getattr(self.owner, "surfaces", {}).get(window_id)
        if surface is not None and not surface.disposed:
            surface.recovery_notice = text

    def run_all(self, snapshot):
        """Recorre todas las cajas; cada grupo en segundo plano y aislado de los demás."""
        closed = self.closed_ids()
        groups = {}
        for workspace in self.owner.store.workspaces:
            for record in workspace.get("windows", []):
                if record.get("tmux") and record["id"] not in closed and record["id"] not in self.inflight:
                    groups.setdefault(AgentTree.group_key(workspace, record), (workspace, []))[1].append(record)
        started = []
        for key, (workspace, records) in groups.items():
            try:
                transport = self.transport_for(key, workspace)
            except Exception:
                transport = None
            if transport is None:
                continue
            windows = [(record["id"], dict(record), snapshot.get(record["id"]), self.tree_allows(workspace, record))
                       for record in records]
            for identifier, _, _, _ in windows:
                self.inflight.setdefault(identifier, [])

            def work(transport=transport, windows=windows, workspace=workspace):
                try:
                    alive = {item["name"] for item in transport.list_sessions()}
                except Exception as error:
                    return {"error": getattr(error, "code", type(error).__name__)}
                results = {}
                for identifier, record, saved, allowed in windows:
                    if record["tmux"] in alive:
                        continue
                    allowed = SessionRecovery.still_allowed(workspace, record, allowed, alive)
                    window, resumable = SessionRecovery.effective(record, saved, allowed=allowed)
                    try:
                        created = transport.ensure_session(window)["created"]
                        results[identifier] = ("created" if created else "exists", window, resumable)
                    except TransportError as error:
                        results[identifier] = ("failed", error.code, error.detail)
                    except Exception as error:
                        results[identifier] = ("failed", type(error).__name__, "")
                return {"results": results}

            def done(outcome, windows=windows, key=key):
                try:
                    if outcome.get("error"):
                        self.record_event(key[0], "group_failed", outcome["error"])
                    for identifier, result in outcome.get("results", {}).items():
                        if result[0] == "created":
                            self.show_notice(identifier, self.notice(result[1], result[2]))
                        elif result[0] == "failed":
                            self.record_event(identifier, result[1], result[2])
                finally:
                    for identifier, _, _, _ in windows:
                        self.finish(identifier)

            self.owner.background(work, done)
            started.append(key)
        return started

    def recover(self, workspace, record, then=None):
        """Recupera una ventana cuya sesión falta y después llama a ``then`` (relanzar la superficie)."""
        identifier = record["id"]
        if identifier in self.inflight:
            self.inflight[identifier].append(then)
            return True
        if identifier in self.closed_ids():
            return False
        transport = self.transport_for(AgentTree.group_key(workspace, record), workspace)
        if transport is None:
            return False
        saved, allowed = dict(record), self.tree_allows(workspace, record)
        self.inflight[identifier] = [then]

        def work():
            decided = allowed
            if decided and workspace.get("kind") == "ssh":
                # Lectura de ahora del socket entero: solo lista, nunca cambia nada.
                try:
                    alive = {item["name"] for item in transport.list_sessions()}
                except Exception:
                    alive = None
                decided = SessionRecovery.still_allowed(workspace, saved, decided, alive)
            window, resumable = SessionRecovery.effective(saved, allowed=decided)
            try:
                return ("created" if transport.ensure_session(window)["created"] else "exists", "", window, resumable)
            except TransportError as error:
                return ("failed", error.code, window, resumable)
            except Exception as error:
                return ("failed", type(error).__name__, window, resumable)

        def done(result):
            try:
                if result[0] == "created":
                    self.show_notice(identifier, self.notice(result[2], result[3]))
                elif result[0] == "failed":
                    self.record_event(identifier, result[1])
            finally:
                self.finish(identifier)

        self.owner.background(work, done)
        return True

    def on_missing_session(self, surface):
        """Salida 72 (la sesión tmux no existe): una sola recuperación por generación del cliente."""
        record = surface.record
        if not record.get("tmux") or self.attempted.get(record["id"]) == surface.generation:
            return False
        generation = surface.generation

        def relaunch():
            if (surface.disposed or surface.generation != generation or surface.pid
                    or surface._pending_launch is not None):
                return
            surface.launch()
            # Si el cliente relanzado vuelve a salir con 72, queda Desconectada como siempre.
            self.attempted[record["id"]] = surface.generation

        return self.recover(surface.workspace, record, relaunch)
