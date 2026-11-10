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
import tempfile
from uniconnect.accounts import AccountsReader, UsageHistory, color_of, driver_source
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
        results = {"local": (("ok", local, None, None), "T1"), "ssh:root@203.0.113.10:22": (("ok", remote, None, None), "T2"),
                   "ssh:root@198.51.100.7:22": (("boveda_cerrada", None, None, None), "T3")}
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
        self.assertEqual(set(response["accounts"][0]), set(expected["accounts"][0]))
        self.assertEqual([(a["key"], a["windows"], a["host_keys"]) for a in response["accounts"]],
                         [("claude:dev@notbetting.com", 2, ["local", "ssh:root@203.0.113.10:22"])])
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
                    completed = Completed("", returncode=255)
                    completed.stderr = "root@cliente: Permission denied (publickey).\n"
                    return completed
                output = [{"version": 1, "socket": "uniconnect-local",
                           "sessions": [session("uc-a", {"provider": "claude", "account": ACCOUNT})]}]
                return Completed("banner del perfil\nUC_ACCOUNTS_V1 " + json.dumps(output) + "\n")

        boxes = self.boxes()
        boxes[1]["connection"] = None  # Sin ssh -G en la prueba: la etiqueta guardada.
        boxes[2]["connection"] = "ssh root@cliente"
        history = UsageHistory(Path(tempfile.mkdtemp()) / "historia.json")
        response = AccountsReader(transport=Transport, history=history).read(boxes)
        self.assertEqual(sorted(call[0] for call in calls), ["local", "root@cliente"])
        self.assertEqual(calls[[c[0] for c in calls].index("local")][1], [["uniconnect-local", ["uc-a", "uc-b"]]])
        self.assertTrue(all(call[2] == 10 for call in calls))
        states = {item["terminal_id"]: item["state"] for item in response["windows"]}
        self.assertEqual((states["a"], states["d"], states["g"]), ("ok", "host_inaccesible", "host_inaccesible"))
        failed = next(host for host in response["hosts"] if host["host_key"].startswith("ssh:root@cliente"))
        self.assertEqual((failed["error"], failed["error_detail"]),
                         ("ssh_fallo", "root@cliente: Permission denied (publickey)."))

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


class HistoryTests(unittest.TestCase):
    def test_one_sample_per_five_minutes_seven_days_shown_fourteen_kept(self):
        history = UsageHistory(Path(tempfile.mkdtemp()) / "accounts-usage-history.json")
        base = 1_794_000_000
        def account(at, percent):
            stamp = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(at))
            return {"key": "claude:dev@notbetting.com",
                    "usage": {"observed_at": stamp, "limits": [{"id": "seven_day", "used_percent": percent}]}}
        history.record([account(base - 10 * 86400, 5.0)], base - 10 * 86400)
        history.record([account(base, 40.0)], base)
        shown = history.record([account(base + 120, 41.0)], base + 120)  # A menos de 5 min: la sustituye.
        self.assertEqual([item["limits"]["seven_day"] for item in shown["claude:dev@notbetting.com"]], [41.0])
        shown = history.record([account(base + 60, 99.0)], base + 400)  # Anterior a la última: no entra.
        self.assertEqual([item["limits"]["seven_day"] for item in shown["claude:dev@notbetting.com"]], [41.0])
        self.assertEqual(len(history.load()["claude:dev@notbetting.com"]), 2)  # La de hace 10 días se guarda.


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


