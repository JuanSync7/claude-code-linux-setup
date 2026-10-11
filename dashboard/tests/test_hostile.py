"""What one person can leave where the collector reads, and what a client can
send the server: none of it may stop a run for everybody else, break a page,
or reach further than its own rows."""
import datetime
import io
import json
import os
import pwd
import socket
import sqlite3
import sys
import threading
import unittest
from unittest import mock
import urllib.error
import urllib.request

from fleetdash import api
from fleetdash import config as cfgmod
from fleetdash import docs, ingest, install, server, spool, store
from tests.fixtures import Fleet, assistant, usage

ME = pwd.getpwuid(os.geteuid()).pw_name
TS = "2026-10-01T10:00:00Z"
NOW = datetime.datetime(2026, 10, 2)


def rows(db, sql, *args):
    con = sqlite3.connect(db)
    try:
        return con.execute(sql, args).fetchall()
    finally:
        con.close()


def head(**over):
    h = {"t": "batch", "v": 1, "host": "host-a", "user": ME, "ts": TS, "claude_version": None,
         "policy_sha256": None}
    h.update(over)
    return h


def usage_row(msg="good", **over):
    d = {"t": "usage", "id": msg, "ts": TS, "session": "s", "model": "claude-opus-5-5",
         "input": 1, "output": 2, "cache_read": 3, "cache_write": 4}
    d.update(over)
    return d


