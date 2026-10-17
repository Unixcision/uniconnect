"""Local, read-only history selection; scrolling never sends SSH commands."""

import threading

from gi.repository import Gdk, GLib, GObject, Gtk, Pango

from .clipboard_text import publish_text
from .terminal_history import TerminalHistory
from .transport import TransportError


class HistoryView(Gtk.Window):
    def __init__(self, surface, transport, record):
        super().__init__(title=surface.owner._('Historial para copiar'))
        self.surface, self.transport, self.record = surface, transport, dict(record)
        self._ = surface.owner._
        self.ready = self.closed = self.loading = False
        self.set_default_size(950, 650)
        parent = surface.get_toplevel()
        if isinstance(parent, Gtk.Window):
            self.set_transient_for(parent)
            self.set_destroy_with_parent(True)
        self.connect('destroy', self._destroyed)
        self.connect('key-press-event', self._key)
        layout = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8, margin=10)
        self.add(layout)
        title = Gtk.Label(label=record.get('name', ''), xalign=0)
        layout.pack_start(title, False, False, 0)
        self.message = Gtk.Label(xalign=0, wrap=True)
        layout.pack_start(self.message, False, False, 0)
        self.search = Gtk.SearchEntry()
        self.search.set_placeholder_text(self._('Buscar en el historial'))
        self.search.connect('activate', self._find)
        layout.pack_start(self.search, False, False, 0)
        self.scroller = Gtk.ScrolledWindow()
        self.text = Gtk.TextView(editable=False, cursor_visible=True, monospace=True,
                                 wrap_mode=Gtk.WrapMode.WORD_CHAR, left_margin=8, right_margin=8)
        self.text.override_font(Pango.FontDescription(surface.owner.store.data.get('settings', {}).get('font', 'Monospace 11')))
        # The local selection is intentionally blue, distinct from tmux mode.
        provider = Gtk.CssProvider()
        provider.load_from_data(b'textview text selection { background-color: #3584e4; color: white; }')
        self.text.get_style_context().add_provider(provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION + 1)
        self.text.connect('copy-clipboard', self._copy_signal)
        self.text.add_events(Gdk.EventMask.BUTTON_PRESS_MASK | Gdk.EventMask.BUTTON_RELEASE_MASK |
                             Gdk.EventMask.POINTER_MOTION_MASK)
        self.text.connect('button-press-event', self._history_button_press)
        self.text.connect('motion-notify-event', self._history_motion)
        self.text.connect('button-release-event', self._history_button_release)
        self._history_drag_mark = None
        self._history_drag_pointer = None
        self._history_drag_timer = None
        self.scroller.add(self.text)
        layout.pack_start(self.scroller, True, True, 0)
        buttons = Gtk.Box(spacing=8)
        for label, callback in (('Copy', self.copy), ('Actualizar historial', self.load), ('Volver al terminal', self.destroy)):
            button = Gtk.Button(label=self._(label))
            button.connect('clicked', lambda _, callback=callback: callback())
            buttons.pack_start(button, False, False, 0)
        layout.pack_start(buttons, False, False, 0)
        self.show_all()
        self.load()

    def load(self):
        if self.loading or self.closed:
            return
        self.loading = True
        self.message.set_text(self._('Cargando historial… Puedes cerrar esta ventana sin interrumpir la sesión.'))
        def work():
            value = error = None
            try:
                value = TerminalHistory(self.transport).capture(self.record)
            except Exception as caught:
                error = caught
            GLib.idle_add(self._loaded, value, error)
        threading.Thread(target=work, name='uniconnect-history', daemon=True).start()

    def _loaded(self, value, error):
        self.loading = False
        if self.closed or self.surface.disposed:
            return False
        if error:
            message = error.code if isinstance(error, TransportError) and error.code.startswith(('El historial', 'No se pudo leer')) else 'No se pudo leer el historial. Puedes seguir usando el terminal.'
            self.message.set_text(self._(message))
            return False
        buffer = self.text.get_buffer()
        buffer.set_text(value)
        end = buffer.get_end_iter()
        buffer.place_cursor(end)
        self.text.scroll_to_iter(end, 0, True, 0, 1)
        GLib.idle_add(self._scroll_to_end)
        self.ready = True
        self.message.set_text(self._('Selecciona arrastrando, también fuera del borde. Copia con Ctrl+C o el botón Copiar. La sesión sigue activa.'))
        self.text.grab_focus()
        return False

    def _scroll_to_end(self):
        if self.closed:
            return False
        adjustment = self.scroller.get_vadjustment()
        adjustment.set_value(max(adjustment.get_lower(),
                                 adjustment.get_upper() - adjustment.get_page_size()))
        return False

    def _history_button_press(self, _widget, event):
        if event.button == 1:
            x, y = self.text.window_to_buffer_coords(Gtk.TextWindowType.TEXT,
                                                     int(event.x), int(event.y))
            buffer = self.text.get_buffer()
            self._history_drag_mark = buffer.create_mark(None, buffer.get_iter_at_location(x, y), True)
            self._history_drag_pointer = (event.x, event.y)
        return False

    def _history_motion(self, _widget, event):
        if (self._history_drag_mark is not None
                and event.state & Gdk.ModifierType.BUTTON1_MASK):
            self._history_drag_pointer = (event.x, event.y)
            text_window = self.text.get_window(Gtk.TextWindowType.TEXT)
            x, y = self._history_drag_pointer
            if y < 0 or y >= text_window.get_height():
                if self._history_drag_timer is None:
                    self._history_drag_timer = GLib.timeout_add(40, self._history_edge_scroll)
        return False

    def _history_button_release(self, _widget, event):
        if event.button == 1:
            self._stop_history_edge_scroll()
            self._clear_history_drag()
        return False

    def _history_edge_scroll(self):
        if self.closed or self._history_drag_mark is None or self._history_drag_pointer is None:
            self._history_drag_timer = None
            return False
        x, y = self._history_drag_pointer
        text_window = self.text.get_window(Gtk.TextWindowType.TEXT)
        height = text_window.get_height()
        if 0 <= y < height:
            self._history_drag_timer = None
            return False
        adjustment = self.scroller.get_vadjustment()
        line_height = max(1, self.text.create_pango_layout('M').get_pixel_size()[1])
        distance = -y if y < 0 else y - height + 1
        lines = min(8, max(1, distance // line_height + 1))
        direction = -1 if y < 0 else 1
        adjustment.set_value(adjustment.get_value() + direction * line_height * lines)
        visible = self.text.get_visible_rect()
        width = text_window.get_width()
        buffer_x, _ = self.text.window_to_buffer_coords(
            Gtk.TextWindowType.TEXT, min(max(int(x), 0), max(0, width - 1)), 0)
        buffer_y = visible.y if y < 0 else visible.y + visible.height - 1
        current = self.text.get_iter_at_location(buffer_x, buffer_y)
        self.text.get_buffer().select_range(current, self.text.get_buffer().get_iter_at_mark(
            self._history_drag_mark))
        return True

    def _stop_history_edge_scroll(self):
        if self._history_drag_timer is not None:
            GLib.source_remove(self._history_drag_timer)
            self._history_drag_timer = None

    def _clear_history_drag(self):
        if self._history_drag_mark is not None:
            self.text.get_buffer().delete_mark(self._history_drag_mark)
            self._history_drag_mark = None
        self._history_drag_pointer = None

    def _copy_signal(self, widget):
        GObject.signal_stop_emission_by_name(widget, 'copy-clipboard')
        self.copy()

    def copy(self):
        bounds = self.text.get_buffer().get_selection_bounds()
        if not bounds:
            self.message.set_text(self._('Selecciona texto antes de copiar.'))
            return
        value = self.text.get_buffer().get_text(*bounds, False)
        publish_text(value)
        self.message.set_text(self._('Copiado. Si RealVNC no lo transfiere, divide la selección: su límite documentado es 256 KiB.')
                              if len(value.encode('utf-8')) > 256 * 1024 else self._('Copiado al portapapeles.'))

    def _key(self, _, event):
        if event.keyval == Gdk.KEY_Escape:
            self.destroy()
            return True
        action = getattr(self.surface.owner, 'action_map', {}).get('copy')
        if action:
            custom = self.surface.owner.store.data.get('settings', {}).get('shortcuts', {})
            key, modifiers = Gtk.accelerator_parse(custom.get('copy', action.shortcut))
            if key and Gdk.keyval_to_lower(event.keyval) == Gdk.keyval_to_lower(key) and event.state & Gtk.accelerator_get_default_mod_mask() == modifiers:
                self.copy()
                return True
        return False

    def _find(self, *_):
        query = self.search.get_text()
        if not query:
            return
        buffer = self.text.get_buffer()
        start = buffer.get_iter_at_mark(buffer.get_insert())
        match = start.forward_search(query, Gtk.TextSearchFlags.CASE_INSENSITIVE, None)
        if not match:
            match = buffer.get_start_iter().forward_search(query, Gtk.TextSearchFlags.CASE_INSENSITIVE, None)
        if match:
            buffer.select_range(match[1], match[0])
            self.text.scroll_to_iter(match[0], .1, False, 0, 0)

    def _destroyed(self, *_):
        self.closed = True
        self._stop_history_edge_scroll()
        self._clear_history_drag()
        self.text.get_buffer().set_text('')
        if self.surface.history_view is self:
            self.surface.history_view = None
        if not self.surface.disposed:
            self.surface.terminal.grab_focus()
