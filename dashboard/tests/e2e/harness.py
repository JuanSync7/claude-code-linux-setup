"""Runs the dashboard the way an operator does: the CLI as a separate process,
the server on a free loopback port, and a real headless browser.

Nothing here imports the code under test to call it directly. A fixture fleet
is built on disk, `python3 -m fleetdash` ingests it, `serve` prints its URL,
and the tests talk to that process over HTTP or through the browser.
"""
import datetime
import html.parser
import json
import os
import select
import shutil
import socket
import sqlite3
import subprocess
import time
import sys
import tempfile
import unittest
import urllib.error
import urllib.request

from tests.fixtures import Fleet, assistant, usage

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
PY = sys.executable
START_TIMEOUT = 15


def cli(config, *args, timeout=120):
    """Run `python3 -m fleetdash -c CONFIG ...`; return (exit code, stdout, stderr)."""
    p = subprocess.run([PY, "-m", "fleetdash", "-c", config] + list(args), cwd=ROOT,
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout)
    return p.returncode, p.stdout.decode(), p.stderr.decode()


def free_port():
    """A loopback port nothing holds right now, for a server that needs a fixed one."""
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def count(db, table):
    con = sqlite3.connect(db)
    try:
        return con.execute("select count(*) from %s" % table).fetchone()[0]
    finally:
        con.close()


def at(days_ago, hhmm):
    """A UTC timestamp `days_ago` days before today. The server under test reads
    the real clock, so a fixed date would age out of every window it reports."""
    day = datetime.datetime.utcnow() - datetime.timedelta(days=days_ago)
    return "%sT%s:00Z" % (day.strftime("%Y-%m-%d"), hhmm)


def populated_fleet():
    """Two people with use, a denial, a redaction, a limit hit and a skill:
    enough for every page to have something to show."""
    f = Fleet()
    f.transcript("alice", "proj-a", "s1", [
        assistant("a1", "ma1", at(3, "10:00"), "claude-opus-5-5", usage(i=900000)),
        assistant("a2", "ma2", at(2, "10:00"), "claude-opus-5-5", usage(),
                  quotaLimits={"status": "rejected", "rateLimitType": "five_hour", "resetsAt": 1}),
        assistant("a3", "ma3", at(2, "11:00"), "claude-opus-5-5", usage(), attributionSkill="review")])
    f.transcript("bob", "proj-b", "s2", [
        assistant("b1", "msg_bdrk_b1", at(2, "10:00"), "claude-opus-5-5", usage(i=1000))])
    f.hooklog("activity", "alice", [
        {"ts": at(2, "10:00"), "tool": "Bash", "detail": "make test"},
        {"ts": at(2, "10:01"), "event": "redaction", "tool": "Read", "kinds": ["private-key"], "count": 1}])
    f.hooklog("denied", "bob", [
        {"ts": at(2, "10:00"), "tool": "Bash", "detail": "sudo x", "denied_by": "Blocked by rule"}])
    return f


