"""Writes a synthetic fleet and its config, for screenshots and trying the UI.
Names, hosts, projects, commands and the policy are invented. The seats carry
the Team plan's list price per month and the token prices are illustrative; a
site's config carries what the site pays. The documents and the Update page's
commands are this repository's own, and none of those commands changes a host.
   python3 tools/demo.py DIR   then   python3 -m fleetdash -c DIR/config.json ingest"""
import calendar
import datetime
import hashlib
import json
import os
import random
import sys

DASH = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REPO = os.path.dirname(DASH)
sys.path.insert(0, DASH)
from tests.fixtures import Fleet, assistant, usage  # noqa: E402

PEOPLE = {"amira": 9, "ben": 6, "chen": 4, "dana": 3, "eli": 2, "farah": 1, "gus": 0.5}
TOOLS = [("Bash", "make test TARGET=parser"), ("Read", "src/parser.c"), ("Edit", "tests/test_parser.c"),
         ("Bash", "grep -rn parse_line src/"), ("Grep", "parse_line"), ("Bash", "git status")]
DENIES = [("Bash", "curl -O https://example.com/x.tgz", "Bash(curl:*) deny rule"),
          ("Bash", "sudo dnf install foo", "Bash(sudo:*) deny rule"),
          ("Read", "~/.ssh/id_rsa", "Read(~/.ssh/**) deny rule"),
          ("Bash", "scp out.tar build:/tmp", "Blocked by classifier"),
          ("Bash", "rm -rf ../shared", "Blocked by classifier")]


POLICY = {"permissions": {"deny": ["Bash(sudo:*)", "Bash(curl:*)", "Bash(wget:*)", "Read(~/.ssh/**)", "Read(**/.env)"],
                          "ask": ["Bash(git push:*)", "Bash(rm -rf:*)"],
                          "allow": ["Read", "Grep", "Glob", "Bash(make:*)", "Bash(git status)", "Bash(git diff:*)"]},
          "hooks": {"PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "/usr/local/libexec/claude-code/audit-log"}]}],
                    "PostToolUse": [{"matcher": "Read|Bash", "hooks": [{"type": "command", "command": "/usr/local/libexec/claude-code/redact"}]}],
                    "SessionEnd": [{"hooks": [{"type": "command", "command": "/usr/local/share/fleetdash/bin/fleetdash feed"}]}]},
          "sandbox": {"enabled": True}, "env": {"HTTPS_PROXY": "http://proxy.invalid:3128", "DISABLE_TELEMETRY": "1"},
          "requiredMinimumVersion": "2.1.17"}
# (host, hours since it last checked in, Claude Code version, holds the fleet's policy, who sent the batch)
HOSTS = [("login-01", 1, "2.1.19", True, "amira"), ("login-02", 3, "2.1.19", True, "ben"),
         ("build-01", 2, "2.1.17", True, "chen"), ("build-02", 5, "2.1.19", False, "dana"),
         ("lab-03", 9 * 24, "2.1.12", True, "eli")]


def _written(path, text, mode=0o644):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as fh:
        fh.write(text)
    os.chmod(path, mode)
    return path


def _hosts(out, now, fleet_policy):
    """One batch per host in the spool, as each host's `feed` would leave it:
    a check-in, and the blocks that host's hooks logged."""
    for n, (host, hours, version, same, user) in enumerate(HOSTS):
        ts = (now - datetime.timedelta(hours=hours)).strftime("%Y-%m-%dT%H:%M:%SZ")
        policy = fleet_policy if same else hashlib.sha256(host.encode()).hexdigest()
        lines = [{"t": "batch", "v": 1, "host": host, "user": user, "ts": ts, "claude_version": version,
                  "policy_sha256": policy}]
        for k in range(random.randint(1, 6)):
            tool, detail, by = random.choice(DENIES)
            lines.append({"t": "event", "key": "%s-%d" % (host, k), "ts": ts, "session": "s", "severity": "deny",
                          "category": "denial", "source": by, "tool": tool, "detail": detail, "host": host})
        _written(os.path.join(out, "spool", "%04d-%s.jsonl" % (n, host)), "".join(json.dumps(x) + "\n" for x in lines))


