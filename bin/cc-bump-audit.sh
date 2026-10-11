#!/usr/bin/env bash
# cc-bump-audit.sh - the deterministic lane of a Claude Code version bump.
#
# Every version a site has run leaves behind verified claims that a NEW
# version can silently invalidate: the sandbox failure mode, the ignored glob
# rules, the compiled-in policy path, the version-floor behaviour. Those claims
# are collected here as PROBES - questions a site must re-ask at every
# bump - so that re-verification is a script run, not somebody's memory.
#
# What this script does:
#   [A] Repo/host coherence - the policy floor, the docs/UPGRADES.md entry the
#       floor requires (same invariant CI check [9] enforces), and the host's
#       approved-version. These are hard checks: a mismatch is exit 1.
#   [B] Auto probes - the standing questions that can be re-asked without a
#       person: binary strings, RPM shape, checksums, version coherence, the
#       private-install sweep. Anything this host cannot test is SKIPped with
#       the reason, never silently passed: a result with no denominator is
#       not a claim.
#   [C] The manual checklist - probes that need an interactive session, a
#       policy flip or a maintenance window. Printed with their doc homes so
#       the operator can hand them out; they are informational here.
#
# This is the deterministic HALF of the bump. The judgment half - vendor
# changelog analysis, the settings-surface diff, script review - is the
# agent-assisted procedure in docs/OPERATIONS.md Part 7, which runs this
# script first. The record both halves produce is docs/UPGRADES.md.
#
# Usage:
#   cc-bump-audit.sh                       audit the current pin
#   cc-bump-audit.sh --target-version X    pre-bump run: adds target checks
#   cc-bump-audit.sh --list-probes         print the probe manifest and exit
#
# Site values (CC_ETC, CC_HOME_ROOT, CC_CLAUDE_BIN, CC_REPO) come from config.sh
# through the loader; an exported CC_* wins, which is how the suite points each
# check at a fixture. Run from a checkout, CC_REPO is that checkout unless one
# was exported. OS seams: CC_RPM_BIN, CC_PROC, CC_MOUNTINFO.
#
# Exit: 0 clean (SKIPs allowed), 1 a hard check or auto probe failed, 2 usage.

set -uo pipefail

# --- site configuration: config.sh through the loader --------------------------
for _cfg in "${CC_CONFIG_LIB:-}" /etc/claude-code/cc-config.sh \
            "$(dirname "$(readlink -f "$0")")/../lib/cc-config.sh"; do
  [ -n "$_cfg" ] && [ -r "$_cfg" ] && { . "$_cfg" || exit 1; _cfg_loaded=1; break; }
done
[ "${_cfg_loaded:-0}" = 1 ] || { echo "cc-bump-audit.sh: cannot find cc-config.sh (looked in /etc/claude-code/ and ../lib/)" >&2; exit 1; }
unset _cfg _cfg_loaded
# Run from a checkout, audit THAT checkout - the one being bumped - not the
# shared one config.sh names, unless the caller exported CC_REPO.
_self="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
case " $CC_CONFIG_OVERRIDES " in *" CC_REPO "*) ;; *)
  [ -d "$_self/settings" ] && [ -d "$_self/bin" ] && CC_REPO="$_self" ;;
esac
unset _self
CC_RPM_BIN="${CC_RPM_BIN:-rpm}"   # the test suite stubs this so probe A2 never reads the live host
CC_PROC="${CC_PROC:-/proc}"        # probe A8 reads it; the suite fabricates one

TARGET=""
LIST_ONLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --target-version) TARGET="${2:-}"; shift 2 || { echo "usage: cc-bump-audit.sh --target-version <x.y.z>" >&2; exit 2; } ;;
    --list-probes)    LIST_ONLY=1; shift ;;
    -h|--help)
      sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "cc-bump-audit.sh: unknown argument '$1' (try --help)" >&2; exit 2 ;;
  esac
done

FAILURES=0
# CC_MOUNTINFO is a test seam only: the predicate below reads the kernel's mount
# table, which a test cannot fabricate without privileges.
CC_MOUNTINFO="${CC_MOUNTINFO:-/proc/self/mountinfo}"