GUIDE = """# Operator guide

Read [the other page](sub/Other.md), [a file that is not listed](../secret.md) or [the web](https://example.com/x).

| Exit | Meaning |
| --- | --- |
| `0` | done |

- first
  - nested **bold**

```
make verify
```

<img src=x onerror=alert(1)> stays text.
"""
POLICY = {"permissions": {"deny": ["Bash(sudo:*)"], "ask": ["Bash(git push:*)"], "allow": ["Read"]},
          "hooks": {"PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "/opt/hooks/audit"}]}]},
          "sandbox": {"enabled": True}, "env": {"HTTPS_PROXY": "http://proxy.invalid:1"},
          "requiredMinimumVersion": "2.1.0"}


def full_config(f, **over):
    """The fleet's config with everything the Hosts, Policy, Docs and Update
    pages read: two documents and one in a second group, a deployed policy that differs from the source
    in one setting, and one harmless action."""
    docs = os.path.join(f.root, "docs")
    os.makedirs(os.path.join(docs, "sub"), exist_ok=True)
    other = "# The other page\n\nBack to [the guide](../Guide.md), on to [the goal](../../GOAL.md).\n"
    for name, text in (("Guide.md", GUIDE), ("sub/Other.md", other)):
        with open(os.path.join(docs, name), "w") as fh:
            fh.write(text)
    goal = os.path.join(f.root, "GOAL.md")
    with open(goal, "w") as fh:
        fh.write("# The goal\n")
    deployed, source = os.path.join(f.root, "deployed.json"), os.path.join(f.root, "source.json")
    with open(source, "w") as fh:
        # laid out on lines, as a repository's file is: a draft is written into the text
        fh.write(json.dumps(POLICY, indent=2) + "\n")
    with open(deployed, "w") as fh:
        json.dump(dict(POLICY, sandbox={"enabled": False}), fh)
    cfg = dict(docs=[{"label": "Guides", "path": docs}, {"label": "Goal", "path": goal}], policy={"deployed": deployed, "source": source},
               actions=[{"id": "say-hello", "label": "Say hello", "about": "Prints one line and changes nothing.",
                         "argv": [PY, "-c", "print('hello from the action')"], "cwd": "", "timeout_s": 20}])
    cfg.update(over)
    return f.config(**cfg)


class Server(object):
    """`fleetdash serve` in its own process. The URL with the token is the
    one line it prints to stderr; the token is read from there, as a person would."""

    def __init__(self, config):
        self.proc = subprocess.Popen([PY, "-m", "fleetdash", "-c", config, "serve"], cwd=ROOT,
                                     stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        ready, _, _ = select.select([self.proc.stderr], [], [], START_TIMEOUT)
        line = self.proc.stderr.readline().decode() if ready else ""
        if "http://" not in line:
            self.stop()
            raise AssertionError("serve printed no URL within %ds: %r" % (START_TIMEOUT, line))
        self.url = line[line.index("http://"):].strip()
        self.base, _, self.token = self.url.partition("/#token=")

    def get(self, path, headers=None, auth=True):
        hdrs = dict(headers or {})
        if auth:
            hdrs.setdefault("X-Fleetdash-Token", self.token)
        req = urllib.request.Request(self.base + path, headers=hdrs)
        opener = urllib.request.build_opener(_NoRedirect)
        try:
            with opener.open(req, timeout=10) as r:
                return r.status, r.headers, r.read()
        except urllib.error.HTTPError as e:
            return e.code, e.headers, e.read()

    def post(self, path, obj, headers=None):
        hdrs = {"X-Fleetdash-Token": self.token, "Content-Type": "application/json"}
        hdrs.update(headers or {})
        req = urllib.request.Request(self.base + path, data=json.dumps(obj).encode(), headers=hdrs, method="POST")
        try:
            with urllib.request.urlopen(req, timeout=60) as r:
                return r.status, json.loads(r.read().decode())
        except urllib.error.HTTPError as e:
            return e.code, json.loads(e.read().decode())

    def run(self, action):
        """Starts a configured action and follows it to its end, as the page
        does: the run as last reported, with everything it printed."""
        key = self.json("/api/actions")["run_key"]
        status, out = self.post("/api/run", {"id": action}, {"X-Fleetdash-Run": key})
        if status != 200:
            raise AssertionError("starting %s answered %d: %r" % (action, status, out))
        text, offset, deadline = "", 0, time.time() + START_TIMEOUT
        while time.time() < deadline:
            chunk = self.json("/api/run?id=%d&offset=%d" % (out["run"], offset))
            text, offset = text + chunk["output"], chunk["next"]
            # ended, and the server is free to start the next one
            if not chunk["more"] and not self.json("/api/actions")["busy"]:
                return dict(chunk["run"], output=text)
        raise AssertionError("run %d of %s did not end" % (out["run"], action))

    def json(self, path):
        status, _, body = self.get(path)
        if status != 200:
            raise AssertionError("%s answered %d: %r" % (path, status, body[:200]))
        return json.loads(body.decode())

    def stop(self):
        if self.proc.poll() is None:
            self.proc.terminate()
            try:
                self.proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.proc.kill()
                self.proc.wait()
        self.proc.stderr.close()


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args):
        return None


# The browser ----------------------------------------------------------------

def browser():
    """The headless browser to drive, or SkipTest only when the operator said
    so with FLEETDASH_BROWSER=none. A missing browser otherwise fails: a
    browser suite that silently ran nothing would read as a pass."""
    named = os.environ.get("FLEETDASH_BROWSER", "")
    if named == "none":
        raise unittest.SkipTest("FLEETDASH_BROWSER=none: browser tests not run")
    for cand in ([named] if named else ["google-chrome", "chromium", "chromium-browser"]):
        path = shutil.which(cand)
        if path:
            return path
    raise AssertionError("no headless browser found (tried %s); install Chrome or Chromium, "
                         "point FLEETDASH_BROWSER at one, or set it to none to skip on purpose"
                         % (named or "google-chrome, chromium, chromium-browser"))


def render(url, budget_ms=5000):
    """The DOM after the page's scripts and fetches have run."""
    exe = browser()
    profile = tempfile.mkdtemp(prefix="fleetdash-browser-")
    args = [exe, "--headless=new", "--disable-gpu", "--no-first-run", "--disable-extensions",
            # without it Chrome waits ~25 s on a desktop keyring over D-Bus
            "--password-store=basic",
            # a new profile otherwise fetches component updates and field trials: a run talks to loopback only
            "--disable-background-networking", "--disable-component-update", "--disable-sync", "--no-pings",
            "--disable-default-apps", "--disable-domain-reliability",
            "--user-data-dir=" + profile, "--virtual-time-budget=%d" % budget_ms, "--dump-dom", url]
    if os.geteuid() == 0:
        args.insert(1, "--no-sandbox")  # Chrome refuses to sandbox as root (the CI container)
    try:
        p = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=60)
    finally:
        shutil.rmtree(profile, ignore_errors=True)
    if p.returncode != 0:
        raise AssertionError("browser exited %d: %s" % (p.returncode, p.stderr.decode()[-500:]))
    return Page(p.stdout.decode())


class Page(html.parser.HTMLParser):
    """What a test asserts on: <main>'s attributes, its headline, its text,
    and the side navigation."""

    def __init__(self, dom):
        super().__init__()
        self.dom, self.main, self.h1, self.text, self.nav = dom, {}, "", [], []
        self._in, self._depth, self._h1, self._a = None, 0, False, None
        self.feed(dom)
        self.main_text = " ".join(t.strip() for t in self.text if t.strip())

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if tag == "main":
            self.main, self._in, self._depth = a, "main", 1
        elif self._in == "main":
            self._depth += 1
        if tag == "h1" and self._in == "main":
            self._h1 = True
        if tag == "a" and "data-page" in a:
            self._a = [a["data-page"], ""]

    def handle_endtag(self, tag):
        if self._in == "main":
            self._depth -= 1
            if self._depth == 0:
                self._in = None
        if tag == "h1":
            self._h1 = False
        if tag == "a" and self._a:
            self.nav.append((self._a[0], self._a[1].strip()))
            self._a = None

    def handle_data(self, data):
        if self._in == "main":
            self.text.append(data)
        if self._h1:
            self.h1 += data
        if self._a:
            self._a[1] += data
