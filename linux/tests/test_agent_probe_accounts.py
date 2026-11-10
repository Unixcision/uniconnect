"""accounts-v1: la cuenta de cada IA, con los casos de contracts/accounts-v1/sonda-cuentas.json."""

import io
import json
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from uniconnect import agent_probe
from uniconnect.agent_probe import account_of

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


class AccountContractCaseTests(unittest.TestCase):
    """Cada caso de sonda-cuentas.json da exactamente su ``espera``, y ningún secreto sale."""

    def test_every_account_case(self):
        data = json.loads(contract("accounts-v1", "sonda-cuentas.json").read_text(encoding="utf-8"))
        self.assertTrue(data["casos"], "sonda-cuentas.json no trae ningún caso")
        for case in data["casos"]:
            with self.subTest(caso=case["nombre"]):
                user = tuple(case["usuario"])
                result = account_of(case["provider"], case["uid"], case["entorno"], file_reader(case["ficheros"]),
                                    lambda uid, user=user: user, data["read_at"])
                self.assertEqual(result, case["espera"])
                self.assertNotIn("NO-SALE", json.dumps(result))
                self.assertNotIn("no-sale", json.dumps(result))


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
                                   "read_at": "2026-11-10T12:30:04Z"})
        self.assertEqual(reader.environments, [11])

    def test_unknown_option_is_still_misuse(self):
        self.assertIsNone(agent_probe.parse_arguments(["--accounts=yes"]))
        self.assertEqual(agent_probe.parse_arguments(["--accounts"]), ("default", [], True))


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
