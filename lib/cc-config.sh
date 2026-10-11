# shellcheck shell=bash
# ===========================================================================
#  cc-config.sh — site configuration loader, sourced by every cc-* script
# ===========================================================================
#
#  Every site value a script uses comes from ONE file, config.sh. This loader
#  finds it, loads it, and REFUSES a config that does not set every key —
#  there are no built-in defaults here. The suggested values live in exactly
#  one place, config.example.sh, which a site copies to config.sh and edits.
#  A second copy of the defaults is how a value comes to mean one thing in a
#  script and another in the config.
#
#  SEARCH ORDER — first hit wins, and only one file is loaded:
#
#    1. $CC_CONFIG                       explicit override (tests use this)
#    2. /etc/claude-code/config.sh       the INSTALLED copy
#    3. <repo>/config.sh                 running from a git checkout
#    4. <repo>/config.example.sh         a checkout with no config.sh yet —
#                                        the sample values, and said so in
#                                        CC_CONFIG_SOURCE
#
#  /etc/claude-code is the one path spelled here rather than read: it is
#  compiled into the claude binary, so it is where the config has to be found
#  from. Order 2 before 3 matters: the timers run the installed scripts with no
#  repo anywhere near them, so on a deployed host the installed copy rules, and
#  editing <repo>/config.sh changes nothing until cc-install.sh --apply copies it.
#  Steps 3 and 4 apply only when this file sits in a checkout (lib/ beside
#  bin/ and settings/), never to the installed copy in /etc/claude-code.
#
#  AN EXPORTED CC_* VALUE WINS OVER THE FILE, for that one run. That is how the
#  test suite points a script at a fixture, and how an operator tries a value
#  before writing it down. Every override is listed in CC_CONFIG_OVERRIDES so
#  a report can say it ran on one. Scripts an engineer's environment could
#  steer — the hooks, which run as the engineer, and cc-admin-session.sh —
#  clear every CC_* variable before sourcing this, so no override reaches them.
#
#  Fails (return 1, message on stderr) when no config is found or a key is
#  missing. Callers stop on that: `. cc-config.sh || exit <their code>`.
#
#  Install: /etc/claude-code/cc-config.sh, root:root, 0644.
# ===========================================================================

# --- the keys -----------------------------------------------------------------
# REQUIRED must be set and non-empty. OPTIONAL must be present and may be empty
# (empty has a documented meaning for each, in config.example.sh). CI check [7]
# holds these lists and config.example.sh to each other in both directions.
CC_REQUIRED_KEYS="CC_SITE_NAME CC_SUPPORT_CONTACT
  CC_ETC CC_ETC_ADMIN CC_SBIN CC_SHARE CC_LOGDIR CC_UNITS CC_LOGROTATE
  CC_PROFILED CC_SKEL CC_CLAUDE_BIN
  CC_PKG CC_PKG_REPO_ID CC_RPM_BASEURL CC_RPM_GPGKEY CC_UPDATE_STAGE_DIR
  CC_RELEASE_CHANNEL_URL CC_WATCH_MAX_AGE_H
  CC_ADMIN_GROUP CC_REPO CC_HOME_ROOT CC_REPORT_KEEP"
CC_OPTIONAL_KEYS="CC_REPO_GROUP CC_EVAL_BIN CC_FLEET_HOSTS CC_METRICS_FILE CC_REPO_RUNAS"
# CC_ADMIN_USERS is an array, so it is checked separately below.

# --- remember what the environment overrides ----------------------------------
# Only EXPORTED variables: a plain shell variable a script set for itself is
# not an override from outside. CC_CONFIG and CC_CONFIG_LIB choose the file and
# the loader; they are not config values.
_cc_env_keep=()
CC_CONFIG_OVERRIDES=""
for _cc_v in ${!CC_@}; do
  case "$_cc_v" in CC_CONFIG|CC_CONFIG_LIB|CC_REQUIRED_KEYS|CC_OPTIONAL_KEYS) continue ;; esac
  case "$(declare -p "$_cc_v" 2>/dev/null)" in
    "declare -"*x*" $_cc_v="*)
      _cc_env_keep+=("$_cc_v=${!_cc_v}")
      CC_CONFIG_OVERRIDES="$CC_CONFIG_OVERRIDES $_cc_v" ;;
  esac
