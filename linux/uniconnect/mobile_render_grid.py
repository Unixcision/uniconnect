"""A bounded tmux capture adapter, not a VT stream emulator.

Input is ONLY ``capture-pane -p -e -N`` for the visible screen and optionally
the last 5000 history rows (``-S -5000``), without ``-J`` or ``-C``. tmux has
already executed cursor movement, erasure and scrolling.
We decode its remaining rendition/ACS metadata into CMUXMobileCore's existing
``cmux.render-grid.v1`` snapshot. Unknown controls are errors, not stripped text.

Requires wcwidth >= 0.2.13 with the Unicode 15.1.0 tables. Width calculation is
explicit and independent of UNICODE_VERSION in the process environment. Capture
does not preserve tmux's original cell widths, custom tab stops or dynamic OSC
palette. Tabs are refused; Unicode widths can still differ from a remote tmux.
The caller supplies the desktop palette/default colors, never an assumed theme.

Protocol references: tmux 3.2a grid.c / cmd-capture-pane.c; current grid.c also
emits OSC 8 hyperlink metadata. Hyperlink targets are never retained or opened.
"""

from dataclasses import asdict, dataclass, replace
import json
import re


MAX_CAPTURE_BYTES = 8 * 1024 * 1024
MAX_GRID_BYTES = 2 * 1024 * 1024 - 4096  # Leave room for the existing RPC envelope.
MAX_SPANS = 16384
MAX_STYLES = 1024
MAX_CONTROL_BYTES = 4096
MAX_SCROLLBACK_ROWS = 5000
UNICODE_VERSION = "15.1.0"

_CONTROL = re.compile(r"[\x00-\x1f\x7f-\x9f]")
_RGB = re.compile(r"#[0-9a-fA-F]{6}\Z")
_ACS = str.maketrans({
    "+": "→", ",": "←", "-": "↑", ".": "↓", "0": "▮", "`": "◆", "a": "▒",
    "b": "␉", "c": "␌", "d": "␍", "e": "␊", "f": "°", "g": "±", "h": "␤", "i": "␋",
    "j": "┘", "k": "┐", "l": "┌", "m": "└", "n": "┼", "o": "⎺", "p": "⎻", "q": "─",
    "r": "⎼", "s": "⎽", "t": "├", "u": "┤", "v": "┴", "w": "┬", "x": "│", "y": "≤",
    "z": "≥", "{": "π", "|": "≠", "}": "£", "~": "·",
})
_SET_FLAGS = {1: "bold", 2: "faint", 3: "italic", 4: "underline", 5: "blink", 6: "blink",
              7: "inverse", 8: "invisible", 9: "strikethrough", 21: "underline", 53: "overline"}
_CLEAR_FLAGS = {23: "italic", 24: "underline", 25: "blink", 27: "inverse", 28: "invisible",
                29: "strikethrough", 55: "overline"}


class CaptureRenderError(ValueError):
    """The capture cannot be represented safely by this snapshot adapter."""


class _CaptureBudgetError(CaptureRenderError):
    """A valid capture may fit after omitting its oldest history rows."""


@dataclass(frozen=True)
class _Style:
    foreground: str | None = None
    background: str | None = None
    bold: bool = False
    faint: bool = False
    italic: bool = False
    underline: bool = False
    blink: bool = False
    inverse: bool = False
    invisible: bool = False
    strikethrough: bool = False
    overline: bool = False


def _rgb(value):
    if not isinstance(value, str) or not _RGB.fullmatch(value):
        raise CaptureRenderError("El color de la captura no es RGB válido")
    return value.lower()


def _palette(values):
    if not isinstance(values, (list, tuple)) or len(values) not in (16, 256):
        raise CaptureRenderError("Indica la paleta del escritorio de 16 o 256 colores")
    colors = tuple(_rgb(value) for value in values)
    if len(colors) == 256:
        return colors
    # A 16-entry palette opts into the standard indexed cube and grayscale.
    levels = (0, 95, 135, 175, 215, 255)
    return colors + tuple(f"#{red:02x}{green:02x}{blue:02x}"
                          for red in levels for green in levels for blue in levels) + tuple(
        f"#{value:02x}{value:02x}{value:02x}" for value in range(8, 239, 10))


