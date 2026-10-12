#!/usr/bin/env bash
# cc-drift.sh - what on this host differs from what was installed, and from the
# checkout it should follow.
#
# WHAT IT IS FOR. A host is meant to hold exactly what `cc-install.sh --apply`
# put there, and that is meant to be what the repository holds. Both drift: an
# administrator edits a file on one host to get something they want, a timer is
# disabled, or the repository moves on and the host is never re-applied. This
# says which, file by file, so a difference is seen and decided on - brought
# into the repository, or put back by the next apply - rather than found later.
#
#   cc-drift.sh                 compare the host with its install record, and
#                               the record with the checkout at CC_REPO
#   cc-drift.sh --repo DIR      the same, against another checkout
#   cc-drift.sh --host-only     the host with its install record alone
#   cc-drift.sh --json          the report as JSON on stdout
#   cc-drift.sh --out FILE      also write the JSON report to FILE, replaced whole
#
# WHAT IT COMPARES. Each complete apply writes $CC_ETC/install-record: the
# commit it came from and, for every file it placed, the file's SHA-256, its
# mode and the checkout path it came from; every directory with its mode and
# owner; every timer it enabled. Against that record:
#   the host  - each file is the same, edited, a different mode or owner,
#               missing, replaced by something that is not a plain file, or
#               unreadable; each directory the same, a different mode or owner,
#               missing or replaced; each timer enabled, not enabled, missing or
#               unknown.
#   the checkout - each file's source is the same as was installed, changed,
#               gone, unreadable, or not from the checkout at all (content the
#               installer writes itself, and a config.sh kept elsewhere).
# The commit installed and the checkout's commit are reported side by side.
#
# WHY IT ONLY READS. The root timer runs this, and the checkout is writable by
# a whole group: running the checkout's installer or its git as root would run
# whatever a member of that group put there. So nothing in the checkout is
# executed - its files are read as data and hashed, and its commit is read from
# .git's files, as cc-install.sh's src_commit does. `cc-install.sh --check` from
# the checkout remains the complete answer to "what would an apply change",
# including files the repository added since; this reports what is there now.
#
# WHAT IT DOES NOT SEE. A file the repository added since the last apply has no
# record, so it shows only as the two commits differing. A file put in a managed
# directory by hand is not looked for. Ownership is compared only when run as
# root, the only time it can be read for every file.
#
# EXIT CODES ARE THE INTERFACE:
#   0  no drift: every item on the host is as recorded and every source in the
#      checkout is unchanged.
#   1  drift: at least one item differs, on the host or in the checkout.
#   2  usage error.
#   3  CANNOT TELL: no config, no install record, a record written before it
#      held checksums, a malformed record, no checkout (without --host-only), or
#      an item that could not be read. Never collapsed into 0 or 1: an
#      unreadable host and a matching one must not produce the same answer.
#
# Site values (CC_ETC, CC_REPO) come from config.sh through the loader.
# Exercised by suite cases DR1-DR16.

set -uo pipefail

for _cfg in "${CC_CONFIG_LIB:-}" /etc/claude-code/cc-config.sh \
            "$(dirname "$(readlink -f "$0")")/../lib/cc-config.sh"; do
  [ -n "$_cfg" ] && [ -r "$_cfg" ] && { . "$_cfg" || exit 3; _cfg_loaded=1; break; }
done
[ "${_cfg_loaded:-0}" = 1 ] || { echo "cc-drift.sh: cannot find cc-config.sh (looked in /etc/claude-code/ and ../lib/)" >&2; exit 3; }
unset _cfg _cfg_loaded

usage() { echo "usage: cc-drift.sh [--repo DIR | --host-only] [--json] [--out FILE]" >&2; exit 2; }
REPO="$CC_REPO"; HOST_ONLY=0; JSON=0; OUT=""; REPO_GIVEN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --repo)      [ $# -ge 2 ] && [ -n "$2" ] || usage; REPO="$2"; REPO_GIVEN=1; shift 2 ;;
    --host-only) HOST_ONLY=1; shift ;;
    --json)      JSON=1; shift ;;
    --out)       [ $# -ge 2 ] && [ -n "$2" ] || usage; OUT="$2"; shift 2 ;;
    -h|--help)   sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)           echo "cc-drift.sh: unknown argument '$1'" >&2; usage ;;
  esac
done
[ "$HOST_ONLY" -eq 1 ] && [ "$REPO_GIVEN" -eq 1 ] && { echo "cc-drift.sh: --repo and --host-only contradict each other - pass one" >&2; exit 2; }
[ "$HOST_ONLY" -eq 1 ] && REPO=""

python3 -I - "$CC_ETC/install-record" "$REPO" "$JSON" "$OUT" <<'PY'
import grp, hashlib, json, os, pwd, re, stat, subprocess, sys, tempfile

