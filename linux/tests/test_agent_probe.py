"""Sonda agent-tree.v1: criterio común de detección con tablas inyectadas, sin tocar el host."""

import io
import json
from pathlib import Path
import subprocess
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from uniconnect import agent_probe
from uniconnect.agent_probe import combine, discover, provider_of

sys.path.insert(0, str(Path(__file__).resolve().parent))
from contracts_dir import contract

CLAUDE_ID = "473ed1de-4397-45ef-b00b-6b17fd7382b0"
OLD_ID = "11111111-2222-4333-8444-555555555555"
CODEX_ID = "01a0ac81-57c7-7af3-8ac2-fe8a957c8b17"
PROBE_HOST = {"hostname": "xunis-scrapper", "uid": 0, "platform": "linux"}


def proc(pid, ppid, argv, uid=1000):
    return {"pid": pid, "ppid": ppid, "uid": uid, "argv": argv}


def run(processes, pane_pid=100, fichas=None, opened=None, lines=None, cwds=None, pane_path="/pane", links=None):
    fichas, opened, lines, cwds, links = fichas or {}, opened or {}, lines or {}, cwds or {}, links or {}
    return discover(pane_pid, processes, lambda pid, uid: fichas.get(pid), lambda pid: opened.get(pid, []),
                    lambda path: lines.get(path), lambda pid: cwds.get(pid), pane_path=pane_path,
                    realpath=lambda path: links.get(path, path))


class ContractCaseTests(unittest.TestCase):
    """Todos los casos de contracts/agent-tree-v1/deteccion-casos.json, con sus claves tal cual."""

    def test_every_shared_detection_case(self):
        data = json.loads(contract("agent-tree-v1", "deteccion-casos.json").read_text(encoding="utf-8"))
        self.assertTrue(data["casos"], "deteccion-casos.json no trae ningún caso")
        for case in data["casos"]:
            with self.subTest(caso=case["nombre"]):
                table = {int(item["pid"]): proc(int(item["pid"]), int(item["ppid"]), item["argv"], int(item.get("uid", 1000)))
                         for item in case["procesos"]}
                result = run(table, int(case["pane_pid"]),
                             {int(key): value for key, value in case.get("fichas", {}).items()},
                             {int(key): value for key, value in case.get("abiertos", {}).items()},
                             case.get("rollouts", {}),
                             {int(key): value for key, value in case.get("cwds", {}).items()},
                             case.get("pane_current_path"), case.get("enlaces", {}))
                agent = result["agent"] or {}
                actual = {"provider": agent.get("provider"), "session_id": agent.get("session_id"),
                          "cwd": agent.get("cwd"), "as_root": agent.get("as_root"), "source": agent.get("source"),
                          "cause": result["reason"]}
                # Solo se comparan las claves que trae «espera».
                for key, expected in case["espera"].items():
                    self.assertEqual(actual[key], expected, key)


