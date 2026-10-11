#!/usr/bin/env bash
# cc-install.sh - idempotent deployment of the Claude Code IT control plane.
#
# What it DOES:   places the policy, site config, operator scripts, hooks, status
#                 line, profile.d drop-ins, resource limits, systemd units and
#                 logrotate config; records the integrity baseline; enables the
#                 three timers; verifies every placement.
# What it DOESN'T: install or upgrade the claude-code RPM. That is a gated change;
#                 use cc-update.sh. This script only deploys the control plane
#                 around it, so it is safe to re-run.
#
#   cc-install.sh --check              dry run: report what would change, touch nothing
#   cc-install.sh --apply              do it (root only)
#     --with-admin                     also install the privileged-session policy AND
#                                      the cc-admin-session.sh launcher - neither is
#                                      placed without this flag
#     --remove-admin                   take the privileged session (policy and
#                                      launcher) off a host that has it; an apply
#                                      with neither flag refuses on such a host
#     --with-ide                       also seed the VSCodium defaults that point the
#                                      Claude extension at the managed CLI
#   cc-install.sh --gates-only         run the policy gates and stop (make quickstart)
#
# An apply holds the control lock ($CC_ETC/.cc-control.lock, shared with
# cc-update.sh), places the policy LAST - after everything it names - and stops
# at the first failed step with the old policy still in force. Each file it
# replaces or removes is kept in $CC_LOGDIR/install-backup/last, and a complete
# apply writes $CC_ETC/install-record: the commit it came from and every file
# it placed, which the next apply reads to remove what the repository dropped.
#
# Refuses to apply while the policy contains template placeholders, and refuses
# if the policy's hook or status-line paths disagree with config.sh - a mismatch
# there means the hooks are registered at a path nothing was installed to, which
# looks configured and enforces nothing.

set -uo pipefail

# --- source tree and site configuration -------------------------------------
SRC="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
[ -r "$SRC/lib/cc-config.sh" ] || { echo "ERROR  $SRC/lib/cc-config.sh missing - is this a full checkout?" >&2; exit 1; }
# Prefer the repo's config when installing: this script's job is to push the
# checkout's intent onto the host, so the checkout must win over the copy the
# host already has. That is the opposite of every other cc-* script.
CC_CONFIG="${CC_CONFIG:-$SRC/config.sh}"
if [ ! -r "$CC_CONFIG" ]; then
  cat >&2 <<EOF
ERROR  no site configuration found at $CC_CONFIG

  This repository ships config.example.sh, not config.sh - the real one is
  gitignored so the tree carries no site detail. Create it:

      cp $SRC/config.example.sh $SRC/config.sh
      \${EDITOR:-vi} $SRC/config.sh

EOF
  exit 1
fi
# shellcheck source=../lib/cc-config.sh
. "$SRC/lib/cc-config.sh" || { echo "ERROR  $CC_CONFIG cannot be used - fix it before installing (the loader says why, above)" >&2; exit 1; }

RPM_BIN="${CC_RPM_BIN:-rpm}"

# installed_version - the version this host would RUN, or empty for "cannot
# tell". Never conflate the two: "unknown" treated as "fine" is how a check
# reports healthy without having examined anything.
#
# rpm FIRST, binary second. The package database is the managed truth: it needs
# no vendor code to execute, it is immune to a private ~/.local/bin/claude
# winning PATH, and it still
# answers when the binary refuses to start - which is the exact state gate 5
# exists to prevent. `rpm -q --qf` prints "package claude-code is not installed"
# on STDOUT with exit 1, so 2>/dev/null does not suppress it and the sentence
# itself would become the "version" without the shape check.
# cc-healthcheck.sh [1]'s `claude --version | awk '{print $1}'` is the form NOT
# to copy: it trusts PATH, has no timeout, and takes a field by position.
installed_version() {
  local v=""
  if v=$("$RPM_BIN" -q --qf '%{VERSION}' "$CC_PKG" 2>/dev/null); then
    case "$v" in ""|*[!0-9.]*) v="" ;; esac
  else
    v=""
  fi
  if [ -z "$v" ] && [ -x "$CC_CLAUDE_BIN" ]; then
    v=$(timeout 15 "$CC_CLAUDE_BIN" --version 2>/dev/null \
          | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)
  fi
  printf '%s' "$v"
}

# The floor a policy FILE would enforce; empty means "cannot tell".
policy_floor_of() {
  python3 -c '
import json, sys
try:
    print(json.load(open(sys.argv[1])).get("requiredMinimumVersion") or "")
except Exception:
    print("")' "$1" 2>/dev/null
}

# True when $1 is strictly below $2, by rpm/dnf ordering - a string compare
# would say 2.1.36 > 2.1.236.
version_below() { [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)" = "$1" ] && [ "$1" != "$2" ]; }

MODE="--check"; WITH_ADMIN=0; REMOVE_ADMIN=0; WITH_IDE=0; ALLOW_BELOW_FLOOR=0; GATES_ONLY=0
for a in "$@"; do
  case "$a" in
    --check|--apply)  MODE="$a" ;;
    --gates-only)     GATES_ONLY=1 ;;
    --with-admin)     WITH_ADMIN=1 ;;
    --remove-admin)   REMOVE_ADMIN=1 ;;
    --with-v2-slices)
       echo "note: --with-v2-slices is not supported. The one slice drop-in this" >&2
       echo "installer places is valid on both cgroup generations, so drop the option." >&2
       echo "Continuing without it." >&2 ;;
    --with-ide)       WITH_IDE=1 ;;
    --allow-below-floor) ALLOW_BELOW_FLOOR=1 ;;
    *) echo "unknown argument: $a" >&2
       echo "usage: cc-install.sh [--check|--apply|--gates-only] [--with-admin|--remove-admin] [--with-ide] [--allow-below-floor]" >&2
       exit 2 ;;
  esac
done
if [ "$WITH_ADMIN" -eq 1 ] && [ "$REMOVE_ADMIN" -eq 1 ]; then
  echo "--with-admin and --remove-admin contradict each other - pass one" >&2; exit 2
