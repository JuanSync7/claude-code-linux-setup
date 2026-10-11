#!/usr/bin/env bash
# cc-audit.sh - evidence-grade snapshot of Claude Code policy on this host.
# Read-only. Produces a timestamped report suitable for change records and
# internal audit. Run monthly, and before/after any policy change.
#
# EXIT CODES. 0 the record was written - findings or not, because this is an
# evidence snapshot, not a verdict (cc-healthcheck.sh is the verdict); the count
# of "**" lines is printed after it. 3 COULD NOT RUN - no config, or the record
# could not be written. 3 is distinct from 0 so that a caller can tell an audit
# on file from no audit at all.
#
# The record names accounts and their credential state, so it is 0640: root
# and the log group, never every user on the host.
#
# Test seams, OS defaults: CC_PASSWD, CC_MOUNTINFO, CC_DOCTOR_TIMEOUT (seconds
# `claude doctor` may take; it can hang on a host with no network). Suite cases
# A1-A10, A40 and AU1-AU5.

set -uo pipefail

# --- site configuration: config.sh through the loader --------------------------
for _cfg in "${CC_CONFIG_LIB:-}" /etc/claude-code/cc-config.sh \
            "$(dirname "$(readlink -f "$0")")/../lib/cc-config.sh"; do
  [ -n "$_cfg" ] && [ -r "$_cfg" ] && { . "$_cfg" || exit 3; _cfg_loaded=1; break; }
done
[ "${_cfg_loaded:-0}" = 1 ] || { echo "cc-audit.sh: cannot find cc-config.sh (looked in /etc/claude-code/ and ../lib/)" >&2; exit 3; }
unset _cfg _cfg_loaded
# The dnf repository file is named by its repo id; /etc/yum.repos.d is dnf's.
# CC_REPO_FILE is a test seam: without it a case could only fabricate a repo
# file by writing the live one.
REPO_FILE="${CC_REPO_FILE:-/etc/yum.repos.d/$CC_PKG_REPO_ID.repo}"

OUT="${1:-$CC_LOGDIR/audit-$(date +%Y%m%d-%H%M%S).txt}"

# ADMIN_NS - is the policy path a bind mount in THIS mount namespace? Inside a
# cc-admin-session.sh session it is: the ADMIN policy is mounted over the fleet
# one, so everything below about "the managed policy" would describe the wrong
# file under a heading that says otherwise. An audit that is quietly about the
# wrong policy is worse than no audit, so this is announced loudly in the report
# itself. Same predicate as cc-install.sh gate 1b, cc-healthcheck.sh [2] and
# cc-bump-audit.sh A3/A7 (docs/REPO-MAP.md carries the coupling); CC_MOUNTINFO is
# the test seam.
CC_MOUNTINFO="${CC_MOUNTINFO:-/proc/self/mountinfo}"
ADMIN_NS=0
CC_PASSWD="${CC_PASSWD:-/etc/passwd}"
MANAGED="${CC_ETC}/managed-settings.json"
if [ -r "$CC_MOUNTINFO" ] && awk -v t="$MANAGED" '$5 == t {found=1} END {exit !found}' "$CC_MOUNTINFO"; then
  ADMIN_NS=1
fi
CC_DOCTOR_TIMEOUT="${CC_DOCTOR_TIMEOUT:-60}"
umask 027
if ! mkdir -p "$(dirname "$OUT")" 2>/dev/null || ! : >> "$OUT" 2>/dev/null; then
  echo "cc-audit.sh: cannot write the audit record $OUT" >&2
  exit 3
fi
chmod 0640 "$OUT" 2>/dev/null

