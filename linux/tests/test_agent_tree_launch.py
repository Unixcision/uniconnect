"""agent-tree-v1 (08-11): las opciones de lanzamiento se capturan, se guardan sin secretos, se usan
al reanudar tras un apagado, y el árbol completo queda en `agent-tree.json` en cada guardado."""

import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import unittest

from test_agent_tree import CLAUDE_ID, TreeFixture
from uniconnect import agent_probe
from uniconnect.agent_tree_document import build
from uniconnect.resume_catalog import AgentResumeCatalog
from uniconnect.state import StateStore
from uniconnect.transport import TmuxCommand

BOOTSTRAP = 'import base64,os,zlib;exec(zlib.decompress(base64.b64decode(os.environ["UNICONNECT_NATIVE_HELPER"])))'


class LaunchOptionsProbeTests(unittest.TestCase):
    def test_keeps_only_allowlisted_options_in_order_without_selector_prompt_or_secrets(self):
        cases = {
            ("claude", "--resume", CLAUDE_ID, "--dangerously-skip-permissions", "--model", "opus",
             "--append-system-prompt", "secreto", "haz esto"): ["--dangerously-skip-permissions", "--model", "opus"],
            ("codex", "--yolo", "resume", CLAUDE_ID, "-m", "gpt-6", "-c", "model_reasoning_effort=high",
             "-c", "model_providers.x.api_key=sk-123", "--no-alt-screen"):
                ["--yolo", "-m", "gpt-6", "-c", "model_reasoning_effort=high", "--no-alt-screen"],
            ("node", "/usr/bin/codex", "-a", "never", "-s", "danger-full-access", "--raro", "valor"):
                ["-a", "never", "-s", "danger-full-access"],
            ("codex", "-c", "notify=" + json.dumps(["/usr/bin/python3", "-c", BOOTSTRAP, "signal"]), "--search"):
                ["--search"],  # El gancho que UniConnect monta en cada arranque no se guarda.
            ("agy", "--conversation", "conv-1", "--model", "m", "--sandbox", "--sandbox"): ["--model", "m", "--sandbox"],
            ("claude", "--continue", "-c", "--", "--model", "texto"): [],  # Tras «--» todo es texto para la IA.
        }
        for argv, expected in cases.items():
            with self.subTest(argv=argv):
                provider = agent_probe.provider_of(list(argv))
                self.assertEqual(agent_probe.launch_options(provider, list(argv)), expected)
        self.assertIsNone(agent_probe.launch_options("grok", ["grok", "-r", "x"]))

    def test_only_is_sandbox_is_read_from_the_environment(self):
        child = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)"],
                                 env=dict(os.environ, IS_SANDBOX="1", SECRETO="no"))
        plain = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)"],
                                 env={k: v for k, v in os.environ.items() if k != "IS_SANDBOX"})
        try:
            reader = agent_probe.HostReader()
            if not reader.proc:
                self.skipTest("/proc required")
            self.assertIs(reader.sandbox(child.pid), True)
            self.assertIs(reader.sandbox(plain.pid), False)
            self.assertIsNone(reader.sandbox(2 ** 22 + 7))  # Un pid que no existe: no se sabe.
        finally:
            for process in (child, plain):
                process.kill()
                process.wait(timeout=5)


class LaunchOptionsTreeTests(TreeFixture):
    ENTRY = {"reason": None, "agent": {"provider": "claude", "session_id": CLAUDE_ID, "cwd": "/root", "as_root": True,
                                       "source": "ficha", "launch": {"arguments": ["--dangerously-skip-permissions"],
                                                                     "is_sandbox": True}}}

    def test_saved_once_and_only_rewritten_when_the_options_change(self):
        record = self.remote
        self.assertTrue(self.tree.transition(record, self.ENTRY))
        self.assertEqual(record["launchOptions"], {"options": ["--dangerously-skip-permissions"], "isSandbox": True,
                                                   "source": "argv", "capturedAt": 1790260204.0})
        self.assertFalse(self.tree.transition(record, self.ENTRY))  # Mismas opciones: nada que guardar.
        changed = json.loads(json.dumps(self.ENTRY))
        changed["agent"]["launch"]["arguments"].extend(["--model", "opus"])
        self.assertTrue(self.tree.transition(record, changed))
        self.assertEqual(record["launchOptions"]["options"], ["--dangerously-skip-permissions", "--model", "opus"])

    def test_options_survive_the_state_cleaning_and_reach_agent_tree_json(self):
        self.tree.transition(self.remote, self.ENTRY)
        self.store.data["workspaces"][1]["hostLabel"] = "root@167.233.192.135:22"
        self.store.save()
        self.assertEqual(self.saved("w-remote")["launchOptions"]["options"], ["--dangerously-skip-permissions"])
        tree = json.loads((self.store.root / "agent-tree.json").read_text())
        self.assertEqual(oct((self.store.root / "agent-tree.json").stat().st_mode & 0o777), "0o600")
        window = next(w for box in tree["workspaces"] for w in box["windows"] if w["id"] == "w-remote")
        self.assertEqual((window["kind"], window["host_label"]), ("ssh", "root@167.233.192.135:22"))
        self.assertEqual(window["agent"]["launch"]["arguments"], ["--dangerously-skip-permissions"])
        self.assertEqual(window["agent"]["launch"]["environment"], {"IS_SANDBOX": "1"})
        self.assertEqual(window["agent"]["state"], "guardado")
        self.assertEqual(window["tmux"], {"socket": "default", "session": "claudebets", "session_id": None,
                                          "pane_id": None, "live": None})
        box = next(box for box in tree["workspaces"] if box["id"] == "box-ssh")
        self.assertEqual(box["host"], {"user": "root", "hostname": "167.233.192.135", "port": 22})
        self.assertNotIn("cred", json.dumps(tree))  # Ni la credencial ni su id.


