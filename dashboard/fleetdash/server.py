"""The HTTP server: the JSON API under /api/ and the static page.

Loopback is not private on a shared host: every user on it can connect. So
every request under /api/ needs the login token in an X-Fleetdash-Token
header. The page gets the token from the part of its address after the #,
which a browser never sends anywhere, and keeps it for that tab. The token is
never put in a cookie: a browser sends a host's cookies to every port on that
host, so to any other person's listener on this machine. The page's own
files hold no data and are served without the token. A Host header other
than the loopback address is refused, so a web page cannot reach the API by
DNS rebinding.

Everything is GET and changes nothing, except POST /api/run, which starts one
of the commands the config lists (see actions.py) and asks for more: the
run key, a small JSON body, and an Origin, when the browser sends one, that is
the address the request itself was sent to. It answers with the run's number
as soon as the command has started; GET /api/run reads what that run has
printed so far.
"""
import hmac
import json
import os
import re
import secrets
import socketserver
import sqlite3
import urllib.parse
from http.server import BaseHTTPRequestHandler, HTTPServer

from fleetdash import actions, api, docs

WEB = os.path.realpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), os.pardir, "web"))
TYPES = {".html": "text/html; charset=utf-8", ".js": "text/javascript; charset=utf-8",
         ".css": "text/css; charset=utf-8", ".svg": "image/svg+xml"}
LOOPBACK = ("127.0.0.1", "localhost")
BODY_MAX = 1024
LENGTH_RE = re.compile(r"[0-9]{1,4}")
# seconds a connection may sit without sending: each one holds a thread
REQUEST_TIMEOUT = 30
TOKEN_BYTES = 24
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


class TokenError(Exception):
    pass


def login_token(cfg):
    """The token a browser logs in with. With token_file set it is kept there,
    owner-only, so a restart does not log everyone out and `url` can print the
    address again; with it empty, each start has a new one."""
    path = cfg["token_file"]
    if not path:
        return secrets.token_urlsafe(TOKEN_BYTES)
    if os.path.lexists(path):
        return read_token(cfg)
    token = secrets.token_urlsafe(TOKEN_BYTES)
    # written whole under another name, then given its own: a start that is
    # interrupted leaves no empty token file for the next one to trip over
    tmp = os.path.join(os.path.dirname(path), ".%s.%s" % (os.path.basename(path), secrets.token_hex(8)))
    try:
        fd = os.open(tmp, os.O_CREAT | os.O_EXCL | os.O_WRONLY | os.O_NOFOLLOW, 0o600)
    except OSError as e:
        raise TokenError("cannot create token_file %s: %s" % (path, e))
    try:
        with os.fdopen(fd, "w") as fh:
            fh.write(token + "\n")
        try:
            os.link(tmp, path)
        except FileExistsError:
            return read_token(cfg)  # another start made it first
        except OSError as e:
            raise TokenError("cannot create token_file %s: %s" % (path, e))
    finally:
        os.unlink(tmp)
    return token


def read_token(cfg):
    path = cfg["token_file"]
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    except OSError as e:
        raise TokenError("cannot read token_file %s: %s" % (path, e))
    with os.fdopen(fd) as fh:
        st = os.fstat(fd)
        # root may read the serving account's token, to print the address
        if st.st_mode & 0o077 or os.geteuid() not in (0, st.st_uid):
            raise TokenError("token_file %s must be owned by this account and closed to everyone else" % path)
        token = fh.read().strip()
    if len(token) < TOKEN_BYTES:
        raise TokenError("token_file %s does not hold a token: remove it and start serve again" % path)
    return token


