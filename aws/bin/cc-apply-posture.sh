#!/bin/bash
# cc-apply-posture.sh - choose this instance's Claude Code policy at boot.
#
# Install: /usr/local/sbin/cc-apply-posture.sh, root:root, 0750.
#
# [PLANNED - designed for the AWS VDI, NOT yet validated on an AMI. See the
# grading warning at the top of docs/LOCAL-VS-AWS.md.]
#
# A VDI is single-tenant, so POSTURE IS A PROPERTY OF THE INSTANCE, chosen once
# at boot by the provisioning system - never switched at runtime by the user, who
# has no sudo. This runs as root from claude-code-posture.service, ordered before
# any user can log in, and installs one of two staged policies over the per-host
# file the product reads.
#
# It replaces the shared-host cc-admin-session.sh bind-mount for the DEFAULT
# posture only: on a single-user box there is no "other users" to protect, so the
# instance runs the policy it was provisioned with. cc-admin-session.sh still
# ships on the ADMIN AMI, because an admin needs BOTH policies reachable on one
# box - the strict one to audit a new build against the rules, the loose one to
# do the work. Admin VDIs therefore boot the FLEET posture and escalate per
# session; see docs/LOCAL-VS-AWS.md §8.3.
#
# POSTURE SOURCE, value "fleet" or "admin":
#   $CC_ETC/posture - a one-word file, written by cloud-init user-data
#                     (write_files, which lands no later than cloud-config).
#   The EC2-tag/SSM alternative needs an instance profile - see READ_TAG below.
#
# PATHS COME FROM THE BAKED CONFIG. The AMI build runs cc-install.sh, which
# places config.sh and the loader in /etc/claude-code beside the staged
# policies, so at boot both are on the image. The posture is a separate one-word
# file; config.sh describes where things are, not which posture to take. An
# image baked without config.sh FAILS this unit (below) rather than guessing
# paths - the same outcome as an unusable fleet policy, and visible as a failed
# unit at first boot. The suite exports each path to fabricate failure paths
# without root.
#
# FAIL CLOSED: anything unexpected - posture file missing or unreadable, unknown
# value, staged policy absent, not valid JSON, or not matching its baked
# checksum - installs the FLEET policy. The loose posture is never reached by
# accident. If the FLEET policy itself is unusable the unit FAILS rather than
# leaving the instance with no policy, because no policy is fail-OPEN and is the
# one outcome worse than the wrong policy.
set -euo pipefail

# --- site configuration: config.sh through the loader --------------------------
for _cfg in "${CC_CONFIG_LIB:-}" /etc/claude-code/cc-config.sh \
            "$(dirname "$(readlink -f "$0")")/../../lib/cc-config.sh"; do
  if [ -n "$_cfg" ] && [ -r "$_cfg" ]; then
    . "$_cfg" || { echo "cc-apply-posture: config incomplete - no posture applied" >&2; exit 1; }
    _cfg_loaded=1; break
  fi
done
[ "${_cfg_loaded:-0}" = 1 ] || { echo "cc-apply-posture: cannot find cc-config.sh - no posture applied" >&2; exit 1; }
unset _cfg _cfg_loaded

STAGE="${CC_POSTURE_STAGE:-$CC_SHARE/policies}"  # both policies, baked into the AMI
TARGET="$CC_ETC/managed-settings.json"           # the path the product reads (fixed)
BASELINE="$TARGET.sha256"                        # what cc-healthcheck.sh §2 compares
POSTURE_FILE="$CC_ETC/posture"
LOG="$CC_LOGDIR/posture.log"

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" | tee -a "$LOG" >&2; }
die() { log "FATAL $*"; exit 1; }

mkdir -p "$(dirname "$LOG")"

# --- resolve requested posture, defaulting to fleet -------------------------
want=fleet
if [[ -r "$POSTURE_FILE" ]]; then
  want=$(tr -d '[:space:]' < "$POSTURE_FILE" | tr '[:upper:]' '[:lower:]')
