import datetime
import json
import os
import threading
import unittest
import urllib.error
import urllib.request

from fleetdash import api, ingest, server, store
from fleetdash import config as cfgmod
from tests.fixtures import Fleet, assistant, usage

NOW = datetime.datetime(2026, 10, 10, 12, 0, 0)


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args):
        return None


class ConfigFailsClosed(unittest.TestCase):
    def setUp(self):
        self.f = Fleet()

    def tearDown(self):
        self.f.close()

    def test_an_unknown_key_is_refused(self):
        with self.assertRaises(cfgmod.ConfigError):
            cfgmod.load(self.f.config(stroe="typo"))

    def test_a_missing_key_is_refused(self):
        path = self.f.config()
        with open(path) as fh:
            d = json.load(fh)
        del d["seats"]
        with open(path, "w") as fh:
            json.dump(d, fh)
        with self.assertRaises(cfgmod.ConfigError):
            cfgmod.load(path)

    def test_an_under_use_rule_out_of_range_is_refused(self):
        for bad in ({"idle_days": 0, "median_fraction": 0.1}, {"idle_days": 14, "median_fraction": 1.5},
                    {"idle_days": 14}, {"idle_days": 14, "median_fraction": 0.1, "x": 1}):
            with self.assertRaises(cfgmod.ConfigError, msg=bad):
                cfgmod.load(self.f.config(under_use=bad))

    def test_a_place_to_keep_runs_that_is_not_a_full_path_is_refused_when_there_is_a_command(self):
        action = {"id": "a", "label": "A", "about": "", "argv": ["true"], "cwd": "", "timeout_s": 5}
        for bad in ("", "runs", "./runs"):
            with self.assertRaises(cfgmod.ConfigError, msg=bad):
                cfgmod.load(self.f.config(actions=[action], runs={"dir": bad, "keep": 5}))
        # with no command nothing is ever kept there
        cfgmod.load(self.f.config(actions=[], runs={"dir": "", "keep": 5}))

    def test_keeping_no_runs_is_refused(self):
        for bad in (0, -1):
            with self.assertRaises(cfgmod.ConfigError, msg=bad):
                cfgmod.load(self.f.config(runs={"dir": "/nonexistent/runs", "keep": bad}))

    def test_a_non_loopback_bind_is_refused_while_there_is_no_tls(self):
        with self.assertRaises(cfgmod.ConfigError):
            cfgmod.load(self.f.config(bind="0.0.0.0"))


class Overview(unittest.TestCase):
    def setUp(self):
        self.f = Fleet()
        self.cfg = cfgmod.load(self.f.config())
        self.f.transcript("alice", "p1", "s1", [
            assistant("a1", "m1", "2026-10-09T10:00:00Z", "claude-opus-5-5",
                      usage(i=1000000, o=0, cr=0, cw=0)),
            assistant("a2", "m2", "2026-10-09T11:00:00Z", "eu.anthropic.claude-opus-5-5",
                      usage(i=0, o=1000000, cr=0, cw=0)),
            assistant("a3", "m3", "2026-10-09T12:00:00Z", "claude-haiku-5-5",
                      usage(i=5, o=5, cr=0, cw=0)),
            assistant("a4", "m4", "2026-08-01T12:00:00Z", "claude-opus-5-5",
                      usage(i=999, o=999, cr=0, cw=0)),
        ])
        self.f.hooklog("denied", "alice", [
            {"ts": "2026-10-09T10:00:00Z", "user": "alice", "tool": "Bash", "detail": "curl x",
             "denied_by": "Blocked by classifier"}])
        ingest.run(self.cfg)
        self.o = api.overview(self.cfg, days=30, now=NOW)

    def tearDown(self):
        self.f.close()

    def test_a_model_named_the_bedrock_way_is_bedrock(self):
        self.assertEqual(tokens_by_provider(self.o), {"anthropic": 1000010, "bedrock": 1000000})

    def test_a_bedrock_id_without_a_region_prefix_is_bedrock_and_priced(self):
        # a Bedrock id with no region prefix: anthropic.<model>-<date>-v1:0
        self.f.transcript("bob", "p1", "s2", [
            assistant("b1", "mb1", "2026-10-09T10:00:00Z", "anthropic.claude-opus-4-5-20251001-v1:0",
                      usage(i=1000000, o=0, cr=0, cw=0))])
        ingest.run(self.cfg)
        o = api.overview(self.cfg, days=30, now=NOW)
        self.assertEqual(tokens_by_provider(o)["bedrock"], 2000000)
        self.assertAlmostEqual(o["cost"]["priced_usd"], 70.0)

    def test_cost_uses_the_price_table_and_an_unpriced_model_is_unknown_not_zero(self):
        # 1M input at 10 + 1M output at 50 (both opus, by family prefix)
        self.assertAlmostEqual(self.o["cost"]["priced_usd"], 60.0)
        self.assertEqual(self.o["cost"]["unpriced_models"], ["claude-haiku-5-5"])
        self.assertIsNone(self.o["cost"]["total_usd"])

    def test_seats_are_prorated_to_the_window(self):
        self.assertAlmostEqual(self.o["seats"]["window_usd"], 100.0)
        self.assertEqual(self.o["seats"]["count"], 1)

    def test_the_window_excludes_older_usage(self):
        self.assertEqual(sum(u["tokens"] for u in self.o["by_user"]), 2000010)

    def test_blocks_are_counted_by_source(self):
        self.assertEqual(self.o["blocks"], [{"source": "Blocked by classifier", "count": 1}])