class OwnDetectionTests(unittest.TestCase):
    def test_ficha_beats_stale_argv_after_clear(self):
        table = [proc(100, 1, ["-zsh"]), proc(200, 100, ["claude", "--resume", OLD_ID, "--dangerously-skip-permissions"])]
        result = run(table, fichas={200: {"pid": 200, "sessionId": CLAUDE_ID.upper(), "cwd": "/root/xunis",
                                          "status": "idle", "version": "2.1.280", "procStart": "x"}})
        self.assertIsNone(result["reason"])
        self.assertEqual(result["agent"]["session_id"], CLAUDE_ID)
        self.assertEqual((result["agent"]["source"], result["agent"]["cwd"], result["agent"]["status"]),
                         ("ficha", "/root/xunis", "idle"))
        without = run(table)
        self.assertEqual((without["agent"]["session_id"], without["agent"]["source"]), (OLD_ID, "argv"))

    def test_node_launcher_with_native_codex_grandchild_is_one_root(self):
        rollout = "/home/u/.codex/sessions/2026/09/24/rollout-2026-09-24T10-00-00-" + CODEX_ID + ".jsonl"
        table = [proc(100, 1, ["bash"]), proc(200, 100, ["node", "/usr/local/bin/codex", "--yolo", "resume", CODEX_ID]),
                 proc(300, 200, ["/usr/local/lib/node_modules/@openai/codex/vendor/codex-x86_64-unknown-linux-musl"]),
                 proc(400, 300, ["bash", "-c", "ls"])]
        result = run(table, opened={300: ["/dev/null", rollout]},
                     lines={rollout: json.dumps({"type": "session_meta", "payload": {"cwd": "/home/u/multigram"}})})
        self.assertEqual(result["roots"], [200])
        self.assertEqual((result["agent"]["provider"], result["agent"]["session_id"], result["agent"]["source"],
                          result["agent"]["cwd"]), ("codex", CODEX_ID, "rollout", "/home/u/multigram"))
        argv_only = run(table)
        self.assertEqual((argv_only["agent"]["session_id"], argv_only["agent"]["source"]), (CODEX_ID, "argv"))
        fresh = run([proc(100, 1, ["bash"]), proc(200, 100, ["codex"])], cwds={200: "/work"})
        self.assertEqual((fresh["reason"], fresh["agent"]["session_id"], fresh["agent"]["cwd"]), ("sin_id", None, "/work"))

    def test_codex_run_by_claude_bash_tool_is_not_a_root(self):
        table = [proc(100, 1, ["zsh"]), proc(200, 100, ["claude"]), proc(300, 200, ["/bin/bash", "-c", "codex exec x"]),
                 proc(400, 300, ["codex", "exec", "x"])]
        result = run(table, fichas={200: {"sessionId": CLAUDE_ID}})
        self.assertEqual(result["roots"], [200])
        self.assertEqual(result["agent"]["provider"], "claude")

    def test_two_claude_processes_are_ambiguous(self):
        table = [proc(100, 1, ["bash"]), proc(200, 100, ["claude"]), proc(300, 100, ["claude", "--resume", OLD_ID])]
        result = run(table, fichas={200: {"sessionId": CLAUDE_ID}})
        self.assertEqual(result["reason"], "identidad_ambigua")
        self.assertIsNone(result["agent"])
        self.assertEqual(result["roots"], [200, 300])

    def test_descends_through_sudo_and_env_as_root(self):
        table = [proc(100, 1, ["-bash"]), proc(200, 100, ["sudo", "-E", "env", "IS_SANDBOX=1", "claude"], uid=0),
                 proc(300, 200, ["env", "IS_SANDBOX=1", "claude"], uid=0),
                 proc(400, 300, ["/root/.local/share/claude/versions/2.1.280", "--resume", CLAUDE_ID], uid=0)]
        result = run(table, cwds={400: "/root/xunis"})
        self.assertEqual(result["roots"], [400])
        self.assertEqual((result["agent"]["provider"], result["agent"]["as_root"], result["agent"]["session_id"],
                          result["agent"]["source"], result["agent"]["cwd"]), ("claude", True, CLAUDE_ID, "argv", "/root/xunis"))

    def test_recycled_pid_ficha_is_ignored(self):
        table = [proc(100, 1, ["bash"]), proc(200, 100, ["vim", "notes.txt"])]
        self.assertEqual(run(table, fichas={200: {"sessionId": CLAUDE_ID}})["reason"], "sin_ia")
        # Una ficha de otro pid (renombrada o copiada) tampoco da identidad.
        claude = [proc(100, 1, ["bash"]), proc(200, 100, ["claude"])]
        stale = run(claude, fichas={200: {"pid": 999, "sessionId": CLAUDE_ID}})
        self.assertEqual((stale["reason"], stale["agent"]["session_id"]), ("sin_id", None))

    def test_process_outside_pane_subtree_never_counts(self):
        # P12: un Terminal.app con el mismo entorno no es descendiente del panel.
        table = [proc(100, 1, ["zsh"]), proc(900, 1, ["claude", "--resume", CLAUDE_ID])]
        self.assertEqual(run(table)["reason"], "sin_ia")
        self.assertEqual(run(table, pane_pid=555)["reason"], "panel_muerto")

    def test_session_with_several_panes_counts_only_the_pane_with_a_root(self):
        table = [proc(100, 1, ["bash"]), proc(101, 1, ["bash"]), proc(200, 101, ["grok", "-r", "conv_42"])]
        panes = [({"pane_id": "%1"}, run(table, 100)), ({"pane_id": "%2"}, run(table, 101))]
        pane, result = combine(panes)
        self.assertEqual((pane["pane_id"], result["agent"]["provider"], result["agent"]["session_id"]), ("%2", "grok", "conv_42"))
        table.append(proc(300, 100, ["agy", "--conversation", "abc"]))
        pane, result = combine([({"pane_id": "%1"}, run(table, 100)), ({"pane_id": "%2"}, run(table, 101))])
        self.assertEqual(result["reason"], "identidad_ambigua")
        pane, result = combine([({"pane_id": "%1", "dead": True}, run(table, 100))])
        self.assertEqual(result["reason"], "panel_muerto")

    def test_provider_markers(self):
        self.assertEqual(provider_of(["node", "/x/node_modules/@anthropic-ai/claude-code/cli.js"]), "claude")
        self.assertEqual(provider_of(["bun", "/x/codex.js"]), "codex")
        self.assertEqual(provider_of(["codex-aarch64-apple-darwin"]), "codex")
        self.assertEqual(provider_of(["antigravity"]), "agy")
        self.assertEqual(provider_of(["grok-cli"]), "grok")
        # Criterio estricto: node/bun con un argumento de basename «claude» sí; CLAUDE.md en un argumento, no.
        self.assertEqual(provider_of(["node", "/opt/homebrew/bin/claude", "--resume", CLAUDE_ID]), "claude")
        self.assertEqual(provider_of(["node22.3", "/x/claude"]), "claude")
        self.assertEqual(provider_of(["/home/u/.local/share/claude/versions/2.1.280"]), "claude")
        for argv in (["node", "server.js"], ["sudo", "claude"], ["python3", "codex.py"], ["-zsh"], [],
                     ["vim", "/root/.claude/CLAUDE.md"], ["node", "/x/claude.md"], ["nodemon", "/x/claude"]):
            self.assertIsNone(provider_of(argv), argv)

    def test_argv_ids_are_conservative(self):
        claude = [proc(100, 1, ["bash"])]
        for argv, expected in ((["claude", "--", "--resume", CLAUDE_ID], None),
                               (["claude", "--resume", CLAUDE_ID, "--session-id", OLD_ID], None),
                               (["claude", "--resume", CLAUDE_ID.upper(), "-r", CLAUDE_ID], CLAUDE_ID),
                               (["claude", "--resume=" + CLAUDE_ID], CLAUDE_ID),
                               (["claude", "-r=" + CLAUDE_ID], None),
                               (["claude", "--resume", "--model", "opus"], None),
                               (["claude", "--resume", "no-es-uuid"], None)):
            with self.subTest(argv=argv):
                result = run(claude + [proc(200, 100, argv)])
                self.assertEqual(result["agent"]["session_id"], expected)
                self.assertEqual(result["reason"], None if expected else "sin_id")


