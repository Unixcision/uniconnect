"""«Uso por cuenta» (contracts/accounts-v1 §4.1): anillos por límite, reset, gráfica de 7 días y ritmo.

El uso es lo último que la propia IA dijo de sus límites (con su `observed_at`); el histórico es lo
que guardó el escritorio, con sus fechas. Un reset ya pasado se pinta a 0 % y un dato viejo, en ámbar.
"""

import datetime
import math
import time
from html import escape
import uuid

import gi
gi.require_version("Gtk", "3.0")
from gi.repository import Gtk

from .accounts import color_of, parse_iso

LIMIT_NAMES = {"five_hour": "5 horas", "seven_day": "Semana", "seven_day_opus": "Semana · Opus",
               "seven_day_sonnet": "Semana · Sonnet", "seven_day_fable": "Semana · Fable"}
WEEKDAYS = ("lun", "mar", "mié", "jue", "vie", "sáb", "dom")
MONTHS = ("ene", "feb", "mar", "abr", "may", "jun", "jul", "ago", "sep", "oct", "nov", "dic")
LINE_COLORS = ("#2F80ED", "#EB5757", "#27AE60", "#9B51E0", "#F2994A", "#00A3A3")
AMBER = "#C9A227"
OUTCOME_TEXT = {"reset": "Hecho: {email} vuelve a empezar.",
                "nothingToReset": "No había nada que resetear: no se ha gastado ninguno.",
                "noCredit": "Esta cuenta ya no tiene reseteos gratis.",
                "alreadyRedeemed": "Ese reseteo ya se había aplicado."}


def limit_name(limit, provider):
    if provider == "codex":
        minutes = limit.get("window_minutes")
        if minutes == 300:
            return "5 horas"
        if minutes == 10080:
            return "Semana"
        if isinstance(minutes, (int, float)) and minutes:
            return "%g h" % (minutes / 60)
    return LIMIT_NAMES.get(limit.get("id"), limit.get("id") or "?")


def span(seconds):
    """«2 d 3 h», «3 h 20 min» o «12 min»."""
    seconds = max(0, int(seconds))
    days, hours, minutes = seconds // 86400, seconds % 86400 // 3600, seconds % 3600 // 60
    if days:
        return "%d d %d h" % (days, hours)
    if hours:
        return "%d h %d min" % (hours, minutes)
    return "%d min" % max(1, minutes)


def when(epoch, *, date=False):
    """«sáb 15:00» en hora local, o «30 nov» con ``date``."""
    moment = datetime.datetime.fromtimestamp(epoch)
    if date:
        return "%d %s" % (moment.day, MONTHS[moment.month - 1])
    return "%s %s" % (WEEKDAYS[moment.weekday()], moment.strftime("%H:%M"))


def effective(limit, now):
    """El porcentaje que vale AHORA: un reset ya pasado es 0 % (sin uso nuevo visto)."""
    resets = parse_iso(limit.get("resets_at"))
    if resets is not None and resets <= now:
        return 0.0, True
    value = limit.get("used_percent")
    return (float(value) if isinstance(value, (int, float)) else 0.0), False


def pace(limit, usage, history, now):
    """§4.1, la misma fórmula en todas: (puntos/día, proyección %, agotamiento) o None."""
    resets, window = parse_iso(limit.get("resets_at")), limit.get("window_minutes")
    observed = parse_iso(usage.get("observed_at")) if usage else None
    current = limit.get("used_percent")
    if resets is None or not isinstance(window, (int, float)) or not window or observed is None \
            or not isinstance(current, (int, float)) or resets <= now:
        return None
    start = resets - window * 60
    points = [(parse_iso(sample.get("at")), (sample.get("limits") or {}).get(limit.get("id"))) for sample in history]
    points = [(at, value) for at, value in points if at is not None and at >= start and at < observed
              and isinstance(value, (int, float))]
    points = sorted(points + [(observed, float(current))])
    if len(points) < 2 or points[-1][0] - points[0][0] < 1800:
        return None
    hourly = (points[-1][1] - points[0][1]) / ((points[-1][0] - points[0][0]) / 3600)
    projection = current + hourly * max(0.0, (resets - now) / 3600)
    exhausted = now + (100 - current) / hourly * 3600 if projection >= 100 and hourly > 0 else None
    return hourly * 24, projection, exhausted


