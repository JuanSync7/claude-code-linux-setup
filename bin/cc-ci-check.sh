#!/usr/bin/env bash
# cc-ci-check.sh — the repository's content checks, for CI and for hand-running.
#
# What it checks is what a REMOTE can verify: file content and the one
# permission bit git records (owner-execute). What it cannot check is
# filesystem modes on a shared checkout (group ownership, setgid,
# internal/'s 2770) — those do not exist in git; githooks/post-merge and
# bin/cc-repo-perms.sh own that job, per checkout, forever.
#
# Runs unprivileged, from any clone. Needs: git, bash, python3, make, cmp.
# Both CI configs (.github/workflows/ci.yml, .gitlab-ci.yml) run these checks
# by calling this script, so the checks cannot drift between platforms. The
# test suites are separate gating jobs in the same configs.
#
# CC_CI_ONLY="10" (or "2,9") runs just the named checks — for the test suite,
# which exercises single checks against scratch repos, and for iterating on
# one check by hand. A partial run says so in its summary and exits 0 only on
# the SELECTED checks — it is never a full pass, and CI must leave it unset.
# An id that names no existing check is a usage error (exit 2), so a typo can
# never silently run zero checks and report success.
#
# A check whose embedded Python exits non-zero has checked nothing, so it
# fails: the findings are printed, the exit status says only "it ran".
#
# Exit: 0 all (selected) checks passed, 1 a check failed, 2 usage.

set -uo pipefail

# Where this script's siblings are, resolved before the cd below so that a
# relative invocation still finds them. It is not always the tree under check:
# the suite points this script at scratch repositories.
BIN_DIR=$(cd "$(dirname "$0")" && pwd) || { echo "cc-ci-check: cannot resolve this script's own directory" >&2; exit 2; }
cd "$(git rev-parse --show-toplevel)" || exit 1

# The valid ids are read from the `if want N` blocks below, so adding a check
# cannot leave this list behind.
if [ -n "${CC_CI_ONLY:-}" ]; then
  IDS=$(sed -n 's/^if want \([0-9][0-9]*\); then$/\1/p' "$0" | tr '\n' ' ')
  for id in $(printf '%s' "$CC_CI_ONLY" | tr ',' ' '); do
    case " $IDS" in
      *" $id "*) ;;
      *) printf 'cc-ci-check: CC_CI_ONLY names no such check: %s (valid: %s)\n' "$id" "${IDS% }" >&2; exit 2 ;;
    esac
  done
fi

FAILURES=0
say()  { printf '%s\n' "$*"; }
ok()   { printf '  ok     %s\n' "$*"; }
bad()  { printf '  FAIL   %s\n' "$*" >&2; FAILURES=$((FAILURES + 1)); }
want() { [ -z "${CC_CI_ONLY:-}" ] || case ",$CC_CI_ONLY," in *,"$1",*) ;; *) return 1 ;; esac; }

# ---- [1] secret guard, whole tree -------------------------------------------
# The pre-commit guard is client-side and opt-in (cc-repo-setup.sh); a clone
# that skipped setup has no guard at all. This re-runs the identical checks
# over every tracked file, so the remote catches what a guardless commit let in.
if want 1; then
say "[1] Secret guard over every tracked file"
if CC_SCAN_ALL=1 bash githooks/pre-commit; then
  ok "no credential-shaped content, transcripts, or oversize files"
else
  bad "the secret guard blocked tracked content - see lines above"
fi
fi

# ---- [2] every tracked JSON parses; the policy carries no placeholders ------
if want 2; then
say "[2] JSON validity and policy placeholders"
while IFS= read -r f; do
  python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$f" 2>/dev/null \
    || bad "$f is not valid JSON"
done < <(git ls-files '*.json')
# Same markers cc-install.sh gate [2] and cc-audit.sh look for — and the same
# comment-stripping first: _comment_* keys legitimately DISCUSS the markers
# (match values, not vocabulary), so scan the effective policy only.
# A template edition (docs/PUBLISHING.md) carries template.json, whose
# "placeholders" keys are the REPLACE-WITH-* names a site fills. Those, and
# only those, pass here; the installer still refuses them. The list is closed
# both ways: a listed name no tracked file uses is a stale entry, and an empty
# list is a template of nothing.
TEMPLATE_PH=""
if git ls-files --error-unmatch template.json >/dev/null 2>&1; then
  # cc-template-fill.sh is the one reader of template.json: it refuses a list
  # that is unreadable, empty, or names anything but a whole placeholder.
  TEMPLATE_PH=$(bash "$BIN_DIR/cc-template-fill.sh" --list) \
    || bad "template.json is not a usable placeholder list (reason above) - correct it, or delete it if this is no longer a template"
  for ph in $TEMPLATE_PH; do
    git grep -qF "$ph" -- . ':!template.json' ':!TEMPLATE.md' ':!publish/overlay/' \
      || bad "template.json lists $ph, which no tracked file uses"
  done
