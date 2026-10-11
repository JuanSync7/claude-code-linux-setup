"""Reads hook logs and transcripts into the store, incrementally.

Every file is written by the user it describes, so none is trusted: see
_file for what is refused, and docs/ARCHITECTURE.md for what that leaves.

Each file has a checkpoint (inode, generation, byte offset). A run reads only
the complete lines past the offset, and writes the rows and the new offset in
one transaction, so a crash or a second run never double-counts. A file that
shrank or changed inode was rotated: it is read again from the start under a
new generation, which keeps its line keys distinct from the old file's.

Only shape is kept: from a transcript, the token counts, model, and the names
of the slash command, skill or plugin, never the text of a message or the
arguments of a command.
"""
import datetime
import errno
import glob
import hashlib
import json
import os
import pwd
import re
import stat

from fleetdash import store

CHUNK = 8 << 20
# no real record comes near this; a longer line is a bad record, not a buffer
LINE_MAX = 64 << 20
DETAIL_MAX = 500
# Timestamps are compared as text, so only one form is accepted: UTC ISO 8601,
# as Claude Code ("...Z") and the hooks ("...+00:00") write it. Anything else
# would sort outside the real range: "zzz" or year 9999 sits inside every
# window and makes its writer look active today. A clock a little fast is
# allowed for; a timestamp further ahead than that is a bad record.
# ASCII digits and the whole string: \d also matches other scripts' digits,
# which strptime reads as numbers but which sort after every ASCII date, and $
# also matches before a trailing newline.
TS_RE = re.compile(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]{1,9})?(?:Z|\+00:00)")
TS_AHEAD = datetime.timedelta(days=1)
HOOK_KINDS = ("activity", "denied")
# Denial kinds the person caused (said No, pressed Esc). Any other kind,
# including one this list has never seen, counts as a policy block.
PERSON_DENIALS = ("user-rejected", "interrupted")


def run(cfg):
    stats = {"files": 0, "lines": 0, "bad_lines": 0, "skipped": []}
    con = store.connect(cfg)
    try:
        for kind in HOOK_KINDS:
            for path in sorted(glob.glob(os.path.join(cfg["hook_log_dir"], kind, "*.jsonl"))):
                user = os.path.basename(path)[:-len(".jsonl")]
                _file(con, cfg, path, user, _hook_reader(kind, user), stats)
        user_rx = re.compile(cfg["user_from_path"])
        for root in sorted(glob.glob(cfg["transcript_glob"])):
            for dirpath, _dirs, files in os.walk(root):
                for name in sorted(files):
                    if not name.endswith(".jsonl"):
                        continue
                    path = os.path.join(dirpath, name)
                    m = user_rx.search(path)
                    if not m:
                        stats["skipped"].append((path, "no user in path"))
                        continue
                    project = os.path.relpath(path, root).split(os.sep)[0]
                    reader = _transcript_reader(path, m.group(1), project)
                    _file(con, cfg, path, m.group(1), reader, stats)
        with con:
            con.execute("insert or replace into meta values ('last_ingest', ?)",
                        (store.iso(datetime.datetime.utcnow()) + "Z",))
    finally:
        con.close()
    return stats


def _file(con, cfg, path, user, reader, stats):
    """Every file was written by the user it describes, so none is trusted:
    it is opened once without following a symlink, checked through that same
    descriptor, and read through it, so it cannot be swapped in between."""
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except OSError as e:
        if e.errno == errno.ELOOP:
            _refuse(con, stats, path, user, "symlink, not followed", os.lstat(path))
        else:
            stats["skipped"].append((path, str(e)))
        return
    with os.fdopen(fd, "rb") as fh:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode):
            return _refuse(con, stats, path, user, "not a regular file", st)
        if st.st_nlink != 1:
            return _refuse(con, stats, path, user, "hard link to another file", st)
        if cfg["verify_file_owner"]:
            owner = _owner(st)
            if owner != user:
                return _refuse(con, stats, path, user, "owner " + owner, st)
        cp = con.execute("select inode, generation, offset from checkpoints where path=?", (path,)).fetchone()
        gen, offset = 0, 0
        if cp is not None:
            gen, offset = cp["generation"], cp["offset"]
            if st.st_ino != cp["inode"] or st.st_size < offset:
                gen, offset = gen + 1, 0
                reader.restart(con)
        if st.st_size == offset:
            return
        stats["files"] += 1
        with con:
            end = offset
            for line_at, end, raw in _complete_lines(fh, offset):
                if raw is not None and not raw.strip():
                    continue
                stats["lines"] += 1
                # work out every row first: a record that fails writes nothing
                try:
                    if raw is None:
                        raise ValueError("line longer than %d bytes" % LINE_MAX)
                    rec = json.loads(raw.decode("utf-8"))
                    if not isinstance(rec, dict):
                        raise ValueError("not an object")
                    rows = reader.take(rec, "%s|%d|%d" % (path, gen, line_at))
                except (ValueError, TypeError, KeyError, AttributeError):
                    stats["bad_lines"] += 1
                    continue
                for sql, args in rows:
                    con.execute(sql, args)
            reader.finish(con, st)
            con.execute("insert or replace into checkpoints values (?,?,?,?)", (path, st.st_ino, gen, end))