def hex_rgb(value):
    value = value.lstrip("#")
    return tuple(int(value[index:index + 2], 16) / 255 for index in (0, 2, 4))


INK = (0.2, 0.2, 0.2)


def ink_of(widget):
    """El color del texto del tema, leído de un widget ya colgado de la ventana (uno suelto no tiene tema)."""
    try:
        color = widget.get_style_context().get_color(Gtk.StateFlags.NORMAL)
        return color.red, color.green, color.blue
    except Exception:
        return INK


def cairo_image(width, height, paint):
    """Pinta con pycairo en una imagen y la devuelve como Gtk.Image.

    Sin el puente gi-cairo (python3-gi-cairo, que el MINIPC no tiene): pycairo sí está y basta.
    """
    import io
    import cairo
    from gi.repository import GdkPixbuf
    scale = 2  # Nítido en pantallas con escala.
    surface = cairo.ImageSurface(cairo.FORMAT_ARGB32, width * scale, height * scale)
    context = cairo.Context(surface)
    context.scale(scale, scale)
    paint(context, width, height)
    data = io.BytesIO()
    surface.write_to_png(data)
    loader = GdkPixbuf.PixbufLoader.new_with_type("png")
    loader.write(data.getvalue())
    loader.close()
    pixbuf = loader.get_pixbuf().scale_simple(width, height, GdkPixbuf.InterpType.BILINEAR)
    return Gtk.Image.new_from_pixbuf(pixbuf)


def Ring(percent, color, size=96, text=True, ink=INK):
    """Anillo de un límite con el porcentaje en el centro."""
    percent = max(0.0, min(100.0, percent))

    def paint(context, width, height):
        radius = min(width, height) / 2 - max(3, min(width, height) * 0.08)
        context.set_line_width(max(3, min(width, height) * 0.1))
        context.set_source_rgba(0.5, 0.5, 0.5, 0.2)
        context.arc(width / 2, height / 2, radius, 0, 2 * math.pi)
        context.stroke()
        if percent > 0:
            context.set_source_rgb(*hex_rgb(color))
            context.arc(width / 2, height / 2, radius, -math.pi / 2, -math.pi / 2 + 2 * math.pi * percent / 100)
            context.stroke()
        if text:
            label = "%d %%" % round(percent)
            context.set_source_rgb(*ink)
            context.set_font_size(min(width, height) * 0.2)
            extents = context.text_extents(label)
            context.move_to(width / 2 - extents.width / 2 - extents.x_bearing, height / 2 + extents.height / 2)
            context.show_text(label)

    return cairo_image(size, size, paint)


def Chart(series, resets, now, width=660, height=220, ink=INK):
    """Los 7 días del histórico: una línea por límite, de 0 a 100 %, con los resets marcados."""

    def paint(context, width, height):
        left, right, top, bottom = 44, 12, 10, 26
        start = now - 7 * 86400
        def x(at):
            return left + (at - start) / (7 * 86400) * (width - left - right)
        def y(value):
            return top + (1 - max(0, min(100, value)) / 100) * (height - top - bottom)
        context.set_font_size(10)
        context.set_line_width(1)
        for value in (0, 25, 50, 75, 100):
            context.set_source_rgba(0.5, 0.5, 0.5, 0.25)
            context.move_to(left, y(value))
            context.line_to(width - right, y(value))
            context.stroke()
            context.set_source_rgba(ink[0], ink[1], ink[2], 0.6)
            context.move_to(4, y(value) + 4)
            context.show_text("%d %%" % value)
        for day in range(8):
            at = start + day * 86400
            context.move_to(x(at) - 10, height - 8)
            context.show_text(WEEKDAYS[datetime.datetime.fromtimestamp(at).weekday()])
        context.set_dash([4, 4])
        for at in resets:
            if start <= at <= now:
                context.set_source_rgba(0.5, 0.5, 0.5, 0.7)
                context.move_to(x(at), top)
                context.line_to(x(at), height - bottom)
                context.stroke()
        context.set_dash([])
        context.set_line_width(2)
        for _, color, points in series:
            points = [(at, value) for at, value in points if at >= start]
            if not points:
                continue
            context.set_source_rgb(*hex_rgb(color))
            context.move_to(x(points[0][0]), y(points[0][1]))
            for at, value in points[1:]:
                context.line_to(x(at), y(value))
            context.stroke()
            for at, value in points:
                context.arc(x(at), y(value), 2.5, 0, 2 * math.pi)
                context.fill()

    return cairo_image(width, height, paint)


