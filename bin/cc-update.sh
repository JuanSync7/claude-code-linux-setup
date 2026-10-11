#!/usr/bin/env bash
# cc-update.sh - gated upgrade of the IT-managed Claude Code package.
#
# Nothing here happens automatically. The package install does not self-update,
# so this script is the only path from one approved version to the next:
#
#   cc-update.sh sessions              # who would block an apply, and why. Changes nothing
#   cc-update.sh check                 # report installed vs available, change nothing
#   cc-update.sh stage <version>       # download the RPM for offline review
#   cc-update.sh apply <version>       # unlock, upgrade to <version>, re-lock, record
#   cc-update.sh rollback <version>    # downgrade to a previously approved version
#                          [--force]   # ... even below the policy floor (see below)
#
# THE ROLLBACK ORDER IS NOT SYMMETRIC WITH THE UPGRADE ORDER. An upgrade moves
# the package, then the policy floor. A rollback must move the POLICY FIRST: the
# floor (requiredMinimumVersion) refuses to start any binary below it, so
# downgrading the package under a floor that still names the new version bricks
# every session on the host. This script refuses that order rather than
# discovering it afterwards; --force is for the operator who has already lowered
# the floor, or who accepts the consequence knowingly.
#
# WHO IS RUNNING THE MANAGED BINARY is answered from /proc, not from a process
# NAME. `pgrep -x claude` matches the name and nothing else, which is wrong in
# both directions: it misses a session started under any other
# argv[0], and it counts a private install of a DIFFERENT
# binary under the same name, which an RPM transaction cannot disturb. The fact that matters is
# which processes have THIS file open as their executable, so that is what is
# tested. Reading /proc/<pid>/exe for another user's process needs root, and an
# unprivileged run says so rather than reporting a clean host.
#
# Site values (CC_PKG, CC_ETC, CC_UPDATE_STAGE_DIR, CC_LOGDIR, CC_CLAUDE_BIN)
# come from config.sh through the loader; an exported CC_* wins for one run.
# Test seams, OS defaults: CC_DNF_BIN, CC_RPM_BIN, CC_PROC, CC_LOG, and
# CC_ALLOW_NONROOT=1 which
# lifts the root check for the suite (dnf itself still needs root, so this
# weakens nothing on a real host). Exercised by suite cases R1-R8 and UD1-UD8.

set -uo pipefail

# --- site configuration: config.sh through the loader --------------------------
for _cfg in "${CC_CONFIG_LIB:-}" /etc/claude-code/cc-config.sh \
            "$(dirname "$(readlink -f "$0")")/../lib/cc-config.sh"; do
  [ -n "$_cfg" ] && [ -r "$_cfg" ] && { . "$_cfg" || exit 1; _cfg_loaded=1; break; }
done
[ "${_cfg_loaded:-0}" = 1 ] || { echo "cc-update.sh: cannot find cc-config.sh (looked in /etc/claude-code/ and ../lib/)" >&2; exit 1; }
unset _cfg _cfg_loaded

PKG="$CC_PKG"
STATE_DIR="$CC_ETC"
APPROVED_FILE="${STATE_DIR}/approved-version"
POLICY_FILE="${STATE_DIR}/managed-settings.json"
STAGE_DIR="$CC_UPDATE_STAGE_DIR"
LOG="${CC_LOG:-$CC_LOGDIR/update.log}"