def _complete_lines(fh, offset):
    """Yield (start, end, bytes) for each newline-terminated line past offset.
    A trailing line with no newline is still being written: leave it. A line
    longer than LINE_MAX is yielded as None once its newline arrives, and is
    not held in memory while it grows."""
    fh.seek(offset)
    pos, buf, over = offset, b"", False
    while True:
        chunk = fh.read(CHUNK)
        if not chunk:
            return
        buf += chunk
        lines = buf.split(b"\n")
        buf = lines.pop()
        for line in lines:
            end = pos + len(line) + 1
            yield pos, end, (None if over or len(line) > LINE_MAX else line)
            pos, over = end, False
        if len(buf) > LINE_MAX:
            over, buf = True, b""


def _owner(st):
    try:
        return pwd.getpwuid(st.st_uid).pw_name
    except KeyError:
        return "uid %d" % st.st_uid


def _refuse(con, stats, path, user, why, st):
    """A file that is not what its path claims is recorded as an integrity
    event, under the user it claims to be for, and not read."""
    stats["skipped"].append((path, why))
    with con:
        con.execute(*_event("%s|integrity|%d" % (path, st.st_ino), store.iso(
            datetime.datetime.utcfromtimestamp(st.st_mtime)) + "Z", user, "", "error",
            "log-integrity", why, "", "file not read: " + why))


def _event(key, ts, user, session, severity, category, source, tool, detail):
    return ("insert or ignore into events values (?,?,?,?,?,?,?,?,?)",
            (_hash(key), _text(ts), user, _text(session), severity, category,
             _text(source), _text(tool), _text(detail)[:DETAIL_MAX]))


def _text(v):
    """A field as text: a transcript or log may hold any JSON type anywhere."""
    if v is None:
        return ""
    if isinstance(v, str):
        return v
    return json.dumps(v, sort_keys=True)


def _ts(v):
    """A record's time: missing is unknown (""), anything but UTC ISO 8601
    no later than TS_AHEAD from now is a bad record."""
    if v is None or v == "":
        return ""
    if not isinstance(v, str) or not TS_RE.fullmatch(v):
        raise ValueError("not a UTC ISO timestamp: %r" % (v,))
    if datetime.datetime.strptime(v[:19], store.ISO) > datetime.datetime.utcnow() + TS_AHEAD:
        raise ValueError("timestamp in the future: %r" % (v,))
    return v


def _count(v):
    """A token count: missing is 0, anything but a whole number is a bad record."""
    if v is None:
        return 0
    if isinstance(v, bool) or not isinstance(v, int) or v < 0:
        raise ValueError("not a token count: %r" % (v,))
    return v


def _hash(s):
    return hashlib.sha1(s.encode("utf-8", "surrogateescape")).hexdigest()


class _hook_reader(object):
    """One JSON line per tool call (activity), refusal (denied) or redaction.
    The user is the one the file is named for, not a field in the line."""

    def __init__(self, kind, user):
        self.kind, self.user = kind, user

    def restart(self, con):
        pass

    def finish(self, con, st):
        pass

    def take(self, rec, key):
        ts, session, tool = _ts(rec.get("ts")), rec.get("session"), rec.get("tool")
        if self.kind == "denied":
            return [_event(key, ts, self.user, session, "deny", "denial",
                           rec.get("denied_by"), tool, rec.get("detail"))]
        if rec.get("event") == "redaction":
            kinds = rec.get("kinds")
            kinds = ",".join(_text(k) for k in kinds) if isinstance(kinds, list) else _text(kinds)
            return [_event(key, ts, self.user, session, "redact", "redaction",
                           "cc-redact-hook", tool, "%s x%s" % (kinds, _text(rec.get("count"))))]
        return [_event(key, ts, self.user, session, "pass", "tool-call", "", tool, rec.get("detail"))]


