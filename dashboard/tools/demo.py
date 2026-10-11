"""Writes a synthetic fleet and its config, for screenshots and trying the UI.
Names, projects and commands are invented. The seats carry the Team plan's
list price per month and the token prices are illustrative; a site's config
carries what the site pays.   python3 tools/demo.py DIR   then   python3 -m fleetdash -c DIR/config.json ingest"""
import calendar
import datetime
import json
import os
import random
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), os.pardir))
from tests.fixtures import Fleet, assistant, usage  # noqa: E402

PEOPLE = {"amira": 9, "ben": 6, "chen": 4, "dana": 3, "eli": 2, "farah": 1, "gus": 0.5}
TOOLS = [("Bash", "make test TARGET=parser"), ("Read", "src/parser.c"), ("Edit", "tests/test_parser.c"),
         ("Bash", "grep -rn parse_line src/"), ("Grep", "parse_line"), ("Bash", "git status")]
DENIES = [("Bash", "curl -O https://example.com/x.tgz", "Bash(curl:*) deny rule"),
          ("Bash", "sudo dnf install foo", "Bash(sudo:*) deny rule"),
          ("Read", "~/.ssh/id_rsa", "Read(~/.ssh/**) deny rule"),
          ("Bash", "scp out.tar build:/tmp", "Blocked by classifier"),
          ("Bash", "rm -rf ../shared", "Blocked by classifier")]


def main(out):
    random.seed(7)
    now = datetime.datetime(2026, 10, 10, 12)
    f = Fleet.__new__(Fleet)
    f.root, f.store = out, os.path.join(out, "store.db")
    n = 0
    for person, weight in PEOPLE.items():
        for proj in range(1 + int(weight // 3)):
            for sess in range(int(3 + weight * 2)):
                day = now - datetime.timedelta(days=random.randint(0, 120) ** 2 // 120, hours=random.randint(0, 9))
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
    path = f.config(port=8765, host_label="demo", verify_file_owner=False,
                    prices_per_mtok={"claude-opus": {"input": 5.0, "output": 25.0, "cache_read": 0.5, "cache_write": 6.25},
                                     "claude-sonnet": {"input": 3.0, "output": 15.0, "cache_read": 0.3, "cache_write": 3.75},
                                     "claude-haiku": {"input": 1.0, "output": 5.0, "cache_read": 0.1, "cache_write": 1.25}},
                    seats=[{"tier": "Premium", "monthly_usd": 125.0, "users": ["amira", "ben", "chen"]},
                           {"tier": "Standard", "monthly_usd": 25.0, "users": ["dana", "eli", "farah", "gus"]}])
    print(path)


if __name__ == "__main__":
    os.makedirs(sys.argv[1], exist_ok=True)
    main(sys.argv[1])