# ADMIN_NS - is $CC_ETC/managed-settings.json a bind mount in THIS mount
# namespace? cc-admin-session.sh bind-mounts the admin policy over the fleet
# policy path for its own process tree, so inside a privileged session every
# probe that reads the deployed policy is reading the ADMIN file while comparing
# it against FLEET expectations. Unguarded, A3 would report sha drift and A7
# missing glob rules there - both artefacts of the mount, neither drift. Same predicate as cc-install.sh gate 1b and cc-healthcheck [2];
# docs/REPO-MAP.md carries the coupling.
ADMIN_NS=0
if [ -r "$CC_MOUNTINFO" ] && awk -v t="$CC_ETC/managed-settings.json" \
     '$5 == t {found=1} END {exit !found}' "$CC_MOUNTINFO"; then
  ADMIN_NS=1
fi

say()  { printf '%s\n' "$*"; }
ok()   { printf '  ok      %s\n' "$*"; }
bad()  { printf '  FAIL    %s\n' "$*" >&2; FAILURES=$((FAILURES + 1)); }
note() { printf '  note    %s\n' "$*"; }
skp()  { printf '  skip    %s\n' "$*"; }

# ---------------------------------------------------------------- the manifest
# id|mode|slug|question|doc home. One row per standing question. When a bump
# closes a question for good, delete its row HERE and its paragraph in the doc;
# when a new verified claim lands, add a row in the same commit.
PROBES=(
  'A1|auto|compiled-policy-path|Is /etc/claude-code/managed-settings.json still a compiled-in path in the binary?|internal/LIMITATIONS-AND-RISKS.md'
  'A2|auto|rpm-package-shape|Does the RPM still install exactly 2 files, no scriptlets, and leave the policy untouched (no .rpmnew/.rpmsave)?|internal/LIMITATIONS-AND-RISKS.md'
  'A3|auto|policy-baseline-sha|Does the deployed policy still match its recorded sha256 baseline?|docs/OPERATIONS.md (4.1)'
  'A4|auto|version-coherence|Do claude --version, approved-version and the policy floor agree?|docs/OPERATIONS.md (3.4)'
  'A5|auto|private-install-floor|Which private installs under the home filesystem sit below the floor (notify-first duty)?|docs/OPERATIONS.md (3.4)'
  'A6|auto|sandbox-helper-strings|Has the binary changed its apply-seccomp / sandbox-runtime search behaviour?|internal/LIMITATIONS-AND-RISKS.md'
  'A7|auto|glob-rules-present|Are all filename deny rules of the source policy (Read(**/...)) in the DEPLOYED policy? (Presence only - whether they now enforce is M10)|docs/RUNBOOK.md'
  'A8|auto|blocking-sessions|Is anything running the MANAGED binary right now? (The apply step refuses while one is - and a claude-admin session does not look like a claude tab)|docs/OPERATIONS.md (3.2)'
  'M1|manual|sandbox-re-enable-gate|With the sandbox temporarily enabled in a window, does a FRESH session run `echo hi`? (The only test that exercises the failing path)|docs/SANDBOX-DECISION.md (4)'
  'M2|manual|policy-rewrite-session-break|Does re-applying the identical policy still break running sessions until restart?|docs/OPERATIONS.md (1.5b)'
  'M3|manual|statusline-renders|Does the managed status line still render for a normal user?|docs/SETTINGS-REFERENCE.md (statusLine)'
  'M4|manual|skill-load-smoke|Does a user-level skill load under the granular strictPluginOnlyCustomization, while hooks and MCP stay locked?|docs/SETTINGS-REFERENCE.md (3.4)'
  'M5|manual|headless-permissiondenied|Does the PermissionDenied hook fire in headless (claude -p) runs?|docs/OPERATIONS.md (4.2, the headless caveat)'
  'M6|manual|required-max-version-reasons|Do both reasons requiredMaximumVersion stays unset still hold (a claude-local install in use; IDE-bundled CLI ahead of the pin)?|docs/SETTINGS-REFERENCE.md (6.1)'
  'M7|manual|ide-wrapper-ancestry|Does the editor panel still run the system claude (CC_CLAUDE_BIN) through the wrapper, not its bundled CLI?|docs/IDE-INTEGRATION.md (3, 6)'
  'M8|manual|invalid-settings-stripped|Are unknown settings keys still stripped-not-rejected (the silent-weakening failure mode that makes doctor mandatory)?|docs/SETTINGS-REFERENCE.md (1.1)'
  'M9|manual|automode-defaults-extend|Does "$defaults" in autoMode arrays still EXTEND the built-ins rather than replace them (hard_deny >= 2, environment >= 27)?|internal/LIMITATIONS-AND-RISKS.md'
  'M10|manual|glob-warning-in-session|Does /doctor IN A SESSION still warn that Read/Edit glob rules are ignored on Linux? The warning DISAPPEARING means the filename rules enforce at this version (record it in internal/LIMITATIONS-AND-RISKS.md) - then run the OPERATIONS 1.9 secret-guard probe to map the overlap. The CLI doctor does not carry permission diagnostics, so only the in-session /doctor answers this|docs/RUNBOOK.md'
  'M11|manual|hook-block-contract|Does a PreToolUse hook exiting 2 still BLOCK the tool call? (The secret guard and the upgrade guard are the enforcement half of the filename deny rules and the version pin; if exit 2 stops blocking they degrade to printing a message while the call proceeds)|docs/SETTINGS-REFERENCE.md (3.7)'
  'M12|manual|wrapper-stripping|Are command wrappers still stripped before permission matching the way the deny list assumes - timeout/nice/xargs stripped, npx/docker exec/mise exec NOT? (A change here silently widens or narrows every Bash rule)|docs/RUNBOOK.md (8.8 item 2)'
  'M13|manual|server-settings-empty|Does the claude.ai organisation console still push no settings, so the local policy remains authoritative? (A server-side payload replaces this file wholesale and silently)|docs/SETTINGS-REFERENCE.md (1.3)'
  'M14|manual|denial-reason-legible|Does the denial log still record a USABLE reason? Every record carries denied_by, and the useful values name a category ([Modify Shared Resources], [Security Weaken], permission_rule). Records carrying only the opaque literal "Blocked by classifier" cannot be triaged by reason at all - only by inspecting detail - so count them separately: one triage field going blind is a finding about the product, not a quiet week|docs/RUNBOOK.md (11.7)'
)

