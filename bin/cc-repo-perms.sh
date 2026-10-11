#!/usr/bin/env bash
# cc-repo-perms.sh - reassert this repository's ownership and modes.
#
# RUN THIS AFTER EVERY git pull, clone or merge that adds files.
#
# WHY IT IS NEEDED. Git records exactly one permission bit: owner-execute.
# It does not record the group, the setgid bit, or internal/'s 2770. So a pull
# that creates a new file gives it the puller's umask - typically 0644
# <you>:users - and a new directory loses the setgid bit that makes group
# inheritance work on a shared checkout. The visible symptom is another member
# of the repository group being unable to edit a file you just added; the
# invisible one is a findings document under internal/ quietly becoming
# world-readable, which on an NFS export that trusts client-asserted identity
# (sec=sys) means readable from any host that can mount it.
#
# Where there is no ACL tooling (an NFSv3 mount has no setfacl), the setgid bit
# is the entire group-inheritance mechanism. Keep it.
#
# WHAT IT SETS — the whole tree is group-only, no 'other' bits anywhere.
# Nothing in a Claude Code session reads this repository at runtime (sessions
# use the copies cc-install.sh placed under /etc and /usr/local), so there is
# no reason for any account outside the repository group to see it.
#   directories            2770 :CC_REPO_GROUP   setgid, group-only
#   internal/ and below    2770 :CC_REPO_GROUP   setgid, group-only
#   *.sh                    770                  group-executable
#   everything else         660
#   config.sh               660                  site config, group-only
#
#   cc-repo-perms.sh            report what would change, touch nothing
#   cc-repo-perms.sh --apply    make the changes
#
# Needs to be run by a member of CC_REPO_GROUP who owns the files, or by root.

set -uo pipefail

# Two trees, deliberately separate:
#   SELF_REPO - the checkout this script lives in, which is where its own
#               configuration and library come from. Never overridable.
#   REPO      - the tree whose modes are being fixed. CC_PERMS_TREE is a test
#               seam so the suite can point it at a fabricated tree, the same
#               pattern as CC_PROC elsewhere. It is not CC_REPO (the config's
#               shared checkout): this script fixes whichever checkout it is in.
#               Conflating the two would make the seam unusable, because a
#               fixture has no lib/ or config.sh.
SELF_REPO="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
REPO="${CC_PERMS_TREE:-$SELF_REPO}"
# Prefer the repo's own config: this script acts on the checkout, not the host.
CC_CONFIG="${CC_CONFIG:-$SELF_REPO/config.sh}"
[ -r "$CC_CONFIG" ] || CC_CONFIG=""
# shellcheck source=../lib/cc-config.sh
. "$SELF_REPO/lib/cc-config.sh"

APPLY=0
case "${1:-}" in
  --apply) APPLY=1 ;;
  ""|--check) ;;
  *) echo "usage: cc-repo-perms.sh [--check|--apply]" >&2; exit 2 ;;
esac

# --- 'other' access, before any refusal --------------------------------------
# Removing world access is right whatever the group, so it runs before the group
# checks below can refuse: on a host where the group does not resolve, a refusal
# that came first would leave internal/ world-readable. It covers .git as well, which the mode
# rules below skip, because .git/objects holds every revision of internal/.
# Only paths this account owns can change; chmod reports the rest.
world=$(find "$REPO" -perm /o=rwx -print 2>/dev/null | wc -l)
if [ "$world" -gt 0 ]; then
  if [ "$APPLY" -eq 1 ]; then
    chmod -R o-rwx "$REPO"
    echo "  stripped other-access from $world path(s)"
  else
    echo "  WOULD strip other-access from $world path(s)"
  fi
fi

if [ -z "$CC_REPO_GROUP" ]; then
  echo "ERROR  CC_REPO_GROUP is not set in $CC_CONFIG_SOURCE" >&2
  echo "       Set it to the group that should own this tree (see config.example.sh)." >&2
  exit 1
fi
if ! getent group "$CC_REPO_GROUP" >/dev/null 2>&1; then
  echo "ERROR  group '$CC_REPO_GROUP' does not resolve on this host." >&2
  echo "       Refusing to chgrp to a group that would land as a bare numeric GID." >&2
  exit 1
fi

# A membership check, because the failure is otherwise baffling: group
# membership is fixed at login, so a session that predates the group being
# created cannot use it even though `getent group` shows it.
if [ "$(id -u)" -ne 0 ] && ! id -nG | tr ' ' '\n' | grep -qx "$CC_REPO_GROUP"; then
  echo "ERROR  $(id -un) is not in '$CC_REPO_GROUP' in THIS session." >&2
  echo "       If you were added recently, log out and back in - credentials are" >&2
  echo "       fixed at login and a running shell never picks up a new group." >&2
  exit 1
fi

