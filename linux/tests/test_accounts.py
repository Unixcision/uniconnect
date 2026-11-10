"""accounts.v1 en Linux: la respuesta se arma solo con lo leído ahora, y la llamada del móvil."""

import json
from pathlib import Path
import sys
import threading
import time
import types
import unittest

try:
    import gi
    gi.require_version("Gtk", "3.0")
    from gi.repository import Gtk
    GTK_AVAILABLE = Gtk.init_check()[0]
except (ImportError, ValueError):
    GTK_AVAILABLE = False

sys.path.insert(0, str(Path(__file__).resolve().parent))
from contracts_dir import contract
from uniconnect.accounts import AccountsReader, color_of, driver_source
from uniconnect.mobile_protocol import RPCError
from uniconnect.mobile_rpc import MobileRPC

ACCOUNT = {"state": "ok", "email": "dev@notbetting.com", "method": "oauth", "plan": "Ultra",
           "organization": "dev@notbetting.com's Organization", "os_user": "root", "config": "/root/.claude.json",
           "read_at": "2026-11-10T12:30:05Z"}


def box(identifier, name, kind, windows, *, connection=None, label=None):
    return {"workspace": {"id": identifier, "name": name, "kind": kind}, "windows": windows,
            "connection": connection, "label": label}


def session(name, agent=None, reason=None):
    return {"name": name, "reason": reason, "agent": agent, "live": True}


class Completed:
    def __init__(self, stdout, returncode=0):
        self.stdout, self.returncode, self.stderr = stdout, returncode, ""


class BuildTests(unittest.TestCase):
    def boxes(self):
        return [box("w1", "PROYECTOS", "local", [{"id": "a", "name": "uniconnect", "tmux": "uc-a"},
                                                  {"id": "b", "name": "zsh", "tmux": "uc-b"},
                                                  {"id": "c", "name": "antigua"}]),
                box("w2", "NOTBETTING", "ssh", [{"id": "d", "name": "APP 2", "tmux": "app", "tmuxSocket": "default"},
                                                 {"id": "e", "name": "vieja", "tmux": "vieja", "tmuxSocket": "default"},
                                                 {"id": "f", "name": "codex", "tmux": "cx", "tmuxSocket": "default"}],
                    connection="ssh root@nb", label="root@203.0.113.10:22"),
                box("w3", "CLIENTE", "ssh", [{"id": "g", "name": "api", "tmux": "api"}], label="root@198.51.100.7:22")]

    def test_states_follow_the_contract_order_and_nothing_old_is_shown(self):
        boxes = self.boxes()
        hosts = AccountsReader.hosts_of(boxes)
        self.assertEqual(list(hosts), ["local", "ssh:root@203.0.113.10:22", "ssh:root@198.51.100.7:22"])
        self.assertEqual(hosts["ssh:root@203.0.113.10:22"]["sockets"], {"default": {"app", "vieja", "cx"}})
        local = {"uniconnect-local": {"sessions": [
            session("uc-a", {"provider": "claude", "as_root": False, "account": dict(ACCOUNT, os_user="dani")}),
            session("uc-b", reason="sin_ia")]}}
        remote = {"default": {"sessions": [
            session("app", {"provider": "claude", "as_root": True, "account": ACCOUNT}),
            session("cx", {"provider": "codex", "as_root": True, "account": {"state": "no_legible", "os_user": "root"}})]}}
        results = {"local": (("ok", local), "T1"), "ssh:root@203.0.113.10:22": (("ok", remote), "T2"),
                   "ssh:root@198.51.100.7:22": (("boveda_cerrada", None), "T3")}
        response = AccountsReader.build(boxes, hosts, results, checked_at="T9")
        expected = json.loads(contract("accounts-v1", "accounts-response.json").read_text())
        self.assertEqual(set(response), set(expected))
        self.assertEqual(set(response["hosts"][0]), set(expected["hosts"][0]))
        self.assertEqual(set(response["windows"][0]), set(expected["windows"][0]))
        self.assertEqual(set(response["windows"][0]["account"]), set(expected["windows"][0]["account"]))
        states = {item["terminal_id"]: item["state"] for item in response["windows"]}
        self.assertEqual(states, {"a": "ok", "b": "sin_ia", "c": "sin_tmux", "d": "ok", "e": "sesion_no_viva",
                                  "f": "no_legible", "g": "host_inaccesible"})
        first = response["windows"][0]
        self.assertEqual(first["agent"], {"provider": "claude", "display_name": "Claude Code", "as_root": False})
        self.assertNotIn("state", first["account"])  # El estado va en la ventana.
        self.assertEqual(first["account"]["os_user"], "dani")
        locked = next(item for item in response["windows"] if item["terminal_id"] == "g")
        self.assertEqual((locked["agent"], locked["account"]), (None, None))  # Sin la cuenta anterior.
        self.assertEqual([host["state"] for host in response["hosts"]], ["ok", "ok", "boveda_cerrada"])
        only = AccountsReader.only(response, "w2")
        self.assertEqual([item["terminal_id"] for item in only["windows"]], ["d", "e", "f"])
        self.assertEqual([host["host_key"] for host in only["hosts"]], ["ssh:root@203.0.113.10:22"])

    def test_one_call_per_host_and_a_host_that_fails_reads_nothing(self):
        calls = []

        class Transport:
            def __init__(self, command, socket_name=None):
                self.command = command

            def run_python(self, source, arguments, timeout):
                calls.append((self.command.destination if self.command else "local", json.loads(arguments[0]), timeout))
                if self.command:
                    return Completed("", returncode=255)
                output = [{"version": 1, "socket": "uniconnect-local",
                           "sessions": [session("uc-a", {"provider": "claude", "account": ACCOUNT})]}]
                return Completed("banner del perfil\nUC_ACCOUNTS_V1 " + json.dumps(output) + "\n")

        boxes = self.boxes()
        boxes[1]["connection"] = None  # Sin ssh -G en la prueba: la etiqueta guardada.
        boxes[2]["connection"] = "ssh root@cliente"
        response = AccountsReader(transport=Transport).read(boxes)
        self.assertEqual(sorted(call[0] for call in calls), ["local", "root@cliente"])
        self.assertEqual(calls[[c[0] for c in calls].index("local")][1], [["uniconnect-local", ["uc-a", "uc-b"]]])
        self.assertTrue(all(call[2] == 10 for call in calls))
        states = {item["terminal_id"]: item["state"] for item in response["windows"]}
        self.assertEqual((states["a"], states["d"], states["g"]), ("ok", "host_inaccesible", "host_inaccesible"))

    def test_a_request_during_a_read_shares_it(self):
        started, release, runs = threading.Event(), threading.Event(), []

        class Reader(AccountsReader):
            def collect(self, boxes):
                runs.append(1)
                started.set()
                release.wait(5)
                return {"version": 1, "checked_at": "T", "hosts": [], "windows": []}

        reader, results = Reader(), []
        first = threading.Thread(target=lambda: results.append(reader.read([])))
        first.start()
        started.wait(5)
        second = threading.Thread(target=lambda: results.append(reader.read([])))
        second.start()
        time.sleep(0.2)
        release.set()
        first.join(5)
        second.join(5)
        self.assertEqual((len(runs), len(results)), (1, 2))  # Una sola lectura, dos respuestas.
        self.assertIsNone(reader.inflight)  # Terminada, la siguiente petición vuelve a leer.

    def test_the_driver_is_the_shared_probe_plus_one_loop(self):
        source = driver_source().decode()
        self.assertIn("def account_of(", source)
        self.assertNotIn('if __name__ == "__main__":\n    sys.exit(main())', source)


