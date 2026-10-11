#!/bin/bash
# cc-admin-session.sh - launch a privileged Claude Code session on a managed host.
#
# Gives ONE process tree a different managed policy by bind-mounting the admin
# policy FILE over /etc/claude-code/managed-settings.json inside a private mount
# namespace. Every other session on the host keeps reading the strict fleet policy;
# nothing on disk is modified, so the cc-install.sh checksum baseline and
# cc-healthcheck.sh both stay clean.
#
# The bind is file-over-file, not directory-over-directory, for two reasons:
#   1. claude runs as an unprivileged user, and a 0700 root directory bind-mounted
#      over /etc/claude-code makes the policy unreadable (EACCES on stat) because
#      the user cannot traverse it. Binding the file means traversal goes through
#      the normal 0755 /etc/claude-code and only the file's own 0644 mode applies -
#      so /etc/claude-code-admin can stay 0700 and unbrowsable.
#   2. The other contents of /etc/claude-code (approved-version, checksum baseline)
#      stay visible, so the cc-* operator scripts behave normally in the session.
#
# Install: /usr/local/sbin/cc-admin-session.sh, root:root, 0750.
# Run from a REAL terminal (RDP/SSH). Running it from inside a Claude Code
# session that is itself in a user namespace cannot work: root is remapped to
# nobody there, so setuid sudo refuses. (The sandbox's user namespace is one
# such; any enclosing user namespace does it.)
#
# Usage:   sudo cc-admin-session.sh [-u USER] [-e] [-n] [-- <claude args>]
#   -u USER   run claude as USER. MUST be the invoker (the default); any other
#             target, and uid 0, are refused - see "target-user policy" below.
#   -e        run CC_EVAL_BIN instead of the managed RPM (see below)
#   -n        dry run: show what would happen, mount nothing
#
# TARGET-USER POLICY. The agent always runs AS the invoker, never as root and
# never as another account. This is what keeps a command-scoped sudoers grant
# (%cc-admins ALL=(root) NOPASSWD: /usr/local/sbin/cc-admin-session.sh) from
# being equivalent to full root: without it, `-u root` would hand back an
# unrestricted root agent under the loose policy. Enforced for every session.
#
# -e: EVALUATING A NEWER BUILD.
# A pinned fleet needs somewhere to try the next version before it is approved,
# and PATH is the wrong place to do it - a personal build called `claude` in
# ~/.local/bin silently shadows the version-gated RPM for that user, outside
# dnf and outside the version gate. Instead the evaluation build is named
# explicitly in config.sh as CC_EVAL_BIN and reached only through this flag,
# so using it is a deliberate, logged act rather than an accident of PATH.
#
# Understand what this combines before using it: the NEWEST, least-tested build
# running under the LOOSEST policy on the host. That is the opposite of the
# fleet posture and is only defensible because it is deliberate, attributable in
# admin.log, and short-lived. Do not leave a session open in this mode.
#
# CC_EVAL_BIN may be a per-user build in a home directory or a shared root-owned
# path; both are accepted, and neither may be group- or world-writable. A shared
# path must be root-owned, because one engineer's writable binary is what every
# other admin would then be running.
#
set -euo pipefail

# Every refusal reaches the log, through die(), whether or not the gate that
# refused called stamp() itself. A privileged launcher that refuses silently leaves the operator and
# the auditor with the same evidence: none. stamp() is defined below and is a
# no-op until then, which is why it is guarded.
die() {
  echo "cc-admin-session: $*" >&2
  if declare -F stamp >/dev/null 2>&1; then stamp "REFUSED reason=die msg=$*"; fi
  exit 1
}

# --- site configuration -----------------------------------------------------
# Paths and the authorisation list come from config.sh via the loader. See
# lib/cc-config.sh for the search order; on a deployed host it resolves to
# /etc/claude-code/config.sh, and the repo is not involved.
#
# WHO MAY OPEN A PRIVILEGED SESSION is CC_ADMIN_GROUP / CC_ADMIN_USERS. That is
# a second gate on top of sudo, not a substitute for it: anyone with
# unrestricted sudo can already edit the fleet policy directly, so the list
# exists to stop a NARROW, command-scoped sudo grant being widened by accident,
# and to make authorised use attributable in admin.log.
#
# No other CC_* from the caller's environment may steer a privileged launcher,
# so all are cleared except the two that choose the config file and loader -
# kept for the test suite. sudo's default env_reset strips those too, so on a
# real escalation only the installed config is read.
for _v in ${!CC_@}; do
  case "$_v" in CC_CONFIG|CC_CONFIG_LIB) ;; *) unset "$_v" ;; esac
