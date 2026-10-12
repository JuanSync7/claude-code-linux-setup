"""Hosts, Policy, Docs, the People report, the Admin page's enrolment and
retention, and the one thing that is not
read-only: starting a configured action."""
import datetime
import hashlib
import json
import os
import sqlite3
import sys
import threading
import time
import unittest
import urllib.error
import urllib.request

from fleetdash import actions, api, docs, ingest, server, store
from fleetdash import config as cfgmod
from fleetdash.vocab import PERSON_STATES, SEVERITIES
from tests.fixtures import Fleet, admin_line, assistant, usage

NOW = datetime.datetime(2026, 10, 10, 12)


def sha(text):
    return hashlib.sha256(text.encode()).hexdigest()


class Hosts(unittest.TestCase):
    def setUp(self):
        self.f = Fleet()
        self.source = os.path.join(self.f.root, "source.json")
        with open(self.source, "w") as fh:
            fh.write('{"a": 1}')
        self.cfg = cfgmod.load(self.f.config(policy={"deployed": "", "source": self.source}))
        con = store.connect(self.cfg)
        with con:
            for host, ts, version, policy in (
                    ("current", "2026-10-10T11:00:00Z", "2.1.10", sha('{"a": 1}')),
                    ("differs", "2026-10-10T11:00:00Z", "2.1.9", sha('{"a": 2}')),
                    ("silent", "2026-10-01T11:00:00Z", None, None)):
                ingest.record_checkin(con, {"host": host, "ts": ts, "claude_version": version,
                                            "policy_sha256": policy}, "alice")
            con.execute(*ingest.event("k1", "2026-10-10T10:00:00Z", "alice", "", "deny", "denial", "r", "Bash", "", "current"))
        con.close()
        self.rows = {r["host"]: r for r in api.hosts(self.cfg, now=NOW)["rows"]}

    def tearDown(self):
        self.f.close()

    def test_a_host_holding_another_policy_is_shown_as_differing(self):
        self.assertEqual({h: r["policy"] for h, r in self.rows.items()},
                         {"current": "current", "differs": "differs", "silent": "unknown"})

    def test_a_host_that_stopped_checking_in_is_stale_not_gone(self):
        self.assertEqual({h: r["stale"] for h, r in self.rows.items()},
                         {"current": False, "differs": False, "silent": True})
        self.assertEqual(api.overview(self.cfg, now=NOW)["hosts"], {"count": 3, "stale": 1})

    def test_versions_compare_as_numbers_and_unknown_is_not_behind(self):
        # as text, 2.1.9 sorts after 2.1.10
        self.assertEqual(api.hosts(self.cfg, now=NOW)["newest_version"], "2.1.10")
        self.assertEqual({h: r["version_behind"] for h, r in self.rows.items()},
                         {"current": False, "differs": True, "silent": False})

    def test_with_no_source_policy_every_host_is_unknown_not_current(self):
        cfg = dict(self.cfg, policy={"deployed": "", "source": ""})
        self.assertEqual({r["policy"] for r in api.hosts(cfg, now=NOW)["rows"]}, {"unknown"})

    def test_events_are_counted_for_the_host_that_logged_them(self):
        self.assertEqual(self.rows["current"]["events"]["deny"], 1)
        self.assertEqual(self.rows["differs"]["events"]["deny"], 0)

    def test_an_ingest_checks_its_own_host_in_with_the_policy_it_holds(self):
        deployed = os.path.join(self.f.root, "deployed.json")
        with open(deployed, "w") as fh:
            fh.write('{"a": 1}')
        fake = os.path.join(self.f.root, "claude")
        with open(fake, "w") as fh:
            fh.write("#!/bin/sh\necho '2.3.4 (Claude Code)'\n")
        os.chmod(fake, 0o700)
        cfg = dict(self.cfg, policy={"deployed": deployed, "source": self.source}, claude_bin=fake)
        ingest.run(cfg)
        me = {r["host"]: r for r in api.hosts(cfg)["rows"]}["test-host"]
        self.assertEqual((me["claude_version"], me["policy"], me["stale"]), ("2.3.4", "current", False))

    def test_a_version_that_cannot_be_read_is_unknown(self):
        self.assertIsNone(ingest.claude_version(os.path.join(self.f.root, "no-such-binary")))
        self.assertIsNone(ingest.claude_version("/bin/false"))
        self.assertIsNone(ingest.claude_version("/bin/true"))
        self.assertIsNone(ingest.claude_version(""))


