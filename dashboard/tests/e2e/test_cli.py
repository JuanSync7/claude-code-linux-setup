"""The CLI and server as processes: exit codes, idempotency, and every
endpoint and asset the page depends on."""
import json
import os
import re
import socket
import sqlite3
import unittest
import urllib.parse

from tests.e2e.harness import ROOT, Server, at, cli, count, free_port, full_config, populated_fleet

TABLES = ("events", "usage", "sessions", "checkpoints")


class Ingest(unittest.TestCase):
    def setUp(self):
        self.f = populated_fleet()
        self.config = self.f.config()

    def tearDown(self):
        self.f.close()

    def test_a_clean_fleet_ingests_with_exit_0_and_reports_what_it_read(self):
        rc, out, err = cli(self.config, "ingest")
        self.assertEqual(rc, 0, err)
        stats = json.loads(out)
        self.assertEqual((stats["files"], stats["bad_lines"], stats["skipped"]), (4, 0, []))
        self.assertGreater(count(self.f.store, "usage"), 0)

    def test_a_second_run_changes_nothing_and_an_append_adds_only_itself(self):
        cli(self.config, "ingest")
        before = {t: count(self.f.store, t) for t in TABLES}
        rc, out, _ = cli(self.config, "ingest")
        self.assertEqual((rc, json.loads(out)["lines"]), (0, 0))
        self.assertEqual({t: count(self.f.store, t) for t in TABLES}, before)
        self.f.hooklog("activity", "alice", [{"ts": at(2, "12:00"), "tool": "Bash", "detail": "ls"}])
        rc, out, _ = cli(self.config, "ingest")
        self.assertEqual((rc, json.loads(out)["lines"]), (0, 1))
        self.assertEqual(count(self.f.store, "events"), before["events"] + 1)

    def test_a_bad_line_is_exit_1_and_everything_else_still_lands(self):
        path = self.f.hooklog("activity", "carol", [])
        with open(path, "a") as fh:
            fh.write("not json\n")
        rc, out, _ = cli(self.config, "ingest")
        self.assertEqual(rc, 1)
        self.assertEqual(json.loads(out)["bad_lines"], 1)
        self.assertGreater(count(self.f.store, "usage"), 0)

    def test_a_bad_config_is_exit_2_with_the_reason(self):
        rc, _, err = cli(self.f.config(stroe="typo"), "ingest")
        self.assertEqual(rc, 2)
        self.assertIn("stroe", err)

    def test_a_store_from_an_older_schema_is_exit_2_and_untouched(self):
        cli(self.config, "ingest")
        con = sqlite3.connect(self.f.store)
        with con:
            con.execute("update meta set v='1' where k='schema'")
        con.close()
        size = os.path.getsize(self.f.store)
        for cmd in ("ingest", "prune", "serve"):
            rc, _, err = cli(self.config, cmd, timeout=20)
            self.assertEqual(rc, 2, cmd)
            self.assertIn("move it aside", err)
        self.assertEqual(os.path.getsize(self.f.store), size)

    def test_prune_is_exit_0_and_reports_counts_per_severity(self):
        cli(self.config, "ingest")
        rc, out, _ = cli(self.config, "prune")
        self.assertEqual(rc, 0)
        self.assertIsInstance(json.loads(out), dict)

    def test_url_prints_the_address_a_running_service_answers_on(self):
        token = os.path.join(self.f.root, "token")
        config = self.f.config(token_file=token, port=free_port())
        self.assertEqual(cli(config, "url")[0], 2)  # no server has started yet: there is no token
        srv = Server(config)
        try:
            rc, out, _ = cli(config, "url")
            self.assertEqual((rc, out.strip()), (0, srv.url))
            # the token is after the #, which no request carries: the page is all the server is asked for
            self.assertEqual(srv.get("/", auth=False)[0], 200)
            self.assertEqual(srv.json("/api/status")["host_label"], "test-host")
        finally:
            srv.stop()
        self.assertEqual(cli(self.f.config(), "url")[0], 1)  # no token file, no fixed port: nothing to print

    def test_serve_on_a_port_something_else_holds_is_exit_2_with_the_reason(self):
        with socket.socket() as held:
            held.bind(("127.0.0.1", 0))
            held.listen(1)
            rc, _, err = cli(self.f.config(port=held.getsockname()[1]), "serve", timeout=20)
        self.assertEqual(rc, 2)
        self.assertEqual(len(err.splitlines()), 1, err)  # a reason, not a traceback
        self.assertIn("cannot listen", err)

    def test_feed_sends_one_persons_usage_and_the_collector_stores_it(self):
        spool = os.path.join(self.f.root, "spool")
        os.mkdir(spool)
        mine = os.path.join(self.f.root, "home", "alice", ".claude", "projects")
        config = self.f.config(spool=spool, transcript_glob="", hook_log_dir="",
                               feed={"transcripts": mine, "state_dir": os.path.join(self.f.root, "feed")})
        rc, out, err = cli(config, "feed")
        self.assertEqual(rc, 0, err)
        self.assertEqual(json.loads(out)["sent"]["usage"], 3)
        self.assertEqual(len(os.listdir(spool)), 1)
        rc, out, err = cli(config, "ingest")
        self.assertEqual(rc, 0, err)
        self.assertEqual((count(self.f.store, "usage"), os.listdir(spool)), (3, []))
        rc, out, _ = cli(config, "feed")
        self.assertEqual((rc, json.loads(out)["sent"]["usage"]), (0, 0))

    def test_install_without_apply_lists_and_writes_nothing(self):
        rc, _, err = cli(self.config, "install")
        self.assertEqual(rc, 1)
        self.assertIn("install.account is not set", err)

    def test_the_store_is_owner_only(self):
        cli(self.config, "ingest")
        self.assertEqual(os.stat(self.f.store).st_mode & 0o077, 0)


