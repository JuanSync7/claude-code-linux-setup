"""Reads hook logs and transcripts into the store, incrementally.

Every file is written by the user it describes, so none is trusted: see
_file for what is refused, and docs/ARCHITECTURE.md for what that leaves.

Each file has a checkpoint (inode, generation, byte offset). A run reads only
the complete lines past the offset, and writes the rows and the new offset in
one transaction, so a crash or a second run never double-counts. A file that
shrank or changed inode was rotated: it is read again from the start under a
new generation, which keeps its line keys distinct from the old file's.

What is kept from a transcript is its shape: the token counts, model, and the
names of the slash command, skill or plugin, never the text of a message. A
tool call that was stopped is the one exception: it is an incident, and what
was asked for is kept with it (see incident()).

A run also records this host's check-in (its Claude Code version and the hash
of the policy it holds), and reads the feed spool and the privileged
session's log when the config names them.
"""
import collections
import datetime
import errno
import glob
import hashlib
import json
import os
import pwd
import re
import stat
import string
import subprocess

from fleetdash import store
from fleetdash.vocab import ADMIN_KINDS, ADMIN_LOG_STATES, INPUT_KINDS

CHUNK = 8 << 20
# no real record comes near this; a longer line is a bad record, not a buffer
LINE_MAX = 64 << 20
DETAIL_MAX = 500
# What a stopped call asked for, and what Claude was told about it, are kept
# to this length (see cut()); a directory or branch to PLACE_MAX; and at most
# FIELDS_MAX of the call's field names.
INPUT_MAX = 2000
# room for the note cut() leaves in the middle of a text it shortened
CUT_NOTE_MAX = 64
PLACE_MAX = 1024
FIELDS_MAX = 32
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
# What makes one record a bad record: its line is counted and the run goes on.
# RecursionError is JSON nested deeper than the parser goes.
BAD_RECORD = (ValueError, TypeError, KeyError, AttributeError, RecursionError)
# No message holds a billion tokens and no transcript a tebibyte. The store's
# integers are 64-bit, and a sum over rows this size cannot leave them.
COUNT_MAX = 10 ** 9
SIZE_MAX = 1 << 40
VERSION_TIMEOUT = 15
# tool calls a transcript reader remembers by id, to name the tool a later
# block stopped; the block follows its call within a few records
CALLS_REMEMBERED = 4096
CODE_MAX = 128
CODE_CHARS = frozenset(string.ascii_letters + string.digits + "_")
TOOL_CHARS = CODE_CHARS | frozenset("-.:")


def run(cfg, own=None):
    """Read every configured source into the store. With own=(user, root),
    read only that person's hook logs and the transcripts under root: that is
    what `feed` runs, as that person, into their own store."""
    stats = {"files": 0, "lines": 0, "bad_lines": 0, "skipped": []}
    con = store.connect(cfg)
    try:
        for path, user, cp, reader in _sources(cfg, own, stats):
            _file(con, cfg, path, user, reader, stats, cp)
        if cfg["admin_log"] and own is None:
            _admin_log(con, cfg, stats)
        if cfg["spool"] and own is None:
            from fleetdash import spool  # spool builds its rows with this module's helpers
            spool.collect(con, cfg, stats)
        with con:
            record_checkin(con, checkin(cfg), owner(os.geteuid()))
            con.execute("insert or replace into meta values ('last_ingest', ?)",
                        (store.iso(datetime.datetime.utcnow()) + "Z",))
    finally:
        con.close()
    return stats


def _sources(cfg, own, stats):
    """Yield (path, user, checkpoint key, reader) for each file to read."""
    host = cfg["host_label"]
    if cfg["hook_log_dir"]:
        for kind in HOOK_KINDS:
            d = os.path.join(cfg["hook_log_dir"], kind)
            if own:
                paths = [p for p in [os.path.join(d, own[0] + ".jsonl")] if os.path.lexists(p)]
            else:
                paths = sorted(glob.glob(os.path.join(d, "*.jsonl")))
            for path in paths:
                user = own[0] if own else os.path.basename(path)[:-len(".jsonl")]
                # a hook log has the same path on every host and is a different
                # file on each, so its checkpoint and its line keys name the host
                yield path, user, "%s:%s" % (host, path), _hook_reader(kind, user, host)
    user_rx = re.compile(cfg["user_from_path"])
    if own:
        roots = [own[1]]
    else:
        roots = sorted(glob.glob(cfg["transcript_glob"])) if cfg["transcript_glob"] else []
    for root in roots:
        for dirpath, _dirs, files in os.walk(root):
            for name in sorted(files):
                if not name.endswith(".jsonl"):
                    continue
                path = os.path.join(dirpath, name)
                if not storable(path):
                    stats["skipped"].append((path.encode("utf-8", "replace").decode(), "its name is not UTF-8"))
                    continue
                user = own[0] if own else None
                if user is None:
                    m = user_rx.search(path)
                    if not m:
                        stats["skipped"].append((path, "no user in path"))
                        continue
                    user = m.group(1)
                project = os.path.relpath(path, root).split(os.sep)[0]
                yield path, user, path, _transcript_reader(path, user, project)