class UsageFormulaTests(unittest.TestCase):
    """§4.1: la misma fórmula de ritmo y proyección en Mac, Linux y Android."""

    NOW = 1_794_000_000

    def stamp(self, at):
        return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(at))

    def test_pace_projection_and_exhaustion(self):
        from uniconnect.accounts_usage import pace
        limit = {"id": "seven_day", "used_percent": 51.0, "resets_at": self.stamp(self.NOW + 2 * 86400),
                 "window_minutes": 10080}
        usage = {"observed_at": self.stamp(self.NOW)}
        history = [{"at": self.stamp(self.NOW - 86400), "limits": {"seven_day": 41.0}},
                   {"at": self.stamp(self.NOW - 9 * 86400), "limits": {"seven_day": 2.0}}]  # Fuera de la ventana.
        daily, projection, exhausted = pace(limit, usage, history, self.NOW)
        self.assertAlmostEqual(daily, 10.0)
        self.assertAlmostEqual(projection, 71.0)
        self.assertIsNone(exhausted)
        fast = [{"at": self.stamp(self.NOW - 3600), "limits": {"seven_day": 41.0}}]
        daily, projection, exhausted = pace(limit, usage, fast, self.NOW)
        self.assertGreater(projection, 100)
        self.assertAlmostEqual(exhausted, self.NOW + 49 / 10 * 3600)  # «Se agotaría el …».
        close = [{"at": self.stamp(self.NOW - 600), "limits": {"seven_day": 50.0}}]
        self.assertIsNone(pace(limit, usage, close, self.NOW))  # Menos de 30 min entre muestras: nada.

    def test_a_passed_reset_is_zero_and_names_follow_the_contract(self):
        from uniconnect.accounts_usage import effective, limit_name, span
        self.assertEqual(effective({"used_percent": 88.0, "resets_at": self.stamp(self.NOW - 60)}, self.NOW), (0.0, True))
        self.assertEqual(effective({"used_percent": 88.0, "resets_at": self.stamp(self.NOW + 60)}, self.NOW), (88.0, False))
        self.assertEqual(limit_name({"id": "seven_day_opus"}, "claude"), "Semana · Opus")
        self.assertEqual(limit_name({"id": "primary", "window_minutes": 300}, "codex"), "5 horas")
        self.assertEqual(limit_name({"id": "secondary", "window_minutes": 10080}, "codex"), "Semana")
        self.assertEqual(limit_name({"id": "x", "window_minutes": 120}, "codex"), "2 h")
        self.assertEqual((span(2 * 86400 + 3 * 3600 + 59), span(3 * 3600 + 20 * 60), span(30)), ("2 d 3 h", "3 h 20 min", "1 min"))


class CodexResetTests(unittest.TestCase):
    def test_spends_on_the_first_ok_window_of_that_account_in_that_host(self):
        calls = []
        account = dict(ACCOUNT, email="it@iberiavo.com", method="chatgpt")

        class Transport:
            def __init__(self, command, socket_name=None):
                pass

            def run_python(self, source, arguments, timeout):
                calls.append(arguments)
                if arguments and arguments[0].startswith("["):
                    output = [{"version": 1, "socket": "uniconnect-local", "sessions": [
                        session("uc-x", {"provider": "codex", "account": account})]}]
                    return Completed("UC_ACCOUNTS_V1 " + json.dumps(output) + "\n")
                return Completed(json.dumps({"version": 1, "codex_reset": {"outcome": "reset", "usage": {"limits": []}}}) + "\n")

        reader = AccountsReader(transport=Transport, history=UsageHistory(Path(tempfile.mkdtemp()) / "h.json"))
        boxes = [box("w", "LOCAL", "local", [{"id": "x", "name": "codex", "tmux": "uc-x"}])]
        key = "6f1c9a1e-2b3d-4c5e-8f70-112233445566"
        result = reader.codex_reset(boxes, "codex:it@iberiavo.com", "local", key)
        self.assertEqual(result, {"account_key": "codex:it@iberiavo.com", "host_key": "local", "outcome": "reset",
                                  "usage": {"limits": []}})
        self.assertEqual(calls[-1], ["--socket", "uniconnect-local", "--session", "uc-x", "--codex-reset", key])
        for args, code in ((("codex:nadie@x.com", "local", key), "not_found"), (("claude:it@iberiavo.com", "local", key),
                           "invalid_params"), (("codex:it@iberiavo.com", "local", "no-es-uuid"), "invalid_params")):
            with self.subTest(args=args), self.assertRaises(RPCError) as caught:
                reader.codex_reset(boxes, *args)
            self.assertEqual(caught.exception.code, code)
