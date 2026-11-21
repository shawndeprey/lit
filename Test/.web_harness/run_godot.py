import subprocess, sys, time, os

EXE = r"D:\Game Dev\Godot\Godot_v4.7.2-stable_win64_console.exe"

def main():
    timeout = float(sys.argv[1])
    log = sys.argv[2]
    cwd = sys.argv[3]
    args = sys.argv[4:]
    if not os.path.exists(EXE):
        print("RUN missing exe", EXE)
        sys.exit(3)
    t0 = time.time()
    with open(log, "wb") as f:
        p = subprocess.Popen([EXE] + args, cwd=cwd, stdout=f, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL)
        try:
            rc = p.wait(timeout=timeout)
            print("RUN exit=%d time=%.1fs" % (rc, time.time() - t0))
        except subprocess.TimeoutExpired:
            subprocess.call(["taskkill", "/PID", str(p.pid), "/T", "/F"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            p.wait()
            print("RUN TIMEOUT killed pid=%d after %.1fs" % (p.pid, time.time() - t0))
            sys.exit(2)
    sys.exit(0 if rc == 0 else 1)

main()
