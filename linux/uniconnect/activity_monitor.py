"""Ciclo de actividad del escritorio: sonda tmux fuera de GTK, decide en el hilo del modelo.

Cada ~2 s recoge los hechos de cada ventana viva (comando en primer plano, título,
salida reciente), evalúa con ``ActivityResolver`` y, si algún estado cambia,
refresca la barra lateral y publica ``workspace.updated`` (coalescido a ≥ 1 s en
``MobileDesktop``). Las cajas SSH se sondean por la misma vía que ya usa el
escritorio para hablar con el remoto, con menos frecuencia. GLib solo se importa
al arrancar el temporizador, para poder componer el monitor con ventanas falsas.
"""

import math
import os
import time
from pathlib import Path

from .activity import ActivityResolver, aggregate_state, parse_list_panes, probe_script, select_pane
from .transport import Transport

VTE_FORMAT_TEXT = 1  # Vte.Format.TEXT; evita importar Vte cuando la terminal es falsa.


class ActivityMonitor:
    INTERVAL_SECONDS = 2.0
    SSH_INTERVAL_SECONDS = 10.0
    SCREEN_ROWS = 12

    def __init__(self, window, *, resolver=None, transport=Transport, clock=time.time,
                 monotonic=time.monotonic, interval=INTERVAL_SECONDS, ssh_interval=SSH_INTERVAL_SECONDS,
                 timer=None, cancel=None):
        self.window = window
        self.resolver = resolver or ActivityResolver(clock=clock)
        self.transport, self.clock, self.monotonic = transport, clock, monotonic
        self.interval, self.ssh_interval = interval, ssh_interval
        self.timer, self.cancel = timer, cancel
        self.pending = set()
        self.probed = {}  # (caja | "local", socket) → último sondeo SSH (monotónico).
        self.source = None

    # ----- ciclo -----

    def start(self):
        if self.source is not None:
            return
        if self.timer is None:
            from gi.repository import GLib
            self.timer, self.cancel = GLib.timeout_add, GLib.source_remove
        self.source = self.timer(max(1, int(self.interval * 1000)), self.cycle)

    def stop(self):
        if self.source is not None and self.cancel is not None:
            self.cancel(self.source)
        self.source = None

    # ----- hechos desde las señales de VTE y del móvil (hilo GTK) -----

    def note_output(self, window_id):
        self.resolver.note_output(window_id)

    def note_input(self, window_id):
        self.resolver.note_input(window_id)

    def note_resize(self, window_id):
        self.resolver.note_resize(window_id)

    def forget(self, window_id):
        self.resolver.forget(window_id)

    # ----- lecturas -----

    def activity(self, window_id):
        return self.resolver.current(window_id)

    def workspace_state(self, workspace):
        return aggregate_state(self.activity(record["id"]).state for record in workspace.get("windows", []))

    @staticmethod
    def foreground_command(surface):
        """Comando en primer plano del PTY de una ventana local sin tmux (solo Linux)."""
        try:
            pty = surface.terminal.get_pty()
            if pty is None:
                return None
            group = os.tcgetpgrp(pty.get_fd())
            return Path(f"/proc/{group}/comm").read_text().strip() or None
        except Exception:
            return None

    @classmethod
    def screen_lines(cls, surface):
        """Las últimas 12 filas visibles del VTE, tal cual (con las vacías); nunca se registran.

        VTE ≥ 0.76 exige ``get_text_format`` (``get_text`` aborta con atributos no
        nulos bajo fatal-criticals); los VTE anteriores solo tienen ``get_text``.
        """
        terminal = surface.terminal
        reader = getattr(terminal, "get_text_format", None)
        if reader is not None:
            try:
                from gi.repository import Vte
                text_format = Vte.Format.TEXT
            except Exception:
                text_format = VTE_FORMAT_TEXT
            text = reader(text_format)
        else:
            text = terminal.get_text(None, None)[0]
        if not isinstance(text, str):
            return None
        return text.rstrip("\n").split("\n")[-cls.SCREEN_ROWS:]

    def cycle(self):
        window = self.window
        if window._closed:
            self.source = None
            return False
        if window.locked:
            return True
        groups = {}
        for surface in tuple(window.surfaces.values()):
            record, workspace = surface.record, surface.workspace
            if surface.disposed or not surface.pid:
                continue  # evaluate() lo trata como muerto.
            self.resolver.note_alive(record["id"], True, launched=record.get("agent"))
            if record.get("tmux"):
                socket = record.get("tmuxSocket") or ("uniconnect" if workspace["kind"] == "ssh" else "uniconnect-local")
                key = (workspace["id"] if workspace["kind"] == "ssh" else "local", socket)
                groups.setdefault(key, []).append((surface, record, workspace))
            else:
                title = None
                try:
                    title = surface.terminal.get_window_title() or ""
                except Exception:
                    pass
                self.resolver.note_probe(record["id"], self.foreground_command(surface), title)
        for key, targets in groups.items():
            if key in self.pending:
                continue
            workspace = targets[0][2]
            command = None
            if workspace["kind"] == "ssh":
                if self.monotonic() - self.probed.get(key, -math.inf) < self.ssh_interval:
                    continue
                vault = getattr(window, "vault", None)
                if vault is not None and vault.locked:
                    continue
                try:
                    command = window.connection(workspace)
                except Exception:
                    continue
                self.probed[key] = self.monotonic()
            try:
                transport = self.transport(command, socket_name=key[1])
            except Exception:
                continue
            self.pending.add(key)
            def work(transport=transport):
                try:
                    output = transport.run(probe_script(transport.socket_name), timeout=8, check=False).stdout
                    return parse_list_panes(output)
                except Exception:
                    return None
            def done(result, key=key, targets=targets):
                self.pending.discard(key)
                if window._closed:
                    return
                for surface, record, workspace in targets:
                    if surface.disposed or window.surfaces.get(record["id"]) is not surface:
                        continue
                    entry = select_pane(result.get(record.get("tmux")), record.get("paneId")) if result else None
                    if entry is None:
                        self.resolver.clear_probe(record["id"])  # Sonda fallida, sesión ausente o pane ambiguo.
                    else:
                        self.resolver.note_probe(record["id"], *entry)
                self.evaluate()
            window.background(work, done)
        self.evaluate()
        return True

    def evaluate(self):
        window = self.window
        changed = False
        live = set()
        for surface in tuple(window.surfaces.values()):
            window_id = surface.record["id"]
            if surface.disposed or not surface.pid:
                continue
            live.add(window_id)
            previous = self.resolver.current(window_id)
            current = self.resolver.evaluate(window_id, screen=lambda surface=surface: self.screen_lines(surface))
            if (current.state, current.agent) != (previous.state, previous.agent):
                changed = True
        for window_id in [key for key in self.resolver.facts if key not in live]:
            # Muerta, cerrada o sin superficie: se olvida todo; nada puede seguir trabajando.
            if self.resolver.current(window_id).state != "unknown":
                changed = True
            self.resolver.forget(window_id)
        if changed:
            window.refresh_sidebar()
        return changed