DNF="${CC_DNF_BIN:-dnf}"
RPM="${CC_RPM_BIN:-rpm}"
# A PATH NAME IS NOT A PATH. `readlink -f` resolves the bare word "claude"
# against the CURRENT DIRECTORY - so a session sweep given it would compare
# every /proc/<pid>/exe against ./claude, match nothing, and report a clear
# host while sessions are running. Use the managed path from config,
# the same one cc-healthcheck.sh and cc-bump-audit.sh use, and resolve a bare
# name through PATH if one is passed.
CLAUDE="$CC_CLAUDE_BIN"
case "$CLAUDE" in
  */*) : ;;
  *)   CLAUDE="$(command -v "$CLAUDE" 2>/dev/null || printf '%s' "$CLAUDE")" ;;
esac
CC_PROC="${CC_PROC:-/proc}"

# The log is best-effort until prepare_write has made its directory: the
# read-only subcommands (sessions, check) create nothing on the host, and a
# missing log directory must not turn a report into a failure.
log() { printf '%s  %s\n' "$(date -Is)" "$1" | tee -a "$LOG" 2>/dev/null; }
die() { log "ERROR: $1"; exit 1; }

# Only the subcommands that change the host create its state and log directories.
prepare_write() {
  mkdir -p "$(dirname "$LOG")" "$STATE_DIR" || die "cannot create $(dirname "$LOG") or $STATE_DIR"
}

# A version is digits separated by dots, and nothing else reaches dnf: an
# argument such as "2.1.0 --nogpgcheck" would otherwise pass through word-for-word.
need_version() {
  case "$2" in
    ""|.*|*.|*..*|*[!0-9.]*)
      log "ERROR: usage: cc-update.sh $1 <version>   (digits and dots, e.g. 2.1.0; got '${2}')"
      exit 2 ;;
  esac
}

[ "$(id -u)" -eq 0 ] || [ "${CC_ALLOW_NONROOT:-0}" = "1" ] || die "must run as root"

# versionlock is what actually stops a routine 'dnf upgrade' from moving Claude Code.
ensure_versionlock() {
  if ! "$DNF" versionlock --help >/dev/null 2>&1; then
    log "installing python3-dnf-plugin-versionlock"
    "$DNF" -y install python3-dnf-plugin-versionlock >>"$LOG" 2>&1 \
      || die "could not install the versionlock plugin"
  fi
}

# installed_version - the version this host would run, or EMPTY for "cannot tell".
# `rpm -q --qf` prints "package claude-code is not installed" on STDOUT with exit
# 1, so 2>/dev/null does not suppress it. Without the shape check that sentence
# becomes the "version" and reaches the rollback path, which would then try
# `versionlock add claude-code-package claude-code is not installed`.
installed_version() {
  local v=""
  if v=$("$RPM" -q --qf '%{VERSION}' "$PKG" 2>/dev/null); then
    case "$v" in ""|*[!0-9.]*) v="" ;; esac
  else
    v=""
  fi
  printf '%s' "$v"
}

# The floor the DEPLOYED policy enforces. Three answers, kept apart:
#   prints the floor, returns 0   - the policy names one
#   prints nothing,  returns 0    - no policy file, or a policy with no floor
#   returns 1                     - a policy is there and its floor cannot be read
# The third is kept apart from the second so that a policy that will not parse
# cannot let rollback skip its guard silently. Callers refuse on it unless forced.
policy_floor() {
  [ -e "$POLICY_FILE" ] || return 0
  python3 -c '
import json, re, sys
v = json.load(open(sys.argv[1])).get("requiredMinimumVersion")
if v is None:
    sys.exit(0)
if not isinstance(v, str) or not re.fullmatch(r"[0-9]+(\.[0-9]+)*", v):
    sys.exit(1)
print(v)' "$POLICY_FILE" 2>/dev/null
}

# record_approved - written only once the binary has been seen to run, and
# atomically: approved-version is what the health check and the report compare
# the host against, so it must never name a version that did not start.
record_approved() {
  printf '%s\n' "$1" > "$APPROVED_FILE.new" && mv -f "$APPROVED_FILE.new" "$APPROVED_FILE" \
    || die "${PKG} ${1} is installed and runs, but $APPROVED_FILE could not be written"
  log "recorded approved version ${1}"
}

# relock - a package left unlocked moves with the next routine 'dnf upgrade',
# with nobody watching. That is a failed change, not a warning.
relock() {
  "$DNF" versionlock add "${PKG}-${1}" >>"$LOG" 2>&1 && return 0
  log "ERROR: ${PKG} is NOT locked - the next 'dnf upgrade' will move it. Lock it by hand now:"
  log "    dnf versionlock add ${PKG}-${1}"
  return 1
}

# True when $1 is strictly below $2, by rpm/dnf version ordering.
version_below() { [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)" = "$1" ] && [ "$1" != "$2" ]; }

# sessions_on_managed_binary - one line per process whose executable IS the
# managed binary: "<pid> <user> <tty> <elapsed> <kind>". Empty output means a
# clear host, and a non-zero return means at least one session is in the way.
# "kind" separates an ordinary session from a claude-admin one, because the
# admin session is invisible in a terminal tab list - it is a runuser child of
# cc-admin-session.sh - and an operator hunting for "the session that is
# blocking me" needs to be told that, not left to find it.
sessions_on_managed_binary() {
  local target found=1 pid exe ppid pcmd kind
  target=$(readlink -f "$CLAUDE" 2>/dev/null || printf '%s' "$CLAUDE")
  for d in "$CC_PROC"/[0-9]*; do
    [ -e "$d/exe" ] || continue
    exe=$(readlink -f "$d/exe" 2>/dev/null) || continue
    [ "$exe" = "$target" ] || continue
    pid=${d##*/}
    ppid=$(awk '/^PPid:/{print $2}' "$d/status" 2>/dev/null)
    pcmd=$(tr '\0' ' ' < "$CC_PROC/${ppid:-0}/cmdline" 2>/dev/null)
    case "$pcmd" in
      *runuser*) kind="claude-admin session (started by cc-admin-session.sh, not a plain tab)" ;;
      *)         kind="session" ;;
    esac
    printf '%s %s %s %s %s\n' "$pid" \
      "$(ps -o user= -p "$pid" 2>/dev/null | tr -d ' ')" \
      "$(ps -o tty=  -p "$pid" 2>/dev/null | tr -d ' ')" \
      "$(ps -o etime= -p "$pid" 2>/dev/null | tr -d ' ')" "$kind"
    found=0
  done
  return $found
}