class PoisonInTheSpool(unittest.TestCase):
    """Each case leaves one hostile thing in the spool, sorted before a good
    batch. The good batch must still be stored: a pass that read nothing after
    the poison would be the collector stopped for everyone."""

    def setUp(self):
        self.f = Fleet()
        self.spool = os.path.join(self.f.root, "spool")
        os.mkdir(self.spool, 0o700)
        self.cfg = cfgmod.load(self.f.config(spool=self.spool, transcript_glob="", hook_log_dir="",
                                             host_label="collector", verify_file_owner=True))
        self.db = self.cfg["store"]

    def tearDown(self):
        for d, dirs, files in os.walk(self.f.root):
            for n in dirs + files:
                if not os.path.islink(os.path.join(d, n)):
                    os.chmod(os.path.join(d, n), 0o700)
        self.f.close()

    def batch(self, name, lines):
        path = os.path.join(self.spool, name)
        with open(path, "wb") as fh:
            for line in lines:
                fh.write((line if isinstance(line, bytes) else json.dumps(line).encode()) + b"\n")
        return path

    def good(self):
        self.batch("z-good.jsonl", [head(), usage_row()])

    def stored(self):
        return [r[0] for r in rows(self.db, "select id from usage order by id")]

    def test_a_directory_named_like_a_batch_is_refused_and_the_next_batch_is_read(self):
        os.mkdir(os.path.join(self.spool, "a.jsonl"))
        self.good()
        stats = ingest.run(self.cfg)
        self.assertEqual([why for _p, why in stats["skipped"]], ["not a regular file"])
        self.assertEqual(self.stored(), ["good"])

    def test_a_count_no_message_could_hold_is_a_bad_record_not_a_stopped_run(self):
        self.batch("a.jsonl", [head(), usage_row("huge", input=2 ** 63), usage_row("big", output=ingest.COUNT_MAX + 1),
                               usage_row("edge", output=ingest.COUNT_MAX)])
        self.good()
        stats = ingest.run(self.cfg)
        self.assertEqual(stats["bad_lines"], 2)
        self.assertEqual(self.stored(), ["edge", "good"])

    def test_text_that_cannot_be_stored_is_a_bad_record(self):
        # a lone surrogate is valid JSON and is not valid UTF-8
        self.batch("a.jsonl", [head(), b'{"t":"usage","id":"\\ud800","ts":"%s","session":"s","model":"m",'
                               b'"input":1,"output":1,"cache_read":1,"cache_write":1}' % TS.encode(),
                               usage_row("after")])
        self.good()
        stats = ingest.run(self.cfg)
        self.assertEqual(stats["bad_lines"], 1)
        self.assertEqual(self.stored(), ["after", "good"])

    def test_a_line_nested_deeper_than_the_parser_goes_is_a_bad_record(self):
        deep = b"[" * 100000
        self.batch("a.jsonl", [head(), deep, usage_row("after")])
        self.batch("b.jsonl", [deep])
        self.good()
        stats = ingest.run(self.cfg)
        self.assertEqual(stats["bad_lines"], 1)
        self.assertEqual(len(stats["skipped"]), 1)  # b: its header is not one
        self.assertEqual(self.stored(), ["after", "good"])

    def test_a_batch_larger_than_any_feed_writes_is_refused_unread(self):
        path = self.batch("a.jsonl", [head(), usage_row("sparse")])
        with open(path, "r+b") as fh:
            fh.truncate(spool.BATCH_MAX + 1)  # sparse: no blocks are written
        self.good()
        with mock.patch.object(ingest, "complete_lines", wraps=ingest.complete_lines) as read:
            stats = ingest.run(self.cfg)
        self.assertEqual(read.call_count, 1)  # the good batch: a size that is claimed costs nothing to refuse
        self.assertEqual(len(stats["skipped"]), 1)
        self.assertEqual(self.stored(), ["good"])
        self.assertEqual(os.listdir(self.spool), [])

    def test_a_batch_that_grows_past_the_limit_while_it_is_read_is_refused_whole(self):
        # its size was within the limit when it was opened; its owner goes on
        # writing, and a reader that followed would never reach the next batch
        path = self.batch("a.jsonl", [head(), usage_row("early")])
        self.good()
        read = ingest.complete_lines

        def read_while_written(fh, offset, most):
            for n, line in enumerate(read(fh, offset, most)):
                if n == 0 and os.path.exists(path) and os.path.samestat(os.fstat(fh.fileno()), os.stat(path)):
                    with open(path, "ab") as more:
                        for i in range(200):
                            more.write(json.dumps(usage_row("late-%d" % i)).encode() + b"\n")
                yield line

        with mock.patch.object(spool, "BATCH_MAX", 4096), \
                mock.patch.object(ingest, "complete_lines", read_while_written):
            stats = ingest.run(self.cfg)
        self.assertEqual(len(stats["skipped"]), 1)
        self.assertEqual(self.stored(), ["good"])
        self.assertEqual(rows(self.db, "select user, category from events"), [(ME, "log-integrity")])
        self.assertEqual(os.listdir(self.spool), [])

    def test_a_line_that_never_ends_stops_at_the_limit(self):
        path = self.batch("a.jsonl", [head(), usage_row("early")])
        with open(path, "ab") as fh:
            fh.write(b"x" * 8192)  # no newline: its owner is still writing it
        self.good()
        with mock.patch.object(spool, "BATCH_MAX", 4096):
            os.truncate(path, 4096)
            read = ingest.complete_lines

            def read_while_written(fh, offset, most):
                if os.path.exists(path):  # gone once it has been refused
                    with open(path, "ab") as more:
                        more.write(b"x" * ingest.CHUNK * 2)
                return read(fh, offset, most)

            with mock.patch.object(ingest, "complete_lines", read_while_written):
                stats = ingest.run(self.cfg)
        self.assertEqual(len(stats["skipped"]), 1)
        self.assertEqual(self.stored(), ["good"])
        self.assertEqual(os.listdir(self.spool), [])

    @unittest.skipIf(os.geteuid() == 0, "root reads a file whatever its mode")
    def test_a_batch_nobody_can_read_is_recorded_and_removed(self):
        os.chmod(self.batch("a.jsonl", [head(), usage_row("hidden")]), 0)
        self.good()
        stats = ingest.run(self.cfg)
        self.assertEqual(len(stats["skipped"]), 1)
        self.assertEqual(rows(self.db, "select user, category from events"), [(ME, "log-integrity")])
        self.assertEqual(os.listdir(self.spool), [])
        self.assertEqual(self.stored(), ["good"])

    def test_a_version_too_long_to_order_is_not_stored(self):
        # stored, it would be turned into a number every time the Hosts page
        # is asked for, and a number that long is one Python refuses to read
        self.batch("a.jsonl", [head(claude_version="9" * 5000 + ".0.0")])
        self.batch("b.jsonl", [head(host="host-b", claude_version="2.1.0")])
        ingest.run(self.cfg)
        self.assertEqual(rows(self.db, "select host, claude_version from hosts where host like 'host-%'"),
                         [("host-b", "2.1.0")])
        said = rows(self.db, "select category, length(detail) from events")
        self.assertEqual([c for c, _ in said], ["log-integrity"])
        self.assertLess(said[0][1], 1000)
        self.assertEqual(api.hosts(self.cfg)["newest_version"], "2.1.0")

    def test_a_check_in_dated_ahead_of_now_does_not_shut_the_real_host_out(self):
        ahead = store.iso(datetime.datetime.utcnow() + datetime.timedelta(hours=20)) + "Z"
        self.batch("a.jsonl", [head(ts=ahead, claude_version="9.9.9")])
        ingest.run(self.cfg)
        seen = rows(self.db, "select last_seen from hosts where host='host-a'")[0][0]
        self.assertLessEqual(seen[:19], store.iso(datetime.datetime.utcnow()))
        # the host's own, honest check-in a moment later still lands
        later = store.iso(datetime.datetime.utcnow() + datetime.timedelta(seconds=1)) + "Z"
        self.batch("b.jsonl", [head(ts=later, claude_version="2.1.0")])
        ingest.run(self.cfg)
        self.assertEqual(rows(self.db, "select claude_version from hosts where host='host-a'"), [("2.1.0",)])


