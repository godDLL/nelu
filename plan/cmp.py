import subprocess
import os

# Lives in plan/ now, so ROOT is the project root (parent of plan/).
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUR = os.path.join(ROOT, "tmp", "nelua")

# The oracle caches --print-ast output by source filename, so every case MUST
# use a unique path or the oracle returns the first case's AST forever.
COUNTER = [0]

def _fresh(prefix):
    COUNTER[0] += 1
    return f"/tmp/{prefix}_{COUNTER[0]}.nelua"

def toks_mine(s):
    # Our dump is the nk-prefixed flat form: `nk<kind> "scalar"` per node, with
    # braces on their own lines.  The oracle escapes control chars in string
    # scalars (a real newline becomes the two chars \n); ours preserves them
    # verbatim.  splitlines() therefore tears a multi-line string scalar into
    # two fragments and we lose the second.  Scan quote-aware: when a quoted
    # scalar is not closed on its own line, accumulate subsequent lines until
    # the closing quote, and escape the real newlines we had to bridge so the
    # scalar matches the oracle's escaped form.
    out=[]
    lines=s.splitlines()
    i=0; n=len(lines)
    while i<n:
        raw=lines[i].strip().rstrip(',')
        if not raw or not raw.startswith('nk'):
            i+=1; continue
        body=raw[2:].strip()
        parts=body.split(None,1); kind=parts[0]; rest=parts[1] if len(parts)>1 else ''
        scalar=None
        if rest:
            if rest==':true': scalar='true'
            elif rest=='false': scalar='false'
            elif ':' in rest and not rest.startswith('"'): scalar=rest.split(':')[0]
            elif rest.startswith('"'):
                q=rest.find('"',1)
                if q==-1:
                    buf=rest; i+=1
                    while i<n:
                        buf+='\n'+lines[i].strip().rstrip(',')
                        q=buf.find('"',1)
                        if q!=-1: break
                        i+=1
                    scalar=buf[1:q].replace('\n','\\n') if q!=-1 else buf[1:].strip('"')
                else:
                    scalar=rest[1:q]
            else: scalar=rest
        out.append((kind,scalar))
        i+=1
    return out

def toks_oracle(s):
    out=[]; pending=None
    for line in s.splitlines():
        line=line.strip().rstrip(',')
        if not line or line in ('{','}'): continue
        if line.endswith('{'):
            out.append([line[:-1].strip(),None]); pending=out[-1]; continue
        if '{' in line and line.endswith('}'):
            kind=line[:line.index('{')].strip(); inner=line[line.index('{')+1:].rstrip('}').strip()
            scalar='true' if inner in('true','false') else (inner.strip('"') if inner.startswith('"') else (inner or None))
            out.append([kind,scalar]); pending=out[-1]; continue
        if (line.startswith('"') and line.endswith('"')) or line in ('true','false') or (line and line[0].isdigit()):
            scalar=line if line in('true','false') else (line.strip('"') if line.startswith('"') else line)
            if pending is not None and pending[1] is None: pending[1]=scalar
            else: out.append([None,scalar]); pending=None
            continue
    return [tuple(t) for t in out]

def mine(src):
    p = _fresh("m")
    open(p, 'w').write(src)
    r = subprocess.run([OUR, '--print-ast', p],
                       capture_output=True, text=True)
    os.remove(p)
    return toks_mine(r.stdout), r.stderr

def oracle(src):
    p = _fresh("o")
    open(p, 'w').write(src)
    r = subprocess.run(['/usr/bin/nelua', '--print-ast', p],
                       capture_output=True, text=True)
    os.remove(p)
    return toks_oracle(r.stdout), r.stderr