def tokens_by_provider(o):
    return {p["provider"]: p["tokens"] for p in o["providers"]}


class Providers(unittest.TestCase):
    """Bedrock answers with the plain model name, so the name alone cannot say
    a call went there. The message id can: Bedrock's start msg_bdrk_."""

    def setUp(self):
        self.f = Fleet()
        self.cfg = cfgmod.load(self.f.config())
        self.f.transcript("alice", "p1", "s1", [
            assistant("a1", "msg_01abc", "2026-10-09T10:00:00Z", "claude-opus-5-5",
                      usage(i=1000000, o=0, cr=0, cw=0)),
            assistant("a2", "msg_bdrk_01abc", "2026-10-09T11:00:00Z", "claude-opus-5-5",
                      usage(i=0, o=1000000, cr=2000000, cw=0)),
            assistant("a3", "msg_bdrk_01abd", "2026-10-09T12:00:00Z", "claude-haiku-5-5",
                      usage(i=5, o=5, cr=0, cw=0)),
            assistant("a4", "0c1f-not-an-api-id", "2026-10-09T12:30:00Z", "<synthetic>",
                      usage(i=0, o=0, cr=0, cw=0)),
        ])
        ingest.run(self.cfg)
        self.o = api.overview(self.cfg, days=30, now=NOW)
        self.p = {p["provider"]: p for p in self.o["providers"]}

    def tearDown(self):
        self.f.close()

    def test_a_bedrock_call_is_known_by_its_message_id_whatever_the_model_is_called(self):
        self.assertEqual(tokens_by_provider(self.o), {"anthropic": 1000000, "bedrock": 3000010})

    def test_the_same_model_through_both_is_a_row_in_each_with_its_own_counts(self):
        row = {k: [m for m in p["models"] if m["model"] == "claude-opus-5-5"] for k, p in self.p.items()}
        self.assertEqual([(m["input"], m["output"], m["cache_read"], m["cache_write"]) for m in row["anthropic"]],
                         [(1000000, 0, 0, 0)])
        self.assertEqual([(m["input"], m["output"], m["cache_read"], m["cache_write"]) for m in row["bedrock"]],
                         [(0, 1000000, 2000000, 0)])
        self.assertAlmostEqual(row["anthropic"][0]["usd"], 10.0)
        self.assertAlmostEqual(row["bedrock"][0]["usd"], 52.0)

    def test_each_provider_has_its_own_cost_and_an_unpriced_model_leaves_only_that_one_unknown(self):
        self.assertAlmostEqual(self.p["anthropic"]["usd"], 10.0)
        self.assertIsNone(self.p["bedrock"]["usd"])
        self.assertAlmostEqual(self.p["bedrock"]["priced_usd"], 52.0)
        self.assertEqual(self.p["bedrock"]["unpriced_models"], ["claude-haiku-5-5"])
        self.assertEqual(self.p["anthropic"]["unpriced_models"], [])

    def test_a_provider_nobody_used_is_still_there_with_nothing_in_it(self):
        cfg = cfgmod.load(self.f.config(bedrock_id_prefix="", bedrock_model_pattern="^never$"))
        p = {x["provider"]: x for x in api.overview(cfg, days=30, now=NOW)["providers"]}
        self.assertEqual((p["bedrock"]["tokens"], p["bedrock"]["models"], p["bedrock"]["usd"]), (0, [], 0.0))
        self.assertEqual(p["anthropic"]["tokens"], 4000010)

    def test_a_message_claude_code_wrote_itself_is_not_a_model(self):
        self.assertNotIn("<synthetic>", [m["model"] for p in self.o["providers"] for m in p["models"]])
        self.assertNotIn("<synthetic>", self.o["cost"]["unpriced_models"])

    def test_the_two_marks_of_bedrock_do_not_count_one_call_twice(self):
        self.f.transcript("bob", "p1", "s2", [
            assistant("b1", "msg_bdrk_02", "2026-10-09T10:00:00Z", "eu.anthropic.claude-opus-5-5",
                      usage(i=7, o=0, cr=0, cw=0))])
        ingest.run(self.cfg)
        o = api.overview(self.cfg, days=30, now=NOW)
        self.assertEqual(tokens_by_provider(o), {"anthropic": 1000000, "bedrock": 3000017})


