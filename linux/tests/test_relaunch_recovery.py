"""Regression coverage for the real recovery-launcher and Codex idle UI."""

import hashlib
import base64
import json
import os
from pathlib import Path
import shlex
import shutil
import select
import signal
import subprocess
import sys
import tempfile
import time
import unittest
import uuid
from types import SimpleNamespace
from unittest.mock import patch

from uniconnect.relaunch_worker import TargetWorker, Unavailable, TmuxOutputEvents
from uniconnect.resume_catalog import AgentResumeCatalog


class ActiveCodexRelaunchTests(unittest.TestCase):
    def test_continue_requires_a_recent_explicit_quota_notice(self):
        quota = ["You’ve hit your usage limit. Visit settings", "", "› Ask Codex to do anything"]
        login = ["Your access token could not be refreshed. Please sign in again.", "",
                 "› Ask Codex to do anything"]
        stale = ["You’ve hit your usage limit", *("" for _ in range(17)), "› Ask Codex to do anything"]
        self.assertTrue(TargetWorker.codex_quota_pause(quota))
        self.assertFalse(TargetWorker.codex_quota_pause(login))
        self.assertFalse(TargetWorker.codex_quota_pause(stale))

    def test_verified_continue_enters_one_exact_message_and_waits_for_codex_activity(self):
        worker = TargetWorker({"action": "start", "verb": "agent.continue", "provider": "codex",
                               "session": "fixture", "socket": "fixture"})
        proof = {"pane": {"pane": "%1"}, "effective_id": "native"}
        state = {"typed": False, "started": False}
        calls, receipts = [], []

        def tmux(*args):
            calls.append(args)
            if args[0] == "capture-pane":
                if state["started"]:
                    return "You’ve hit your usage limit\n› continua\n• Working (1s • esc to interrupt)\n› Ask Codex to do anything\n  GPT-6 medium · ~ · Conversation"
                if state["typed"]:
                    return "You’ve hit your usage limit\n\n› continua\n\n  GPT-6 medium · ~ · Conversation"
                return "You’ve hit your usage limit\n\n› Ask Codex to do anything\n\n  GPT-6 medium · ~ · Conversation"
            if args[0] == "display-message":
                return "2"
            if args[0] == "send-keys":
                if args[-1] == "continua":
                    state["typed"] = True
                elif args[-1] == "Enter":
                    state["started"] = True
                return ""
            self.fail("Unexpected tmux command: " + repr(args))

        worker.tmux = tmux
        worker.inspect = lambda **kwargs: proof
        worker.same_live_agent = lambda *args: True
        worker.require_empty_composer = lambda *args, **kwargs: {"tail": ["", "  GPT-6 medium · ~ · Conversation"]}
        worker.write = lambda path, value: receipts.append(value["state"])
        worker.continue_codex(proof, {"pid": 20, "start": "1"}, "journal")
        sent = [call[-1] for call in calls if call[0] == "send-keys"]
        self.assertEqual(sent, ["continua", "Enter"])
        self.assertEqual(receipts, ["entregando", "verificado"])

    def fixture(self, *, working=True, background=True, draft=False, warning=False):
        worker = TargetWorker({"action": "inspect", "verb": "agent.relaunch", "session": "fixture",
                               "socket": "fixture", "provider": "codex", "catalog": AgentResumeCatalog().providers})
        process = {"pid": 20, "start": "123", "cwd": "/work", "executable": "/bin/codex",
                   "argv": ["/bin/codex", "--yolo", "-m", "model", "-c", 'model_reasoning_effort="high"']}
        context = {"type": "turn_context", "payload": {"turn_id": "turn", "model": "model", "effort": "high",
                   "cwd": "/work", "sandbox_policy": {"type": "danger-full-access"}, "approval_policy": "never"}}
        state = {"working": working, "background": background, "completed": not working, "draft": draft, "exit": False}
        calls = []
        worker.pane = lambda: ({"pane": "%1"}, {"pid": 10, "argv": ["/bin/bash", "-i"]}, "0", "")
        worker.descendants = lambda _: {20: process}
        worker.native_id = lambda *args: "native"
        def configuration(provider, current, identifier, hook, **options):
            rows = [context]
            if state["completed"]:
                rows.append({"type": "event_msg", "payload": {"type": "turn_aborted", "turn_id": "turn"}})
            return TargetWorker.validate_quiescence(rows, current, **options)
        worker.quiescent_configuration = configuration
        def tmux(*args):
            calls.append(args)
            if args[0] == "display-message":
                return "2" if state["exit"] and warning else "0"
            if args[0] == "send-keys":
                if args[-1] == "Escape":
                    state["working"] = False
                elif args[-1] == "/exit":
                    state["exit"] = True
                return ""
            if args[0] != "capture-pane":
                self.fail("Unexpected tmux operation: " + repr(args))
            if state["exit"]:
                menu = "› /exit  exit Codex\n\n" if warning else ""
                return menu + "› /exit\n\n  GPT-6-Astra medium · ~ · Conversation"
            # Status text transcribed from the 0.158 TVO capture (2026-10-01).
            status = "• Working (5m 07s • esc to interrupt)" if state["working"] else ""
            if state["background"]:
                status += (" · " if status else "") + "2 background terminals running · /ps to view · /stop to close"
            prompt = "› actual draft" if state["draft"] else "› Ask Codex to do anything"
            if "-e" in args and not state["draft"]:
                prompt = "\x1b[1m›\x1b[0m\x1b[39m\x1b[49m \x1b[2mAsk Codex to do anything\x1b[0m\x1b[39m\x1b[49m"
            footer = "  GPT-6-Astra medium · ~ · Conversation"
            if warning:
                footer += "                                                ⚠ 1 warning · f2 to view"
            return status + "\n\n" + prompt + "\n\n" + footer
        worker.tmux = tmux
        return worker, process, state, calls

    def test_active_plan_proves_identity_and_configuration_without_sending_keys(self):
        worker, process, state, calls = self.fixture()
        proof = worker.inspect()
        self.assertTrue(proof["active"])
        self.assertEqual(proof["effective_id"], "native")
        self.assertTrue(all(args[0] == "capture-pane" for args in calls))
        process["argv"][process["argv"].index("-m") + 1] = "changed"
        with self.assertRaises(Unavailable) as error:
            worker.inspect()
        self.assertEqual(error.exception.cause, "no_soportado")

    def test_known_activity_is_not_an_unknown_dialog_but_drafts_still_block(self):
        for working, background in ((True, True), (True, False), (False, True)):
            with self.subTest(working=working, background=background):
                worker, process, state, calls = self.fixture(working=working, background=background)
                proof = worker.inspect()
                self.assertTrue(proof["active"])
                worker.request.pop("verb")
                with self.assertRaises(Unavailable) as error:
                    worker.inspect()
                self.assertEqual(error.exception.cause, "tareas_de_fondo")
                state["draft"] = True
                worker.request["verb"] = "agent.relaunch"
                with self.assertRaises(Unavailable) as error:
                    worker.inspect()
                self.assertEqual(error.exception.cause, "dialogo_desconocido")
                self.assertFalse(any(args[0] == "send-keys" for args in calls))

    def test_confirmed_working_turn_is_interrupted_then_exited_with_separate_enter(self):
        worker, process, state, calls = self.fixture()
        proof = worker.inspect()
        worker.request.update(action="start", expected=proof)
        worker.request.pop("verb")
        phases, waits = [], []
        worker.write = lambda path, value: phases.append(value["state"])
        def wait(*args):
            waits.append(True)
            state["completed"] = True
        with patch("uniconnect.relaunch_worker.os.pidfd_open", return_value=90), \
             patch("uniconnect.relaunch_worker.os.close"), \
             patch("uniconnect.relaunch_worker.select.select", return_value=([90], [], [])):
            worker.exit_codex(proof, process, Path("unused-journal"), SimpleNamespace(wait=wait))
        sent = [args for args in calls if args[0] == "send-keys"]
        self.assertEqual(sent, [("send-keys", "-t", "%1", "Escape"),
                                ("send-keys", "-t", "%1", "-l", "--", "/exit"),
                                ("send-keys", "-t", "%1", "Enter")])
        self.assertTrue(waits)  # UI changed before the native turn-aborted record arrived.
        self.assertTrue(all(phase == "cerrando" for phase in phases))

    def test_confirmation_does_not_authorize_a_draft_or_another_generation(self):
        for mutation in ("draft", "generation", "no_confirmation"):
            with self.subTest(mutation=mutation):
                worker, process, state, calls = self.fixture()
                proof = worker.inspect()
                worker.request.update(action="start", expected=proof)
                worker.request.pop("verb")
                if mutation == "draft":
                    state["draft"] = True
                elif mutation == "generation":
                    process["start"] = "replacement"
                else:
                    worker.request["expected"] = {key: value for key, value in proof.items() if key != "active"}
                with patch("uniconnect.relaunch_worker.os.pidfd_open", return_value=90), \
                     patch("uniconnect.relaunch_worker.os.close"), self.assertRaises(Unavailable):
                    worker.exit_codex(proof, process, Path("unused-journal"), SimpleNamespace(wait=lambda *args: self.fail("wait")))
                self.assertFalse(any(args[0] == "send-keys" for args in calls))

    def test_active_consent_allows_completion_but_preserves_identity_and_configuration(self):
        worker, process, state, calls = self.fixture()
        proof = worker.inspect()
        idle = {key: value for key, value in proof.items() if key != "active"}
        self.assertTrue(TargetWorker.same_target(idle, proof))
        self.assertFalse(TargetWorker.same_target(proof, idle))
        for field in ("generation", "pid", "start", "effective_id", "configuration", "native_configuration", "pane"):
            with self.subTest(field=field):
                self.assertFalse(TargetWorker.same_target({**idle, field: "changed"}, proof))

    def test_input_changed_during_final_native_check_is_not_submitted(self):
        worker, process, state, calls = self.fixture(working=False, background=False)
        proof = worker.inspect()
        worker.request.update(action="start", expected=proof)
        worker.request.pop("verb")
        inspect = worker.inspect
        tmux = worker.tmux
        def changed_inspect():
            result = inspect()
            if state["exit"]:
                state["late_draft"] = True
            return result
        def changed_tmux(*args):
            result = tmux(*args)
            if args[0] == "capture-pane" and state.get("late_draft"):
                return result.replace("› /exit", "› /exit\n  user continuation · with · separators")
            return result
        worker.inspect = changed_inspect
        worker.tmux = changed_tmux
        worker.write = lambda *args: None
        with patch("uniconnect.relaunch_worker.os.pidfd_open", return_value=90), \
             patch("uniconnect.relaunch_worker.os.close"), self.assertRaises(Unavailable) as error:
            worker.exit_codex(proof, process, Path("unused-journal"), SimpleNamespace(wait=lambda *args: self.fail("wait")))
        self.assertEqual(error.exception.cause, "dialogo_desconocido")
        self.assertEqual([args[-1] for args in calls if args[0] == "send-keys"], ["/exit"])

    def test_real_codex_exit_menu_can_hide_the_footer_warning_before_enter(self):
        # Codex 0.159.2 TC capture on 2026-10-01: the /exit menu appears above
        # the input and hides only "⚠ 1 warning · f2 to view" in the model footer.
        worker, process, state, calls = self.fixture(working=False, background=False, warning=True)
        proof = worker.inspect()
        worker.request.update(action="start", expected=proof)
        worker.request.pop("verb")
        worker.write = lambda *args: None
        with patch("uniconnect.relaunch_worker.os.pidfd_open", return_value=90), \
             patch("uniconnect.relaunch_worker.os.close"), \
             patch("uniconnect.relaunch_worker.select.select", return_value=([90], [], [])):
            worker.exit_codex(proof, process, Path("unused-journal"), SimpleNamespace(wait=lambda *args: self.fail("wait")))
        self.assertEqual([args[-1] for args in calls if args[0] == "send-keys"], ["/exit", "Enter"])

    def test_warning_hint_normalization_keeps_draft_lines_and_the_original_footer(self):
        original = {"tail": ["", "  GPT-5.6-Sol high · ~ · Continúa desarrollo TC    ⚠ 1 warning · f2 to view"]}
        footer = "  GPT-5.6-Sol high · ~ · Continúa desarrollo TC"
        self.assertTrue(TargetWorker.codex_exit_composer(["› /exit  exit Codex", "", "› /exit", "", footer], 2, original))
        for tail in (["", "  user continuation · with · separators", footer],
                     ["", "  user text    ⚠ 1 warning · f2 to view", footer],
                     ["", footer.replace("high", "low")], ["", footer.replace("TC", "Other")],
                     ["", "", footer]):
            with self.subTest(tail=tail):
                self.assertFalse(TargetWorker.codex_exit_composer(["› /exit", *tail], 0, original))

    def test_new_codex_spinner_and_background_terminal_counts_are_recognised(self):
        self.assertEqual(TargetWorker.codex_activity(["◦ Working (30s • esc to interrupt)"]),
                         {"working": True, "background": False})
        waiting = "• Waiting for background terminal (10m59s · esc to interrupt) · 3 background terminals running"
        self.assertEqual(TargetWorker.codex_activity([waiting]), {"working": True, "background": True})
        self.assertEqual(TargetWorker.codex_activity(["The log said: " + waiting]),
                         {"working": False, "background": True})
        self.assertEqual(TargetWorker.codex_activity([waiting, *([""] * 12)]),
                         {"working": False, "background": False})
        self.assertEqual(TargetWorker.codex_activity(["1 background terminal running · /ps to view"]),
                         {"working": False, "background": True})
        self.assertEqual(TargetWorker.codex_activity(["0 background terminals running"]),
                         {"working": False, "background": False})

    def test_effective_settings_changes_are_visible_even_when_argv_stays_implicit(self):
        process = {"cwd": "/work", "argv": ["codex", "--yolo"]}
        context = {"type": "turn_context", "payload": {"turn_id": "turn", "model": "old", "effort": "high",
                   "cwd": "/work", "sandbox_policy": {"type": "danger-full-access"}, "approval_policy": "never"}}
        complete = {"type": "event_msg", "payload": {"type": "task_complete", "turn_id": "turn"}}
        def settings(model, effort):
            return {"type": "event_msg", "payload": {"type": "thread_settings_applied", "thread_settings": {
                "model": model, "reasoning_effort": effort, "cwd": "/work", "approval_policy": "never",
                "permission_profile": {"type": "disabled"}}}}
        original = TargetWorker.validate_quiescence([context, complete, settings("model", "high")], process)
        for model, effort in (("changed", "high"), ("model", "low")):
            changed = TargetWorker.validate_quiescence([context, complete, settings(model, effort)], process)
            self.assertNotEqual(TargetWorker.digest(original), TargetWorker.digest(changed))

    def test_process_birth_bounds_include_sampling_time_and_one_start_tick(self):
        with patch("uniconnect.relaunch_worker.time.time", side_effect=[1000.0, 1000.004]), \
             patch("uniconnect.relaunch_worker.time.clock_gettime", return_value=800.0), \
             patch("uniconnect.relaunch_worker.os.sysconf", return_value=100):
            lower, upper = TargetWorker.process_birth_bounds({"start": "2000"})
        self.assertAlmostEqual(lower, 220.0)
        self.assertAlmostEqual(upper, 220.014)
        for clock in ([1000.0, 999.9], [1000.0, 1002.0]):
            with patch("uniconnect.relaunch_worker.time.time", side_effect=clock), \
                 patch("uniconnect.relaunch_worker.time.clock_gettime", return_value=800.0):
                self.assertIsNone(TargetWorker.process_birth_bounds({"start": "2000"}))

    def test_mismatched_terminal_event_cannot_leave_a_stale_active_turn_valid(self):
        process = {"cwd": "/work", "argv": ["codex", "--yolo"]}
        context = {"type": "turn_context", "payload": {"turn_id": "turn", "model": "model", "effort": None,
                   "cwd": "/work", "sandbox_policy": {"type": "danger-full-access"}, "approval_policy": "never"}}
        for kind in ("task_complete", "turn_aborted"):
            rows = [context, {"type": "event_msg", "payload": {"type": kind, "turn_id": "other"}}]
            with self.subTest(kind=kind), self.assertRaises(Unavailable):
                TargetWorker.validate_quiescence(rows, process, allow_active=True)


