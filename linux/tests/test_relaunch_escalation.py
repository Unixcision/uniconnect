"""relaunch-v1 «Escalado y mismas opciones» (08-11) contra procesos y tmux reales, en servidores privados.

Una IA que no sale con /exit se mata (solo su árbol), un pane sin shell recibe un shell de
login limpio con respawn-pane, y una sesión que ya no está se recrea con sus opciones. Nunca
se toca el servidor tmux ni nada fuera del árbol de la IA.
"""

import base64
import copy
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock
import uuid

from test_relaunch_agents import PROVIDER
from uniconnect import relaunch_worker
from uniconnect.relaunch_worker import TargetWorker, TmuxOutputEvents, Unavailable

# El mismo Codex falso, pero «terco» con UC_FIXTURE_STUBBORN: ignora /exit (como una IA colgada).
STUBBORN = PROVIDER.replace('!strcmp(input, "/exit\\n")', '!strcmp(input, "/exit\\n") && !getenv("UC_FIXTURE_STUBBORN")')
assert STUBBORN != PROVIDER


@unittest.skipUnless(Path("/proc").exists() and shutil.which("tmux") and shutil.which("cc")
                     and hasattr(os, "pidfd_open"), "Linux with tmux, cc and pidfd required")
class EscalationTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory(prefix="uc-escalation-")
        self.root = Path(self.folder.name)
        self.socket = "uc-escalation-" + uuid.uuid4().hex[:10]
        self.binary = ["tmux", "-L", self.socket]
        # Login shells of the respawn read this, not root's real profile.
        self.env = dict(os.environ, SHELL="/bin/sh", HOME=str(self.root), ENV="")
        for name in ("TMUX", "TMUX_PANE"):
            self.env.pop(name, None)

    def tearDown(self):
        subprocess.run(self.binary + ["kill-server"], capture_output=True, timeout=5)
        self.folder.cleanup()

    def tmux(self, *args):
        return subprocess.run(self.binary + list(args), check=True, capture_output=True, text=True,
                              timeout=5, env=self.env).stdout.strip()

    def codex(self, native, *, stubborn=False):
        executable = self.root / "codex"
        subprocess.run(["cc", "-x", "c", "-", "-o", str(executable)], input=STUBBORN, text=True,
                       capture_output=True, check=True, timeout=30)
        (self.root / ".codex/thread-writer-locks").mkdir(parents=True, exist_ok=True)
        transcripts = self.root / ".codex/sessions/2026/09/14"
        transcripts.mkdir(parents=True, exist_ok=True)
        (transcripts / ("rollout-fixture-" + native + ".jsonl")).write_text("\n".join(json.dumps(row) for row in (
            {"type": "session_meta", "payload": {"id": native}},
            {"type": "turn_context", "payload": {"turn_id": "t", "model": "fixture-model", "cwd": str(self.root),
                                                 "sandbox_policy": {"type": "danger-full-access"},
                                                 "approval_policy": "never"}},
            {"type": "event_msg", "payload": {"type": "task_complete", "turn_id": "t"}})) + "\n")
        return shlex.join(["env", "UC_FIXTURE_ID=" + native, "UC_FIXTURE_ROOT=" + str(self.root),
                           *(["UC_FIXTURE_STUBBORN=1"] if stubborn else []), str(executable), "--yolo", "-m", "fixture-model"])

    def worker(self):
        return TargetWorker({"session": "fixture", "socket": self.socket, "provider": "codex", "verb": "agent.relaunch",
                             "window_id": "fixture", "identity_helper": base64.b64encode(b"pass").decode(),
                             "catalog": {"codex": {"resume": ["{executable}", "resume", "{sessionId}", "{arguments}"]}}})

    def planned(self, worker, events):
        deadline = time.monotonic() + 10
        while True:
            try:
                return worker.inspect()
            except (Unavailable, OSError):
                events.wait(deadline, time.monotonic)

    def relaunch(self, root_command, native, *, stubborn=False, typed=None):
        # As a list, never one string: tmux would run a string through ``sh -c`` and the pane's
        # root would be that sh (an unknown root, which respawns) instead of the shell itself.
        self.tmux("new-session", "-d", "-s", "fixture", "-c", str(self.root), *root_command)
        events = TmuxOutputEvents(self.binary, "fixture")
        try:
            if typed:
                self.tmux("send-keys", "-t", "=fixture:", "-l", typed + "\n")
            worker = self.worker()
            proof = self.planned(worker, events)
            worker.request["expected"] = copy.deepcopy(proof)  # respawn_pane updates its pane in place.
            journal = self.root / "journal.json"
            worker.write(journal, {"state": "planificado"})
            with mock.patch.object(relaunch_worker, "EXIT_SECONDS", 2):
                worker.perform(journal)
            after = worker.inspect()
            return proof, after, worker.read(journal)
        finally:
            events.close()

    def test_an_agent_that_ignores_exit_is_killed_and_reopened_in_the_same_shell(self):
        native = str(uuid.uuid4())
        proof, after, journal = self.relaunch(["/bin/bash", "--noprofile", "--norc", "-i"], native, stubborn=True,
                                              typed=self.codex(native, stubborn=True))
        self.assertEqual(journal, {"state": "verificado", "effective_id": native, "escalation": "kill_process"})
        self.assertEqual(after["pane"], proof["pane"])  # Mismo pane y mismo shell: solo murió la IA.
        self.assertEqual(after["effective_id"], native)
        self.assertNotEqual((after["pid"], after["start"]), (proof["pid"], proof["start"]))

    def test_an_agent_under_an_unknown_root_gets_a_fresh_login_shell_in_the_same_pane(self):
        native = str(uuid.uuid4())
        command = self.codex(native)
        # Un «supervisor» que no es un shell limpio: tras la IA se queda vivo.
        proof, after, journal = self.relaunch(["sh", "-c", command + "; sleep 300"], native)
        self.assertTrue(proof.get("respawn"))
        self.assertEqual(journal["escalation"], "respawn_pane")
        self.assertEqual(after["pane"]["pane"], proof["pane"]["pane"])  # Mismo id de pane...
        self.assertNotEqual(after["pane"]["pane_pid"], proof["pane"]["pane_pid"])  # ...con otro shell.
        root = TargetWorker.process(self.worker(), after["pane"]["pane_pid"])
        self.assertEqual(Path(root["argv"][0]).name.lstrip("-"), "sh")
        self.assertEqual(after["effective_id"], native)

    def test_a_missing_session_is_recreated_with_its_options_and_a_shell(self):
        native = str(uuid.uuid4())
        self.tmux("new-session", "-d", "-s", "fixture", "-c", str(self.root), "/bin/bash", "--noprofile", "--norc", "-i")
        self.tmux("new-session", "-d", "-s", "ajena", "/bin/sleep", "300")  # Otra sesión del mismo servidor.
        worker = self.worker()
        proof = {"pane": worker.pane()[0], "effective_id": native}
        events = TmuxOutputEvents(self.binary, "fixture")
        self.tmux("kill-session", "-t", "=fixture")  # Como si se hubiera caído.
        try:
            escalation, root, replaced = worker.respawn_pane(proof, {"cwd": str(self.root)},
                                                             self.root / "journal.json", events)
            replaced.close()
        finally:
            events.close()
        self.assertEqual(escalation, "recreate_session")
        self.assertEqual(Path(root["argv"][0]).name.lstrip("-"), "sh")
        self.assertEqual(self.tmux("show-options", "-qv", "-t", "=fixture:", "mouse"), "on")
        self.assertEqual(self.tmux("show-options", "-qv", "-t", "=fixture:", "@uniconnect_agent_owner"), "codex:" + native)
        self.assertEqual(self.tmux("display-message", "-p", "-t", "=fixture:", "#{pane_current_path}"),
                         str(self.root.resolve()))
        self.assertIn("ajena", self.tmux("list-sessions", "-F", "#{session_name}"))  # El servidor sigue entero.


