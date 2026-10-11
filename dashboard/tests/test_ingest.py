import json
import os
import pwd
import sqlite3
import tracemalloc
import unittest

from fleetdash import config as cfgmod
from fleetdash import ingest, store
from tests.fixtures import CANARY, Fleet, assistant, usage

ME = pwd.getpwuid(os.geteuid()).pw_name


def rows(db, sql, *args):
    con = sqlite3.connect(db)
    try:
        return con.execute(sql, args).fetchall()
    finally:
        con.close()


class IngestTranscripts(unittest.TestCase):
    def setUp(self):
        self.f = Fleet()
        self.cfg = cfgmod.load(self.f.config())

    def tearDown(self):
        self.f.close()

    def run_ingest(self):
        return ingest.run(self.cfg)

    def test_usage_is_one_row_per_message_and_the_last_line_wins(self):
        # Streaming writes the same message id more than once; counting each
        # line would double the tokens.
        self.f.transcript("alice", "p1", "s1", [
            assistant("aa1", "m1", "2026-10-01T10:00:00Z", "claude-opus-5-5", usage(o=5)),
            assistant("aa2", "m1", "2026-10-01T10:00:01Z", "claude-opus-5-5", usage(o=20)),
            assistant("aa3", "m2", "2026-10-01T10:01:00Z", "claude-opus-5-5", usage(o=7)),
        ])
        self.run_ingest()
        got = rows(self.cfg["store"], "select id, output from usage order by id")
        self.assertEqual(got, [("m1", 20), ("m2", 7)])
        self.assertEqual(rows(self.cfg["store"], "select distinct user from usage"), [("alice",)])

    def test_no_message_content_reaches_the_store(self):
        self.f.transcript("alice", "p1", "s1", [
            {"type": "user", "uuid": "u1", "timestamp": "2026-10-01T10:00:00Z",
             "message": {"role": "user", "content": "prompt " + CANARY}},
            assistant("aa1", "m1", "2026-10-01T10:00:01Z", "claude-opus-5-5", usage()),
            {"type": "system", "subtype": "local_command", "uuid": "c1",
             "timestamp": "2026-10-01T10:02:00Z",
             "commandRun": {"command": "review", "args": "secret " + CANARY}},
        ])
        self.run_ingest()
        with open(self.cfg["store"], "rb") as fh:
            self.assertNotIn(CANARY.encode(), fh.read())
        cmds = rows(self.cfg["store"], "select category, detail from events where category='slash-command'")
        self.assertEqual(cmds, [("slash-command", "/review")])

    def test_a_rejected_quota_is_a_rate_limit_event_and_an_allowed_one_is_not(self):
        self.f.transcript("bob", "p1", "s1", [
            assistant("aa1", "m1", "2026-10-01T10:00:00Z", "claude-opus-5-5", usage(),
                      quotaLimits={"status": "rejected", "rateLimitType": "five_hour", "resetsAt": 1}),
            assistant("aa2", "m2", "2026-10-01T10:00:00Z", "claude-opus-5-5", usage(),
                      quotaLimits={"status": "allowed", "rateLimitType": "seven_day"}),
        ])
        self.run_ingest()
        got = rows(self.cfg["store"], "select user, severity, detail from events where category='rate-limit'")
        self.assertEqual(got, [("bob", "quota", "five_hour rejected")])

    def test_a_limit_hit_is_one_event_per_window_not_one_per_retry(self):
        # a person blocked for five hours retries many times; each retry is a
        # record, but they hit the limit once
        q5 = {"status": "rejected", "rateLimitType": "five_hour", "resetsAt": 1790405400}
        self.f.transcript("bob", "p1", "s1", [
            assistant("r1", "m1", "2026-10-01T10:00:00Z", "claude-opus-5-5", usage(), quotaLimits=q5),
            assistant("r2", "m2", "2026-10-01T10:05:00Z", "claude-opus-5-5", usage(), quotaLimits=q5),
            assistant("r3", "m3", "2026-10-01T11:00:00Z", "claude-opus-5-5", usage(),
                      quotaLimits=dict(q5, resetsAt=1790423400)),
            assistant("r4", "m4", "2026-10-01T11:00:00Z", "claude-opus-5-5", usage(),
                      quotaLimits=dict(q5, rateLimitType="seven_day")),
        ])
        self.f.transcript("carol", "p1", "s1", [  # the same window for someone else is their own hit
            assistant("c1", "mc1", "2026-10-01T10:00:00Z", "claude-opus-5-5", usage(), quotaLimits=q5)])
        self.run_ingest()
        got = rows(self.cfg["store"], "select user, ts, detail from events where category='rate-limit' order by user, ts, detail")
        self.assertEqual(got, [("bob", "2026-10-01T10:00:00Z", "five_hour rejected"),
                               ("bob", "2026-10-01T11:00:00Z", "five_hour rejected"),
                               ("bob", "2026-10-01T11:00:00Z", "seven_day rejected"),
                               ("carol", "2026-10-01T10:00:00Z", "five_hour rejected")])

    def test_an_api_error_is_an_error_event_with_its_status(self):
        self.f.transcript("bob", "p1", "s1", [
            {"type": "assistant", "uuid": "e1", "timestamp": "2026-10-01T10:00:00Z",
             "isApiErrorMessage": True, "apiErrorStatus": 529,
             "message": {"content": [{"type": "text", "text": CANARY}]}},
        ])
        self.run_ingest()
        got = rows(self.cfg["store"], "select severity, detail from events where category='api-error'")
        self.assertEqual(got, [("error", "HTTP 529")])

    def test_skill_plugin_and_denial_attributions_are_events(self):
        self.f.transcript("carol", "p1", "s1", [
            assistant("aa1", "m1", "2026-10-01T10:00:00Z", "claude-opus-5-5", usage(),
                      attributionSkill="code-review", attributionPlugin="superpowers"),
            {"type": "user", "uuid": "d1", "timestamp": "2026-10-01T10:00:02Z",
             "toolDenialKind": "permission-rule", "message": {"content": CANARY}},
        ])
        self.run_ingest()
        got = sorted(rows(self.cfg["store"], "select category, severity, source, detail from events"))
        self.assertEqual(got, [
            ("denial", "deny", "permission-rule", ""),
            ("plugin", "info", "", "superpowers"),
            ("skill", "info", "", "code-review"),
        ])

    def test_a_person_saying_no_is_not_a_policy_block_but_an_unknown_kind_is(self):
        self.f.transcript("carol", "p1", "s1", [
            {"type": "user", "uuid": "d%d" % i, "timestamp": "2026-10-01T10:00:0%dZ" % i, "toolDenialKind": k}
            for i, k in enumerate(["user-rejected", "interrupted", "automode-blocked", "something-new"])])
        self.run_ingest()
        got = sorted(rows(self.cfg["store"], "select source, severity from events"))
        self.assertEqual(got, [("automode-blocked", "deny"), ("interrupted", "info"),
                               ("something-new", "deny"), ("user-rejected", "info")])

    def test_sessions_record_size_age_and_owner(self):
        p = self.f.transcript("alice", "p1", "s1", [
            assistant("aa1", "m1", "2026-09-01T10:00:00Z", "claude-opus-5-5", usage()),
            assistant("aa2", "m2", "2026-09-03T10:00:00Z", "claude-opus-5-5", usage()),
        ])
        self.run_ingest()
        got = rows(self.cfg["store"], "select user, bytes, first_ts, last_ts, records from sessions")
        self.assertEqual(got, [("alice", os.path.getsize(p), "2026-09-01T10:00:00Z", "2026-09-03T10:00:00Z", 2)])