done
unset _v
for _cfg in "${CC_CONFIG_LIB:-}" /etc/claude-code/cc-config.sh \
            "$(dirname "$(readlink -f "$0")")/../lib/cc-config.sh"; do
  [ -n "$_cfg" ] && [ -r "$_cfg" ] && { . "$_cfg" || die "config incomplete - see the message above"; _cfg_loaded=1; break; }
done
[ "${_cfg_loaded:-0}" = 1 ] || die "cannot find cc-config.sh (looked in /etc/claude-code/ and ../lib/)"
unset _cfg _cfg_loaded

ADMIN_POLICY_DIR="$CC_ETC_ADMIN"
ADMIN_POLICY="$CC_ADMIN_POLICY"
FLEET_POLICY="$CC_POLICY"
CLAUDE_BIN="$CC_CLAUDE_BIN"
ADMIN_LOG="$CC_ADMIN_LOG"
ADMIN_GROUP="$CC_ADMIN_GROUP"
ADMIN_USERS=("${CC_ADMIN_USERS[@]+"${CC_ADMIN_USERS[@]}"}")

# --- audit stamp -------------------------------------------------------------
# Defined here, before any gate, so that EVERY refusal can be recorded. A refusal
# that leaves no trace is the one an audit cannot see, and the refusals below are
# the attempted-misuse cases most worth having on record.
#
# ONE line shape for this file: field order is fixed and every line carries the
# same keys, so `awk -F'[ =]'` over admin.log does not need to know which kind of
# line it is looking at. Callers pass only the trailing message - never repeat
# invoker= or target=, they are emitted here.
stamp() {
  # Every field is neutralised before it is written: -u is caller-controlled,
  # and a newline in it (or in a die() message quoting it) would otherwise
  # write a second, forged record. Account fields keep only name characters;
  # the message keeps its spaces and loses control characters.
  local msg="${1//[[:cntrl:]]/?}" tty_val inv="${SUDO_USER:-root}" tgt="${RUN_AS:-unset}"
  inv="${inv//[^A-Za-z0-9._@-]/?}"; tgt="${tgt//[^A-Za-z0-9._@-]/?}"
  # `tty` prints "not a tty" on STDOUT and exits non-zero when there is no
  # controlling terminal, so `$(tty || echo none)` captures BOTH strings - the
  # result carries spaces and an embedded newline, which splits the record in two
  # and shifts every field after it. Assign-then-default keeps one token, so
  # every line in this file has the same field positions even for a
  # non-interactive invocation, which is exactly when the audit trail matters.
  tty_val=$(tty 2>/dev/null) || tty_val=none
  # The log lives under /var/log/claude-code and only root can write it. A
  # non-root invocation is refused by the gate below anyway, so attempting the
  # write would only emit a confusing "Permission denied" over the real refusal
  # message. Root must never fail silently, though: if the append fails AS ROOT,
  # say so, because that means the audit trail is not being written.
  [ "$(id -u)" -eq 0 ] || return 0
  mkdir -p "$(dirname "$ADMIN_LOG")" 2>/dev/null
  # 0640, root-only to read: the file says who held privilege and when. The
  # root umask would create it 0644, and a later chmod narrows a file already out there.
  ( umask 027
    printf '%s pid=%s invoker=%s target=%s tty=%s %s\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$$" "$inv" "$tgt" \
      "$tty_val" "$msg" >>"$ADMIN_LOG" ) \
    || echo "cc-admin-session: WARNING: could not write $ADMIN_LOG - this session is unaudited" >&2
  chmod 0640 "$ADMIN_LOG" 2>/dev/null
}

RUN_AS="${SUDO_USER:-}"
DRY=0
EVAL=0
while getopts ":u:ne" opt; do
  case "$opt" in
    u) RUN_AS="$OPTARG" ;;
    n) DRY=1 ;;
    e) EVAL=1 ;;
    *) die "usage: cc-admin-session.sh [-u USER] [-e] [-n] [-- <claude args>]" ;;
  esac
done
shift $((OPTIND - 1))
[[ "${1:-}" == "--" ]] && shift

# --- preconditions -----------------------------------------------------------
[[ $EUID -eq 0 ]] || die "must run as root (use sudo, from a real terminal)"
[[ -n "$RUN_AS" ]] || die "cannot determine target user; pass -u USER"

# --- who, then what ----------------------------------------------------------
# Both gates below are cheap (string compares and two directory lookups) and run
# before every filesystem, JSON and NFS check, for two reasons: a command-scoped
# sudoers grant treats them as its hard preconditions, so they must not be
# reachable only via unrelated state such as the admin policy's directory mode;
# and each writes its own admin.log line, so an attempt is recorded before
# anything else can fail first and mask it.
#
# Order is deliberate: authorisation ("may this person open a session at all?")
# precedes the target-user policy ("is the requested target legal?"). An
# unauthorised invoker passing -u root must be logged as unauthorised, which is
# the more serious fact, rather than as a target-user violation.
INVOKER="${SUDO_USER:-root}"