@unittest.skipUnless(Path("/proc").exists() and hasattr(os, "pidfd_open"), "Linux pidfd required")
class TerminateTreeTests(unittest.TestCase):
    def test_kills_the_agent_and_its_children_even_if_they_ignore_sigterm_and_nothing_else(self):
        script = ("import os,signal,subprocess,sys,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); "
                  "child=subprocess.Popen([sys.executable,'-c','import signal,time; "
                  "signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(300)']); "
                  "print(child.pid, flush=True); time.sleep(300)")
        agent = subprocess.Popen([sys.executable, "-c", script], stdout=subprocess.PIPE, text=True)
        bystander = subprocess.Popen(["sleep", "300"])  # Hermano, no hijo: no se toca.
        try:
            child = int(agent.stdout.readline())
            worker = TargetWorker({"session": "fixture", "socket": "fixture"})
            started = time.monotonic()
            worker.terminate_tree(worker.process(agent.pid), grace=0.5)
            self.assertLess(time.monotonic() - started, 5)
            self.assertIsNotNone(agent.wait(timeout=2))  # Muerto (SIGKILL tras ignorar SIGTERM).
            with self.assertRaises(OSError):
                worker.process(child)  # El nieto también, aunque ya no sea hijo directo.
            self.assertIsNone(bystander.poll())
        finally:
            for process in (agent, bystander):
                if process.poll() is None:
                    process.kill()
                    process.wait(timeout=5)
            agent.stdout.close()


if __name__ == "__main__":
    unittest.main()
