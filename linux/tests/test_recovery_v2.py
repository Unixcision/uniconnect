"""Behaviour of the recovery supervisor that does not need a live tmux or /proc."""
import importlib.util
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

_REPO = Path(__file__).resolve().parents[2]
_SPEC = importlib.util.spec_from_file_location(
    "uniconnect_recovery", Path(__file__).resolve().parents[1] / "scripts/recovery.py"
)
recovery = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(recovery)


def contract(name):
    return json.loads((_REPO / "contracts/agent-tree-v1" / name).read_text(encoding="utf-8"))


class FixtureReaders:
    """Lo que la detección lee del sistema, servido desde un caso del fixture compartido.

    Las fichas se sirven donde las buscaría la implementación: en /root si el proceso es de root, y
    en el HOME de quien sondea si no. Así el caso de sudo solo pasa si se busca también en /root.
    """

    def __init__(self, home, procesos, fichas=None, abiertos=None, rollouts=None, cwds=None, enlaces=None,
                 cerrojos=(), proc_legible=True, fichas_en_home=False):
        self.home = home
        self.claude_dir = home.rstrip("/") + "/.claude"
        self.table = {p["pid"]: {"pid": p["pid"], "ppid": p.get("ppid", 1), "uid": p.get("uid", 1000), "argv": p["argv"]}
                      for p in procesos}
        self.files = {}
        for pid, ficha in (fichas or {}).items():
            uid = self.table.get(int(pid), {}).get("uid")
            base = self.claude_dir if (fichas_en_home or uid != 0) else "/root/.claude"
            self.files[base + "/sessions/" + str(pid) + ".json"] = json.dumps(ficha)
        self.files.update(rollouts or {})
        self.opened = {int(pid): paths for pid, paths in (abiertos or {}).items()}
        self.cwds = {int(pid): path for pid, path in (cwds or {}).items()}
        self.links = enlaces or {}
        self.locks = set(cerrojos)
        self.proc_readable = proc_legible

    def process_table(self):
        return dict(self.table) if self.proc_readable else None

    def open_files(self, pid):
        return list(self.opened.get(pid, [])) if self.proc_readable else None

    def cwd(self, pid):
        return self.cwds.get(pid)

    def read_text(self, path, limit=65536):
        return self.files.get(path)

    def list_dir(self, path):
        prefix = path.rstrip("/") + "/"
        return [p[len(prefix):] for p in self.files if p.startswith(prefix) and "/" not in p[len(prefix):]]

    def realpath(self, path):
        return self.links.get(path, path)

    def locked(self, path):
        return str(path) in self.locks


def readers_for_case(caso):
    return FixtureReaders(caso["home"], caso["procesos"], caso.get("fichas"), caso.get("abiertos"),
                          caso.get("rollouts"), caso.get("cwds"), caso.get("enlaces"))