if [ "$LIST_ONLY" -eq 1 ]; then
  say "cc-bump-audit probe manifest - the questions every version bump re-asks"
  say ""
  printf '  %-4s %-6s %-28s %s\n' "id" "mode" "probe" "documented in"
  for row in "${PROBES[@]}"; do
    IFS='|' read -r id mode slug _q home <<< "$row"
    printf '  %-4s %-6s %-28s %s\n' "$id" "$mode" "$slug" "$home"
  done
  say ""
  say "Question texts: run with no arguments for the full audit, or read the"
  say "PROBES table in this script - each row cites the document that owns it."
  exit 0
fi

# ---------------------------------------------------------------- [A] coherence
say "[A] Repo and host coherence"

# NO CHECKOUT IS A SKIP, NOT A FAILURE. This script installs to /usr/local/sbin
# as well as living in the repository, because probes A5 and A8 under-report
# unprivileged and the weekly report runs it as root from a host path where no
# checkout exists. Section [A] is repo-side coherence and simply cannot be
# answered there; [B] can, and is the reason to run it at all.
POLICY_SRC="$CC_REPO/settings/managed-settings.json"
FLOOR=""
if [ ! -f "$POLICY_SRC" ]; then
  if [ -n "${CC_REPO_OPTIONAL:-}" ] || [ ! -d "$CC_REPO/settings" ]; then
    skp "repo/host coherence: no checkout at $CC_REPO, so the floor, the UPGRADES entry and approved-version cannot be cross-checked here. Run it from the repository for section [A]"
  else
    bad "no policy at $POLICY_SRC - is CC_REPO pointing at a checkout?"
  fi
