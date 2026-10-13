"""`feed`: one person sends the shape of their own use to the collector.

Run as that person (from a session-end hook, or by hand). It reads their own
transcripts and their own hook logs into a private store under
feed.state_dir, exactly as `ingest` would, then writes every row that is new
since the last batch as one file in the spool. The collector never needs to
read a home directory.

A batch is written under a temporary name and renamed when complete, so the
collector never sees half of one. The outbox is emptied only after the rename:
a crash in between sends the same rows again, and the collector's keys make a
row sent twice count once.
"""
import datetime
import fcntl
import json
import os
import secrets
import stat
import time

from fleetdash import ingest, store

BATCH_VERSION = 1
# The collector refuses a larger file unread: a size is free to claim and
# costly to read. Months of one person's use come to a few percent of this.
BATCH_MAX = 1 << 30
# Every insert is noted here by a trigger, in this private store only. A
# watermark on rowid would miss a row replaced in place: SQLite gives the
# replacement the rowid it just freed.
OUTBOX = """
create table if not exists outbox (seq integer primary key autoincrement, tbl text not null,
                                   a text not null, b text not null);
create trigger if not exists outbox_events after insert on events
    begin insert into outbox (tbl, a, b) values ('event', new.key, ''); end;
create trigger if not exists outbox_incidents after insert on incidents
    begin insert into outbox (tbl, a, b) values ('incident', new.key, ''); end;
create trigger if not exists outbox_usage after insert on usage
    begin insert into outbox (tbl, a, b) values ('usage', new.user, new.id); end;
create trigger if not exists outbox_sessions after insert on sessions
    begin insert into outbox (tbl, a, b) values ('session', new.user, new.path); end;
"""
QUERIES = (
    ("event", "select key, ts, session, severity, category, source, tool, detail, host from events "
              "where key in (select a from outbox where tbl='event' and seq<=?)"),
    ("incident", "select key, input, input_kind, input_len, fields, said, cwd, branch, client, call_id from incidents "
                 "where key in (select a from outbox where tbl='incident' and seq<=?)"),
    ("usage", "select id, ts, session, model, input, output, cache_read, cache_write from usage "
              "where (user, id) in (select a, b from outbox where tbl='usage' and seq<=?)"),
    ("session", "select path, project, session, bytes, first_ts, last_ts, records from sessions "
                "where (user, path) in (select a, b from outbox where tbl='session' and seq<=?)"),
)


class FeedError(Exception):
    pass


def run(cfg):
    """Returns the ingest stats plus what was sent. Raises FeedError when the
    batch could not be delivered; nothing is lost, the next run sends it."""
    if not cfg["spool"]:
        raise FeedError("spool is not set in the config: there is nowhere to send to")
    user = ingest.owner(os.geteuid())
    state = os.path.expanduser(cfg["feed"]["state_dir"])
    os.makedirs(state, mode=0o700, exist_ok=True)
    lock = os.open(os.path.join(state, "lock"), os.O_CREAT | os.O_RDWR, 0o600)
    try:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            # another session of the same person is feeding: it will send these rows
            return {"busy": True}
        own = dict(cfg, store=os.path.join(state, "store.db"), spool="")
        con = store.connect(own)
        try:
            con.executescript(OUTBOX)
        finally:
            con.close()
        stats = ingest.run(own, own=(user, os.path.expanduser(cfg["feed"]["transcripts"])))
        stats["busy"] = False
        stats["sent"] = _send(own, cfg["spool"], user)
        return stats
    finally:
        os.close(lock)


def _send(own, spool, user):
    con = store.connect(own)
    try:
        top = con.execute("select coalesce(max(seq), 0) from outbox").fetchone()[0]
        me = con.execute("select * from hosts where host=?", (own["host_label"],)).fetchone()
        header = {"t": "batch", "v": BATCH_VERSION, "host": own["host_label"], "user": user,
                  "ts": me["last_seen"] if me else store.iso(datetime.datetime.utcnow()) + "Z",
                  "claude_version": me["claude_version"] if me else None,
                  "policy_sha256": me["policy_sha256"] if me else None,
                  "drift": ingest.stored_drift(con.execute("select * from drift where host=?",
                                                           (own["host_label"],)).fetchone())}
        sent = {kind: 0 for kind, _ in QUERIES}
        tmp = os.path.join(spool, ".tmp-%s" % secrets.token_hex(8))
        try:
            fd = os.open(tmp, os.O_CREAT | os.O_EXCL | os.O_WRONLY | os.O_NOFOLLOW, 0o600)
        except OSError as e:
            raise FeedError("cannot write to the spool %s: %s" % (spool, e))
        try:
            with os.fdopen(fd, "w") as fh:
                fh.write(json.dumps(header) + "\n")
                for kind, sql in QUERIES:
                    for row in con.execute(sql, (top,)):
                        d = dict(row)
                        d["t"] = kind
                        fh.write(json.dumps(d) + "\n")
                        sent[kind] += 1
                fh.flush()
                if fh.tell() > BATCH_MAX:
                    raise FeedError("this batch is %d bytes and the collector reads at most %d: nothing was "
                                    "sent and nothing is lost" % (fh.tell(), BATCH_MAX))
                _let_the_collector_read(fh.fileno(), spool)
                os.fsync(fh.fileno())
            # the name sorts by time, so one person's batches are read in the order written
            os.rename(tmp, os.path.join(spool, "%d-%d-%s.jsonl" % (time.time() * 1e9, os.getpid(),
                                                                secrets.token_hex(8))))
        except BaseException:
            try:
                os.unlink(tmp)
            except OSError:
                pass
            raise
        with con:
            con.execute("delete from outbox where seq<=?", (top,))
        return sent
    finally:
        con.close()


def _let_the_collector_read(fd, spool):
    """A batch stays owner-only when the spool is this person's own (they are
    the collector). In a shared spool it must reach the collector and nobody
    else: the installer makes the spool setgid to the collector's group, so the
    file is born in that group, and group read is then enough. Anything else
    would mean opening the batch to everyone, so it is refused."""
    d, f = os.stat(spool), os.fstat(fd)
    if d.st_uid == f.st_uid:
        return
    if d.st_mode & stat.S_ISGID and f.st_gid == d.st_gid:
        os.fchmod(fd, 0o640)
        return
    raise FeedError("the spool %s is not setgid to its collector's group, so a batch in it could "
                    "only be read by its sender: install it with `fleetdash install`" % spool)
