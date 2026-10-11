#!/usr/bin/env bash
# cc-report.sh - the weekly estate report: run every check, say what changed,
# and answer two questions in words a person can act on.
#
# WHAT IT IS FOR. Everything this control plane knows is already checked by some
# script - but each one prints to a different place, on a different cadence, and
# nothing joins them up or notices when an answer changes. This runs them all,
# ranks what came back, compares it to last week, and writes one file that
# answers:
#
#     BUMP: ok to plan | hold - <rule ids>
#     REPORT TO MANAGEMENT: no major errors flagged | <n> alert(s) need an owner
#
# Both are FIELDS, not prose to be re-read: a reader (or a skill) takes them
# verbatim. If a reader's own reading of the ledger disagrees with the verdict,
# that is a defect in this script and should be reported as one.
#
# WHY IT RUNS AS ROOT, FROM A TIMER. The material is unreadable otherwise, and
# half-readable is worse than nothing: the activity and denial logs are 0600
# per user inside 1733 directories (an ordinary user cannot even list them);
# healthcheck.log is 0640 root:root; probe A5 cannot see a home whose ~/.local
# is 0700, and probe A8 cannot see another user's processes. An unprivileged run
# still works and is useful - it just says, in section 11, exactly which
# collectors it could not run. It never says "clean" about something it could
# not read.
#
# EXIT CODES ARE THE INTERFACE:
#   0  ran, report written, ZERO alerts (FYIs allowed)
#   1  ran, report written, at least one ALERT - the unit shows failed, which is
#      the same idiom cc-healthcheck.sh uses and the reason a timer is enough
#   2  usage error
#   3  COULD NOT COMPLETE - no report written, or the output directory is
#      unusable. Deliberately distinct from 1: "bad week" and "no answer" must
#      not look alike.
#
# WHAT IT MUST NOT DO, and does not:
#   * never sudo (it is already root under the timer; a sudo inside it is how an
#     unprivileged invocation silently escalates)
#   * never a package transaction - only read-only dnf/rpm queries
#   * never write under /etc, never invoke cc-install.sh at all
#   * never git commit/add/push/fetch, and never write into the checkout
#   * never re-implement a check a cc-* script already performs. If a check is
#     missing, that is a finding about the script that should own it
#   * never read log CONTENT beyond the shape fields the hooks already recorded,
#     and never a session transcript
#
# Site values (paths, CC_REPO, CC_REPO_GROUP, CC_REPORT_KEEP, CC_HOME_ROOT)
# come from config.sh through the installed loader, so it runs on a host with
# no checkout present. Test seams, OS defaults: CC_REPORT_DIR CC_PROC
# CC_MOUNTINFO CC_RPM_BIN CC_DNF_BIN CC_NOW. Suite cases RP1-RP16.

set -uo pipefail

# --- site configuration: config.sh through the loader --------------------------
for _cfg in "${CC_CONFIG_LIB:-}" /etc/claude-code/cc-config.sh \
            "$(dirname "$(readlink -f "$0")")/../lib/cc-config.sh"; do
  [ -n "$_cfg" ] && [ -r "$_cfg" ] && { . "$_cfg" || exit 3; _cfg_loaded=1; break; }
done
[ "${_cfg_loaded:-0}" = 1 ] || { echo "cc-report.sh: cannot find cc-config.sh (looked in /etc/claude-code/ and ../lib/)" >&2; exit 3; }
unset _cfg _cfg_loaded

CC_PROC="${CC_PROC:-/proc}"
CC_MOUNTINFO="${CC_MOUNTINFO:-/proc/self/mountinfo}"
CC_RPM_BIN="${CC_RPM_BIN:-rpm}"
OUTDIR="${CC_REPORT_DIR:-$CC_LOGDIR/reports}"
GROUP="$CC_REPO_GROUP"
KEEP="$CC_REPORT_KEEP"

DRY=0; FORMAT=both; WANT_SECTIONS=""; SKIP_SECTIONS=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)      DRY=1; shift ;;
    --output-dir)   OUTDIR="${2:?--output-dir needs a path}"; shift 2 ;;
    --repo)         CC_REPO="${2:?--repo needs a path}"; shift 2 ;;
    --keep)         KEEP="${2:?--keep needs a number}"; shift 2 ;;
    --section)      WANT_SECTIONS="${2:?--section needs ids}"; shift 2 ;;
    --skip-section) SKIP_SECTIONS="${2:?--skip-section needs ids}"; shift 2 ;;
    --format)       FORMAT="${2:?--format text|json|both}"; shift 2 ;;
    --list-rules)
      # Every rule this script can actually evaluate. Printed here rather than
      # described in a document - but printing a hand-written list from inside
      # the script only stops it drifting from a DOCUMENT, not from the code:
      # a rule can be advertised and unimplemented, or fire without appearing
      # here. SKIP rules are the worst class to lose - a rule that says "could
      # not be answered" is the one a reader most needs catalogued. Suite case
      # RP11 asserts this list and the ids used in the code below are the same
      # set, in both directions, so the claim is enforced.
      cat <<'RULES'
