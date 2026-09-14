"""Provider, fleet and isolated-process relaunch behavior; no real account used."""

import base64
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
import time
from types import SimpleNamespace
import unittest
import uuid

from uniconnect.relaunch_agents import RelaunchAgents
from uniconnect.relaunch_fleet import RelaunchFleet
from uniconnect.relaunch_worker import TargetWorker, Unavailable, TmuxOutputEvents
from uniconnect.resume_catalog import AgentResumeCatalog
from uniconnect.transport import Transport


class ArgumentsTests(unittest.TestCase):
    def setUp(self):
        self.catalog = AgentResumeCatalog().providers

    def test_replaces_effective_id_keeps_model_permissions_and_quoted_arguments(self):
        args = TargetWorker.resume_arguments("codex", ["/bin/codex", "resume", "-C", "/work with spaces",
            "-m", "model", "--sandbox", "workspace-write", "--ask-for-approval", "on-request", "old"], "current", self.catalog)
        self.assertEqual(args, ["/bin/codex", "resume", "current", "-C", "/work with spaces", "-m", "model",
                               "--sandbox", "workspace-write", "--ask-for-approval", "on-request"])
        args = TargetWorker.resume_arguments("claude", ["/bin/claude", "--resume", "old", "--model", "model",
            "--permission-mode", "default", "--append-system-prompt", "x; $(not a shell command)"], "current", self.catalog)
        self.assertEqual(args, ["/bin/claude", "--resume", "current", "--model", "model", "--permission-mode", "default",
                                "--append-system-prompt", "x; $(not a shell command)"])
        self.assertFalse(any("dangerously" in part for part in args))

    def test_prompt_subcommand_and_unknown_option_are_not_replayed(self):
        for argv in (["codex", "exec", "fix"], ["codex", "resume", "old", "do anything"],
                     ["codex", "--unknown"], ["claude", "--print", "prompt"], ["claude", "--resume"]):
            with self.subTest(argv=argv), self.assertRaises(Unavailable):
                TargetWorker.resume_arguments(argv[0], argv, "current", self.catalog)

    def test_managed_notify_is_not_duplicated_and_user_configuration_is_retained(self):
        from uniconnect.agent_identity_hook import BOOTSTRAP
        hook = json.dumps(["/usr/bin/python3", "-c", BOOTSTRAP, "signal"])
        args = TargetWorker.resume_arguments("codex", ["codex", "resume", "old", "-c", "notify=" + hook,
            "-c", 'model_reasoning_effort="high"'], "current", self.catalog)
        self.assertEqual(args, ["codex", "resume", "current", "-c", 'model_reasoning_effort="high"'])

    def test_unknown_provider_is_visible_but_does_not_issue_any_process_command(self):
        worker = TargetWorker({"session": "fixture", "socket": "fixture", "provider": "grok", "catalog": self.catalog})
        worker.pane = lambda: ({}, {}, "0", "")
        with self.assertRaises(Unavailable) as error:
            worker.inspect()
        self.assertEqual(error.exception.cause, "no_soportado")

    def test_footer_or_unknown_dialog_does_not_prove_an_empty_composer(self):
        worker = TargetWorker({"session": "fixture", "socket": "fixture"})
        for screen in ("some output\nbypass permissions", "❯ draft", "Do you trust this folder?\n❯ "):
            worker.tmux = lambda *args, screen=screen: (str(len(screen.splitlines()) - 1) if args[0] == "display-message" else screen)
            with self.assertRaises(Unavailable):
                worker.require_empty_composer({"pane": {"pane": "%1"}})

    def test_native_turn_activity_and_runtime_settings_are_required_before_exit(self):
        process = {"cwd": "/work", "argv": ["codex", "-m", "fixture-model", "-s", "read-only", "-a", "never"]}
        context = {"type": "turn_context", "payload": {"model": "fixture-model", "cwd": "/work",
                    "sandbox_policy": {"type": "read-only"}, "approval_policy": "never"}}
        complete = {"type": "event_msg", "payload": {"type": "task_complete"}}
        TargetWorker.validate_quiescence([context, complete], process)
        for rows in ([context], [context, complete, {"type": "event_msg", "payload": {"type": "task_started"}}],
                     [context, complete, {"type": "response_item", "payload": {"role": "user"}}],
                     [context, complete, {"type": "event_msg", "payload": {"type": "thread_settings_applied",
                         "thread_settings": {"model": "changed", "cwd": "/work", "approval_policy": "never"}}}]):
            with self.subTest(rows=rows), self.assertRaises(Unavailable):
                TargetWorker.validate_quiescence(rows, process)
        with self.assertRaises(Unavailable):
            TargetWorker.validate_quiescence([context, complete], {**process, "argv": ["codex"]})


class FleetTests(unittest.TestCase):
    def test_global_freezes_local_and_remote_machine_plans_and_shows_partial_failures(self):
        calls = []
        def call(address, method, params):
            calls.append((address, method, params))
            if address == "100.64.0.3":
                raise ConnectionError()
            if method == "host.status":
                return {"machine_id": "remote", "capabilities": ["relaunch.v1"]}
            if method == "relaunch.plan":
                return {"operation_id": address, "token": "token", "targets": [
                    {"key": "shared-pane", "label": "IA", "provider": "codex", "generation": 1}], "excluded": []}
            return {"operation_state": "terminada", "results": [{"key": "shared-pane", "state": "verificado"}]}
        local = SimpleNamespace(machine_id="local", dispatch=lambda method, params: call("local", method, params))
        peers = [{"address": "100.64.0.2", "label": "Mac"}, {"address": "100.64.0.3", "label": "No disponible"}]
        fleet = RelaunchFleet(local, peers, call=call)
        plan = fleet.plan()
        peers.append({"address": "100.64.0.4", "label": "Nuevo"})
        self.assertEqual(len(plan["targets"]), 2)
        self.assertEqual(plan["excluded"], [{"label": "No disponible", "cause": "host_inaccesible"}])
        self.assertEqual([c[2]["scope"]["kind"] for c in calls if c[1] == "relaunch.plan"], ["machine", "machine"])
        result = fleet.operation("relaunch.apply")
        self.assertEqual(result["operation_state"], "terminada")
        self.assertFalse(any(c[0] == "100.64.0.4" for c in calls))


