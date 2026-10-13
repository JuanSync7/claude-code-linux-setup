#!/usr/bin/env bash
# cc-healthcheck.sh - recurring health and drift check for a shared Claude Code host.
# Intended to run daily from a systemd timer as root. Writes a report and exits
# non-zero when something needs IT attention, so the timer surfaces a failed unit.
#
# THREE THINGS THIS CHECK DOES NOT ASSUME. Each would turn the report into a
# false "healthy" on a host whose accounts come from a directory service and
# whose homes are on a separate filesystem:
#
#   1. USER ENUMERATION is not read from /etc/passwd alone. On a host whose
#      accounts come from LDAP/sss, /etc/passwd may hold no interactive account
#      at all, and a check that iterates it examines nobody's credentials. The
#      real home directories under CC_HOME_ROOT are enumerated and each owner is
#      resolved with stat, cross-checked against getent. `getent passwd` with no
#      argument is deliberately NOT the primary source either - sssd enumeration
#      is frequently disabled, so it can return nothing for directory users.
#      The size of the population examined is always reported ("Audited N
#      account(s)") so a wrong denominator is visible instead of hiding behind
#      a green verdict.
#   2. THE SIDE-INSTALL SCAN walks the same enumerated homes, and looks for both
#      the launcher and the install TREE: a home can hold the tree with no
#      launcher on PATH, so a scan testing only ~/.local/bin/claude
#      under-reports. The count is not restated here - it moves with the floor
#      and with each private upgrade; cc-bump-audit.sh probe A5 is the live
#      answer.
#   3. THE DISK TARGET is the filesystem that actually contains the homes.
#      /home may be a directory of symlinks on the root filesystem, so checking
#      /home would watch the wrong filesystem for the usage alarm.
#
# EXIT CODES. 0 healthy; 1 ran, and at least one item needs attention; 2 usage
# error; 3 COULD NOT RUN - no config, or the report cannot be written. 3 is
# kept apart from 1 because "the host is unhealthy" and "this check produced
# no answer" need different responses.

set -uo pipefail

# --- site configuration: config.sh through the loader --------------------------
# Every path and site value comes from config.sh; nothing is spelled here. The
# installed loader is tried first, the checkout's when run from one. A config
# that is missing or incomplete is a failed health check, not a guess.
for _cfg in "${CC_CONFIG_LIB:-}" /etc/claude-code/cc-config.sh \
            "$(dirname "$(readlink -f "$0")")/../lib/cc-config.sh"; do
  [ -n "$_cfg" ] && [ -r "$_cfg" ] && { . "$_cfg" || exit 3; _cfg_loaded=1; break; }
done
[ "${_cfg_loaded:-0}" = 1 ] || { echo "cc-healthcheck.sh: cannot find cc-config.sh (looked in /etc/claude-code/ and ../lib/)" >&2; exit 3; }
unset _cfg _cfg_loaded

# Test seams: OS facts, not site values. The suite fabricates each.
CC_PASSWD="${CC_PASSWD:-/etc/passwd}"
# The endpoints [5] must reach for install, login and inference.
CC_REACH_URLS="${CC_REACH_URLS:-https://api.anthropic.com https://platform.claude.com https://claude.ai https://downloads.claude.ai}"

# --metrics <path> additionally renders this run as a Prometheus textfile.
# Rendering rather than a second source: every number below is already computed
# here, so a separate metrics script would be free to disagree with the log.
METRICS_OUT="${CC_METRICS:-$CC_METRICS_FILE}"
while [ $# -gt 0 ]; do
  case "$1" in
    --metrics) METRICS_OUT="${2:?--metrics needs a path}"; shift 2 ;;
    -h|--help) sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "cc-healthcheck.sh: unknown argument '$1' (try --help)" >&2; exit 2 ;;
  esac
done

REPORT="${CC_REPORT:-$CC_LOGDIR/healthcheck.log}"
MANAGED="${CC_ETC}/managed-settings.json"
BASELINE="${CC_ETC}/managed-settings.json.sha256"
APPROVED_FILE="${CC_ETC}/approved-version"
ISSUES=0

if ! mkdir -p "$(dirname "$REPORT")" 2>/dev/null || ! : >> "$REPORT" 2>/dev/null; then
  echo "cc-healthcheck.sh: cannot write the report $REPORT - no check was run" >&2
  exit 3
