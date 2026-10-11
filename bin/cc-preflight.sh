#!/usr/bin/env bash
# cc-preflight.sh - validate a Rocky Linux 8 host before deploying Claude Code.
# Run as root on the target instance. Exits non-zero if a hard blocker is found.

set -uo pipefail

# --- site configuration: config.sh through the loader --------------------------
# Before an install there is no /etc/claude-code yet; run from the checkout, the
# loader then reads its config.sh (or the template's sample values, and says so).
for _cfg in "${CC_CONFIG_LIB:-}" /etc/claude-code/cc-config.sh \
            "$(dirname "$(readlink -f "$0")")/../lib/cc-config.sh"; do
  [ -n "$_cfg" ] && [ -r "$_cfg" ] && { . "$_cfg" || exit 1; _cfg_loaded=1; break; }
done
[ "${_cfg_loaded:-0}" = 1 ] || { echo "cc-preflight.sh: cannot find cc-config.sh (looked in /etc/claude-code/ and ../lib/)" >&2; exit 1; }
unset _cfg _cfg_loaded
FAIL=0
WARN=0

ok()   { printf '  [ OK ]  %s\n' "$1"; }
warn() { printf '  [WARN]  %s\n' "$1"; WARN=$((WARN+1)); }
bad()  { printf '  [FAIL]  %s\n' "$1"; FAIL=$((FAIL+1)); }

echo "== Claude Code preflight: $(hostname -f 2>/dev/null || hostname) =="
echo

echo "-- Platform --"
if [ -r /etc/os-release ]; then
  . /etc/os-release
  echo "  Detected: ${PRETTY_NAME:-unknown}"
  case "${ID:-}${VERSION_ID:-}" in
    rocky8*|rhel8*|almalinux8*|centos8*) ok "RHEL 8 family - served by the Anthropic dnf repository" ;;
    rocky9*|rhel9*|almalinux9*)          ok "RHEL 9 family - served by the Anthropic dnf repository" ;;
    *) warn "Untested distribution for this runbook; validate manually" ;;
  esac
else
  bad "/etc/os-release not readable"
fi

# Architecture must be x86_64 or aarch64.
ARCH=$(uname -m)
case "$ARCH" in
  x86_64|aarch64) ok "Architecture $ARCH is supported" ;;
  *)              bad "Architecture $ARCH is not supported" ;;
esac

echo
echo "-- CPU and memory --"
# The native binary requires AVX on x86_64. EC2 instance families before ~2013
# equivalents, and some hypervisor configurations, do not expose it.
if [ "$ARCH" = "x86_64" ]; then
  if grep -qw avx /proc/cpuinfo; then
    ok "AVX instruction set present"
  else
    bad "AVX not exposed to this guest - the native binary will fail with 'Illegal instruction'"
  fi
fi

MEM_MB=$(awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo)
if [ "${MEM_MB:-0}" -ge 4096 ]; then
  ok "RAM ${MEM_MB} MB meets the 4 GB minimum"
else
  bad "RAM ${MEM_MB} MB is below the documented 4 GB minimum"
fi

# A shared multi-user workstation needs headroom per concurrent session.
NPROC=$(nproc)
echo "  Note: ${NPROC} vCPU, ${MEM_MB} MB RAM total. Budget ~2 GB per concurrent interactive session."

echo
echo "-- C library --"
LDD_OUT=$(ldd --version 2>&1 | head -1)
echo "  $LDD_OUT"
if echo "$LDD_OUT" | grep -qiE 'gnu libc|glibc'; then
  ok "glibc detected - the installer should select the glibc binary variant"
else
  warn "Non-glibc or unrecognised libc; confirm the correct binary variant is installed"
fi
# A stray musl cross-toolchain makes the installer misdetect the platform.
if ls /lib/libc.musl* >/dev/null 2>&1; then
  warn "musl libraries present on a glibc host - installer may pick the wrong variant"
fi

echo
echo "-- Sandbox dependencies (required only if sandbox.enabled is true) --"
for pkg in bubblewrap socat; do
  if command -v "${pkg/bubblewrap/bwrap}" >/dev/null 2>&1; then
    ok "$pkg present"
  else
    warn "$pkg not installed - run 'dnf install $pkg' ('dnf provides $pkg' names the repository that carries it)"
  fi
done
# Unprivileged user namespaces are what bubblewrap actually needs - but they are
# ALSO how a user with no sudo sheds the managed policy entirely, by bind-mounting
# their own file over managed-settings.json in a private namespace. So 0 is a
# blocker or a requirement depending ENTIRELY on whether the sandbox is enabled,
# and this probe must not assert one posture over the other:
#
#   sandbox enabled  -> 0 breaks every sandboxed command      (blocker)
#   sandbox disabled -> non-zero leaves the policy bypassable  (the boundary is
#                       gone; aws/sysctl.d/50-claude-code-userns.conf sets 0)
#
# The shipped policy disables the sandbox (docs/SANDBOX-DECISION.md), and there
# 0 is CORRECT: flagging it would fail an AMI build on the very condition the
# VDI design requires (docs/LOCAL-VS-AWS.md 8.2). The deployed policy is read
# rather than assumed, because a site may enable the sandbox and because this
# script also runs before the policy exists.
MAXNS=$(sysctl -n user.max_user_namespaces 2>/dev/null || echo unknown)
CC_POLICY_FILE="$CC_POLICY"
# THREE states, not two. An `if python3 …; then yes; else no; fi` maps a missing
# python3, an unparseable policy and a crash all onto "the sandbox is disabled" -
# and then prints a green "0 is correct with the sandbox disabled" while hiding a
# hard blocker. Exit 0 means enabled, 1 means disabled, and ANY other status
# (2 = could not parse, 127 = no python3) means unknown, which is reported as
# unknown. "Cannot tell" is never "fine".
SANDBOX_WANTED=unknown
if [ -r "$CC_POLICY_FILE" ] && command -v python3 >/dev/null 2>&1; then
  python3 -c "
