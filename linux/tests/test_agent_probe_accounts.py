"""accounts-v1: la cuenta de cada IA, con los casos de contracts/accounts-v1/sonda-cuentas.json."""

import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from uniconnect import agent_probe
from uniconnect.agent_probe import account_of, claude_usage, codex_live_usage, codex_usage

sys.path.insert(0, str(Path(__file__).resolve().parent))
from contracts_dir import contract


def file_reader(ficheros):
    """``read_file`` falso: lo que no está en ``ficheros`` no existe."""
    def read(path):
        entry = ficheros.get(path)
        if entry is None:
            return ("absent", None)
        if entry["estado"] == "ok":
            return ("ok", entry["json"])
        return (entry["estado"], None)
    return read


def text_reader(ficheros):
    """``read_text`` falso, para los ficheros de texto (``texto``) como ``cuentas-token``."""
    def read(path):
        entry = ficheros.get(path)
        if entry is None or (entry["estado"] == "ok" and "texto" not in entry):
            return ("absent", None)
        if entry["estado"] == "ok":
            return ("ok", entry["texto"])
        return (entry["estado"], None)
    return read


class AccountContractCaseTests(unittest.TestCase):
    """Cada caso de sonda-cuentas.json da exactamente su ``espera``, y ningún secreto sale."""

    def test_every_account_case(self):
        data = json.loads(contract("accounts-v1", "sonda-cuentas.json").read_text(encoding="utf-8"))
        self.assertTrue(data["casos"], "sonda-cuentas.json no trae ningún caso")
        for case in data["casos"]:
            with self.subTest(caso=case["nombre"]):
                user = tuple(case["usuario"])
                result = account_of(case["provider"], case["uid"], case["entorno"], file_reader(case["ficheros"]),
                                    lambda uid, user=user: user, data["read_at"],
                                    read_text=text_reader(case["ficheros"]))
                self.assertEqual(result, case["espera"])
                self.assertNotIn("NO-SALE", json.dumps(result))
                self.assertNotIn("no-sale", json.dumps(result))


class UsageContractCaseTests(unittest.TestCase):
    """Cada caso de ``usos`` en sonda-cuentas.json da exactamente su ``espera``."""

    def test_every_usage_case(self):
        data = json.loads(contract("accounts-v1", "sonda-cuentas.json").read_text(encoding="utf-8"))
        self.assertTrue(data["usos"], "sonda-cuentas.json no trae ningún caso de uso")
        for case in data["usos"]:
            with self.subTest(caso=case["nombre"]):
                if case["funcion"] == "claude_usage":
                    result = claude_usage(case["documento"], case["email"])
                elif case["funcion"] == "codex_live_usage":
                    result = codex_live_usage(case["documento"], case["observed_at"])
                else:
                    result = codex_usage(case["documento"])
                self.assertEqual(result, case["espera"])

    def test_usage_is_only_read_for_an_account_with_email(self):
        calls = []

        def usage_of(provider, folder, email, pid=None, uid=None, environment=None):
            calls.append((provider, folder, email, pid, uid))
            return {"source": "statusline", "observed_at": "2026-11-10T12:00:00Z", "limits": []}

        def read(path):
            if path == "/root/.claude.json":
                return ("ok", {"oauthAccount": {"emailAddress": "dev@notbetting.com"}})
            return ("absent", None)

        ok = account_of("claude", 0, {"HOME": "/root"}, read, lambda uid: ("root", "/root"), "t", usage_of, 41)
        self.assertEqual(calls, [("claude", "/root/.claude", "dev@notbetting.com", 41, 0)])
        self.assertEqual(ok["usage"]["source"], "statusline")
        calls.clear()
        none = account_of("claude", 0, {"HOME": "/x"}, lambda path: ("absent", None), lambda uid: ("x", "/x"), "t", usage_of)
        self.assertEqual((none["state"], none["usage"], calls), ("sin_sesion", None, []))


