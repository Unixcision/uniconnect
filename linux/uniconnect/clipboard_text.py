"""Explicit text copies publish both Linux selections for desktop/VNC clients."""

from gi.repository import Gdk, Gtk


def publish_text(text):
    # Not a clipboard watcher: only the user's Copy action changes these.
    # PRIMARY-only viewers and CLIPBOARD consumers receive identical text.
    for selection in (Gdk.SELECTION_PRIMARY, Gdk.SELECTION_CLIPBOARD):
        clipboard = Gtk.Clipboard.get(selection)
        clipboard.set_text(text, -1)
    Gtk.Clipboard.get(Gdk.SELECTION_CLIPBOARD).store()