class RecoveryRelaunchTests(unittest.TestCase):
    def worker(self):
        return TargetWorker({"session": "fixture", "socket": "fixture", "provider": "codex"})

    def test_styled_empty_codex_composer_does_not_depend_on_cursor_position(self):
        # Exact SGR sequence captured from Codex 0.158 and 0.159.2 on 2026-10-01.
        # Gray variants below are synthetic compatibility cases, not old-version captures.
        marker = "\x1b[1m›\x1b[0m\x1b[39m\x1b[49m "
        suffix = "\x1b[0m\x1b[39m\x1b[49m"
        for style in ("\x1b[2m", "\x1b[0;2m", "\x1b[90m", "\x1b[38;5;244m", "\x1b[38;2;128;128;128m"):
            for cursor in ((2, 2), (6, 2), (0, 0)):
                with self.subTest(style=style, cursor=cursor):
                    worker = self.worker()
                    plain = "Finished.\n\n› Ask Codex to do anything\n\n  GPT-5.6-Sol high · ~ · Conversation"
                    styled = plain.replace("› Ask Codex to do anything", marker + style + "Ask Codex to do anything" + suffix)
                    calls = []
                    def tmux(*args):
                        calls.append(args)
                        if args[0] == "display-message":
                            return str(cursor[0] if args[-1] == "#{cursor_x}" else cursor[1])
                        return styled if "-e" in args else plain
                    worker.tmux = tmux
                    worker.require_empty_composer({"pane": {"pane": "%1"}})
                    self.assertTrue(all(args[0] in ("capture-pane", "display-message") for args in calls))

    def test_placeholder_lookalike_drafts_and_background_colors_never_prove_empty(self):
        text = "Ask Codex to do anything"
        for styled in ("› " + text, "› \x1b[1m" + text, "› \x1b[31m" + text,
                       "› \x1b[48;2;2;2;2m" + text, "› \x1b[48;5;244m" + text,
                       "› \x1b[2mAsk\x1b[22m Codex to do anything", "› \x1b[2m\x1b[0m" + text,
                       "› \x1b[2;7m" + text, "› \x1b[2;8m" + text,
                       "› \x1b[2m" + text + " extra"):
            with self.subTest(styled=styled):
                self.assertFalse(TargetWorker.codex_placeholder(styled))

    def test_a_later_draft_multiline_input_dialog_or_changed_screen_blocks_the_close(self):
        placeholder = "› Ask Codex to do anything"
        styled_placeholder = "› \x1b[2mAsk Codex to do anything\x1b[0m"
        screens = ((placeholder + "\n› actual draft", styled_placeholder + "\n› actual draft"),
                   (placeholder + "\n  second line of a draft", styled_placeholder + "\n  second line of a draft"),
                   (placeholder + "\nUnknown dialog", styled_placeholder + "\nUnknown dialog"),
                   (placeholder, "› new draft"), (placeholder, placeholder),
                   ("›\n  one · two · three", "›\n  one · two · three"),
                   ("›\n\n  GPT-6-Astra medium · ~ · typed draft", "›\n\n  GPT-6-Astra medium · ~ · typed draft"))
        for plain, styled in screens:
            with self.subTest(plain=plain, styled=styled):
                worker = self.worker()
                worker.tmux = lambda *args: styled if "-e" in args else plain
                with self.assertRaises(Unavailable) as error:
                    worker.require_empty_composer({"pane": {"pane": "%1"}})
                self.assertEqual(error.exception.cause, "dialogo_desconocido")

    def test_resume_settings_supersede_old_turn_configuration_but_not_activity(self):
        process = {"cwd": "/work", "argv": ["codex", "resume", "id", "--yolo", "-m", "current", "-c", 'model_reasoning_effort="max"']}
        context = {"type": "turn_context", "payload": {"turn_id": "turn", "model": "old", "effort": "high", "cwd": "/work",
                   "approval_policy": "on-request", "sandbox_policy": {"type": "workspace-write"}}}
        complete = {"type": "event_msg", "payload": {"type": "task_complete", "turn_id": "turn"}}
        settings = {"type": "event_msg", "payload": {"type": "thread_settings_applied", "thread_settings": {
            "model": "current", "reasoning_effort": "max", "cwd": "/work", "approval_policy": "never",
            "permission_profile": {"type": "disabled"}}}}
        native = TargetWorker.validate_quiescence([context, complete, settings], process)
        self.assertTrue(native["settings_applied"])
        self.assertEqual((native["model"], native["effort"]), ("current", "max"))
        resume = TargetWorker.resume_arguments("codex", process["argv"], "id", AgentResumeCatalog().providers,
                                               native)
        self.assertEqual(resume[resume.index("-m") + 1], "current")
        self.assertEqual(resume[resume.index("-c") + 1], 'model_reasoning_effort="max"')
        TargetWorker.validate_quiescence([context, complete, settings],
                                         {**process, "argv": ["codex", "resume", "id", "--yolo"]})
        # Native current settings may replace stale model/effort selectors, but
        # permission policy and cwd must still be proven exactly.
        for argv in (["codex", "-s", "workspace-write", "-a", "never"],
                     ["codex", "--yolo", "-C", "/other"]):
            with self.subTest(argv=argv), self.assertRaises(Unavailable):
                TargetWorker.validate_quiescence([context, complete, settings], {**process, "argv": argv})
        for rows in ([context, settings], [context, complete, settings, {"type": "event_msg", "payload": {"type": "task_started", "turn_id": "next"}}]):
            with self.assertRaises(Unavailable):
                TargetWorker.validate_quiescence(rows, process)
        with self.assertRaises(Unavailable):
            TargetWorker.validate_quiescence([context, complete], {**process, "argv": ["codex", "--yolo", "-m", "wrong"]})

    def test_only_pinned_recovery_with_same_conversation_and_arguments_is_admitted(self):
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            script = home / "recovery.py"
            script.write_text("# reviewed recovery fixture\n")
            script.chmod(0o600)
            manifest = home / "manifest.json"
            entry = {"tmux": "fixture", "agent": "codex", "sessionId": "native", "cwd": directory,
                     "model": "m", "reasoningEffort": "max"}
            manifest.write_text(json.dumps({"tmuxSocket": "fixture", "windows": [entry]}))
            worker = self.worker()
            worker.request["recovery_sha256"] = hashlib.sha256(script.read_bytes()).hexdigest()
            root = {"argv": ["/usr/bin/python3", str(script), "--manifest", str(manifest), "launch", "fixture"]}
            process = {"cwd": directory, "argv": ["/bin/codex", "resume", "-C", directory, "-m", "m", "-c", 'model_reasoning_effort="max"',
                       "--dangerously-bypass-approvals-and-sandbox", "native"]}
            proof = worker.recovery_launcher(root, process, "native")
            self.assertEqual(proof["session_id"], "native")
            # Forma nueva del lanzador (recovery.py sin preguntas): codex --yolo resume <id> -C ...
            current = {"cwd": directory, "argv": ["/bin/codex", "--yolo", "resume", "native", "-C", directory, "-m", "m",
                                                  "-c", 'model_reasoning_effort="max"']}
            self.assertEqual(worker.recovery_launcher(root, current, "native"), proof)
            # El lanzador de recovery.launch_command lleva --socket S: se admite si es el de la petición.
            with_socket = {"argv": [*root["argv"][:4], "--socket", "fixture", *root["argv"][4:]]}
            self.assertEqual(worker.recovery_launcher(with_socket, current, "native"), proof)
            inline = {**current, "argv": [*current["argv"], "--no-alt-screen"]}
            for launcher in (root, with_socket):
                self.assertEqual(worker.recovery_launcher(launcher, inline, "native"), proof)
                for extra in ("--search", "--no-alt-screen", "--dangerously-bypass-approvals-and-sandbox"):
                    with self.subTest(extra=extra), self.assertRaises(Unavailable):
                        worker.recovery_launcher(launcher, {**inline, "argv": [*inline["argv"], extra]}, "native")
            with self.assertRaises(Unavailable):
                worker.recovery_launcher({"argv": [*root["argv"][:4], "--socket", "otro", *root["argv"][4:]]}, current, "native")
            with self.assertRaises(Unavailable):
                worker.recovery_launcher(root, {**current, "argv": [*current["argv"], "--dangerously-bypass-approvals-and-sandbox"]}, "native")
            for mutation in ("id", "script", "arguments"):
                with self.subTest(mutation=mutation):
                    changed = dict(process)
                    if mutation == "id":
                        entry["sessionId"] = "stale"
                        manifest.write_text(json.dumps({"tmuxSocket": "fixture", "windows": [entry]}))
                    elif mutation == "script":
                        script.write_text("# unreviewed supervisor\n")
                    else:
                        changed["argv"] = [*process["argv"], "--search"]
                    with self.assertRaises(Unavailable):
                        worker.recovery_launcher(root, changed, "native")
                    entry["sessionId"] = "native"
                    manifest.write_text(json.dumps({"tmuxSocket": "fixture", "windows": [entry]}))
                    script.write_text("# reviewed recovery fixture\n")

    @unittest.skipUnless(hasattr(os, 'fork'), 'requires a Linux worker')
    def test_two_panes_serialize_startup_on_destination_and_duplicate_does_not_repeat(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory); entered_r,entered_w=os.pipe(); release_r,release_w=os.pipe()
            children=[]; original_fork=os.fork
            def fork():
                pid=original_fork()
                if pid:children.append(pid)
                return pid
            def worker(number):
                value=self.worker();proof={'generation':number}
                value.request.update(expected=proof,operation_id=str(uuid.uuid4()))
                value.paths=lambda: (root/f'{number}.lock',root/f'{number}-claim.json',root/f'{number}-journal.json')
                value.inspect=lambda **_:proof
                def perform(journal):
                    os.write(entered_w,str(number).encode())
                    if number==1:os.read(release_r,1)
                    value.write(journal,{'state':'verificado'})
                value.perform=perform
                return value
            try:
                first,second=worker(1),worker(2)
                with patch.object(os,'fork',side_effect=fork):
                    self.assertEqual(first.start(),{'state':'planificado'})
                    self.assertTrue(select.select([entered_r],[],[],5)[0]);self.assertEqual(os.read(entered_r,1),b'1')
                    self.assertEqual(second.start(),{'state':'planificado'})
                    self.assertFalse(select.select([entered_r],[],[],0.2)[0])
                    os.write(release_w,b'!')
                    self.assertTrue(select.select([entered_r],[],[],5)[0]);self.assertEqual(os.read(entered_r,1),b'2')
                for pid in children:os.waitpid(pid,0)
                children.clear()
                self.assertEqual(first.start(),{'state':'verificado'})
                self.assertEqual(second.start(),{'state':'verificado'})
            finally:
                for pid in children:
                    try:os.kill(pid,signal.SIGTERM)
                    except ProcessLookupError:pass
                    os.waitpid(pid,0)
                for fd in (entered_r,entered_w,release_r,release_w):os.close(fd)


