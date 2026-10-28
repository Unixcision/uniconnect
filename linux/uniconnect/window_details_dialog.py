"""Presentación GTK de window_details.v1; las lecturas del destino se ejecutan fuera de GTK."""

import time

from gi.repository import GLib, Gtk, Pango

from .clipboard_text import publish_text
from .window_details import CHECKING, TITLE, WindowDetails


class WindowDetailsDialog(Gtk.Dialog):
    """Detalles seleccionables y copiables de una ventana, sin ejecutar la orden de reanudación."""

    FAILED = "No se han podido pedir los detalles de esta ventana."
    COPY_FAILED = "No se han podido copiar los datos al portapapeles."

    def __init__(self, owner, surface):
        super().__init__(title=TITLE, transient_for=owner, modal=True, destroy_with_parent=True)
        self.owner, self.workspace, self.record = owner, surface.workspace, surface.record
        self.details = None
        self.loading, self.closed = False, False
        self.set_default_size(680, 540)
        self.add_button("Cerrar", Gtk.ResponseType.CLOSE)
        self.connect("response", lambda *_: self.destroy())
        self.connect("destroy", self._destroyed)

        content = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10, margin=20)
        header = Gtk.Box(spacing=8)
        self.spinner = Gtk.Spinner()
        self.status = Gtk.Label(xalign=0, wrap=True)
        self.status.get_style_context().add_class("dim-label")
        header.pack_start(self.spinner, False, False, 0)
        header.pack_start(self.status, True, True, 0)
        self.refresh_button = Gtk.Button(label="Actualizar")
        self.refresh_button.connect("clicked", lambda *_: self.refresh())
        header.pack_end(self.refresh_button, False, False, 0)
        content.pack_start(header, False, False, 0)

        self.grid = Gtk.Grid(column_spacing=18, row_spacing=8, hexpand=True)
        scroll = Gtk.ScrolledWindow()
        scroll.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        scroll.set_min_content_height(260)
        scroll.add(self.grid)
        content.pack_start(scroll, True, True, 0)
        buttons = Gtk.Box(spacing=8)
        self.copy_id_button = Gtk.Button(label="Copiar ID")
        self.copy_details_button = Gtk.Button(label="Copiar detalles")
        self.copy_command_button = Gtk.Button(label="Copiar orden")
        for button, kind in ((self.copy_id_button, "session_id"),
                             (self.copy_details_button, "details"),
                             (self.copy_command_button, "command")):
            button.connect("clicked", lambda _, action=kind: self.copy(action))
            buttons.pack_start(button, False, False, 0)
        content.pack_start(buttons, False, False, 0)
        self.copy_status = Gtk.Label(xalign=0, wrap=True)
        self.copy_status.get_style_context().add_class("dim-label")
        content.pack_start(self.copy_status, False, False, 0)
        self.get_content_area().add(content)
        self.show_all()
        self.refresh()

    def _destroyed(self, *_):
        # Cerrar por Escape, por el gestor de ventanas o junto al padre invalida la entrega.
        self.closed = True
        self.details = None

    def _available(self):
        if self.closed:
            return False
        if self.owner._closed or self.owner.locked:
            self.destroy()
            return False
        return True

    def refresh(self):
        if not self._available() or self.loading:
            return
        self.loading = True
        self.copy_status.set_text("")
        saved = None
        try:
            # Solo copias y acceso a la bóveda ya abierta; nunca ssh -G ni la sonda aquí.
            saved = self.owner.window_details(self.workspace, self.record)
            inputs = self.owner.details_inputs(self.workspace, self.record)
            catalog = self.owner._details_catalog()
        except Exception:
            self.loading = False
            self.render(self.unchecked(saved), self.FAILED, failed=True)
            return
        self.render(saved, CHECKING)

        def work():
            try:
                workspace, record, connection, transport = inputs
                return WindowDetails.gather(workspace, record, connection=connection, transport=transport,
                                            catalog=catalog, clock=time.time)
            except Exception:
                # Los errores de SSH pueden contener la orden/credencial: no se muestran ni copian.
                return None

        def done(details):
            if not self._available():
                return
            self.loading = False
            self.render(details or self.unchecked(saved), WindowDetails.warning(details) if details else self.FAILED,
                        failed=details is None)

        try:
            self.owner.background(work, done)
        except Exception:
            done(None)

    @staticmethod
    def unchecked(saved):
        """Una lectura fallida nunca confirma que tmux esté parado."""
        return dict(saved, reason="host_inaccesible") if saved and saved["tmux"] else saved

    def render(self, details, note, *, failed=False):
        self.details = details
        self.status.set_text(note or "")
        self.status.set_visible(bool(note))
        self.refresh_button.set_sensitive(not self.loading)
        self.refresh_button.set_label("Reintentar" if failed or (details and WindowDetails.warning(details)) else "Actualizar")
        self.spinner.set_visible(self.loading)
        if self.loading:
            self.spinner.start()
        else:
            self.spinner.stop()
        for child in self.grid.get_children():
            self.grid.remove(child)
        for index, (key, label, value) in enumerate(WindowDetails.rows(details) if details else []):
            if key == "tmux_id" and self.loading:
                value = "Sin comprobar"
            name = Gtk.Label(label=label, xalign=0, yalign=0)
            name.get_style_context().add_class("dim-label")
            self.grid.attach(name, 0, index, 1, 1)
            text = Gtk.Label(xalign=0, yalign=0, selectable=True, wrap=True, hexpand=True)
            text.set_max_width_chars(58)
            text.set_line_wrap_mode(Pango.WrapMode.WORD_CHAR)
            if key in ("socket", "session", "tmux_id", "session_id", "cwd", "command"):
                text.set_markup("<tt>" + GLib.markup_escape_text(value) + "</tt>")
            else:
                text.set_text(value)
            box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
            box.pack_start(text, False, False, 0)
            if key == "command" and WindowDetails.command_note(details):
                box.pack_start(Gtk.Label(label=WindowDetails.command_note(details), xalign=0, wrap=True), False, False, 0)
            self.grid.attach(box, 1, index, 1, 1)
        self.grid.show_all()
        # Mientras llega la lectura viva, ningún botón copia una identidad guardada que puede cambiar.
        self.copy_details_button.set_sensitive(details is not None and not self.loading)
        for button, kind in ((self.copy_id_button, "session_id"), (self.copy_command_button, "command")):
            available = details is not None and WindowDetails.copy_value(details, kind) is not None
            button.set_visible(available)
            button.set_sensitive(available and not self.loading)

    def copy(self, kind):
        if not self._available() or self.loading or self.details is None:
            return
        value = WindowDetails.copy_value(self.details, kind)
        if value is None:
            return
        try:
            publish_text(value)
        except Exception:
            self.copy_status.set_text(self.COPY_FAILED)
            return
        self.copy_status.set_text({"session_id": "ID copiado", "details": "Detalles copiados",
                                   "command": "Orden copiada"}[kind])
