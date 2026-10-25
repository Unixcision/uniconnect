"""Installer refreshes only UniConnect-owned CLI links and preserves the old target."""

from contextlib import redirect_stdout
import io
import os
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import install as linux_install


class InstallTests(unittest.TestCase):
    def make_checkout(self, root):
        source = root / "checkout" / "linux"
        (source / "uniconnect").mkdir(parents=True)
        (source / "uniconnect" / "cli.py").write_text("# cli\n")
        (source / "uniconnect-linux").write_text("#!/bin/sh\nexit 0\n")
        (source / "cmux").write_text("#!/bin/sh\nexit 0\n")
        (root / "checkout" / "docs" / "assets").mkdir(parents=True)
        (root / "checkout" / "docs" / "assets" / "logo-256.png").write_bytes(b"icon")
        return source

    def test_refreshes_old_uniconnect_cli_link_and_backs_up_exact_link(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = self.make_checkout(root)
            old = root / "old-checkout" / "linux"
            (old / "uniconnect").mkdir(parents=True)
            (old / "uniconnect" / "cli.py").write_text("# old\n")
            (old / "cmux").write_text("#!/bin/sh\nexit 0\n")
            home = root / "home"
            bindir = home / ".local/bin"
            bindir.mkdir(parents=True)
            cli_link = bindir / "uniconnect-cli"
            cli_link.symlink_to(os.path.relpath(old / "cmux", bindir))
            custom = bindir / "cmux"
            custom.write_text("custom client\n")
            applications = home / ".local/share/applications"

            with redirect_stdout(io.StringIO()):
                linux_install.install(source, home=home, applications=applications)

            self.assertEqual(cli_link.resolve(), (source / "cmux").resolve())
            self.assertEqual(custom.read_text(), "custom client\n")
            backups = list((home / ".local/state/uniconnect/install-backups").iterdir())
            old_backup = backups[0] / "uniconnect-cli"
            self.assertTrue(old_backup.is_symlink())
            self.assertEqual(old_backup.resolve(), (old / "cmux").resolve())

    def test_keeps_non_uniconnect_cli_symlink(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = self.make_checkout(root)
            home = root / "home"
            bindir = home / ".local/bin"
            bindir.mkdir(parents=True)
            custom_target = root / "personal-cmux"
            custom_target.write_text("custom client\n")
            cli_link = bindir / "uniconnect-cli"
            cli_link.symlink_to(custom_target)

            with redirect_stdout(io.StringIO()):
                linux_install.install(source, home=home, applications=home / "applications")

            self.assertEqual(cli_link.resolve(), custom_target.resolve())


if __name__ == "__main__":
    unittest.main()