class StoredOptionsResumeTests(unittest.TestCase):
    WINDOW = {"id": "w", "tmux": "t", "cwd": "/root", "agent": "claude", "sessionId": CLAUDE_ID}

    def test_resume_after_shutdown_uses_the_saved_options_not_the_no_prompt_policy(self):
        catalog = AgentResumeCatalog()
        saved = dict(self.WINDOW, launchOptions={"options": ["--model", "opus"], "isSandbox": False})
        self.assertEqual(catalog.window_argv(saved), ["claude", "--resume", CLAUDE_ID, "--model", "opus"])
        self.assertIn("--dangerously-skip-permissions", catalog.window_argv(self.WINDOW))  # Sin opciones: como antes.
        codex = {"id": "c", "tmux": "c", "cwd": "/w", "agent": "codex", "sessionId": CLAUDE_ID,
                 "launchOptions": {"options": ["-a", "never"], "isSandbox": False}}
        self.assertEqual(catalog.window_argv(codex), ["codex", "resume", CLAUDE_ID, "-a", "never", "--no-alt-screen"])

    def test_is_sandbox_comes_back_only_if_it_ran_sandboxed(self):
        def script(window):
            return shlex.split(TmuxCommand.pane_command(window))[2]
        sandboxed = dict(self.WINDOW, launchOptions={"options": ["--dangerously-skip-permissions"], "isSandbox": True})
        self.assertIn("export IS_SANDBOX=1;", script(sandboxed))
        plain = dict(self.WINDOW, launchOptions={"options": [], "isSandbox": False})
        self.assertNotIn("IS_SANDBOX", script(plain))
        self.assertIn('[ "$(id -u)" = 0 ] && export IS_SANDBOX=1;', script(self.WINDOW))  # Sin opciones: como antes.

    def test_damaged_saved_options_are_dropped_instead_of_breaking_the_launch(self):
        for damaged in ({"options": "x"}, {"options": ["a\nb"]}, {"options": ["x"] * 65}, {"options": [], "isSandbox": "sí"}):
            with self.subTest(damaged=damaged):
                window = TmuxCommand.validate_window(dict(self.WINDOW, launchOptions=damaged))
                self.assertNotIn("launchOptions", window)


class DocumentTests(unittest.TestCase):
    def test_document_never_carries_live_tmux_ids_or_unknown_sources(self):
        data = {"workspaces": [{"id": "b", "name": "B", "kind": "local", "windows": [
            {"id": "w", "name": "W", "tmux": "s", "agent": "antigravity", "sessionId": "c1", "agentSource": "raro",
             "interrupted": True, "agentObservedAt": 0, "history": [{"agent": "antigravity", "sessionId": "c0"}]},
            {"id": "x", "name": "X", "agent": "shell"}]}]}
        tree = build(data, machine_id="MINIPC", now=1790260204)
        first, second = tree["workspaces"][0]["windows"]
        self.assertEqual(tree["platform"], "linux")
        self.assertEqual(tree["checked_at"], "2026-09-24T14:30:04Z")
        self.assertEqual(first["agent"]["provider"], "agy")
        self.assertEqual(first["agent"]["source"], "registro")
        self.assertEqual(first["agent"]["state"], "interrumpido")
        self.assertIsNone(first["agent"]["observed_at"])
        self.assertEqual(first["agent"]["history"][0]["provider"], "agy")
        self.assertEqual(first["tmux"]["socket"], "uniconnect-local")
        self.assertIsNone(second["tmux"])
        self.assertIsNone(second["agent"])


if __name__ == "__main__":
    unittest.main()