else
  FLOOR=$(python3 -c '
import json, sys
try:
    print(json.load(open(sys.argv[1])).get("requiredMinimumVersion") or "")
except Exception:
    print("")' "$POLICY_SRC" 2>/dev/null)
  if [ -z "$FLOOR" ]; then
    note "the policy sets no requiredMinimumVersion - no floor to audit against"
  else
    ok "policy floor: $FLOOR"
    # Same invariant as CI check [9], enforced here too so an on-host run
    # with no CI in sight still refuses an unrecorded pin.
    if [ ! -f "$CC_REPO/docs/UPGRADES.md" ]; then
      bad "docs/UPGRADES.md is missing - the floor $FLOOR has no recorded transition"
    elif grep -qE "^## ${FLOOR//./\\.}\b" "$CC_REPO/docs/UPGRADES.md"; then
      ok "docs/UPGRADES.md has an entry for $FLOOR"
    else
      bad "docs/UPGRADES.md has no entry for $FLOOR - record the transition before moving on"
    fi
  fi
fi

APPROVED=""
if [ -f "$CC_ETC/approved-version" ]; then
  APPROVED=$(head -1 "$CC_ETC/approved-version" | tr -d '[:space:]')
  if [ -n "$FLOOR" ] && [ "$APPROVED" != "$FLOOR" ]; then
    bad "approved-version ($APPROVED) and the policy floor ($FLOOR) disagree - a half-done bump: the floor moves with the policy apply, approved-version with the package move (cc-update.sh / make pin); finish the OPERATIONS Part 7 sequence"
  else
    ok "approved-version: ${APPROVED:-<empty>}"
  fi
else
  note "no $CC_ETC/approved-version on this host (governance may precede the CLI here)"
fi

if [ -n "$TARGET" ]; then
  say ""
  say "[A+] Pre-bump checks against target $TARGET"
  if [ -n "$FLOOR" ] && [ "$TARGET" != "$FLOOR" ] && \
     [ "$(printf '%s\n%s\n' "$FLOOR" "$TARGET" | sort -V | tail -1)" = "$FLOOR" ]; then
    bad "target $TARGET is below the current floor $FLOOR - a downgrade locks every session out (lower the floor first, OPERATIONS 3.2)"
  elif [ "$TARGET" = "$FLOOR" ]; then
    note "target equals the current floor - nothing to move"
  else
    ok "target $TARGET is above the floor $FLOOR"
  fi
  if [ -f "$CC_REPO/docs/UPGRADES.md" ] && grep -qE "^## ${TARGET//./\\.}\b" "$CC_REPO/docs/UPGRADES.md"; then
    ok "docs/UPGRADES.md already has an entry for $TARGET"
  else
    note "docs/UPGRADES.md has no entry for $TARGET yet - the bump owes one (CI check [9] will hold the pin until it lands)"
  fi
fi

# ---------------------------------------------------------------- [B] auto probes
say ""
say "[B] Auto probes"
if [ "$ADMIN_NS" -eq 1 ]; then
  note "privileged session detected ($CC_ETC/managed-settings.json is a bind mount): the probes that read the DEPLOYED policy are skipped, not failed"
fi

# A1 compiled-policy-path. A build may store the path as TWO literals
# ("/etc/claude-code" and "managed-settings.json") that it joins at runtime,
# so grepping for the concatenated path alone would fail on a healthy binary.
# Accept either shape; corroborate behaviourally with /status in a session,
# which must attribute the managed source to that path.
if [ -x "$CC_CLAUDE_BIN" ] && command -v strings >/dev/null 2>&1; then
  # grep -c, never grep -q: this script runs under pipefail, and grep -q's
  # early exit SIGPIPEs the producer on a MATCH - the pipeline then reports
  # failure precisely when the check succeeds. -c reads to EOF.
  BINSTR=$(strings -a "$CC_CLAUDE_BIN" 2>/dev/null)
  N_FULL=$(printf '%s' "$BINSTR" | grep -c '/etc/claude-code/managed-settings.json')
  N_DIR=$(printf '%s' "$BINSTR" | grep -cx '/etc/claude-code')
  N_FILE=$(printf '%s' "$BINSTR" | grep -c 'managed-settings.json')
  if [ "$N_FULL" -ge 1 ]; then
    ok "A1 compiled-policy-path: compiled in as one literal"
  elif [ "$N_DIR" -ge 1 ] && [ "$N_FILE" -ge 1 ]; then
    ok "A1 compiled-policy-path: compiled in as components (/etc/claude-code + managed-settings.json, joined at runtime)"
  else
    bad "A1 compiled-policy-path: neither the path nor its components in $CC_CLAUDE_BIN strings - the immovable-policy argument just lost its foundation; confirm with /status before believing this"
  fi
else
  skp "A1 compiled-policy-path: no binary at $CC_CLAUDE_BIN or no strings(1) here"
fi

# A2 rpm-package-shape
if command -v "$CC_RPM_BIN" >/dev/null 2>&1 && "$CC_RPM_BIN" -q "$CC_PKG" >/dev/null 2>&1; then
  NFILES=$("$CC_RPM_BIN" -ql "$CC_PKG" 2>/dev/null | wc -l)
  if [ "$NFILES" -eq 2 ]; then
    ok "A2 rpm-package-shape: 2 files, the expected package shape"
  else
    bad "A2 rpm-package-shape: RPM installs $NFILES files (expected 2) - compare with the RPM shape the site recorded in internal/LIMITATIONS-AND-RISKS.md before applying"
  fi
  if [ -z "$("$CC_RPM_BIN" -q --scripts "$CC_PKG" 2>/dev/null)" ]; then
    ok "A2 rpm-package-shape: no scriptlets"
  else
    bad "A2 rpm-package-shape: the package gained scriptlets - they run as root at install time; review them"
  fi
  # compgen per pattern: a single `ls a/*.rpmnew a/*.rpmsave` fails when EITHER
  # glob is unmatched, so the bad branch would need both kinds at once - and
  # rpm leaves exactly one kind per config-file event.
  RPMLEFT="$(compgen -G "$CC_ETC/*.rpmnew"; compgen -G "$CC_ETC/*.rpmsave")"
  if [ -n "$RPMLEFT" ]; then
    bad "A2 rpm-package-shape: $(printf '%s' "$RPMLEFT" | tr '\n' ' ')- a package now owns the policy directory"
  else
    ok "A2 rpm-package-shape: no .rpmnew/.rpmsave under $CC_ETC"
  fi
else
  skp "A2 rpm-package-shape: no rpm or no $CC_PKG package on this host"
fi

# A3 policy-baseline-sha
if [ "$ADMIN_NS" -eq 1 ]; then
  skp "A3 policy-baseline-sha: privileged session - $CC_ETC/managed-settings.json is the bind-mounted ADMIN policy, so the fleet baseline cannot be checked from here. Re-run from a plain session"
elif [ -f "$CC_ETC/managed-settings.json.sha256" ]; then
  if (cd "$CC_ETC" && sha256sum -c managed-settings.json.sha256 --status 2>/dev/null); then
    ok "A3 policy-baseline-sha: deployed policy matches its baseline"
  else
    bad "A3 policy-baseline-sha: deployed policy DIFFERS from its recorded baseline - drift or an unrecorded change"
  fi
else
  skp "A3 policy-baseline-sha: no baseline at $CC_ETC/managed-settings.json.sha256"
fi

# A4 version-coherence
if [ -x "$CC_CLAUDE_BIN" ]; then
  LIVEV=$(timeout 15 "$CC_CLAUDE_BIN" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)
  if [ -z "$LIVEV" ]; then
    skp "A4 version-coherence: $CC_CLAUDE_BIN did not report a version"
  elif [ -n "$FLOOR" ] && [ "$(printf '%s\n%s\n' "$FLOOR" "$LIVEV" | sort -V | head -1)" != "$FLOOR" ]; then
    bad "A4 version-coherence: binary $LIVEV is BELOW the floor $FLOOR - no session on this host can start"
  else
    ok "A4 version-coherence: binary $LIVEV, floor ${FLOOR:-<none>}, approved ${APPROVED:-<none>}"
  fi
else
  skp "A4 version-coherence: no binary at $CC_CLAUDE_BIN"
fi

# A5 private-install-floor
if [ -d "$CC_HOME_ROOT" ] && [ -n "$FLOOR" ]; then
  BELOW=0; FOUND=0; UNREADABLE=0; OPAQUE=0
  for h in "$CC_HOME_ROOT"/*; do
    b="$h/.local/bin/claude"
    v=""
    # A home whose ~/.local we cannot traverse is not a home without an install:
    # it is a home we cannot see into, and the difference decides whether a
    # colleague gets told their tooling is about to stop starting. Run this
    # probe as root for a complete answer; unprivileged, say what was missed.
    if [ -d "$h/.local" ] && [ ! -x "$h/.local" ]; then
      OPAQUE=$((OPAQUE + 1))
      note "A5 private-install-floor: $(basename "$h") - \$HOME/.local is not readable as $(id -un), so any private install there is invisible to this sweep (re-run as root)"
      continue
    fi
    # NEVER execute "$b". The weekly report runs this sweep as root, and the
    # file belongs to the engineer: running it would hand them root. Read the
    # version from what the native installer leaves on disk instead - the
    # launcher is a symlink into ~/.local/share/claude/versions/<version>.
    if [ -L "$b" ] || [ -e "$b" ]; then
      FOUND=$((FOUND + 1))
      v=""
      if [ -L "$b" ]; then
        v=$(basename "$(readlink -f "$b" 2>/dev/null)" | grep -oxE '[0-9]+\.[0-9]+\.[0-9]+' || true)
      fi
      if [ -z "$v" ]; then
        note "A5 private-install-floor: $(basename "$h") has a launcher at \$HOME/.local/bin/claude that is not a link into its versions tree - not executed (this sweep may run as root); check its version by hand"
        v=$(ls -1 "$h/.local/share/claude/versions" 2>/dev/null \
              | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -1)
      fi
    elif [ -d "$h/.local/share/claude/versions" ]; then
      # The install TREE with no launcher on PATH, counted as cc-healthcheck
      # [4] counts it: a sweep that tests only
      # ~/.local/bin/claude under-reports, and here it under-reports the
      # notify-first duty - the person is invisible precisely because their
      # install is the least visible. Read the highest version directory
      # instead of executing anything.
      FOUND=$((FOUND + 1))
      v=$(ls -1 "$h/.local/share/claude/versions" 2>/dev/null \
            | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -1)
      [ -n "$v" ] && note "A5 private-install-floor: $(basename "$h") has an install tree at \$HOME/.local/share/claude ($v) with no launcher on PATH - runnable by path, and the native updater may recreate the symlink"
    else
      continue
    fi
    if [ -z "$v" ]; then
      UNREADABLE=$((UNREADABLE + 1))
      note "A5 private-install-floor: $(basename "$h") has an install whose version could not be read - check by hand before moving the floor"
      continue
    fi
    if [ "$(printf '%s\n%s\n' "$FLOOR" "$v" | sort -V | head -1)" != "$FLOOR" ]; then
      note "A5 private-install-floor: $(basename "$h") runs $v (below $FLOOR - refuses to start; notify per OPERATIONS 3.4)"
      BELOW=$((BELOW + 1))
    fi
  done
  # Always print the denominator: "0 below" means nothing without "of how many",
  # and "0 of 0" is a broken sweep wearing the same green as a clean host.
  A5MSG="A5 private-install-floor: $FOUND private install(s) found, $BELOW below the floor"
  [ "$UNREADABLE" -gt 0 ] && A5MSG="$A5MSG, $UNREADABLE unreadable"
  [ "$OPAQUE" -gt 0 ] && A5MSG="$A5MSG, $OPAQUE home(s) not visible to this run"
  ok "$A5MSG"
else
  skp "A5 private-install-floor: no $CC_HOME_ROOT to sweep, or no floor set"
fi

# A6 sandbox-helper-strings (report-only: a site records its baseline in
# internal/LIMITATIONS-AND-RISKS.md)
if [ -x "$CC_CLAUDE_BIN" ] && command -v strings >/dev/null 2>&1; then
  HITS=$(strings -a "$CC_CLAUDE_BIN" 2>/dev/null | grep -cE 'claude-cli-internal|@anthropic-ai/sandbox-runtime|apply-seccomp' || true)
  note "A6 sandbox-helper-strings: $HITS matching string(s) in the binary - diff the actual lines against the baseline the site recorded in internal/LIMITATIONS-AND-RISKS.md before trusting any sandbox change"
else
  skp "A6 sandbox-helper-strings: no binary or no strings(1) here"
fi

# A7 glob-rules-present. The CLI `claude doctor` carries NO permission
# diagnostics when captured (it prints install/update
# state and settings-schema warnings, then defers to the in-session /doctor),
# so no script can see the glob warning. The scriptable half is presence:
# every filename rule (Read(**/...)) in the SOURCE policy must be in the
# DEPLOYED one - read from the source, so dropping or adding a rule there is
# not a second edit here. A source naming none is a check over nothing, and
# fails. Whether the rules ENFORCE is manual probe M10.
if [ "$ADMIN_NS" -eq 1 ]; then
  skp "A7 glob-rules-present: privileged session - the policy at $CC_ETC is the ADMIN one, which drops these rules by design (ADMIN-SESSION.md 3). Re-run from a plain session"
