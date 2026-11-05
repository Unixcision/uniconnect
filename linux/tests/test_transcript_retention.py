"""transcript-retention-v1 en Linux: el plan del contrato, comprimir sin perder nada y no tocar lo que está en uso.

Todo corre sobre carpetas temporales con raíces, estado y fichas inyectados: ninguna
prueba mira el `~/.claude` ni el `~/.codex` de quien las ejecuta.
"""

import fcntl
import gzip
import itertools
import json
import os
import shutil
import stat
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

from contracts_dir import contract
from uniconnect.transcript_retention import (Entry, Policy, RetentionSchedule, Summary, plan, protected_ids, run,
                                             scan)

DAY = 86400.0
A = "a9391254-c89b-4a93-84bd-4ee48ff6ee1f"
B = "0e01c373-911f-4dd6-8c19-3dd633122c01"
C = "c70ac04e-7d18-437e-b012-95dada22adb0"
D = "01a07d57-041b-7840-8b77-02e9789002a7"
E = "77777777-7777-4777-8777-777777777777"
F = "11111111-1111-4111-8111-111111111111"


def transcript(lines=4000, tag="línea"):
    """Un `.jsonl` creíble: líneas JSON distintas, con texto no ASCII."""
    return b"".join(json.dumps({"n": index, "texto": "%s %d" % (tag, index)}, ensure_ascii=False).encode() + b"\n"
                    for index in range(lines))


class ContractCases(unittest.TestCase):
    def test_every_case_of_the_shared_contract(self):
        document = json.loads(contract("transcript-retention-v1", "cases.json").read_text(encoding="utf-8"))
        self.assertEqual(document["version"], 1)
        policy = Policy(**document["policy"])
        # La app usa la política por omisión: tiene que ser la del contrato.
        self.assertEqual(Policy(), policy)
        self.assertTrue(document["cases"])
        for case in document["cases"]:
            with self.subTest(case["name"]):
                entries = [Entry(item["path"], item["age_days"]) for item in case["files"]]
                result = plan(entries, case["protected"], policy)
                self.assertEqual(sorted(result.compress), sorted(case["compress"]))
                self.assertEqual(sorted(result.delete), sorted(case["delete"]))


class RetentionOnDisk(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="uniconnect-retencion-")
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name)
        home = self.base / "home"
        self.claude = home / ".claude" / "projects"
        self.codex = home / ".codex" / "sessions"
        self.sessions = home / ".claude" / "sessions"
        for folder in (self.claude, self.codex, self.sessions):
            folder.mkdir(parents=True)
        self.state = self.base / "estado" / "state.json"
        self.state.parent.mkdir()
        self.now = time.time()
        self.logged = []

    def age(self, path, days):
        moment = self.now - days * DAY
        os.utime(path, (moment, moment))

    def write(self, root, relative, content, days):
        path = root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(content)
        self.age(path, days)
        return path

    def retention(self, **overrides):
        options = dict(roots={"claude": self.claude, "codex": self.codex}, state_paths=(self.state,),
                       sessions_dir=self.sessions, clock=lambda: self.now, alive=lambda pid: False,
                       log=self.logged.append)
        options.update(overrides)
        return run(**options)

    @staticmethod
    def packed(path):
        return path.with_name(path.name + ".gz")

    @staticmethod
    def temporary_of(path):
        return path.with_name(path.name + ".gz.tmp")

    def snapshot(self, path):
        info = path.stat()
        return path.read_bytes(), info.st_mtime_ns