VER-00 SKIP   the version watch is not installed here - nothing is watching for a release
VER-01 FYI    a version above the pin is published
VER-04 ALERT  the version watch could not tell (repository unreachable, or no pin)
VER-05 ALERT  no versionlock entry for the package - the version gate is off
VER-06 ALERT  installed, approved-version and the policy floor do not agree
POL-01 ALERT  deployed fleet policy differs from the repository copy
POL-02 ALERT  deployed admin policy differs from the repository copy
POL-03 ALERT  a deployed hook, operator script or statusline differs from its repository copy
POL-05 ALERT  uncommitted changes under settings/ or hooks/ - a half-done deploy
POL-04 FYI    uncommitted changes elsewhere in the checkout
POL-06 SKIP   privileged session or no checkout - the comparison was not made
POL-07 SKIP   git could not read the checkout, so uncommitted changes were not checked
HLT-01 ALERT  health check: policy missing, invalid, or wrongly owned
HLT-03 ALERT  health check: a hook or the statusline is missing or writable
HLT-06 ALERT  health check audited one account or fewer - a broken denominator
HLT-07 FYI    other health-check findings, listed
HLT-08 ALERT  the health check could not run (exit 3) - no answer about this host
INS-01 ALERT  a private install is below the policy floor (notify-first duty)
INS-02 ALERT  a home the sweep could not see - an incomplete answer, not a clean one
PRB-01 ALERT  a probe that used to pass now FAILS
PRB-02 ALERT  a probe that used to pass can no longer be answered
PRB-00 SKIP   the previous report was taken from a different session type, so probe verdicts are not comparable
PRB-03 FYI    a probe that was failing or skipped now passes
CI-01  ALERT  cc-ci-check.sh fails - a red main is stop-the-line
CI-04  SKIP   no checkout, or root with no CC_REPO_RUNAS - CI and the checkout's git state were not checked
LOG-02 ALERT  a denial mentions a control-plane boundary (sudo, the policy tree, shadow, keys)
LOG-07 ALERT  a file in an evidence log directory is not a regular file owned by the user it is named for
LOG-05 FYI    no denials in the window (printed with the headless caveat - an empty log is not proof)
LOG-06 SKIP   the evidence logs could not be read as this user - run the report as root
CAP-03 ALERT  the log filesystem is 85% full or more
CAP-06 ALERT  the logrotate config is missing, will not parse, or names no evidence log
RUN-01 ALERT  the previous report is more than 9 days old - a run was missed
RUN-04 FYI    a collector was skipped (always listed in section 11)
RULES
      exit 0 ;;
    --list-sections)
      printf '%s\n' "sum alerts ver pol hlt prb log repo cap est dlt run"
      exit 0 ;;
    -h|--help) sed -n '2,50p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "cc-report.sh: unknown argument '$1' (try --help)" >&2; exit 2 ;;
  esac
done
case "$KEEP" in ''|*[!0-9]*) echo "cc-report.sh: --keep wants a number" >&2; exit 2 ;; esac
case "$FORMAT" in text|json|both) ;; *) echo "cc-report.sh: --format wants text, json or both" >&2; exit 2 ;; esac

PARTIAL=0
[ -n "$WANT_SECTIONS" ] || [ -n "$SKIP_SECTIONS" ] && PARTIAL=1
want_section() {
  case ",$SKIP_SECTIONS," in *",$1,"*) return 1 ;; esac
  [ -z "$WANT_SECTIONS" ] && return 0
  case ",$WANT_SECTIONS," in *",$1,"*) return 0 ;; *) return 1 ;; esac
}

WORK=$(mktemp -d 2>/dev/null) || { echo "cc-report.sh: no writable temp dir" >&2; exit 3; }
trap 'rm -rf "$WORK"' EXIT
NOW="${CC_NOW:-$(date -Is)}"
STAMP=$(date -d "$NOW" +%Y%m%d-%H%M%S 2>/dev/null || date +%Y%m%d-%H%M%S)
HOST=$(hostname -f 2>/dev/null || hostname)
AS_USER=$(id -un)

# --- the condition ledger -----------------------------------------------------
# One line per condition: level<TAB>rule<TAB>text. Everything else - the verdict,
# the exit code, the delta - is derived from this file, so there is exactly one
# place a condition can be recorded and no way for the summary to disagree with
# the body.
LEDGER="$WORK/ledger.tsv"; : > "$LEDGER"
cond() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$LEDGER"; }
alert() { cond ALERT "$1" "$2"; }
fyi()   { cond FYI   "$1" "$2"; }
skipc() { cond SKIP  "$1" "$2"; }

# --- the run inventory --------------------------------------------------------
# Section 11, and the reason this script can be trusted: a check that did not run
# must never wear the same green as a check that ran and found nothing.
RUNLOG="$WORK/run.tsv"; : > "$RUNLOG"
runrec() { printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" >> "$RUNLOG"; }

# collect <name> <outfile> <command...> - run a collector, time it, record it.
collect() {
  local name="$1" outf="$2"; shift 2
  local t0 t1 rc
  if ! command -v "$1" >/dev/null 2>&1 && [ ! -x "$1" ]; then
    runrec "$name" skipped - - "not present at $1"
    return 127
  fi
  t0=$(date +%s)
  "$@" > "$outf" 2>&1; rc=$?
  t1=$(date +%s)
  # 126 = found but not executable, 127 = not found. Neither is a run, and
  # recording them as "ran, exit 126" is the same lie as a green verdict over a
  # denominator of one. The operator scripts are 0750 root:root, so this is
  # exactly what an unprivileged run of this report hits.
  if [ "$rc" -eq 126 ] || [ "$rc" -eq 127 ]; then
    runrec "$name" skipped - "$((t1 - t0))s" "could not execute as $AS_USER (exit $rc) - the operator scripts are 0750 root:root; run the report as root"
    return $rc
  fi
  runrec "$name" ran "$rc" "$((t1 - t0))s" "$AS_USER"
  return $rc
}

# ---------------------------------------------------------------- privileged ns
# One of five copies of this predicate (cc-install.sh gate 1b, cc-healthcheck [2],
# cc-bump-audit A3/A7 and cc-audit.sh are the others; docs/REPO-MAP.md carries
# the coupling).
# Inside a claude-admin session the fleet policy path is the bind-mounted ADMIN
# policy, so every deployed-vs-repo comparison below would report drift that does
# not exist.
ADMIN_NS=0
if [ -r "$CC_MOUNTINFO" ] && awk -v t="$CC_ETC/managed-settings.json" \
     '$5 == t {found=1} END {exit !found}' "$CC_MOUNTINFO"; then
  ADMIN_NS=1
fi

# ================================================================ collectors
VER_OUT="$WORK/ver.txt";  : > "$VER_OUT"
HLT_OUT="$WORK/hlt.txt";  : > "$HLT_OUT"
PRB_OUT="$WORK/prb.txt";  : > "$PRB_OUT"
CI_OUT="$WORK/ci.txt";    : > "$CI_OUT"

# --- version state
if want_section ver; then
  collect "cc-version-watch.sh" "$VER_OUT" "$CC_SBIN/cc-version-watch.sh" --quiet
  VER_RC=$?
  VER_LINE=$(grep -m1 '^cc-version-watch:' "$VER_OUT" 2>/dev/null || true)
  VER_STATUS=$(printf '%s' "$VER_LINE" | sed -n 's/.*status=\([^ ]*\).*/\1/p')
  VER_PIN=$(printf '%s' "$VER_LINE" | sed -n 's/.*[^_]pin=\([^ ]*\).*/\1/p')
  VER_HEAD=$(printf '%s' "$VER_LINE" | sed -n 's/.*repo_head=\([^ ]*\).*/\1/p')
  # NOT INSTALLED and COULD NOT TELL are different answers and must not share a
  # rule id: the first is an incomplete deployment, the second is a control that
  # ran and failed to reach the vendor.
  if [ "$VER_RC" -eq 127 ] || [ -z "$VER_LINE" ]; then
    skipc VER-00 "the version watch is not installed on this host ($CC_SBIN/cc-version-watch.sh) - run cc-install.sh --apply. Nothing is watching for a new release here"
  else
    case "$VER_STATUS" in
      behind)  fyi   VER-01 "a version above the pin is published: repository head ${VER_HEAD:-?} > pin ${VER_PIN:-?}" ;;
      current) : ;;
      *)       alert VER-04 "the version watch ran and could not tell whether we are behind (status=${VER_STATUS:-none}) - a repository that did not answer must never read as 'we are current'" ;;
    esac
  fi
  # The version gate itself: no versionlock entry means a routine dnf upgrade
  # moves Claude Code with nobody watching.
  if command -v "${CC_DNF_BIN:-dnf}" >/dev/null 2>&1; then
    if ! "${CC_DNF_BIN:-dnf}" -q versionlock list 2>/dev/null | grep -qF "$CC_PKG"; then
      alert VER-05 "no versionlock entry for $CC_PKG - the version gate is off"
    fi
  fi