def _width_function():
    # Lazy import: an older installation can still run the desktop and report
    # an explicit unavailable snapshot instead of crashing during module import.
    try:
        import wcwidth
        version = tuple(int(value) for value in wcwidth.__version__.split(".")[:3])
        if (version < (0, 2, 13) or UNICODE_VERSION not in wcwidth.list_versions()
                or not callable(wcwidth.wcswidth)):
            raise ValueError()
    except (ImportError, AttributeError, ValueError) as error:
        raise CaptureRenderError("La captura requiere wcwidth 0.2.13 o posterior con Unicode 15.1") from error
    return lambda text: wcwidth.wcswidth(text, unicode_version=UNICODE_VERSION)


def capture_dependencies_ready():
    """Whether this installation can advertise render-grid snapshot support."""
    try:
        _width_function()
        return True
    except CaptureRenderError:
        return False


def _number(value):
    if not value or len(value) > 3 or not value.isascii() or not value.isdigit():
        raise CaptureRenderError("Parámetro de estilo no válido")
    return int(value)


def _extended_color(parts, palette):
    values = list(parts)
    if not values:
        raise CaptureRenderError("Color extendido incompleto")
    mode = _number(values[0])
    if mode == 5 and len(values) == 2:
        index = _number(values[1])
        if index <= 255:
            return palette[index]
    if mode == 2:
        # Colon SGR may include an empty or default color-space identifier.
        if len(values) == 5 and values[1] in ("", "0"):
            values.pop(1)
        if len(values) == 4:
            components = [_number(value) for value in values[1:]]
            if all(value <= 255 for value in components):
                return "#" + "".join(f"{value:02x}" for value in components)
    raise CaptureRenderError("Color extendido no admitido")


def _sgr(style, parameters, palette):
    if len(parameters) > 1024 or any(char not in "0123456789;:" for char in parameters):
        raise CaptureRenderError("Secuencia de estilo no válida")
    tokens = parameters.split(";")
    if len(tokens) > 128:
        raise CaptureRenderError("Demasiados parámetros de estilo")
    index = 0
    while index < len(tokens):
        token = tokens[index]
        index += 1
        if ":" in token:
            parts = token.split(":")
            code = _number(parts[0])
            if code == 4 and len(parts) == 2 and _number(parts[1]) <= 5:
                style = replace(style, underline=_number(parts[1]) != 0)
            elif token == "5:3":
                # Legacy tmux encodes its overline attribute using this form.
                style = replace(style, overline=True)
            elif code in (38, 48, 58):
                color = _extended_color(parts[1:], palette)
                if code != 58:  # The shared DTO has no separate underline color.
                    style = replace(style, **{"foreground" if code == 38 else "background": color})
            else:
                raise CaptureRenderError("Variante de estilo no admitida")
            continue
        code = _number(token or "0")
        if code == 0:
            style = _Style()
        elif code in _SET_FLAGS:
            style = replace(style, **{_SET_FLAGS[code]: True})
        elif code in _CLEAR_FLAGS:
            style = replace(style, **{_CLEAR_FLAGS[code]: False})
        elif code == 22:
            style = replace(style, bold=False, faint=False)
        elif code in (39, 49):
            style = replace(style, **{"foreground" if code == 39 else "background": None})
        elif 30 <= code <= 37 or 90 <= code <= 97:
            color_index = code - 30 if code < 90 else code - 90 + 8
            style = replace(style, foreground=palette[color_index])
        elif 40 <= code <= 47 or 100 <= code <= 107:
            color_index = code - 40 if code < 100 else code - 100 + 8
            style = replace(style, background=palette[color_index])
        elif code in (38, 48, 58):
            if index >= len(tokens):
                raise CaptureRenderError("Color extendido incompleto")
            count = {"5": 2, "2": 4}.get(tokens[index])
            if count is None or index + count > len(tokens):
                raise CaptureRenderError("Color extendido incompleto")
            color = _extended_color(tokens[index:index + count], palette)
            index += count
            if code != 58:
                style = replace(style, **{"foreground" if code == 38 else "background": color})
        elif code != 59:  # Reset underline color: intentionally no DTO field.
            raise CaptureRenderError("Atributo de estilo no admitido")
    return style


