"""Export a web build of the Lit project with a chosen main scene, from a scratch mirror.

python webbuild.py res://Test/test_suite/TestSuite.tscn
"""
import io, os, re, subprocess, sys, time

SRC = r"d:\Game Dev\lit"
HERE = os.path.dirname(os.path.abspath(__file__))
PROJ = os.path.join(HERE, "proj")
OUT = os.path.join(HERE, "build")
RUN = os.path.join(os.path.dirname(HERE), "run_godot.py")

scene = sys.argv[1]
t0 = time.time()
r = subprocess.run(["robocopy", SRC, PROJ, "/MIR", "/NFL", "/NDL", "/NJH", "/NJS", "/NP", "/XD", ".git", ".godot\\shader_cache", ".godot\\editor", "builds",
                    "/XF", "*.zip", "*.log"], capture_output=True, text=True)
if r.returncode >= 8:
    print("MIRROR FAILED", r.stdout, r.stderr)
    sys.exit(1)
p = os.path.join(PROJ, "project.godot")
s = io.open(p, encoding="utf-8", newline="").read()
s2, n = re.subn(r'(?m)^run/main_scene=.*$', 'run/main_scene="%s"' % scene, s)
assert n == 1, "main_scene line not found"
io.open(p, "w", encoding="utf-8", newline="").write(s2)
log = os.path.join(os.path.dirname(HERE), "runs", "web_export.log")
rc = subprocess.call([sys.executable, RUN, "600", log, PROJ, "--headless", "--path", PROJ, "--export-debug", "Web", os.path.join(OUT, "lit.html")])
ok = rc == 0 and os.path.exists(os.path.join(OUT, "lit.pck")) and os.path.getmtime(os.path.join(OUT, "lit.pck")) >= t0
print("BUILD %s scene=%s in %.0fs" % ("OK" if ok else "FAILED rc=%d" % rc, scene, time.time() - t0))
sys.exit(0 if ok else 1)
