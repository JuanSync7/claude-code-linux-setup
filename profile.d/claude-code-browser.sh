# /etc/profile.d/claude-code-browser.sh — install root:root 0644
#
# WHY THIS EXISTS
# OAuth login opens a browser and completes through a short-lived callback on
# loopback. Setting BROWSER short-circuits xdg-open entirely, so a misconfigured
# per-user desktop default cannot break login.
#
# Without it, xdg-open on an XFCE desktop resolves through
#   xfce4-web-browser.desktop -> exo-open -> the WebBrowser= entry in
#   ~/.config/xfce4/helpers.rc
# and if that entry names "links" (a terminal browser), OAuth fails SILENTLY:
# links launches with no TTY because the desktop entry sets Terminal=false,
# exits immediately, no window ever appears, and xdg-open still returns 0.
#
# Setting this at host level rather than per home directory is deliberate: a fix
# dropped into one home does not cover the next person to log in.
#
# The .csh sibling is REQUIRED — /etc/profile.d/*.sh is not sourced by
# csh-family shells, so a csh or tcsh login is reached by the sibling alone.
#
# THE BROWSER IS DETECTED, NOT HARDCODED. The first executable candidate wins,
# preference Chrome -> Chromium -> Firefox. If none is found BROWSER is left
# UNSET on purpose, so xdg-open still gets its chance rather than being pointed
# at a path that does not exist.
#
# Detection rather than a constant, because a WRONG constant here is worse than
# no drop-in at all: BROWSER short-circuits xdg-open to a non-existent binary, so
# OAuth login fails silently with no window and nothing logged, overriding a
# working desktop default. The hosts of one fleet need not ship the same browser,
# so no single path is correct on all of them. Detection also makes a new build
# image work with no edit here.
#
# Do NOT assume a browser from the host you are reading this on, and do not
# "simplify" this back to one path. Ask the host:
#   sh -c '. /etc/profile.d/claude-code-browser.sh; echo "$BROWSER"'
#
# KEEP THE CANDIDATE LIST IDENTICAL IN BOTH SIBLINGS — cc-healthcheck.sh probe 2c
# sources each one and flags them disagreeing.
#
# A display is still required and CANNOT be set from here: DISPLAY is issued per
# session by sshd when the client asks for forwarding (ssh -X). Ask the host what
# this resolved to, rather than reading the list:
#
#   sh -c '. /etc/profile.d/claude-code-browser.sh; echo "BROWSER=$BROWSER"'
#
# Empty means no candidate exists here and browser login will fail silently.

for _cc_b in /bin/google-chrome-stable /bin/google-chrome \
             /bin/chromium-browser /bin/chromium /bin/firefox
do
    if [ -x "$_cc_b" ]; then
        BROWSER="$_cc_b"
        export BROWSER
        break
    fi
done
unset _cc_b