class IngestIsIdempotent(unittest.TestCase):
    def setUp(self):
        self.f = Fleet()
        self.cfg = cfgmod.load(self.f.config())

    def tearDown(self):
        self.f.close()

    def count(self):
        return rows(self.cfg["store"], "select count(*) from usage")[0][0]

    def test_a_second_run_adds_nothing_and_an_append_adds_only_the_new_line(self):
        self.f.transcript("alice", "p1", "s1", [
            assistant("aa1", "m1", "2026-10-01T10:00:00Z", "claude-opus-5-5", usage())])
        ingest.run(self.cfg)
        ingest.run(self.cfg)
        self.assertEqual(self.count(), 1)
        self.f.transcript("alice", "p1", "s1", [
            assistant("aa2", "m2", "2026-10-01T10:05:00Z", "claude-opus-5-5", usage())])
        ingest.run(self.cfg)
        self.assertEqual(self.count(), 2)
        self.assertEqual(rows(self.cfg["store"], "select records from sessions")[0][0], 2)

    def test_a_half_written_line_waits_for_its_newline(self):
        p = self.f.transcript("alice", "p1", "s1", [])
        line = json.dumps(assistant("aa1", "m1", "2026-10-01T10:00:00Z", "claude-opus-5-5", usage()))
        with open(p, "a") as fh:
            fh.write(line[:30])
        ingest.run(self.cfg)
        self.assertEqual(self.count(), 0)
        with open(p, "a") as fh:
            fh.write(line[30:] + "\n")
        ingest.run(self.cfg)
        self.assertEqual(self.count(), 1)

    def test_a_rotated_log_is_read_from_the_start(self):
        rec = {"ts": "2026-10-01T10:00:00Z", "user": "alice", "session": "s", "tool": "Bash", "detail": "ls"}
        p = self.f.hooklog("activity", "alice", [rec, rec])
        ingest.run(self.cfg)
        os.remove(p)
        rec2 = dict(rec, detail="make", ts="2026-10-02T10:00:00Z")
        self.f.hooklog("activity", "alice", [rec2])
        ingest.run(self.cfg)
        got = rows(self.cfg["store"], "select detail from events where category='tool-call' order by ts")
        self.assertEqual(got, [("ls",), ("ls",), ("make",)])

    def test_a_log_truncated_in_place_is_read_from_the_start(self):
        # logrotate copytruncate keeps the inode; only the size shows it
        rec = {"ts": "2026-10-01T10:00:00Z", "user": "alice", "tool": "Bash", "detail": "a long first command"}
        p = self.f.hooklog("activity", "alice", [rec, rec])
        ingest.run(self.cfg)
        with open(p, "w") as fh:
            fh.write(json.dumps(dict(rec, detail="x", ts="2026-10-02T10:00:00Z")) + "\n")
        ingest.run(self.cfg)
        got = rows(self.cfg["store"], "select detail from events order by ts")
        self.assertEqual([g[0] for g in got][-1], "x")


