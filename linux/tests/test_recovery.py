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


def contracts_dir():
    """contracts/ subiendo carpeta a carpeta desde este fichero (D8). Si no está, el test falla."""
    for folder in Path(__file__).resolve().parents:
        if (folder / "contracts").is_dir():
            return folder / "contracts"
    raise AssertionError("No se encuentra contracts/ subiendo desde " + __file__)


def repo_file(relative):
    path = contracts_dir().parent / relative
    assert path.is_file(), "Falta " + str(path)
    return path


class LiveOwnershipTest(unittest.TestCase):
    @unittest.skipUnless(shutil.which("tmux"), "tmux required")
    def test_existing_session_keeps_its_options_and_running_pane(self):
        # Antes la vuelta ponía `set-clipboard off` en el servidor cada 15 segundos, también sobre
        # sesiones vivas. Ahora (D4) solo acompaña al new-session que arranca el servidor: una
        # sesión que ya existe, y su servidor, no se reconfiguran.
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


class ScriptedTmux:
    """tmux de mentira para un socket: el servidor existe, no existe o contesta algo raro.

    `server`: True (vivo), False (no hay servidor: «no server running») o None (un error que no
    dice si hay servidor). `sessions`: {nombre: dueño}. Registra cada llamada.
    """

    def __init__(self, server, sessions=None, server_pid="100"):
        self.server = server
        self.sessions = dict(sessions or {})
        self.server_pid = server_pid
        self.calls = []

    def __call__(self, socket, *args, check=True):
        self.calls.append(args)
        name = args[args.index("-t") + 1].lstrip("=").rstrip(":") if "-t" in args else None
        if args[0] == "list-sessions":
            if self.server is True:
                return subprocess.CompletedProcess(args, 0, "".join(self.server_pid + "\n" for _ in self.sessions), "")
            if self.server is False:
                return subprocess.CompletedProcess(args, 1, "", "no server running on /tmp/tmux-0/" + socket + "\n")
            return subprocess.CompletedProcess(args, 1, "", "protocol version mismatch\n")
        if args[0] == "has-session":
            return subprocess.CompletedProcess(args, 0 if name in self.sessions else 1, "", "")
        if args[0] == "show-option":
            return subprocess.CompletedProcess(args, 0, (self.sessions.get(name) or "") + "\n", "")
        if args[0] == "list-panes":
            return subprocess.CompletedProcess(args, 0, "%1\t0\n", "")
        if args[0] == "new-session":
            self.sessions[args[args.index("-s") + 1]] = ""
            self.server = True
            return subprocess.CompletedProcess(args, 0, "", "")
        if args[0] == "set-option" and "@uniconnect_session_id" in args:
            self.sessions[name] = args[-1]
        return subprocess.CompletedProcess(args, 0, "", "")

    def server_changes(self):
        """Llamadas que tocan el servidor entero: opciones sin -t, -s o -g, y tablas de teclas."""
        changes = []
        for call in self.calls:
            for index, token in enumerate(call):
                if token in ("set-option", "set-window-option") and (
                        "-s" in call[index:index + 3] or "-g" in call[index:index + 3] or "-t" not in call[index:index + 4]):
                    changes.append(call)
                if token in ("bind-key", "unbind-key"):
                    changes.append(call)
        return changes


class ServerOptionsOnlyOnANewServerTest(unittest.TestCase):
    """D4: ninguna ruta automática cambia opciones de un servidor tmux que ya existía."""

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.manifest = Path(self.directory.name) / "manifest.json"

    def tearDown(self):
        self.directory.cleanup()

    def ensure(self, fake):
        data = {"tmuxSocket": "s", "windows": [{"name": "nueva", "tmux": "nueva", "agent": "claude",
                                                "sessionId": "714b0eae-b568-4e0c-a70b-c87c0d0a801a",
                                                "cwd": self.directory.name}]}
        self.manifest.write_text(json.dumps(data))
        with patch.object(recovery, "tmux", side_effect=fake), \
             patch.object(recovery, "verify_session"), patch.object(recovery, "command_for"), \
             patch.object(recovery, "boot_id", return_value="boot-1"):
            recovery.ensure_windows(data, self.manifest)
        self.assertIn("nueva", fake.sessions)

    def test_set_clipboard_goes_with_the_new_session_that_starts_the_server(self):
        fake = ScriptedTmux(server=False)
        self.ensure(fake)
        created = [call for call in fake.calls if call[0] == "new-session"]
        self.assertEqual(len(created), 1)
        self.assertEqual(list(created[0][-5:]), [";", "set-option", "-s", "set-clipboard", "off"])
        # Aparte de esa, nada del servidor: solo opciones de la sesión recién creada.
        self.assertEqual([c for c in fake.server_changes() if c[0] != "new-session"], [])

    def test_a_live_server_gets_no_server_option_nor_key_table(self):
        # Otra sesión viva en el mismo servidor (a menudo tmux 3.2a con IA dentro): solo new-session.
        fake = ScriptedTmux(server=True, sessions={"otra": "otro-dueno"})
        self.ensure(fake)
        self.assertFalse([c for c in fake.calls if "set-clipboard" in c])
        self.assertEqual(fake.server_changes(), [])
        # Las de la sesión nueva sí, siempre con -t.
        self.assertIn(("set-option", "-t", "=nueva:", "@uniconnect_session_id", "714b0eae-b568-4e0c-a70b-c87c0d0a801a"),
                      fake.calls)

    def test_an_unknown_server_state_counts_as_live(self):
        fake = ScriptedTmux(server=None)
        self.ensure(fake)
        self.assertFalse([c for c in fake.calls if "set-clipboard" in c])
        self.assertEqual(fake.server_changes(), [])

    def test_server_running_reads_the_no_server_messages(self):
        for stderr, expected in (("no server running on /tmp/tmux-0/s", False),
                                 ("error connecting to /tmp/tmux-0/s (No such file or directory)", False),
                                 ("error connecting to /tmp/tmux-0/s (Connection refused)", False),
                                 ("protocol version mismatch", None)):
            with self.subTest(stderr=stderr), patch.object(
                    recovery, "tmux", return_value=subprocess.CompletedProcess([], 1, "", stderr)):
                self.assertIs(recovery.server_running("s"), expected)
        with patch.object(recovery, "tmux", return_value=subprocess.CompletedProcess([], 0, "100\n", "")):
            self.assertIs(recovery.server_running("s"), True)
        with patch.object(recovery, "tmux", side_effect=FileNotFoundError("tmux")):
            self.assertIsNone(recovery.server_running("s"))