fi
if [ "$GATES_ONLY" -eq 1 ] && [ "$MODE" = "--apply" ]; then
  echo "--gates-only places nothing - it cannot be combined with --apply" >&2; exit 2
fi
DRY=1; [ "$MODE" = "--apply" ] && DRY=0

# place() decides "current" and verifies every copy with cmp. Without it each
# compare fails, so --check calls current files stale and --apply reports every
# copy as corrupt ("does not match its source") - a corruption alarm for a
# missing tool. A minimal image (Rocky 8 container) ships without diffutils.
command -v cmp >/dev/null 2>&1 || {
  echo "ERROR  cc-install.sh needs cmp (package diffutils) to compare and verify what it places - install it and rerun" >&2
  exit 1
}
ERRORS=0; WARNS=0

say()  { printf '  %s\n' "$1"; }
act()  { if [ "$DRY" -eq 1 ]; then printf '  WOULD  %s\n' "$1"; else printf '  DO     %s\n' "$1"; fi; }
bad()  { printf '  ERROR  %s\n' "$1"; ERRORS=$((ERRORS+1)); }
warn() { printf '  WARN   %s\n' "$1"; WARNS=$((WARNS+1)); }

# Every destination this run manages, for the install record and the prune.
PLACED=()

# The files an apply replaces or removes are copied here first; a complete
# apply that changed anything turns .next into last. One generation, so the
# directory cannot grow without bound; a hand-edited policy is kept apart
# (hand-edited-*) and never rotated, because it is evidence.
BACKUP="$CC_LOGDIR/install-backup"
backup() {   # backup <file> - keep a copy before it is replaced or removed
  local f="$1"
  [ -f "$f" ] || return 0
  # $BACKUP is 0700, so what is created beneath it needs no mode of its own.
  install -d -m 0700 "$BACKUP" 2>/dev/null &&
    mkdir -p "$BACKUP/.next${f%/*}" 2>/dev/null &&
    cp -a "$f" "$BACKUP/.next$f" 2>/dev/null ||
    { bad "could not keep a copy of $f in $BACKUP/.next - not replacing it"; return 1; }
}
rotate_backup() {
  [ "$DRY" -eq 0 ] && [ -d "$BACKUP/.next" ] || return 0
  if [ -n "$(ls -A "$BACKUP/.next" 2>/dev/null)" ]; then
    rm -rf "$BACKUP/last" && mv "$BACKUP/.next" "$BACKUP/last" &&
      say "replaced and removed files kept in $BACKUP/last"
  else
    rmdir "$BACKUP/.next" 2>/dev/null
  fi
}