PROVIDER = r'''
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <termios.h>
int main(int argc, char **argv) {
  char path[4096];
  const char *id = argc>2 && argv[2][0]!='-' ? argv[2] : argv[argc-1];
  snprintf(path, sizeof path, "%s/.codex/thread-writer-locks/%s.lock", getenv("UC_FIXTURE_ROOT"), id);
  int fd = open(path, O_CREAT|O_RDWR, 0600);
  struct flock lock = {.l_type=F_WRLCK, .l_whence=SEEK_SET};
  if (fd < 0 || fcntl(fd, F_SETLK, &lock)) return 2;
  struct termios mode; tcgetattr(0, &mode); cfmakeraw(&mode); tcsetattr(0,TCSANOW,&mode);
  printf("\033[2J\033[H\033[1m›\033[0m \033[2mAsk Codex to do anything\033[0m\r\033[2C"); fflush(stdout);
  char text[64]={0}; size_t n=0; char c;
  while (read(0,&c,1)==1) {
    if (c=='\r' || c=='\n') { if (!strcmp(text,"/exit")) break; return 3; }
    if (n+1>=sizeof text) return 4; text[n++]=c;
    printf("\033[2J\033[H› %s",text); fflush(stdout);
  }
  close(fd); return 0; /* Deliberately leave raw mode behind, like the repro. */
}
'''

