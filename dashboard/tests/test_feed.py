"""The push path: a person's `feed` writes a batch, the collector's `ingest`
reads the spool. The collector here never reads a home."""
import json
import os
import pwd
import sqlite3
import unittest

from fleetdash import config as cfgmod
from fleetdash import feed, ingest, spool
from tests.fixtures import CANARY, Fleet, assistant, usage

ME = pwd.getpwuid(os.geteuid()).pw_name
TS = "2026-10-01T10:00:00Z"


def rows(db, sql, *args):
    con = sqlite3.connect(db)
    try:
        return con.execute(sql, args).fetchall()
    finally:
        con.close()


class Pushed(unittest.TestCase):
    """One fleet tree, two configs: the feeding person's (host-a) and the
    collector's, which has a spool and no direct source."""

    def setUp(self):
        self.f = Fleet()
        self.spool = os.path.join(self.f.root, "spool")
        os.mkdir(self.spool, 0o700)
        self.mine = os.path.join(self.f.root, "home", ME, ".claude", "projects")
        self.collector = cfgmod.load(self.f.config(spool=self.spool, transcript_glob="", hook_log_dir="",
                                                   host_label="collector", verify_file_owner=True))
        self.db = self.collector["store"]

    def tearDown(self):
        self.f.close()

    def feeder(self, host="host-a"):
        return dict(self.collector, host_label=host, hook_log_dir=os.path.join(self.f.root, "log"),
                    feed={"transcripts": self.mine, "state_dir": os.path.join(self.f.root, "state")})

    def use(self, n=1, msg="m1"):
        self.f.transcript(ME, "p1", "s1", [
            assistant("u%d" % n, msg, TS, "claude-opus-5-5", usage(o=n), attributionSkill="review")])
        self.f.hooklog("denied", ME, [{"ts": TS, "tool": "Bash", "detail": "sudo x", "denied_by": "rule"}])

    def batches(self):
        return sorted(n for n in os.listdir(self.spool))

    def test_a_feed_then_an_ingest_lands_the_persons_rows_and_empties_the_spool(self):
        self.use()
        sent = feed.run(self.feeder())["sent"]
        self.assertEqual(sent, {"event": 2, "incident": 1, "usage": 1, "session": 1})
        self.assertEqual(len(self.batches()), 1)
        stats = ingest.run(self.collector)
        self.assertEqual((stats["bad_lines"], stats["skipped"]), (0, []))
        self.assertEqual(rows(self.db, "select user, id, output from usage"), [(ME, "m1", 1)])
        self.assertEqual(rows(self.db, "select user, bytes > 0 from sessions"), [(ME, 1)])
        self.assertEqual(sorted(rows(self.db, "select category, host from events")),
                         [("denial", "host-a"), ("skill", "")])
        # what the stopped call asked for arrives beside its event
        self.assertEqual(rows(self.db, "select e.host, i.input, i.input_len, i.said from incidents i "
                              "join events e on e.key=i.key"), [("host-a", "sudo x", 6, "")])
        self.assertEqual(self.batches(), [])

    def test_a_second_feed_sends_only_what_is_new_and_a_changed_message_replaces_its_row(self):
        self.use()
        feed.run(self.feeder())
        # the same message id, written again with more output, as streaming does
        self.f.transcript(ME, "p1", "s1", [assistant("u9", "m1", TS, "claude-opus-5-5", usage(o=50))])
        sent = feed.run(self.feeder())["sent"]
        self.assertEqual(sent, {"event": 0, "incident": 0, "usage": 1, "session": 1})
        ingest.run(self.collector)
        self.assertEqual(rows(self.db, "select id, output from usage"), [("m1", 50)])

    def test_reading_a_log_a_second_time_sends_no_stopped_call_again(self):
        self.use()
        feed.run(self.feeder())
        # the private store forgets how far it read, so every line is read again
        con = sqlite3.connect(os.path.join(self.f.root, "state", "store.db"))
        with con:
            con.execute("delete from checkpoints")
        con.close()
        sent = feed.run(self.feeder())["sent"]
        self.assertEqual((sent["event"], sent["incident"]), (0, 0))

    def test_a_feed_with_nothing_new_still_checks_the_host_in(self):
        sent = feed.run(self.feeder())["sent"]
        self.assertEqual(sent, {"event": 0, "incident": 0, "usage": 0, "session": 0})
        ingest.run(self.collector)
        self.assertEqual(rows(self.db, "select host, reported_by from hosts where host='host-a'"),
                         [("host-a", ME)])

    def test_a_batch_read_twice_counts_once(self):
        self.use()
        feed.run(self.feeder())
        name = self.batches()[0]
        with open(os.path.join(self.spool, name), "rb") as fh:
            copy = fh.read()
        ingest.run(self.collector)
        before = rows(self.db, "select count(*) from events") + rows(self.db, "select count(*) from usage")
        with open(os.path.join(self.spool, "again.jsonl"), "wb") as fh:
            fh.write(copy)
        ingest.run(self.collector)
        self.assertEqual(rows(self.db, "select count(*) from events") + rows(self.db, "select count(*) from usage"),
                         before)

    def test_a_crash_after_the_batch_is_written_sends_the_rows_again_not_never(self):
        self.use()
        real = feed.os.rename

        def crash_after(a, b):
            real(a, b)
            raise KeyboardInterrupt()
        feed.os.rename = crash_after
        try:
            with self.assertRaises(KeyboardInterrupt):
                feed.run(self.feeder())
        finally:
            feed.os.rename = real
        self.assertEqual(feed.run(self.feeder())["sent"]["usage"], 1)

    def test_two_hosts_feed_one_store_and_the_same_hook_log_path_is_two_logs(self):
        # /var/log is local to each host: the same path holds different lines on each
        self.use()
        feed.run(self.feeder("host-a"))
        os.unlink(os.path.join(self.f.root, "log", "denied", ME + ".jsonl"))
        self.f.hooklog("denied", ME, [{"ts": TS, "tool": "Bash", "detail": "curl x", "denied_by": "rule"}])
        feed.run(self.feeder("host-b"))
        ingest.run(self.collector)
        self.assertEqual(sorted(rows(self.db, "select host, detail from events where category='denial'")),
                         [("host-a", "sudo x"), ("host-b", "curl x")])
        self.assertEqual(rows(self.db, "select host from hosts order by host"),
                         [("collector",), ("host-a",), ("host-b",)])

    def test_no_message_content_reaches_the_batch(self):
        self.use()
        feed.run(self.feeder())
        with open(os.path.join(self.spool, self.batches()[0]), "rb") as fh:
            self.assertNotIn(CANARY.encode(), fh.read())

    def test_a_batch_in_my_own_spool_is_closed_to_everyone_else(self):
        feed.run(self.feeder())
        self.assertEqual(os.stat(os.path.join(self.spool, self.batches()[0])).st_mode & 0o077, 0)

    def test_a_second_feed_while_one_runs_steps_aside(self):
        import fcntl
        state = self.feeder()["feed"]["state_dir"]
        os.makedirs(state)
        held = os.open(os.path.join(state, "lock"), os.O_CREAT | os.O_RDWR, 0o600)
        fcntl.flock(held, fcntl.LOCK_EX)
        try:
            self.assertEqual(feed.run(self.feeder()), {"busy": True})
        finally:
            os.close(held)
        self.assertEqual(self.batches(), [])

    def test_with_no_spool_configured_feed_refuses(self):
        with self.assertRaises(feed.FeedError):
            feed.run(dict(self.feeder(), spool=""))

    def test_a_spool_it_cannot_write_to_is_an_error_and_the_rows_go_next_time(self):
        self.use()
        with self.assertRaises(feed.FeedError):
            feed.run(dict(self.feeder(), spool=os.path.join(self.f.root, "no-such-dir")))
        self.assertEqual(feed.run(self.feeder())["sent"]["usage"], 1)