else
  runrec "cc-version-watch.sh" skipped - - "section ver not selected"
fi

# --- health check. CC_REPORT points at the workdir so the DAILY log is not
# double-appended by a weekly run reading it.
if want_section hlt; then
  collect "cc-healthcheck.sh" "$HLT_OUT" env CC_REPORT="$WORK/hc.log" "$CC_SBIN/cc-healthcheck.sh"
  HLT_RC=$?
  # Exit 3 is the health check's "no answer": a green-looking ledger built from
  # no data is the failure this report exists to prevent.
  [ "$HLT_RC" -eq 3 ] && alert HLT-08 "the health check could not run (exit 3): $(grep -m1 'cc-healthcheck' "$HLT_OUT" 2>/dev/null || echo 'no reason given')"
  HLT_FLAGS=$(grep -c '^  \*\* ' "$HLT_OUT" 2>/dev/null || echo 0)
  HLT_ACCT=$(sed -n 's/.*Audited \([0-9]*\) account.*/\1/p' "$HLT_OUT" 2>/dev/null | head -1)
  while IFS= read -r f; do
    case "$f" in
      *"is missing - the host is running with no IT policy"*|*"Invalid JSON"*|*"Owner is"*|*"writable beyond root"*)
        alert HLT-01 "health check: $f" ;;
      *issing*|*"not executable"*|*"must be root-owned"*|*UNAUDITED*|*"writable by"*)
        # A hook the policy names but that is absent, non-executable or
        # group-writable means calls proceed with no evidence and only a
        # transcript warning. Silent loss of the audit trail is the failure this
        # deployment exists to prevent, so it is never an FYI.
        alert HLT-03 "health check: $f" ;;
      *) fyi HLT-07 "health check: $f" ;;
    esac
  done < <(sed -n 's/^  \*\* //p' "$HLT_OUT" 2>/dev/null)
  if [ -n "$HLT_ACCT" ] && [ "$HLT_ACCT" -le 1 ]; then
    alert HLT-06 "the health check examined only $HLT_ACCT account(s) - a green verdict over a broken denominator is the failure this rule exists to catch"
  fi
else
  runrec "cc-healthcheck.sh" skipped - - "section hlt not selected"
fi

# --- probes
if want_section prb; then
  collect "cc-bump-audit.sh" "$PRB_OUT" env CC_REPO_OPTIONAL=1 CC_REPO="$CC_REPO" "$CC_SBIN/cc-bump-audit.sh"
  PRB_RC=$?
  # One verdict per probe id, for the delta comparison.
  : > "$WORK/probes.tsv"
  while IFS= read -r line; do
    verb=$(printf '%s' "$line" | awk '{print $1}')
    id=$(printf '%s' "$line" | awk '{print $2}')
    case "$id" in A[0-9]|A[0-9][0-9]|M[0-9]|M[0-9][0-9]) printf '%s\t%s\n' "$id" "$verb" >> "$WORK/probes.tsv" ;; esac
  done < <(sed -n 's/^  \(ok\|FAIL\|note\|skip\) *\([A-Z][0-9]*\) .*/\1 \2/p' "$PRB_OUT" 2>/dev/null)
  # VER-06. cc-bump-audit's section [A] - pin coherence: the floor, the
  # UPGRADES entry and approved-version - prints FAILs with NO probe id, so the
  # parser above drops every one of them. Without reading PRB_RC, a half-done
  # bump (the floor moved with the policy apply, approved-version did not, or
  # the reverse) would be invisible to the report that advertises VER-06 for
  # exactly that condition.
  #
  # It is read as a STANDING condition, not a delta: a half-done bump FAILs
  # identically every week, so PRB-01 - which fires on a pass-to-FAIL
  # transition - stays quiet forever once the first report has it in baseline.
  # That is the same trap as a probe regression, in the one place the bump
  # procedure calls work.
  while IFS= read -r cl; do
    case "$cl" in
      [A-Z][0-9]" "*|[A-Z][0-9][0-9]" "*) continue ;;  # a probe FAIL: PRB-0x owns it
    esac
    alert VER-06 "version/pin coherence: $cl"
  done < <(sed -n 's/^  FAIL    //p' "$PRB_OUT" 2>/dev/null)
  # A5's answer is the notify-first duty, so it is read explicitly rather than
  # inferred from the probe's verb.
  BELOW=$(sed -n 's/.*private install(s) found, \([0-9]*\) below the floor.*/\1/p' "$PRB_OUT" | head -1)
  OPAQUE=$(sed -n 's/.*, \([0-9]*\) home(s) not visible.*/\1/p' "$PRB_OUT" | head -1)
  if [ -n "$BELOW" ] && [ "$BELOW" -gt 0 ]; then
    alert INS-01 "$BELOW private install(s) are below the policy floor and will refuse to start - the affected colleagues must be told (OPERATIONS 3.4). Names: probe A5, run as root"
  fi
  if [ -n "$OPAQUE" ] && [ "$OPAQUE" -gt 0 ]; then
    alert INS-02 "$OPAQUE home(s) were not visible to this sweep - an incomplete answer, not a clean one. Run the report as root"
  fi
