"""The SQLite store: schema, connection and retention.

The store holds the shape of activity (who, when, which tool, which model,
how many tokens), never message content. It still holds the commands the
audit hook logged, so it is created owner-only.
"""
import datetime
import os
import sqlite3

SCHEMA = """
create table if not exists events (
    key      text primary key,   -- stable per source line, so a re-run inserts nothing
    ts       text not null,
    user     text not null,
    session  text not null default '',
    severity text not null,
    category text not null,
    source   text not null default '',  -- who decided: a rule, the classifier, a hook
    tool     text not null default '',
    detail   text not null default '',
    host     text not null default ''   -- the host whose hook logged it; '' when the source does not say
);
create index if not exists events_ts on events(ts);
create index if not exists events_filter on events(user, severity, category);

create table if not exists usage (
    id          text not null,     -- the API message id: streaming repeats it, the last line wins
    ts          text not null,
    user        text not null,
    session     text not null,
    model       text not null,
    input       integer not null,
    output      integer not null,
    cache_read  integer not null,
    cache_write integer not null,
    -- keyed by user too: a message id is whatever the transcript says, and a
    -- user who copies someone else's id must not overwrite their row
    primary key (user, id)
);
create index if not exists usage_ts on usage(ts);

create table if not exists sessions (
    path     text not null,
    user     text not null,
    project  text not null,
    session  text not null,
    bytes    integer not null,
    first_ts text,               -- NULL until a line with a timestamp is seen
    last_ts  text,
    records  integer not null,
    -- keyed by user too: a path is whatever a feed batch says, and one
    -- person naming another's file must not replace that person's row
    primary key (user, path)
);

create table if not exists checkpoints (
    path       text primary key,
    inode      integer not null,
    generation integer not null,  -- bumped each time the file is seen rotated
    offset     integer not null
);

create table if not exists hosts (
    host           text primary key,
    last_seen      text not null,   -- when it last checked in
    claude_version text,            -- NULL: the check-in could not read it
    policy_sha256  text,            -- NULL: no policy file was readable there
    reported_by    text not null    -- whose run carried the check-in
);

create table if not exists runs (
    id        integer primary key autoincrement,
    ts        text not null,     -- when it was started
    action    text not null,
    argv      text not null,     -- JSON list: the command as it was started, whatever the config says now
    cwd       text not null,
    state     text not null,     -- vocab.RUN_STATES
    exit_code integer,           -- NULL unless state is done
    seconds   real,              -- NULL while it runs
    bytes     integer            -- how much it printed; NULL while it runs
);

create table if not exists meta (k text primary key, v text not null);
"""

ISO = "%Y-%m-%dT%H:%M:%S"
# Bumped when a table's key or what a row means changes. A store under any
# other version is refused, not mixed: rebuilding it is one ingest.
#   2: usage keyed by (user, id); one rate-limit event per limit window
#   3: every stored timestamp is UTC ISO 8601 and not in the future
#   4: ...in ASCII digits only; a 3 store may hold other scripts' digits
#   5: an event names its host and a hook-log key includes it; sessions keyed
#      by (user, path); host check-ins and action runs have tables
#   6: a run has a row from its start, with its command line and its state
SCHEMA_VERSION = 6


def connect(cfg):
    path = cfg["store"]
    if not os.path.exists(path):
        # create it owner-only before sqlite opens it with the umask
        os.close(os.open(path, os.O_CREAT | os.O_WRONLY, 0o600))
    con = sqlite3.connect(path, timeout=30)
    con.row_factory = sqlite3.Row
    fresh = con.execute("select count(*) from sqlite_master").fetchone()[0] == 0
    con.executescript(SCHEMA)
    if fresh:
        with con:
            con.execute("insert into meta values ('schema', ?)", (str(SCHEMA_VERSION),))
    row = con.execute("select v from meta where k='schema'").fetchone()
    if row is None or row["v"] != str(SCHEMA_VERSION):
        con.close()
        raise StoreError("%s was written under store schema %s, this is %d: move it aside and ingest again"
                         % (path, row["v"] if row else "1 or older", SCHEMA_VERSION))
    return con


class StoreError(Exception):
    pass


def iso(dt):
    return dt.strftime(ISO)


def prune(cfg, now=None):
    """Drop events past their severity's age or row cap. Usage rows are kept:
    they are small and the cost history needs them. Returns removed counts."""
    now = now or datetime.datetime.utcnow()
    removed = {}
    con = connect(cfg)
    try:
        with con:
            for sev, rule in sorted(cfg["retention"].items()):
                cutoff = iso(now - datetime.timedelta(days=rule["days"]))
                n = con.execute("delete from events where severity=? and ts<?", (sev, cutoff)).rowcount
                n += con.execute(
                    "delete from events where severity=? and key not in "
                    "(select key from events where severity=? order by ts desc, key desc limit ?)",
                    (sev, sev, rule["max_rows"])).rowcount
                if n:
                    removed[sev] = n
        con.execute("vacuum")
    finally:
        con.close()
    return removed
