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

from uniconnect.relaunch_agents import RelaunchAgents, RelaunchUnavailable
from uniconnect.relaunch_fleet import RelaunchFleet
from uniconnect.relaunch_worker import TargetWorker, Unavailable, TmuxOutputEvents
from uniconnect.resume_catalog import AgentResumeCatalog
from uniconnect.transport import Transport, TransportError


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

    def test_codex_yolo_is_retained_for_resume(self):
        args = TargetWorker.resume_arguments("codex", ["codex", "resume", "old", "--yolo"],
                                             "current", self.catalog)
        self.assertEqual(args, ["codex", "resume", "current", "--yolo"])

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
        context = {"type": "turn_context", "payload": {"turn_id": "current-turn", "model": "fixture-model", "cwd": "/work",
                    "sandbox_policy": {"type": "read-only"}, "approval_policy": "never"}}
        complete = {"type": "event_msg", "payload": {"type": "task_complete", "turn_id": "current-turn"}}
        TargetWorker.validate_quiescence([context, complete], process)
        yolo_process = {**process, "argv": ["codex", "--yolo"]}
        yolo_context = {**context, "payload": {**context["payload"],
                                                "sandbox_policy": {"type": "danger-full-access"},
                                                "approval_policy": "never"}}
        TargetWorker.validate_quiescence([yolo_context, complete], yolo_process)
        for rows in ([context], [context, complete, {"type": "event_msg", "payload": {"type": "task_started"}}],
                     [context, {"type": "event_msg", "payload": {"type": "task_complete", "turn_id": "old-turn"}}],
                     [context, {"type": "event_msg", "payload": {"type": "task_started", "turn_id": "new-turn"}}, complete],
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

    def test_all_hosts_disconnected_is_unknown_not_a_finished_operation(self):
        local = SimpleNamespace(machine_id="local", dispatch=lambda *args: (_ for _ in ()).throw(ConnectionError()))
        fleet = RelaunchFleet.restore(local, [{"id": "local", "label": "Local", "plan": {
            "operation_id": "op", "targets": [{"key": "pane"}], "excluded": []}}])
        value = fleet.operation("relaunch.status")
        self.assertEqual(value["operation_state"], "en_curso")
        self.assertEqual(value["results"][0]["state"], "planificado")

    def test_configured_port_and_directory_endpoint_survive_receipt_recovery(self):
        calls = []
        local = SimpleNamespace(machine_id="local", dispatch=lambda method, params:
            {"operation_id": "local-op", "token": "token", "targets": [], "excluded": []})
        def call(address, method, params):
            calls.append((address, method, params))
            if method == "host.status":
                return {"machine_id": "remote", "capabilities": ["relaunch.v1"]}
            if method == "relaunch.plan":
                return {"operation_id": "remote-op", "token": "token", "targets": [], "excluded": []}
            return {"results": [], "operation_state": "terminada"}
        destination = {"host": "mac.tail123.ts.net", "port": 59001}
        fleet = RelaunchFleet(local, [{"id": "saved", "name": "Mac", **destination}], call=call)
        fleet.plan()
        self.assertEqual(calls[0][0], destination)
        host = fleet.hosts[1]
        restored = RelaunchFleet.restore(local, [{key: host[key] for key in ("id", "label", "endpoint", "plan")}], call=call)
        restored.operation("relaunch.status")
        self.assertEqual(calls[-1][0], destination)

    def test_removed_host_route_cannot_receive_apply_but_original_status_is_recoverable(self):
        calls = []
        local = SimpleNamespace(machines=SimpleNamespace(snapshot=lambda: []))
        host = {"id": "saved", "label": "Mac", "endpoint": {"host": "100.64.0.2", "port": 59001},
                "plan": {"operation_id": "op", "token": "token", "targets": [{"key": "pane"}], "excluded": []}}
        fleet = RelaunchFleet.restore(local, [host], call=lambda address, method, params:
            calls.append(method) or {"operation_state": "terminada", "results": []})
        value = fleet.operation("relaunch.apply")
        self.assertEqual(calls, [])
        self.assertEqual(value["results"][0]["cause"], "generacion_cambiada")
        fleet.operation("relaunch.status")
        self.assertEqual(calls, ["relaunch.status"])


class WorkerStatusTests(unittest.TestCase):
    def test_missing_journal_requires_user_and_seals_the_same_operation_against_late_start(self):
        import fcntl
        with tempfile.TemporaryDirectory(prefix="uc-relaunch-journal-") as directory:
            root = Path(directory)
            paths = root / "pane.lock", root / "claim.json", root / "operation.json"
            worker = TargetWorker({"action": "status", "session": "fixture", "socket": "fixture",
                                   "expected": {"generation": 1}})
            worker.paths = lambda: paths
            worker.inspect = lambda **kw: self.fail("status/late start must not inspect or close an agent")
            with paths[0].open("w") as lock:
                fcntl.flock(lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
                value = worker.dispatch()
                self.assertEqual(value["state"], "planificado")
                self.assertFalse(paths[2].exists())  # Never race the live owner.
            value = worker.dispatch()
            self.assertEqual(value, {"state": "necesita_usuario", "cause": "sin_autoridad"})
            self.assertEqual(worker.dispatch(), value)
            self.assertFalse(paths[1].exists())  # No generation consumed/released by an absent receipt.
            worker.request["action"] = "start"
            self.assertEqual(worker.dispatch(), value)  # A late request cannot close after a final response.


class RecoveryAndRevocationTests(unittest.TestCase):
    def setUp(self):
        self.candidate = {"provider": "codex", "connection": None,
                          "record": {"id": "window", "tmux": "fixture", "tmuxSocket": "fixture"}}
        self.proof = {"key": "pane", "generation": 1}

    def test_revocation_or_replacement_while_probe_is_pending_never_sends_start(self):
        for revoke in (True, False):
            allowed, current, calls = [True], [True], []
            adapter = RelaunchAgents(validate=lambda candidate: current[0])
            def request(candidate, action, **params):
                calls.append(action)
                if revoke:
                    allowed[0] = False
                else:
                    current[0] = False
                return self.proof
            adapter.request = request
            if revoke:
                with self.assertRaises(RelaunchUnavailable) as error:
                    adapter.execute(self.candidate, "agent.relaunch", self.proof, "operation", lambda r: None, lambda: allowed[0])
                self.assertEqual(error.exception.cause, "permisos")
            else:
                value = adapter.execute(self.candidate, "agent.relaunch", self.proof, "operation", lambda r: None, lambda: allowed[0])
                self.assertEqual(value["cause"], "generacion_cambiada")
            self.assertEqual(calls, ["inspect"])

    def test_lost_start_response_and_long_outage_recover_same_journal_without_another_start(self):
        for lose_start in (True, False):
            clock, starts, reachable, status_ids = [0], [], [False], []
            operation = str(uuid.uuid4())
            def run(command, **kwargs):
                request = json.loads(base64.b64decode(shlex.split(command)[-1]))
                action = request["action"]
                if action == "inspect":
                    value = self.proof
                elif action == "start":
                    starts.append(request["operation_id"])
                    if lose_start:
                        raise TransportError("connection_timeout")
                    value = {"state": "cerrando"}
                else:
                    status_ids.append(request["operation_id"])
                    if not reachable[0]:
                        raise TransportError("remote_command_failed")
                    value = {"state": "verificado", "effective_id": "same-conversation"}
                return SimpleNamespace(stdout="UC_RELAUNCH_V1 " + json.dumps(value))
            adapter = RelaunchAgents(transport_factory=lambda *a, **k: SimpleNamespace(run=run),
                resolve=lambda target: self.candidate, clock=lambda: clock[0],
                wait=lambda delay: clock.__setitem__(0, clock[0] + delay))
            value = adapter.execute(self.candidate, "agent.relaunch", self.proof, operation, lambda r: None, lambda: True)
            self.assertNotIn(value["state"], ("fallido", "necesita_usuario", "verificado"))
            with self.assertRaises(RelaunchUnavailable):
                adapter.recover({"proof": self.proof}, operation)
            reachable[0] = True
            self.assertEqual(adapter.recover({"proof": self.proof}, operation)["state"], "verificado")
            self.assertEqual(starts, [operation])
            self.assertEqual(set(status_ids), {operation})


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
static void draft(int ignored) { const char text[]="\033[2J\033[H› borrador"; write(1,text,sizeof(text)-1); }
static void clear(int ignored) { const char text[]="\033[2J\033[H› "; write(1,text,sizeof(text)-1); }
int main(int argc, char **argv) {
  const char *id = getenv("UC_FIXTURE_ID");
  if (argc > 2 && !strcmp(argv[1], "resume")) id = argv[2];
  char file[4096];
  snprintf(file, sizeof file, "%s/.codex/thread-writer-locks/%s.lock", getenv("UC_FIXTURE_ROOT"), id);
  int fd = open(file, O_CREAT|O_RDWR, 0600);
  struct flock lock = {.l_type=F_WRLCK, .l_whence=SEEK_SET, .l_start=0, .l_len=0};
  if (fd < 0 || fcntl(fd, F_SETLK, &lock)) return 2;
  signal(SIGTERM, stop);
  signal(SIGUSR1, draft); signal(SIGUSR2, clear);
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
                {"type": "turn_context", "payload": {"turn_id": "fixture-turn", "model": "fixture-model", "cwd": directory,
                    "sandbox_policy": {"type": "read-only"}, "approval_policy": "never"}},
                {"type": "event_msg", "payload": {"type": "task_complete", "turn_id": "fixture-turn"}})) + "\n")
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
                import signal
                os.kill(proof["pid"], signal.SIGUSR1)
                def screen_until(predicate):
                    deadline = time.monotonic() + 5
                    while not predicate(subprocess.check_output(["tmux", "-L", socket_name, "capture-pane", "-p", "-t", "=fixture:"], text=True)):
                        events.wait(deadline, time.monotonic)
                screen_until(lambda screen: "› borrador" in screen)
                rejected = str(uuid.uuid4())
                draft_result = adapter.execute(candidate, "agent.relaunch", proof, rejected, phases.append, lambda: True)
                self.assertEqual(draft_result, {"state": "necesita_usuario", "cause": "dialogo_desconocido"})
                self.assertEqual(adapter.probe(candidate, "agent.relaunch"), proof)
                os.kill(proof["pid"], signal.SIGUSR2)
                screen_until(lambda screen: screen.splitlines()[0].strip() == "›" and "borrador" not in screen)
                self.assertEqual(adapter.request(candidate, "start", expected=proof, operation_id=rejected), draft_result)
                phases.clear()
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
