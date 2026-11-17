"""Drive a Godot web export in the installed Chrome (or Playwright's Firefox) and record everything it does.

python webrun.py --out runs/x --timeout 300 [--godot-args '["--","quit=on"]']
                 [--no-watchdog] [--fresh] [--until REGEX] [--settle S] [--shot S] [--idle S]
                 [--url http://127.0.0.1:8765/lit.html] [--chrome-arg ...] [--browser chrome|firefox]
                 [--dump-all] [--crash-after S]

Writes <out>/log.txt (console, events, timings), <out>/shot_*.png, <out>/summary.txt,
<out>/src_<n>_<frag|vert>.glsl for every Lit program (all programs with --dump-all),
and any "[file] name i/n chunk" console dumps reassembled as <out>/<name>.
Exit codes: 0 until-regex matched, 2 timeout, 3 WebGL context lost, 4 page/renderer crash,
5 failure notice or fatal console line, 6 idle (no output while responsive), 7 hard kill.
"""
import argparse, json, os, re, shutil, subprocess, sys, threading, time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "pylib"))
from playwright.sync_api import sync_playwright, Error as PWError, TimeoutError as PWTimeout  # noqa: E402

FATAL = r"RuntimeError|Aborting\.|Aborted\(|abort\(|memory access out of bounds|Uncaught |context lost|CONTEXT_LOST|Out of memory|unreachable"

INIT_JS = r"""
(() => {
  const T = () => performance.now();
  const log = (s) => console.log("[gl] " + s);
  const origGet = HTMLCanvasElement.prototype.getContext;
  const seen = new WeakSet();
  function fingerprint(src) {
    if (!src) return "?";
    const defs = [];
    const re = /#define\s+(LIT_[A-Z0-9_]+)/g; let m;
    while ((m = re.exec(src)) !== null) if (!defs.includes(m[1])) defs.push(m[1]);
    const lit = src.indexOf("lit_light_data") >= 0 ? "LIT" : (src.indexOf("lit_world_sdf") >= 0 ? "LITSDF" : "godot");
    const mode = (src.match(/#define\s+(USE_[A-Z0-9_]+|MODE_[A-Z0-9_]+)/g) || []).map(x => x.split(/\s+/)[1]).join(",");
    return lit + " len=" + src.length + " defs=" + defs.join(",") + " mode=" + mode;
  }
  function wrap(gl) {
    if (seen.has(gl)) return; seen.add(gl);
    const srcOf = new WeakMap(), typeOf = new WeakMap(), fragOf = new WeakMap(), linkT = new WeakMap(), id = new WeakMap();
    let n = 0, total = 0;
    const p = Object.getPrototypeOf(gl);
    const o = {};
    for (const k of ["shaderSource","compileShader","attachShader","linkProgram","getProgramParameter","getShaderParameter","createShader"]) o[k] = p[k];
    gl.createShader = function(t) { const s = o.createShader.call(this, t); typeOf.set(s, t); return s; };
    gl.shaderSource = function(s, src) { srcOf.set(s, src); return o.shaderSource.call(this, s, src); };
    gl.compileShader = function(s) { const t0 = T(); const r = o.compileShader.call(this, s); const dt = T() - t0;
      if (dt > 20) log("compileShader " + dt.toFixed(0) + "ms " + (typeOf.get(s) === this.FRAGMENT_SHADER ? "frag" : "vert")); return r; };
    gl.getShaderParameter = function(s, pn) { const t0 = T(); const r = o.getShaderParameter.call(this, s, pn); const dt = T() - t0;
      if (pn === this.COMPILE_STATUS && dt > 20) log("compileStatus " + dt.toFixed(0) + "ms " + (typeOf.get(s) === this.FRAGMENT_SHADER ? "frag" : "vert") + " ok=" + r);
      return r; };
    const attached = new WeakMap();
    const dumped = new WeakSet();
    gl.attachShader = function(pr, s) { if (typeOf.get(s) === this.FRAGMENT_SHADER) fragOf.set(pr, s); if (!attached.has(pr)) attached.set(pr, []); attached.get(pr).push(s);
      const r = o.attachShader.call(this, pr, s);
      const list = attached.get(pr);
      if (list.length >= 2 && !dumped.has(pr)) {
        const fs = srcOf.get(fragOf.get(pr)) || "";
        if (window.__dumpAll || fs.indexOf("lit_light_data") >= 0) {
          dumped.add(pr);
          if (!id.has(pr)) id.set(pr, ++n);
          const vs = (() => { for (const x of list) if (typeOf.get(x) === this.VERTEX_SHADER) return srcOf.get(x) || ""; return ""; })();
          for (const [kind, src] of [["frag", fs], ["vert", vs]]) {
            const cnt = Math.ceil(src.length / 50000) || 1;
            for (let i = 0; i < cnt; i++) console.log("[src] " + id.get(pr) + " " + kind + " " + i + "/" + cnt + " " + src.slice(i * 50000, (i + 1) * 50000));
          }
          log("dumped program #" + id.get(pr) + " frag=" + fs.length + " vert=" + vs.length);
        }
      }
      return r; };
    gl.linkProgram = function(pr) { if (!id.has(pr)) id.set(pr, ++n); const t0 = T(); const r = o.linkProgram.call(this, pr); linkT.set(pr, [t0, T() - t0]); return r; };
    gl.getProgramParameter = function(pr, pn) { const t0 = T(); const r = o.getProgramParameter.call(this, pr, pn);
      if (pn === this.LINK_STATUS) { const lt = linkT.get(pr) || [t0, 0]; const dt = T() - lt[0]; total += dt; linkT.delete(pr);
        const fs = srcOf.get(fragOf.get(pr)) || "";
        log("link #" + id.get(pr) + " " + dt.toFixed(0) + "ms (call " + lt[1].toFixed(0) + "ms) ok=" + r + " total=" + (total/1000).toFixed(1) + "s " + fingerprint(fs));
        }
      return r; };
  }
  HTMLCanvasElement.prototype.getContext = function(type, attrs) {
    const ctx = origGet.call(this, type, attrs);
    if (ctx && (type === "webgl2" || type === "webgl")) {
      wrap(ctx);
      this.addEventListener("webglcontextlost", (e) => { console.log("[harness] webglcontextlost " + (e.statusMessage || "")); }, false);
      try {
        const dbg = ctx.getExtension("WEBGL_debug_renderer_info");
        log("context " + type + " renderer=" + (dbg ? ctx.getParameter(dbg.UNMASKED_RENDERER_WEBGL) : "?") +
            " units=" + ctx.getParameter(ctx.MAX_TEXTURE_IMAGE_UNITS) + " maxtex=" + ctx.getParameter(ctx.MAX_TEXTURE_SIZE) +
            " ext=" + (ctx.getSupportedExtensions() || []).filter(e => /float|parallel/.test(e)).join(","));
      } catch (e) { log("context probe failed " + e); }
    }
    return ctx;
  };
})();
"""