class EventsAndSessions(unittest.TestCase):
    def setUp(self):
        self.f = Fleet()
        self.cfg = cfgmod.load(self.f.config())
        for u in ("alice", "bob"):
            self.f.hooklog("activity", u, [
                {"ts": "2026-10-09T10:00:00Z", "user": u, "tool": "Bash", "detail": "ls"}])
        self.f.hooklog("denied", "bob", [
            {"ts": "2026-10-09T10:00:01Z", "user": "bob", "tool": "Bash", "detail": "sudo x", "denied_by": "rule"}])
        self.f.transcript("alice", "p1", "old", [
            assistant("a1", "m1", "2026-06-01T10:00:00Z", "claude-opus-5-5", usage())])
        self.f.transcript("bob", "p1", "new", [
            assistant("b1", "m2", "2026-10-09T10:00:00Z", "claude-opus-5-5", usage())])
        ingest.run(self.cfg)

    def tearDown(self):
        self.f.close()

    def test_events_filter_by_user_and_severity(self):
        got = api.events(self.cfg, user="bob", severity="deny")
        self.assertEqual([(e["user"], e["detail"]) for e in got["rows"]], [("bob", "sudo x")])
        self.assertEqual(got["total"], 1)

    def test_a_stopped_call_carries_its_incident_and_no_other_event_does(self):
        got = api.events(self.cfg)["rows"]
        self.assertEqual([e["incident"] for e in got if e["category"] == "denial"], [
            {"input": "sudo x", "input_kind": "", "input_len": 6, "fields": None, "said": "",
             "cwd": "", "branch": "", "client": "", "call_id": ""}])
        self.assertEqual({e["incident"] for e in got if e["category"] != "denial"}, {None})
        self.assertEqual({"key" in e for e in got}, {False})

    def test_category_counts_ignore_the_category_filter_so_the_tabs_stay(self):
        got = api.events(self.cfg, category="denial")
        counts = {c["category"]: c["count"] for c in got["by_category"]}
        self.assertEqual((counts["denial"], counts["tool-call"]), (1, 2))
        self.assertEqual(got["total"], 1)

    def test_events_report_their_facets(self):
        got = api.events(self.cfg)
        self.assertEqual(got["facets"]["users"], ["alice", "bob"])
        self.assertIn("deny", got["facets"]["severities"])

    def test_events_filter_by_who_decided_and_by_tool(self):
        self.f.hooklog("denied", "alice", [
            {"ts": "2026-10-09T10:00:02Z", "user": "alice", "tool": "Write", "detail": "/etc/x", "denied_by": "hook"}])
        ingest.run(self.cfg)
        by_source = api.events(self.cfg, source="hook")
        self.assertEqual([(e["user"], e["tool"]) for e in by_source["rows"]], [("alice", "Write")])
        self.assertEqual(by_source["total"], 1)
        by_tool = api.events(self.cfg, tool="Bash", severity="deny")
        self.assertEqual([e["detail"] for e in by_tool["rows"]], ["sudo x"])
        self.assertEqual(api.events(self.cfg, tool="Write", source="rule")["total"], 0)

    def test_the_facets_list_only_the_deciders_and_tools_that_are_stored(self):
        f = api.events(self.cfg)["facets"]
        self.assertEqual(f["tools"], ["Bash"])
        self.assertEqual(f["sources"], sorted({e["source"] for e in api.events(self.cfg)["rows"]} - {""}))
        self.assertIn("rule", f["sources"])

    def test_sessions_report_age_and_filter_by_user(self):
        got = api.sessions(self.cfg, now=NOW)
        ages = {s["user"]: s["age_days"] for s in got["rows"]}
        self.assertEqual(ages, {"alice": 131, "bob": 1})
        only = api.sessions(self.cfg, user="alice", now=NOW)
        self.assertEqual([s["user"] for s in only["rows"]], ["alice"])
        self.assertEqual({u["user"] for u in got["by_user"]}, {"alice", "bob"})