class PoisonInTheLogs(unittest.TestCase):
    def setUp(self):
        self.f = Fleet()
        self.cfg = cfgmod.load(self.f.config())
        self.db = self.cfg["store"]

    def tearDown(self):
        self.f.close()

    def test_a_directory_named_like_a_hook_log_is_refused_and_the_other_logs_are_read(self):
        self.f.hooklog("denied", "bob", [{"ts": TS, "tool": "Bash", "detail": "x", "denied_by": "rule"}])
        os.mkdir(os.path.join(self.f.root, "log", "denied", "alice.jsonl"))
        stats = ingest.run(self.cfg)
        self.assertEqual([why for _p, why in stats["skipped"]], ["not a regular file"])
        self.assertEqual(rows(self.db, "select user from events where category='denial'"), [("bob",)])

    def test_an_oversized_count_or_unstorable_text_in_a_transcript_is_a_bad_record(self):
        path = self.f.transcript("alice", "p", "s", [
            assistant("a1", "m1", TS, "claude-opus-5-5", usage(i=2 ** 63)),
            assistant("a2", "m2", TS, "claude-opus-5-5", usage(o=2 ** 64))])
        with open(path, "ab") as fh:
            fh.write(b'{"type":"assistant","uuid":"a3","timestamp":"%s","message":{"id":"\\udfff","model":"m",'
                     b'"usage":{"input_tokens":1}}}\n' % TS.encode())
            fh.write(b"[" * 100000 + b"\n")
        self.f.transcript("alice", "p", "s", [assistant("a4", "m4", TS, "claude-opus-5-5", usage())])
        self.f.transcript("bob", "p", "s", [assistant("b1", "mb", TS, "claude-opus-5-5", usage())])
        stats = ingest.run(self.cfg)
        self.assertEqual(stats["bad_lines"], 4)
        self.assertEqual(rows(self.db, "select id from usage order by id"), [("m4",), ("mb",)])

    def test_a_transcript_whose_name_is_not_text_is_skipped_not_fatal(self):
        d = os.path.join(self.f.root, "home", "alice", ".claude", "projects", "p")
        os.makedirs(d)
        with open(os.path.join(os.fsencode(d), b"\xff\xfe.jsonl"), "w") as fh:
            fh.write(json.dumps(assistant("a1", "m1", TS, "claude-opus-5-5", usage())) + "\n")
        self.f.transcript("bob", "p", "s", [assistant("b1", "mb", TS, "claude-opus-5-5", usage())])
        stats = ingest.run(self.cfg)
        self.assertEqual(len(stats["skipped"]), 1)
        self.assertEqual(rows(self.db, "select id from usage"), [("mb",)])

    def test_the_largest_counts_a_store_can_hold_still_add_up_on_every_page(self):
        self.f.transcript("alice", "p", "s", [
            assistant("a%d" % i, "m%d" % i, TS, "claude-opus-5-5",
                      usage(i=ingest.COUNT_MAX, o=ingest.COUNT_MAX, cr=ingest.COUNT_MAX, cw=ingest.COUNT_MAX))
            for i in range(50)])
        self.assertEqual(ingest.run(self.cfg)["bad_lines"], 0)
        self.assertEqual(api.overview(self.cfg, days=30, now=NOW)["by_user"][0]["tokens"], 200 * ingest.COUNT_MAX)
        self.assertEqual(api.people(self.cfg, days=30, now=NOW)["rows"][0]["tokens"], 200 * ingest.COUNT_MAX)
        self.assertIn("alice", api.people_csv(self.cfg, now=NOW))