n=0
fix() {  # fix <target-mode> <path...>
  local mode="$1"; shift
  local p cur
  for p in "$@"; do
    cur=$(stat -c '%a' "$p" 2>/dev/null) || continue
    if [ "$((8#$cur))" -ne "$((8#$mode))" ]; then
      n=$((n+1))
      if [ "$APPLY" -eq 1 ]; then chmod "$mode" "$p"; else printf '  WOULD chmod %s %s (is %s)\n' "$mode" "$p" "$cur"; fi
    fi
  done
}

echo "Repo   : $REPO"
echo "Group  : $CC_REPO_GROUP"
echo "Mode   : $([ "$APPLY" -eq 1 ] && echo APPLY || echo 'CHECK (nothing will change)')"
echo

# --- group ownership --------------------------------------------------------
wrong_group=$(find "$REPO" -path "$REPO/.git" -prune -o \! -group "$CC_REPO_GROUP" -print 2>/dev/null | head -50)
if [ -n "$wrong_group" ]; then
  cnt=$(printf '%s\n' "$wrong_group" | wc -l)
  n=$((n+cnt))
  if [ "$APPLY" -eq 1 ]; then
    find "$REPO" -path "$REPO/.git" -prune -o \! -group "$CC_REPO_GROUP" -exec chgrp "$CC_REPO_GROUP" {} + 2>/dev/null
    echo "  chgrp $CC_REPO_GROUP: $cnt path(s)"
  else
    printf '%s\n' "$wrong_group" | sed "s|^|  WOULD chgrp $CC_REPO_GROUP |"
  fi
fi

# --- modes: general tree ----------------------------------------------------
# internal/ is excluded here and handled separately below.
while IFS= read -r -d '' d; do fix 2770 "$d"; done < <(
  find "$REPO" -path "$REPO/.git" -prune -o -path "$REPO/internal" -prune -o -type d -print0)
# Executable only where something is actually invoked: bin/, hooks/, share/,
# tests/ (by *.sh name), and githooks/ (by directory, because git requires
# exact names like `pre-commit` with no extension).
#
# NOT lib/cc-config.sh and NOT config*.sh - those are sourced, and a sourced
# file carrying the execute bit invites someone to run it directly, which
# silently does nothing useful.
#
# githooks/ is by-directory deliberately: matching on *.sh would have stripped
# the execute bit off every hook and disabled the pre-commit guard without a
# word. That is exactly the failure this script exists to prevent, so it is
# worth the special case.
# Matched at ANY depth, not just at the top level. aws/bin/cc-apply-posture.sh
# is the case that needs it: matched only at the top level, a *.sh under a
# nested bin/ would fall through to the 660 rule below and have its execute bit
# stripped by the very script that exists to protect execute bits. The rule is
# "a *.sh inside a directory named bin, hooks, share or tests, wherever that
# directory sits".
while IFS= read -r -d '' f; do fix 770 "$f"; done < <(
  find "$REPO" -path "$REPO/.git" -prune -o \
       -type f -name '*.sh' \
       \( -path '*/bin/*' -o -path '*/hooks/*' -o -path '*/share/*' -o -path '*/tests/*' \) \
       -print0)
if [ -d "$REPO/githooks" ]; then
  while IFS= read -r -d '' f; do fix 770 "$f"; done < <(find "$REPO/githooks" -type f -print0)
fi
while IFS= read -r -d '' f; do
  case "$f" in
    */bin/*.sh|*/hooks/*.sh|*/share/*.sh|*/tests/*.sh) continue ;;
    "$REPO"/githooks/*) continue ;;
    "$REPO"/config.sh) continue ;;   # handled below, group-only
  esac
  fix 660 "$f"
done < <(find "$REPO" -path "$REPO/.git" -prune -o -path "$REPO/internal" -prune -o -type f -print0)

# --- modes: internal/, group-only ------------------------------------------
# 2770/660, so the findings register and the deployment evidence are not
# readable by every account that can reach the checkout. The directory mode is what does the
# work: with no 'other' bits on internal/ itself, the file modes inside are
# unreachable regardless.
if [ -d "$REPO/internal" ]; then
  while IFS= read -r -d '' d; do fix 2770 "$d"; done < <(find "$REPO/internal" -type d -print0)
  while IFS= read -r -d '' f; do fix 660 "$f"; done < <(find "$REPO/internal" -type f -print0)
fi

# --- config.sh: site values, group-only ------------------------------------
[ -f "$REPO/config.sh" ] && fix 660 "$REPO/config.sh"

echo
if [ "$n" -eq 0 ]; then
  echo "Nothing to change - permissions are correct."
elif [ "$APPLY" -eq 1 ]; then
  echo "Corrected $n path(s)."
else
  echo "$n path(s) would change. Re-run with --apply."
fi
