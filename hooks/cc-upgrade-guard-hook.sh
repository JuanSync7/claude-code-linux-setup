#!/bin/bash -p
# cc-upgrade-guard-hook.sh - PreToolUse signpost for self-update attempts.
#
# WHY THIS EXISTS
# The Claude Code version on this fleet is IT-managed: the RPM is version-locked
# (make pin / bin/cc-update.sh) and requiredMinimumVersion in the managed policy
# is the floor. A session that tries to upgrade the binary - "claude update", an
# npm sideload, the vendor's curl installer, a package-manager transaction -
# cannot succeed (the deny list blocks the privileged forms, versionlock blocks
# the rest), but without this hook the refusal is a bare permission error that
# explains nothing. This hook converts that dead end into a signpost: it blocks
# the call with exit 2 and says WHERE version moves actually happen.
#
# WHAT IT IS NOT - do not oversell it when reporting coverage:
#   This is a redirect, not the enforcement. The controls that actually hold the
#   version are the dnf versionlock, root ownership of /usr/bin/claude, and the
#   deny rules on sudo/dnf/rpm. A command shape this hook does not recognise
#   still hits those - including one a user deliberately disguises, e.g. by
#   quoting the command word itself. Accepted: the signpost is for the honest
#   path, the versionlock is for every path.
#
# HOW MATCHING WORKS - two rules, both load-bearing:
#   * Quoted spans are stripped before matching. A quoted string is an ARGUMENT
#     (a commit message, a grep pattern, an echo text), never a command - so
#     "talking about upgrades" is unblockable by construction, whatever
#     separators the quote contains.
#   * Patterns then anchor to a command position on the unquoted skeleton:
#     start of any line, or after ; & | $( or a backtick, with sudo/env
#     prefixes allowed. Mid-line vocabulary still does not match.
#
# SAFETY RULES, load-bearing - same contract as cc-secret-guard-hook.sh:
#   * Exit 2 ONLY on a positive match. Malformed JSON, missing python3, a
#     missing command field, an unexpected tool - ALL exit 0 (allow). A parsing
#     bug must never become a fleet-wide denial of service.
#   * Never read or log anything. This hook writes no files.
#
# Registered in managed-settings.json PreToolUse with matcher "Bash".
# Install: /usr/local/sbin/cc-upgrade-guard-hook.sh, 0755 root:root.

# The engineer's environment must not steer what runs this hook: it is a
# control against that same engineer. `-p` above makes bash ignore BASH_ENV and
# ENV (which run before line 1) and exported functions; the absolute
# interpreter path skips a `bash` planted first on PATH; PATH is reset before
# the first command; python runs isolated (-I: no PYTHONPATH, no user site).
# A preloaded library (LD_PRELOAD) is not stopped here - nothing inside a
# script can stop it. That is the residual limit of a hook as a control.
PATH=/usr/bin:/bin; export PATH

support_contact() {
  # Site config, read only from the installed copy: this runs as the engineer, so
  # every CC_* in their environment is cleared first and none can steer it.
  # The test suite rewrites the one path below to a fixture loader.
  for _v in ${!CC_@}; do unset "$_v"; done
  if . /etc/claude-code/cc-config.sh >/dev/null 2>&1 && [ -n "${CC_SUPPORT_CONTACT:-}" ]; then
    printf '%s' "$CC_SUPPORT_CONTACT"
  else
    printf 'IT support (contact not configured: CC_SUPPORT_CONTACT)'
  fi
}

INPUT="$(cat 2>/dev/null)"

# Fail open on anything unexpected. Decision is printed by python3 as a single token.
DECISION="$(
  printf '%s' "$INPUT" | /usr/bin/python3 -I -c '
import json, re, sys
try:
    d = json.loads(sys.stdin.read() or "{}")
except Exception:
    print("ALLOW"); raise SystemExit(0)

ti = d.get("tool_input") or {}
if not isinstance(ti, dict):
    print("ALLOW"); raise SystemExit(0)