class Serve(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.f = populated_fleet()
        config = full_config(cls.f)
        cli(config, "ingest")
        cls.srv = Server(config)

    @classmethod
    def tearDownClass(cls):
        cls.srv.stop()
        cls.f.close()

    def test_without_the_token_no_figure_is_served(self):
        with open(os.path.join(ROOT, "web", "app.js")) as fh:
            calls = sorted(set(re.findall(r'"(/api/[a-z.]+)', fh.read())))
        self.assertGreaterEqual(len(calls), 9, calls)
        for path in calls:
            self.assertEqual(self.srv.get(path, auth=False)[0], 403, path)

    def test_the_token_is_never_a_cookie_and_never_reaches_the_server_in_an_address(self):
        self.assertIn("/#token=", self.srv.url)
        for path in ("/", "/?token=" + self.srv.token, "/api/status"):
            _, headers, _ = self.srv.get(path)
            self.assertIsNone(headers["Set-Cookie"], path)
        self.assertEqual(self.srv.get("/api/status?token=" + self.srv.token, auth=False)[0], 403)
        self.assertEqual(self.srv.get("/api/status", headers={"Cookie": "fleetdash=" + self.srv.token},
                                      auth=False)[0], 403)

    def test_every_asset_the_page_links_is_served_with_its_type(self):
        _, _, body = self.srv.get("/")
        links = re.findall(r'(?:href|src)="([^"#:]+)"', body.decode())
        self.assertGreaterEqual(len(links), 3, links)  # css, js, icon at least
        for link in links:
            status, headers, _ = self.srv.get("/" + link)
            self.assertEqual(status, 200, link)
            self.assertNotIn("octet", headers["Content-Type"], link)

    def test_every_api_the_page_calls_exists_and_answers_json(self):
        with open(os.path.join(ROOT, "web", "app.js")) as fh:
            calls = sorted(set(re.findall(r'"(/api/[a-z]+)', fh.read())))
        self.assertGreaterEqual(len(calls), 9, calls)
        # the one call that is about a thing: ask for a thing the listing names
        first = self.srv.json("/api/docs")["groups"][0]["docs"][0]["id"]
        args = {"/api/doc": "?id=" + urllib.parse.quote(first), "/api/run": None}
        for path in calls:
            if args.get(path, "") is not None:
                self.assertIsInstance(self.srv.json(path + args.get(path, "")), dict, path)
        self.assertIn("/api/run", calls)  # covered below: it is not a GET

    def test_a_configured_action_runs_from_a_logged_in_page_and_is_recorded(self):
        listing = self.srv.json("/api/actions")
        self.assertEqual([a["id"] for a in listing["actions"]], ["say-hello"])
        before = count(self.f.store, "runs")
        status, out = self.srv.post("/api/run", {"id": "say-hello"}, {"X-Fleetdash-Run": listing["run_key"]})
        self.assertEqual((status, out["exit_code"], out["output"]), (200, 0, "hello from the action\n"))
        self.assertEqual(count(self.f.store, "runs"), before + 1)
        self.assertEqual(self.srv.json("/api/actions")["actions"][0]["last"]["exit_code"], 0)

    def test_an_action_is_not_started_without_the_pages_key_or_the_login(self):
        before = count(self.f.store, "runs")
        self.assertEqual(self.srv.post("/api/run", {"id": "say-hello"})[0], 403)
        key = self.srv.json("/api/actions")["run_key"]
        self.assertEqual(self.srv.post("/api/run", {"id": "say-hello"},
                                       {"X-Fleetdash-Run": key, "X-Fleetdash-Token": "wrong"})[0], 403)
        self.assertEqual(self.srv.post("/api/run", {"id": "say-hello"},
                                       {"X-Fleetdash-Run": key, "Origin": "http://evil.example"})[0], 403)
        self.assertEqual(count(self.f.store, "runs"), before)

    def test_the_host_the_policy_and_the_documents_come_back(self):
        h = self.srv.json("/api/hosts")
        self.assertEqual([(r["host"], r["policy"], r["stale"]) for r in h["rows"]], [("test-host", "differs", False)])
        p = self.srv.json("/api/policy")
        self.assertEqual((p["same"], p["differs"]), (False, ["sandbox"]))
        self.assertEqual([d["title"] for d in self.srv.json("/api/docs")["groups"][0]["docs"]],
                         ["Operator guide", "The other page"])

    def test_every_response_carries_the_security_headers(self):
        for path in ("/", "/app.js", "/api/overview"):
            _, headers, _ = self.srv.get(path)
            self.assertIn("default-src 'self'", headers["Content-Security-Policy"], path)
            self.assertEqual(headers["X-Content-Type-Options"], "nosniff", path)

    def test_the_data_the_fleet_holds_comes_back(self):
        o = self.srv.json("/api/overview?days=3650")
        self.assertEqual(sorted(u["user"] for u in o["by_user"]), ["alice", "bob"])
        self.assertEqual({p["provider"] for p in o["by_provider"]}, {"anthropic", "bedrock"})
        self.assertEqual(o["blocks"], [{"source": "Blocked by rule", "count": 1}])
        p = self.srv.json("/api/people?days=3650")
        self.assertEqual({r["user"]: r["five_hour"] for r in p["rows"]}, {"alice": 1, "bob": 0})


if __name__ == "__main__":
    unittest.main()
