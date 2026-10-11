"""The collector's side of the feed: reads the batches people's `feed` runs
left in the spool, and removes each once its rows are stored.

A batch is written by the person it describes, so nothing in it is trusted
beyond that: the person is the file's owner (not what the file says), every
row is stored under that person, every value is checked against the same
rules a log line is, and an event's key is combined with the person so that
nobody can name, and so replace, another person's row.
"""
import datetime
import errno
import json
import os
import re
import stat

from fleetdash import ingest, store
from fleetdash.feed import BATCH_MAX, BATCH_VERSION
from fleetdash.vocab import CATEGORIES, SEVERITIES

SUFFIX = ".jsonl"
NAME_MAX = 255
PATH_MAX = 4096
VERSION_RE = re.compile(ingest.VERSION)
SHA256_RE = re.compile(r"[0-9a-f]{64}")


def collect(con, cfg, stats):
    try:
        names = sorted(n for n in os.listdir(cfg["spool"]) if n.endswith(SUFFIX))
    except OSError as e:
        stats["skipped"].append((cfg["spool"], str(e)))
        return
    for name in names:
        _batch(con, cfg, os.path.join(cfg["spool"], name), stats)


def _batch(con, cfg, path, stats):
    cp_key = "spool:" + path
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except OSError as e:
        if e.errno in (errno.ELOOP, errno.EACCES):
            try:
                st = os.lstat(path)
            except OSError:
                st = None
            if st is not None:
                return _refuse(con, stats, path, ingest.owner(st.st_uid), "symlink, not followed"
                               if e.errno == errno.ELOOP else "closed to the collector", st)
        stats["skipped"].append((path, str(e)))
        return
    st = os.fstat(fd)
    owner = ingest.owner(st.st_uid)
    if not stat.S_ISREG(st.st_mode):
        # before it is wrapped as a file: a directory opens, and cannot be one
        os.close(fd)
        return _refuse(con, stats, path, owner, "not a regular file", st)
    with os.fdopen(fd, "rb") as fh:
        if st.st_nlink != 1:
            return _refuse(con, stats, path, owner, "hard link to another file", st)
        if st.st_size > BATCH_MAX:
            # a size is free to claim (a sparse file) and costly to read
            return _refuse(con, stats, path, owner, "larger than the %d bytes a batch may be" % BATCH_MAX, st)
        done = con.execute("select inode from checkpoints where path=?", (cp_key,)).fetchone()
        if done is None or done["inode"] != st.st_ino:
            lines = ingest.complete_lines(fh, 0, BATCH_MAX)
            try:
                head = _header(next(lines, (0, 0, None))[2])
            except ingest.BAD_RECORD as e:
                return _refuse(con, stats, path, owner, "not a batch: %s" % type(e).__name__
                               if isinstance(e, RecursionError) else "not a batch: %s" % e, st)
            except ingest.Grew:
                return _refuse(con, stats, path, owner, "grew past the %d bytes a batch may be" % BATCH_MAX, st)
            user = owner if cfg["verify_file_owner"] else head["user"]
            if head["user"] != user:
                return _refuse(con, stats, path, owner, "says it is from " + head["user"][:NAME_MAX], st)
            try:
                _rows(con, lines, head, user, stats)
            except ingest.Grew:
                return _refuse(con, stats, path, owner, "grew past the %d bytes a batch may be" % BATCH_MAX, st)
            stats["files"] += 1
            with con:
                # remembered until the file is gone, so a batch that cannot be
                # removed is not read again over rows a later batch replaced
                con.execute("insert or replace into checkpoints values (?,?,0,?)", (cp_key, st.st_ino, st.st_size))
    try:
        os.unlink(path)
    except OSError as e:
        stats["skipped"].append((path, "read, but cannot be removed: %s" % e))
        return
    with con:
        con.execute("delete from checkpoints where path=?", (cp_key,))


