# <proveedor> <id>: 0 libre, 1 abierta, 2 no comprobable
import glob,json,os,re,sys
O=os.path;B=O.basename;F=re.fullmatch;E=O.exists;G=glob.glob
def c(w):
 b=w and B(w[0])
 return b and(b=='claude'or'/claude/versions/'in w[0]or F(r'(node(js)?|bun)[\d.]*',b)and any('@anthropic-ai/claude-code'in x or B(x)=='claude'for x in w[1:]))
def a(q):
 try:return open('/proc/'+q+'/cmdline',encoding='latin1').read().split('\0')[:-1]
 except OSError:return os.popen('ps -o args= -p%d'%int(q)).read().split()
def k(p):return E(p)and any(':%d '%os.stat(p).st_ino in l for l in open('/proc/locks'))
def g(p,i):
 H=O.expanduser('~')
 if not F('[A-Za-z0-9_-]{1,160}',i):return 2
 if p=='claude':
  d=(os.getenv('CLAUDE_CONFIG_DIR')or H+'/.claude')+'/sessions'
  if not os.access(d,5):return 2*O.isdir(d)
  for f in G(d+'/*.json'):
   try:
    if json.load(open(f))['sessionId'].lower()==i.lower()and c(a(B(f)[:-5])):return 1
   except Exception:pass
  return 0
 if not E('/proc/self'):return 2
 if p=='codex':
  for l in G('/proc/[0-9]*/fd/*'):
   try:t=os.readlink(l)
   except OSError:t=''
   if'/.codex/sessions/'in t and t.endswith(i+'.jsonl'):return 1
  return k(H+'/.codex/thread-writer-locks/'+i+'.lock')*1
 if p=='agy'and k(H+'/.gemini/antigravity-cli/presence/'+i+'.lock'):return 1
 if p not in('agy','grok'):return 2
 for l in G('/proc/[0-9]*'):
  w=a(l[6:]);b=w and B(w[0])
  if b and i in w and(b in('agy','antigravity')if p=='agy'else b.split('-')[0]=='grok'):return 1
 return 0
try:r=g(*sys.argv[1:3])
except Exception:r=2
sys.exit(r)