def checkin(cfg, now=None):
    """What this host says about itself. A value that cannot be read is None:
    unknown, never a guess."""
    return {"host": cfg["host_label"],
            "ts": store.iso(now or datetime.datetime.utcnow()) + "Z",
            "claude_version": claude_version(cfg["claude_bin"]),
            "policy_sha256": file_sha256(cfg["policy"]["deployed"])}


# each part is short enough to be read as a number wherever versions are ordered
VERSION = r"[0-9]{1,9}\.[0-9]{1,9}\.[0-9]{1,9}"
VERSION_RE = re.compile(VERSION)


def claude_version(binary):
    if not binary:
        return None
    try:
        p = subprocess.run([binary, "--version"], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                           stderr=subprocess.DEVNULL, timeout=VERSION_TIMEOUT)
    except (OSError, subprocess.SubprocessError):
        return None
    if p.returncode != 0:
        return None
    # the vendor prints prose ("2.1.0 (Claude Code)") and offers no structured form
    m = re.search(VERSION, p.stdout.decode("utf-8", "replace"))
    return m.group(0) if m else None


def file_sha256(path):
    if not path:
        return None
    h = hashlib.sha256()
    try:
        with open(path, "rb") as fh:
            for chunk in iter(lambda: fh.read(1 << 20), b""):
                h.update(chunk)
    except OSError:
        return None
    return h.hexdigest()


def record_checkin(con, c, reported_by):
    """Keep the newest check-in per host. An older one arriving late (a batch
    read out of order) does not replace a newer one."""
    row = con.execute("select last_seen from hosts where host=?", (c["host"],)).fetchone()
    if row is None or c["ts"] >= row["last_seen"]:
        con.execute("insert or replace into hosts values (?,?,?,?,?)",
                    (c["host"], c["ts"], c["claude_version"], c["policy_sha256"], reported_by))


def _file(con, cfg, path, user, reader, stats, cp_key):
    """Every file was written by the user it describes, so none is trusted:
    it is opened once without following a symlink, checked through that same
    descriptor, and read through it, so it cannot be swapped in between."""
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except OSError as e:
        if e.errno == errno.ELOOP:
            _refuse(con, stats, path, user, "symlink, not followed", os.lstat(path), cp_key)
        else:
            stats["skipped"].append((path, str(e)))
        return
    st = os.fstat(fd)
    if not stat.S_ISREG(st.st_mode):
        # before it is wrapped as a file: a directory opens, and cannot be one
        os.close(fd)
        return _refuse(con, stats, path, user, "not a regular file", st, cp_key)
    with os.fdopen(fd, "rb") as fh:
        if st.st_nlink != 1:
            return _refuse(con, stats, path, user, "hard link to another file", st, cp_key)
        if cfg["verify_file_owner"]:
            actual = owner(st.st_uid)
            if actual != user:
                return _refuse(con, stats, path, user, "owner " + actual, st, cp_key)
        cp = con.execute("select inode, generation, offset from checkpoints where path=?", (cp_key,)).fetchone()
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
            for line_at, end, raw in complete_lines(fh, offset):
                if raw is not None and not raw.strip():
                    continue
                stats["lines"] += 1
                # work out every row first: a record that fails writes nothing
                try:
                    if raw is None:
                        raise ValueError("line longer than %d bytes" % LINE_MAX)
                    rows = reader.take(reader.parse(raw), "%s|%d|%d" % (cp_key, gen, line_at))
                except BAD_RECORD:
                    stats["bad_lines"] += 1
                    continue
                for sql, args in rows:
                    con.execute(sql, args)
            reader.finish(con, st)
            con.execute("insert or replace into checkpoints values (?,?,?,?)", (cp_key, st.st_ino, gen, end))