class UsageView(Gtk.Paned):
    """Lista lateral de cuentas (con «Resumen») y el detalle de la elegida."""

    def __init__(self, owner, *, go_to_window, reset_done):
        super().__init__(orientation=Gtk.Orientation.HORIZONTAL)
        self.owner, self._ = owner, owner._
        self.go_to_window, self.reset_done = go_to_window, reset_done
        self.response, self.accounts, self.selected = None, [], None
        self.side = Gtk.ListBox(selection_mode=Gtk.SelectionMode.SINGLE)
        self.side.connect("row-selected", self.on_selected)
        side_scroll = Gtk.ScrolledWindow(hscrollbar_policy=Gtk.PolicyType.NEVER)
        side_scroll.set_size_request(270, -1)
        side_scroll.add(self.side)
        self.pack1(side_scroll, False, False)
        self.detail = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10, margin=12)
        detail_scroll = Gtk.ScrolledWindow()
        detail_scroll.add(self.detail)
        self.pack2(detail_scroll, True, False)

    # ----- datos -----
    def set_response(self, response, provider=None):
        self.response = response
        self.accounts = [account for account in response.get("accounts", [])
                         if provider is None or account["provider"] == provider]
        keys = [None] + [account["key"] for account in self.accounts]
        if self.selected not in keys:
            self.selected = None
        for child in self.side.get_children():
            self.side.remove(child)
            child.destroy()
        self.side.add(self.side_row(None))
        for account in self.accounts:
            self.side.add(self.side_row(account))
        self.side.show_all()
        self.side.select_row(self.side.get_row_at_index(keys.index(self.selected)))
        self.show_detail()

    def hosts(self):
        return {host["host_key"]: host for host in (self.response or {}).get("hosts", [])}

    def top_limit(self, account, now):
        limits = ((account.get("usage") or {}).get("limits")) or []
        values = [effective(limit, now)[0] for limit in limits]
        return max(values) if values else None

    # ----- lista lateral -----
    def side_row(self, account):
        row = Gtk.ListBoxRow()
        row.account_key = account["key"] if account else None
        box = Gtk.Box(spacing=8, margin=6)
        if account is None:
            box.pack_start(Gtk.Label(label=self._("Resumen"), xalign=0), True, True, 0)
        else:
            top = self.top_limit(account, time.time())
            box.pack_start(Ring(top or 0, color_of(account["email"]), size=26, text=False, ink=ink_of(self.side)), False, False, 0)
            text = Gtk.Label(xalign=0)
            text.set_markup('<span foreground="%s"><b>%s</b></span>\n<small>%s%s</small>' % (
                color_of(account["email"]), escape(account["email"]), escape(account.get("display_name") or account["provider"]),
                escape(" · %d %%" % round(top)) if top is not None else ""))
            box.pack_start(text, True, True, 0)
        row.add(box)
        return row

    def on_selected(self, _, row):
        key = getattr(row, "account_key", None) if row is not None else None
        if key != self.selected:
            self.selected = key
            self.show_detail()

    # ----- detalle -----
    def clear(self):
        for child in self.detail.get_children():
            self.detail.remove(child)
            child.destroy()

    def show_detail(self):
        self.clear()
        account = next((item for item in self.accounts if item["key"] == self.selected), None)
        if account is None:
            self.summary()
        else:
            self.account_detail(account)
        self.detail.show_all()

    def label(self, markup, *, css=None, wrap=True):
        widget = Gtk.Label(xalign=0, wrap=wrap)
        widget.set_markup(markup)
        if css:
            widget.get_style_context().add_class(css)
        return widget

    def summary(self):
        self.detail.pack_start(self.label("<big><b>%s</b></big>" % escape(self._("Resumen"))), False, False, 0)
        if not self.accounts:
            self.detail.pack_start(self.label(escape(self._("Ninguna cuenta con sesión en esta lectura."))), False, False, 0)
            return
        grid = Gtk.FlowBox(selection_mode=Gtk.SelectionMode.NONE, min_children_per_line=1, max_children_per_line=4,
                           row_spacing=10, column_spacing=10, homogeneous=True)
        now = time.time()
        for account in self.accounts:
            card = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4, margin=8)
            top = self.top_limit(account, now)
            card.pack_start(Ring(top or 0, color_of(account["email"]), size=72, text=top is not None, ink=ink_of(self.detail)),
                            False, False, 0)
            card.pack_start(self.label('<span foreground="%s"><b>%s</b></span>' % (
                color_of(account["email"]), escape(account["email"]))), False, False, 0)
            card.pack_start(self.label("<small>%s</small>" % escape(self.where_text(account))), False, False, 0)
            next_reset = self.next_reset(account, now)
            if next_reset:
                card.pack_start(self.label("<small>%s</small>" % escape(next_reset)), False, False, 0)
            button = Gtk.Button(relief=Gtk.ReliefStyle.NONE)
            button.add(card)
            button.connect("clicked", lambda _, key=account["key"]: self.select(key))
            frame = Gtk.Frame()
            frame.add(button)
            grid.add(frame)
        self.detail.pack_start(grid, False, False, 0)

    def select(self, key):
        keys = [None] + [account["key"] for account in self.accounts]
        self.side.select_row(self.side.get_row_at_index(keys.index(key)))

    def where_text(self, account):
        name = account.get("display_name") or account["provider"]
        windows = self._("1 ventana") if account["windows"] == 1 else self._("{n} ventanas").format(n=account["windows"])
        hosts = len(account.get("host_keys", []))
        return "%s · %s · %s" % (name, windows, self._("1 host") if hosts == 1 else self._("{m} hosts").format(m=hosts))

    def next_reset(self, account, now):
        times = [parse_iso(limit.get("resets_at")) for limit in ((account.get("usage") or {}).get("limits") or [])]
        times = [at for at in times if at and at > now]
        return self._("Resetea en {span} · {when}").format(span=span(min(times) - now), when=when(min(times))) if times else None

    def account_detail(self, account):
        now, color = time.time(), color_of(account["email"])
        usage = account.get("usage")
        hosts = self.hosts()
        heading = Gtk.Box(spacing=10)
        heading.pack_start(self.label('<span size="x-large" foreground="%s"><b>%s</b></span>' % (
            color, escape(account["email"])), wrap=False), False, False, 0)
        heading.pack_start(self.label(escape(account.get("display_name") or account["provider"]), css="uc-accounts-badge",
                                      wrap=False), False, False, 0)
        if account.get("plan"):
            heading.pack_start(self.label(escape(account["plan"]), css="uc-accounts-plan", wrap=False), False, False, 0)
        self.detail.pack_start(heading, False, False, 0)
        self.detail.pack_start(self.label(escape(self.where_text(account))), False, False, 0)
        credits = (usage or {}).get("reset_credits") or {}
        if account["provider"] == "codex" and isinstance(credits.get("available"), int) and credits["available"] > 0:
            line = Gtk.Box(spacing=10)
            text = self._("1 reseteo gratis disponible") if credits["available"] == 1 else \
                self._("{n} reseteos gratis disponibles").format(n=credits["available"])
            expires = parse_iso(credits.get("next_expires_at"))
            if expires:
                text += " · " + self._("el primero caduca el {date}").format(date=when(expires, date=True))
            line.pack_start(self.label(escape(text)), False, False, 0)
            button = Gtk.Button(label=self._("Usar un reseteo gratis"))
            button.connect("clicked", lambda *_: self.confirm_reset(account, credits["available"]))
            line.pack_start(button, False, False, 0)
            self.detail.pack_start(line, False, False, 0)
        if not usage or not usage.get("limits"):
            hint = (self._("aparecen en cuanto esta cuenta trabaje en una ventana con la barra de estado de UniConnect")
                    if account["provider"] == "claude" else self._("en cuanto Codex haga una petición"))
            self.detail.pack_start(self.label("<b>%s</b>\n%s" % (escape(self._("Sin datos de uso todavía")), escape(hint))),
                                   False, False, 0)
        else:
            cards = Gtk.FlowBox(selection_mode=Gtk.SelectionMode.NONE, min_children_per_line=1, max_children_per_line=3,
                                row_spacing=10, column_spacing=10)
            for limit in usage["limits"]:
                cards.add(self.limit_card(account, usage, limit, now, hosts))
            self.detail.pack_start(cards, False, False, 0)
            self.detail.pack_start(self.label("<b>%s</b>" % escape(self._("Últimos 7 días"))), False, False, 0)
            self.detail.pack_start(self.chart(account, usage, now), False, False, 0)
        self.detail.pack_start(self.label("<b>%s</b>" % escape(self._("Dónde está"))), False, False, 0)
        for item in (self.response or {}).get("windows", []):
            if item["state"] == "ok" and (item.get("agent") or {}).get("provider") == account["provider"] \
                    and ((item.get("account") or {}).get("email") or "").lower() == account["email"]:
                link = Gtk.LinkButton(label="%s · %s · %s" % (item.get("workspace") or "", item.get("window") or "",
                                                              hosts.get(item["host_key"], {}).get("label") or item["host_key"]),
                                      uri="uniconnect:ventana", halign=Gtk.Align.START)
                link.connect("activate-link", lambda _, item=item: (self.go_to_window(item, account["email"]), True)[1])
                self.detail.pack_start(link, False, False, 0)

    def limit_card(self, account, usage, limit, now, hosts):
        percent, reset_passed = effective(limit, now)
        card = Gtk.Box(spacing=12, margin=10)
        card.pack_start(Ring(percent, color_of(account["email"]), ink=ink_of(self.detail)), False, False, 0)
        text = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
        text.pack_start(self.label("<b>%s</b>" % escape(self._(limit_name(limit, account["provider"])))), False, False, 0)
        resets = parse_iso(limit.get("resets_at"))
        if reset_passed:
            text.pack_start(self.label(escape(self._("Reseteado el {date} · sin uso nuevo visto").format(
                date=when(resets, date=True) + " " + when(resets)[4:]))), False, False, 0)
        elif resets:
            text.pack_start(self.label(escape(self._("Resetea en {span} · {when}").format(
                span=span(resets - now), when=when(resets)))), False, False, 0)
        observed = parse_iso(usage.get("observed_at"))
        if observed is not None:
            age = now - observed
            place = hosts.get(usage.get("host_key"), {}).get("label") or usage.get("host_key") or ""
            if age > 3600:
                text.pack_start(self.label('<span foreground="%s">%s</span>' % (AMBER, escape(
                    self._("Dato de hace {span}").format(span=span(age)) + " · " + place))), False, False, 0)
            else:
                text.pack_start(self.label(escape(self._("Visto hace {span} en {place}").format(span=span(age), place=place))),
                                False, False, 0)
        result = None if reset_passed else pace(limit, usage, account.get("history") or [], now)
        if result:
            daily, projection, exhausted = result
            text.pack_start(self.label(escape(self._("Ritmo: {sign}{value:.1f} puntos por día").format(
                sign="+" if daily >= 0 else "", value=daily))), False, False, 0)
            message = (self._("Se agotaría el {when}").format(when=when(exhausted)) if exhausted else
                       self._("A este ritmo, llegarás al {value} % antes del reset").format(value=round(max(0, projection))))
            text.pack_start(self.label(escape(message)), False, False, 0)
        card.pack_start(text, True, True, 0)
        frame = Gtk.Frame()
        frame.add(card)
        frame.set_size_request(340, -1)  # Anchas, sin cortar líneas.
        return frame

    def chart(self, account, usage, now):
        series, resets = [], []
        for index, limit in enumerate(usage.get("limits") or []):
            points = []
            for sample in account.get("history") or []:
                value = (sample.get("limits") or {}).get(limit.get("id"))
                at = parse_iso(sample.get("at"))
                if at is not None and isinstance(value, (int, float)):
                    points.append((at, float(value)))
            observed = parse_iso(usage.get("observed_at"))
            if observed is not None and isinstance(limit.get("used_percent"), (int, float)):
                points.append((observed, float(limit["used_percent"])))
            series.append((limit_name(limit, account["provider"]), LINE_COLORS[index % len(LINE_COLORS)], sorted(points)))
            # El reset marcado: el comienzo de la ventana actual de cada límite (no cada 5 h de la semana).
            reset, window = parse_iso(limit.get("resets_at")), limit.get("window_minutes")
            if reset and isinstance(window, (int, float)) and window:
                resets.append(reset - window * 60 if reset > now else reset)
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
        box.pack_start(Chart(series, resets, now, ink=ink_of(self.detail)), False, False, 0)
        legend = Gtk.Box(spacing=12)
        for name, color, _ in series:
            legend.pack_start(self.label('<span foreground="%s">●</span> %s' % (color, escape(self._(name))), wrap=False),
                              False, False, 0)
        legend.pack_start(self.label("<small>%s</small>" % escape(self._("discontinuas: resets")), wrap=False), False, False, 0)
        box.pack_start(legend, False, False, 0)
        return box

    # ----- §5 reseteo gratis de Codex -----
    def confirm_reset(self, account, available):
        dialog = Gtk.MessageDialog(transient_for=self.get_toplevel(), modal=True, message_type=Gtk.MessageType.QUESTION,
                                   buttons=Gtk.ButtonsType.NONE, text=self._("Usar un reseteo gratis"))
        dialog.format_secondary_text(self._(
            "¿Gastar 1 de {n} reseteos gratis de {email}? Los límites de Codex de esta cuenta vuelven a 0 %. "
            "No se puede deshacer.").format(n=available, email=account["email"]))
        dialog.add_buttons(self._("Cancelar"), Gtk.ResponseType.CANCEL, self._("Gastar reseteo"), Gtk.ResponseType.OK)
        accepted = dialog.run() == Gtk.ResponseType.OK
        dialog.destroy()
        if not accepted:
            return
        host_key = (account.get("usage") or {}).get("host_key") or account["host_keys"][0]
        key = str(uuid.uuid4())  # Una vez por confirmación; un reintento reutiliza la misma.
        from .accounts import AccountsReader
        boxes = AccountsReader.snapshot(self.owner)

        def work():
            try:
                return self.owner.accounts_reader.codex_reset(boxes, account["key"], host_key, key)
            except Exception as error:
                return error

        def done(result):
            if isinstance(result, Exception):
                text = getattr(result, "message", None) or str(result)
            else:
                text = self._(OUTCOME_TEXT.get(result.get("outcome"), "{outcome}")).format(
                    email=account["email"], outcome=result.get("outcome"))
            message = Gtk.MessageDialog(transient_for=self.get_toplevel(), modal=True, message_type=Gtk.MessageType.INFO,
                                        buttons=Gtk.ButtonsType.CLOSE, text=text)
            message.run()
            message.destroy()
            self.reset_done()

        self.owner.background(work, done)
