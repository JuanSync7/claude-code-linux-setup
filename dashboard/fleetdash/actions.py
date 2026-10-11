"""The commands the Update page can start: only the ones the config lists.

A request names an action by its id and nothing else. The argument list, the
working directory and the time limit all come from the config, so nothing a
browser sends is ever part of a command line. One action runs at a time.
"""
import datetime
import os
import secrets
import signal
import subprocess
import tempfile
import threading
import time

from fleetdash import store

OUTPUT_MAX = 256 << 10


class Busy(Exception):
    pass


class Runner(object):
    def __init__(self, cfg):
        self.cfg = cfg
        self.by_id = {a["id"]: a for a in cfg["actions"]}
        # A page must present this to start anything. It is new at every start
        # and only readable through a logged-in GET, so a request forged from
        # another site, which cannot read responses, cannot know it.
        self.key = secrets.token_urlsafe(24)
        self._lock = threading.Lock()
        self._output = {}
        self.running = None

    def listing(self):
        con = store.connect(self.cfg)
        try:
            last = {r["action"]: dict(r) for r in con.execute(
                "select action, ts, exit_code, seconds from runs where id in "
                "(select max(id) from runs group by action)")}
        finally:
            con.close()
        return {"run_key": self.key, "running": self.running, "actions": [
            {"id": a["id"], "label": a["label"], "about": a["about"], "command": a["argv"],
             "timeout_s": a["timeout_s"], "last": last.get(a["id"]), "output": self._output.get(a["id"])}
            for a in self.cfg["actions"]]}

    def run(self, action_id):
        """KeyError for an id the config does not list, Busy while another runs."""
        a = self.by_id[action_id]
        if not self._lock.acquire(False):
            raise Busy()
        try:
            self.running = action_id
            started = time.time()
            ts = store.iso(datetime.datetime.utcnow()) + "Z"
            # output goes to a file, not a pipe: a command that prints without
            # end fills a disk quota the time limit then stops, not this process
            with tempfile.TemporaryFile() as out:
                try:
                    p = subprocess.Popen(a["argv"], cwd=a["cwd"] or None, stdin=subprocess.DEVNULL,
                                         stdout=out, stderr=subprocess.STDOUT, start_new_session=True)
                except OSError as e:
                    result = {"exit_code": None, "timed_out": False, "output": "could not start: %s" % e,
                              "truncated": False}
                else:
                    timed_out = False
                    try:
                        code = p.wait(timeout=a["timeout_s"])
                    except subprocess.TimeoutExpired:
                        timed_out, code = True, None
                        # its own session, so the children it started stop with it
                        try:
                            os.killpg(p.pid, signal.SIGKILL)
                        except OSError:
                            pass
                        p.wait()
                    size = out.seek(0, os.SEEK_END)
                    out.seek(0)
                    result = {"exit_code": code, "timed_out": timed_out, "truncated": size > OUTPUT_MAX,
                              "output": out.read(OUTPUT_MAX).decode("utf-8", "replace")}
            result.update(id=action_id, ts=ts, seconds=round(time.time() - started, 2))
            con = store.connect(self.cfg)
            try:
                with con:
                    con.execute("insert into runs (ts, action, exit_code, seconds) values (?,?,?,?)",
                                (ts, action_id, result["exit_code"], result["seconds"]))
            finally:
                con.close()
            self._output[action_id] = result
            return result
        finally:
            self.running = None
            self._lock.release()