SUPERVISOR = '''import json,subprocess,sys
from pathlib import Path
data=json.loads(Path(sys.argv[2]).read_text())
e=data['windows'][0]
while True:
 p=subprocess.Popen([e['executable'],'resume','-C',e['cwd'],'-m',e['model'],'-c','model_reasoning_effort="max"','--dangerously-bypass-approvals-and-sandbox',e['sessionId']])
 p.wait()
 print('\\x1b[2J\\x1b[H',end='',flush=True)
 input('Sesión cerrada. Pulsa Intro para recuperar el mismo historial: ')
'''


@unittest.skipUnless(Path('/proc').exists() and shutil.which('tmux') and shutil.which('cc'), 'isolated Linux VM required')
class RecoveryRuntimeTests(unittest.TestCase):
    def test_same_pane_conversation_and_launcher_survive_normal_exit_and_raw_tty(self):
        self.run_relaunch(supervised=True)

    def test_plain_shell_uses_normal_exit_and_reopens_same_conversation(self):
        self.run_relaunch(supervised=False)

    def run_relaunch(self, *, supervised):
        with tempfile.TemporaryDirectory(prefix='uc-recovery-e2e-') as directory:
            root=Path(directory); native=str(uuid.uuid4()); socket='uc-recovery-'+uuid.uuid4().hex[:10]
            locks=root/'.codex/thread-writer-locks';locks.mkdir(parents=True)
            transcripts=root/'.codex/sessions/2026/09/21';transcripts.mkdir(parents=True)
            executable=root/'codex'
            subprocess.run(['cc','-x','c','-','-o',str(executable)],input=PROVIDER,text=True,capture_output=True,check=True,timeout=30)
            rows=[{'type':'session_meta','payload':{'id':native}},
                  {'type':'turn_context','payload':{'turn_id':'t','model':'m','effort':'max','cwd':directory,'approval_policy':'never','sandbox_policy':{'type':'danger-full-access'}}},
                  {'type':'event_msg','payload':{'type':'task_complete','turn_id':'t'}}]
            (transcripts/('rollout-fixture-'+native+'.jsonl')).write_text('\n'.join(map(json.dumps,rows))+'\n')
            script=root/'recovery.py';script.write_text(SUPERVISOR);script.chmod(0o600)
            manifest=root/'manifest.json';manifest.write_text(json.dumps({'tmuxSocket':socket,'windows':[{
                'tmux':'fixture','agent':'codex','sessionId':native,'cwd':directory,'executable':str(executable),'model':'m','reasoningEffort':'max'}]}))
            binary=['tmux','-L',socket]
            # Same argv shape as the deployed recovery supervisor. The fixture
            # source is explicitly pinned in the request, never globally trusted.
            command=shlex.join(['env','UC_FIXTURE_ROOT='+directory,sys.executable,str(script),'--manifest',str(manifest),'launch','fixture']) if supervised else '/bin/bash --noprofile --norc -i'
            subprocess.run(binary+['new-session','-d','-s','fixture','-c',directory,command],check=True,capture_output=True)
            events=TmuxOutputEvents(binary,'fixture')
            try:
                if not supervised:
                    command=shlex.join(['env','UC_FIXTURE_ROOT='+directory,str(executable),'resume',native,'-C',directory,'-m','m','-c','model_reasoning_effort="max"','--dangerously-bypass-approvals-and-sandbox'])
                    subprocess.run(binary+['send-keys','-t','=fixture:','-l',command+'\n'],check=True,capture_output=True)
                request={'session':'fixture','socket':socket,'provider':'codex','window_id':'fixture','recovery_sha256':hashlib.sha256(script.read_bytes()).hexdigest(),
                         'identity_helper':base64.b64encode(b'pass').decode(),
                         'catalog':{'codex':{'resume':['{executable}','resume','{sessionId}','{arguments}']}}}
                worker=TargetWorker(request);deadline=time.monotonic()+10
                while True:
                    try:
                        proof=worker.inspect();worker.require_empty_composer(proof);break
                    except (Unavailable,OSError):events.wait(deadline,time.monotonic)
                worker.request['expected']=proof
                journal=root/'journal.json';worker.write(journal,{'state':'planificado'})
                worker.perform(journal)
                self.assertEqual(worker.read(journal),{'state':'verificado','effective_id':native})
                after=worker.inspect()
                self.assertEqual(after['pane'],proof['pane'])
                self.assertEqual(after.get('launcher'),proof.get('launcher'))
                self.assertEqual(after['effective_id'],native)
                self.assertNotEqual(after['pid'],proof['pid'])
                self.assertFalse(worker.same_process({'pid':proof['pid'],'start':proof['start']}))
            finally:
                events.close()
                subprocess.run(binary+['kill-server'],capture_output=True,timeout=5)


if __name__ == "__main__":
    unittest.main()
