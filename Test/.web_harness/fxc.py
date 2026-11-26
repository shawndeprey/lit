"""Time D3DCompile on ANGLE-translated HLSL (placeholders filled the way ANGLE's link step does).

python fxc.py <file.hlsl> [--flags=0xC000] [--nodef] [--target=ps_5_0] [--dump=out.hlsl]
Prints: FXC <file> <seconds> ok=<bool> bytes=<n> [errors]
"""
import ctypes, io, os, re, sys, time

DLLS = [r"C:\Program Files\Google\Chrome\Application\157.0.8103.79\d3dcompiler_47.dll", r"C:\Windows\System32\d3dcompiler_47.dll"]


class MACRO(ctypes.Structure):
    _fields_ = [("Name", ctypes.c_char_p), ("Definition", ctypes.c_char_p)]


def blob_bytes(p):
    if not p:
        return b""
    vt = ctypes.cast(ctypes.cast(p, ctypes.POINTER(ctypes.c_void_p))[0], ctypes.POINTER(ctypes.c_void_p))
    getptr = ctypes.WINFUNCTYPE(ctypes.c_void_p, ctypes.c_void_p)(vt[3])
    getsize = ctypes.WINFUNCTYPE(ctypes.c_size_t, ctypes.c_void_p)(vt[4])
    n = getsize(p)
    return ctypes.string_at(getptr(p), n)


def fill(src):
    if "@@ PIXEL OUTPUT @@" not in src:
        return src
    m = re.search(r"// Varyings\n(.*?)\n\n", src, re.S)
    vary = []
    for line in (m.group(1).split("\n") if m else []):
        mm = re.match(r"static\s+(nointerpolation\s+)?(\w+)\s+(\w+)\s*=", line)
        if mm:
            vary.append((mm.group(1) or "", mm.group(2), mm.group(3)))
    struct = "struct PS_INPUT {\n" + "".join("    %s%s v%d : TEXCOORD%d;\n" % (q, t, i, i) for i, (q, t, n) in enumerate(vary)) + "};\n"
    out = struct + "struct PS_OUTPUT { float4 c0 : SV_TARGET0; };\nPS_OUTPUT generateOutput() { PS_OUTPUT o; o.c0 = out_frag_color; return o; }\n"
    src = src.replace("@@ PIXEL OUTPUT @@", out)
    src = src.replace("@@ PIXEL MAIN PARAMETERS @@", "in float4 sv_pos : SV_Position, in PS_INPUT input")
    pro = "gl_FragCoord = sv_pos;\n" + "".join("%s = input.v%d;\n" % (n, i) for i, (q, t, n) in enumerate(vary))
    src = src.replace("@@ MAIN PROLOGUE @@", pro)
    return src


def main():
    path = sys.argv[1]
    flags = 0xC000
    defs = True
    target = b"ps_5_0"
    dump = None
    for o in sys.argv[2:]:
        if o.startswith("--flags="):
            flags = int(o.split("=")[1], 0)
        if o == "--nodef":
            defs = False
        if o.startswith("--target="):
            target = o.split("=")[1].encode()
        if o.startswith("--dump="):
            dump = o.split("=")[1]
    src = fill(io.open(path, encoding="utf-8", newline="").read())
    if dump:
        io.open(dump, "w", encoding="utf-8", newline="").write(src)
    dll = None
    for d in DLLS:
        if os.path.exists(d):
            dll = ctypes.WinDLL(d)
            break
    D3DCompile = dll.D3DCompile
    D3DCompile.restype = ctypes.c_long
    D3DCompile.argtypes = [ctypes.c_char_p, ctypes.c_size_t, ctypes.c_char_p, ctypes.POINTER(MACRO), ctypes.c_void_p, ctypes.c_char_p,
                           ctypes.c_char_p, ctypes.c_uint, ctypes.c_uint, ctypes.POINTER(ctypes.c_void_p), ctypes.POINTER(ctypes.c_void_p)]
    macros = (MACRO * 2)()
    if defs:
        macros[0].Name = b"ANGLE_ENABLE_LOOP_FLATTEN"
        macros[0].Definition = b"1"
    data = src.encode("utf-8")
    code = ctypes.c_void_p()
    errs = ctypes.c_void_p()
    t0 = time.time()
    hr = D3DCompile(data, len(data), os.path.basename(path).encode(), macros, None, b"main", target, flags, 0, ctypes.byref(code), ctypes.byref(errs))
    dt = time.time() - t0
    err = blob_bytes(errs).decode("utf-8", "replace").strip()
    size = len(blob_bytes(code)) if hr == 0 else 0
    print("FXC %s %.1fs ok=%s bytes=%d flags=0x%x%s" % (os.path.basename(path), dt, hr == 0, size, flags, (" | " + err[:600].replace("\n", " || ")) if err else ""), flush=True)


main()
