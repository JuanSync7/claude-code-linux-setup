# /etc/profile.d/claude-code-browser.csh — install root:root 0644
#
# csh/tcsh sibling of claude-code-browser.sh. REQUIRED, not optional:
# /etc/profile.d/*.sh is sourced only by sh-family shells, so a user whose login
# shell is csh or tcsh is reached by this file alone. See claude-code-browser.sh
# for the full reasoning, including why the browser is DETECTED rather than
# hardcoded.
#
# The candidate list below MUST match the .sh sibling exactly — cc-healthcheck.sh
# probe 2c sources both and flags them disagreeing. A correct .sh with a stale
# .csh reaches no csh or tcsh user.
#
# A syntax error in this file breaks LOGIN for every tcsh user on the host. After
# editing, verify with:  tcsh -f -c 'source /etc/profile.d/claude-code-browser.csh'

foreach _cc_b ( /bin/google-chrome-stable /bin/google-chrome \
                /bin/chromium-browser /bin/chromium /bin/firefox )
    if ( -x $_cc_b ) then
        setenv BROWSER $_cc_b
        break
    endif
end
unset _cc_b
