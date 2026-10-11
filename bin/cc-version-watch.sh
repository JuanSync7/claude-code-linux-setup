#!/usr/bin/env bash
# cc-version-watch.sh - is there a Claude Code version above our pin?
#
# WHAT IT IS FOR, in one sentence: so that nobody has to remember to look. Once a
# week a root timer asks the vendor's repository whether anything newer than the
# version our policy demands has been published, writes the answer as one JSON
# file and one greppable line, and exits non-zero if the answer is yes.
#
# It installs nothing, downloads no RPM and touches no package. Anyone can run it
# by hand without sudo (the answer is then printed rather than filed).
#
#   cc-version-watch.sh              ask, print, file the JSON if root
#   cc-version-watch.sh --json       machine output only
#   cc-version-watch.sh --no-network skip the vendor HTTP corroboration
#   cc-version-watch.sh --list       what this script reads, and from where
#
# EXIT CODES ARE THE INTERFACE - a timer only sees the status:
#   0  nothing above the pin is published. The quiet, normal case.
#   1  THE FINDING: a version above the pin exists. Non-zero on purpose, so the
#      unit enters a failed state and `systemctl --failed` surfaces it, the same
#      idiom cc-healthcheck.sh uses.
#   2  usage error.
#   3  CANNOT TELL: no pin, unparseable policy, repoquery failed, or repository
#      metadata older than --max-age. Never collapsed into 0 and never into 1.
#      "No denominator, no claim" - a broken repository and a current host must
#      not produce the same output.
#
# WHY IT NEVER CARRIES A VERSION LITERAL. The pin is read at run time, every run,
# from the deployed policy. There is no default and no fallback, and no version
# literal the code could act on (the one in a comment illustrates sort order only): a second copy of the pin is a second source of
# truth, and this script's whole value is telling you when the real one is behind.
# An unreadable pin is exit 3, not an assumption.
#
# WHAT IT DELIBERATELY DOES NOT DO. It does not classify a release as important,
# security-relevant or worth taking - that is model judgment and it belongs to
# the version-bump procedure (docs/OPERATIONS.md Part 7). It does not choose a
# target. It does not open a change request. It reports a number and how it got
# it.
#
# Site values (CC_ETC, CC_PKG, CC_PKG_REPO_ID, CC_RELEASE_CHANNEL_URL,
# CC_WATCH_MAX_AGE_H, CC_LOGDIR) come from config.sh through the loader. Test
# seams, OS defaults: CC_DNF_BIN, CC_RPM_BIN, CC_REPORT, CC_NO_NETWORK,
# CC_REPOMD_GLOBS. Exercised by suite cases W1-W8.

set -uo pipefail

# --- site configuration: config.sh through the loader --------------------------
for _cfg in "${CC_CONFIG_LIB:-}" /etc/claude-code/cc-config.sh \
            "$(dirname "$(readlink -f "$0")")/../lib/cc-config.sh"; do
  [ -n "$_cfg" ] && [ -r "$_cfg" ] && { . "$_cfg" || exit 3; _cfg_loaded=1; break; }
done
[ "${_cfg_loaded:-0}" = 1 ] || { echo "cc-version-watch.sh: cannot find cc-config.sh (looked in /etc/claude-code/ and ../lib/)" >&2; exit 3; }
unset _cfg _cfg_loaded

POLICY="$CC_ETC/managed-settings.json"
APPROVED_FILE="$CC_ETC/approved-version"
DNF="${CC_DNF_BIN:-dnf}"
RPM="${CC_RPM_BIN:-rpm}"
PKG="$CC_PKG"
REPO_ID="$CC_PKG_REPO_ID"
# Space-separated globs. Both the vendor publish stamp and our own cache age are
# read from these files; see the freshness section below.
#
# SCOPED TO THE CACHE THIS RUN ACTUALLY USES, which is decided by euid: dnf as
# root reads /var/cache/dnf, and as anyone else a private /var/tmp/dnf-<user>-*
# tree. Globbing both and taking the best of them mixes two independent answers:
# an unprivileged --cacheonly run could be declared fresh on the strength of the
# root timer's cache while answering repo_head out of a week-old user cache.
if [ "$(id -u)" -eq 0 ]; then
  CC_REPOMD_DEFAULT="/var/cache/dnf/${REPO_ID}-*/repodata/repomd.xml"
else
  CC_REPOMD_DEFAULT="/var/tmp/dnf-$(id -un)-*/${REPO_ID}-*/repodata/repomd.xml"
