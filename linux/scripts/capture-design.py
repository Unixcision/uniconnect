#!/usr/bin/env python3
"""Capture the real GTK 3 layout in CI using visibly DEMO-only private fixtures.

No shell, SSH, tmux or AI process is launched. TerminalSurface and MainWindow
are the production widgets, with only automatic process launch disabled. PNGs
prove appearance on this runner, not functionality, connectivity or parity.
Run under an isolated display: xvfb-run -a /usr/bin/python3 this-file --output DIR.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import sys
import tempfile
import time
from unittest.mock import patch
import uuid


def arguments():
    parser = argparse.ArgumentParser(description="Capturas GTK reales con datos DEMO sin conexiones")
    parser.add_argument("--output", type=Path, help="Directorio de imágenes; por defecto, temporal")
    return parser.parse_args()


def main():
    if not sys.platform.startswith("linux"):
        raise SystemExit("Esta captura solo se ejecuta en Linux, en una VM o CI con pantalla aislada")
    args = arguments()
    output = args.output.resolve() if args.output else Path(tempfile.mkdtemp(prefix="uc-design-images-"))
    output.mkdir(parents=True, exist_ok=True)
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

    import gi
    gi.require_version("Gtk", "3.0")
    gi.require_version("Gdk", "3.0")
    gi.require_version("Vte", "2.91")
    from gi.repository import Gdk, Gio, GLib, Gtk
    from uniconnect.state import StateStore
    from uniconnect.terminal import TerminalSurface
    from uniconnect.vault import Vault
    from uniconnect.window import MainWindow

    if not Gtk.init_check()[0]:
        raise SystemExit("No hay pantalla GTK; usa xvfb-run en CI o una VM aislada")
    settings = Gtk.Settings.get_default()
    settings.set_property("gtk-theme-name", "Adwaita")
    settings.set_property("gtk-icon-theme-name", "Adwaita")
    settings.set_property("gtk-enable-animations", False)

    def settle(milliseconds=450):
        loop = GLib.MainLoop()
        GLib.timeout_add(milliseconds, lambda: loop.quit() or False)
        loop.run()

    def wait_for(predicate, seconds=5):
        deadline = time.monotonic() + seconds
        while not predicate():
            if time.monotonic() >= deadline:
                raise RuntimeError("La ventana DEMO no terminó de dibujarse")
            settle(40)
        settle()

    def no_process(*_args, **_kwargs):
        raise RuntimeError("La captura de diseño prohíbe lanzar procesos o conexiones")

    def demo_surface(owner, workspace, record, create=False):
        surface = TerminalSurface(owner, workspace, record, create=False, auto_launch=False)
        surface.status = "DEMO"
        surface.status_label.set_text("DEMO · Sin proceso ni conexión")
        surface.terminal.feed((
            "\x1b[2J\x1b[H\x1b[1;38;2;11;228;250mDEMO · UniConnect Linux\x1b[0m\r\n\r\n"
            "Captura de diseño de los widgets GTK y VTE reales.\r\n"
            "No hay shell, SSH, tmux ni IA conectados.\r\n\r\n"
            "\x1b[38;2;195;68;243mProyecto DEMO\x1b[0m\r\n"
            "  Colores       Azul noche · cian · violeta\r\n"
            "  Tipografía    Español: edición, conexión, terminal\r\n"
            "  Espaciado     Superior · laterales · inferior\r\n\r\n"
            "Esta imagen no verifica conexiones ni recuperación de sesiones.\r\n"
            "\x1b[?25l"
        ).encode("utf-8"))
        return surface

    def allocation(widget):
        value = widget.get_allocation()
        return {"x": value.x, "y": value.y, "width": value.width, "height": value.height}

    metadata = {"scope": "DEMO: revisión visual, sin procesos ni conexiones",
                "gtk_version": f"{Gtk.get_major_version()}.{Gtk.get_minor_version()}.{Gtk.get_micro_version()}",
                "theme": "Adwaita oscuro + appearance.css del repositorio",
                "commit": os.environ.get("GITHUB_SHA"), "states": []}
    css = Path(__file__).resolve().parents[1] / "uniconnect" / "appearance.css"
    metadata["css_sha256"] = hashlib.sha256(css.read_bytes()).hexdigest()

    # This directory is created by this script and is the only state/vault root.
    # Neither the user's defaults nor the installed application's state is read.
    with tempfile.TemporaryDirectory(prefix="uc-design-state-") as folder:
        root = Path(folder)
        vault = Vault(root / "state")
        vault.initialize("DEMO-only-disposable-design-fixture")
        store = StateStore(root / "state", vault=vault)
        store.data["settings"].update(theme="dark", locale="es", font="Monospace 11", sidebarWidth=270,
                                      compactSidebar=False, autoLockMinutes=0, mobileHostEnabled=False)
        for index, (name, color) in enumerate((("Proyecto DEMO", "#0be4fa"), ("Herramientas DEMO", "#5a1fe5"),
                                              ("Documentación DEMO", "#33c7de"), ("Diseño DEMO", "#c344f3"),
                                              ("Archivo DEMO", "#a5b4d4"))):
            windows = [{"id": f"demo-window-{index}-{number}", "name": f"Consola DEMO {number + 1}",
                        "paneId": "main", "cwd": str(root), "agent": "terminal"}
                       for number in range(3 if index == 0 else 1)]
            store.workspaces.append({"id": f"demo-workspace-{index}", "name": name, "kind": "local",
                                     "cwd": str(root), "color": color, "windows": windows,
                                     "selectedWindowId": windows[0]["id"]})
        store.data["selectedWorkspaceId"] = "demo-workspace-0"
        store.save()
        app = Gtk.Application(application_id="com.unixcision.uniconnect.design" + uuid.uuid4().hex[:8],
                              flags=Gio.ApplicationFlags.NON_UNIQUE)
        app.register(None)
        window = None
        # Safeguards make accidental launch or future network activation fail,
        # instead of capturing a secretly connected or fabricated healthy state.
        with patch("uniconnect.window.TerminalSurface", side_effect=demo_surface), \
             patch.object(TerminalSurface, "launch", side_effect=no_process), \
             patch("uniconnect.transport.Transport.run", side_effect=no_process), \
             patch("uniconnect.transport.Transport.ensure_session", side_effect=no_process), \
             patch("uniconnect.mobile_host.MobileHost.start", side_effect=no_process):
            try:
                window = MainWindow(app, store, vault)
                window.get_titlebar().set_subtitle("DEMO · Solo revisión visual")
                window.present()
                wait_for(lambda: window.get_mapped() and window._sidebar_refresh == 0)
                if not hasattr(window, "_appearance_provider"):
                    raise RuntimeError("La captura exige el proveedor CSS real del producto")

                for mode in ("expandido", "compacto"):
                    if mode == "compacto":
                        window.action_sidebar()  # Exercise the production layout action.
                        wait_for(lambda: window._sidebar_refresh == 0)
                    window.status_label.set_text("DEMO · Captura de diseño · Sin procesos ni conexiones")
                    settle()
                    if any(surface.pid or surface._preparing or surface._spawning
                           for surface in window.surfaces.values()):
                        raise RuntimeError("Una terminal DEMO intentó iniciar un proceso")
                    drawable = window.get_window()
                    drawable.get_display().sync()
                    width, height = drawable.get_width(), drawable.get_height()
                    pixbuf = Gdk.pixbuf_get_from_window(drawable, 0, 0, width, height)
                    if pixbuf is None or pixbuf.get_width() < 500 or pixbuf.get_height() < 400:
                        raise RuntimeError("La captura de la ventana GTK está vacía o incompleta")
                    path = output / f"uniconnect-linux-demo-{mode}.png"
                    if not pixbuf.savev(str(path), "png", [], []):
                        raise RuntimeError("No se pudo guardar la captura GTK")
                    metadata["states"].append({"name": mode, "png": path.name,
                                               "image_width": pixbuf.get_width(), "image_height": pixbuf.get_height(),
                                               "scale": window.get_scale_factor(), "window": allocation(window),
                                               "sidebar": allocation(window.body.get_child1()),
                                               "sidebar_divider_position": window.body.get_position(),
                                               "search_visible": window.sidebar_search.get_visible(),
                                               "live_processes": 0})
                    print(path, flush=True)
            finally:
                if window is not None:
                    window.on_delete()
                    window.destroy()
    report = output / "capturas-demo.json"
    report.write_text(json.dumps(metadata, ensure_ascii=False, indent=2) + "\n")
    print(report, flush=True)


if __name__ == "__main__":
    main()