class PaletteTests(unittest.TestCase):
    def test_same_account_same_color_everywhere(self):
        palette = json.loads(contract("accounts-v1", "paleta.json").read_text())
        for email, index in palette["ejemplos"].items():
            with self.subTest(email=email):
                self.assertEqual(color_of(email), palette["colores"][index])
        self.assertEqual(color_of(None), palette["neutro"])


@unittest.skipUnless(GTK_AVAILABLE, "GTK required")
class MobileAccountsTests(unittest.TestCase):
    def setUp(self):
        self.window = types.SimpleNamespace(
            store=types.SimpleNamespace(workspaces=[{"id": "w1", "name": "UNO", "kind": "local", "windows": []}], data={}),
            locked=False, vault=None, surfaces={}, focused_surface=None,
            accounts_reader=types.SimpleNamespace(read=lambda boxes: {
                "version": 1, "checked_at": "T", "hosts": [{"host_key": "local"}],
                "windows": [{"workspace_id": "w1", "host_key": "local"}, {"workspace_id": "w2", "host_key": "local"}]}))
        self.rpc = MobileRPC(self.window, types.SimpleNamespace(machine_id="fixture"), lambda callback: callback())

    def test_capability_and_errors_of_the_contract(self):
        errors = json.loads(contract("accounts-v1", "errors.json").read_text())
        self.assertIn("accounts.v1", self.rpc.dispatch("mobile.workspace.list", {}, "peer")["capabilities"])
        result = self.rpc.dispatch("mobile.accounts.list", {"workspace_id": "w1"}, "peer")
        self.assertEqual([item["workspace_id"] for item in result["windows"]], ["w1"])
        for params, code in (({"workspace_id": ""}, "invalid_params"), ({"workspace_id": 7}, "invalid_params"),
                             ({"workspace_id": "nope"}, "not_found")):
            with self.subTest(params=params), self.assertRaises(RPCError) as caught:
                self.rpc.dispatch("mobile.accounts.list", params, "peer")
            self.assertEqual((caught.exception.code, caught.exception.message), (code, errors[code]["mensaje"]))
        self.window.locked = True
        with self.assertRaises(RPCError) as caught:
            self.rpc.dispatch("mobile.accounts.list", {}, "peer")
        self.assertEqual((caught.exception.code, caught.exception.message), ("locked", errors["locked"]["mensaje"]))


if __name__ == "__main__":
    unittest.main()
