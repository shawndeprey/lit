import http.server, socketserver, sys, os

root = sys.argv[1]
port = int(sys.argv[2])


class H(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *a, **k):
        super().__init__(*a, directory=root, **k)

    def end_headers(self):
        self.send_header("Cross-Origin-Opener-Policy", "same-origin")
        self.send_header("Cross-Origin-Embedder-Policy", "require-corp")
        self.send_header("Cache-Control", "no-store")
        super().end_headers()

    def log_message(self, fmt, *args):
        pass


socketserver.TCPServer.allow_reuse_address = True
with socketserver.ThreadingTCPServer(("127.0.0.1", port), H) as s:
    pages = sorted(f for f in os.listdir(root) if f.endswith(".html"))
    print("serving", root, "on", port, flush=True)
    for f in pages:
        print("  open http://127.0.0.1:%d/%s" % (port, f), flush=True)
    s.serve_forever()