# Who breaks if the binary changes underneath them. apply REFUSES on this;
# rollback only reports it, because a rollback is an emergency and waiting for
# an idle host can be the worse outcome.
report_live_sessions() {
  local out
  out=$(sessions_on_managed_binary) || return 1
  log "WARNING: these sessions are running the managed binary and will break at the swap:"
  printf '%s\n' "$out" | while read -r line; do log "  $line"; done
  return 0
}

cmd_check() {
  local inst avail approved
  inst=$(installed_version)
  approved=$( [ -f "$APPROVED_FILE" ] && tr -d '[:space:]' < "$APPROVED_FILE" || echo "none recorded" )
  log "installed: ${inst:-not installed}"
  log "approved:  ${approved}"
  # --refresh so we do not report a stale cache as 'up to date'. Capture dnf's own
  # status separately: a failed query must NOT be reported as 'nothing available',
  # or an operator reads a broken repo as 'we are current'.
  local dnf_out dnf_rc
  dnf_out=$("$DNF" -q --refresh list available "$PKG" 2>&1); dnf_rc=$?
  # dnf exits 1 when a query simply matches nothing, so treat that as 'none'
  # and anything else as a genuine failure.
  if [ "$dnf_rc" -ne 0 ] && ! printf '%s' "$dnf_out" | grep -qi 'no matching\|no packages'; then
    log "available: QUERY FAILED (dnf exit ${dnf_rc}) - repository unreachable or misconfigured"
    log "dnf said: $(printf '%s' "$dnf_out" | head -3 | tr '\n' ' ')"
    log "ACTION: fix the repository before assuming the installed version is current"
    return 1
  fi
  # ARCH FILTER, and it is not cosmetic. `dnf list available claude-code` on an
  # x86_64 host also lists the aarch64 build of the SAME version, because that
  # package is not installed here. Taking `tail -1` of the rows then reports
  # the installed version as "available" while the host sits exactly at it - a standing
  # false "raise a change request". Compare like with like: this arch only, and
  # by version ordering rather than by "the output was non-empty".
  local arch; arch=$(uname -m)
  avail=$(printf '%s' "$dnf_out" \
            | awk -v a="$arch" -v p="$PKG" '$1 == (p "." a) {print $2}' \
            | sed 's/-[0-9]*$//' | sort -V | tail -1)
  if [ -n "$avail" ] && [ -n "$inst" ] && ! version_below "$inst" "$avail"; then
    log "available: nothing newer than the installed ${inst} for ${arch}"
    avail=""
  fi
  if [ -z "$avail" ]; then
    log "available: none newer than installed"
  else
    log "available: ${avail}"
    log "ACTION: raise a change request before running 'cc-update.sh apply'"
  fi
  log "current versionlock entries:"
  "$DNF" versionlock list 2>/dev/null | grep -i claude | tee -a "$LOG" || log "  (none)"
}