class People(unittest.TestCase):
    """Limit hits and under-use per person, against their seat."""

    def setUp(self):
        self.f = Fleet()
        self.cfg = cfgmod.load(self.f.config(seats=[
            {"tier": "Max", "monthly_usd": 100.0, "users": ["alice", "dave"]},
            {"tier": "Pro", "monthly_usd": 20.0, "users": ["bob"]}]))
        q = lambda kind, at: {"status": "rejected", "rateLimitType": kind, "resetsAt": at}
        self.f.transcript("alice", "p", "s1", [
            assistant("a1", "ma1", "2026-10-08T10:00:00Z", "claude-opus-5-5", usage(i=900000, o=0, cr=0, cw=0)),
            assistant("a2", "ma2", "2026-10-09T10:00:00Z", "claude-opus-5-5", usage(i=100000, o=0, cr=0, cw=0),
                      quotaLimits=q("five_hour", 1)),
            assistant("a3", "ma3", "2026-10-09T11:00:00Z", "claude-opus-5-5", usage(i=0, o=0, cr=0, cw=0),
                      quotaLimits=q("five_hour", 1)),  # a retry inside the same window
            assistant("a4", "ma4", "2026-10-09T16:00:00Z", "claude-opus-5-5", usage(i=0, o=0, cr=0, cw=0),
                      quotaLimits=q("five_hour", 2)),
            assistant("a5", "ma5", "2026-10-09T17:00:00Z", "claude-opus-5-5", usage(i=0, o=0, cr=0, cw=0),
                      quotaLimits=q("seven_day", 3)),
            assistant("a6", "ma6", "2026-08-01T10:00:00Z", "claude-opus-5-5", usage(i=5, o=0, cr=0, cw=0),
                      quotaLimits=q("five_hour", 0)),  # outside the window
        ])
        self.f.transcript("bob", "p", "s1", [
            assistant("b1", "mb1", "2026-10-09T10:00:00Z", "claude-opus-5-5", usage(i=1000, o=0, cr=0, cw=0))])
        self.f.transcript("erin", "p", "s1", [
            assistant("e1", "me1", "2026-10-01T10:00:00Z", "claude-opus-5-5", usage(i=500000, o=0, cr=0, cw=0)),
            assistant("e2", "me2", "2026-10-02T10:00:00Z", "claude-opus-5-5", usage(i=0, o=0, cr=0, cw=0))])
        self.f.transcript("carol", "p", "s1", [
            assistant("c1", "mc1", "2026-08-20T10:00:00Z", "claude-opus-5-5", usage(i=50, o=0, cr=0, cw=0))])
        ingest.run(self.cfg)
        self.p = api.people(self.cfg, days=30, now=NOW)
        self.by = {r["user"]: r for r in self.p["rows"]}

    def tearDown(self):
        self.f.close()

    def test_everyone_with_use_or_a_seat_is_listed_once(self):
        self.assertEqual(sorted(self.by), ["alice", "bob", "carol", "dave", "erin"])

    def test_limit_hits_count_windows_inside_the_window(self):
        a = self.by["alice"]
        self.assertEqual((a["five_hour"], a["seven_day"]), (2, 1))
        self.assertEqual(a["last_limit"], "2026-10-09T17:00:00Z")
        self.assertEqual((self.by["bob"]["five_hour"], self.by["bob"]["last_limit"]), (0, None))

    def test_tokens_and_active_days_are_counted_in_the_window(self):
        a, e = self.by["alice"], self.by["erin"]
        self.assertEqual((a["tokens"], a["active_days"]), (1000000, 2))
        self.assertEqual((e["tokens"], e["active_days"], e["last_active"]), (500000, 2, "2026-10-02T10:00:00Z"))

    def test_a_seat_never_used_is_never_used_not_zero_days_ago(self):
        d = self.by["dave"]
        self.assertEqual((d["tier"], d["tokens"], d["last_active"]), ("Max", 0, None))
        self.assertEqual(d["under_use"], ["never used"])

    def test_no_use_for_longer_than_the_idle_limit_is_under_use(self):
        self.assertEqual(self.by["carol"]["under_use"], ["no use in 51 days"])
        self.assertIsNone(self.by["carol"]["tier"])

    def test_use_far_below_the_median_is_under_use(self):
        # median of people with use in the window: alice 1M, erin 500k, bob 1k -> 500k; 10% is 50k
        self.assertEqual(self.p["median_tokens"], 500000)
        self.assertEqual(self.by["bob"]["under_use"], ["under 10% of the median"])
        self.assertEqual(self.by["alice"]["under_use"], [])
        self.assertEqual(self.by["erin"]["under_use"], [])

    def test_the_rules_are_reported_with_the_figures(self):
        self.assertEqual(self.p["rules"], {"idle_days": 14, "median_fraction": 0.1})