cmd = ti.get("command") or ""
if not isinstance(cmd, str) or not cmd:
    print("ALLOW"); raise SystemExit(0)

# Rule 1: strip quoted spans - arguments are never command positions.
skel = re.sub(r"\x27[^\x27]*\x27|\"[^\"]*\"", " ", cmd)

# Rule 2: a command position on what remains. re.MULTILINE makes ^ the start
# of every line, because multi-line Bash tool calls are a normal shape.
PRE = r"(?:^\s*|[;&|]\s*|\$\(\s*|`\s*)(?:sudo\s+(?:-\S+\s+)*|env\s+(?:\w+=\S*\s+)*)*"

# The self-update shapes worth a signpost on this fleet (Linux forms only;
# the vendor also documents brew/winget/apk forms that cannot occur here).
PATTERNS = [
    PRE + r"claude(?:-local)?\s+(?:update|install|migrate-installer)\b",
    PRE + r"npm\s+(?:install|i|add|update|up|upgrade)\b[^;&|\n]*@anthropic-ai/claude-code",
    # Verbs are matched with an explicit hyphen guard rather than \b, because \b
    # sits happily on both sides of a hyphen: \bupdate\b fires inside the
    # READ-ONLY "dnf check-update", which the bump procedure itself runs
    # (OPERATIONS 3.2 step 2). The lookbehind kills that, so every hyphenated
    # transaction verb - dist-upgrade, upgrade-minimal, distro-sync - has to be
    # spelled out, longest alternative first. Query verbs (list, info, search,
    # repoquery, check-update, provides) are simply absent from the list.
    PRE + r"(?:dnf|yum|microdnf|apt-get|apt|zypper)\b[^;&|\n]*"
        + r"(?<![-\w])(?:dist-upgrade|full-upgrade|upgrade-minimal|distro-sync"
        + r"|localinstall|reinstall|upgrade|install|update|downgrade|swap)(?![-\w])"
        + r"[^;&|\n]*\bclaude-code\b",
    PRE + r"(?:curl|wget|fetch)\b[^;&|\n]*\bclaude\.ai/install\.(?:sh|cmd|ps1)\b",
]
for p in PATTERNS:
    if re.search(p, skel, re.MULTILINE):
        print("DENY"); raise SystemExit(0)

# rpm needs flag-CLUSTER inspection, which one regex cannot do: -Uvh and -ivh
# must deny while -qi (query-info) stays allowed. Long forms are simple; short
# clusters deny on U or F anywhere, or i without q (install vs query-info).
for m in re.finditer(PRE + r"rpm\s+([^;&|\n]*)", skel, re.MULTILINE):
    seg = m.group(1)
    if "claude-code" not in seg:
        continue
    if re.search(r"--(?:install|upgrade|freshen|reinstall)\b", seg):
        print("DENY"); raise SystemExit(0)
    for cluster in re.findall(r"(?<!\S)-([a-zA-Z]+)", seg):
        if "U" in cluster or "F" in cluster or ("i" in cluster and "q" not in cluster and "e" not in cluster):
            print("DENY"); raise SystemExit(0)

print("ALLOW")
' 2>/dev/null
)"

case "$DECISION" in
  DENY)
    # stderr is surfaced to the model/user as the block reason.
    printf 'Blocked by IT policy: Claude Code on this host is IT-managed - the version is\n' >&2
    printf 'RPM-pinned and locked, so an in-session upgrade cannot take effect.\n' >&2
    printf 'Version moves are gated changes with their own procedure (the version bump,\n' >&2
    printf 'docs/OPERATIONS.md Part 7 in the deployment repository).\n' >&2
    # The contact is site config, read only on a block so an allowed call pays
    # nothing. A missing config never unblocks: the decision above stands.
    printf 'Questions: %s\n' "$(support_contact)" >&2
    exit 2
    ;;
  *)
    exit 0
    ;;
esac
