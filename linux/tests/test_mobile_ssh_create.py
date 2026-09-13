"""ssh_create.v1 on Linux: a connection command typed on the phone.

`create_mobile_workspace` is exercised unbound against a stand-in window, so the rules that decide
what reaches the vault are tested without GTK, without a real store and without a real vault.
"""
import sys
import types
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from uniconnect.mobile_protocol import RPCError
from uniconnect.transport import SSHCommand
from uniconnect.window import MainWindow


class Vault:
    def __init__(self, locked=False):
        self.locked = locked
        self.stored = []

    def put(self, command):
        self.stored.append(command)
        return "cred-" + str(len(self.stored))


class MobileSSHCreateTests(unittest.TestCase):
    def setUp(self):
        self.vault = Vault()
        self.source = {"id": "origen", "name": "VPS", "kind": "ssh", "credentialId": "cred-vieja",
                       "hostLabel": "dani@example.com"}
        self.committed = []
        self.window = types.SimpleNamespace(
            vault=self.vault,
            _=lambda text: text,
            _runtime_operation=None,
            store=types.SimpleNamespace(
                workspaces=[self.source], _active_transaction=None,
                journal_path=types.SimpleNamespace(exists=lambda: False),
            ),
            commit_new_workspace=lambda workspace: (self.committed.append(workspace), workspace)[1],
        )

    def create(self, params):
        return MainWindow.create_mobile_workspace(self.window, params)

    def test_a_written_command_is_stored_in_the_vault_and_labels_the_box(self):
        workspace = self.create({"name": "ELTEMPLO", "kind": "ssh",
                                 "connect_command": "ssh root@eltemploacademy.com"})
        self.assertEqual(self.vault.stored, ["ssh root@eltemploacademy.com"])
        self.assertEqual(workspace["credentialId"], "cred-1")
        # The same label the desktop dialog writes for the same command, not a second spelling.
        self.assertEqual(workspace["hostLabel"], str(SSHCommand.parse("ssh root@eltemploacademy.com").endpoint_key()))
        self.assertEqual(workspace["kind"], "ssh")
        self.assertEqual(self.committed, [workspace])

    def test_a_command_with_a_password_reaches_the_vault_whole(self):
        command = "sshpass -p 'secreta' ssh dani@example.com"
        workspace = self.create({"name": "VPS", "kind": "ssh", "connect_command": command})
        self.assertEqual(self.vault.stored, [command])
        self.assertEqual(workspace["hostLabel"], str(SSHCommand.parse(command).endpoint_key()))

    def test_what_the_parser_refuses_never_reaches_the_vault(self):
        for command in ("rm -rf /", "ssh", "ssh root@x; rm -rf /", "curl http://x | sh"):
            with self.subTest(command=command):
                with self.assertRaises(RPCError) as raised:
                    self.create({"name": "VPS", "kind": "ssh", "connect_command": command})
                self.assertEqual(raised.exception.code, "invalid_params")
        self.assertEqual(self.vault.stored, [])

    def test_a_command_that_could_never_be_one_is_refused_before_parsing(self):
        for command in ("", " ssh root@x ", "ssh root@x\nrm -rf /", "ssh " + "a" * 4096, 7, None):
            with self.subTest(command=command):
                with self.assertRaises(RPCError):
                    self.create({"name": "VPS", "kind": "ssh", "connect_command": command})
        self.assertEqual(self.vault.stored, [])

    def test_a_locked_vault_refuses_before_anything_is_parsed_or_stored(self):
        self.vault.locked = True
        with self.assertRaises(RPCError) as raised:
            self.create({"name": "VPS", "kind": "ssh", "connect_command": "ssh root@example.com"})
        self.assertEqual(raised.exception.code, "locked")
        self.assertEqual(self.vault.stored, [])

    def test_inheriting_still_works_and_stores_nothing(self):
        workspace = self.create({"name": "Copia", "kind": "ssh", "source_workspace_id": "origen"})
        self.assertEqual(workspace["credentialId"], "cred-vieja")
        self.assertEqual(workspace["hostLabel"], "dani@example.com")
        self.assertEqual(self.vault.stored, [])


if __name__ == "__main__":
    unittest.main()