class Prune(unittest.TestCase):
    def setUp(self):
        self.f = Fleet()
        self.cfg = cfgmod.load(self.f.config())

    def tearDown(self):
        self.f.close()

    def test_old_passes_go_and_old_denials_stay(self):
        self.f.hooklog("activity", "alice", [
            {"ts": "2026-08-01T10:00:00Z", "user": "alice", "tool": "Bash", "detail": "old pass"},
            {"ts": "2026-10-09T10:00:00Z", "user": "alice", "tool": "Bash", "detail": "new pass"}])
        self.f.hooklog("denied", "alice", [
            {"ts": "2026-08-01T10:00:00Z", "user": "alice", "tool": "Bash", "detail": "old deny", "denied_by": "r"}])
        ingest.run(self.cfg)
        removed = store.prune(self.cfg, now=NOW)
        self.assertEqual(removed.get("pass"), 1)
        left = sorted(e["detail"] for e in api.events(self.cfg)["rows"])
        self.assertEqual(left, ["new pass", "old deny"])

    def test_an_incident_goes_when_its_event_does_and_not_before(self):
        self.f.hooklog("denied", "alice", [
            {"ts": "2020-08-01T10:00:00Z", "tool": "Bash", "detail": "ancient", "denied_by": "r"},
            {"ts": "2026-10-09T10:00:00Z", "tool": "Bash", "detail": "recent", "denied_by": "r"}])
        ingest.run(self.cfg)
        store.prune(self.cfg, now=NOW)
        con = store.connect(self.cfg)
        try:
            self.assertEqual([r[0] for r in con.execute("select input from incidents")], ["recent"])
        finally:
            con.close()

    def test_a_row_cap_keeps_the_newest(self):
        cfg = dict(self.cfg)
        cfg["retention"] = dict(cfg["retention"], **{"pass": {"days": 3650, "max_rows": 2}})
        self.f.hooklog("activity", "alice", [
            {"ts": "2026-10-0%dT10:00:00Z" % d, "user": "alice", "tool": "Bash", "detail": "d%d" % d}
            for d in (1, 2, 3)])
        ingest.run(cfg)
        store.prune(cfg, now=NOW)
        self.assertEqual(sorted(e["detail"] for e in api.events(cfg)["rows"]), ["d2", "d3"])