def _rows(con, lines, head, user, stats):
    """Store a batch's rows and its check-in, or none of them. The size was
    checked when the file was opened and its owner can go on writing, so the
    limit is kept again, by the reader, on what has actually been read."""
    at = dict(stats)
    try:
        with con:
            for _at, _end, raw in lines:
                if raw is not None and not raw.strip():
                    continue
                stats["lines"] += 1
                try:
                    if raw is None:
                        raise ValueError("line longer than %d bytes" % ingest.LINE_MAX)
                    sql, args = _row(json.loads(raw.decode("utf-8")), user)
                except ingest.BAD_RECORD:
                    stats["bad_lines"] += 1
                    continue
                con.execute(sql, args)
            # the time is the sender's word: one ahead of this clock would
            # outrank every later check-in the host itself makes
            head["ts"] = min(head["ts"], store.iso(datetime.datetime.utcnow()) + "Z",
                             key=lambda t: t[:19])
            ingest.record_checkin(con, head, user)
    except ingest.Grew:
        # the rows are rolled back, so they are not counted as read either
        stats["lines"], stats["bad_lines"] = at["lines"], at["bad_lines"]
        raise


def _refuse(con, stats, path, user, why, st):
    """A file that is not a batch from its owner is recorded under its owner,
    not read, and removed so that it is reported once."""
    stats["skipped"].append((path, why))
    with con:
        con.execute(*ingest.event("spool:%s|integrity|%d" % (path, st.st_ino), store.iso(
            datetime.datetime.utcfromtimestamp(st.st_mtime)) + "Z", user, "", "error",
            "log-integrity", why, "", "batch not read: " + why))
    try:
        os.rmdir(path) if stat.S_ISDIR(st.st_mode) else os.unlink(path)
    except OSError:
        pass  # it stays, and is refused and listed again on the next run


def _str(v):
    if not isinstance(v, str) or not ingest.storable(v):
        raise ValueError("not text: %r" % (v,))
    return v


def _name(v, most=NAME_MAX):
    v = _str(v)
    if not v or len(v) > most:
        raise ValueError("a name must be 1 to %d characters" % most)
    return v


def _opt(v, rx):
    if v is None:
        return None
    if not rx.fullmatch(_str(v)):
        raise ValueError("unexpected value %r" % (v,))
    return v


def _header(raw):
    if raw is None:
        raise ValueError("no header line")
    h = json.loads(raw.decode("utf-8"))
    if h.get("t") != "batch" or h.get("v") != BATCH_VERSION:
        raise ValueError("not a version %d batch header" % BATCH_VERSION)
    ts = ingest.timestamp(h.get("ts"))
    if not ts:
        raise ValueError("no time")
    return {"host": _name(h.get("host")), "user": _name(h.get("user")), "ts": ts,
            "claude_version": _opt(h.get("claude_version"), VERSION_RE),
            "policy_sha256": _opt(h.get("policy_sha256"), SHA256_RE)}


def _row(d, user):
    kind = d["t"]
    if kind == "event":
        if d["severity"] not in SEVERITIES or d["category"] not in CATEGORIES:
            raise ValueError("outside the vocabulary")
        # keyed with the person: a key is whatever the batch says
        return ingest.event("%s|%s" % (user, _name(d["key"])), ingest.timestamp(d["ts"]), user, _str(d["session"]),
                            d["severity"], d["category"], _str(d["source"]), _str(d["tool"]),
                            _str(d["detail"]), _str(d["host"])[:NAME_MAX])
    if kind == "usage":
        return ("insert or replace into usage values (?,?,?,?,?,?,?,?,?)", (
            _name(d["id"]), ingest.timestamp(d["ts"]), user, _str(d["session"]),
            ingest.model_label(_str(d["model"]))[:NAME_MAX],
            ingest.count(d["input"]), ingest.count(d["output"]),
            ingest.count(d["cache_read"]), ingest.count(d["cache_write"])))
    if kind == "session":
        return ("insert or replace into sessions values (?,?,?,?,?,?,?,?)", (
            _name(d["path"], PATH_MAX), user,
            _str(d["project"]), _str(d["session"]), ingest.count(d["bytes"], ingest.SIZE_MAX),
            ingest.timestamp(d["first_ts"]) or None, ingest.timestamp(d["last_ts"]) or None,
            ingest.count(d["records"])))
    raise ValueError("unknown row type %r" % (kind,))