class FakeReader:
    """Lector inyectado: nada de tmux, /proc, ps ni lsof del host de pruebas."""

    def __init__(self, panes, processes, fichas=None, *, opened=None, cwds=None, lines=None, error=None,
                 truncated=False, host=None):
        self._panes, self._processes, self._fichas = panes, processes, fichas or {}
        self._opened, self._cwds, self._lines, self._error = opened or {}, cwds or {}, lines or {}, error
        self.truncated = truncated
        self._host = host or PROBE_HOST
        self.calls = []

    def host(self):
        return dict(self._host)

    def panes(self, socket_name):
        self.calls.append(("panes", socket_name))
        return self._panes, self._error

    def processes(self):
        return {item["pid"]: item for item in self._processes}

    def ficha(self, pid, uid):
        return self._fichas.get(pid)

    def open_files(self, pid):
        return self._opened.get(pid, [])

    def cwd(self, pid):
        return self._cwds.get(pid)

    def first_line(self, path):
        return self._lines.get(path)

    @staticmethod
    def realpath(path):
        return path


def pane(session, session_id, window, pane_id, pid, dead, path, command):
    return {"session": session, "session_id": session_id, "window_index": window, "pane_id": pane_id,
            "pane_pid": pid, "dead": dead, "current_path": path, "current_command": command}