class SetupTokenTests(unittest.TestCase):
    """Una Claude con token de setup-token sale con la cuenta del token, y el token no sale nunca."""

    TOKEN = "sk-ant-oat01-NO-SALE-prueba"

    def test_fingerprint_is_the_one_the_status_line_computes(self):
        if not shutil.which("openssl"):
            self.skipTest("sin openssl")
        status_line = subprocess.run(["openssl", "dgst", "-sha256", "-r"], input=self.TOKEN.encode(),
                                     stdout=subprocess.PIPE, check=True).stdout.decode()[:16]
        self.assertEqual(agent_probe.token_fingerprint(self.TOKEN.encode()), status_line)

    def test_a_live_process_leaves_only_its_fingerprint(self):
        environment = dict(os.environ, CLAUDE_CODE_OAUTH_TOKEN=self.TOKEN, HOME="/home/prueba")
        # El propio intérprete y no `sleep`: macOS 27 no enseña el entorno de los binarios de Apple.
        child = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)"], env=environment)
        try:
            values = agent_probe.HostReader().account_environment(child.pid)
        finally:
            child.kill()
            child.wait()
        if values is None or values.get("HOME") != "/home/prueba":
            self.skipTest("este sistema no deja leer el entorno de ese proceso (binario de Apple en macOS)")
        self.assertEqual(values.get("CLAUDE_CODE_OAUTH_TOKEN"), hashlib.sha256(self.TOKEN.encode()).hexdigest()[:16])
        self.assertNotIn("NO-SALE", json.dumps(values))

    def test_usage_comes_from_the_token_file_of_that_account(self):
        folder = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, folder)
        huella = agent_probe.token_fingerprint(self.TOKEN.encode())
        limits = {"seven_day": {"used_percentage": 21, "resets_at": 1794650400}}
        Path(folder, "uniconnect-uso-%s.json" % huella).write_text(json.dumps(
            {"version": 1, "email": "unixcision@gmail.com", "observed_at": "2026-11-14T13:13:39Z", "rate_limits": limits}))
        Path(folder, "uniconnect-uso.json").write_text(json.dumps(
            {"version": 1, "email": "subs@iberiavo.com", "observed_at": "2026-11-14T13:34:02Z",
             "rate_limits": {"seven_day": {"used_percentage": 80, "resets_at": 1794650400}}}))
        reader = agent_probe.HostReader()
        usage = reader.usage_of("claude", folder, "unixcision@gmail.com", environment={"CLAUDE_CODE_OAUTH_TOKEN": huella})
        self.assertEqual([limit["used_percent"] for limit in usage["limits"]], [21.0])
        # El fichero común es de otra cuenta: no se le atribuye a la del token.
        other = agent_probe.HostReader().usage_of("claude", folder, "unixcision@gmail.com", environment={})
        self.assertIsNone(other)


class ProbeAccountsFlagTests(unittest.TestCase):
    """``--accounts`` añade ``account`` a cada IA; sin él la salida no cambia."""

    NOW = 1794313804  # 2026-11-10T12:30:04Z

    class Reader:
        truncated = False

        def __init__(self):
            self.environments = []

        def host(self):
            return {"hostname": "noleakos", "uid": 0, "platform": "linux"}

        def panes(self, socket_name):
            return [{"session": "hunt", "session_id": "$1", "window_index": 0, "pane_id": "%1", "pane_pid": 10,
                     "dead": False, "current_path": "/root", "current_command": "claude"}], None

        def processes(self):
            return {10: {"pid": 10, "ppid": 1, "uid": 0, "argv": ["-bash"]},
                    11: {"pid": 11, "ppid": 10, "uid": 0, "argv": ["/root/.local/share/claude/versions/2.1.321"]}}

        def ficha(self, pid, uid):
            return None

        def open_files(self, pid):
            return []

        def cwd(self, pid):
            return "/root"

        def account_environment(self, pid):
            self.environments.append(pid)
            return {"HOME": "/root"}

        def read_account_file(self, path):
            if path == "/root/.claude.json":
                return ("ok", {"oauthAccount": {"emailAddress": "dev@notbetting.com", "planDisplayName": "Ultra"}})
            return ("absent", None)

        @staticmethod
        def user_of(uid):
            return ("root", "/root")

        @staticmethod
        def first_line(path):
            return None

        @staticmethod
        def realpath(path):
            return path

    def run_main(self, arguments):
        reader, out = self.Reader(), io.StringIO()
        self.assertEqual(agent_probe.main(arguments, reader=reader, stdout=out, now=self.NOW), 0)
        return json.loads(out.getvalue()), reader

    def test_without_flag_output_has_no_account(self):
        data, reader = self.run_main(["--socket", "default"])
        self.assertNotIn("account", data["sessions"][0]["agent"])
        self.assertEqual(reader.environments, [])

    def test_with_flag_each_agent_carries_its_account(self):
        data, reader = self.run_main(["--socket", "default", "--accounts", "--session", "hunt"])
        account = data["sessions"][0]["agent"]["account"]
        self.assertEqual(account, {"state": "ok", "email": "dev@notbetting.com", "method": "oauth", "plan": "Ultra",
                                   "organization": None, "os_user": "root", "config": "/root/.claude.json",
                                   "read_at": "2026-11-10T12:30:04Z", "usage": None})
        self.assertEqual(reader.environments, [11])

    def test_with_flag_a_token_session_carries_the_token_account(self):
        huella = agent_probe.token_fingerprint(b"sk-ant-oat01-NO-SALE")

        class Reader(self.Reader):
            def account_environment(self, pid):
                self.environments.append(pid)
                return {"HOME": "/root", "CLAUDE_CODE_OAUTH_TOKEN": huella}

            def read_account_text(self, path):
                return ("ok", "%s kin@example.com\n" % huella) if path == "/root/.claude/cuentas-token" else ("absent", None)

        reader, out = Reader(), io.StringIO()
        self.assertEqual(agent_probe.main(["--socket", "default", "--accounts"], reader=reader, stdout=out, now=self.NOW), 0)
        account = json.loads(out.getvalue())["sessions"][0]["agent"]["account"]
        self.assertEqual((account["state"], account["method"], account["email"], account["config"]),
                         ("ok", "setup_token", "kin@example.com", "/root/.claude/cuentas-token"))
        self.assertNotIn("NO-SALE", out.getvalue())

    def test_unknown_option_is_still_misuse(self):
        self.assertIsNone(agent_probe.parse_arguments(["--accounts=yes"]))
        self.assertEqual(agent_probe.parse_arguments(["--accounts"]), ("default", [], True, None))