fi
CC_REPOMD_GLOBS="${CC_REPOMD_GLOBS:-$CC_REPOMD_DEFAULT}"
REPORT="${CC_REPORT:-$CC_LOGDIR/version-watch.json}"
MAX_AGE_H="$CC_WATCH_MAX_AGE_H"
NO_NETWORK="${CC_NO_NETWORK:-0}"
# The vendor's own installer reads this endpoint (claude.ai/install.sh); it is
# documented BY USE, not by documentation, so it is corroboration and never the
# primary source.
CHANNEL_URL="$CC_RELEASE_CHANNEL_URL"

JSON_ONLY=0; QUIET=0; REFRESH=1
while [ $# -gt 0 ]; do
  case "$1" in
    --json)       JSON_ONLY=1; shift ;;
    --quiet)      QUIET=1; shift ;;
    --no-network) NO_NETWORK=1; shift ;;
    --cacheonly)  REFRESH=0; shift ;;
    --refresh)    REFRESH=1; shift ;;
    --max-age)    MAX_AGE_H="${2:-}"; shift 2 || { echo "usage: --max-age <hours>" >&2; exit 2; } ;;
    --list)
      printf 'cc-version-watch reads:\n'
      printf '  pin           %s -> requiredMinimumVersion\n' "$POLICY"
      printf '  repo head     %s repoquery --repo=%s --arch=%s\n' "$DNF" "$REPO_ID" "$(uname -m)"
      printf '  channel head  %s (corroboration only)\n' "$CHANNEL_URL"
      printf '  installed     %s -q %s\n' "$RPM" "$PKG"
      printf '  approved      %s\n' "$APPROVED_FILE"
      printf '  publish stamp <revision> in %s\n' "$CC_REPOMD_GLOBS"
      printf '  writes        %s (root only, overwritten each run)\n' "$REPORT"
      exit 0 ;;
    -h|--help) sed -n '2,43p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "cc-version-watch.sh: unknown argument '$1' (try --help)" >&2; exit 2 ;;
  esac
done
case "$MAX_AGE_H" in ''|*[!0-9]*) echo "cc-version-watch.sh: --max-age wants whole hours" >&2; exit 2 ;; esac

say()  { [ "$JSON_ONLY" -eq 1 ] || [ "$QUIET" -eq 1 ] || printf '%s\n' "$*"; }
ok()   { [ "$JSON_ONLY" -eq 1 ] || [ "$QUIET" -eq 1 ] || printf '  ok      %s\n' "$*"; }
note() { [ "$JSON_ONLY" -eq 1 ] || [ "$QUIET" -eq 1 ] || printf '  note    %s\n' "$*"; }
bad()  { [ "$JSON_ONLY" -eq 1 ] || printf '  FAIL    %s\n' "$*" >&2; }

