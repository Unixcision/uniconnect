"""Regression coverage for the real recovery-launcher and Codex idle UI."""

import hashlib
import base64
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
import uuid
from unittest.mock import patch

from uniconnect.relaunch_worker import TargetWorker, Unavailable, TmuxOutputEvents


class RecoveryRelaunchTests(unittest.TestCase):
    def worker(self):
        return TargetWorker({"session": "fixture", "socket": "fixture", "provider": "codex"})

    def test_dim_placeholder_at_empty_cursor_is_not_a_draft(self):
        worker = self.worker()
        plain = "› Ask Codex to do anything"
        styled = "\x1b[1m›\x1b[0m \x1b[2mAsk Codex to do anything\x1b[0m"
        def tmux(*args):
            if args[0] == "display-message":
                return "2" if args[-1] == "#{cursor_x}" else "0"
            return styled if "-e" in args else plain
        worker.tmux = tmux
        worker.require_empty_composer({"pane": {"pane": "%1"}})
        for line, cursor in ((plain, 2), (styled, 6), (styled + " extra", 2)):
            with self.subTest(line=line, cursor=cursor):
                worker.tmux = lambda *a: (str(cursor) if a[-1] == "#{cursor_x}" else "0") if a[0] == "display-message" else (line if "-e" in a else plain)
                with self.assertRaises(Unavailable):
                    worker.require_empty_composer({"pane": {"pane": "%1"}})

    def test_resume_settings_supersede_old_turn_configuration_but_not_activity(self):
        process = {"cwd": "/work", "argv": ["codex", "resume", "id", "--yolo", "-m", "current", "-c", 'model_reasoning_effort="max"']}
        context = {"type": "turn_context", "payload": {"turn_id": "turn", "model": "old", "effort": "high", "cwd": "/work",
                   "approval_policy": "on-request", "sandbox_policy": {"type": "workspace-write"}}}
        complete = {"type": "event_msg", "payload": {"type": "task_complete", "turn_id": "turn"}}
        settings = {"type": "event_msg", "payload": {"type": "thread_settings_applied", "thread_settings": {
            "model": "current", "reasoning_effort": "max", "cwd": "/work", "approval_policy": "never",
            "permission_profile": {"type": "disabled"}}}}
        TargetWorker.validate_quiescence([context, complete, settings], process)
        TargetWorker.validate_quiescence([context, complete, settings], {**process, "argv": ["codex", "resume", "id", "--yolo"]})
        for rows in ([context, settings], [context, complete, settings, {"type": "event_msg", "payload": {"type": "task_started", "turn_id": "next"}}]):
            with self.assertRaises(Unavailable):
                TargetWorker.validate_quiescence(rows, process)
        with self.assertRaises(Unavailable):
            TargetWorker.validate_quiescence([context, complete, settings], {**process, "argv": ["codex", "--yolo", "-m", "wrong"]})

    def test_only_pinned_recovery_with_same_conversation_and_arguments_is_admitted(self):
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            script = home / "recovery.py"
            script.write_text("# reviewed recovery fixture\n")
            script.chmod(0o600)
            manifest = home / "manifest.json"
            entry = {"tmux": "fixture", "agent": "codex", "sessionId": "native", "cwd": directory,
                     "model": "m", "reasoningEffort": "max"}
            manifest.write_text(json.dumps({"tmuxSocket": "fixture", "windows": [entry]}))
            worker = self.worker()
            worker.request["recovery_sha256"] = hashlib.sha256(script.read_bytes()).hexdigest()
            root = {"argv": ["/usr/bin/python3", str(script), "--manifest", str(manifest), "launch", "fixture"]}
            process = {"cwd": directory, "argv": ["/bin/codex", "resume", "-C", directory, "-m", "m", "-c", 'model_reasoning_effort="max"',
                       "--dangerously-bypass-approvals-and-sandbox", "native"]}
            proof = worker.recovery_launcher(root, process, "native")
            self.assertEqual(proof["session_id"], "native")
            for mutation in ("id", "script", "arguments"):
                with self.subTest(mutation=mutation):
                    changed = dict(process)
                    if mutation == "id":
                        entry["sessionId"] = "stale"
                        manifest.write_text(json.dumps({"tmuxSocket": "fixture", "windows": [entry]}))
                    elif mutation == "script":
                        script.write_text("# unreviewed supervisor\n")
                    else:
                        changed["argv"] = [*process["argv"], "--search"]
                    with self.assertRaises(Unavailable):
                        worker.recovery_launcher(root, changed, "native")
                    entry["sessionId"] = "native"
                    manifest.write_text(json.dumps({"tmuxSocket": "fixture", "windows": [entry]}))
                    script.write_text("# reviewed recovery fixture\n")


PROVIDER = r'''
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <termios.h>
int main(int argc, char **argv) {
  char path[4096];
  const char *id = argc>2 && argv[2][0]!='-' ? argv[2] : argv[argc-1];
  snprintf(path, sizeof path, "%s/.codex/thread-writer-locks/%s.lock", getenv("UC_FIXTURE_ROOT"), id);
  int fd = open(path, O_CREAT|O_RDWR, 0600);
  struct flock lock = {.l_type=F_WRLCK, .l_whence=SEEK_SET};
  if (fd < 0 || fcntl(fd, F_SETLK, &lock)) return 2;
  struct termios mode; tcgetattr(0, &mode); cfmakeraw(&mode); tcsetattr(0,TCSANOW,&mode);
  printf("\033[2J\033[H\033[1m›\033[0m \033[2mAsk Codex to do anything\033[0m\r\033[2C"); fflush(stdout);
  char text[64]={0}; size_t n=0; char c;
  while (read(0,&c,1)==1) {
    if (c=='\r' || c=='\n') { if (!strcmp(text,"/exit")) break; return 3; }
    if (n+1>=sizeof text) return 4; text[n++]=c;
    printf("\033[2J\033[H› %s",text); fflush(stdout);
  }
  close(fd); return 0; /* Deliberately leave raw mode behind, like the repro. */
}
'''