# src_commit - the commit the source tree is at, read from .git's files. Never
# by running git: as root, in a checkout a group writes, git would run that
# group's hooks and config. Prints "unknown" when the tree is not a plain clone.
src_commit() {
  local head ref c=""
  head=$(head -c 200 "$SRC/.git/HEAD" 2>/dev/null) || { echo unknown; return; }
  case "$head" in
    "ref: "*)
      ref=${head#ref: }
      case "$ref" in *..*|/*) echo unknown; return ;; esac
      c=$(head -c 64 "$SRC/.git/$ref" 2>/dev/null) ||
        c=$(awk -v r="$ref" '$2 == r {print $1; exit}' "$SRC/.git/packed-refs" 2>/dev/null) ;;
    *) c=$head ;;
  esac
  case "$c" in [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]*) printf '%s\n' "${c%%[!0-9a-f]*}" ;; *) echo unknown ;; esac
}

# place <src> <dst> <mode> [label] - idempotent, creates the parent, verifies.
# Writes a temporary file beside <dst>, checks it, and renames it into place:
# the destination is always either the old file or the new one, never absent,
# unreadable or half-written - claude reads the policy at any moment.
place() {
  local src="$1" dst="$2" mode="$3" label="${4:-$(basename "$2")}"
  PLACED+=("$dst")
  if [ ! -f "$src" ]; then bad "source missing: $src"; return 1; fi
  # A dry run is useful to a non-root operator, but most destinations are 0750
  # root - cmp then fails with EACCES and returns non-zero, which is
  # indistinguishable from "contents differ" unless we check readability first.
  # An unreadable file reported as a pending change would make --check claim
  # updates that do not exist.
  if [ "$DRY" -eq 1 ] && [ -f "$dst" ] && [ ! -r "$dst" ]; then
    say "$label exists, cannot compare as $(id -un) (run --check as root for a true diff)"
    return 0
  fi
  if [ -f "$dst" ] && cmp -s "$src" "$dst"; then
    local m; m=$(stat -c '%a' "$dst")
    if [ "$((8#$m))" -ne "$((8#$mode))" ]; then
      act "fix mode on $dst ($m -> $mode)"
      [ "$DRY" -eq 0 ] && chmod "$mode" "$dst"
    else
      say "$label already current"
    fi
    return 0
  fi
  act "install $label -> $dst ($mode root:root)"
  [ "$DRY" -eq 1 ] && return 0
  # Create the parent ONLY when it is absent. `install -d -m 0755 -o root -g
  # root` applies mode AND ownership to a directory that already exists, so an
  # unconditional call would re-open the admin policy directory from 0700 to
  # 0755, undoing the mkdirmode 0700 of step [12] on every apply that rewrites
  # the admin policy. A directory's mode belongs to
  # whoever declared it with mkdirmode; place() owns the FILE, never the parent.
  # The same call would have flipped $CC_LOGDIR/reports from root:$CC_REPO_GROUP
  # to root:root had anything ever placed a file there.
  [ -d "$(dirname "$dst")" ] ||
    install -d -m 0755 -o root -g root "$(dirname "$dst")" 2>/dev/null
  local tmp
  tmp=$(mktemp "$(dirname "$dst")/.cc-install.XXXXXX") || { bad "cannot create a temporary file beside $dst"; return 1; }
  if ! install -o root -g root -m "$mode" "$src" "$tmp"; then
    rm -f "$tmp"; bad "failed to install $dst (the previous file is unchanged)"; return 1
  fi
  # Verify the copy before it replaces anything: content and mode both.
  if ! cmp -s "$src" "$tmp"; then
    rm -f "$tmp"; bad "$dst: the copy does not match its source (the previous file is unchanged)"; return 1
  fi
  # stat prints 644 where the mode literal is 0644, so compare numerically
  # rather than as strings.
  local got; got=$(stat -c '%a' "$tmp")
  if [ "$((8#$got))" -ne "$((8#$mode))" ]; then
    rm -f "$tmp"; bad "$dst: the copy has mode $got, expected $mode (the previous file is unchanged)"; return 1
  fi
  backup "$dst" || { rm -f "$tmp"; return 1; }
  # rename(2) within one directory is atomic.
  mv -f "$tmp" "$dst" || { rm -f "$tmp"; bad "could not move the new $label into place at $dst"; return 1; }
  return 0
}

# place_text <dst> <mode> <label> - place() for content generated here (stdin).
place_text() {
  local f; f=$(mktemp "$GEN/gen.XXXXXX") || { bad "cannot stage $3"; return 1; }
  cat > "$f"
  place "$f" "$1" "$2" "$3"
}

# stop_if_failed - an apply stops at the first failed step, before the policy
# moves: a policy naming hooks that did not land enforces nothing.
stop_if_failed() {
  [ "$DRY" -eq 0 ] && [ "$ERRORS" -gt 0 ] || return 0
  echo
  echo "Stopped: ${ERRORS} error(s) above. The policy was NOT changed and no timer was"
  echo "enabled; files already placed by this run stay, and their previous versions"
  echo "are kept in $BACKUP/last. Fix the cause, then re-run."
  rotate_backup
  exit 1
}

# mkdirmode <dir> <mode> [owner] - idempotent directory with an asserted mode.
mkdirmode() {
  local d="$1" mode="$2" own="${3:-root:root}"
  if [ -d "$d" ]; then
    local m; m=$(stat -c '%a' "$d")
    if [ "$((8#$m))" -ne "$((8#$mode))" ]; then
      act "fix mode on $d ($m -> $mode)"
      [ "$DRY" -eq 0 ] && chmod "$mode" "$d"
    else
      say "$d exists"
    fi
  else
    act "create $d ($mode $own)"
    [ "$DRY" -eq 0 ] && install -d -m "$mode" -o "${own%:*}" -g "${own#*:}" "$d"
  fi
}

echo "=============================================================="
echo "Claude Code control-plane install - $([ "$DRY" -eq 1 ] && echo 'DRY RUN' || echo 'APPLYING')"
echo "Source : $SRC"
echo "Config : $CC_CONFIG_SOURCE"
echo "Site   : $CC_SITE_NAME"
echo "=============================================================="

# ---- gate 1: root -----------------------------------------------------------
if [ "$DRY" -eq 0 ] && [ "$(id -u)" -ne 0 ]; then
  bad "must run as root to apply"; exit 1
fi

# Generated content (the skel seeds) is staged here and placed like any file.
GEN=$(mktemp -d) || { echo "ERROR  cannot create a temporary directory" >&2; exit 1; }
trap 'rm -rf "$GEN"' EXIT

# ---- gate 1a: one change at a time -----------------------------------------
# Two applies, or an apply and a package update, interleaving leave a host that
# matches neither. cc-update.sh takes the same lock. A dry run changes nothing
# and does not wait for it.
SRC_COMMIT=$(src_commit)
if [ "$DRY" -eq 0 ]; then
  [ -d "$CC_ETC" ] || install -d -m 0755 -o root -g root "$CC_ETC"
  exec 9>>"$CC_CONTROL_LOCK" || { bad "cannot open the lock $CC_CONTROL_LOCK"; exit 1; }
  if ! flock -n 9; then
    bad "another install or update is running (it holds $CC_CONTROL_LOCK) - wait for it, then re-run"
    exit 1
  fi
  # A pull mid-way through rewrites the tree this run is copying from. The lock
  # cannot hold git off, so refuse to start during one and re-read the commit
  # at the end (step [16]).
  if [ -e "$SRC/.git/index.lock" ]; then
    bad "a git operation is in progress in $SRC (.git/index.lock exists) - let it finish, then re-run"
    exit 1
  fi
fi
if [ -r "$CC_ETC/install-record" ]; then
  say "deployed: $(grep -m1 '^commit=' "$CC_ETC/install-record" 2>/dev/null || echo 'commit=unknown')  this checkout: commit=$SRC_COMMIT"
else
  say "deployed: no install record on this host  this checkout: commit=$SRC_COMMIT"
fi

# ---- gate 1b: not inside a privileged session's mount namespace -------------
# cc-admin-session.sh bind-mounts the ADMIN policy file over $CC_POLICY for its
# own process tree. Writing to that path from inside the namespace does not
# write to the fleet policy - it writes THROUGH the bind, clobbering
# /etc/claude-code-admin/managed-settings.json with the fleet policy, which
# silently destroys the privileged session's configuration and leaves the real
# fleet policy untouched. The dry run is safe and still useful, so only --apply
# is blocked.
# CC_MOUNTINFO is a test seam: this is the highest-consequence copy of the
# predicate, so a case must be able to fabricate it. The other four copies
# (cc-audit.sh, cc-healthcheck.sh [2], cc-bump-audit.sh, cc-report.sh) read the
# same variable. Keep the awk identical to theirs: field 5 is the mount point.
CC_MOUNTINFO="${CC_MOUNTINFO:-/proc/self/mountinfo}"
if [ -r "$CC_MOUNTINFO" ] && awk -v t="$CC_POLICY" '$5 == t {found=1} END {exit !found}' "$CC_MOUNTINFO"; then
  echo
  echo "  BLOCKED  $CC_POLICY is a bind mount in this mount namespace."
  echo "           You are almost certainly inside a cc-admin-session.sh session."
  echo "           Applying here would overwrite the ADMIN policy, not the fleet one."
  echo "           Exit the privileged session and re-run from a plain root shell."
  [ "$DRY" -eq 0 ] && exit 1
  warn "dry run continues, but [4] Policy below is comparing against the admin"
  warn "  policy, not the fleet policy - ignore any difference it reports there."
fi

# ---- gate 2: source tree is complete ---------------------------------------
echo
echo "[1] Source files"
for f in settings/managed-settings.json lib/cc-config.sh \
         bin/cc-preflight.sh bin/cc-healthcheck.sh bin/cc-update.sh bin/cc-audit.sh \
         bin/cc-version-watch.sh bin/cc-report.sh bin/cc-bump-audit.sh \
         hooks/cc-audit-hook.sh hooks/cc-denied-hook.sh hooks/cc-secret-guard-hook.sh \
         hooks/cc-upgrade-guard-hook.sh hooks/cc-redact-hook.sh \
         share/statusline.sh share/cc-vscode-claude-wrapper.sh \
         docs/ENGINEER-GUIDE.md \
         profile.d/claude-code-home.sh profile.d/claude-code-home.csh \
         profile.d/claude-code-browser.sh profile.d/claude-code-browser.csh \
         systemd/claude-code-healthcheck.service systemd/claude-code-healthcheck.timer \
         systemd/claude-code-version-watch.service systemd/claude-code-version-watch.timer \
         systemd/claude-code-report.service systemd/claude-code-report.timer \
         systemd/claude-code-logrotate \
         systemd/user-.slice.d/50-claude-code.conf; do
  if [ -f "$SRC/$f" ]; then say "found $f"; else bad "missing $f"; fi
done
[ "$ERRORS" -eq 0 ] || { echo; bad "source tree incomplete - re-clone or re-extract"; exit 1; }

# ---- gate 3: the policy must be valid and fully filled in -------------------
echo
echo "[2] Policy readiness"
POL="$SRC/settings/managed-settings.json"
if ! python3 -c "import json;json.load(open('$POL'))" 2>/dev/null; then
  bad "managed-settings.json is not valid JSON"
else
  say "valid JSON"
  # Same markers cc-audit.sh looks for. A policy shipped with placeholders looks
  # configured and enforces nothing, so block the install rather than warn.
  PH=$(python3 - "$POL" <<'PY'
import json, sys
MARKERS = ("REPLACE-WITH", "REPLACE_WITH", "TODO", "FIXME", "CHANGEME")
def walk(n, p=""):
    if isinstance(n, dict):
        for k, v in n.items():
            if k.startswith("_comment"): continue
            yield from walk(v, f"{p}.{k}" if p else k)
    elif isinstance(n, list):
        for i, v in enumerate(n): yield from walk(v, f"{p}[{i}]")
    elif isinstance(n, str):
        if any(m in n.upper() for m in MARKERS) or n.startswith("<"):
            yield f"{p} = {n}"
for x in walk(json.load(open(sys.argv[1]))): print(x)
PY
)
  if [ -n "$PH" ]; then
    bad "policy still contains placeholders - fill these in first:"
    printf '%s\n' "$PH" | sed 's/^/           /'
  else
    say "no unreplaced placeholders"
  fi
  # autoMode arrays must extend the built-ins, not replace them.
  MISS=$(python3 - "$POL" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); am = d.get("autoMode", {})
for k in ("environment", "allow", "soft_deny", "hard_deny"):
    v = am.get(k)
    if isinstance(v, list) and "$defaults" not in v: print("autoMode." + k)
PY
)
  if [ -n "$MISS" ]; then
    bad "autoMode array(s) missing \"\$defaults\" - this REPLACES the built-in rules:"
    printf '%s\n' "$MISS" | sed 's/^/           /'
  else
    say "autoMode arrays extend the built-in defaults"
  fi

  # ---- gate 4: policy paths must agree with config.sh ----------------------
  # A hook registered at a path nothing was installed to is the worst kind of
  # failure: /permissions shows it, the health check can show it, and it never
  # runs. Cross-check rather than trust that the two were edited together.
  BADPATH=$(python3 - "$POL" "$CC_SBIN" "$CC_STATUSLINE" <<'PY'
import json, sys, re
pol, sbin, statusline = sys.argv[1], sys.argv[2], sys.argv[3]
d = json.load(open(pol))
for ev, entries in (d.get("hooks") or {}).items():
    for e in entries:
        for h in e.get("hooks", []):
            cmd = h.get("command", "")
            for tok in re.findall(r'/[A-Za-z0-9_./-]+', cmd):
                if tok.endswith(".sh") and "hook" in tok and not tok.startswith(sbin + "/"):
                    print(f"hooks.{ev}: {tok} is not under {sbin}")
sl = ((d.get("statusLine") or {}).get("command") or "")
toks = [t for t in re.findall(r'/[A-Za-z0-9_./-]+', sl) if t.endswith(".sh")]
if toks and toks[0] != statusline:
    print(f"statusLine: {toks[0]} != {statusline}")
PY
)
  if [ -n "$BADPATH" ]; then
    bad "policy paths disagree with config.sh - the hooks would not run:"
    printf '%s\n' "$BADPATH" | sed 's/^/           /'
  else
    say "hook and status-line paths agree with config.sh"
  fi

  # ---- gate 4b: the hooks must find the loader where [7] places it -----------
  # The hooks run as the engineer and read config only from one fixed path, so
  # an engineer's environment cannot steer them. If that path is not where
  # this install puts the loader, every hook logs nothing (the audit hooks)
  # or names no contact (the guards) - with every directory check green.
  HOOKS_OFF=""
  for h in "$SRC"/hooks/cc-*-hook.sh; do
    grep -qF "$CC_ETC/cc-config.sh" "$h" || HOOKS_OFF="$HOOKS_OFF $(basename "$h")"
  done
  if [ -n "$HOOKS_OFF" ]; then
    bad "hooks do not read the loader at $CC_ETC/cc-config.sh, where it is installed:$HOOKS_OFF"
  else
    say "hooks read the loader where it is installed ($CC_ETC/cc-config.sh)"
  fi

  # ---- gate 4c: every static file agrees with config.sh ---------------------
  # The units, logrotate stanza, sudoers drop-in and both policies spell their
  # paths and the support address literally (their readers do not source
  # config.sh). A site that moved a value in config.sh and not in them would
  # install a unit that runs nothing, or rotate a directory nothing writes to.
  CPL=$(CC_CONFIG="$CC_CONFIG" bash -c '. "$1/lib/cc-config.sh" >/dev/null && export ${!CC_@} && python3 "$1/lib/cc-coupling.py" "$1"' _ "$SRC" 2>&1)
  if [ $? -ne 0 ]; then
    bad "a static file disagrees with $CC_CONFIG (edit the file to match - they are concrete on purpose):"
    printf '%s\n' "$CPL" | sed 's/^/           /'
  else
    say "units, logrotate, sudoers and both policies agree with config.sh"
  fi

  # ---- gate 5: the policy floor must not exceed the version installed here ---
  # requiredMinimumVersion refuses to START any binary below it. Applying a
  # policy whose floor is above this host's version therefore takes every user
  # down at once, with the vendor's message and no obvious cause - and it looks
  # like an ordinary policy apply while doing it. The supported order is package
  # first, policy second (OPERATIONS.md 7.1 step 5); this gate makes the wrong
  # order refuse instead of become an outage.
  #
  # It reads the INCOMING policy from the source tree, never the deployed file,
  # so a privileged session's bind mount cannot fool it - unlike [4] Policy.
  FLOOR=$(policy_floor_of "$POL")
  INST=$(installed_version)
  if [ -z "$FLOOR" ]; then
    say "policy sets no version floor - nothing to check against the installed version"
  elif [ -z "$INST" ]; then
    # A host being built legitimately has the policy before the package
    # (QUICKSTART 2). That is a warning, not a failure - but it must SAY that
    # the gate did not run, because unknown is not "not below".
    if [ -x "$CC_CLAUDE_BIN" ] || "$RPM_BIN" -q "$CC_PKG" >/dev/null 2>&1; then
      warn "claude is present but its version could not be read - the floor ($FLOOR) was NOT checked"
      warn "  check by hand before applying:  rpm -q $CC_PKG ; $CC_CLAUDE_BIN --version"
    else
      warn "no claude on this host yet - policy floor $FLOOR NOT checked. Expected while"
      warn "  building a host: the policy may land before the package. Install at or above"
      warn "  the floor next:  make pin VERSION=$FLOOR"
    fi
  elif version_below "$INST" "$FLOOR"; then
    if [ "$ALLOW_BELOW_FLOOR" -eq 1 ]; then
      warn "--allow-below-floor: applying floor $FLOOR over installed $INST."
      warn "  Every session on this host will refuse to start until the package moves:"
      warn "  \"Claude Code $INST is older than the minimum version required by your"
      warn "  organization ($FLOOR)\". Announce it (OPERATIONS.md 1.5b), then move the"
      warn "  package (OPERATIONS.md 3.2)."
    else
      bad "policy floor $FLOOR is ABOVE the installed version $INST - applying this would"
      bad "  stop every session on this host: \"Claude Code $INST is older than the minimum"
      bad "  version required by your organization ($FLOOR)\". Package first, policy second:"
      bad "    1. sudo $CC_SBIN/cc-update.sh apply $FLOOR   (or: make pin VERSION=$FLOOR)"
      bad "    2. sudo bash bin/cc-install.sh --apply"
      bad "  Or accept the outage knowingly:  --allow-below-floor"
    fi
  else
    say "installed $INST is at or above the policy floor $FLOOR"
  fi

  # The admin policy carries its own floor and the two move together. A session
  # that can run dnf is precisely the session you need working during a bad bump.
  if [ "$WITH_ADMIN" -eq 1 ] && [ -f "$SRC/settings/managed-settings-admin.json" ] && [ -n "$INST" ]; then
    AFLOOR=$(policy_floor_of "$SRC/settings/managed-settings-admin.json")
    if [ -n "$AFLOOR" ] && version_below "$INST" "$AFLOOR"; then
      if [ "$ALLOW_BELOW_FLOOR" -eq 1 ]; then
        warn "--allow-below-floor: admin policy floor $AFLOOR is above the installed $INST"
      else
        bad "admin policy floor $AFLOOR is above the installed version $INST - claude-admin"
        bad "  would refuse to start. Both policies move together (REPO-MAP.md 2)."
      fi
    fi
  fi
fi
[ "$ERRORS" -eq 0 ] || { echo; echo "Refusing to continue. Fix the above, then re-run."; exit 1; }
if [ "$GATES_ONLY" -eq 1 ]; then
  echo; echo "Policy gates passed (--gates-only: nothing placed)."; exit 0
fi

# ---- gate 6: the privileged session is either managed or removed ------------
# The escalation path placed by an earlier --with-admin would otherwise stay on
# the host unmanaged: never updated, never checked against the fleet policy's
# floor, and invisible to whoever runs the next plain apply. Make the operator
# say which. The admin directory is 0700, so a non-root --check sees only the
# launcher.
if [ "$WITH_ADMIN" -eq 0 ] && [ "$REMOVE_ADMIN" -eq 0 ] &&
   { [ -e "$CC_ADMIN_POLICY" ] || [ -e "$CC_SBIN/cc-admin-session.sh" ]; }; then
  bad "the privileged session is installed on this host ($CC_SBIN/cc-admin-session.sh and/or"
  bad "  $CC_ADMIN_POLICY). Pass --with-admin to keep managing it, or --remove-admin to take it off."
  echo; echo "Refusing to continue. Fix the above, then re-run."; exit 1
fi

# ---- place everything -------------------------------------------------------
# Order matters. The policy names the hooks, the status line and the scripts,
# so it goes in LAST ([4], below [14]): a policy that lands before what it names
# registers hooks at paths that do not exist yet, and a failed step would leave
# it that way. Each step that can fail is followed by stop_if_failed.
echo
echo "[3] Directories"
mkdirmode "$CC_ETC"    0755
mkdirmode "$CC_LOGDIR" 0755
# The weekly report lands here. 2750 root:<group>, so a member of that group (and an
# agent session running as one) can read it with no sudo, while the world cannot
# even list it. The reports quote command shapes and finding text, which is
# group-only material - the same reasoning that keeps internal/ out of make dist.
if getent group "$CC_REPO_GROUP" >/dev/null 2>&1; then
  mkdirmode "$CC_LOGDIR/reports" 2750 "root:$CC_REPO_GROUP"
else
  warn "group $CC_REPO_GROUP does not resolve here - reports will be root-only"
  warn "  on this host, and no agent session will be able to read them"
  mkdirmode "$CC_LOGDIR/reports" 0700
fi
mkdirmode "$CC_SHARE"  0755
# 1733: engineers' own sessions append here as themselves, so they need write
# and traverse. They must NOT get read or list - one user's command history is
# not another user's business - and the sticky bit stops them deleting or
# renaming each other's files. This is the single most easily broken mode in
# the deployment; a well-meaning chmod 755 turns the audit trail into a
# readable record of everyone's activity.
mkdirmode "$CC_ACTIVITY_LOG_DIR" 1733
mkdirmode "$CC_LOGDIR/denied"    1733
stop_if_failed

echo
echo "[5] Site configuration"
# The loader and the site values, so every installed cc-* script resolves the
# same paths this run used. Without these, a script in /usr/local/sbin has no
# site values to read and refuses to run.
place "$SRC/lib/cc-config.sh" "$CC_ETC/cc-config.sh" 0644 "cc-config.sh (loader)"
place "$CC_CONFIG"            "$CC_ETC/config.sh"    0644 "config.sh (site values)"
stop_if_failed

echo
echo "[6] Operator scripts"
# 0750: root-only. These read the policy, the logs and the RPM state.
# cc-admin-session.sh is NOT in this list: it is the escalation path and is
# placed only with --with-admin, in [12] below, next to the policy it mounts.
for s in cc-preflight.sh cc-healthcheck.sh cc-update.sh cc-audit.sh cc-install.sh \
         cc-version-watch.sh cc-report.sh cc-bump-audit.sh; do
  [ -f "$SRC/bin/$s" ] && place "$SRC/bin/$s" "$CC_SBIN/$s" 0750 "$s"
done
stop_if_failed

echo
echo "[7] Hooks"
# 0755, NOT 0750: these run as the engineer, inside their own session. Tighten
# them and they silently stop running — calls proceed UNAUDITED with only a
# transcript warning, since anything but a hook's own exit 2 is non-blocking.
for h in cc-audit-hook.sh cc-denied-hook.sh cc-secret-guard-hook.sh cc-upgrade-guard-hook.sh cc-redact-hook.sh; do
  place "$SRC/hooks/$h" "$CC_SBIN/$h" 0755 "$h"
done
stop_if_failed

echo
echo "[8] Status line, IDE wrapper and engineer's guide"
# Path and name are fixed by statusLine.command in the policy - gate 4 checks it.
place "$SRC/share/statusline.sh" "$CC_STATUSLINE" 0755 "statusline.sh"
# The IDE wrapper is always placed, whether or not an editor is installed: it is
# an inert script until something names it in claudeProcessWrapper, and having
# it present means enabling the IDE later needs no root step.
place "$SRC/share/cc-vscode-claude-wrapper.sh" \
      "$CC_SHARE/cc-vscode-claude-wrapper.sh" 0755 "cc-vscode-claude-wrapper.sh"
# The welcome banner (companyAnnouncements) names this path, and engineers cannot
# read the repository (group-only), so the guide must live on the host.
place "$SRC/docs/ENGINEER-GUIDE.md" "$CC_SHARE/ENGINEER-GUIDE.md" 0644 "ENGINEER-GUIDE.md"
stop_if_failed

echo
echo "[9] profile.d drop-ins"
# BOTH variants of each are required: where the login shell is tcsh, a
# .sh-only install silently does nothing for those users.
#   home    - resolves HOME to the real path, not a published symlink
#   browser - sets BROWSER, without which OAuth login can fail silently
for p in claude-code-home.sh claude-code-home.csh \
         claude-code-browser.sh claude-code-browser.csh; do
  place "$SRC/profile.d/$p" "$CC_PROFILED/$p" 0644 "$p"
done
stop_if_failed

echo
echo "[10] systemd units and log rotation"
for u in claude-code-healthcheck.service claude-code-healthcheck.timer \
         claude-code-version-watch.service claude-code-version-watch.timer \
         claude-code-report.service claude-code-report.timer; do
  place "$SRC/systemd/$u" "$CC_UNITS/$u" 0644 "$u"
done
place "$SRC/systemd/claude-code-logrotate" "$CC_LOGROTATE_FILE" 0644 "logrotate config"
stop_if_failed

echo
echo "[11] Resource limits"
# ONE drop-in, valid on both cgroup generations, containing only TasksMax: a
# per-user cap on task count that stops a fork bomb and can affect nothing
# else - no cross-user throttling, nothing killed, no effect on running work.
# No memory or CPU sizing is installed: the drop-in's own header says why.
CGROUP_FS=$(stat -fc %T /sys/fs/cgroup 2>/dev/null || echo unknown)
say "cgroup generation: $([ "$CGROUP_FS" = tmpfs ] && echo v1 || echo "$CGROUP_FS") (informational - the drop-in is valid on both)"
place "$SRC/systemd/user-.slice.d/50-claude-code.conf" \
      "$CC_UNITS/user-.slice.d/50-claude-code.conf" 0644 "user slice limits"
stop_if_failed

echo
echo "[12] Privileged session (policy + launcher)"
if [ "$WITH_ADMIN" -eq 1 ]; then
  # 0700 root on the DIRECTORY, 0644 on the FILE. The directory mode is what
  # keeps the admin policy unbrowsable; the file must stay world-readable
  # because claude reads it as the unprivileged target user through the bind
  # mount. cc-admin-session.sh asserts both and refuses to start otherwise.
  mkdirmode "$CC_ETC_ADMIN" 0700
  place "$SRC/settings/managed-settings-admin.json" "$CC_ADMIN_POLICY" 0644 "admin policy"
  # The launcher lands ONLY here, never in [6]: a host built without
  # --with-admin carries no escalation path at all. Root-only to run (0750),
  # and --apply itself already refuses non-root, so only an administrator can
  # ever put this on a host.
  place "$SRC/bin/cc-admin-session.sh" "$CC_SBIN/cc-admin-session.sh" 0750 "cc-admin-session.sh (launcher)"
  # POST-CONDITION, not decoration: re-read the directory AFTER the policy has
  # been written. mkdirmode asserted 0700 above, then place() wrote a file into
  # it - and a defect in that order would re-open this directory to
  # 0755 on repeated applies. The only other thing that catches it is
  # cc-admin-session.sh refusing to start, which surfaces the fault at the
  # moment someone urgently needs a privileged session. Check it here, where
  # the damage is done and an operator is already watching.
  if [ "$DRY" -eq 0 ] && [ -d "$CC_ETC_ADMIN" ]; then
    dm=$(stat -c '%a %U' "$CC_ETC_ADMIN")
    if [ "$dm" = "700 root" ]; then
      say "$CC_ETC_ADMIN verified 0700 root after write"
    else
      bad "$CC_ETC_ADMIN is '$dm', expected '700 root' - the admin policy is"
      bad "  browsable and cc-admin-session.sh will refuse to start. Fix:"
      bad "  chmod 0700 $CC_ETC_ADMIN && chown root:root $CC_ETC_ADMIN"
    fi
  fi
  say "authorised invokers: group $CC_ADMIN_GROUP, users: ${CC_ADMIN_USERS[*]:-<none>}"
  if [ "${#CC_ADMIN_USERS[@]}" -eq 0 ] && ! getent group "$CC_ADMIN_GROUP" >/dev/null 2>&1; then
    warn "neither CC_ADMIN_GROUP ($CC_ADMIN_GROUP) nor CC_ADMIN_USERS resolves - nobody"
    warn "  will be able to open a privileged session. That is fail-closed, not broken."
  fi
elif [ "$REMOVE_ADMIN" -eq 1 ]; then
  # Copies are kept like any replaced file. The sudoers drop-in is installed by
  # hand (ADMIN-SESSION.md), so it is named here and left to the operator.
  for f in "$CC_SBIN/cc-admin-session.sh" "$CC_ADMIN_POLICY"; do
    [ -e "$f" ] || continue
    act "remove $f (a copy is kept in $BACKUP/last)"
    [ "$DRY" -eq 0 ] && { backup "$f" && rm -f "$f" || bad "could not remove $f"; }
  done
  if [ -d "$CC_ETC_ADMIN" ]; then
    act "remove the directory $CC_ETC_ADMIN if empty"
    [ "$DRY" -eq 0 ] && { rmdir "$CC_ETC_ADMIN" 2>/dev/null || warn "$CC_ETC_ADMIN is not empty - left in place"; }
  fi
  say "Remove the admin sudoers drop-in by hand if this host has one."
else
  say "skipped (pass --with-admin). This is the escalation path - policy AND"
  say "  launcher; a host built without the flag has neither. Installing it on"
  say "  a host that does not need it widens the attack surface for no gain."
fi
stop_if_failed

echo
echo "[13] IDE defaults"
# Seeds the VSCodium settings that point the Claude extension at the managed
# CLI. Behind a flag because the control plane should not assume an editor is
# installed, and because this is the one part of the deployment that is a
# DEFAULT rather than a control - VS Code and its forks have no managed-settings
# tier, so a user can undo it. See docs/IDE-INTEGRATION.md sections 3 and 8.
if [ "$WITH_IDE" -eq 1 ]; then
  # Managed like every other file: brought back to this content on each
  # --with-ide apply. An apply without the flag leaves it as it is.
  IDE_SKEL="$CC_SKEL/.config/VSCodium/User"
  place_text "$IDE_SKEL/settings.json" 0644 "VSCodium skel settings" <<IDEJSON
{
  "claudeCode.claudeProcessWrapper": "$CC_SHARE/cc-vscode-claude-wrapper.sh",
  "claudeCode.initialPermissionMode": "default"
}
IDEJSON
  # /etc/skel reaches new accounts only. Say so rather than let an operator
  # believe existing users were covered.
  say "NOTE: $CC_SKEL affects NEW accounts only. Existing users need these two"
  say "  keys added to ~/.config/VSCodium/User/settings.json by hand."
else
  say "skipped (pass --with-ide). Only needed on desktops running an editor."
fi
stop_if_failed

echo
echo "[14] New-account baseline ($CC_SKEL)"
# Copied into an account only when the account is created; existing users are
# unaffected by design. Managed, so a change here reaches the NEXT new account.
place_text "$CC_SKEL/.claude/settings.json" 0644 "skel baseline" <<'SKELJSON'
{
  "autoUpdatesChannel": "stable",
  "cleanupPeriodDays": 14,
  "includeCoAuthoredBy": false
}
SKELJSON
stop_if_failed

echo
echo "[4] Policy (placed last: it names everything above)"
# A policy that differs from the baseline the last apply recorded was edited by
# hand on this host. Overwriting it and re-recording the baseline would erase
# the only evidence, so say so first and keep the edited copy where no
# rotation reaches it.
if [ -f "$CC_POLICY" ] && [ -r "$CC_POLICY" ]; then
  if [ ! -f "$CC_POLICY_SHA" ]; then
    warn "$CC_POLICY has no recorded baseline ($CC_POLICY_SHA) - cannot tell whether it was edited by hand"
  elif ! ( cd "$CC_ETC" && sha256sum -c --quiet --status "$CC_POLICY_SHA" ) 2>/dev/null; then
    warn "$CC_POLICY differs from its recorded baseline - it was edited on this host since the last apply"
    if [ "$DRY" -eq 0 ]; then
      kept="$BACKUP/hand-edited-$(date -u +%Y%m%dT%H%M%SZ)-managed-settings.json"
      if install -d -m 0700 "$BACKUP" && cp -a "$CC_POLICY" "$kept"; then
        warn "  the edited copy is kept at $kept - review it before relying on this apply"
      else
        bad "could not keep the hand-edited policy at $kept - not overwriting it"
      fi
    else
      warn "  --apply will keep the edited copy in $BACKUP before replacing it"
    fi
  fi
fi
stop_if_failed
if place "$POL" "$CC_POLICY" 0644 "managed-settings.json"; then
  if [ "$DRY" -eq 0 ]; then
    if ( cd "$CC_ETC" && sha256sum managed-settings.json > "$CC_POLICY_SHA.new" && mv -f "$CC_POLICY_SHA.new" "$CC_POLICY_SHA" ); then
      say "recorded integrity baseline"
    else
      bad "could not record the integrity baseline $CC_POLICY_SHA"
    fi
  else
    act "record integrity baseline in $(basename "$CC_POLICY_SHA")"
  fi
fi
stop_if_failed

echo
echo "[14b] Files the repository no longer ships"
# The previous complete apply recorded every file it placed. One recorded then
# and not placed now was dropped from the repository: remove it, keeping a copy.
# Only regular files under the directories this installer writes are touched.
# The IDE seed is placed only with --with-ide, so a plain apply leaves it.
PRUNED=0
if [ -r "$CC_ETC/install-record" ]; then
  while IFS= read -r f; do
    case " ${PLACED[*]} " in *" $f "*) continue ;; esac
    case "$f" in "$CC_SKEL/.config/VSCodium/"*) [ "$WITH_IDE" -eq 0 ] && continue ;; esac
    case "$f" in
      "$CC_ETC"/*|"$CC_ETC_ADMIN"/*|"$CC_SBIN"/*|"$CC_SHARE"/*|"$CC_PROFILED"/*|"$CC_UNITS"/*|"$CC_LOGROTATE"/*|"$CC_SKEL"/*) ;;
      *) warn "install record names $f, outside every managed directory - left alone"; continue ;;
    esac
    [ -f "$f" ] && [ ! -L "$f" ] || continue
    act "remove $f (no longer shipped; a copy is kept in $BACKUP/last)"
    PRUNED=$((PRUNED+1))
    [ "$DRY" -eq 0 ] && { backup "$f" && rm -f "$f" || bad "could not remove $f"; }
  done < <(sed -n 's/^file=//p' "$CC_ETC/install-record")
  [ "$PRUNED" -eq 0 ] && say "nothing to remove"
else
  say "no install record yet - nothing to compare against (the first apply writes one)"
fi
stop_if_failed

echo
echo "[15] Enable the timers"
# The version watch is enabled with --now like the health check, but note the
# asymmetry: it exits 1 when a newer version EXISTS, so a freshly enabled timer
# on a host that is behind will immediately show a failed unit. That is the
# control working, not a broken install.
if [ "$DRY" -eq 0 ]; then
  if systemctl daemon-reload; then
    say "systemd reloaded"
  else
    bad "systemctl daemon-reload failed - systemd may still run the previous units"
  fi
  for t in claude-code-healthcheck.timer claude-code-version-watch.timer claude-code-report.timer; do
    if systemctl enable --now "$t" >/dev/null 2>&1; then
      say "$t enabled"
    else
      bad "could not enable $t"
    fi
  done
else
  act "systemctl daemon-reload && systemctl enable --now claude-code-healthcheck.timer claude-code-version-watch.timer claude-code-report.timer"
fi

echo
echo "[16] Install record"
if [ "$DRY" -eq 1 ]; then
  act "write $CC_ETC/install-record (commit $SRC_COMMIT, ${#PLACED[@]} files)"
else
  END_COMMIT=$(src_commit)
  if [ "$END_COMMIT" != "$SRC_COMMIT" ]; then
    bad "the checkout moved during this apply ($SRC_COMMIT -> $END_COMMIT): this host may hold"
    bad "  files from both. Re-run once the pull or checkout has finished."
  fi
  if [ "$ERRORS" -eq 0 ]; then
    {
      echo "# Written by cc-install.sh --apply. The next apply reads the file= lines to"
      echo "# remove what the repository no longer ships; --check prints the commit."
      echo "commit=$SRC_COMMIT"
      echo "source=$SRC"
      echo "applied=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      printf 'file=%s\n' "${PLACED[@]}"
    } > "$CC_ETC/install-record.new" && chmod 0644 "$CC_ETC/install-record.new" &&
      mv -f "$CC_ETC/install-record.new" "$CC_ETC/install-record" &&
      say "recorded commit $SRC_COMMIT and ${#PLACED[@]} files in $CC_ETC/install-record" ||
      bad "could not write $CC_ETC/install-record"
  else
    say "not written: this apply had errors, so the previous record stands"
  fi
  rotate_backup
fi

echo
echo "=============================================================="
if [ "$DRY" -eq 1 ]; then
  echo "DRY RUN complete, ${ERRORS} error(s), ${WARNS} warning(s)."
  echo "Re-run with --apply to make changes."
  exit 0
fi
echo "APPLIED, ${ERRORS} error(s), ${WARNS} warning(s). Now verify:"
cat <<'NEXT'
    claude doctor                 # does Claude Code accept the policy?
    claude auto-mode config       # did the classifier config take effect?
    cc-healthcheck.sh             # every placement, mode and drift check
    cc-audit.sh                   # file this as the deployment baseline record
  As a normal user, in a NEW login shell (profile.d needs a fresh login):
    /permissions                  # every effective rule and its source file
    /status                       # active managed source and login
NEXT
[ "$ERRORS" -eq 0 ] || exit 1
