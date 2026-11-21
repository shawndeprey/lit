"""Time compile+link of GLSL files in Chrome via bench.html (one window, watchdog off).

python benchrun.py <vert.glsl> <frag1.glsl> [frag2.glsl ...] [--parallel] [--timeout S] [--tag T]
Files are copied into build/shaders/ and timed in one page load. Prints the BENCH lines.
"""
import os, shutil, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
args = [a for a in sys.argv[1:] if not a.startswith("--")]
opts = [a for a in sys.argv[1:] if a.startswith("--")]
timeout = 900
tag = "b"
for o in opts:
    if o.startswith("--timeout="):
        timeout = int(o.split("=")[1])
    if o.startswith("--tag="):
        tag = o.split("=")[1]
par = "--parallel" in opts
trans = "--translate" in opts
draw = "--draw" in opts
extra = [o for o in opts if o.startswith("--chrome-arg=") or o == "--fresh"]
vert, frags = args[0], args[1:]
sd = os.path.join(HERE, "build", "shaders")
os.makedirs(sd, exist_ok=True)
names = []
shutil.copy(vert, os.path.join(sd, "v.glsl"))
for i, f in enumerate(frags):
    n = "f%d_%s.glsl" % (i, os.path.basename(f).replace(".glsl", ""))
    shutil.copy(f, os.path.join(sd, n))
    names.append("shaders/" + n)
url = "http://127.0.0.1:8765/bench.html?v=shaders/v.glsl&f=%s%s" % (",".join(names), ("&parallel=1" if par else "") + ("&translate=1" if trans else "") + ("&draw=1" if draw else ""))
out = os.path.join(HERE, "..", "runs", "bench_%s_%d" % (tag, int(time.time())))
t0 = time.time()
rc = subprocess.call([sys.executable, os.path.join(HERE, "webrun.py"), "--out", out, "--timeout", str(timeout), "--no-watchdog",
                      "--idle", str(timeout), "--url", url, "--until", "BENCH DONE", "--settle", "0.5", "--shot", "100000"] + extra,
                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
for line in open(os.path.join(out, "log.txt"), encoding="utf-8"):
    if "BENCH" in line:
        print(line.split("[log] ", 1)[-1].rstrip())
print("rc=%d wall=%.0fs out=%s" % (rc, time.time() - t0, out))
for f in sorted(os.listdir(out)):
    if f.endswith(".hlsl"):
        print("hlsl", f, os.path.getsize(os.path.join(out, f)))