SUPERVISOR = '''import json,subprocess,sys
from pathlib import Path
data=json.loads(Path(sys.argv[2]).read_text())
e=data['windows'][0]
while True:
 p=subprocess.Popen([e['executable'],'resume','-C',e['cwd'],'-m',e['model'],'-c','model_reasoning_effort="max"','--dangerously-bypass-approvals-and-sandbox',e['sessionId']])
 p.wait()
 print('\\x1b[2J\\x1b[H',end='',flush=True)
 input('Sesión cerrada. Pulsa Intro para recuperar el mismo historial: ')
'''


@unittest.skipUnless(Path('/proc').exists() and shutil.which('tmux') and shutil.which('cc'), 'isolated Linux VM required')
class RecoveryRuntimeTests(unittest.TestCase):
    def test_same_pane_conversation_and_launcher_survive_normal_exit_and_raw_tty(self):
        self.run_relaunch(supervised=True)

    def test_plain_shell_uses_normal_exit_and_reopens_same_conversation(self):
        self.run_relaunch(supervised=False)

    def run_relaunch(self, *, supervised):
        with tempfile.TemporaryDirectory(prefix='uc-recovery-e2e-') as directory:
            root=Path(directory); native=str(uuid.uuid4()); socket='uc-recovery-'+uuid.uuid4().hex[:10]
            locks=root/'.codex/thread-writer-locks';locks.mkdir(parents=True)
            transcripts=root/'.codex/sessions/2026/09/21';transcripts.mkdir(parents=True)
            executable=root/'codex'
            subprocess.run(['cc','-x','c','-','-o',str(executable)],input=PROVIDER,text=True,capture_output=True,check=True,timeout=30)
            rows=[{'type':'session_meta','payload':{'id':native}},
                  {'type':'turn_context','payload':{'turn_id':'t','model':'m','effort':'max','cwd':directory,'approval_policy':'never','sandbox_policy':{'type':'danger-full-access'}}},
                  {'type':'event_msg','payload':{'type':'task_complete','turn_id':'t'}}]
            (transcripts/('rollout-fixture-'+native+'.jsonl')).write_text('\n'.join(map(json.dumps,rows))+'\n')
            script=root/'recovery.py';script.write_text(SUPERVISOR);script.chmod(0o600)
            manifest=root/'manifest.json';manifest.write_text(json.dumps({'tmuxSocket':socket,'windows':[{
                'tmux':'fixture','agent':'codex','sessionId':native,'cwd':directory,'executable':str(executable),'model':'m','reasoningEffort':'max'}]}))
            binary=['tmux','-L',socket]
            # Same argv shape as the deployed recovery supervisor. The fixture
            # source is explicitly pinned in the request, never globally trusted.
            command=shlex.join(['env','UC_FIXTURE_ROOT='+directory,sys.executable,str(script),'--manifest',str(manifest),'launch','fixture']) if supervised else '/bin/bash --noprofile --norc -i'
            subprocess.run(binary+['new-session','-d','-s','fixture','-c',directory,command],check=True,capture_output=True)
            events=TmuxOutputEvents(binary,'fixture')
            try:
                if not supervised:
                    command=shlex.join(['env','UC_FIXTURE_ROOT='+directory,str(executable),'resume',native,'-C',directory,'-m','m','-c','model_reasoning_effort="max"','--dangerously-bypass-approvals-and-sandbox'])
                    subprocess.run(binary+['send-keys','-t','=fixture:','-l',command+'\n'],check=True,capture_output=True)
                request={'session':'fixture','socket':socket,'provider':'codex','window_id':'fixture','recovery_sha256':hashlib.sha256(script.read_bytes()).hexdigest(),
                         'identity_helper':base64.b64encode(b'pass').decode(),
                         'catalog':{'codex':{'resume':['{executable}','resume','{sessionId}','{arguments}']}}}
                worker=TargetWorker(request);deadline=time.monotonic()+10
                while True:
                    try:
                        proof=worker.inspect();worker.require_empty_composer(proof);break
                    except (Unavailable,OSError):events.wait(deadline,time.monotonic)
                worker.request['expected']=proof
                journal=root/'journal.json';worker.write(journal,{'state':'planificado'})
                worker.perform(journal)
                self.assertEqual(worker.read(journal),{'state':'verificado','effective_id':native})
                after=worker.inspect()
                self.assertEqual(after['pane'],proof['pane'])
                self.assertEqual(after.get('launcher'),proof.get('launcher'))
                self.assertEqual(after['effective_id'],native)
                self.assertNotEqual(after['pid'],proof['pid'])
                self.assertFalse(worker.same_process({'pid':proof['pid'],'start':proof['start']}))
            finally:
                events.close()
                subprocess.run(binary+['kill-server'],capture_output=True,timeout=5)


if __name__ == "__main__":
    unittest.main()