def main(out):
    random.seed(7)
    # the server reads the real clock, so a fixed date would age out of every window
    now = datetime.datetime.utcnow().replace(minute=0, second=0, microsecond=0)
    f = Fleet.__new__(Fleet)
    f.root, f.store = out, os.path.join(out, "store.db")
    n = 0
    for person, weight in PEOPLE.items():
        for proj in range(1 + int(weight // 3)):
            for sess in range(int(3 + weight * 2)):
                # a chat runs up to three hours: start it far enough back that none of it is in the future
                day = now - datetime.timedelta(days=random.randint(0, 120) ** 2 // 120, hours=random.randint(4, 13))
                recs = []
                for k in range(int(20 * weight * random.random()) + 3):
                    n += 1
                    ts = (day + datetime.timedelta(minutes=k)).strftime("%Y-%m-%dT%H:%M:%SZ")
                    model = random.choice(["claude-opus-5-5"] * 5 + ["claude-sonnet-5-5"] * 3 + ["claude-haiku-5-5"]
                                          + (["eu.anthropic.claude-opus-5-5"] * 3 if person in ("chen", "dana") else []))
                    extra = {}
                    if random.random() < 0.004 * weight:
                        # a rejection names the window it falls in by when that window resets,
                        # so retries inside one window count as one hit, as a transcript records them
                        kind = random.choice(["five_hour"] * 4 + ["seven_day"])
                        span = 5 * 3600 if kind == "five_hour" else 7 * 86400
                        at = calendar.timegm((day + datetime.timedelta(minutes=k)).timetuple())
                        extra["quotaLimits"] = {"status": "rejected", "rateLimitType": kind,
                                                "resetsAt": at - at % span + span}
                    if random.random() < 0.01:
                        extra.update(isApiErrorMessage=True, apiErrorStatus=random.choice([429, 500, 529]))
                    if random.random() < 0.03:
                        extra["attributionSkill"] = random.choice(["code-review", "debugging", "brainstorming"])
                    recs.append(assistant("%08d" % n, "msg%d" % n, ts, model, usage(
                        i=random.randint(5, 900), o=random.randint(100, 4000),
                        cr=random.randint(20000, 160000), cw=random.randint(0, 9000)), **extra))
                    if random.random() < 0.02:
                        recs.append({"type": "system", "subtype": "local_command", "uuid": "c%d" % n, "timestamp": ts,
                                     "commandRun": {"command": random.choice(["compact", "review", "clear", "init"])}})
                f.transcript(person, "-projects-proj%d-work" % proj, "sess%d-%d" % (proj, sess), recs)
                acts, dens = [], []
                for k in range(len(recs)):
                    ts = recs[k]["timestamp"]
                    tool, detail = random.choice(TOOLS)
                    acts.append({"ts": ts, "user": person, "session": "s", "tool": tool, "detail": detail})
                    if random.random() < 0.02:
                        tool, detail, by = random.choice(DENIES)
                        dens.append({"ts": ts, "user": person, "session": "s", "tool": tool, "detail": detail, "denied_by": by})
                    if random.random() < 0.003:
                        acts.append({"ts": ts, "user": person, "session": "s", "event": "redaction", "tool": "Bash",
                                     "kinds": [random.choice(["private-key", "aws-key", "jwt"])], "count": 1})
                f.hooklog("activity", person, acts)
                f.hooklog("denied", person, dens)
    text = json.dumps(POLICY, indent=2) + "\n"
    source = _written(os.path.join(out, "policy", "source.json"), text)
    deployed = _written(os.path.join(out, "policy", "deployed.json"), text)
    claude = _written(os.path.join(out, "bin", "claude"), "#!/bin/sh\necho '2.1.19 (Claude Code)'\n", 0o755)
    _hosts(out, now, hashlib.sha256(text.encode()).hexdigest())
    config = os.path.join(out, "config.json")
    run = [sys.executable, "-m", "fleetdash", "-c", config]
    actions = [{"id": "ingest", "label": "Read new logs now", "cwd": DASH, "timeout_s": 300, "argv": run + ["ingest"],
                "about": "Reads what the hosts logged since the last run, instead of waiting for the timer."},
               {"id": "install-preview", "label": "Preview the dashboard install", "cwd": DASH, "timeout_s": 60,
                "argv": run + ["install"],
                "about": "Lists what installing this dashboard as a service would place. Changes nothing."}]
    docs = [{"label": "Dashboard", "path": os.path.join(DASH, "README.md")},
            {"label": "Dashboard design", "path": os.path.join(DASH, "docs")}]
    if os.path.exists(os.path.join(REPO, "bin", "cc-ci-check.sh")):
        actions.append({"id": "repo-checks", "label": "Run the repository checks", "cwd": REPO, "timeout_s": 600,
                        "argv": ["bash", "bin/cc-ci-check.sh"],
                        "about": "The checks CI runs on every push. Reads the repository, changes nothing."})
        docs.append({"label": "Fleet guides", "path": os.path.join(REPO, "docs")})
    path = f.config(port=0, host_label="demo", verify_file_owner=False, spool=os.path.join(out, "spool"),
                    claude_bin=claude, policy={"deployed": deployed, "source": source}, docs=docs, actions=actions,
                    prices_per_mtok={"claude-opus": {"input": 5.0, "output": 25.0, "cache_read": 0.5, "cache_write": 6.25},
                                     "claude-sonnet": {"input": 3.0, "output": 15.0, "cache_read": 0.3, "cache_write": 3.75},
                                     "claude-haiku": {"input": 1.0, "output": 5.0, "cache_read": 0.1, "cache_write": 1.25}},
                    seats=[{"tier": "Premium", "monthly_usd": 125.0, "users": ["amira", "ben", "chen"]},
                           {"tier": "Standard", "monthly_usd": 25.0, "users": ["dana", "eli", "farah", "gus"]}])
    print(path)


if __name__ == "__main__":
    os.makedirs(sys.argv[1], exist_ok=True)
    main(sys.argv[1])
