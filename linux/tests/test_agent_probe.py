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

REPO = Path(__file__).resolve().parents[2]
CASES = REPO / "contracts" / "agent-tree-v1" / "deteccion-casos.json"

CLAUDE_ID = "473ed1de-4397-45ef-b00b-6b17fd7382b0"
OLD_ID = "11111111-2222-4333-8444-555555555555"
CODEX_ID = "01a0ac81-57c7-7af3-8ac2-fe8a957c8b17"


def proc(pid, ppid, argv, uid=1000):
    return {"pid": pid, "ppid": ppid, "uid": uid, "argv": argv}


def run(processes, pane_pid=100, fichas=None, opened=None, lines=None, cwds=None, pane_path="/pane"):
    fichas, opened, lines, cwds = fichas or {}, opened or {}, lines or {}, cwds or {}
    return discover(pane_pid, processes, lambda pid, uid: fichas.get(pid), lambda pid: opened.get(pid, []),
                    lambda path: lines.get(path), lambda pid: cwds.get(pid), pane_path=pane_path)


def first(mapping, *names, required=True, case="?"):
    for name in names:
        if name in mapping:
            return mapping[name]
    if required:
        raise AssertionError("contracts/agent-tree-v1/deteccion-casos.json: al caso %r le falta %s" % (case, " o ".join(names)))
    return None


class ContractCaseTests(unittest.TestCase):
    """Todos los casos compartidos; si el fichero falta, el test falla (no se salta)."""

    def test_every_shared_detection_case(self):
        self.assertTrue(CASES.is_file(), "Falta %s (CONTRATO-1): sin él no se puede probar el criterio común." % CASES)
        data = json.loads(CASES.read_text(encoding="utf-8"))
        cases = data if isinstance(data, list) else first(data, "casos", "cases", case="(raíz)")
        self.assertTrue(cases, "deteccion-casos.json no trae ningún caso")
        for index, case in enumerate(cases):
            name = case.get("id") or case.get("nombre") or case.get("name") or str(index)
            with self.subTest(caso=name):
                processes = first(case, "procesos", "processes", case=name)
                table = {}
                for item in processes:
                    argv = item.get("argv")
                    if isinstance(argv, str):
                        argv = argv.split()
                    table[int(item["pid"])] = proc(int(item["pid"]), int(item["ppid"]), argv or [], int(item.get("uid", 1000)))
                fichas = {int(key): value for key, value in (first(case, "fichas", "claude_sessions", required=False, case=name) or {}).items()}
                opened = {int(key): value for key, value in (first(case, "abiertos", "open_files", required=False, case=name) or {}).items()}
                lines = first(case, "primeras_lineas", "first_lines", "primera_linea", required=False, case=name) or {}
                lines = {path: (value if isinstance(value, str) else json.dumps(value)) for path, value in lines.items()}
                cwds = {int(key): value for key, value in (first(case, "cwd_procesos", "process_cwd", required=False, case=name) or {}).items()}
                pane_path = first(case, "pane_current_path", "pane_path", required=False, case=name)
                panes = first(case, "paneles", "panes", required=False, case=name)
                if panes:
                    results = [({"pane_id": pane.get("pane_id", "%" + str(i)), "dead": bool(pane.get("dead") or pane.get("muerto"))},
                                run(table, int(pane["pane_pid"]), fichas, opened, lines, cwds, pane_path)) for i, pane in enumerate(panes)]
                    result = combine(results)[1]
                else:
                    pane_pid = int(first(case, "pane_pid", "panel_pid", case=name))
                    result = run(table, pane_pid, fichas, opened, lines, cwds, pane_path)
                expected = first(case, "esperado", "expected", case=name)
                reason = first(expected, "reason", "razon", "motivo", required=False, case=name)
                self.assertEqual(result["reason"], reason)
                agent = result["agent"] or {}
                for keys, actual in ((("provider", "proveedor"), agent.get("provider")),
                                     (("session_id", "id"), agent.get("session_id")),
                                     (("source", "fuente"), agent.get("source")),
                                     (("as_root", "como_root"), agent.get("as_root")),
                                     (("cwd",), agent.get("cwd"))):
                    if any(key in expected for key in keys):
                        self.assertEqual(actual, first(expected, *keys, case=name), keys[0])


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
        for argv in (["node", "server.js"], ["sudo", "claude"], ["python3", "codex.py"], ["-zsh"], []):
            self.assertIsNone(provider_of(argv), argv)


class FakeReader:
    truncated = False

    def __init__(self, panes, processes, fichas=None):
        self._panes, self._processes, self._fichas = panes, processes, fichas or {}
        self.calls = []

    def panes(self, socket_name):
        self.calls.append(("panes", socket_name))
        return self._panes, None

    def processes(self):
        return {item["pid"]: item for item in self._processes}

    def ficha(self, pid, uid):
        return self._fichas.get(pid)

    def open_files(self, pid):
        return []

    def cwd(self, pid):
        return None

    @staticmethod
    def first_line(path):
        return None

    @staticmethod
    def realpath(path):
        return path


class CommandLineTests(unittest.TestCase):
    def pane(self, session, pane_id, pid, path="/root"):
        return {"session": session, "session_id": "$" + pane_id[1:], "window_index": 0, "pane_id": pane_id,
                "pane_pid": pid, "dead": False, "current_path": path, "current_command": "bash"}

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
