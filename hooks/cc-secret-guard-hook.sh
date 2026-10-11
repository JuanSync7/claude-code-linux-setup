#!/bin/bash -p
# cc-secret-guard-hook.sh - PreToolUse guard for secret FILENAMES.
#
# WHY THIS EXISTS
# The policy's rules that match a secret by FILENAME anywhere on disk
# (Read(**/.env) and siblings) are glob patterns, and whether Claude Code
# enforces those on Linux depends on the version: some builds report them
# ignored in the in-session `/doctor`, others enforce them. Probe M10 of
# cc-bump-audit.sh asks at each version move, and a site records the answer
# for the version in use in internal/LIMITATIONS-AND-RISKS.md.
#
# This hook is the enforcement of record whatever that status: it inspects the
# file path of each Read/Edit/Write/NotebookEdit call (the policy's matcher -
# Grep and Glob are not in it) and exits 2 - which BLOCKS the tool - when the
# basename it is given, or the basename it resolves to, looks like a credential.
# It is also the ONLY control for .env.<name>: the policy carries no
# Read(**/.env.*) rule, because deny rules run before this hook and such a rule
# would refuse the allow-listed .env.example.
#
# WHAT IT DOES NOT DO - state this plainly when reporting coverage:
#   It does not reach arbitrary subprocesses. `python3 -c "open('/x/.env').read()"` is
#   a Bash call whose file access the hook never sees, exactly like the permission
#   rules beside it. Only the OS sandbox covers that, and only at directory
#   granularity. The compensating control for a secret that IS read is the network
#   layer: the Bash denies on network tools plus autoMode.hard_deny make sending it
#   off-fleet harder (sandbox.network.strictAllowlist would be the OS-level control,
#   but it is inert while the sandbox is disabled). Layered, not airtight.
#
# SAFETY RULES, load-bearing - do not break these:
#   * Exit 2 ONLY on a positive filename match. EVERY other path - malformed JSON,
#     missing python3, unreadable stdin, an unexpected tool - exits 0 (allow). A
#     logging or parsing bug must never become a fleet-wide denial of service.
#   * Never read or log file CONTENTS. Same content boundary as the audit hooks
#     (runbook 11.7): the path is evidence, the contents are the engineer's work.
#
# Registered in managed-settings.json PreToolUse alongside cc-audit-hook.sh.
# Install: /usr/local/sbin/cc-secret-guard-hook.sh, 0755 root:root (runs as the engineer).

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
import json, os, re, sys
try:
    d = json.loads(sys.stdin.read() or "{}")
except Exception:
    print("ALLOW"); raise SystemExit(0)

ti = d.get("tool_input") or {}
if not isinstance(ti, dict):
    print("ALLOW"); raise SystemExit(0)

# Only look at file-path-bearing fields. Bash commands are deliberately NOT parsed:
# argument parsing is fragile (runbook 8.8) and the deny list already covers the
# command names that matter.
path = ti.get("file_path") or ti.get("path") or ti.get("notebook_path") or ""
if not isinstance(path, str) or not path:
    print("ALLOW"); raise SystemExit(0)

# Judge every name the path goes by: the one given, and the one it RESOLVES to.
# A symlink called notes.txt that points at a .env is a .env; so is a link
# called .env.example (an allow-listed name) that points at one. A relative
# path is resolved against the session cwd. A path that does not resolve
# (not there yet: a Write) is judged by its given name alone.
names = [os.path.basename(path)]
try:
    cwd = d.get("cwd") or ""
    full = path if os.path.isabs(path) or not isinstance(cwd, str) or not cwd else os.path.join(cwd, path)
    real = os.path.realpath(full)
    if os.path.basename(real) != names[0]:
        names.append(os.path.basename(real))
except Exception:
    pass

# The filename rules of the policy, plus the obvious siblings. Matched on the
# BASENAME so the rule holds at any depth - which is what **/ expresses.
PATTERNS = [
    r"^\.env$",                      # Read(**/.env)
    r"^\.env\..+$",                  # no policy rule: this hook alone
    r"^.+\.pem$",                    # Read(**/*.pem)
    r"^id_rsa.*$",                   # Read(**/id_rsa*)
    r"^id_ed25519.*$",               # Read(**/id_ed25519*)
    r"^id_ecdsa.*$",
    r"^id_dsa.*$",
    r"^.+\.p12$", r"^.+\.pfx$", r"^.+\.key$",
    r"^\.netrc$", r"^\.pgpass$",
    r"^credentials$",                # ~/.aws/credentials, gcloud, etc.
    r"^\.credentials\.json$",        # Claude Code own credential store
    r"^service-account.*\.json$",
    r"^\.npmrc$", r"^\.pypirc$",     # contain registry auth tokens
]

# Allowlist: legitimate files whose names collide with the patterns above.
# Public keys and certificate bundles are not secrets and are read constantly.
ALLOW = [
    r"^id_rsa\.pub$", r"^id_ed25519\.pub$", r"^id_ecdsa\.pub$", r"^id_dsa\.pub$",
    r"^\.env\.example$", r"^\.env\.sample$", r"^\.env\.template$", r"^\.env\.dist$",
    r"^ca-bundle\.pem$", r"^ca-certificates\.pem$", r"^cacert\.pem$",
    r"^fullchain\.pem$", r"^chain\.pem$",   # public cert chains, not private keys
]
# A name on the allowlist is cleared; any other name that matches a pattern
# blocks - so an allow-listed link name cannot launder a secret target.
for base in names:
    if any(re.match(p, base, re.IGNORECASE) for p in ALLOW):
        continue
    for p in PATTERNS:
        if re.match(p, base, re.IGNORECASE):
            print("DENY " + base); raise SystemExit(0)

print("ALLOW")
' 2>/dev/null
)"

case "$DECISION" in
  DENY*)
    name="${DECISION#DENY }"
    # stderr is surfaced to the model/user as the block reason.
    printf 'Blocked by IT policy: "%s" matches a credential filename pattern.\n' "$name" >&2
    printf 'Credential files are kept out of Claude Code sessions on this host.\n' >&2
    # The contact is site config, read only on a block so an allowed call pays
    # nothing. A missing config never unblocks: the decision above stands.
    printf 'If this file is genuinely not a secret, raise it with %s.\n' "$(support_contact)" >&2
    exit 2
    ;;
  *)
    exit 0
    ;;
esac
