"""Explicit text copies publish both Linux selections for desktop/VNC clients."""

import os
import shutil
import subprocess

from gi.repository import Gdk, Gtk


def _resend_x11vnc_clipboard():
    """Nudge a local x11vnc server after an explicit app copy, when available."""
    binary = shutil.which("x11vnc")
    display = os.environ.get("DISPLAY")
    if not binary or not display:
        return
    try:
        subprocess.run([binary, "-display", display, "-R", "resend_clipboard"],
                       stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                       stderr=subprocess.DEVNULL, check=False, timeout=1)
    except (OSError, subprocess.TimeoutExpired):
        # Clipboard publication must still work locally if no controllable
        # x11vnc server is running on this display.
        pass


def publish_text(text):
    # Not a clipboard watcher: only the user's Copy action changes these.
    # PRIMARY-only viewers and CLIPBOARD consumers receive identical text.
    for selection in (Gdk.SELECTION_PRIMARY, Gdk.SELECTION_CLIPBOARD):
        clipboard = Gtk.Clipboard.get(selection)
        clipboard.set_text(text, -1)
    Gtk.Clipboard.get(Gdk.SELECTION_CLIPBOARD).store()
    _resend_x11vnc_clipboard()