class DetectionContractTest(unittest.TestCase):
    """contracts/agent-tree-v1/deteccion-casos.json contra la detección real de recovery.py."""

    def test_every_detection_case_of_the_contract(self):
        casos = contract("deteccion-casos.json")["casos"]
        self.assertGreaterEqual(len(casos), 14)
        for caso in casos:
            with self.subTest(caso=caso["nombre"]):
                readers = readers_for_case(caso)
                found = recovery.detect_agent(caso["pane_pid"], readers.process_table(), readers, caso.get("pane_current_path"))
                for key, value in caso["espera"].items():
                    self.assertEqual(found.get(key), value, key)

    def test_every_guard_case_of_the_contract(self):
        casos = contract("deteccion-casos.json")["guarda"]
        for caso in casos:
            with self.subTest(caso=caso["nombre"]):
                readers = FixtureReaders(caso["home"], caso["procesos"], caso.get("fichas_vivas"), caso.get("abiertos"),
                                         cerrojos=caso.get("cerrojos", ()), proc_legible=caso.get("proc_legible", True),
                                         fichas_en_home=True)
                self.assertEqual(recovery.guard(caso["proveedor"], caso["id"], readers), caso["espera"])

    def test_a_live_ficha_blocks_the_resume(self):
        entry = {"agent": "claude", "sessionId": "473ed1de-4397-45ef-b00b-6b17fd7382b0", "cwd": "/root/xunis"}
        ficha = {"2100": {"sessionId": entry["sessionId"], "cwd": "/root/xunis"}}
        vivo = FixtureReaders("/root", [{"pid": 2100, "uid": 0, "argv": ["claude"]}], ficha, fichas_en_home=True)
        muerto = FixtureReaders("/root", [], ficha, fichas_en_home=True)
        self.assertFalse(recovery.native_session_available(entry, vivo))
        self.assertTrue(recovery.native_session_available(entry, muerto))

    def test_every_pane_of_a_session_is_looked_at(self):
        # El primer panel es un shell; la IA está en el segundo. Antes solo se miraba el primero.
        readers = FixtureReaders("/home/dani", [
            {"pid": 10, "ppid": 1, "uid": 1000, "argv": ["-bash"]},
            {"pid": 20, "ppid": 1, "uid": 1000, "argv": ["-bash"]},
            {"pid": 21, "ppid": 20, "uid": 1000, "argv": ["codex", "--yolo", "resume", "019a4e2b-6c3d-7f81-9a05-3e7b1c8d2f46"]},
        ], cwds={21: "/home/dani/api"})
        panes = [{"pane_pid": 10, "dead": False, "cwd": "/home/dani"}, {"pane_pid": 20, "dead": False, "cwd": "/home/dani/api"}]
        found = recovery.detect_session(panes, readers.process_table(), readers)
        self.assertEqual((found["provider"], found["session_id"]), ("codex", "019a4e2b-6c3d-7f81-9a05-3e7b1c8d2f46"))
        # IA en dos paneles de la misma sesión: ambigua, no se elige.
        readers.table[11] = {"pid": 11, "ppid": 10, "uid": 1000, "argv": ["claude", "--resume", "714b0eae-b568-4e0c-a70b-c87c0d0a801a"]}
        self.assertEqual(recovery.detect_session(panes, readers.process_table(), readers), {"cause": "identidad_ambigua"})

    def test_live_sessions_returns_every_pane(self):
        out = "\n".join([
            "\t".join(["claudebets", "$0", "0", "%0", "41230", "0", "/root/xunis", "bash"]),
            "\t".join(["claudebets", "$0", "0", "%7", "41231", "0", "/root/xunis", "claude"]),
        ])
        with patch.object(recovery, "tmux", return_value=subprocess.CompletedProcess([], 0, out, "")):
            sessions = recovery.live_sessions("default")
        self.assertEqual([p["pane_id"] for p in sessions["claudebets"]], ["%0", "%7"])