else
  runrec "cc-bump-audit.sh" skipped - - "section prb not selected"
fi

# --- repository and CI. Everything here reads or RUNS the shared checkout,
# which the group can write: its scripts, and its .git/config, where
# core.fsmonitor or a hook names a command git itself will run. Root executing
# anything from a group-writable share is a privilege escalation,
# so as root every command goes through runuser to CC_REPO_RUNAS - and with no
# usable account the section does not run at all (fail closed, and say so).
# Commands run from inside the checkout: the unit's cwd is /, and
# cc-ci-check.sh finds its tree with git rev-parse.
if want_section repo; then
  if [ -d "$CC_REPO/.git" ]; then
    REPO_AS=(); REPO_WHO="$AS_USER"; REPO_OK=1
    if [ "$(id -u)" -eq 0 ]; then
      if [ -n "${CC_REPO_RUNAS:-}" ] && [ "$CC_REPO_RUNAS" != root ] \
         && [ "$(id -u "$CC_REPO_RUNAS" 2>/dev/null)" != 0 ] && id -u "$CC_REPO_RUNAS" >/dev/null 2>&1 \
         && command -v runuser >/dev/null 2>&1; then
        REPO_AS=(runuser -u "$CC_REPO_RUNAS" --); REPO_WHO="$CC_REPO_RUNAS"
      else
        REPO_OK=0
      fi
    fi
    if [ "$REPO_OK" -eq 0 ]; then
      runrec "cc-ci-check.sh" skipped - - "running as root, and CC_REPO_RUNAS names no usable non-root account"
      skipc CI-04 "the report runs as root and CC_REPO_RUNAS ('${CC_REPO_RUNAS:-}') names no usable non-root account, so CI and the checkout's git state were not checked - root never runs the group-writable checkout. Set CC_REPO_RUNAS in config.sh"
    else
      collect "cc-ci-check.sh" "$CI_OUT" "${REPO_AS[@]}" bash -c 'cd "$1" && exec bash bin/cc-ci-check.sh' _ "$CC_REPO"
      CI_RC=$?
      [ "$CI_RC" -ne 0 ] && alert CI-01 "cc-ci-check.sh exits $CI_RC - a red main is stop-the-line (CLAUDE.md)"
      # A git that cannot read the tree prints nothing, which is exactly what a
      # clean tree prints - so the exit status decides, not the output.
      if DIRTY=$("${REPO_AS[@]}" git -C "$CC_REPO" status --porcelain 2>/dev/null); then
        if [ -n "$DIRTY" ]; then
          if printf '%s' "$DIRTY" | grep -qE '(settings|hooks)/'; then
            alert POL-05 "the checkout has uncommitted changes under settings/ or hooks/ - an unapplied policy change is a half-done deploy"
          else
            fyi POL-04 "the checkout has uncommitted changes ($(printf '%s' "$DIRTY" | wc -l) path(s)), none under settings/ or hooks/"
          fi
        fi
      else
        skipc POL-07 "git could not read the checkout as $REPO_WHO, so uncommitted changes were not checked"
      fi
      GIT_HEAD=$("${REPO_AS[@]}" git -C "$CC_REPO" log -1 --format='%h %s' 2>/dev/null)
    fi
  else
    runrec "cc-ci-check.sh" skipped - - "no checkout at $CC_REPO"
    skipc CI-04 "no checkout at $CC_REPO, so CI and the repository comparison were not run"
  fi
else
  runrec "cc-ci-check.sh" skipped - - "section repo not selected"
fi