# A version string we are willing to compare. Anything else is "cannot tell".
numeric() { case "$1" in ''|*[!0-9.]*) return 1 ;; *) return 0 ;; esac; }
# Strictly below, by rpm/dnf ordering - a string compare says 2.1.36 > 2.1.236.
version_below() { [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)" = "$1" ] && [ "$1" != "$2" ]; }

# ---------------------------------------------------------------- the pin
PIN=""
if [ -r "$POLICY" ] && command -v python3 >/dev/null 2>&1; then
  PIN=$(python3 -c '
import json, sys
try:
    print(json.load(open(sys.argv[1])).get("requiredMinimumVersion") or "")
except Exception:
    print("")' "$POLICY" 2>/dev/null)
fi

# ---------------------------------------------------------------- the repo head
# --arch, and it is not cosmetic: `dnf list available` also lists the OTHER
# architecture's build of the same version, because that package is not installed
# here. Taking any row produced a standing false "a newer version is available"
# in cc-update.sh check. Ask for one arch and one number.
#
# --disableplugin=versionlock is REQUIRED. The versionlock is what stops a
# routine `dnf upgrade` moving Claude Code - and it also filters everything above
# the lock out of a query, so a locked host asking "is there anything newer"
# answers "no" forever. That is the exact blindness this script exists to remove.
ARCH=$(uname -m)
REPO_HEAD=""; REPO_SRC="dnf-repoquery"; QERR=""
if [ "$REFRESH" -eq 1 ]; then RFLAG="--refresh"; else RFLAG="--cacheonly"; fi
QERR=$(mktemp 2>/dev/null || printf '/tmp/ccvw.%s' "$$")
REPO_HEAD=$("$DNF" -q $RFLAG --disableplugin=versionlock repoquery \
              --repo="$REPO_ID" --latest-limit=1 --arch="$ARCH" \
              --queryformat '%{version}' "$PKG" 2>"$QERR" | tr -d '[:space:]')
QRC=$?
QERR_TEXT=$(tr '\n' ' ' < "$QERR" 2>/dev/null); rm -f "$QERR"
numeric "$REPO_HEAD" || { REPO_HEAD=""; REPO_SRC="unavailable"; }

# ---------------------------------------------------------------- freshness
# TWO DIFFERENT QUESTIONS, which one number cannot answer:
#
#   (a) when did the VENDOR last publish?   -> published_age_h
#   (b) how old is the copy WE hold?        -> cache_age_h
#
# The mtime of a cached repomd.xml answers (b) at best and (a) never, and it is
# not even stable across cache directories: the transient /var/tmp/dnf-<user>-*
# trees dnf creates and removes per invocation download repomd.xml afresh, so
# their mtime is OUR fetch time, and when such a tree is cleaned up the number
# jumps back to whatever older cache survives. Two runs minutes apart against
# an unchanged repository can therefore report different ages.
#
# (a) is answered exactly by repomd.xml's own <revision>, the unix timestamp the
# vendor stamps when it regenerates the repository. Every copy of a given
# repository state carries the same value, so it does not matter which cache it
# is read from and a transient tree cannot perturb it. Take the MAXIMUM across
# the copies we can see: the newest repository state this host has fetched.
#
# (b) is still the mtime, and is still a MINIMUM across caches - "the freshest
# copy we hold" is the right reading of our own staleness. It is what --max-age
# tests under --cacheonly, and it is used for nothing else.
#
# What --refresh proves is separate from both: a --refresh query that SUCCEEDS
# proves dnf reached (or revalidated against) the repository just now. That is
# the freshness claim, and it is exact. A --refresh query that fails to reach
# the network says so on stderr; dnf can then fall back to a cached answer,
# which is the dangerous case - a stale number wearing a fresh look. Catch it by
# shape and report unknown. --cacheonly makes no freshness claim at all, by
# definition; then, and only then, cache_age_h and --max-age apply.
#
# Root and an ordinary user use different caches (/var/cache/dnf vs
# /var/tmp/dnf-<user>-*), so the cache age and the user are both reported: two
# people can legitimately get two answers, and the output explains why.
# CC_REPOMD_GLOBS (defined with the other parameters above) is the test seam.

# Unquoted on purpose: the value is space-separated globs, and a glob that
# matches nothing stays literal and is dropped by the -r test. READABLE, not
# merely present: `stat` succeeds on a mode-000 file, so a -f test would let an
# unparseable copy contribute a cache age while contributing no revision - the
# script would then report an age for a file it could not read.
repomd_files() {
  local f
  for f in $CC_REPOMD_GLOBS; do [ -r "$f" ] && [ -f "$f" ] && printf '%s\n' "$f"; done
  return 0
}

# (a) the vendor's own publish stamp. Empty - never a guess - if no copy is
# readable, none carries a <revision>, the value is not a plausible unix time,
# or the copies DISAGREE.
#
# <revision> IS NOT GUARANTEED TO BE A UNIX TIME. createrepo_c --revision takes
# an arbitrary string and a YYYYMMDDHHMMSS stamp is a common choice; subtracting
# one of those from `date +%s` yields a large negative number, which would be
# published as a measurement. Bound it: anything in the future (beyond an hour
# of clock skew) or before 2010 is not a stamp we can read, so say unknown.
#
# DISAGREEMENT IS ALSO UNKNOWN. Taking the maximum across caches could describe
# a NEWER repository state than the one repo_head was read from - "the vendor
# published 1h ago, newest is <older version>" - which is exactly the stale
# number wearing a fresh look this script exists to prevent. If our copies do
# not agree on the state we hold, we cannot date it.
REV_FLOOR=1262304000                      # 2010-01-01, below any real repo
published_epoch() {
  local f rev first="" now
  now=$(date +%s)
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    rev=$(sed -n 's/.*<revision>\([0-9][0-9]*\)<\/revision>.*/\1/p' "$f" 2>/dev/null | head -1)
    case "$rev" in ''|*[!0-9]*) continue ;; esac
    [ "$rev" -lt "$REV_FLOOR" ] && return 0          # not a unix timestamp
    [ "$rev" -gt $(( now + 3600 )) ] && return 0     # future: skew or not a time
    if [ -z "$first" ]; then first="$rev"
    elif [ "$rev" != "$first" ]; then return 0; fi   # caches disagree
  done <<EOF
$(repomd_files)
EOF
  printf '%s' "$first"
}

# (b) how old is the freshest copy we hold
cache_age_h() {
  local f age newest=""
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    age=$(( ( $(date +%s) - $(stat -c %Y "$f") ) / 3600 ))
    if [ -z "$newest" ] || [ "$age" -lt "$newest" ]; then newest="$age"; fi
  done <<EOF
$(repomd_files)
EOF
  printf '%s' "${newest:-unknown}"
}

PUB_EPOCH=$(published_epoch)
if [ -n "$PUB_EPOCH" ]; then
  PUBLISHED_AGE=$(( ( $(date +%s) - PUB_EPOCH ) / 3600 ))
else
  PUBLISHED_AGE=unknown
fi
CACHE_AGE=$(cache_age_h)                # how old the copy WE hold is
NETWORK_FAILED=0
case "$QERR_TEXT" in
  *"Failed to synchronize"*|*"Cannot download"*|*"Errors during downloading"*|\
  *"Cannot prepare internal mirrorlist"*|*"Could not resolve host"*|*"Failed to download"*)
    NETWORK_FAILED=1 ;;