class Client(unittest.TestCase):
    def setUp(self):
        self.f = Fleet()
        self.cfg = cfgmod.load(self.f.config(actions=[
            {"id": "ok", "label": "OK", "about": "", "cwd": "", "timeout_s": 20,
             "argv": [sys.executable, "-c", "print('ran')"]}]))
        ingest.run(self.cfg)
        self.httpd = server.make_server(self.cfg, token="t0ken")
        self.port = self.httpd.server_address[1]
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()

    def tearDown(self):
        self.httpd.shutdown()
        self.httpd.server_close()
        self.f.close()

    def call(self, method, path, body=None, **headers):
        hdrs = {"X-Fleetdash-Token": "t0ken"}
        hdrs.update({k.replace("_", "-"): v for k, v in headers.items()})
        hdrs = {k: v for k, v in hdrs.items() if v is not None}
        req = urllib.request.Request("http://127.0.0.1:%d%s" % (self.port, path), method=method, headers=hdrs,
                                     data=body)
        try:
            with urllib.request.urlopen(req, timeout=20) as r:
                return r.status, r.headers, r.read()
        except urllib.error.HTTPError as e:
            return e.code, e.headers, e.read()

    def key(self):
        return json.loads(self.call("GET", "/api/actions")[2].decode())["run_key"]

    def test_a_cookie_is_not_a_login_and_none_is_ever_set(self):
        # a browser sends a host's cookies to every port on it, so to any other
        # person's listener on this machine: the token must never be in one
        self.assertEqual(self.call("GET", "/api/overview", X_Fleetdash_Token=None, Cookie="fleetdash=t0ken")[0], 403)
        for path in ("/", "/?token=t0ken", "/api/overview", "/api/overview?token=t0ken"):
            with self.subTest(path=path):
                self.assertIsNone(self.call("GET", path)[1]["Set-Cookie"])
        self.assertEqual(self.call("GET", "/api/overview?token=t0ken", X_Fleetdash_Token=None)[0], 403)

    def test_the_page_itself_holds_no_data_and_is_served_to_anyone_on_this_host(self):
        for path in ("/", "/app.js", "/style.css"):
            with self.subTest(path=path):
                status, _, body = self.call("GET", path, X_Fleetdash_Token=None)
                self.assertEqual(status, 200)
                self.assertNotIn(b"t0ken", body)
        self.assertEqual(self.call("GET", "/", X_Fleetdash_Token=None, Host="evil.example")[0], 403)

    def test_a_run_through_a_tunnel_on_another_local_port_is_accepted(self):
        # ssh -L 9999:127.0.0.1:<port>: the browser names the port it sees
        status, _, body = self.call("POST", "/api/run", b'{"id":"ok"}', X_Fleetdash_Run=self.key(),
                                    Host="127.0.0.1:9999", Origin="http://127.0.0.1:9999")
        self.assertEqual((status, json.loads(body.decode())["exit_code"]), (200, 0))

    def test_a_run_from_a_page_on_another_port_or_site_is_refused(self):
        key = self.key()
        for origin in ("http://127.0.0.1:1", "http://localhost:%d" % self.port, "https://127.0.0.1:%d" % self.port,
                       "http://evil.example", "null"):
            with self.subTest(origin=origin):
                self.assertEqual(self.call("POST", "/api/run", b'{"id":"ok"}', X_Fleetdash_Run=key,
                                           Origin=origin)[0], 403)
        self.assertEqual(rows(self.cfg["store"], "select count(*) from runs"), [(0,)])

    def test_a_body_nested_past_the_parser_or_a_length_that_is_not_a_number_is_a_400(self):
        key = self.key()
        self.assertEqual(self.call("POST", "/api/run", b"[" * 1024, X_Fleetdash_Run=key)[0], 400)
        s = socket.create_connection(("127.0.0.1", self.port), timeout=10)
        try:
            s.sendall(("POST /api/run HTTP/1.1\r\nHost: 127.0.0.1:%d\r\nX-Fleetdash-Token: t0ken\r\n"
                       "X-Fleetdash-Run: %s\r\nContent-Length: 1_1\r\n\r\n" % (self.port, key)).encode()
                      + b'{"id":"ok"}')
            self.assertIn(b" 400 ", s.recv(4096).split(b"\r\n")[0])
        finally:
            s.close()
        self.assertEqual(rows(self.cfg["store"], "select count(*) from runs"), [(0,)])

    def test_a_connection_that_sends_nothing_is_closed_after_the_time_limit(self):
        real = server.REQUEST_TIMEOUT
        self.assertGreater(real, 0)
        server.REQUEST_TIMEOUT = 0.5
        try:
            httpd = server.make_server(self.cfg, token="t0ken")
        finally:
            server.REQUEST_TIMEOUT = real
        threading.Thread(target=httpd.serve_forever, daemon=True).start()
        s = socket.create_connection(("127.0.0.1", httpd.server_address[1]), timeout=10)
        try:
            self.assertEqual(s.recv(1), b"")  # closed by the server, not held open
        finally:
            s.close()
            httpd.shutdown()
            httpd.server_close()

    def test_a_query_the_store_cannot_answer_is_a_500_that_says_so(self):
        con = sqlite3.connect(self.cfg["store"])
        with con:
            for i in range(2):
                con.execute("insert into usage values (?,?,?,?,?,?,?,?,?)",
                            ("x%d" % i, store.iso(datetime.datetime.utcnow()) + "Z", "eve", "s", "m", 2 ** 62, 0, 0, 0))
        con.close()
        status, _, body = self.call("GET", "/api/overview")
        self.assertEqual(status, 500)
        self.assertIn("error", json.loads(body.decode()))
        self.assertEqual(self.call("GET", "/api/status")[0], 200)