done
CC_CONFIG_OVERRIDES="${CC_CONFIG_OVERRIDES# }"

# --- locate the site config -----------------------------------------------------
cc_config_file=""
if [ -n "${CC_CONFIG:-}" ]; then
  cc_config_file="$CC_CONFIG"
  [ -r "$cc_config_file" ] || {
    echo "cc-config: CC_CONFIG=$cc_config_file is not readable" >&2
    unset _cc_v _cc_env_keep cc_config_file
    return 1
  }
elif [ -r "/etc/claude-code/config.sh" ]; then
  cc_config_file="/etc/claude-code/config.sh"
else
  # Resolve the repo root from this file's own location: lib/ -> repo root.
  # BASH_SOURCE, not $0 — $0 is the sourcing script, which may be anywhere.
  _cc_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)"
  if [ -n "$_cc_root" ] && [ -d "$_cc_root/settings" ] && [ -d "$_cc_root/bin" ]; then
    if [ -r "$_cc_root/config.sh" ]; then
      cc_config_file="$_cc_root/config.sh"
    elif [ -r "$_cc_root/config.example.sh" ]; then
      cc_config_file="$_cc_root/config.example.sh"
    fi
  fi
  unset _cc_root
fi

if [ -z "$cc_config_file" ]; then
  echo "cc-config: no config.sh found (looked in \$CC_CONFIG, /etc/claude-code/config.sh" >&2
  echo "           and the checkout). Install one with cc-install.sh --apply or make quickstart." >&2
  unset _cc_v _cc_env_keep cc_config_file
  return 1
fi

# --- read it as DATA, never as code ---------------------------------------------
# config.sh is edited in a group-writable checkout, is never reviewed (it is
# gitignored), and root loads it: cc-install.sh --apply, every timer, and the
# installed copy every hook reads. Sourcing it would run whatever any group
# member typed, as root. So each line must be one of these, or the load fails
# naming the line - and nothing in the file runs:
#   blank, or a # comment
#   CC_KEY="value"   no $ ` or \ inside - nothing to expand
#   CC_KEY='value'   literal
#   CC_KEY=value     letters, digits and _ . / : @ + , = - only
#   CC_ADMIN_USERS=("a" 'b' c)   one line, elements in those same forms
# each optionally followed by spaces and a # comment. A later line wins, as in
# the shell. CC_KEY must be a listed key: a typo is refused, not ignored.
_cc_re_dq='^(CC_[A-Z0-9_]+)="([^"$`\]*)"[[:space:]]*(#.*)?$'
_cc_re_sq="^(CC_[A-Z0-9_]+)='([^']*)'[[:space:]]*(#.*)?\$"
_cc_re_bare='^(CC_[A-Z0-9_]+)=([A-Za-z0-9_./:@+,=-]*)([[:space:]]+(#.*)?)?$'
_cc_re_arr='^CC_ADMIN_USERS=\((.*)\)[[:space:]]*(#.*)?$'
_cc_re_el="^[[:space:]]*(\"([^\"\$\`\\]*)\"|'([^']*)'|([A-Za-z0-9_.@-]+))"
_cc_keys=" $(printf '%s ' $CC_REQUIRED_KEYS $CC_OPTIONAL_KEYS)"
_cc_bad=""; _cc_n=0
while IFS= read -r _cc_l || [ -n "$_cc_l" ]; do
  _cc_n=$((_cc_n + 1))
  _cc_l="${_cc_l#"${_cc_l%%[![:space:]]*}"}"
  case "$_cc_l" in ''|'#'*) continue ;; esac
  if [[ $_cc_l =~ $_cc_re_dq ]] || [[ $_cc_l =~ $_cc_re_sq ]] || [[ $_cc_l =~ $_cc_re_bare ]]; then
    _cc_v="${BASH_REMATCH[1]}"; _cc_val="${BASH_REMATCH[2]}"
    case "$_cc_keys" in
      *" $_cc_v "*) printf -v "$_cc_v" '%s' "$_cc_val" ;;
      *) _cc_bad="line $_cc_n sets $_cc_v, which is not a config key"; break ;;
    esac
  elif [[ $_cc_l =~ $_cc_re_arr ]]; then
    _cc_rest="${BASH_REMATCH[1]}"; CC_ADMIN_USERS=()
    while [[ $_cc_rest =~ $_cc_re_el ]]; do
      CC_ADMIN_USERS+=("${BASH_REMATCH[2]}${BASH_REMATCH[3]}${BASH_REMATCH[4]}")
      _cc_rest="${_cc_rest:${#BASH_REMATCH[0]}}"
    done
    case "$_cc_rest" in *[![:space:]]*) _cc_bad="line $_cc_n: CC_ADMIN_USERS has an element that is not plain data" ; break ;; esac
  else
    _cc_bad="line $_cc_n is not a plain CC_KEY=value assignment (config.sh is read as data; nothing in it runs)"; break
  fi