def model_label(model):
    """A Bedrock inference-profile ARN carries an AWS account id; keep only
    the fact that it is one."""
    if model.startswith("arn:"):
        return "arn:aws:bedrock:inference-profile"
    return model


class _transcript_reader(object):
    def __init__(self, path, user, project):
        self.path, self.user, self.project = path, user, project
        self.session = os.path.basename(path)[:-len(".jsonl")]
        self.records, self.first, self.last = 0, None, None

    def restart(self, con):
        con.execute("delete from sessions where path=?", (self.path,))

    def finish(self, con, st):
        row = con.execute("select records, first_ts, last_ts from sessions where path=?",
                          (self.path,)).fetchone()
        records, first, last = self.records, self.first, self.last
        if row is not None:
            records += row["records"]
            first = min(x for x in (first, row["first_ts"]) if x) if (first or row["first_ts"]) else None
            last = max(x for x in (last, row["last_ts"]) if x) if (last or row["last_ts"]) else None
        con.execute("insert or replace into sessions values (?,?,?,?,?,?,?,?)",
                    (self.path, self.user, self.project, self.session, st.st_size, first, last, records))

    def take(self, rec, key):
        rows = self._rows(rec, key)
        self.records += 1
        ts = _ts(rec.get("timestamp"))
        if ts:
            self.first = ts if self.first is None else min(self.first, ts)
            self.last = ts if self.last is None else max(self.last, ts)
        return rows

    def _rows(self, rec, key):
        rows = []
        ts = _ts(rec.get("timestamp"))
        session = _text(rec.get("sessionId")) or self.session
        base = _text(rec.get("uuid")) or key
        msg = rec.get("message") if isinstance(rec.get("message"), dict) else {}

        u = msg.get("usage")
        if rec.get("type") == "assistant" and isinstance(u, dict) and msg.get("id"):
            rows.append(("insert or replace into usage values (?,?,?,?,?,?,?,?,?)", (
                _text(msg["id"]), _text(ts), self.user, session, model_label(_text(msg.get("model"))),
                _count(u.get("input_tokens")), _count(u.get("output_tokens")),
                _count(u.get("cache_read_input_tokens")), _count(u.get("cache_creation_input_tokens")))))

        q = rec.get("quotaLimits")
        if isinstance(q, dict) and q.get("status") == "rejected":
            kind = _text(q.get("rateLimitType", "unknown"))
            # every retry while blocked is a record; the window (its reset
            # time) is the hit. With no reset time, each record stands alone.
            at = q.get("resetsAt")
            qkey = ("%s|quota|%s|%s" % (self.user, kind, at) if isinstance(at, int) and not isinstance(at, bool)
                    else base + "|quota")
            rows.append(_event(qkey, ts, self.user, session, "quota", "rate-limit", "", "",
                               "%s rejected" % kind))
        if rec.get("isApiErrorMessage") or rec.get("apiErrorStatus"):
            status = rec.get("apiErrorStatus")
            rows.append(_event(base + "|api", ts, self.user, session, "error", "api-error", "", "",
                               "HTTP %s" % _text(status) if status else "API error"))
        if rec.get("attributionSkill"):
            rows.append(_event(base + "|skill", ts, self.user, session, "info", "skill", "", "",
                               rec["attributionSkill"]))
        if rec.get("attributionPlugin"):
            rows.append(_event(base + "|plugin", ts, self.user, session, "info", "plugin", "", "",
                               rec["attributionPlugin"]))
        if rec.get("toolDenialKind"):
            kind = _text(rec["toolDenialKind"])
            rows.append(_event(base + "|denial", ts, self.user, session,
                               "info" if kind in PERSON_DENIALS else "deny", "denial", kind, "", ""))
        cmd = rec.get("commandRun")
        if isinstance(cmd, dict) and cmd.get("command"):
            # the name only: the rest of the line is the person's arguments
            name = _text(cmd["command"]).lstrip("/").split()
            if not name:
                raise ValueError("a command with no name")
            rows.append(_event(base + "|cmd", ts, self.user, session, "info", "slash-command", "", "",
                               "/" + name[0]))
        return rows