class NoPromptSupersedesTest(unittest.TestCase):
    """D2: la copia de `noPrompt` aplica `supersedes` con la misma regla que el Mac y Linux."""

    def test_every_resume_case_of_the_contract_with_its_arguments(self):
        casos = json.loads((contracts_dir() / "agent-tree-v1/reanudar-comandos.json").read_text(encoding="utf-8"))["casos"]
        self.assertTrue(any(caso.get("arguments") for caso in casos))
        for caso in casos:
            with self.subTest(caso=caso["nombre"]):
                got = recovery.canonical_resume(caso["provider"], caso["session_id"], caso["cwd"], caso["as_root"],
                                                caso.get("arguments", []))
                self.assertEqual(got["argv"], caso["argv"])
                self.assertEqual(got["environment"], caso["environment"])
                self.assertEqual(got["command"], caso["command"])
                self.assertEqual(got["no_prompt_verified"], caso["no_prompt_verified"])
                # Aplicarla dos veces da lo mismo que una.
                self.assertEqual(recovery.apply_no_prompt(caso["provider"], got["argv"]), got["argv"])

    def test_codex_never_keeps_approval_or_sandbox_next_to_yolo(self):
        argv = recovery.canonical_argv("codex", "01a0ac81-57c7-7af3-8ac2-fe8a957c8b17",
                                       ["-a", "never", "-s=read-only", "--full-auto", "--sandbox", "workspace-write",
                                        "--ask-for-approval=on-request", "-C", "/w"])
        self.assertEqual(argv, ["codex", "--yolo", "resume", "01a0ac81-57c7-7af3-8ac2-fe8a957c8b17", "-C", "/w"])

    def test_a_trailing_flag_without_value_is_dropped_alone(self):
        argv = recovery.canonical_argv("codex", "01a0ac81-57c7-7af3-8ac2-fe8a957c8b17", ["-C", "/w", "-a"])
        self.assertEqual(argv, ["codex", "--yolo", "resume", "01a0ac81-57c7-7af3-8ac2-fe8a957c8b17", "-C", "/w"])

    def test_the_launch_uses_the_same_policy_as_the_canonical_form(self):
        with patch.object(recovery.shutil, "which", return_value="/usr/bin/codex"):
            argv = recovery.command_for({"agent": "codex", "sessionId": "t1", "cwd": "/w", "model": "m"})
        self.assertEqual(argv, ["/usr/bin/codex", "--yolo", "resume", "t1", "-C", "/w", "-m", "m"])

    def test_the_copy_is_the_catalog_policy(self):
        # La copia no puede decir otra cosa que el catálogo compartido, supersedes incluido. Sin
        # salida silenciosa: si el catálogo no trae la política de Codex, el test falla.
        catalog = json.loads(repo_file("Packages/CMUXAgentLaunch/Sources/CMUXAgentLaunch/Resources/agent-resume-v1.json")
                             .read_text(encoding="utf-8"))["providers"]
        self.assertIn("supersedes", catalog["codex"]["noPrompt"])
        for catalog_id, wire in (("claude", "claude"), ("codex", "codex"), ("antigravity", "agy"), ("grok", "grok")):
            with self.subTest(provider=wire):
                self.assertEqual(catalog[catalog_id].get("noPrompt"), recovery.NO_PROMPT.get(wire))