fi
if git ls-files 'settings/*.json' | TEMPLATE_PH="$TEMPLATE_PH" python3 -c '
import json, os, string, sys
MARKERS = ("REPLACE-WITH", "REPLACE_WITH", "TODO", "FIXME", "CHANGEME")
LISTED = set(os.environ["TEMPLATE_PH"].split())
# A placeholder is read whole - REPLACE-WITH and every capital, digit and
# hyphen that follows - and removed only when that whole name is listed. So a
# listed name never excuses a longer, unlisted one that begins with it. A
# hyphen that ends the run belongs to the surrounding text, not the name.
NAME_CHARS = set(string.ascii_uppercase + string.digits + "-")
def without_listed(text):
    kept, at = [], 0
    while True:
        start = text.find("REPLACE-WITH", at)
        if start < 0:
            return "".join(kept) + text[at:]
        end = start
        while end < len(text) and text[end] in NAME_CHARS:
            end += 1
        name = text[start:end].rstrip("-")
        kept.append(text[at:start])
        if name in LISTED:
            at = start + len(name)
        else:
            kept.append(text[start:end])
            at = end
def strip(o):
    if isinstance(o, dict):
        return {k: strip(v) for k, v in o.items() if not k.startswith("_comment")}
    return [strip(v) for v in o] if isinstance(o, list) else o
bad = 0
for f in (l.strip() for l in sys.stdin):
    text = json.dumps(strip(json.load(open(f))))
    # What is left after the listed names are taken out is judged as in a site
    # edition: an unlisted placeholder still carries its REPLACE-WITH marker.
    text = without_listed(text)
    for m in MARKERS:
        if m in text:
            print(f"  FAIL   {f}: effective policy contains {m}" + (" outside the names template.json lists" if LISTED else "")); bad = 1
sys.exit(bad)'; then
  ok "all tracked JSON parses; no placeholder markers in the effective policy"
else
  bad "placeholder markers in a shipped policy - a governed-looking host that enforces nothing"
fi
fi

