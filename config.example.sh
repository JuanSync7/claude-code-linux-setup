# shellcheck shell=bash
# ===========================================================================
#  config.example.sh — site configuration template
# ===========================================================================
#
#  Copy to config.sh and fill in for this site. config.sh is gitignored.
#
#      cp config.example.sh config.sh && ${EDITOR:-vi} config.sh
#
#  WHAT THIS IS, AND WHAT IT IS NOT
#
#  This file holds no credentials, and it must never be used to hold one.
#  Everything here is site *topology* — hostnames, group names, install paths,
#  who may open a privileged session. It is separated out for two reasons:
#
#    1. so this repository can be cloned, forked, reviewed or handed to a
#       vendor without redacting it;
#    2. so a second site is a new config.sh rather than a patch set.
#
#  If a value ever needs to be secret, it does not belong here — put it in a
#  root-owned 0600 file outside the repo and reference the path.
#
#  It is shell-shaped, not YAML. Rocky 8 has neither yq nor jq, and the only
#  YAML parser is PyYAML on the system python — so a YAML config would make
#  cc-preflight.sh depend on an interpreter it exists to check for.
#
#  It is DATA, never run: root loads it, and it lives in a group-writable
#  checkout. lib/cc-config.sh parses it line by line and refuses, naming the
#  line, anything but a comment or one of these (each may end in # comment):
#      CC_KEY="value"    no $ ` or \ inside — nothing is expanded
#      CC_KEY='value'    CC_KEY=plain_value    CC_ADMIN_USERS=("a" "b")
#  A key it does not know is refused too, so a typo cannot pass silently.
#
#  EVERY KEY BELOW IS READ, AND EVERY ONE MUST BE PRESENT. lib/cc-config.sh
#  has no defaults of its own: it loads this file's copy (config.sh) and
#  refuses to run, naming the missing keys, if one is absent. The values below
#  are the suggested ones — keep a line as it is to accept it, edit it to
#  change it. Scripts never spell a value themselves; CI check [11] fails any
#  that does, so the value you set here is the value every script uses.
#
#  Consumers: every host script, hook and the Makefile, through
#  lib/cc-config.sh (installed beside this file as /etc/claude-code/cc-config.sh).
#  A fresh checkout with no config.sh runs on this file's values and says so.
#
#  NOT templated from here: settings/managed-settings.json. See §5.
# ===========================================================================

# --- 1. Identity of this deployment ----------------------------------------
# The site name heads the health check and report. The support contact is
# printed wherever an engineer is told "ask IT": the banner check, and the two
# hooks that block a call (secret guard, upgrade guard). The policy's own
# banner text spells the address too, because claude reads the policy and not
# this file (§5); cc-install.sh refuses when that text does not contain this
# value.
CC_SITE_NAME="REPLACE-WITH-SITE-NAME"
CC_SUPPORT_CONTACT="REPLACE-WITH-SUPPORT-EMAIL"

# --- 2. Install destinations ------------------------------------------------
# These are where the control plane lands on a host. /etc/claude-code is the
# ONE path that is not a choice: it is compiled into the claude binary. The
# rest are conventional and may be moved, but cc-healthcheck.sh and the
# managed policy's hook commands must agree with them.
CC_ETC="/etc/claude-code"                        # policy dir — FIXED by the product
CC_ETC_ADMIN="/etc/claude-code-admin"            # admin policy dir, 0700 root
CC_SBIN="/usr/local/sbin"                        # operator scripts + hooks; must be on root's PATH
CC_SHARE="/usr/local/share/claude-code"          # statusline.sh; referenced by the policy
CC_LOGDIR="/var/log/claude-code"                 # activity/, admin.log, healthcheck output
CC_UNITS="/etc/systemd/system"
CC_LOGROTATE="/etc/logrotate.d"                  # a DIRECTORY; the file is <this>/claude-code
CC_PROFILED="/etc/profile.d"
CC_SKEL="/etc/skel"
CC_CLAUDE_BIN="/usr/bin/claude"                  # the managed RPM's binary

# --- 3. Who may open a privileged session -----------------------------------
# Gate on cc-admin-session.sh, checked against the INVOKER (SUDO_USER), on top
# of sudo. Authorisation is: membership of CC_ADMIN_GROUP (if that group
# resolves) OR literal presence in CC_ADMIN_USERS.
#
# Prefer the group: a name list does not survive a leaver process. Where the
# group does not exist in the directory yet, name the admins here - the list
# ships empty, so a new site has no admin until it says who (fail closed;
# cc-install.sh warns when neither resolves).
CC_ADMIN_GROUP="cc-admins"
CC_ADMIN_USERS=()

# --- 4. Group that owns this tree, and reads the weekly reports -------------
# Reasserted by bin/cc-repo-perms.sh after a pull, because git records only the
# execute bit — not the setgid bit, not the group, and not internal/'s 2770.
# cc-install.sh and cc-report.sh give this group read access to the reports.
# EMPTY means no such group at this site: the reports are root-only, and
# cc-repo-perms.sh refuses to run (it has nothing to assert).
CC_REPO_GROUP="cc-maintainers"