class Server(unittest.TestCase):
    def setUp(self):
        self.f = Fleet()
        self.cfg = cfgmod.load(self.f.config())
        ingest.run(self.cfg)
        self.httpd = server.make_server(self.cfg, token="t0ken")
        self.port = self.httpd.server_address[1]
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()

    def tearDown(self):
        self.httpd.shutdown()
        self.httpd.server_close()
        self.f.close()

    def get(self, path, method="GET", headers=None):
        hdrs = {"X-Fleetdash-Token": "t0ken"} if headers is None else headers
        req = urllib.request.Request("http://127.0.0.1:%d%s" % (self.port, path), method=method,
                                     headers=hdrs)
        opener = urllib.request.build_opener(NoRedirect)
        try:
            with opener.open(req, timeout=5) as r:
                return r.status, r.read()
        except urllib.error.HTTPError as e:
            return e.code, e.read()

    def test_no_token_is_refused_because_loopback_is_shared(self):
        self.assertEqual(self.get("/api/overview", headers={})[0], 403)
        self.assertEqual(self.get("/api/status", headers={"X-Fleetdash-Token": "wrong"})[0], 403)
        # not bytes a header can be compared as: refused, not a crash
        self.assertEqual(self.get("/api/status", headers={"X-Fleetdash-Token": "t\u00f8ken"})[0], 403)

    def test_a_foreign_host_header_is_refused(self):
        self.assertEqual(self.get("/api/overview", headers={
            "X-Fleetdash-Token": "t0ken", "Host": "evil.example"})[0], 403)

    def test_the_api_answers_json(self):
        status, body = self.get("/api/overview?days=7")
        self.assertEqual(status, 200)
        self.assertIn("by_user", json.loads(body.decode()))

    def test_the_page_is_served(self):
        status, body = self.get("/")
        self.assertEqual(status, 200)
        self.assertIn(b"<html", body)

    def test_people_answers_json(self):
        status, body = self.get("/api/people?days=7")
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(body.decode())["days"], 7)

    def test_it_is_read_only(self):
        self.assertEqual(self.get("/api/overview", method="POST")[0], 405)

    def test_static_paths_cannot_leave_the_web_root(self):
        # a servable extension one level above the web root
        web = os.path.join(self.f.root, "web")
        os.makedirs(web)
        with open(os.path.join(web, "index.html"), "w") as fh:
            fh.write("<html>")
        with open(os.path.join(self.f.root, "secret.html"), "w") as fh:
            fh.write("secret")
        httpd = server.make_server(self.cfg, token="t0ken", web=web)
        threading.Thread(target=httpd.serve_forever, daemon=True).start()
        try:
            self.port, port = httpd.server_address[1], self.port
            self.assertEqual(self.get("/index.html")[0], 200)
            self.assertEqual(self.get("/%2e%2e/secret.html")[0], 404)
            self.assertEqual(self.get("/..%2fsecret.html")[0], 404)
        finally:
            httpd.shutdown()
            httpd.server_close()
            self.port = port

    def test_a_bad_parameter_is_a_400_not_a_crash(self):
        self.assertEqual(self.get("/api/overview?days=abc")[0], 400)


if __name__ == "__main__":
    unittest.main()