# ---- [3] executable bits are in the INDEX, not just on disk ----------------
# In a clone with core.fileMode=false, chmod alone never reaches
# git: a fresh clone gets 644 scripts and the README's own first command dies
# with "Permission denied". The fix is `git update-index --chmod=+x <file>`.
if want 3; then
say "[3] Executable bits recorded in git"
PRE3=$FAILURES
while read -r mode _ _ f; do
  case "$f" in
    *.md) ;; # directory maps and docs - data, never executed
    lib/*|config.example.sh) # sourced, never executed - 644 is correct
      [ "$mode" = 100755 ] && bad "$f is executable in the index but is sourced, not run" ;;
    # Any *.sh inside a bin/ hooks/ share/ tests/ directory, at ANY depth (the
    # top-level share/ included - */share/ alone needs a parent), plus
    # githooks/ by directory (git needs exact names like `pre-commit`). Nested
    # directories are covered for aws/bin/cc-apply-posture.sh: were git to
    # record it 100644, a fresh clone would get a boot-time policy selector it
    # cannot execute, on a host whose logins are gated on that unit.
    */bin/*.sh|*/hooks/*.sh|*/share/*.sh|*/tests/*.sh|share/*.sh|bin/*|githooks/*|hooks/*|tests/*)
      [ "$mode" = 100755 ] || bad "$f is $mode in the index - a fresh clone cannot execute it (git update-index --chmod=+x '$f')" ;;
  esac
done < <(git ls-files -s)
[ "$FAILURES" -eq "$PRE3" ] && ok "every script a clone must run is 100755"
fi

# ---- [4] shell syntax --------------------------------------------------------
if want 4; then
say "[4] bash -n on every tracked shell script"
SYNTAX_BAD=0
while IFS= read -r f; do
  bash -n "$f" 2>/dev/null || { bad "$f fails bash -n"; SYNTAX_BAD=1; }
done < <(git ls-files '*.sh' 'bin/*' 'githooks/*' 'hooks/*' 'tests/*' | sort -u | grep -v '\.md$')
[ "$SYNTAX_BAD" -eq 0 ] && ok "all scripts parse"
fi

# ---- [5] markdown links resolve ----------------------------------------------
# internal/archive/ is exempt: frozen records may cite a tree that no longer
# exists, and rewriting them to fix links would falsify the record.
if want 5; then
say "[5] Relative links in tracked markdown"
# A doc that is not UTF-8 is read with replacement characters, so one bad
# byte cannot end the scan before the docs after it.
LINKS_OUT=$(git ls-files '*.md' | grep -v '^internal/archive/' | python3 -c '
import os, re, sys
for doc in (l.strip() for l in sys.stdin):
    base = os.path.dirname(doc)
    for t in re.findall(r"\]\(([^)#\s]+)", open(doc, encoding="utf-8", errors="replace").read()):
        if t.startswith(("http://", "https://", "mailto:")): continue
        if not os.path.exists(os.path.join(base, t)):
            print(f"  FAIL   {doc}: broken link -> {t}")'); RC5=$?
if [ "$RC5" -ne 0 ]; then
  bad "the link scan exited $RC5 - no link was checked"
elif [ -n "$LINKS_OUT" ]; then printf '%s\n' "$LINKS_OUT" >&2; FAILURES=$((FAILURES + 1)); else ok "every relative link lands on a real file"; fi
fi

# ---- [6] the deployment stages end-to-end ------------------------------------
# DESTDIR staging runs quickstart's guards (the config loads, command-line
# paths equal config.sh, the static files agree with it) with no root and no
# live host, on the template - the one config every clone has -
# then this asserts the staged manifest is complete. This is the check that
# catches a policy/hook/Makefile disagreement before it reaches a host.
# A template edition cannot stage as it stands - that refusal is the point -
# so there [6] proves both halves by difference, not by reading the refusal:
# the unfilled tree must be refused, and the copy bin/cc-template-fill.sh
# writes, which differs from it only by every listed placeholder filled, must
# stage whole. Together they show the placeholders, and nothing else, are what
# the installer refused.
if want 6; then
say "[6] make quickstart DESTDIR staging"
STAGE=$(mktemp -d)
FILLED=""
trap 'rm -rf "$STAGE" ${FILLED:+"$FILLED"}' EXIT
ROOT6=.
if git ls-files --error-unmatch template.json >/dev/null 2>&1; then
  if make quickstart DESTDIR="$STAGE" CONFIG=config.example.sh >/dev/null 2>&1; then
    bad "the unfilled template staged - the installer would place a policy with placeholders"
  else
    ok "the installer refuses the unfilled template (the filled copy below must stage)"
  fi
  rm -rf "$STAGE"; STAGE=$(mktemp -d); FILLED=$(mktemp -d)
  if bash bin/cc-template-fill.sh "$FILLED" >/dev/null 2>&1; then
    ROOT6=$FILLED
  else
    bad "bin/cc-template-fill.sh could not write a filled copy - run it by hand for the reason"
  fi
fi
if make -C "$ROOT6" quickstart DESTDIR="$STAGE" CONFIG=config.example.sh >/dev/null 2>&1; then
  MISSING=0
  # The paths come from the config the Makefile itself loaded, and the hook
  # list from the Makefile's own HOOKS variable - no copy of either here, so a
  # value changed in config.sh or a hook added there is followed automatically.
  # shellcheck disable=SC1091
  EXPECT=$(cd "$ROOT6" && env -i PATH="$PATH" CC_CONFIG=config.example.sh bash -c '. lib/cc-config.sh >/dev/null 2>&1 || exit 1
    printf "%s\n" "$CC_POLICY" "$CC_STATUSLINE" "$CC_ACTIVITY_LOG_DIR" "$CC_DENIED_LOG_DIR" \
      "$CC_ETC/cc-config.sh" "$CC_ETC/config.sh"
    for h in $(sed -n "s/^HOOKS *:*= *//p" Makefile); do printf "%s\n" "$CC_SBIN/${h##*/}"; done' | sed 's|^/||')
  [ -n "$EXPECT" ] || bad "lib/cc-config.sh did not load - the staged manifest cannot be named"
  while IFS= read -r p; do
    [ -e "$STAGE/$p" ] || { bad "staged tree is missing $p"; MISSING=1; }
  done <<< "$EXPECT"
  [ "$MISSING" -eq 0 ] && ok "guards passed and the staged tree holds the full manifest (hooks read from the Makefile)"
  # Whether every hook list names the same set is check [13] - it needs no staging.
else
  # The commonest cause on a minimal image is named, because the staging run's
  # own message is not shown here.
  command -v cmp >/dev/null 2>&1 \
    || bad "cmp is not installed (package diffutils), and the installer refuses to run without it"
  bad "make quickstart DESTDIR=... failed - run it by hand for the refusal message"
fi
fi

# ---- [7] the loader's key lists and the template agree, both ways ----------
# lib/cc-config.sh has no defaults: it names the keys a config must set, and
# config.example.sh is the one place their suggested values live. A key the
# loader requires but the template lacks is a key no site can discover; a key
# in the template the loader does not know is a value nothing validates. And
# the template itself must load - it is what a fresh clone and the suite run on.
if want 7; then
say "[7] config.example.sh and the loader's key lists agree"
PRE7=$FAILURES
KEYS7=$(bash -c '. lib/cc-config.sh >/dev/null 2>&1; printf "%s %s CC_ADMIN_USERS" "$CC_REQUIRED_KEYS" "$CC_OPTIONAL_KEYS"' | tr -s ' \n' '\n' | sort -u)
TMPL7=$(grep -oE '^CC_[A-Z_]+=' config.example.sh | tr -d = | sort -u)
[ -n "$KEYS7" ] || bad "lib/cc-config.sh names no keys - the loader could not be read"
for k in $(comm -23 <(printf '%s\n' "$KEYS7") <(printf '%s\n' "$TMPL7")); do
  bad "$k is required by lib/cc-config.sh but has no line in config.example.sh"
done
for k in $(comm -13 <(printf '%s\n' "$KEYS7") <(printf '%s\n' "$TMPL7")); do
  bad "$k is set in config.example.sh but lib/cc-config.sh does not list it"
done
grep -qE '^\s*: "\$\{CC_[A-Z_]+:=' lib/cc-config.sh \
  && bad "lib/cc-config.sh spells a default (: \"\${CC_X:=...}\") - defaults live only in config.example.sh"
ERR7=$(env -i PATH="$PATH" CC_CONFIG=config.example.sh bash -c '. lib/cc-config.sh' 2>&1) \
  || bad "config.example.sh does not load: $ERR7"
# The key table in docs/QUICKSTART.md 9 is the readable reference: one row per
# key, and a value it shows must be the template's, or the reference lies.
OUT7=$(python3 - "$KEYS7" <<'PY'
import os, re, sys
keys = set(sys.argv[1].split())
if not os.path.isfile("docs/QUICKSTART.md"):
    print("docs/QUICKSTART.md is missing - the key reference cannot be checked"); sys.exit(0)
tmpl = dict(re.findall(r'^(CC_[A-Z_]+)="([^"]*)"', open("config.example.sh").read(), re.M))
rows = {}
for line in open("docs/QUICKSTART.md"):
    m = re.match(r"\|\s*`(CC_[A-Z_]+)`\s*\|.*\|\s*(.*?)\s*\|\s*$", line)
    if m:
        if m.group(1) in rows:
            print(m.group(1) + " has two rows")
        rows[m.group(1)] = m.group(2)
for k in sorted(keys - set(rows)):
    print(k + " has no row")
for k in sorted(set(rows) - keys):
    print(k + " has a row but the loader does not list it")
for k, v in sorted(rows.items()):
    lit = re.fullmatch(r"`([^`]*)`", v)
    if lit and k in tmpl and lit.group(1) != tmpl[k]:
        print(k + " shows " + lit.group(1) + " but the template sets " + tmpl[k])
    if v == "*(empty)*" and tmpl.get(k, "x") != "":
        print(k + " shows empty but the template sets a value")
PY
); RC7=$?
[ "$RC7" -eq 0 ] || bad "the QUICKSTART key-table check exited $RC7 - the table was not checked"
while IFS= read -r m; do [ -n "$m" ] && bad "docs/QUICKSTART.md key table: $m"; done <<< "$OUT7"
[ "$FAILURES" -eq "$PRE7" ] && ok "every key is listed once, set in the template, the template loads, and the QUICKSTART key table matches"
fi

# ---- [8] every code and config file is mentioned in the documentation -------
# Name-mention is a floor, not proof of documentation - but a file no doc even
# names is invisible to every reader, and that is catchable mechanically.
# internal/ is the site record, not shipped machinery, so it is out of scope.
# The name must stand alone: cc-x.sh inside acc-x.sh or cc-x.sh.old is a
# different file, so it is not a mention. A path prefix or a full stop is.
if want 8; then
say "[8] Every tracked code/config file appears in the docs"
PRE8=$FAILURES
while IFS= read -r f; do
  # The dashboard documents itself: its files are named in their own
  # directory's map. Everything else must still be named in the shipped docs.
  homes=(docs/ README.md)
  case "$f" in dashboard/*) homes=("$(dirname "$f")/README.md") ;; esac
  grep -rqlP "(?<![\w.-])\Q$(basename "$f")\E(?![\w-]|\.\w)" "${homes[@]}" 2>/dev/null \
    || bad "$f is named in no document - add it to its home (host scripts: RUNBOOK \$12; repo tooling: README)"
done < <(git ls-files | grep -vE '\.md$|^internal/')
[ "$FAILURES" -eq "$PRE8" ] && ok "no invisible files"
fi

# ---- [9] the pinned version has a docs/UPGRADES.md entry ---------------------
# A version bump is a recorded transition, not just a number: vendor changes,
# the settings-surface delta, our response, the probe results. This check makes
# the record impossible to skip - requiredMinimumVersion cannot move without
# docs/UPGRADES.md gaining the matching "## <version>" entry in the same push.
# The entry contract lives at the top of UPGRADES.md; the procedure that
# produces an entry is OPERATIONS.md Part 7.
if want 9; then
say "[9] The pinned version has a docs/UPGRADES.md entry"
# Every policy is read - the admin policy carries the same floor, and a pin
# moved or dropped in either one is a transition. No pin is not "nothing to
# anchor": the floor is a control, and removing it is the bump to record.
OUT9=$(python3 - <<'PY'
import glob, json
fleet = "settings/managed-settings.json"
pols = sorted(set(glob.glob("settings/managed-settings*.json")) | {fleet})
pins = {}
for f in pols:
    try:
        v = json.load(open(f)).get("requiredMinimumVersion")
    except (OSError, ValueError) as e:
        print(f"BAD {f} could not be read ({e}) - its pin cannot be checked"); continue
    if not v:
        print(f"BAD {f} has no requiredMinimumVersion - the version floor is a control, and removing it is a transition too")
        continue
    pins[f] = v
fp = pins.get(fleet)
for f, v in sorted(pins.items()):
    if fp and v != fp:
        print(f"BAD {f} pins {v} but {fleet} pins {fp} - both policies move together (docs/REPO-MAP.md)")
if fp:
    print("PIN " + fp)
PY
); RC9=$?
REQ=$(printf '%s\n' "$OUT9" | sed -n 's/^PIN //p')
while IFS= read -r m; do bad "$m"; done < <(printf '%s\n' "$OUT9" | sed -n 's/^BAD //p')
if [ "$RC9" -ne 0 ]; then
  bad "the pin check exited $RC9 - no policy was read"
elif [ -z "$REQ" ]; then
  : # reported above
elif [ ! -f docs/UPGRADES.md ]; then
  bad "policy pins $REQ but docs/UPGRADES.md does not exist - every pin needs its recorded transition"
elif grep -qE "^## ${REQ//./\\.}\b" docs/UPGRADES.md; then
  ok "docs/UPGRADES.md has an entry for the pinned $REQ"
else
  bad "docs/UPGRADES.md has no entry for $REQ - record the transition (entry contract at the top of that file)"
fi
fi

# ---- [10] every executable script is tested, or its absence is recorded ------
# The suite is the only thing standing between a silent regression and a fleet,
# so a script arriving with no cases must not arrive quietly. This runs
# tests/test-cc-scripts.sh --coverage, which maps every executable shell script
# to the cases that exercise it - derived from the suite's own head2 markers and
# assertion call sites, not from a hand-written table, because a hand-written
# table is what drifted in cc-report.sh --list-rules.
#
# It does NOT demand universal coverage. It demands that every uncovered script
# be named in the suite's ACKNOWLEDGED_UNTESTED list with a reason, so that
# "nobody has tested this" and "we decided not to and here is why" stop looking
# the same. Static analysis only: it runs no test, touches no host state, and is
# therefore safe wherever the suite itself cannot run. Being
# static, it credits a case that never executes; the suite's own COV verdict,
# at the end of a full run, is the one that counts only cases that ran.
if want 10; then
say "[10] Every executable script is tested, or its absence is recorded"
if [ ! -x tests/test-cc-scripts.sh ]; then
  bad "tests/test-cc-scripts.sh is missing or not executable - coverage cannot be established"
else
  COV_OUT=$(bash tests/test-cc-scripts.sh --coverage 2>&1); COV_RC=$?
  if [ "$COV_RC" -eq 0 ]; then
    ok "$(printf '%s' "$COV_OUT" | sed -n 's/^\([0-9]*\) script(s) examined.*/\1/p') script(s) mapped to cases; every untested one has a recorded reason"
  else
    printf '%s\n' "$COV_OUT" | grep -E '\*\*' | sed 's/^/       /'
    bad "a script has no cases and no recorded reason - add cases, or an ACKNOWLEDGED_UNTESTED entry saying why not"
  fi
fi
fi

# ---- [11] no site value is spelled in code -----------------------------------
# Every site value comes from config.sh through lib/cc-config.sh; that is the
# rule check [7] holds for the key lists, and this one holds for the code. Two
# shapes are caught, in every tracked script, hook, Makefile and workflow:
#   * a default on a config key  - ${CC_PKG:-claude-code}, ${CC_LOGDIR:=...}.
#     The loader refuses a config without the key, so a default can only ever
#     disagree with it.
#   * a value from config.example.sh spelled literally. Values with a / or @
#     (paths, URLs, addresses) match anywhere; short words match as a whole
#     token only, and numbers are not matched at all.
# Comments are not scanned: docs and comments may state a value as a reference.
# In docs, only a `sudo` line inside a code block is held to the rule - that is
# an operator command, which must work at any site.
# The exceptions are FACTS, not site values, and each carries its reason. Add
# one only with a reason a reviewer would accept; the list is the audit trail.
if want 11; then
say "[11] No config value is spelled in code"
HC11=$(bash -c '. lib/cc-config.sh >/dev/null 2>&1; printf "%s %s\n" "$CC_REQUIRED_KEYS" "$CC_OPTIONAL_KEYS"' | python3 -c '
import re, subprocess, sys
keys = set(sys.stdin.read().split()) | {"CC_POLICY", "CC_POLICY_SHA", "CC_ADMIN_POLICY",
    "CC_ADMIN_LOG", "CC_ACTIVITY_LOG_DIR", "CC_DENIED_LOG_DIR", "CC_STATUSLINE", "CC_LOGROTATE_FILE"}
if len(keys) < 10:
    print("lib/cc-config.sh: the key lists could not be read - nothing would be checked"); sys.exit(0)
# (file, text on the line, why it is a fact and not a site value)
ALLOW = [
    ("*", "/etc/claude-code/cc-config.sh",
     "where the loader is installed: it is how a script FINDS config, so it cannot come from config"),
    ("*", "looked in /etc/claude-code/",
     "the error message for the same lookup"),
    ("lib/cc-config.sh", "/etc/claude-code/config.sh",
     "the loader finding the installed config - same reason"),
    ("Makefile", "/etc/claude-code",
     "ETC is pinned on purpose: the claude binary has /etc/claude-code compiled in, so it is not a choice"),
    ("bin/cc-bump-audit.sh", "/etc/claude-code",
     "probe A1 asks whether the BINARY still has this path compiled in - the vendor fact under test"),
    ("hooks/cc-upgrade-guard-hook.sh", "claude-code",
     "the signpost matches vendor command shapes (package, npm name, installer URL); it reads no config so it never slows a Bash call"),
]
tmpl = open("config.example.sh").read()
vals = {m.group(1): m.group(2) for m in re.finditer(r"^(CC_[A-Z_]+)=\"([^\"]*)\"", tmpl, re.M)}
for m in re.finditer(r"^(CC_[A-Z_]+)=\(([^)]*)\)", tmpl, re.M):
    for v in re.findall(r"\"([^\"]+)\"", m.group(2)):
        vals.setdefault(m.group(1), v)
files = subprocess.run(["git", "ls-files", "bin/*.sh", "hooks/*.sh", "share/*.sh", "aws/bin/*",
    "githooks/*", "lib/*.sh", "profile.d/*.sh", "Makefile", ".github/workflows/*.yml", ".gitlab-ci.yml"],
    stdout=subprocess.PIPE, universal_newlines=True).stdout.split()
import fnmatch
def allowed(f, line):
    return any(fnmatch.fnmatch(f, g) and t in line for g, t, _ in ALLOW)
for f in files:
    if f.endswith(".md"): continue
    try: lines = open(f, errors="replace").read().splitlines()
    except OSError: continue
    in_allow = False
    for n, line in enumerate(lines, 1):
        # the exception list below names the values it excuses, by design
        if f == "bin/cc-ci-check.sh" and line.startswith("ALLOW = ["): in_allow = True
        if in_allow:
            in_allow = line.strip() != "]"; continue
        if not line.strip() or line.strip().startswith("#"): continue
        for m in re.finditer(r"\$\{(CC_[A-Z_]+):?[-=]([^}]+)\}", line):
            if m.group(1) in keys:
                print(f"{f}:{n}: {m.group(1)} is given a default ({m.group(2)}) - the config sets it; read it")
        if allowed(f, line): continue
        for k, v in vals.items():
            if len(v) < 4 or v.isdigit(): continue
            if "/" in v or "@" in v:
                hit = v in line
            else:
                hit = re.search(r"(?<![\w./@-])" + re.escape(v) + r"(?![\w./-])", line)
            if hit:
                print(f"{f}:{n}: spells {k}=\"{v}\" - read $" + k)
# Docs may state a value as a reference, but a command an operator runs with
# sudo must use the key, or it is wrong at any site that moved the value.
docs = subprocess.run(["git", "ls-files", "*.md"], stdout=subprocess.PIPE,
    universal_newlines=True).stdout.split()
for f in docs:
    if f.startswith("internal/"): continue
    fence = False
    for n, line in enumerate(open(f, errors="replace"), 1):
        if line.lstrip().startswith("```"): fence = not fence; continue
        if not (fence and line.lstrip().startswith("sudo ")) or allowed(f, line): continue
        for k, v in vals.items():
            if ("/" in v or "@" in v) and len(v) >= 4 and re.search(re.escape(v) + r"(?![\w.-])", line):
                print(f"{f}:{n}: a sudo command spells {k}=\"{v}\" - write $" + k + " (QUICKSTART.md 9)")
'); RC11=$?
if [ "$RC11" -ne 0 ]; then
  bad "the site-value scan exited $RC11 - no file was checked"
elif [ -n "$HC11" ]; then
  printf '%s\n' "$HC11" | while IFS= read -r l; do bad "$l"; done
  FAILURES=$((FAILURES + $(printf '%s\n' "$HC11" | wc -l)))
else
  ok "every site value in code is read from config"
fi
fi

# ---- [12] the static files agree with config ---------------------------------
# The policies, units, logrotate stanza and sudoers drop-in are read by claude,
# systemd, logrotate and sudo - none of which sources config.sh - so they spell
# their paths and the support address literally. lib/cc-coupling.py holds each
# to the config: here against the template, at install time (cc-install.sh
# gate 4c, make quickstart) against the site's own config.sh, where it also
# catches a value the site moved but a static file did not.
if want 12; then
say "[12] The static files agree with config"
CPL12=$(env -i PATH="$PATH" CC_CONFIG=config.example.sh bash -c '. lib/cc-config.sh && export ${!CC_@} && python3 lib/cc-coupling.py .' 2>&1); RC12=$?
if [ "$RC12" -eq 0 ]; then
  ok "units, logrotate, sudoers and both policies name the paths and contact config.example.sh sets"
else
  printf '%s\n' "$CPL12" | while IFS= read -r l; do printf '  FAIL   %s\n' "$l" >&2; done
  bad "a static file disagrees with config (lib/cc-coupling.py, exit $RC12)"
fi
fi

# ---- [13] every list of hooks names the same set ------------------------------
# The Makefile's HOOKS is what quickstart installs. Five other lists must agree
# with it: each policy's hooks[] (a hook installed but not registered never
# runs; one registered but not installed fails open with a transcript warning),
# the installer's source gate and placement list, and the healthcheck's
# presence list (a hook it does not watch can vanish unnoticed).
if want 13; then
say "[13] Every list of hooks names the same set"
OUT13=$(python3 - <<'PY'
import glob, json, re
HOOK = r"cc-[\w-]+-hook\.sh"
mk = re.search(r"^HOOKS\s*:?=\s*(.*)$", open("Makefile").read(), re.M)
want = {p.rsplit("/", 1)[-1] for p in mk.group(1).split()} if mk else set()
if not want:
    print("Makefile has no HOOKS := list - nothing to hold the others to")
    raise SystemExit
def compare(where, names):
    for h in sorted(want - names):
        print(f"{where} lacks {h}")
    for h in sorted(names - want):
        print(f"{where} names {h}, which the Makefile HOOKS does not install")
pols = sorted(glob.glob("settings/managed-settings*.json"))
if not pols:
    print("no settings/managed-settings*.json - no policy to compare")
for f in pols:
    try:
        d = json.load(open(f))
    except (OSError, ValueError) as e:
        print(f"{f} could not be read ({e})"); continue
    compare(f + " hooks[]", {n for ev in (d.get("hooks") or {}).values() for m in ev
                             for h in m.get("hooks", []) for n in re.findall(HOOK, h.get("command", ""))})
# (script, how many explicit hook lists it holds) - a list the regex stops
# seeing must fail here, not pass as "no list, nothing wrong"
for f, expect in (("bin/cc-install.sh", 2), ("bin/cc-healthcheck.sh", 1)):
    text = open(f).read()
    lists = [m for m in re.finditer(r"^[ \t]*for \w+ in (.*?); do", text, re.M | re.S)
             if re.search(HOOK, m.group(1)) and "*" not in m.group(1)]
    if len(lists) != expect:
        print(f"{f} holds {len(lists)} explicit hook list(s), expected {expect} - this check no longer sees them")
    for m in lists:
        compare(f"{f} hook list at line {text[:m.start()].count(chr(10)) + 1}", set(re.findall(HOOK, m.group(1))))
PY
); RC13=$?
if [ "$RC13" -ne 0 ]; then
  bad "the hook-list check exited $RC13 - no list was compared"
elif [ -n "$OUT13" ]; then
  while IFS= read -r m; do bad "$m"; done <<< "$OUT13"
else
  ok "the Makefile HOOKS, both policies' hooks[], the installer's two lists and the healthcheck's list name the same set"
fi
fi

if want 14; then
say "[14] Couplings the installer, scripts, skills and test layout must keep"
# Each of these is a docs/REPO-MAP.md coupling. Every
# sub-check counts the lists it expects to see, so a list the parser stops
# recognising fails here instead of passing as "nothing to compare".
OUT14=$(python3 - <<'PY'
import glob, json, os, re, subprocess
def code(text):  # non-comment lines of a shell script
    return "\n".join(l for l in text.splitlines() if not l.lstrip().startswith("#"))
tracked = subprocess.check_output(["git", "ls-files"], universal_newlines=True).split()

# (a) every unit in systemd/ is in the installer's source gate and placement
# lists, and every timer in its enable loop and dry-run hint: a timer placed
# but never enabled is a silent no-op.
units = sorted(os.path.basename(p) for p in glob.glob("systemd/*.service") + glob.glob("systemd/*.timer"))
timers = [u for u in units if u.endswith(".timer")]
inst = code(open("bin/cc-install.sh").read())
lists = [m.group(1) for m in re.finditer(r"^[ \t]*for \w+ in (.*?); do", inst, re.M | re.S)]
UNIT = r"claude-code-[\w-]+\.(?:service|timer)"
for what, found, need in (
        ("source-gate", [l for l in lists if re.search("systemd/" + UNIT, l)], units),
        ("placement", [l for l in lists if re.search(r"(?<![/\w-])" + UNIT, l) and ".service" in l], units),
        ("enable --now loop", [l for l in lists if ".timer" in l and ".service" not in l], timers),
        ("dry-run enable hint", re.findall(r'act "[^"]*enable --now([^"]*)"', inst), timers)):
    if len(found) != 1:
        print(f"bin/cc-install.sh holds {len(found)} {what} list(s), expected 1 - this check no longer sees it")
        continue
    names = set(re.findall(r"(?<![\w-])" + UNIT, found[0].replace("systemd/", " ")))
    for u in need:
        if u not in names:
            print(f"bin/cc-install.sh {what} list lacks {u}")
    for u in sorted(names - set(need)):
        print(f"bin/cc-install.sh {what} list names {u}, which systemd/ does not ship")

# (b) the privileged-session predicate: every script that reads the mount
# table does it through the CC_MOUNTINFO seam with the same predicate, and the
# count matches the number REPO-MAP states.
SEAM = 'CC_MOUNTINFO="${CC_MOUNTINFO:-/proc/self/mountinfo}"'
PRED = "'$5 == t {found=1} END {exit !found}' \"$CC_MOUNTINFO\""
readers = []
for f in tracked:
    if not f.endswith(".sh") or f.startswith(("internal/", "tests/")) or f == "bin/cc-ci-check.sh":
        continue
    c = code(open(f, errors="replace").read())
    if "mountinfo" not in c:
        continue
    readers.append(f)
    if SEAM not in c:
        print(f"{f} reads the mount table without the CC_MOUNTINFO seam default")
    if PRED not in c:
        print(f"{f} does not use the shared bind-mount predicate over \"$CC_MOUNTINFO\"")
    if c.count("/proc/self/mountinfo") != c.count(SEAM):
        print(f"{f} reads /proc/self/mountinfo directly, outside the seam")
row = next((l for l in open("docs/REPO-MAP.md") if "privileged-session detection" in l), "")
m = re.search(r"\*\*(\w+)\*\* scripts", row)
words = "zero one two three four five six seven eight nine ten".split()
stated = words.index(m.group(1).lower()) if m and m.group(1).lower() in words else None
if stated is None:
    print("docs/REPO-MAP.md privileged-session row states no script count this check can read")
elif stated != len(readers):
    print(f"docs/REPO-MAP.md says {m.group(1)} scripts carry the predicate; {len(readers)} do: {' '.join(readers)}")
for f in readers:
    if f"`{f}`" not in row:
        print(f"docs/REPO-MAP.md privileged-session row does not name {f}")

# (c) no copy of the pin on a code line of anything that ships or runs CI
try:
    pin = json.load(open("settings/managed-settings.json")).get("requiredMinimumVersion")
except (OSError, ValueError) as e:
    pin = None; print(f"settings/managed-settings.json could not be read ({e})")
if pin:
    rx = re.compile(r"(?<![\w.])" + re.escape(str(pin)) + r"(?![\w]|\.\d)")
    for f in tracked:
        if f.startswith(("internal/", "tests/")) or not (
                re.search(r"\.(sh|csh|py)$", f) or f.startswith("githooks/")
                or f in ("Makefile", ".gitlab-ci.yml") or f.startswith(".github/workflows/")):
            continue
        for n, l in enumerate(open(f, errors="replace").read().splitlines(), 1):
            if not l.lstrip().startswith("#") and rx.search(l):
                print(f"{f}:{n} spells the pin {pin} - read it from the policy at run time")

# (d) tests/: every file has a row in tests/README.md, and a script neither CI
# config runs says so in its row - a separate test script otherwise lints and
# never runs.
rows = {}
for l in open("tests/README.md"):
    m = re.match(r"\|\s*`([^`]+)`\s*\|", l)
    if m:
        rows[m.group(1)] = l
files = {f[len("tests/"):] for f in tracked if f.startswith("tests/")} - {"README.md"}
for f in sorted(files - set(rows)):
    print(f"tests/{f} has no row in tests/README.md")
for f in sorted(set(rows) - files):
    print(f"tests/README.md has a row for {f}, which is not in tests/")
ci = [open(c).read() for c in (".github/workflows/ci.yml", ".gitlab-ci.yml")]
for f in sorted(files):
    if f.endswith(".sh") and f in rows and not all(f"tests/{f}" in c for c in ci) \
            and "never run by CI" not in rows[f]:
        print(f"tests/{f} is not run by both CI configs, and its tests/README.md row does not say 'never run by CI'")

# (e) skills cite OPERATIONS Part 7 by section number and by 7.2 row: both
# are an interface, and a renumber or a renamed row strands the skill.
ops = open("docs/OPERATIONS.md").read()
heads = set(re.findall(r"^## (7\.\d+) ", ops, re.M))
s72 = re.search(r"^## 7\.2 .*?(?=^## )", ops, re.M | re.S)
runs = set(re.findall(r"^\| `([\w.-]+)`", s72.group(0), re.M)) if s72 else set()
if not heads or not runs:
    print("docs/OPERATIONS.md: no Part 7 headings or no 7.2 table rows - this check no longer sees them")
skills = sorted(glob.glob(".claude/skills/*/SKILL.md"))
if not skills:
    print("no .claude/skills/*/SKILL.md - nothing to check")
for f in skills:
    t = open(f).read()
    for sec in sorted(set(re.findall(r"§(7\.\d+)", t)) - heads):
        print(f"{f} cites OPERATIONS §{sec}, which has no '## {sec}' heading")
    for r in sorted(set(re.findall(r"the `([\w-]+)` row", t)) - runs):
        print(f"{f} cites the `{r}` row, which OPERATIONS §7.2 does not have")
    if "§7.2" in t and f.split("/")[2] not in runs:
        print(f"{f} cites §7.2 as its contract, but §7.2 has no `{f.split('/')[2]}` row")

# (f) the ruleset guarding main requires exactly the ci.yml jobs that gate: a
# gating job it omits can fail and the commit still lands; a name no job has
# never reports, and every landing waits for it until it times out.
jobs = re.search(r"^jobs:\n(.*)", open(".github/workflows/ci.yml").read(), re.M | re.S)
parts = re.split(r"^  ([\w-]+):[ \t]*\n", jobs.group(1), flags=re.M) if jobs else []
gating = {n for n, body in zip(parts[1::2], parts[2::2])
          if not re.search(r"^    continue-on-error:[ \t]*true\b", body, re.M)}
try:
    rs = json.load(open(".github/rulesets/main.json"))
    req = {c["context"] for r in rs["rules"] if r["type"] == "required_status_checks"
           for c in r["parameters"]["required_status_checks"]}
except (OSError, ValueError, KeyError, TypeError) as e:
    req = None
    print(f".github/rulesets/main.json cannot be read as a ruleset ({e.__class__.__name__}: {e})")
if not gating:
    print(".github/workflows/ci.yml: no gating jobs found - this check no longer sees them")
elif req is not None:
    for j in sorted(gating - req):
        print(f".github/rulesets/main.json does not require the gating ci.yml job {j} - it could fail and the commit still land")
    for j in sorted(req - gating):
        print(f".github/rulesets/main.json requires {j}, which is no gating ci.yml job - every landing would wait for it")
PY
); RC14=$?
if [ "$RC14" -ne 0 ]; then
  bad "the coupling check exited $RC14 - nothing was compared"
elif [ -n "$OUT14" ]; then
  while IFS= read -r m; do bad "$m"; done <<< "$OUT14"
else
  ok "systemd units are in all four installer lists, the mount-table predicate is shared, no pin is copied, tests/ is mapped, skills cite live Part 7 sections, main requires every gating CI job"
fi
fi

echo
if [ "$FAILURES" -ne 0 ]; then
  say "cc-ci-check: $FAILURES check(s) FAILED"
  exit 1
elif [ -n "${CC_CI_ONLY:-}" ]; then
  say "cc-ci-check: selected check(s) [$CC_CI_ONLY] passed - PARTIAL run, not a full pass"
else
  say "cc-ci-check: all checks passed"
fi