elif [ -f "$CC_ETC/managed-settings.json" ]; then
  read -r NGLOB NWANT < <(python3 -c '
import json, sys
def deny(path):
    try:
        return (json.load(open(path)).get("permissions") or {}).get("deny") or []
    except Exception:
        return []
want = [r for r in deny(sys.argv[2]) if r.startswith("Read(**/")]
have = deny(sys.argv[1])
print(sum(1 for r in want if r in have), len(want))' "$CC_ETC/managed-settings.json" "$POLICY_SRC" 2>/dev/null)
  if [ "${NWANT:-0}" -eq 0 ]; then
    bad "A7 glob-rules-present: the source policy names no filename rule (Read(**/...)) - nothing to check, or $POLICY_SRC is unreadable"
  elif [ "${NGLOB:-0}" -eq "$NWANT" ]; then
    ok "A7 glob-rules-present: all $NWANT filename rules from the source policy are in the deployed one (enforcement question: probe M10)"
  else
    bad "A7 glob-rules-present: only ${NGLOB:-0} of $NWANT filename rules from the source policy are deployed - documentation-of-intent lost (docs/RUNBOOK.md says keep them)"
  fi
else
  skp "A7 glob-rules-present: no deployed policy at $CC_ETC/managed-settings.json"
fi

# A8 blocking-sessions. Asked HERE, at audit time, because the answer decides
# whether the maintenance window can start at all - and the failure it prevents
# is easy to hit: an operator with "no session tabs open" is blocked by their
# own claude-admin session, which is a runuser child and invisible as a tab.
# Same question as `cc-update.sh sessions`, same /proc-not-process-name method
# (docs/REPO-MAP.md carries the coupling); this copy only reports.
BUSY=0
if [ -d "$CC_PROC" ]; then
  CLAUDE_REAL=$(readlink -f "$CC_CLAUDE_BIN" 2>/dev/null || printf '%s' "$CC_CLAUDE_BIN")
  for d in "$CC_PROC"/[0-9]*; do
    [ -e "$d/exe" ] || continue
    [ "$(readlink -f "$d/exe" 2>/dev/null)" = "$CLAUDE_REAL" ] || continue
    BUSY=$((BUSY + 1))
  done
  if [ "$BUSY" -eq 0 ]; then
    ok "A8 blocking-sessions: nothing is running $CC_CLAUDE_BIN$([ "$(id -u)" -eq 0 ] || printf '%s' " (visible to $(id -un) - run as root to see every user)")"
  else
    note "A8 blocking-sessions: $BUSY process(es) are running $CC_CLAUDE_BIN - the apply step will REFUSE until they exit. List them with: cc-update.sh sessions. A claude-admin session counts and does not look like a claude tab; a private install such as claude-local does not count"
  fi
else
  skp "A8 blocking-sessions: no $CC_PROC to read"
fi

# ---------------------------------------------------------------- [C] manual
say ""
say "[C] Manual probes - need a session, a window, or a policy flip"
for row in "${PROBES[@]}"; do
  IFS='|' read -r id mode slug q home <<< "$row"
  [ "$mode" = "manual" ] || continue
  printf '  [ ] %-4s %-28s %s\n' "$id" "$slug" "$q"
  printf '      %-4s %-28s -> %s\n' "" "" "$home"
done

say ""
if [ "$FAILURES" -eq 0 ]; then
  say "cc-bump-audit: clean (skips above are conditions this run could not test)"
  exit 0
else
  say "cc-bump-audit: $FAILURES check(s) FAILED"
  exit 1
fi