class ResumeCommandsContractTest(unittest.TestCase):
    """contracts/agent-tree-v1/reanudar-comandos.json contra las órdenes de recovery.py."""

    def test_canonical_resume_matches_the_contract(self):
        for caso in contract("reanudar-comandos.json")["casos"]:
            with self.subTest(caso=caso["nombre"]):
                got = recovery.canonical_resume(caso["provider"], caso["session_id"], caso["cwd"], caso["as_root"],
                                                caso.get("arguments", []))
                self.assertEqual(got["argv"], caso["argv"])
                self.assertEqual(got["environment"], caso["environment"])
                self.assertEqual(got["command"], caso["command"])
                self.assertEqual(got["no_prompt_verified"], caso["no_prompt_verified"])

    def test_command_for_launches_the_canonical_argv(self):
        # Lo que se lanza de verdad empieza por la forma canónica; Codex añade detrás -C <cwd>.
        # command_for saca sus argumentos del manifiesto (-C, -m, -c), no de `arguments`: los casos
        # con `arguments` (supersedes de --yolo) se comprueban en canonical_resume.
        for caso in (c for c in contract("reanudar-comandos.json")["casos"] if not c.get("arguments")):
            with self.subTest(caso=caso["nombre"]):
                entry = {"agent": caso["provider"], "sessionId": caso["session_id"], "cwd": caso["cwd"]}
                with patch.object(recovery, "claude_executable", return_value="claude"), \
                     patch.object(recovery.shutil, "which", side_effect=lambda name: name):
                    argv = recovery.command_for(entry)
                self.assertEqual(argv[:len(caso["argv"])], caso["argv"])
                if caso["provider"] == "codex":
                    self.assertEqual(argv[len(caso["argv"]):], ["-C", caso["cwd"]])
                else:
                    self.assertEqual(len(argv), len(caso["argv"]))

    def test_the_copied_policy_matches_the_shared_catalog(self):
        # recovery.py lleva una copia porque se despliega solo. Si el catálogo ya trae `noPrompt`,
        # la copia no puede decir otra cosa.
        catalog = json.loads((_REPO / "Packages/CMUXAgentLaunch/Sources/CMUXAgentLaunch/Resources/agent-resume-v1.json")
                             .read_text(encoding="utf-8"))["providers"]
        compared = 0
        for catalog_id, wire in (("claude", "claude"), ("codex", "codex"), ("antigravity", "agy"), ("grok", "grok")):
            policy = catalog.get(catalog_id, {}).get("noPrompt")
            if policy is None:
                continue
            compared += 1
            self.assertEqual(policy, recovery.NO_PROMPT.get(wire), wire)
        if compared == 0:
            self.skipTest("el catálogo todavía no trae noPrompt")


class NoPromptFlagsTest(unittest.TestCase):
    """Every recovered agent must come back without asking for permissions."""

    def test_claude_is_resumed_with_its_id_and_skip_permissions_at_the_end(self):
        with patch.object(recovery, "claude_executable", return_value="/usr/bin/claude"):
            argv = recovery.command_for({"agent": "claude", "sessionId": "abc", "cwd": "/tmp"})
        self.assertEqual(argv, ["/usr/bin/claude", "--resume", "abc", "--dangerously-skip-permissions"])

    def test_codex_is_resumed_in_yolo_with_folder_model_and_effort(self):
        with patch.object(recovery.shutil, "which", return_value="/usr/bin/codex"):
            argv = recovery.command_for({"agent": "codex", "sessionId": "t1", "cwd": "/w", "model": "m", "reasoningEffort": "max"})
        self.assertEqual(argv, ["/usr/bin/codex", "--yolo", "resume", "t1", "-C", "/w", "-m", "m",
                                "-c", 'model_reasoning_effort="max"'])

    def test_gemini_is_resumed_skipping_permissions(self):
        with patch.object(recovery.shutil, "which", return_value="/usr/bin/agy"):
            argv = recovery.command_for({"agent": "agy", "sessionId": "g1", "cwd": "/w"})
        self.assertEqual(argv, ["/usr/bin/agy", "--dangerously-skip-permissions", "--conversation", "g1"])

    def test_grok_is_resumed_with_its_own_syntax(self):
        with patch.object(recovery.shutil, "which", return_value="/usr/bin/grok"):
            argv = recovery.command_for({"agent": "grok", "sessionId": "k1", "cwd": "/w"})
        self.assertEqual(argv, ["/usr/bin/grok", "-r", "k1"])

    def test_an_unknown_agent_is_an_error_not_antigravity(self):
        # Antes cualquier agente desconocido caía en la rama de agy.
        with patch.object(recovery.shutil, "which", return_value="/usr/bin/agy"):
            with self.assertRaises(ValueError):
                recovery.command_for({"agent": "copiloto", "sessionId": "x1", "cwd": "/w"})

    def test_grok_is_not_checked_against_a_conversation_file(self):
        with tempfile.TemporaryDirectory() as cwd:
            recovery.verify_session({"agent": "grok", "sessionId": "k1", "cwd": cwd})

    def test_plain_commands_run_through_a_login_shell(self):
        self.assertEqual(recovery.command_for({"agent": "command", "command": "python bot.py", "cwd": "/w"}),
                         ["bash", "-lc", "python bot.py"])

    def test_claude_as_root_is_told_it_is_sandboxed(self):
        # Claude refuses its no-prompt flag as root unless IS_SANDBOX is set.
        with patch.object(recovery.os, "geteuid", return_value=0):
            self.assertEqual(recovery.environment_for({"agent": "claude"}).get("IS_SANDBOX"), "1")
        with patch.object(recovery.os, "geteuid", return_value=1000):
            env = recovery.environment_for({"agent": "claude"})
            self.assertEqual(env.get("IS_SANDBOX"), os.environ.get("IS_SANDBOX"))

    def test_codex_as_root_gets_no_sandbox_variable(self):
        with patch.object(recovery.os, "geteuid", return_value=0):
            self.assertEqual(recovery.environment_for({"agent": "codex"}).get("IS_SANDBOX"), os.environ.get("IS_SANDBOX"))

    def test_claude_folder_is_trusted_ahead_of_the_launch(self):
        with tempfile.TemporaryDirectory() as home:
            config = Path(home) / ".claude.json"
            config.write_text(json.dumps({"projects": {}}))
            with patch.object(recovery.Path, "home", return_value=Path(home)):
                recovery.trust_folder_for_claude(home)
            self.assertTrue(json.loads(config.read_text())["projects"][os.path.realpath(home)]["hasTrustDialogAccepted"])


