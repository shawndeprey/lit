"""Inlining tree of a dumped GLES3 fragment shader: python inltree.py <frag.glsl>"""
import io, re, sys

s = io.open(sys.argv[1], encoding="utf-8", newline="").read()
lines = s.replace("\r\n", "\n").split("\n")
defs = []
for i, l in enumerate(lines):
    m = re.match(r"^(vec[234]|float|int|bool|uint|ivec[234]|mat[234]|void) (m_[A-Za-z0-9_]+)\(", l)
    if m:
        defs.append((i, m.group(2)))
    if l.startswith("void main()"):
        defs.append((i, "main"))
defs.append((len(lines), "END"))
body = {}
for k in range(len(defs) - 1):
    body[defs[k][1]] = "\n".join(lines[defs[k][0] + 1:defs[k + 1][0]])
names = [n for _, n in defs[:-1]]
calls = {}
for n in names:
    c = {}
    for m in names:
        if m == n:
            continue
        k = len(re.findall(r"\b" + re.escape(m) + r"\(", body[n]))
        if k:
            c[m] = k
    calls[n] = c
inst = {"main": 1}
order = names[::-1]
changed = True
while changed:
    changed = False
    for n in names:
        tot = sum(inst.get(caller, 0) * k for caller, cs in calls.items() for m, k in cs.items() if m == n)
        if n != "main" and inst.get(n) != tot:
            inst[n] = tot
            changed = True
size = {n: body[n].count("\n") + 1 for n in names}
rows = sorted(((size[n] * inst.get(n, 0), n, size[n], inst.get(n, 0)) for n in names), reverse=True)
print("%-40s %6s %5s %8s" % ("function", "lines", "inst", "lines*inst"))
tot = 0
for w, n, sz, k in rows:
    if k:
        tot += w
        print("%-40s %6d %5d %8d   callers: %s" % (n, sz, k, w, ", ".join("%s x%d" % (c, cs[n]) for c, cs in calls.items() if n in cs)))
print("total inlined lines", tot)
