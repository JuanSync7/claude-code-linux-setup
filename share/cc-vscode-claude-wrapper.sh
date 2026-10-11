#!/usr/bin/env bash
# cc-vscode-claude-wrapper.sh
#
# Makes the Claude Code VS Code / VSCodium extension run the dnf-managed CLI
# instead of the private copy it bundles.
#
# WHY THIS IS NEEDED
# The extension does not use `claude` from PATH. It bundles its own CLI build
# and runs that for its chat panel. So without this wrapper an engineer using
# the editor panel runs whatever version the extension shipped with, which is
# not the version dnf installed and versionlock pinned.
#
# The managed policy still applies either way - /etc/claude-code/managed-settings.json
# is a compiled-in path in every Claude Code build, so deny rules, hooks and
# activity logging bind to the bundled copy too. What differs is only the
# VERSION. This wrapper closes that, and nothing else.
#
# HOW THE EXTENSION CALLS IT
# The `claudeProcessWrapper` setting names an executable, and the extension
# passes the path of its own bundled binary as the first argument when it has
# one. So the invocation is:
#
#     cc-vscode-claude-wrapper.sh <bundled-cli-path> [claude args...]
#
# This script drops that first argument and execs the managed binary with the
# rest. Pointing `claudeProcessWrapper` straight at /usr/bin/claude does NOT
# work: the bundled path would arrive as argv[1] and be treated as a prompt or
# a subcommand.
#
# IF THE MANAGED BINARY IS MISSING
# Falls back to the bundled binary with a warning on stderr rather than
# refusing to start. That is deliberate. The fallback costs version
# consistency, not policy enforcement - the bundled copy is still governed by
# managed settings - and an editor that will not open is a worse outcome than
# an editor running a slightly different build.
#
# Install: /usr/local/share/claude-code/cc-vscode-claude-wrapper.sh, 0755 root:root.
# Configure: see docs/IDE-INTEGRATION.md.
#
# Set CC_WRAPPER_DEBUG=1 to have the decision logged to stderr.

set -uo pipefail

# The managed binary is CC_CLAUDE_BIN in site config. This runs as the engineer,
# so their environment is cleared of CC_* first and only the installed config
# decides - the same rule as the hooks. No config, no guess: the editor shows
# the error instead of silently running some other claude.
for _v in ${!CC_@}; do [ "$_v" = CC_WRAPPER_DEBUG ] || unset "$_v"; done
for _cfg in /etc/claude-code/cc-config.sh \
            "$(dirname "$(readlink -f "$0")")/../../lib/cc-config.sh"; do
  if [ -r "$_cfg" ]; then . "$_cfg" || exit 1; _cfg_loaded=1; break; fi
done
[ "${_cfg_loaded:-0}" = 1 ] || { echo "cc-vscode-wrapper: cannot find cc-config.sh - ask IT to run cc-install.sh" >&2; exit 1; }
unset _v _cfg _cfg_loaded

dbg() { [ "${CC_WRAPPER_DEBUG:-0}" = 1 ] && printf 'cc-vscode-wrapper: %s\n' "$1" >&2; return 0; }

BUNDLED=""
# Decide whether argv[1] is the bundled binary or a real argument.
#
# It must be an existing executable regular file - that alone rules out flags,
# subcommands and prompts. On top of that it must LOOK like an extension's
# bundled CLI: named *claude*, or living under an extensions directory. Both
# tests together, because getting this wrong is bad in either direction:
#   - fail to drop it, and the path is handed to Claude as a prompt
#   - drop it wrongly, and a real first argument silently disappears
#
# The name test alone is too narrow: it assumes the bundled binary is called
# "claude", which is likely but not guaranteed across extension builds. The
# path test covers a differently named binary shipped inside the extension.
_is_bundled() {
  [ -f "$1" ] && [ -x "$1" ] || return 1
  case "$(basename "$1")" in *claude*) return 0 ;; esac
  case "$1" in
    */extensions/*|*/.vscode*/*|*/vscodium/*|*/VSCodium/*|*/code-oss/*) return 0 ;;
  esac
  return 1
}

if [ "$#" -gt 0 ] && _is_bundled "${1:-}"; then
  BUNDLED="$1"
  shift
  dbg "bundled binary supplied and dropped: $BUNDLED"
else
  dbg "no bundled binary in argv; passing all arguments through"
fi

if [ -x "$CC_CLAUDE_BIN" ]; then
  dbg "exec managed binary: $CC_CLAUDE_BIN"
  exec "$CC_CLAUDE_BIN" "$@"
fi

# Managed binary absent. Warn loudly, then keep the editor working.
printf 'cc-vscode-claude-wrapper: %s is missing or not executable.\n' "$CC_CLAUDE_BIN" >&2
if [ -n "$BUNDLED" ]; then
  printf '  Falling back to the extension'"'"'s bundled CLI. The managed policy still\n' >&2
  printf '  applies, but this build is NOT the version dnf pinned. Report this to IT.\n' >&2
  exec "$BUNDLED" "$@"
fi
printf '  No bundled CLI was supplied either. Cannot start Claude Code.\n' >&2
exit 127
