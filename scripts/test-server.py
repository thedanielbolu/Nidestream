"""Local test server for SwiftDM's download engine.

Serves files from ROOT with Range/If-Range support and a per-connection speed cap (so
multi-connection speedups are visible), a /norange/ prefix that ignores Range headers,
and /sha256/<name> with the expected checksum.

    python3 scripts/test-server.py [port] [root]
"""
import hashlib, http.server, os, re, sys, time, socketserver, threading
ROOT = os.path.abspath(sys.argv[2]) if len(sys.argv) > 2 else os.path.join(os.path.dirname(os.path.abspath(__file__)), "files")
RATE = int(os.environ.get("RATE", str(2 * 1024 * 1024)))  # bytes/sec per connection
CONNS = {"n": 0, "max": 0}
lock = threading.Lock()

class H(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *a): pass
    def do_GET(self):
        path = self.path.split("?")[0]
        norange = path.startswith("/norange/")
        if norange: path = path[len("/norange"):]
        if path.startswith("/sha256/"):
            with open(os.path.join(ROOT, path[len("/sha256/"):]), "rb") as f:
                body = hashlib.sha256(f.read()).hexdigest().encode()
            self.send_response(200); self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body); return
        if path == "/stats":
            body = ("%d %d" % (CONNS["n"], CONNS["max"])).encode()
            self.send_response(200); self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body); return
        fp = os.path.join(ROOT, path.lstrip("/"))
        if not os.path.isfile(fp):
            self.send_response(404); self.send_header("Content-Length", "0"); self.end_headers(); return
        size = os.path.getsize(fp)
        etag = '"%x-%x"' % (size, int(os.path.getmtime(fp)))
        start, end, status = 0, size - 1, 200
        rng = self.headers.get("Range")
        ifr = self.headers.get("If-Range")
        if rng and not norange and (ifr is None or ifr == etag):
            m = re.match(r"bytes=(\d+)-(\d*)", rng)
            if m:
                start = int(m.group(1)); end = int(m.group(2)) if m.group(2) else size - 1
                end = min(end, size - 1)
                if start > end:
                    self.send_response(416); self.send_header("Content-Range", "bytes */%d" % size); self.send_header("Content-Length", "0"); self.end_headers(); return
                status = 206
        self.send_response(status)
        ctype = "application/vnd.apple.mpegurl" if fp.endswith(".m3u8") else "application/octet-stream"
        self.send_header("Content-Type", ctype)
        self.send_header("ETag", etag)
        if not norange: self.send_header("Accept-Ranges", "bytes")
        if status == 206: self.send_header("Content-Range", "bytes %d-%d/%d" % (start, end, size))
        if path.endswith("disposition.bin"): self.send_header("Content-Disposition", "attachment; filename*=UTF-8''r%C3%A9sum%C3%A9%20final.bin")
        self.send_header("Content-Length", str(end - start + 1))
        self.end_headers()
        with lock:
            CONNS["n"] += 1; CONNS["max"] = max(CONNS["max"], CONNS["n"])
        try:
            with open(fp, "rb") as f:
                f.seek(start); left = end - start + 1; chunk = 64 * 1024
                t0 = time.time(); sent = 0
                while left > 0:
                    data = f.read(min(chunk, left))
                    self.wfile.write(data); left -= len(data); sent += len(data)
                    ahead = sent / RATE - (time.time() - t0)
                    if ahead > 0 and not fp.endswith((".m3u8", ".ts", ".key")): time.sleep(ahead)
        except (BrokenPipeError, ConnectionResetError):
            pass
        finally:
            with lock: CONNS["n"] -= 1

class S(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True

S(("127.0.0.1", int(sys.argv[1]) if len(sys.argv) > 1 else 8765), H).serve_forever()
