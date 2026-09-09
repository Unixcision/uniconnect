"""Lectura real de pantalla VTE para activity.v1, bajo G_DEBUG=fatal-criticals como la captura de la CI."""

import json
import os
import subprocess
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

from uniconnect.activity_monitor import ActivityMonitor

try:
    import gi
    gi.require_version("Gtk", "3.0")
    gi.require_version("Vte", "2.91")
    from gi.repository import Gtk, Vte  # noqa: F401
    GTK_AVAILABLE = Gtk.init_check()[0]
except (ImportError, ValueError):
    GTK_AVAILABLE = False

# Se ejecuta en un proceso hijo: un VTE-CRITICAL con fatal-criticals aborta el proceso
# entero (exit 133), que es exactamente lo que rompió la captura del SHA 22e6e5361.
CHILD = r'''
import json, sys, types
import gi
gi.require_version("Gtk", "3.0")
gi.require_version("Vte", "2.91")
from gi.repository import GLib, Gtk, Vte
from uniconnect.activity_monitor import ActivityMonitor

terminal = Vte.Terminal()
terminal.set_size(40, 6)
window = Gtk.OffscreenWindow()
window.add(terminal)
window.show_all()
terminal.feed("".join(f"fila {n}\r\n" for n in range(1, 15)).encode() + b"Do you want to proceed?\r\n\x1b[1m\xe2\x9d\xaf 1. Yes\x1b[0m")
loop = GLib.MainLoop()
GLib.timeout_add(400, loop.quit)
loop.run()
surface = types.SimpleNamespace(terminal=terminal, pid=1)
lines = ActivityMonitor.screen_lines(surface)
print(json.dumps({"lines": lines, "api": "get_text_format" if hasattr(terminal, "get_text_format") else "get_text"}))
'''


@unittest.skipUnless(GTK_AVAILABLE, "GTK display required")
class ScreenReadTests(unittest.TestCase):
    def test_screen_lines_read_the_visible_rows_without_vte_criticals(self):
        env = dict(os.environ, G_DEBUG="fatal-criticals", PYTHONPATH=str(ROOT))
        result = subprocess.run([sys.executable, "-c", CHILD], capture_output=True, text=True, timeout=60, env=env)
        self.assertEqual(result.returncode, 0, f"stdout={result.stdout!r}\nstderr={result.stderr[-2000:]!r}")
        self.assertNotIn("CRITICAL", result.stderr)
        payload = json.loads(result.stdout.strip().splitlines()[-1])
        lines = payload["lines"]
        self.assertIsNotNone(lines)
        self.assertLessEqual(len(lines), ActivityMonitor.SCREEN_ROWS)
        self.assertIn("Do you want to proceed?", lines)
        self.assertTrue(any("1. Yes" in line for line in lines))
        self.assertNotIn("fila 1", lines)  # Se leen las filas visibles, no las desplazadas fuera.


if __name__ == "__main__":
    unittest.main()