fi
# READ_TAG alternative (needs ec2:DescribeTags on an instance profile):
#   TOKEN=$(curl -s -X PUT http://169.254.169.254/latest/api/token \
#           -H 'X-aws-ec2-metadata-token-ttl-seconds: 60')
#   want=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
#          http://169.254.169.254/latest/meta-data/tags/instance/claude-posture)

case "$want" in
  fleet|admin) : ;;
  *) log "unknown posture '$want' - failing closed to fleet"; want=fleet ;;
esac

# --- pick a usable source, falling back to fleet ----------------------------
# A staged policy is usable only if it exists, parses, AND matches the checksum
# baked beside it at image-build time. The checksum is the whole point: without
# it this script would install whatever is staged and then certify it, so a
# tampered staging directory would self-approve on every boot.
usable() {
  local src="$1" sha="$1.sha256" want_sha have_sha
  [[ -f "$src" ]] || { log "$src missing"; return 1; }
  python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$src" 2>/dev/null \
    || { log "$src is not valid JSON"; return 1; }
  [[ -f "$sha" ]] || { log "$sha missing - staged policy has no baked checksum to verify against"; return 1; }
  want_sha=$(awk 'NR==1{print $1}' "$sha")
  have_sha=$(sha256sum "$src" | awk '{print $1}')
  [[ -n "$want_sha" ]] || { log "$sha holds no checksum"; return 1; }
  [[ "$want_sha" == "$have_sha" ]] \
    || { log "$src does not match its baked checksum (baked $want_sha, found $have_sha)"; return 1; }
  return 0
}

src="$STAGE/managed-settings.$want.json"
if ! usable "$src"; then
  [[ "$want" == fleet ]] && die "the fleet policy is unusable - refusing to boot with no policy"
  log "requested posture '$want' is unusable - failing closed to fleet"
  want=fleet
  src="$STAGE/managed-settings.fleet.json"
  usable "$src" || die "the fleet policy is unusable - refusing to boot with no policy"
fi

# --- install atomically ------------------------------------------------------
# Via a temp file on the SAME filesystem then mv, so an interruption (disk full,
# or SIGTERM at TimeoutStartSec) can never leave a truncated policy in place:
# claude strips unparseable entries, so a half-written file is a silently
# degraded policy rather than an obvious failure.
tmp="$TARGET.new.$$"
trap 'rm -f "$tmp"' EXIT
install -o root -g root -m 0644 "$src" "$tmp"
python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$tmp" \
  || die "staged copy did not survive the copy - refusing to install"
mv -f "$tmp" "$TARGET"

# The runtime baseline is the BAKED checksum, copied across - never recomputed
# from what was just written. Recomputing would make cc-healthcheck.sh §2 a
# tautology that always passes.
install -o root -g root -m 0644 "$src.sha256" "$BASELINE"

# --- post-install assertions -------------------------------------------------
[[ -f "$TARGET" ]] || die "post-install: $TARGET does not exist"
python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$TARGET" 2>/dev/null \
  || die "post-install: $TARGET is not valid JSON"
[[ "$(awk 'NR==1{print $1}' "$BASELINE")" == "$(sha256sum "$TARGET" | awk '{print $1}')" ]] \
  || die "post-install: $TARGET does not match the baseline just installed"

# The userns knob is what makes the policy a boundary rather than a guardrail on
# a box the user cannot be given sudo on (docs/LOCAL-VS-AWS.md §8.2). Assert it.
uns=$(cat /proc/sys/user/max_user_namespaces 2>/dev/null || echo unknown)
[[ "$uns" == 0 ]] || log "WARNING user.max_user_namespaces=$uns (expected 0) - the managed policy is bypassable by any local user; check /etc/sysctl.d/50-claude-code-userns.conf"

log "posture applied: $want  source=$(basename "$src")  sha=$(awk 'NR==1{print $1}' "$BASELINE")  userns=$uns"