fi
exec > >(tee -a "$REPORT") 2>&1

echo "=============================================================="
echo "Claude Code health check - $(date -Is) - $(hostname -f 2>/dev/null || hostname)"
echo "=============================================================="

note() { printf '  %s\n' "$1"; }
flag() { printf '  ** %s\n' "$1"; ISSUES=$((ISSUES+1)); }

# --- 0. Build the account list ONCE, from the filesystem ----------------------
# One line per account: "<user>:<home>". Written to a file and read line by line so
# a home directory containing a space cannot be torn into two "accounts".
USER_LIST="${WORKTMP:-${TMPDIR:-/tmp}}/cc-users.$$"
trap 'rm -f "$USER_LIST"' EXIT
: > "$USER_LIST"

# CC_HOME_ROOT is a site fact (config.sh): /etc/passwd holds only local
# accounts on a directory-backed host, so the homes cannot be found from it.
# A wrong value must FAIL here, not quietly audit nobody - a missing root, or
# one holding no directory a real account owns, is flagged after the scan.
if [ ! -d "$CC_HOME_ROOT" ]; then
  flag "Home root $CC_HOME_ROOT (CC_HOME_ROOT in $CC_CONFIG_SOURCE) does not exist - no engineer's credentials or side installs can be checked"
else
  # Primary source: real homes under CC_HOME_ROOT, owner resolved by stat.
  for home in "$CC_HOME_ROOT"/*; do
    [ -d "$home" ] || continue
    owner=$(stat -c '%U' "$home" 2>/dev/null)
    # stat prints UNKNOWN when the owning uid has no account - a stranded home.
    if [ -z "$owner" ] || [ "$owner" = "UNKNOWN" ]; then
      flag "Stranded home with no resolvable owner: $home (uid $(stat -c '%u' "$home" 2>/dev/null)) - check the leaver process"
      continue
    fi
    printf '%s:%s\n' "$owner" "$home" >> "$USER_LIST"
  done
fi

# Secondary source: local interactive accounts from /etc/passwd whose homes live
# outside CC_HOME_ROOT (e.g. service accounts on local disk). Appended, deduplicated.
awk -F: '$3>=1000 && $3<65534 && $7 !~ /nologin|false/ {print $1":"$6}' "$CC_PASSWD" 2>/dev/null \
  | while IFS= read -r entry; do
      h="${entry#*:}"
      case "$h" in "$CC_HOME_ROOT"/*) continue ;; esac
      printf '%s\n' "$entry"
    done >> "$USER_LIST"

if [ -d "$CC_HOME_ROOT" ] && ! grep -qF ":$CC_HOME_ROOT/" "$USER_LIST"; then
  flag "Home root $CC_HOME_ROOT (CC_HOME_ROOT in $CC_CONFIG_SOURCE) holds no home owned by a real account - wrong value for this host?"
fi
sort -u -o "$USER_LIST" "$USER_LIST"
USER_COUNT=$(wc -l < "$USER_LIST" | tr -d ' ')

# --- 1. Binary present and at the version IT expects -------------------------
echo "[1] Installed version"
if ! command -v claude >/dev/null 2>&1; then
  flag "claude not on PATH for root; check the package install"
else
  INSTALLED=$(claude --version 2>/dev/null | awk '{print $1}')
  note "claude --version -> ${INSTALLED:-unknown}"
  if rpm -q "$CC_PKG" >/dev/null 2>&1; then
    note "RPM: $(rpm -q "$CC_PKG")"
  else
    flag "$CC_PKG RPM not installed - binary may be an unmanaged side install"
  fi
  # The package being installed is not the same as the package being what RUNS.
  RESOLVED=$(command -v claude 2>/dev/null)
  note "resolves to: ${RESOLVED:-not found}"
  if [ -n "$RESOLVED" ]; then
    # Resolve symlinks before asking rpm, or /bin/claude (a symlink into /usr/bin)
    # can report as unowned and produce a spurious finding.
    REAL=$(readlink -f "$RESOLVED" 2>/dev/null || echo "$RESOLVED")
    [ "$REAL" != "$RESOLVED" ] && note "real path: $REAL"
    if OWNER_PKG=$(rpm -qf "$REAL" 2>/dev/null); then
      note "owned by package: $OWNER_PKG"
      case "$OWNER_PKG" in
        claude-code-*) : ;;
        *) flag "binary on PATH belongs to $OWNER_PKG, not $CC_PKG" ;;
      esac
    else
      flag "binary on PATH ($REAL) is owned by NO package - it shadows the managed RPM"
    fi
  fi
  if [ -f "$APPROVED_FILE" ]; then
    APPROVED=$(tr -d '[:space:]' < "$APPROVED_FILE")
    if [ "$INSTALLED" != "$APPROVED" ]; then
      flag "Version drift: installed ${INSTALLED}, approved ${APPROVED}"
    else
      note "Matches approved version ${APPROVED}"
    fi
  else
    # Without the record there is nothing to compare against, so drift cannot
    # be seen: that is a finding, not a section to skip.
    flag "No approved-version recorded at $APPROVED_FILE - version drift cannot be checked (cc-update.sh apply or make pin writes it)"
  fi
fi

# --- 2. Managed settings integrity -------------------------------------------
echo "[2] Managed settings"
if [ ! -f "$MANAGED" ]; then
  flag "$MANAGED is missing - the host is running with no IT policy"
else
  if python3 -c "import json;json.load(open('$MANAGED'))" 2>/dev/null; then
    note "Valid JSON"
  else
    flag "Invalid JSON - Claude Code strips unparseable entries and policy may not apply"
  fi
  PERM=$(stat -c '%a' "$MANAGED")
  OWNER=$(stat -c '%U:%G' "$MANAGED")
  [ "$OWNER" = "root:root" ] || flag "Owner is $OWNER, expected root:root"
  case "$PERM" in
    644|444) note "Mode $PERM" ;;
    *)       flag "Mode $PERM is writable beyond root; expected 644" ;;
  esac
  # Inside a cc-admin-session.sh mount namespace $MANAGED is the bind-mounted
  # ADMIN policy, so comparing it against the FLEET baseline reports drift that
  # does not exist. Same predicate as cc-install.sh gate 1b and cc-bump-audit
  # probe A3; CC_MOUNTINFO is a test seam (the kernel mount table cannot be
  # fabricated unprivileged). docs/REPO-MAP.md carries the coupling.
  CC_MOUNTINFO="${CC_MOUNTINFO:-/proc/self/mountinfo}"
  if [ -r "$CC_MOUNTINFO" ] && awk -v t="$MANAGED" '$5 == t {found=1} END {exit !found}' "$CC_MOUNTINFO"; then
    note "Privileged session: $MANAGED is bind-mounted from the admin policy, so"
    note "  the fleet baseline is not comparable here - re-run from a plain session"
  elif [ -f "$BASELINE" ]; then
    want=$(awk 'NR==1{print $1}' "$BASELINE")
    have=$(sha256sum "$MANAGED" | awk '{print $1}')
    if [ -z "$want" ]; then
      flag "Baseline file $BASELINE contains no checksum - re-record it"
    elif [ "$want" = "$have" ]; then
      note "Checksum matches the deployed baseline"
    else
      flag "Managed settings changed since deployment - investigate before accepting"
      note "  baseline: $want"
      note "  current : $have"
    fi
  else
    note "No baseline checksum recorded (create with: sha256sum $MANAGED > $BASELINE)"
  fi
  # The sandbox is only as good as its dependencies. Warn while the
  # policy enables it but a dependency is absent - fail-open means this is silent.
  if python3 -c "
import json,sys
d=json.load(open('$MANAGED'))
s=d.get('sandbox') or {}
sys.exit(0 if s.get('enabled') else 1)" 2>/dev/null; then
    for dep in bwrap socat; do
      command -v "$dep" >/dev/null 2>&1 || flag "sandbox is ENABLED in policy but $dep is missing - enforcement is degraded"
    done
  fi
fi

# The artefacts the policy and the IDE defaults name.
# A hook that is missing or not executable is a SILENT failure - calls proceed
# unaudited with only a transcript warning - so presence is checked here, daily.
echo
echo "[2b] Hooks, status line and IDE wrapper"
# Per-artefact result, kept for the metrics rendering: "<basename> <1|0>".
MANAGED_FILE_OK=""
for f in "$CC_SBIN/cc-audit-hook.sh" "$CC_SBIN/cc-secret-guard-hook.sh" \
         "$CC_SBIN/cc-denied-hook.sh" "$CC_SBIN/cc-upgrade-guard-hook.sh" \
         "$CC_SBIN/cc-redact-hook.sh" \
         "$CC_SHARE/statusline.sh"; do
  if [ ! -f "$f" ]; then
    flag "$(basename "$f") missing at $f - the policy names it; sessions run UNAUDITED"
    MANAGED_FILE_OK="$MANAGED_FILE_OK$(basename "$f") 0
"
  elif [ ! -x "$f" ]; then
    flag "$(basename "$f") not executable - same silent failure as missing"
    MANAGED_FILE_OK="$MANAGED_FILE_OK$(basename "$f") 0
"
  else
    m=$(stat -c '%a' "$f"); o=$(stat -c '%U' "$f")
    [ "$o" = root ] || flag "$(basename "$f") owned by $o, expected root"
    if [ $(( 8#$m & 8#022 )) -ne 0 ]; then
      flag "$(basename "$f") mode $m is writable beyond root - the control is editable by users"
      MANAGED_FILE_OK="$MANAGED_FILE_OK$(basename "$f") 0
"
    else
      note "$(basename "$f") present, root, $m"
      MANAGED_FILE_OK="$MANAGED_FILE_OK$(basename "$f") 1
"
    fi
  fi
done
# The IDE wrapper is a DEFAULT, not a control (IDE-INTEGRATION.md section 8):
# engineers may legitimately override claudeProcessWrapper in their own
# settings, and that is an accepted risk. What must NOT drift is the wrapper
# file itself and the machine-wide seed - those are root's.
WRAPPER="$CC_SHARE/cc-vscode-claude-wrapper.sh"
if [ -f "$WRAPPER" ]; then
  m=$(stat -c '%a' "$WRAPPER"); o=$(stat -c '%U' "$WRAPPER")
  if [ "$o" != root ] || [ $(( 8#$m & 8#022 )) -ne 0 ]; then
    flag "IDE wrapper $WRAPPER is $o/$m - must be root-owned and unwritable by others"
  else
    note "IDE wrapper present, root, $m"
  fi
  IDE_SEED="$CC_SKEL/.config/VSCodium/User/settings.json"
  if [ -f "$IDE_SEED" ] && ! grep -q 'claudeProcessWrapper' "$IDE_SEED" 2>/dev/null; then
    flag "IDE seed $IDE_SEED no longer sets claudeProcessWrapper - new users get the bundled CLI"
  fi
else
  note "IDE wrapper not installed (fine on non-desktop hosts)"
fi

# --- 3. Per-user configuration audit -----------------------------------------
echo
echo "[2c] Browser drop-ins agree"
# BROWSER is what makes the OAuth login work, and it is set by TWO files that
# must stay in step: claude-code-browser.sh for sh/bash and .csh for tcsh, which
# may be the login shell. tcsh does not source *.sh, so a candidate added to one
# and not the other gives some users a working login and the others a
# silent failure - xdg-open resolves to nothing, no window appears, and the exit
# status is still 0. Nothing else compares them, which is why this exists: the
# drop-ins' own comments promise this check by name.
BR_SH="$CC_PROFILED/claude-code-browser.sh"
BR_CSH="$CC_PROFILED/claude-code-browser.csh"
if [ ! -f "$BR_SH" ] && [ ! -f "$BR_CSH" ]; then
  note "no browser drop-ins installed - skipped (they are placed by cc-install.sh --apply)"
elif [ ! -f "$BR_SH" ] || [ ! -f "$BR_CSH" ]; then
  flag "only one browser drop-in is installed - tcsh and sh users will not agree"
  note "  sh:  ${BR_SH}$( [ -f "$BR_SH" ] || printf ' (MISSING)')"
  note "  csh: ${BR_CSH}$( [ -f "$BR_CSH" ] || printf ' (MISSING)')"
else
  BR_A=$(sh -c ". '$BR_SH' >/dev/null 2>&1; printf '%s' \"\$BROWSER\"" 2>/dev/null)
  if command -v tcsh >/dev/null 2>&1; then
    # csh errors on an unset variable, so test $?BROWSER before reading it.
    BR_B=$(tcsh -f -c "source '$BR_CSH' >& /dev/null; if (\$?BROWSER) printf '%s' \"\$BROWSER\"" 2>/dev/null)
    if [ "$BR_A" = "$BR_B" ]; then
      if [ -z "$BR_A" ]; then
        flag "neither drop-in found a browser on this host - OAuth login will fail silently"
        note "  install one, or add it to the candidate list in BOTH drop-ins"
      else
        note "both drop-ins resolve BROWSER to $BR_A"
      fi
    else
      flag "the browser drop-ins disagree: sh gives '${BR_A:-<unset>}', tcsh gives '${BR_B:-<unset>}'"
      note "  the candidate lists in the .sh and .csh siblings must be identical"
    fi
  else
    note "tcsh is not installed; only the sh drop-in could be evaluated (BROWSER=${BR_A:-<unset>})"
  fi
fi

echo "[2d] Admin policy directory"
# The 0700 root mode on $CC_ETC_ADMIN is the whole of what keeps the admin
# policy unbrowsable: the FILE is deliberately 0644, because claude reads it as
# the unprivileged target user through the bind mount (ADMIN-SESSION.md §3). So
# the directory mode is the control. cc-admin-session.sh asserts it at launch
# and refuses, but that surfaces the fault at the moment someone urgently needs
# a privileged session, and only for whoever tried. cc-install.sh asserts it
# after writing the policy; drift from any other cause needs this standing
# check rather than trust.
if [ ! -d "$CC_ETC_ADMIN" ]; then
  note "no admin policy directory on this host - skipped (placed by --with-admin)"
else
  AD_PERMS=$(stat -c '%a %U:%G' "$CC_ETC_ADMIN" 2>/dev/null || echo unknown)
  if [ "$AD_PERMS" = "700 root:root" ]; then
    note "$CC_ETC_ADMIN is 0700 root:root"
  else
    flag "$CC_ETC_ADMIN is '$AD_PERMS', expected '700 root:root'"
    note "  the admin policy is browsable by others and cc-admin-session.sh"
    note "  will refuse to start. Fix: chmod 0700 $CC_ETC_ADMIN"
    note "  and chown root:root $CC_ETC_ADMIN"
  fi
  # The file must stay 0644: tightening it breaks the session rather than
  # securing it, so a wrong mode here is worth naming in either direction.
  if [ -f "$CC_ADMIN_POLICY" ]; then
    AF_PERMS=$(stat -c '%a %U:%G' "$CC_ADMIN_POLICY" 2>/dev/null || echo unknown)
    [ "$AF_PERMS" = "644 root:root" ] ||
      flag "$CC_ADMIN_POLICY is '$AF_PERMS', expected '644 root:root'"
  fi
fi

echo "[3] Per-user state"
while IFS= read -r entry; do
  [ -n "$entry" ] || continue
  u="${entry%%:*}"; h="${entry#*:}"
  [ -d "$h/.claude" ] || continue
  cred="$h/.claude/.credentials.json"
  if [ -f "$cred" ]; then
    mode=$(stat -c '%a' "$cred")
    owner=$(stat -c '%U' "$cred")
    [ "$mode" != "600" ] && flag "$u: credentials mode $mode (expected 600)"
    [ "$owner" != "$u" ] && flag "$u: credentials owned by $owner"
    age_days=$(( ( $(date +%s) - $(stat -c %Y "$cred") ) / 86400 ))
    [ "$age_days" -gt 80 ] && note "$u: credentials last written ${age_days}d ago - login may be near expiry"
  fi
  us="$h/.claude/settings.json"
  if [ -f "$us" ]; then
    python3 -c "import json;json.load(open('$us'))" 2>/dev/null \
      || flag "$u: ~/.claude/settings.json is invalid JSON"
  fi
  # Homes are not assumed to be 0700. Where they are more open, the kernel does
  # not isolate users from each other and the policy's deny rules are the
  # primary control between engineers, not belt-and-braces - so check the modes
  # rather than assume them. On an NFS export that trusts client-asserted
  # identity (sec=sys) a file mode is no boundary against another host either:
  # fixing these modes is necessary but not sufficient. A site records what
  # its exports trust in internal/LIMITATIONS-AND-RISKS.md.
  hmode=$(stat -c '%a' "$h" 2>/dev/null)
  case "$hmode" in
    700|750|710|711) : ;;
    *) note "$u: home mode $hmode is group/world-accessible - kernel isolation between engineers is weaker than the runbook assumes" ;;
  esac
  for secret in .ssh .gnupg .aws; do
    if [ -d "$h/$secret" ]; then
      smode=$(stat -c '%a' "$h/$secret" 2>/dev/null)
      [ "$smode" != "700" ] && flag "$u: $secret is mode $smode (expected 700) - readable by other engineers on this host"
    fi
  done
done < "$USER_LIST"
note "Audited ${USER_COUNT} account(s) from ${CC_HOME_ROOT} + local interactive accounts"
[ "$USER_COUNT" -le 1 ] && flag "Only ${USER_COUNT} account(s) found - enumeration may be broken; verify against 'ls ${CC_HOME_ROOT}'"

# --- 4. Unmanaged side installs ----------------------------------------------
echo "[4] Conflicting installations"
FOUND_SIDE=0
# Counts by state for the metrics rendering. COUNTS ONLY, never identities: a
# metrics file must be world-readable for an exporter to serve it, and who runs
# what is group-only material (RUNBOOK 11.7). That mode requirement is itself
# the test for what may go in the file.
INS_SHADOW=0; INS_TREE=0; INS_PRESERVED=0
while IFS= read -r entry; do
  [ -n "$entry" ] || continue
  h="${entry#*:}"; u="${entry%%:*}"

  # Severity depends on whether it can shadow the managed binary on PATH, so the
  # three cases are reported differently. Lumping them together would raise a daily
  # false positive against a deliberately preserved install, which is how alert
  # fatigue starts.
  #
  #   (a) $HOME/.local/bin/claude exists  -> FLAG. This is the real drift: it
  #       precedes /usr/bin on PATH, so it silently replaces the version-locked RPM
  #       for that user and self-updates outside change control.
  #   (b) no bare `claude`, but an install TREE plus a deliberately renamed
  #       launcher (claude-local) -> NOTE. Cannot shadow `claude`; it is a copy
  #       kept deliberately, for rollback or comparison.
  #   (c) no bare `claude` and no renamed launcher, but a tree is present -> FLAG,
  #       with accurate wording. It cannot shadow `claude` today, but it is ~1 GB of
  #       ungoverned binaries per version, can be run by explicit path, and the
  #       native updater may recreate the symlink and turn it into case (a).
  alt_list=""
  for alt in "$h"/.local/bin/claude-*; do
    [ -e "$alt" ] || continue
    alt_list="${alt_list} $(basename "$alt")->$(basename "$(readlink "$alt" 2>/dev/null)" 2>/dev/null)"
  done

  if [ -e "$h/.local/bin/claude" ]; then
    ver=""
    [ -L "$h/.local/bin/claude" ] && ver=" -> $(basename "$(readlink "$h/.local/bin/claude")" 2>/dev/null)"
    flag "$u: unmanaged native install on PATH at \$HOME/.local/bin/claude${ver} - shadows the managed RPM"
    FOUND_SIDE=1; INS_SHADOW=$((INS_SHADOW+1))
  elif [ -d "$h/.local/share/claude" ]; then
    if [ -n "$alt_list" ]; then
      vers=$(ls -1 "$h/.local/share/claude/versions" 2>/dev/null | tr '\n' ' ')
      note "$u: preserved alternate install${alt_list} (tree holds: ${vers:-none}) - deliberate, does not shadow \`claude\`"
      INS_PRESERVED=$((INS_PRESERVED+1))
    else
      vers=$(ls -1 "$h/.local/share/claude/versions" 2>/dev/null | tr '\n' ' ')
      flag "$u: ungoverned install tree at \$HOME/.local/share/claude (${vers:-unknown}) with no launcher on PATH - not shadowing \`claude\` today, but runnable by path and the native updater may recreate the symlink"
      FOUND_SIDE=1; INS_TREE=$((INS_TREE+1))
    fi
  fi
done < "$USER_LIST"
if [ -e "${CC_NPM_GLOBAL:-/usr/lib/node_modules/@anthropic-ai/claude-code}" ]; then
  flag "Global npm install present alongside the RPM"
  FOUND_SIDE=1
fi
[ "$FOUND_SIDE" -eq 0 ] && note "No side installs found"

# --- 5. Outbound reachability -------------------------------------------------
echo "[5] Connectivity"
# Python, not curl: some endpoint protection products kill curl started from a
# shell as a "malicious file download", which reads a working host as
# unreachable. Any HTTP answer, an error status included, proves the endpoint is
# reachable (proxy variables are honoured).
for url in $CC_REACH_URLS; do
  if python3 - "$url" >/dev/null 2>&1 <<'PY'
import sys, urllib.request, urllib.error
try:
    urllib.request.urlopen(urllib.request.Request(sys.argv[1], method="HEAD"), timeout=10)
except urllib.error.HTTPError:
    pass
PY
  then
    note "${url} reachable"
  else
    flag "${url} unreachable"
  fi
done

# --- 6. Disk ------------------------------------------------------------------
echo "[6] Disk"
# Resolve the filesystem that actually holds the homes, following the symlink farm.
FS_TARGET=$(readlink -f "$CC_HOME_ROOT" 2>/dev/null || echo "$CC_HOME_ROOT")
if [ -d "$FS_TARGET" ]; then
  MOUNT=$(df -P "$FS_TARGET" | awk 'NR==2{print $6}')
  SRC=$(df -PT "$FS_TARGET" | awk 'NR==2{print $1" ("$2")"}')
  USE=$(df -P "$FS_TARGET" | awk 'NR==2{gsub("%","",$5);print $5}')
  note "$FS_TARGET is on $MOUNT from $SRC - ${USE}% used"
  [ "${USE:-0}" -ge 85 ] && flag "$MOUNT above 85% - review cleanupPeriodDays and session retention"
else
  flag "Home filesystem $FS_TARGET does not exist - check CC_HOME_ROOT"
fi
# The audit logs are host-local and are lost on a rebuild unless shipped off-host.
if [ -d "$CC_LOGDIR" ]; then
  LUSE=$(df -P "$CC_LOGDIR" | awk 'NR==2{gsub("%","",$5);print $5}')
  note "$CC_LOGDIR is ${LUSE}% used (host-local; ship off-host to survive a rebuild)"
  [ "${LUSE:-0}" -ge 85 ] && flag "$CC_LOGDIR filesystem above 85%"
fi

# --- 7. Weekly report freshness ----------------------------------------------
# The weekly report has three ways to notice its own absence and needs all
# three, because each fails differently: Persistent=true catches downtime, the
# report's own RUN-01 rule catches a stale predecessor - but only when a run
# happens - and this check catches silence on a DAILY cadence. Six lines here
# make a missed weekly run visible tomorrow instead of next month.
#
# Silently skipped when the reports directory does not exist, so the check stays
# valid on a host where the report is not installed.
echo
echo "[7] Weekly report freshness"
REPORT_STATE="$CC_LOGDIR/reports/state.json"
if [ ! -d "$CC_LOGDIR/reports" ]; then
  note "no reports directory - the weekly report is not installed on this host (skipped)"
elif [ ! -r "$REPORT_STATE" ]; then
  flag "no $REPORT_STATE - the weekly report has never completed a full run here"
else
  R_TS=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("generated_at",""))' "$REPORT_STATE" 2>/dev/null)
  if [ -z "$R_TS" ]; then
    flag "$REPORT_STATE carries no generated_at - the report state is unreadable"
  else
    R_AGE=$(( ( $(date +%s) - $(date -d "$R_TS" +%s 2>/dev/null || echo 0) ) / 86400 ))
    if [ "$R_AGE" -gt 9 ]; then
      flag "the last weekly report is ${R_AGE} days old (${R_TS}) - a run was missed and nothing said so"
    else
      note "last weekly report ${R_AGE} day(s) ago (${R_TS})"
    fi
  fi
fi

# --- 8. Install drift --------------------------------------------------------
# Whether this host still holds what cc-install.sh --apply put there, and the
# checkout what it was applied from. cc-drift.sh answers, and its report is
# kept at CC_DRIFT_REPORT, where the dashboard's check-in reads it. When the
# script cannot be run the last report is removed, so an old "none" is never
# read as today's answer; when it runs and cannot tell, it replaces the report
# with one that says unknown and why.
echo
echo "[8] Install drift"
if [ ! -x "$CC_SBIN/cc-drift.sh" ]; then
  rm -f "$CC_DRIFT_REPORT"
  flag "$CC_SBIN/cc-drift.sh is not installed - drift was not checked (cc-install.sh --apply places it)"
else
  "$CC_SBIN/cc-drift.sh" --out "$CC_DRIFT_REPORT" 2>&1 | sed 's/^/  /'
  DRIFT_RC=${PIPESTATUS[0]}
  case "$DRIFT_RC" in
    0) note "the host is as installed, and the checkout as it was applied from" ;;
    1) flag "the host or the checkout differs from what was installed (listed above; cc-install.sh --check says what an apply would change)" ;;
    3) flag "drift cannot be told (above) - the report at $CC_DRIFT_REPORT says unknown" ;;
    *) rm -f "$CC_DRIFT_REPORT"
       flag "cc-drift.sh failed (exit $DRIFT_RC) - drift was not checked" ;;
  esac
fi

# --- the Prometheus textfile rendering ---------------------------------------
# A RENDERING of this run, not a second source of truth. Written atomically,
# because a half-written file makes node_exporter set node_textfile_scrape_error
# and every dashboard built on it goes amber for a reason nobody can find.
#
# Silently skipped when the parent directory does not exist - which is any host
# with no exporter installed. That is deliberate: the file starts being served
# the day an exporter arrives, at no further cost to this repository.
# docs/REPORTING.md 6 is the contract.
if [ -n "$METRICS_OUT" ]; then
  if [ ! -d "$(dirname "$METRICS_OUT")" ]; then
    note "metrics: $(dirname "$METRICS_OUT") does not exist, nothing written (no exporter on this host)"
  else
    _m_tmp="$METRICS_OUT.$$"
    {
      printf '# HELP claude_code_build_info Installed, approved and floor versions on this host.\n'
      printf '# TYPE claude_code_build_info gauge\n'
      printf 'claude_code_build_info{version="%s",approved="%s"} 1\n' "${INSTALLED:-unknown}" "${APPROVED:-unknown}"
      printf '# HELP claude_code_version_drift 1 if the installed binary differs from approved-version.\n'
      printf '# TYPE claude_code_version_drift gauge\n'
      printf 'claude_code_version_drift %s\n' "$( [ -n "${APPROVED:-}" ] && [ "${INSTALLED:-}" != "${APPROVED:-}" ] && echo 1 || echo 0 )"
      printf '# HELP claude_code_healthcheck_issues Findings from this health check run.\n'
      printf '# TYPE claude_code_healthcheck_issues gauge\n'
      printf 'claude_code_healthcheck_issues %s\n' "$ISSUES"
      printf '# HELP claude_code_healthcheck_accounts_audited Size of the account population examined. THE DENOMINATOR - alert if it drops.\n'
      printf '# TYPE claude_code_healthcheck_accounts_audited gauge\n'
      printf 'claude_code_healthcheck_accounts_audited %s\n' "${USER_COUNT:-0}"
      printf '# HELP claude_code_managed_file_ok 1 if the named managed artefact is present, root-owned and not group/world-writable.\n'
      printf '# TYPE claude_code_managed_file_ok gauge\n'
      printf '%s' "$MANAGED_FILE_OK" | while read -r _f _v; do
        [ -n "$_f" ] && printf 'claude_code_managed_file_ok{file="%s"} %s\n' "$_f" "$_v"
      done
      printf '# HELP claude_code_private_installs Private per-user installs by state. Counts only, never identities.\n'
      printf '# TYPE claude_code_private_installs gauge\n'
      printf 'claude_code_private_installs{state="shadowing"} %s\n' "$INS_SHADOW"
      printf 'claude_code_private_installs{state="tree_only"} %s\n' "$INS_TREE"
      printf 'claude_code_private_installs{state="preserved"} %s\n' "$INS_PRESERVED"
      printf '# HELP claude_code_textfile_timestamp_seconds When this file was written. STALENESS DETECTOR - a textfile collector serves the last file forever if the writer stops, so alert above ~26h.\n'
      printf '# TYPE claude_code_textfile_timestamp_seconds gauge\n'
      printf 'claude_code_textfile_timestamp_seconds %s\n' "$(date +%s)"
    } > "$_m_tmp" 2>/dev/null
    # 0644: node_exporter runs as its own user and must be able to read it. That
    # requirement is the privacy test - anything needing group-only protection
    # cannot be in this file.
    chmod 0644 "$_m_tmp" 2>/dev/null
    if mv -f "$_m_tmp" "$METRICS_OUT" 2>/dev/null; then
      note "metrics: wrote $METRICS_OUT"
    else
      rm -f "$_m_tmp" 2>/dev/null
      flag "metrics: could not write $METRICS_OUT"
    fi
  fi
fi

echo
if [ "$ISSUES" -eq 0 ]; then
  echo "RESULT: healthy"
  exit 0
fi
echo "RESULT: ${ISSUES} item(s) need attention"
exit 1