class Bind(unittest.TestCase):
    def test_an_address_the_server_cannot_listen_on_is_refused_in_the_config(self):
        f = Fleet()
        self.addCleanup(f.close)
        with self.assertRaises(cfgmod.ConfigError):
            cfgmod.load(f.config(bind="::1"))


class Token(unittest.TestCase):
    def test_a_token_file_is_never_seen_half_written(self):
        f = Fleet()
        self.addCleanup(f.close)
        cfg = cfgmod.load(f.config(token_file=os.path.join(f.root, "token")))
        real = server.secrets.token_urlsafe

        def dies(n):
            raise RuntimeError("stopped while making the token")
        server.secrets.token_urlsafe = dies
        try:
            with self.assertRaises(RuntimeError):
                server.login_token(cfg)
        finally:
            server.secrets.token_urlsafe = real
        # the start that was interrupted left nothing a later start trips over
        self.assertEqual(server.login_token(cfg), server.read_token(cfg))
        self.assertEqual(os.listdir(f.root).count("token"), 1)
        self.assertEqual([n for n in os.listdir(f.root) if n.startswith(".token")], [])


class Report(unittest.TestCase):
    def test_a_cell_starting_with_a_tab_or_a_return_is_not_run_by_a_spreadsheet(self):
        for lead in ("=", "+", "-", "@", "\t", "\r"):
            with self.subTest(lead=lead):
                self.assertEqual(api._cell(lead + "cmd"), "'" + lead + "cmd")
        self.assertEqual(api._cell("plain"), "plain")


class PolicyFile(unittest.TestCase):
    def setUp(self):
        self.f = Fleet()
        self.path = os.path.join(self.f.root, "policy.json")

    def tearDown(self):
        self.f.close()

    def state(self, raw):
        with open(self.path, "wb") as fh:
            fh.write(raw)
        return api._policy_file(self.path)["state"]

    def test_rules_that_are_not_a_list_are_unreadable_not_no_rules(self):
        self.assertEqual(self.state(b'{"permissions": {"deny": ["Bash(sudo:*)"]}}'), "ok")
        self.assertEqual(self.state(b'{"permissions": {"deny": "Bash(sudo:*)"}}'), "unreadable")
        self.assertEqual(self.state(b'{"permissions": ["deny"]}'), "unreadable")

    def test_a_policy_nested_past_the_parser_is_unreadable(self):
        self.assertEqual(self.state(b"[" * 100000), "unreadable")


class Documents(unittest.TestCase):
    def setUp(self):
        self.f = Fleet()
        self.dir = os.path.join(self.f.root, "docs")
        os.mkdir(self.dir)
        with open(os.path.join(self.dir, "A.md"), "w") as fh:
            fh.write("# Alpha\n")
        self.cfg = cfgmod.load(self.f.config(docs=[{"label": "Guides", "path": self.dir}]))

    def tearDown(self):
        self.f.close()

    def test_only_a_regular_file_is_listed_so_a_link_or_a_pipe_is_never_opened(self):
        secret = os.path.join(self.f.root, "secret.md")
        with open(secret, "w") as fh:
            fh.write("# Secret title\n")
        os.symlink(secret, os.path.join(self.dir, "link.md"))
        os.mkfifo(os.path.join(self.dir, "pipe.md"))  # opening it would block for ever
        done = []
        t = threading.Thread(target=lambda: done.append(docs.index(self.cfg)), daemon=True)
        t.start()
        t.join(10)
        self.assertTrue(done, "the listing blocked")
        self.assertEqual([d["title"] for d in done[0]["groups"][0]["docs"]], ["Alpha"])
        for name in ("link.md", "pipe.md"):
            with self.assertRaises(ValueError):
                docs.read(self.cfg, "0:" + name)


