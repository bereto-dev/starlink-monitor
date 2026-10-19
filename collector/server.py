"""HTTP API + static files for the Starlink Dashboard."""
import json
import mimetypes
import os
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

DASHBOARD_PATH = "/sl-dashboard/"
DASHBOARD_DIR = os.path.realpath(os.path.join(os.path.dirname(__file__), "..", "sl-dashboard"))


def local_midnight(now=None):
    t = time.localtime(now or time.time())
    return time.mktime((t.tm_year, t.tm_mon, t.tm_mday, 0, 0, 0, 0, 0, -1))


def make_server(state, store, host="0.0.0.0", port=8766):
    class Handler(BaseHTTPRequestHandler):
        server_version = "StarlinkMonitor/0.1"

        def log_message(self, fmt, *args):  # quiet: the dashboard polls every 3 s
            pass

        def _send(self, code, body, ctype, extra=None):
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Access-Control-Allow-Origin", "*")
            self.send_header("Cache-Control", "no-cache")
            for k, v in (extra or {}).items():
                self.send_header(k, v)
            self.end_headers()
            if self.command != "HEAD":
                self.wfile.write(body)

        def _json(self, obj, code=200):
            body = json.dumps(obj, separators=(",", ":"), allow_nan=False).encode()
            self._send(code, body, "application/json; charset=utf-8")

        def do_HEAD(self):
            self.do_GET()

        def do_GET(self):
            u = urlparse(self.path)
            q = {k: v[0] for k, v in parse_qs(u.query).items()}
            p = u.path
            try:
                if p == "/api/now":
                    return self._json(state.now())
                if p == "/api/history":
                    return self._json(store.history(q.get("range", "15m")))
                if p == "/api/outages":
                    since = float(q["since"]) if q.get("since") else local_midnight()
                    return self._json(store.outages(since, float(q.get("min_s", 0))))
                if p in ("/", DASHBOARD_PATH.rstrip("/")):
                    return self._send(302, b"", "text/plain", {"Location": DASHBOARD_PATH})
                if p.startswith(DASHBOARD_PATH):
                    return self._static(p[len(DASHBOARD_PATH):] or "index.html")
                return self._json({"error": "not found"}, 404)
            except (ValueError, KeyError) as e:
                return self._json({"error": str(e)}, 400)

        def _static(self, rel):
            path = os.path.realpath(os.path.join(DASHBOARD_DIR, rel))
            if not path.startswith(DASHBOARD_DIR + os.sep) or not os.path.isfile(path):
                return self._json({"error": "not found"}, 404)
            ctype = mimetypes.guess_type(path)[0] or "application/octet-stream"
            if ctype.startswith("text/") or ctype.endswith("javascript"):
                ctype += "; charset=utf-8"
            with open(path, "rb") as f:
                self._send(200, f.read(), ctype)

    ThreadingHTTPServer.allow_reuse_address = True
    srv = ThreadingHTTPServer((host, port), Handler)
    srv.daemon_threads = True
    return srv
