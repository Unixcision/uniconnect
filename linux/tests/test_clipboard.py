"""Real GTK clipboard image/text behavior on an isolated test display."""

import hashlib
import os
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

try:
    import gi
    gi.require_version("Gtk", "3.0")
    gi.require_version("Gdk", "3.0")
    gi.require_version("GdkPixbuf", "2.0")
    from gi.repository import Gdk, GdkPixbuf, GLib, Gtk
    from uniconnect.clipboard import ClipboardError, ClipboardImages
    GTK_AVAILABLE = Gtk.init_check()[0]
except (ImportError, ValueError):
    GTK_AVAILABLE = False


@unittest.skipUnless(GTK_AVAILABLE, "GTK display required; run under xvfb-run")
class ClipboardImagesTests(unittest.TestCase):
    def setUp(self):
        # A named selection isolates this fixture even inside its private Xvfb.
        self.selection = Gtk.Clipboard.get(Gdk.Atom.intern("UNICONNECT_TEST_IMAGES", False))
        self.directory = tempfile.TemporaryDirectory(prefix="uc-clipboard-")
        self.reader = ClipboardImages(Path(self.directory.name) / "cache", max_files=2)

    def tearDown(self):
        self.selection.clear()
        self.reader.close()
        self.directory.cleanup()

    def receive(self):
        loop = GLib.MainLoop()
        received = []
        timed_out = []

        def finish(kind, value):
            received.append((kind, value))
            GLib.idle_add(loop.quit)

        def deadline():
            timed_out.append(True)
            loop.quit()
            return False

        source = GLib.timeout_add_seconds(5, deadline)
        request_id = self.reader.request(lambda path: finish("image", path), lambda text: finish("text", text),
                                         lambda error: finish("error", error), clipboard=self.selection)
        loop.run()
        if not timed_out:
            GLib.source_remove(source)
        self.assertFalse(timed_out, "clipboard callback timed out")
        self.assertEqual(len(received), 1)
        return received[0]

    def image(self, seed=0):
        width, height = 29, 17
        pixels = bytes((value + seed) % 256 for value in range(width * height * 4))
        pixbuf = GdkPixbuf.Pixbuf.new_from_bytes(GLib.Bytes.new(pixels), GdkPixbuf.Colorspace.RGB,
                                               True, 8, width, height, width * 4)
        self.selection.set_image(pixbuf)
        return pixbuf

    def test_png_preserves_exact_clipboard_pixels_and_private_transfer_bytes(self):
        pixbuf = self.image()
        _, expected = pixbuf.save_to_bufferv("png", [], [])
        kind, path = self.receive()
        self.assertEqual(kind, "image")
        self.assertEqual(path.stat().st_mode & 0o777, 0o600)
        self.assertEqual(path.parent.stat().st_mode & 0o777, 0o700)
        # This callback is the same boundary used by the shared file-upload action.
        upload_bytes = path.read_bytes()
        self.assertEqual(hashlib.sha256(upload_bytes).hexdigest(), hashlib.sha256(bytes(expected)).hexdigest())
        decoded = GdkPixbuf.Pixbuf.new_from_file(str(path))
        self.assertEqual(bytes(decoded.get_pixels()), bytes(pixbuf.get_pixels()))
        self.reader.release(path)
        self.assertFalse(path.exists())

    def test_text_keeps_unicode_and_never_creates_image_files(self):
        content = "codex resume αβ\nsegunda línea"
        self.selection.set_text(content, -1)
        self.assertEqual(self.receive(), ("text", content))
        self.assertEqual(list(self.reader.cache_dir.iterdir()), [])

    def test_cache_is_bounded_and_retained_uploads_are_not_evicted(self):
        self.image(1)
        _, held = self.receive()
        self.image(2)
        _, old_local = self.receive()
        self.reader.retain_for_local(old_local)
        self.image(3)
        _, newest = self.receive()
        self.assertTrue(held.exists())
        self.assertFalse(old_local.exists())
        self.assertTrue(newest.exists())
        self.assertEqual(len(list(self.reader.cache_dir.glob("*.png"))), 2)
        self.reader.release(held)
        self.reader.release(newest)

    def test_cancelled_image_request_does_not_deliver_or_leave_a_file(self):
        self.image()
        callbacks = []
        loop = GLib.MainLoop()
        cancellation_done = []
        request_id = self.reader.request(callbacks.append, callbacks.append, callbacks.append, clipboard=self.selection)
        def cancelled():
            cancellation_done.append(True)
            loop.quit()
            return False
        self.reader.cancel(request_id, cancelled)
        deadline = GLib.timeout_add_seconds(5, loop.quit)
        loop.run()
        GLib.source_remove(deadline)
        self.assertEqual(cancellation_done, [True])
        self.selection.set_text("after cancellation", -1)
        self.assertEqual(self.receive(), ("text", "after cancellation"))
        self.assertEqual(callbacks, [])
        self.assertEqual(list(self.reader.cache_dir.glob("*.png")), [])

    def test_cleanup_rejects_paths_outside_its_cache(self):
        outside = Path(self.directory.name) / "user-file"
        outside.write_text("preserve")
        with self.assertRaises(ClipboardError):
            self.reader.release(outside)
        self.assertEqual(outside.read_text(), "preserve")

    def test_prune_cleans_expired_interrupted_encoding_without_touching_other_files(self):
        stale = self.reader.cache_dir / (".clipboard-" + "a" * 32 + ".png.tmp")
        stale.write_bytes(b"interrupted PNG")
        os.utime(stale, (1, 1))
        unrelated = self.reader.cache_dir / "other-file"
        unrelated.write_text("preserve")
        self.reader.prune()
        self.assertFalse(stale.exists())
        self.assertEqual(unrelated.read_text(), "preserve")


if __name__ == "__main__":
    unittest.main()
