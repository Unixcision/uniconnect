# <proveedor> <id> -> 0 libre, 1 abierta, 2 no comprobable
import glob,json,os,re,subprocess as S,sys
B=os.path.basename;D=os.path.isdir
def g(p,i):
 H=os.path.expanduser('~')
 if not re.fullmatch('[A-Za-z0-9_-]{1,160}',i):return 2
 if p=='claude':
  d=os.path.join(os.environ.get('CLAUDE_CONFIG_DIR')or H+'/.claude','sessions')
  if not D(d):return 0
  if not os.access(d,5):return 2
  for f in glob.glob(d+'/*.json'):
   try:j=json.load(open(f))
   except Exception:continue
   if str(j.get('sessionId')).lower()!=i.lower():continue
   q=str(j.get('pid')or B(f)[:-5])
   try:c=open('/proc/'+q+'/cmdline','rb').read().replace(b'\0',b' ').decode()
   except OSError:c=S.run(['ps','-o','args=','-p',q],stdout=S.PIPE).stdout.decode()
   w=c.split()
   if w and(B(w[0])=='claude'or'/claude/versions/'in w[0]or'@anthropic-ai/claude-code'in c):return 1
  return 0
 if not D('/proc/self'):return 2
 if p=='codex':
  for l in glob.glob('/proc/[0-9]*/fd/*'):
   try:t=os.readlink(l)
   except OSError:continue
   if'/.codex/sessions/'in t and t.endswith(i+'.jsonl'):return 1
  k=H+'/.codex/thread-writer-locks/'+i+'.lock'
  if os.path.exists(k):
   n=':%d '%os.stat(k).st_ino
   if any(n in l for l in open('/proc/locks')):return 1
  return 0
 if p not in('agy','grok'):return 2
 for l in glob.glob('/proc/[0-9]*/cmdline'):
  try:w=open(l,'rb').read().split(b'\0')
  except OSError:continue
  if B(w[0])==p.encode()and i.encode()in w:return 1
 return 0
try:r=g(*sys.argv[1:3])
except Exception:r=2
sys.exit(r)