esac
if [ "$REFRESH" -eq 1 ] && [ "$QRC" -eq 0 ] && [ "$NETWORK_FAILED" -eq 0 ]; then
  FRESHNESS=refreshed-now
  STALE=0
elif [ "$NETWORK_FAILED" -eq 1 ]; then
  FRESHNESS=refresh-failed
  STALE=1
else
  FRESHNESS=cache-only
  if [ "$CACHE_AGE" != unknown ] && [ "$CACHE_AGE" -le "$MAX_AGE_H" ]; then STALE=0; else STALE=1; fi
fi

# ---------------------------------------------------------------- channel head
CHANNEL_HEAD=""; CHANNEL_STATE=skipped
if [ "$NO_NETWORK" -eq 0 ] && command -v python3 >/dev/null 2>&1; then
  CHANNEL_HEAD=$(python3 - "$CHANNEL_URL" <<'PY' 2>/dev/null
import sys, urllib.request
try:
    req = urllib.request.Request(sys.argv[1], headers={"User-Agent": "cc-version-watch"})
    print(urllib.request.urlopen(req, timeout=15).read().decode().strip())
except Exception:
    print("")
PY
)
  if numeric "$CHANNEL_HEAD"; then CHANNEL_STATE=ok; else CHANNEL_HEAD=""; CHANNEL_STATE=unreachable; fi
fi

# ---------------------------------------------------------------- host facts
INSTALLED=""
if INSTALLED=$("$RPM" -q --qf '%{VERSION}' "$PKG" 2>/dev/null); then
  numeric "$INSTALLED" || INSTALLED=""
else
  INSTALLED=""
fi
APPROVED=""
[ -r "$APPROVED_FILE" ] && APPROVED=$(tr -d '[:space:]' < "$APPROVED_FILE")

# ---------------------------------------------------------------- the verdict
say "cc-version-watch - is anything published above our pin?"
STATUS=unknown; RC=3; ABOVE=0; NEWEST_ABOVE=""
if [ -z "$PIN" ]; then
  bad "no requiredMinimumVersion could be read from $POLICY - cannot tell whether we are behind"
elif [ -z "$REPO_HEAD" ]; then
  bad "the repository could not be queried for $PKG.$ARCH - cannot tell whether we are behind"
  note "a broken repository and a current host must not look the same; this is exit 3, not 0"
elif [ "$STALE" -eq 1 ]; then
  if [ "$FRESHNESS" = refresh-failed ]; then
    bad "the repository could not be reached, so any number below would be a cached guess"
    note "dnf said: ${QERR_TEXT:0:160}"
  else
    # Three different ways to land here, and they are not interchangeable. The
    # middle one is a refresh that WAS attempted and failed for a reason that is
    # not network-shaped; saying "no refresh was performed" there is untrue.
    if [ "$CACHE_AGE" = unknown ]; then
      bad "no readable $REPO_ID metadata was found, so the age of the copy we hold cannot be established (limit ${MAX_AGE_H}h)"
      note "nothing here is a guess: with no cache to date, staleness is unknown, and unknown is not current"
    elif [ "$REFRESH" -eq 1 ]; then
      bad "the refresh did not complete and the copy we hold was fetched ${CACHE_AGE}h ago (limit ${MAX_AGE_H}h)"
      note "dnf exited $QRC and said: ${QERR_TEXT:0:160}"
    else
      bad "no refresh was performed and the copy we hold was fetched ${CACHE_AGE}h ago (limit ${MAX_AGE_H}h)"
      note "run without --cacheonly, or raise --max-age deliberately"
    fi
  fi