class Compression(RetentionOnDisk):
    def test_round_trips_byte_for_byte_and_keeps_the_date(self):
        content = transcript()
        source = self.write(self.claude, "-Users-dani/%s.jsonl" % A, content, 40)
        young = self.write(self.claude, "-Users-dani/%s.jsonl" % B, b'{"hoy": 1}\n', 2)
        mtime, mode = source.stat().st_mtime_ns, stat.S_IMODE(source.stat().st_mode)
        before_young = self.snapshot(young)

        summary = self.retention()

        packed = self.packed(source)
        self.assertFalse(source.exists())
        self.assertFalse(self.temporary_of(source).exists())
        self.assertEqual(gzip.decompress(packed.read_bytes()), content)
        if shutil.which("gzip"):
            self.assertEqual(subprocess.run(["gzip", "-dc", str(packed)], stdout=subprocess.PIPE, check=True).stdout,
                             content)
        self.assertEqual(packed.stat().st_mtime_ns, mtime)
        self.assertEqual(stat.S_IMODE(packed.stat().st_mode), mode)
        self.assertEqual(self.snapshot(young), before_young)
        self.assertEqual((summary.compressed, summary.deleted, summary.deferred, summary.failures), (1, 0, 0, 0))
        self.assertEqual(summary.freed_bytes, len(content) - packed.stat().st_size)
        self.assertEqual(len(self.logged), 1)

    def test_appending_to_an_existing_gz_gives_old_then_new(self):
        old, new = transcript(300, "vieja"), transcript(200, "nueva")
        previous = gzip.compress(old, mtime=0)
        packed = self.write(self.claude, "-Users-dani/%s.jsonl.gz" % E, previous, 120)
        source = self.write(self.claude, "-Users-dani/%s.jsonl" % E, new, 40)
        mtime = source.stat().st_mtime_ns

        summary = self.retention()

        self.assertFalse(source.exists())
        data = packed.read_bytes()
        self.assertEqual(data[:len(previous)], previous)  # Lo viejo, intacto byte a byte.
        self.assertEqual(gzip.decompress(data), old + new)
        self.assertEqual(packed.stat().st_mtime_ns, mtime)
        self.assertEqual((summary.compressed, summary.failures), (1, 0))

    def test_an_expired_gz_goes_before_its_resumed_jsonl_is_compressed(self):
        packed = self.write(self.claude, "-Users-dani/%s.jsonl.gz" % E, gzip.compress("de hace dos años\n".encode()), 400)
        new = transcript(100, "retomada")
        source = self.write(self.claude, "-Users-dani/%s.jsonl" % E, new, 40)

        summary = self.retention()

        self.assertFalse(source.exists())
        self.assertEqual(gzip.decompress(packed.read_bytes()), new)
        self.assertEqual((summary.deleted, summary.compressed, summary.failures), (1, 1, 0))

    def test_a_file_that_changes_while_compressing_is_left_for_the_next_hour(self):
        content, extra = transcript(), b'{"otra": "l\xc3\xadnea"}\n'
        source = self.write(self.claude, "-Users-dani/%s.jsonl" % A, content, 40)

        def failpoint(stage, path):
            if stage == "comprimido":
                with open(source, "ab") as handle:
                    handle.write(extra)

        summary = self.retention(failpoint=failpoint)

        self.assertEqual(source.read_bytes(), content + extra)
        self.assertFalse(self.packed(source).exists())
        self.assertFalse(self.temporary_of(source).exists())
        self.assertEqual((summary.compressed, summary.deferred, summary.failures), (0, 1, 0))

    def test_a_write_in_the_last_instant_undoes_a_new_gz(self):
        content, extra = transcript(), b'{"justo": "ahora"}\n'
        source = self.write(self.claude, "-Users-dani/%s.jsonl" % A, content, 40)

        def failpoint(stage, path):
            if stage == "renombrado":
                with open(source, "ab") as handle:
                    handle.write(extra)

        summary = self.retention(failpoint=failpoint)

        self.assertEqual(source.read_bytes(), content + extra)
        self.assertFalse(self.packed(source).exists())
        self.assertEqual((summary.compressed, summary.deferred, summary.failures), (0, 1, 0))

    def test_a_write_in_the_last_instant_restores_the_previous_gz(self):
        previous = gzip.compress(transcript(50, "archivada"), mtime=0)
        packed = self.write(self.claude, "-Users-dani/%s.jsonl.gz" % E, previous, 120)
        before = self.snapshot(packed)
        content, extra = transcript(80, "retomada"), b'{"justo": "ahora"}\n'
        source = self.write(self.claude, "-Users-dani/%s.jsonl" % E, content, 40)

        def failpoint(stage, path):
            if stage == "renombrado":
                with open(source, "ab") as handle:
                    handle.write(extra)

        summary = self.retention(failpoint=failpoint)

        self.assertEqual(self.snapshot(packed), before)
        self.assertEqual(source.read_bytes(), content + extra)
        self.assertEqual((summary.compressed, summary.deferred, summary.failures), (0, 1, 0))

    def test_a_cut_between_rename_and_removal_is_finished_without_duplicating(self):
        content = transcript()
        source = self.write(self.claude, "-Users-dani/%s.jsonl" % A, content, 40)

        def cut(stage, path):
            if stage == "renombrado":
                raise RuntimeError("corte simulado")

        first = self.retention(failpoint=cut)
        self.assertEqual(first.failures, 1)
        self.assertTrue(source.exists())
        self.assertTrue(self.packed(source).exists())

        second = self.retention()

        self.assertFalse(source.exists())
        self.assertEqual(gzip.decompress(self.packed(source).read_bytes()), content)  # Una sola vez.
        self.assertEqual((second.compressed, second.failures, second.freed_bytes), (1, 0, len(content)))

    def test_a_leftover_temporary_from_a_crash_is_replaced(self):
        content = transcript(100)
        source = self.write(self.claude, "-Users-dani/%s.jsonl" % A, content, 40)
        self.temporary_of(source).write_bytes(b"medio gzip de una pasada que se cort\xc3\xb3")

        summary = self.retention()

        self.assertEqual(gzip.decompress(self.packed(source).read_bytes()), content)
        self.assertFalse(self.temporary_of(source).exists())
        self.assertEqual((summary.compressed, summary.failures), (1, 0))

    def test_one_broken_file_does_not_stop_the_rest(self):
        broken = self.write(self.claude, "-Users-dani/%s.jsonl" % A, transcript(10, "rota"), 40)
        fine = self.write(self.claude, "-Users-dani/%s.jsonl" % B, transcript(10, "sana"), 40)
        before = self.snapshot(broken)

        def failpoint(stage, path):
            if stage == "comprimido" and A in path:
                raise OSError("disco lleno simulado")

        summary = self.retention(failpoint=failpoint)

        self.assertEqual(self.snapshot(broken), before)
        self.assertFalse(self.temporary_of(broken).exists())
        self.assertFalse(self.packed(broken).exists())
        self.assertFalse(fine.exists())
        self.assertTrue(self.packed(fine).exists())
        self.assertEqual((summary.compressed, summary.failures), (1, 1))
        self.assertIn("fallos 1", self.logged[-1])