class ForgetOrRecreateTest(unittest.TestCase):
    """A window missing on purpose is forgotten; a crash or a reboot brings everything back."""

    def _data(self, boot, names=("a", "b")):
        return {"tmuxSocket": "s", "seen": {"bootId": boot, "sessions": list(names)},
                "windows": [{"tmux": n, "sessionId": n} for n in names]}

    def test_one_window_gone_on_the_same_boot_was_closed_by_hand(self):
        data = self._data("boot-1")
        with patch.object(recovery, "boot_id", return_value="boot-1"), \
             patch.object(recovery, "tmux", return_value=recovery.subprocess.CompletedProcess([], 0, "", "")):
            self.assertTrue(recovery.missing_is_deliberate(data, [data["windows"][0]]))

    def test_every_window_gone_means_the_server_died(self):
        data = self._data("boot-1")
        with patch.object(recovery, "boot_id", return_value="boot-1"), \
             patch.object(recovery, "tmux", return_value=recovery.subprocess.CompletedProcess([], 1, "", "")):
            self.assertFalse(recovery.missing_is_deliberate(data, data["windows"]))

    def test_a_new_boot_brings_everything_back(self):
        data = self._data("boot-1")
        with patch.object(recovery, "boot_id", return_value="boot-2"), \
             patch.object(recovery, "tmux", return_value=recovery.subprocess.CompletedProcess([], 0, "", "")):
            self.assertFalse(recovery.missing_is_deliberate(data, [data["windows"][0]]))

    def test_all_windows_of_one_socket_gone_means_that_server_died(self):
        # Dos servidores vigilados: que falten todas las de uno es su caída, aunque el otro siga.
        data = {"tmuxSocket": "a", "tmuxSockets": ["a", "b"], "seen": {"bootId": "boot-1"},
                "windows": [{"tmux": "x", "tmuxSocket": "a"}, {"tmux": "y", "tmuxSocket": "b"}, {"tmux": "z", "tmuxSocket": "b"}]}
        with patch.object(recovery, "boot_id", return_value="boot-1"), \
             patch.object(recovery, "tmux", return_value=recovery.subprocess.CompletedProcess([], 0, "", "")):
            self.assertFalse(recovery.missing_is_deliberate(data, [data["windows"][0]]))
            self.assertTrue(recovery.missing_is_deliberate(data, [data["windows"][1]]))