class Policy(unittest.TestCase):
    def setUp(self):
        self.f = Fleet()
        self.dep = os.path.join(self.f.root, "deployed.json")
        self.src = os.path.join(self.f.root, "source.json")
        self.doc = {"permissions": {"deny": ["Bash(sudo:*)"], "allow": ["Read"]},
                    "hooks": {"PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "/x/audit"}]}]},
                    "sandbox": {"enabled": True}, "env": {"HTTPS_PROXY": "http://proxy.invalid:1"},
                    "requiredMinimumVersion": "2.1.0"}
        self.cfg = cfgmod.load(self.f.config(policy={"deployed": self.dep, "source": self.src}))

    def tearDown(self):
        self.f.close()

    def write(self, path, doc):
        with open(path, "w") as fh:
            json.dump(doc, fh)

    def test_the_rules_hooks_and_sandbox_are_read_out(self):
        self.write(self.dep, self.doc)
        self.write(self.src, self.doc)
        p = api.policy(self.cfg)
        d = p["deployed"]
        self.assertEqual((p["same"], p["differs"]), (True, []))
        self.assertEqual(d["rules"], {"deny": ["Bash(sudo:*)"], "ask": [], "allow": ["Read"]})
        self.assertEqual(d["hooks"], [{"event": "PreToolUse", "matcher": "Bash", "command": "/x/audit"}])
        self.assertEqual((d["sandbox"], d["minimum_version"]), (True, "2.1.0"))

    def test_an_env_value_is_never_returned_only_its_name(self):
        self.write(self.dep, self.doc)
        self.assertEqual(api.policy(self.cfg)["deployed"]["env"], ["HTTPS_PROXY"])
        self.assertNotIn("proxy.invalid", json.dumps(api.policy(self.cfg)))

    def test_a_deployed_policy_that_differs_names_the_sections_that_differ(self):
        self.write(self.src, self.doc)
        self.write(self.dep, dict(self.doc, sandbox={"enabled": False}, extra=1))
        p = api.policy(self.cfg)
        self.assertEqual((p["same"], p["differs"]), (False, ["extra", "sandbox"]))

    def test_missing_unreadable_and_not_configured_are_three_different_answers(self):
        self.assertEqual(api.policy(self.cfg)["deployed"]["state"], "missing")
        with open(self.dep, "w") as fh:
            fh.write("{not json")
        p = api.policy(dict(self.cfg, policy={"deployed": self.dep, "source": ""}))
        self.assertEqual((p["deployed"]["state"], p["source"]["state"], p["same"]),
                         ("unreadable", "not-configured", None))

    def test_a_policy_of_the_wrong_shape_does_not_crash_the_page(self):
        self.write(self.dep, {"hooks": {"X": "y", "Y": [1, {"hooks": [2]}]}, "sandbox": 3, "env": []})
        d = api.policy(self.cfg)["deployed"]
        self.assertEqual((d["state"], d["hooks"], d["sandbox"], d["env"]), ("ok", [], None, []))


class Docs(unittest.TestCase):
    def setUp(self):
        self.f = Fleet()
        self.dir = os.path.join(self.f.root, "docs")
        os.makedirs(os.path.join(self.dir, "sub"))
        for name, text in (("B.md", "# Second\n\nbody"), ("A.md", "no heading"), ("sub/C.md", "# Third"),
                           ("notes.txt", "not a document")):
            with open(os.path.join(self.dir, name), "w") as fh:
                fh.write(text)
        self.single = os.path.join(self.f.root, "GOAL.md")
        with open(self.single, "w") as fh:
            fh.write("# The goal\n")
        self.secret = os.path.join(self.f.root, "secret.md")
        with open(self.secret, "w") as fh:
            fh.write("# Secret\n")
        self.cfg = cfgmod.load(self.f.config(docs=[{"label": "Guides", "path": self.dir},
                                                   {"label": "Goal", "path": self.single},
                                                   {"label": "Gone", "path": os.path.join(self.f.root, "nope")}]))

    def tearDown(self):
        self.f.close()

    def test_every_markdown_file_is_listed_with_the_title_it_gives_itself(self):
        g = docs.index(self.cfg)["groups"]
        self.assertEqual([(d["id"], d["title"]) for d in g[0]["docs"]],
                         [("0:A.md", "A.md"), ("0:B.md", "Second"), ("0:sub/C.md", "Third")])
        self.assertEqual([(d["id"], d["title"]) for d in g[1]["docs"]], [("1:GOAL.md", "The goal")])

    def test_each_document_says_where_it_is_so_a_link_between_groups_can_be_followed(self):
        g = docs.index(self.cfg)["groups"]
        self.assertEqual(g[1]["docs"][0]["path"], self.single)
        self.assertEqual(docs.read(self.cfg, "0:sub/C.md")["path"], os.path.join(self.dir, "sub", "C.md"))

    def test_a_directory_that_is_not_there_is_said_so(self):
        g = docs.index(self.cfg)["groups"]
        self.assertEqual([(x["label"], x["found"], len(x["docs"])) for x in g],
                         [("Guides", True, 3), ("Goal", True, 1), ("Gone", False, 0)])

    def test_every_listed_document_opens(self):
        n = 0
        for g in docs.index(self.cfg)["groups"]:
            for d in g["docs"]:
                self.assertIn("markdown", docs.read(self.cfg, d["id"]))
                n += 1
        self.assertEqual(n, 4)

    def test_only_a_listed_document_can_be_asked_for(self):
        for bad in ("0:../secret.md", "0:notes.txt", "9:A.md", "A.md", "", "0:" + self.secret, "1:../secret.md"):
            with self.subTest(id=bad):
                with self.assertRaises(ValueError):
                    docs.read(self.cfg, bad)

    def test_a_listed_link_out_of_the_directory_is_not_followed(self):
        os.symlink(self.secret, os.path.join(self.dir, "link.md"))
        with self.assertRaises(ValueError):
            docs.read(self.cfg, "0:link.md")

    def test_an_oversized_document_is_refused(self):
        with open(os.path.join(self.dir, "big.md"), "w") as fh:
            fh.write("x" * (docs.DOC_MAX + 1))
        with self.assertRaises(ValueError):
            docs.read(self.cfg, "0:big.md")


class PeopleReport(unittest.TestCase):
    def setUp(self):
        self.f = Fleet()
        self.f.transcript("alice", "p", "s1", [assistant("a1", "m1", "2026-10-09T10:00:00Z", "claude-opus-5-5",
                                                         usage(i=1000000, o=0, cr=0, cw=0))])
        self.f.transcript("=cmd", "p", "s2", [assistant("b1", "m2", "2026-10-09T10:00:00Z", "claude-mystery-1",
                                                        usage())])
        self.cfg = cfgmod.load(self.f.config())
        ingest.run(self.cfg)

    def tearDown(self):
        self.f.close()

    def test_the_frame_around_every_page_is_told_which_site_and_how_fresh(self):
        s = api.status(self.cfg)
        self.assertEqual(s["host_label"], "test-host")
        self.assertEqual(s["last_ingest"], api.overview(self.cfg, now=NOW)["last_ingest"])
        self.assertTrue(s["last_ingest"])
        empty = Fleet()
        self.addCleanup(empty.close)
        self.assertIsNone(api.status(cfgmod.load(empty.config()))["last_ingest"])

    def test_a_persons_cost_uses_the_price_table_and_is_unknown_with_an_unpriced_model(self):
        rows = {r["user"]: r for r in api.people(self.cfg, now=NOW)["rows"]}
        self.assertEqual(rows["alice"]["usd"], 10.0)
        self.assertIsNone(rows["=cmd"]["usd"])
        self.assertEqual((rows["alice"]["seat_usd"], rows["=cmd"]["seat_usd"]), (100.0, None))

    def test_the_report_has_a_row_per_person_and_unknown_is_an_empty_cell(self):
        import csv
        import io
        got = list(csv.DictReader(io.StringIO(api.people_csv(self.cfg, now=NOW))))
        self.assertEqual(len(got), 2)
        by = {r["user"].lstrip("'"): r for r in got}
        self.assertEqual((by["alice"]["usd"], by["alice"]["tier"], by["alice"]["tokens"]), ("10.00", "Max", "1000000"))
        self.assertEqual((by["=cmd"]["usd"], by["=cmd"]["seat_usd"]), ("", ""))

    def test_a_name_that_starts_like_a_formula_is_not_one_in_a_spreadsheet(self):
        self.assertIn("\n'=cmd,", api.people_csv(self.cfg, now=NOW))


class RunningActions(unittest.TestCase):
    def setUp(self):
        self.f = Fleet()
        self.marker = os.path.join(self.f.root, "ran")
        self.go = os.path.join(self.f.root, "go")
        py = sys.executable
        self.cfg = cfgmod.load(self.f.config(actions=[
            {"id": "ok", "label": "Say ok", "about": "prints", "cwd": "", "timeout_s": 20,
             "argv": [py, "-c", "import os,sys; print('hello'); print(os.getcwd()); sys.exit(3)"]},
            {"id": "touch", "label": "Touch", "about": "", "cwd": self.f.root, "timeout_s": 20,
             "argv": [py, "-c", "open('ran','a').write('x')"]},
            {"id": "slow", "label": "Slow", "about": "", "cwd": "", "timeout_s": 1,
             "argv": [py, "-c", "import subprocess,sys,time; subprocess.Popen([sys.executable,'-c','import time; time.sleep(30)']); time.sleep(30)"]},
            {"id": "loud", "label": "Loud", "about": "", "cwd": "", "timeout_s": 20,
             "argv": [py, "-c", "print('y' * %d)" % (actions.OUTPUT_MAX + 600000)]},
            {"id": "gone", "label": "Gone", "about": "", "cwd": "", "timeout_s": 5, "argv": ["/no/such/binary"]},
            {"id": "talk", "label": "Talk", "about": "", "cwd": "", "timeout_s": 20,
             "argv": [py, "-u", "-c", "import os,sys,time\nprint('first')\nwhile not os.path.exists(sys.argv[1]): time.sleep(0.05)\nprint('second')", self.go]},
            {"id": "wide", "label": "Wide", "about": "", "cwd": "", "timeout_s": 20,
             "argv": [py, "-c", "import sys; sys.stdout.buffer.write(b'x' + b'\\xc3\\xa9' * %d + b'\\n')" % actions.CHUNK_MAX]},
            {"id": "binary", "label": "Binary", "about": "", "cwd": "", "timeout_s": 20,
             "argv": [py, "-c", "import sys; sys.stdout.buffer.write(b'a\\xffb\\xc3')"]}],
            runs={"dir": os.path.join(self.f.root, "runs"), "keep": 3}))
        self.httpd = server.make_server(self.cfg, token="t0ken")
        self.port = self.httpd.server_address[1]
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()
        self.key = json.loads(self.call("GET", "/api/actions")[1].decode())["run_key"]

    def tearDown(self):
        open(self.go, "w").close()
        self.runner_idle()
        self.httpd.shutdown()
        self.httpd.server_close()
        self.f.close()

    def runner_idle(self):
        """A run's row is done a moment before its thread has tidied up and let go."""
        deadline = time.time() + 40
        while json.loads(self.call("GET", "/api/actions")[1].decode())["busy"]:
            self.assertLess(time.time(), deadline)
            time.sleep(0.02)

    def call(self, method, path, body=None, **headers):
        hdrs = {"X-Fleetdash-Token": "t0ken"}
        hdrs.update({k.replace("_", "-"): v for k, v in headers.items()})
        hdrs = {k: v for k, v in hdrs.items() if v is not None}
        req = urllib.request.Request("http://127.0.0.1:%d%s" % (self.port, path), method=method, headers=hdrs,
                                     data=body if body is None or isinstance(body, bytes) else json.dumps(body).encode())
        try:
            with urllib.request.urlopen(req, timeout=40) as r:
                return r.status, r.read()
        except urllib.error.HTTPError as e:
            return e.code, e.read()

    def start(self, action, **headers):
        headers.setdefault("X_Fleetdash_Run", self.key)
        status, body = self.call("POST", "/api/run", {"id": action}, **headers)
        return status, json.loads(body.decode())

    def read(self, run, offset=0):
        status, body = self.call("GET", "/api/run?id=%d&offset=%d" % (run, offset))
        return status, json.loads(body.decode())

    def run_action(self, action, **headers):
        """Starts it, follows it to its end the way the page does, and returns
        the run as last reported with everything it printed."""
        status, out = self.start(action, **headers)
        if status != 200:
            return status, out
        text, offset, deadline = "", 0, time.time() + 40
        while time.time() < deadline:
            chunk = self.read(out["run"], offset)[1]
            text, offset = text + chunk["output"], chunk["next"]
            if not chunk["more"]:
                return status, dict(chunk["run"], output=text, cut=chunk["cut"], file=chunk["file"])
        self.fail("run %d did not end" % out["run"])

    def test_a_listed_action_runs_and_its_exit_code_and_output_come_back(self):
        status, out = self.run_action("ok")
        self.assertEqual((status, out["exit_code"], out["state"]), (200, 3, "done"))
        self.assertTrue(out["output"].startswith("hello\n"))

    def test_it_runs_in_the_configured_directory(self):
        self.assertEqual(self.run_action("touch")[1]["exit_code"], 0)
        self.assertTrue(os.path.exists(self.marker))

    def test_starting_answers_at_once_and_the_output_can_be_read_while_it_runs(self):
        t0 = time.time()
        status, out = self.start("talk")
        self.assertEqual(status, 200)
        self.assertLess(time.time() - t0, 2)
        seen, offset, deadline = "", 0, time.time() + 10
        while "first" not in seen and time.time() < deadline:
            chunk = self.read(out["run"], offset)[1]
            seen, offset = seen + chunk["output"], chunk["next"]
        self.assertIn("first", seen)
        self.assertNotIn("second", seen)
        self.assertEqual((chunk["run"]["state"], chunk["run"]["exit_code"], chunk["more"]), ("running", None, True))
        open(self.go, "w").close()
        while chunk["more"] and time.time() < deadline:
            chunk = self.read(out["run"], offset)[1]
            seen, offset = seen + chunk["output"], chunk["next"]
        self.assertEqual((seen, chunk["run"]["state"], chunk["run"]["exit_code"]), ("first\nsecond\n", "done", 0))

    def test_a_run_keeps_the_command_it_was_started_with_and_all_it_printed(self):
        out = self.run_action("ok")[1]
        self.assertEqual((out["action"], out["command"], out["cwd"]), ("ok", self.cfg["actions"][0]["argv"], ""))
        self.assertEqual(out["bytes"], len(out["output"]))
        with open(out["file"]) as fh:
            self.assertEqual(fh.read(), out["output"])
        self.assertEqual(os.stat(out["file"]).st_mode & 0o777, 0o600)
        self.assertEqual(os.stat(self.cfg["runs"]["dir"]).st_mode & 0o777, 0o700)
        # a second server on the same store, as after a restart, still has it
        again = actions.Runner(self.cfg).read(out["run"], 0)
        self.assertEqual((again["output"], again["run"]["exit_code"]), (out["output"], 3))

    def test_each_run_is_recorded_and_the_listing_shows_the_last_and_the_history(self):
        self.run_action("ok")
        self.run_action("ok")
        self.run_action("touch")
        con = sqlite3.connect(self.cfg["store"])
        self.assertEqual(con.execute("select action, state, exit_code from runs order by id").fetchall(),
                         [("ok", "done", 3), ("ok", "done", 3), ("touch", "done", 0)])
        con.close()
        listing = json.loads(self.call("GET", "/api/actions")[1].decode())
        listed = {a["id"]: a for a in listing["actions"]}
        self.assertEqual((listed["ok"]["last"]["exit_code"], listed["ok"]["last"]["run"], listed["slow"]["last"]),
                         (3, 2, None))
        self.assertEqual([(r["run"], r["action"]) for r in listing["runs"]], [(3, "touch"), (2, "ok"), (1, "ok")])

    def test_only_the_newest_runs_are_kept_and_an_older_ones_output_goes_with_it(self):
        files = [self.run_action("ok")[1]["file"] for _ in range(4)]
        self.runner_idle()
        self.assertEqual([os.path.exists(f) for f in files], [False, True, True, True])
        listing = json.loads(self.call("GET", "/api/actions")[1].decode())
        self.assertEqual([r["run"] for r in listing["runs"]], [4, 3, 2])
        self.assertEqual(self.read(1)[0], 404)

    def test_an_action_past_its_time_limit_is_stopped_with_its_children_and_has_no_exit_code(self):
        status, out = self.run_action("slow")
        self.assertEqual((status, out["exit_code"], out["state"]), (200, None, "timed-out"))
        self.assertLess(out["seconds"], 10)

    def test_long_output_is_shown_up_to_a_limit_and_the_file_has_the_rest(self):
        out = self.run_action("loud")[1]
        self.assertEqual((len(out["output"]), out["cut"]), (actions.OUTPUT_MAX, True))
        self.assertEqual(os.path.getsize(out["file"]), actions.OUTPUT_MAX + 600001)
        self.assertEqual(out["bytes"], actions.OUTPUT_MAX + 600001)
        # from any offset, not only one a chunk ends on
        status, tail = self.read(out["run"], actions.OUTPUT_MAX - 10)
        self.assertEqual((status, len(tail["output"]), tail["next"], tail["more"], tail["cut"]),
                         (200, 10, actions.OUTPUT_MAX, False, True))

    def test_a_character_cut_by_a_chunk_is_whole_in_the_next_one(self):
        out = self.run_action("wide")[1]
        self.assertEqual(out["output"], "x" + "\u00e9" * actions.CHUNK_MAX + "\n")
        first = self.read(out["run"], 0)[1]
        self.assertEqual((first["next"], first["output"][-1]), (actions.CHUNK_MAX - 1, "\u00e9"))

    def test_output_that_is_not_text_is_shown_marked_not_refused(self):
        out = self.run_action("binary")[1]
        self.assertEqual(out["output"], "a\ufffdb\ufffd")

    def test_a_command_that_cannot_start_is_reported_not_a_crash(self):
        status, out = self.run_action("gone")
        self.assertEqual((status, out["exit_code"], out["state"]), (200, None, "not-started"))
        self.assertIn("could not start", out["output"])

    def test_a_run_another_server_left_unfinished_is_shown_as_interrupted_not_running(self):
        con = sqlite3.connect(self.cfg["store"])
        with con:
            con.execute("insert into runs (ts, action, argv, cwd, state) values "
                        "('2026-10-09T10:00:00Z', 'ok', '[\"x\"]', '', 'running')")
        con.close()
        listing = json.loads(self.call("GET", "/api/actions")[1].decode())
        self.assertEqual((listing["running"], listing["runs"][0]["state"]), (None, "interrupted"))
        status, got = self.read(listing["runs"][0]["run"])
        self.assertEqual((status, got["run"]["state"], got["more"], got["output"]), (200, "interrupted", False, ""))

    def test_a_run_that_is_not_there_or_a_place_past_its_end_is_refused(self):
        run = self.run_action("ok")[1]["run"]
        self.assertEqual(self.read(run + 1)[0], 404)
        self.assertEqual(self.read(run, 10 ** 6)[0], 400)
        for q in ("", "?id=x", "?id=%d&offset=-1" % run, "?id=0"):
            self.assertEqual(self.call("GET", "/api/run" + q)[0], 400, q)
        self.assertEqual(self.call("GET", "/api/run?id=%d" % run, X_Fleetdash_Token=None)[0], 403)

    def test_when_a_runs_output_cannot_be_kept_nothing_is_started_or_recorded(self):
        taken = os.path.join(self.cfg["runs"]["dir"], "1.log")
        os.makedirs(self.cfg["runs"]["dir"])
        open(taken, "w").close()
        status, out = self.start("touch")
        self.assertEqual(status, 500)
        self.assertIn("cannot keep", out["error"])
        self.assertFalse(os.path.exists(self.marker))
        listing = json.loads(self.call("GET", "/api/actions")[1].decode())
        self.assertEqual((listing["runs"], listing["busy"]), ([], False))
        os.unlink(taken)
        self.assertEqual(self.run_action("touch")[1]["exit_code"], 0)

    def test_an_id_the_config_does_not_list_runs_nothing(self):
        self.assertEqual(self.run_action("rm -rf /")[0], 404)
        self.assertEqual(self.run_action("")[0], 404)

    def test_nothing_in_a_request_reaches_the_command_line(self):
        status, _ = self.call("POST", "/api/run", {"id": "touch", "argv": ["sh"]}, X_Fleetdash_Run=self.key)
        self.assertEqual(status, 400)
        status, _ = self.call("POST", "/api/run?id=touch", {"cwd": "/"}, X_Fleetdash_Run=self.key)
        self.assertEqual(status, 400)
        self.assertFalse(os.path.exists(self.marker))

    def test_without_the_login_token_nothing_runs(self):
        self.assertEqual(self.run_action("touch", X_Fleetdash_Token=None)[0], 403)
        self.assertEqual(self.run_action("touch", X_Fleetdash_Token="wrong")[0], 403)
        self.assertFalse(os.path.exists(self.marker))

    def test_without_the_run_key_nothing_runs(self):
        self.assertEqual(self.run_action("touch", X_Fleetdash_Run=None)[0], 403)
        self.assertEqual(self.run_action("touch", X_Fleetdash_Run="guess")[0], 403)
        self.assertFalse(os.path.exists(self.marker))

    def test_a_request_from_another_origin_runs_nothing(self):
        for origin in ("http://evil.example", "http://127.0.0.1:1", "https://127.0.0.1:%d" % self.port, "null"):
            self.assertEqual(self.run_action("touch", Origin=origin)[0], 403, origin)
        self.assertFalse(os.path.exists(self.marker))
        self.assertEqual(self.run_action("touch", Origin="http://127.0.0.1:%d" % self.port)[1]["exit_code"], 0)

    def test_a_foreign_host_header_runs_nothing(self):
        self.assertEqual(self.run_action("touch", Host="evil.example")[0], 403)
        self.assertFalse(os.path.exists(self.marker))

    def test_an_oversized_or_malformed_body_is_a_400(self):
        for body in (b"x" * 2000, b"not json", b"[]", b'{"id": 5}', b""):
            self.assertEqual(self.call("POST", "/api/run", body, X_Fleetdash_Run=self.key)[0], 400, body[:20])

    def test_only_one_action_runs_at_a_time(self):
        status, out = self.start("talk")
        listing = json.loads(self.call("GET", "/api/actions")[1].decode())
        self.assertEqual((status, listing["running"], listing["run"], listing["busy"]), (200, "talk", out["run"], True))
        self.assertEqual(self.start("touch")[0], 409)
        self.assertFalse(os.path.exists(self.marker))
        open(self.go, "w").close()
        self.runner_idle()
        listing = json.loads(self.call("GET", "/api/actions")[1].decode())
        self.assertEqual((listing["running"], listing["run"]), (None, None))
        self.assertEqual(self.run_action("touch")[1]["exit_code"], 0)

    def test_every_other_post_is_still_refused(self):
        self.assertEqual(self.call("POST", "/api/overview", {"id": "ok"}, X_Fleetdash_Run=self.key)[0], 405)
        self.assertEqual(self.call("PUT", "/api/run", {"id": "ok"}, X_Fleetdash_Run=self.key)[0], 405)

    def test_the_run_key_is_not_given_out_without_the_login_token(self):
        self.assertEqual(self.call("GET", "/api/actions", X_Fleetdash_Token=None)[0], 403)

    def test_the_new_pages_answer_and_the_report_downloads_as_csv(self):
        for path in ("/api/hosts", "/api/policy", "/api/docs"):
            self.assertEqual(self.call("GET", path)[0], 200, path)
        self.assertEqual(self.call("GET", "/api/doc?id=0:nope.md")[0], 400)
        req = urllib.request.Request("http://127.0.0.1:%d/api/people.csv?days=7" % self.port,
                                     headers={"X-Fleetdash-Token": "t0ken"})
        with urllib.request.urlopen(req, timeout=5) as r:
            self.assertEqual(r.headers["Content-Type"], "text/csv; charset=utf-8")
            self.assertIn("attachment", r.headers["Content-Disposition"])
            self.assertTrue(r.read().startswith(b"user,tier,tokens"))


class Enrolment(unittest.TestCase):
    """Who is sending data and who has stopped: per host and per person."""

    def setUp(self):
        self.f = Fleet()
        self.cfg = cfgmod.load(self.f.config(seats=[
            {"tier": "Max", "monthly_usd": 100.0, "users": ["alice", "dave"]}]))
        con = store.connect(self.cfg)
        with con:
            for host, ts, by in (("h1", "2026-10-10T11:00:00Z", "alice"), ("h2", "2026-10-01T11:00:00Z", "bob")):
                ingest.record_checkin(con, {"host": host, "ts": ts, "claude_version": None, "policy_sha256": None}, by)
            usage_row = "insert into usage values (?,?,?,'s','claude-opus-5-5',1,1,0,0)"
            con.execute(usage_row, ("m1", "2026-10-08T10:00:00Z", "alice"))
            con.execute(usage_row, ("m2", "2026-09-01T10:00:00Z", "bob"))
            con.execute(*ingest.event("k1", "2026-10-09T10:00:00Z", "alice", "", "pass", "tool-call", "", "Bash", "", "h1"))
            con.execute(*ingest.event("k2", "2026-10-09T09:00:00Z", "alice", "", "pass", "tool-call", "", "Bash", "", "h2"))
            con.execute(*ingest.event("k6", "2026-08-30T10:00:00Z", "bob", "", "pass", "tool-call", "", "Bash", "", "h1"))
            # a transcript's event does not say which host it came from
            con.execute(*ingest.event("k7", "2026-08-30T11:00:00Z", "bob", "", "info", "skill", "", "", "review"))
            # a refused file is about the person, and is not data from them
            con.execute(*ingest.event("k3", "2026-10-10T09:00:00Z", "carol", "", "error", "log-integrity",
                                      "hard link to another file", "", "batch not read: hard link to another file"))
            con.execute(*ingest.event("k4", "2026-10-10T10:00:00Z", "alice", "", "error", "log-integrity",
                                      "symlink, not followed", "", "file not read: symlink, not followed"))
            con.execute(*ingest.event("k5", "2026-10-09T08:00:00Z", "alice", "", "error", "log-integrity",
                                      "older", "", "file not read: older"))
        con.close()
        self.e = api.enrolment(self.cfg, now=NOW)
        self.people = {r["user"]: r for r in self.e["people"]}

    def tearDown(self):
        self.f.close()

    def test_a_person_is_sending_quiet_or_has_never_sent(self):
        self.assertEqual({u: r["state"] for u, r in self.people.items()},
                         {"alice": "sending", "bob": "quiet", "carol": "never", "dave": "never"})

    def test_every_state_is_one_the_vocabulary_names(self):
        self.assertEqual({r["state"] for r in self.e["people"]}, set(PERSON_STATES))

    def test_the_last_data_is_the_newest_of_use_and_events_and_unknown_when_there_is_none(self):
        self.assertEqual(self.people["alice"]["last_data"], "2026-10-09T10:00:00Z")
        self.assertEqual(self.people["bob"]["last_data"], "2026-09-01T10:00:00Z")
        self.assertIsNone(self.people["dave"]["last_data"])
        # a file that was refused is not data from the person it names
        self.assertIsNone(self.people["carol"]["last_data"])

    def test_quiet_is_the_same_number_of_days_the_people_page_calls_idle(self):
        self.assertEqual(self.e["idle_days"], self.cfg["under_use"]["idle_days"])
        cfg = dict(self.cfg, under_use={"idle_days": 60, "median_fraction": 0.1})
        self.assertEqual({r["user"]: r["state"] for r in api.enrolment(cfg, now=NOW)["people"]}["bob"], "sending")

    def test_a_person_lists_the_hosts_their_events_came_from_and_their_seat(self):
        self.assertEqual(self.people["alice"]["hosts"], ["h1", "h2"])
        self.assertEqual(self.people["bob"]["hosts"], ["h1"])
        self.assertEqual(self.people["carol"]["hosts"], [])
        self.assertEqual((self.people["alice"]["seat"], self.people["bob"]["seat"]), ("Max", None))

    def test_refused_files_are_counted_per_person_with_the_newest_reason(self):
        a = self.people["alice"]
        self.assertEqual((a["refused"], a["last_refused"]),
                         (2, {"ts": "2026-10-10T10:00:00Z", "why": "file not read: symlink, not followed"}))
        self.assertEqual((self.people["bob"]["refused"], self.people["bob"]["last_refused"]), (0, None))
        self.assertEqual(self.people["carol"]["refused"], 1)

    def test_a_host_is_quiet_on_the_hosts_page_rule_and_says_who_it_heard_from(self):
        hosts = {r["host"]: r for r in self.e["hosts"]}
        self.assertEqual({h: r["stale"] for h, r in hosts.items()}, {"h1": False, "h2": True})
        self.assertEqual({h: r["people"] for h, r in hosts.items()}, {"h1": 2, "h2": 1})
        self.assertEqual(hosts["h2"]["reported_by"], "bob")
        self.assertEqual(self.e["stale_hours"], self.cfg["host_stale_hours"])

    def test_an_empty_store_lists_seat_holders_as_never_and_no_host(self):
        f = Fleet()
        self.addCleanup(f.close)
        e = api.enrolment(cfgmod.load(f.config()), now=NOW)
        self.assertEqual(([(r["user"], r["state"]) for r in e["people"]], e["hosts"]), ([("alice", "never")], []))


class Retention(unittest.TestCase):
    """What the store keeps, and what the next prune would remove from it."""

    def setUp(self):
        self.f = Fleet()
        cfg = cfgmod.load(self.f.config())
        cfg["retention"] = dict(cfg["retention"], info={"days": 3650, "max_rows": 2})
        self.cfg = cfg
        con = store.connect(cfg)
        with con:
            for i, (ts, sev) in enumerate((
                    ("2026-08-01T10:00:00Z", "pass"), ("2026-10-09T10:00:00Z", "pass"),  # 14 days: one is past
                    ("2026-10-01T10:00:00Z", "info"), ("2026-10-02T10:00:00Z", "info"),
                    ("2026-10-03T10:00:00Z", "info"),                                     # 2 rows: one is over
                    ("2026-08-01T10:00:00Z", "deny"))):                                   # 365 days: kept
                con.execute(*ingest.event("k%d" % i, ts, "alice", "", sev, "tool-call", "", "Bash", ""))
            con.execute("insert into usage values ('m1','2026-07-01T10:00:00Z','alice','s','claude-opus-5-5',1,1,0,0)")
        con.close()
        self.r = api.retention(cfg, now=NOW)
        self.rows = {r["severity"]: r for r in self.r["rows"]}

    def tearDown(self):
        self.f.close()

    def test_there_is_one_row_per_severity_with_its_rule_in_the_vocabularys_order(self):
        self.assertEqual([r["severity"] for r in self.r["rows"]], list(SEVERITIES))
        self.assertEqual((self.rows["pass"]["days"], self.rows["pass"]["max_rows"]), (14, 1000))

    def test_a_row_says_how_many_are_stored_and_how_old_the_oldest_is(self):
        self.assertEqual((self.rows["info"]["stored"], self.rows["info"]["oldest"]), (3, "2026-10-01T10:00:00Z"))
        # none stored: the oldest is unknown, not a date
        self.assertEqual((self.rows["quota"]["stored"], self.rows["quota"]["oldest"]), (0, None))

    def test_what_a_prune_would_remove_is_what_a_prune_then_removes(self):
        said = {s: r["would_remove"] for s, r in self.rows.items() if r["would_remove"]}
        self.assertEqual(said, {"pass": 1, "info": 1})
        self.assertEqual(store.prune(self.cfg, now=NOW), said)
        self.assertEqual({r["would_remove"] for r in api.retention(self.cfg, now=NOW)["rows"]}, {0})

    def test_a_row_both_too_old_and_over_the_cap_is_counted_once(self):
        cfg = dict(self.cfg, retention=dict(self.cfg["retention"], info={"days": 9, "max_rows": 1}))
        # the 1 October row is past 9 days; of the two left, one is over the cap
        said = {r["severity"]: r["would_remove"] for r in api.retention(cfg, now=NOW)["rows"]}
        self.assertEqual(said["info"], 2)
        self.assertEqual(store.prune(cfg, now=NOW)["info"], 2)

    def test_usage_is_kept_and_says_so(self):
        self.assertEqual(self.r["admin_log"], {"stored": 0, "oldest": None})
        self.assertEqual(self.r["usage"], {"stored": 1, "oldest": "2026-07-01T10:00:00Z"})
        store.prune(self.cfg, now=NOW)
        self.assertEqual(api.retention(self.cfg, now=NOW)["usage"]["stored"], 1)

    def test_it_says_how_many_runs_are_kept(self):
        self.assertEqual(self.r["runs"], {"keep": 20, "stored": 0})


class AdminEndpoints(unittest.TestCase):
    def setUp(self):
        self.f = Fleet()
        self.cfg = cfgmod.load(self.f.config())
        self.httpd = server.make_server(self.cfg)
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()

    def tearDown(self):
        self.httpd.shutdown()
        self.httpd.server_close()
        self.f.close()

    def get(self, path, token=None):
        req = urllib.request.Request("http://127.0.0.1:%d%s" % (self.httpd.server_address[1], path),
                                     headers={"X-Fleetdash-Token": self.httpd.token if token is None else token})
        try:
            with urllib.request.urlopen(req, timeout=10) as r:
                return r.status, json.loads(r.read().decode())
        except urllib.error.HTTPError as e:
            return e.code, json.loads(e.read().decode())

    def test_enrolment_and_retention_are_served_to_a_logged_in_page(self):
        status, e = self.get("/api/enrolment")
        self.assertEqual((status, sorted(e)), (200, ["hosts", "idle_days", "people", "stale_hours"]))
        status, r = self.get("/api/retention")
        self.assertEqual((status, sorted(r)), (200, ["admin_log", "rows", "runs", "usage"]))
        status, a = self.get("/api/admin-sessions")
        self.assertEqual((status, sorted(a)), (200, ["calls_kept_days", "log", "ran_shown", "refusals", "refusals_total",
                                                     "sessions", "sessions_total"]))

    def test_neither_is_served_without_the_token(self):
        for path in ("/api/enrolment", "/api/retention", "/api/admin-sessions"):
            self.assertEqual(self.get(path, token="wrong")[0], 403, path)


class PrivilegedSessions(unittest.TestCase):
    """The privileged session's own log: who started one, how it ended, who
    was refused, and what that person ran while it was open."""

    def setUp(self):
        self.f = Fleet()
        self.log = os.path.join(self.f.root, "log", "admin.log")
        self.cfg = cfgmod.load(self.f.config(admin_log=self.log))

    def tearDown(self):
        self.f.close()

    def read(self, lines, now=NOW, cfg=None):
        self.f.adminlog(lines)
        self.stats = ingest.run(cfg or self.cfg)
        return api.admin_sessions(cfg or self.cfg, now=now)

    def test_a_start_and_its_end_are_one_session(self):
        a = self.read([admin_line("2026-10-10T10:00:00Z", 100, "alice", "admin session START bin=/usr/bin/claude eval=0"),
                       admin_line("2026-10-10T10:30:00Z", 100, "alice", "admin session END rc=0")])
        self.assertEqual(self.stats["bad_lines"], 0)
        s, = a["sessions"]
        self.assertEqual({k: s[k] for k in ("host", "invoker", "target", "tty", "started", "ended", "seconds", "rc")},
                         {"host": "test-host", "invoker": "alice", "target": "alice", "tty": "/dev/pts/2",
                          "started": "2026-10-10T10:00:00Z", "ended": "2026-10-10T10:30:00Z", "seconds": 1800,
                          "rc": 0})
        self.assertEqual(a["refusals"], [])

    def test_a_start_with_no_end_has_no_end_and_no_exit_code_not_zero(self):
        a = self.read([admin_line("2026-10-10T10:00:00Z", 100, "alice", "admin session START bin=/usr/bin/claude eval=0")])
        s, = a["sessions"]
        self.assertEqual((s["ended"], s["seconds"], s["rc"]), (None, None, None))

    def test_a_process_number_used_again_starts_a_second_session(self):
        a = self.read([admin_line("2026-10-08T10:00:00Z", 100, "alice", "admin session START bin=c eval=0"),
                       admin_line("2026-10-09T10:00:00Z", 100, "bob", "admin session START bin=c eval=0"),
                       admin_line("2026-10-09T10:05:00Z", 100, "bob", "admin session END rc=3")])
        # newest first
        self.assertEqual([(s["invoker"], s["ended"], s["rc"]) for s in a["sessions"]],
                         [("bob", "2026-10-09T10:05:00Z", 3), ("alice", None, None)])

    def test_a_second_end_for_a_process_number_does_not_reopen_the_session_it_ended(self):
        a = self.read([admin_line("2026-10-08T10:00:00Z", 100, "alice", "admin session START bin=c eval=0"),
                       admin_line("2026-10-08T10:05:00Z", 100, "alice", "admin session END rc=0"),
                       admin_line("2026-10-09T10:00:00Z", 100, "bob", "admin session END rc=4")])
        self.assertEqual([(s["invoker"], s["started"], s["ended"], s["rc"]) for s in a["sessions"]],
                         [("bob", None, "2026-10-09T10:00:00Z", 4),
                          ("alice", "2026-10-08T10:00:00Z", "2026-10-08T10:05:00Z", 0)])

    def test_two_sessions_one_person_has_open_at_once_each_keep_their_own_end(self):
        a = self.read([admin_line("2026-10-08T10:00:00Z", 100, "alice", "admin session START bin=c eval=0"),
                       admin_line("2026-10-08T11:00:00Z", 200, "alice", "admin session START bin=c eval=0"),
                       admin_line("2026-10-08T12:00:00Z", 100, "alice", "admin session END rc=1"),
                       admin_line("2026-10-10T11:00:01Z", 200, "alice", "admin session END rc=2")])
        # the second one ran for more than a day: its length is all of it, not the part past midnight
        self.assertEqual([(s["started"], s["seconds"], s["rc"]) for s in a["sessions"]],
                         [("2026-10-08T11:00:00Z", 2 * 86400 + 1, 2), ("2026-10-08T10:00:00Z", 7200, 1)])

    def test_two_lines_stamped_in_the_same_second_are_both_kept(self):
        a = self.read([admin_line("2026-10-10T09:00:00Z", 7, "alice", "REFUSED reason=uid0"),
                       admin_line("2026-10-10T09:00:00Z", 7, "alice", "REFUSED reason=uid0")])
        self.assertEqual(len(a["refusals"]), 2)

    def test_what_ran_is_looked_up_under_the_account_the_session_ran_as(self):
        self.f.hooklog("activity", "svc", [{"ts": "2026-10-10T10:01:00Z", "tool": "Bash", "detail": "as the target"}])
        self.f.hooklog("activity", "alice", [{"ts": "2026-10-10T10:02:00Z", "tool": "Bash", "detail": "as the invoker"}])
        s, = self.read([admin_line("2026-10-10T10:00:00Z", 100, "alice", "admin session START bin=c eval=0", target="svc"),
                        admin_line("2026-10-10T10:30:00Z", 100, "alice", "admin session END rc=0", target="svc")])["sessions"]
        self.assertEqual([c["detail"] for c in s["ran"]], ["as the target"])

    def test_an_end_whose_start_was_never_read_has_no_start(self):
        a = self.read([admin_line("2026-10-10T10:30:00Z", 100, "alice", "admin session END rc=0")])
        s, = a["sessions"]
        self.assertEqual((s["started"], s["ended"], s["seconds"], s["rc"]), (None, "2026-10-10T10:30:00Z", None, 0))

    def test_a_refusal_is_listed_with_its_reason_and_is_not_a_session(self):
        a = self.read([
            admin_line("2026-10-10T09:00:00Z", 7, "mallory", "REFUSED reason=unauthorised group=wheel", target="unset"),
            admin_line("2026-10-10T09:01:00Z", 8, "alice", "REFUSED reason=uid0", target="root", tty="none"),
            admin_line("2026-10-10T09:02:00Z", 9, "alice", "REFUSED reason=die msg=policy file is missing")])
        self.assertEqual(a["sessions"], [])
        self.assertEqual([(r["ts"], r["invoker"], r["target"], r["tty"], r["reason"], r["detail"]) for r in a["refusals"]], [
            ("2026-10-10T09:02:00Z", "alice", "alice", "/dev/pts/2", "die", "msg=policy file is missing"),
            ("2026-10-10T09:01:00Z", "alice", "root", "none", "uid0", ""),
            ("2026-10-10T09:00:00Z", "mallory", "unset", "/dev/pts/2", "unauthorised", "group=wheel")])

    def test_a_line_that_is_not_the_launchers_shape_is_a_bad_line_and_stores_nothing(self):
        good = admin_line("2026-10-10T10:00:00Z", 100, "alice", "admin session START bin=c eval=0")
        bad = ["garbage",
               "2026-10-10T10:00:00Z pid=x invoker=alice target=alice tty=none admin session START",
               "2026-10-10T10:00:00Z invoker=alice pid=1 target=alice tty=none admin session START",
               "yesterday pid=1 invoker=alice target=alice tty=none admin session START",
               "2026-10-10T10:00:00Z pid=1 invoker=alice target=alice tty=none",
               "2026-10-10T10:00:00Z pid=1 invoker=alice target=alice tty=none something else happened",
               "2026-10-10T10:00:00Z pid=1 invoker=alice target=alice tty=none admin session END rc=zero",
               "2026-10-10T10:00:00Z pid=1 invoker=alice target=alice tty=none REFUSED because",
               "2026-10-10T10:00:00Z pid=1 user=alice target=alice tty=none admin session START",
               " pid=1 invoker=alice target=alice tty=none admin session START",  # no time at all
               "2026-10-10T10:00:00Z pid=1 invoker= target=alice tty=none admin session START",
               "2026-10-10T10:00:00Z pid=1 invoker=alice target=alice tty=none admin session END rc=0 and more",
               "2026-10-10T10:00:00Z pid=1 invoker=alice target=alice tty=none admin session END rc=-1",
               "2026-10-10T10:00:00Z pid=+1 invoker=alice target=alice tty=none admin session START",
               "2026-10-10T10:00:00Z pid=1 invoker=alice target=alice tty=none"]
        a = self.read(bad + [good])
        self.assertEqual((self.stats["bad_lines"], len(a["sessions"]), a["refusals"]), (len(bad), 1, []))

    def test_a_second_ingest_adds_nothing_and_an_appended_line_adds_one(self):
        self.read([admin_line("2026-10-10T10:00:00Z", 100, "alice", "admin session START bin=c eval=0")])
        self.assertEqual(len(self.read([])["sessions"]), 1)
        a = self.read([admin_line("2026-10-10T10:30:00Z", 100, "alice", "admin session END rc=0")])
        self.assertEqual([(s["started"], s["ended"]) for s in a["sessions"]],
                         [("2026-10-10T10:00:00Z", "2026-10-10T10:30:00Z")])

    def test_a_session_counts_what_that_person_ran_on_that_host_while_it_was_open(self):
        call = lambda ts, detail: {"ts": ts, "tool": "Bash", "detail": detail}
        self.f.hooklog("activity", "alice", [call("2026-10-10T09:59:00Z", "before"), call("2026-10-10T10:01:00Z", "dnf install x"),
                                             call("2026-10-10T10:02:00Z", "systemctl restart y"),
                                             call("2026-10-10T10:31:00Z", "after")])
        self.f.hooklog("activity", "bob", [call("2026-10-10T10:03:00Z", "someone else")])
        self.f.hooklog("denied", "alice", [dict(call("2026-10-10T10:04:00Z", "rm -rf /"), denied_by="rule")])
        s, = self.read([admin_line("2026-10-10T10:00:00Z", 100, "alice", "admin session START bin=c eval=0"),
                        admin_line("2026-10-10T10:30:00Z", 100, "alice", "admin session END rc=0")])["sessions"]
        self.assertEqual((s["calls"], s["blocked"]), (2, 1))
        self.assertEqual([(c["severity"], c["tool"], c["detail"]) for c in s["ran"]],
                         [("pass", "Bash", "dnf install x"), ("pass", "Bash", "systemctl restart y"),
                          ("deny", "Bash", "rm -rf /")])

    def test_what_a_session_ran_is_unknown_with_no_end_or_once_tool_calls_that_old_are_pruned(self):
        a = self.read([admin_line("2026-08-01T10:00:00Z", 100, "alice", "admin session START bin=c eval=0"),
                       admin_line("2026-08-01T10:30:00Z", 100, "alice", "admin session END rc=0"),
                       admin_line("2026-10-10T10:00:00Z", 101, "alice", "admin session START bin=c eval=0")])
        # passes are kept 14 days: none stored is then not the same as none run
        self.assertEqual([(s["calls"], s["blocked"], s["ran"]) for s in a["sessions"]], [(None, None, None)] * 2)

    def test_only_the_newest_calls_shown_are_capped_and_the_count_is_not(self):
        n = api.ADMIN_RAN_SHOWN + 5
        self.f.hooklog("activity", "alice", [{"ts": "2026-10-10T10:%02d:%02dZ" % divmod(i, 60), "tool": "Bash", "detail": "c%d" % i}
                                             for i in range(1, n + 1)])
        s, = self.read([admin_line("2026-10-10T10:00:00Z", 100, "alice", "admin session START bin=c eval=0"),
                        admin_line("2026-10-10T10:30:00Z", 100, "alice", "admin session END rc=0")])["sessions"]
        self.assertEqual((s["calls"], len(s["ran"]), s["ran"][0]["detail"]), (n, api.ADMIN_RAN_SHOWN, "c1"))

    def test_the_log_says_whether_it_is_configured_there_and_readable(self):
        self.assertEqual(api.admin_sessions(dict(self.cfg, admin_log=""), now=NOW)["log"],
                         {"path": "", "state": "not-configured", "at": None, "error": None})
        # configured, and no ingest has looked yet
        self.assertEqual(api.admin_sessions(self.cfg, now=NOW)["log"]["state"], "not-read-yet")
        # no file: a host where no privileged session was ever started. Not an error.
        stats = ingest.run(self.cfg)
        log = api.admin_sessions(self.cfg, now=NOW)["log"]
        self.assertEqual((stats["skipped"], log["state"], log["error"]), ([], "absent", None))
        self.assertIsNotNone(log["at"])
        self.f.adminlog([admin_line("2026-10-10T10:00:00Z", 100, "alice", "admin session START bin=c eval=0")])
        ingest.run(self.cfg)
        self.assertEqual(api.admin_sessions(self.cfg, now=NOW)["log"]["state"], "read")

    def test_a_log_that_cannot_be_opened_is_said_on_the_page_and_in_the_exit_status(self):
        blocker = os.path.join(self.f.root, "a-file")
        open(blocker, "w").close()
        cfg = dict(self.cfg, admin_log=os.path.join(blocker, "admin.log"))
        stats = ingest.run(cfg)
        log = api.admin_sessions(cfg, now=NOW)["log"]
        self.assertEqual((len(stats["skipped"]), log["state"]), (1, "unreadable"))
        self.assertIn("Not a directory", log["error"])
        # and once it can be read, the error is gone
        ingest.run(self.cfg)
        self.assertIsNone(api.admin_sessions(self.cfg, now=NOW)["log"]["error"])

    def test_with_owners_checked_a_log_root_does_not_own_is_refused(self):
        cfg = dict(self.cfg, verify_file_owner=True)
        a = self.read([admin_line("2026-10-10T10:00:00Z", 100, "alice", "admin session START bin=c eval=0")], cfg=cfg)
        if os.geteuid() == 0:  # the CI container: root wrote the fixture, as the launcher would
            self.assertEqual((len(a["sessions"]), a["log"]["state"]), (1, "read"))
        else:
            self.assertEqual((a["sessions"], a["log"]["state"]), ([], "unreadable"))
            self.assertIn("owner ", a["log"]["error"])

    def test_no_admin_log_configured_reads_none_and_skips_nothing(self):
        cfg = dict(self.cfg, admin_log="")
        self.f.adminlog([admin_line("2026-10-10T10:00:00Z", 100, "alice", "admin session START bin=c eval=0")])
        self.assertEqual((ingest.run(cfg)["skipped"], api.admin_sessions(cfg, now=NOW)["sessions"]), ([], []))

    def test_a_path_that_is_not_absolute_is_refused_at_start_up(self):
        with self.assertRaises(cfgmod.ConfigError):
            cfgmod.load(self.f.config(admin_log="log/admin.log"))

    def test_the_log_is_kept_whole_and_retention_says_so(self):
        self.read([admin_line("2026-01-01T10:00:00Z", 100, "alice", "admin session START bin=c eval=0")])
        store.prune(self.cfg, now=NOW)
        self.assertEqual(api.retention(self.cfg, now=NOW)["admin_log"], {"stored": 1, "oldest": "2026-01-01T10:00:00Z"})


class LoginToken(unittest.TestCase):
    def setUp(self):
        self.f = Fleet()
        self.path = os.path.join(self.f.root, "token")
        self.cfg = cfgmod.load(self.f.config(token_file=self.path))

    def tearDown(self):
        self.f.close()

    def test_a_token_file_is_created_owner_only_and_reused_by_the_next_start(self):
        first = server.login_token(self.cfg)
        self.assertEqual(os.stat(self.path).st_mode & 0o777, 0o600)
        self.assertEqual(server.login_token(self.cfg), first)
        self.assertEqual(server.read_token(self.cfg), first)

    def test_with_no_token_file_each_start_has_a_new_token(self):
        cfg = dict(self.cfg, token_file="")
        self.assertNotEqual(server.login_token(cfg), server.login_token(cfg))

    def test_a_token_file_open_to_others_or_too_short_or_a_symlink_is_refused(self):
        server.login_token(self.cfg)
        os.chmod(self.path, 0o640)
        with self.assertRaises(server.TokenError):
            server.login_token(self.cfg)
        os.chmod(self.path, 0o600)
        with open(self.path, "w") as fh:
            fh.write("short\n")
        with self.assertRaises(server.TokenError):
            server.login_token(self.cfg)
        os.unlink(self.path)
        real = os.path.join(self.f.root, "elsewhere")
        with open(real, "w") as fh:
            fh.write("x" * 40)
        os.chmod(real, 0o600)
        os.symlink(real, self.path)
        with self.assertRaises(server.TokenError):
            server.login_token(self.cfg)


class NestedConfig(unittest.TestCase):
    def setUp(self):
        self.f = Fleet()

    def tearDown(self):
        self.f.close()

    def refused(self, **over):
        with self.assertRaises(cfgmod.ConfigError):
            cfgmod.load(self.f.config(**over))

    def test_a_nested_table_with_a_missing_unknown_or_mistyped_key_is_refused(self):
        self.refused(feed={"transcripts": "x"})
        self.refused(policy={"deployed": "", "source": "", "extra": ""})
        self.refused(policy={"deployed": 1, "source": ""})
        self.refused(docs=[{"label": "a"}])
        self.refused(host_stale_hours=0)

    def test_an_action_must_be_a_fixed_command_with_a_plain_id_and_a_time_limit(self):
        good = {"id": "dry-run", "label": "x", "about": "", "argv": ["make", "x"], "cwd": "", "timeout_s": 5}
        cfgmod.load(self.f.config(actions=[good]))
        for bad in ({"id": "a b"}, {"id": "../x"}, {"id": ""}, {"argv": []}, {"argv": ["make", ""]},
                    {"argv": "make x"}, {"argv": ["make", 1]}, {"timeout_s": 0}, {"timeout_s": True}):
            with self.subTest(bad=bad):
                self.refused(actions=[dict(good, **bad)])
        self.refused(actions=[good, good])


if __name__ == "__main__":
    unittest.main()