class _CaptureReader:
    def __init__(self, screen, columns, rows, palette, width, *, first_row=0):
        self.screen, self.columns, self.rows = screen, columns, rows
        self.first_row = first_row
        self.palette, self.width = palette, width
        self.row, self.column, self.acs = 0, 0, False
        self.style = _Style()
        self.styles = {self.style: 0}
        self.spans, self.pending = [], []

    def flush(self):
        text = "".join(self.pending)
        self.pending.clear()
        if not text:
            return
        # Skipped history still passes through the SGR/ACS state machine, but
        # never occupies the retained style registry or span/JSON budgets.
        if self.row < self.first_row:
            return
        width = self.width(text)
        if width <= 0 or self.row >= self.rows or self.column + width > self.columns:
            raise CaptureRenderError("La geometría Unicode de la captura no coincide con la cuadrícula")
        if self.style not in self.styles:
            if len(self.styles) >= MAX_STYLES:
                raise _CaptureBudgetError("La captura contiene demasiados estilos")
            self.styles[self.style] = len(self.styles)
        if len(self.spans) >= MAX_SPANS:
            raise _CaptureBudgetError("La captura contiene demasiados fragmentos")
        self.spans.append({"row": self.row, "column": self.column, "style_id": self.styles[self.style],
                           "text": text, "cell_width": width})
        self.column += width

    def escape(self, offset):
        source = self.screen
        if source.startswith("\x1b[", offset):
            end = source.find("m", offset + 2, offset + 1027)
            if end < 0:
                raise CaptureRenderError("La captura contiene una orden de terminal no admitida")
            next_style = _sgr(self.style, source[offset + 2:end], self.palette)
            if next_style != self.style:
                self.flush()
                self.style = next_style
            return end + 1
        if source.startswith("\x1b]8;", offset):
            end = offset + 4
            while end < len(source) and end - offset <= MAX_CONTROL_BYTES:
                if source[end] == "\x07" or source.startswith("\x1b\\", end):
                    payload = source[offset + 4:end]
                    if (";" not in payload or _CONTROL.search(payload)
                            or len(payload.encode("utf-8")) > MAX_CONTROL_BYTES):
                        raise CaptureRenderError("Metadatos de enlace no válidos")
                    return end + (1 if source[end] == "\x07" else 2)
                end += 1
            raise CaptureRenderError("Metadatos de enlace incompletos o excesivos")
        if source.startswith(("\x1b(0", "\x1b(B"), offset):
            self.acs = source[offset + 2] == "0"
            return offset + 3
        raise CaptureRenderError("La captura contiene una orden de terminal no admitida")

    def parse(self):
        offset = 0
        while offset < len(self.screen):
            match = _CONTROL.search(self.screen, offset)
            end = match.start() if match else len(self.screen)
            chunk = self.screen[offset:end]
            if chunk:
                self.pending.append(chunk.translate(_ACS) if self.acs else chunk)
            if not match:
                break
            control = match.group()
            offset = end + 1
            if control == "\x1b":
                offset = self.escape(end)
            elif control == "\n":
                self.flush()
                self.row += 1
                self.column = 0
                if self.row > self.rows:
                    raise CaptureRenderError("La captura supera el número de filas")
            elif control in ("\x0e", "\x0f"):
                self.acs = control == "\x0e"
            else:
                # In particular, a tab's original width is lost in capture-pane.
                # Guessing eight-column stops would corrupt subsequent columns.
                raise CaptureRenderError("La captura contiene controles o tabulaciones no representables")
        self.flush()


