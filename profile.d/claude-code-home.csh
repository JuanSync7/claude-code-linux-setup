# /etc/profile.d/claude-code-home.csh — install root:root 0644
#
# csh/tcsh sibling of claude-code-home.sh. REQUIRED, not optional:
# /etc/profile.d/*.sh is sourced only by sh-family shells, so a user whose login
# shell is csh or tcsh is reached by this file alone. See claude-code-home.sh
# for the full reasoning.
#
# Summary: when the home directory the directory service publishes is a symlink
# to the real path, bubblewrap cannot create a mount point through the
# symlinked parent, so every sandboxed command fails until HOME resolves to the
# real path.

if ( -l "$HOME" ) then
    set _cc_real_home = `readlink -f "$HOME"`
    if ( "$_cc_real_home" != "" && -d "$_cc_real_home" ) then
        setenv HOME "$_cc_real_home"
    endif
    unset _cc_real_home
endif
