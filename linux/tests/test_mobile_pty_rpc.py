"""PTY target/permission contract through the real Linux RPC boundary."""

import copy
import types
import unittest
from unittest.mock import patch

from uniconnect.mobile_protocol import RPCError
from uniconnect.mobile_rpc import MobileRPC


class MobilePTYRPCTests(unittest.TestCase):
    def setUp(self):
        self.record = {"id": "terminal", "name": "Guardada", "tmux": "saved-session", "tmuxSocket": "uniconnect-local",
                       "paneId": "%0", "sessionId": "native-identity", "agent": "terminal", "cwd": "/tmp"}
        self.workspace = {"id": "workspace", "kind": "local", "cwd": "/tmp", "windows": [self.record]}
        self.window = types.SimpleNamespace(locked=False, surfaces={},
            store=types.SimpleNamespace(workspaces=[self.workspace], data={"selectedWorkspaceId": "another"}))
        self.rpc = MobileRPC(self.window, types.SimpleNamespace(machine_id="host"), lambda callback: callback())
        self.rpc.host = types.SimpleNamespace(address="100.64.0.1", port=58465,
                                             has_topic=lambda *_: True, emit_private=lambda *_: True)
        self.params = {"workspace_id": "workspace", "surface_id": "terminal", "client_id": "mobile", "columns": 40, "rows": 12}

    def tearDown(self):
        self.rpc.close_attachments()

    def test_capability_and_cold_target_do_not_materialize_vte_or_mutate_model(self):
        before = copy.deepcopy(self.workspace)
        status = self.rpc.dispatch("mobile.host.status", {}, "connection")
        self.assertIn("terminal.pty.v1", status["capabilities"])
        launch, target = self.rpc.prepare_pty(self.params, lambda: True)
        self.assertEqual(target["surface_id"], "terminal")
        self.rpc.validate_pty(target, lambda: True)
        self.assertEqual(before, self.workspace)
        self.assertEqual({}, self.window.surfaces)
        self.assertEqual("another", self.window.store.data["selectedWorkspaceId"])
        self.assertTrue(launch.argv)

    def test_explicit_identity_never_falls_back_to_selected_or_replaced_record(self):
        for params in ({"surface_id": "terminal"}, {**self.params, "terminal_id": "conflict"},
                       {**self.params, "workspace_id": "missing"}):
            with self.subTest(params=params), self.assertRaises(RPCError):
                self.rpc.prepare_pty(params, lambda: True)
        _, target = self.rpc.prepare_pty(self.params, lambda: True)
        self.workspace["windows"][0] = dict(self.record)
        with self.assertRaises(RPCError) as error:
            self.rpc.validate_pty(target, lambda: True)
        self.assertEqual("target_changed", error.exception.code)

    def test_permission_lock_transaction_and_binding_changes_fail_closed(self):
        _, target = self.rpc.prepare_pty(self.params, lambda: True)
        with self.assertRaises(RPCError) as error:
            self.rpc.prepare_pty(self.params, lambda: False)
        self.assertEqual("approval_required", error.exception.code)
        self.window.locked = True
        with self.assertRaises(RPCError) as error:
            self.rpc.validate_pty(target, lambda: True)
        self.assertEqual("locked", error.exception.code)
        self.window.locked = False
        self.window._runtime_operation = types.SimpleNamespace(active=True)
        with self.assertRaises(RPCError) as error:
            self.rpc.prepare_pty(self.params, lambda: True)
        self.assertEqual("busy", error.exception.code)
        self.window._runtime_operation.active = False
        self.record["tmuxSocket"] = "other-server"
        with self.assertRaises(RPCError) as error:
            self.rpc.validate_pty(target, lambda: True)
        self.assertEqual("target_changed", error.exception.code)

    def test_nondurable_target_is_rejected_without_spawn(self):
        self.record.pop("tmux")
        with self.assertRaises(RPCError) as error:
            self.rpc.prepare_pty(self.params, lambda: True)
        self.assertEqual("not_durable", error.exception.code)

    def test_only_attach_ack_activates_owned_reader_and_disconnect_cleans_it(self):
        calls = []
        self.rpc.attachments = types.SimpleNamespace(
            activate=lambda identifier, connection: calls.append(("activate", identifier, connection)),
            disconnected=lambda connection: calls.append(("disconnect", connection)),
            close=lambda: calls.append(("close",)))
        self.rpc.response_enqueued("mobile.terminal.pty_input", {"attach_id": "id"}, "owner")
        self.assertEqual([], calls)
        self.rpc.response_enqueued("mobile.terminal.attach", {"attach_id": "id"}, "owner")
        self.rpc.disconnected("owner")
        self.assertEqual([("activate", "id", "owner"), ("disconnect", "owner")], calls)

    def test_close_disconnects_socket_queues_before_closing_pty_manager(self):
        calls = []
        self.rpc.host.disconnect_clients = lambda: calls.append("disconnect-clients")
        self.rpc.attachments = types.SimpleNamespace(close=lambda: calls.append("close-pty"))
        self.rpc.close_attachments()
        self.assertEqual(calls, ["disconnect-clients", "close-pty"])
        del self.rpc.host.disconnect_clients
        calls.clear()
        self.rpc.close_attachments()
        self.assertEqual(calls, ["close-pty"])  # Existing fake hosts remain supported.

    def test_disconnect_failure_still_closes_pty_manager(self):
        calls = []
        def fail():
            calls.append("disconnect-clients")
            raise RuntimeError("fixture")
        self.rpc.host.disconnect_clients = fail
        self.rpc.attachments = types.SimpleNamespace(close=lambda: calls.append("close-pty"))
        with self.assertRaises(RuntimeError):
            self.rpc.close_attachments()
        self.assertEqual(calls, ["disconnect-clients", "close-pty"])
        del self.rpc.host.disconnect_clients

    def test_raw_methods_do_not_dispatch_to_desktop_input_or_viewport(self):
        operations = []
        self.rpc.attachments = types.SimpleNamespace(
            dispatch=lambda operation, params, owner, allowed: operations.append((operation, owner, allowed())) or {"queued": True},
            close=lambda: None)
        for operation in ("attach", "pty_input", "pty_resize", "detach"):
            self.rpc.dispatch("mobile.terminal." + operation, {}, "owner")
        self.assertEqual([("terminal." + operation, "owner", True)
                          for operation in ("attach", "pty_input", "pty_resize", "detach")], operations)
        self.assertEqual({}, self.window.surfaces)

    def test_ssh_identity_uses_only_the_host_credential_revision(self):
        self.workspace.update(kind="ssh", credentialId="host-revision")
        self.record["tmuxSocket"] = "uniconnect"
        requested = []
        self.window.connection = lambda workspace: requested.append(workspace["credentialId"]) or "ssh user@fixture.invalid"
        launch, target = self.rpc.prepare_pty({**self.params, "connect": "ssh attacker@elsewhere"}, lambda: True)
        self.assertEqual(["host-revision"], requested)
        self.assertNotIn("attacker@elsewhere", str(launch.argv))
        self.workspace["credentialId"] = "replacement-revision"
        with self.assertRaises(RPCError) as error:
            self.rpc.validate_pty(target, lambda: True)
        self.assertEqual("target_changed", error.exception.code)