PROVIDER = r'''
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <fcntl.h>
#include <signal.h>
#include <sys/stat.h>
#include <string.h>
static volatile sig_atomic_t stopped = 0;
static void stop(int ignored) { stopped = 1; }
int main(int argc, char **argv) {
  const char *id = getenv("UC_FIXTURE_ID");
  if (argc > 2 && !strcmp(argv[1], "resume")) id = argv[2];
  char file[4096];
  snprintf(file, sizeof file, "%s/.codex/thread-writer-locks/%s.lock", getenv("UC_FIXTURE_ROOT"), id);
  int fd = open(file, O_CREAT|O_RDWR, 0600);
  struct flock lock = {.l_type=F_WRLCK, .l_whence=SEEK_SET, .l_start=0, .l_len=0};
  if (fd < 0 || fcntl(fd, F_SETLK, &lock)) return 2;
  signal(SIGTERM, stop);
  printf("\033[2J\033[H› "); fflush(stdout);
  while (!stopped) pause();
  close(fd);
  return 0;
}
'''


@unittest.skipUnless(os.name == "posix" and Path("/proc").exists() and shutil.which("cc") and shutil.which("tmux"),
                     "Needs isolated Linux runner, C compiler and tmux")
class TargetIntegrationTests(unittest.TestCase):
    def test_fresh_process_same_conversation_same_pane_and_duplicate_apply(self):
        with tempfile.TemporaryDirectory(prefix="uc-relaunch-runtime-") as directory:
            root = Path(directory)
            (root / ".codex/thread-writer-locks").mkdir(parents=True)
            executable = root / "codex"
            subprocess.run(["cc", "-x", "c", "-", "-o", str(executable)], input=PROVIDER,
                           text=True, capture_output=True, check=True, timeout=30)
            socket_name = "uc-relaunch-" + uuid.uuid4().hex[:12]
            native = str(uuid.uuid4())
            transcripts = root / ".codex/sessions/2026/09/14"
            transcripts.mkdir(parents=True)
            (transcripts / ("rollout-fixture-" + native + ".jsonl")).write_text("\n".join(json.dumps(row) for row in (
                {"type": "session_meta", "payload": {"id": native}},
                {"type": "turn_context", "payload": {"model": "fixture-model", "cwd": directory,
                    "sandbox_policy": {"type": "read-only"}, "approval_policy": "never"}},
                {"type": "event_msg", "payload": {"type": "task_complete"}})) + "\n")
            transport = Transport(socket_name=socket_name)
            candidate = {"label": "Fixture · Codex", "provider": "codex", "connection": None,
                         "record": {"id": "fixture", "tmux": "fixture", "tmuxSocket": socket_name}}
            adapter = RelaunchAgents()
            subprocess.run(["tmux", "-L", socket_name, "new-session", "-d", "-s", "fixture", "-c", directory,
                            "/bin/bash", "--noprofile", "--norc", "-i"], check=True, capture_output=True, timeout=5)
            events = TmuxOutputEvents(["tmux", "-L", socket_name], "fixture")
            try:
                command = shlex.join(["env", "UC_FIXTURE_ID=" + native, "UC_FIXTURE_ROOT=" + directory,
                                      str(executable), "-m", "fixture-model", "-s", "read-only", "-a", "never"])
                subprocess.run(["tmux", "-L", socket_name, "send-keys", "-t", "=fixture:", "-l", command + "\n"],
                               check=True, capture_output=True, timeout=5)
                deadline = time.monotonic() + 8
                while True:
                    try:
                        proof = adapter.probe(candidate, "agent.relaunch")
                        break
                    except Exception:
                        self.assertLess(time.monotonic(), deadline)
                        events.wait(deadline, time.monotonic)
                operation = str(uuid.uuid4())
                phases = []
                result = adapter.execute(candidate, "agent.relaunch", proof, operation, phases.append, lambda: True)
                self.assertEqual(result, {"state": "verificado", "effective_id": native})
                new = adapter.probe(candidate, "agent.relaunch")
                self.assertEqual(new["pane"], proof["pane"])
                self.assertNotEqual((new["pid"], new["start"]), (proof["pid"], proof["start"]))
                self.assertEqual(new["effective_id"], proof["effective_id"])
                self.assertEqual(adapter.request(candidate, "start", expected=proof, operation_id=operation), result)
                self.assertEqual(adapter.probe(candidate, "agent.relaunch"), new)
                another = adapter.request(candidate, "start", expected=proof, operation_id=str(uuid.uuid4()))
                self.assertEqual(another, {"state": "omitido", "cause": "duplicado"})
                self.assertTrue(all(p["state"] in ("planificado", "cerrando", "reabriendo", "verificado") for p in phases))
            finally:
                events.close()
                subprocess.run(["tmux", "-L", socket_name, "kill-server"], capture_output=True, timeout=5)