# AUTHORISATION GATE. Checked against the INVOKER, not the target of -u, so that
# granting someone the ability to run this is a deliberate act.
authorised=0
# +expansion form: an empty CC_ADMIN_USERS must not trip `set -u`. An empty
# list combined with a CC_ADMIN_GROUP that does not resolve means NOBODY is
# authorised — fail closed, which is the correct direction for this gate.
for u in "${ADMIN_USERS[@]+"${ADMIN_USERS[@]}"}"; do
  [[ "$INVOKER" == "$u" ]] && authorised=1
done
if [[ $authorised -eq 0 ]] && getent group "$ADMIN_GROUP" >/dev/null 2>&1; then
  id -nG "$INVOKER" 2>/dev/null | tr ' ' '\n' | grep -qx "$ADMIN_GROUP" && authorised=1
fi
if [[ $authorised -eq 0 ]]; then
  stamp "REFUSED reason=unauthorised group=$ADMIN_GROUP"
  die "$INVOKER is not authorised for a privileged session (needs group $ADMIN_GROUP)"
fi

# Only now is -u looked up: before the gate, the difference between "no such
# user" and any other refusal told an unauthorised caller which accounts exist.
# The shape check keeps anything that is not an account name away from getent
# and out of every message below.
[[ "$RUN_AS" =~ ^[A-Za-z0-9._][A-Za-z0-9._@-]*$ ]] || die "-u is not a valid account name"
getent passwd "$RUN_AS" >/dev/null || die "no such user: $RUN_AS (sss/ldap lookup failed)"

# TARGET-USER POLICY. The agent runs AS the invoker: never uid 0, never another
# account. Without this, `-u root` turns a one-command sudoers allowlist entry
# back into unrestricted root, because the loose admin policy permits sudo inside
# the session. Admin commands are run via sudo FROM WITHIN the session instead.
# Reproducing another user's problem as that user is a real need, but it is a
# separate, explicitly-gated capability - not a side effect of -u - and is not
# provided here.
target_uid=$(getent passwd "$RUN_AS" | head -1 | cut -d: -f3)   # head -1: a duplicate NSS entry (local + LDAP) would otherwise return two lines and the uid-0 test would silently not match
if [[ "$target_uid" == 0 ]]; then
  stamp "REFUSED reason=uid0"
  die "refusing to run the agent as root (uid 0): an admin session is not a root shell"
fi
if [[ "$RUN_AS" != "$INVOKER" ]]; then
  stamp "REFUSED reason=impersonation"
  die "-u $RUN_AS refused: an admin session runs as the invoker ($INVOKER), not another account"
fi

[[ -d "$ADMIN_POLICY_DIR" ]] || die "$ADMIN_POLICY_DIR missing - install the admin policy first"
[[ -f "$ADMIN_POLICY" ]] || die "$ADMIN_POLICY missing"
[[ -f "$FLEET_POLICY" ]] || die "$FLEET_POLICY missing - is the fleet policy deployed?"
[[ -x "$CLAUDE_BIN" ]] || die "$CLAUDE_BIN missing - the managed RPM is not installed"