NOTICE_JS = """(() => { const n = document.getElementById('status-notice');
  if (!n) return null; const d = getComputedStyle(n).display; return d !== 'none' ? n.textContent : null; })()"""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--timeout", type=float, default=300)
    ap.add_argument("--url", default="http://127.0.0.1:8765/lit.html")
    ap.add_argument("--godot-args", default="[]")
    ap.add_argument("--no-watchdog", action="store_true")
    ap.add_argument("--fresh", action="store_true", help="new browser profile (cold shader cache)")
    ap.add_argument("--until", default=None)
    ap.add_argument("--settle", type=float, default=3)
    ap.add_argument("--shot", type=float, default=30)
    ap.add_argument("--idle", type=float, default=90, help="stop after this long with no console output while responsive")
    ap.add_argument("--fatal", default=FATAL)
    ap.add_argument("--chrome-arg", action="append", default=[])
    ap.add_argument("--profile", default=None)
    ap.add_argument("--browser", default="chrome", help="chrome (installed) or firefox (Playwright build)")
    ap.add_argument("--dump-all", action="store_true", help="dump every program's GLSL, not only Lit's")
    ap.add_argument("--crash-after", type=float, default=None, help="self-test: crash the renderer after S seconds")
    a = ap.parse_args()

    os.makedirs(a.out, exist_ok=True)
    here = os.path.dirname(os.path.abspath(__file__))
    profile = a.profile or os.path.join(here, "profile" if a.browser == "chrome" else "profile_ff")
    if a.fresh and os.path.isdir(profile):
        shutil.rmtree(profile, ignore_errors=True)
    os.makedirs(profile, exist_ok=True)
    logf = open(os.path.join(a.out, "log.txt"), "w", encoding="utf-8")
    t0 = time.time()
    state = {"lost": False, "crash": False, "matched": False, "fatal": None, "lines": 0, "last_line": time.time(),
             "links": [], "suite": [], "errors": [], "src": {}}
    until = re.compile(a.until) if a.until else None
    fatal = re.compile(a.fatal) if a.fatal else None
    summary_path = os.path.join(a.out, "summary.txt")

    def log(kind, msg):
        line = "%7.1f %-8s %s" % (time.time() - t0, kind, msg)
        logf.write(line + "\n"); logf.flush()
        if kind in ("event", "harness", "pageerr") or "[harness]" in msg:
            print(line, flush=True)

    def kill_profile_browser():
        subprocess.call(["powershell", "-NoProfile", "-Command",
                         "Get-CimInstance Win32_Process -Filter \"Name='chrome.exe' or Name='firefox.exe'\" | Where-Object { $_.CommandLine -like '*%s*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }" % profile.replace("\\", "\\\\")],
                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    def write_summary(rc):
        with open(summary_path, "w", encoding="utf-8") as s:
            s.write("rc=%d lost=%s crash=%s matched=%s fatal=%s console_lines=%d elapsed=%.0fs\n" % (
                rc, state["lost"], state["crash"], state["matched"], (state["fatal"] or "")[:200], state["lines"], time.time() - t0))
            s.write("links=%d\n" % len(state["links"]))
            def ms(l):
                m = re.search(r"link #\d+ (\d+)ms", l); return int(m.group(1)) if m else 0
            for l in sorted(state["links"], key=ms, reverse=True)[:40]:
                s.write("  " + l[5:] + "\n")
            for l in state["suite"]:
                if any(k in l for k in ("SUMMARY", "RESULT", "FAIL", "GAP", "ENV", "LITBENCH")):
                    s.write(l + "\n")
            for l in state["errors"][:20]:
                s.write("ERR " + l[:300].replace("\n", " | ") + "\n")

    def hard_kill():
        log("harness", "HARD KILL: playwright did not return in time")
        kill_profile_browser()
        write_summary(7)
        os._exit(7)

    killer = threading.Timer(a.timeout + 45, hard_kill)
    killer.daemon = True
    killer.start()

    def chunk_file(prefix, txt):
        # "[src] id kind i/n chunk" or "[file] name i/n chunk", reassembled on the last chunk.
        if prefix == "[src] ":
            parts = txt[len(prefix):].split(" ", 3)
            pid, kind, idx = parts[0], parts[1], parts[2]
            chunk = parts[3] if len(parts) > 3 else ""
            key = (pid, kind); name = "src_%s_%s.glsl" % (pid, kind)
        else:
            parts = txt[len(prefix):].split(" ", 2)
            name, idx = parts[0], parts[1]
            chunk = parts[2] if len(parts) > 2 else ""
            key = ("file", name)
        state["src"].setdefault(key, {})[idx] = chunk
        i, n = idx.split("/")
        if len(state["src"][key]) == int(n):
            got = state["src"][key]
            with open(os.path.join(a.out, name), "w", encoding="utf-8", newline="") as f:
                f.write("".join(got["%d/%s" % (k, n)] for k in range(int(n))))

    args = ["--autoplay-policy=no-user-gesture-required", "--window-size=1600,1000", "--no-first-run"]
    if a.no_watchdog:
        args.append("--disable-gpu-watchdog")
    args += a.chrome_arg
    rc = 2
    with sync_playwright() as pw:
        if a.browser == "firefox":
            ctx = pw.firefox.launch_persistent_context(profile, headless=False, viewport={"width": 1600, "height": 900},
                                                       firefox_user_prefs={"webgl.force-enabled": True})
        else:
            ctx = pw.chromium.launch_persistent_context(profile, channel="chrome", headless=False, args=args,
                                                        viewport={"width": 1600, "height": 900},
                                                        ignore_default_args=["--enable-automation", "--no-sandbox"])
        page = ctx.pages[0] if ctx.pages else ctx.new_page()
        page.add_init_script(("window.__dumpAll = true;\n" if a.dump_all else "") + INIT_JS)
        godot_args = json.loads(a.godot_args)

        def route(r):
            body = r.fetch().text()
            body = body.replace('"args":[]', '"args":' + json.dumps(godot_args), 1)
            r.fulfill(status=200, content_type="text/html", body=body,
                      headers={"Cross-Origin-Opener-Policy": "same-origin", "Cross-Origin-Embedder-Policy": "require-corp"})
        if godot_args:
            page.route(a.url, route)

        def on_console(m):
            txt = m.text
            state["lines"] += 1
            state["last_line"] = time.time()
            if txt.startswith("[src] "):
                chunk_file("[src] ", txt); return
            if txt.startswith("[file] "):
                chunk_file("[file] ", txt); return
            log("console", "[%s] %s" % (m.type, txt))
            if m.type == "error":
                state["errors"].append(txt)
            if "[harness] webglcontextlost" in txt:
                state["lost"] = True
            if txt.startswith("[gl] link"):
                state["links"].append(txt)
            if txt.startswith("SUITE ") or txt.startswith("LITBENCH"):
                state["suite"].append(txt)
            if until and until.search(txt):
                state["matched"] = True
            elif fatal and fatal.search(txt) and state["fatal"] is None:
                state["fatal"] = txt
        page.on("console", on_console)
        def on_pageerr(e):
            log("pageerr", str(e)); state["errors"].append("pageerror: " + str(e))
            if state["fatal"] is None:
                state["fatal"] = "pageerror: " + str(e)
        page.on("pageerror", on_pageerr)
        page.on("crash", lambda: (log("event", "PAGE CRASH"), state.__setitem__("crash", True)))
        page.on("close", lambda: log("event", "page closed"))
        ctx.on("close", lambda: log("event", "context closed"))

        log("harness", "goto %s args=%s watchdog=%s fresh=%s browser=%s" % (a.url, godot_args, not a.no_watchdog, a.fresh, a.browser))
        try:
            page.goto(a.url, wait_until="commit", timeout=60000)
        except PWError as e:
            log("event", "goto failed: %s" % e)
            if "crash" in str(e).lower():
                state["crash"] = True
        last_shot = time.time(); shot_n = 0; blocked_since = None; responsive = True
        while True:
            now = time.time()
            if state["crash"]:
                log("event", "STOP: crash"); rc = 4; break
            if state["lost"]:
                log("event", "STOP: WebGL context lost"); rc = 3; time.sleep(2)
                if a.browser == "chrome":
                    try:
                        g = ctx.new_page()
                        g.goto("chrome://gpu", timeout=15000)
                        g.wait_for_timeout(2500)
                        txt = g.evaluate("""(() => { const out = []; const walk = (n) => { if (n.shadowRoot) walk(n.shadowRoot);
                            for (const c of n.childNodes) { if (c.nodeType === 3) out.push(c.textContent); else walk(c); } };
                            walk(document.body); return out.join("\\n"); })()""")
                        log("event", "chrome://gpu text %d chars" % len(txt))
                        for ln in txt.split("\n"):
                            if re.search(r"GPU process|exit|crash|reset|lost|hung|watchdog|D3D|device", ln, re.I):
                                log("gpulog", ln.strip()[:300])
                        g.close()
                    except PWError as e:
                        log("event", "chrome://gpu read failed: %s" % str(e)[:120])
                break
            if state["fatal"]:
                log("event", "STOP: fatal line: %s" % state["fatal"][:200]); rc = 5; time.sleep(1); break
            if state["matched"]:
                log("event", "STOP: until matched"); time.sleep(a.settle); rc = 0; break
            if now - t0 > a.timeout:
                log("event", "STOP: TIMEOUT after %.0fs" % a.timeout); rc = 2; break
            if page.is_closed():
                log("event", "STOP: page closed by someone"); rc = 4; break
            if a.crash_after is not None and now - t0 > a.crash_after:
                a.crash_after = None
                log("harness", "self-test: crashing the renderer")
                try:
                    page.goto("chrome://crash", timeout=10000)
                except PWError as e:
                    log("event", "crash goto raised: %s" % str(e)[:120])
                    if "crash" in str(e).lower():
                        state["crash"] = True
                continue
            try:
                page.wait_for_function("1", timeout=1500, polling=250)
                responsive = True
                if blocked_since is not None:
                    log("event", "main thread unblocked after %.1fs" % (now - blocked_since)); blocked_since = None
                try:
                    notice = page.evaluate(NOTICE_JS)
                except PWError:
                    notice = None
                if notice:
                    state["fatal"] = "notice: " + notice.strip()
                    continue
            except PWTimeout:
                responsive = False
                if blocked_since is None:
                    blocked_since = now; log("event", "main thread blocked (compile or hang)")
            except PWError as e:
                if "closed" in str(e).lower() or "crash" in str(e).lower():
                    log("event", "STOP: page gone: %s" % str(e)[:200]); rc = 4; break
            if responsive and now - state["last_line"] > a.idle:
                log("event", "STOP: idle %.0fs with no output" % a.idle); rc = 6; break
            if now - last_shot >= a.shot:
                try:
                    shot_n += 1
                    page.screenshot(path=os.path.join(a.out, "shot_%02d.png" % shot_n), timeout=5000)
                except PWError:
                    pass
                last_shot = now
            time.sleep(1.0)
        try:
            if not page.is_closed():
                page.screenshot(path=os.path.join(a.out, "shot_final.png"), timeout=8000)
        except PWError:
            log("event", "final screenshot failed")
        try:
            ctx.close()
        except PWError:
            pass
    kill_profile_browser()
    killer.cancel()
    write_summary(rc)
    print(open(summary_path, encoding="utf-8").read())
    sys.exit(rc)


main()