# The accounts to examine, built the way cc-healthcheck.sh builds them: homes
# under CC_HOME_ROOT, owner resolved by stat, then local interactive
# accounts from /etc/passwd whose homes live elsewhere. /etc/passwd alone misses
# every directory-backed (LDAP/sss) account, which on some sites is all of them.
USERS_TMP=$(mktemp) || { echo "cc-audit.sh: no writable temp dir" >&2; exit 3; }
trap 'rm -f "$USERS_TMP"' EXIT
if [ -d "$CC_HOME_ROOT" ]; then
  for home in "$CC_HOME_ROOT"/*; do
    [ -d "$home" ] || continue
    owner=$(stat -c '%U' "$home" 2>/dev/null)
    [ -n "$owner" ] && [ "$owner" != UNKNOWN ] && printf '%s:%s\n' "$owner" "$home"
  done >> "$USERS_TMP"
fi
awk -F: '$3>=1000 && $3<65534 && $7 !~ /nologin|false/ {print $1":"$6}' "$CC_PASSWD" 2>/dev/null \
  | while IFS= read -r entry; do
      case "${entry#*:}" in "$CC_HOME_ROOT"/*) continue ;; esac
      printf '%s\n' "$entry"
    done >> "$USERS_TMP"
sort -u -o "$USERS_TMP" "$USERS_TMP"

{
echo "Claude Code policy audit"
echo "Host      : $(hostname -f 2>/dev/null || hostname)"
echo "Generated : $(date -Is)"
echo "Operator  : ${SUDO_USER:-$(id -un)}"
if [ "$ADMIN_NS" -eq 1 ]; then
  echo "Policy    : *** PRIVILEGED SESSION - $MANAGED IS A BIND MOUNT ***"
  echo "            Everything below about the managed policy describes the ADMIN"
  echo "            policy, not the fleet policy every other user receives. Do not"
  echo "            compare this report against fleet claims. Re-run from a plain"
  echo "            root shell for an audit of the fleet policy."
fi
# Only report an instance ID that actually looks like one; off EC2 (or behind a
# proxy) this endpoint returns an error body with exit status 0.
# Python, not curl: some endpoint protection products kill curl started from a
# shell.
AWS_ID=$(python3 -c '
import urllib.request
print(urllib.request.urlopen("http://169.254.169.254/latest/meta-data/instance-id", timeout=2).read().decode()[:40])' 2>/dev/null || true)
case "$AWS_ID" in
  i-[0-9a-f]*) echo "AWS       : $AWS_ID" ;;
  *)           echo "AWS       : n/a (not an EC2 instance, or metadata unreachable)" ;;
esac
echo "==============================================================="

echo
echo "--- 1. Package and version ---"
rpm -qi "$CC_PKG" 2>/dev/null | sed -n '1,12p' || echo "$CC_PKG RPM not installed"
echo "Binary version: $(claude --version 2>/dev/null || echo 'not runnable as this user')"
echo "Version lock  :"
dnf versionlock list 2>/dev/null | grep -i claude || echo "  (no lock - version can move on the next dnf upgrade)"
echo "Repo config   : $REPO_FILE"
sed -n '1,20p' "$REPO_FILE" 2>/dev/null || echo "  (no $REPO_FILE)"
echo "Signing key   :"
# The Claude Code release key fingerprint ends BAA929FF1A7ECACE; RPM names imported
# keys by the low 32 bits of the key ID, so the package is gpg-pubkey-1a7ecace-*.
# Report whether the host trusts it, and whether the repo trusts a local file or
# refetches over the network at install time.
if rpm -q gpg-pubkey 2>/dev/null | grep -qi '1a7ecace'; then
  echo "  trusted in RPM DB: $(rpm -q gpg-pubkey 2>/dev/null | grep -i '1a7ecace')"
else
  echo "  ** Claude Code release key (…1A7ECACE) NOT in the RPM database **"
  echo "     Either the package was never installed from the signed repo, or the key"
  echo "     was removed. Verify before the next upgrade."
fi
KEYSRC=$(awk -F= '/^gpgkey/{print $2}' "$REPO_FILE" 2>/dev/null)
case "$KEYSRC" in
  file://*) echo "  repo gpgkey: $KEYSRC (local file - verified once, good)" ;;
  http*)    echo "  repo gpgkey: $KEYSRC"
            echo "     Note: fetched over the network at install time. Staging it at"
            echo "     /etc/pki/rpm-gpg/ and using file:// is preferred on a gated host." ;;
  "")       echo "  (no gpgkey line - is gpgcheck enabled?)" ;;
esac
GPGCHECK=$(awk -F= '/^gpgcheck/{gsub(/ /,"",$2);print $2}' "$REPO_FILE" 2>/dev/null)
if [ "${GPGCHECK:-}" = "1" ]; then
  echo "  gpgcheck: 1"
else
  echo "  ** gpgcheck is '${GPGCHECK:-unset}' - packages are NOT signature-verified **"
fi

echo
echo "--- 2. Managed settings (authoritative policy) ---"
if [ -f "$MANAGED" ]; then
  echo "Path   : $MANAGED"
  echo "Mode   : $(stat -c '%a %U:%G' "$MANAGED")"
  echo "SHA256 : $(sha256sum "$MANAGED" | awk '{print $1}')"
  echo "Content:"
  # Pretty-print so a reviewer can read the effective policy in the record.
  python3 -m json.tool "$MANAGED" 2>/dev/null || cat "$MANAGED"
else
  echo "** NO MANAGED SETTINGS FILE - host is unpoliced **"
fi

echo
echo "--- 3. Policy lock keys in force ---"
# These are the keys that stop a user widening the policy. An absent key is the
# finding, so distinguish the three states explicitly: NO POLICY FILE (nothing is
# enforced), UNPARSEABLE (the file exists but Claude Code stripped entries), and
# <unset> (file is fine, this particular lock was simply not configured).
if [ ! -f "$MANAGED" ]; then
  echo "  ** NO POLICY FILE - none of the lock keys below are in force **"
elif ! python3 -c 'import json,sys;json.load(open(sys.argv[1]))' "$MANAGED" 2>/dev/null; then
  echo "  ** POLICY FILE UNPARSEABLE - Claude Code strips invalid entries; treat every"
  echo "     lock below as NOT in force until the JSON is fixed **"
else
  python3 - "$MANAGED" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
top = ["allowManagedPermissionRulesOnly", "allowManagedHooksOnly",
       "allowManagedMcpServersOnly", "allowedMcpServers", "disableSideloadFlags",
       "strictPluginOnlyCustomization", "disableClaudeAiConnectors",
       "forceLoginOrgUUID", "requiredMinimumVersion"]
# disableAutoMode is deliberately NOT in this list. Leaving it unset is the
# intended posture: auto mode runs after the permission system, so the deny rules
# still hold, and disabling it just drives users toward bypass. Its state is
# reported below as information, not as a missing control.
perms = ["defaultMode", "disableBypassPermissionsMode"]
missing = []
for k in top:
    v = d.get(k, "<unset>")
    if v == "<unset>":
        missing.append(k)
    print(f"  {k:<34} {json.dumps(v)}")
p = d.get("permissions", {})
for k in perms:
    v = p.get(k, "<unset>")
    if v == "<unset>":
        missing.append("permissions." + k)
    print(f"  permissions.{k:<22} {json.dumps(v)}")

# Informational, with the intent spelled out either way.
dam = p.get("disableAutoMode", "<unset>")
if dam == "<unset>":
    print("  permissions.disableAutoMode        <unset> - auto mode ENABLED (intended;")
    print("                                     deny rules still apply beneath it)")
else:
    print(f"  permissions.disableAutoMode        {json.dumps(dam)} - auto mode DISABLED. Expect")
    print("                                     prompt fatigue and pressure for bypass;")
    print("                                     confirm this is deliberate")
if missing:
    print()
    print("  ** NOT SET (%d): %s" % (len(missing), ", ".join(missing)))
    print("     Each is a control you intended but do not have. Confirm deliberate.")

# Unreplaced template placeholders are the classic way a policy reaches production
# looking configured while enforcing nothing.
MARKERS = ("REPLACE-WITH", "REPLACE_WITH", "REPLACEWITH", "TODO", "FIXME", "CHANGEME")

def placeholders(node, path=""):
    if isinstance(node, dict):
        for k, v in node.items():
            # _comment_* keys are documentation for the reader, not policy values.
            # They often quote words like "REPLACES", so scanning them is noise.
            if k.startswith("_comment"):
                continue
            yield from placeholders(v, f"{path}.{k}" if path else k)
    elif isinstance(node, list):
        for i, v in enumerate(node):
            yield from placeholders(v, f"{path}[{i}]")
    elif isinstance(node, str):
        up = node.upper()
        if any(mk in up for mk in MARKERS) or node.startswith("<"):
            yield path, node

found = list(placeholders(d))
if found:
    print()
    print("  ** UNREPLACED PLACEHOLDERS (%d) - policy is NOT production ready:" % len(found))
    for p, v in found:
        print(f"       {p} = {v}")

# Outbound data controls. /feedback is the highest-risk one - conversation history
# including code, optionally a public GitHub issue - and the umbrella nonessential-traffic
# variable is NOT documented as covering it, so report each key on its own.
print()
print("  --- outbound data controls (env) ---")
envb = d.get("env", {})
EGRESS = [
    ("DISABLE_FEEDBACK_COMMAND", "/feedback, /bug, /share - code + public GitHub issue, 5yr"),
    ("CLAUDE_CODE_DISABLE_FEEDBACK_SURVEY", "transcript + session log upload, 6mo"),
    ("DISABLE_TELEMETRY", "usage metrics"),
    ("DISABLE_ERROR_REPORTING", "error reports"),
    ("CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC", "umbrella; does NOT cover /feedback"),
]
unset_egress = []
for k, why in EGRESS:
    v = envb.get(k)
    if v in ("1", "true", "True", True):
        print(f"  {k:<42} off")
    else:
        unset_egress.append(k)
        print(f"  {k:<42} ** ON ** ({why})")
if unset_egress:
    print()
    print("  ** DATA EGRESS ENABLED (%d): %s" % (len(unset_egress), ", ".join(unset_egress)))
    print("     Each is a path for conversation content to leave this host. Confirm deliberate.")

# The sharpest footgun in the settings surface: setting any autoMode rule array
# without the literal "$defaults" REPLACES the built-in list for that field,
# silently discarding force-push, curl-pipe-to-bash, production-deploy and
# data-exfiltration protections. Report the state of every array explicitly.
am = d.get("autoMode")
if am is None:
    print()
    print("  autoMode                           <unset> - classifier runs with built-in defaults only")
else:
    print()
    print("  --- autoMode ---")
    bad = []
    for k in ("environment", "allow", "soft_deny", "hard_deny"):
        v = am.get(k)
        if v is None:
            print(f"  autoMode.{k:<25} <unset> (built-in defaults apply)")
        elif not isinstance(v, list):
            bad.append(k)
            print(f"  autoMode.{k:<25} ** NOT A LIST **")
        elif "$defaults" in v:
            print(f"  autoMode.{k:<25} {len(v)} entr{'y' if len(v)==1 else 'ies'}, includes $defaults")
        else:
            bad.append(k)
            print(f"  autoMode.{k:<25} {len(v)} entries, MISSING \"$defaults\"")
    cas = am.get("classifyAllShell", "<unset>")
    print(f"  autoMode.classifyAllShell         {json.dumps(cas)}")
    if bad:
        print()
        print("  ** MISSING \"$defaults\" (%d): %s" % (len(bad), ", ".join("autoMode." + b for b in bad)))
        print("     Each of these REPLACED the built-in rule list instead of extending it.")
        print("     soft_deny without $defaults discards force-push, curl|bash and")
        print("     production-deploy blocks; hard_deny without it discards the built-in")
        print("     data-exfiltration rule. Add \"$defaults\" unless this is deliberate.")
PY
fi

echo
echo "--- 4. Sandbox posture ---"
python3 - "$MANAGED" <<'PY' 2>/dev/null || echo "  (could not read sandbox block)"
import json,sys
try:
    d=json.load(open(sys.argv[1]))
except Exception:
    print("  (no managed settings)"); raise SystemExit
s=d.get("sandbox",{})
if not s:
    print("  ** sandbox not configured - Bash has unrestricted OS-level network and filesystem access **")
else:
    for k in ("enabled","failIfUnavailable","allowUnsandboxedCommands"):
        print(f"  {k:28} {json.dumps(s.get(k,'<unset>'))}")
    net=s.get("network",{})
    print(f"  network.strictAllowlist      {json.dumps(net.get('strictAllowlist','<unset>'))}")
    print(f"  network.allowManagedDomainsOnly {json.dumps(net.get('allowManagedDomainsOnly','<unset>'))}")
    doms=net.get("allowedDomains",[])
    print(f"  network.allowedDomains       {len(doms)} entr{'y' if len(doms)==1 else 'ies'}")
    for x in doms: print(f"      - {x}")
    fs=s.get("filesystem",{})
    print(f"  filesystem.allowManagedReadPathsOnly {json.dumps(fs.get('allowManagedReadPathsOnly','<unset>'))}")
    print(f"  filesystem.denyRead          {json.dumps(fs.get('denyRead',[]))}")
PY

echo
echo "--- 5. Sandbox runtime dependencies ---"
for b in bwrap socat; do
  p=$(command -v "$b" 2>/dev/null)
  printf '  %-8s %s\n' "$b" "${p:-NOT INSTALLED - sandbox cannot start}"
done
printf '  %-8s %s\n' "userns" "$(sysctl -n user.max_user_namespaces 2>/dev/null || echo unknown)"

echo
echo "--- 6. Accounts and credentials ---"
echo "  Audited $(wc -l < "$USERS_TMP" | tr -d ' ') account(s): homes under $CC_HOME_ROOT, plus local accounts housed elsewhere"
printf '  %-16s %-10s %-8s %s\n' USER CREDS MODE "LAST LOGIN WRITE"
while IFS=: read -r u h; do
  c="$h/.claude/.credentials.json"
  if [ -f "$c" ]; then
    printf '  %-16s %-10s %-8s %s\n' "$u" present "$(stat -c '%a' "$c")" "$(date -d "@$(stat -c %Y "$c")" '+%Y-%m-%d')"
  else
    printf '  %-16s %-10s %-8s %s\n' "$u" none - -
  fi
done < "$USERS_TMP"

echo
echo "--- 7. Unmanaged installs and local overrides ---"
while IFS=: read -r u h; do
  [ -e "$h/.local/bin/claude" ] && echo "  ** $u has a private native install at ~/.local/bin/claude **"
  [ -f "$h/.claude/settings.json" ] && echo "  $u has ~/.claude/settings.json ($(wc -c <"$h/.claude/settings.json") bytes)"
done < "$USERS_TMP"
[ -e /usr/lib/node_modules/@anthropic-ai/claude-code ] && echo "  ** global npm install present **"

echo
echo "--- 8. Effective diagnostics ---"
# Bounded: doctor reaches the network and can hang on a host with none, which
# would hang the whole audit with it.
# Captured in a variable, not a file: this runs as root, and any name derived
# from the temp list is one another account could pre-plant as a symlink.
doc_out=$(timeout "$CC_DOCTOR_TIMEOUT" claude doctor 2>&1 < /dev/null); drc=$?
[[ -n "$doc_out" ]] && printf '%s\n' "$doc_out" | sed 's/^/  /'
case "$drc" in
  0)   : ;;
  124) echo "  claude doctor did not finish within ${CC_DOCTOR_TIMEOUT}s - killed (CC_DOCTOR_TIMEOUT)" ;;
  *)   echo "  claude doctor unavailable in this context (exit $drc)" ;;
esac

echo
echo "=== end of audit ==="
} | tee "$OUT"
[ "${PIPESTATUS[1]}" -eq 0 ] || { echo "cc-audit.sh: the audit record $OUT is incomplete - writing it failed" >&2; exit 3; }

echo
echo "Audit written to: $OUT"
echo "Findings: $(grep -c '^ *\*\*' "$OUT") line(s) marked ** in the record"
exit 0
