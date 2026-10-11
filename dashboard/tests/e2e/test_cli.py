"""The CLI and server as processes: exit codes, idempotency, and every
endpoint and asset the page depends on."""
import json
import os
import re
import sqlite3
import unittest

from tests.e2e.harness import ROOT, Server, at, cli, count, populated_fleet

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

    def test_the_store_is_owner_only(self):
        cli(self.config, "ingest")
        self.assertEqual(os.stat(self.f.store).st_mode & 0o077, 0)


class Serve(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.f = populated_fleet()
        config = cls.f.config()
        cli(config, "ingest")
        cls.srv = Server(config)

    @classmethod
    def tearDownClass(cls):
        cls.srv.stop()
        cls.f.close()

    def test_without_the_token_nothing_is_served(self):
        for path in ("/", "/app.js", "/api/overview"):
            self.assertEqual(self.srv.get(path, auth=False)[0], 403, path)

    def test_the_printed_url_logs_in_with_a_cookie_and_keeps_no_token_in_the_address(self):
        status, headers, _ = self.srv.get("/?token=" + self.srv.token, auth=False)
        self.assertEqual((status, headers["Location"]), (303, "/"))
        cookie = headers["Set-Cookie"].split(";")[0]
        self.assertEqual(self.srv.get("/", headers={"Cookie": cookie}, auth=False)[0], 200)

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
        self.assertGreaterEqual(len(calls), 4, calls)
        for path in calls:
            self.assertIsInstance(self.srv.json(path), dict, path)

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