class Grew(Exception):
    """A file went on past the size its reader allows."""


def complete_lines(fh, offset, most=None):
    """Yield (start, end, bytes) for each newline-terminated line past offset.
    A trailing line with no newline is still being written: leave it. A line
    longer than LINE_MAX is yielded as None once its newline arrives, and is
    not held in memory while it grows. With most given, reading past that
    many bytes raises Grew: a file's owner can write for as long as it is
    read, whatever size it had when it was opened."""
    fh.seek(offset)
    pos, buf, over, read = offset, b"", False, 0
    while True:
        chunk = fh.read(CHUNK)
        if not chunk:
            return
        read += len(chunk)
        if most is not None and read > most:
            raise Grew()
        buf += chunk
        lines = buf.split(b"\n")
        buf = lines.pop()
        for line in lines:
            end = pos + len(line) + 1
            yield pos, end, (None if over or len(line) > LINE_MAX else line)
            pos, over = end, False
        if len(buf) > LINE_MAX:
            over, buf = True, b""


def owner(uid):
    try:
        return pwd.getpwuid(uid).pw_name
    except KeyError:
        return "uid %d" % uid


def _refuse(con, stats, path, user, why, st, cp_key):
    """A file that is not what its path claims is recorded as an integrity
    event, under the user it claims to be for, and not read."""
    stats["skipped"].append((path, why))
    with con:
        con.execute(*event("%s|integrity|%d" % (cp_key, st.st_ino), store.iso(
            datetime.datetime.utcfromtimestamp(st.st_mtime)) + "Z", user, "", "error",
            "log-integrity", why, "", "file not read: " + why))


def event(key, ts, user, session, severity, category, source, tool, detail, host=""):
    return ("insert or ignore into events values (?,?,?,?,?,?,?,?,?,?)",
            (_hash(key), text(ts), user, text(session), severity, category,
             text(source), text(tool), text(detail)[:DETAIL_MAX], host))


