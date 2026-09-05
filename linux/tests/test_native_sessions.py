"""Real provider-shaped hook -> isolated tmux metadata -> durable model, in CI."""

import copy
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
from types import SimpleNamespace
import unittest
from unittest.mock import patch
import uuid

from uniconnect.agent_identity_hook import launch
from uniconnect.native_sessions import NativeSessions
from uniconnect.state import StateStore
from uniconnect.transport import TmuxCommand, Transport


PROVIDER_FIXTURE = r'''
import json, os, pathlib, shlex, subprocess, sys, time
root = pathlib.Path(sys.argv[1])
agent = sys.argv[2]
args = sys.argv[3:]
if agent == "claude":
    settings = json.loads(args[args.index("--settings") + 1])
    hook = shlex.split(settings["hooks"]["SessionStart"][0]["hooks"][0]["command"])
else:
    hook = json.loads(args[args.index("-c") + 1].removeprefix("notify="))
last = None
deadline = time.monotonic() + 30
while time.monotonic() < deadline:
    try:
        event = json.loads((root / "event.json").read_text())
    except (OSError, ValueError):
        time.sleep(0.03)
        continue
    if event["number"] == last:
        time.sleep(0.03)
        continue
    last = event["number"]
    env = dict(os.environ)
    if event.get("foreign"):
        env["TMUX_PANE"] = "%999999"
    payload = json.dumps(event["payload"])
    result = subprocess.run(hook + ([payload] if agent == "codex" else []),
        input=payload if agent == "claude" else None, env=env, text=True,
        capture_output=True, timeout=5)
    # The bridge must never echo provider payloads, prompts or transcript paths.
    (root / "done.json").write_text(json.dumps({"number": last,
        "quiet": not result.stdout and not result.stderr, "code": result.returncode}))
'''