else
  ok "pin $PIN (from $POLICY)"
  ok "newest in the repository for $ARCH: $REPO_HEAD (metadata $FRESHNESS)"
  if version_below "$PIN" "$REPO_HEAD"; then
    STATUS=behind; RC=1; ABOVE=1; NEWEST_ABOVE="$REPO_HEAD"
    note "A VERSION ABOVE THE PIN EXISTS: $REPO_HEAD > $PIN"
    note "This is not a decision. Target choice is OPERATIONS 3.1; the move is Part 7"
    note "(say \"version bump\" in a session opened in the deployment repository)."
  else
    STATUS=current; RC=0
    ok "nothing above the pin is published"
    version_below "$REPO_HEAD" "$PIN" && note "the repository head is BELOW the pin - channel rollback, or a pin ahead of the channel. Not an alert, but worth a look"
  fi
  case "$CHANNEL_STATE" in
    ok)
      if [ "$CHANNEL_HEAD" = "$REPO_HEAD" ]; then
        ok "the vendor channel agrees: $CHANNEL_HEAD"
      elif version_below "$REPO_HEAD" "$CHANNEL_HEAD"; then
        note "the vendor channel is at $CHANNEL_HEAD but the RPM repository has not published it yet - not something you can install here"
      else
        note "the RPM repository ($REPO_HEAD) is AHEAD of the vendor channel ($CHANNEL_HEAD) - an anomaly, worth a human look"
      fi ;;
    unreachable) note "the vendor channel endpoint did not answer - the repository head above stands alone" ;;
    skipped)     note "vendor channel corroboration skipped (--no-network)" ;;
  esac
fi
[ -n "$INSTALLED" ] && ok "installed $INSTALLED, approved ${APPROVED:-<none recorded>}"

# One machine line, ALWAYS printed, whatever the exit code. This is the whole
# answer in a form the weekly report and journalctl can both consume.
printf 'cc-version-watch: status=%s pin=%s repo_head=%s channel_head=%s installed=%s approved=%s above_pin=%s newest_above=%s freshness=%s published_age_h=%s cache_age_h=%s source=%s as_user=%s\n' \
  "$STATUS" "${PIN:-}" "${REPO_HEAD:-}" "${CHANNEL_HEAD:-}" "${INSTALLED:-}" "${APPROVED:-}" \
  "$ABOVE" "${NEWEST_ABOVE:-}" "$FRESHNESS" "$PUBLISHED_AGE" "$CACHE_AGE" "$REPO_SRC" "$(id -un)"

# The JSON is a CACHE for the report generator, not an authority - it is
# overwritten every run, which is also why it needs no logrotate stanza. Do not
# add one.
if [ "$(id -u)" -eq 0 ]; then
  mkdir -p "$(dirname "$REPORT")" 2>/dev/null
  tmp="$REPORT.$$"
  cat > "$tmp" <<EOF
{
  "schema": "cc-version-watch/2",
  "generated_at": "$(date -Is)",
  "host": "$(hostname -f 2>/dev/null || hostname)",
  "status": "$STATUS",
  "exit_code": $RC,
  "pin": "${PIN:-}",
  "pin_source": "$POLICY",
  "repo_head": "${REPO_HEAD:-}",
  "repo_arch": "$ARCH",
  "repo_source": "$REPO_SRC",
  "channel_head": "${CHANNEL_HEAD:-}",
  "channel_state": "$CHANNEL_STATE",
  "installed": "${INSTALLED:-}",
  "approved": "${APPROVED:-}",
  "above_pin": $ABOVE,
  "newest_above": "${NEWEST_ABOVE:-}",
  "freshness": "$FRESHNESS",
  "published_age_h": "$PUBLISHED_AGE",
  "cache_age_h": "$CACHE_AGE",
  "as_user": "$(id -un)"
}
EOF
  chmod 0640 "$tmp" 2>/dev/null
  mv -f "$tmp" "$REPORT" 2>/dev/null || note "could not write $REPORT"
else
  [ "$JSON_ONLY" -eq 1 ] && cat <<EOF
{"schema":"cc-version-watch/2","status":"$STATUS","pin":"${PIN:-}","repo_head":"${REPO_HEAD:-}","above_pin":$ABOVE,"as_user":"$(id -un)","filed":false}
EOF
  [ "$JSON_ONLY" -eq 1 ] || note "not root - nothing filed to $REPORT; the output above is the whole answer"
fi

exit "$RC"