class Deletion(RetentionOnDisk):
    def test_more_than_a_year_goes_compressed_or_not(self):
        plain = self.write(self.claude, "-Users-dani/%s.jsonl" % A, transcript(20), 400)
        packed = self.write(self.claude, "-Users-dani/%s.jsonl.gz" % B, gzip.compress(transcript(20)), 366)
        kept = self.write(self.claude, "-Users-dani/%s.jsonl.gz" % C, gzip.compress(transcript(20)), 200)
        sizes = plain.stat().st_size + packed.stat().st_size
        before = self.snapshot(kept)

        summary = self.retention()

        self.assertFalse(plain.exists())
        self.assertFalse(packed.exists())
        self.assertEqual(self.snapshot(kept), before)
        self.assertEqual((summary.deleted, summary.compressed, summary.freed_bytes), (2, 0, sizes))

    def test_emptied_folders_go_but_the_roots_stay(self):
        self.write(self.claude, "-Users-dani-viejo/%s.jsonl" % C, b"x\n", 400)
        self.write(self.claude, "-Users-dani-viejo/%s/subagents/agent-a1b2c3.jsonl" % C, b"y\n", 500)
        self.write(self.codex, "2025/01/02/rollout-2025-01-02T10-00-00-%s.jsonl" % D, b"z\n", 400)
        notes = self.write(self.claude, "-Users-dani-mixto/notas.txt", b"no es una conversacion\n", 900)
        self.write(self.claude, "-Users-dani-mixto/%s.jsonl" % E, b"w\n", 400)
        already_empty = self.claude / "-Users-dani-vacio"
        already_empty.mkdir()

        summary = self.retention()

        self.assertEqual(summary.deleted, 4)
        self.assertFalse((self.claude / "-Users-dani-viejo").exists())
        self.assertFalse((self.codex / "2025").exists())
        self.assertTrue(self.claude.is_dir())
        self.assertTrue(self.codex.is_dir())
        self.assertEqual(list(self.codex.iterdir()), [])
        self.assertTrue(notes.exists())  # Ni el fichero ajeno ni su carpeta se tocan.
        self.assertTrue(already_empty.is_dir())  # Solo se quita lo que esta pasada vació.