class FakeTmux:
    """tmux de mentira: sesiones por socket, dueño de cada una y registro de llamadas."""

    def __init__(self, sessions):
        self.sessions = sessions  # {socket: {name: owner}}
        self.calls = []

    def __call__(self, socket, *args, check=True):
        self.calls.append((socket,) + args)
        live = self.sessions.setdefault(socket, {})
        name = args[args.index("-t") + 1].lstrip("=").rstrip(":") if "-t" in args else None
        if args[0] == "has-session":
            return subprocess.CompletedProcess(args, 0 if name in live else 1, "", "")
        if args[0] == "show-option":
            return subprocess.CompletedProcess(args, 0, (live.get(name) or "") + "\n", "")
        if args[0] == "list-panes" and "-a" not in args:
            return subprocess.CompletedProcess(args, 0, "%1\t0\n", "")
        if args[0] == "list-panes":
            return subprocess.CompletedProcess(args, 0, "", "")
        if args[0] == "list-sessions":
            # Como tmux de verdad: sin sesiones no hay servidor, y lo dice.
            return subprocess.CompletedProcess(args, 0 if live else 1, "", "" if live else "no server running on /tmp/tmux-0/" + socket)
        if args[0] == "new-session":
            live[args[args.index("-s") + 1]] = ""
            return subprocess.CompletedProcess(args, 0, "", "")
        if args[0] == "set-option" and "@uniconnect_session_id" in args:
            live[name] = args[-1]
        return subprocess.CompletedProcess(args, 0, "", "")

    def mutations(self):
        return [c for c in self.calls if c[1] in ("set-option", "set-window-option", "respawn-pane", "new-session", "kill-session")]


class EnsureTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.manifest = Path(self.directory.name) / "manifest.json"
        self.cwd = self.directory.name

    def tearDown(self):
        self.directory.cleanup()

    def write(self, data):
        self.manifest.write_text(json.dumps(data))
        return data

    def entry(self, name, **extra):
        return {"name": name, "tmux": name, "agent": "claude", "sessionId": name + "-id", "cwd": self.cwd, **extra}

    def test_a_learned_session_without_owner_is_adopted_and_the_rest_still_processed(self):
        data = self.write({"tmuxSocket": "s", "windows": [self.entry("aprendida"), self.entry("nueva")]})
        fake = FakeTmux({"s": {"aprendida": ""}})
        with patch.object(recovery, "tmux", side_effect=fake), \
             patch.object(recovery, "verify_session"), patch.object(recovery, "command_for"), \
             patch.object(recovery, "boot_id", return_value="boot-1"):
            recovery.ensure_windows(data, self.manifest)
        stored = {w["tmux"]: w for w in json.loads(self.manifest.read_text())["windows"]}
        self.assertTrue(stored["aprendida"]["adopted"])
        self.assertIn("nueva", fake.sessions["s"])
        # A la adoptada no se le tocó nada.
        self.assertFalse([c for c in fake.mutations() if "aprendida" in " ".join(c)])

    def test_a_broken_entry_is_isolated(self):
        data = self.write({"tmuxSocket": "s", "windows": [self.entry("rota"), self.entry("sana")]})
        fake = FakeTmux({"s": {}})

        def verify(entry):
            if entry["tmux"] == "rota":
                raise ValueError("Falta la conversación original de Claude")

        with patch.object(recovery, "tmux", side_effect=fake), \
             patch.object(recovery, "verify_session", side_effect=verify), patch.object(recovery, "command_for"), \
             patch.object(recovery, "boot_id", return_value="boot-1"):
            recovery.ensure_windows(data, self.manifest)
        self.assertNotIn("rota", fake.sessions["s"])
        self.assertIn("sana", fake.sessions["s"])

    def test_no_set_clipboard_on_a_server_that_was_already_alive(self):
        # D4: el servidor ya tiene otra sesión viva, así que una opción -s le afectaría: no se pone
        # ni suelta ni con el new-session de la que faltaba.
        data = self.write({"tmuxSocket": "s", "windows": [self.entry("viva"), self.entry("caida")]})
        fake = FakeTmux({"s": {"viva": "viva-id"}})
        with patch.object(recovery, "tmux", side_effect=fake), \
             patch.object(recovery, "verify_session"), patch.object(recovery, "command_for"), \
             patch.object(recovery, "boot_id", return_value="boot-1"):
            recovery.ensure_windows(data, self.manifest)
        self.assertEqual([c for c in fake.calls if "set-clipboard" in c], [])
        self.assertIn("caida", fake.sessions["s"])
        self.assertFalse([c for c in fake.mutations() if "=viva" in " ".join(c) or "=viva:" in " ".join(c)])

    def test_set_clipboard_only_with_the_new_session_that_starts_the_server(self):
        data = self.write({"tmuxSocket": "s", "windows": [self.entry("caida")]})
        fake = FakeTmux({"s": {}})
        with patch.object(recovery, "tmux", side_effect=fake), \
             patch.object(recovery, "verify_session"), patch.object(recovery, "command_for"), \
             patch.object(recovery, "boot_id", return_value="boot-1"):
            recovery.ensure_windows(data, self.manifest)
        clipboard = [c for c in fake.calls if "set-clipboard" in c]
        self.assertEqual([c[1] for c in clipboard], ["new-session"])

    def test_two_watched_sockets(self):
        data = self.write({"tmuxSocket": "uniconnect", "tmuxSockets": ["uniconnect", "default"],
                           "windows": [self.entry("a"), self.entry("b", tmuxSocket="default")]})
        fake = FakeTmux({"uniconnect": {}, "default": {"otra": ""}})
        with patch.object(recovery, "tmux", side_effect=fake), \
             patch.object(recovery, "verify_session"), patch.object(recovery, "command_for"), \
             patch.object(recovery, "boot_id", return_value="boot-1"):
            recovery.ensure_windows(data, self.manifest)
        self.assertIn("a", fake.sessions["uniconnect"])
        self.assertIn("b", fake.sessions["default"])
        self.assertNotIn("b", fake.sessions["uniconnect"])
        self.assertEqual(recovery.watched_sockets(data), ["uniconnect", "default"])
        # La ventana nueva se lanza sabiendo en qué servidor vive.
        created = [c for c in fake.calls if c[1] == "new-session" and c[0] == "default"][0]
        self.assertIn("--socket default", " ".join(created))


