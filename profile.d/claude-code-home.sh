# /etc/profile.d/claude-code-home.sh — install root:root 0644
#
# WHY THIS EXISTS
# A directory service can publish a home directory (/home/<user>) that is a
# symlink to the real path on a file server. bubblewrap cannot create a mount
# point through a symlinked parent, so every sandboxed Bash command then fails
# with:
#
#     bwrap: Can't mkdir /home/<user>/.ssh: Not a directory
#
# Every sandbox.filesystem rule that starts with "~" expands to $HOME, so this
# affects allowRead, denyRead and allowWrite alike. Resolving HOME to the real
# path before Claude Code starts makes all of them work. Where HOME is not a
# symlink the test below is false and this file changes nothing.
#
# THIS IS A WORKAROUND. The permanent fix is one directory attribute: publish
# the real path as the home directory. This file and its .csh sibling are not
# needed on a host where that is done.
#
# The .csh sibling is NOT optional: /etc/profile.d/*.sh is sourced only by
# sh-family shells. Shipped alone, this file reaches no csh or tcsh user.

if [ -n "$HOME" ] && [ -L "$HOME" ]; then
    _cc_real_home=$(readlink -f "$HOME" 2>/dev/null)
    if [ -n "$_cc_real_home" ] && [ -d "$_cc_real_home" ]; then
        HOME="$_cc_real_home"
        export HOME
    fi
    unset _cc_real_home
fi