import json,sys
try:
    s = (json.load(open(sys.argv[1])).get('sandbox') or {})
except Exception:
    sys.exit(2)
sys.exit(0 if s.get('enabled') else 1)" "$CC_POLICY_FILE" 2>/dev/null
  case "$?" in
    0) SANDBOX_WANTED=yes ;;
    1) SANDBOX_WANTED=no ;;
    *) SANDBOX_WANTED=unknown ;;
  esac
fi
if [ "$MAXNS" = "unknown" ]; then
  warn "Could not read user.max_user_namespaces"
elif [ "$MAXNS" = "0" ]; then
  case "$SANDBOX_WANTED" in
    yes) bad  "user.max_user_namespaces is 0 but the deployed policy enables the sandbox - bubblewrap cannot create a sandbox" ;;
    no)  ok   "user.max_user_namespaces = 0 - correct with the sandbox disabled; the policy cannot be shed in a user namespace" ;;
    *)   warn "user.max_user_namespaces is 0 and the deployed policy could not be read (absent, unparseable, or no python3) - correct if the sandbox stays disabled, a HARD BLOCKER if it is enabled. This check did not run; decide it by hand" ;;
  esac
else
  case "$SANDBOX_WANTED" in
    yes) ok   "user.max_user_namespaces = $MAXNS - bubblewrap can create a sandbox" ;;
    no)  warn "user.max_user_namespaces = $MAXNS with the sandbox disabled - any local user can bind-mount their own policy over $CC_POLICY_FILE and shed it; install aws/sysctl.d/50-claude-code-userns.conf" ;;
    *)   ok   "user.max_user_namespaces = $MAXNS" ;;
  esac
fi

echo
echo "-- Desktop session and browser (required for interactive OAuth login) --"
BROWSER_FOUND=0
for b in xdg-open firefox google-chrome chromium chromium-browser; do
  if command -v "$b" >/dev/null 2>&1; then ok "$b present"; BROWSER_FOUND=1; fi
done
[ "$BROWSER_FOUND" -eq 1 ] || bad "No browser or xdg-open found - users will be forced into the paste-the-code login flow"

echo
echo "-- Loopback --"
# The OAuth redirect returns to a short-lived listener on 127.0.0.1. Rather than
# parsing `ip addr` (which needs iproute2 and varies by version), bind a real
# socket the way Claude Code does - this tests the capability, not its description.
if python3 - <<'PY' >/dev/null 2>&1
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
s.listen(1)
s.close()
PY
then
  ok "Can bind a listener on 127.0.0.1 (OAuth callback will work)"
else
  bad "Cannot bind on 127.0.0.1 - browser login will fall back to the paste-the-code flow"
fi
if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
  LOZONE=$(firewall-cmd --get-zone-of-interface=lo 2>/dev/null || echo "")
  if [ "$LOZONE" = "trusted" ] || [ -z "$LOZONE" ]; then
    ok "firewalld does not restrict loopback"
  else
    warn "Loopback is in firewalld zone '$LOZONE' - confirm it permits local connections"
  fi
fi

echo
echo "-- Outbound connectivity --"
# Minimum set for install + login + inference. See the network section of the runbook
# for the full allowlist.
# Python, not curl: some endpoint protection products kill curl started from a
# shell as a "malicious file download", which reads a working host as unreachable.
# Any HTTP answer, an error status included, proves the endpoint is reachable.
for host in downloads.claude.ai api.anthropic.com claude.ai claude.com platform.claude.com; do
  if python3 - "https://${host}" >/dev/null 2>&1 <<'PY'
import sys, urllib.request, urllib.error
try:
    urllib.request.urlopen(urllib.request.Request(sys.argv[1], method="HEAD"), timeout=10)
except urllib.error.HTTPError:
    pass
PY
  then
    ok "https://${host} reachable"
  else
    bad "https://${host} NOT reachable - login or inference will fail"
  fi
done
[ -n "${HTTPS_PROXY:-}" ] && echo "  Note: HTTPS_PROXY is set to ${HTTPS_PROXY}"

echo
echo "-- Managed settings location --"
echo "  config: $CC_CONFIG_SOURCE"
if [ -d "$CC_ETC" ]; then
  ok "$CC_ETC exists"
  if [ -f "$CC_ETC/managed-settings.json" ]; then
    if command -v python3 >/dev/null 2>&1 && \
       python3 -c "import json,sys;json.load(open('$CC_ETC/managed-settings.json'))" 2>/dev/null; then
      ok "managed-settings.json is valid JSON"
    else
      bad "managed-settings.json is present but not valid JSON - entries will be stripped"
    fi
    PERM=$(stat -c '%a %U:%G' "$CC_ETC/managed-settings.json")
    echo "  Permissions: $PERM (expected 644 root:root)"
  else
    warn "No managed-settings.json yet - deploy it before opening the host to users"
  fi
else
  warn "$CC_ETC does not exist yet"
fi

echo
echo "== Summary: ${FAIL} failure(s), ${WARN} warning(s) =="
[ "$FAIL" -eq 0 ] || exit 1
exit 0
