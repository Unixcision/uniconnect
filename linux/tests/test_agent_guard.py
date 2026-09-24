"""Guarda de conversación abierta: se ejecuta de verdad, con HOME y fichas en directorios temporales."""

import base64
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

GUARD = Path(__file__).resolve().parents[1] / "uniconnect" / "agent_guard.py"
BOOT = "import base64,sys;s=sys.argv.pop(1);exec(base64.b64decode(s))"
SESSION = "473ed1de-4397-45ef-b00b-6b17fd7382b0"


class AgentGuardTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="uc-guard-")
        self.home = Path(self.directory.name)
        self.sessions = self.home / ".claude" / "sessions"
        self.sessions.mkdir(parents=True)
        self.children = []

    def tearDown(self):
        for child in self.children:
            child.kill()
            child.wait(timeout=5)
        os.chmod(self.sessions, 0o700)
        self.directory.cleanup()

    def guard(self, provider, session, *, bootstrap=False):
        environment = {key: value for key, value in os.environ.items() if key != "CLAUDE_CONFIG_DIR"}
        environment["HOME"] = str(self.home)
        if bootstrap:
            argv = [sys.executable, "-c", BOOT, base64.b64encode(GUARD.read_bytes()).decode(), provider, session]
        else:
            argv = [sys.executable, str(GUARD), provider, session]
        return subprocess.run(argv, env=environment, capture_output=True, timeout=30).returncode

    def spawn_named(self, name):
        # argv[0] termina en el nombre del proveedor, como el binario real.
        link = self.home / "bin" / name
        link.parent.mkdir(exist_ok=True)
        if not link.exists():
            link.symlink_to("/bin/sleep")
        child = subprocess.Popen([str(link), "60"])
        self.children.append(child)
        return child.pid

    def ficha(self, pid, session=SESSION):
        (self.sessions / ("%d.json" % pid)).write_text(json.dumps({"pid": pid, "sessionId": session, "cwd": "/x"}))

    def test_is_small_enough_to_travel_inside_a_tmux_command(self):
        self.assertLess(GUARD.stat().st_size, 1536)

    def test_live_claude_ficha_means_open(self):
        self.ficha(self.spawn_named("claude"), SESSION.upper())
        self.assertEqual(self.guard("claude", SESSION), 1)
        self.assertEqual(self.guard("claude", SESSION, bootstrap=True), 1)
        self.assertEqual(self.guard("claude", "0d8f0000-0000-4000-8000-000000000000"), 0)

    def test_dead_or_foreign_pid_ficha_is_free(self):
        finished = subprocess.Popen([sys.executable, "-c", "pass"])
        finished.wait(timeout=10)
        self.ficha(finished.pid)
        self.assertEqual(self.guard("claude", SESSION), 0)
        (self.sessions / ("%d.json" % finished.pid)).unlink()
        self.ficha(self.spawn_named("vim"))  # PID vivo, pero no es Claude: PID reciclado.
        self.assertEqual(self.guard("claude", SESSION), 0)
        (self.sessions / "roto.json").write_text("{no es json")
        self.assertEqual(self.guard("claude", SESSION), 0)

    def spawn_as(self, name, *arguments):
        """Un /bin/bash real que se presenta como ``name`` (argv[0]) con ``arguments`` detrás.

        bash conserva argv[0] en macOS y Linux (el python de framework del Mac se reejecuta y lo pierde).
        """
        child = subprocess.Popen([name, "-c", "echo listo; sleep 60; :", *arguments], executable="/bin/bash",
                                 stdout=subprocess.PIPE)
        self.children.append(child)
        self.assertEqual(child.stdout.readline().strip(), b"listo")
        return child.pid

    def test_strict_claude_criterion_like_detection(self):
        # contracts/agent-tree-v1 (guarda): la ficha de un pid reciclado que ahora es `vim CLAUDE.md`
        # no bloquea; un Claude de npm lanzado por su shebang (`node …/bin/claude`) sí.
        self.ficha(self.spawn_as("vim", str(self.home / ".claude" / "CLAUDE.md")))
        self.assertEqual(self.guard("claude", SESSION), 0)
        for path in self.sessions.glob("*.json"):
            path.unlink()
        self.ficha(self.spawn_as("node", "/opt/homebrew/bin/claude"))
        self.assertEqual(self.guard("claude", SESSION), 1)

    def test_missing_directory_is_free_and_unreadable_directory_cannot_be_checked(self):
        empty = tempfile.TemporaryDirectory(prefix="uc-guard-empty-")
        self.addCleanup(empty.cleanup)
        environment = dict(os.environ, HOME=empty.name)
        environment.pop("CLAUDE_CONFIG_DIR", None)
        process = subprocess.run([sys.executable, str(GUARD), "claude", SESSION], env=environment, timeout=30)
        self.assertEqual(process.returncode, 0)
        if os.geteuid() == 0:
            self.skipTest("root puede leer cualquier directorio")
        os.chmod(self.sessions, 0)
        self.assertEqual(self.guard("claude", SESSION), 2)

    def test_invalid_input_or_unknown_provider_is_never_free(self):
        self.assertEqual(self.guard("claude", "../../etc"), 2)
        self.assertEqual(self.guard("desconocida", SESSION), 2)
        process = subprocess.run([sys.executable, str(GUARD)], env=dict(os.environ, HOME=str(self.home)), timeout=30)
        self.assertEqual(process.returncode, 2)

    def test_codex_without_proc_cannot_be_checked(self):
        if os.path.isdir("/proc/self"):
            self.skipTest("este host tiene /proc")
        self.assertEqual(self.guard("codex", SESSION), 2)
        self.assertEqual(self.guard("grok", "conv_1"), 2)

    @unittest.skipUnless(os.path.isdir("/proc/self/fd"), "necesita /proc (Linux)")
    def test_codex_rollout_open_by_a_process_means_open(self):
        rollout = self.home / ".codex" / "sessions" / "2026" / "09" / "24" / ("rollout-2026-09-24T10-00-00-%s.jsonl" % SESSION)
        rollout.parent.mkdir(parents=True)
        rollout.write_text("{}\n")
        self.assertEqual(self.guard("codex", SESSION), 0)
        holder = subprocess.Popen([sys.executable, "-c", "import sys,time;f=open(sys.argv[1]);print('listo',flush=True);time.sleep(60)",
                                   str(rollout)], stdout=subprocess.PIPE)
        self.children.append(holder)
        self.assertEqual(holder.stdout.readline().strip(), b"listo")
        self.assertEqual(self.guard("codex", SESSION), 1)

    @unittest.skipUnless(os.path.isdir("/proc/self/fd"), "necesita /proc (Linux)")
    def test_agy_and_grok_are_open_when_a_provider_process_carries_the_id(self):
        self.assertEqual(self.guard("grok", "conv_1"), 0)
        holder = subprocess.Popen(["grok", "-c", "print('listo',flush=True);import time;time.sleep(60)", "-r", "conv_1"],
                                  executable=sys.executable, stdout=subprocess.PIPE)
        self.children.append(holder)
        self.assertEqual(holder.stdout.readline().strip(), b"listo")
        self.assertEqual(self.guard("grok", "conv_1"), 1)
        self.assertEqual(self.guard("agy", "conv_1"), 0)


if __name__ == "__main__":
    unittest.main()