RECORD, CHECKOUT, AS_JSON, OUT = sys.argv[1], sys.argv[2], sys.argv[3] == "1", sys.argv[4]
SHA = re.compile(r"[0-9a-f]{64}\Z")
MODE = re.compile(r"[0-7]{3,4}\Z")
TIMER = re.compile(r"[A-Za-z0-9@._-]+\.timer\Z")
# the states that are not drift, and the ones that leave the answer unknown
SAME = "same"
UNKNOWN_HOST = ("unreadable", "unknown")
UNKNOWN_REPO = ("unreadable",)
REPO_DRIFT = ("changed", "gone")
AS_ROOT = os.geteuid() == 0


class CannotTell(Exception):
    pass


def read_record(path):
    try:
        with open(path, encoding="utf-8") as fh:
            lines = fh.read().splitlines()
    except FileNotFoundError:
        raise CannotTell("no install record at %s: this host was never installed by cc-install.sh --apply" % path)
    except (OSError, UnicodeDecodeError) as e:
        raise CannotTell("cannot read the install record %s: %s" % (path, e))
    rec = {"commit": None, "applied": None, "files": [], "dirs": [], "timers": []}
    for n, line in enumerate(lines, 1):
        if not line or line.startswith("#"):
            continue
        key, eq, value = line.partition("=")
        if not eq:
            raise CannotTell("%s line %d is not key=value" % (path, n))
        bad = CannotTell("%s line %d is not a %s the installer writes" % (path, n, key))
        if key in ("commit", "applied"):
            rec[key] = value
        elif key == "sum":
            f = value.split("\t")
            if (len(f) != 4 or not SHA.match(f[0]) or not MODE.match(f[1]) or not os.path.isabs(f[3])
                    or not (f[2] == "-" or (not os.path.isabs(f[2]) and ".." not in f[2].split("/")))):
                raise bad
            rec["files"].append({"sha256": f[0], "mode": f[1], "source": f[2], "path": f[3]})
        elif key == "dir":
            f = value.split("\t")
            if len(f) != 3 or not MODE.match(f[0]) or f[1].count(":") != 1 or not os.path.isabs(f[2]):
                raise bad
            rec["dirs"].append({"mode": f[0], "owner": f[1], "path": f[2]})
        elif key == "timer":
            if not TIMER.match(value):
                raise bad
            rec["timers"].append(value)
    if not rec["files"]:
        raise CannotTell("the install record %s holds no checksums: it was written before cc-install.sh "
                         "recorded them - re-apply once (cc-install.sh --apply) and run this again" % path)
    return rec


def opened(path):
    """(state, sha256, stat) of a plain file, read without following a link."""
    try:
        before = os.lstat(path)
    except FileNotFoundError:
        return "missing", None, None
    except OSError:
        return "unreadable", None, None
    if not stat.S_ISREG(before.st_mode):
        return "replaced", None, before
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except OSError:
        return "unreadable", None, before
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode) or (st.st_dev, st.st_ino) != (before.st_dev, before.st_ino):
            return "unreadable", None, before
        h = hashlib.sha256()
        with os.fdopen(fd, "rb") as fh:
            fd = None
            for chunk in iter(lambda: fh.read(1 << 20), b""):
                h.update(chunk)
        return "read", h.hexdigest(), st
    except OSError:
        return "unreadable", None, before
    finally:
        if fd is not None:
            os.close(fd)


def owner(st):
    try:
        user = pwd.getpwuid(st.st_uid).pw_name
    except KeyError:
        user = str(st.st_uid)
    try:
        group = grp.getgrgid(st.st_gid).gr_name
    except KeyError:
        group = str(st.st_gid)
    return user + ":" + group


def file_on_host(f):
    state, sha, st = opened(f["path"])
    if state != "read":
        return state
    if sha != f["sha256"]:
        return "edited"
    if AS_ROOT and owner(st) != "root:root":
        return "owner"
    return SAME if stat.S_IMODE(st.st_mode) == int(f["mode"], 8) else "mode"


def file_in_checkout(f):
    if not CHECKOUT:
        return "not compared"
    if f["source"] == "-":
        return "not from the checkout"
    state, sha, _st = opened(os.path.join(CHECKOUT, f["source"]))
    if state in ("missing", "replaced"):
        return "gone"
    if state != "read":
        return "unreadable"
    return SAME if sha == f["sha256"] else "changed"


def dir_on_host(d):
    try:
        st = os.lstat(d["path"])
    except FileNotFoundError:
        return "missing"
    except OSError:
        return "unreadable"
    if not stat.S_ISDIR(st.st_mode):
        return "replaced"
    if AS_ROOT and owner(st) != d["owner"]:
        return "owner"
    return SAME if stat.S_IMODE(st.st_mode) == int(d["mode"], 8) else "mode"