def cut(v, most=INPUT_MAX):
    """Text held to about `most` characters by keeping both ends, as the
    denial hook does: a cap that keeps only the head lets padding push the
    part that matters out of the record."""
    if len(v) <= most:
        return v
    return v[:most // 2] + "...[%d characters cut]..." % (len(v) - most) + v[-(most // 2):]


def incident(key, asked=None, fields=None, said="", cwd="", branch="", client="", call_id="", length=None):
    """The record of one stopped call, beside its event (same key): what was
    asked for, as (which field of the call, its text), or None when the call
    was not seen or has no such field; the names of the call's fields, None
    when it was not seen; what Claude was told; and where and under which
    client it happened. The two long texts come already shortened by cut(),
    with `length` what the first was before: a text cut twice would lose the
    note the first cut left, so here they are only held to a hard limit."""
    kind, value = asked or ("", None)
    held = INPUT_MAX + CUT_NOTE_MAX
    return ("insert or ignore into incidents values (?,?,?,?,?,?,?,?,?,?)",
            (_hash(key), None if value is None else value[:held], kind,
             None if value is None else len(value) if length is None else length,
             None if fields is None else json.dumps(fields), said[:held], cwd[:PLACE_MAX], branch[:PLACE_MAX],
             client, call_id))


def asked(given):
    """From a tool call's input: (which field says what was asked for, its
    text) or None, and the names of its fields. The fields kept are those in
    INPUT_KINDS (a command, a file, a URL, a path); what a call would have
    written to a file, or sent to another tool, is the person's work and is
    not."""
    if not isinstance(given, dict):
        return None, []
    what = next(((k, given[k]) for k in INPUT_KINDS
                 if isinstance(given.get(k), str) and given[k] and storable(given[k])), None)
    return what, sorted(k for k in given if _code(k))[:FIELDS_MAX]


def _plain(v):
    """A field that should be text, as text: anything else is left out."""
    return v if isinstance(v, str) and storable(v) else ""


def _told(content):
    """What a tool result says, from its text or its text parts."""
    if isinstance(content, list):
        return "\n".join(p["text"] for p in content if isinstance(p, dict) and p.get("type") == "text"
                         and _plain(p.get("text")))
    return _plain(content)


def storable(s):
    """Whether the store can hold this text. JSON can spell half of a
    surrogate pair, and a file name can hold bytes that are not UTF-8; neither
    can be written, and each must be refused where it is read."""
    try:
        s.encode("utf-8")
    except UnicodeEncodeError:
        return False
    return True


def text(v):
    """A field as text: a transcript or log may hold any JSON type anywhere."""
    if v is None:
        return ""
    if isinstance(v, str):
        if not storable(v):
            raise ValueError("text that is not UTF-8")
        return v
    return json.dumps(v, sort_keys=True)


def timestamp(v):
    """A record's time: missing is unknown (""), anything but UTC ISO 8601
    no later than TS_AHEAD from now is a bad record."""
    if v is None or v == "":
        return ""
    if not isinstance(v, str) or not TS_RE.fullmatch(v):
        raise ValueError("not a UTC ISO timestamp: %r" % (v,))
    if datetime.datetime.strptime(v[:19], store.ISO) > datetime.datetime.utcnow() + TS_AHEAD:
        raise ValueError("timestamp in the future: %r" % (v,))
    return v


def count(v, most=COUNT_MAX):
    """A token count: missing is 0, anything but a whole number up to `most`
    is a bad record."""
    if v is None:
        return 0
    if isinstance(v, bool) or not isinstance(v, int) or not 0 <= v <= most:
        raise ValueError("not a count from 0 to %d: %r" % (most, v))
    return v


def _hash(s):
    return hashlib.sha1(s.encode("utf-8", "surrogateescape")).hexdigest()


def json_record(raw):
    rec = json.loads(raw.decode("utf-8"))
    if not isinstance(rec, dict):
        raise ValueError("not an object")
    return rec


class _hook_reader(object):
    """One JSON line per tool call (activity), refusal (denied) or redaction.
    The user is the one the file is named for, not a field in the line, and
    the host is the one reading it: the hooks write only to their own host."""

    parse = staticmethod(json_record)

    def __init__(self, kind, user, host):
        self.kind, self.user, self.host = kind, user, host

    def restart(self, con):
        pass

    def finish(self, con, st):
        pass

    def take(self, rec, key):
        ts, session, tool = timestamp(rec.get("ts")), rec.get("session"), rec.get("tool")
        if self.kind == "denied":
            # the hook says what was asked for and not which field it was, and
            # nothing of what Claude was told; its length is the hook's count
            # where it is one, as the hook cuts too
            what, n, call = _plain(rec.get("detail")), rec.get("detail_len"), _plain(rec.get("call_id"))
            return [event(key, ts, self.user, session, "deny", "denial",
                           rec.get("denied_by"), tool, rec.get("detail"), self.host),
                    incident(key, ("", cut(what)) if what else None,
                             cwd=_plain(rec.get("cwd")), call_id=call if len(call) <= CODE_MAX else "",
                             length=n if isinstance(n, int) and not isinstance(n, bool) and 0 <= n <= SIZE_MAX
                             else len(what))]
        if rec.get("event") == "redaction":
            kinds = rec.get("kinds")
            kinds = ",".join(text(k) for k in kinds) if isinstance(kinds, list) else text(kinds)
            return [event(key, ts, self.user, session, "redact", "redaction",
                           "cc-redact-hook", tool, "%s x%s" % (kinds, text(rec.get("count"))), self.host)]
        return [event(key, ts, self.user, session, "pass", "tool-call", "", tool, rec.get("detail"),
                       self.host)]


# The launcher's line: a time, these four as name=value in this order, then
# the message. It writes each as one word with no space in it.
ADMIN_FIELDS = ("pid", "invoker", "target", "tty")
ADMIN_START = ("admin", "session", "START")
ADMIN_END = ("admin", "session", "END")
ADMIN_REFUSED = "REFUSED"
EXIT_CODE_RE = re.compile(r"[0-9]{1,3}")
PID_RE = re.compile(r"[0-9]{1,10}")


def _named(word, name):
    """The value of one name=value word, which must be the one expected."""
    key, eq, value = word.partition("=")
    if key != name or not eq or not value:
        raise ValueError("expected %s=..." % name)
    return value


class _admin_reader(object):
    """One line per privileged session started, ended or refused, as
    bin/cc-admin-session.sh stamps it. A line of any other shape is a bad
    line: nothing is guessed from it."""

    def __init__(self, host):
        self.host = host

    def restart(self, con):
        pass  # a rotated log's lines are history: they stay

    def finish(self, con, st):
        pass

    @staticmethod
    def parse(raw):
        words = raw.decode("utf-8").rstrip("\n").split(" ")
        if len(words) < 2 + len(ADMIN_FIELDS):
            raise ValueError("too short")
        rec = {"ts": words[0]}
        for name, word in zip(ADMIN_FIELDS, words[1:]):
            rec[name] = _named(word, name)
        if not PID_RE.fullmatch(rec["pid"]):
            raise ValueError("pid is not a number")
        said = words[1 + len(ADMIN_FIELDS):]
        start, end, refused = ADMIN_KINDS
        rec.update(reason="", rc=None)
        if tuple(said[:3]) == ADMIN_START:
            rec.update(kind=start, detail=" ".join(said[3:]))
        elif tuple(said[:3]) == ADMIN_END and len(said) == 4:
            code = _named(said[3], "rc")
            if not EXIT_CODE_RE.fullmatch(code):
                raise ValueError("exit code is not a number")
            rec.update(kind=end, rc=int(code), detail="")
        elif said[0] == ADMIN_REFUSED and len(said) > 1:
            rec.update(kind=refused, reason=_named(said[1], "reason"), detail=" ".join(said[2:]))
        else:
            raise ValueError("not a start, an end or a refusal")
        return rec

    def take(self, rec, key):
        ts = timestamp(rec["ts"])
        if not ts:
            raise ValueError("no time")
        return [("insert or ignore into admin_log values (?,?,?,?,?,?,?,?,?,?,?)", (
            _hash(key), self.host, ts, int(rec["pid"]), text(rec["invoker"]), text(rec["target"]),
            text(rec["tty"]), rec["kind"], text(rec["reason"]), rec["rc"], text(rec["detail"])[:DETAIL_MAX]))]


def _admin_log(con, cfg, stats):
    """Read the privileged session's log and record what was found there, so
    the page can tell no sessions from a log that was never read. Only root
    writes that file, so with owners checked it must be root's."""
    path, host = cfg["admin_log"], cfg["host_label"]
    _unset, _unread, absent, unreadable, state = ADMIN_LOG_STATES
    before = len(stats["skipped"])
    try:
        os.lstat(path)
    except FileNotFoundError:
        state = absent
    except OSError:
        pass  # anything else is said by the open below
    if state != absent:
        _file(con, cfg, path, owner(0), _admin_reader(host), stats, "%s:%s" % (host, path))
    why = stats["skipped"][before:]
    with con:
        con.execute("insert or replace into meta values ('admin_log', ?)", (json.dumps({
            "state": unreadable if why else state, "error": why[0][1] if why else None,
            "at": store.iso(datetime.datetime.utcnow()) + "Z"}),))


def model_label(model):
    """A Bedrock inference-profile ARN carries an AWS account id; keep only
    the fact that it is one."""
    if model.startswith("arn:"):
        return "arn:aws:bedrock:inference-profile"
    return model


def _code(v, chars=CODE_CHARS):
    """Whether a field is one of the vendor's short codes (rate_limit,
    classifier) or, with TOOL_CHARS, a tool's name: those are kept. A
    sentence, or anything long, is whatever the file's owner wrote and is not."""
    return isinstance(v, str) and 0 < len(v) <= CODE_MAX and chars.issuperset(v)


class _transcript_reader(object):
    parse = staticmethod(json_record)

    def __init__(self, path, user, project):
        self.path, self.user, self.project = path, user, project
        self.session = os.path.basename(path)[:-len(".jsonl")]
        self.records, self.first, self.last = 0, None, None
        self.calls = collections.OrderedDict()  # tool call id -> (tool name, what it asked for, its field names)

    def restart(self, con):
        con.execute("delete from sessions where user=? and path=?", (self.user, self.path))

    def finish(self, con, st):
        row = con.execute("select records, first_ts, last_ts from sessions where user=? and path=?",
                          (self.user, self.path)).fetchone()
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
        ts = timestamp(rec.get("timestamp"))
        if ts:
            self.first = ts if self.first is None else min(self.first, ts)
            self.last = ts if self.last is None else max(self.last, ts)
        return rows

    def _rows(self, rec, key):
        rows = []
        ts = timestamp(rec.get("timestamp"))
        session = text(rec.get("sessionId")) or self.session
        base = text(rec.get("uuid")) or key
        msg = rec.get("message") if isinstance(rec.get("message"), dict) else {}

        u = msg.get("usage")
        if rec.get("type") == "assistant" and isinstance(u, dict) and msg.get("id"):
            rows.append(("insert or replace into usage values (?,?,?,?,?,?,?,?,?)", (
                text(msg["id"]), text(ts), self.user, session, model_label(text(msg.get("model"))),
                count(u.get("input_tokens")), count(u.get("output_tokens")),
                count(u.get("cache_read_input_tokens")), count(u.get("cache_creation_input_tokens")))))

        q = rec.get("quotaLimits")
        if isinstance(q, dict) and q.get("status") == "rejected":
            kind = text(q.get("rateLimitType", "unknown"))
            # every retry while blocked is a record; the window (its reset
            # time) is the hit. With no reset time, each record stands alone.
            at = q.get("resetsAt")
            qkey = ("%s|quota|%s|%s" % (self.user, kind, at) if isinstance(at, int) and not isinstance(at, bool)
                    else base + "|quota")
            rows.append(event(qkey, ts, self.user, session, "quota", "rate-limit", "", "",
                               "%s rejected" % kind))
        if rec.get("isApiErrorMessage") or rec.get("apiErrorStatus"):
            status = rec.get("apiErrorStatus")
            said = ["HTTP %s" % text(status)] if status else []
            said += [rec["error"]] if _code(rec.get("error")) else []
            rows.append(event(base + "|api", ts, self.user, session, "error", "api-error", "", "",
                               " ".join(said) or "API error"))
        if rec.get("attributionSkill"):
            rows.append(event(base + "|skill", ts, self.user, session, "info", "skill", "", "",
                               rec["attributionSkill"]))
        if rec.get("attributionPlugin"):
            rows.append(event(base + "|plugin", ts, self.user, session, "info", "plugin", "", "",
                               rec["attributionPlugin"]))
        content = msg.get("content") if isinstance(msg.get("content"), list) else []
        for part in content:
            # the tool's name, and what it asked for in case the call is stopped
            if (isinstance(part, dict) and part.get("type") == "tool_use"
                    and isinstance(part.get("id"), str) and len(part["id"]) <= CODE_MAX
                    and _code(part.get("name"), TOOL_CHARS)):
                what, fields = asked(part.get("input"))
                self.calls[part["id"]] = (part["name"], what and (what[0], cut(what[1])), fields, what and len(what[1]))
                if len(self.calls) > CALLS_REMEMBERED:
                    self.calls.popitem(last=False)
        if rec.get("toolDenialKind"):
            kind = text(rec["toolDenialKind"])
            result = next((part for part in content if isinstance(part, dict)
                           and isinstance(part.get("tool_use_id"), str) and len(part["tool_use_id"]) <= CODE_MAX
                           and storable(part["tool_use_id"])), {})
            # a call read in an earlier run is not remembered: its tool and what it asked for are unknown
            tool, what, fields, length = self.calls.get(result.get("tool_use_id"), ("", None, None, None))
            decision = rec.get("permissionDecision") if isinstance(rec.get("permissionDecision"), dict) else {}
            why = decision.get("reasonType") if _code(decision.get("reasonType")) else ""
            rows.append(event(base + "|denial", ts, self.user, session,
                               "info" if kind in PERSON_DENIALS else "deny", "denial", kind, tool, why))
            version = _plain(rec.get("version"))
            rows.append(incident(
                base + "|denial", what, fields,
                # what a person typed when they said no is a message, and no message is kept
                "" if kind in PERSON_DENIALS else cut(_told(result.get("content"))),
                _plain(rec.get("cwd")), _plain(rec.get("gitBranch")),
                version if VERSION_RE.fullmatch(version) else "", result.get("tool_use_id", ""), length))
        cmd = rec.get("commandRun")
        if isinstance(cmd, dict) and cmd.get("command"):
            # the name only: the rest of the line is the person's arguments
            name = text(cmd["command"]).lstrip("/").split()
            if not name:
                raise ValueError("a command with no name")
            rows.append(event(base + "|cmd", ts, self.user, session, "info", "slash-command", "", "",
                               "/" + name[0]))
        return rows