class CodexResetModeTests(unittest.TestCase):
    """``--codex-reset``: solo con una sesión, solo sobre un Codex, y la salida lleva ``codex_reset``."""

    NOW = 1794313804

    class Reader(ProbeAccountsFlagTests.Reader):
        def __init__(self, argv):
            super().__init__()
            self.argv = argv
            self.resets = []

        def processes(self):
            return {10: {"pid": 10, "ppid": 1, "uid": 0, "argv": ["-bash"]},
                    11: {"pid": 11, "ppid": 10, "uid": 0, "argv": self.argv}}

        def codex_reset(self, pid, uid, folder, environment, key):
            self.resets.append((pid, uid, folder, key))
            return {"outcome": "reset", "usage": None}

    def run_main(self, argv, arguments):
        reader, out = self.Reader(argv), io.StringIO()
        status = agent_probe.main(arguments, reader=reader, stdout=out, now=self.NOW)
        return status, (json.loads(out.getvalue()) if out.getvalue() else None), reader

    def test_resets_the_codex_of_the_only_session(self):
        status, data, reader = self.run_main(["codex", "resume", "--yolo"],
                                             ["--session", "hunt", "--codex-reset", "3f1c2b9e-uniconnect-1"])
        self.assertEqual(status, 0)
        self.assertEqual(data["codex_reset"], {"outcome": "reset", "usage": None})
        self.assertEqual(reader.resets, [(11, 0, "/root/.codex", "3f1c2b9e-uniconnect-1")])

    def test_refuses_anything_but_codex(self):
        status, data, reader = self.run_main(["/root/.local/share/claude/versions/2.1.321"],
                                             ["--session", "hunt", "--codex-reset", "3f1c2b9e-uniconnect-1"])
        self.assertEqual(data["codex_reset"], {"error": "no_es_codex"})
        self.assertEqual(reader.resets, [])

    def test_needs_exactly_one_session_and_a_sane_key(self):
        self.assertIsNone(agent_probe.parse_arguments(["--codex-reset", "3f1c2b9e-uniconnect-1"]))
        self.assertIsNone(agent_probe.parse_arguments(["--session", "a", "--session", "b", "--codex-reset", "3f1c2b9e-u"]))
        self.assertIsNone(agent_probe.parse_arguments(["--session", "a", "--codex-reset", "x; rm -rf /"]))


class PaletteContractTests(unittest.TestCase):
    """paleta.json: el índice de color es FNV-1a de 32 bits del email en minúsculas, mod 8."""

    @staticmethod
    def index(email):
        value = 0x811C9DC5
        for byte in email.lower().encode("utf-8"):
            value = ((value ^ byte) * 0x01000193) & 0xFFFFFFFF
        return value % 8

    def test_examples(self):
        data = json.loads(contract("accounts-v1", "paleta.json").read_text(encoding="utf-8"))
        self.assertEqual(len(data["colores"]), 8)
        for email, expected in data["ejemplos"].items():
            self.assertEqual(self.index(email), expected, email)


if __name__ == "__main__":
    unittest.main()