class HostileBatches(unittest.TestCase):
    def setUp(self):
        self.f = Fleet()
        self.spool = os.path.join(self.f.root, "spool")
        os.mkdir(self.spool, 0o700)
        self.cfg = cfgmod.load(self.f.config(spool=self.spool, transcript_glob="", hook_log_dir="",
                                             verify_file_owner=True))
        self.db = self.cfg["store"]

    def tearDown(self):
        self.f.close()

    def batch(self, lines, user=ME, name="1.jsonl", **head):
        h = {"t": "batch", "v": 1, "host": "host-a", "user": user, "ts": TS,
             "claude_version": "2.1.0", "policy_sha256": None}
        h.update(head)
        path = os.path.join(self.spool, name)
        with open(path, "w") as fh:
            for rec in [h] + lines:
                fh.write((rec if isinstance(rec, str) else json.dumps(rec)) + "\n")
        return path

    def event(self, **over):
        e = {"t": "event", "key": "k1", "ts": TS, "session": "s", "severity": "deny", "category": "denial",
             "source": "rule", "tool": "Bash", "detail": "x", "host": "host-a"}
        e.update(over)
        return e

    def incident(self, **over):
        i = {"t": "incident", "key": "k1", "input": "sudo x", "input_kind": "command", "input_len": 6,
             "fields": '["command"]', "said": "Refused", "cwd": "/w", "branch": "main", "client": "2.1.0", "call_id": "t1"}
        i.update(over)
        return i

    INCIDENTS = "select e.user, i.input, i.input_kind, i.input_len, i.fields, i.said, i.cwd, i.branch, i.client, " \
                "i.call_id from incidents i join events e on e.key=i.key order by i.input"

    def test_an_incident_lands_beside_its_event_under_the_files_owner(self):
        self.batch([self.incident(), self.event(), self.incident(key="k2", input=None, input_kind="", input_len=None,
                                                                 fields=None, said="", cwd="", branch="", client=""),
                    self.event(key="k2")])
        stats = ingest.run(self.cfg)
        self.assertEqual(stats["bad_lines"], 0)
        self.assertEqual(rows(self.db, self.INCIDENTS), [
            (ME, None, "", None, None, "", "", "", "", "t1"),
            (ME, "sudo x", "command", 6, '["command"]', "Refused", "/w", "main", "2.1.0", "t1")])

    def test_an_incident_cannot_be_written_over_another_persons(self):
        ingest.run(self.cfg)
        con = sqlite3.connect(self.db)
        with con:
            con.execute(*ingest.event("victim|k1", TS, "victim", "s", "deny", "denial", "rule", "Bash", "theirs"))
            con.execute(*ingest.incident("victim|k1", ("command", "theirs")))
        con.close()
        self.batch([self.incident(key="victim|k1", input="forged"), self.incident(input="mine"), self.event()])
        ingest.run(self.cfg)
        self.assertEqual(rows(self.db, self.INCIDENTS), [(ME, "mine") + rows(self.db, self.INCIDENTS)[0][2:],
                                                         ("victim", "theirs", "command", 6, None, "", "", "", "", "")])

    def test_an_incident_with_a_bad_value_is_a_bad_line(self):
        bad = [dict(input_kind="body"), dict(input=7), dict(input_len=-1), dict(input_len="6"), dict(fields="{}"),
               dict(fields='["a", 7]'), dict(fields=json.dumps(["f%d" % i for i in range(99)])),
               dict(fields='["%s"]' % ("x" * 500)), dict(said=None), dict(cwd=["/"]), dict(branch=7),
               dict(client="latest"), dict(call_id=None), dict(key=""), dict(input="\ud800")]
        self.batch([self.incident(key="b%d" % n, **over) if "key" not in over else self.incident(**over)
                    for n, over in enumerate(bad)] + [{"t": "incident", "key": "short"}])
        stats = ingest.run(self.cfg)
        self.assertEqual((stats["bad_lines"], rows(self.db, "select count(*) from incidents")), (len(bad) + 1, [(0,)]))

    def test_an_incident_is_held_to_its_limits_whatever_the_batch_says(self):
        self.batch([self.incident(input="x" * 99999, input_len=99999, said="y" * 99999, cwd="/" * 99999,
                                  branch="b" * 99999, call_id="t" * 99999), self.event()])
        ingest.run(self.cfg)
        (got,) = rows(self.db, "select length(input), input_len, length(said), length(cwd), length(branch), "
                               "length(call_id) from incidents")
        held = ingest.INPUT_MAX + ingest.CUT_NOTE_MAX
        self.assertEqual(got, (held, 99999, held, ingest.PLACE_MAX, ingest.PLACE_MAX, ingest.CODE_MAX))

    def usage_row(self, **over):
        u = {"t": "usage", "id": "m1", "ts": TS, "session": "s", "model": "claude-opus-5-5",
             "input": 1, "output": 2, "cache_read": 3, "cache_write": 4}
        u.update(over)
        return u

    def test_a_batch_that_names_someone_else_is_refused_and_recorded_under_its_owner(self):
        self.batch([self.usage_row()], user="victim")
        stats = ingest.run(self.cfg)
        self.assertEqual(len(stats["skipped"]), 1)
        self.assertEqual(rows(self.db, "select count(*) from usage"), [(0,)])
        self.assertEqual(rows(self.db, "select user, category from events"), [(ME, "log-integrity")])
        self.assertEqual(os.listdir(self.spool), [])

    def test_every_row_is_stored_under_the_files_owner_whatever_the_row_says(self):
        self.batch([dict(self.usage_row(), user="victim"), dict(self.event(), user="victim")])
        ingest.run(self.cfg)
        self.assertEqual(rows(self.db, "select distinct user from usage"), [(ME,)])
        self.assertEqual(rows(self.db, "select distinct user from events"), [(ME,)])

    def test_an_event_key_cannot_name_another_persons_event(self):
        # the victim's event, stored under the key a batch from them would get
        ingest.run(self.cfg)
        con = sqlite3.connect(self.db)
        with con:
            con.execute(*ingest.event("victim|k1", TS, "victim", "s", "deny", "denial", "rule", "Bash", "theirs"))
        con.close()
        self.batch([self.event(key="k1", detail="mine"), self.event(key="victim|k1", detail="forged")])
        ingest.run(self.cfg)
        self.assertEqual(rows(self.db, "select detail from events where user='victim'"), [("theirs",)])
        self.assertEqual(len(rows(self.db, "select 1 from events where user=?", ME)), 2)

    def test_a_row_outside_the_vocabulary_or_with_a_bad_value_is_a_bad_line_and_the_rest_lands(self):
        self.batch([self.event(severity="fatal"), self.event(key="k2", category="gossip"),
                    self.usage_row(id="m2", output=-5), self.usage_row(id="m3", ts="9999-01-01T00:00:00Z"),
                    self.usage_row(id="m4", model=7), {"t": "mystery"}, "not json", "[1]",
                    self.usage_row(id="good")])
        stats = ingest.run(self.cfg)
        self.assertEqual(stats["bad_lines"], 8)
        self.assertEqual(rows(self.db, "select id from usage"), [("good",)])
        self.assertEqual(rows(self.db, "select count(*) from events"), [(0,)])

    def test_a_file_with_no_valid_header_is_refused(self):
        for i, head in enumerate(({"v": 2}, {"host": ""}, {"ts": "yesterday"}, {"claude_version": "<b>"},
                                  {"policy_sha256": "abc"}, {"t": "event"})):
            with self.subTest(head=head):
                self.batch([self.usage_row()], name="h%d.jsonl" % i, **head)
                stats = ingest.run(self.cfg)
                self.assertEqual(len(stats["skipped"]), 1, stats)
        self.assertEqual(rows(self.db, "select count(*) from usage"), [(0,)])
        self.assertEqual(os.listdir(self.spool), [])

    def test_a_symlink_or_a_hard_link_in_the_spool_is_not_read(self):
        target = os.path.join(self.f.root, "elsewhere.jsonl")
        with open(target, "w") as fh:
            fh.write(json.dumps({"t": "batch", "v": 1, "host": "h", "user": ME, "ts": TS,
                                 "claude_version": None, "policy_sha256": None}) + "\n"
                     + json.dumps(self.usage_row()) + "\n")
        os.symlink(target, os.path.join(self.spool, "a.jsonl"))
        os.link(target, os.path.join(self.spool, "b.jsonl"))
        stats = ingest.run(self.cfg)
        self.assertEqual(sorted(why for _p, why in stats["skipped"]),
                         ["hard link to another file", "symlink, not followed"])
        self.assertEqual(rows(self.db, "select count(*) from usage"), [(0,)])
        self.assertTrue(os.path.exists(target))

    def test_an_older_check_in_does_not_replace_a_newer_one(self):
        self.batch([], name="2.jsonl", ts="2026-10-02T10:00:00Z", claude_version="2.2.0")
        ingest.run(self.cfg)
        self.batch([], name="1.jsonl", ts="2026-10-01T10:00:00Z", claude_version="2.1.0")
        ingest.run(self.cfg)
        self.assertEqual(rows(self.db, "select claude_version from hosts where host='host-a'"), [("2.2.0",)])

    def test_a_batch_that_cannot_be_removed_is_reported_and_not_read_again(self):
        path = self.batch([self.usage_row(output=2)])
        real = spool.os.unlink
        spool.os.unlink = lambda p: (_ for _ in ()).throw(PermissionError("no"))
        try:
            stats = ingest.run(self.cfg)
            self.assertEqual(len(stats["skipped"]), 1)
            # a later batch replaced the row; reading the stuck one again would undo that
            con = sqlite3.connect(self.db)
            with con:
                con.execute("update usage set output=99")
            con.close()
            stats = ingest.run(self.cfg)
            self.assertEqual(len(stats["skipped"]), 1)
        finally:
            spool.os.unlink = real
        self.assertEqual(rows(self.db, "select output from usage"), [(99,)])
        self.assertEqual(ingest.run(self.cfg)["skipped"], [])
        self.assertFalse(os.path.exists(path))
        self.assertEqual(rows(self.db, "select count(*) from checkpoints"), [(0,)])

    def test_a_half_written_batch_is_left_alone(self):
        with open(os.path.join(self.spool, ".tmp-abc"), "w") as fh:
            fh.write("partial")
        self.assertEqual(ingest.run(self.cfg)["skipped"], [])
        self.assertEqual(os.listdir(self.spool), [".tmp-abc"])

    def test_a_spool_that_is_not_there_is_reported(self):
        os.rmdir(self.spool)
        self.assertEqual(len(ingest.run(self.cfg)["skipped"]), 1)