# --- policy and artefact drift
if want_section pol; then
  if [ "$ADMIN_NS" -eq 1 ]; then
    skipc POL-06 "this is a privileged session: $CC_ETC/managed-settings.json is the bind-mounted ADMIN policy, so no deployed-vs-repository comparison was made. Re-run from a plain root shell"
    runrec "policy drift" skipped - - "privileged session (bind mount)"
  elif [ ! -d "$CC_REPO/settings" ]; then
    skipc POL-06 "no checkout at $CC_REPO, so deployed files could not be compared against their source"
    runrec "policy drift" skipped - - "no checkout"
  else
    runrec "policy drift" ran 0 0s "$AS_USER"
    sha() { [ -r "$1" ] && sha256sum "$1" 2>/dev/null | awk '{print $1}'; }
    A=$(sha "$CC_ETC/managed-settings.json"); B=$(sha "$CC_REPO/settings/managed-settings.json")
    if [ -n "$A" ] && [ -n "$B" ] && [ "$A" != "$B" ]; then
      alert POL-01 "the deployed fleet policy differs from the repository copy - either an apply is owed or the deployed file was edited by hand"
    fi
    A=$(sha "$CC_ETC_ADMIN/managed-settings.json"); B=$(sha "$CC_REPO/settings/managed-settings-admin.json")
    if [ -n "$A" ] && [ -n "$B" ] && [ "$A" != "$B" ]; then
      alert POL-02 "the deployed ADMIN policy differs from the repository copy"
    fi
    DIFFN=0
    for f in "$CC_REPO"/hooks/*.sh; do
      [ -f "$f" ] || continue
      A=$(sha "$CC_SBIN/$(basename "$f")"); B=$(sha "$f")
      [ -n "$A" ] && [ -n "$B" ] && [ "$A" != "$B" ] && DIFFN=$((DIFFN+1))
    done
    A=$(sha "$CC_SHARE/statusline.sh"); B=$(sha "$CC_REPO/share/statusline.sh")
    [ -n "$A" ] && [ -n "$B" ] && [ "$A" != "$B" ] && DIFFN=$((DIFFN+1))
    [ "$DIFFN" -gt 0 ] && alert POL-03 "$DIFFN deployed artefact(s) differ from their repository copy - cc-install.sh --apply reverts hand edits, so a difference means an apply is owed"
  fi
else
  runrec "policy drift" skipped - - "section pol not selected"
fi

# --- evidence logs. SHAPE ONLY: counts and normalised keys, never a command
# line into the summary.
if want_section log; then
  DEN_DIR="$CC_LOGDIR/denied"; ACT_DIR="$CC_LOGDIR/activity"
  if [ -r "$DEN_DIR" ] && [ -x "$DEN_DIR" ]; then
    runrec "evidence logs" ran 0 0s "$AS_USER"
    # The directories are 1733: ANY user can create <someone>.jsonl in them. A
    # FIFO there would hang this read forever, as root; a symlink would be
    # followed; a file owned by someone else would count as the named user's. Only a
    # regular file owned by the user it is named for is read - anything else is
    # LOG-07, named, and never opened.
    DEN_N=0; ACT_N=0; DEN_USERS=0; BADLOG=(); DEN_OK=()
    logok() { [ -f "$1" ] && [ ! -L "$1" ] && [ "$(stat -c %U "$1" 2>/dev/null)" = "$(basename "$1" .jsonl)" ]; }
    for f in "$DEN_DIR"/*.jsonl "$ACT_DIR"/*.jsonl; do
      [ -e "$f" ] || [ -L "$f" ] || continue
      logok "$f" || BADLOG+=("${f#"$CC_LOGDIR"/}")
    done
    for f in "$DEN_DIR"/*.jsonl; do logok "$f" && [ -r "$f" ] || continue; DEN_OK+=("$f"); DEN_N=$((DEN_N + $(wc -l < "$f"))); DEN_USERS=$((DEN_USERS+1)); done
    for f in "$ACT_DIR"/*.jsonl; do logok "$f" && [ -r "$f" ] || continue; ACT_N=$((ACT_N + $(wc -l < "$f"))); done
    [ "${#BADLOG[@]}" -gt 0 ] && alert LOG-07 "${#BADLOG[@]} file(s) in the evidence log directories are not a regular file owned by the user they are named for - planted or forged, and not read: ${BADLOG[*]}"
    # The boundary rule: a refusal that touched the control plane itself is
    # always an alert, however it was worded, because the wording went opaque at
    # one version move and `detail` is the only field that still triages.
    # PARSE THE JSON, do not pattern-match the raw line. The regex this replaces
    # anchored on "detail":"[^\"]*<token>[^\"]*" and so stopped at the first
    # ESCAPED QUOTE inside the recorded command - making any refusal whose command
    # contained a quote invisible to the count. An alert with a wrong count is worse than no count, because a
    # reader has no reason to doubt it.
    BOUND=$(python3 -c '
import json, re, sys
tok = re.compile(r"sudo |/etc/shadow|/etc/sudoers|" + re.escape(sys.argv[2]) + r"|[.]credentials[.]json"
                 r"|id_rsa|id_ed25519|unshare|nsenter|mount --bind|versionlock")
n = 0
for f in sys.argv[3:]:
    for line in open(f, errors="replace"):
        try:
            d = json.loads(line)
        except Exception:
            continue
        if tok.search(d.get("detail", "") or ""):
            n += 1
print(n)' "$DEN_DIR" "$CC_ETC" "${DEN_OK[@]}" 2>/dev/null || echo 0)
    [ "${BOUND:-0}" -gt 0 ] && alert LOG-02 "$BOUND denial(s) touch a control-plane boundary (sudo, the policy tree, shadow/sudoers, private keys, the versionlock). All were BLOCKED - this is a review item, not an incident"
    [ "${DEN_N:-0}" -eq 0 ] && fyi LOG-05 "no denials recorded in this window. Note the caveat: the PermissionDenied hook does not fire in headless runs (cc-bump-audit.sh probe M5), so an empty log is not proof of no denials"
  else
    runrec "evidence logs" skipped - - "$DEN_DIR is not readable as $AS_USER (1733 by design) - run as root"
    skipc LOG-06 "the evidence logs could not be read as $AS_USER - the directories are 1733 by design. Run the report as root"
    DEN_N=; ACT_N=; DEN_USERS=
  fi
else
  runrec "evidence logs" skipped - - "section log not selected"
fi

# --- capacity
if want_section cap; then
  runrec "capacity" ran 0 0s "$AS_USER"
  LOG_PCT=$(df --output=pcent "$CC_LOGDIR" 2>/dev/null | tail -1 | tr -dc '0-9')
  LOG_SIZE=$(du -sh "$CC_LOGDIR" 2>/dev/null | awk '{print $1}')
  [ -n "${LOG_PCT:-}" ] && [ "$LOG_PCT" -ge 85 ] && alert CAP-03 "the filesystem holding $CC_LOGDIR is ${LOG_PCT}% full"
  if [ -f "$CC_LOGROTATE_FILE" ]; then
    if command -v logrotate >/dev/null 2>&1 && ! logrotate -d "$CC_LOGROTATE_FILE" >/dev/null 2>&1; then
      alert CAP-06 "$CC_LOGROTATE_FILE will not parse - retention has lapsed silently"
    fi
    # PRESENT AND PARSEABLE IS NOT COVERING: a config can rotate the health log
    # and the audit reports and name neither evidence log, so the two
    # directories that hold the audit trail are never rotated at all - while a
    # rule that only tests that the file exists and parses reports fine. Name
    # the stanza that is absent.
    MISSG=""
    for g in activity denied; do
      grep -q "$CC_LOGDIR/$g/\*\.jsonl" "$CC_LOGROTATE_FILE" 2>/dev/null || MISSG="$MISSG $g"
    done
    grep -qF "$CC_LOGDIR/admin.log" "$CC_LOGROTATE_FILE" 2>/dev/null || MISSG="$MISSG admin.log"
    [ -n "$MISSG" ] && alert CAP-06 "$CC_LOGROTATE_FILE has no stanza for:$MISSG - that evidence log is never rotated, and a config that exists and parses does not prove otherwise"
  else
    alert CAP-06 "$CC_LOGROTATE_FILE is missing - the logs are not being rotated"
  fi
else
  runrec "capacity" skipped - - "section cap not selected"
fi

# ================================================================ the delta
# NEW / RESOLVED / UNCHANGED come from the PREVIOUS REPORT'S JSON, not from
# parsing any register: one comparison, one source, no markdown scraping.
STATE="$OUTDIR/state.json"
PREV_TS=""; NEW_N=0; RES_N=0; UNCH_N=0; PREV_IDS=""; PREV_PROBES=""
if [ -r "$STATE" ]; then
  PREV_TS=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("generated_at",""))' "$STATE" 2>/dev/null)
  PREV_IDS=$(python3 -c 'import json,sys;print(" ".join(sorted(json.load(open(sys.argv[1])).get("condition_ids",[]))))' "$STATE" 2>/dev/null)
  PREV_PROBES=$(python3 -c 'import json,sys;d=json.load(open(sys.argv[1])).get("probes",{});print(" ".join(f"{k}={v}" for k,v in sorted(d.items())))' "$STATE" 2>/dev/null)
  PREV_ADMIN_NS=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("admin_ns","unknown"))' "$STATE" 2>/dev/null)
  if [ -n "$PREV_TS" ]; then
    AGE_D=$(( ( $(date -d "$NOW" +%s 2>/dev/null || date +%s) - $(date -d "$PREV_TS" +%s 2>/dev/null || echo 0) ) / 86400 ))
    [ "$AGE_D" -gt 9 ] && alert RUN-01 "the previous report is ${AGE_D} days old - a weekly run was missed, so this delta spans more than a week"
  fi
fi
# A probe whose answer changed is itself work (OPERATIONS 7.1 step 2) - but only
# when the two runs were comparable. A3 and A7 answer "ok" from a plain shell and
# "skip" from a privileged session, by design, so comparing across session types
# raises PRB-02 ("a probe that used to pass can no longer be answered") on every
# alternate run and PRB-03 on the one after. That is a property of who ran it,
# not of the host, and an alert that fires on a schedule teaches people to
# ignore alerts. Compare like with like, and say so when it cannot.
PROBE_DELTA=1
if [ -n "${PREV_ADMIN_NS:-}" ] && [ "${PREV_ADMIN_NS:-unknown}" != unknown ] \
   && [ "$PREV_ADMIN_NS" != "$ADMIN_NS" ]; then
  PROBE_DELTA=0
  skipc PRB-00 "the previous report was taken from a $( [ "$PREV_ADMIN_NS" = 1 ] && echo privileged || echo plain ) session and this one from a $( [ "$ADMIN_NS" = 1 ] && echo privileged || echo plain ) one, so probe verdicts are not comparable - A3 and A7 legitimately differ between the two. Run both from the same kind of session to get a probe delta"
fi
if [ "$PROBE_DELTA" -eq 1 ] && [ -s "$WORK/probes.tsv" ] && [ -n "$PREV_PROBES" ]; then
  while IFS=$'\t' read -r pid verb; do
    for kv in $PREV_PROBES; do
      case "$kv" in
        "$pid="*) old="${kv#*=}"
          if [ "$old" = ok ] && [ "$verb" = FAIL ]; then
            alert PRB-01 "probe $pid was ok and now FAILS - the vendor changed behaviour this deployment depends on"
          elif [ "$old" = ok ] && [ "$verb" = skip ]; then
            alert PRB-02 "probe $pid was ok and can no longer be answered - a lost control, not a neutral event"
          elif { [ "$old" = FAIL ] || [ "$old" = skip ]; } && [ "$verb" = ok ]; then
            fyi PRB-03 "probe $pid now passes (was $old)"
          fi ;;
      esac
    done
  done < "$WORK/probes.tsv"
fi

# Every skipped collector is an FYI, always, so silence is never free.
while IFS=$'\t' read -r name status rc secs why; do
  [ "$status" = skipped ] && fyi RUN-04 "collector '$name' did not run: $why"
done < "$RUNLOG"

# The readability of this report is a condition like any other, so it is decided
# HERE - before the delta and the verdict read the ledger. Only the chmod is left
# further down, where OUTDIR exists. Deciding it after the count is what made
# FYI_N disagree with the list printed underneath it.
if [ -z "$GROUP" ]; then
  # Empty CC_REPO_GROUP is a documented choice (config.example.sh §4), not a fault.
  FILE_MODE=0600; GROUP_NOTE="CC_REPO_GROUP is empty, so reports are root-only by configuration"
elif getent group "$GROUP" >/dev/null 2>&1; then
  FILE_MODE=0640; GROUP_NOTE=""
else
  FILE_MODE=0600
  GROUP_NOTE="group $GROUP does not resolve on this host, so reports are root-only here and an agent session cannot read them"
  fyi RUN-04 "$GROUP_NOTE"
fi

# THE DELTA IS SNAPSHOTTED HERE, after the last condition is written - and that
# placement is the whole correctness argument. PRB-0x and the per-collector
# RUN-04 rows are appended above; a snapshot taken before them would miss them as
# NEW, and then, once they were in the baseline, report them RESOLVED for ever
# after - while condition_ids, built from the final ledger, still listed them. A
# probe regression could then never appear as NEW, which is the one thing
# OPERATIONS 7.1 step 2 calls work.
CUR_IDS=$(cut -f2 "$LEDGER" | sort -u | tr '\n' ' ')
for id in $CUR_IDS; do
  case " $PREV_IDS " in *" $id "*) UNCH_N=$((UNCH_N+1)) ;; *) NEW_N=$((NEW_N+1)) ;; esac
done
for id in $PREV_IDS; do
  case " $CUR_IDS " in *" $id "*) ;; *) RES_N=$((RES_N+1)) ;; esac
done

# ================================================================ the verdict
ALERT_N=$(awk -F'\t' '$1=="ALERT"' "$LEDGER" | wc -l | tr -d ' ')
FYI_N=$(awk -F'\t' '$1=="FYI"' "$LEDGER" | wc -l | tr -d ' ')
SKIP_N=$(awk -F'\t' '$1=="SKIP"' "$LEDGER" | wc -l | tr -d ' ')
HOLD_IDS=$(awk -F'\t' '$1=="ALERT"' "$LEDGER" | cut -f2 \
            | grep -E '^(POL-0[1235]|PRB-0[12]|CI-01|VER-0[456]|INS-01)$' | sort -u | tr '\n' ' ')
if [ -n "$HOLD_IDS" ]; then BUMP_VERDICT="hold — ${HOLD_IDS% }"; else BUMP_VERDICT="ok to plan"; fi
if [ "$ALERT_N" -eq 0 ]; then
  MGMT_VERDICT="no major errors flagged"
else
  MGMT_VERDICT="$ALERT_N alert(s) need a named owner before this is reportable"
fi
RC=0; [ "$ALERT_N" -gt 0 ] && RC=1

# ================================================================ output
if [ "$DRY" -eq 1 ]; then OUTDIR="$WORK/dryrun"; fi
mkdir -p "$OUTDIR" 2>/dev/null || { echo "cc-report.sh: cannot create $OUTDIR" >&2; exit 3; }
# Group-readable so an agent session (and IT) can read the report without sudo;
# world cannot even list the directory. If the group does not resolve - a group
# local to one host does not resolve on the others - fall back to root-only and SAY
# SO. Never widen to world.
if [ -z "$GROUP_NOTE" ]; then
  chgrp "$GROUP" "$OUTDIR" 2>/dev/null; chmod 2750 "$OUTDIR" 2>/dev/null
else
  chmod 0700 "$OUTDIR" 2>/dev/null
fi

MD="$OUTDIR/report-$STAMP.md"
JS="$OUTDIR/report-$STAMP.json"

{
  printf '# Claude Code estate report — %s\n' "$HOST"
  printf 'Generated : %s  by cc-report.sh (as %s)\n' "$NOW" "$AS_USER"
  printf 'Window    : since %s\n' "${PREV_TS:-<no previous report - this is the first>}"
  printf 'Scope     : this host only. Estate coverage is stated in internal/CURRENT-STATE.md, section "Fleet coverage"\n'
  [ "$PARTIAL" -eq 1 ] && printf 'PARTIAL   : section selection was used - this is not a full pass, and latest.* was not updated\n'
  printf 'Verdict   : %s — %s alert, %s fyi, %s skip\n' "$( [ "$RC" -eq 0 ] && echo OK || echo ALERT )" "$ALERT_N" "$FYI_N" "$SKIP_N"
  printf 'BUMP: %s\n' "$BUMP_VERDICT"
  printf 'REPORT TO MANAGEMENT: %s\n' "$MGMT_VERDICT"
  printf '\n## 0. Summary for management\n'
  # The sandbox clause is read from the deployed policy: exit 0 enabled, 1
  # disabled, anything else (no file, not JSON, key absent or not a boolean)
  # is "not read" - never one of the two answers.
  python3 -c 'import json,sys
try:
    v = json.load(open(sys.argv[1]))["sandbox"]["enabled"]
except (OSError, ValueError, KeyError, TypeError):
    sys.exit(2)   # an uncaught error would exit 1, which is the answer "disabled"
sys.exit(0 if v is True else 1 if v is False else 2)' "$CC_ETC/managed-settings.json" 2>/dev/null
  case $? in
    0) SANDBOX_SAYS="sandbox enabled" ;;
    1) SANDBOX_SAYS="sandbox disabled by decision (docs/SANDBOX-DECISION.md)" ;;
    *) SANDBOX_SAYS="sandbox state not read ($CC_ETC/managed-settings.json does not give sandbox.enabled)" ;;
  esac
  printf 'Posture      : version %s, floor %s; %s. %s\n' \
    "${VER_HEAD:-unknown}" "${VER_PIN:-unknown}" "$SANDBOX_SAYS" \
    "$(grep -m1 -oE 'Coverage: [0-9]+ of [0-9]+' "$CC_REPO/internal/CURRENT-STATE.md" 2>/dev/null || echo 'not stated in the register')"
  printf 'Exposure     : %s alert(s), %s new since the last report. Registers: internal/CURRENT-STATE.md section "Open findings", internal/LIMITATIONS-AND-RISKS.md — cited, never restated here\n' "$ALERT_N" "$NEW_N"
  printf 'What changed : %s new, %s resolved, %s unchanged. HEAD %s\n' "$NEW_N" "$RES_N" "$UNCH_N" "${GIT_HEAD:-unknown}"
  printf 'What is owed : every ALERT below, each of which needs a named owner\n'
  printf '\n## 1. ALERTS\n'
  if [ "$ALERT_N" -eq 0 ]; then printf 'none\n'; else
    awk -F'\t' '$1=="ALERT"{printf "[ALERT] %-7s %s\n", $2, $3}' "$LEDGER"
  fi
  printf '\n### 1b. FYI and SKIP\n'
  awk -F'\t' '$1!="ALERT"{printf "[%-5s] %-7s %s\n", $1, $2, $3}' "$LEDGER"
  printf '\n## 2. Version and package state\n%s\n' "${VER_LINE:-not collected}"
  printf '\n## 4. Health check\n'
  grep -E '^RESULT:|^  \*\* ' "$HLT_OUT" 2>/dev/null || printf 'not collected\n'
  printf '\n## 5. Probes\n'
  grep -E '^  (ok|FAIL|note|skip) ' "$PRB_OUT" 2>/dev/null | sed -n '1,40p' || printf 'not collected\n'
  printf '\n## 6. Evidence logs\n'
  printf 'activity lines: %s | denial lines: %s | denial files: %s\n' "${ACT_N:-unread}" "${DEN_N:-unread}" "${DEN_USERS:-unread}"
  printf '\n## 7. Repository and CI\n'
  printf 'cc-ci-check: %s | HEAD: %s\n' "${CI_RC:-not run}" "${GIT_HEAD:-unknown}"
  printf '\n## 8. Capacity\n'
  printf '%s: %s%% full, %s in use\n' "$CC_LOGDIR" "${LOG_PCT:-?}" "${LOG_SIZE:-?}"
  printf '\n## 10. Delta\n'
  printf 'NEW %s | RESOLVED %s | UNCHANGED %s | previous report: %s\n' "$NEW_N" "$RES_N" "$UNCH_N" "${PREV_TS:-none}"
  printf '\n## 11. Run inventory — what ran, and what did not\n'
  awk -F'\t' '{printf "%-24s %-8s exit=%-4s %-6s %s\n", $1, $2, $3, $4, $5}' "$RUNLOG"
} > "$MD"

# The JSON is built from VALUES: every scalar crosses as an environment variable
# and the program text is a quoted heredoc. Splicing shell text into the Python
# source would let a collector line carrying a quote or a backslash break the
# program.
if ! R_NOW="$NOW" R_HOST="$HOST" R_AS_USER="$AS_USER" R_PARTIAL="$PARTIAL" R_RC="$RC" \
     R_BUMP="$BUMP_VERDICT" R_MGMT="$MGMT_VERDICT" \
     R_ALERT="$ALERT_N" R_FYI="$FYI_N" R_SKIP="$SKIP_N" R_NEW="$NEW_N" R_RES="$RES_N" R_UNCH="$UNCH_N" \
     R_VER_LINE="${VER_LINE:-}" R_VER_PIN="${VER_PIN:-}" R_VER_HEAD="${VER_HEAD:-}" \
     R_PREV_TS="${PREV_TS:-}" R_ADMIN_NS="$ADMIN_NS" \
     python3 - "$JS" "$LEDGER" "$RUNLOG" "$WORK/probes.tsv" <<'PY'
import json, os, sys
js, ledger, runlog, probes = sys.argv[1:5]
e = os.environ
def rows(p, n):
    out = []
    try:
        for line in open(p):
            f = line.rstrip("\n").split("\t")
            if len(f) >= n: out.append(f)
    except FileNotFoundError:
        pass
    return out
conds = [{"level": l, "rule": r, "text": t} for l, r, t in rows(ledger, 3)]
runs  = [{"collector": a, "status": b, "exit": c, "seconds": d, "note": n} for a, b, c, d, n in rows(runlog, 5)]
prb   = {a: b for a, b in rows(probes, 2)}
doc = {
  "schema": "cc-report/1",
  "generated_at": e["R_NOW"],
  "host": e["R_HOST"],
  "as_user": e["R_AS_USER"],
  "partial": e["R_PARTIAL"] == "1",
  "exit_code": int(e["R_RC"]),
  "verdict": {"bump": e["R_BUMP"], "management": e["R_MGMT"]},
  "counts": {k: int(e["R_" + v]) for k, v in (("alert", "ALERT"), ("fyi", "FYI"), ("skip", "SKIP"),
             ("new", "NEW"), ("resolved", "RES"), ("unchanged", "UNCH"))},
  "version": {"line": e["R_VER_LINE"], "pin": e["R_VER_PIN"], "repo_head": e["R_VER_HEAD"]},
  "conditions": conds,
  "condition_ids": sorted({c["rule"] for c in conds}),
  "probes": prb,
  "run": runs,
  "previous_report": e["R_PREV_TS"],
  "admin_ns": int(e["R_ADMIN_NS"]),
}
with open(js, "w") as f:
    json.dump(doc, f, indent=2)
PY
then
  # Exit 3 is "no report written": the markdown alone is not a report a reader
  # can key on, and latest.* keeps the last good pair.
  echo "cc-report.sh: could not write the JSON report $JS - nothing was published" >&2
  rm -f "$MD" 2>/dev/null; [ -f "$JS" ] && rm -f "$JS" 2>/dev/null
  exit 3
fi

chmod "$FILE_MODE" "$MD" "$JS" 2>/dev/null
[ -n "${GROUP:-}" ] && getent group "$GROUP" >/dev/null 2>&1 && chgrp "$GROUP" "$MD" "$JS" 2>/dev/null

# latest.* and state.json are the contract a reader keys on - so a PARTIAL run
# must not move them, exactly as CC_CI_ONLY never claims a full pass.
if [ "$PARTIAL" -eq 0 ] && [ "$DRY" -eq 0 ]; then
  cp -f "$MD" "$OUTDIR/latest.md" 2>/dev/null
  cp -f "$JS" "$OUTDIR/latest.json" 2>/dev/null
  cp -f "$JS" "$STATE" 2>/dev/null
  chmod "$FILE_MODE" "$OUTDIR/latest.md" "$OUTDIR/latest.json" "$STATE" 2>/dev/null
  # Prune AFTER writing, never before: a failed run must not delete history.
  # Strict pattern only, so a stray file is never removed, and latest.*/state.json
  # cannot match it by construction.
  ls -1t "$OUTDIR"/report-????????-??????.md 2>/dev/null | tail -n +$((KEEP + 1)) | while read -r old; do
    rm -f "$old" "${old%.md}.json"
  done
fi

case "$FORMAT" in
  json) cat "$JS" ;;
  text) cat "$MD" ;;
  both) cat "$MD"; printf '\nJSON: %s\n' "$JS" ;;
esac
[ "$DRY" -eq 1 ] && printf '\nDRY RUN - written to %s and discarded; latest.* and state.json untouched\n' "$OUTDIR"

exit "$RC"
