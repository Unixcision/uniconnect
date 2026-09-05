"""Private bare-Git fixtures; no network or real conversation notifier."""

import copy
import fcntl
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts"))
from uniconnect_branch_monitor import BranchMonitor, MonitorError, REPOSITORY, atomic_json, encoded, fingerprint


class BranchMonitorTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="uniconnect-monitor-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.repo = self.root / "remote.git"
        subprocess.run(["git", "init", "--bare", str(self.repo)], check=True, capture_output=True)
        self.git("remote", "add", "origin", "https://github.com/Unixcision/uniconnect.git")
        tree = self.git("mktree", input="").strip()
        self.first = self.git("commit-tree", tree, "-m", "first fixture").strip()
        self.second = self.git("commit-tree", tree, "-m", "second fixture").strip()
        self.third = self.git("commit-tree", tree, "-m", "third fixture").strip()
        self.git("update-ref", "refs/heads/uniconnect", self.first)
        self.config = {"repo_path": str(self.repo), "repository": REPOSITORY,
                       "state_dir": str(self.root / "state"), "notify_argv": ["/fixture/notifier", "literal ; argument"]}
        self.runs, self.calls, self.notifications = [], [], []
        self.notification_status = 0
        self.monitor = BranchMonitor(self.config, runner=self.runner, notifier=self.notify)

    def git(self, *argv, input=None):
        environment = dict(os.environ, GIT_AUTHOR_NAME="Fixture", GIT_AUTHOR_EMAIL="fixture@example.test",
                           GIT_COMMITTER_NAME="Fixture", GIT_COMMITTER_EMAIL="fixture@example.test")
        return subprocess.check_output(["git", "-C", str(self.repo), *argv], input=input, text=True,
                                       stderr=subprocess.DEVNULL, env=environment)

    def runner(self, argv, *, cwd):
        self.calls.append(argv)
        self.assertEqual(cwd, self.repo)
        if argv == ["git", "remote", "get-url", "origin"]:
            return self.git("remote", "get-url", "origin")
        if argv == ["git", "ls-remote", "--heads", "origin"]:
            return self.git("ls-remote", "--heads", str(self.repo))
        self.assertEqual(argv, ["gh", "run", "list", "--repo", REPOSITORY, "--limit", "30", "--json",
                               "databaseId,headBranch,headSha,name,status,conclusion,url"])
        return json.dumps(self.runs)

    def notify(self, argv):
        self.assertEqual(argv[:-1], self.config["notify_argv"])
        self.assertEqual(Path(argv[-1]), self.monitor.pending)
        self.notifications.append(json.loads(Path(argv[-1]).read_bytes()))
        return self.notification_status

    def run_record(self, identifier=1, status="completed", conclusion="success"):
        return {"databaseId": identifier, "headBranch": "uniconnect", "headSha": self.first,
                "name": "Fixture CI", "status": status, "conclusion": conclusion,
                "url": f"https://github.com/{REPOSITORY}/actions/runs/{identifier}"}

    def test_initial_baseline_is_silent_and_unchanged_polls_never_rewrite_it(self):
        self.runs = [self.run_record()]
        self.assertEqual(self.monitor.once(), "baseline")
        snapshot = self.monitor.snapshot.read_bytes()
        timestamp = self.monitor.snapshot.stat().st_mtime_ns
        self.assertEqual(self.monitor.once(), "unchanged")
        self.assertEqual(self.notifications, [])
        self.assertEqual(self.monitor.snapshot.read_bytes(), snapshot)
        self.assertEqual(self.monitor.snapshot.stat().st_mtime_ns, timestamp)
        self.assertEqual(stat.S_IMODE(self.monitor.root.stat().st_mode), 0o700)
        for name in ("snapshot.json", "monitor.lock"):
            self.assertEqual(stat.S_IMODE((self.monitor.root / name).stat().st_mode), 0o600)

    def test_real_bare_git_create_update_delete_are_sorted_and_exact(self):
        self.git("update-ref", "refs/heads/deleted", self.first)
        self.monitor.once()
        self.git("update-ref", "refs/heads/uniconnect", self.second)
        self.git("update-ref", "refs/heads/created", self.first)
        self.git("update-ref", "-d", "refs/heads/deleted")
        self.assertEqual(self.monitor.once(), "delivered")
        event = self.notifications[0]
        self.assertEqual(event["branches"], [
            {"branch": "created", "kind": "created", "oldSha": None, "newSha": self.first},
            {"branch": "deleted", "kind": "deleted", "oldSha": self.first, "newSha": None},
            {"branch": "uniconnect", "kind": "updated", "oldSha": self.first, "newSha": self.second}])
        self.assertNotIn("progress", encoded(event).decode())
        self.assertFalse(self.monitor.pending.exists())
        self.assertEqual(self.monitor.once(), "unchanged")

    def test_only_new_completed_ci_conclusions_notify(self):
        self.runs = [self.run_record(status="queued", conclusion=None)]
        self.monitor.once()
        self.runs[0]["status"] = "in_progress"
        self.assertEqual(self.monitor.once(), "unchanged")
        self.runs[0].update(status="completed", conclusion="success")
        self.assertEqual(self.monitor.once(), "delivered")
        self.assertEqual(self.notifications[0]["ci"], self.runs)
        self.assertEqual(self.monitor.once(), "unchanged")
        self.runs[0]["conclusion"] = "failure"
        self.assertEqual(self.monitor.once(), "delivered")
        self.assertEqual(len(self.notifications), 2)

    def test_failed_delivery_retries_same_event_before_observing_more_changes(self):
        self.monitor.once()
        before = self.monitor.snapshot.read_bytes()
        self.git("update-ref", "refs/heads/uniconnect", self.second)
        self.notification_status = 9
        with self.assertRaisesRegex(MonitorError, "notification-failed"):
            self.monitor.once()
        pending = self.monitor.pending.read_bytes()
        self.assertEqual(self.monitor.snapshot.read_bytes(), before)
        for path in (self.monitor.pending, self.monitor.candidate):
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
        self.git("update-ref", "refs/heads/uniconnect", self.third)
        self.notification_status = 0
        self.calls.clear()
        self.assertEqual(self.monitor.once(), "delivered")
        self.assertEqual(self.notifications[-1], json.loads(pending))
        self.assertEqual(self.calls, [["git", "remote", "get-url", "origin"]])
        self.assertEqual(self.monitor.once(), "delivered")
        self.assertEqual(self.notifications[-1]["branches"][0]["oldSha"], self.second)
        self.assertEqual(self.notifications[-1]["branches"][0]["newSha"], self.third)

    def test_crash_after_baseline_write_cleans_pending_without_redelivery(self):
        self.monitor.once()
        self.git("update-ref", "refs/heads/uniconnect", self.second)

        def interrupted_write(path, value):
            atomic_json(path, value)
            if path == self.monitor.snapshot:
                raise OSError("fixture interruption after durable baseline")

        with patch("uniconnect_branch_monitor.atomic_json", interrupted_write):
            with self.assertRaises(OSError):
                self.monitor.once()
        self.assertTrue(self.monitor.pending.exists())
        self.assertEqual(self.monitor.once(), "delivered")
        self.assertEqual(len(self.notifications), 1)
        self.assertFalse(self.monitor.pending.exists())

    def test_orphan_observed_snapshot_recovers_before_a_new_remote_poll(self):
        self.monitor.once()
        before = self.monitor.snapshot.read_bytes()
        self.git("update-ref", "refs/heads/uniconnect", self.second)

        def interrupt_after_candidate(path, value):
            atomic_json(path, value)
            if path == self.monitor.candidate:
                raise OSError("fixture crash before event creation")

        with patch("uniconnect_branch_monitor.atomic_json", interrupt_after_candidate):
            with self.assertRaises(OSError):
                self.monitor.once()
        self.assertFalse(self.monitor.pending.exists())
        self.assertTrue(self.monitor.candidate.exists())
        self.assertEqual(self.monitor.snapshot.read_bytes(), before)
        with self.assertRaisesRegex(MonitorError, "pending-delivery-required"):
            self.monitor.once(baseline=True)
        self.git("update-ref", "refs/heads/uniconnect", self.third)
        self.calls.clear()
        self.assertEqual(self.monitor.once(), "delivered")
        self.assertEqual(self.calls, [["git", "remote", "get-url", "origin"]])
        self.assertEqual(self.notifications[0]["branches"][0]["newSha"], self.second)
        self.assertEqual(self.monitor.once(), "delivered")
        self.assertEqual(self.notifications[1]["branches"][0]["oldSha"], self.second)
        self.assertEqual(self.notifications[1]["branches"][0]["newSha"], self.third)

    def test_invalid_orphan_snapshot_fails_closed_without_notification(self):
        self.monitor.once()
        before = self.monitor.snapshot.read_bytes()
        candidate = json.loads(before)
        candidate["ci"] = {"1": {"databaseId": 1}}
        atomic_json(self.monitor.candidate, candidate)
        self.calls.clear()
        with self.assertRaisesRegex(MonitorError, "invalid-snapshot"):
            self.monitor.once()
        self.assertEqual(self.calls, [["git", "remote", "get-url", "origin"]])
        self.assertEqual(self.monitor.snapshot.read_bytes(), before)
        self.assertEqual(self.notifications, [])

    def test_forbidden_state_paths_are_rejected_before_any_filesystem_write(self):
        alias = self.root / "home-alias"
        alias.symlink_to(Path.home(), target_is_directory=True)
        for path in ("/tmp/..", str(Path.home()), str(alias), str(self.repo), str(self.repo / "state"),
                     str(self.repo / "nested/../state"), str(self.repo.parent)):
            with self.subTest(path=path):
                with self.assertRaisesRegex(MonitorError, "invalid-config"):
                    BranchMonitor({**self.config, "state_dir": path})
        self.assertFalse((self.repo / "state").exists())

    def test_existing_nonprivate_directory_is_not_chmodded(self):
        foreign = self.root / "not-a-monitor-directory"
        foreign.mkdir(mode=0o755)
        monitor = BranchMonitor({**self.config, "state_dir": str(foreign)}, runner=self.runner, notifier=self.notify)
        with self.assertRaisesRegex(MonitorError, "unsafe-state-directory"):
            monitor.once()
        self.assertEqual(stat.S_IMODE(foreign.stat().st_mode), 0o755)
        self.assertEqual(list(foreign.iterdir()), [])

    def test_pending_event_cannot_be_discarded_by_baseline_or_tampering(self):
        self.monitor.once()
        before = self.monitor.snapshot.read_bytes()
        self.git("update-ref", "refs/heads/uniconnect", self.second)
        self.notification_status = 1
        with self.assertRaises(MonitorError):
            self.monitor.once()
        with self.assertRaisesRegex(MonitorError, "pending-delivery-required"):
            self.monitor.once(baseline=True)
        candidate = json.loads(self.monitor.candidate.read_bytes())
        candidate["branches"]["uniconnect"] = self.third
        atomic_json(self.monitor.candidate, candidate)
        with self.assertRaisesRegex(MonitorError, "invalid-pending-event"):
            self.monitor.once()
        self.assertEqual(self.monitor.snapshot.read_bytes(), before)
        self.assertEqual(len(self.notifications), 1)

    def test_saved_baseline_recovers_even_if_candidate_cleanup_already_happened(self):
        self.monitor.once()
        self.git("update-ref", "refs/heads/uniconnect", self.second)
        self.notification_status = 1
        with self.assertRaises(MonitorError):
            self.monitor.once()
        atomic_json(self.monitor.snapshot, json.loads(self.monitor.candidate.read_bytes()))
        self.monitor.candidate.unlink()
        self.assertEqual(self.monitor.once(), "delivered")
        self.assertEqual(len(self.notifications), 1)
        self.assertFalse(self.monitor.pending.exists())

    def test_initial_notify_on_empty_repository_still_creates_a_baseline(self):
        self.git("update-ref", "-d", "refs/heads/uniconnect")
        self.assertEqual(self.monitor.once(notify_initial=True), "baseline")
        self.assertTrue(self.monitor.snapshot.exists())
        self.assertEqual(self.notifications, [])

    def test_overlap_returns_busy_without_source_or_notifier_calls(self):
        self.monitor.once()
        self.calls.clear()
        with open(self.monitor.root / "monitor.lock", "rb") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.assertEqual(self.monitor.once(), "busy")
        self.assertEqual(self.calls, [])
        self.assertEqual(self.notifications, [])

    def test_wrong_origin_fails_closed_without_exposing_its_credentials(self):
        for remote in ("https://github.com/another/repo.git", "https://github.com.evil.test/Unixcision/uniconnect",
                       "https://fixture-secret@github.com/Unixcision/uniconnect.git", "file:///tmp/another.git"):
            with self.subTest(remote=remote):
                self.git("remote", "set-url", "origin", remote)
                self.calls.clear()
                with self.assertRaisesRegex(MonitorError, "^unexpected-origin$"):
                    self.monitor.once()
                self.assertEqual(len(self.calls), 1)
                self.assertFalse(self.monitor.snapshot.exists())

    def test_expected_https_and_ssh_origin_forms_are_accepted(self):
        for remote in ("https://github.com/Unixcision/uniconnect", "git@github.com:Unixcision/uniconnect.git",
                       "ssh://git@github.com/Unixcision/uniconnect.git"):
            self.git("remote", "set-url", "origin", remote)
            self.monitor.validate_remote()

    def test_invalid_config_and_ci_fail_before_notification(self):
        invalid = {**self.config, "repository": "another/repo"}
        with self.assertRaisesRegex(MonitorError, "invalid-config"):
            BranchMonitor(invalid)
        self.monitor.once()
        before = self.monitor.snapshot.read_bytes()
        self.git("update-ref", "refs/heads/uniconnect", self.second)
        self.runs = [{**self.run_record(), "url": "https://evil.example.test/secret"}]
        with self.assertRaisesRegex(MonitorError, "invalid-ci-response"):
            self.monitor.once()
        self.assertEqual(self.monitor.snapshot.read_bytes(), before)
        self.assertEqual(self.notifications, [])

    def test_explicit_initial_notification_has_deterministic_identity(self):
        self.runs = [self.run_record()]
        self.assertEqual(self.monitor.once(notify_initial=True), "delivered")
        event = self.notifications[0]
        unsigned = {key: value for key, value in event.items() if key != "eventId"}
        self.assertEqual(event["eventId"], fingerprint(unsigned))
        snapshot = json.loads(self.monitor.snapshot.read_bytes())
        self.assertEqual(event, BranchMonitor.event(None, copy.deepcopy(snapshot)))


if __name__ == "__main__":
    unittest.main()
