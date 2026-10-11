# cc-coupling.py - do the static files agree with config.sh?
#
# Scripts read config.sh at run time, but some files cannot: the policies, the
# systemd units, the logrotate stanza and the sudoers drop-in are read by
# claude, systemd, logrotate and sudo, none of which sources a shell file. A
# value appears in them literally - and a value written twice can disagree. A unit
# that runs a script from a directory nothing was installed to, or a logrotate
# stanza for a directory no log is written to, looks configured and does
# nothing. This holds each of them to config.sh.
#
# Two kinds of rule:
#   * STRUCTURAL - each file's paths must sit where config.sh puts things:
#     ExecStart under CC_SBIN, logrotate paths under CC_LOGDIR, sudoers naming
#     %CC_ADMIN_GROUP and CC_SBIN, policy hooks under CC_SBIN, the status line
#     at CC_STATUSLINE, the guide under CC_SHARE, a banner address equal to
#     CC_SUPPORT_CONTACT.
#   * DRIFT - a site whose config.sh moves a path or address away from the
#     template's value must edit every static file that still spells the
#     template's value. CI runs on the template, where this never fires; the
#     installer runs on the site's config.sh, where it does.
#
# Usage: the caller loads config through lib/cc-config.sh and exports CC_*:
#   bash -c '. lib/cc-config.sh && export ${!CC_@} && python3 lib/cc-coupling.py .'
# Prints one line per disagreement; exit 0 none, 1 some, 2 usage.
# Callers: CI check [12] (bin/cc-ci-check.sh) and cc-install.sh gate 4c.

import glob
import json
import os
import re
import sys

if len(sys.argv) != 2 or not os.path.isdir(sys.argv[1]):
    sys.exit("usage: cc-coupling.py <repo root>   (with the CC_* config exported)")
root = sys.argv[1]
env = os.environ
need = ["CC_SBIN", "CC_SHARE", "CC_LOGDIR", "CC_ADMIN_GROUP", "CC_SUPPORT_CONTACT",
        "CC_STATUSLINE", "CC_ETC_ADMIN"]
missing = [k for k in need if not env.get(k)]
if missing:
    print("cc-coupling: config not exported (" + " ".join(missing) + ") - nothing could be checked")
    sys.exit(2)
sbin, share, logdir = (env[k].rstrip("/") for k in ("CC_SBIN", "CC_SHARE", "CC_LOGDIR"))
problems = []


def rel(path):
    return os.path.relpath(path, root)


def files(pattern):
    return sorted(glob.glob(os.path.join(root, pattern)))


# --- systemd units: what they run must be where the scripts are installed ----
# aws/systemd/ holds the posture unit, installed only on AWS hosts - same rule.
for f in files("systemd/*.service") + files("aws/systemd/*.service"):
    for n, line in enumerate(open(f), 1):
        m = re.match(r"\s*ExecStart=-?(\S+)", line)
        if m and os.path.dirname(m.group(1)) != sbin:
            problems.append(f"{rel(f)}:{n}: ExecStart runs {m.group(1)}, not under CC_SBIN={sbin}")

# --- logrotate: every stanza must rotate a path the scripts write to ---------
for f in files("systemd/*logrotate*"):
    for n, line in enumerate(open(f), 1):
        m = re.match(r"\s*(/\S+)", line)
        if m and not m.group(1).startswith(logdir + "/"):
            problems.append(f"{rel(f)}:{n}: rotates {m.group(1)}, not under CC_LOGDIR={logdir}")

# --- sudoers: the group that may escalate, and the one command it may run -----
for f in files("aws/sudoers.d/*"):
    for n, line in enumerate(open(f), 1):
        if line.lstrip().startswith("#"):
            continue
        for g in re.findall(r"(?<![\w])%([\w.-]+)", line):
            if g != env["CC_ADMIN_GROUP"]:
                problems.append(f"{rel(f)}:{n}: grants %{g}, but CC_ADMIN_GROUP={env['CC_ADMIN_GROUP']}")
        for p in re.findall(r"/[\w./-]*/cc-[\w.-]+\.sh", line):
            if os.path.dirname(p) != sbin:
                problems.append(f"{rel(f)}:{n}: allows {p}, not under CC_SBIN={sbin}")

# --- policies: the paths and the address claude itself reads -----------------
for f in files("settings/managed-settings*.json"):
    try:
        d = json.load(open(f))
    except (OSError, ValueError) as e:
        problems.append(f"{rel(f)}: not readable JSON ({e}) - check [2] reports why")
        continue
    for ev, entries in (d.get("hooks") or {}).items():
        for e in entries:
            for h in e.get("hooks", []):
                for tok in re.findall(r"/[\w./-]+\.sh", h.get("command", "")):
                    if os.path.dirname(tok) != sbin:
                        problems.append(f"{rel(f)}: hooks.{ev} runs {tok}, not under CC_SBIN={sbin}")
    sl = (d.get("statusLine") or {}).get("command", "")
    if sl and env["CC_STATUSLINE"] not in sl.split():
        problems.append(f"{rel(f)}: statusLine runs '{sl}', not CC_STATUSLINE={env['CC_STATUSLINE']}")
    text = json.dumps(d)
    for tok in re.findall(r"/[\w./-]*/ENGINEER-GUIDE\.md", text):
        if os.path.dirname(tok) != share:
            problems.append(f"{rel(f)}: names the guide at {tok}, not under CC_SHARE={share}")
    for a in (d.get("companyAnnouncements") or []):
        for addr in re.findall(r"[\w.+-]+@[\w-]+(?:\.[\w-]+)+", a):
            if addr != env["CC_SUPPORT_CONTACT"]:
                problems.append(f"{rel(f)}: the banner names {addr}, but CC_SUPPORT_CONTACT={env['CC_SUPPORT_CONTACT']}")

# --- drift: a value the site moved, still spelled at the template's value -----
tmpl_path = os.path.join(root, "config.example.sh")
if os.path.isfile(tmpl_path):
    tmpl = dict(re.findall(r'^(CC_[A-Z_]+)="([^"]*)"', open(tmpl_path).read(), re.M))
    static = (files("settings/*.json") + files("systemd/*") + files("systemd/*/*")
              + files("aws/systemd/*") + files("aws/systemd/*/*")
              + files("aws/sudoers.d/*") + files("profile.d/*"))
    static = [f for f in static if os.path.isfile(f) and not f.endswith(".md")]
    for k, tv in sorted(tmpl.items()):
        sv = env.get(k, "")
        if not sv or sv == tv or not ("/" in tv or "@" in tv) or len(tv) < 4:
            continue
        for f in static:
            for n, line in enumerate(open(f, errors="replace"), 1):
                if re.search(re.escape(tv) + r"(?![\w.-])", line):
                    problems.append(f"{rel(f)}:{n}: still spells {k}'s template value {tv}; this site sets {sv}")

for p in problems:
    print(p)
sys.exit(1 if problems else 0)
