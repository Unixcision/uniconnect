"""Explicit text copies publish both Linux selections for desktop/VNC clients."""

import ctypes
import ctypes.util
import os

from gi.repository import Gdk, Gtk


def _publish_x11_cutbuffer(text):
    """Publish explicit copies to x11vnc through X11's legacy cut buffer.

    x11vnc polls PRIMARY/CLIPBOARD selections and deliberately delays its first
    selection send; its ``resend_clipboard`` control command only resends the
    server's cached value. XStoreBytes raises the CUT_BUFFER0 property event
    that x11vnc already forwards immediately, without installing a watcher or
    depending on an external clipboard utility.
    """
    if not os.environ.get("DISPLAY") or "\0" in text:
        return
    library = ctypes.util.find_library("X11")
    if not library:
        return
    try:
        x11 = ctypes.CDLL(library)
        x11.XOpenDisplay.argtypes = [ctypes.c_char_p]
        x11.XOpenDisplay.restype = ctypes.c_void_p
        x11.XStoreBytes.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int]
        x11.XStoreBytes.restype = None
        x11.XFlush.argtypes = [ctypes.c_void_p]
        x11.XCloseDisplay.argtypes = [ctypes.c_void_p]
        display = x11.XOpenDisplay(None)
        if not display:
            return
        try:
            encoded = text.encode("utf-8")
            if len(encoded) > 2_147_483_647:
                return
            x11.XStoreBytes(display, encoded, len(encoded))
            x11.XFlush(display)
        finally:
            x11.XCloseDisplay(display)
    except (OSError, OverflowError, UnicodeError):
        # A missing/unavailable X display must not break local clipboard copy.
        pass


def publish_text(text):
    # Not a clipboard watcher: only the user's Copy action changes these.
    # PRIMARY-only viewers and CLIPBOARD consumers receive identical text.
    for selection in (Gdk.SELECTION_PRIMARY, Gdk.SELECTION_CLIPBOARD):
        clipboard = Gtk.Clipboard.get(selection)
        clipboard.set_text(text, -1)
    Gtk.Clipboard.get(Gdk.SELECTION_CLIPBOARD).store()
    _publish_x11_cutbuffer(text)