class IngestHookLogs(unittest.TestCase):
    def setUp(self):
        self.f = Fleet()
        self.cfg = cfgmod.load(self.f.config())

    def tearDown(self):
        self.f.close()

    def test_activity_redaction_and_denial_records_map_to_categories(self):
        self.f.hooklog("activity", "alice", [
            {"ts": "2026-10-01T10:00:00Z", "user": "alice", "session": "s", "tool": "Bash", "detail": "make test"},
            {"ts": "2026-10-01T10:00:01Z", "user": "alice", "session": "s", "event": "redaction",
             "tool": "Read", "kinds": ["private-key"], "count": 1},
        ])
        self.f.hooklog("denied", "alice", [
            {"ts": "2026-10-01T10:00:02Z", "user": "alice", "session": "s", "tool": "Bash",
             "detail": "curl x", "denied_by": "Blocked by classifier", "category": ""},
        ])
        ingest.run(self.cfg)
        got = sorted(rows(self.cfg["store"], "select category, severity, source, tool, detail from events"))
        self.assertEqual(got, [
            ("denial", "deny", "Blocked by classifier", "Bash", "curl x"),
            ("redaction", "redact", "cc-redact-hook", "Read", "private-key x1"),
            ("tool-call", "pass", "", "Bash", "make test"),
        ])

    def test_a_log_not_owned_by_its_named_user_is_not_read(self):
        # The log directories are sticky and world-writable: anyone can
        # create <victim>.jsonl. Here the runner owns a file named for alice.
        cfg = cfgmod.load(self.f.config(verify_file_owner=True))
        self.f.hooklog("denied", "alice", [
            {"ts": "2026-10-01T10:00:00Z", "user": "alice", "tool": "Bash", "detail": "forged"}])
        stats = ingest.run(cfg)
        got = rows(cfg["store"], "select user, severity, category, detail from events")
        self.assertEqual(got, [("alice", "error", "log-integrity", "file not read: owner " + ME)])
        self.assertEqual(len(stats["skipped"]), 1)

    def test_a_bad_line_is_counted_not_swallowed(self):
        p = self.f.hooklog("activity", "alice", [])
        with open(p, "a") as fh:
            fh.write("not json\n")
        self.assertEqual(ingest.run(self.cfg)["bad_lines"], 1)