@unittest.skipUnless(sys.platform.startswith("linux") and shutil.which("tmux"), "Linux tmux required")
class NativeSessionIntegrationTests(unittest.TestCase):
    def test_real_hook_pane_and_model_for_each_provider_without_touching_existing_history(self):
        for agent in ("claude", "codex"):
            with self.subTest(agent=agent), tempfile.TemporaryDirectory(prefix="uc-native-") as directory:
                root = Path(directory)
                socket = "uc-native-" + uuid.uuid4().hex[:12]
                transport = Transport(socket_name=socket)
                provider = root / "provider.py"
                provider.write_text(PROVIDER_FIXTURE)
                window = {"id": str(uuid.uuid4()), "name": "Fixture", "tmux": "fixture",
                          "tmuxSocket": socket, "cwd": directory, "agent": agent,
                          "history": [{"agent": agent, "sessionId": "imported-old", "id": "imported-history",
                                       "firstSeenAt": 123, "customMetadata": {"keep": True}}]}
                original_history = copy.deepcopy(window["history"])
                workspace = {"id": "workspace", "name": "Fixture", "kind": "local", "windows": [window]}
                store = StateStore(root / "state")
                store.data["workspaces"] = [workspace]
                store.save()
                surface = SimpleNamespace(record=window, workspace=workspace, generation=1, disposed=False,
                    pid=1, _ownership_keys=[("tmux", ("local",), socket, "fixture")],
                    status="Running", update_status=lambda status: None)
                owner = SimpleNamespace(store=store, surfaces={window["id"]: surface}, _closed=False, locked=False,
                    _terminal_owners={surface._ownership_keys[0]: surface}, background=lambda work, done: done(work()))
                tracker = NativeSessions(owner)
                native = str(uuid.uuid4())

                def event(number, identifier, *, foreign=False):
                    payload = ({"hook_event_name": "SessionStart", "session_id": identifier,
                                "source": "startup" if number == 1 else "clear"}
                               if agent == "claude" else {"type": "agent-turn-complete", "thread-id": identifier})
                    payload["prompt"] = "private fixture text never retained"
                    (root / "event.json").write_text(json.dumps({"number": number, "payload": payload, "foreign": foreign}))
                    deadline = time.monotonic() + 8
                    while time.monotonic() < deadline:
                        try:
                            result = json.loads((root / "done.json").read_text())
                            if result["number"] == number:
                                self.assertTrue(result["quiet"])
                                self.assertEqual(result["code"], 0)
                                return
                        except (OSError, ValueError):
                            pass
                        time.sleep(0.03)
                    self.fail("The fixture provider did not deliver its bounded hook")

                try:
                    # Only substitute the provider executable. Hook injection,
                    # subprocess ancestry, tmux CAS, transport and store are real.
                    with patch.object(TmuxCommand, "agent_argv", return_value=[sys.executable, str(provider), directory, agent]):
                        transport.ensure_session(window)
                    event(1, native)
                    proofs = tracker.read(transport)
                    self.assertEqual([proof["session_id"] for proof in proofs], [native])
                    tracker.poll()
                    self.assertEqual(window["sessionId"], native)
                    self.assertEqual(window["history"][:1], original_history)
                    self.assertIs(owner._terminal_owners[("agent", ("local",), agent, native)], surface)
                    self.assertEqual(StateStore(root / "state").workspaces[0]["windows"][0]["sessionId"], native)
                    before = transport.run(TmuxCommand._binary(socket) + " display-message -p -t '=fixture:' '#{pane_pid}'").stdout
                    event(2, str(uuid.uuid4()), foreign=True)
                    self.assertEqual(tracker.read(transport)[0]["session_id"], native)
                    replacement = str(uuid.uuid4())
                    event(3, replacement)
                    tracker.poll()
                    self.assertEqual(window["sessionId"], replacement)
                    event(4, native)  # Retired thread cannot roll the pane back.
                    self.assertEqual(tracker.read(transport)[0]["session_id"], replacement)
                    after = transport.run(TmuxCommand._binary(socket) + " display-message -p -t '=fixture:' '#{pane_pid}'").stdout
                    self.assertEqual(before, after)
                    self.assertEqual(window["history"][0], original_history[0])
                    self.assertNotIn("private fixture", store.path.read_text())
                    self.assertEqual([item["sessionId"] for item in window["history"]], ["imported-old", native, replacement])
                finally:
                    subprocess.run(["tmux", "-L", socket, "kill-server"], capture_output=True, timeout=3)
                    (Path.home() / ".local/state/uniconnect" / ("tmux-create-" + socket + ".lock")).unlink(missing_ok=True)

    def test_late_desktop_callback_and_failed_save_do_not_replace_persisted_identity(self):
        with tempfile.TemporaryDirectory(prefix="uc-native-state-") as directory:
            store = StateStore(directory)
            record = {"id": "window", "name": "Fixture", "tmux": "fixture", "agent": "claude", "sessionId": "old"}
            workspace = {"id": "box", "name": "Fixture", "kind": "local", "windows": [record]}
            store.data["workspaces"] = [workspace]
            store.save()
            callbacks = []
            surface = SimpleNamespace(record=record, workspace=workspace, generation=1, disposed=False, pid=1,
                _ownership_keys=[("tmux", ("local",), "uniconnect-local", "fixture")])
            owner = SimpleNamespace(store=store, surfaces={"window": surface}, _closed=False, locked=False,
                background=lambda work, done: callbacks.append(done), _terminal_owners={})
            tracker = NativeSessions(owner)
            proof = {"window_id": "window", "tmux": "fixture", "agent": "claude", "session_id": "new"}
            tracker.poll()
            surface.generation += 1
            callbacks[0]([proof])
            self.assertEqual(record["sessionId"], "old")
            before = copy.deepcopy(record)
            with patch.object(store, "save", side_effect=OSError("fixture write failure")):
                with self.assertRaises(OSError):
                    tracker.persist(record, proof)
            self.assertEqual(record, before)
            self.assertEqual(StateStore(directory).workspaces[0]["windows"][0]["sessionId"], "old")

    def test_unavailable_hook_falls_back_to_unchanged_agent_arguments(self):
        with patch.dict("os.environ", {"TMUX_PANE": ""}), patch("os.execvpe") as execute:
            launch({"argv": ["claude", "--resume", "existing"], "agent": "claude", "window_id": "window"})
        self.assertEqual(execute.call_args.args[:2], ("claude", ["claude", "--resume", "existing"]))


if __name__ == "__main__":
    unittest.main()