# --- 5. Values that are NOT set from here -----------------------------------
# claude reads settings/managed-settings.json itself and sources no shell file,
# so these values are written in the policy, not here. Nothing substitutes
# them at install time, and that is deliberate: the policy is the one artefact
# where an operator must be able to read the literal effective value, so the
# deployed policy is the file you read. SETTINGS-REFERENCE.md documents it key
# by key, and cc-install.sh REFUSES to deploy a policy that still contains a
# placeholder. (Which edition carries placeholders, and how they are filled:
# docs/PUBLISHING.md §1.)
#
# So for a new site, edit these in settings/managed-settings.json by hand:
#
#   autoMode.environment[]      internal domain suffix, storage host, exports
#   permissions.deny[]          site-specific paths to protect
#   hooks[].command             must match CC_SBIN above
#   statusLine.command          must match CC_SHARE above
#   notice                      the banner users see, and the support contact
#   forceLoginMethod            login pin
#
# Read the present values in that file, not here - a copy in this comment
# would drift from it. bin/cc-healthcheck.sh cross-checks the hook and
# statusline paths against §2 and reports a mismatch.

# --- 6. Evaluation build (optional) -----------------------------------------
# Enables `cc-admin-session.sh -e`. Leave EMPTY on any host with no reason to
# run an unmanaged build.
#
# A version-pinned fleet still needs somewhere to try the next release before
# approving it. PATH is the wrong place: a personal build named `claude` in
# ~/.local/bin shadows the version-gated RPM silently. Naming it here instead
# makes every use deliberate and recorded in admin.log.
#
# The binary AND every directory above it must be owned by the invoker or root
# and not group- or world-writable (a sticky directory such as /tmp excepted);
# cc-admin-session.sh refuses otherwise. A symlink is resolved and its target is
# what is checked and run. A shared, group-writable project area is therefore
# not a valid home for it.
CC_EVAL_BIN=""

# --- 7. Fleet membership ----------------------------------------------------
# Space-separated hostnames of EVERY host in the fleet — governed or not, since
# a reachable host that is not governed is exactly what the check looks for.
# Read only by the fleet-drift skill (.claude/skills/fleet-drift/SKILL.md).
# Empty means the peer list is unknown, and the skill says so instead of
# reporting a clean fleet. Example: CC_FLEET_HOSTS="host01 host02 host03"
CC_FLEET_HOSTS=""

# --- 8. Where the package comes from -----------------------------------------
# The RPM this fleet installs and the dnf repository it comes from. Change the
# two URLs to point at an internal mirror; `make pin` writes them into
# /etc/yum.repos.d/<CC_PKG_REPO_ID>.repo. cc-update.sh stages a download in
# CC_UPDATE_STAGE_DIR before installing it.
CC_PKG="claude-code"                             # RPM name
CC_PKG_REPO_ID="claude-code"                     # dnf repo id, and the .repo file name
CC_RPM_BASEURL="https://downloads.claude.ai/claude-code/rpm/stable"
CC_RPM_GPGKEY="https://downloads.claude.ai/keys/claude-code.asc"
CC_UPDATE_STAGE_DIR="/var/cache/claude-code-staging"

# --- 9. Watching for new releases ---------------------------------------------
# cc-version-watch.sh reads the vendor's release channel as corroboration of
# the repository metadata, and calls the metadata stale when it is older than
# CC_WATCH_MAX_AGE_H hours. The watch reads dnf's cached metadata and does not
# refresh it, so the age is that of the host's last dnf refresh: a day plus
# slack fits a host whose dnf-makecache timer runs daily.
CC_RELEASE_CHANNEL_URL="https://downloads.claude.ai/claude-code-releases/stable"
CC_WATCH_MAX_AGE_H="26"

# --- 10. Where this site keeps things -------------------------------------------
# CC_REPO: the shared git checkout of this repository — the source, not the
# installed copies. The weekly report compares this host against it; on a host
# that cannot see it, the report says the comparison was skipped.
# CC_HOME_ROOT: the directory that holds every engineer's home directory, where
# the checks look for private Claude installs and credential files. A wrong
# value means those checks examine nobody, so the health check fails rather
# than skips when this directory holds no home of a real account.
# CC_REPO_RUNAS: optional. The non-root account the weekly report (which runs
# as root) uses to run CI and git in CC_REPO. The checkout is group-writable,
# so root never runs anything from it. EMPTY means the repo section is skipped
# when the report runs as root, and the report says so.
CC_REPO="/srv/claude-code"
CC_HOME_ROOT="/users"
CC_REPO_RUNAS=""

# --- 11. Reports and metrics ----------------------------------------------------
# CC_REPORT_KEEP: how many weekly reports cc-report.sh keeps (52 = a year).
# CC_METRICS_FILE: where the daily health check writes a Prometheus textfile for
# node_exporter. EMPTY means no metrics file is written.
CC_REPORT_KEEP="52"
CC_METRICS_FILE="/var/lib/node_exporter/textfile_collector/claude_code.prom"
