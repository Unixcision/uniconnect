"""«Cuentas de IA» (contracts/accounts-v1, §4): una ventana aparte, grande, leída en vivo.

Con qué cuenta está cada IA, por espacio o por cuenta, con fichas por email para filtrar. Se lee
al abrir, con «Actualizar» y cada 15 s solo mientras está visible. Nunca enseña una cuenta vieja:
lo que no se pudo leer en esta lectura sale como tal.
"""

import json
import time
from html import escape

import gi
gi.require_version("Gtk", "3.0")
from gi.repository import GLib, Gtk

from .accounts import NO_AI, UNREAD, AccountsReader, color_of
from .accounts_usage import UsageView
from .vault import atomic_write, private_read

STATE_TEXT = {"sin_sesion": "Sin sesión", "desconocida": "Cuenta no expuesta", "host_inaccesible": "Host sin respuesta",
              "sin_ia": "Sin IA", "sesion_no_viva": "La sesión tmux no está viva", "sin_tmux": "Sin tmux",
              "identidad_ambigua": "Identidad ambigua", "panel_muerto": "Panel muerto"}
HOST_ERROR_TEXT = {"sin_respuesta": "no contestó a tiempo", "sin_python3": "no tiene python3",
                   "ssh_fallo": "falló la conexión SSH", "salida_no_valida": "respondió algo que no es la sonda",
                   "tmux_no_disponible": "no tiene tmux", "tmux_fallo": "tmux dio un error"}
METHOD_TEXT = {"api_key": "Clave de API", "bedrock": "Bedrock", "vertex": "Vertex", "foundry": "Foundry"}
CSS = b"""
.uc-accounts-chip { border-radius: 14px; padding: 2px 10px; }
.uc-accounts-group { font-weight: bold; margin-top: 10px; }
.uc-accounts-email { font-size: 13pt; font-weight: bold; }
.uc-accounts-plan { border-radius: 9px; padding: 0 8px; background: alpha(currentColor, 0.12); font-size: 9pt; }
.uc-accounts-badge { border-radius: 4px; padding: 0 6px; background: alpha(currentColor, 0.08); font-size: 9pt; }
.uc-accounts-warning { color: #C9A227; }
"""


