"""Loads the site config. Every key is required and no unknown key is allowed,
so a typo fails at start-up instead of silently using a default."""
import json
import os
import re

from fleetdash.vocab import SEVERITIES


class ConfigError(Exception):
    pass


KEYS = {
    "store": str,                  # SQLite file the collector writes and the server reads
    "host_label": str,             # label shown in the header, never a real host name in docs
    "bind": str,                   # loopback only: there is no TLS
    "port": int,                   # 0 picks a free port
    "transcript_glob": str,        # glob of ~/.claude/projects directories; "" reads no home directly
    "user_from_path": str,         # regex; group 1 is the user name in a transcript path
    "hook_log_dir": str,           # holds activity/<user>.jsonl and denied/<user>.jsonl; "" reads none
    "spool": str,                  # directory people's feed batches arrive in; "" for no feed
    "feed": dict,                  # {transcripts, state_dir}: what `feed` reads and where it keeps its place; ~ is the caller's home
    "token_file": str,             # where serve keeps its login token between starts; "" for a new one each start
    "claude_bin": str,             # the claude binary a check-in asks for its version; "" for version unknown
    "policy": dict,                # {deployed, source}: the policy this host holds, and the one the fleet should hold
    "host_stale_hours": int,       # a host not heard from for this long is shown as stale
    "docs": list,                  # [{label, path}]: directories of documents the Docs page shows
    "actions": list,               # [{id, label, about, argv, cwd, timeout_s}]: the only commands the Update page can run
    "runs": dict,                  # {dir, keep}: where each run's output is kept, and how many runs back
    "install": dict,               # {account, python, code_dir, config_file, units_dir, ingest_interval, prune_calendar}
    "verify_file_owner": bool,     # refuse a hook log or transcript not owned by the user it is for
    "bedrock_id_prefix": str,      # what a Bedrock message id starts with; "" to go by the model name alone
    "bedrock_model_pattern": str,  # regex on the model name that also marks a Bedrock call
    "prices_per_mtok": dict,       # model-family prefix -> USD per million tokens
    "seats": list,                 # [{tier, monthly_usd, users: [...]}]
    "retention": dict,             # severity -> {days, max_rows}
    "under_use": dict,             # {idle_days, median_fraction}: when the People page flags a person
}
PRICE_FIELDS = ("input", "output", "cache_read", "cache_write")
# Each nested table's keys and their types: exactly these, like the top level.
SHAPES = {
    "feed": {"transcripts": str, "state_dir": str},
    "policy": {"deployed": str, "source": str},
    "runs": {"dir": str, "keep": int},
    "install": {"account": str, "python": str, "code_dir": str, "config_file": str, "units_dir": str,
                "ingest_interval": str, "prune_calendar": str},
}
ROW_SHAPES = {
    "docs": {"label": str, "path": str},
    "actions": {"id": str, "label": str, "about": str, "argv": list, "cwd": str, "timeout_s": int},
}
# the server listens on IPv4 only
LOOPBACK = ("127.0.0.1", "localhost")


def load(path):
    try:
        with open(path) as fh:
            cfg = json.load(fh)
    except (OSError, ValueError) as e:
        raise ConfigError("cannot read config %s: %s" % (path, e))
    if not isinstance(cfg, dict):
        raise ConfigError("config must be a JSON object")
    unknown = sorted(set(cfg) - set(KEYS))
    missing = sorted(set(KEYS) - set(cfg))
    if unknown:
        raise ConfigError("unknown config keys: %s" % ", ".join(unknown))
    if missing:
        raise ConfigError("missing config keys: %s" % ", ".join(missing))
    for key, kind in KEYS.items():
        # bool is a subclass of int; a port of true is still wrong
        if not isinstance(cfg[key], kind) or (kind is int and isinstance(cfg[key], bool)):
            raise ConfigError("%s must be %s" % (key, kind.__name__))
    if cfg["bind"] not in LOOPBACK:
        raise ConfigError("bind must be a loopback address (%s): the server has no TLS"
                          % ", ".join(LOOPBACK))
    for key in ("user_from_path", "bedrock_model_pattern"):
        try:
            re.compile(cfg[key])
        except re.error as e:
            raise ConfigError("%s is not a valid regex: %s" % (key, e))
    for family, row in cfg["prices_per_mtok"].items():
        if not isinstance(row, dict) or sorted(row) != sorted(PRICE_FIELDS):
            raise ConfigError("prices_per_mtok[%s] needs exactly %s" % (family, ", ".join(PRICE_FIELDS)))
    for seat in cfg["seats"]:
        if not isinstance(seat, dict) or sorted(seat) != ["monthly_usd", "tier", "users"]:
            raise ConfigError("each seat needs exactly tier, monthly_usd, users")
    if sorted(cfg["retention"]) != sorted(SEVERITIES):
        raise ConfigError("retention needs exactly one row per severity: %s" % ", ".join(SEVERITIES))
    for sev, row in cfg["retention"].items():
        if not isinstance(row, dict) or sorted(row) != ["days", "max_rows"]:
            raise ConfigError("retention[%s] needs exactly days, max_rows" % sev)
    for key, shape in SHAPES.items():
        _shape(key, cfg[key], shape)
    for key, shape in ROW_SHAPES.items():
        for i, row in enumerate(cfg[key]):
            _shape("%s[%d]" % (key, i), row, shape)
        names = [row["label" if key == "docs" else "id"] for row in cfg[key]]
        if len(set(names)) != len(names):
            raise ConfigError("%s names the same entry twice" % key)
    for a in cfg["actions"]:
        # the id goes into a URL and the argv into exec: neither is ever built from a request
        if not a["id"] or not a["id"].replace("-", "").isalnum():
            raise ConfigError("actions id %r must be letters, digits and hyphens" % a["id"])
        if not a["argv"] or not all(isinstance(x, str) and x for x in a["argv"]):
            raise ConfigError("actions[%s].argv must be a list of non-empty strings" % a["id"])
        if a["timeout_s"] < 1:
            raise ConfigError("actions[%s].timeout_s must be at least 1" % a["id"])
    if cfg["actions"] and not os.path.isabs(cfg["runs"]["dir"]):
        raise ConfigError("runs.dir must be an absolute path when actions are listed: a run's output is kept there")
    if cfg["runs"]["keep"] < 1:
        raise ConfigError("runs.keep must be at least 1")
    if cfg["host_stale_hours"] < 1:
        raise ConfigError("host_stale_hours must be at least 1")
    u = cfg["under_use"]
    if sorted(u) != ["idle_days", "median_fraction"]:
        raise ConfigError("under_use needs exactly idle_days, median_fraction")
    if not isinstance(u["idle_days"], int) or isinstance(u["idle_days"], bool) or u["idle_days"] < 1:
        raise ConfigError("under_use.idle_days must be a whole number of days, at least 1")
    if (not isinstance(u["median_fraction"], (int, float)) or isinstance(u["median_fraction"], bool)
            or not 0 <= u["median_fraction"] <= 1):
        raise ConfigError("under_use.median_fraction must be between 0 and 1")
    return cfg


def _shape(name, value, shape):
    if not isinstance(value, dict) or sorted(value) != sorted(shape):
        raise ConfigError("%s needs exactly %s" % (name, ", ".join(sorted(shape))))
    for key, kind in shape.items():
        if not isinstance(value[key], kind) or (kind is int and isinstance(value[key], bool)):
            raise ConfigError("%s.%s must be %s" % (name, key, kind.__name__))