def render_grid_from_tmux_capture(screen, *, surface_id, columns, rows,
                                  cursor_column, cursor_row, cursor_visible, alternate_screen,
                                  revision, palette, default_foreground, default_background,
                                  scrollback_rows=0):
    """Return one full render-grid DTO without I/O, input or session mutation.

    ``palette`` is the desktop's 16 ANSI colors (plus the standard 6³/gray
    indexed colors), or all 256 explicitly resolved slots. Defaults are RGB
    ``#rrggbb`` strings. ``revision`` is supplied by the host's serialized
    snapshot publisher, not fabricated from timestamps or terminal byte counts.

    Unsupported controls, invalid geometry and resource limits raise
    ``CaptureRenderError``. No partial frame is returned. Underline variants
    retain the shared DTO's boolean underline; link targets, underline color,
    and modes other than the active screen are not represented. ``scrollback_rows``
    counts the capture's leading history lines, oldest first (at most 5000).
    They share the viewport style registry and only appear on primary FULL frames;
    switching to the alternate screen never invents alternate-screen history.
    History exceeding the existing style/span/JSON limits is reduced oldest-first;
    viewport dimensions and cursor never change. ``scrollback_rows`` in the
    returned frame is the number actually retained, not the requested maximum.
    """
    if (not isinstance(screen, str) or not isinstance(surface_id, str) or not surface_id
            or len(surface_id) > 128 or _CONTROL.search(surface_id)):
        raise CaptureRenderError("Identidad o captura no válida")
    for value in (columns, rows, cursor_column, cursor_row, revision, scrollback_rows):
        if type(value) is not int:
            raise CaptureRenderError("Las dimensiones y la revisión deben ser enteros")
    if (not 1 <= columns <= 1000 or not 1 <= rows <= 1000
            or not 0 <= cursor_column < columns or not 0 <= cursor_row < rows
            or not 0 <= revision <= 2**64 - 1
            or not 0 <= scrollback_rows <= MAX_SCROLLBACK_ROWS
            or type(cursor_visible) is not bool or type(alternate_screen) is not bool):
        raise CaptureRenderError("Dimensiones, cursor o revisión no válidos")
    try:
        surface_id.encode("utf-8")
        if len(screen.encode("utf-8")) > MAX_CAPTURE_BYTES:
            raise CaptureRenderError("La captura supera el límite permitido")
    except UnicodeEncodeError as error:
        raise CaptureRenderError("La captura no contiene Unicode válido") from error
    colors = _palette(palette)
    foreground, background = _rgb(default_foreground), _rgb(default_background)
    width = _width_function()
    def materialize(retained_rows):
        first_row = scrollback_rows - retained_rows
        reader = _CaptureReader(screen, columns, rows + scrollback_rows, colors, width, first_row=first_row)
        reader.parse()
        history_spans = [{**span, "row": span["row"] - first_row}
                         for span in reader.spans if span["row"] < scrollback_rows]
        viewport_spans = [{**span, "row": span["row"] - scrollback_rows}
                          for span in reader.spans if span["row"] >= scrollback_rows]
        frame = {"format": "cmux.render-grid.v1", "surface_id": surface_id,
                 "state_seq": revision, "revision": revision, "columns": columns, "rows": rows,
                 "cursor": {"row": cursor_row, "column": cursor_column, "visible": cursor_visible,
                            "shape": "block", "blinking": False},
                 "full": True, "cleared_rows": [], "active_screen": "alternate" if alternate_screen else "primary",
                 "styles": [{"id": identifier, **asdict(style)} for style, identifier in reader.styles.items()],
                 "row_spans": viewport_spans, "modes": [],
                 "scrollback_rows": retained_rows, "scrollback_spans": history_spans,
                 "terminal_foreground": foreground, "terminal_background": background}
        if len(json.dumps(frame, ensure_ascii=False, separators=(",", ":")).encode()) > MAX_GRID_BYTES:
            raise _CaptureBudgetError("La cuadrícula supera el límite permitido")
        return frame

    requested = 0 if alternate_screen else scrollback_rows
    try:
        return materialize(requested)
    except _CaptureBudgetError:
        if not requested:
            raise
    # Keep a known-valid viewport even if no history can fit. Bisection takes
    # at most 15 captures for 5000 rows, rather than reparsing once per old row.
    # Each attempt rebuilds only retained styles, preserving inherited SGR/ACS.
    best = materialize(0)
    lower, upper = 0, requested
    while upper - lower > 1:
        retained = (lower + upper) // 2
        try:
            candidate = materialize(retained)
        except _CaptureBudgetError:
            upper = retained
        else:
            lower, best = retained, candidate
    return best
