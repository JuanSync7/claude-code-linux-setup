"""A read-only HTTP server: the JSON API under /api/ and the static page.

Loopback is not private on a shared host: every user on it can connect. So a
request needs the token printed at start-up, presented once as ?token= (which
sets a cookie) or as an X-Fleetdash-Token header. A Host header other than the
loopback address is refused, so a web page cannot reach the API by DNS rebinding.
"""
import hmac
import json
import os
import secrets
import socketserver
import urllib.parse
from http.server import BaseHTTPRequestHandler, HTTPServer

from fleetdash import api

WEB = os.path.realpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), os.pardir, "web"))
TYPES = {".html": "text/html; charset=utf-8", ".js": "text/javascript; charset=utf-8",
         ".css": "text/css; charset=utf-8", ".svg": "image/svg+xml"}
COOKIE = "fleetdash"
HEADERS = {
    "Content-Security-Policy": "default-src 'self'; frame-ancestors 'none'; base-uri 'none'",
    "X-Content-Type-Options": "nosniff",
    "Referrer-Policy": "no-referrer",
    "Cache-Control": "no-store",
}


class _Server(socketserver.ThreadingMixIn, HTTPServer):
    daemon_threads = True


def _int(q, name, default, lo, hi):
    if name not in q:
        return default
    v = int(q[name][0])  # ValueError -> 400
    if not lo <= v <= hi:
        raise ValueError("%s must be between %d and %d" % (name, lo, hi))
    return v


def _str(q, name):
    return q[name][0] if q.get(name) and q[name][0] else None


def make_server(cfg, token=None, web=WEB):
    token = token or secrets.token_urlsafe(24)
    web = os.path.realpath(web)

    class Handler(BaseHTTPRequestHandler):
        server_version = "fleetdash"
        sys_version = ""

        def log_message(self, fmt, *args):
            pass  # the query string carries the token: do not echo it

        def _send(self, status, body, ctype, extra=None):
            self.send_response(status)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
            for k, v in HEADERS.items():
                self.send_header(k, v)
            for k, v in (extra or {}).items():
                self.send_header(k, v)
            self.end_headers()
            self.wfile.write(body)

        def _json(self, status, obj):
            self._send(status, json.dumps(obj).encode(), "application/json")

        def _refuse(self):
            self._json(405, {"error": "read-only"})

        do_POST = do_PUT = do_DELETE = do_PATCH = _refuse

        def _host_ok(self):
            host = (self.headers.get("Host") or "").rsplit(":", 1)[0].strip("[]")
            return host in ("127.0.0.1", "localhost", "::1")

        def _authed(self, q):
            given = self.headers.get("X-Fleetdash-Token") or ""
            if not given:
                for part in (self.headers.get("Cookie") or "").split(";"):
                    k, _, v = part.strip().partition("=")
                    if k == COOKIE:
                        given = v
            return hmac.compare_digest(given.encode(), token.encode())

        def do_GET(self):
            url = urllib.parse.urlsplit(self.path)
            q = urllib.parse.parse_qs(url.query)
            if not self._host_ok():
                return self._json(403, {"error": "unexpected Host header"})
            if "token" in q and hmac.compare_digest(q["token"][0].encode(), token.encode()):
                # trade the token in the URL for a cookie, and drop it from the address bar
                return self._send(303, b"", "text/plain", {
                    "Location": url.path or "/",
                    "Set-Cookie": "%s=%s; HttpOnly; SameSite=Strict; Path=/" % (COOKIE, token)})
            if not self._authed(q):
                return self._send(403, b"Open the URL printed when the server started.\n",
                                  "text/plain; charset=utf-8")
            if url.path.startswith("/api/"):
                return self._api(url.path, q)
            return self._static(url.path)

        def _api(self, path, q):
            try:
                if path == "/api/overview":
                    out = api.overview(cfg, days=_int(q, "days", 30, 1, 3650))
                elif path == "/api/events":
                    out = api.events(cfg, user=_str(q, "user"), severity=_str(q, "severity"),
                                     category=_str(q, "category"),
                                     limit=_int(q, "limit", 200, 1, 2000),
                                     offset=_int(q, "offset", 0, 0, 10 ** 9))
                elif path == "/api/sessions":
                    out = api.sessions(cfg, user=_str(q, "user"))
                elif path == "/api/people":
                    out = api.people(cfg, days=_int(q, "days", 30, 1, 3650))
                else:
                    return self._json(404, {"error": "no such endpoint"})
            except ValueError as e:
                return self._json(400, {"error": str(e)})
            self._json(200, out)

        def _static(self, path):
            rel = urllib.parse.unquote(path).lstrip("/") or "index.html"
            full = os.path.realpath(os.path.join(web, rel))
            ext = os.path.splitext(full)[1]
            if not full.startswith(web + os.sep) or ext not in TYPES or not os.path.isfile(full):
                return self._json(404, {"error": "not found"})
            with open(full, "rb") as fh:
                self._send(200, fh.read(), TYPES[ext])

    httpd = _Server((cfg["bind"], cfg["port"]), Handler)
    httpd.token = token
    return httpd