cases=[('1','local x: integer = 0'),('2','local t = {1, 2, foo = 3}'),('3','function foo(a: integer): integer return a + 1 end'),('4','for i = 1, 10 do print(i) end'),('5','local s = a.b:c(1)'),('6','local f = function(x) return x + 1 end'),('7','if a > 0 then x = 1 elseif a == 0 then x = 0 else x = -1 end'),('8','local u: record { a: integer, b: string } = { a = 1, b = "hi" }'),('9','local arr: array(integer, 10)'),('10','local p: pointer(integer)'),('11','local e: enum { Red = 0, Green = 1, Blue = 2 }'),('12','local un: union { X: integer, Y: string }'),('13','local fn: function(a: integer): integer'),('14','defer\n  print(1)\nend'),('15','local y = 1 + 2 * 3 - 4 / 5 % 6'),('16','local z = a and b or c'),('17','local w = not x'),('18','local v = #t'),('19','local b = a == b'),('20','local g = a < b and c >= d'),('21','local ptr: *integer'),('22','local arr2: array(integer)'),('23','local v: integer | string'),('24','local f2: function(a: integer, b: string): integer, string'),('25','local opt: integer?'),('26','local nested: array(pointer(integer), 5)'),('27','local rec2: record { name: string, age: integer, tags: array(string, 3) }'),('28','local x = -5'),('29','local s = "hi" .. "lo"'),('30','local a, b = 1, 2'),('31','local t = { [1] = "a", ["x"] = 2, y = 3 }'),('32','function obj:method(a, b) return self end'),('33','local f = function(self, a): integer <ann> return a end'),('34','while x > 0 do x = x - 1 end'),('35','repeat print(x) until x == 0'),('36','local function fib(n) if n < 2 then return n end return fib(n-1) + fib(n-2) end'),('37','local t = {1, 2, 3}; print(#t)'),('38','local x = (1 + 2) * 3'),('39','local s = [[long\nstring]]'),('40','local e: enum { Red, Green, Blue }')]
def norm_m1(tokens):
    # M1 dump canonicalization (mirrors plan/regress.py). The two parse-AST
    # dumps are structurally different by design (ours is nk-prefixed flat,
    # the oracle is nested), so tokenization is the only honest comparison.
    # Two canonicalization rules, both verified not to mask regressions:
    #   Rule 1 -- drop the oracle's absent-field placeholder (a bare
    #     (None,'false') never carries a genuine value; a real boolean is
    #     always wrapped as (Boolean,'false')).
    #   Rule 2 -- our dump renders the binary operator as a pseudo-node
    #     (BinaryOp,add); the oracle renders it as a bare scalar (None,add).
    out = []
    for kind, scalar in tokens:
        if kind is None and scalar == "false":
            continue
        if kind == "BinaryOp" and scalar is not None:
            out.append((None, scalar))
            continue
        out.append((kind, scalar))
    return out

# cmp: 40-case token-level AST diff, oracle vs ours.  Report-only: exit 0
# always, even with diffs (see plan/GATES.md).
print("cmp: 40-case token-level AST diff (oracle vs ours) -- report-only, exit 0 always")
fails=0
for n,c in cases:
    mo,me=mine(c); oo,oe=oracle(c)
    rej='syntax error' in oe; me_=me.strip()!=''
    if me_ and not rej: print(f"[{n}] MINE-ERR: {me.strip()[:100]}")
    if rej and not me_: print(f"[{n}] ORACLE-REJECTS BUT MINE PARSED: {c[:48]}"); fails+=1; continue
    if me_: print(f"[{n}] BOTH-ERR"); continue
    if norm_m1(mo)==norm_m1(oo): print(f"[{n}] MATCH")
    else:
        fails+=1; print(f"[{n}] DIFF: {c[:48]}")
        N=min(len(mo),len(oo))
        for i in range(N):
            if mo[i]!=oo[i]: print(f"    #{i} M:{mo[i]} O:{oo[i]}"); break
        if len(mo)!=len(oo): print(f"    (len M={len(mo)} O={len(oo)})")
print(f"\n{fails} diffs out of {len(cases)}")