class Installer(unittest.TestCase):
    def setUp(self):
        self.f = Fleet()
        self.t = self.f.root
        self.stage = os.path.join(self.t, "stage")

    def tearDown(self):
        self.f.close()

    def config(self, **table_over):
        t = self.t
        table = {"account": ME, "python": sys.executable, "code_dir": t + "/code",
                 "config_file": t + "/etc/config.json", "units_dir": t + "/units",
                 "ingest_interval": "5min", "prune_calendar": "daily"}
        table.update(table_over)
        return self.f.config(port=8765, token_file=t + "/var/token", store=t + "/var/store.db",
                             spool=t + "/spool", install=table)

    def run_install(self, path, apply=True):
        out, err = io.StringIO(), io.StringIO()
        rc = install.main(cfgmod.load(path), path, apply=apply, root=self.stage,
                          systemctl=lambda *a: 0, out=out, err=err)
        return rc, out.getvalue(), err.getvalue()

    def test_a_link_where_a_directory_belongs_is_refused_and_nothing_is_written_through_it(self):
        elsewhere = os.path.join(self.t, "elsewhere")
        os.mkdir(elsewhere, 0o755)
        os.makedirs(self.stage + self.t)
        os.symlink(elsewhere, self.stage + self.t + "/spool")
        rc, _, err = self.run_install(self.config())
        self.assertEqual(rc, 1)
        self.assertIn("/spool", err)
        self.assertEqual(os.stat(elsewhere).st_mode & 0o7777, 0o755)
        self.assertEqual(os.listdir(elsewhere), [])
        self.assertFalse(os.path.exists(self.stage + self.t + "/code"))  # refused before anything was placed

    def test_a_link_left_where_a_file_is_written_is_replaced_not_written_through(self):
        victim = os.path.join(self.t, "victim")
        with open(victim, "w") as fh:
            fh.write("untouched")
        os.makedirs(self.stage + self.t + "/units")
        os.symlink(victim, self.stage + self.t + "/units/fleetdash-serve.service.new")
        path = self.config()
        self.assertEqual(self.run_install(path)[0], 0)
        with open(victim) as fh:
            self.assertEqual(fh.read(), "untouched")
        self.assertEqual(self.run_install(path, apply=False)[0], 0)  # and the host now matches

    def test_a_link_put_back_as_the_file_is_opened_is_not_written_through(self):
        # the other account wins the race: the stale name is cleared, and the
        # link is back before the installer opens it
        victim = os.path.join(self.f.root, "victim")
        with open(victim, "w") as fh:
            fh.write("untouched")
        os.makedirs(self.stage + "/units")
        target = "/units/fleetdash-serve.service"
        clear = os.unlink

        def cleared_then_put_back(path):
            clear(path)
            os.symlink(victim, path)

        os.symlink(victim, self.stage + target + ".new")
        with mock.patch.object(install.os, "unlink", cleared_then_put_back):
            with self.assertRaises(FileExistsError):
                install._place(("file", target, 0o644, False, b"[Unit]\n"), "nobody", self.stage)
        with open(victim) as fh:
            self.assertEqual(fh.read(), "untouched")
        self.assertFalse(os.path.lexists(self.stage + target))

    def test_a_value_that_would_add_a_line_or_a_word_to_a_unit_is_refused(self):
        for over in ({"account": "svc\nUser=root"}, {"code_dir": self.t + "/co de"},
                     {"ingest_interval": "5min\nOnCalendar=minutely"}, {"prune_calendar": "daily\nUnit=x.service"},
                     {"python": "/usr/bin/python3 -c"}):
            with self.subTest(over=over):
                rc, _, err = self.run_install(self.config(**over))
                self.assertEqual(rc, 1, err)
        self.assertFalse(os.path.exists(self.stage))


if __name__ == "__main__":
    unittest.main()
