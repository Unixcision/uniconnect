"""Launch UniConnect's native Linux desktop with an isolated state owner."""

import argparse
import fcntl
import json
import os
import sys
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description="UniConnect Linux")
    parser.add_argument("--state-dir", type=Path)
    parser.add_argument("--import-file", type=Path)
    parser.add_argument("--connect", help="SSH command used for an explicit JSON import")
    parser.add_argument("--locale", choices=("en", "es", "ja"))
    parser.add_argument("--validate", action="store_true", help="Check the stored snapshot without launching terminals")
    options = parser.parse_args()
    from .state import StateStore
    from .vault import Vault, default_root
    root = options.state_dir or default_root()
    root.mkdir(mode=0o700, parents=True, exist_ok=True)
    owner = (root / "app.lock").open("a")
    try:
        fcntl.flock(owner, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        print("UniConnect is already running for this state directory.", file=sys.stderr)
        return 1
    vault = Vault(root)
    store = StateStore(root, vault=vault)
    if options.validate:
        print(json.dumps({"workspaces": len(store.workspaces), "windows": sum(len(w["windows"]) for w in store.workspaces),
                          "vaultPresent": vault.exists, "state": str(store.path)}))
        return 0
    import gi
    gi.require_version("Gtk", "3.0")
    from gi.repository import Gio, Gtk
    from .window import MainWindow
    application = Gtk.Application(application_id="com.unixcision.uniconnect.linux",
                                  flags=Gio.ApplicationFlags.NON_UNIQUE)
    def activate(app):
        try:
            if vault.exists:
                vault.unlock()
            else:
                vault.initialize()
        except Exception as error:
            # Startup is deliberately non-interactive. Never turn a keyring failure
            # into an unexpected password gate or silently store an unencrypted key.
            print(str(error), file=sys.stderr)
            app.quit()
            return
        if options.import_file:
            from .imports import Importer
            Importer(vault).preview(options.import_file, default_connect=options.connect).apply(store)
        if options.locale:
            store.data.setdefault("settings", {})["locale"] = options.locale
            store.save()
        window = MainWindow(app, store, vault)
        from .control import ControlServer
        app.control_server = ControlServer(window)
        app.connect("shutdown", lambda *_: app.control_server.close())
        window.present()
        # Keep strong ownership until GTK has shut down every native surface.
        app.main_window = window
    application.connect("activate", activate)
    return application.run([sys.argv[0]])


if __name__ == "__main__":
    raise SystemExit(main())