class WhatIsNotAConversation(RetentionOnDisk):
    def test_symlinks_are_ignored(self):
        outside = self.base / "fuera"
        target = self.write(outside, "%s.jsonl" % A, transcript(30), 400)
        inner = self.write(outside, "carpeta/%s.jsonl" % B, transcript(30), 400)
        (self.claude / "-Users-dani").mkdir()
        link = self.claude / "-Users-dani" / ("%s.jsonl" % C)
        link.symlink_to(target)
        (self.claude / "-Users-dani-enlace").symlink_to(outside / "carpeta", target_is_directory=True)
        before = [self.snapshot(target), self.snapshot(inner)]

        summary = self.retention()
        linked = self.base / "raiz-enlace"
        linked.symlink_to(outside, target_is_directory=True)
        linked_root = self.retention(roots={"claude": linked})

        self.assertTrue(link.is_symlink())
        self.assertTrue((self.claude / "-Users-dani-enlace").is_symlink())
        self.assertEqual([self.snapshot(target), self.snapshot(inner)], before)
        self.assertEqual(summary, Summary())
        self.assertEqual(linked_root, Summary())  # Una raíz que es un enlace tampoco se sigue.

    def test_scan_reports_logical_paths_of_regular_transcripts_only(self):
        self.write(self.claude, "-Users-dani/%s.jsonl" % A, b"a\n", 40)
        self.write(self.claude, "-Users-dani/%s.json" % B, b"{}", 400)
        self.write(self.claude, "-Users-dani/%s.jsonl.gz.tmp" % C, b"", 400)
        self.write(self.codex, "2026/09/03/rollout-2026-09-03T15-40-16-%s.jsonl.gz" % D, b"", 10)

        entries = scan({"claude": self.claude, "codex": self.codex}, self.now)

        self.assertEqual([entry.path for entry in entries],
                         ["claude/-Users-dani/%s.jsonl" % A,
                          "codex/2026/09/03/rollout-2026-09-03T15-40-16-%s.jsonl.gz" % D])
        self.assertAlmostEqual(entries[0].age_days, 40, places=3)


class InUse(RetentionOnDisk):
    def test_conversations_in_use_are_never_touched(self):
        self.state.write_text(json.dumps({"version": 1, "workspaces": [{"id": "caja", "kind": "local", "name": "Mac",
                                          "windows": [{"id": "ventana", "sessionId": A.upper()}]}]}))
        (self.sessions / "4242.json").write_text(json.dumps({"pid": 4242, "sessionId": B}))
        (self.sessions / "777.json").write_text(json.dumps({"pid": 777, "sessionId": C}))
        window = self.write(self.claude, "-Users-dani/%s.jsonl" % A, transcript(20), 90)
        subagent = self.write(self.claude, "-Users-dani/%s/subagents/agent-a1b2c3.jsonl" % A, transcript(5), 500)
        alive = self.write(self.claude, "-Users-dani/%s.jsonl" % B, transcript(20), 400)
        dead = self.write(self.claude, "-Users-dani/%s.jsonl" % C, transcript(20), 400)
        in_memory = self.write(self.codex, "2026/09/07/rollout-2026-09-07T21-27-29-%s.jsonl" % D, transcript(20), 60)
        unrelated = self.write(self.codex, "2026/09/03/rollout-2026-09-03T15-40-16-%s.jsonl" % E, transcript(20), 60)
        protected = [window, subagent, alive, in_memory]
        before = [self.snapshot(path) for path in protected]

        summary = self.retention(alive=lambda pid: pid == 4242,
                                 state_texts=(json.dumps({"ventanaNueva": {"sessionId": D}}),))

        self.assertEqual([self.snapshot(path) for path in protected], before)
        for path in protected:
            self.assertFalse(self.packed(path).exists())
        self.assertFalse(dead.exists())  # Su Claude ya no vive: más de un año, se borra.
        self.assertFalse(unrelated.exists())
        self.assertTrue(self.packed(unrelated).exists())
        self.assertEqual((summary.compressed, summary.deleted, summary.failures), (1, 1, 0))

    def test_protected_set_reads_state_and_live_fichas(self):
        self.state.write_text('{"windows": [{"id": "%s", "resume": "%s"}]}' % (F, A.upper()))
        (self.sessions / "4242.json").write_text('{"pid": 4242, "sessionId": "%s", "cwd": "/' % B)  # A medio escribir.
        (self.sessions / "100.json").write_text(json.dumps({"sessionId": C}))
        (self.sessions / "notas.json").write_text(json.dumps({"sessionId": D}))

        found = protected_ids(state_paths=(self.state,), state_texts=('{"x": "%s"}' % E,),
                              sessions_dir=self.sessions, alive=lambda pid: pid == 4242)

        self.assertEqual(found, {F, A, B, E})

    def test_a_conversation_that_comes_alive_mid_run_is_spared(self):
        first = self.write(self.claude, "-Users-dani/%s.jsonl" % A, transcript(10), 40)
        second = self.write(self.claude, "-Users-dani/%s.jsonl" % C, transcript(10), 40)
        before = self.snapshot(second)
        clock = itertools.count(0, 10)  # Cada consulta, 10 s más tarde: el guardián relee.

        def failpoint(stage, path):
            if stage == "comprimido" and A in path:
                (self.sessions / "4242.json").write_text(json.dumps({"pid": 4242, "sessionId": C}))

        summary = self.retention(failpoint=failpoint, monotonic=lambda: next(clock), alive=lambda pid: pid == 4242)

        self.assertFalse(first.exists())
        self.assertEqual(self.snapshot(second), before)
        self.assertFalse(self.packed(second).exists())
        self.assertFalse(self.temporary_of(second).exists())
        self.assertEqual((summary.compressed, summary.failures), (1, 0))

    def test_an_unreadable_state_touches_nothing(self):
        self.state.mkdir()  # Existe pero no se puede leer como fichero.
        old = self.write(self.claude, "-Users-dani/%s.jsonl" % A, transcript(10), 400)
        before = self.snapshot(old)

        summary = self.retention()

        self.assertEqual(self.snapshot(old), before)
        self.assertEqual((summary.deleted, summary.compressed, summary.failures), (0, 0, 1))
        self.assertIn("no se toca nada", self.logged[-1])

    def test_another_run_holding_the_roots_is_respected(self):
        old = self.write(self.claude, "-Users-dani/%s.jsonl" % A, transcript(10), 400)
        descriptor = os.open(self.claude, os.O_RDONLY | os.O_DIRECTORY)
        self.addCleanup(os.close, descriptor)
        fcntl.flock(descriptor, fcntl.LOCK_EX)

        summary = self.retention()

        self.assertTrue(old.exists())
        self.assertEqual(summary, Summary())