done < "$cc_config_file"
if [ -n "$_cc_bad" ]; then
  echo "cc-config: $cc_config_file: $_cc_bad" >&2
  unset _cc_v _cc_val _cc_l _cc_n _cc_rest _cc_bad _cc_keys _cc_env_keep cc_config_file _cc_re_dq _cc_re_sq _cc_re_bare _cc_re_arr _cc_re_el
  return 1
fi
unset _cc_val _cc_l _cc_n _cc_rest _cc_bad _cc_keys _cc_re_dq _cc_re_sq _cc_re_bare _cc_re_arr _cc_re_el

# --- re-apply the environment's overrides -------------------------------------
for _cc_v in "${_cc_env_keep[@]}"; do
  printf -v "${_cc_v%%=*}" '%s' "${_cc_v#*=}"
done

# --- every key, or nothing ------------------------------------------------------
_cc_missing=""
for _cc_v in $CC_REQUIRED_KEYS; do
  [ -n "${!_cc_v:-}" ] || _cc_missing="$_cc_missing $_cc_v"
done
for _cc_v in $CC_OPTIONAL_KEYS; do
  [ -n "${!_cc_v+x}" ] || _cc_missing="$_cc_missing $_cc_v"
done
declare -p CC_ADMIN_USERS >/dev/null 2>&1 || _cc_missing="$_cc_missing CC_ADMIN_USERS"
if [ -n "$_cc_missing" ]; then
  echo "cc-config: $cc_config_file does not set:$_cc_missing" >&2
  echo "           Copy each from config.example.sh, where it is explained, and set it for this site." >&2
  unset _cc_v _cc_env_keep _cc_missing cc_config_file
  return 1
fi
unset _cc_v _cc_env_keep _cc_missing

# Derived — not settable, so there is exactly one spelling of each.
CC_POLICY="$CC_ETC/managed-settings.json"
CC_POLICY_SHA="$CC_ETC/managed-settings.json.sha256"
CC_CONTROL_LOCK="$CC_ETC/.cc-control.lock"   # held by cc-install.sh --apply and cc-update.sh apply/rollback
CC_ADMIN_POLICY="$CC_ETC_ADMIN/managed-settings.json"
CC_ADMIN_LOG="$CC_LOGDIR/admin.log"
CC_ACTIVITY_LOG_DIR="$CC_LOGDIR/activity"
CC_DENIED_LOG_DIR="$CC_LOGDIR/denied"
CC_STATUSLINE="$CC_SHARE/statusline.sh"
CC_LOGROTATE_FILE="$CC_LOGROTATE/claude-code"

# Where it came from, for the health check and the audit record to report.
case "$cc_config_file" in
  */config.example.sh) CC_CONFIG_SOURCE="$cc_config_file (sample values: this checkout has no config.sh)" ;;
  *)                   CC_CONFIG_SOURCE="$cc_config_file" ;;
esac
unset cc_config_file

# cc_config_find_repo — echo the repo root, or nothing if not run from one.
# Used by cc-install.sh to locate its own source tree.
cc_config_find_repo() {
  local d
  d="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || return 1
  [ -d "$d/settings" ] && [ -d "$d/bin" ] && printf '%s\n' "$d"
}
return 0
