#!/usr/bin/env bash
# test-cc-scripts.sh - condition coverage tests for the cc-* operational scripts.
#
# Each test fabricates one specific state and asserts the script DETECTS it.
# The scripts read their site values from config.sh through lib/cc-config.sh;
# an exported CC_* wins for that run, so each fixture exports the paths it
# fabricates (CC_ETC, CC_HOME_ROOT, CC_LOGDIR ...) and nothing reads the real
# host's. OS seams (CC_PASSWD, CC_PROC, CC_RPM_BIN ...) default to the OS.
#
# Usage:  ./tests/test-cc-scripts.sh [-v|--coverage]
# Exit:   0 = all assertions passed, 1 = at least one failed, 2 = usage
#
# --coverage maps every executable shell script in the repository to the suite
# section that exercises it, DERIVED from this file's own head2 markers and
# assertion call sites - not a hand-written table, which would rot the way the
# cc-report.sh rule catalogue did. It exits 1 if a script has no cases and is not
# named in ACKNOWLEDGED_UNTESTED below, so an untested script can exist only
# where someone has written down that it does. Growth is caught; the existing
# set is visible and owned rather than silently carried. --coverage is static,
# so a full run also ends with a COV verdict built from the cases that RAN
# (cov_runtime below): a case that sits in this file but never executes does
# not count there.
#
# Re-run this on a real Rocky 8 host: several branches are environment-determined
# and are reported as SKIP rather than silently passing.

set -uo pipefail

VERBOSE=0
COVERAGE=0
case "${1:-}" in
  -v)         VERBOSE=1 ;;
  --coverage) COVERAGE=1 ;;
  '')         ;;
  *) echo "test-cc-scripts.sh: unknown argument '$1' (want -v or --coverage)" >&2; exit 2 ;;
esac

HERE=$(cd "$(dirname "$0")" && pwd)
# The operator scripts live in bin/, so $SCRIPTS/.. is the repo root and every
# other path below is derived from it.
SCRIPTS="${CC_SCRIPTS:-$HERE/../bin}"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# A template edition (docs/PUBLISHING.md) cannot be tested as it stands: its
# policy carries placeholders, the installer refuses them, and every case that
# installs would fail for that reason instead of its own. There the suite runs
# on the filled copy bin/cc-template-fill.sh writes - the same tree with each
# placeholder replaced - and this run's verdict is that run's. The copy has no
# template.json, so it does not fill itself again.
if git -C "$SCRIPTS/.." ls-files --error-unmatch template.json >/dev/null 2>&1; then
  FILLED="$WORK/filled"
  ( cd "$SCRIPTS/.." && bash bin/cc-template-fill.sh "$FILLED" ) >&2 \
    || { echo "test-cc-scripts.sh: template edition, and no filled copy could be written (reason above) - nothing was tested" >&2; exit 1; }
  # The suite and the checks it drives read the tracked file list, so the copy
  # is committed. The identity is this throwaway repository's alone.
  { git -C "$FILLED" init -q \
      && git -C "$FILLED" add -A \
      && git -C "$FILLED" -c user.name=cc-template-fill -c user.email=cc-template-fill@localhost commit -q -m "filled copy"; } >&2 \
    || { echo "test-cc-scripts.sh: template edition, and the filled copy could not be committed - nothing was tested" >&2; exit 1; }
  echo "test-cc-scripts.sh: template edition - running the suite on a filled copy" >&2
  CC_SCRIPTS="" bash "$FILLED/tests/test-cc-scripts.sh" "$@"
  exit $?
fi

# NONROOT - the non-root account a case acts as when it needs one: an invoker
# for the admin-session gates, a CC_REPO_RUNAS for the report. Unprivileged it
# is this account; as root it is SUDO_USER when the suite was started with sudo.
# A CI container has neither, and root in that role makes every gate refuse for
# being root instead of for its own reason - there a stock system account
# stands in (not nobody, which AS3 uses as the impersonation target). Empty when
# none resolves; the cases that need it skip.
NONROOT=""
if [ "$(id -u)" -ne 0 ]; then NONROOT=$(id -un)
elif [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ]; then NONROOT=$SUDO_USER
else for a in daemon bin; do getent passwd "$a" >/dev/null && { NONROOT=$a; break; }; done
fi

PASS=0; FAIL=0; SKIP=0
CURRENT=""

# ---------------------------------------------------------------- --coverage
# Scripts with no cases of their own, each with the reason it is acceptable.
# A script here is a decision someone took; a script NOT here and untested is a
# gap --coverage refuses to pass over. Remove an entry when you add its cases -
# do not add one to make --coverage quiet.
ACKNOWLEDGED_UNTESTED="
tests/cc-e2e.sh|the opt-in live harness - it runs real claude sessions, which cost model tokens and need a signed-in claude, so CI cannot; its cases ARE the test of the policy and hooks in the real binary
config.example.sh|a template of assignments with no logic; check [7] asserts every CC_* parameter appears in it
profile.d/claude-code-home.sh|two-line HOME resolution with no branch a fixture could exercise
profile.d/claude-code-home.csh|tcsh sibling of the above, same two lines in the other dialect
profile.d/claude-code-browser.sh|BROWSER selection; health check [2c] evaluates BOTH dialects on the host each day, which a fixture cannot do
profile.d/claude-code-browser.csh|tcsh sibling; [2c] is what proves the two agree, and that is the property that matters
share/cc-vscode-claude-wrapper.sh|inert until claudeProcessWrapper names it; IDE-INTEGRATION's method is proposed, not yet executed
bin/cc-repo-setup.sh|one-shot per clone, and its effect (hooks enabled) is what githooks then do
githooks/post-merge|thin wrapper: re-runs cc-repo-perms.sh --apply, whose behaviour is PM1-PM7
githooks/post-checkout|thin wrapper: re-runs cc-repo-perms.sh --apply, whose behaviour is PM1-PM7
"

# ---------------------------------------------------------------- coverage map
# cov_map <suite file> - one line per assertion call site: <subject><TAB><line>.
# The subject is the script the suite was last seen invoking (see --coverage).
cov_map() {
  awk -v self="$1" '
    BEGIN {
      while ((getline l < self) > 0) {
        ln++
        if (l ~ /^ACKNOWLEDGED_UNTESTED="/) { ack = 1; continue }
        if (ack) { if (l ~ /^"$/) ack = 0; continue }
        if (l ~ /^head2 "/) { s = l; sub(/^head2 "/, "", s); sub(/".*$/, "", s); subj = s; continue }
        if (match(l, /run_hook[ \t]+[A-Za-z0-9._-]+\.sh/))
          { h = substr(l, RSTART, RLENGTH); sub(/^run_hook[ \t]+/, "", h); subj = h }
        # A hook driven through a helper is named once, in the variable
        # assignment for that helper (DHK=..., AHK=...); that line sets the
        # subject for everything after it. Assignments ONLY - a hook merely
        # NAMED in a comment must not claim the cases that follow it.
        # No apostrophes anywhere in this awk block: it is single-quoted, and an
        # apostrophe ends it, and the failure it causes names a line far from here.
        # Match on the DIRECTORY the value points into - bin, hooks or githooks -
        # rather than on a cc-*.sh name shape. githooks/pre-commit has no
        # extension and no cc- prefix, so a name-shaped rule silently failed to
        # attribute its cases and the gate kept reporting it untested while its
        # cases sat a few lines above.
        else if (match(l, /^[A-Z][A-Z0-9_]*="[^"]*\/(bin|hooks|githooks)\/[A-Za-z0-9._-]+"/))
          { h = substr(l, RSTART, RLENGTH); sub(/^.*\//, "", h); sub(/"$/, "", h); subj = h }
        if (subj == "") continue
        # One count per assertion: the three assert_* helpers, plus the success
        # branch of an inline if/then-fail/else-pass, counted once via pass.
        if (l ~ /(assert_has|assert_lacks|assert_rc)[ \t]+"/ || l ~ /^[ \t]*pass[ \t]+"/) print subj "\t" ln
      }
    }
  ' /dev/null
}
# cov_population <root> - the scripts coverage is owed for, from git (see below)
cov_population() {
  (cd "$1" && git ls-files 2>/dev/null) | grep -E '\.(sh|csh)$|^githooks/' |
    grep -vE '^(internal|tests)/|\.md$' | sort | while IFS= read -r p; do printf '%s/%s\n' "$1" "$p"; done
}
# cov_runtime <map> <ledger> <population> <root> <acknowledged list>
# Prints "NONE <script> <call sites>" for a script none of whose attributed
# call sites appears on any recorded stack, and "SKIPPED <script>" for one whose
# only executed sites were skips. Exit 1 if any NONE.
cov_runtime() {
  awk -v root="$4" -v ack="$5" '
    BEGIN { n = split(ack, a, "\n"); for (i = 1; i <= n; i++) { split(a[i], f, "|"); if (f[1] != "") acked[f[1]] = 1 } }
    FILENAME == ARGV[1] { b = $1; sub(/^.*\//, "", b); sites[b] = sites[b] " " $2; nsites[b]++; next }
    FILENAME == ARGV[2] { for (i = 2; i <= NF; i++) { if ($1 == "S") skipped[$i] = 1; else ran[$i] = 1 }; next }
    {
      rel = $0; sub("^" root "/", "", rel); b = rel; sub(/^.*\//, "", b)
      if (rel in acked || !(b in nsites)) next
      split(sites[b], ls, " "); r = 0; sk = 0
      for (j in ls) { if (ls[j] in ran) r = 1; else if (ls[j] in skipped) sk = 1 }
      if (r) next
      if (sk) print "SKIPPED " rel
      else { print "NONE " rel " " nsites[b]; bad = 1 }
    }
    END { exit bad }
  ' "$1" "$2" "$3"
}

if [ "$COVERAGE" -eq 1 ]; then
  ROOT=$(cd "$HERE/.." && pwd)
  SELF="$HERE/$(basename "$0")"
  printf '%-42s %-26s %6s  %s\n' SCRIPT SECTION CASES VERDICT
  printf '%-42s %-26s %6s  %s\n' "------" "-------" "-----" "-------"
  # Counts are attributed to a SUBJECT, not to a section, because one section -
  # "hooks" - exercises several scripts and a per-section count would
  # credit each of them with every case. The subject is the last thing the suite was
  # seen invoking: a head2 marker, a run_hook <name> call, or $DHK (the denied
  # hook's own variable). Attribution therefore follows what the suite actually
  # runs rather than where the lines happen to sit.
  #
  # The ACKNOWLEDGED_UNTESTED block is skipped explicitly. It names script paths,
  # and without the skip a script would count as referenced BECAUSE it was
  # declared untested - the same self-reference that made RP11's first draft pass
  # off its own explanatory comment.
  cov_map "$SELF" | awk -F'\t' '{n[$1]++} END {for (k in n) print k "\t" n[k]}' > "$WORK/sections.tsv"
  gap=0; total=0
  while IFS= read -r f; do
    rel=${f#"$ROOT"/}
    total=$((total+1))
    base=$(basename "$f")
    # A head2 marker may name a path (aws/bin/cc-apply-posture.sh) or a bare
    # file, so both sides are reduced to a basename before comparing.
    sect=$(awk -F'\t' -v b="$base" '{k=$1; sub(/^.*\//,"",k)} k==b {print $1; exit}' "$WORK/sections.tsv")
    n=$(awk -F'\t' -v b="$base" '{k=$1; sub(/^.*\//,"",k)} k==b {print $2; exit}' "$WORK/sections.tsv")
    if [ -z "$n" ]; then n=0; sect=-; fi
    ack=$(printf '%s\n' "$ACKNOWLEDGED_UNTESTED" | awk -F'|' -v r="$rel" '$1==r {print $2}')
    if [ "${n:-0}" -eq 0 ]; then
      if [ -n "$ack" ]; then
        case "$ack" in
          "NOT ACCEPTED"*) verdict="NONE  ** $ack"; gap=$((gap+1)) ;;
          *)               verdict="none  (acknowledged: $ack)" ;;
        esac
      else
        verdict="NONE  ** UNACKNOWLEDGED - add cases, or an entry saying why not"; gap=$((gap+1))
      fi
    else
      verdict=COVERED
    fi
    printf '%-42s %-26s %6s  %s\n' "$rel" "${sect:--}" "${n:-0}" "$verdict"
    # THE DENOMINATOR COMES FROM GIT, not from the filesystem. With
    # `find -perm -u+x`, a script that lost its execute bit on disk would vanish
    # from this table and from the total, and the gate would stay green having
    # examined one script fewer. Modes on disk are not trusted: a clone with
    # core.fileMode=false never records them, which is why CI check [3] exists.
    # git ls-files is also what a fresh clone gets, which is the population
    # that matters.
  done < <(cov_population "$ROOT")
  echo
  echo "$total script(s) examined. A case is an assert_* call site or an inline pass branch,"
  echo "attributed to the script the suite was last seen invoking - not to the section it sits in,"
  echo "because one section exercises several hooks. Runtime totals differ: three call sites are loops"
  echo "that expand against the repo's current file set. Run without --coverage for the executed count."
  if [ "$gap" -gt 0 ]; then
    echo "$gap script(s) untested without an accepted reason - see the ** rows above."
    exit 1
  fi
  echo "Every untested script has a recorded reason."
  exit 0
fi

# Each result also records the line numbers on its call stack in the coverage
# ledger, so the end of a full run can tell which call sites actually ran.
pass() { PASS=$((PASS+1)); echo "P ${BASH_LINENO[*]}" >> "$WORK/cov-ledger"; printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
fail() { FAIL=$((FAIL+1)); echo "F ${BASH_LINENO[*]}" >> "$WORK/cov-ledger"; printf '  \033[31mFAIL\033[0m  %s\n' "$1"
         [ "$VERBOSE" -eq 1 ] && printf '        output was:\n%s\n' "$(sed 's/^/          /' "$CURRENT")"; }
skip() { SKIP=$((SKIP+1)); echo "S ${BASH_LINENO[*]}" >> "$WORK/cov-ledger"; printf '%s\n' "$1" >> "$WORK/skips"; printf '  \033[33mSKIP\033[0m  %s\n' "$1"; }
rc() { cat "$WORK/rc" 2>/dev/null || echo 99; }
head2() { printf '\n== %s ==\n' "$1"; }

# assert_has <id> <file> <pattern>
assert_has() {
  CURRENT="$2"
  if grep -qF -- "$3" "$2"; then pass "$1"; else fail "$1 (expected to find: $3)"; fi
}
# assert_lacks <id> <file> <pattern>
assert_lacks() {
  CURRENT="$2"
  if grep -qF -- "$3" "$2"; then fail "$1 (should NOT contain: $3)"; else pass "$1"; fi
}
# assert_rc <id> <actual> <expected>
assert_rc() {
  CURRENT="${4:-/dev/null}"
  if [ "$2" -eq "$3" ]; then pass "$1"; else fail "$1 (exit $2, expected $3)"; fi
}

# ---------------------------------------------------------------- fixtures
# Every script reads its site values through lib/cc-config.sh, which refuses to
# run without a complete config. The suite runs on the template's sample values
# - the same file in every clone, unlike a site's gitignored config.sh - with
# every value a script WRITES to redirected into $WORK, so a case that forgets
# to export a path still cannot touch the host's logs, metrics or staging. A
# case points one value elsewhere by exporting it (an exported CC_* wins over
# the file for that run; the hooks are the exception, see hc_loader below).
# CC_CONFIG_LIB pins the checkout's loader: on a deployed host the scripts
# would otherwise find the installed /etc/claude-code/cc-config.sh first.
TMPL="$SCRIPTS/../config.example.sh"
export CC_CONFIG_LIB="$SCRIPTS/../lib/cc-config.sh"
export CC_CONFIG="$WORK/suite-config.sh"
mkdir -p "$WORK/suite-log" "$WORK/suite-homes"
{ cat "$TMPL"
  printf 'CC_LOGDIR="%s"\n'           "$WORK/suite-log"
  printf 'CC_METRICS_FILE=""\n'
  printf 'CC_UPDATE_STAGE_DIR="%s"\n' "$WORK/suite-stage"
  printf 'CC_HOME_ROOT="%s"\n'        "$WORK/suite-homes"
} > "$CC_CONFIG"

# A fake /etc/passwd plus fake home directories, so the per-user checks have
# something deterministic to walk.
mk_passwd() {
  local dir="$1"
  mkdir -p "$dir/home/alice" "$dir/home/bob"
  cat > "$dir/passwd" <<EOF
root:x:0:0:root:/root:/bin/bash
daemon:x:1:1:daemon:/usr/sbin:/usr/sbin/nologin
alice:x:1001:1001:Alice:$dir/home/alice:/bin/bash
bob:x:1002:1002:Bob:$dir/home/bob:/bin/bash
svc:x:1003:1003:Service:$dir/home/svc:/usr/sbin/nologin
EOF
}

GOOD_POLICY='{
  "permissions": {
    "defaultMode": "default",
    "disableBypassPermissionsMode": "disable",
    "deny": ["Bash(sudo *)"]
  },
  "allowManagedPermissionRulesOnly": true,
  "allowManagedHooksOnly": true,
  "allowManagedMcpServersOnly": true,
  "allowedMcpServers": [],
  "disableSideloadFlags": true,
  "strictPluginOnlyCustomization": true,
  "disableClaudeAiConnectors": true,
  "forceLoginOrgUUID": "11111111-2222-4333-8444-555555555555",
  "requiredMinimumVersion": "2.1.200",
  "sandbox": {
    "enabled": true,
    "failIfUnavailable": true,
    "allowUnsandboxedCommands": false,
    "filesystem": { "allowManagedReadPathsOnly": true, "denyRead": ["~/.ssh"] },
    "network": { "strictAllowlist": true, "allowManagedDomainsOnly": true,
                 "allowedDomains": ["api.anthropic.com"] }
  }
}'

# ================================================================ cc-healthcheck
head2 "cc-healthcheck.sh"

run_hc() {  # run_hc <etcdir> <fixturedir> [extra env assignments...]
  local etc="$1" fx="$2"; shift 2
  local out="$WORK/hc.$RANDOM.out"
  # WORKTMP scopes cc-healthcheck's scratch account list into this run's own
  # temp dir. Without it the file lands in a shared /tmp, and H21 - which
  # asserts nothing was left behind - reads every OTHER concurrent run as
  # litter. On a shared multi-user host, two people running `make test` at the
  # same time is not an unusual event; a suite that fails then is a suite people
  # stop believing.
  # A fixture home root with two runner-owned homes, so the account count is
  # this fixture's and never the live host's population. The fixture users in
  # $fx/passwd live outside it and arrive through the second source.
  [ -d "$fx/homeroot" ] || mkdir -p "$fx/homeroot/u1" "$fx/homeroot/u2"
  env CC_ETC="$etc" CC_PASSWD="$fx/passwd" CC_HOME_ROOT="$fx/homeroot" \
      CC_NPM_GLOBAL="$fx/nonexistent-npm" CC_REPORT="$WORK/hc.log" WORKTMP="$WORK" "$@" \
      bash "$SCRIPTS/cc-healthcheck.sh" >"$out" 2>&1
  echo $? > "$WORK/rc"
  echo "$out"
}

# --- H1: no policy file at all
FX="$WORK/h1"; mk_passwd "$FX"; ETC="$WORK/h1etc"; mkdir -p "$ETC"
O=$(run_hc "$ETC" "$FX")
assert_has "H1  missing policy file is flagged" "$O" "is missing - the host is running with no IT policy"
assert_rc  "H1  exit 1 when findings exist" "$(rc)" 1 "$O"

# --- H2: policy file present but unparseable
FX="$WORK/h2"; mk_passwd "$FX"; ETC="$WORK/h2etc"; mkdir -p "$ETC"
printf '{ "permissions": ' > "$ETC/managed-settings.json"   # truncated JSON
chmod 644 "$ETC/managed-settings.json"
O=$(run_hc "$ETC" "$FX")
assert_has "H2  invalid JSON is flagged" "$O" "Invalid JSON"

# --- H3/H4: file mode
FX="$WORK/h3"; mk_passwd "$FX"; ETC="$WORK/h3etc"; mkdir -p "$ETC"
printf '%s' "$GOOD_POLICY" > "$ETC/managed-settings.json"; chmod 644 "$ETC/managed-settings.json"
O=$(run_hc "$ETC" "$FX")
assert_has  "H3  valid JSON recognised" "$O" "Valid JSON"
assert_has  "H3  mode 644 accepted" "$O" "Mode 644"
assert_lacks "H3  mode 644 not flagged" "$O" "writable beyond root"
chmod 666 "$ETC/managed-settings.json"
O=$(run_hc "$ETC" "$FX")
assert_has "H4  world-writable policy flagged" "$O" "Mode 666 is writable beyond root"
chmod 644 "$ETC/managed-settings.json"

# --- H5/H6/H7: checksum baseline
O=$(run_hc "$ETC" "$FX")
assert_has "H7  absent baseline reported" "$O" "No baseline checksum recorded"
# Baseline recorded with a RELATIVE filename (created from inside the dir).
( cd "$ETC" && sha256sum managed-settings.json > managed-settings.json.sha256 )
O=$(run_hc "$ETC" "$FX")
assert_has "H5a matching checksum recognised (relative baseline)" "$O" "Checksum matches the deployed baseline"
# Baseline recorded with an ABSOLUTE filename, as OPERATIONS 3.2 instructs.
sha256sum "$ETC/managed-settings.json" > "$ETC/managed-settings.json.sha256"
O=$(run_hc "$ETC" "$FX")
assert_has "H5b matching checksum recognised (absolute baseline)" "$O" "Checksum matches the deployed baseline"
# An empty or malformed baseline must be reported, not silently treated as a match.
: > "$ETC/managed-settings.json.sha256"
O=$(run_hc "$ETC" "$FX")
assert_has "H5c empty baseline reported" "$O" "contains no checksum"
sha256sum "$ETC/managed-settings.json" > "$ETC/managed-settings.json.sha256"
printf '%s\n' '{"tampered": true}' > "$ETC/managed-settings.json"
O=$(run_hc "$ETC" "$FX")
assert_has "H6  tampered policy detected via checksum" "$O" "changed since deployment"
printf '%s' "$GOOD_POLICY" > "$ETC/managed-settings.json"
( cd "$ETC" && sha256sum managed-settings.json > managed-settings.json.sha256 )

# A stub claude, first on PATH and owned by no package, so the binary checks run
# the same on every host: with the host's own claude they skipped wherever none
# was installed (a CI container) and passed or skipped by what this host had.
CLSTUB="$WORK/clstub"; mkdir -p "$CLSTUB"
printf '#!/bin/sh\necho "9.9.9 (Claude Code)"\n' > "$CLSTUB/claude"; chmod 755 "$CLSTUB/claude"

# --- H8/H9: approved-version drift
echo "9.9.9" > "$ETC/approved-version"
O=$(run_hc "$ETC" "$FX" PATH="$CLSTUB:$PATH")
assert_has  "H8  matching approved version recognised" "$O" "Matches approved version"
assert_lacks "H8  no drift reported when equal" "$O" "Version drift"
echo "0.0.1-not-a-real-version" > "$ETC/approved-version"
O=$(run_hc "$ETC" "$FX" PATH="$CLSTUB:$PATH")
assert_has "H9  version drift detected" "$O" "Version drift"
rm -f "$ETC/approved-version"

# --- H30: the binary that RUNS must be the one the package owns. /usr/local/bin
# precedes /usr/bin on RHEL-family PATHs, so a hand-placed binary shadows the
# version-locked RPM while `rpm -q claude-code` still reports it as present.
O=$(run_hc "$ETC" "$FX" PATH="$CLSTUB:$PATH")
assert_has "H30 reports which path claude resolves to" "$O" "resolves to: $CLSTUB/claude"
assert_has "H30b unowned binary on PATH flagged as shadowing" "$O" "binary on PATH ($CLSTUB/claude) is owned by NO package"

# --- H10/H11/H12/H13: credential file state
FX="$WORK/h10"; mk_passwd "$FX"; ETC="$WORK/h10etc"; mkdir -p "$ETC"
printf '%s' "$GOOD_POLICY" > "$ETC/managed-settings.json"; chmod 644 "$ETC/managed-settings.json"
mkdir -p "$FX/home/alice/.claude"
echo '{}' > "$FX/home/alice/.claude/.credentials.json"
chmod 600 "$FX/home/alice/.claude/.credentials.json"
O=$(run_hc "$ETC" "$FX")
assert_lacks "H11 mode 600 credentials not flagged" "$O" "credentials mode"
chmod 644 "$FX/home/alice/.claude/.credentials.json"
O=$(run_hc "$ETC" "$FX")
assert_has "H10 loose credential mode flagged" "$O" "credentials mode 644"
# ownership: only assertable when we can actually chown
if chown daemon "$FX/home/alice/.claude/.credentials.json" 2>/dev/null; then
  O=$(run_hc "$ETC" "$FX")
  assert_has "H12 credential owned by wrong user flagged" "$O" "credentials owned by"
  chown root "$FX/home/alice/.claude/.credentials.json" 2>/dev/null
else
  skip "H12 credential ownership (cannot chown here)"
fi
# age: backdate 100 days
chmod 600 "$FX/home/alice/.claude/.credentials.json"
touch -d "100 days ago" "$FX/home/alice/.claude/.credentials.json"
O=$(run_hc "$ETC" "$FX")
assert_has "H13 stale credentials surfaced" "$O" "may be near expiry"

# --- H14: user settings invalid JSON
printf '{ nope' > "$FX/home/alice/.claude/settings.json"
O=$(run_hc "$ETC" "$FX")
assert_has "H14 invalid user settings flagged" "$O" "settings.json is invalid JSON"
echo '{}' > "$FX/home/alice/.claude/settings.json"

# --- H15: per-user side install
O=$(run_hc "$ETC" "$FX")
assert_has "H17 clean host reports no side installs" "$O" "No side installs found"
mkdir -p "$FX/home/bob/.claude" "$FX/home/bob/.local/bin"
touch "$FX/home/bob/.local/bin/claude"
O=$(run_hc "$ETC" "$FX")
assert_has  "H15 per-user native side install detected" "$O" "bob: unmanaged native install"
assert_lacks "H15 no longer reports clean" "$O" "No side installs found"

# --- H16: global npm install
NPMDIR="$FX/fake-npm"; mkdir -p "$NPMDIR"
O=$(env CC_ETC="$ETC" CC_PASSWD="$FX/passwd" CC_HOME_ROOT="$FX/homeroot" \
        CC_NPM_GLOBAL="$NPMDIR" CC_REPORT="$WORK/hc.log" \
        bash "$SCRIPTS/cc-healthcheck.sh" >"$WORK/h16.out" 2>&1; echo "$WORK/h16.out")
assert_has "H16 global npm install detected" "$O" "Global npm install present"

# --- H18: nologin accounts are excluded from the per-user walk
mkdir -p "$FX/home/svc/.claude"
echo '{}' > "$FX/home/svc/.claude/.credentials.json"; chmod 666 "$FX/home/svc/.claude/.credentials.json"
O=$(run_hc "$ETC" "$FX")
assert_lacks "H18 nologin account excluded from credential check" "$O" "svc: credentials mode"

# --- H19: home directory containing a space
# Word-splitting over the account list would tear this into two "accounts",
# miscount the total, and silently skip the credential check for that user.
#
# THE DENOMINATOR HALF OF THIS CASE NEEDS CC_HOME_ROOT silenced. cc-healthcheck.sh
# builds the account list from TWO sources: every directory under $CC_HOME_ROOT
# (owner resolved by stat) and every uid>=1000 line in $CC_PASSWD whose home is
# NOT under it. run_hc points CC_HOME_ROOT at a fixture root holding two homes,
# so the fixture's users arrive through the second source - the per-user
# assertions above and in every other H case are real - and the count includes
# those two. This assertion is about the count, so it needs the first source
# silenced.
#
# Pointing CC_HOME_ROOT at an EMPTY directory is the way to do that, not at the
# fixture's homes: those are owned by whoever runs the suite, so stat would
# attribute "od d" to the runner and the account would stop being called odd.
FX="$WORK/h19"; ETC="$WORK/h19etc"; mkdir -p "$FX/home/od d/.claude" "$ETC" "$FX/nohomes"
printf 'root:x:0:0:root:/root:/bin/bash\nodd:x:1001:1001:Odd:%s/home/od d:/bin/bash\n' "$FX" > "$FX/passwd"
printf '%s' "$GOOD_POLICY" > "$ETC/managed-settings.json"; chmod 644 "$ETC/managed-settings.json"
echo '{}' > "$FX/home/od d/.claude/.credentials.json"
chmod 666 "$FX/home/od d/.claude/.credentials.json"
O=$(run_hc "$ETC" "$FX")
assert_has "H19 space in home: credential mode still detected" "$O" "odd: credentials mode 666"
O=$(run_hc "$ETC" "$FX" CC_HOME_ROOT="$FX/nohomes")
# The literal the script prints is "Audited N account(s) from <root> + local
# interactive accounts", so the assertion stops at the count.
assert_has "H19 space in home: account counted once" "$O" "Audited 1 account(s)"

# --- H23: the denominator guard itself. An audit of one account out of many,
# reported as healthy, is the failure this guard exists for. The fixture gives
# it a home root of its own, so the USER_COUNT <= 1 branch is reached whatever
# the population of the host the suite runs on.
CURRENT="$O"
if grep -q "enumeration may be broken" "$O"; then
  pass "H23 a denominator of one is flagged, not reported as clean"
else
  fail "H23 a denominator of one is flagged, not reported as clean"
fi
assert_rc "H23 and a broken denominator fails the run" "$(rc)" 1 "$O"
# The opposite direction: a healthy population must NOT trip the guard, or the
# alarm becomes noise and gets ignored - which is how the original defect
# survived.
O=$(run_hc "$ETC" "$FX")
assert_lacks "H23b a normal population does not trip the guard" "$O" "enumeration may be broken"
assert_lacks "H23c and a root holding real homes is not called wrong" "$O" "holds no home owned by a real account"

# --- H24: CC_HOME_ROOT is a site value, and a wrong one must FAIL, not audit
# nobody. /etc/passwd cannot stand in for it on a directory-backed host.
O=$(run_hc "$ETC" "$FX" CC_HOME_ROOT="$FX/no-such-root")
assert_has "H24 a home root that does not exist is flagged" "$O" "does not exist - no engineer's credentials"
assert_rc  "H24 and fails the run" "$(rc)" 1 "$O"
O=$(run_hc "$ETC" "$FX" CC_HOME_ROOT="$FX/nohomes")
assert_has "H24b a home root holding no real home is flagged" "$O" "holds no home owned by a real account"

# --- H20: concurrent runs against one report file must not corrupt it
FX="$WORK/h20"; mk_passwd "$FX"; ETC="$WORK/h20etc"; mkdir -p "$ETC" "$FX/homeroot/u1" "$FX/homeroot/u2"
printf '%s' "$GOOD_POLICY" > "$ETC/managed-settings.json"; chmod 644 "$ETC/managed-settings.json"
: > "$WORK/shared.log"
for _ in 1 2 3; do
  env CC_ETC="$ETC" CC_PASSWD="$FX/passwd" CC_HOME_ROOT="$FX/homeroot" \
      CC_NPM_GLOBAL="$FX/none" CC_REPORT="$WORK/shared.log" WORKTMP="$WORK" \
      bash "$SCRIPTS/cc-healthcheck.sh" >/dev/null 2>&1 &
done
wait
CURRENT="$WORK/shared.log"
if [ "$(grep -c '^RESULT' "$WORK/shared.log")" -eq 3 ]; then
  pass "H20 three concurrent runs each wrote a complete report"
else
  fail "H20 three concurrent runs each wrote a complete report"
fi

# --- H21: no temp files left behind. Scoped to THIS run: every invocation above
# sets WORKTMP, so a leak lands here. Globbing the shared /tmp instead made the
# case fail whenever a second suite run - or a colleague on this multi-user host
# - had one in flight, which is a false alarm about someone else's correct
# behaviour, and the fastest way to teach people to ignore a red suite.
CURRENT="/dev/null"
if ls "$WORK"/cc-users.* >/dev/null 2>&1; then
  fail "H21 no stale temp files left behind by this run"
else
  pass "H21 no stale temp files left behind by this run"
fi

# --- H22: the weekly report has three ways to notice its own absence, and this
# is the only one on a DAILY cadence. A missed weekly run is otherwise invisible
# until somebody asks.
FX7="$WORK/h20"; mk_passwd "$FX7"; ETC7="$WORK/h20etc"; mkdir -p "$ETC7"
LOG7="$WORK/h20log"
O=$(run_hc "$ETC7" "$FX7" CC_LOGDIR="$LOG7")
assert_has "H22 no reports directory is a skip, not a finding" "$O" "the weekly report is not installed on this host"
mkdir -p "$LOG7/reports"
O=$(run_hc "$ETC7" "$FX7" CC_LOGDIR="$LOG7")
assert_has "H22 a reports directory with no state is a finding" "$O" "has never completed a full run"
printf '{"generated_at":"%s"}\n' "$(date -Is)" > "$LOG7/reports/state.json"
O=$(run_hc "$ETC7" "$FX7" CC_LOGDIR="$LOG7")
assert_has "H22 a fresh report is reported, not flagged" "$O" "last weekly report 0 day(s) ago"
printf '{"generated_at":"2020-01-01T00:00:00+00:00"}\n' > "$LOG7/reports/state.json"
O=$(run_hc "$ETC7" "$FX7" CC_LOGDIR="$LOG7")
assert_has "H22 a stale report is flagged with its age" "$O" "a run was missed and nothing said so"

# --- MT1-MT4: the Prometheus rendering. It is a rendering of the run, so the
# numbers must equal what the log said; and it must fail SAFE in two directions -
# never a half-written file (node_exporter would set scrape_error and every panel
# goes amber for an unfindable reason), and never a file at all where no exporter
# exists.
FXM="$WORK/mt"; mk_passwd "$FXM"; ETCM="$WORK/mtetc"; mkdir -p "$ETCM"
MDIR="$WORK/textfile"; mkdir -p "$MDIR"
O=$(run_hc "$ETCM" "$FXM" CC_METRICS_FILE="$MDIR/claude_code.prom")
CURRENT="$O"
if [ -r "$MDIR/claude_code.prom" ]; then pass "MT1 a metrics file is written when the directory exists"
else fail "MT1 a metrics file is written when the directory exists"; fi
CURRENT="$MDIR/claude_code.prom"
assert_has "MT2 the denominator metric is present" "$MDIR/claude_code.prom" "claude_code_healthcheck_accounts_audited"
assert_has "MT2 and the staleness metric"          "$MDIR/claude_code.prom" "claude_code_textfile_timestamp_seconds"
# The numbers must agree with the log, or the rendering has become a second
# source of truth - the exact thing a flag-on-the-same-script avoids.
LOG_ISSUES=$(sed -n 's/^RESULT: \([0-9]*\) item.*/\1/p' "$O" | tail -1)
MET_ISSUES=$(sed -n 's/^claude_code_healthcheck_issues \([0-9]*\)/\1/p' "$MDIR/claude_code.prom")
if [ "${LOG_ISSUES:-0}" = "${MET_ISSUES:-x}" ] || { [ -z "$LOG_ISSUES" ] && [ "${MET_ISSUES:-x}" = 0 ]; }; then
  pass "MT3 the metric agrees with the log it renders"
else
  fail "MT3 the metric agrees with the log it renders (log=$LOG_ISSUES metric=$MET_ISSUES)"
fi
# The world-readable mode is the privacy test: anything needing group-only
# protection cannot be in this file. It must also carry no user names.
CURRENT="$MDIR/claude_code.prom"
if grep -qE 'alice|bob|/users/' "$MDIR/claude_code.prom"; then
  fail "MT3 no identities in the metrics file"
else
  pass "MT3 no identities in the metrics file"
fi
O=$(run_hc "$ETCM" "$FXM" CC_METRICS_FILE="$WORK/no-such-dir/claude_code.prom")
assert_has "MT4 a missing collector directory writes nothing and says so" "$O" "does not exist, nothing written"

# --- HE: reachability is asked without curl, an absent approved-version
# is a finding, and "could not run" is exit 3, never the "unhealthy" 1.
HEB="$WORK/hebin"; mkdir -p "$HEB"
printf '#!/bin/sh\necho "$*" >> "%s/curl-called"\nexit 0\n' "$WORK" > "$HEB/curl"
printf '#!/bin/sh\necho "9.9.9 (Claude Code)"\n' > "$HEB/claude"
chmod 755 "$HEB/curl" "$HEB/claude"
python3 - "$WORK/he-port" > /dev/null 2>&1 <<'PY' &
import http.server, sys, socketserver
class Q(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *a): pass
s = socketserver.TCPServer(("127.0.0.1", 0), Q)
open(sys.argv[1], "w").write(str(s.server_address[1]))
s.timeout = 30
for _ in range(10): s.handle_request()
PY
HE_SRV=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$WORK/he-port" ] && break; sleep 0.3; done
HE_PORT=$(cat "$WORK/he-port" 2>/dev/null)
FX="$WORK/he1"; mk_passwd "$FX"; ETC="$WORK/he1etc"; mkdir -p "$ETC"; rm -f "$WORK/curl-called"
O=$(run_hc "$ETC" "$FX" PATH="$HEB:$PATH" CC_REACH_URLS="http://127.0.0.1:$HE_PORT/ http://127.0.0.1:1/")
CURRENT="$O"
if [ -e "$WORK/curl-called" ]; then fail "HE1 reachability never runs curl (endpoint protection may kill it)"
else pass "HE1 reachability never runs curl (endpoint protection may kill it)"; fi
assert_has "HE1 a listening endpoint is reachable"      "$O" "http://127.0.0.1:$HE_PORT/ reachable"
assert_has "HE1 a closed port is flagged unreachable"   "$O" "http://127.0.0.1:1/ unreachable"
kill "$HE_SRV" 2>/dev/null; wait "$HE_SRV" 2>/dev/null
assert_has "HE2 a host with no approved-version is flagged, not skipped" "$O" "No approved-version recorded"
O=$(run_hc "$ETC" "$FX" CC_REPORT=/dev/null/hc/hc.log)
assert_rc  "HE3 a report that cannot be written exits 3, not 1" "$(rc)" 3 "$O"
O=$(run_hc "$ETC" "$FX" CC_CONFIG="$WORK/he-no-such-config.sh")
assert_rc  "HE4 a config that cannot be loaded exits 3, not 1" "$(rc)" 3 "$O"

# ================================================================ cc-audit
head2 "cc-audit.sh"

run_audit() {  # run_audit <etcdir> <fixturedir>
  local out="$WORK/audit.$RANDOM.txt"
  env CC_ETC="$1" CC_PASSWD="$2/passwd" CC_HOME_ROOT="$2/homeroot" CC_REPO_FILE="$2/yum.repo" \
      bash "$SCRIPTS/cc-audit.sh" "$WORK/audit-report.$RANDOM.txt" >"$out" 2>&1
  echo $? > "$WORK/rc"
  echo "$out"
}

# --- A1: no policy file
FX="$WORK/a1"; mk_passwd "$FX"; ETC="$WORK/a1etc"; mkdir -p "$ETC"
O=$(run_audit "$ETC" "$FX")
assert_has "A1  no policy file reported distinctly" "$O" "NO POLICY FILE"
assert_has "A1  unpoliced host called out in section 2" "$O" "NO MANAGED SETTINGS FILE"
assert_has "A7  sandbox absence flagged" "$O" "no managed settings"

# --- A2: unparseable policy (must NOT look the same as A1)
FX="$WORK/a2"; mk_passwd "$FX"; ETC="$WORK/a2etc"; mkdir -p "$ETC"
printf '{ "permissions": ' > "$ETC/managed-settings.json"
O=$(run_audit "$ETC" "$FX")
assert_has  "A2  unparseable policy reported distinctly" "$O" "POLICY FILE UNPARSEABLE"
assert_lacks "A2  not confused with a missing file" "$O" "NO POLICY FILE"

# --- A3/A5/A6/A8: complete policy
FX="$WORK/a3"; mk_passwd "$FX"; ETC="$WORK/a3etc"; mkdir -p "$ETC"
printf '%s' "$GOOD_POLICY" > "$ETC/managed-settings.json"
O=$(run_audit "$ETC" "$FX")
assert_lacks "A3  no locks reported missing when all present" "$O" "NOT SET"
assert_has  "A3b unset disableAutoMode reported as intended, not missing" "$O" "auto mode ENABLED (intended;"
assert_lacks "A3c disableAutoMode is not listed as a missing control" "$O" "permissions.disableAutoMode\n"
assert_lacks "A6  no placeholder warning for a real UUID" "$O" "UNREPLACED PLACEHOLDERS"
assert_has  "A8  sandbox posture rendered" "$O" "network.strictAllowlist"
assert_has  "A8  allowedDomains counted" "$O" "network.allowedDomains       1 entry"
assert_has  "A8  managed read lock rendered" "$O" "filesystem.allowManagedReadPathsOnly true"

# --- A4: missing lock keys are named
FX="$WORK/a4"; mk_passwd "$FX"; ETC="$WORK/a4etc"; mkdir -p "$ETC"
echo '{"permissions": {"deny": ["Bash(sudo *)"]}}' > "$ETC/managed-settings.json"
O=$(run_audit "$ETC" "$FX")
assert_has "A4  absent locks enumerated" "$O" "NOT SET"
assert_has "A4  names the specific missing lock" "$O" "allowManagedPermissionRulesOnly"
assert_has "A7  sandbox-not-configured warning" "$O" "sandbox not configured"

# --- A5: placeholder detection
FX="$WORK/a5"; mk_passwd "$FX"; ETC="$WORK/a5etc"; mkdir -p "$ETC"
python3 - "$ETC/managed-settings.json" <<PY
import json,sys
d=json.loads('''$GOOD_POLICY''')
d["forceLoginOrgUUID"]="REPLACE-WITH-YOUR-ORG-UUID"
json.dump(d, open(sys.argv[1],"w"), indent=2)
PY
O=$(run_audit "$ETC" "$FX")
assert_has "A5  unreplaced placeholder detected" "$O" "UNREPLACED PLACEHOLDERS"
assert_has "A5  placeholder path named" "$O" "forceLoginOrgUUID = REPLACE-WITH-YOUR-ORG-UUID"

# --- A5b: a _comment_* key that quotes the word "REPLACES" while explaining the
# placeholder convention must NOT be reported as an unreplaced placeholder.
FX="$WORK/a5b"; mk_passwd "$FX"; ETC="$WORK/a5betc"; mkdir -p "$ETC"
CC_POLICY="$GOOD_POLICY" python3 -c '
import json, os, sys
d = json.loads(os.environ["CC_POLICY"])
d["_comment_1"] = "Omitting $defaults REPLACES the entire built-in list."
json.dump(d, open(sys.argv[1], "w"), indent=2)
' "$ETC/managed-settings.json"
O=$(run_audit "$ETC" "$FX")
assert_lacks "A5b comment quoting REPLACES is not a false positive" "$O" "UNREPLACED PLACEHOLDERS"

# --- A5c: other placeholder markers are caught, including inside nested arrays.
FX="$WORK/a5c"; mk_passwd "$FX"; ETC="$WORK/a5cetc"; mkdir -p "$ETC"
CC_POLICY="$GOOD_POLICY" python3 -c '
import json, os, sys
d = json.loads(os.environ["CC_POLICY"])
d["autoMode"] = {"environment": ["$defaults", "Source control: TODO"]}
json.dump(d, open(sys.argv[1], "w"), indent=2)
' "$ETC/managed-settings.json"
O=$(run_audit "$ETC" "$FX")
assert_has "A5c TODO marker caught in a nested array" "$O" "autoMode.environment[1]"

# --- A5d: autoMode arrays missing "$defaults" is the sharpest footgun in the
# settings surface, so the audit must call it out explicitly.
FX="$WORK/a5d"; mk_passwd "$FX"; ETC="$WORK/a5detc"; mkdir -p "$ETC"
CC_POLICY="$GOOD_POLICY" python3 -c '
import json, os, sys
d = json.loads(os.environ["CC_POLICY"])
d["autoMode"] = {"environment": ["Source control: github.example.com/acme"],
                 "hard_deny": ["$defaults", "Never exfiltrate customer data"]}
json.dump(d, open(sys.argv[1], "w"), indent=2)
' "$ETC/managed-settings.json"
O=$(run_audit "$ETC" "$FX")
assert_has "A5d autoMode array missing \$defaults is flagged" "$O" "MISSING \"\$defaults\""
assert_has "A5d names the offending array" "$O" "autoMode.environment"

# --- A5e: autoMode arrays that all include "$defaults" must not be flagged.
FX="$WORK/a5e"; mk_passwd "$FX"; ETC="$WORK/a5eetc"; mkdir -p "$ETC"
CC_POLICY="$GOOD_POLICY" python3 -c '
import json, os, sys
d = json.loads(os.environ["CC_POLICY"])
d["autoMode"] = {"environment": ["$defaults", "Source control: x"],
                 "hard_deny": ["$defaults", "Never exfiltrate customer data"],
                 "classifyAllShell": True}
json.dump(d, open(sys.argv[1], "w"), indent=2)
' "$ETC/managed-settings.json"
O=$(run_audit "$ETC" "$FX")
assert_lacks "A5e correct autoMode config is not flagged" "$O" "MISSING \"\$defaults\""
assert_has "A5e classifyAllShell rendered" "$O" "autoMode.classifyAllShell"

# --- A6a/A6b: outbound data controls must be reported, and an enabled egress path
# must be flagged. /feedback alone can put customer code in a public GitHub issue.
FX="$WORK/a6"; mk_passwd "$FX"; ETC="$WORK/a6etc"; mkdir -p "$ETC"
CC_POLICY="$GOOD_POLICY" python3 -c '
import json, os, sys
d = json.loads(os.environ["CC_POLICY"])
d["env"] = {"DISABLE_FEEDBACK_COMMAND": "1", "CLAUDE_CODE_DISABLE_FEEDBACK_SURVEY": "1",
            "DISABLE_TELEMETRY": "1", "DISABLE_ERROR_REPORTING": "1",
            "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1"}
json.dump(d, open(sys.argv[1], "w"), indent=2)
' "$ETC/managed-settings.json"
O=$(run_audit "$ETC" "$FX")
assert_has  "A6a all egress controls off is reported" "$O" "DISABLE_FEEDBACK_COMMAND                   off"
assert_lacks "A6a no egress warning when all disabled" "$O" "DATA EGRESS ENABLED"

FX="$WORK/a6b"; mk_passwd "$FX"; ETC="$WORK/a6betc"; mkdir -p "$ETC"
CC_POLICY="$GOOD_POLICY" python3 -c '
import json, os, sys
d = json.loads(os.environ["CC_POLICY"])
d["env"] = {"CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1"}
json.dump(d, open(sys.argv[1], "w"), indent=2)
' "$ETC/managed-settings.json"
O=$(run_audit "$ETC" "$FX")
assert_has "A6b umbrella alone still flags /feedback as ON" "$O" "DISABLE_FEEDBACK_COMMAND                   ** ON **"
assert_has "A6b egress summary names the gap" "$O" "DATA EGRESS ENABLED"

# --- A40: supply chain. gpgcheck=0 means packages are not signature-verified, and a
# network-fetched gpgkey is weaker than a locally staged one on a gated host.
# The repo file is a fixture through CC_REPO_FILE: a case that wrote the live
# /etc/yum.repos.d file would, as root, leave a gpgcheck=0 repo on the host
# until its restore line ran, and for good if the run died first.
FX="$WORK/a40"; mk_passwd "$FX"; ETC="$WORK/a40etc"; mkdir -p "$ETC"
printf '%s' "$GOOD_POLICY" > "$ETC/managed-settings.json"
cat > "$FX/yum.repo" <<'REPOEOF'
[claude-code]
name=Claude Code
baseurl=https://downloads.claude.ai/claude-code/rpm/stable
enabled=1
gpgcheck=0
gpgkey=https://downloads.claude.ai/keys/claude-code.asc
REPOEOF
O=$(run_audit "$ETC" "$FX")
assert_has "A40 gpgcheck=0 is flagged as unverified" "$O" "packages are NOT signature-verified"
assert_has "A40 network-fetched gpgkey is noted" "$O" "fetched over the network at install time"
assert_has "A40 the repo file read is the one named by CC_REPO_FILE" "$O" "$FX/yum.repo"

# --- A9: credential table
FX="$WORK/a9"; mk_passwd "$FX"; ETC="$WORK/a9etc"; mkdir -p "$ETC"
printf '%s' "$GOOD_POLICY" > "$ETC/managed-settings.json"
mkdir -p "$FX/home/alice/.claude"; echo '{}' > "$FX/home/alice/.claude/.credentials.json"
O=$(run_audit "$ETC" "$FX")
assert_has "A9  user with credentials listed present" "$O" "alice            present"
assert_has "A9  user without credentials listed none" "$O" "bob              none"

# --- A10: EC2 metadata must not leak an error body
assert_has "A10 non-EC2 metadata reported cleanly" "$O" "AWS       : n/a"

# --- AU: the audit counts the accounts that exist (a directory-backed
# site has them on the file server, not in /etc/passwd), keeps its evidence private,
# cannot hang on claude doctor, and it never exits 0 without a record on file.
FX="$WORK/au1"; mk_passwd "$FX"; ETC="$WORK/au1etc"; mkdir -p "$ETC" "$FX/homeroot/$(id -un)"
printf '%s' "$GOOD_POLICY" > "$ETC/managed-settings.json"
AUB="$WORK/aubin"; mkdir -p "$AUB"
printf '#!/bin/sh\n[ "$1" = doctor ] && sleep 30\necho "9.9.9 (Claude Code)"\n' > "$AUB/claude"
printf '#!/bin/sh\necho "$*" >> "%s/curl-called"\nexit 0\n' "$WORK" > "$AUB/curl"
chmod 755 "$AUB/claude" "$AUB/curl"; rm -f "$WORK/curl-called"
AUOUT="$WORK/au1-report.txt"
O="$WORK/au1.out"
( umask 022; timeout 25 env CC_ETC="$ETC" CC_PASSWD="$FX/passwd" CC_HOME_ROOT="$FX/homeroot" PATH="$AUB:$PATH" \
    CC_DOCTOR_TIMEOUT=2 bash "$SCRIPTS/cc-audit.sh" "$AUOUT" > "$O" 2>&1; echo $? > "$WORK/rc" )
assert_has "AU1 an account whose home is on the filer is audited" "$O" "  $(id -un) "
assert_has "AU1 and the population is stated" "$O" "Audited 3 account(s)"
if [ "$(stat -c '%a' "$AUOUT" 2>/dev/null)" = 640 ]; then pass "AU2 the audit record is 0640 under a 022 umask"
else CURRENT="$O"; fail "AU2 the audit record is 0640 under a 022 umask (got $(stat -c '%a' "$AUOUT" 2>/dev/null))"; fi
CURRENT="$O"
case "$(rc)" in 0) pass "AU3 a hung claude doctor does not hang the audit" ;;
  *) fail "AU3 a hung claude doctor does not hang the audit (exit $(rc); 124 = it hung)" ;; esac
assert_has "AU3 and the timeout is reported" "$O" "claude doctor did not finish within 2s"
CURRENT="$O"
if [ -e "$WORK/curl-called" ]; then fail "AU5 the instance-id lookup never runs curl"
else pass "AU5 the instance-id lookup never runs curl"; fi
# AU6: the audit runs as root, so claude doctor's output must never go to a
# path another account could predict and pre-plant (a symlink beside the mktemp
# file). The stub records where its stdout points.
AU6B="$WORK/au6bin"; mkdir -p "$AU6B"
printf '#!/bin/sh\nif [ "$1" = doctor ]; then readlink /proc/$$/fd/1 > "%s/au6.fd1"; echo "doctor-said-hello"; exit 0; fi\necho "9.9.9 (Claude Code)"\n' "$WORK" > "$AU6B/claude"
chmod 755 "$AU6B/claude"; rm -f "$WORK/au6.fd1"
O="$WORK/au6.out"
env CC_ETC="$WORK/au1etc" CC_PASSWD="$WORK/au1/passwd" CC_HOME_ROOT="$WORK/au1/homeroot" PATH="$AU6B:$PATH" \
    bash "$SCRIPTS/cc-audit.sh" "$WORK/au6-report.txt" > "$O" 2>&1
assert_has   "AU6 claude doctor output still reaches the record" "$O" "  doctor-said-hello"
assert_has   "AU6 and is captured through a pipe, not a file" "$WORK/au6.fd1" "pipe:"
assert_lacks "AU6 and never via a predictable file beside the temp list" "$WORK/au6.fd1" ".doctor"
FX="$WORK/au4"; mk_passwd "$FX"; ETC="$WORK/au4etc"; mkdir -p "$ETC"
echo '{"permissions": {"deny": ["Bash(sudo *)"]}}' > "$ETC/managed-settings.json"
O="$WORK/au4.out"
env CC_ETC="$ETC" CC_PASSWD="$FX/passwd" CC_HOME_ROOT="$FX/homeroot" PATH="$AUB:$PATH" CC_DOCTOR_TIMEOUT=1 \
    bash "$SCRIPTS/cc-audit.sh" "$WORK/au4-report.txt" > "$O" 2>&1; echo $? > "$WORK/rc"
assert_rc  "AU4 an audit with findings exits 0 - a snapshot, not a verdict" "$(rc)" 0 "$O"
assert_has "AU4 and counts them" "$O" "Findings: "
env CC_ETC="$ETC" CC_PASSWD="$FX/passwd" CC_HOME_ROOT="$FX/homeroot" PATH="$AUB:$PATH" CC_DOCTOR_TIMEOUT=1 \
    bash "$SCRIPTS/cc-audit.sh" /dev/null/au/report.txt > "$O" 2>&1; echo $? > "$WORK/rc"
assert_rc  "AU4 an audit that cannot write its record exits 3" "$(rc)" 3 "$O"

# --- EDR1: no shipped script runs curl or wget. Endpoint protection can
# kill them as a suspected file download, so a check built on curl reads
# a working host as broken. Comments and quoted prose are not invocations.
EDR_HITS=$(grep -nE '(^|[;&|(`]|\$\()[[:space:]]*(curl|wget)[[:space:]]' \
             "$SCRIPTS"/*.sh "$SCRIPTS"/../hooks/*.sh "$SCRIPTS"/../aws/bin/*.sh 2>/dev/null | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#')
printf '%s\n' "$EDR_HITS" > "$WORK/edr1.out"; CURRENT="$WORK/edr1.out"
if [ -n "$EDR_HITS" ]; then fail "EDR1 no shipped script invokes curl or wget"
else pass "EDR1 no shipped script invokes curl or wget"; fi

# ================================================================ cc-preflight
head2 "cc-preflight.sh"

run_pf() {
  local out="$WORK/pf.$RANDOM.out"
  env CC_ETC="$1" bash "$SCRIPTS/cc-preflight.sh" >"$out" 2>&1
  echo $? > "$WORK/rc"
  echo "$out"
}

# --- P1: CC_ETC absent
O=$(run_pf "$WORK/no-such-etc")
assert_has "P1  absent managed-settings dir warned" "$O" "does not exist yet"

# --- P2: invalid policy JSON is a hard failure
ETC="$WORK/p2etc"; mkdir -p "$ETC"; printf '{ bad' > "$ETC/managed-settings.json"
O=$(run_pf "$ETC")
assert_has "P2  invalid policy JSON is a FAIL" "$O" "not valid JSON - entries will be stripped"
assert_rc  "P2  exit 1 on hard blocker" "$(rc)" 1 "$O"

# --- P3: valid policy JSON
ETC="$WORK/p3etc"; mkdir -p "$ETC"; printf '%s' "$GOOD_POLICY" > "$ETC/managed-settings.json"
O=$(run_pf "$ETC")
assert_has "P3  valid policy JSON recognised" "$O" "managed-settings.json is valid JSON"

# --- P4: loopback bind test
assert_has "P4  loopback bind test executes" "$O" "127.0.0.1"

# --- P5: sections all render
for section in "Platform" "CPU and memory" "C library" "Sandbox dependencies" \
               "Desktop session and browser" "Loopback" "Outbound connectivity" \
               "Managed settings location"; do
  assert_has "P5  section present: $section" "$O" "-- $section"
done

# --- environment-determined branches we cannot force here
skip "P6 AVX-absent branch (cannot fake /proc/cpuinfo)"
skip "P7 RAM-below-minimum branch (cannot fake /proc/meminfo)"
skip "P8 unsupported-architecture branch (cannot fake uname -m)"
skip "P9 non-RHEL rejection branch (cannot test: this host IS RHEL-family)"
skip "P10 musl-present branch (no musl toolchain here)"
skip "P11 user.max_user_namespaces=0 branch (would need sysctl change)"

# ================================================================ cc-update
head2 "cc-update.sh"

run_up() {
  local out="$WORK/up.$RANDOM.out"
  env CC_ETC="$WORK/upetc" CC_LOG="$WORK/up.log" \
      bash "$SCRIPTS/cc-update.sh" "$@" >"$out" 2>&1
  echo $? > "$WORK/rc"
  echo "$out"
}
mkdir -p "$WORK/upetc"

# --- U1/U2/U3/U6: usage handling. cc-update.sh checks root BEFORE parsing its
# arguments (die "must run as root"), so no usage text is reachable from an
# unprivileged run: these four can only pass as root, and skip otherwise.
if [ "$(id -u)" -eq 0 ]; then
  # --- U1: no subcommand prints usage and exits 2
  O=$(run_up)
  assert_has "U1  usage shown with no subcommand" "$O" "Usage:"
  assert_rc  "U1  exit 2 on no subcommand" "$(rc)" 2 "$O"

  # --- U2/U3/U6: missing version argument
  O=$(run_up stage);    assert_has "U2  stage requires a version" "$O" "usage: cc-update.sh stage <version>"
  O=$(run_up apply);    assert_has "U3  apply requires a version" "$O" "usage: cc-update.sh apply <version>"
  O=$(run_up rollback); assert_has "U6  rollback requires a version" "$O" "usage: cc-update.sh rollback <version>"
else
  skip "U1/U2/U3/U6 usage tests (cc-update.sh refuses non-root before parsing args)"
fi

# --- U5: dnf query failure must NOT read as "nothing available"  (regression test)
if command -v dnf >/dev/null 2>&1; then
  skip "U5 dnf-absent regression (dnf IS present here - run on a disposable host with a broken repo)"
else
  O=$(run_up check)
  assert_has  "U5  dnf failure reported as QUERY FAILED" "$O" "QUERY FAILED"
  assert_lacks "U5  does NOT claim nothing is available" "$O" "none newer than installed"
  assert_rc   "U5  non-zero exit on failed query" "$(rc)" 1 "$O"
fi

# --- U4: must refuse to run as non-root
if [ "$(id -u)" -eq 0 ] && command -v runuser >/dev/null 2>&1 && id nobody >/dev/null 2>&1; then
  mkdir -p "$WORK/nrlog"; chmod 777 "$WORK/nrlog"
  O="$WORK/u4.out"
  runuser -u nobody -- env CC_ETC="$WORK/upetc" CC_LOG="$WORK/nrlog/u.log" \
    bash "$SCRIPTS/cc-update.sh" check >"$O" 2>&1
  U4_RC=$?
  CURRENT="$O"
  if grep -q "must run as root" "$O" || [ "$U4_RC" -ne 0 ]; then
    pass "U4  refuses to run as non-root"
  else
    fail "U4  refuses to run as non-root"
  fi
else
  skip "U4 non-root refusal (need root + runuser + nobody)"
fi

# --- U7: apply refuses while sessions are running
skip "U7 apply refuses with live sessions ON A REAL HOST (a real claude process and a real RPM); the DECISION is covered by R7/R8 against a fabricated /proc"
skip "U8 apply / rollback happy path (mutates a package - run on a disposable host)"

# --- R1..R6: the ROLLBACK path, exercised end to end against stubs. A real
# rollback moves a package and is therefore U8's job on a pilot host; what is
# testable here is every DECISION the script makes around that move, which is
# where its failure modes live. CC_DNF_BIN / CC_RPM_BIN / CC_CLAUDE_BIN /
# CC_PGREP_BIN / CC_ALLOW_NONROOT are declared test seams (see the script head).
mk_dnf_stub() {  # mk_dnf_stub <path> [ERE matched against the whole argument list]
  local p="$1" failon="${2:-}"
  cat > "$p" <<EOF
#!/usr/bin/env bash
# Records every invocation; fails only when the argument list matches the ERE it
# was built with. Matching on the WHOLE list, not one token, is what lets a test
# fail 'install claude-code' while letting the versionlock plugin install work.
printf '%s\n' "\$*" >> "\$CC_TEST_DNF_CALLS"
[ -n "${failon}" ] && printf '%s' "\$*" | grep -qE "${failon}" && exit 1
exit 0
EOF
  chmod 755 "$p"
}
RB="$WORK/rb"; mkdir -p "$RB"
mk_dnf_stub "$RB/dnf"
printf '#!/usr/bin/env bash\nprintf %%s 2.1.236\n'            > "$RB/rpm";    chmod 755 "$RB/rpm"
printf '#!/usr/bin/env bash\necho "2.1.228 (Claude Code)"\n'  > "$RB/claude"; chmod 755 "$RB/claude"
printf '#!/usr/bin/env bash\nexit 1\n'                        > "$RB/pgrep";  chmod 755 "$RB/pgrep"
# A deployed policy whose FLOOR is the version we are rolling away from.
printf '{"requiredMinimumVersion":"2.1.236"}\n' > "$WORK/upetc/managed-settings.json"

run_rb() {  # run_rb <args...>
  local out="$WORK/rb.$RANDOM.out"
  : > "$WORK/rb.calls"
  env CC_ETC="$WORK/upetc" CC_LOG="$WORK/up.log" CC_ALLOW_NONROOT=1 \
      CC_DNF_BIN="$RB/dnf" CC_RPM_BIN="$RB/rpm" CC_CLAUDE_BIN="$RB/claude" \
      CC_PGREP_BIN="$RB/pgrep" CC_TEST_DNF_CALLS="$WORK/rb.calls" \
      bash "$SCRIPTS/cc-update.sh" "$@" >"$out" 2>&1
  echo $? > "$WORK/rc"
  echo "$out"
}

# R1: rolling BELOW the policy floor is the trap the whole procedure exists to
# avoid - requiredMinimumVersion above the installed binary means every session
# on the host refuses to start. Refuse, and name the order that works.
O=$(run_rb rollback 2.1.228)
assert_rc  "R1  rollback below the policy floor is refused" "$(rc)" 1 "$O"
assert_has "R1  the floor is named" "$O" "2.1.236"
assert_has "R1  the working order is given" "$O" "policy"
CURRENT="$O"
if grep -q "downgrade" "$WORK/rb.calls"; then fail "R1  no package transaction attempted"
else pass "R1  no package transaction attempted"; fi

# R2: --force is the deliberate override, for the operator who has already
# lowered the floor or accepts the consequence.
O=$(run_rb rollback 2.1.228 --force)
assert_rc  "R2  --force proceeds" "$(rc)" 0 "$O"
assert_has "R2  the override is recorded, not silent" "$O" "force"

# R3: at or above the floor, the happy path - unlock, downgrade, re-lock,
# record, smoke test.
O=$(run_rb rollback 2.1.236)
assert_rc  "R3  rollback at the floor exits 0" "$(rc)" 0 "$O"
CURRENT="$O"
grep -q "versionlock delete" "$WORK/rb.calls" && pass "R3  lock released" || fail "R3  lock released"
grep -q "downgrade claude-code-2.1.236" "$WORK/rb.calls" && pass "R3  downgrade requested" || fail "R3  downgrade requested"
grep -q "versionlock add claude-code-2.1.236" "$WORK/rb.calls" && pass "R3  lock re-applied at the target" || fail "R3  lock re-applied at the target"
assert_has "R3  smoke test ran" "$O" "smoke test"
if [ "$(tr -d '[:space:]' < "$WORK/upetc/approved-version")" = "2.1.236" ]; then
  pass "R3  approved-version recorded"
else fail "R3  approved-version recorded"; fi

# R4: a rollback that cannot move the package must leave it LOCKED. Without
# this the host ends an emergency unlocked, and the next routine 'dnf upgrade'
# moves Claude Code with nobody watching. Both transaction shapes have to fail
# for this branch to be reached: 'downgrade' is tried first and 'install' is the
# documented fallback for when the target is not a downgrade at all.
mk_dnf_stub "$RB/dnf" '(downgrade|install) claude-code'
O=$(run_rb rollback 2.1.240)
assert_rc  "R4  failed rollback exits 1" "$(rc)" 1 "$O"
CURRENT="$O"
if grep -q "versionlock add claude-code-2.1.236" "$WORK/rb.calls"; then
  pass "R4  the lock is restored at the version still installed" 
else fail "R4  the lock is restored at the version still installed"; fi
if grep -q "versionlock add claude-code-2.1.240" "$WORK/rb.calls"; then
  fail "R4  and NOT at the version that failed to install"
else pass "R4  and NOT at the version that failed to install"; fi
mk_dnf_stub "$RB/dnf"

# R5: a binary that does not run after the rollback is a hard failure, not a
# line in the log - the same contract apply already has.
printf '#!/usr/bin/env bash\nexit 127\n' > "$RB/claude"; chmod 755 "$RB/claude"
O=$(run_rb rollback 2.1.236)
assert_rc  "R5  a dead binary after rollback exits 1" "$(rc)" 1 "$O"
assert_has "R5  and says so" "$O" "does not run"
printf '#!/usr/bin/env bash\necho "2.1.228 (Claude Code)"\n' > "$RB/claude"; chmod 755 "$RB/claude"


# --- R7/R8: WHO is running the managed binary. The question is which processes
# have THIS FILE as their executable - not which processes are named "claude".
# A process name answers it wrongly in both directions: a claude-admin session is
# a runuser child and easy to miss when hunting for a tab, and `claude-local` is a
# different binary that an RPM transaction cannot disturb. Fabricate a /proc.
mk_proc() {  # mk_proc <procdir> <pid> <exe target> <parent cmdline>
  local pr="$1" pid="$2" exe="$3" pcmd="$4"
  local ppid=$((pid + 1))
  mkdir -p "$pr/$pid" "$pr/$ppid"
  ln -sfn "$exe" "$pr/$pid/exe"
  printf 'PPid:\t%s\n' "$ppid" > "$pr/$pid/status"
  printf '%s' "$pcmd" | tr ' ' '\0' > "$pr/$ppid/cmdline"
}
PR="$WORK/fakeproc"; mkdir -p "$PR"
: > "$RB/managed-claude"; : > "$RB/private-claude"
mk_proc "$PR" 4001 "$RB/managed-claude" "runuser -u someone -- env HOME=/users/someone $RB/managed-claude"
mk_proc "$PR" 4003 "$RB/private-claude" "-bash"

run_rb_proc() {  # run_rb_proc <args...> - as run_rb, but against the fake /proc
  local out="$WORK/rb.$RANDOM.out"
  : > "$WORK/rb.calls"
  env CC_ETC="$WORK/upetc" CC_LOG="$WORK/up.log" CC_ALLOW_NONROOT=1 \
      CC_DNF_BIN="$RB/dnf" CC_RPM_BIN="$RB/rpm" CC_CLAUDE_BIN="$RB/managed-claude" \
      CC_PROC="$PR" CC_TEST_DNF_CALLS="$WORK/rb.calls" \
      bash "$SCRIPTS/cc-update.sh" "$@" >"$out" 2>&1
  echo $? > "$WORK/rc"
  echo "$out"
}

O=$(run_rb_proc sessions)
assert_rc  "R7  sessions exits 1 when the managed binary is in use" "$(rc)" 1 "$O"
assert_has "R7  the blocking pid is named"        "$O" "4001"
assert_has "R7  an admin session is called out"   "$O" "claude-admin session"
assert_lacks "R7  a DIFFERENT binary is not counted" "$O" "4003"

O=$(run_rb_proc apply 2.1.240)
assert_rc  "R8  apply refuses while the binary is in use" "$(rc)" 1 "$O"
assert_has "R8  and says why"                     "$O" "sessions are running"
CURRENT="$O"
if grep -q "install claude-code" "$WORK/rb.calls"; then
  fail "R8  no package transaction was attempted"
else pass "R8  no package transaction was attempted"; fi

rm -rf "$PR"; mkdir -p "$PR"          # nobody home: the other direction
O=$(run_rb_proc sessions)
assert_rc  "R8b sessions exits 0 on a clear host" "$(rc)" 0 "$O"
assert_has "R8b and says whose view it is"        "$O" "no session is running the managed binary"

# --- R6: rollback is an emergency, so live sessions WARN rather than block
# (apply blocks - R8). The operator still has to be told whose session breaks.
mk_proc "$PR" 4001 "$RB/managed-claude" "runuser -u someone -- env HOME=/users/someone $RB/managed-claude"
printf '{"requiredMinimumVersion":"2.1.236"}\n' > "$WORK/upetc/managed-settings.json"
printf '#!/usr/bin/env bash\necho "2.1.236 (Claude Code)"\n' > "$RB/managed-claude"
chmod 755 "$RB/managed-claude"
O=$(run_rb_proc rollback 2.1.236)
assert_rc  "R6  live sessions do not block an emergency rollback" "$(rc)" 0 "$O"
assert_has "R6  but they are reported" "$O" "will break at the swap"

# --- UD: apply and rollback around the move itself. Stubs as R1-R8; the
# installed version is 2.1.236 unless a case says otherwise.
rm -rf "$PR"; mkdir -p "$PR"
mk_dnf_stub "$RB/dnf"
printf '{"requiredMinimumVersion":"2.1.236"}\n' > "$WORK/upetc/managed-settings.json"
printf '#!/usr/bin/env bash\necho "2.1.240 (Claude Code)"\n' > "$RB/claude"; chmod 755 "$RB/claude"
ud_calls() { CURRENT="$WORK/rb.calls"; if grep -qE "$2" "$WORK/rb.calls"; then fail "$1"; else pass "$1"; fi; }

# UD1: apply moves forward only. A lower version is a rollback, which has
# the floor guard; apply had none and downgraded without a check.
O=$(run_rb apply 2.1.228)
assert_rc  "UD1 apply to a version below the installed one is refused" "$(rc)" 1 "$O"
assert_has "UD1 and points at rollback" "$O" "cc-update.sh rollback 2.1.228"
ud_calls   "UD1 and no package transaction is attempted" "install claude-code|downgrade"

# UD2: with nothing installed to compare against, the floor still holds.
printf '#!/usr/bin/env bash\necho "package claude-code is not installed"\nexit 1\n' > "$RB/rpm-none"; chmod 755 "$RB/rpm-none"
O="$WORK/ud2.out"; : > "$WORK/rb.calls"
env CC_ETC="$WORK/upetc" CC_LOG="$WORK/up.log" CC_ALLOW_NONROOT=1 CC_DNF_BIN="$RB/dnf" CC_RPM_BIN="$RB/rpm-none" \
    CC_CLAUDE_BIN="$RB/claude" CC_PROC="$PR" CC_TEST_DNF_CALLS="$WORK/rb.calls" \
    bash "$SCRIPTS/cc-update.sh" apply 2.1.230 > "$O" 2>&1; echo $? > "$WORK/rc"
assert_rc  "UD2 apply below the deployed policy floor is refused" "$(rc)" 1 "$O"
assert_has "UD2 and names the floor" "$O" "below the deployed policy floor 2.1.236"
ud_calls   "UD2 and no package transaction is attempted" "install claude-code"

# UD3: a host left unlocked is a failure, not a warning - the next routine
# dnf upgrade moves Claude Code with nobody watching.
printf '2.1.236\n' > "$WORK/upetc/approved-version"
mk_dnf_stub "$RB/dnf" 'versionlock add claude-code-2.1.240'
O=$(run_rb apply 2.1.240)
assert_rc  "UD3 apply whose versionlock fails exits 1" "$(rc)" 1 "$O"
assert_has "UD3 and says the package is unlocked" "$O" "NOT locked"
mk_dnf_stub "$RB/dnf" 'versionlock add claude-code-2.1.236'
O=$(run_rb rollback 2.1.236)
assert_rc  "UD3 rollback whose versionlock fails exits 1" "$(rc)" 1 "$O"
mk_dnf_stub "$RB/dnf"

# UD4: approved-version names a version that was proven to run. It was
# written before the smoke test, so a dead binary became the approved one.
printf '2.1.236\n' > "$WORK/upetc/approved-version"
printf '#!/usr/bin/env bash\nexit 127\n' > "$RB/claude"; chmod 755 "$RB/claude"
O=$(run_rb apply 2.1.240)
assert_rc  "UD4 a dead binary after apply exits 1" "$(rc)" 1 "$O"
if [ "$(tr -d '[:space:]' < "$WORK/upetc/approved-version")" = "2.1.236" ]; then
  pass "UD4 and approved-version still names the last version that ran"
else CURRENT="$O"; fail "UD4 and approved-version still names the last version that ran"; fi
printf '2.1.240\n' > "$WORK/upetc/approved-version"
O=$(run_rb rollback 2.1.236)
if [ "$(tr -d '[:space:]' < "$WORK/upetc/approved-version")" = "2.1.240" ]; then
  pass "UD4 a dead binary after rollback is not recorded as approved either"
else CURRENT="$O"; fail "UD4 a dead binary after rollback is not recorded as approved either"; fi
printf '#!/usr/bin/env bash\necho "2.1.240 (Claude Code)"\n' > "$RB/claude"; chmod 755 "$RB/claude"

# UD5: a policy whose floor cannot be read is not a policy with no floor.
printf '{"requiredMinimumVersion": "2.1.236",\n' > "$WORK/upetc/managed-settings.json"
O=$(run_rb rollback 2.1.228)
assert_rc  "UD5 rollback refuses when the deployed floor cannot be read" "$(rc)" 1 "$O"
assert_has "UD5 and says so" "$O" "cannot read the floor"
ud_calls   "UD5 and no package transaction is attempted" "downgrade|install claude-code"
O=$(run_rb rollback 2.1.228 --force)
assert_rc  "UD5 --force still proceeds" "$(rc)" 0 "$O"
printf '{"requiredMinimumVersion":"2.1.236"}\n' > "$WORK/upetc/managed-settings.json"

# UD6: a refused apply changes nothing - not even the versionlock plugin.
mk_dnf_stub "$RB/dnf" 'versionlock --help'
mk_proc "$PR" 4001 "$RB/managed-claude" "-bash"
printf '#!/usr/bin/env bash\necho "2.1.236 (Claude Code)"\n' > "$RB/managed-claude"; chmod 755 "$RB/managed-claude"
O=$(run_rb_proc apply 2.1.240)
assert_rc  "UD6 apply with live sessions is refused" "$(rc)" 1 "$O"
ud_calls   "UD6 and installs nothing first, not even the versionlock plugin" "install"
rm -rf "$PR"; mkdir -p "$PR"; mk_dnf_stub "$RB/dnf"

# UD7: read-only subcommands create nothing.
O="$WORK/ud7.out"
env CC_ETC="$WORK/ud7-etc" CC_LOG="$WORK/ud7-log/u.log" CC_ALLOW_NONROOT=1 CC_DNF_BIN="$RB/dnf" CC_RPM_BIN="$RB/rpm" \
    CC_CLAUDE_BIN="$RB/claude" CC_PROC="$PR" CC_TEST_DNF_CALLS="$WORK/rb.calls" \
    bash "$SCRIPTS/cc-update.sh" sessions > "$O" 2>&1
CURRENT="$O"
if [ -e "$WORK/ud7-etc" ] || [ -e "$WORK/ud7-log" ]; then fail "UD7 sessions creates no directory"
else pass "UD7 sessions creates no directory"; fi

# UD8: a version is digits and dots; anything else never reaches dnf.
O=$(run_rb apply '2.1.240 --nogpgcheck')
assert_rc  "UD8 a version that is not digits and dots is refused" "$(rc)" 2 "$O"
ud_calls   "UD8 and never reaches dnf" "install claude-code"

# ================================================================ cc-config
head2 "lib/cc-config.sh"

# The loader has no defaults: it loads one config and refuses an incomplete
# one, naming what is missing. Each case sources it in a clean shell (env -i),
# so nothing exported by the suite leaks in except what the case passes.
LDR="$SCRIPTS/../lib/cc-config.sh"
TMPL="$SCRIPTS/../config.example.sh"
ld() {  # ld <out> <VAR=val>... -- <bash snippet run after sourcing>
  local out="$1"; shift; local envs=()
  while [ "$1" != "--" ]; do envs+=("$1"); shift; done; shift
  env -i PATH="$PATH" "${envs[@]}" bash -c ". \"$LDR\" || exit 9; $1" >"$out" 2>&1
  echo $? > "$WORK/rc"
}
O="$WORK/ld1.out"; ld "$O" CC_CONFIG="$TMPL" -- 'echo "src=$CC_CONFIG_SOURCE sbin=$CC_SBIN"'
assert_rc  "LC1 the template loads" "$(rc)" 0 "$O"
assert_has "LC1 and its values are the ones used" "$O" "sbin=/usr/local/sbin"

LCF="$WORK/ld-partial.sh"; grep -v '^CC_HOME_ROOT=' "$TMPL" > "$LCF"
O="$WORK/ld2.out"; ld "$O" CC_CONFIG="$LCF" -- 'echo loaded'
assert_rc    "LC2 a config missing a required key is refused" "$(rc)" 9 "$O"
assert_has   "LC2 and the refusal names the key" "$O" "does not set: CC_HOME_ROOT"
assert_lacks "LC2 and nothing ran on the partial config" "$O" "loaded"

LCF="$WORK/ld-emptyreq.sh"; sed 's#^CC_LOGDIR=.*#CC_LOGDIR=""#' "$TMPL" > "$LCF"
O="$WORK/ld3.out"; ld "$O" CC_CONFIG="$LCF" -- 'echo loaded'
assert_has "LC3 a required key set EMPTY is refused too" "$O" "does not set: CC_LOGDIR"

LCF="$WORK/ld-emptyopt.sh"; sed 's#^CC_METRICS_FILE=.*#CC_METRICS_FILE=""#' "$TMPL" > "$LCF"
O="$WORK/ld4.out"; ld "$O" CC_CONFIG="$LCF" -- 'echo "loaded m=[$CC_METRICS_FILE]"'
assert_has "LC4 an optional key may be empty" "$O" "loaded m=[]"
LCF="$WORK/ld-noopt.sh"; grep -v '^CC_METRICS_FILE=' "$TMPL" > "$LCF"
O="$WORK/ld4b.out"; ld "$O" CC_CONFIG="$LCF" -- 'echo loaded'
assert_has "LC4b but it must be present" "$O" "does not set: CC_METRICS_FILE"

O="$WORK/ld5.out"; ld "$O" CC_CONFIG="$TMPL" CC_LOGDIR=/tmp/elsewhere -- 'echo "log=$CC_LOGDIR adm=$CC_ADMIN_LOG ov=[$CC_CONFIG_OVERRIDES]"'
assert_has "LC5 an exported value wins over the file for that run" "$O" "log=/tmp/elsewhere adm=/tmp/elsewhere/admin.log"
assert_has "LC5 and the override is listed" "$O" "ov=[CC_LOGDIR]"

# config.sh sits in a group-writable checkout, is never reviewed, and root
# loads it (--apply, every timer, the installed copy every hook reads). So it is
# DATA, parsed, never sourced: a line that would run anything is refused, and
# what it would have run never runs.
LCF="$WORK/ld-cmdsub.sh"; { cat "$TMPL"; printf 'CC_SITE_NAME="x$(touch %s/ld-pwned1)"\n' "$WORK"; } > "$LCF"
O="$WORK/ld8.out"; ld "$O" CC_CONFIG="$LCF" -- 'echo loaded'
assert_rc  "LC8 a command substitution in a value is refused" "$(rc)" 9 "$O"
assert_rc  "LC8 and it never ran" "$([ -e "$WORK/ld-pwned1" ] && echo 1 || echo 0)" 0 "$O"
assert_has "LC8 and the refusal names the line" "$O" "ld-cmdsub.sh:"
LCF="$WORK/ld-cmd.sh"; { cat "$TMPL"; printf 'touch %s/ld-pwned2\n' "$WORK"; } > "$LCF"
O="$WORK/ld9.out"; ld "$O" CC_CONFIG="$LCF" -- 'echo loaded'
assert_rc  "LC9 a bare command line is refused" "$(rc)" 9 "$O"
assert_rc  "LC9 and it never ran" "$([ -e "$WORK/ld-pwned2" ] && echo 1 || echo 0)" 0 "$O"
LCF="$WORK/ld-bt.sh"; { cat "$TMPL"; printf 'CC_SITE_NAME=`touch %s/ld-pwned3`\n' "$WORK"; } > "$LCF"
O="$WORK/ld9b.out"; ld "$O" CC_CONFIG="$LCF" -- 'echo loaded'
assert_rc  "LC9b a backtick value is refused and never ran" "$(rc)$([ -e "$WORK/ld-pwned3" ] && echo 1 || echo 0)" 90 "$O"
LCF="$WORK/ld-arr.sh"; { cat "$TMPL"; printf 'CC_ADMIN_USERS=("a" b $(touch %s/ld-pwned4))\n' "$WORK"; } > "$LCF"
O="$WORK/ld9c.out"; ld "$O" CC_CONFIG="$LCF" -- 'echo loaded'
assert_rc  "LC9c a command inside the admin-users array is refused and never ran" "$(rc)$([ -e "$WORK/ld-pwned4" ] && echo 1 || echo 0)" 90 "$O"
LCF="$WORK/ld-unk.sh"; { cat "$TMPL"; printf 'CC_SBNI="/tmp"\n'; } > "$LCF"
O="$WORK/ld10.out"; ld "$O" CC_CONFIG="$LCF" -- 'echo loaded'
assert_rc  "LC10 an unknown key (a typo) is refused, not ignored" "$(rc)" 9 "$O"
assert_has "LC10 and the refusal names it" "$O" "CC_SBNI"
LCF="$WORK/ld-forms.sh"; { cat "$TMPL"
  printf "CC_SITE_NAME='single quoted # not a comment'\n"
  printf 'CC_REPORT_KEEP=12   # trailing comment\n'
  printf '  CC_ADMIN_USERS=("one" two '"'"'three'"'"')\n'
  printf 'CC_FLEET_HOSTS="h1 h2"\n'; } > "$LCF"
O="$WORK/ld11.out"; ld "$O" CC_CONFIG="$LCF" -- 'echo "n=[$CC_SITE_NAME] k=[$CC_REPORT_KEEP] u=[${CC_ADMIN_USERS[*]}] c=${#CC_ADMIN_USERS[@]} f=[$CC_FLEET_HOSTS]"'
assert_has "LC11 the plain data forms load as the shell would read them" "$O" "n=[single quoted # not a comment] k=[12] u=[one two three] c=3 f=[h1 h2]"
LCF="$WORK/ld-empty-arr.sh"; { cat "$TMPL"; printf 'CC_ADMIN_USERS=()\n'; } > "$LCF"
O="$WORK/ld12.out"; ld "$O" CC_CONFIG="$LCF" -- 'echo "c=${#CC_ADMIN_USERS[@]}"'
assert_has "LC12 an empty admin-users array is still set" "$O" "c=0"
O="$WORK/ld12b.out"; ld "$O" CC_CONFIG="$TMPL" -- 'echo "c=${#CC_ADMIN_USERS[@]} g=[$CC_ADMIN_GROUP]"'
assert_has "LC12b the template names no admin user - a new site fails closed until it names one" "$O" "c=0 g=[cc-admins]"

LCR="$WORK/ld-checkout"; mkdir -p "$LCR/lib" "$LCR/bin" "$LCR/settings"
cp "$LDR" "$LCR/lib/"; cp "$TMPL" "$LCR/"
O="$WORK/ld6.out"
env -i PATH="$PATH" bash -c ". \"$LCR/lib/cc-config.sh\" || exit 9; echo \"src=\$CC_CONFIG_SOURCE\"" >"$O" 2>&1
if [ -r /etc/claude-code/config.sh ]; then
  skip "LC6 checkout fallback (an installed /etc/claude-code/config.sh is found first here)"
else
  assert_has "LC6 a checkout with no config.sh runs on the sample, and says so" "$O" "sample values"
  rm "$LCR/config.example.sh"
  env -i PATH="$PATH" bash -c ". \"$LCR/lib/cc-config.sh\" || exit 9; echo loaded" >"$O" 2>&1
  echo $? > "$WORK/rc"
  assert_rc  "LC7 no config anywhere is refused" "$(rc)" 9 "$O"
  assert_has "LC7 and says where it looked" "$O" "no config.sh found"
fi

# ================================================================ cc-ci-check
head2 "cc-ci-check.sh"

REPOROOT="$SCRIPTS/.."

# cc-ci-check.sh runs against whatever git checkout it starts in, and honours
# CC_CI_ONLY=<n[,n]> to run a single check. A scratch repo holding just the
# files one check reads therefore lets that check be exercised in isolation,
# without staging the whole deployment.
mk_ci_repo() {  # mk_ci_repo <dir> <requiredMinimumVersion or ""> - both policies, as the tree has
  local dir="$1" ver="$2" f
  mkdir -p "$dir/settings" "$dir/docs"
  git -C "$dir" init -q
  for f in managed-settings.json managed-settings-admin.json; do
    if [ -n "$ver" ]; then
      printf '{"requiredMinimumVersion": "%s"}\n' "$ver" > "$dir/settings/$f"
    else
      printf '{}\n' > "$dir/settings/$f"
    fi
  done
}

run_ci9() {  # run_ci9 <scratch repo dir>
  local out="$WORK/ci9.$RANDOM.out"
  ( cd "$1" && CC_CI_ONLY=9 bash "$REPOROOT/bin/cc-ci-check.sh" ) >"$out" 2>&1
  echo $? > "$WORK/rc"
  echo "$out"
}

# --- C1: a version pin with no UPGRADES.md at all is a red build
R="$WORK/ci9a"; mk_ci_repo "$R" "2.1.200"
O=$(run_ci9 "$R")
assert_has "C1  pin without docs/UPGRADES.md fails" "$O" "docs/UPGRADES.md does not exist"
assert_rc  "C1  exit 1 when the record is missing" "$(rc)" 1 "$O"

# --- C2: UPGRADES.md present but with no entry for the pinned version
R="$WORK/ci9b"; mk_ci_repo "$R" "2.1.200"
printf '# log\n\n## 2.1.199 — earlier\n' > "$R/docs/UPGRADES.md"
O=$(run_ci9 "$R")
assert_has "C2  missing entry for the pin fails" "$O" "no entry for 2.1.200 -"
assert_rc  "C2  exit 1 when the entry is missing" "$(rc)" 1 "$O"

# --- C3: entry present -> green
printf '\n## 2.1.200 — pinned\n' >> "$R/docs/UPGRADES.md"
O=$(run_ci9 "$R")
assert_has "C3  entry for the pin passes" "$O" "an entry for the pinned 2.1.200"
assert_rc  "C3  exit 0 with the entry present" "$(rc)" 0 "$O"
assert_lacks "C6  CC_CI_ONLY=9 skipped the other checks" "$O" "[1] Secret guard"
assert_has   "C6b a partial run says it is partial" "$O" "PARTIAL run"

# --- C23/C24: the admin policy carries the same floor. A pin moved in
# one policy only, or dropped from it, is a floor nothing recorded.
cp -r "$R" "$WORK/ci9adm"; R9="$WORK/ci9adm"
printf '{"requiredMinimumVersion": "2.1.199"}\n' > "$R9/settings/managed-settings-admin.json"
O=$(run_ci9 "$R9")
assert_has "C23 an admin pin that differs from the fleet pin fails" "$O" "settings/managed-settings-admin.json pins 2.1.199 but settings/managed-settings.json pins 2.1.200"
assert_rc  "C23 exit 1" "$(rc)" 1 "$O"
printf '{}\n' > "$R9/settings/managed-settings-admin.json"
O=$(run_ci9 "$R9")
assert_has "C24 an admin policy with no pin fails" "$O" "settings/managed-settings-admin.json has no requiredMinimumVersion"
printf '{"requiredMinimumVersion": \n' > "$R9/settings/managed-settings.json"
printf '{"requiredMinimumVersion": "2.1.200"}\n' > "$R9/settings/managed-settings-admin.json"
O=$(run_ci9 "$R9")
assert_has "C25 an unreadable fleet policy fails, not passes as unpinned" "$O" "settings/managed-settings.json could not be read"
assert_rc  "C25 exit 1" "$(rc)" 1 "$O"

# --- C4: version match must not cross number boundaries (2.1.20 vs 2.1.200)
R="$WORK/ci9c"; mk_ci_repo "$R" "2.1.20"
printf '## 2.1.200 — a different version\n' > "$R/docs/UPGRADES.md"
O=$(run_ci9 "$R")
assert_has "C4  a 2.1.200 entry does not satisfy a 2.1.20 pin" "$O" "no entry for 2.1.20 -"

# --- C5: no pin is not "nothing to anchor" - the version floor is a
# control, and removing it is the one bump the record would otherwise miss
R="$WORK/ci9d"; mk_ci_repo "$R" ""
O=$(run_ci9 "$R")
assert_rc    "C5  no pin in the fleet policy fails" "$(rc)" 1 "$O"
assert_has   "C5  and says which policy" "$O" "settings/managed-settings.json has no requiredMinimumVersion"

# --- C7: the entry heading must START with the version - a heading for another
# version that merely mentions the pin must not satisfy the check
R="$WORK/ci9e"; mk_ci_repo "$R" "2.1.200"
printf '## 2.1.300 — supersedes 2.1.200\n' > "$R/docs/UPGRADES.md"
O=$(run_ci9 "$R")
assert_has "C7  a mention inside another entry heading does not count" "$O" "no entry for 2.1.200 -"

# --- C9-C11: check [7] holds the loader's key lists and the template together
mk_ci7() {  # mk_ci7 <dir> - a scratch repo with the real loader and template
  mk_ci_repo "$1" ""; mkdir -p "$1/lib" "$1/bin"
  cp "$REPOROOT/lib/cc-config.sh" "$1/lib/"; cp "$REPOROOT/config.example.sh" "$1/"
  mkdir -p "$1/docs"; cp "$REPOROOT/docs/QUICKSTART.md" "$1/docs/"
}
run_ci7() { local out="$WORK/ci7.$RANDOM.out"
  ( cd "$1" && CC_CI_ONLY=7 bash "$REPOROOT/bin/cc-ci-check.sh" ) >"$out" 2>&1
  echo $? > "$WORK/rc"; echo "$out"; }
R="$WORK/ci7a"; mk_ci7 "$R"
O=$(run_ci7 "$R")
assert_rc  "C9  the real loader and template agree" "$(rc)" 0 "$O"
R="$WORK/ci7b"; mk_ci7 "$R"; sed -i '/^CC_HOME_ROOT=/d' "$R/config.example.sh"
O=$(run_ci7 "$R")
assert_has "C10 a required key missing from the template fails" "$O" "CC_HOME_ROOT is required by lib/cc-config.sh but has no line"
R="$WORK/ci7c"; mk_ci7 "$R"; printf 'CC_UNLISTED_KEY="x"\n' >> "$R/config.example.sh"
O=$(run_ci7 "$R")
assert_has "C11 a template key the loader does not list fails" "$O" "CC_UNLISTED_KEY is set in config.example.sh but lib/cc-config.sh does not list it"
R="$WORK/ci7d"; mk_ci7 "$R"; sed -i 's/^# --- the keys/: "${CC_SBIN:=\/usr\/local\/sbin}"\n&/' "$R/lib/cc-config.sh"
O=$(run_ci7 "$R")
assert_has "C11b a default spelled in the loader fails" "$O" "spells a default"

# --- C12-C18: check [11] finds a site value spelled in code. Each case is one
# fault injected into a scratch repo holding the real loader and template; C12
# is the clean control, so a check that flags everything cannot pass the set.
mk_ci11() {  # mk_ci11 <dir> <file> <line> - a scratch repo whose one script holds <line>
  mk_ci7 "$1"; mkdir -p "$1/$(dirname "$2")"
  printf '#!/usr/bin/env bash\n%s\n' "$3" > "$1/$2"
  git -C "$1" add -A >/dev/null 2>&1
}
run_ci11() { local out="$WORK/ci11.$RANDOM.out"
  ( cd "$1" && CC_CI_ONLY=11 bash "$REPOROOT/bin/cc-ci-check.sh" ) >"$out" 2>&1
  echo $? > "$WORK/rc"; echo "$out"; }
# The group is read from the template the fixture holds, so the cases follow
# whatever value a site's template carries.
CI11_GRP=$(. "$REPOROOT/config.example.sh" >/dev/null 2>&1; printf '%s' "$CC_REPO_GROUP")
R="$WORK/ci11a"; mk_ci11 "$R" bin/cc-x.sh 'rpm -q "$CC_PKG"; chgrp "$CC_REPO_GROUP" f; x='"${CI11_GRP}_old"
O=$(run_ci11 "$R")
assert_rc  "C12 code that reads every value from config passes" "$(rc)" 0 "$O"
R="$WORK/ci11b"; mk_ci11 "$R" bin/cc-x.sh 'rpm -q claude-code'
O=$(run_ci11 "$R")
assert_has "C13 a package name spelled in a script fails" "$O" 'bin/cc-x.sh:2: spells CC_PKG="claude-code"'
R="$WORK/ci11c"; mk_ci11 "$R" hooks/cc-x-hook.sh 'LOGDIR="${CC_LOGDIR:-/srv/logs}"'
O=$(run_ci11 "$R")
assert_has "C14 a default on a config key fails, whatever the value" "$O" "CC_LOGDIR is given a default (/srv/logs)"
R="$WORK/ci11d"; mk_ci11 "$R" .github/workflows/w.yml 'base = "https://downloads.claude.ai/claude-code/rpm/stable"'
O=$(run_ci11 "$R")
assert_has "C15 a vendor URL spelled in a workflow fails" "$O" "spells CC_RPM_BASEURL="
R="$WORK/ci11e"; mk_ci11 "$R" bin/cc-x.sh "chgrp $CI11_GRP f"
O=$(run_ci11 "$R")
assert_has "C16 a short value matches as a whole word" "$O" "spells CC_REPO_GROUP=\"$CI11_GRP\""
R="$WORK/ci11f"; mk_ci11 "$R" bin/cc-x.sh '# the RPM is claude-code, from /etc/claude-code
. /etc/claude-code/cc-config.sh || exit 1'
O=$(run_ci11 "$R")
assert_rc  "C17 a value in a comment, and the loader's own path, pass" "$(rc)" 0 "$O"
R="$WORK/ci11g"; mk_ci11 "$R" bin/cc-ci-check.sh 'ALLOW = [
    ("x", "claude-code", "reason"),
]
rpm -q claude-code'
O=$(run_ci11 "$R")
assert_has "C18 the exception list exempts itself and nothing after it" "$O" "bin/cc-ci-check.sh:5: spells CC_PKG="

# --- C19-C22: the readable key reference, and doc commands. The QUICKSTART
# table must have one row per key showing the template's value (check [7]); a
# sudo line in a doc code block must use the key, while a diagram may not (C22).
R="$WORK/ci7t1"; mk_ci7 "$R"; sed -i '/^| `CC_REPORT_KEEP`/d' "$R/docs/QUICKSTART.md"
O=$(run_ci7 "$R")
assert_has "C19 a key with no row in the QUICKSTART table fails" "$O" "CC_REPORT_KEEP has no row"
R="$WORK/ci7t2"; mk_ci7 "$R"; sed -i 's#^\(| `CC_LOGDIR` .*\)`/var/log/claude-code`#\1`/srv/log`#' "$R/docs/QUICKSTART.md"
O=$(run_ci7 "$R")
assert_has "C20 a table value that is not the template's fails" "$O" "CC_LOGDIR shows /srv/log but the template sets"
R="$WORK/ci11h"; mk_ci11 "$R" bin/cc-x.sh 'true'
printf '# x\n```bash\nsudo /usr/local/sbin/cc-audit.sh\n```\n' > "$R/docs/X.md"; git -C "$R" add -A >/dev/null 2>&1
O=$(run_ci11 "$R")
assert_has "C21 a sudo command in a doc that spells a path fails" "$O" 'docs/X.md:3: a sudo command spells CC_SBIN='
R="$WORK/ci11i"; mk_ci11 "$R" bin/cc-x.sh 'true'
printf '# x\n```bash\nsudo $CC_SBIN/cc-audit.sh\n  /usr/local/sbin/cc-*.sh  <- the scripts\n```\n' > "$R/docs/X.md"; git -C "$R" add -A >/dev/null 2>&1
O=$(run_ci11 "$R")
assert_rc  "C22 a sudo command using the key, and a reference path, pass" "$(rc)" 0 "$O"

# --- C26: a check whose embedded Python dies has checked nothing, so it
# must not print ok. A python3 that crashes stands in for any crash.
mkdir -p "$WORK/pycrash"
printf '#!/bin/sh\necho "Traceback (most recent call last): injected" >&2\nexit 1\n' > "$WORK/pycrash/python3"
chmod +x "$WORK/pycrash/python3"
R="$WORK/ci26"; mk_ci7 "$R"; printf '[x](docs/QUICKSTART.md)\n' > "$R/README.md"
printf '{"requiredMinimumVersion": "2.1.200"}\n' | tee "$R/settings/managed-settings.json" > "$R/settings/managed-settings-admin.json"
printf '## 2.1.200\n' > "$R/docs/UPGRADES.md"; git -C "$R" add -A >/dev/null 2>&1
git -C "$R" rm -q --cached docs/QUICKSTART.md   # [7] reads it from disk; its links name docs not here
for c in 5 7 9 11; do
  O="$WORK/ci26.$c.out"
  ( cd "$R" && PATH="$WORK/pycrash:$PATH" CC_CI_ONLY=$c bash "$REPOROOT/bin/cc-ci-check.sh" ) >"$O" 2>&1
  echo $? > "$WORK/rc"
  assert_rc "C26 check [$c] fails when its Python crashes" "$(rc)" 1 "$O"
done
# the control: the same repo with a working python3 is green on all four
O="$WORK/ci26.ok.out"
( cd "$R" && CC_CI_ONLY=5,7,9,11 bash "$REPOROOT/bin/cc-ci-check.sh" ) >"$O" 2>&1
echo $? > "$WORK/rc"
assert_rc "C26 control: with python3 working the same checks pass" "$(rc)" 0 "$O"

# --- C27: a doc that is not UTF-8 must not stop [5] before the docs after it
R="$WORK/ci27"; mk_ci_repo "$R" ""
printf '# caf\xe9\n' > "$R/docs/A.md"; printf '[gone](NOPE.md)\n' > "$R/docs/B.md"
git -C "$R" add -A >/dev/null 2>&1
O="$WORK/ci27.out"
( cd "$R" && CC_CI_ONLY=5 bash "$REPOROOT/bin/cc-ci-check.sh" ) >"$O" 2>&1
echo $? > "$WORK/rc"
assert_has "C27 a broken link after a non-UTF-8 doc is still found" "$O" "docs/B.md: broken link -> NOPE.md"
assert_rc  "C27 exit 1" "$(rc)" 1 "$O"

# --- C28-C32: check [13] holds every list of hooks to the Makefile's
# HOOKS: both policies' hooks[], the installer's source gate and placement
# list, and the healthcheck's presence list. A hook missing from any one of
# them is installed-but-unregistered, registered-but-uninstalled, or unwatched.
mk_ci13() {  # mk_ci13 <dir> - a scratch repo with the real hook lists
  mk_ci_repo "$1" ""; mkdir -p "$1/bin"
  cp "$REPOROOT/Makefile" "$1/"; cp "$REPOROOT/settings/"managed-settings*.json "$1/settings/"
  cp "$REPOROOT/bin/cc-install.sh" "$REPOROOT/bin/cc-healthcheck.sh" "$1/bin/"
}
run_ci13() { local out="$WORK/ci13.$RANDOM.out"
  ( cd "$1" && CC_CI_ONLY=13 bash "$REPOROOT/bin/cc-ci-check.sh" ) >"$out" 2>&1
  echo $? > "$WORK/rc"; echo "$out"; }
R="$WORK/ci13a"; mk_ci13 "$R"
O=$(run_ci13 "$R")
assert_rc  "C28 the real Makefile, policies, installer and healthcheck agree" "$(rc)" 0 "$O"
R="$WORK/ci13b"; mk_ci13 "$R"
python3 - "$R/settings/managed-settings-admin.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
for ev in d["hooks"].values():
    for m in ev:
        m["hooks"] = [h for h in m["hooks"] if "cc-denied-hook.sh" not in h["command"]]
json.dump(d, open(sys.argv[1], "w"))
PY
O=$(run_ci13 "$R")
assert_has "C29 a hook dropped from the ADMIN policy fails" "$O" "settings/managed-settings-admin.json hooks[] lacks cc-denied-hook.sh"
R="$WORK/ci13c"; mk_ci13 "$R"
sed -i 's/^for h in cc-audit-hook.sh cc-denied-hook.sh /for h in cc-audit-hook.sh /' "$R/bin/cc-install.sh"
O=$(run_ci13 "$R")
assert_has "C30 a hook dropped from the installer's placement list fails" "$O" "bin/cc-install.sh"
assert_has "C30 and names the hook" "$O" "lacks cc-denied-hook.sh"
R="$WORK/ci13d"; mk_ci13 "$R"
sed -i 's|"$CC_SBIN/cc-denied-hook.sh" ||' "$R/bin/cc-healthcheck.sh"
O=$(run_ci13 "$R")
assert_has "C31 a hook dropped from the healthcheck's list fails" "$O" "bin/cc-healthcheck.sh"
R="$WORK/ci13e"; mk_ci13 "$R"
sed -i 's|^HOOKS  := .*|HOOKS  := hooks/cc-audit-hook.sh|' "$R/Makefile"
O=$(run_ci13 "$R")
assert_has "C32 a Makefile HOOKS short of the policy fails" "$O" "settings/managed-settings.json hooks[] names cc-secret-guard-hook.sh, which the Makefile HOOKS does not install"

# --- C33: a top-level share/*.sh is a script a clone may run
R="$WORK/ci33"; mk_ci_repo "$R" ""; mkdir -p "$R/share"
printf '#!/bin/sh\n' > "$R/share/x.sh"; chmod 644 "$R/share/x.sh"
git -C "$R" add -A >/dev/null 2>&1; git -C "$R" update-index --chmod=-x share/x.sh
O="$WORK/ci33.out"
( cd "$R" && CC_CI_ONLY=3 bash "$REPOROOT/bin/cc-ci-check.sh" ) >"$O" 2>&1
assert_has "C33 a top-level share/*.sh without +x in the index fails" "$O" "share/x.sh is 100644 in the index"

# --- C34/C35: [8] wants the file NAMED, not a longer name containing it
R="$WORK/ci34"; mk_ci_repo "$R" ""; rm -f "$R/settings/"*.json; mkdir -p "$R/bin"
printf '#!/bin/sh\n' > "$R/bin/cc-x.sh"
printf 'see bin/cc-x.sh.old and acc-x.sh\n' > "$R/docs/X.md"
git -C "$R" add -A >/dev/null 2>&1
O="$WORK/ci34.out"
( cd "$R" && CC_CI_ONLY=8 bash "$REPOROOT/bin/cc-ci-check.sh" ) >"$O" 2>&1
assert_has "C34 a longer name containing the file's name is not a mention" "$O" "bin/cc-x.sh is named in no document"
printf 'run `bin/cc-x.sh`. Also cc-x.sh, at the end of a sentence.\n' > "$R/docs/X.md"
( cd "$R" && CC_CI_ONLY=8 bash "$REPOROOT/bin/cc-ci-check.sh" ) >"$O" 2>&1
echo $? > "$WORK/rc"
assert_rc  "C35 control: the name itself, in a path or before a full stop, is a mention" "$(rc)" 0 "$O"

# --- C36: [12] holds the AWS posture unit too
R="$WORK/ci36"; mk_ci7 "$R"; cp "$REPOROOT/lib/cc-coupling.py" "$R/lib/"; mkdir -p "$R/aws/systemd"
printf '[Service]\nExecStart=/opt/elsewhere/cc-apply-posture.sh\n' > "$R/aws/systemd/claude-code-posture.service"
O="$WORK/ci36.out"
( cd "$R" && CC_CI_ONLY=12 bash "$REPOROOT/bin/cc-ci-check.sh" ) >"$O" 2>&1
assert_has "C36 an AWS unit running a script outside CC_SBIN fails" "$O" "aws/systemd/claude-code-posture.service:2: ExecStart runs /opt/elsewhere/cc-apply-posture.sh"

# --- C37-C44: check [14] holds couplings that would otherwise rest on
# discipline. One fixture copies the real files; each case breaks one thing.
mk_ci14() {  # mk_ci14 <dir> - a scratch repo with the real installer, units, maps and skills
  mk_ci_repo "$1" ""; mkdir -p "$1/tests" "$1/.github/workflows" "$1/.claude"
  cp "$REPOROOT/settings/"managed-settings*.json "$1/settings/"
  cp -r "$REPOROOT/bin" "$REPOROOT/systemd" "$1/"; cp -r "$REPOROOT/.claude/skills" "$1/.claude/"
  cp "$REPOROOT/docs/REPO-MAP.md" "$REPOROOT/docs/OPERATIONS.md" "$1/docs/"
  cp "$REPOROOT/tests/README.md" "$1/tests/"; : > "$1/tests/test-cc-scripts.sh"; : > "$1/tests/cc-e2e.sh"
  cp "$REPOROOT/.github/workflows/ci.yml" "$1/.github/workflows/"; cp "$REPOROOT/.gitlab-ci.yml" "$1/"
  git -C "$1" add -A >/dev/null 2>&1
}
run_ci14() { local out="$WORK/ci14.$RANDOM.out"
  git -C "$1" add -A >/dev/null 2>&1
  ( cd "$1" && CC_CI_ONLY=14 bash "$REPOROOT/bin/cc-ci-check.sh" ) >"$out" 2>&1
  echo $? > "$WORK/rc"; echo "$out"; }
R="$WORK/ci14a"; mk_ci14 "$R"
O=$(run_ci14 "$R")
assert_rc  "C37 the real installer, units, scripts, tests map and skills pass [14]" "$(rc)" 0 "$O"
R="$WORK/ci14b"; mk_ci14 "$R"
sed -i 's/^  for t in claude-code-healthcheck.timer claude-code-version-watch.timer claude-code-report.timer; do/  for t in claude-code-healthcheck.timer claude-code-version-watch.timer; do/' "$R/bin/cc-install.sh"
O=$(run_ci14 "$R")
assert_has "C38 a timer placed but missing from the enable loop fails" "$O" "enable --now loop list lacks claude-code-report.timer"
R="$WORK/ci14b2"; mk_ci14 "$R"
sed -i 's/^  act "systemctl daemon-reload && systemctl enable --now /  act "systemctl daemon-reload \&\& systemctl start /' "$R/bin/cc-install.sh"
O=$(run_ci14 "$R")
assert_has "C38 a list the parser no longer sees fails rather than passing as empty" "$O" "holds 0 dry-run enable hint list(s), expected 1"
R="$WORK/ci14c"; mk_ci14 "$R"
printf '[Timer]\nOnCalendar=daily\n' > "$R/systemd/claude-code-new.timer"
O=$(run_ci14 "$R")
assert_has "C39 a new timer the installer never names fails at the source gate" "$O" "source-gate list lacks claude-code-new.timer"
assert_has "C39 and at the enable loop" "$O" "enable --now loop list lacks claude-code-new.timer"
R="$WORK/ci14d"; mk_ci14 "$R"
printf '#!/bin/bash\nawk 1 /proc/self/mountinfo\n' > "$R/bin/cc-new.sh"
O=$(run_ci14 "$R")
assert_has "C40 a sixth script reading the mount table directly fails" "$O" "bin/cc-new.sh reads /proc/self/mountinfo directly, outside the seam"
assert_has "C40 and the REPO-MAP count no longer matches" "$O" "docs/REPO-MAP.md says Five scripts carry the predicate; 6 do"
R="$WORK/ci14e"; mk_ci14 "$R"
PIN14=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["requiredMinimumVersion"])' "$R/settings/managed-settings.json")
printf '# the pin %s, in a comment, may be stated\nV=%s0\n' "$PIN14" "$PIN14" >> "$R/bin/cc-update.sh"
O=$(run_ci14 "$R")
assert_rc  "C41 control: the pin in a comment, and a longer version containing it, pass" "$(rc)" 0 "$O"
printf 'FLOOR=%s\n' "$PIN14" >> "$R/bin/cc-update.sh"
O=$(run_ci14 "$R")
assert_has "C41 a copy of the pin on a code line fails" "$O" "spells the pin $PIN14"
R="$WORK/ci14f"; mk_ci14 "$R"
printf '#!/bin/bash\n' > "$R/tests/test-extra.sh"
O=$(run_ci14 "$R")
assert_has "C42 a test script with no tests/README.md row fails" "$O" "tests/test-extra.sh has no row in tests/README.md"
printf '| `test-extra.sh` | more cases |\n' >> "$R/tests/README.md"
O=$(run_ci14 "$R")
assert_has "C42 and one neither CI config runs must say so" "$O" "tests/test-extra.sh is not run by both CI configs"
R="$WORK/ci14g"; mk_ci14 "$R"
sed -i 's/^## 7\.2 The standing audits/## 7.9 The standing audits/' "$R/docs/OPERATIONS.md"
O=$(run_ci14 "$R")
assert_has "C43 renumbering the Part 7 section a skill cites fails" "$O" "cites OPERATIONS §7.2, which has no '## 7.2' heading"
R="$WORK/ci14h"; mk_ci14 "$R"
sed -i 's/^| `log-review` |/| `logs-review` |/' "$R/docs/OPERATIONS.md"
O=$(run_ci14 "$R")
assert_has "C43 renaming the 7.2 row a skill cites fails" "$O" "cites the \`log-review\` row, which OPERATIONS §7.2 does not have"
O="$WORK/ci44.out"
( cd "$R" && CC_CI_ONLY=99 bash "$REPOROOT/bin/cc-ci-check.sh" ) >"$O" 2>&1
assert_rc  "C44 an unknown check id is a usage error" "$?" 2 "$O"
assert_has "C44 and the valid list is read from the checks themselves, 14 included" "$O" "11 12 13 14)"

# --- CT1-CT8: the template edition (docs/PUBLISHING.md). template.json at the
# root lists the placeholders a site fills; while it exists, [2] accepts those
# and only those, both ways, and [6] shows by difference that the installer
# refuses the unfilled tree and stages a filled copy. Each case differs from a
# passing one by a single change, so the exit code alone names the cause.
# The fixtures name placeholders no real template lists (REPLACE-WITH-FIXTURE-*).
# In a template edition this file is itself filled before it runs, and a real
# name here would arrive already replaced.
run_ci2() { local out="$WORK/ci2.$RANDOM.out"
  git -C "$1" add -A >/dev/null 2>&1
  ( cd "$1" && CC_CI_ONLY=2 bash "$REPOROOT/bin/cc-ci-check.sh" ) >"$out" 2>&1
  echo $? > "$WORK/rc"; echo "$out"; }
R="$WORK/ct1"; mk_ci_repo "$R" ""
printf '{"companyAnnouncements": ["REPLACE-WITH-FIXTURE-ORG managed"]}\n' > "$R/settings/managed-settings.json"
O=$(run_ci2 "$R")
assert_rc  "CT1 without template.json a placeholder in the policy fails, as always" "$(rc)" 1 "$O"
printf '{"placeholders": {"REPLACE-WITH-FIXTURE-ORG": {"meaning": "the organisation", "example": "Example Org"}}}\n' > "$R/template.json"
O=$(run_ci2 "$R")
assert_rc  "CT2 with template.json listing it, the placeholder passes" "$(rc)" 0 "$O"
printf '{"companyAnnouncements": ["REPLACE-WITH-FIXTURE-ORG at REPLACE-WITH-OTHER"]}\n' > "$R/settings/managed-settings.json"
O=$(run_ci2 "$R")
assert_rc  "CT3 a placeholder template.json does not list fails" "$(rc)" 1 "$O"
printf '{"companyAnnouncements": ["REPLACE-WITH-FIXTURE-ORG"]}\n' > "$R/settings/managed-settings.json"
printf '{"placeholders": {"REPLACE-WITH-FIXTURE-ORG": {"meaning": "the organisation", "example": "Example Org"}, "REPLACE-WITH-GONE": {"meaning": "nothing uses it", "example": "gone"}}}\n' > "$R/template.json"
O=$(run_ci2 "$R")
assert_rc  "CT4 a listed placeholder nothing uses fails - the list is closed both ways" "$(rc)" 1 "$O"
printf '{"placeholders": {"REPLACE-WITH-FIXTURE-ORG": {"meaning": "the organisation", "example": "Example Org"}}}\n' > "$R/template.json"
printf '{"companyAnnouncements": ["REPLACE-WITH-FIXTURE-ORG TODO"]}\n' > "$R/settings/managed-settings.json"
O=$(run_ci2 "$R")
assert_rc  "CT5 the other markers still fail in a template" "$(rc)" 1 "$O"
printf '{"placeholders": {}}\n' > "$R/template.json"
printf '{}\n' > "$R/settings/managed-settings.json"
O=$(run_ci2 "$R")
assert_rc  "CT5b a template.json that lists no placeholder fails - a template of nothing is a mistake" "$(rc)" 1 "$O"
# The list is taken out of the policy text before the markers are looked for,
# so a name that is not a whole placeholder would take a marker apart with it.
printf '{"companyAnnouncements": ["REPLACE-WITH-FIXTURE-ORG"]}\n' > "$R/settings/managed-settings.json"
printf '{"placeholders": {"REPLACE-WITH-FIXTURE-ORG": {"meaning": "the organisation", "example": "Example Org"}, "E": {"meaning": "one letter of every marker", "example": "e"}}}\n' > "$R/template.json"
O=$(run_ci2 "$R")
assert_rc  "CT5c a listed name that is not a REPLACE-WITH-* placeholder fails" "$(rc)" 1 "$O"
printf '{"placeholders": {"REPLACE-WITH-FIXTURE-ORG": {"meaning": "the organisation", "example": "Example Org"}}}\n' > "$R/template.json"
printf '{"companyAnnouncements": ["REPLACE-WITH-FIXTURE-ORG and REPLACE-WITH-FIXTURE-ORG2"]}\n' > "$R/settings/managed-settings.json"
O=$(run_ci2 "$R")
assert_rc  "CT5d an unlisted placeholder that begins with a listed one's whole name fails" "$(rc)" 1 "$O"
printf '{"companyAnnouncements": ["REPLACE-WITH-FIXTURE-ORG-managed, by REPLACE-WITH-FIXTURE-ORG."]}\n' > "$R/settings/managed-settings.json"
O=$(run_ci2 "$R")
assert_rc  "CT5e a listed placeholder passes wherever it sits in a value" "$(rc)" 0 "$O"

mk_ci6t() {  # mk_ci6t <dir> - this working tree, as a template with one placeholder to fill
  mkdir -p "$1"; ( cd "$REPOROOT" && git ls-files | grep -v '^internal/' | tar -cf - -T - ) | tar -xf - -C "$1"
  git -C "$1" init -q
  printf '{"placeholders": {"REPLACE-WITH-FIXTURE-USE": {"meaning": "what the fleet is for", "example": "software engineering"}}}\n' > "$1/template.json"
}
run_ci6() { local out="$WORK/ci6.$RANDOM.out"
  git -C "$1" add -A >/dev/null 2>&1
  ( cd "$1" && CC_CI_ONLY=6 bash bin/cc-ci-check.sh ) >"$out" 2>&1
  echo $? > "$WORK/rc"; echo "$out"; }
R="$WORK/ct6"; mk_ci6t "$R"
sed -i 's/Primary use: [^"]*"/Primary use: REPLACE-WITH-FIXTURE-USE"/' "$R/settings/managed-settings.json" "$R/settings/managed-settings-admin.json"
O=$(run_ci6 "$R")
assert_rc  "CT6 a template: the unfilled tree is refused and a filled copy stages - [6] passes" "$(rc)" 0 "$O"
R="$WORK/ct7"; mk_ci6t "$R"
printf 'fill REPLACE-WITH-FIXTURE-USE\n' > "$R/docs/FILL.md"
O=$(run_ci6 "$R")
assert_rc  "CT7 a template the installer would install unfilled fails [6]" "$(rc)" 1 "$O"
R="$WORK/ct8"; mk_ci6t "$R"
printf 'fill REPLACE-WITH-FIXTURE-USE\n' > "$R/docs/FILL.md"
sed -i 's/Primary use: [^"]*"/Primary use: FIXME"/' "$R/settings/managed-settings.json"
O=$(run_ci6 "$R")
assert_rc  "CT8 a template refused for something other than its placeholders fails [6]" "$(rc)" 1 "$O"

# --- C8: a selector naming no real check is a usage error, never a silent pass
R="$WORK/ci9f"; mk_ci_repo "$R" "2.1.200"
O="$WORK/ci9f.out"
( cd "$R" && CC_CI_ONLY=banana bash "$REPOROOT/bin/cc-ci-check.sh" ) >"$O" 2>&1
echo $? > "$WORK/rc"
assert_rc  "C8  CC_CI_ONLY=banana exits 2 (usage), not 0" "$(rc)" 2 "$O"
assert_has "C8  and names the bad id" "$O" "banana"

# ================================================================ cc-bump-audit
head2 "cc-bump-audit.sh"

# The audit reads the repo tree via CC_REPO and the host via CC_ETC, so both
# sides can be fixtures. A minimal "repo" is a policy with a floor plus an
# UPGRADES log; the host side is an etc dir with approved-version.
mk_bump_repo() {  # mk_bump_repo <dir> <floor> <upgrades-entry-version or "">
  local dir="$1" floor="$2" entry="$3"
  mkdir -p "$dir/settings" "$dir/docs"
  printf '{"requiredMinimumVersion": "%s"}\n' "$floor" > "$dir/settings/managed-settings.json"
  if [ -n "$entry" ]; then
    printf '# log\n\n## %s — pinned\n' "$entry" > "$dir/docs/UPGRADES.md"
  fi
}

run_ba() {  # run_ba <repodir> <etcdir> [args...]
  local repo="$1" etc="$2"; shift 2
  local out="$WORK/ba.$RANDOM.out"
  # CC_RPM_BIN is stubbed to a nonexistent path so probe A2 SKIPs instead of
  # reading the live host's package database - fixtures decide the outcome.
  env CC_REPO="$repo" CC_ETC="$etc" CC_HOME_ROOT="$WORK/ba-nohomes" CC_CLAUDE_BIN="$WORK/ba-noclaude" \
      CC_RPM_BIN="$WORK/ba-norpm" \
      bash "$SCRIPTS/cc-bump-audit.sh" "$@" >"$out" 2>&1
  echo $? > "$WORK/rc"
  echo "$out"
}

# --- B1: the probe manifest is printable and carries both modes
R="$WORK/ba1"; mk_bump_repo "$R" "2.1.200" "2.1.200"; ETC="$WORK/ba1etc"; mkdir -p "$ETC"
O=$(run_ba "$R" "$ETC" --list-probes)
assert_rc  "B1  --list-probes exits 0" "$(rc)" 0 "$O"
assert_has "B1  auto probes listed" "$O" "compiled-policy-path"
assert_has "B1  manual probes listed" "$O" "sandbox-re-enable-gate"
assert_has "B1  every probe names its doc home" "$O" "SANDBOX-DECISION"

# --- B2: coherent fixture passes the repo-side checks
echo "2.1.200" > "$ETC/approved-version"
O=$(run_ba "$R" "$ETC")
assert_rc  "B2  coherent repo+host exits 0" "$(rc)" 0 "$O"
assert_has "B2  floor read from the policy" "$O" "2.1.200"

# --- B3: floor with no UPGRADES entry is a failure (same invariant as CI [9])
R="$WORK/ba3"; mk_bump_repo "$R" "2.1.200" "2.1.199"
O=$(run_ba "$R" "$ETC")
assert_has "B3  missing UPGRADES entry for the floor is flagged" "$O" "no entry for 2.1.200"
assert_rc  "B3  exit 1" "$(rc)" 1 "$O"

# --- B4: approved-version drifting from the floor is flagged
R="$WORK/ba4"; mk_bump_repo "$R" "2.1.200" "2.1.200"; ETC4="$WORK/ba4etc"; mkdir -p "$ETC4"
echo "2.1.150" > "$ETC4/approved-version"
O=$(run_ba "$R" "$ETC4")
assert_has "B4  approved-version drift from the floor is flagged" "$O" "approved-version"
assert_rc  "B4  exit 1 on drift" "$(rc)" 1 "$O"

# --- B5: --target-version reminds that the new entry is owed, without failing
R="$WORK/ba5"; mk_bump_repo "$R" "2.1.200" "2.1.200"; ETC5="$WORK/ba5etc"; mkdir -p "$ETC5"
echo "2.1.200" > "$ETC5/approved-version"
O=$(run_ba "$R" "$ETC5" --target-version 2.1.250)
assert_rc  "B5  pre-bump run against a target exits 0" "$(rc)" 0 "$O"
assert_has "B5  the owed entry is named" "$O" "2.1.250"

# --- B6: a target BELOW the floor is refused - rollback locks the host out
O=$(run_ba "$R" "$ETC5" --target-version 2.1.100)
assert_has "B6  target below the floor is refused" "$O" "below the current floor"
assert_rc  "B6  exit 1" "$(rc)" 1 "$O"

# --- B7: usage discipline
O=$(run_ba "$R" "$ETC5" --no-such-flag)
assert_rc "B7  unknown flag exits 2" "$(rc)" 2 "$O"

# --- B8/B9: inside a privileged session the policy path is a BIND MOUNT of the
# admin policy, so probes A3 (baseline sha) and A7 (glob rules) are reading the
# wrong file and must SKIP, not FAIL: a FAIL there is an artefact of the mount,
# not drift. CC_MOUNTINFO is the seam - the
# kernel mount table cannot be fabricated without privileges.
R="$WORK/ba8"; mk_bump_repo "$R" "2.1.200" "2.1.200"; ETC8="$WORK/ba8etc"; mkdir -p "$ETC8"
# A7's expected rules come from the SOURCE policy, not a list in the script.
printf '{"requiredMinimumVersion": "2.1.200", "permissions": {"deny": ["Read(**/.env)", "Read(**/*.pem)", "Read(~/.ssh/**)"]}}\n' \
  > "$R/settings/managed-settings.json"
echo "2.1.200" > "$ETC8/approved-version"
# A deployed policy that would FAIL both probes: wrong sha, no glob rules.
printf '{"permissions":{"deny":[]}}\n' > "$ETC8/managed-settings.json"
echo "0000000000000000000000000000000000000000000000000000000000000000  managed-settings.json" \
     > "$ETC8/managed-settings.json.sha256"

export CC_MOUNTINFO=/dev/null
O=$(run_ba "$R" "$ETC8")
assert_rc  "B8  outside a privileged session the drift still FAILS" "$(rc)" 1 "$O"
assert_has "B8  A3 reports the sha difference" "$O" "A3 policy-baseline-sha: deployed policy DIFFERS"
assert_has "B8  A7 reports the missing rules" "$O" "A7 glob-rules-present: only 0 of 2"
# B8c: the deployed policy carries the source's filename rules -> A7 ok; a
# source policy that names none is a check over nothing, and fails.
printf '{"permissions":{"deny":["Read(**/.env)","Read(**/*.pem)"]}}\n' > "$ETC8/managed-settings.json"
O=$(run_ba "$R" "$ETC8")
assert_has "B8c A7 passes when every source filename rule is deployed" "$O" "A7 glob-rules-present: all 2 filename rules"
printf '{"requiredMinimumVersion": "2.1.200", "permissions": {"deny": []}}\n' > "$R/settings/managed-settings.json"
O=$(run_ba "$R" "$ETC8")
assert_has "B8c A7 fails when the source policy names no filename rule" "$O" "A7 glob-rules-present: the source policy names no filename rule"
printf '{"requiredMinimumVersion": "2.1.200", "permissions": {"deny": ["Read(**/.env)", "Read(**/*.pem)"]}}\n' \
  > "$R/settings/managed-settings.json"
printf '{"permissions":{"deny":[]}}\n' > "$ETC8/managed-settings.json"

# mountinfo field 5 is the mount point; one line naming the policy path is what
# cc-admin-session.sh's bind mount looks like to every reader of the table.
MI="$WORK/ba8.mountinfo"
printf '900 30 0:57 / %s rw,relatime shared:1 - tmpfs tmpfs rw\n' "$ETC8/managed-settings.json" > "$MI"
export CC_MOUNTINFO="$MI"
O=$(run_ba "$R" "$ETC8")
assert_rc  "B9  privileged session exits 0 - artefacts are not failures" "$(rc)" 0 "$O"
assert_has "B9  the session is named up front" "$O" "privileged session detected"
assert_has "B9  A3 skips with a reason" "$O" "A3 policy-baseline-sha: privileged session"
assert_has "B9  A7 skips with a reason" "$O" "A7 glob-rules-present: privileged session"
unset CC_MOUNTINFO

# --- B10: the A5 private-install sweep decides who gets TOLD their tooling is
# about to stop starting, so every way it can under-report is a person missed.
# Three shapes: a launcher on PATH, an install TREE with no launcher (the shape
# the first survey missed), and a home whose ~/.local cannot be traversed.
HOMES="$WORK/ba10homes"
mkdir -p "$HOMES/withlauncher/.local/bin" "$HOMES/withlauncher/.local/share/claude/versions/2.1.209" \
         "$HOMES/treeonly/.local/share/claude/versions/2.1.216" \
         "$HOMES/opaque/.local/share/claude/versions/2.1.100" "$HOMES/planted/.local/bin"
ln -s "$HOMES/withlauncher/.local/share/claude/versions/2.1.209" "$HOMES/withlauncher/.local/bin/claude"
# A launcher that is a script, not the installer's symlink. The weekly report
# runs this sweep as root, so EXECUTING it would hand any engineer root: it must
# be classified by what it is on disk, never run.
printf '#!/bin/sh\ntouch "%s"\necho "2.1.209 (Claude Code)"\n' "$WORK/ba10-executed" > "$HOMES/planted/.local/bin/claude"
chmod 755 "$HOMES/planted/.local/bin/claude"
rm -f "$WORK/ba10-executed"
chmod 600 "$HOMES/opaque/.local"      # present, not traversable: invisible, not absent
R="$WORK/ba10"; mk_bump_repo "$R" "2.1.236" "2.1.236"; ETC10="$WORK/ba10etc"; mkdir -p "$ETC10"
echo "2.1.236" > "$ETC10/approved-version"
O=$(env CC_REPO="$R" CC_ETC="$ETC10" CC_HOME_ROOT="$HOMES" CC_CLAUDE_BIN="$WORK/ba-noclaude" \
        CC_RPM_BIN="$WORK/ba-norpm" CC_MOUNTINFO=/dev/null \
        bash "$SCRIPTS/cc-bump-audit.sh" > "$WORK/ba10.out" 2>&1; echo $? > "$WORK/rc"; echo "$WORK/ba10.out")
assert_has "B10 a launcher below the floor is named"      "$O" "withlauncher runs 2.1.209 (below 2.1.236"
assert_has "B10 a tree with no launcher is named too"     "$O" "treeonly has an install tree"
assert_has "B10 and counted against the floor"            "$O" "treeonly runs 2.1.216 (below 2.1.236"
if [ "$(id -u)" -eq 0 ]; then
  skip "B10 unreadable-home reporting (root can traverse a 0600 directory, so the case cannot be fabricated)"
else
  assert_has "B10 an unreadable home is reported, not skipped silently" "$O" "opaque - \$HOME/.local is not readable"
fi
assert_has "B10 the denominator is printed"               "$O" "private install(s) found"
assert_rc  "B10 no user's launcher is ever executed"      "$([ -e "$WORK/ba10-executed" ] && echo 1 || echo 0)" 0 "$O"
assert_has "B10 a launcher that is not the installer's symlink is reported, unread" "$O" "planted has a launcher at \$HOME/.local/bin/claude that is not a link into its versions tree"
chmod 700 "$HOMES/opaque/.local"      # so the suite's own cleanup can remove it

# ================================================================ hooks
head2 "hooks"

HOOKSDIR="$SCRIPTS/../hooks"

# hc_loader <hook filename> <config file> -> path of a copy of the hook that
# loads <config file>. The hooks clear every CC_* and source only the fixed
# installed loader, so an exported override - the way every other script is
# pointed at a fixture - cannot reach them. That is the point; the suite
# rewrites the one loader path instead. "none" as the config gives a copy whose
# loader is missing, i.e. a host with no usable config.
hc_loader() {
  local hook="$1" cfg="$2" d; d=$(mktemp -d "$WORK/hl.XXXX")
  if [ "$cfg" = none ]; then
    sed "s#/etc/claude-code/cc-config.sh#$d/no-such-loader.sh#" "$HOOKSDIR/$hook" > "$d/$hook"
  else
    printf 'CC_CONFIG="%s"\n. "%s"\n' "$cfg" "$SCRIPTS/../lib/cc-config.sh" > "$d/loader.sh"
    sed "s#/etc/claude-code/cc-config.sh#$d/loader.sh#" "$HOOKSDIR/$hook" > "$d/$hook"
  fi
  grep -q "$d/" "$d/$hook" || { echo "hc_loader: $hook no longer names /etc/claude-code/cc-config.sh" >&2; return 1; }
  printf '%s' "$d/$hook"
}
# hc_cfg <logdir> -> a suite config whose CC_LOGDIR is <logdir>
hc_cfg() {
  local c="$1/cfg.sh"; { cat "$CC_CONFIG"; printf 'CC_LOGDIR="%s"\n' "$1"; } > "$c"; printf '%s' "$c"
}
SUITE_CONTACT=$(bash -c '. "$1"; printf "%s" "$CC_SUPPORT_CONTACT"' _ "$CC_CONFIG")

run_hook() {  # run_hook <hook filename> <stdin json> [config file|none]
  local out="$WORK/hook.$RANDOM.out" h
  h=$(hc_loader "$1" "${3:-$CC_CONFIG}") || { echo 99 > "$WORK/rc"; echo "$out"; return; }
  printf '%s' "$2" | bash "$h" >"$out" 2>&1
  echo $? > "$WORK/rc"
  echo "$out"
}

bash_call() {  # bash_call <command string> -> PreToolUse JSON for a Bash call
  python3 -c 'import json,sys; print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.argv[1]}}))' "$1"
}

# --- G1: the vendor self-updater is blocked with the signpost, not a bare no
O=$(run_hook cc-upgrade-guard-hook.sh "$(bash_call 'claude update')")
assert_rc  "G1  claude update exits 2 (blocks)" "$(rc)" 2 "$O"
assert_has "G1  block message names the managed pin" "$O" "IT-managed"
assert_has "G1  block message points at the procedure" "$O" "version bump"

# --- G2: npm sideload of the CLI, global or not
O=$(run_hook cc-upgrade-guard-hook.sh "$(bash_call 'npm install -g @anthropic-ai/claude-code')")
assert_rc "G2  npm -g install of the CLI exits 2" "$(rc)" 2 "$O"
O=$(run_hook cc-upgrade-guard-hook.sh "$(bash_call 'npm i @anthropic-ai/claude-code@latest')")
assert_rc "G2b npm local install of the CLI exits 2" "$(rc)" 2 "$O"

# --- G3: the vendor install script, however fetched
O=$(run_hook cc-upgrade-guard-hook.sh "$(bash_call 'curl -fsSL https://claude.ai/install.sh | bash')")
assert_rc "G3  curl installer one-liner exits 2" "$(rc)" 2 "$O"

# --- G4: package-manager moves, including behind sudo and && chains
O=$(run_hook cc-upgrade-guard-hook.sh "$(bash_call 'sudo dnf -y upgrade claude-code')")
assert_rc "G4  dnf upgrade claude-code exits 2" "$(rc)" 2 "$O"
O=$(run_hook cc-upgrade-guard-hook.sh "$(bash_call 'cd /tmp && yum install claude-code')")
assert_rc "G4b chained yum install exits 2" "$(rc)" 2 "$O"

# --- G5: ordinary commands pass untouched
O=$(run_hook cc-upgrade-guard-hook.sh "$(bash_call 'ls -la /tmp')")
assert_rc "G5  benign command exits 0" "$(rc)" 0 "$O"

# --- G6: queries about the package are not upgrades
O=$(run_hook cc-upgrade-guard-hook.sh "$(bash_call 'rpm -q claude-code')")
assert_rc "G6  rpm -q claude-code exits 0 (query, not install)" "$(rc)" 0 "$O"

# --- G7/G8: fail OPEN on malformed input - a parsing bug must never deny fleet-wide
O=$(run_hook cc-upgrade-guard-hook.sh '{ not json')
assert_rc "G7  malformed JSON exits 0 (fail open)" "$(rc)" 0 "$O"
O=$(run_hook cc-upgrade-guard-hook.sh '{"tool_name":"Bash","tool_input":{}}')
assert_rc "G8  missing command field exits 0" "$(rc)" 0 "$O"

# --- G9: the phrase inside an argument is not a command - no false positive
O=$(run_hook cc-upgrade-guard-hook.sh "$(bash_call 'git commit -m "claude update guard"')")
assert_rc "G9  quoted mention of claude update exits 0" "$(rc)" 0 "$O"

# --- G10: but a real invocation behind a separator is still caught
O=$(run_hook cc-upgrade-guard-hook.sh "$(bash_call 'true; claude update')")
assert_rc "G10 claude update after a separator exits 2" "$(rc)" 2 "$O"

# --- G11/G12: multi-line and indented commands are normal Bash-tool shapes
O=$(run_hook cc-upgrade-guard-hook.sh "$(bash_call $'set -e\nclaude update')")
assert_rc "G11 claude update on a later line exits 2" "$(rc)" 2 "$O"
O=$(run_hook cc-upgrade-guard-hook.sh "$(bash_call '  claude update')")
assert_rc "G12 leading whitespace does not evade" "$(rc)" 2 "$O"

# --- G13: quoted arguments are never command positions, whatever they contain
O=$(run_hook cc-upgrade-guard-hook.sh "$(bash_call 'git commit -m "docs (claude update guard)"')")
assert_rc "G13 parenthesis inside a quoted message exits 0" "$(rc)" 0 "$O"
O=$(run_hook cc-upgrade-guard-hook.sh "$(bash_call 'git commit -m "a; claude update"')")
assert_rc "G13b separator inside a quoted message exits 0" "$(rc)" 0 "$O"

# --- G14/G15: rpm flag CLUSTERS - the canonical -Uvh/-ivh deny, query forms pass
O=$(run_hook cc-upgrade-guard-hook.sh "$(bash_call 'sudo rpm -Uvh claude-code-2.1.229.x86_64.rpm')")
assert_rc "G14 rpm -Uvh exits 2" "$(rc)" 2 "$O"
O=$(run_hook cc-upgrade-guard-hook.sh "$(bash_call 'rpm -ivh ./claude-code.rpm')")
assert_rc "G14b rpm -ivh exits 2" "$(rc)" 2 "$O"
O=$(run_hook cc-upgrade-guard-hook.sh "$(bash_call 'rpm -qi claude-code')")
assert_rc "G15 rpm -qi (query-info) exits 0" "$(rc)" 0 "$O"

# --- G16: package-manager QUERIES must pass. The bump procedure itself asks the
# repository what versions exist (OPERATIONS 3.2 step 2), so blocking a query
# would block the very procedure this hook signposts. `check-update` is the trap:
# a word-boundary match on "update" fires after the hyphen.
O=$(run_hook cc-upgrade-guard-hook.sh "$(bash_call 'sudo dnf -q check-update claude-code')")
assert_rc "G16 dnf check-update (a query) exits 0" "$(rc)" 0 "$O"
O=$(run_hook cc-upgrade-guard-hook.sh "$(bash_call 'dnf list --showduplicates claude-code')")
assert_rc "G16b dnf list exits 0" "$(rc)" 0 "$O"
O=$(run_hook cc-upgrade-guard-hook.sh "$(bash_call 'dnf repoquery --latest-limit 1 claude-code')")
assert_rc "G16c dnf repoquery exits 0" "$(rc)" 0 "$O"
O=$(run_hook cc-upgrade-guard-hook.sh "$(bash_call 'dnf -q info claude-code')")
assert_rc "G16d dnf info exits 0" "$(rc)" 0 "$O"

# --- G17: transaction verbs still deny. The hyphen guard that fixes G16 means
# every hyphenated verb must now be spelled out, so these are the regression
# fence around that list; localinstall and distro-sync were genuine gaps before
# it (no bare install/upgrade token anywhere in the command).
O=$(run_hook cc-upgrade-guard-hook.sh "$(bash_call 'sudo apt-get dist-upgrade claude-code')")
assert_rc "G17 apt-get dist-upgrade exits 2" "$(rc)" 2 "$O"
O=$(run_hook cc-upgrade-guard-hook.sh "$(bash_call 'sudo dnf upgrade-minimal claude-code')")
assert_rc "G17b dnf upgrade-minimal exits 2" "$(rc)" 2 "$O"
O=$(run_hook cc-upgrade-guard-hook.sh "$(bash_call 'sudo dnf localinstall ./claude-code-2.1.236-1.x86_64.rpm')")
assert_rc "G17c dnf localinstall of the claude-code rpm exits 2" "$(rc)" 2 "$O"
O=$(run_hook cc-upgrade-guard-hook.sh "$(bash_call 'sudo dnf distro-sync claude-code')")
assert_rc "G17d dnf distro-sync exits 2" "$(rc)" 2 "$O"
O=$(run_hook cc-upgrade-guard-hook.sh "$(bash_call 'sudo dnf -y upgrade claude-code')")
assert_rc "G17e the plain upgrade verb still exits 2" "$(rc)" 2 "$O"

# --- D1-D6: the denial hook. Without these, the reason field can go blind at a
# version move and nothing reports it.
DHK="$SCRIPTS/../hooks/cc-denied-hook.sh"
run_denied() {   # run_denied <json>
  local d="$WORK/den.$RANDOM"; mkdir -p "$d/denied"
  printf '%s' "$1" | bash "$(hc_loader cc-denied-hook.sh "$(hc_cfg "$d")")" >/dev/null 2>&1
  echo $? > "$WORK/rc"
  cat "$d"/denied/*.jsonl 2>/dev/null > "$WORK/den.out"
  echo "$WORK/den.out"
}

# The shape fields are recorded and the CONTENT is not. This is the line between
# an audit trail and employee monitoring, and it is the hook's whole contract.
O=$(run_denied '{"tool_name":"Bash","tool_input":{"command":"sudo id","file_text":"CANARY-SECRET"},"reason":"[Security Weaken] tried to widen the policy","session_id":"s1","cwd":"/tmp"}')
assert_rc  "D1  a well-formed payload is recorded" "$(rc)" 0 "$O"
assert_has "D1  the tool is recorded"              "$O" '"tool":"Bash"'
assert_has "D1  the command SHAPE is recorded"     "$O" 'sudo id'
assert_lacks "D1  file content never reaches the log" "$O" "CANARY-SECRET"

# The rationale can arrive in `reason` or in a sibling field, depending on the
# client version. Both are captured, and the log says which keys arrived, so a
# reader of one field can tell when it is looking at a placeholder.
O=$(run_denied '{"tool_name":"Bash","tool_input":{"command":"unshare -Urm"},"reason":"Blocked by classifier","category":"Auto Mode Bypass","session_id":"s2","cwd":"/tmp"}')
assert_has "D2  the placeholder reason is still recorded"   "$O" '"denied_by":"Blocked by classifier"'
assert_has "D2  and the category that now carries the real reason" "$O" '"category":"Auto Mode Bypass"'
assert_has "D3  the payload key NAMES are recorded"          "$O" '"payload_keys":['
assert_has "D3  including the key that would otherwise be missed" "$O" 'category'

# Names only, never values: payload_keys must not leak the value of a key it
# names, which is what makes recording it safe.
O=$(run_denied '{"tool_name":"Bash","tool_input":{"command":"ls"},"reason":"x","secret_field":"CANARY-VALUE","session_id":"s3","cwd":"/tmp"}')
assert_has  "D4  an unknown key is named"        "$O" 'secret_field'
assert_lacks "D4  but its value is not recorded" "$O" "CANARY-VALUE"

# Fail-open, always: a logging hook that exits non-zero would BLOCK the tool
# call it was only supposed to witness.
O=$(run_denied '{ not json at all')
assert_rc "D5  malformed JSON still exits 0 - a logger must never block" "$(rc)" 0 "$O"
O=$(run_denied '{}')
assert_rc "D5  an empty payload still exits 0" "$(rc)" 0 "$O"

# Where it happened and which call it was: a record that says only "Bash,
# refused" cannot be matched to the chat it came from or tried again in place.
# Read as JSON, so a value is checked under its own key and not found anywhere
# on the line. A payload without them records them as empty, not missing.
den_fields() {   # den_fields <log> -> cwd|mode|call_id of each line, or "unreadable"
  python3 -c '
import json, sys
try:
    for line in open(sys.argv[1]):
        r = json.loads(line)
        print("|".join(r[k] for k in ("cwd", "mode", "call_id")))
except (OSError, ValueError, KeyError, TypeError):
    print("unreadable")' "$1"
}
O=$(run_denied '{"tool_name":"Bash","tool_input":{"command":"ls"},"reason":"x","session_id":"s6","cwd":"/projects/x","permission_mode":"acceptEdits","tool_use_id":"toolu_06"}')
CURRENT="$O"
if [ "$(den_fields "$O")" = "/projects/x|acceptEdits|toolu_06" ]; then pass "D6  the directory, permission mode and call id are recorded"
else fail "D6  the directory, permission mode and call id are recorded"; fi
O=$(run_denied '{"tool_name":"Bash","tool_input":{"command":"ls"},"reason":"x"}')
CURRENT="$O"
if [ "$(den_fields "$O")" = "||" ]; then pass "D6  and are empty when the payload has none"
else fail "D6  and are empty when the payload has none"; fi

# --- S1-S8: the secret guard. It is ENFORCEMENT, not evidence - the only hook
# that blocks a call - and it had no cases at all. Its seven checks lived in
# OPERATIONS 1.9 as a hand-run smoke test, which runs when a person builds a
# host and remembers to; the upgrade guard next door graduated from the same
# procedure into the G cases and its 1.9 block now says so. This is that
# promotion, plus the cases the smoke test does not cover.
#
# It is the enforcement of record for the policy's filename rules, whose own
# enforcement varies by version, and the only control for .env.<name>
# (PL1) - a regression here reopens the gap on every host, with no other detector.
path_call() {  # path_call <tool> <path> -> PreToolUse JSON
  python3 -c 'import json,sys; print(json.dumps({"tool_name":sys.argv[1],"tool_input":{"file_path":sys.argv[2]}}))' "$1" "$2"
}

# Blocks: exit 2 is what stops the tool call.
O=$(run_hook cc-secret-guard-hook.sh "$(path_call Read '/scratch/x/.env')")
assert_rc  "S1  a bare .env is blocked"            "$(rc)" 2 "$O"
assert_has "S1  and the block names the file"      "$O" "matches a credential filename pattern"
assert_has "S1  and says where to go if it is wrong" "$O" "$SUITE_CONTACT"
# The contact is CC_SUPPORT_CONTACT, read on the block. No config must never
# unblock: the decision does not depend on config, only the message does.
O=$(run_hook cc-secret-guard-hook.sh "$(path_call Read '/scratch/x/.env')" none)
assert_rc  "S1b with no usable config a .env is still blocked" "$(rc)" 2 "$O"
assert_has "S1b and the message says the contact is not configured" "$O" "contact not configured: CC_SUPPORT_CONTACT"
O=$(run_hook cc-upgrade-guard-hook.sh "$(bash_call 'claude update')" none)
assert_rc  "G1b with no usable config claude update is still blocked" "$(rc)" 2 "$O"
O=$(run_hook cc-upgrade-guard-hook.sh "$(bash_call 'claude update')")
assert_has "G1c the upgrade block names the configured contact" "$O" "Questions: $SUITE_CONTACT"
# .env.<anything> other than the allow-listed names has no policy rule behind
# it (PL1), so the guard is what stops it.
O=$(run_hook cc-secret-guard-hook.sh "$(path_call Read '/scratch/x/.env.local')")
assert_rc "S1c .env.local is blocked by the guard alone" "$(rc)" 2 "$O"
O=$(run_hook cc-secret-guard-hook.sh "$(path_call Read '/h/.ssh/id_rsa')")
assert_rc "S2  a private key is blocked"           "$(rc)" 2 "$O"
O=$(run_hook cc-secret-guard-hook.sh "$(path_call Edit '/deep/nested/dir/prod.pem')")
assert_rc "S2b a .pem at depth is blocked - the basename rule is what **/ meant" "$(rc)" 2 "$O"
O=$(run_hook cc-secret-guard-hook.sh "$(path_call Read '/x/.aws/credentials')")
assert_rc "S2c a bare credentials file is blocked" "$(rc)" 2 "$O"

# Allows: a FALSE POSITIVE here blocks real work fleet-wide, which is why 1.9
# refuses to wire the hook in until every "want 0" case passes.
O=$(run_hook cc-secret-guard-hook.sh "$(path_call Read '/scratch/x/main.py')")
assert_rc "S3  an ordinary source file is allowed" "$(rc)" 0 "$O"
O=$(run_hook cc-secret-guard-hook.sh "$(path_call Read '/h/.ssh/id_rsa.pub')")
assert_rc "S3b a PUBLIC key is allowed - it is not a secret and is read constantly" "$(rc)" 0 "$O"
O=$(run_hook cc-secret-guard-hook.sh "$(path_call Read '/x/.env.example')")
assert_rc "S3c .env.example is allowed"            "$(rc)" 0 "$O"
O=$(run_hook cc-secret-guard-hook.sh "$(path_call Read '/etc/pki/ca-bundle.pem')")
assert_rc "S3d a public cert bundle is allowed"    "$(rc)" 0 "$O"
# The allowlist is checked BEFORE the patterns, so ordering is the contract:
# id_rsa.pub matches both ^id_rsa.*$ and ^id_rsa\.pub$, and must allow.
O=$(run_hook cc-secret-guard-hook.sh "$(path_call Read '/h/fullchain.pem')")
assert_rc "S3e allowlist beats pattern where both match" "$(rc)" 0 "$O"

# FAIL OPEN on everything unexpected. The header calls this load-bearing: a
# parsing bug that exited 2 would become a fleet-wide denial of service, and
# every session on every host would stop being able to read files.
O=$(run_hook cc-secret-guard-hook.sh 'not json at all')
assert_rc "S4  malformed JSON allows - a guard bug must not become an outage" "$(rc)" 0 "$O"
O=$(run_hook cc-secret-guard-hook.sh '')
assert_rc "S4b empty stdin allows"                 "$(rc)" 0 "$O"
O=$(run_hook cc-secret-guard-hook.sh '{"tool_name":"Bash","tool_input":{"command":"cat /x/.env"}}')
assert_rc "S5  a Bash call is NOT parsed for paths - deliberately, see the header" "$(rc)" 0 "$O"
O=$(run_hook cc-secret-guard-hook.sh '{"tool_name":"Read","tool_input":[]}')
assert_rc "S5b a non-object tool_input allows"     "$(rc)" 0 "$O"

# The content boundary applies here too: the guard reads the PATH, never the file.
O=$(run_hook cc-secret-guard-hook.sh '{"tool_name":"Read","tool_input":{"file_path":"/x/.env","file_text":"CANARY-SECRET"}}')
assert_rc    "S6  a blocked call still exits 2 when content is present" "$(rc)" 2 "$O"
assert_lacks "S6  and the block message never echoes content"           "$O" "CANARY-SECRET"

# --- AH1-AH5: the activity hook. It is the evidence layer - one line per tool
# call - and it had no cases either, despite its own header claiming the suite
# asserts its canary. The only check was OPERATIONS 1.10 rows 7-8, run by hand
# at build time; nothing re-runs it, so a regression in the field whitelist
# would leak file contents into a log every engineer's session appends to.
AHK="$SCRIPTS/../hooks/cc-audit-hook.sh"
run_audit() {   # run_audit <json> [extra env assignments...]
  local d="$WORK/act.$RANDOM" j="$1"; shift; mkdir -p "$d/activity"
  printf '%s' "$j" | env "$@" bash "$(hc_loader cc-audit-hook.sh "$(hc_cfg "$d")")" >/dev/null 2>&1
  echo $? > "$WORK/rc"
  cat "$d"/activity/*.jsonl 2>/dev/null > "$WORK/act.out"
  echo "$WORK/act.out"
}

# --- AH0: the engineer's environment cannot move the evidence. The hook runs as
# the engineer, who could otherwise export a CC_* path and have their own
# activity written somewhere they control - or nowhere.
EVIL="$WORK/evil"; mkdir -p "$EVIL/activity"
O=$(run_audit '{"tool_name":"Bash","tool_input":{"command":"id"}}' \
      CC_ACTIVITY_LOG_DIR="$EVIL/activity" CC_LOGDIR="$EVIL" CC_CONFIG="$WORK/no-such.sh" CC_CONFIG_LIB="$WORK/no-such.sh")
assert_has "AH0 an exported CC_* does not redirect the activity log" "$O" '"tool":"Bash"'
CURRENT=/dev/null
if ls "$EVIL"/activity/*.jsonl >/dev/null 2>&1; then
  fail "AH0 and nothing was written where the engineer pointed it"
else
  pass "AH0 and nothing was written where the engineer pointed it"
fi
# With no usable config the hook still exits 0 - it must never block a call.
printf '%s' '{"tool_name":"Bash","tool_input":{"command":"id"}}' | bash "$(hc_loader cc-audit-hook.sh none)" >/dev/null 2>&1
assert_rc "AH0b with no usable config the activity hook still exits 0" "$?" 0
O=$(run_audit '{"tool_name":"Bash","tool_input":{"command":"ls -la /projects"},"session_id":"s1","cwd":"/projects/x","permission_mode":"default"}')
assert_rc  "AH1 a well-formed call is recorded"  "$(rc)" 0 "$O"
assert_has "AH1 the tool is recorded"            "$O" '"tool":"Bash"'
assert_has "AH1 the command shape is recorded"   "$O" 'ls -la /projects'
assert_has "AH1 and the working directory"       "$O" '"cwd":"/projects/x"'

# THE CANARY. This is the assertion the hook's own header promises and did not
# have: file CONTENT must never reach the activity log. The whitelist is
# ordered - command, then file_path, then url, then path - so a fourth branch
# added for a new tool's input shape is exactly how content would start leaking.
O=$(run_audit '{"tool_name":"Write","tool_input":{"file_path":"/tmp/x.txt","content":"CANARY-SECRET","file_text":"CANARY-SECRET","new_string":"CANARY-SECRET"},"session_id":"s2","cwd":"/tmp"}')
assert_has   "AH2 the file PATH is recorded"                 "$O" '/tmp/x.txt'
assert_lacks "AH2 content never reaches the activity log"    "$O" "CANARY-SECRET"
O=$(run_audit '{"tool_name":"Edit","tool_input":{"file_path":"/tmp/y.txt","old_string":"CANARY-OLD","new_string":"CANARY-NEW"},"session_id":"s3","cwd":"/tmp"}')
assert_lacks "AH2b neither side of an edit is recorded"      "$O" "CANARY-"
O=$(run_audit '{"tool_name":"WebFetch","tool_input":{"url":"https://example.internal/x","prompt":"CANARY-PROMPT"},"session_id":"s4","cwd":"/tmp"}')
assert_has   "AH3 a WebFetch url is recorded"                "$O" 'example.internal'
assert_lacks "AH3 but the prompt is not - prompts are content" "$O" "CANARY-PROMPT"

# A pathological argument must not bloat every reader's log; the cap is 2000.
O=$(run_audit "$(python3 -c 'import json;print(json.dumps({"tool_name":"Bash","tool_input":{"command":"x"*9000},"session_id":"s5","cwd":"/tmp"}))')")
CURRENT="$O"
if [ "$(wc -c < "$O")" -lt 2600 ]; then
  pass "AH4 an oversized argument is capped, not written whole"
else
  fail "AH4 an oversized argument is capped, not written whole ($(wc -c < "$O") bytes)"
fi

# Fail open, same as the denial hook: a logger that exits non-zero blocks the
# call it was only supposed to witness, and this one runs on EVERY Bash, Edit,
# Write and WebFetch on the fleet.
O=$(run_audit '{ not json')
assert_rc "AH5 malformed JSON still exits 0 - a logger must never block" "$(rc)" 0 "$O"
O=$(run_audit '{}')
assert_rc "AH5b an empty payload still exits 0" "$(rc)" 0 "$O"

# --- PC1-PC8: the pre-commit secret guard. CLAUDE.md relies on it by name -
# "never commit config.sh, any credential-shaped value, or a *.jsonl transcript.
# The pre-commit guard blocks these by value shape." It had no cases, and the
# reason recorded for that was wrong: cc-ci-check [1] runs the guard over THIS
# repository, which is clean by construction, so it proves the guard does not
# false-positive and says nothing about whether it still detects anything. A
# guard tested only against material it should pass is untested in the direction
# that matters.
#
# Fixtures are built in a scratch git repo at run time and never committed:
# a file containing a real-looking token, committed here as a fixture, is the
# exact accident the guard exists to stop.
PCG="$SCRIPTS/../githooks/pre-commit"
run_precommit() {   # run_precommit <filename> <content>
  local d="$WORK/pc.$RANDOM"; mkdir -p "$d"
  git -C "$d" init -q
  printf '%s' "$2" > "$d/$1"
  git -C "$d" add -f -- "$1" >/dev/null 2>&1
  local out="$WORK/pc.$RANDOM.out"
  ( cd "$d" && bash "$PCG" >"$out" 2>&1 )
  echo $? > "$WORK/rc"
  echo "$out"
}
# Token literals are assembled at run time. Writing one whole into this file
# would make the suite itself trip the guard on the commit that adds it - which
# is a fair demonstration that the guard works, and a poor way to find out.
GH_PAT="gh""p_$(printf 'A%.0s' $(seq 1 24))"
AWS_ID="AK""IA$(printf 'B%.0s' $(seq 1 16))"

O=$(run_precommit "notes.txt" "here is a key $GH_PAT and nothing else")
assert_rc  "PC1 a GitHub token shape is blocked"   "$(rc)" 1 "$O"
assert_has "PC1 and the block says why it matters" "$O" "compromised even after deletion"
O=$(run_precommit "notes.txt" "aws id $AWS_ID in prose")
assert_rc "PC2 an AWS access-key id is blocked"    "$(rc)" 1 "$O"
O=$(run_precommit "svc.conf" "$(printf -- '-----BEGIN RSA PRIVATE KEY-----\nMIIabc\n-----END RSA PRIVATE KEY-----\n')")
assert_rc "PC3 a PEM private key block is blocked" "$(rc)" 1 "$O"
O=$(run_precommit "nslcd.conf" "uri ldap://dc.example\n")
assert_rc  "PC4 a system auth config is blocked by NAME"  "$(rc)" 1 "$O"
O=$(run_precommit "session.jsonl" '{"a":1}')
assert_rc "PC5 a transcript is blocked by extension" "$(rc)" 1 "$O"
O=$(run_precommit "config.sh" "CC_ETC=/etc/claude-code")
assert_rc  "PC6 a force-added config.sh is blocked" "$(rc)" 1 "$O"
assert_has "PC6 and it names the file to commit instead" "$O" "config.example.sh"
O=$(run_precommit "big.txt" "$(printf 'x%.0s' $(seq 1 600000))")
assert_rc "PC7 an oversized file is blocked"        "$(rc)" 1 "$O"

# THE OTHER DIRECTION, and the harder half. A repository like this one legitimately
# discusses words such as bindpw and password in its documents and deny rules; a
# guard matching vocabulary rather than values would block every future edit to
# CURRENT-STATE.md and be switched off within a week. The value charset excludes
# * < > $ { } ( ) precisely so a glob, a placeholder and a shell expansion cannot
# match as values.
O=$(run_precommit "SETTINGS.md" 'The deny rule `Read(**/*password*)` covers it, and `bindpw` is discussed in the findings register.')
assert_rc "PC8 a deny rule quoting password vocabulary is NOT blocked" "$(rc)" 0 "$O"
O=$(run_precommit "policy.json" '{"forceLoginOrgUUID": "<REPLACE-WITH-THE-ORG-UUID>"}')
assert_rc "PC8b a placeholder is not a credential value"              "$(rc)" 0 "$O"
O=$(run_precommit "script.sh" 'PW="${CC_PASSWD}"; export API_KEY="$SOME_VAR"')
assert_rc "PC8c a shell expansion is not a credential value"          "$(rc)" 0 "$O"
O=$(run_precommit "ok.md" 'A perfectly ordinary sentence about tokens and secrets.')
assert_rc "PC8d prose about secrets is not a secret"                  "$(rc)" 0 "$O"

# --- HB1-HB6: the hooks are a control against the engineer, so nothing in the
# engineer's environment may steer the interpreter that runs them. The hooks
# are EXECUTED here, as Claude Code runs them, not passed to `bash`: the
# shebang is part of what is tested. The hostile environment is BASH_ENV (runs
# before line 1), a bash/cat/python3/id first on PATH, and PYTHONPATH with a
# sitecustomize - each touches a marker, and an impostor bash or cat exits 0,
# which for a guard means "allow".
HB="$WORK/hb"; mkdir -p "$HB/bin" "$HB/py"
for t in bash cat python3 id; do
  printf '#!/bin/sh\ntouch "%s/ran-%s"\nexit 0\n' "$HB" "$t" > "$HB/bin/$t"; chmod 755 "$HB/bin/$t"
done
printf 'touch "%s/ran-bashenv"\nexit 0\n' "$HB" > "$HB/bashenv"
printf 'open("%s/ran-sitecustomize", "w").close()\n' "$HB" > "$HB/py/sitecustomize.py"
hb_exec() {  # hb_exec <hook filename> <stdin json> [config] -> runs the hook as an executable, in the hostile env
  local h out="$WORK/hb.$RANDOM.out"; rm -f "$HB"/ran-*
  h=$(hc_loader "$1" "${3:-$CC_CONFIG}"); chmod 755 "$h"
  printf '%s' "$2" | env BASH_ENV="$HB/bashenv" ENV="$HB/bashenv" PATH="$HB/bin:$PATH" PYTHONPATH="$HB/py" \
    "$h" >"$out" 2>&1
  echo $? > "$WORK/rc"; echo "$out"
}
hb_ran() { ls "$HB"/ran-* 2>/dev/null | sed 's#.*/ran-##' | tr '\n' ' '; }
O=$(hb_exec cc-secret-guard-hook.sh '{"tool_name":"Read","tool_input":{"file_path":"/p/.env"}}')
assert_rc  "HB1 the secret guard still blocks under a hostile BASH_ENV/PATH/PYTHONPATH" "$(rc)" 2 "$O"
assert_rc  "HB1 and nothing the engineer planted ran [$(hb_ran)]" "$(ls "$HB"/ran-* 2>/dev/null | wc -l)" 0 "$O"
O=$(hb_exec cc-upgrade-guard-hook.sh "$(bash_call 'claude update')")
assert_rc  "HB2 the upgrade guard still blocks under the hostile environment" "$(rc)" 2 "$O"
assert_rc  "HB2 and nothing the engineer planted ran [$(hb_ran)]" "$(ls "$HB"/ran-* 2>/dev/null | wc -l)" 0 "$O"
HBL="$WORK/hb-log"; mkdir -p "$HBL/activity" "$HBL/denied"
O=$(hb_exec cc-audit-hook.sh "$(bash_call 'echo hb3-shape')" "$(hc_cfg "$HBL")")
assert_has "HB3 the audit hook still records under the hostile environment" "$(ls "$HBL"/activity/*.jsonl 2>/dev/null | head -1 || echo "$WORK/none")" "hb3-shape"
assert_rc  "HB3 and nothing the engineer planted ran [$(hb_ran)]" "$(ls "$HB"/ran-* 2>/dev/null | wc -l)" 0 "$O"
O=$(hb_exec cc-denied-hook.sh "$(bash_call 'echo hb3b-shape')" "$(hc_cfg "$HBL")")
assert_has "HB3b the denied hook still records under the hostile environment" "$(ls "$HBL"/denied/*.jsonl 2>/dev/null | head -1 || echo "$WORK/none")" "hb3b-shape"
assert_rc  "HB3b and nothing the engineer planted ran [$(hb_ran)]" "$(ls "$HB"/ran-* 2>/dev/null | wc -l)" 0 "$O"

# HB4: the log directories are 1733, so ANOTHER user can create the file a
# victim's hook will append to - as a symlink to somewhere else, or a FIFO that
# blocks every tool call. The hook appends only to a regular file it owns, never
# through a link, never blocking; anything else is left alone (and the call
# still goes ahead - a hook never blocks on its own logging).
HBP="$WORK/hb-plant"; mkdir -p "$HBP/activity" "$HBP/denied"; ME=$(id -un)
printf 'untouched\n' > "$HBP/elsewhere"
ln -s "$HBP/elsewhere" "$HBP/activity/$ME.jsonl"
O=$(printf '%s' "$(bash_call 'echo hb4')" | bash "$(hc_loader cc-audit-hook.sh "$(hc_cfg "$HBP")")" >/dev/null 2>&1; echo $? > "$WORK/rc"; echo "$HBP/elsewhere")
assert_rc    "HB4 a planted symlink log does not fail the call" "$(rc)" 0 "$O"
assert_lacks "HB4 and nothing is written through it" "$O" "hb4"
mkfifo "$HBP/denied/$ME.jsonl"
timeout 10 bash "$(hc_loader cc-denied-hook.sh "$(hc_cfg "$HBP")")" < <(bash_call 'echo hb4b') >/dev/null 2>&1; echo $? > "$WORK/rc"
assert_rc  "HB4b a planted FIFO log does not hang the call (timeout would be 124)" "$(rc)" 0 "$HBP/denied"

# HB5: a long command keeps its END. Padding the front of a command must not
# push the part that matters past the cap.
LONGCMD="echo $(head -c 3000 /dev/zero | tr '\0' 'a') ; HB5-TAIL-MARK"
O=$(run_audit "$(bash_call "$LONGCMD")")
assert_has "HB5 the end of a long command is kept" "$O" "HB5-TAIL-MARK"
assert_has "HB5 and the record says how long it really was" "$O" '"detail_len":'

# HB6: the guard judges what a path RESOLVES to, not only the name it is given.
HBS="$WORK/hb-sym"; mkdir -p "$HBS"; printf 'K=v\n' > "$HBS/.env"; ln -s "$HBS/.env" "$HBS/notes.txt"
ln -s "$HBS/.env" "$HBS/.env.example"
O=$(run_hook cc-secret-guard-hook.sh "{\"tool_name\":\"Read\",\"tool_input\":{\"file_path\":\"$HBS/notes.txt\"}}")
assert_rc "HB6 an innocently named symlink to a .env file is blocked" "$(rc)" 2 "$O"
O2=$(run_hook cc-secret-guard-hook.sh "{\"tool_name\":\"Read\",\"cwd\":\"$HBS\",\"tool_input\":{\"file_path\":\"notes.txt\"}}")
assert_rc "HB6 a relative one too, resolved against the session's cwd" "$(rc)" 2 "$O2"
O=$(run_hook cc-secret-guard-hook.sh "{\"tool_name\":\"Read\",\"tool_input\":{\"file_path\":\"$HBS/.env.example\"}}")
assert_rc "HB6 an allow-listed NAME does not launder a secret target" "$(rc)" 2 "$O"
mkdir -p "$WORK/hb-sym-ex.d"; printf 'X=example\n' > "$WORK/hb-sym-ex.d/.env.example"
O=$(run_hook cc-secret-guard-hook.sh "{\"tool_name\":\"Read\",\"tool_input\":{\"file_path\":\"$WORK/hb-sym-ex.d/.env.example\"}}")
assert_rc "HB6 a real .env.example is still allowed" "$(rc)" 0 "$O"

# --- cc-redact-hook.sh: credential-shaped text is removed from a tool's output
# before the model sees it. Measured on the pinned build:
# an updatedToolOutput whose shape differs from the tool's own is DROPPED and the
# original output reaches the model, so every case below also checks that the
# rewrite keeps the input's exact key structure. Fixture secrets are assembled
# at run time from fragments: no credential-shaped value sits in this file, which
# the pre-commit guard and CI check [1] would rightly refuse.
RDL="$WORK/rd-logs"; mkdir -p "$RDL/activity"; RDCFG=$(hc_cfg "$RDL")
# rd_case <kind> <tool shape> -> a PostToolUse JSON line carrying a fixture of <kind>
rd_case() {
  python3 -I - "$1" "$2" <<'PY'
import base64, json, sys, textwrap
kind, shape = sys.argv[1], sys.argv[2]
B, E, PK = "-----BEGIN ", "-----END ", "PRIVATE " + "KEY-----"
body = "b3BlbnNzaC1rZXktdjEAAAAA" + "RDCANARYzq7Wm4Xp9" * 3
pem = B + "OPENSSH " + PK + "\n" + body + "\n" + E + "OPENSSH " + PK
big = B + "OPENSSH " + PK + "\n" + "\n".join([body] * 6) + "\n" + E + "OPENSSH " + PK
# A DER key body as a PEM shows it without its BEGIN line (tail -n +2, a Read
# with an offset): SEQUENCE, then INTEGER version 0 or 1 - which no certificate
# or public key starts with.
fill = (b"RDCANARY" + bytes(range(256))) * 5
der = lambda head: "\n".join(textwrap.wrap(base64.b64encode(head + fill).decode(), 64))
v = {
  "pem": "before\n" + pem + "\nafter",
  "pem_cut": "x\n" + B + "RSA " + PK + "\nMIIRDCANARYabcdefghijklmnopqrstuv\nMIIpartial",
  "openssh_body": "line1\n" + body + "\nline3",
  "b64_pem": "enc: " + base64.b64encode(pem.encode()).decode(),
  "hex_pem": "hex: " + pem.encode().hex(),
  "aws": "id=" + "AKIA" + "RDCANARYQ7WM4XP9",
  "anthropic": "k=" + "sk-" + "ant-" + "oat01-RDCANARY" + "x" * 30,
  "github": "t=" + "ghp_" + "RDCANARY" + "a" * 32,
  "gitlab": "t=" + "glpat-" + "RDCANARY" + "b" * 14,
  "slack": "t=" + "xoxb-" + "1234-RDCANARY-" + "c" * 10,
  "google": "k=" + "AIza" + "RDCANARY" + "d" * 27,
  "jwt": "bearer " + "eyJ" + "hbGciOiJIUzI1" + ".eyJ" + "zdWIiOiJSRENBTkFSWSJ9" + ".RDCANARY" + "e" * 20,
  "url_pw": "remote: https://" + "builder:" + "RDCANARYpw9" + "@git.example/x.git",
  "pgp": B + "PGP " + PK[:-5] + " BLOCK-----\n\nlQOYBF" + "RDCANARYzq7Wm4Xp9" * 3 + "\n" + E + "PGP " + PK[:-5] + " BLOCK-----",
  "b64_wrapped": base64.encodebytes(big.encode()).decode(),
  "b64_glued": "payload" + base64.b64encode(big.encode()).decode(),
  "hex_0x": "0x" + pem.encode().hex(),
  "der_rsa": der(bytes([0x30, 0x82, 0x04, 0xa2, 0x02, 0x01, 0x00])),
  "der_pkcs8": der(bytes([0x30, 0x82, 0x04, 0xbe, 0x02, 0x01, 0x00, 0x30, 0x0d])),
  "der_ec": base64.b64encode(bytes([0x30, 0x77, 0x02, 0x01, 0x01, 0x04, 0x20]) + fill[:112]).decode(),
  "b64_indented": "data:\n" + "\n".join("    " + l for l in base64.encodebytes(big.encode()).decode().splitlines()),
  "b64_jsonesc": json.dumps({"k": base64.encodebytes(big.encode()).decode()}),
  "b64_spaced": " ".join(base64.encodebytes(big.encode()).decode().split()),
  "der_indented": "\n".join("  " + l for l in der(bytes([0x30, 0x82, 0x04, 0xa2, 0x02, 0x01, 0x00])).splitlines()),
  "der_jsonesc": json.dumps(der(bytes([0x30, 0x82, 0x04, 0xa2, 0x02, 0x01, 0x00]))),
  "benign_der": der(bytes([0x30, 0x82, 0x05, 0x10, 0x30, 0x82, 0x03, 0xf8])) + "\n" + der(bytes([0x30, 0x82, 0x01, 0x22, 0x30, 0x0d, 0x06, 0x09])),
  "benign": "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQC7 user@host\n" + B + "CERTIFICATE-----\nMIIBszCCAVmgAwIBAgIU\n" + E + "CERTIFICATE-----\ncommit 3f9a1c2e8b7d6a5f4e3d2c1b0a9f8e7d6c5b4a39\n" + base64.b64encode(b"just an ordinary sentence that is long enough to look like a blob").decode(),
}[kind]
if shape == "bash":
  resp = {"stdout": v, "stderr": "", "interrupted": False, "isImage": False, "noOutputExpected": False}
  tool = "Bash"
elif shape == "read":
  resp = {"type": "text", "file": {"filePath": "/w/f.txt", "content": v, "numLines": 3, "startLine": 1, "totalLines": 3}}
  tool = "Read"
else:
  resp = [{"type": "text", "text": v}]
  tool = "mcp__x__y"
print(json.dumps({"hook_event_name": "PostToolUse", "session_id": "s1", "tool_name": tool,
                  "tool_input": {}, "tool_response": resp}))
PY
}
# rd_check <file> -> "SAME" when updatedToolOutput keeps the input's key
# structure, "NOREWRITE" when the hook printed nothing, else a reason
rd_check() {
  python3 -I - "$1" "$2" <<'PY'
import json, sys
out, inp = open(sys.argv[1]).read().strip(), json.loads(open(sys.argv[2]).read())
if not out:
    print("NOREWRITE"); raise SystemExit
try:
    new = json.loads(out)["hookSpecificOutput"]["updatedToolOutput"]
except Exception as e:
    print("BADJSON", e); raise SystemExit
def sk(x):
    if isinstance(x, dict): return {k: sk(v) for k, v in x.items()}
    if isinstance(x, list): return [sk(v) for v in x]
    return type(x).__name__
print("SAME" if sk(new) == sk(inp["tool_response"]) else "SHAPE-DIFFERS")
PY
}
# rd_leak <file> <input> -> how many of the input's long tokens (20+ characters
# with no space, so encoded runs too) survive into updatedToolOutput. Needed for
# encoded fixtures, whose text never holds the canary literally.
rd_leak() {
  python3 -I - "$1" "$2" <<'PY'
import json, re, sys
out, inp = open(sys.argv[1]).read().strip(), json.loads(open(sys.argv[2]).read())
def strs(x):
    if isinstance(x, str): yield x
    elif isinstance(x, dict):
        for v in x.values(): yield from strs(v)
    elif isinstance(x, list):
        for v in x: yield from strs(v)
toks = {t for s in strs(inp["tool_response"]) for t in re.findall(r"[A-Za-z0-9+/=]{20,}", s)}
new = "\n".join(strs(json.loads(out)["hookSpecificOutput"]["updatedToolOutput"])) if out else "\n".join(strs(inp["tool_response"]))
print("LEAKED %d of %d" % (sum(t in new for t in toks), len(toks)))
PY
}
for k in pem pem_cut openssh_body b64_pem hex_pem aws anthropic github gitlab slack google jwt url_pw; do
  rd_case "$k" bash > "$WORK/rd.in"
  O=$(run_hook cc-redact-hook.sh "$(cat "$WORK/rd.in")" "$RDCFG")
  assert_rc    "RD1 [$k] exits 0" "$(rc)" 0 "$O"
  assert_lacks "RD1 [$k] the fixture never reaches the model" "$O" "RDCANARY"
  assert_has   "RD1 [$k] the cut is marked" "$O" "REDACTED"
  rd_check "$O" "$WORK/rd.in" > "$WORK/rd.chk"
  assert_has   "RD1 [$k] the rewrite keeps the tool's output shape" "$WORK/rd.chk" "SAME"
done
for s in read mcp; do
  rd_case pem "$s" > "$WORK/rd.in"
  O=$(run_hook cc-redact-hook.sh "$(cat "$WORK/rd.in")" "$RDCFG")
  assert_lacks "RD2 [$s] a key in a $s result is redacted" "$O" "RDCANARY"
  rd_check "$O" "$WORK/rd.in" > "$WORK/rd.chk"
  assert_has   "RD2 [$s] and the $s shape is kept" "$WORK/rd.chk" "SAME"
done
assert_has "RD3 the model is told why, with a route to ask" "$O" "$SUITE_CONTACT"
# Encoded and header-less keys: the default `base64` output wraps at 76, so each
# line alone decodes to a fragment; a key body read without its BEGIN line; hex
# behind a 0x; base64 glued to a word; a run whose lines are indented (YAML),
# JSON-escaped (a literal \n) or space-separated. RD9 counts surviving tokens,
# not a canary.
for k in pgp b64_wrapped b64_glued hex_0x der_rsa der_pkcs8 der_ec \
         b64_indented b64_jsonesc b64_spaced der_indented der_jsonesc; do
  rd_case "$k" bash > "$WORK/rd.in"
  O=$(run_hook cc-redact-hook.sh "$(cat "$WORK/rd.in")" "$RDCFG")
  rd_leak "$O" "$WORK/rd.in" > "$WORK/rd.chk"
  assert_has   "RD9 [$k] no token of the key reaches the model" "$WORK/rd.chk" "LEAKED 0 of"
  assert_lacks "RD9 [$k] nor the canary" "$O" "RDCANARY"
  rd_check "$O" "$WORK/rd.in" > "$WORK/rd.chk"
  assert_has   "RD9 [$k] the rewrite keeps the tool's output shape" "$WORK/rd.chk" "SAME"
done
rd_case benign_der bash > "$WORK/rd.in"
O=$(run_hook cc-redact-hook.sh "$(cat "$WORK/rd.in")" "$RDCFG")
rd_check "$O" "$WORK/rd.in" > "$WORK/rd.chk"
assert_has "RD9 a certificate or public-key DER body is not taken for a private key" "$WORK/rd.chk" "NOREWRITE"
# An alarm that fires on healthy output corrupts the engineer's work: public
# keys, certificates, commit hashes and ordinary base64 pass untouched.
rd_case benign bash > "$WORK/rd.in"
O=$(run_hook cc-redact-hook.sh "$(cat "$WORK/rd.in")" "$RDCFG")
assert_rc "RD4 benign output exits 0" "$(rc)" 0 "$O"
rd_check "$O" "$WORK/rd.in" > "$WORK/rd.chk"
assert_has "RD4 public keys, certificates, hashes and plain base64 are not rewritten" "$WORK/rd.chk" "NOREWRITE"
# The evidence line: tool and kinds, never the text.
assert_has   "RD5 a redaction is logged" "$RDL/activity/$(id -un).jsonl" '"event":"redaction"'
assert_lacks "RD5 the log never holds the redacted text" "$RDL/activity/$(id -un).jsonl" "RDCANARY"
if [ "$(stat -c %a "$RDL/activity/$(id -un).jsonl")" = 600 ]; then pass "RD5 the log is 0600"; else fail "RD5 the log is 0600"; fi
# No config: redaction must still happen; only the log is lost.
rd_case aws bash > "$WORK/rd.in"
O=$(run_hook cc-redact-hook.sh "$(cat "$WORK/rd.in")" none)
assert_lacks "RD6 with no usable config the output is still redacted" "$O" "RDCANARY"
# Fault injection: a scan that raises must withhold, not pass the text through.
RDF=$(hc_loader cc-redact-hook.sh "$RDCFG")
if grep -q '^def scan(text):$' "$RDF"; then
  sed -i 's/^def scan(text):$/def scan(text):\n    raise RuntimeError("injected")/' "$RDF"
  rd_case pem read > "$WORK/rd.in"
  bash "$RDF" < "$WORK/rd.in" > "$WORK/rd.out" 2>&1; echo $? > "$WORK/rc"
  assert_rc    "RD7 a scan that fails still exits 0" "$(rc)" 0 "$WORK/rd.out"
  assert_lacks "RD7 ...and withholds the text instead of passing it" "$WORK/rd.out" "RDCANARY"
  rd_check "$WORK/rd.out" "$WORK/rd.in" > "$WORK/rd.chk"
  assert_has   "RD7 ...in the tool's own shape" "$WORK/rd.chk" "SAME"
else
  fail "RD7 the fault seam 'def scan(text):' is gone from cc-redact-hook.sh"
fi
# Input that is not JSON cannot be rewritten (there is no shape to keep): exit 0
# quietly. This is the one fail-open path, and it is stated in the hook header.
O=$(run_hook cc-redact-hook.sh 'not json' "$RDCFG")
assert_rc "RD8 unparseable input exits 0" "$(rc)" 0 "$O"

# ================================================================ settings files
head2 "settings files"
for f in "$SCRIPTS/../settings"/*.json; do
  CURRENT="/dev/null"
  if python3 -c "import json;json.load(open('$f'))" 2>/dev/null; then
    pass "JSON parses: $(basename "$f")"
  else
    fail "JSON parses: $(basename "$f")"
  fi
done
# PL1: a name the secret guard allow-lists must not be
# refused by a policy rule. Deny rules run BEFORE the hook, so once filename
# globs enforce, a rule such as Read(**/.env.*) refuses .env.example and the
# guard's allowlist never gets a say. Names: the .env entries of ALLOW in
# hooks/cc-secret-guard-hook.sh.
CURRENT="/dev/null"
PL1_HITS=$(python3 - "$SCRIPTS/../settings/managed-settings.json" <<'PY'
import fnmatch, json, sys
deny = json.load(open(sys.argv[1]))["permissions"]["deny"]
globs = [r[len("Read(**/"):-1] for r in deny if r.startswith("Read(**/") and r.endswith(")")]
if not globs:
    print("the policy has no Read(**/...) rules - the check would be vacuous")
for name in (".env.example", ".env.sample", ".env.template", ".env.dist"):
    for g in globs:
        if fnmatch.fnmatchcase(name, g):
            print(f"Read(**/{g}) refuses {name}")
PY
) || PL1_HITS="${PL1_HITS}; the check itself failed (exit non-zero)"
if [ -z "$PL1_HITS" ]; then pass "PL1 no fleet deny rule refuses a .env name the secret guard allow-lists"
else fail "PL1 no fleet deny rule refuses a .env name the secret guard allow-lists: $(echo "$PL1_HITS" | tr '\n' ';')"; fi

# PL2: the places a session could write to outlive itself - an SSH key or
# config, a user settings file, a binary that shadows the managed one on PATH -
# are refused to Claude's file tools on the fleet.
CURRENT="/dev/null"
PL2_MISSING=$(python3 - "$SCRIPTS/../settings/managed-settings.json" <<'PY'
import json, sys
deny = json.load(open(sys.argv[1]))["permissions"]["deny"]
for r in ("Edit(~/.ssh/**)", "Edit(~/.local/bin/**)",
          "Edit(~/.claude/settings.json)", "Edit(~/.claude/settings.local.json)"):
    if r not in deny:
        print(r)
PY
) || PL2_MISSING="${PL2_MISSING}; the check itself failed (exit non-zero)"
if [ -z "$PL2_MISSING" ]; then pass "PL2 the fleet policy refuses edits to persistence paths"
else fail "PL2 the fleet policy refuses edits to persistence paths - missing: $(echo "$PL2_MISSING" | tr '\n' ' ')"; fi

# PL3: the deny-list facts the documents state are derived from the policy
# files, not typed by hand. SETTINGS-REFERENCE.md 3.2 is the one home of the
# fleet count and must agree with its own table; ADMIN-SESSION.md lists the
# fleet rules the admin policy drops. A rule added to either policy without
# the document following fails here.
CURRENT="/dev/null"
PL3_ERR=$(python3 - "$SCRIPTS/.." <<'PY'
import json, re, sys
root = sys.argv[1]
fleet = json.load(open(root + "/settings/managed-settings.json"))["permissions"]["deny"]
admin = json.load(open(root + "/settings/managed-settings-admin.json"))["permissions"]["deny"]
ref = open(root + "/docs/SETTINGS-REFERENCE.md").read()
sec = ref.split("### 3.2 ", 1)[1].split("\n### ", 1)[0]
m = re.search(r"\*\*Class: Boundary\.\*\* (\d+) rules, in the (\w+) categories", sec)
words = {"five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9}
rows = [l for l in sec.splitlines() if l.startswith("| ") and not l.startswith("| Category") and not l.startswith("| ---")]
named = sum(len(re.findall(r"`[^`]+`", r.split(" | ")[1])) for r in rows)
if not m:
    print("SETTINGS-REFERENCE 3.2 no longer states the rule count")
else:
    if int(m.group(1)) != len(fleet):
        print(f"SETTINGS-REFERENCE 3.2 says {m.group(1)} rules, policy has {len(fleet)}")
    if words.get(m.group(2)) != len(rows):
        print(f"SETTINGS-REFERENCE 3.2 says {m.group(2)} categories, table has {len(rows)}")
if named != len(fleet):
    print(f"SETTINGS-REFERENCE 3.2 table names {named} rules, policy has {len(fleet)}")
adm = open(root + "/docs/ADMIN-SESSION.md").read()
blk = adm.split("The fleet rules dropped in the admin policy", 1)[1].split("```", 2)[1]
listed, kind = set(), None
for line in blk.splitlines():
    m2 = re.match(r"(Bash|Read|Edit):(.*)", line)
    if m2:
        kind, line = m2.group(1), m2.group(2)
    for tok in line.split():
        if tok.startswith("mcp__"):
            listed.add(tok)
        elif kind == "Bash":
            listed.add(f"Bash({tok} *)")
        elif kind:
            listed.add(f"{kind}({tok})")
dropped = {r for r in fleet if r not in admin}
if not dropped:
    print("the admin policy drops nothing - the check would be vacuous")
for r in sorted(dropped - listed):
    print(f"ADMIN-SESSION does not list dropped rule {r}")
for r in sorted(listed - dropped):
    print(f"ADMIN-SESSION lists {r}, which the admin policy does not drop")
PY
) || PL3_ERR="${PL3_ERR}; the check itself failed (exit non-zero)"
if [ -z "$PL3_ERR" ]; then pass "PL3 the documented deny-list counts and admin drop-list match the policy files"
else fail "PL3 the documented deny-list counts and admin drop-list match the policy files: $(echo "$PL3_ERR" | tr '\n' ';')"; fi

# settings/managed-settings.json is the live policy, so it must contain no
# placeholder at all. _comment_* keys are skipped the same way cc-install.sh's
# gate skips them: their text describes placeholders, and a search of the whole
# file would report on the comments whatever the real keys said.
CURRENT="/dev/null"
PLACEHOLDERS=$(python3 - "$SCRIPTS/../settings/managed-settings.json" <<'PY'
import json, sys
MARKERS = ("REPLACE-WITH", "REPLACE_WITH", "TODO", "FIXME", "CHANGEME")
def walk(n, p=""):
    if isinstance(n, dict):
        for k, v in n.items():
            if k.startswith("_comment"): continue
            yield from walk(v, f"{p}.{k}" if p else k)
    elif isinstance(n, list):
        for i, v in enumerate(n): yield from walk(v, f"{p}[{i}]")
    elif isinstance(n, str):
        if any(m in n.upper() for m in MARKERS) or n.startswith("<"):
            yield p
for x in walk(json.load(open(sys.argv[1]))): print(x)
PY
)
if [ -z "$PLACEHOLDERS" ]; then
  pass "live policy has no unreplaced placeholders (outside _comment_ keys)"
else
  fail "live policy still contains placeholders: $(echo "$PLACEHOLDERS" | tr '\n' ' ')"
fi

# The engineer's guide is the only document written for the people the policy
# governs, so it must not drift from it: every Bash command the policy denies or
# asks about is named in the guide, and the welcome banner points at the path
# cc-install.sh places the guide on. An empty rule list is a failure, not a pass.
CURRENT="/dev/null"
GUIDE_DRIFT=$(python3 - "$SCRIPTS/../settings/managed-settings.json" \
                        "$SCRIPTS/../docs/ENGINEER-GUIDE.md" <<'PY'
import json, re, sys
pol = json.load(open(sys.argv[1], encoding="utf-8"))
guide = open(sys.argv[2], encoding="utf-8").read()
perms = pol.get("permissions", {})
cmds = [m.group(1) for r in perms.get("deny", []) + perms.get("ask", [])
        for m in [re.fullmatch(r"Bash\((.+?) \*\)", r)] if m]
if not cmds:
    print("no Bash(... *) rules found in the policy - the check would be vacuous")
for c in cmds:
    if f"`{c}`" not in guide:
        print(f"guide does not name `{c}`")
PY
)
if [ -z "$GUIDE_DRIFT" ]; then
  pass "engineer's guide names every Bash command the policy denies or asks about"
else
  fail "engineer's guide drifted from the policy: $(echo "$GUIDE_DRIFT" | tr '\n' ';')"
fi
CURRENT="/dev/null"
GUIDE_DST=$(sed -n 's/^place "$SRC\/docs\/ENGINEER-GUIDE.md" "$CC_SHARE\/\([^"]*\)".*/\1/p' \
              "$SCRIPTS/cc-install.sh")
if [ -n "$GUIDE_DST" ] && python3 -c "
import json,sys
a=' '.join(json.load(open(sys.argv[1],encoding='utf-8'))['companyAnnouncements'])
sys.exit(0 if '/usr/local/share/claude-code/'+sys.argv[2] in a else 1)" \
     "$SCRIPTS/../settings/managed-settings.json" "$GUIDE_DST"; then
  pass "welcome banner points at the path cc-install.sh places the guide on"
else
  fail "welcome banner and cc-install.sh disagree on the guide path (placed as '$GUIDE_DST')"
fi

# The pin is written once, in the policy. A shipped Reference or Runsheet that
# spells the current pin goes stale at the next bump without failing anything
# (README and QUICKSTART both did). UPGRADES.md is the version record and
# internal/ the dated one; DOC-STYLE's version-literal rule names both.
CURRENT="/dev/null"
PIN_NOW=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["requiredMinimumVersion"])' \
            "$SCRIPTS/../settings/managed-settings.json" 2>/dev/null)
PIN_HITS=$(cd "$SCRIPTS/.." && git ls-files -- '*.md' ':!internal' ':!docs/UPGRADES.md' \
             | xargs grep -lF -- "$PIN_NOW" 2>/dev/null)
if [ -z "$PIN_NOW" ]; then
  fail "pin literal check: no requiredMinimumVersion in the policy - the check would be vacuous"
elif [ -z "$PIN_HITS" ]; then
  pass "no shipped Reference or Runsheet spells the current pin ($PIN_NOW)"
else
  fail "the current pin $PIN_NOW is spelled in: $(echo "$PIN_HITS" | tr '\n' ' ')- point at requiredMinimumVersion instead"
fi

# GOAL.md is the top of the repository and holds no detail: a detail there has
# a second home, and editing it would read as a change of direction. Absolute
# paths, versions, CC_* parameters, camelCase policy keys and any value the
# config template sets (a host, a group, an address) are detail. It must also rank at least one rule, and both front doors must point
# at it - an unreferenced top is one nobody reads.
CURRENT="/dev/null"
GOAL_VALUES=$(bash -c '. "$1" >/dev/null 2>&1; for v in $(compgen -v CC_); do printf "%s\t%s\n" "$v" "${!v}"; done' _ "$SCRIPTS/../config.example.sh")
GOAL_DRIFT=$(GOAL_VALUES="$GOAL_VALUES" python3 - "$SCRIPTS/.." <<'PY'
import os, re, sys
root = sys.argv[1]
goal = open(f"{root}/GOAL.md", encoding="utf-8").read()
for name, pat in [("absolute path", r"`/"), ("version number", r"\b\d+\.\d+\.\d+\b"),
                  ("CC_* parameter", r"\bCC_[A-Z_]+"), ("policy key", r"`[a-z]+[A-Z]\w*`")]:
    for m in re.finditer(pat, goal):
        print(f"GOAL.md holds a {name}: {m.group(0)!r}")
# A value of the config template is named by its key, never printed: on a real
# site it is that site's host, group or address.
values = [l.split("\t", 1) for l in os.environ["GOAL_VALUES"].splitlines() if "\t" in l]
if len(values) < 10:
    print("config.example.sh gave fewer than 10 values - the check would be vacuous")
for key, value in values:
    if len(value) >= 4 and not value.isdigit() and value in goal:
        print(f"GOAL.md holds the value of {key}")
rules = goal.split("## The rules", 1)
if len(rules) < 2 or not re.search(r"^1\. \*\*", rules[1], re.M):
    print("GOAL.md ranks no rules - the check would be vacuous")
for door in ("CLAUDE.md", "README.md"):
    if "GOAL.md" not in open(f"{root}/{door}", encoding="utf-8").read():
        print(f"{door} does not point at GOAL.md")
PY
)
if [ -z "$GOAL_DRIFT" ]; then
  pass "GOAL.md ranks its rules, holds no detail, and both front doors point at it"
else
  fail "GOAL.md drifted: $(echo "$GOAL_DRIFT" | tr '\n' ';')"
fi

# ================================================================ packaging
head2 "packaging and unit consistency"
UNIT="$SCRIPTS/../systemd/claude-code-healthcheck.service"
CURRENT="/dev/null"
# The COMMAND WORD, not the whole line: the unit now passes --metrics <path>,
# and this check is about where the binary is installed, not about its arguments.
EXECPATH=$(sed -n 's/^ExecStart=//p' "$UNIT" | awk '{print $1}')
if [ -n "$EXECPATH" ] && [ "$(basename "$EXECPATH")" = "cc-healthcheck.sh" ] \
   && grep -q "$(dirname "$EXECPATH")" "$SCRIPTS/../README.md"; then
  pass "unit ExecStart path matches the directory README installs to"
else
  fail "unit ExecStart ($EXECPATH) does not match the README install target"
fi

if command -v systemd-analyze >/dev/null 2>&1; then
  if systemd-analyze calendar "$(awk -F= '/^OnCalendar=/{print $2}' \
       "$SCRIPTS/../systemd/claude-code-healthcheck.timer")" >/dev/null 2>&1; then
    pass "timer OnCalendar expression is valid"
  else
    fail "timer OnCalendar expression is valid"
  fi
else
  skip "timer OnCalendar validation (systemd-analyze unavailable)"
fi

CURRENT="/dev/null"
if [ -f "$SCRIPTS/../systemd/claude-code-logrotate" ]; then
  pass "logrotate config is shipped (daily timer would otherwise grow the log forever)"
else
  fail "logrotate config is shipped"
fi
# logrotate exits 0 on an unknown directive and only prints `error:`, so the
# exit code alone proves nothing: the output is the assertion. The `su root
# root` directive makes -d switch euid, so it runs as root - real, or a user
# namespace. LR2 breaks a directive on purpose to prove LR1 can fail.
LR=()
if [ "$(id -u)" -eq 0 ]; then LR=(env)
elif unshare -r true 2>/dev/null; then LR=(unshare -r)
fi
if ! command -v logrotate >/dev/null 2>&1; then
  skip "LR1-LR2 logrotate config syntax (logrotate not installed)"
elif [ "${#LR[@]}" -eq 0 ]; then
  skip "LR1-LR2 logrotate config syntax (not root, and no user namespace for its su directive)"
else
  # Checked as the installer places it (0644): logrotate ignores a config that
  # is group-writable, which a checkout under the repository convention is.
  LRC="$WORK/lr.conf"
  install -m 0644 "$SCRIPTS/../systemd/claude-code-logrotate" "$LRC"
  "${LR[@]}" logrotate -d -s "$WORK/lr.state" "$LRC" > "$WORK/lr.out" 2>&1
  assert_rc    "LR1 logrotate -d accepts the shipped config" "$?" 0 "$WORK/lr.out"
  assert_lacks "LR1 and reports no error in it" "$WORK/lr.out" "error:"
  sed 's/^\(\s*\)rotate /\1rotat /' "$LRC" > "$WORK/lr.bad"
  "${LR[@]}" logrotate -d -s "$WORK/lr.state" "$WORK/lr.bad" > "$WORK/lr.out" 2>&1
  assert_has   "LR2 a misspelt directive is reported (the LR1 check can fail)" "$WORK/lr.out" "unknown option 'rotat'"
fi

# Every script must carry a bash shebang. Either form is accepted.
#
# Most of these use `#!/usr/bin/env bash`. cc-admin-session.sh deliberately
# uses the absolute `#!/bin/bash`: it runs as root under sudo and hands out a
# privileged session, so it should not resolve its interpreter through PATH.
# sudo's secure_path makes that safe in practice, but "in practice" is a weak
# guarantee for the one script in this repo whose whole purpose is escalation.
# Both forms are accepted, so the glob below covers that script too.
for f in "$SCRIPTS"/cc-*.sh; do
  CURRENT="/dev/null"
  if head -1 "$f" | grep -qE '^#!(/usr/bin/env bash|/bin/bash)$'; then
    pass "shebang present: $(basename "$f")"
  else
    fail "shebang present: $(basename "$f") (got: $(head -1 "$f"))"
  fi
done

# --- H2c: the browser drop-ins must agree. tcsh does not source *.sh, and the
# login shell may be tcsh, so a candidate added to one sibling and not the other
# gives users of one shell a working OAuth login and users of the other a silent failure.
PD="$WORK/profiled"; mkdir -p "$PD"
mk_browser() {  # mk_browser <sh-target> <csh-target>
  printf 'BROWSER="%s"\nexport BROWSER\n' "$1" > "$PD/claude-code-browser.sh"
  printf 'setenv BROWSER "%s"\n' "$2" > "$PD/claude-code-browser.csh"
}
FX="$WORK/h2c"; mk_passwd "$FX"; ETC2C="$WORK/h2cetc"; mkdir -p "$ETC2C"
mk_browser /bin/agreed /bin/agreed
O=$(run_hc "$ETC2C" "$FX" CC_PROFILED="$PD")
if command -v tcsh >/dev/null 2>&1; then
  assert_has "H2c agreeing drop-ins are reported, not flagged" "$O" "both drop-ins resolve BROWSER to /bin/agreed"
  mk_browser /bin/one /bin/two
  O=$(run_hc "$ETC2C" "$FX" CC_PROFILED="$PD")
  assert_has "H2c disagreeing drop-ins are flagged" "$O" "browser drop-ins disagree"
else
  # Without tcsh only one sibling can be evaluated, so "agree" is unprovable -
  # the check must say so rather than claim agreement.
  assert_has   "H2c without tcsh, only the sh drop-in is evaluated and that is said" "$O" "tcsh is not installed; only the sh drop-in could be evaluated"
  assert_lacks "H2c and agreement is not claimed" "$O" "both drop-ins resolve BROWSER"
  skip "H2c agree/disagree verdicts (no tcsh on this host to evaluate the .csh sibling)"
fi
rm -f "$PD/claude-code-browser.csh"
O=$(run_hc "$ETC2C" "$FX" CC_PROFILED="$PD")
assert_has "H2c a missing sibling is flagged" "$O" "only one browser drop-in is installed"

# --- H2d: the admin policy DIRECTORY mode is the control - the file inside it
# is deliberately 0644, so 0700 on the directory is the only thing making the
# policy unbrowsable. An installer that re-opened it to 0755 would go unnoticed on the
# host: cc-admin-session.sh asserts the mode, but only at launch and only for
# whoever tried.
# The three cases below are the three answers this check must be able to give -
# absent, correct, and wrong - because "not installed here" and "checked and
# clean" must never read the same.
AD="$WORK/h2d-admin"
O=$(run_hc "$ETC2C" "$FX" CC_ETC_ADMIN="$WORK/h2d-nonexistent")
assert_has "H2d no admin dir is a skip, not a pass" "$O" "no admin policy directory on this host"
mkdir -p "$AD"; chmod 0700 "$AD"
O=$(run_hc "$ETC2C" "$FX" CC_ETC_ADMIN="$AD")
# Owner is asserted alongside the mode, so a non-root suite run cannot claim the
# clean answer - it correctly reports the ownership it actually found.
if [ "$(id -u)" -eq 0 ]; then
  assert_has "H2d a 0700 root dir is reported as checked" "$O" "is 0700 root:root"
else
  assert_has "H2d a non-root-owned admin dir is flagged, not assumed" "$O" "expected '700 root:root'"
fi
chmod 0755 "$AD"
O=$(run_hc "$ETC2C" "$FX" CC_ETC_ADMIN="$AD")
assert_has "H2d a 0755 admin dir is flagged" "$O" "expected '700 root:root'"
assert_has "H2d and the flag says how to fix it" "$O" "chmod 0700 $AD"
assert_rc  "H2d a wrong admin dir mode fails the run" "$(rc)" 1 "$O"

# ================================================================ cc-report
head2 "cc-report.sh"

# The report is only worth reading if two things hold: a check that did not run
# is never reported as clean, and the verdict cannot disagree with the ledger it
# is derived from. Every case below is one of those two.
RPSB="$WORK/rpsbin"; mkdir -p "$RPSB"
mk_rp_stub() {  # mk_rp_stub <name> <exit> <stdout...>
  local n="$1" rc="$2"; shift 2
  { printf '#!/usr/bin/env bash\n'; for l in "$@"; do printf 'printf "%%s\\n" %q\n' "$l"; done; printf 'exit %s\n' "$rc"; } > "$RPSB/$n"
  chmod 755 "$RPSB/$n"
}
# A clean host: watch says current, health check healthy, probes all ok.
mk_rp_clean() {
  mk_rp_stub cc-version-watch.sh 0 "cc-version-watch: status=current pin=9.9.9 repo_head=9.9.9 above_pin=0"
  mk_rp_stub cc-healthcheck.sh   0 "[1] Installed version" "  Audited 11 account(s)" "RESULT: healthy"
  mk_rp_stub cc-bump-audit.sh    0 "  ok      A1 compiled-policy-path: fine" "  ok      A5 private-install-floor: 5 private install(s) found, 0 below the floor"
}
RPLOG="$WORK/rplog"; mkdir -p "$RPLOG/denied" "$RPLOG/activity" "$RPLOG/reports"
RPREPO="$WORK/rprepo"; mkdir -p "$RPREPO/settings" "$RPREPO/hooks"
printf '{"requiredMinimumVersion":"9.9.9"}\n' > "$RPREPO/settings/managed-settings.json"
printf '{"requiredMinimumVersion":"9.9.9"}\n' > "$RPREPO/settings/managed-settings-admin.json"

# A COVERING logrotate fixture, so these cases do not depend on the host's own
# config - which is exactly what RP10 tests, and what would otherwise leak into
# RP3.
RPLRD="$WORK/rp-logrotate.d"; mkdir -p "$RPLRD"; RPLR="$RPLRD/claude-code"
cat > "$RPLR" <<EOF
$RPLOG/activity/*.jsonl
$RPLOG/denied/*.jsonl
{
    weekly
    rotate 52
    copytruncate
    missingok
}
$RPLOG/admin.log {
    monthly
    rotate 24
    missingok
}
EOF
run_rp() {   # run_rp <outdir> [args...]
  local od="$1"; shift
  local out="$WORK/rp.$RANDOM.out"
  env CC_LOGROTATE="$RPLRD" \
      CC_SBIN="$RPSB" CC_LOGDIR="$RPLOG" CC_REPO="$RPREPO" CC_REPORT_DIR="$od" \
      CC_ETC="$WORK/rpetc" CC_ETC_ADMIN="$WORK/rpetcadmin" CC_MOUNTINFO=/dev/null \
      CC_DNF_BIN="$WORK/rp-nodnf" CC_REPO_GROUP="no-such-group-$$" \
      bash "$SCRIPTS/cc-report.sh" --format text "$@" > "$out" 2>&1
  echo $? > "$WORK/rc"
  echo "$out"
}
mkdir -p "$WORK/rpetc" "$WORK/rpetcadmin"

# --- RP13: the repo section reads and RUNS the shared checkout, which the group
# can write - its scripts and its .git/config (core.fsmonitor names a command
# git runs). As root it must run them only as CC_REPO_RUNAS, and with no such
# account it must not run them at all. Root is simulated by an `id` stub on
# PATH; `runuser` is a stub that records the account and runs the command.
RP13="$WORK/rp13"; mkdir -p "$RP13/repo/bin" "$RP13/repo/settings" "$RP13/fakeroot"
git -C "$RP13/repo" init -q 2>/dev/null
cp "$RPREPO/settings/"*.json "$RP13/repo/settings/"
printf '#!/usr/bin/env bash\npwd > "%s/ci-ran"\nexit 0\n' "$RP13" > "$RP13/repo/bin/cc-ci-check.sh"
printf '#!/bin/sh\n[ "$1" = "-u" ] && [ $# -eq 1 ] && { echo 0; exit 0; }\nexec /usr/bin/id "$@"\n' > "$RP13/fakeroot/id"
printf '#!/bin/sh\necho "$2" >> "%s/runuser-as"\nshift 3\nexec "$@"\n' "$RP13" > "$RP13/fakeroot/runuser"
chmod 755 "$RP13/fakeroot/id" "$RP13/fakeroot/runuser"
run_rp13() {  # run_rp13 <CC_REPO_RUNAS> [as-root]
  rm -f "$RP13/ci-ran" "$RP13/runuser-as"
  local p="$PATH"; [ "${2:-}" = as-root ] && p="$RP13/fakeroot:$PATH"
  ( cd / && env PATH="$p" CC_REPO_RUNAS="$1" CC_LOGROTATE="$RPLRD" CC_SBIN="$RPSB" CC_LOGDIR="$RPLOG" \
      CC_REPO="$RP13/repo" CC_REPORT_DIR="$RP13/out" CC_ETC="$WORK/rpetc" CC_ETC_ADMIN="$WORK/rpetcadmin" \
      CC_MOUNTINFO=/dev/null CC_DNF_BIN="$WORK/rp-nodnf" CC_REPO_GROUP="no-such-group-$$" \
      bash "$SCRIPTS/cc-report.sh" --format text --section repo --dry-run > "$RP13/out.txt" 2>&1 )
  echo "$RP13/out.txt"
}
O=$(run_rp13 "" as-root)
assert_rc  "RP13 as root with no CC_REPO_RUNAS the checkout's CI is NOT run" "$([ -e "$RP13/ci-ran" ] && echo 1 || echo 0)" 0 "$O"
assert_has "RP13 and the skip says why, naming the key" "$O" "CC_REPO_RUNAS"
if [ -n "$NONROOT" ]; then
  O=$(run_rp13 "$NONROOT" as-root)
  assert_has "RP13 as root with CC_REPO_RUNAS the CI runs as that account" "$RP13/runuser-as" "$NONROOT"
  assert_has "RP13 and from inside the checkout, not from the unit's cwd" "$RP13/ci-ran" "$RP13/repo"
else
  skip "RP13 CC_REPO_RUNAS honoured (running as root, and no non-root account resolves)"
fi
O=$(run_rp13 root as-root)
assert_rc  "RP13 CC_REPO_RUNAS=root is refused, not obeyed" "$([ -e "$RP13/ci-ran" ] && echo 1 || echo 0)" 0 "$O"
if [ "$(id -u)" -ne 0 ]; then
  O=$(run_rp13 "")
  assert_has "RP13 unprivileged, the CI runs as the caller from inside the checkout" "$RP13/ci-ran" "$RP13/repo"
else
  skip "RP13 unprivileged CI run (this run IS root - the unprivileged branch cannot be reached)"
fi

# --- RP14: anyone can create a file in the 1733 log directories, and the
# report reads them as root. A FIFO there hung the read forever; a symlink was
# followed; a file not owned by the user it is named for was counted as theirs.
# Each is reported as LOG-07 and never read.
R14="$WORK/rp14"; mkdir -p "$R14/denied" "$R14/activity" "$R14/reports"
printf '{"detail":"x"}\n' > "$R14/denied/$(id -un).jsonl"
mkfifo "$R14/denied/fifo-user.jsonl"; ln -s /etc/passwd "$R14/activity/link-user.jsonl"
timeout 60 env CC_LOGROTATE="$RPLRD" CC_SBIN="$RPSB" CC_LOGDIR="$R14" CC_REPO="$RPREPO" CC_REPORT_DIR="$WORK/rp14-out" \
    CC_ETC="$WORK/rpetc" CC_ETC_ADMIN="$WORK/rpetcadmin" CC_MOUNTINFO=/dev/null CC_DNF_BIN="$WORK/rp-nodnf" \
    CC_REPO_GROUP="no-such-group-$$" bash "$SCRIPTS/cc-report.sh" --format text --section log --dry-run > "$R14/out.txt" 2>&1
echo $? > "$WORK/rc"
assert_rc  "RP14 a FIFO in a log directory does not hang the report (124 = it hung; 1 = ran, with an alert)" "$(rc)" 1 "$R14/out.txt"
assert_has "RP14 a planted FIFO or symlink is an alert, named" "$R14/out.txt" "LOG-07"
assert_has "RP14 and the count says how many" "$R14/out.txt" "2 file(s)"

# --- RP1: --list-rules answers at all
O=$(run_rp "$WORK/rp-out1" --list-rules)
assert_rc  "RP1 --list-rules exits 0" "$(rc)" 0 "$O"
assert_has "RP1 and names a rule id with its level" "$O" "INS-01 ALERT"

# --- RP11: --list-rules must equal the set of ids the code can actually raise,
# IN BOTH DIRECTIONS. Printing a hand-written heredoc from inside the script
# stops it drifting from a DOCUMENT; it does nothing to stop it drifting from
# the code, and it had - two ids advertised that no line emitted (one of them
# VER-06, the half-done-bump alert), and three ids that fired without being
# listed. All three of those were SKIP rules: "could not be answered" is the
# class a reader most needs catalogued, and it was the class that went missing.
# This case is what makes "it cannot drift" true rather than asserted.
# Ids are read from CALL SITES, not from any occurrence in the file, so that
# naming an id in a comment cannot satisfy or break the assertion.
RP_ADV=$(sed -n '/cat <<.RULES/,/^RULES$/p' "$SCRIPTS/cc-report.sh" | grep -oE '^[A-Z]{2,4}-[0-9]{2}' | sort -u)
RP_EMIT=$(grep -oE '\b(alert|fyi|skipc)[[:space:]]+[A-Z]{2,4}-[0-9]{2}\b' "$SCRIPTS/cc-report.sh" |
          grep -oE '[A-Z]{2,4}-[0-9]{2}' | sort -u)
RP_ONLY_ADV=$(comm -23 <(printf '%s\n' "$RP_ADV") <(printf '%s\n' "$RP_EMIT") | tr '\n' ' ')
RP_ONLY_EMIT=$(comm -13 <(printf '%s\n' "$RP_ADV") <(printf '%s\n' "$RP_EMIT") | tr '\n' ' ')
CURRENT="$SCRIPTS/cc-report.sh"
if [ -n "${RP_ONLY_ADV// /}" ]; then
  fail "RP11 no rule is advertised that the code cannot raise (advertised only: $RP_ONLY_ADV)"
else
  pass "RP11 no rule is advertised that the code cannot raise"
fi
if [ -n "${RP_ONLY_EMIT// /}" ]; then
  fail "RP11 no rule fires that --list-rules omits (emitted only: $RP_ONLY_EMIT)"
else
  pass "RP11 no rule fires that --list-rules omits"
fi

# --- RP12: VER-06, the rule RP11 caught as advertised-and-unimplemented.
# cc-bump-audit prints its section [A] pin-coherence failures with NO probe id
# and on stderr, so the probes.tsv parser drops them and PRB_RC was captured and
# never read: a half-done bump was invisible to the report that advertises a
# rule for it. It must be read as a STANDING condition - a half-done bump FAILs
# identically every week, so a transition rule like PRB-01 goes quiet after the
# first report puts it in baseline.
mk_rp_clean
mk_rp_stub cc-bump-audit.sh 1 \
  "  ok      A1 compiled-policy-path: fine" \
  "  FAIL    approved-version (2.1.232) and the policy floor (2.1.236) disagree - a half-done bump" \
  "  ok      A5 private-install-floor: 5 private install(s) found, 0 below the floor"
O=$(run_rp "$WORK/rp-out12")
assert_has "RP12 a half-done bump raises VER-06" "$O" "VER-06"
assert_has "RP12 and quotes the coherence failure"  "$O" "half-done bump"
assert_rc  "RP12 an alert makes the run exit 1"     "$(rc)" 1 "$O"
# A probe FAIL carries an id and belongs to PRB-0x; VER-06 must not also claim it,
# or every probe regression would be double-reported as a version defect.
mk_rp_clean
mk_rp_stub cc-bump-audit.sh 1 \
  "  ok      A1 compiled-policy-path: fine" \
  "  FAIL    A3 policy-baseline-sha: deployed policy does not match its baseline" \
  "  ok      A5 private-install-floor: 5 private install(s) found, 0 below the floor"
O=$(run_rp "$WORK/rp-out12b")
assert_lacks "RP12b a probe FAIL is not re-reported as VER-06" "$O" "VER-06"
mk_rp_clean

# --- RP2: usage discipline
O=$(run_rp "$WORK/rp-out1" --keep banana);  assert_rc "RP2 a non-numeric --keep exits 2" "$(rc)" 2 "$O"
O=$(run_rp "$WORK/rp-out1" --format banana); assert_rc "RP2 an unknown --format exits 2" "$(rc)" 2 "$O"
O=$(run_rp "$WORK/rp-out1" --nonsense);      assert_rc "RP2 an unknown flag exits 2" "$(rc)" 2 "$O"

# --- RP3: a clean host exits 0 and says so in both verdict fields
mk_rp_clean
OD="$WORK/rp-out3"
O=$(run_rp "$OD")
assert_rc  "RP3 a clean run exits 0"                  "$(rc)" 0 "$O"
assert_has "RP3 the bump verdict is a field, not prose" "$O" "BUMP: ok to plan"
assert_has "RP3 and the management verdict too"         "$O" "REPORT TO MANAGEMENT: no major errors flagged"
CURRENT="$O"
if ls "$OD"/report-*.md >/dev/null 2>&1 && ls "$OD"/report-*.json >/dev/null 2>&1; then
  pass "RP3 both artefacts are written"
else fail "RP3 both artefacts are written"; fi
if [ -r "$OD/latest.json" ] && [ -r "$OD/state.json" ]; then
  pass "RP3 latest.json and state.json are updated on a full run"
else fail "RP3 latest.json and state.json are updated on a full run"; fi

# --- RP4: an alert must change the exit code AND both verdicts. This is the
# ledger-to-verdict link: if they could disagree, the report would be unusable.
mk_rp_stub cc-bump-audit.sh 0 "  ok      A5 private-install-floor: 5 private install(s) found, 2 below the floor"
OD4="$WORK/rp-out4"
O=$(run_rp "$OD4")
assert_rc  "RP4 an alert exits 1"                    "$(rc)" 1 "$O"
assert_has "RP4 the alert is in the ledger"          "$O" "[ALERT] INS-01"
assert_has "RP4 the bump verdict holds, naming the rule" "$O" "BUMP: hold — INS-01"
assert_has "RP4 and management is told it needs an owner" "$O" "need a named owner"

# --- RP5: THE DENOMINATOR RULE. A collector that could not run is listed in
# section 11 and raised as an FYI - never absent, never silently clean.
rm -f "$RPSB/cc-healthcheck.sh"
OD5="$WORK/rp-out5"
O=$(run_rp "$OD5")
CURRENT="$O"
if grep -qE '^cc-healthcheck\.sh +skipped' "$O"; then
  pass "RP5 a missing collector is named in the run inventory"
else
  fail "RP5 a missing collector is named in the run inventory"
fi
assert_has "RP5 and raised as a condition"                          "$O" "RUN-04  collector 'cc-healthcheck.sh' did not run"
mk_rp_clean

# --- RP6: a PARTIAL run must not move latest.* or state.json - the same rule
# CC_CI_ONLY follows, because a selective pass is not a pass.
OD6="$WORK/rp-out6"; mkdir -p "$OD6"
O=$(run_rp "$OD6" --section ver)
assert_has "RP6 a partial run says so in the header" "$O" "PARTIAL"
CURRENT="$O"
if [ -e "$OD6/latest.json" ] || [ -e "$OD6/state.json" ]; then
  fail "RP6 and does not update latest.* or state.json"
else
  pass "RP6 and does not update latest.* or state.json"
fi

# --- RP7: the delta comes from the previous report's JSON, and a stale
# predecessor is itself an alert - otherwise a missed run is invisible.
OD7="$WORK/rp-out7"; mkdir -p "$OD7"
printf '{"generated_at":"2020-01-01T00:00:00+00:00","condition_ids":["INS-01"],"probes":{"A1":"ok"}}\n' > "$OD7/state.json"
mk_rp_stub cc-bump-audit.sh 0 "  FAIL    A1 compiled-policy-path: gone" "  ok      A5 private-install-floor: 5 private install(s) found, 0 below the floor"
O=$(run_rp "$OD7")
assert_has "RP7 a missed run is an alert"                  "$O" "RUN-01"
assert_has "RP7 a probe that regressed from ok to FAIL is an alert" "$O" "PRB-01"
assert_has "RP7 and a condition that cleared counts as resolved"    "$O" "RESOLVED 1"

# --- RP7b: a condition that is STILL PRESENT must never count as resolved, and
# a late-appended one must be able to count as NEW. A delta snapshotted before
# RUN-04 and the PRB-0x rules are written can never show those two as new and
# reports them resolved for ever after - so a probe regression, the one thing
# the bump procedure calls work, would not show up in the delta at all.
OD7B="$WORK/rp-out7b"; mkdir -p "$OD7B"
printf '{"generated_at":"%s","condition_ids":["RUN-04"],"probes":{}}\n' "$(date -Is)" > "$OD7B/state.json"
mk_rp_clean
O=$(run_rp "$OD7B")
assert_has "RP7b a standing condition is unchanged, not resolved" "$O" "RESOLVED 0 | UNCHANGED 1"
CURRENT="$O"
# And the arithmetic must close: new + unchanged == the number of distinct ids.
if python3 - "$O" <<'PYCHK'
import re, sys
t = open(sys.argv[1]).read()
m = re.search(r"NEW (\d+) \| RESOLVED (\d+) \| UNCHANGED (\d+)", t)
# The level label contains a space ("[FYI  ]"), so match the id rather than
# splitting on whitespace and hoping.
ids = set(re.findall(r"^\[(?:ALERT|FYI|SKIP)\s*\]\s+(\S+)", t, re.M))
sys.exit(0 if m and int(m.group(1)) + int(m.group(3)) == len(ids) else 1)
PYCHK
then pass "RP7b new + unchanged equals the number of conditions raised"
else fail "RP7b new + unchanged equals the number of conditions raised"
fi

# --- RP7c: probe verdicts are only comparable between runs of the SAME session
# type. A3 and A7 answer "ok" from a plain shell and "skip" from a privileged
# session by design, so comparing across the two raised PRB-02 on every alternate
# run - an alert that fires on a schedule, which teaches people to ignore alerts.
OD7C="$WORK/rp-out7c"; mkdir -p "$OD7C"
printf '{"generated_at":"%s","condition_ids":[],"probes":{"A3":"ok"},"admin_ns":1}\n' "$(date -Is)" > "$OD7C/state.json"
mk_rp_stub cc-bump-audit.sh 0 "  skip    A3 policy-baseline-sha: privileged session" "  ok      A5 private-install-floor: 5 private install(s) found, 0 below the floor"
O=$(run_rp "$OD7C")   # run_rp forces CC_MOUNTINFO=/dev/null, so this run is PLAIN
assert_has "RP7c a cross-session-type comparison is skipped, with the reason" "$O" "PRB-00"
CURRENT="$O"
if grep -q "PRB-02" "$O"; then
  fail "RP7c and does not raise a probe regression that is only a session difference"
else
  pass "RP7c and does not raise a probe regression that is only a session difference"
fi
# Same session type, genuine regression: the alert must still fire.
OD7D="$WORK/rp-out7d"; mkdir -p "$OD7D"
printf '{"generated_at":"%s","condition_ids":[],"probes":{"A3":"ok"},"admin_ns":0}\n' "$(date -Is)" > "$OD7D/state.json"
O=$(run_rp "$OD7D")
assert_has "RP7c a real regression within one session type still alerts" "$O" "PRB-02"
mk_rp_clean

# --- RP8: --dry-run leaves the real output directory untouched
OD8="$WORK/rp-out8"; mkdir -p "$OD8"
mk_rp_clean
O=$(run_rp "$OD8" --dry-run)
CURRENT="$O"
if [ -n "$(ls -A "$OD8" 2>/dev/null)" ]; then
  fail "RP8 --dry-run writes nothing into the output directory"
else
  pass "RP8 --dry-run writes nothing into the output directory"
fi
assert_has "RP8 and says it was a dry run" "$O" "DRY RUN"

# --- RP10: "the config exists and parses" is not "the logs are rotated". A
# config that rotates the health log and the audit reports and names NEITHER
# evidence log leaves the audit trail unrotated while a check of "exists and
# parses" reports fine. The rule reads the stanzas, not the file's presence.
LRDIR="$WORK/lr"; mkdir -p "$LRDIR"
cat > "$LRDIR/claude-code" <<EOF
$RPLOG/healthcheck.log {
    weekly
    rotate 26
    missingok
}
EOF
mk_rp_clean
OD10="$WORK/rp-out10"
O=$(env CC_SBIN="$RPSB" CC_LOGDIR="$RPLOG" CC_REPO="$RPREPO" CC_REPORT_DIR="$OD10" \
        CC_ETC="$WORK/rpetc" CC_ETC_ADMIN="$WORK/rpetcadmin" CC_MOUNTINFO=/dev/null \
        CC_DNF_BIN="$WORK/rp-nodnf" CC_REPO_GROUP="no-such-group-$$" \
        CC_LOGROTATE="$LRDIR" \
        bash "$SCRIPTS/cc-report.sh" --format text > "$WORK/rp10.out" 2>&1; echo $? > "$WORK/rc"; echo "$WORK/rp10.out")
assert_has "RP10 a config that names no evidence log is an alert" "$O" "has no stanza for:"
assert_has "RP10 and it names which one is missing"               "$O" "activity"
assert_has "RP10 the admin-session log is an evidence log too"    "$O" "admin.log"
# And the other direction: a config that DOES name them must not alert.
cat >> "$LRDIR/claude-code" <<EOF
$RPLOG/activity/*.jsonl
$RPLOG/denied/*.jsonl
{
    weekly
    rotate 52
    copytruncate
    missingok
}
$RPLOG/admin.log {
    monthly
    rotate 24
    missingok
}
EOF
O=$(env CC_SBIN="$RPSB" CC_LOGDIR="$RPLOG" CC_REPO="$RPREPO" CC_REPORT_DIR="$WORK/rp-out10b" \
        CC_ETC="$WORK/rpetc" CC_ETC_ADMIN="$WORK/rpetcadmin" CC_MOUNTINFO=/dev/null \
        CC_DNF_BIN="$WORK/rp-nodnf" CC_REPO_GROUP="no-such-group-$$" \
        CC_LOGROTATE="$LRDIR" \
        bash "$SCRIPTS/cc-report.sh" --format text > "$WORK/rp10b.out" 2>&1; echo $? > "$WORK/rc"; echo "$WORK/rp10b.out")
CURRENT="$O"
if grep -q "has no stanza for:" "$O"; then
  fail "RP10 a covering config does not alert"
else
  pass "RP10 a covering config does not alert"
fi

# --- RP9: when the group does not resolve, reports must go root-only and SAY so,
# never fall back to world-readable.
O=$(run_rp "$WORK/rp-out9")
assert_has "RP9 an unresolvable group is reported, not silently widened" "$O" "does not resolve"

# --- RP15: the JSON is built from values, never by splicing shell text
# into Python source. A collector line carrying quotes and a backslash broke the
# program, and the report still exited as if it had written its JSON.
mk_rp_clean
mk_rp_stub cc-version-watch.sh 0 'cc-version-watch: status=current pin=9.9.9 repo_head=9.9.9 above_pin=0 note="""x\" '"'y'"
O=$(run_rp "$WORK/rp-out15")
CURRENT="$O"
if python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
sys.exit(0 if d["version"]["line"].endswith("note=\"\"\"x\\\" '"'"'y'"'"'") else 1)' "$WORK/rp-out15/latest.json" 2>/dev/null; then
  pass "RP15 a collector line with quotes and a backslash lands in the JSON verbatim"
else fail "RP15 a collector line with quotes and a backslash lands in the JSON verbatim"; fi
mk_rp_clean
# RP15b: a JSON that could not be written is "no answer" (3), and latest.* keeps
# the last good report rather than a markdown file with no JSON beside it.
mkdir -p "$WORK/rp-out15b/report-20260101-000000.json"
printf 'previous\n' > "$WORK/rp-out15b/latest.json"
printf 'previous-md\n' > "$WORK/rp-out15b/latest.md"
O=$(CC_NOW=2026-01-01T00:00:00+00:00 run_rp "$WORK/rp-out15b")
assert_rc  "RP15b a JSON that cannot be written exits 3" "$(rc)" 3 "$O"
assert_has "RP15b and says so" "$O" "could not write the JSON"
assert_has "RP15b and latest.json is not moved" "$WORK/rp-out15b/latest.json" "previous"
assert_has "RP15b and latest.md is not moved either" "$WORK/rp-out15b/latest.md" "previous-md"
# RP16: the health check's "could not run" (exit 3) is an alert, not a quiet
# ledger built from no data.
mk_rp_clean
mk_rp_stub cc-healthcheck.sh 3 "cc-healthcheck.sh: cannot write the report /x - no check was run"
O=$(run_rp "$WORK/rp-out16" --dry-run)
assert_has "RP16 a health check that could not run is an alert" "$O" "HLT-08"
assert_rc  "RP16 and the report exits 1" "$(rc)" 1 "$O"

# RP17: the summary's sandbox clause is read from the deployed policy. A site
# that enabled the sandbox must not be told it is disabled, and a policy that
# cannot be read is "not read", never one of the two answers.
mk_rp_clean
rm -f "$WORK/rpetc/managed-settings.json"   # an earlier case may have deployed one
O=$(run_rp "$WORK/rp-out17" --dry-run)
assert_has "RP17 with no deployed policy the sandbox state is not read, and says so" "$O" "sandbox state not read"
printf '{"sandbox":{"enabled":true}}\n' > "$WORK/rpetc/managed-settings.json"
O=$(run_rp "$WORK/rp-out17" --dry-run)
assert_has   "RP17 an enabled sandbox is reported as enabled" "$O" "sandbox enabled"
assert_lacks "RP17 and not as disabled" "$O" "sandbox disabled"
printf '{"sandbox":{"enabled":false}}\n' > "$WORK/rpetc/managed-settings.json"
O=$(run_rp "$WORK/rp-out17" --dry-run)
assert_has "RP17 a disabled sandbox is reported as disabled, with its record" "$O" "sandbox disabled by decision (docs/SANDBOX-DECISION.md)"
printf '{"sandbox":{}}\n' > "$WORK/rpetc/managed-settings.json"
O=$(run_rp "$WORK/rp-out17" --dry-run)
assert_has "RP17 a policy that does not set the key is not read as either" "$O" "sandbox state not read"
rm -f "$WORK/rpetc/managed-settings.json"
mk_rp_clean

# ================================================================ cc-version-watch
head2 "cc-version-watch.sh"

# The watcher's whole job is to be believed: "nothing newer" and "I could not
# tell" must never look alike, because the first is a reason to relax and the
# second is a reason to look. Every case below is one of those two being
# mistaken for the other.
mk_dnf_watch() {   # mk_dnf_watch <path> <version-to-report|-> [stderr-text]
  cat > "$1" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "\$CC_TEST_DNF_CALLS"
if [ -n "${3:-}" ]; then printf '%s\n' "${3:-}" >&2; exit 1; fi
[ "${2}" = "-" ] && exit 0
printf '%s' "${2}"
EOF
  chmod 755 "$1"
}
mk_watch_etc() {   # mk_watch_etc <dir> <pin|-> [approved]
  mkdir -p "$1"
  if [ "$2" = "-" ]; then printf '{}\n' > "$1/managed-settings.json"
  else printf '{"requiredMinimumVersion":"%s"}\n' "$2" > "$1/managed-settings.json"; fi
  [ -n "${3:-}" ] && printf '%s\n' "$3" > "$1/approved-version"
  return 0
}
run_watch() {   # run_watch <etcdir> <dnfstub> [args...]
  local etc="$1" dnfb="$2"; shift 2
  local out="$WORK/watch.$RANDOM.out"
  : > "$WORK/watch.calls"
  env CC_ETC="$etc" CC_DNF_BIN="$dnfb" CC_RPM_BIN="$WORK/rpm-236" CC_NO_NETWORK=1 \
      CC_REPORT="$WORK/watch-report.json" CC_TEST_DNF_CALLS="$WORK/watch.calls" \
      bash "$SCRIPTS/cc-version-watch.sh" "$@" >"$out" 2>&1
  echo $? > "$WORK/rc"
  echo "$out"
}

WETC="$WORK/watchetc"; mk_watch_etc "$WETC" "2.1.236" "2.1.236"
mk_dnf_watch "$WORK/dnf-same" "2.1.236"
mk_dnf_watch "$WORK/dnf-newer" "2.1.240"
mk_dnf_watch "$WORK/dnf-none" "-"
mk_dnf_watch "$WORK/dnf-netfail" "-" "Failed to synchronize cache for repo 'claude-code'"

# --- W1: no pin means CANNOT TELL, never "we are current"
WETC0="$WORK/watchetc-nopin"; mk_watch_etc "$WETC0" "-"
O=$(run_watch "$WETC0" "$WORK/dnf-same")
assert_rc  "W1  a policy with no floor exits 3 (unknown)" "$(rc)" 3 "$O"
assert_has "W1  and says the pin could not be read"       "$O" "no requiredMinimumVersion"

# --- W2: head equals pin - the quiet, normal case
O=$(run_watch "$WETC" "$WORK/dnf-same")
assert_rc  "W2  nothing above the pin exits 0" "$(rc)" 0 "$O"
assert_has "W2  and says so"                   "$O" "nothing above the pin is published"

# --- W3: THE FINDING. Non-zero so a timer surfaces it, and it names the version.
O=$(run_watch "$WETC" "$WORK/dnf-newer")
assert_rc  "W3  a version above the pin exits 1" "$(rc)" 1 "$O"
assert_has "W3  and names it"                    "$O" "2.1.240 > 2.1.236"
assert_has "W3  and points at the procedure, not a decision" "$O" "OPERATIONS 3.1"

# --- W4: a repository that cannot be reached must NOT read as "current". dnf can
# answer from cache after a failed refresh, which is a stale number wearing a
# fresh look - the single most dangerous outcome for this script.
O=$(run_watch "$WETC" "$WORK/dnf-netfail")
assert_rc  "W4  an unreachable repository exits 3, not 0" "$(rc)" 3 "$O"
CURRENT="$O"
if grep -qE "could not be (reached|queried)" "$O"; then
  pass "W4  and says the number would be a guess"
else
  fail "W4  and says the number would be a guess"
fi

# --- W5: the query must be arch-filtered and versionlock-blind. Without the
# first, the other architecture's build of the SAME version reads as "newer";
# without the second, a locked host answers "nothing newer" forever, which is
# precisely the blindness this script exists to remove.
O=$(run_watch "$WETC" "$WORK/dnf-same")
CURRENT="$WORK/watch.calls"
if grep -q -- "--arch=$(uname -m)" "$WORK/watch.calls"; then
  pass "W5  the repository query is arch-filtered"
else
  fail "W5  the repository query is arch-filtered"
fi
if grep -q -- "--disableplugin=versionlock" "$WORK/watch.calls"; then
  pass "W5  and asks with the versionlock disabled"
else
  fail "W5  and asks with the versionlock disabled"
fi

# --- W6: an unprivileged run files nothing and says so, rather than failing or
# pretending. The exit code is still the real answer.
O=$(run_watch "$WETC" "$WORK/dnf-newer")
CURRENT="$O"
if [ "$(id -u)" -ne 0 ]; then
  assert_has "W6  an unprivileged run says nothing was filed" "$O" "not root"
  if [ -f "$WORK/watch-report.json" ]; then
    fail "W6  and writes no report file"
  else
    pass "W6  and writes no report file"
  fi
else
  assert_rc "W6  a root run files the report" "$(rc)" 1 "$O"
  if [ -f "$WORK/watch-report.json" ]; then pass "W6  and the JSON exists"; else fail "W6  and the JSON exists"; fi
  CURRENT="$WORK/watch-report.json"
  if grep -q '"above_pin": 1' "$WORK/watch-report.json"; then pass "W6  and records the finding"; else fail "W6  and records the finding"; fi
fi

# --- W7: usage discipline, and NO version literal anywhere in the script - a
# second copy of the pin is a second source of truth.
O=$(run_watch "$WETC" "$WORK/dnf-same" --max-age banana)
assert_rc "W7  a non-numeric --max-age exits 2" "$(rc)" 2 "$O"
# Comments may legitimately DISCUSS versions (the sort-order note does); what
# must not exist is a literal in CODE, which would be a second copy of the pin.
CURRENT="$SCRIPTS/cc-version-watch.sh"
if sed 's/#.*//' "$SCRIPTS/cc-version-watch.sh" | grep -qE '[0-9]+\.[0-9]+\.[0-9]{2,}'; then
  fail "W7  no version literal in code (comments may discuss versions)"
else
  pass "W7  no version literal in code (comments may discuss versions)"
fi

# --- W8: published_age_h must come from repomd.xml's <revision> - the vendor's
# own publish stamp - and not from the mtime of whichever cache directory
# happens to survive. The minimum mtime across cache dirs includes
# the transient /var/tmp/dnf-<user>-* trees dnf creates and removes per
# invocation, so two runs minutes apart against an UNCHANGED repository can
# report different ages. <revision> is identical
# in every copy of a repository state, so a transient tree cannot move it.
W8DIR="$WORK/repomd"; mkdir -p "$W8DIR/persistent" "$W8DIR/transient"
W8NOW=$(date +%s)
W8REV=$(( W8NOW - 300*3600 ))          # the vendor published 300h ago
for d in persistent transient; do
  printf '<repomd><revision>%s</revision></repomd>\n' "$W8REV" > "$W8DIR/$d/repomd.xml"
done
touch -d "@$(( W8NOW - 100*3600 ))" "$W8DIR/persistent/repomd.xml"   # we fetched 100h ago

# CC_TEST_DNF_CALLS is not optional: the dnf stub's first line appends to it, so
# leaving it unset makes that an ambiguous redirect and the stub writes
# "No such file or directory" to stderr - the very stream cc-version-watch.sh
# pattern-matches to decide NETWORK_FAILED. It happens not to match a current
# shape, which is exactly the kind of accident a later pattern would turn into
# three silently-wrong cases.
run_watch_globs() {   # run_watch_globs <globs> [args...]
  local globs="$1"; shift
  local out="$WORK/watch.$RANDOM.out"
  : > "$WORK/watch.calls"
  env CC_ETC="$WETC" CC_DNF_BIN="$WORK/dnf-same" CC_RPM_BIN="$WORK/rpm-236" \
      CC_NO_NETWORK=1 CC_REPORT="$WORK/watch-report.json" \
      CC_TEST_DNF_CALLS="$WORK/watch.calls" CC_REPOMD_GLOBS="$globs" \
      bash "$SCRIPTS/cc-version-watch.sh" "$@" >"$out" 2>&1
  echo $? > "$WORK/rc"
  echo "$out"
}
w8field() { grep -o "$2=[0-9]*" "$1" | head -1 | cut -d= -f2; }

O=$(run_watch_globs "$W8DIR/persistent/repomd.xml")
CURRENT="$O"
W8_PUB1=$(w8field "$O" published_age_h); W8_CACHE1=$(w8field "$O" cache_age_h)
# the transient tree now exists too, with a brand-new mtime - the regression case
O=$(run_watch_globs "$W8DIR/persistent/repomd.xml $W8DIR/transient/repomd.xml")
CURRENT="$O"
W8_PUB2=$(w8field "$O" published_age_h); W8_CACHE2=$(w8field "$O" cache_age_h)

if [ "$W8_PUB1" = 300 ] && [ "$W8_PUB2" = 300 ]; then
  pass "W8  published_age_h reads <revision>, and a transient cache does not move it"
else
  fail "W8  published_age_h reads <revision>, and a transient cache does not move it (got $W8_PUB1 then $W8_PUB2, want 300 both)"
fi
if [ "$W8_CACHE1" = 100 ] && [ "$W8_CACHE2" = 0 ]; then
  pass "W8  cache_age_h separately reports the freshest copy we hold"
else
  fail "W8  cache_age_h separately reports the freshest copy we hold (got $W8_CACHE1 then $W8_CACHE2, want 100 then 0)"
fi
# no copy at all is "unknown", never a guess
O=$(run_watch_globs "$W8DIR/absent/repomd.xml")
CURRENT="$O"
assert_has "W8  an absent repomd gives published_age_h=unknown" "$O" "published_age_h=unknown"
assert_has "W8  and cache_age_h=unknown, not a fabricated zero"  "$O" "cache_age_h=unknown"

# A PRESENT BUT UNREADABLE copy is the realistic variant and behaves differently
# from an absent one: stat succeeds on mode 000, so a -f test would have let it
# contribute a cache age of 0 from a file whose <revision> could not be read -
# and under --cacheonly a 0 sets STALE=0. It must contribute neither number.
mkdir -p "$W8DIR/noperm"
printf '<repomd><revision>%s</revision></repomd>\n' "$W8REV" > "$W8DIR/noperm/repomd.xml"
chmod 000 "$W8DIR/noperm/repomd.xml"
if [ -r "$W8DIR/noperm/repomd.xml" ]; then
  skip "W8  unreadable repomd contributes nothing (running as root: mode 000 is still readable)"
else
  O=$(run_watch_globs "$W8DIR/noperm/repomd.xml")
  CURRENT="$O"
  assert_has "W8  an unreadable repomd gives published_age_h=unknown" "$O" "published_age_h=unknown"
  assert_has "W8  and does not date a file it could not read"         "$O" "cache_age_h=unknown"
fi
chmod 644 "$W8DIR/noperm/repomd.xml"

# Caches that DISAGREE cannot date the state we hold: taking the newest could
# describe a repository state that repo_head did not come from.
mkdir -p "$W8DIR/disagree"
printf '<repomd><revision>%s</revision></repomd>\n' "$(( W8REV + 50*3600 ))" > "$W8DIR/disagree/repomd.xml"
O=$(run_watch_globs "$W8DIR/persistent/repomd.xml $W8DIR/disagree/repomd.xml")
CURRENT="$O"
assert_has "W8  caches that disagree on <revision> give unknown" "$O" "published_age_h=unknown"

# <revision> is not guaranteed to be a unix time. createrepo_c --revision takes
# an arbitrary string; a YYYYMMDDHHMMSS stamp subtracted from now() is a large
# negative number, which must never be published as a measurement.
mkdir -p "$W8DIR/notatime"
printf '<repomd><revision>20260914103000</revision></repomd>\n' > "$W8DIR/notatime/repomd.xml"
O=$(run_watch_globs "$W8DIR/notatime/repomd.xml")
CURRENT="$O"
assert_has "W8  a YYYYMMDDHHMMSS revision is unknown, not a negative age" "$O" "published_age_h=unknown"
assert_lacks "W8  and no negative age reaches the machine line"           "$O" "published_age_h=-"

# ================================================================ cc-apply-posture (aws/)
head2 "aws/bin/cc-apply-posture.sh"

# This runs as root at boot on a VDI image and decides WHICH policy the instance
# gets. Its header justifies its env-with-default design by saying the suite can
# fabricate every failure path; these are that suite. Nothing here needs root or
# a real /etc - the seams are CC_ETC, CC_SHARE, CC_LOGDIR, CC_POSTURE_STAGE.
POST="$SCRIPTS/../aws/bin/cc-apply-posture.sh"
run_post() {   # run_post <etc> <stage> [logdir]
  local etc="$1" stage="$2" log="${3:-$WORK/postlog}"
  local out="$WORK/post.$RANDOM.out"
  mkdir -p "$etc" "$log"
  env CC_ETC="$etc" CC_POSTURE_STAGE="$stage" CC_LOGDIR="$log" CC_SHARE="$WORK/postshare" \
      bash "$POST" >"$out" 2>&1
  echo $? > "$WORK/rc"
  echo "$out"
}
mk_stage() {   # mk_stage <dir> <fleet-ok:1|0> <admin-ok:1|0>
  local d="$1"; mkdir -p "$d"
  printf '{"requiredMinimumVersion":"2.1.236"}\n' > "$d/managed-settings.fleet.json"
  printf '{"requiredMinimumVersion":"2.1.236","_admin":true}\n' > "$d/managed-settings.admin.json"
  if [ "$2" = 1 ]; then (cd "$d" && sha256sum managed-settings.fleet.json > managed-settings.fleet.json.sha256)
  else printf '%s  managed-settings.fleet.json\n' "$(printf '0%.0s' $(seq 64))" > "$d/managed-settings.fleet.json.sha256"; fi
  if [ "$3" = 1 ]; then (cd "$d" && sha256sum managed-settings.admin.json > managed-settings.admin.json.sha256)
  else rm -f "$d/managed-settings.admin.json.sha256"; fi
}

if [ -f "$POST" ]; then
  # PS1/PS2 install a file with `install -o root -g root`, which only root can do
  # - the script places a policy at boot, so that is correct and must not be
  # relaxed for a test. The REFUSAL paths (PS3/PS4) need no privilege and are the
  # ones that matter most, so they run either way.
  if [ "$(id -u)" -eq 0 ]; then
  # PS1: the default posture is fleet, and a good staged policy is installed.
  ST="$WORK/stage1"; mk_stage "$ST" 1 1; E1="$WORK/post-etc1"
  O=$(run_post "$E1" "$ST")
  assert_rc  "PS1 a clean fleet posture applies" "$(rc)" 0 "$O"
  CURRENT="$O"
  if [ -f "$E1/managed-settings.json" ]; then pass "PS1 the policy is installed"; else fail "PS1 the policy is installed"; fi
  if [ -f "$E1/managed-settings.json.sha256" ]; then pass "PS1 the BAKED baseline is copied across"; else fail "PS1 the BAKED baseline is copied across"; fi

  # PS2: an unknown posture word fails CLOSED to fleet rather than guessing.
  ST2="$WORK/stage2"; mk_stage "$ST2" 1 1; E2="$WORK/post-etc2"; mkdir -p "$E2"
  printf 'banana\n' > "$E2/posture"
  O=$(run_post "$E2" "$ST2")
  assert_has "PS2 an unknown posture word fails closed to fleet" "$O" "unknown posture"
  assert_rc  "PS2 and still applies a policy"  "$(rc)" 0 "$O"

  else
    skip "PS1/PS2 posture install paths (install -o root needs root; the refusal paths below still run)"
  fi

  # PS3: a checksum mismatch must REFUSE. A silently-degraded policy is the whole
  # reason the baked checksum exists.
  ST3="$WORK/stage3"; mk_stage "$ST3" 0 1; E3="$WORK/post-etc3"
  O=$(run_post "$E3" "$ST3")
  assert_rc "PS3 a corrupt staged policy is refused" "$(rc)" 1 "$O"
  CURRENT="$O"
  if [ -f "$E3/managed-settings.json" ]; then fail "PS3 and nothing is installed"; else pass "PS3 and nothing is installed"; fi

  # PS4: admin posture with no staged admin policy must not silently downgrade
  # to fleet without saying so.
  ST4="$WORK/stage4"; mk_stage "$ST4" 1 0; rm -f "$ST4/managed-settings.admin.json"
  E4="$WORK/post-etc4"; mkdir -p "$E4"; printf 'admin\n' > "$E4/posture"
  O=$(run_post "$E4" "$ST4")
  assert_has "PS4 an unusable admin policy is announced, not silent" "$O" "fleet"
else
  skip "PS1-PS4 posture selector (aws/bin/cc-apply-posture.sh not present)"
fi

# ================================================================ cc-admin-session
head2 "cc-admin-session.sh"

# This is the escalation path: a sudoers grant on it is only NOT equivalent to
# full root because of the three refusals below. They had no coverage at all.
# The gates sit after the root check: unprivileged, AS1 asserts the root
# refusal itself, and the gates behind it run as root in a user namespace.
run_adm() {   # run_adm <config> [args...]
  local cfg="$1"; shift
  local out="$WORK/adm.$RANDOM.out"
  env CC_CONFIG="$cfg" bash "$SCRIPTS/cc-admin-session.sh" "$@" >"$out" 2>&1
  echo $? > "$WORK/rc"
  echo "$out"
}
ADMCFG="$WORK/adm-config.sh"
ADMLOG="$WORK/admlog/admin.log"     # cc-config.sh derives CC_ADMIN_LOG=$CC_LOGDIR/admin.log
cp "$SCRIPTS/../config.example.sh" "$ADMCFG"
# Two fixtures, because the gates are ordered: authorisation runs FIRST, so a
# config that authorises nobody can only ever exercise that one gate. ADMCFG
# authorises the invoker in order to reach the target-policy gates behind it;
# ADMCFG_NOAUTH authorises nobody and exercises the outer gate itself.
printf 'CC_LOGDIR="%s/admlog"\nCC_ADMIN_GROUP="cc-admins-nonexistent-for-tests"\nCC_ADMIN_USERS=("%s")\n' \
  "$WORK" "$NONROOT" >> "$ADMCFG"
ADMCFG_NOAUTH="$WORK/adm-config-noauth.sh"
cp "$SCRIPTS/../config.example.sh" "$ADMCFG_NOAUTH"
printf 'CC_LOGDIR="%s/admlog"\nCC_ADMIN_GROUP="cc-admins-nonexistent-for-tests"\nCC_ADMIN_USERS=()\n' \
  "$WORK" >> "$ADMCFG_NOAUTH"

if [ "$(id -u)" -ne 0 ]; then
  O=$(run_adm "$ADMCFG")
  assert_rc  "AS1 refuses to run unprivileged" "$(rc)" 1 "$O"
  assert_has "AS1 and says why"                "$O" "must run as root"
else
  skip "AS1 unprivileged refusal (this run IS root - the gate cannot fire)"
fi

# The gates behind the root check are reached as root: real root when the suite
# runs as root, otherwise a user namespace (`unshare -r`), where EUID is 0 and
# getent, id and the log write behave as on a real escalation. SUDO_USER is set
# to NONROOT, as `sudo` would set it.
ASROOT=()
if [ -z "$NONROOT" ]; then :
elif [ "$(id -u)" -eq 0 ]; then ASROOT=(env SUDO_USER="$NONROOT")
elif unshare -r true 2>/dev/null; then ASROOT=(unshare -r env SUDO_USER="$NONROOT")
fi
run_adm_root() {   # run_adm_root <config> [args...]
  local cfg="$1"; shift
  local out="$WORK/adm.$RANDOM.out"
  "${ASROOT[@]}" CC_CONFIG="$cfg" bash "$SCRIPTS/cc-admin-session.sh" "$@" >"$out" 2>&1
  echo $? > "$WORK/rc"
  echo "$out"
}

if [ "${#ASROOT[@]}" -gt 0 ]; then
  # -u root is the whole reason a command-scoped sudoers grant is not a root
  # grant: without this refusal, `sudo cc-admin-session.sh -u root` IS `sudo -i`.
  O=$(run_adm_root "$ADMCFG" -u root)
  assert_rc  "AS2 refuses target root" "$(rc)" 1 "$O"
  assert_has "AS2 and records the reason" "$ADMLOG" "reason=uid0"
  # Impersonating a colleague would run the agent under their identity, with
  # their home and their audit trail.
  O=$(run_adm_root "$ADMCFG" -u nobody)
  assert_rc  "AS3 refuses a target that is not the invoker" "$(rc)" 1 "$O"
  assert_has "AS3 and records the reason" "$ADMLOG" "reason=impersonation"
  # And the outer gate still refuses someone the config does not name at all -
  # this is the gate that makes a command-scoped sudoers grant safe to ship.
  O=$(run_adm_root "$ADMCFG_NOAUTH")
  assert_rc  "AS3b an unauthorised invoker is refused" "$(rc)" 1 "$O"
  assert_has "AS3b and records the reason" "$ADMLOG" "reason=unauthorised"

  # Every refusal must reach the log, not only the three that call stamp()
  # directly - a privileged launcher that refuses silently leaves the operator
  # and the auditor with identical evidence: none.
  O=$(run_adm_root "$ADMCFG" -u "no-such-user-$$")
  assert_has "AS4 a refusal from die() is also stamped" "$ADMLOG" "reason=die msg=no such user"

  # AS9: -u is caller-controlled text. A newline in it must not forge an
  # admin.log record - whichever gate refuses, the unauthorised one included -
  # and an unauthorised caller must not learn from getent whether an account
  # exists: the lookup comes after the authorisation gate.
  FORGE=$'nobody\n2026-01-01T00:00:00Z pid=1 invoker=root target=root tty=none admin session START'
  O=$(run_adm_root "$ADMCFG_NOAUTH" -u "$FORGE")
  assert_has "AS9 an unauthorised -u with a newline is refused and stamped" "$ADMLOG" "reason=unauthorised"
  CURRENT="$ADMLOG"
  if grep -q '^2026-01-01T00:00:00Z pid=1 ' "$ADMLOG"; then fail "AS9 and it cannot forge a record in admin.log"
  else pass "AS9 and it cannot forge a record in admin.log"; fi
  O=$(run_adm_root "$ADMCFG" -u "$FORGE")
  assert_rc  "AS9 an authorised invoker's malformed -u is refused" "$(rc)" 1 "$O"
  assert_has "AS9 as not an account name" "$O" "not a valid account name"
  CURRENT="$ADMLOG"
  if grep -q '^2026-01-01T00:00:00Z pid=1 ' "$ADMLOG"; then fail "AS9 and that refusal forges nothing either"
  else pass "AS9 and that refusal forges nothing either"; fi
  AS9B="$WORK/as9bin"; mkdir -p "$AS9B"
  printf '#!/bin/sh\necho "$*" >> "%s/as9.getent"\nexec /usr/bin/getent "$@"\n' "$WORK" > "$AS9B/getent"
  chmod 755 "$AS9B/getent"; rm -f "$WORK/as9.getent"
  "${ASROOT[@]}" PATH="$AS9B:$PATH" CC_CONFIG="$ADMCFG_NOAUTH" bash "$SCRIPTS/cc-admin-session.sh" -u nobody \
    > "$WORK/as9.out" 2>&1
  assert_has   "AS9 the authorisation gate consults getent (stub ran)" "$WORK/as9.getent" "group "
  assert_lacks "AS9 and no account is looked up before it" "$WORK/as9.getent" "passwd"

  # AS10: an eval binary is only as safe as every directory above it - a
  # group-writable parent lets another account rename in a different binary, and
  # a symlink can point anywhere. The path is resolved, every parent walked,
  # and the resolved path is what runs.
  EV="$WORK/as10"; mkdir -p "$EV/adm" "$EV/etc" "$EV/gw" "$EV/ok"
  echo '{}' > "$EV/adm/managed-settings.json"; echo '{}' > "$EV/etc/managed-settings.json"
  for d in gw ok; do printf '#!/bin/sh\nexit 0\n' > "$EV/$d/claude"; chmod 755 "$EV/$d/claude"; done
  chmod 755 "$EV" "$EV/ok"; chmod 775 "$EV/gw"; ln -sfn "$EV/gw/claude" "$EV/ok/link"
  for c in gw ok link; do
    case $c in gw) b="$EV/gw/claude" ;; ok) b="$EV/ok/claude" ;; link) b="$EV/ok/link" ;; esac
    cp "$ADMCFG" "$WORK/as10-$c.sh"
    printf 'CC_ETC="%s/etc"\nCC_ETC_ADMIN="%s/adm"\nCC_CLAUDE_BIN="%s/ok/claude"\nCC_EVAL_BIN="%s"\n' \
      "$EV" "$EV" "$EV" "$b" >> "$WORK/as10-$c.sh"
  done
  O=$(run_adm_root "$WORK/as10-gw.sh" -e -n)
  # The message, not the exit code, is the discriminating assertion: a later
  # gate (the admin policy directory mode) also exits 1 on this fixture.
  assert_has "AS10 an eval binary under a group-writable directory is refused, naming it" "$O" "parent directory $EV/gw is mode 775"
  O=$(run_adm_root "$WORK/as10-link.sh" -e -n)
  assert_has "AS10 a symlink into that directory is resolved and refused" "$O" "parent directory $EV/gw is mode 775"
  # Control: the same binary under a 0755 directory passes every test-owned
  # parent. (In a user namespace the real root's / and /tmp show as unmapped,
  # so the walk may still stop above $EV; it must not stop AT $EV.)
  O=$(run_adm_root "$WORK/as10-ok.sh" -e -n)
  assert_lacks "AS10 a 0755 parent is accepted" "$O" "parent directory $EV"
else
  skip "AS2-AS4, AS9, AS10 gates behind the root check (no user namespace, or as root no non-root account to invoke as)"
fi

# AS8: admin.log says who held privilege and when; it is root-only to
# read. It was created 0644 by the root umask and by the logrotate `create`.
# Root is simulated by an `id` stub, so the unauthorised refusal is stamped.
AS8B="$WORK/as8bin"; mkdir -p "$AS8B"
printf '#!/bin/sh\n[ "$1" = "-u" ] && [ $# -eq 1 ] && { echo 0; exit 0; }\nexec /usr/bin/id "$@"\n' > "$AS8B/id"
chmod 755 "$AS8B/id"
rm -rf "$WORK/admlog"; mkdir -p "$WORK/admlog"
( umask 022; env PATH="$AS8B:$PATH" CC_CONFIG="$ADMCFG_NOAUTH" bash "$SCRIPTS/cc-admin-session.sh" > "$WORK/as8.out" 2>&1 )
CURRENT="$WORK/as8.out"
if [ "$(stat -c '%a' "$ADMLOG" 2>/dev/null)" = 640 ]; then pass "AS8 a new admin.log is 0640 under a 022 umask"
else fail "AS8 a new admin.log is 0640 under a 022 umask (got $(stat -c '%a' "$ADMLOG" 2>/dev/null || echo none))"; fi
chmod 644 "$ADMLOG"
( env PATH="$AS8B:$PATH" CC_CONFIG="$ADMCFG_NOAUTH" bash "$SCRIPTS/cc-admin-session.sh" > "$WORK/as8.out" 2>&1 )
if [ "$(stat -c '%a' "$ADMLOG" 2>/dev/null)" = 640 ]; then pass "AS8 an existing world-readable admin.log is narrowed on the next stamp"
else fail "AS8 an existing world-readable admin.log is narrowed on the next stamp"; fi
assert_has "AS8 logrotate recreates it 0640 too" "$SCRIPTS/../systemd/claude-code-logrotate" "    create 0640 root root"
CURRENT="$SCRIPTS/../systemd/claude-code-logrotate"
if grep -q "create 0644" "$SCRIPTS/../systemd/claude-code-logrotate"; then fail "AS8 and no stanza recreates a log world-readable"
else pass "AS8 and no stanza recreates a log world-readable"; fi

# The launcher must NOT exec: exec discards the EXIT trap, and with it the
# END record, leaving admin.log a START for every session and an END for
# none. Run a whole authorised
# session with `unshare` stubbed to exit 7: the END record, carrying the
# child's exit code, is the observable proof that the trap survived.
if [ "${#ASROOT[@]}" -gt 0 ]; then
  L="$WORK/as5"; rm -rf "$L"; mkdir -p "$L/adm" "$L/etc" "$L/bin" "$L/stub"
  echo '{}' > "$L/adm/managed-settings.json"; echo '{}' > "$L/etc/managed-settings.json"
  chmod 700 "$L/adm"; chmod 644 "$L/adm/managed-settings.json"
  printf '#!/bin/sh\nexit 0\n' > "$L/bin/claude"; chmod 755 "$L/bin/claude"
  printf '#!/bin/sh\nexit 7\n' > "$L/stub/unshare"; chmod 755 "$L/stub/unshare"
  cp "$ADMCFG" "$WORK/as5.sh"
  printf 'CC_ETC="%s/etc"\nCC_ETC_ADMIN="%s/adm"\nCC_CLAUDE_BIN="%s/bin/claude"\n' "$L" "$L" "$L" >> "$WORK/as5.sh"
  : > "$ADMLOG"
  "${ASROOT[@]}" PATH="$L/stub:$PATH" CC_CONFIG="$WORK/as5.sh" bash "$SCRIPTS/cc-admin-session.sh" \
    > "$WORK/as5.out" 2>&1
  assert_rc  "AS5 an authorised session reaches the launch and returns the child's exit code" "$?" 7 "$WORK/as5.out"
  assert_has "AS5 a START record is written" "$ADMLOG" "admin session START"
  assert_has "AS6 the EXIT trap survives the launch: an END record carries the child's code" "$ADMLOG" "admin session END rc=7"
else
  skip "AS5-AS6 END record (no user namespace, or as root no non-root account to invoke as)"
fi

# ================================================================ cc-install
head2 "cc-install.sh"

# Gate 5 refuses to apply a policy whose requiredMinimumVersion is ABOVE the
# version installed on the host. That combination is an outage wearing the
# clothes of a routine apply: the floor refuses to START any binary below it, so
# every session on the host stops at once with a message about the organisation's
# minimum version and no clue which command caused it.
#
# cc-install.sh derives its source tree from its own path and has no CC_REPO
# seam, so the only way to vary the INCOMING policy is to run a COPY of the tree.
# --check is used throughout: it writes nothing, and the root gate applies to
# --apply alone, so these run unprivileged.
mk_install_repo() {   # mk_install_repo <dir> <floor|-> [admin-floor|-]
  local dir="$1" floor="$2" afloor="${3:--}" d
  mkdir -p "$dir"
  for d in settings lib bin hooks share profile.d systemd; do cp -a "$SCRIPTS/../$d" "$dir/"; done
  # The engineer's guide is the one file the installer places from docs/.
  mkdir -p "$dir/docs" && cp -a "$SCRIPTS/../docs/ENGINEER-GUIDE.md" "$dir/docs/"
  # The installer refuses without a site config, and the real one is gitignored,
  # so the fixture carries the shipped template. Paths stay at the template's
  # values deliberately: gate 4 compares the policy's hook paths against them,
  # and a fixture that moved them would fail there and never reach gate 5.
  cp -a "$SCRIPTS/../config.example.sh" "$dir/config.sh"
  [ "$floor" = "-" ] || python3 - "$dir/settings/managed-settings.json" "$floor" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p)); d["requiredMinimumVersion"] = sys.argv[2]
json.dump(d, open(p, "w"), indent=2)
PY
  [ "$afloor" = "-" ] || python3 - "$dir/settings/managed-settings-admin.json" "$afloor" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p)); d["requiredMinimumVersion"] = sys.argv[2]
json.dump(d, open(p, "w"), indent=2)
PY
}

# Real rpm reports a missing package on STDOUT with exit 1. A gate that checked
# only the exit status - or only the output - would read that sentence as a
# version, so the stub reproduces it exactly.
stub_rpm() {   # stub_rpm <path> <version|->
  if [ "$2" = "-" ]; then
    printf '#!/usr/bin/env bash\necho "package claude-code is not installed"\nexit 1\n' > "$1"
  else
    printf '#!/usr/bin/env bash\nprintf "%%s" "%s"\n' "$2" > "$1"
  fi
  chmod 755 "$1"
}
stub_claude() {   # stub_claude <path> <version|->
  if [ "$2" = "-" ]; then printf '#!/usr/bin/env bash\nexit 1\n' > "$1"
  else printf '#!/usr/bin/env bash\necho "%s (Claude Code)"\n' "$2" > "$1"; fi
  chmod 755 "$1"
}

run_inst() {   # run_inst <repodir> <rpmstub> <claudestub> [args...]
  local repo="$1" rpmb="$2" cl="$3"; shift 3
  local out="$WORK/inst.$RANDOM.out" cfg="$WORK/inst.$RANDOM.config.sh"
  # The stub paths go in a per-case CONFIG, not the environment: config.sh
  # assigns CC_CLAUDE_BIN unconditionally, so it wins over an exported value.
  # CC_CONFIG is cc-config.sh's documented override and is what the suite uses
  # everywhere else.
  sed 's#^CC_CLAUDE_BIN=.*#CC_CLAUDE_BIN="'"$cl"'"#' "$repo/config.sh" > "$cfg"
  env CC_CONFIG="$cfg" CC_RPM_BIN="$rpmb" CC_CLAUDE_BIN="$cl" \
      bash "$repo/bin/cc-install.sh" --check "$@" >"$out" 2>&1
  echo $? > "$WORK/rc"
  echo "$out"
}

run_inst_env() {   # run_inst_env <repodir> <rpmstub> <claudestub> <VAR=val>... -- for cases
  local repo="$1" rpmb="$2" cl="$3"; shift 3   # that need an extra seam in the environment
  local out="$WORK/inst.$RANDOM.out" cfg="$WORK/inst.$RANDOM.config.sh"
  sed 's#^CC_CLAUDE_BIN=.*#CC_CLAUDE_BIN="'"$cl"'"#' "$repo/config.sh" > "$cfg"
  env CC_CONFIG="$cfg" CC_RPM_BIN="$rpmb" CC_CLAUDE_BIN="$cl" "$@" \
      bash "$repo/bin/cc-install.sh" --check >"$out" 2>&1
  echo $? > "$WORK/rc"
  echo "$out"
}

stub_rpm "$WORK/rpm-236" "2.1.236";  stub_claude "$WORK/cl-236" "2.1.236"
stub_rpm "$WORK/rpm-232" "2.1.232";  stub_claude "$WORK/cl-232" "2.1.232"
stub_rpm "$WORK/rpm-none" "-";       stub_claude "$WORK/cl-mute" "-"

# --- I1: installed at the floor - allowed
IR="$WORK/inst-ok"; mk_install_repo "$IR" "2.1.236"
O=$(run_inst "$IR" "$WORK/rpm-236" "$WORK/cl-236")
assert_has "I1  installed at the floor is accepted" "$O" "is at or above the policy floor"

# --- I2: installed BELOW the floor - refused, with the vendor's own message and
# the working order. This is the outage the gate exists to prevent.
IR2="$WORK/inst-below"; mk_install_repo "$IR2" "2.1.236"
O=$(run_inst "$IR2" "$WORK/rpm-232" "$WORK/cl-232")
assert_rc  "I2  a floor above the installed version REFUSES" "$(rc)" 1 "$O"
assert_has "I2  it names both versions"        "$O" "floor 2.1.236 is ABOVE the installed version 2.1.232"
assert_has "I2  it quotes what users would see" "$O" "older than the minimum"
assert_has "I2  it gives the working order"     "$O" "cc-update.sh apply 2.1.236"

# --- I3: the override is honoured, warns, and does not refuse
O=$(run_inst "$IR2" "$WORK/rpm-232" "$WORK/cl-232" --allow-below-floor)
assert_has "I3  --allow-below-floor proceeds with a warning" "$O" "--allow-below-floor: applying floor"
CURRENT="$O"
if grep -q "is ABOVE the installed version" "$O"; then
  fail "I3  and does not also refuse"
else
  pass "I3  and does not also refuse"
fi

# --- I4: a fresh host - no package, and no binary AT ALL - warns and continues.
# A host being built legitimately has the policy before the package.
O=$(run_inst "$IR2" "$WORK/rpm-none" "$WORK/no-such-claude")
assert_has "I4  a fresh host warns rather than failing" "$O" "no claude on this host yet"
assert_has "I4  and names the next command"             "$O" "make pin VERSION=2.1.236"

# --- I4b: the DIFFERENT unknown - something is installed but will not say what
# version it is. That must not read as "fresh host", and above all must not read
# as "not below the floor": the gate says explicitly that it did not run.
O=$(run_inst "$IR2" "$WORK/rpm-none" "$WORK/cl-mute")
assert_has "I4b a present-but-mute binary says the floor was NOT checked" "$O" "was NOT checked"
assert_has "I4b and tells the operator how to check by hand"              "$O" "rpm -q claude-code"
CURRENT="$O"
if grep -q "is ABOVE the installed version" "$O"; then
  fail "I4  and does not refuse"
else
  pass "I4  and does not refuse"
fi

# --- I5: rpm's "package ... is not installed" sentence must never become a
# version. If it did, version_below would compare garbage and the gate would
# either refuse a healthy host or pass a broken one.
CURRENT="$O"
if grep -q "is not installed" "$O"; then
  fail "I5  rpm's not-installed sentence is not treated as a version"
else
  pass "I5  rpm's not-installed sentence is not treated as a version"
fi

# --- I6: the ADMIN policy carries its own floor and is checked too, but only
# with --with-admin. A claude-admin session that cannot start is the session you
# most need during a bad bump.
IR3="$WORK/inst-admin"; mk_install_repo "$IR3" "2.1.232" "2.1.236"
O=$(run_inst "$IR3" "$WORK/rpm-232" "$WORK/cl-232" --with-admin)
assert_has "I6  the admin policy floor is checked under --with-admin" "$O" "admin policy floor 2.1.236 is above"
O=$(run_inst "$IR3" "$WORK/rpm-232" "$WORK/cl-232")
CURRENT="$O"
if grep -q "admin policy floor" "$O"; then
  fail "I6b and is NOT checked without it"
else
  pass "I6b and is NOT checked without it"
fi

# --- I10: gate 4c, the static files against the site's config. A unit that
# runs a script from a directory nothing was installed to looks configured and
# runs nothing; the gate refuses before anything is placed.
IR4="$WORK/inst-coupling"; mk_install_repo "$IR4" "2.1.236"
sed -i 's#^ExecStart=/usr/local/sbin/#ExecStart=/opt/elsewhere/#' "$IR4/systemd/claude-code-report.service"
O=$(run_inst "$IR4" "$WORK/rpm-236" "$WORK/cl-236")
assert_rc  "I10 a unit that disagrees with config.sh REFUSES" "$(rc)" 1 "$O"
assert_has "I10 and names the file and the value" "$O" "claude-code-report.service:28: ExecStart runs /opt/elsewhere/cc-report.sh, not under CC_SBIN=/usr/local/sbin"
O=$(run_inst "$IR" "$WORK/rpm-236" "$WORK/cl-236")
assert_has "I10b an untouched tree passes gate 4c" "$O" "units, logrotate, sudoers and both policies agree with config.sh"
# --- I10c: a config that does not set every key is refused, not half-applied
IR5="$WORK/inst-badcfg"; mk_install_repo "$IR5" "2.1.236"; sed -i '/^CC_LOGDIR=/d' "$IR5/config.sh"
O="$WORK/inst-badcfg.out"; env CC_CONFIG="$IR5/config.sh" bash "$IR5/bin/cc-install.sh" --check >"$O" 2>&1; echo $? > "$WORK/rc"
assert_rc  "I10c an incomplete config.sh REFUSES" "$(rc)" 1 "$O"
assert_has "I10c and names the missing key" "$O" "does not set: CC_LOGDIR"

# --- CP1-CP8: lib/cc-coupling.py, rule by rule. Each case moves ONE value in a
# copy of the static files; CP1 is the untouched control.
mk_cpl() {  # mk_cpl <dir> - the static files, the template, and the loader
  mkdir -p "$1"; local d
  for d in settings systemd lib aws profile.d; do cp -a "$REPOROOT/$d" "$1/"; done
  cp "$REPOROOT/config.example.sh" "$1/"
}
run_cpl() {  # run_cpl <dir> [CC_X=v ...] - template config, with the given values moved
  local dir="$1" out="$WORK/cpl.$RANDOM.out"; shift
  env -i PATH="$PATH" CC_CONFIG="$dir/config.example.sh" "$@" \
    bash -c '. "$0/lib/cc-config.sh" && export ${!CC_@} && python3 "$0/lib/cc-coupling.py" "$0"' "$dir" >"$out" 2>&1
  echo $? > "$WORK/rc"; echo "$out"; }
CP="$WORK/cpl-ok"; mk_cpl "$CP"
O=$(run_cpl "$CP")
assert_rc  "CP1 the shipped static files agree with the template" "$(rc)" 0 "$O"
CP="$WORK/cpl-lr"; mk_cpl "$CP"; sed -i 's#^/var/log/claude-code/update.log#/var/log/other/update.log#' "$CP/systemd/claude-code-logrotate"
O=$(run_cpl "$CP")
assert_has "CP2 logrotate rotating outside CC_LOGDIR fails" "$O" "rotates /var/log/other/update.log, not under CC_LOGDIR"
CP="$WORK/cpl-su"; mk_cpl "$CP"
O=$(run_cpl "$CP" CC_ADMIN_GROUP=ops)
assert_has "CP3 sudoers granting another group fails" "$O" "grants %cc-admins, but CC_ADMIN_GROUP=ops"
CP="$WORK/cpl-sl"; mk_cpl "$CP"
O=$(run_cpl "$CP" CC_SHARE=/opt/share)
assert_has "CP4 a status line outside CC_SHARE fails" "$O" "statusLine runs"
assert_has "CP4 and so does the guide path" "$O" "names the guide at /usr/local/share/claude-code/ENGINEER-GUIDE.md"
CP="$WORK/cpl-bn"; mk_cpl "$CP"
O=$(run_cpl "$CP" CC_SUPPORT_CONTACT=help@example.org)
assert_has "CP5 a banner naming another contact fails" "$O" "the banner names"
CP="$WORK/cpl-dr"; mk_cpl "$CP"
O=$(run_cpl "$CP" CC_LOGDIR=/srv/cclog)
assert_has "CP6 a moved CC_LOGDIR still spelled in a policy fails" "$O" "settings/managed-settings.json:"
assert_has "CP6 and says which template value is stale" "$O" "still spells CC_LOGDIR's template value /var/log/claude-code; this site sets /srv/cclog"
CP="$WORK/cpl-hk"; mk_cpl "$CP"
O=$(run_cpl "$CP" CC_SBIN=/opt/sbin)
assert_has "CP7 policy hooks outside CC_SBIN fail, in BOTH policies" "$O" "settings/managed-settings-admin.json: hooks.PreToolUse runs"
O="$WORK/cpl-noenv.out"; env -i PATH="$PATH" python3 "$REPOROOT/lib/cc-coupling.py" "$REPOROOT" >"$O" 2>&1; echo $? > "$WORK/rc"
assert_rc  "CP8 run with no config exported, it refuses (exit 2), not passes" "$(rc)" 2 "$O"

# --- Q1-Q4: make quickstart's config guards, staged under DESTDIR in a copy
mk_mkrepo() {  # mk_mkrepo <dir> - what quickstart reads
  mkdir -p "$1/docs"; local d
  for d in settings hooks share lib systemd aws profile.d bin; do cp -a "$REPOROOT/$d" "$1/"; done
  cp "$REPOROOT/Makefile" "$REPOROOT/config.example.sh" "$1/"; cp "$REPOROOT/docs/ENGINEER-GUIDE.md" "$1/docs/"
}
run_qs() {  # run_qs <dir> [make args...]
  local dir="$1" out="$WORK/qs.$RANDOM.out"; shift
  ( cd "$dir" && env -u CC_CONFIG -u CC_CONFIG_LIB make -s quickstart DESTDIR="$dir/stage" "$@" ) >"$out" 2>&1
  echo $? > "$WORK/rc"; echo "$out"; }
QR="$WORK/qs-nocfg"; mk_mkrepo "$QR"
O=$(run_qs "$QR")
assert_rc  "Q1  quickstart with no config.sh REFUSES" "$(rc)" 2 "$O"
assert_has "Q1  and says how to make one" "$O" "Create it with: make config"
QR="$WORK/qs-part"; mk_mkrepo "$QR"; grep -v '^CC_SHARE=' "$QR/config.example.sh" > "$QR/config.sh"
O=$(run_qs "$QR")
assert_has "Q2  an incomplete config.sh is refused, naming the key" "$O" "does not set: CC_SHARE"
QR="$WORK/qs-ok"; mk_mkrepo "$QR"; cp "$QR/config.example.sh" "$QR/config.sh"
O=$(run_qs "$QR" SBIN=/opt/x)
assert_has "Q3  a command-line SBIN that differs from config.sh is refused" "$O" "SBIN=/opt/x, but"
O=$(run_qs "$QR")
assert_rc  "Q4  a complete config stages" "$(rc)" 0 "$O"
CURRENT="$O"
if [ -f "$QR/stage/etc/claude-code/config.sh" ] && [ -f "$QR/stage/etc/claude-code/cc-config.sh" ]; then
  pass "Q4  and installs config.sh and the loader beside the policy"
else
  fail "Q4  and installs config.sh and the loader beside the policy"
fi
QR="$WORK/qs-cpl"; mk_mkrepo "$QR"; cp "$QR/config.example.sh" "$QR/config.sh"
sed -i 's#^CC_LOGDIR=.*#CC_LOGDIR="/srv/cclog"#' "$QR/config.sh"
O=$(run_qs "$QR")
assert_has "Q5  a static file that disagrees with config.sh stops quickstart" "$O" "a static file disagrees with"
# Q6: quickstart runs the installer's policy gates, not a subset of them.
QR="$WORK/qs-ph"; mk_mkrepo "$QR"; cp "$QR/config.example.sh" "$QR/config.sh"
sed -i 's#"cleanupPeriodDays"#"_x": "REPLACE-WITH-SOMETHING", "cleanupPeriodDays"#' "$QR/settings/managed-settings.json"
O=$(run_qs "$QR")
assert_has "Q6  quickstart refuses a policy with a placeholder (installer gate 3)" "$O" "policy still contains placeholders"
if [ -e "$QR/stage/etc/claude-code/managed-settings.json" ]; then fail "Q6  and stages nothing"; else pass "Q6  and stages nothing"; fi

# --- I9: gate 1b, the refusal that stops an --apply inside a privileged session.
# CLAUDE.md warns about this failure by name: cc-admin-session.sh bind-mounts the
# ADMIN policy over the fleet path, so writing there writes THROUGH the bind and
# destroys the admin policy while leaving the fleet policy untouched. It is the
# most consequential of the five copies of the mountinfo predicate, and it was
# the only one that hardcoded /proc/self/mountinfo instead of reading the
# CC_MOUNTINFO seam - so the guard with the worst failure mode was the one no
# case could fabricate. It can now.
I9MI="$WORK/i9-mountinfo"
IR9="$WORK/inst-ns"; mk_install_repo "$IR9" "2.1.236"
# Field 5 of a mountinfo line is the mount point. Everything else is filler of
# the right shape, because the predicate reads field 5 and nothing else.
printf '99 98 0:99 / %s rw,relatime shared:1 - ext4 /dev/x rw\n' "/etc/claude-code/managed-settings.json" > "$I9MI"
O=$(run_inst_env "$IR9" "$WORK/rpm-236" "$WORK/cl-236" CC_MOUNTINFO="$I9MI")
assert_has "I9  a bind-mounted policy path is detected as a privileged session" "$O" "is a bind mount in this mount namespace"
assert_has "I9  and the warning names what applying there would destroy"        "$O" "overwrite the ADMIN policy"
# --check must still RUN - a dry run inside an admin session is safe and useful,
# and refusing it outright would remove the only way to inspect from in there.
assert_rc  "I9  --check is not blocked, only warned"  "$(rc)" 0 "$O"
assert_has "I9b and it says its policy comparison is against the admin policy"  "$O" "ignore any difference it reports there"
# The other direction: no bind mount, no warning. A gate that fires always is a
# gate people learn to work around.
O=$(run_inst_env "$IR9" "$WORK/rpm-236" "$WORK/cl-236" CC_MOUNTINFO=/dev/null)
assert_lacks "I9c a plain session is not accused of being privileged" "$O" "is a bind mount in this mount namespace"

# --- I7: place() must never re-assert a mode on a parent that already exists.
# `install -d -m 0755 -o root -g root <dir>` applies mode AND ownership to an
# EXISTING directory, so the unconditional form re-opened /etc/claude-code-admin
# from 0700 to 0755 on every apply that rewrote the admin policy - one line
# after mkdirmode had just set 0700. Nothing detected it but cc-admin-session.sh
# refusing to start. This is a source assertion because the damage needs a real
# root write to reproduce (I8), and the fence has to run on every host.
CURRENT="$SCRIPTS/cc-install.sh"
# Every `install -d` that targets a dirname must be guarded by a -d test on the
# line before it. awk, not a multi-grep, so the assertion reads as the rule.
UNGUARDED=$(awk '
  /install -d .*\$\(dirname/ { if (prev !~ /\[ -d "\$\(dirname/) print NR": "$0 }
  { prev = $0 }
' "$SCRIPTS/cc-install.sh")
if [ -n "$UNGUARDED" ]; then
  fail "I7  place() creates the parent only when absent (unguarded: $UNGUARDED)"
else
  pass "I7  place() creates the parent only when absent"
fi

# --- IA: --apply end to end, unprivileged, into a fake root. Every path the
# installer writes is rewritten into $FR/root in a copy of the tree, and the
# root-only commands are stubbed: id says 0, install drops -o/-g, systemctl
# records what it was asked, stat reports the owner as root. What this proves
# is the installer's own logic - order, atomicity, records, pruning; ownership
# still needs a root run (I8).
fr_setup() {   # fr_setup <dir> - tree at <dir>/repo, fake root at <dir>/root, stubs at <dir>/stub
  local d="$1" s
  rm -rf "$d"; mkdir -p "$d/repo" "$d/root" "$d/stub"
  for s in settings lib bin hooks share profile.d systemd; do cp -a "$SCRIPTS/../$s" "$d/repo/"; done
  mkdir -p "$d/repo/docs" && cp -a "$SCRIPTS/../docs/ENGINEER-GUIDE.md" "$d/repo/docs/"
  cp -a "$SCRIPTS/../config.example.sh" "$d/repo/config.example.sh"
  cp -a "$SCRIPTS/../config.example.sh" "$d/repo/config.sh"
  /usr/bin/python3 -I - "$d/repo" "$d/root" <<'PY'
import os, re, sys
repo, root = sys.argv[1], sys.argv[2]
pat = re.compile(r'(?<![\w./-])(/etc/claude-code-admin|/etc/claude-code|/usr/local/sbin|/usr/local/share/claude-code'
                 r'|/var/log/claude-code|/etc/systemd/system|/etc/logrotate\.d|/etc/profile\.d|/etc/skel)(?=[/"\'\s:;)]|$)')
for top, _, files in os.walk(repo):
    for f in files:
        p = os.path.join(top, f)
        try:
            t = open(p).read()
        except (UnicodeDecodeError, OSError):
            continue
        n = pat.sub(lambda m: root + m.group(1), t)
        if n != t:
            open(p, "w").write(n)
PY
  printf '#!/bin/sh\n[ "$1" = "-u" ] && [ $# -eq 1 ] && { echo 0; exit 0; }\nexec /usr/bin/id "$@"\n' > "$d/stub/id"
  printf '#!/bin/bash\na=()\nwhile [ $# -gt 0 ]; do case "$1" in -o|-g) shift 2 ;; *) a+=("$1"); shift ;; esac; done\nexec /usr/bin/install "${a[@]}"\n' > "$d/stub/install"
  printf '#!/bin/sh\necho "$*" >> "%s/systemctl.log"\n[ "$1" = daemon-reload ] && [ -f "%s/fail-reload" ] && exit 1\nexit 0\n' "$d" "$d" > "$d/stub/systemctl"
  printf '#!/bin/sh\nexit 0\n' > "$d/stub/chown"
  printf '#!/bin/sh\n/usr/bin/stat "$@" | sed "s/ %s\\$/ root/"\n' "$(id -un)" > "$d/stub/stat"
  chmod 755 "$d/stub/"*
}
fr_apply() {   # fr_apply <dir> [args] - output <dir>/out, exit status in $WORK/rc
  local d="$1"; shift
  env PATH="$d/stub:$PATH" CC_CONFIG="$d/repo/config.sh" CC_RPM_BIN="$WORK/rpm-236" \
      CC_CLAUDE_BIN="$WORK/cl-236" CC_MOUNTINFO=/dev/null \
      bash "$d/repo/bin/cc-install.sh" --apply "$@" > "$d/out" 2>&1
  echo $? > "$WORK/rc"
}
fr_touch_policy() {   # fr_touch_policy <dir> <tag> - a content change place() must write
  /usr/bin/python3 -I - "$1/repo/settings/managed-settings.json" "$2" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p)); d["_comment_test_touch"] = sys.argv[2]
json.dump(d, open(p, "w"), indent=2)
PY
}
# --- I8: the I7 defect end to end, as REAL root - the fake root's stubs
# (install drops -o/-g, stat prints root) cannot show ownership, so this case
# runs the same rewritten tree with only systemctl stubbed. Every path the
# installer writes, $CC_ETC included, is under $I8/root. One left at its
# live location would let a root run of the suite on a governed host write the
# fixture's policy and template config.sh over the real ones.
if [ "$(id -u)" -ne 0 ]; then
  skip "I8  --apply --with-admin leaves CC_ETC_ADMIN 0700 (needs root)"
  skip "I8b the apply states it verified the admin dir after writing (needs root)"
else
  I8="$WORK/i8"; fr_setup "$I8"
  mkdir -p "$I8/stub-root"; mv "$I8/stub/systemctl" "$I8/stub-root/"
  ai_run() {
    env PATH="$I8/stub-root:$PATH" CC_CONFIG="$I8/repo/config.sh" CC_RPM_BIN="$WORK/rpm-236" \
        CC_CLAUDE_BIN="$WORK/cl-236" CC_MOUNTINFO=/dev/null \
        bash "$I8/repo/bin/cc-install.sh" --apply --with-admin >"$WORK/ai.out" 2>&1
    echo $? > "$WORK/rc"
  }
  # First apply creates the directory and writes the policy into it - the run
  # in which the directory's mode is the installer's to set.
  ai_run; CURRENT="$WORK/ai.out"
  M1=$(stat -c '%a %U' "$I8/root/etc/claude-code-admin" 2>/dev/null || echo missing)
  # Second apply with CHANGED content: place() skips identical files, so only a
  # real rewrite reaches the parent-creation line. This is the "after an update"
  # case.
  python3 - "$I8/repo/settings/managed-settings-admin.json" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p))
d["_comment_test_touch"] = "force a content difference so place() rewrites"
json.dump(d, open(p, "w"), indent=2)
PY
  ai_run
  M2=$(stat -c '%a %U' "$I8/root/etc/claude-code-admin" 2>/dev/null || echo missing)
  if [ "$M1" = "700 root" ] && [ "$M2" = "700 root" ]; then
    pass "I8  --apply --with-admin leaves CC_ETC_ADMIN 0700 (first: $M1, rewrite: $M2)"
  else
    fail "I8  --apply --with-admin leaves CC_ETC_ADMIN 0700 (first: $M1, rewrite: $M2)"
  fi
  # I8b: the run must SAY it checked. mkdirmode self-heals a wrong mode at the
  # top of step [12], so the post-condition cannot be provoked from outside
  # without breaking the script - which means the thing worth asserting is that
  # it makes a positive claim at all. A silent pass and a check that never ran
  # are indistinguishable to an operator reading the transcript, and this is the
  # directory whose mode nothing else on the host verifies.
  assert_has "I8b the apply states it verified the admin dir after writing" \
             "$WORK/ai.out" "verified 0700 root after write"
fi

FR="$WORK/fr"; fr_setup "$FR"; FRE="$FR/root/etc/claude-code"

# IA0: place() compares with cmp, and a host without diffutils (a minimal
# container) made every compare fail - reported as "the copy does not match its
# source", a corruption alarm for a missing tool. The installer must name the
# tool and stop before it places anything. The PATH holds every /usr/bin tool
# except cmp.
mkdir -p "$WORK/nocmp"
for f in /usr/bin/*; do [ "${f##*/}" = cmp ] || ln -s "$f" "$WORK/nocmp/${f##*/}"; done
env PATH="$FR/stub:$WORK/nocmp" CC_CONFIG="$FR/repo/config.sh" CC_RPM_BIN="$WORK/rpm-236" \
    CC_CLAUDE_BIN="$WORK/cl-236" CC_MOUNTINFO=/dev/null \
    /usr/bin/bash "$FR/repo/bin/cc-install.sh" --apply > "$WORK/ia0.out" 2>&1
echo $? > "$WORK/rc"
assert_rc   "IA0 an apply on a host without cmp fails" "$(rc)" 1 "$WORK/ia0.out"
assert_has  "IA0 and names the missing tool" "$WORK/ia0.out" "needs cmp (package diffutils)"
assert_lacks "IA0 and does not misreport it as a bad copy" "$WORK/ia0.out" "does not match its source"
assert_lacks "IA0 and attempts no placement" "$WORK/ia0.out" "-> $FR/root/"

fr_apply "$FR"
assert_rc  "IA1 an unprivileged apply into a fake root completes" "$(rc)" 0 "$FR/out"

# IA2: place() must never leave the live file half-written. The fault is a
# write that dies part-way (a full disk): the stub copies half the source and
# fails. An in-place install leaves the policy truncated; a temp-and-rename one
# leaves the previous policy whole.
cp "$FRE/managed-settings.json" "$WORK/ia2.before"
fr_touch_policy "$FR" ia2
cp "$FR/stub/install" "$FR/stub/install.real"
cat > "$FR/stub/install" <<EOF2
#!/bin/bash
case "\$*" in *managed-settings*) last="\${@: -1}"; src="\${@: -2:1}"
  head -c \$(( \$(wc -c < "\$src") / 2 )) "\$src" > "\$last"; exit 1 ;; esac
exec "$FR/stub/install.real" "\$@"
EOF2
fr_apply "$FR"
if cmp -s "$WORK/ia2.before" "$FRE/managed-settings.json"; then
  pass "IA2 a write that dies part-way leaves the previous policy whole"
else
  CURRENT="$FR/out"; fail "IA2 a write that dies part-way leaves the previous policy whole"
fi
if [ "$(rc)" -ne 0 ]; then pass "IA2 and the apply fails"; else fail "IA2 and the apply fails"; fi
mv "$FR/stub/install.real" "$FR/stub/install"

# IA3: the policy names the hooks, so it goes in LAST, and a failed step
# stops the run before it. A hook that cannot be written must leave the old
# policy in force and enable nothing.
fr_apply "$FR"; cp "$FRE/managed-settings.json" "$WORK/ia3.before"; : > "$FR/systemctl.log"
fr_touch_policy "$FR" ia3; echo "# ia3" >> "$FR/repo/hooks/cc-audit-hook.sh"
cp "$FR/stub/install" "$FR/stub/install.real"
printf '#!/bin/bash\ncase "$*" in *cc-audit-hook*) exit 1 ;; esac\nexec "%s" "$@"\n' "$FR/stub/install.real" > "$FR/stub/install"
fr_apply "$FR"; CURRENT="$FR/out"
if cmp -s "$WORK/ia3.before" "$FRE/managed-settings.json"; then
  pass "IA3 a failed hook placement leaves the old policy in force"
else
  fail "IA3 a failed hook placement leaves the old policy in force"
fi
if [ -s "$FR/systemctl.log" ]; then fail "IA3 and the run stops before enabling timers"; else pass "IA3 and the run stops before enabling timers"; fi
assert_rc  "IA3 and exits 1" "$(rc)" 1 "$FR/out"
mv "$FR/stub/install.real" "$FR/stub/install"
fr_touch_policy "$FR" ia3b; echo "# ia3b" >> "$FR/repo/hooks/cc-audit-hook.sh"
fr_apply "$FR"
POLN=$(grep -n "install managed-settings.json" "$FR/out" | head -1 | cut -d: -f1)
HOOKN=$(grep -n "install cc-audit-hook.sh" "$FR/out" | head -1 | cut -d: -f1)
if [ -n "$POLN" ] && [ -n "$HOOKN" ] && [ "$POLN" -gt "$HOOKN" ]; then
  pass "IA3 the policy is placed after the hooks it names"
else
  CURRENT="$FR/out"; fail "IA3 the policy is placed after the hooks it names (policy line ${POLN:-none}, hook line ${HOOKN:-none})"
fi

# IA4: the host records which commit it was built from, read from the
# repository's files - never by running git as root in a checkout others write.
FR4="$WORK/fr4"; fr_setup "$FR4"
( cd "$FR4/repo" && git init -q && git add -A && git -c user.name=t -c user.email=t@t commit -qm t ) >/dev/null 2>&1
fr_apply "$FR4"
WANT=$(git -C "$FR4/repo" rev-parse HEAD 2>/dev/null)
assert_has "IA4 the install record names the deployed commit" "$FR4/root/etc/claude-code/install-record" "commit=$WANT"
assert_has "IA4 and lists the files it placed" "$FR4/root/etc/claude-code/install-record" "file=$FR4/root/usr/local/sbin/cc-audit-hook.sh"
# IA4b: a checkout that moves under a running apply is reported, not recorded as one commit.
printf '#!/bin/sh\ncd "%s/repo" && git -c user.name=t -c user.email=t@t commit -q --allow-empty -m moved\nexit 0\n' "$FR4" > "$FR4/stub/systemctl"
echo "# ia4b" >> "$FR4/repo/share/statusline.sh"
fr_apply "$FR4"
assert_has "IA4b a checkout that moves during the apply is reported" "$FR4/out" "the checkout moved during this apply"
assert_rc  "IA4b and the apply fails" "$(rc)" 1 "$FR4/out"

# IA5: a replaced file is kept, so the previous deployment can be restored.
fr_apply "$FR"; cp "$FR/root/usr/local/sbin/cc-audit-hook.sh" "$WORK/ia5.before"
echo "# ia5" >> "$FR/repo/hooks/cc-audit-hook.sh"; fr_apply "$FR"
if cmp -s "$WORK/ia5.before" "$FR/root/var/log/claude-code/install-backup/last$FR/root/usr/local/sbin/cc-audit-hook.sh"; then
  pass "IA5 the file an apply replaced is kept in install-backup/last"
else
  CURRENT="$FR/out"; fail "IA5 the file an apply replaced is kept in install-backup/last"
fi

# IA6: one change at a time. Two applies, or an apply and a package
# update, interleaving leave a host matching neither.
( flock 9; sleep 4 ) 9>"$FRE/.cc-control.lock" &
IAPID=$!; sleep 1
fr_apply "$FR"
assert_has "IA6 a second apply refuses while another holds the lock" "$FR/out" "another install or update is running"
assert_rc  "IA6 and exits 1" "$(rc)" 1 "$FR/out"
mkdir -p "$WORK/ia6etc"; printf '#!/bin/sh\necho "$*" >> "%s/ia6.dnf"\n' "$WORK" > "$WORK/ia6dnf"; chmod 755 "$WORK/ia6dnf"
( flock 9; sleep 4 ) 9>"$WORK/ia6etc/.cc-control.lock" &
sleep 1
env CC_ETC="$WORK/ia6etc" CC_LOG="$WORK/ia6.log" CC_ALLOW_NONROOT=1 CC_DNF_BIN="$WORK/ia6dnf" \
    bash "$SCRIPTS/cc-update.sh" apply 9.9.9 > "$WORK/ia6u.out" 2>&1
echo $? > "$WORK/rc"
assert_has "IA6 cc-update.sh apply refuses on the same lock" "$WORK/ia6u.out" "another install or update is running"
if [ -e "$WORK/ia6.dnf" ]; then fail "IA6 and runs no dnf"; else pass "IA6 and runs no dnf"; fi
wait

# IA7: a hand-edited policy is evidence. The apply reports it and keeps the
# edited copy before overwriting; --check reports it too.
fr_apply "$FR"; echo " " >> "$FRE/managed-settings.json"; cp "$FRE/managed-settings.json" "$WORK/ia7.edited"
env PATH="$FR/stub:$PATH" CC_CONFIG="$FR/repo/config.sh" CC_RPM_BIN="$WORK/rpm-236" CC_CLAUDE_BIN="$WORK/cl-236" \
    CC_MOUNTINFO=/dev/null bash "$FR/repo/bin/cc-install.sh" --check > "$WORK/ia7c.out" 2>&1
assert_has "IA7 --check reports a policy that differs from its recorded baseline" "$WORK/ia7c.out" "differs from its recorded baseline"
fr_apply "$FR"
assert_has "IA7 --apply reports it before overwriting" "$FR/out" "differs from its recorded baseline"
KEPT=$(ls "$FR/root/var/log/claude-code/install-backup/" 2>/dev/null | grep '^hand-edited-' | head -1)
if [ -n "$KEPT" ] && cmp -s "$WORK/ia7.edited" "$FR/root/var/log/claude-code/install-backup/$KEPT"; then
  pass "IA7 and keeps the hand-edited copy"
else
  CURRENT="$FR/out"; fail "IA7 and keeps the hand-edited copy"
fi

# IA8: a file the repository no longer ships is removed from the host
# (kept in the backup); a file the installer never placed is left alone.
fr_apply "$FR"
printf '#!/bin/sh\n' > "$FR/root/usr/local/sbin/cc-retired.sh"
printf '#!/bin/sh\n' > "$FR/root/usr/local/sbin/not-ours.sh"
echo "file=$FR/root/usr/local/sbin/cc-retired.sh" >> "$FRE/install-record"
fr_apply "$FR"
CURRENT="$FR/out"
if [ -e "$FR/root/usr/local/sbin/cc-retired.sh" ]; then fail "IA8 a file the repo dropped is removed"; else pass "IA8 a file the repo dropped is removed"; fi
if [ -e "$FR/root/usr/local/sbin/not-ours.sh" ]; then pass "IA8 a file the installer never placed is left alone"; else fail "IA8 a file the installer never placed is left alone"; fi
if [ -e "$FR/root/var/log/claude-code/install-backup/last$FR/root/usr/local/sbin/cc-retired.sh" ]; then
  pass "IA8 and the removed file is kept in the backup"; else fail "IA8 and the removed file is kept in the backup"; fi

# IA9: an earlier --with-admin does not silently stay behind unmanaged.
FR9="$WORK/fr9"; fr_setup "$FR9"
fr_apply "$FR9" --with-admin
assert_rc  "IA9 --with-admin applies" "$(rc)" 0 "$FR9/out"
M9=$(/usr/bin/stat -c '%a' "$FR9/root/etc/claude-code-admin" 2>/dev/null)
if [ "$M9" = 700 ]; then pass "IA9 and the admin directory is 0700"; else fail "IA9 and the admin directory is 0700 (got ${M9:-missing})"; fi
fr_apply "$FR9"
assert_has "IA9 a later apply without it refuses rather than leave the admin files unmanaged" "$FR9/out" "the privileged session is installed on this host"
assert_rc  "IA9 and exits 1" "$(rc)" 1 "$FR9/out"
fr_apply "$FR9" --remove-admin
CURRENT="$FR9/out"
if [ -e "$FR9/root/usr/local/sbin/cc-admin-session.sh" ] || [ -e "$FR9/root/etc/claude-code-admin/managed-settings.json" ]; then
  fail "IA9 --remove-admin removes the launcher and the admin policy"
else
  pass "IA9 --remove-admin removes the launcher and the admin policy"
fi

# IA10: the new-account baseline is managed, not seeded once and abandoned.
echo '{"stale": true}' > "$FR/root/etc/skel/.claude/settings.json"
fr_apply "$FR"
assert_lacks "IA10 an outdated skel baseline is brought up to date" "$FR/root/etc/skel/.claude/settings.json" "stale"

# IA11: a failed daemon-reload fails the apply.
touch "$FR/fail-reload"; fr_apply "$FR"; rm -f "$FR/fail-reload"
assert_has "IA11 a failed daemon-reload is reported" "$FR/out" "systemctl daemon-reload failed"
assert_rc  "IA11 and the apply exits 1" "$(rc)" 1 "$FR/out"

# ================================================================ cc-repo-perms
head2 "cc-repo-perms.sh"

# The script exists to stop git's blindness to modes from breaking the tree, so
# the one thing it must never do is strip an execute bit itself. It did: *.sh was
# matched only under the TOP-LEVEL bin/ hooks/ share/ tests/, so a script in a
# nested directory - aws/bin/cc-apply-posture.sh - fell through to the "everything
# else 660" rule. These cases fence both directions.
PFX="$WORK/permsrepo"
mkdir -p "$PFX/bin" "$PFX/aws/bin" "$PFX/hooks" "$PFX/docs" "$PFX/lib" "$PFX/internal"
printf '#!/usr/bin/env bash\ntrue\n' > "$PFX/bin/cc-top.sh"
printf '#!/usr/bin/env bash\ntrue\n' > "$PFX/aws/bin/cc-nested.sh"
printf '#!/usr/bin/env bash\ntrue\n' > "$PFX/hooks/cc-hook.sh"
printf 'sourced, never executed\n'    > "$PFX/lib/cc-config.sh"
printf '# doc\n'                      > "$PFX/docs/GUIDE.md"
chmod 600 "$PFX/bin/cc-top.sh" "$PFX/aws/bin/cc-nested.sh" "$PFX/hooks/cc-hook.sh"
# The script refuses unless CC_REPO_GROUP resolves and the runner is in it, so
# the fixture config names the runner's own primary group. The checkout's
# own config.sh would make PM1-PM5 pass only for members of the group it names.
PMCFG="$WORK/perms-config.sh"
cp "$SCRIPTS/../config.example.sh" "$PMCFG"
printf 'CC_REPO_GROUP="%s"\n' "$(id -gn)" >> "$PMCFG"
O="$WORK/perms.out"
CC_CONFIG="$PMCFG" CC_PERMS_TREE="$PFX" bash "$SCRIPTS/cc-repo-perms.sh" --check > "$O" 2>&1
echo $? > "$WORK/rc"
assert_rc  "PM1 --check exits 0" "$(rc)" 0 "$O"
assert_has "PM1 a top-level bin script is made executable"  "$O" "770 $PFX/bin/cc-top.sh"
assert_has "PM2 a NESTED bin script is made executable too" "$O" "770 $PFX/aws/bin/cc-nested.sh"
assert_has "PM3 a hooks script is made executable"          "$O" "770 $PFX/hooks/cc-hook.sh"
CURRENT="$O"
if grep -q "660 $PFX/aws/bin/cc-nested.sh" "$O"; then
  fail "PM4 the nested script is NOT stripped to 660"
else
  pass "PM4 the nested script is NOT stripped to 660"
fi
# lib/*.sh is sourced, not run: it must stay non-executable, which is the reason
# the rule keys on the DIRECTORY rather than on the .sh suffix alone.
assert_has "PM5 a sourced lib/*.sh stays 660" "$O" "660 $PFX/lib/cc-config.sh"
# And the two refusals that guard the group: a name that does not resolve, and
# one the runner is not in - either would chgrp the tree to a group nobody here
# can use.
printf 'CC_REPO_GROUP="cc-no-such-group-for-tests"\n' >> "$PMCFG"
CC_CONFIG="$PMCFG" CC_PERMS_TREE="$PFX" bash "$SCRIPTS/cc-repo-perms.sh" --check > "$O" 2>&1
assert_rc  "PM6 a group that does not resolve is refused" "$?" 1 "$O"
assert_has "PM6 and says so" "$O" "does not resolve on this host"
PMOTHER=$(getent group | cut -d: -f1 | grep -vxF -f <(id -nG | tr ' ' '\n') | head -1)
if [ "$(id -u)" -eq 0 ] || [ -z "$PMOTHER" ]; then
  skip "PM7 not-a-member refusal (root bypasses it, or no foreign group resolves)"
else
  printf 'CC_REPO_GROUP="%s"\n' "$PMOTHER" >> "$PMCFG"
  CC_CONFIG="$PMCFG" CC_PERMS_TREE="$PFX" bash "$SCRIPTS/cc-repo-perms.sh" --check > "$O" 2>&1
  assert_rc  "PM7 a group the runner is not in is refused" "$?" 1 "$O"
  assert_has "PM7 and says so" "$O" "is not in '$PMOTHER' in THIS session"
fi
# Stripping 'other' access is never wrong, whatever the group, so it must not
# wait for the group checks: where the group does not resolve, a refusal that
# came first would leave internal/ world-readable. .git is included, because
# .git/objects holds every revision of internal/.
mkdir -p "$PFX/.git/objects/ab"
printf 'blob\n'     > "$PFX/.git/objects/ab/cd"
printf 'finding\n'  > "$PFX/internal/F.md"
chmod 755 "$PFX/.git" "$PFX/.git/objects" "$PFX/.git/objects/ab" "$PFX/internal"
chmod 644 "$PFX/.git/objects/ab/cd" "$PFX/internal/F.md"
PMBAD="$WORK/perms-badgroup.sh"
cp "$SCRIPTS/../config.example.sh" "$PMBAD"
printf 'CC_REPO_GROUP="cc-no-such-group-for-tests"\n' >> "$PMBAD"
CC_CONFIG="$PMBAD" CC_PERMS_TREE="$PFX" bash "$SCRIPTS/cc-repo-perms.sh" --check > "$O" 2>&1
assert_rc  "PM8 --check with an unresolved group still exits 1" "$?" 1 "$O"
assert_has "PM8 and reports the world access it would strip" "$O" "WOULD strip other-access"
if [ -n "$(find "$PFX/internal/F.md" -perm /o=rwx)" ]; then pass "PM8 --check changed nothing"; else fail "PM8 --check changed nothing"; fi
CC_CONFIG="$PMBAD" CC_PERMS_TREE="$PFX" bash "$SCRIPTS/cc-repo-perms.sh" --apply > "$O" 2>&1
assert_rc  "PM9 --apply with an unresolved group still exits 1" "$?" 1 "$O"
CURRENT="$O"
if [ -z "$(find "$PFX" -perm /o=rwx)" ]; then
  pass "PM9 ...but strips every 'other' bit first, .git included"
else
  fail "PM9 ...but strips every 'other' bit first, .git included"
fi
chmod 644 "$PFX/.git/objects/ab/cd"
cp "$SCRIPTS/../config.example.sh" "$PMCFG.ok"
printf 'CC_REPO_GROUP="%s"\n' "$(id -gn)" >> "$PMCFG.ok"
CC_CONFIG="$PMCFG.ok" CC_PERMS_TREE="$PFX" bash "$SCRIPTS/cc-repo-perms.sh" --apply > "$O" 2>&1
assert_rc  "PM10 --apply with a good group exits 0" "$?" 0 "$O"
if [ -z "$(find "$PFX/.git" -perm /o=rwx)" ]; then
  pass "PM10 strips 'other' access inside .git too"
else
  fail "PM10 strips 'other' access inside .git too"
fi

# ================================================================ statusline
head2 "share/statusline.sh"

# The status line renders on every prompt, so a wrong segment is seen by every
# user and believed. A git global option placed after the subcommand makes git
# diff exit 129, and a script that reads any non-zero exit as "changes present"
# then reports every repository as dirty. These cases fence the git segment, the
# per-user override, and the Bedrock-only cost segment.
SL="$HERE/../share/statusline.sh"
SLH="$WORK/slhome"; SLR="$WORK/slrepo"
mkdir -p "$SLH/.claude" "$SLR"
git -C "$SLR" init -q && git -C "$SLR" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
sl() { printf '%s' "$1" | env -u CLAUDE_CODE_USE_BEDROCK HOME="$SLH" CC_PYTEST_RESULT=/nonexistent "${@:2}" bash "$SL" > "$WORK/sl.out" 2>&1; }
SLJ='{"model":{"id":"claude-x"},"workspace":{"current_dir":"'"$SLR"'"},"cost":{"total_cost_usd":1.234,"total_duration_ms":3720000}}'

sl "$SLJ"
assert_has   "SL1 a clean repository renders without a dirty marker" "$WORK/sl.out" "git:"
assert_lacks "SL1b ...and no '*' follows the branch"                 "$WORK/sl.out" "*"
echo x > "$SLR/tracked" && git -C "$SLR" add tracked
sl "$SLJ"
assert_has   "SL2 a staged change renders the dirty marker"          "$WORK/sl.out" "*"
git -C "$SLR" -c user.email=t@t -c user.name=t commit -q -m t && touch "$SLR/new"
sl "$SLJ"
assert_has   "SL3 an untracked file renders the untracked marker"    "$WORK/sl.out" "?"
rm -f "$SLR/new"

sl "$SLJ"
assert_has   "SL4 session duration comes from cost.total_duration_ms" "$WORK/sl.out" "up:1h2m"
assert_lacks "SL5 no cost segment on a subscription login"           "$WORK/sl.out" '$1.23'
sl "$SLJ" CLAUDE_CODE_USE_BEDROCK=1
assert_has   "SL6 session cost renders when CLAUDE_CODE_USE_BEDROCK=1" "$WORK/sl.out" '$1.23'

printf '#!/bin/bash\necho USER-OVERRIDE\n' > "$SLH/.claude/statusline.sh"
chmod 0644 "$SLH/.claude/statusline.sh"
sl "$SLJ"
assert_has   "SL7 a user's own ~/.claude/statusline.sh replaces the default" "$WORK/sl.out" "USER-OVERRIDE"
chmod 0664 "$SLH/.claude/statusline.sh"
sl "$SLJ"
assert_lacks "SL8 a group-writable override is refused (someone else could edit it)" "$WORK/sl.out" "USER-OVERRIDE"
assert_has   "SL8b ...and the default renders instead"                "$WORK/sl.out" "git:"
rm -f "$SLH/.claude/statusline.sh"

# ================================================================ cc-template-fill
head2 "cc-template-fill.sh"
# The script acts on the clone it lives in, so each fixture carries a copy.
mk_tf() {  # mk_tf <dir> [template.json content] - a clone with one placeholder used in two files
  mkdir -p "$1/bin" "$1/docs"
  cp "$SCRIPTS/cc-template-fill.sh" "$1/bin/"
  printf 'org: REPLACE-WITH-FIXTURE-ORG, again REPLACE-WITH-FIXTURE-ORG\n' > "$1/a.txt"
  printf 'mail REPLACE-WITH-FIXTURE-MAIL\n' > "$1/docs/b.md"
  printf 'no placeholder here\n' > "$1/plain.txt"
  printf '# fill me\n' > "$1/TEMPLATE.md"
  local list='{"placeholders": {"REPLACE-WITH-FIXTURE-ORG": {"meaning": "org", "example": "Example Org"}, "REPLACE-WITH-FIXTURE-MAIL": {"meaning": "mail", "example": "help@example.org"}}}'
  printf '%s\n' "${2:-$list}" > "$1/template.json"
  git -C "$1" init -q && git -C "$1" add -A
  printf 'untracked\n' > "$1/scratch.txt"
}
run_tf() { local out="$WORK/tf.$RANDOM.out"   # run_tf <src> <args...>
  local src="$1"; shift
  ( cd "$src" && bash bin/cc-template-fill.sh "$@" ) >"$out" 2>&1
  echo $? > "$WORK/rc"; echo "$out"; }
S="$WORK/tf1"; mk_tf "$S"
O=$(run_tf "$S");                 assert_rc "TF1 no destination is a usage error" "$(rc)" 2 "$O"
O=$(run_tf "$S" a b);             assert_rc "TF1b two destinations is a usage error" "$(rc)" 2 "$O"
O=$(run_tf "$S" --bogus);         assert_rc "TF1c an unknown option is a usage error, not a directory name" "$(rc)" 2 "$O"
D="$WORK/tf1.out"
O=$(run_tf "$S" "$D");            assert_rc "TF2 a template fills into a new directory" "$(rc)" 0 "$O"
printf 'org: Example Org, again Example Org\n' > "$WORK/tf.want.a"
printf 'mail help@example.org\n' > "$WORK/tf.want.b"
cmp -s "$D/a.txt" "$WORK/tf.want.a" && cmp -s "$D/docs/b.md" "$WORK/tf.want.b" \
  && pass "TF2 every listed placeholder is replaced, in every file, by its neutral value" || fail "TF2 the filled files are not the expected bytes"
cmp -s "$D/plain.txt" "$S/plain.txt" && pass "TF2 a file with no placeholder is copied unchanged" || fail "TF2 plain.txt changed"
[ ! -e "$D/template.json" ] && [ ! -e "$D/TEMPLATE.md" ] \
  && pass "TF3 the filled copy is a site edition: no template.json, no TEMPLATE.md" || fail "TF3 the template's own files were copied"
[ ! -e "$D/scratch.txt" ] && pass "TF3 an untracked file is not copied" || fail "TF3 an untracked file reached the copy"
[ -x "$D/bin/cc-template-fill.sh" ] && pass "TF3 file modes survive the copy" || fail "TF3 the script lost its executable bit"
O=$(run_tf "$S" "$D");            assert_rc "TF4 a destination that already holds files is refused, not merged into" "$(rc)" 1 "$O"
mkdir "$WORK/tf.empty"
O=$(run_tf "$S" "$WORK/tf.empty"); assert_rc "TF4b an existing empty directory is accepted" "$(rc)" 0 "$O"
S="$WORK/tf5"; mk_tf "$S"; git -C "$S" rm -q --cached template.json; rm "$S/template.json"
O=$(run_tf "$S" "$WORK/tf5.out"); assert_rc "TF5 a tree with no template.json is not a template - refused" "$(rc)" 1 "$O"
[ ! -e "$WORK/tf5.out" ] && pass "TF5 and nothing was created" || fail "TF5 a refusal left a directory behind"
# The marker is the TRACKED file, as in check [2]: a stray template.json in a
# working tree does not turn a site edition into a template.
S="$WORK/tf5b"; mk_tf "$S"; git -C "$S" rm -q --cached template.json
O=$(run_tf "$S" "$WORK/tf5b.out"); assert_rc "TF5b an untracked template.json does not make a template - refused" "$(rc)" 1 "$O"
S="$WORK/tf6"; mk_tf "$S" '{not json'
O=$(run_tf "$S" "$WORK/tf6.out"); assert_rc "TF6 an unreadable template.json is refused" "$(rc)" 1 "$O"
S="$WORK/tf7"; mk_tf "$S" '{"placeholders": {}}'
O=$(run_tf "$S" "$WORK/tf7.out"); assert_rc "TF7 an empty placeholder list is refused" "$(rc)" 1 "$O"
# --list is the one reading of template.json: check [2] takes its names from it.
S="$WORK/tf8"; mk_tf "$S"
O=$(run_tf "$S" --list); assert_rc "TF8 --list exits 0 on a usable list" "$(rc)" 0 "$O"
printf 'REPLACE-WITH-FIXTURE-MAIL\nREPLACE-WITH-FIXTURE-ORG\n' > "$WORK/tf8.want"
( cd "$S" && bash bin/cc-template-fill.sh --list 2>/dev/null ) | cmp -s - "$WORK/tf8.want" \
  && pass "TF8 --list prints the listed names, one per line, and nothing else" || fail "TF8 --list did not print exactly the listed names"
TF_ENTRY='{"meaning": "m", "example": "v"}'
for bad in 'E' 'XEPLACE-WITH-ABC' 'REPLACE-WITH-' 'REPLACE-WITH-lower' 'REPLACE-WITH-A B' 'REPLACE-WITH-A-'; do
  S="$WORK/tf9.$RANDOM"; mk_tf "$S" "{\"placeholders\": {\"REPLACE-WITH-FIXTURE-ORG\": $TF_ENTRY, \"$bad\": $TF_ENTRY}}"
  O=$(run_tf "$S" --list); assert_rc "TF9 a list naming '$bad' is refused" "$(rc)" 1 "$O"
done
S="$WORK/tf10"; mk_tf "$S" '{"placeholders": ["REPLACE-WITH-FIXTURE-ORG"]}'
O=$(run_tf "$S" --list); assert_rc "TF10 a list that is not an object of name: meaning is refused" "$(rc)" 1 "$O"
# Each entry says what the placeholder means and gives the value a filled copy
# carries. A value that is itself a placeholder would leave the copy unfilled.
for entry in '"just a sentence"' '{"meaning": "m"}' '{"example": "v"}' '{"meaning": "m", "example": ""}' '{"meaning": "m", "example": 7}' '{"meaning": "m", "example": "REPLACE-WITH-FIXTURE-ORG"}'; do
  S="$WORK/tf11.$RANDOM"; mk_tf "$S" "{\"placeholders\": {\"REPLACE-WITH-FIXTURE-ORG\": $entry}}"
  O=$(run_tf "$S" --list); assert_rc "TF11 an entry of $entry is refused" "$(rc)" 1 "$O"
done

# ================================================================ cc-publish
head2 "cc-publish.sh"

# The public template edition (docs/PUBLISHING.md). Every case runs against a
# scratch source repo standing in for this one: a fake site ("Zephyr Corp",
# one person "Quokka.Lee"), an internal/ that must never leave, stub
# verifiers whose exit code the case chooses, and the real secret guard.
PUB="$SCRIPTS/cc-publish.sh"
mk_pub_src() {  # mk_pub_src <dir>
  local d="$1"
  mkdir -p "$d/bin" "$d/tests" "$d/githooks" "$d/settings" "$d/internal" "$d/publish/overlay/internal" "$d/docs"
  git -C "$d" init -q
  printf 'Zephyr Corp builds things. zephyrus and subzephyr are different words.\n' > "$d/README.md"
  printf '# docs\n' > "$d/docs/README.md"  # keeps docs/ when a case removes its only file
  # the real policy holds its banner art raw (UTF-8, newlines escaped); a JSON
  # writer may as well \u-escape it - both forms must be found
  printf '{"banner": "Zephyr Corp\\nfleet", "raw": "Zephyr \xe2\x95\x90\\nart", "esc": "Zephyr \\u2550\\nart"}\n' > "$d/settings/p.json"
  printf 'internal Zephyr notes\n' > "$d/internal/secret.md"
  printf '#!/bin/sh\nexit "${STUB_CI_RC:-0}"\n' > "$d/bin/cc-ci-check.sh"
  printf '#!/bin/sh\nexit "${STUB_SUITE_RC:-0}"\n' > "$d/tests/test-cc-scripts.sh"
  cp "$SCRIPTS/../githooks/pre-commit" "$d/githooks/pre-commit"
  printf '# Template\n\nFill the placeholders listed in template.json.\n' > "$d/publish/overlay/TEMPLATE.md"
  printf '{"placeholders": {"REPLACE-WITH-FIXTURE-ORG": {"meaning": "the organisation", "example": "Example Org"}}}\n' > "$d/publish/overlay/template.json"
  printf '# internal\n' > "$d/publish/overlay/internal/README.md"
  git -C "$d" add -A
  git -C "$d" -c user.name=t -c user.email=t@example.org commit -qm src
}
mk_pub_map() {  # mk_pub_map <path> <mode> [json] - default: the fake site's map
  if [ -n "${3:-}" ]; then printf '%s\n' "$3" > "$1"; else cat > "$1" <<'JSON'
{"replace": [["Zephyr Corp\nfleet", "REPLACE-WITH-FIXTURE-ORG"], ["Zephyr Corp", "REPLACE-WITH-FIXTURE-ORG"],
             ["Zephyr \u2550\nart", "REPLACE-WITH-FIXTURE-ART"]],
 "deny": ["zephyr", "Quokka.Lee"]}
JSON
  fi
  chmod "$2" "$1"
}
run_pub() {  # run_pub <src dir> <args...> - output file path; exit code in $WORK/rc
  local d="$1"; shift
  local out="$WORK/pub.$RANDOM.out"
  ( cd "$d" && bash "$PUB" "$@" ) >"$out" 2>&1
  echo $? > "$WORK/rc"
  echo "$out"
}
pub_commits() { git -C "$1" rev-list --count HEAD 2>/dev/null || echo 0; }
pub_commit() { git -C "$1" add -A && git -C "$1" -c user.name=t -c user.email=t@example.org commit -qm "$2"; }

S="$WORK/pubsrc"; mk_pub_src "$S"
MAP="$WORK/pubmap.json"; mk_pub_map "$MAP" 600
OUT="$WORK/pubout"
AUTH="Pat Example <pat@example.org>"

# --- PB1-PB4: usage and the map's own guards, all before anything is written
O=$(run_pub "$S")
assert_rc  "PB1 no arguments is a usage error" "$(rc)" 2 "$O"
O=$(run_pub "$S" --out "$OUT" --map "$MAP")
assert_rc  "PB2 no --author is refused, never the machine's git identity" "$(rc)" 2 "$O"
assert_has "PB2 the refusal names --author" "$O" "--author"
mk_pub_map "$WORK/pubmap644.json" 644
O=$(run_pub "$S" --out "$OUT" --map "$WORK/pubmap644.json" --author "$AUTH")
assert_rc  "PB3 a map readable by others is refused" "$(rc)" 2 "$O"
assert_has "PB3 the refusal says why" "$O" "readable by group or others"
mk_pub_map "$WORK/pubmapbad.json" 600 '{"replace": ['
O=$(run_pub "$S" --out "$OUT" --map "$WORK/pubmapbad.json" --author "$AUTH")
assert_rc  "PB4 a map that is not JSON is refused" "$(rc)" 2 "$O"
mk_pub_map "$WORK/pubmapnodeny.json" 600 '{"replace": [], "deny": []}'
O=$(run_pub "$S" --out "$OUT" --map "$WORK/pubmapnodeny.json" --author "$AUTH")
assert_rc  "PB4b an empty deny list is refused - a scan against nothing passes everything" "$(rc)" 2 "$O"
[ -e "$OUT" ] && fail "PB4c a refused run created the output directory" || pass "PB4c no refused run created the output directory"

# --- PB5-PB7: a clean publish, what it carries, and that it is idempotent
printf 'uncommitted-line\n' >> "$S/README.md"
O=$(run_pub "$S" --out "$OUT" --map "$MAP" --author "$AUTH")
assert_rc  "PB5 a clean source publishes with exit 0" "$(rc)" 0 "$O"
assert_has "PB5 the site name became its placeholder" "$OUT/README.md" "REPLACE-WITH-FIXTURE-ORG builds things"
# The subject is compared whole: an id of the source commit would tie the public
# history to a private one, and any addition to the fixed text shows here.
[ "$(git -C "$OUT" log -1 --format=%s)" = "Publish the template edition" ] \
  && pass "PB5 the default commit subject names nothing from the source" \
  || fail "PB5 the default commit subject names nothing from the source"
assert_has "PB5 a JSON-escaped value is substituted too" "$OUT/settings/p.json" '"banner": "REPLACE-WITH-FIXTURE-ORG"'
assert_has "PB5 a raw UTF-8 value with an escaped newline is substituted" "$OUT/settings/p.json" '"raw": "REPLACE-WITH-FIXTURE-ART"'
assert_has "PB5 and its \\u-escaped form too" "$OUT/settings/p.json" '"esc": "REPLACE-WITH-FIXTURE-ART"'
[ -e "$OUT/internal/secret.md" ] && fail "PB5 internal/ was exported" || pass "PB5 internal/ is never exported"
cmp -s "$S/publish/overlay/template.json" "$OUT/template.json" \
  && pass "PB5 the overlay's template.json is laid on top, byte for byte" || fail "PB5 the output's template.json is not the overlay's"
assert_has "PB5 the overlay's blank registers land in internal/" "$OUT/internal/README.md" "# internal"
[ -e "$OUT/publish/overlay" ] && pass "PB5 the overlay itself is published (the tool is part of the template)" || fail "PB5 the overlay was dropped"
assert_lacks "PB6 an uncommitted edit never reaches the output" "$OUT/README.md" "uncommitted-line"
git -C "$OUT" log -1 --format='%an <%ae>' > "$WORK/pub.author"
assert_has "PB5 the commit is authored as --author" "$WORK/pub.author" "$AUTH"
assert_rc  "PB5 the first publish is one commit" "$(pub_commits "$OUT")" 1
git -C "$S" checkout -q -- README.md
O=$(run_pub "$S" --out "$OUT" --map "$MAP" --author "$AUTH")
assert_rc  "PB7 a second run over the same source exits 0" "$(rc)" 0 "$O"
assert_has "PB7 and says nothing changed" "$O" "unchanged"
assert_rc  "PB7 and makes no commit" "$(pub_commits "$OUT")" 1

# --- PB8-PB11: the deny scan - never prints the term, whole words, paths, bytes
printf 'ask QUOKKA.lee about it\n' > "$S/docs/x.md"; pub_commit "$S" hit
O=$(run_pub "$S" --out "$OUT" --map "$MAP" --author "$AUTH")
assert_rc    "PB8 a denied term in a file refuses (exit 1)" "$(rc)" 1 "$O"
assert_has   "PB8 the hit names file and line" "$O" "docs/x.md:1"
assert_has   "PB8 and the deny entry by number" "$O" "deny entry #2"
grep -qi quokka "$O" && fail "PB8 the output printed the denied term" || pass "PB8 the output never prints the denied term"
assert_rc    "PB8 nothing was committed" "$(pub_commits "$OUT")" 1
git -C "$S" rm -q docs/x.md; printf 'x\n' > "$S/docs/zephyr-notes.txt"; pub_commit "$S" pathhit
O=$(run_pub "$S" --out "$OUT" --map "$MAP" --author "$AUTH")
assert_rc    "PB9 a denied term in a file NAME refuses" "$(rc)" 1 "$O"
grep -qi zephyr "$O" && fail "PB9 the output printed the denied term from the path" || pass "PB9 the path is printed masked"
git -C "$S" rm -q docs/zephyr-notes.txt; printf 'bin\000ary ZEPHYR\000\n' > "$S/docs/blob.bin"; pub_commit "$S" binhit
O=$(run_pub "$S" --out "$OUT" --map "$MAP" --author "$AUTH")
assert_rc    "PB10 a denied term inside a binary file refuses" "$(rc)" 1 "$O"
git -C "$S" rm -q docs/blob.bin; pub_commit "$S" clean
O=$(run_pub "$S" --out "$OUT" --map "$MAP" --author "$AUTH")
assert_rc    "PB11 zephyrus and subzephyr are not zephyr: whole words, both edges (exit 0)" "$(rc)" 0 "$O"
O=$(run_pub "$S" --out "$OUT" --map "$MAP" --author "Quokka.Lee <q@example.org>")
assert_rc    "PB12 an author carrying a denied term refuses" "$(rc)" 1 "$O"
O=$(run_pub "$S" --out "$OUT" --map "$MAP" --author "$AUTH" --message "from Zephyr")
assert_rc    "PB12b a commit message carrying a denied term refuses" "$(rc)" 1 "$O"

# --- PB13-PB14: the secret guard and the output's own verifiers gate the commit
N=$(pub_commits "$OUT")
printf 'id=%s%s\n' "AKIA" "RDCANARYQ7WM4XP9" > "$S/docs/k.txt"; pub_commit "$S" key
O=$(run_pub "$S" --out "$OUT" --map "$MAP" --author "$AUTH")
assert_rc    "PB13 a credential-shaped value refuses (the secret guard runs)" "$(rc)" 1 "$O"
assert_rc    "PB13 nothing was committed" "$(pub_commits "$OUT")" "$N"
git -C "$S" rm -q docs/k.txt; printf 'v2\n' > "$S/docs/v2.md"; pub_commit "$S" v2
O=$(STUB_CI_RC=1 run_pub "$S" --out "$OUT" --map "$MAP" --author "$AUTH")
assert_rc    "PB14 a failing cc-ci-check in the output refuses" "$(rc)" 1 "$O"
O=$(STUB_SUITE_RC=1 run_pub "$S" --out "$OUT" --map "$MAP" --author "$AUTH")
assert_rc    "PB14b a failing suite in the output refuses" "$(rc)" 1 "$O"
assert_rc    "PB14 nothing was committed" "$(pub_commits "$OUT")" "$N"
mkdir -p "$WORK/pblog"
O=$(STUB_SUITE_RC=1 TMPDIR="$WORK/pblog" run_pub "$S" --out "$OUT" --map "$MAP" --author "$AUTH")
assert_rc    "PB14d a failed verifier leaves its whole output in one log file, to be read" "$(find "$WORK/pblog" -maxdepth 1 -type f -name 'cc-publish-verify.*' | wc -l)" 1
O=$(TMPDIR="$WORK/pblog" run_pub "$S" --out "$OUT" --map "$MAP" --author "$AUTH")
assert_rc    "PB14e a passing run leaves no log behind" "$(find "$WORK/pblog" -mindepth 1 | wc -l)" 1
mv "$S/tests/test-cc-scripts.sh" "$WORK/pub.suite"; pub_commit "$S" nosuite
O=$(run_pub "$S" --out "$OUT" --map "$MAP" --author "$AUTH")
assert_rc    "PB14c a missing verifier refuses - an unverified tree is not published" "$(rc)" 1 "$O"
mv "$WORK/pub.suite" "$S/tests/test-cc-scripts.sh"; pub_commit "$S" suiteback

# --- PB15: --push, and only --push, moves the remote
BARE="$WORK/pub.git"; git init -q --bare "$BARE"
OUT2="$WORK/pubout2"
O=$(run_pub "$S" --out "$OUT2" --remote "$BARE" --map "$MAP" --author "$AUTH")
assert_rc    "PB15 a publish without --push exits 0" "$(rc)" 0 "$O"
assert_rc    "PB15 and the remote is untouched" "$(git -C "$BARE" rev-list --all | wc -l)" 0
O=$(run_pub "$S" --out "$OUT2" --remote "$BARE" --map "$MAP" --author "$AUTH" --push)
assert_rc    "PB15 the --push run exits 0" "$(rc)" 0 "$O"
[ "$(git -C "$BARE" rev-parse main 2>/dev/null)" = "$(git -C "$OUT2" rev-parse HEAD)" ] \
  && pass "PB15 --push puts the reviewed commit on the remote's main" || fail "PB15 the remote's main is not the output's HEAD"

# --- PB16: --scan, the mode the public repository's CI runs
O=$(run_pub "$OUT" --scan)
assert_rc    "PB16 --scan with no map and no CC_PUBLISH_DENY is a usage error" "$(rc)" 2 "$O"
O=$(CC_PUBLISH_DENY=$'zephyr\nquokka.lee' run_pub "$OUT" --scan)
assert_rc    "PB16 --scan of a clean published tree exits 0" "$(rc)" 0 "$O"
printf 'from zephyr\n' > "$OUT/late.md"; git -C "$OUT" add late.md
O=$(CC_PUBLISH_DENY=$'zephyr\nquokka.lee' run_pub "$OUT" --scan)
assert_rc    "PB16 --scan finds a term added on the public side" "$(rc)" 1 "$O"
assert_has   "PB16 the hit names file and line" "$O" "late.md:1"
# The list arrived as a CI secret and this output lands in a public log: which
# entry matched, and how many entries there are, describe the list itself.
assert_lacks "PB16 a list from CC_PUBLISH_DENY is not described: no entry number" "$O" "deny entry"
assert_lacks "PB16 and no count of its entries" "$O" "deny entries"
git -C "$OUT" rm -qf late.md

# --- PB17: an export with no files is a failure, not a clean scan
E="$WORK/pubempty"; mkdir -p "$E/internal"; git -C "$E" init -q
printf 'x\n' > "$E/internal/only.md"; pub_commit "$E" only-internal
O=$(run_pub "$E" --out "$WORK/pubout3" --map "$MAP" --author "$AUTH")
assert_rc    "PB17 a source with nothing to publish refuses" "$(rc)" 1 "$O"
mkdir -p "$WORK/pubnone"; git -C "$WORK/pubnone" init -q
O=$(CC_PUBLISH_DENY=zephyr run_pub "$WORK/pubnone" --scan)
assert_rc    "PB17b --scan of a clone with no files refuses - a scan of nothing is not a pass" "$(rc)" 1 "$O"

# --- PB18: a document may name a path under internal/ only when the published
# tree holds it. The fixture names the path in two parts so this file, which is
# itself published, does not name one. PB18 and PB18b differ by one thing: the
# overlay gaining the file the document names.
PRIV=internal
N=$(pub_commits "$OUT")
printf 'The evidence is in `%s/archive/old.md`.\n' "$PRIV" > "$S/docs/ref.md"; pub_commit "$S" dead-ref
O=$(run_pub "$S" --out "$OUT" --map "$MAP" --author "$AUTH")
assert_rc    "PB18 a document naming a path the published tree does not hold refuses" "$(rc)" 1 "$O"
assert_rc    "PB18 nothing was committed" "$(pub_commits "$OUT")" "$N"
mkdir -p "$S/publish/overlay/$PRIV/archive"; printf '# old\n' > "$S/publish/overlay/$PRIV/archive/old.md"; pub_commit "$S" overlay-holds-it
O=$(run_pub "$S" --out "$OUT" --map "$MAP" --author "$AUTH")
assert_rc    "PB18b the same document publishes once the overlay holds that path" "$(rc)" 0 "$O"
printf 'Site records live under `%s/`; the register is `%s/README.md`.\n' "$PRIV" "$PRIV" > "$S/docs/ref.md"; pub_commit "$S" live-refs
O=$(run_pub "$S" --out "$OUT" --map "$MAP" --author "$AUTH")
assert_rc    "PB18c naming the directory, or a file the overlay supplies, publishes" "$(rc)" 0 "$O"
printf 'x=%s/archive/gone.txt\n' "$PRIV" > "$S/bin/writes-there.sh"; pub_commit "$S" code-names-a-runtime-path
O=$(run_pub "$S" --out "$OUT" --map "$MAP" --author "$AUTH")
assert_rc    "PB18d the rule is for documents: a script naming a path it writes at run time publishes" "$(rc)" 0 "$O"

# ================================================================ coverage ledger
head2 "runtime coverage"

# --coverage is static: it credits an assertion by where it SITS, so one inside
# `if false` or in a helper nobody calls still counts. A full run therefore
# also keeps a ledger - every pass, fail and skip records the line numbers on
# its call stack - and cov_runtime credits a script only when one of the call
# sites attributed to it actually ran. COV1-COV4 drive it with fixtures; the
# real verdict on this run is the COV line at the end of the summary.
printf 'a.sh\t10\na.sh\t11\nb.sh\t20\nc.sh\t30\n' > "$WORK/cov.map"
printf '/r/a.sh\n/r/b.sh\n/r/c.sh\n/r/d.sh\n' > "$WORK/cov.pop"
printf 'P 170 11 3000\nS 20\nF 99\n' > "$WORK/cov.ledger"
cov_runtime "$WORK/cov.map" "$WORK/cov.ledger" "$WORK/cov.pop" /r "d.sh|why" > "$WORK/cov.out" 2>&1
echo $? > "$WORK/rc"
assert_lacks "COV1 a script whose attributed case ran is not reported" "$WORK/cov.out" "a.sh"
assert_has   "COV2 a script whose only cases were skipped here says so" "$WORK/cov.out" "SKIPPED b.sh"
assert_has   "COV3 a script whose cases sit in the file but never ran fails" "$WORK/cov.out" "NONE c.sh 1"
assert_lacks "COV4 an acknowledged-untested script is not reported" "$WORK/cov.out" "d.sh"
assert_rc    "COV3 exit 1 when a script's cases never ran" "$(rc)" 1 "$WORK/cov.out"
printf 'P 30\nP 11\nS 20\n' > "$WORK/cov.ledger"
cov_runtime "$WORK/cov.map" "$WORK/cov.ledger" "$WORK/cov.pop" /r "d.sh|why" > "$WORK/cov.out" 2>&1
echo $? > "$WORK/rc"
assert_rc    "COV5 exit 0 when every script has a case that ran or was skipped" "$(rc)" 0 "$WORK/cov.out"

# ---- the run's own coverage verdict: did each script's cases RUN, not just sit?
ROOT=$(cd "$HERE/.." && pwd)
cov_map "$HERE/$(basename "$0")" > "$WORK/cov-run.map"
cov_population "$ROOT" > "$WORK/cov-run.pop"
cov_runtime "$WORK/cov-run.map" "$WORK/cov-ledger" "$WORK/cov-run.pop" "$ROOT" "$ACKNOWLEDGED_UNTESTED" > "$WORK/cov-run.out"
echo $? > "$WORK/rc"
if [ ! -s "$WORK/cov-run.pop" ] || [ ! -s "$WORK/cov-run.map" ]; then
  fail "COV the run's coverage verdict had no scripts or no call sites to judge"
elif [ "$(rc)" -eq 0 ]; then
  pass "COV every script owed cases had at least one attributed case run"
  while read -r _ s; do skip "COV every case attributed to $s was skipped on this host"; done < <(grep '^SKIPPED' "$WORK/cov-run.out")
else
  while read -r _ s n; do fail "COV $s has $n case(s) attributed to it in this file, and none of them ran"; done < <(grep '^NONE' "$WORK/cov-run.out")
fi

# ================================================================ summary
printf '\n=====================================================\n'
printf 'PASS %d   FAIL %d   SKIP %d\n' "$PASS" "$FAIL" "$SKIP"
printf '=====================================================\n'
# The footer is the run's own skip list, each with the reason its case gave -
# a hand-typed list here named five of the sixteen and went stale.
if [ "$SKIP" -gt 0 ]; then
  printf 'SKIPs are conditions this host cannot fabricate; each closes on a host that can:\n'
  sed 's/^/  /' "$WORK/skips"
fi
[ "$FAIL" -eq 0 ] || exit 1
exit 0