class SharedSpoolModes(unittest.TestCase):
    """The rule for a spool owned by another account, with the stat results stood in for:
    no test can create a second account."""

    def check(self, dir_mode, dir_gid, file_gid):
        import collections
        import stat as statmod
        S = collections.namedtuple("S", "st_uid st_gid st_mode")
        chmods = []
        real = feed.os.stat, feed.os.fstat, feed.os.fchmod
        feed.os.stat = lambda p: S(1, dir_gid, statmod.S_IFDIR | dir_mode)
        feed.os.fstat = lambda fd: S(2, file_gid, statmod.S_IFREG | 0o600)
        feed.os.fchmod = lambda fd, mode: chmods.append(mode)
        try:
            feed._let_the_collector_read(0, "/spool")
        finally:
            feed.os.stat, feed.os.fstat, feed.os.fchmod = real
        return chmods

    def test_in_a_setgid_spool_the_batch_is_opened_to_the_collectors_group_only(self):
        self.assertEqual(self.check(0o3733, 50, 50), [0o640])

    def test_without_setgid_or_born_in_another_group_the_batch_is_refused(self):
        with self.assertRaises(feed.FeedError):
            self.check(0o1733, 50, 50)
        with self.assertRaises(feed.FeedError):
            self.check(0o3733, 50, 51)


if __name__ == "__main__":
    unittest.main()