class FakeStore:
    def __init__(self, root):
        self.root = Path(root)
        self.path = self.root / "state.json"
        self.data = {"workspaces": [{"windows": [{"id": "ventana", "sessionId": A}]}]}


class FakeWindow:
    def __init__(self, root):
        self._closed = False
        self.store = FakeStore(root)


class Schedule(unittest.TestCase):
    def setUp(self):
        self.root = Path("/estado/uniconnect")
        self.window = FakeWindow(self.root)
        self.timers, self.cancelled, self.calls, self.logged = [], [], [], []

    def timer(self, seconds, callback):
        self.timers.append((seconds, callback))
        return len(self.timers)

    def runner(self, **options):
        self.calls.append(options)
        return Summary()

    def schedule(self, **overrides):
        options = dict(runner=self.runner, timer=self.timer, cancel=self.cancelled.append, spawn=lambda work: work(),
                       user_state_root=self.root, log=self.logged.append)
        options.update(overrides)
        return RetentionSchedule(self.window, **options)

    def test_once_shortly_after_start_and_then_every_hour(self):
        schedule = self.schedule()
        schedule.start()
        self.assertEqual([seconds for seconds, _ in self.timers], [RetentionSchedule.FIRST_DELAY_SECONDS])
        self.assertLessEqual(RetentionSchedule.FIRST_DELAY_SECONDS, 300)
        self.assertEqual(self.calls, [])

        self.assertFalse(self.timers[0][1]())  # La primera es de un solo disparo.
        self.assertEqual(len(self.calls), 1)
        self.assertEqual(self.calls[0]["state_paths"], (self.window.store.path,))
        self.assertIn(A, self.calls[0]["state_texts"][0])
        self.assertEqual(self.timers[1][0], 3600)

        self.assertTrue(self.timers[1][1]())
        self.assertEqual(len(self.calls), 2)
        self.window._closed = True
        self.assertFalse(self.timers[1][1]())
        self.assertEqual(len(self.calls), 2)

    def test_stop_cancels_the_pending_timer(self):
        schedule = self.schedule()
        schedule.start()
        schedule.stop()
        self.assertEqual(self.cancelled, [1])

    def test_an_isolated_state_dir_never_schedules(self):
        self.schedule(user_state_root=Path("/otro/estado")).start()
        self.assertEqual(self.timers, [])

    def test_a_failing_run_never_escapes_and_does_not_block_the_next(self):
        def broken(**options):
            raise RuntimeError("fallo inesperado")

        schedule = self.schedule(runner=broken)
        self.assertTrue(schedule.launch())
        self.assertFalse(schedule.running)
        self.assertIn("RuntimeError", self.logged[-1])
        self.assertTrue(schedule.launch())

    def test_never_two_runs_at_once(self):
        pending = []
        schedule = self.schedule(spawn=pending.append)
        self.assertTrue(schedule.launch())
        self.assertFalse(schedule.launch())
        self.assertEqual(len(pending), 1)
        pending.pop()()
        self.assertTrue(schedule.launch())


if __name__ == "__main__":
    unittest.main()