cmd_stage() {
  local ver="$1"
  mkdir -p "$STAGE_DIR"
  log "downloading ${PKG}-${ver} to ${STAGE_DIR} for review"
  # download-only keeps the RPM on disk so it can be scanned and signed off
  # before it ever touches the running system.
  # --arch, or dnf fetches EVERY architecture the repository carries: staging
  # would pull the aarch64 build onto an x86_64 host, which then sits in the
  # signature-check step as a file nobody will ever install.
  local arch; arch=$(uname -m)
  "$DNF" -y download --arch "$arch" --destdir "$STAGE_DIR" "${PKG}-${ver}" >>"$LOG" 2>&1 \
    || "$DNF" -y install --downloadonly --downloaddir "$STAGE_DIR" "${PKG}-${ver}.${arch}" >>"$LOG" 2>&1 \
    || die "could not download ${PKG}-${ver} for ${arch}"
  log "staged files:"
  # shellcheck disable=SC2012  # human-readable listing for the change record, not parsed
  ls -l "$STAGE_DIR" | tee -a "$LOG"
  log "verify the signature before approving:"
  log "  rpm -Kv ${STAGE_DIR}/${PKG}-${ver}*.rpm"
}

cmd_apply() {
  local ver="$1" prev floor
  need_version apply "$ver"
  prev=$(installed_version)

  # Every refusal comes before the first change, the versionlock plugin included:
  # a refused apply leaves the host exactly as it found it.
  # apply moves forward only. A lower version is a rollback, and rollback is the
  # path that carries the policy-floor guard and its instructions.
  if [ -n "$prev" ] && version_below "$ver" "$prev"; then
    die "${ver} is below the installed ${prev}; apply only moves forward - use: cc-update.sh rollback ${ver}"
  fi
  if ! floor=$(policy_floor); then
    die "cannot read the floor (requiredMinimumVersion) in $POLICY_FILE - fix the deployed policy first"
  fi
  if [ -n "$floor" ] && version_below "$ver" "$floor"; then
    die "${ver} is below the deployed policy floor ${floor}; the host would refuse to start it"
  fi

  # Refuse to swap the binary out from under a running session on a shared host.
  # Same question one step earlier, and the reason `cc-update.sh sessions` exists.
  if report_live_sessions; then
    log "  Exit each one (or 'kill <pid>'), then re-run. A claude-admin session is"
    log "  the easy one to miss: it does not look like a claude tab from the outside."
    log "  Private installs such as claude-local run a DIFFERENT binary and are not listed."
    die "sessions are running; schedule this in a maintenance window or ask users to exit"
  fi
  [ "$(id -u)" -eq 0 ] || log "NOTE: not root - only your own processes were visible in $CC_PROC"

  ensure_versionlock
  log "upgrading ${PKG} ${prev:-none} -> ${ver}"
  "$DNF" versionlock delete "$PKG" >>"$LOG" 2>&1 || true
  if ! "$DNF" -y install "${PKG}-${ver}" >>"$LOG" 2>&1; then
    if [ -n "$prev" ]; then
      log "upgrade failed; restoring lock on ${prev}"
      relock "$prev" || true
    else
      log "upgrade failed; nothing was installed before, so there is no lock to restore"
    fi
    die "dnf install ${PKG}-${ver} failed - see $LOG"
  fi
  relock "$ver" || die "${PKG} ${ver} is installed but NOT locked (and not smoke-tested)"

  # Smoke test before recording or declaring success.
  if "$CLAUDE" --version >>"$LOG" 2>&1; then
    log "smoke test: claude --version OK -> $("$CLAUDE" --version 2>/dev/null)"
  else
    die "binary does not run after upgrade - roll back with: cc-update.sh rollback ${prev:-<previous version>}"
  fi
  record_approved "$ver"
  if "$CLAUDE" doctor >>"$LOG" 2>&1; then
    log "claude doctor completed"
  else
    log "WARN: claude doctor reported issues, see $LOG"
  fi
  log "DONE. Announce the new version to users."
}

