"""Loads the site config. Every key is required and no unknown key is allowed,
so a typo fails at start-up instead of silently using a default."""
import json
import re

from fleetdash.vocab import SEVERITIES


class ConfigError(Exception):
    pass


KEYS = {
    "store": str,                  # SQLite file the collector writes and the server reads
    "host_label": str,             # label shown in the header, never a real host name in docs
    "bind": str,                   # loopback only: there is no TLS
    "port": int,                   # 0 picks a free port
    "transcript_glob": str,        # glob of ~/.claude/projects directories
    "user_from_path": str,         # regex; group 1 is the user name in a transcript path
    "hook_log_dir": str,           # holds activity/<user>.jsonl and denied/<user>.jsonl
    "verify_file_owner": bool,     # refuse a hook log or transcript not owned by the user it is for
    "bedrock_model_pattern": str,  # regex on the model id that marks a Bedrock call
    "prices_per_mtok": dict,       # model-family prefix -> USD per million tokens
    "seats": list,                 # [{tier, monthly_usd, users: [...]}]
    "retention": dict,             # severity -> {days, max_rows}
    "under_use": dict,             # {idle_days, median_fraction}: when the People page flags a person
}
PRICE_FIELDS = ("input", "output", "cache_read", "cache_write")
LOOPBACK = ("127.0.0.1", "::1", "localhost")


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
    u = cfg["under_use"]
    if sorted(u) != ["idle_days", "median_fraction"]:
        raise ConfigError("under_use needs exactly idle_days, median_fraction")
    if not isinstance(u["idle_days"], int) or isinstance(u["idle_days"], bool) or u["idle_days"] < 1:
        raise ConfigError("under_use.idle_days must be a whole number of days, at least 1")
    if (not isinstance(u["median_fraction"], (int, float)) or isinstance(u["median_fraction"], bool)
            or not 0 <= u["median_fraction"] <= 1):
        raise ConfigError("under_use.median_fraction must be between 0 and 1")
    return cfg
