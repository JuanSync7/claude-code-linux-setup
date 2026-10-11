"""Builds a fake fleet on disk: homes with transcripts, and the hook logs.

Everything a test needs is written under one temporary root, so no test reads
a real home directory or a real log. CANARY marks text that must never reach
the store: message content, prompt text, slash-command arguments.
"""
import json
import os
import shutil
import tempfile

CANARY = "ZZCANARYZZ"


def assistant(uuid, msg_id, ts, model, usage, **extra):
    rec = {"type": "assistant", "uuid": uuid, "timestamp": ts, "sessionId": "s-" + uuid[:2],
           "message": {"id": msg_id, "model": model, "usage": usage,
                       "content": [{"type": "text", "text": "reply " + CANARY}]}}
    rec.update(extra)
    return rec


def usage(i=10, o=20, cr=300, cw=40):
    return {"input_tokens": i, "output_tokens": o, "cache_read_input_tokens": cr,
            "cache_creation_input_tokens": cw}


class Fleet(object):
    """A temporary tree laid out like a host: <root>/home/<user>/.claude/projects
    and <root>/log/{activity,denied}/<user>.jsonl."""

    def __init__(self):
        self.root = tempfile.mkdtemp(prefix="fleetdash-")
        self.store = os.path.join(self.root, "store.db")

    def close(self):
        shutil.rmtree(self.root, ignore_errors=True)

    def transcript(self, user, project, session, records):
        d = os.path.join(self.root, "home", user, ".claude", "projects", project)
        os.makedirs(d, exist_ok=True)
        path = os.path.join(d, session + ".jsonl")
        with open(path, "a") as f:
            for r in records:
                f.write(json.dumps(r) + "\n")
        return path

    def hooklog(self, kind, user, records):
        d = os.path.join(self.root, "log", kind)
        os.makedirs(d, exist_ok=True)
        path = os.path.join(d, user + ".jsonl")
        with open(path, "a") as f:
            for r in records:
                f.write(json.dumps(r) + "\n")
        return path

    def config(self, **over):
        cfg = {
            "store": self.store,
            "host_label": "test-host",
            "bind": "127.0.0.1",
            "port": 0,
            "transcript_glob": os.path.join(self.root, "home", "*", ".claude", "projects"),
            "user_from_path": "/home/([^/]+)/",
            "hook_log_dir": os.path.join(self.root, "log"),
            "spool": "",
            "feed": {"transcripts": os.path.join(self.root, "home", "nobody", ".claude", "projects"),
                     "state_dir": os.path.join(self.root, "feed-state")},
            "token_file": "",
            "claude_bin": "",
            "policy": {"deployed": os.path.join(self.root, "etc", "managed-settings.json"), "source": ""},
            "host_stale_hours": 72,
            "docs": [],
            "actions": [],
            "install": {"account": "", "python": "/usr/bin/python3",
                        "code_dir": "/usr/local/share/fleetdash", "config_file": "/etc/fleetdash/config.json",
                        "units_dir": "/etc/systemd/system", "ingest_interval": "5min", "prune_calendar": "daily"},
            # the test runner owns every fixture file, whatever its name
            "verify_file_owner": False,
            "bedrock_model_pattern": r"^(?:(?:[a-z]{2,4}\.)?anthropic\.|arn:aws:bedrock:)",
            "prices_per_mtok": {
                "claude-opus": {"input": 10.0, "output": 50.0, "cache_read": 1.0, "cache_write": 20.0}
            },
            "seats": [{"tier": "Max", "monthly_usd": 100.0, "users": ["alice"]}],
            "under_use": {"idle_days": 14, "median_fraction": 0.1},
            "retention": {"pass": {"days": 14, "max_rows": 1000},
                          "info": {"days": 30, "max_rows": 1000},
                          "deny": {"days": 365, "max_rows": 100000},
                          "redact": {"days": 365, "max_rows": 100000},
                          "quota": {"days": 365, "max_rows": 100000},
                          "error": {"days": 180, "max_rows": 100000}},
        }
        cfg.update(over)
        path = os.path.join(self.root, "config.json")
        with open(path, "w") as f:
            json.dump(cfg, f)
        return path