class IngestRefusesHostileFiles(unittest.TestCase):
    """Every file is written by the user it describes, so every file is
    hostile to every other user's data and to the collector itself."""

    def setUp(self):
        self.f = Fleet()
        self.cfg = cfgmod.load(self.f.config())
        self.strict = cfgmod.load(self.f.config(verify_file_owner=True))

    def tearDown(self):
        self.f.close()

    def zed(self):
        self.f.transcript("zed", "p", "s", [assistant("z1", "zz", "2026-10-01T10:00:00Z", "claude-opus-5-5", usage())])

    def test_one_bad_record_does_not_stop_everyone_elses_ingest(self):
        self.f.transcript("mallory", "p", "s", [
            assistant("m1", "x1", "2026-10-01T10:00:00Z", "claude-opus-5-5", {"input_tokens": "x"}),
            {"type": "system", "uuid": "c1", "timestamp": "2026-10-01T10:00:00Z", "commandRun": {"command": "   "}},
            assistant("m2", "x2", "2026-10-01T10:00:00Z", "claude-opus-5-5", usage(), attributionSkill={"a": 1}),
        ])
        self.f.hooklog("activity", "mallory", [
            {"ts": "2026-10-01T10:00:00Z", "tool": "Bash", "detail": {"a": 1}},
            {"ts": "2026-10-01T10:00:00Z", "event": "redaction", "tool": "Read", "kinds": [1, None], "count": 1}])
        self.zed()
        stats = ingest.run(self.cfg)
        self.assertEqual(rows(self.cfg["store"], "select user from usage where id='zz'"), [("zed",)])
        self.assertEqual(stats["bad_lines"], 2)  # the token count and the blank command
        # a record that failed wrote nothing at all, not half its rows
        self.assertEqual(rows(self.cfg["store"], "select count(*) from usage where id='x1'"), [(0,)])

    def test_a_timestamp_that_is_not_utc_iso_or_is_in_the_future_is_a_bad_record(self):
        # a timestamp sorts as text: "zzz" or year 9999 would sit inside every
        # window and make its writer look active today, for ever
        bad = ["t", "zzz", "9999-01-01T00:00:00Z", "2026-13-01T00:00:00Z", "2026-10-01T10:00:00+05:00",
               "2026-10-01 10:00:00", 1759312800, ["2026-10-01T10:00:00Z"],
               # digits strptime reads as 2026 but that sort after every ASCII date
               "\u0662\u0660\u0662\u0666-10-01T10:00:00Z", "\uff12\uff10\uff12\uff16-10-01T10:00:00Z",
               "2026-10-01T10:00:00Z\n"]
        self.f.transcript("mallory", "p", "s", [assistant("m%d" % i, "x%d" % i, ts, "claude-opus-5-5", usage())
                                                for i, ts in enumerate(bad)])
        self.f.hooklog("activity", "mallory", [{"ts": ts, "tool": "Bash", "detail": "ls"} for ts in bad])
        self.zed()
        stats = ingest.run(self.cfg)
        self.assertEqual(stats["bad_lines"], 2 * len(bad))
        self.assertEqual(rows(self.cfg["store"], "select count(*) from usage where user='mallory'"), [(0,)])
        self.assertEqual(rows(self.cfg["store"], "select count(*) from events where user='mallory'"), [(0,)])
        self.assertEqual(rows(self.cfg["store"], "select last_ts from sessions where user='mallory'"), [(None,)])

    def test_the_timestamps_claude_code_and_the_hooks_write_are_read(self):
        good = ["2026-10-01T10:00:00Z", "2026-10-01T10:00:00.123Z", "2026-10-01T10:00:00.123456+00:00",
                "2026-10-01T10:00:00+00:00"]
        self.f.transcript("ann", "p", "s", [assistant("a%d" % i, "y%d" % i, ts, "claude-opus-5-5", usage())
                                            for i, ts in enumerate(good)])
        self.f.hooklog("activity", "ann", [{"ts": ts, "tool": "Bash", "detail": "ls"} for ts in good]
                       + [{"tool": "Bash", "detail": "no time at all"}])  # missing is unknown, not wrong
        stats = ingest.run(self.cfg)
        self.assertEqual(stats["bad_lines"], 0)
        self.assertEqual(rows(self.cfg["store"], "select count(*) from usage where user='ann'"), [(4,)])
        self.assertEqual(rows(self.cfg["store"], "select count(*) from events where user='ann'"), [(5,)])

    def test_an_overlong_line_is_a_bad_record_whether_it_spans_chunks_or_not(self):
        for chunk in (256, 1 << 16):  # spread over many reads, and inside one
            f = Fleet()
            try:
                cfg = cfgmod.load(f.config())
                p = f.transcript("mallory", "p", "s", [])
                with open(p, "w") as fh:
                    # valid JSON, so only the length can make it a bad record
                    fh.write(json.dumps(assistant("m0", "huge", "2026-10-01T10:00:00Z", "claude-opus-5-5",
                                                  usage(), pad="x" * 5000)) + "\n" + json.dumps(
                        assistant("m1", "after", "2026-10-01T10:00:00Z", "claude-opus-5-5", usage())) + "\n")
                old = ingest.LINE_MAX, ingest.CHUNK
                ingest.LINE_MAX, ingest.CHUNK = 1000, chunk
                try:
                    stats = ingest.run(cfg)
                finally:
                    ingest.LINE_MAX, ingest.CHUNK = old
                self.assertEqual(stats["bad_lines"], 1, chunk)
                self.assertEqual(rows(cfg["store"], "select id from usage"), [("after",)])
            finally:
                f.close()

    def test_a_line_with_no_end_is_not_held_in_memory(self):
        class Endless(object):  # 8 MB of one line, then its newline
            def __init__(self):
                self.left = 8 << 20
            def seek(self, n):
                pass
            def read(self, n):
                if self.left <= 0:
                    return b"\n" if self.left == 0 and not setattr(self, "left", -1) else b""
                self.left -= n
                return b"x" * n
        old = ingest.LINE_MAX, ingest.CHUNK
        ingest.LINE_MAX, ingest.CHUNK = 1 << 16, 1 << 16
        tracemalloc.start()
        try:
            got = list(ingest.complete_lines(Endless(), 0))
            peak = tracemalloc.get_traced_memory()[1]
        finally:
            tracemalloc.stop()
            ingest.LINE_MAX, ingest.CHUNK = old
        self.assertEqual([(start, raw) for start, _end, raw in got], [(0, None)])
        self.assertLess(peak, 1 << 20)

    def test_reusing_another_users_message_id_cannot_rewrite_their_row(self):
        self.f.transcript("alice", "p", "s", [
            assistant("a1", "msg-A", "2026-10-01T10:00:00Z", "claude-opus-5-5", usage(o=999))])
        ingest.run(self.cfg)
        self.f.transcript("mallory", "p", "s", [
            assistant("b1", "msg-A", "2026-10-01T10:00:00Z", "claude-opus-5-5", usage(o=1))])
        ingest.run(self.cfg)
        self.assertEqual(rows(self.cfg["store"], "select user, output from usage order by user"),
                         [("alice", 999), ("mallory", 1)])

    def test_a_symlinked_transcript_is_not_followed(self):
        self.f.transcript("alice", "p", "s", [
            assistant("a1", "msg-A", "2026-10-01T10:00:00Z", "claude-opus-5-5", usage())])
        d = os.path.join(self.f.root, "home", "mallory", ".claude", "projects", "p")
        os.makedirs(d)
        os.symlink(os.path.join(self.f.root, "home", "alice", ".claude", "projects", "p", "s.jsonl"),
                   os.path.join(d, "stolen.jsonl"))
        ingest.run(self.cfg)
        self.assertEqual(rows(self.cfg["store"], "select user from sessions"), [("alice",)])
        self.assertEqual(rows(self.cfg["store"], "select user from usage"), [("alice",)])

    def test_a_hook_log_symlinked_to_a_file_its_user_owns_is_refused(self):
        # the owner check alone passes: the target really is owned by ME
        target = self.f.transcript(ME, "p", "s", [{"ts": "t", "tool": "Bash", "detail": "forged"}])
        os.makedirs(os.path.join(self.f.root, "log", "denied"))
        os.symlink(target, os.path.join(self.f.root, "log", "denied", ME + ".jsonl"))
        ingest.run(self.strict)
        got = rows(self.strict["store"], "select category from events where detail='forged'")
        self.assertEqual(got, [])
        self.assertEqual(rows(self.strict["store"], "select count(*) from events where category='log-integrity'"), [(1,)])

    def test_a_hard_link_to_another_users_transcript_is_refused(self):
        a = self.f.transcript("alice", "p", "s", [
            assistant("a1", "msg-A", "2026-10-01T10:00:00Z", "claude-opus-5-5", usage())])
        d = os.path.join(self.f.root, "home", "mallory", ".claude", "projects", "p")
        os.makedirs(d)
        os.link(a, os.path.join(d, "stolen.jsonl"))
        stats = ingest.run(self.cfg)
        self.assertEqual(rows(self.cfg["store"], "select user from usage"), [])
        self.assertEqual(len(stats["skipped"]), 2)

    def test_a_store_from_before_the_per_user_key_is_refused_not_mixed(self):
        con = sqlite3.connect(self.cfg["store"])
        con.execute("create table usage (id text primary key, ts text, user text, session text, model text,"
                    " input int, output int, cache_read int, cache_write int)")
        con.close()
        with self.assertRaises(store.StoreError):
            ingest.run(self.cfg)

    def test_a_store_written_under_another_schema_version_is_refused(self):
        ingest.run(self.cfg)
        con = sqlite3.connect(self.cfg["store"])
        with con:
            con.execute("update meta set v='1' where k='schema'")
        con.close()
        with self.assertRaises(store.StoreError):
            ingest.run(self.cfg)

    def test_a_new_store_is_stamped_and_reopens(self):
        ingest.run(self.cfg)
        ingest.run(self.cfg)
        self.assertEqual(rows(self.cfg["store"], "select v from meta where k='schema'"), [(str(store.SCHEMA_VERSION),)])

    def test_a_transcript_not_owned_by_its_home_user_is_refused(self):
        self.f.transcript("alice", "p", "s", [  # written by the test runner, under alice's home
            assistant("a1", "msg-A", "2026-10-01T10:00:00Z", "claude-opus-5-5", usage())])
        self.f.transcript(ME, "p", "s", [
            assistant("m1", "msg-M", "2026-10-01T10:00:00Z", "claude-opus-5-5", usage())])
        stats = ingest.run(self.strict)
        self.assertEqual(rows(self.strict["store"], "select user from usage"), [(ME,)])
        self.assertEqual(rows(self.strict["store"], "select user, category from events"), [("alice", "log-integrity")])
        self.assertEqual(len(stats["skipped"]), 1)


if __name__ == "__main__":
    unittest.main()