def timer_on_host(name):
    try:
        p = subprocess.run(["systemctl", "show", "-p", "LoadState", "-p", "UnitFileState", name],
                           stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=30)
    except (OSError, subprocess.SubprocessError):
        return "unknown"
    if p.returncode != 0:
        return "unknown"
    props = dict(line.partition("=")[::2] for line in p.stdout.decode("utf-8", "replace").splitlines())
    if props.get("LoadState") == "not-found":
        return "missing"
    if props.get("LoadState") != "loaded" or "UnitFileState" not in props:
        return "unknown"
    return SAME if props["UnitFileState"] == "enabled" else "not enabled"


def commit_of(tree):
    """The commit a checkout is at, read from .git's files as cc-install.sh's
    src_commit reads it; None when it cannot be told."""
    git = os.path.join(tree, ".git")
    try:
        with open(os.path.join(git, "HEAD")) as fh:
            head = fh.read(200).strip()
        if head.startswith("ref: "):
            ref = head[5:]
            if ".." in ref or ref.startswith("/"):
                return None
            try:
                with open(os.path.join(git, ref)) as fh:
                    c = fh.read(64).strip()
            except FileNotFoundError:
                c = None
                with open(os.path.join(git, "packed-refs")) as fh:
                    for line in fh:
                        f = line.split()
                        if len(f) == 2 and f[1] == ref:
                            c = f[0]
                            break
        else:
            c = head
    except (OSError, UnicodeDecodeError):
        return None
    return c if c and re.match(r"[0-9a-f]{7,64}\Z", c) else None


def report():
    rec = read_record(RECORD)
    if CHECKOUT and not os.path.isdir(CHECKOUT):
        raise CannotTell("no checkout at %s to compare against - name one with --repo, or pass --host-only" % CHECKOUT)
    items = [{"kind": "file", "path": f["path"], "source": f["source"],
              "host": file_on_host(f), "repo": file_in_checkout(f)} for f in rec["files"]]
    items += [{"kind": "directory", "path": d["path"], "source": None, "host": dir_on_host(d), "repo": None}
              for d in rec["dirs"]]
    items += [{"kind": "timer", "path": t, "source": None, "host": timer_on_host(t), "repo": None}
              for t in rec["timers"]]
    unknown = [i for i in items if i["host"] in UNKNOWN_HOST or i["repo"] in UNKNOWN_REPO]
    host = [i for i in items if i["host"] != SAME and i["host"] not in UNKNOWN_HOST]
    repo = [i for i in items if i["repo"] in REPO_DRIFT]
    verdict = "unknown" if unknown else "drift" if host or repo else "none"
    return {"verdict": verdict, "record": RECORD, "installed_commit": rec["commit"], "applied": rec["applied"],
            "checkout": CHECKOUT or None, "checkout_commit": commit_of(CHECKOUT) if CHECKOUT else None,
            "owner_checked": AS_ROOT,
            "counts": {"files": len(rec["files"]), "directories": len(rec["dirs"]), "timers": len(rec["timers"]),
                       "host_differs": len(host), "checkout_differs": len(repo), "unknown": len(unknown)},
            "items": items}


def text(r):
    short = lambda c: c[:12] if c else "unknown"
    c = r["counts"]
    out = ["Drift: %s. Installed from commit %s at %s." % (r["verdict"], short(r["installed_commit"]), r["applied"] or "an unrecorded time")]
    if r["checkout"]:
        out.append("Checkout %s is at commit %s." % (r["checkout"], short(r["checkout_commit"])))
    else:
        out.append("The checkout was not compared (--host-only).")
    out.append("Compared %d files, %d directories and %d timers%s." % (
        c["files"], c["directories"], c["timers"], "" if r["owner_checked"] else "; owners not compared (not root)"))
    for i in r["items"]:
        if i["host"] != SAME:
            out.append("  on the host   %-22s %s" % (i["host"], i["path"]))
        if i["repo"] in REPO_DRIFT + UNKNOWN_REPO:
            out.append("  in checkout   %-22s %s (from %s)" % (i["repo"], i["path"], i["source"]))
    return "\n".join(out)


def write_out(path, body):
    d = os.path.dirname(os.path.abspath(path))
    fd, tmp = tempfile.mkstemp(prefix=".cc-drift.", dir=d)
    try:
        with os.fdopen(fd, "w") as fh:
            fh.write(body)
        os.chmod(tmp, 0o644)
        os.replace(tmp, path)
    except BaseException:
        os.unlink(tmp)
        raise


try:
    r = report()
except CannotTell as e:
    print("cc-drift.sh: cannot tell: %s" % e, file=sys.stderr)
    sys.exit(3)
except Exception:
    # an uncaught error would exit 1, which reads as drift found
    import traceback
    traceback.print_exc()
    sys.exit(3)
body = json.dumps(r, indent=1, sort_keys=True) + "\n"
if OUT:
    try:
        write_out(OUT, body)
    except OSError as e:
        print("cc-drift.sh: cannot write the report to %s: %s" % (OUT, e), file=sys.stderr)
        sys.exit(3)
print(body if AS_JSON else text(r), end="" if AS_JSON else "\n")
sys.exit({"none": 0, "drift": 1, "unknown": 3}[r["verdict"]])
PY