CODEX_2 = "019a4e2b-6c3d-7f81-9a05-3e7b1c8d2f46"
ROLLOUT = "/root/.codex/sessions/2026/09/24/rollout-2026-09-24T10-12-40-" + CODEX_ID + ".jsonl"
EXAMPLE_PANES = [
    pane("claudebets", "$0", 0, "%0", 41230, False, "/root/xunis", "claude"),
    pane("scrapper-codex", "$1", 0, "%1", 41390, False, "/root", "node"),
    pane("ufabetbot", "$2", 0, "%2", 41510, False, "/root/ufabetbot", "claude"),
    pane("hgabot", "$3", 0, "%3", 41600, False, "/root/hgabot", "python3"),
    pane("pruebas", "$4", 0, "%4", 41700, False, "/root/pruebas", "bash"),
    pane("caida", "$5", 0, "%5", 41800, True, "/root/caida", "claude"),
    pane("api", "$6", 0, "%6", 41900, False, "/root/api", "bash"),
    pane("api", "$6", 1, "%7", 41950, False, "/root/api", "codex"),
]
EXAMPLE_PROCESSES = [
    proc(41230, 1, ["-bash"], 0), proc(41251, 41230, ["claude", "--dangerously-skip-permissions"], 0),
    proc(41390, 1, ["-bash"], 0),
    proc(41402, 41390, ["node", "/usr/lib/node_modules/@openai/codex/bin/codex.js", "--yolo"], 0),
    proc(41410, 41402, ["/usr/lib/node_modules/@openai/codex/vendor/x86_64-unknown-linux-musl/codex/"
                        "codex-x86_64-unknown-linux-musl", "--yolo"], 0),
    proc(41510, 1, ["-bash"], 0), proc(41522, 41510, ["claude", "login"], 0),
    proc(41600, 1, ["-bash"], 0), proc(41611, 41600, ["python3", "/root/hgabot/bot.py"], 0),
    proc(41700, 1, ["-bash"], 0), proc(41711, 41700, ["claude"], 0), proc(41712, 41700, ["claude", "--resume", CLAUDE_ID], 0),
    proc(41900, 1, ["-bash"], 0),
    proc(41950, 1, ["-bash"], 0), proc(41960, 41950, ["codex", "--yolo", "resume", CODEX_2], 0),
]


def example_reader():
    """El host del ejemplo de contracts/agent-tree-v1/sonda-salida.json (el lector falso con el que se generó)."""
    return FakeReader(
        EXAMPLE_PANES, EXAMPLE_PROCESSES,
        {41251: {"pid": 41251, "sessionId": CLAUDE_ID, "cwd": "/root/xunis", "status": "busy", "version": "2.1.280",
                 "procStart": "Thu Sep 24 14:02:11 2026"}},
        opened={41410: ["/dev/pts/1", "/root/.codex/log/codex-tui.log", ROLLOUT]},
        cwds={41522: "/root/ufabetbot", 41960: "/root/api", 41402: "/root", 41410: "/root"},
        lines={ROLLOUT: json.dumps({"timestamp": "2026-09-24T10:12:40.512Z", "type": "session_meta",
                                    "payload": {"id": CODEX_ID, "cwd": "/root/scrapper", "originator": "codex_cli_rs"}})})


class SharedOutputContractTests(unittest.TestCase):
    """probe()/main() dan exactamente sonda-salida.json y las salidas de sonda-lectura.json."""

    NOW = 1790260204  # 2026-09-24T14:30:04Z

    def test_probe_matches_the_shared_output_example(self):
        expected = json.loads(contract("agent-tree-v1", "sonda-salida.json").read_text(encoding="utf-8"))
        self.assertEqual(agent_probe.probe("default", reader=example_reader(), now=self.NOW), expected)
        out = io.StringIO()
        self.assertEqual(agent_probe.main(["--socket", "default"], reader=example_reader(), stdout=out, now=self.NOW), 0)
        line = out.getvalue()
        self.assertTrue(line.endswith("\n") and line.count("\n") == 1)
        self.assertEqual(json.loads(line), expected)
        self.assertLessEqual(len(line.encode()), agent_probe.MAX_OUTPUT + 1)

    def test_error_and_limit_outputs_and_what_can_be_deduced(self):
        data = json.loads(contract("agent-tree-v1", "sonda-lectura.json").read_text(encoding="utf-8"))
        hgabot = pane("hgabot", "$3", 0, "%3", 41230, False, "/root/hgabot", "bash")

        class Broken(FakeReader):
            def panes(self, socket_name):
                raise KeyError("fixture")

        readers = {
            "sin_tmux_instalado": lambda: FakeReader([], [], error="tmux_no_disponible"),
            "tmux_respondio_con_error": lambda: FakeReader([], [], error="tmux_fallo"),
            "sin_servidor_en_ese_socket": lambda: FakeReader([], []),
            "la_sonda_fallo": lambda: Broken([], []),
            "sesion_pedida_que_no_existe": lambda: FakeReader([hgabot], [proc(41230, 1, ["-bash"], 0)]),
            "salida_recortada": lambda: FakeReader([hgabot], [proc(41230, 1, ["-bash"], 0)], truncated=True),
        }
        self.assertEqual({item["nombre"] for item in data["salidas"]}, set(readers))
        for item in data["salidas"]:
            with self.subTest(salida=item["nombre"]):
                out = io.StringIO()
                self.assertEqual(agent_probe.main(item["argumentos"], reader=readers[item["nombre"]](), stdout=out,
                                                  now=self.NOW), 0)
                result = json.loads(out.getvalue())
                self.assertEqual(result, item["salida"])
                code = result["error"].split(":", 1)[0] if result["error"] else None
                self.assertEqual({"error": code, "ausente_es_desaparecida": code is None and not result["truncated"]},
                                 item["espera"])