class SnapshotTest(unittest.TestCase):
    """The manifest learns the sessions that exist, so a window created later is protected too."""

    def _readers(self):
        return FixtureReaders("/root", [
            {"pid": 42, "ppid": 1, "uid": 0, "argv": ["-bash"]},
            {"pid": 43, "ppid": 42, "uid": 0, "argv": ["claude", "--dangerously-skip-permissions"]},
        ], fichas={"43": {"sessionId": "473ed1de-4397-45ef-b00b-6b17fd7382b0", "cwd": "/root/xunis"}})

    def test_learns_a_new_claude_session_from_its_process(self):
        with tempfile.TemporaryDirectory() as directory:
            manifest = Path(directory) / "manifest.json"
            data = {"tmuxSocket": "s", "windows": []}
            manifest.write_text(json.dumps(data))
            panes = {"new": [{"pane_pid": 42, "dead": False, "cwd": "/root"}]}
            with patch.object(recovery, "live_sessions", return_value=panes), \
                 patch.object(recovery, "boot_id", return_value="boot-1"):
                recovery.snapshot(data, manifest, self._readers())
            stored = json.loads(manifest.read_text())
            window = stored["windows"][0]
            self.assertEqual((window["tmux"], window["tmuxSocket"], window["agent"], window["sessionId"], window["cwd"],
                              window["source"], window["asRoot"]),
                             ("new", "s", "claude", "473ed1de-4397-45ef-b00b-6b17fd7382b0", "/root/xunis", "ficha", True))
            self.assertEqual(stored["seen"]["bootId"], "boot-1")

    def test_merges_onto_the_manifest_on_disk(self):
        # Mientras el supervisor daba la vuelta alguien olvidó una ventana y editó otra a mano.
        with tempfile.TemporaryDirectory() as directory:
            manifest = Path(directory) / "manifest.json"
            data = {"tmuxSocket": "s", "windows": [{"tmux": "vieja", "agent": "codex", "sessionId": "v"},
                                                  {"tmux": "editada", "agent": "codex", "sessionId": "e"}]}
            manifest.write_text(json.dumps({"tmuxSocket": "s", "windows": [
                {"tmux": "editada", "agent": "codex", "sessionId": "e", "model": "puesto-a-mano"}]}))
            panes = {"new": [{"pane_pid": 42, "dead": False, "cwd": "/root"}]}
            with patch.object(recovery, "live_sessions", return_value=panes), \
                 patch.object(recovery, "boot_id", return_value="boot-1"):
                recovery.snapshot(data, manifest, self._readers())
            stored = {w["tmux"]: w for w in json.loads(manifest.read_text())["windows"]}
            self.assertEqual(set(stored), {"editada", "new"})
            self.assertEqual(stored["editada"]["model"], "puesto-a-mano")

    def test_an_ambiguous_or_idless_session_leaves_the_stored_one_alone(self):
        with tempfile.TemporaryDirectory() as directory:
            manifest = Path(directory) / "manifest.json"
            stored_entry = {"tmux": "s1", "agent": "claude", "sessionId": "714b0eae-b568-4e0c-a70b-c87c0d0a801a", "cwd": "/w"}
            data = {"tmuxSocket": "s", "windows": [dict(stored_entry)]}
            manifest.write_text(json.dumps(data))
            readers = FixtureReaders("/home/dani", [
                {"pid": 42, "ppid": 1, "uid": 1000, "argv": ["-bash"]},
                {"pid": 43, "ppid": 42, "uid": 1000, "argv": ["claude", "login"]},
            ])
            with patch.object(recovery, "live_sessions", return_value={"s1": [{"pane_pid": 42, "dead": False, "cwd": "/w"}]}), \
                 patch.object(recovery, "boot_id", return_value="boot-1"):
                recovery.snapshot(data, manifest, readers)
            self.assertEqual(json.loads(manifest.read_text())["windows"][0]["sessionId"], stored_entry["sessionId"])