# --- -e: select the evaluation binary ---------------------------------------
BIN_LABEL="managed RPM"
if [[ $EVAL -eq 1 ]]; then
  [[ -n "${CC_EVAL_BIN:-}" ]] || die "-e given but CC_EVAL_BIN is not set in $CC_CONFIG_SOURCE"
  # No -u check here: the target-user policy above already guarantees
  # RUN_AS == INVOKER for every session, so running one user's binary as another
  # is unreachable. Duplicating it here would only shadow that refusal with a
  # message blaming the eval binary for what is a target-user violation.
  [[ -f "$CC_EVAL_BIN" && -x "$CC_EVAL_BIN" ]] || die "CC_EVAL_BIN=$CC_EVAL_BIN is not an executable file"
  # The binary is only as safe as every directory above it: a writable parent
  # lets another account rename a different binary into place between this
  # check and the exec, and a symlink can be re-pointed. So the path is resolved
  # once, every parent up to / is checked, and the RESOLVED path is what runs.
  # A sticky world-writable directory (/tmp) is accepted: there only an entry's
  # owner can rename it, and each entry below it is owner-checked in turn.
  ereal=$(readlink -f -- "$CC_EVAL_BIN") || die "CC_EVAL_BIN=$CC_EVAL_BIN cannot be resolved"
  edir=$(dirname -- "$ereal")
  while :; do
    read -r dbits downer < <(stat -c '%a %U' -- "$edir") || die "cannot stat $edir"
    if [[ "$downer" != root && "$downer" != "$RUN_AS" ]]; then
      die "CC_EVAL_BIN parent directory $edir is owned by $downer, not $RUN_AS or root"
    fi
    if (( 8#$dbits & 8#022 )) && ! (( 8#$dbits & 8#1000 )); then
      die "CC_EVAL_BIN parent directory $edir is mode $dbits - group/world writable, so another account could swap the binary"
    fi
    [[ "$edir" == / ]] && break
    edir=$(dirname -- "$edir")
  done
  # Group- or world-writable means somebody else could swap what runs here.
  # Owner-writable is expected and fine - it is the owner's own build.
  ebits=$(stat -Lc '%a' "$CC_EVAL_BIN")
  if (( 8#$ebits & 8#022 )); then
    die "CC_EVAL_BIN=$CC_EVAL_BIN is mode $ebits - group/world writable, so another account could replace it"
  fi
  eowner=$(stat -Lc '%U' "$CC_EVAL_BIN")
  if [[ "$eowner" != "$RUN_AS" && "$eowner" != "root" ]]; then
    die "CC_EVAL_BIN=$CC_EVAL_BIN is owned by $eowner, not $RUN_AS or root"
  fi
  CLAUDE_BIN="$ereal"
  BIN_LABEL="EVALUATION BUILD (unmanaged, outside dnf and the version gate)"
fi

# The admin policy directory must stay unbrowsable: it is the one place on the
# host that documents how to obtain an unsandboxed session. The POLICY FILE itself
# must be world-readable, because claude reads it as the unprivileged target user
# through the bind mount - the 0700 directory is what keeps it out of reach by
# any other path.
dperms=$(stat -c '%a %U' "$ADMIN_POLICY_DIR")
[[ "$dperms" == "700 root" ]] || die "$ADMIN_POLICY_DIR must be 0700 root (is: $dperms)"
fperms=$(stat -c '%a %U %G' "$ADMIN_POLICY")
[[ "$fperms" == "644 root root" ]] || die "$ADMIN_POLICY must be 0644 root root (is: $fperms)"

python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$ADMIN_POLICY" \
  || die "admin policy is not valid JSON - refusing to start"

# HOME must be the real path. Where the directory service publishes a home that
# is a symlink, a mount namespace tool cannot mount through it (the same reason
# as profile.d/claude-code-home.sh), so the passwd entry is resolved here.
REAL_HOME=$(getent passwd "$RUN_AS" | head -1 | cut -d: -f6)
REAL_HOME=$(readlink -f "$REAL_HOME")
[[ -d "$REAL_HOME" ]] || die "resolved home $REAL_HOME does not exist"

if [[ $DRY -eq 1 ]]; then
  echo "DRY RUN"
  echo "  would bind-mount $ADMIN_POLICY over $FLEET_POLICY in a private mount ns"
  echo "  would run: $CLAUDE_BIN $* as $RUN_AS (HOME=$REAL_HOME)"
  echo "  binary   : $BIN_LABEL"
  echo "  fleet policy on disk is untouched either way"
  exit 0
fi

cat <<EOF

  *** PRIVILEGED CLAUDE CODE SESSION ***
  binary          : $CLAUDE_BIN
                    $BIN_LABEL
  user            : $RUN_AS
  home            : $REAL_HOME
  invoker         : $INVOKER
  policy          : $ADMIN_POLICY (bind-mounted over $FLEET_POLICY, this process tree only)
  sandbox         : OFF  - no filesystem isolation, no network allowlist
  admin commands  : PERMITTED - sudo, dnf, systemctl, rpm are not denied
  logged to       : $ADMIN_LOG and $CC_ACTIVITY_LOG_DIR/

  Other users' sessions on this host are unaffected.
  Exit the session as soon as the administrative task is done.

EOF

stamp "admin session START bin=$CLAUDE_BIN eval=$EVAL"
# NOT `exec` below, and the trap is the reason. `exec` replaces this shell, which
# discards the EXIT trap - so a launcher that exec'd would record a START for
# every session and an END for none, and session DURATION would not be
# auditable. Keeping the wrapper
# alive costs one idle shell per admin session and buys the other half of the
# record. The child's ancestry is unchanged (unshare -> runuser -> claude), which
# is what cc-update.sh's session sweep keys on.
trap 'stamp "admin session END rc=$?"' EXIT

# --propagation private: the bind is invisible outside this namespace and cannot
# leak back to the host mount table.
# unshare -m takes a MOUNT namespace only - deliberately NOT --user, because a
# user namespace is exactly what remaps root to nobody and breaks setuid sudo.
unshare --mount --propagation private -- \
  /bin/bash -c '
    set -euo pipefail
    mount --bind "$1" "$2"
    exec runuser -u "$3" -- env HOME="$4" "$5" "${@:6}"
  ' _ "$ADMIN_POLICY" "$FLEET_POLICY" "$RUN_AS" "$REAL_HOME" "$CLAUDE_BIN" "$@"
exit $?