class CommandLineTests(unittest.TestCase):
    def pane(self, session, pane_id, pid, path="/root"):
        return pane(session, "$" + pane_id[1:], 0, pane_id, pid, False, path, "bash")

    def test_cli_with_injected_tables_prints_json_v1(self):
        reader = FakeReader([self.pane("claudebets", "%0", 100, "/root/xunis"), self.pane("hgabot", "%3", 300)],
                            [proc(100, 1, ["-bash"], 0), proc(200, 100, ["claude"], 0), proc(300, 1, ["-bash"], 0)],
                            {200: {"pid": 200, "sessionId": CLAUDE_ID, "cwd": "/root/xunis", "status": "busy"}})
        out = io.StringIO()
        self.assertEqual(agent_probe.main(["--socket", "default"], reader=reader, stdout=out, now=1790260205), 0)
        data = json.loads(out.getvalue())
        self.assertEqual((data["version"], data["socket"], data["error"], data["checked_at"]),
                         (1, "default", None, "2026-09-24T14:30:05Z"))
        sessions = {item["name"]: item for item in data["sessions"]}
        self.assertEqual((sessions["claudebets"]["session_id"], sessions["claudebets"]["pane_id"]), ("$0", "%0"))
        agent = sessions["claudebets"]["agent"]
        self.assertEqual((agent["provider"], agent["session_id"], agent["as_root"], agent["source"], agent["cwd"]),
                         ("claude", CLAUDE_ID, True, "ficha", "/root/xunis"))
        self.assertEqual((sessions["hgabot"]["reason"], sessions["hgabot"]["agent"]), ("sin_ia", None))
        out = io.StringIO()
        agent_probe.main(["--socket", "uniconnect-local", "--session", "hgabot"], reader=reader, stdout=out)
        self.assertEqual([item["name"] for item in json.loads(out.getvalue())["sessions"]], ["hgabot"])
        self.assertEqual(reader.calls[-1], ("panes", "uniconnect-local"))

    def test_bad_usage_exits_2_and_failures_travel_in_json(self):
        self.assertEqual(agent_probe.main(["--socket"], stdout=io.StringIO()), 2)
        self.assertEqual(agent_probe.main(["--socket", "bad name"], stdout=io.StringIO()), 2)
        self.assertEqual(agent_probe.main(["extra"], stdout=io.StringIO()), 2)

        class Broken(FakeReader):
            def panes(self, socket_name):
                raise RuntimeError("fixture")
        out = io.StringIO()
        self.assertEqual(agent_probe.main([], reader=Broken([], []), stdout=out), 0)
        data = json.loads(out.getvalue())
        self.assertTrue(data["error"].startswith("sonda_fallo"))
        self.assertEqual(data["sessions"], [])

    def test_output_is_bounded(self):
        output = {"version": 1, "sessions": [{"name": "s%d" % i, "panes": [{"current_path": "x" * 400}] * 4,
                                              "agent": None} for i in range(400)]}
        encoded = agent_probe.encode(output)
        self.assertLessEqual(len(encoded.encode()), agent_probe.MAX_OUTPUT)
        self.assertTrue(json.loads(encoded)["truncated"])

    def test_base64_bootstrap_reads_arguments_like_stdin(self):
        # Mismo arranque que usan Transport.run_python y el Mac: sys.argv[1:] son los argumentos de la CLI.
        import base64
        source = Path(agent_probe.__file__).read_bytes()
        boot = "import base64,sys;s=sys.argv.pop(1);exec(base64.b64decode(s))"
        for argv, stdin in (([sys.executable, "-c", boot, base64.b64encode(source).decode(), "--socket"], None),
                            ([sys.executable, "-", "--socket"], source)):
            process = subprocess.run(argv, input=stdin, capture_output=True, timeout=20)
            self.assertEqual(process.returncode, 2, process.stderr)
            self.assertIn(b"uso:", process.stderr)


if __name__ == "__main__":
    unittest.main()