def make_server(cfg, token=None, web=WEB):
    token = token or login_token(cfg)
    web = os.path.realpath(web)
    runner = actions.Runner(cfg)

    class Handler(BaseHTTPRequestHandler):
        server_version = "fleetdash"
        sys_version = ""
        timeout = REQUEST_TIMEOUT

        def log_message(self, fmt, *args):
            pass  # no request log: a filter's query string names a person

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

        do_PUT = do_DELETE = do_PATCH = _refuse

        def _host_ok(self):
            return (self.headers.get("Host") or "").rsplit(":", 1)[0] in LOOPBACK

        def _origin_ok(self):
            """A browser names the page a POST came from. Absent (a script, not
            a browser) is allowed; present, it must be the address this
            request was sent to: the Host header, already known to be
            loopback. Through a tunnel that is the tunnel's port, not this
            server's."""
            origin = self.headers.get("Origin")
            if origin is None:
                return True
            try:
                o = urllib.parse.urlsplit(origin)
            except ValueError:
                return False
            return o.scheme == "http" and o.netloc == self.headers.get("Host")

        def do_POST(self):
            url = urllib.parse.urlsplit(self.path)
            if url.path != "/api/run":
                return self._refuse()
            if not self._host_ok() or not self._origin_ok():
                return self._json(403, {"error": "unexpected Host or Origin header"})
            if not self._authed():
                return self._json(403, {"error": "not logged in"})
            if not hmac.compare_digest((self.headers.get("X-Fleetdash-Run") or "").encode(), runner.key.encode()):
                return self._json(403, {"error": "reload the page: this server has restarted"})
            try:
                # digits only: int() also reads "1_1" and " 11"
                given = self.headers.get("Content-Length") or ""
                length = int(given) if LENGTH_RE.fullmatch(given) else 0
                if not 0 < length <= BODY_MAX:
                    raise ValueError("body must be 1 to %d bytes" % BODY_MAX)
                body = json.loads(self.rfile.read(length).decode("utf-8"))
                if not isinstance(body, dict) or sorted(body) != ["id"] or not isinstance(body["id"], str):
                    raise ValueError('body must be {"id": "<action id>"}')
            except ValueError as e:
                return self._json(400, {"error": str(e)})
            except RecursionError:
                return self._json(400, {"error": "body nested too deeply"})
            try:
                run = runner.start(body["id"])
            except KeyError:
                return self._json(404, {"error": "no such action"})
            except actions.Busy:
                return self._json(409, {"error": "another action is running"})
            except actions.CannotStart as e:
                return self._json(500, {"error": str(e)})
            self._json(200, {"run": run})

        def _authed(self):
            given = self.headers.get("X-Fleetdash-Token") or ""
            return hmac.compare_digest(given.encode("utf-8", "replace"), token.encode())

        def do_GET(self):
            url = urllib.parse.urlsplit(self.path)
            q = urllib.parse.parse_qs(url.query)
            if not self._host_ok():
                return self._json(403, {"error": "unexpected Host header"})
            if not url.path.startswith("/api/"):
                return self._static(url.path)
            if not self._authed():
                return self._json(403, {"error": "not logged in"})
            return self._api(url.path, q)

        def _api(self, path, q):
            try:
                if path == "/api/status":
                    out = api.status(cfg)
                elif path == "/api/overview":
                    out = api.overview(cfg, days=_int(q, "days", 30, 1, 3650))
                elif path == "/api/events":
                    out = api.events(cfg, user=_str(q, "user"), severity=_str(q, "severity"),
                                     category=_str(q, "category"), source=_str(q, "source"), tool=_str(q, "tool"),
                                     limit=_int(q, "limit", 200, 1, 2000),
                                     offset=_int(q, "offset", 0, 0, 10 ** 9))
                elif path == "/api/sessions":
                    out = api.sessions(cfg, user=_str(q, "user"))
                elif path == "/api/people":
                    out = api.people(cfg, days=_int(q, "days", 30, 1, 3650))
                elif path == "/api/people.csv":
                    days = _int(q, "days", 30, 1, 3650)
                    return self._send(200, api.people_csv(cfg, days=days).encode("utf-8"), "text/csv; charset=utf-8",
                                      {"Content-Disposition": 'attachment; filename="people-%dd.csv"' % days})
                elif path == "/api/hosts":
                    out = api.hosts(cfg, days=_int(q, "days", 30, 1, 3650))
                elif path == "/api/enrolment":
                    out = api.enrolment(cfg)
                elif path == "/api/admin-sessions":
                    out = api.admin_sessions(cfg)
                elif path == "/api/retention":
                    out = api.retention(cfg)
                elif path == "/api/policy":
                    out = api.policy(cfg)
                elif path == "/api/docs":
                    out = docs.index(cfg)
                elif path == "/api/doc":
                    out = docs.read(cfg, _str(q, "id") or "")
                elif path == "/api/actions":
                    out = runner.listing()
                elif path == "/api/run":
                    if "id" not in q:
                        raise ValueError("id is required")
                    try:
                        out = runner.read(_int(q, "id", 0, 1, 10 ** 12), _int(q, "offset", 0, 0, actions.OUTPUT_MAX))
                    except KeyError:
                        return self._json(404, {"error": "no such run: only the newest are kept"})
                else:
                    return self._json(404, {"error": "no such endpoint"})
            except ValueError as e:
                return self._json(400, {"error": str(e)})
            except sqlite3.Error as e:
                # said, not a dropped connection: the page shows it
                return self._json(500, {"error": "the store could not answer: %s" % e})
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