class DeliberateCloseTest(unittest.TestCase):
    """D6: solo se olvida lo que se cerró a mano en **el mismo** servidor tmux."""

    def data(self, **seen):
        return {"tmuxSocket": "s", "seen": {"bootId": "boot-1", **seen},
                "windows": [{"tmux": "a", "sessionId": "a"}, {"tmux": "b", "sessionId": "b"}]}

    def deliberate(self, data, server_pids):
        with patch.object(recovery, "boot_id", return_value="boot-1"), \
             patch.object(recovery, "tmux", return_value=subprocess.CompletedProcess([], 0, server_pids, "")):
            return recovery.missing_is_deliberate(data, [data["windows"][0]])

    def test_one_window_missing_from_the_same_server_was_closed_by_hand(self):
        self.assertTrue(self.deliberate(self.data(servers={"s": "100"}), "100\n"))

    def test_a_restarted_server_is_a_crash_even_if_someone_already_opened_a_window(self):
        # El tmux cayó y UniConnect (desde un escritorio) ya levantó otro con una de las ventanas.
        # Antes eso se leía como «falta solo una: cerrada a mano» y se olvidaban para siempre.
        self.assertFalse(self.deliberate(self.data(servers={"s": "100"}), "200\n"))

    def test_without_a_recorded_server_the_old_rule_holds(self):
        self.assertTrue(self.deliberate(self.data(), "200\n"))

    def test_snapshot_records_the_server_of_each_socket(self):
        with tempfile.TemporaryDirectory() as directory:
            manifest = Path(directory) / "manifest.json"
            data = {"tmuxSocket": "s", "windows": []}
            manifest.write_text(json.dumps(data))
            panes = {"x": [{"pane_pid": 42, "dead": False, "cwd": "/w", "server_pid": "4242"}]}

            class NoProcesses:
                def process_table(self):
                    return {}

            with patch.object(recovery, "live_sessions", return_value=panes), \
                 patch.object(recovery, "boot_id", return_value="boot-1"):
                recovery.snapshot(data, manifest, NoProcesses())
            self.assertEqual(json.loads(manifest.read_text())["seen"]["servers"], {"s": "4242"})

    def test_live_sessions_reads_the_server_pid_and_still_accepts_the_old_line(self):
        out = "\n".join(["\t".join(["a", "$0", "0", "%0", "41230", "0", "/root", "bash", "4242"]),
                         "\t".join(["b", "$1", "0", "%1", "41231", "0", "/root", "bash"])])
        with patch.object(recovery, "tmux", return_value=subprocess.CompletedProcess([], 0, out, "")):
            sessions = recovery.live_sessions("s")
        self.assertEqual(sessions["a"][0]["server_pid"], "4242")
        self.assertNotIn("server_pid", sessions["b"][0])


class OwnershipTest(unittest.TestCase):
    """D6: el supervisor reconoce sus sesiones por `@uniconnect_session_id`/`tmuxOwner`."""

    def run_ensure(self, entry, owner):
        with tempfile.TemporaryDirectory() as directory:
            manifest = Path(directory) / "manifest.json"
            data = {"tmuxSocket": "s", "windows": [entry]}
            manifest.write_text(json.dumps(data))
            fake = ScriptedTmux(server=True, sessions={entry["tmux"]: owner})
            with patch.object(recovery, "tmux", side_effect=fake):
                recovery.ensure_windows(data, manifest)
            return fake, json.loads(manifest.read_text())["windows"][0]

    def test_a_session_of_an_older_supervisor_gets_its_owner_recorded(self):
        fake, stored = self.run_ensure({"tmux": "w", "sessionId": "viejo"}, "viejo")
        self.assertEqual(stored["tmuxOwner"], "viejo")
        # Solo se apunta en el manifiesto: a tmux solo se le pregunta.
        self.assertEqual([call[0] for call in fake.calls], ["has-session", "show-option", "list-panes"])

    def test_after_a_clear_the_recorded_owner_still_recognises_the_session(self):
        fake, stored = self.run_ensure({"tmux": "w", "sessionId": "nuevo", "tmuxOwner": "viejo"}, "viejo")
        self.assertIn("list-panes", [call[0] for call in fake.calls])
        self.assertEqual(stored["tmuxOwner"], "viejo")

    def test_another_owner_is_skipped_and_never_claimed(self):
        fake, stored = self.run_ensure({"tmux": "w", "sessionId": "mio"}, "de-otro")
        self.assertEqual([call[0] for call in fake.calls], ["has-session", "show-option"])
        self.assertNotIn("tmuxOwner", stored)


class DeadPaneTest(unittest.TestCase):
    def test_a_session_whose_panes_are_all_dead_is_panel_muerto(self):
        table = {10: {"pid": 10, "ppid": 1, "uid": 0, "argv": ["-bash"]}}
        self.assertEqual(recovery.detect_session([{"pane_pid": 10, "dead": True, "cwd": "/"}], table, None),
                         {"cause": "panel_muerto"})
        # El shell del panel ya no está en la tabla: tampoco dice que la IA se cerrara.
        self.assertEqual(recovery.detect_session([{"pane_pid": 99, "dead": False, "cwd": "/"}], table, None),
                         {"cause": "panel_muerto"})


if __name__ == "__main__":
    unittest.main()