cmd_rollback() {
  local ver="$1" force="${2:-}" prev floor
  need_version rollback "$ver"
  [ -z "$force" ] || [ "$force" = "--force" ] || die "usage: cc-update.sh rollback <version> [--force]"

  # THE GUARD. requiredMinimumVersion refuses to start any binary below it, so
  # a package rolled back under a floor that still names the new version takes
  # the whole host down - and the operator running this is already having a bad
  # day. Refuse, and name the order that works.
  if ! floor=$(policy_floor); then
    if [ "$force" = "--force" ]; then
      log "WARNING: --force: the floor in $POLICY_FILE cannot be read; rolling back without the guard."
      floor=""
    else
      log "ERROR: cannot read the floor (requiredMinimumVersion) in $POLICY_FILE"
      log "  Without it this script cannot tell whether ${ver} would be refused at start."
      log "  Fix the deployed policy (bin/cc-install.sh --apply), or accept the risk:"
      log "    cc-update.sh rollback ${ver} --force"
      exit 1
    fi
  fi
  if [ -n "$floor" ] && version_below "$ver" "$floor"; then
    if [ "$force" = "--force" ]; then
      log "WARNING: --force: rolling back to ${ver}, BELOW the policy floor ${floor}."
      log "  Every session on this host will refuse to start until the floor is lowered."
    else
      log "ERROR: ${ver} is below the deployed policy floor ${floor}"
      log "  requiredMinimumVersion refuses to start a binary below the floor, so this"
      log "  order would leave the host unable to run claude at all."
      log "  Roll the POLICY back first, then the package:"
      log "    1. edit requiredMinimumVersion to ${ver} in settings/managed-settings.json"
      log "    2. bin/cc-install.sh --apply   (from a plain root shell, announce first)"
      log "    3. cc-update.sh rollback ${ver}"
      log "  Or, if you accept a host that cannot start claude until step 2 lands:"
      log "    cc-update.sh rollback ${ver} --force"
      exit 1
    fi
  fi

  ensure_versionlock
  prev=$(installed_version)
  log "rolling back ${prev:-unknown} -> ${ver}"
  report_live_sessions || true   # emergency path: report, do not block (apply blocks)

  "$DNF" versionlock delete "$PKG" >>"$LOG" 2>&1 || true
  if ! "$DNF" -y downgrade "${PKG}-${ver}" >>"$LOG" 2>&1 \
    && ! "$DNF" -y install "${PKG}-${ver}" >>"$LOG" 2>&1; then
    # Never leave an emergency half-done with the package UNLOCKED: the next
    # routine 'dnf upgrade' would move Claude Code with nobody watching.
    log "rollback failed; restoring the lock on ${prev:-$ver}"
    relock "${prev:-$ver}" || true
    die "rollback to ${ver} failed - see $LOG"
  fi
  relock "$ver" || die "${PKG} ${ver} is installed but NOT locked (and not smoke-tested)"
  log "rolled back and re-locked at ${ver}"

  # Same smoke test apply has: a rollback that leaves a dead binary is worse
  # than the state it was rolling back from, and it must not exit 0.
  if "$CLAUDE" --version >>"$LOG" 2>&1; then
    log "smoke test: claude --version OK -> $("$CLAUDE" --version 2>/dev/null)"
  else
    die "binary does not run after rollback to ${ver} - the host has no working claude"
  fi
  record_approved "$ver"
  log "DONE. If the policy floor still names a newer version, lower it and re-apply."
}

# One change at a time: cc-install.sh --apply holds the same lock, and a policy
# floor moving while the package moves is how a host ends up refusing to start.
take_lock() {
  exec 9>>"$CC_CONTROL_LOCK" || die "cannot open the lock $CC_CONTROL_LOCK"
  flock -n 9 || die "another install or update is running (it holds $CC_CONTROL_LOCK) - wait for it, then re-run"
}

case "${1:-}" in
  sessions) if report_live_sessions; then
              log "-> apply would REFUSE. Exit these first."; exit 1
            else
              log "no session is running the managed binary$([ "$(id -u)" -eq 0 ] || printf '%s' " (visible to $(id -un); run as root for every user)")"
            fi ;;
  check)    cmd_check ;;
  stage)    need_version stage "${2:-}"; prepare_write; cmd_stage "${2:-}" ;;
  apply)    prepare_write; take_lock; cmd_apply "${2:-}" ;;
  rollback) prepare_write; take_lock; cmd_rollback "${2:-}" "${3:-}" ;;
  *) cat <<'USAGE'
Usage:
  cc-update.sh sessions           Who is running the managed binary right now, and
                                  therefore what would block an apply. Read-only.
  cc-update.sh check              Report installed / approved / available versions.
  cc-update.sh stage <version>    Download the RPM for offline review and signature check.
  cc-update.sh apply <version>    Upgrade to <version>, re-apply versionlock, smoke test.
  cc-update.sh rollback <version> [--force]
                                  Return to a previously approved version. Refused when
                                  <version> is below the deployed policy floor unless
                                  --force: the floor would stop the host starting claude.
USAGE
     exit 2 ;;
esac
