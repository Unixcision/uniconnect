"""Regression checks for preserving an agent thread owned by another process."""

import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import importlib.util

_SPEC = importlib.util.spec_from_file_location(
    "uniconnect_recovery", Path(__file__).resolve().parents[1] / "scripts/recovery.py"
)
recovery = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(recovery)


class LiveOwnershipTest(unittest.TestCase):
    @unittest.skipUnless(shutil.which("tmux"), "tmux required")
    def test_existing_session_keeps_its_options_and_running_pane(self):
        # Antes la vuelta ponía `set-clipboard off` en el servidor cada 15 segundos, también sobre
        # sesiones vivas. Ahora solo al crear: una sesión que ya existe no se reconfigura.
        # Todo ocurre en un servidor tmux propio, en un socket temporal; nunca en el del usuario.
        with tempfile.TemporaryDirectory(prefix="uc-owner-regression-") as directory:
            sock = str(Path(directory) / "socket")
            base = ["tmux", "-S", sock, "-f", "/dev/null"]
            env = {k: v for k, v in os.environ.items() if k != "TMUX"}

            def run(*args, **kwargs):
                return subprocess.run(base + list(args), text=True, capture_output=True, timeout=10, env=env, **kwargs)

            try:
                command = shlex.join([sys.executable, "-c", "import sys; sys.stdin.readline()"])
                run("new-session", "-d", "-s", "fixture", "-x", "119", "-y", "35", command, check=True)
                run("set-option", "-t", "=fixture:", "@uniconnect_session_id", "fixture-id", check=True)
                before_pane = run("display-message", "-p", "-t", "=fixture:", "#{pid}|#{pane_pid}", check=True).stdout
                before_clipboard = run("show-options", "-s", "-v", "set-clipboard", check=True).stdout
                data = {"tmuxSocket": "test-only", "windows": [{"tmux": "fixture", "sessionId": "fixture-id"}]}
                # La política real, dirigida solo a este socket de prueba.
                with patch.object(recovery, "tmux", side_effect=lambda socket, *args, **kw: run(*args, **kw)):
                    recovery.ensure_windows(data, Path(directory) / "unused-manifest.json")
                self.assertEqual(run("show-options", "-s", "-v", "set-clipboard", check=True).stdout, before_clipboard)
                self.assertEqual(run("display-message", "-p", "-t", "=fixture:", "#{pid}|#{pane_pid}", check=True).stdout, before_pane)
            finally:
                run("kill-server", check=False)  # Solo el socket de prueba creado aquí.

    @unittest.skipUnless(os.path.isdir("/proc/self/fd"), "/proc de Linux necesario")
    def test_kernel_lock_blocks_recovery_until_actual_owner_exits(self):
        with tempfile.TemporaryFile() as handle:
            path = Path("/proc") / str(os.getpid()) / "fd" / str(handle.fileno())
            child = subprocess.Popen(
                [sys.executable, "-c",
                 "import fcntl,sys; h=open(sys.argv[1]); fcntl.flock(h,fcntl.LOCK_EX); "
                 "print('ready',flush=True); sys.stdin.readline()", str(path)],
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE, text=True,
            )
            try:
                self.assertEqual(child.stdout.readline().strip(), "ready")
                self.assertIn(child.pid, recovery.lock_owners(path))
                with patch.object(recovery, "native_lock_path", return_value=path):
                    self.assertFalse(recovery.native_session_available({}))
                # The owner exits normally; the recovery check never signals it.
                child.stdin.write("\n")
                child.stdin.flush()
                child.wait(timeout=5)
                self.assertEqual(recovery.lock_owners(path), [])
                with patch.object(recovery, "native_lock_path", return_value=path):
                    self.assertTrue(recovery.native_session_available({}))
            finally:
                child.stdin.close()
                child.stdout.close()
                child.wait(timeout=5)

    def test_existing_unowned_tmux_target_is_adopted_without_exception(self):
        # Cambiado a propósito (24-09-2026). Antes una sesión aprendida sin dueño lanzaba
        # «different ownership» y esa excepción cortaba la vuelta entera: ninguna ventana posterior
        # del manifiesto se vigilaba. Ahora queda `adopted: true`, sin tocarla.
        with tempfile.TemporaryDirectory() as directory:
            manifest = Path(directory) / "manifest.json"
            data = {"tmuxSocket": "uniconnect", "windows": [{
                "tmux": "uc-test-01a070d7", "sessionId": "01a070d7-5f44-7f33-aee1-867c845860ef",
            }]}
            manifest.write_text(json.dumps(data))
            calls = []

            def fake_tmux(socket, *args, **kwargs):
                calls.append(args)
                return subprocess.CompletedProcess(args, 0, stdout="\n", stderr="")

            with patch.object(recovery, "tmux", side_effect=fake_tmux):
                recovery.ensure_windows(data, manifest)
            # Solo se pregunta: ni set-option, ni respawn, ni new-session.
            self.assertEqual([call[0] for call in calls], ["has-session", "show-option"])
            self.assertTrue(json.loads(manifest.read_text())["windows"][0]["adopted"])

    def test_existing_target_of_another_owner_is_skipped_without_exception(self):
        with tempfile.TemporaryDirectory() as directory:
            manifest = Path(directory) / "manifest.json"
            data = {"tmuxSocket": "uniconnect", "windows": [{
                "tmux": "uc-test-01a070d7", "sessionId": "01a070d7-5f44-7f33-aee1-867c845860ef",
            }]}
            manifest.write_text(json.dumps(data))
            calls = []

            def fake_tmux(socket, *args, **kwargs):
                calls.append(args)
                return subprocess.CompletedProcess(args, 0, stdout="another-owner\n", stderr="")

            with patch.object(recovery, "tmux", side_effect=fake_tmux):
                recovery.ensure_windows(data, manifest)
            self.assertEqual([call[0] for call in calls], ["has-session", "show-option"])
            self.assertNotIn("adopted", json.loads(manifest.read_text())["windows"][0])


class ClaudeProjectFolderTest(unittest.TestCase):
    """Claude guarda cada conversación en una carpeta con TODO lo no alfanumérico convertido en guion.

    El supervisor solo convertía `/` y `_`, así que una conversación de `/var/www/pre.totalradarvo.es`
    se buscaba en `-var-www-pre.totalradarvo.es` y se daba por perdida: «The original Claude
    conversation is missing», reintentando cada 30 segundos sin recuperar nunca la ventana.
    """

    def test_conversation_in_a_folder_with_dots_is_found(self):
        with tempfile.TemporaryDirectory() as home, tempfile.TemporaryDirectory() as base:
            cwd = Path(base) / "pre.totalradarvo.es" / "mi_app"
            cwd.mkdir(parents=True)
            session = "cc08331a-fc7d-4944-b642-d0ca1dc37901"
            # Así la guarda Claude Code: cada carácter no alfanumérico pasa a ser un guion.
            folder = Path(home) / ".claude/projects" / "".join(
                c if c.isalnum() else "-" for c in os.path.realpath(cwd))
            folder.mkdir(parents=True)
            (folder / (session + ".jsonl")).write_text("{}\n")
            with patch.object(recovery.Path, "home", return_value=Path(home)):
                recovery.verify_session({"agent": "claude", "cwd": str(cwd), "sessionId": session})


if __name__ == "__main__":
    unittest.main()
