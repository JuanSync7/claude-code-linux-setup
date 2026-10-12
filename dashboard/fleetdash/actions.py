"""The commands the Update page can start: only the ones the config lists.

A request names an action by its id and nothing else. The argument list, the
working directory and the time limit all come from the config, so nothing a
browser sends is ever part of a command line. One action runs at a time.

Starting one answers at once with the run's number. Everything the command
prints goes to that run's own file under runs.dir as it is printed, so the
page can show it while the command is still running, and anyone can read it
after. The run's row keeps the command line it was started with: the config
may say something else by the time someone looks.
"""
import codecs
import datetime
import json
import os
import secrets
import signal
import sqlite3
import subprocess
import threading
import time

from fleetdash import store
from fleetdash.vocab import RUN_INTERRUPTED

# how much of one run's output the page is given; the file has all of it
OUTPUT_MAX = 1 << 20
# how much of it one request is given
CHUNK_MAX = 64 << 10
COLUMNS = "id, ts, action, argv, cwd, state, exit_code, seconds, bytes"


class Busy(Exception):
    pass


class CannotStart(Exception):
    """The run could not be recorded or its output file made, so nothing ran."""


class Runner(object):
    def __init__(self, cfg):
        self.cfg = cfg
        self.dir = cfg["runs"]["dir"]
        self.by_id = {a["id"]: a for a in cfg["actions"]}
        # A page must present this to start anything. It is new at every start
        # and only readable through a logged-in GET, so a request forged from
        # another site, which cannot read responses, cannot know it.
        self.key = secrets.token_urlsafe(24)
        self._lock = threading.Lock()
        self.current = None  # the run this server has going: (run, action id)

    def _row(self, r):
        """A run as the page is told it. A row still marked running that this
        server is not running was left by one that stopped: it has no result."""
        mine = self.current is not None and self.current[0] == r["id"]
        return {"run": r["id"], "ts": r["ts"], "action": r["action"], "command": json.loads(r["argv"]),
                "cwd": r["cwd"], "state": RUN_INTERRUPTED if r["state"] == "running" and not mine else r["state"],
                "exit_code": r["exit_code"], "seconds": r["seconds"], "bytes": r["bytes"]}

    def listing(self):
        con = store.connect(self.cfg)
        try:
            runs = [self._row(r) for r in con.execute("select %s from runs order by id desc" % COLUMNS)]
        finally:
            con.close()
        last = {}
        for r in runs:
            last.setdefault(r["action"], r)
        current = self.current
        return {"run_key": self.key, "busy": self._lock.locked(),
                "running": current[1] if current else None, "run": current[0] if current else None,
                "runs": runs, "actions": [
                    {"id": a["id"], "label": a["label"], "about": a["about"], "command": a["argv"], "cwd": a["cwd"],
                     "timeout_s": a["timeout_s"], "last": last.get(a["id"])} for a in self.cfg["actions"]]}

    def _file(self, run):
        return os.path.join(self.dir, "%d.log" % run)

    def start(self, action_id):
        """Starts it and returns its run number. KeyError for an id the config
        does not list, Busy while another runs, CannotStart when the run could
        not be recorded: a command whose output would be lost is not run."""
        a = self.by_id[action_id]
        if not self._lock.acquire(False):
            raise Busy()
        try:
            ts = store.iso(datetime.datetime.utcnow()) + "Z"
            try:
                os.makedirs(self.dir, mode=0o700, exist_ok=True)
                con = store.connect(self.cfg)
                try:
                    # one transaction: a run with no output file leaves no row
                    with con:
                        run = con.execute(
                            "insert into runs (ts, action, argv, cwd, state) values (?,?,?,?,'running')",
                            (ts, action_id, json.dumps(a["argv"]), a["cwd"])).lastrowid
                        out = os.open(self._file(run), os.O_CREAT | os.O_EXCL | os.O_WRONLY | os.O_NOFOLLOW, 0o600)
                finally:
                    con.close()
            except (OSError, sqlite3.Error) as e:
                raise CannotStart("cannot keep this run's output under %s: %s" % (self.dir, e))
            self.current = (run, action_id)
            threading.Thread(target=self._run, args=(a, run, out), daemon=True).start()
            return run
        except BaseException:
            self._lock.release()
            raise

    def _run(self, a, run, out):
        started = time.time()
        try:
            state, code = "done", None
            try:
                try:
                    p = subprocess.Popen(a["argv"], cwd=a["cwd"] or None, stdin=subprocess.DEVNULL,
                                         stdout=out, stderr=subprocess.STDOUT, start_new_session=True)
                except OSError as e:
                    state = "not-started"
                    os.write(out, ("could not start: %s\n" % e).encode("utf-8", "replace"))
                else:
                    try:
                        code = p.wait(timeout=a["timeout_s"])
                    except subprocess.TimeoutExpired:
                        state = "timed-out"
                        # its own session, so the children it started stop with it
                        try:
                            os.killpg(p.pid, signal.SIGKILL)
                        except OSError:
                            pass
                        p.wait()
                size = os.fstat(out).st_size
            finally:
                os.close(out)
            con = store.connect(self.cfg)
            try:
                with con:
                    con.execute("update runs set state=?, exit_code=?, seconds=?, bytes=? where id=?",
                                (state, code, round(time.time() - started, 2), size, run))
                    old = [r[0] for r in con.execute("select id from runs order by id desc limit -1 offset ?",
                                                     (self.cfg["runs"]["keep"],))]
                    con.executemany("delete from runs where id=?", [(i,) for i in old])
            finally:
                con.close()
            for i in old:
                try:
                    os.unlink(self._file(i))
                except FileNotFoundError:
                    pass
        finally:
            self.current = None
            self._lock.release()

    def read(self, run, offset):
        """The run and what it printed from offset on, one chunk at a time.
        KeyError for a run that is not kept, ValueError for an offset past
        what it has printed. `more` says whether to ask again from `next`."""
        con = store.connect(self.cfg)
        try:
            r = con.execute("select %s from runs where id=?" % COLUMNS, (run,)).fetchone()
        finally:
            con.close()
        if r is None:
            raise KeyError(run)
        row = self._row(r)
        going = row["state"] == "running"
        try:
            fd = os.open(self._file(run), os.O_RDONLY | os.O_NOFOLLOW)
        except FileNotFoundError:
            raw, size = b"", 0
        else:
            with os.fdopen(fd, "rb") as fh:
                size = os.fstat(fd).st_size
                fh.seek(offset)
                raw = fh.read(max(0, min(CHUNK_MAX, OUTPUT_MAX - offset)))
        if offset > size:
            raise ValueError("offset is past the %d bytes this run has printed" % size)
        end = offset + len(raw)
        # A chunk can end inside a character. Unless nothing will follow it,
        # that character is left for the next chunk to give whole.
        last = end >= OUTPUT_MAX or (end == size and not going)
        decoder = codecs.getincrementaldecoder("utf-8")("replace")
        text = decoder.decode(raw, last)
        nxt = end - len(decoder.getstate()[0])
        return {"run": row, "offset": offset, "next": nxt, "size": size, "output": text, "file": self._file(run),
                "more": nxt < min(size, OUTPUT_MAX) or (going and nxt < OUTPUT_MAX),
                "cut": size > OUTPUT_MAX and nxt >= OUTPUT_MAX}