class AccountsWindow(Gtk.Window):
    REFRESH_SECONDS = 15

    def __init__(self, owner):
        super().__init__(title=owner._("Cuentas de IA"))
        self.owner, self._ = owner, owner._
        self.response, self.reading, self.closed = None, False, False
        self.filter, self.mode, self.show_no_ai, self.provider = ("all",), "workspace", False, None
        self.geometry_path = owner.store.root / "accounts-window.json"
        self.set_default_size(1040, 720)
        self.set_size_request(760, 520)
        self.restore_geometry()
        provider = Gtk.CssProvider()
        provider.load_from_data(CSS)
        Gtk.StyleContext.add_provider_for_screen(self.get_screen(), provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)

        header = Gtk.HeaderBar(show_close_button=True, title=self._("Cuentas de IA"))
        self.set_titlebar(header)
        self.spinner = Gtk.Spinner()
        refresh = Gtk.Button(label=self._("Actualizar"))
        refresh.connect("clicked", lambda *_: self.refresh())
        header.pack_start(refresh)
        header.pack_start(self.spinner)
        above = Gtk.Switch(valign=Gtk.Align.CENTER)
        above.connect("notify::active", lambda switch, _: self.set_keep_above(switch.get_active()))
        header.pack_end(above)
        header.pack_end(Gtk.Label(label=self._("Siempre delante")))
        self.header = header

        outer = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8, margin=12)
        self.stack = Gtk.Stack(transition_type=Gtk.StackTransitionType.CROSSFADE)
        switcher = Gtk.StackSwitcher(stack=self.stack, halign=Gtk.Align.CENTER)
        outer.pack_start(switcher, False, False, 0)
        body = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        providers = Gtk.Box(spacing=8)
        providers.pack_start(Gtk.Label(label=self._("IA:")), False, False, 0)
        self.provider_chips = Gtk.FlowBox(selection_mode=Gtk.SelectionMode.NONE, max_children_per_line=12,
                                          row_spacing=4, column_spacing=4, hexpand=True)
        providers.pack_start(self.provider_chips, True, True, 0)
        outer.pack_start(providers, False, False, 0)  # La IA elegida vale para las dos vistas.
        filters = Gtk.Box(spacing=8)
        self.chips = Gtk.FlowBox(selection_mode=Gtk.SelectionMode.NONE, max_children_per_line=12, row_spacing=4,
                                 column_spacing=4, hexpand=True)
        filters.pack_start(self.chips, True, True, 0)
        self.search = Gtk.SearchEntry(placeholder_text=self._("Buscar espacio, ventana, email, host o usuario"),
                                      width_chars=34, valign=Gtk.Align.START)
        self.search.connect("search-changed", lambda *_: self.render())
        filters.pack_end(self.search, False, False, 0)
        body.pack_start(filters, False, False, 0)

        grouping = Gtk.Box(spacing=12)
        by_space = Gtk.RadioButton.new_with_label(None, self._("Por espacio"))
        by_account = Gtk.RadioButton.new_with_label_from_widget(by_space, self._("Por cuenta"))
        by_ai = Gtk.RadioButton.new_with_label_from_widget(by_space, self._("Por IA"))
        by_space.connect("toggled", lambda button: button.get_active() and self.set_mode("workspace"))
        by_account.connect("toggled", lambda button: button.get_active() and self.set_mode("account"))
        by_ai.connect("toggled", lambda button: button.get_active() and self.set_mode("provider"))
        no_ai = Gtk.Switch(valign=Gtk.Align.CENTER)
        no_ai.connect("notify::active", lambda switch, _: self.set_no_ai(switch.get_active()))
        for widget in (by_space, by_account, by_ai, Gtk.Label(label="  "), Gtk.Label(label=self._("Ventanas sin IA")), no_ai):
            grouping.pack_start(widget, False, False, 0)
        body.pack_start(grouping, False, False, 0)

        self.warnings = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=2)
        body.pack_start(self.warnings, False, False, 0)
        self.rows = Gtk.ListBox(selection_mode=Gtk.SelectionMode.NONE)
        scroll = Gtk.ScrolledWindow(vexpand=True)
        scroll.add(self.rows)
        body.pack_start(scroll, True, True, 0)
        self.usage = UsageView(owner, go_to_window=self.go_to_window, reset_done=self.refresh)
        self.stack.add_titled(body, "ventanas", self._("Ventanas"))
        self.stack.add_titled(self.usage, "uso", self._("Uso por cuenta"))
        outer.pack_start(self.stack, True, True, 0)
        self.add(outer)

        self.connect("configure-event", self.remember_geometry)
        self.connect("destroy", self.on_destroy)
        GLib.timeout_add_seconds(1, self.tick)
        GLib.timeout_add_seconds(self.REFRESH_SECONDS, self.periodic)
        self.show_all()
        self.refresh()

    # ----- posición -----
    def restore_geometry(self):
        try:
            value = json.loads(private_read(self.geometry_path, maximum=4096))
            width, height = max(760, int(value["width"])), max(520, int(value["height"]))
            self.resize(width, height)
            self.move(int(value["x"]), int(value["y"]))
        except (OSError, ValueError, KeyError, TypeError):
            pass

    def remember_geometry(self, *_):
        x, y = self.get_position()
        width, height = self.get_size()
        self.pending_geometry = {"x": x, "y": y, "width": width, "height": height}
        if not getattr(self, "geometry_timer", None):
            self.geometry_timer = GLib.timeout_add(600, self.save_geometry)
        return False

    def save_geometry(self):
        self.geometry_timer = None
        try:
            atomic_write(self.geometry_path, json.dumps(self.pending_geometry).encode())
        except OSError:
            pass
        return False

    def on_destroy(self, *_):
        self.closed = True
        if getattr(self, "pending_geometry", None):
            self.save_geometry()
        if getattr(self.owner, "accounts_window", None) is self:
            self.owner.accounts_window = None

    # ----- lectura -----
    def visible(self):
        window = self.get_window()
        return bool(self.get_mapped() and window and not (window.get_state() & 2))  # 2 = ICONIFIED

    def periodic(self):
        if self.closed:
            return False
        if self.visible():
            self.refresh()
        return True

    def refresh(self):
        if self.reading or self.closed:
            return
        if self.owner.locked:
            self.show_message(self._("UniConnect está bloqueado."))
            return
        boxes = AccountsReader.snapshot(self.owner)
        self.reading = True
        self.spinner.start()
        def read():
            try:
                return self.owner.accounts_reader.read(boxes)
            except Exception as error:  # Nunca un diálogo de error cada 15 s: va en la cabecera.
                return error
        self.owner.background(read, self.loaded)

    def loaded(self, response):
        self.reading = False
        self.spinner.stop()
        if self.closed:
            return
        if isinstance(response, Exception) or not isinstance(response, dict):
            self.show_message(self._("No se pudieron leer las cuentas: {error}").format(error=response))
            return
        self.response, self.loaded_at = response, time.time()
        self.render()
        self.usage.set_response(response, self.provider)
        self.tick()

    def tick(self):
        if self.closed:
            return False
        if self.response:
            seconds = max(0, int(time.time() - getattr(self, "loaded_at", time.time())))
            self.header.set_subtitle(self._("Leído en vivo hace {n} s").format(n=seconds))
        return True

    def show_message(self, text):
        self.header.set_subtitle(text)

    # ----- filtros -----
    def set_mode(self, mode):
        self.mode = mode
        self.render()

    def set_no_ai(self, value):
        self.show_no_ai = value
        self.render()

    def choose(self, value):
        self.filter = value
        self.render()

    def choose_provider(self, provider):
        """§4.2: al cambiar de IA, la ficha de cuenta vuelve a «Todas» (y «Uso por cuenta», solo esas)."""
        self.provider, self.filter = provider, ("all",)
        self.render()
        if self.response:
            self.usage.set_response(self.response, self.provider)

    def go_to_window(self, item, email):
        """«Dónde está» → esa ventana en la pestaña «Ventanas»."""
        self.stack.set_visible_child_name("ventanas")
        self.filter = ("email", email)
        self.search.set_text(item.get("window") or "")
        self.render()

    def candidates(self, *, any_provider=False):
        windows = self.response["windows"] if self.response else []
        return [item for item in windows if (self.show_no_ai or item["state"] not in NO_AI)
                and (any_provider or self.provider is None or (item.get("agent") or {}).get("provider") == self.provider)]

    def matches(self, item, hosts):
        account = item.get("account") or {}
        if self.filter[0] == "email" and (account.get("email") or "").lower() != self.filter[1]:
            return False
        if self.filter[0] == "sin_sesion" and item["state"] != "sin_sesion":
            return False
        if self.filter[0] == "sin_leer" and item["state"] not in UNREAD:
            return False
        text = self.search.get_text().strip().lower()
        if text:
            haystack = " ".join(str(value or "") for value in (
                item.get("workspace"), item.get("window"), account.get("email"), item.get("host_key"),
                hosts.get(item.get("host_key"), {}).get("label"), account.get("os_user"))).lower()
            return text in haystack
        return True

    # ----- pintar -----
    def chip(self, label, value, color=None, *, into=None, active=None, choose=None):
        button = Gtk.ToggleButton()
        button.get_style_context().add_class("uc-accounts-chip")
        markup = ('<span foreground="%s">●</span> ' % color if color else "") + escape(label)
        text = Gtk.Label()
        text.set_markup(markup)
        button.add(text)
        button.set_active(self.filter == value if active is None else active)
        button.connect("toggled", lambda widget: widget.get_active() and (choose or self.choose)(value))
        (into or self.chips).add(button)

    def render(self):
        for container in (self.provider_chips, self.chips, self.warnings, self.rows):
            for child in container.get_children():
                container.remove(child)
                child.destroy()
        if not self.response:
            return
        hosts = {host["host_key"]: host for host in self.response["hosts"]}
        # §4.2: una ficha por cada IA que HAYA en esta lectura (sin lista fija), de más a menos ventanas.
        everything = self.candidates(any_provider=True)
        providers = {}
        for item in everything:
            agent = item.get("agent") or {}
            if agent.get("provider"):
                name, count = providers.get(agent["provider"], (agent.get("display_name") or agent["provider"], 0))
                providers[agent["provider"]] = (name, count + 1)
        if self.provider is not None and self.provider not in providers:
            self.provider = None
        self.chip(self._("Todas las IA · {n}").format(n=len(everything)), None, into=self.provider_chips,
                  active=self.provider is None, choose=self.choose_provider)
        for provider, (name, count) in sorted(providers.items(), key=lambda pair: (-pair[1][1], pair[1][0])):
            self.chip("%s · %d" % (name, count), provider, into=self.provider_chips, active=self.provider == provider,
                      choose=self.choose_provider)
        candidates = self.candidates()
        emails = {}
        for item in candidates:
            email = ((item.get("account") or {}).get("email") or "").lower()
            if item["state"] == "ok" and email:
                emails[email] = emails.get(email, 0) + 1
        if self.filter[0] == "email" and self.filter[1] not in emails:
            self.filter = ("all",)
        self.chip(self._("Todas · {n}").format(n=len(candidates)), ("all",))
        for email, count in sorted(emails.items(), key=lambda pair: (-pair[1], pair[0])):
            self.chip("%s · %d" % (email, count), ("email", email), color_of(email))
        self.chip(self._("Sin sesión · {n}").format(n=sum(item["state"] == "sin_sesion" for item in candidates)),
                  ("sin_sesion",))
        self.chip(self._("Sin leer · {n}").format(n=sum(item["state"] in UNREAD for item in candidates)), ("sin_leer",))

        for host in self.response["hosts"]:
            if host["state"] != "ok":
                reason = (self._("la bóveda está cerrada") if host["state"] == "boveda_cerrada" else
                          self._(HOST_ERROR_TEXT.get(host.get("error"), "no contestó")))
                if host.get("error_detail"):
                    reason += " · " + host["error_detail"]
                warning = Gtk.Label(label=self._("No se pudo leer {host}: {reason}").format(host=host["label"], reason=reason),
                                    xalign=0, selectable=True, wrap=True)
                warning.get_style_context().add_class("uc-accounts-warning")
                self.warnings.pack_start(warning, False, False, 0)

        shown = [item for item in candidates if self.matches(item, hosts)]
        groups = {}
        for item in shown:
            if self.mode == "provider":
                agent = item.get("agent") or {}
                key = agent.get("provider") or "~"
            elif self.mode == "account":
                account = item.get("account") or {}
                key = (account.get("email") or "").lower() if item["state"] == "ok" and account.get("email") else (
                    "~" + (self._("Sin sesión") if item["state"] == "sin_sesion" else
                           self._("Sin IA") if item["state"] in NO_AI else self._("Sin leer")))
            else:
                key = item["workspace_id"]
            groups.setdefault(key, []).append(item)
        order = (sorted(groups, key=lambda key: (key.startswith("~"), -len(groups[key]), key))
                 if self.mode in ("account", "provider") else list(groups))
        for key in order:
            self.rows.add(self.group_header(key, groups[key], hosts))
            for item in groups[key]:
                self.rows.add(self.window_row(item, hosts))
        if not shown:
            empty = Gtk.Label(label=self._("Ninguna ventana con este filtro."), margin=24)
            empty.get_style_context().add_class("dim-label")
            self.rows.add(empty)
        self.provider_chips.show_all()
        self.chips.show_all()
        self.warnings.show_all()
        self.rows.show_all()

    def group_header(self, key, items, hosts):
        label = Gtk.Label(xalign=0)
        label.get_style_context().add_class("uc-accounts-group")
        if self.mode == "provider":
            if key == "~":
                text = "%s · %d" % (escape(self._("Sin IA")), len(items))
            else:
                accounts = len({((item.get("account") or {}).get("email") or "").lower() for item in items
                                if item["state"] == "ok" and (item.get("account") or {}).get("email")})
                name = (items[0].get("agent") or {}).get("display_name") or key
                text = "%s · %s" % (escape(name), escape(
                    (self._("1 ventana") if len(items) == 1 else self._("{n} ventanas").format(n=len(items))) + " · " +
                    (self._("1 cuenta") if accounts == 1 else self._("{m} cuentas").format(m=accounts))))
        elif self.mode == "account":
            if key.startswith("~"):
                text = "%s · %d" % (escape(key[1:]), len(items))
            else:
                count_hosts = len({item["host_key"] for item in items})
                text = '<span foreground="%s">●</span> %s · %s' % (
                    color_of(key), escape(key), escape(
                        (self._("1 ventana") if len(items) == 1 else self._("{n} ventanas").format(n=len(items))) + " " +
                        (self._("en 1 host") if count_hosts == 1 else self._("en {h} hosts").format(h=count_hosts))))
        else:
            first = items[0]
            host = hosts.get(first["host_key"], {}).get("label") or ""
            text = "%s  <small>%s</small>" % (escape(first.get("workspace") or ""), escape(host))
        label.set_markup(text)
        row = Gtk.ListBoxRow(activatable=False, selectable=False)
        row.add(label)
        return row

    def window_row(self, item, hosts):
        account = item.get("account") or {}
        grid = Gtk.Grid(column_spacing=12, row_spacing=2, margin_start=12, margin_top=4, margin_bottom=4)
        name = Gtk.Label(label=item.get("window") or "", xalign=0, width_chars=22, max_width_chars=28, ellipsize=3)
        grid.attach(name, 0, 0, 1, 2)
        agent = item.get("agent") or {}
        badge = Gtk.Label(label=agent.get("display_name") or "—")
        badge.get_style_context().add_class("uc-accounts-badge")
        grid.attach(badge, 1, 0, 1, 1)
        main = Gtk.Label(xalign=0, hexpand=True)
        if item["state"] == "ok" and account.get("email") and account.get("method") in (None, "oauth", "chatgpt"):
            main.set_markup('<span foreground="%s">%s</span>' % (color_of(account["email"]), escape(account["email"])))
            main.get_style_context().add_class("uc-accounts-email")
        elif item["state"] == "ok" and account.get("method") in METHOD_TEXT:
            main.set_text(self._(METHOD_TEXT[account["method"]]))
            main.get_style_context().add_class("uc-accounts-email")
        else:
            text = (self._("No legible como {user}").format(user=account.get("os_user") or self._("otro usuario"))
                    if item["state"] == "no_legible" else self._(STATE_TEXT.get(item["state"], item["state"])))
            main.set_text(text)
            main.get_style_context().add_class("dim-label")
        grid.attach(main, 2, 0, 1, 1)
        if account.get("plan"):
            plan = Gtk.Label(label=account["plan"])
            plan.get_style_context().add_class("uc-accounts-plan")
            grid.attach(plan, 3, 0, 1, 1)
        details = [part for part in (account.get("os_user"), account.get("config")) if part]
        if self.mode in ("account", "provider"):
            details.append(hosts.get(item["host_key"], {}).get("label") or item["host_key"])
        if details:
            small = Gtk.Label(xalign=0)
            small.set_markup("<small>%s</small>" % escape(" · ".join(details)))
            small.get_style_context().add_class("dim-label")
            grid.attach(small, 1, 1, 3, 1)
        row = Gtk.ListBoxRow(activatable=False, selectable=False)
        row.add(grid)
        return row
