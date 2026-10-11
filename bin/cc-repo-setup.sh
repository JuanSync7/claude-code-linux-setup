#!/usr/bin/env bash
# cc-repo-setup.sh — prepare a fresh clone. Run once, per clone.
#
#     bin/cc-repo-setup.sh
#
# Git will NOT install hooks from a clone, deliberately: a repository that could
# execute code on `git clone` would be a trivial attack. So this has to be an
# explicit, local step, and nothing enforces it. Anyone who skips it simply gets
# no guard -- which is worth knowing about the design rather than assuming the
# protection is automatic.
#
# What it does:
#   1. points core.hooksPath at githooks/ (pre-commit guard; post-merge and
#      post-checkout perms)
#   2. creates config.sh from the template if absent
#   3. reports the permission state of the checkout
#
# Idempotent. Safe to re-run, and worth re-running after a pull that changes
# the hooks.

set -uo pipefail

REPO="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
cd "$REPO" || exit 1

ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$1"; }
info() { printf '    %s\n' "$1"; }

printf '\nClaude Code control plane — clone setup\n'
printf 'Repo: %s\n\n' "$REPO"

# --- 1. hooks ---------------------------------------------------------------
if [ -d githooks ]; then
  current=$(git config --local core.hooksPath || true)
  if [ "$current" = "githooks" ]; then
    ok "git hooks already enabled (core.hooksPath=githooks)"
  else
    git config --local core.hooksPath githooks
    ok "git hooks enabled: core.hooksPath=githooks"
  fi
  chmod +x githooks/* 2>/dev/null
  info "pre-commit    blocks credentials, transcripts and config dumps"
  info "post-merge    reasserts group/setgid modes after a pull"
  info "post-checkout reasserts them after a checkout"
else
  warn "githooks/ missing — no pre-commit guard in this clone"
fi

# --- 2. site config ---------------------------------------------------------
if [ -f config.sh ]; then
  ok "config.sh present"
else
  if [ -f config.example.sh ]; then
    cp config.example.sh config.sh
    chmod 0660 config.sh 2>/dev/null || chmod 0600 config.sh
    ok "config.sh created from config.example.sh"
    warn "EDIT IT before running cc-install.sh — it ships with empty/site-neutral values"
  else
    warn "config.example.sh missing; cannot create config.sh"
  fi
fi
# It is gitignored; confirm that, because a force-add would push site topology.
if git check-ignore -q config.sh 2>/dev/null; then
  ok "config.sh is gitignored"
else
  warn "config.sh is NOT ignored — check .gitignore before committing anything"
fi

# --- 3. permissions ---------------------------------------------------------
printf '\n'
if [ -x bin/cc-repo-perms.sh ]; then
  if out=$(bin/cc-repo-perms.sh 2>&1); then
    if printf '%s' "$out" | grep -q 'Nothing to change'; then
      ok "permissions correct"
    else
      warn "permissions need correcting — run: bin/cc-repo-perms.sh --apply"
      printf '%s\n' "$out" | sed 's/^/    /' | head -12
    fi
  else
    # Not fatal: a personal clone in your own home needs none of this.
    info "cc-repo-perms.sh not applicable here:"
    printf '%s\n' "$out" | sed 's/^/    /' | head -4
    info "That is expected for a private clone — group modes only matter on a"
    info "shared checkout. Nothing to do."
  fi
fi

printf '\nNext:\n'
printf '    ${EDITOR:-vi} config.sh\n'
printf '    sudo bin/cc-preflight.sh\n'
printf '    sudo bin/cc-install.sh --check\n\n'