class SuperviseTest(unittest.TestCase):
    def test_the_manifest_is_read_again_on_every_round(self):
        with tempfile.TemporaryDirectory() as directory:
            manifest = Path(directory) / "manifest.json"
            manifest.write_text(json.dumps({"tmuxSocket": "s", "windows": [{"tmux": "a"}]}))
            seen = []
            with patch.object(recovery, "ensure_windows", side_effect=lambda data, path: seen.append([w["tmux"] for w in data["windows"]])), \
                 patch.object(recovery, "snapshot"):
                recovery.supervise_once(manifest)
                # `forget` desde otra consola entre dos vueltas.
                manifest.write_text(json.dumps({"tmuxSocket": "s", "windows": []}))
                recovery.supervise_once(manifest)
            self.assertEqual(seen, [["a"], []])


class StatusTest(unittest.TestCase):
    def test_status_tells_socket_source_and_resume_command(self):
        data = {"tmuxSocket": "default", "windows": [{"tmux": "claudebets", "agent": "claude", "sessionId": "473ed1de-4397-45ef-b00b-6b17fd7382b0",
                                                      "cwd": "/root/xunis", "source": "ficha", "asRoot": True}]}
        printed = []
        with patch.object(recovery, "live_sessions", return_value={}), \
             patch.object(recovery, "native_session_available", return_value=True), \
             patch("builtins.print", side_effect=lambda text, **kw: printed.append(text)):
            recovery.status(data)
        row = json.loads(printed[0])["windows"][0]
        self.assertEqual(row["socket"], "default")
        self.assertEqual(row["source"], "ficha")
        self.assertEqual(row["resumeCommand"],
                         "cd -- '/root/xunis' && IS_SANDBOX=1 claude --resume 473ed1de-4397-45ef-b00b-6b17fd7382b0 --dangerously-skip-permissions")


if __name__ == "__main__":
    unittest.main()
