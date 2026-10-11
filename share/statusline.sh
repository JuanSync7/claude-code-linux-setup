#!/usr/bin/env bash
# Claude Code status line - the site default, shipped to every user.
# Installed by cc-install.sh to /usr/local/share/claude-code/statusline.sh (0755 root:root,
# local disk) and wired up by the managed statusLine key, so every session gets it with no
# per-user step. Editing this one file changes the default for every user on the host.
#
# Segments: model | context tokens + % | session cost (Bedrock only) | rate limits | session
#           duration | git | python env | docker | pytest
#
# YOUR OWN STATUS LINE. Put an executable-or-not script at ~/.claude/statusline.sh and it
# replaces this one: it receives the same JSON on stdin and whatever it prints is shown.
# An empty script hides the status line. It is used only if it is a regular file owned by
# you and writable by nobody else - otherwise a colleague who could edit it could run
# commands as you on every prompt. CC_STATUSLINE_USER names a different file. A statusLine
# in your own settings.json has no effect: the managed key always wins, which is why the
# override is a file this script hands over to rather than a setting.
#
# Portability notes for the shared fleet:
#   - Uses /usr/bin/python3 for JSON parsing because jq is not assumed to be installed.
#   - Nothing user-specific is hardcoded; every path comes from the JSON on stdin or $HOME.
#   - Safe on NFS homes: git runs with --no-optional-locks (a GLOBAL option - it must come
#     before the subcommand) so a read-only or slow working tree is never locked.
#   - Pytest summary file can be overridden with CC_PYTEST_RESULT for shared setups.
input=$(cat)
user_sl="${CC_STATUSLINE_USER:-$HOME/.claude/statusline.sh}"
if [ -f "$user_sl" ] && [ ! -L "$user_sl" ] && [ -O "$user_sl" ] \
   && [ -z "$(find "$user_sl" -maxdepth 0 -perm /022 2>/dev/null)" ]; then
  printf '%s' "$input" | exec bash "$user_sl"
fi
# debug dump (uncomment to capture raw JSON):
# echo "$input" > /tmp/claude-statusline-debug.json
fmt_tok() {
  local n=$1
  if [ -z "$n" ] || [ "$n" = "null" ] || [ "$n" = "0" ]; then echo "0"; return; fi
  if   [ "$n" -ge 1000000 ] 2>/dev/null; then awk "BEGIN { printf \"%.1fM\", $n/1000000 }"
  elif [ "$n" -ge 1000    ] 2>/dev/null; then awk "BEGIN { printf \"%.0fk\",  $n/1000    }"
  else echo "$n"
  fi
}
# Parse all JSON fields with Python (jq is not assumed to be installed)
eval "$(printf '%s' "$input" | /usr/bin/python3 -c '
import json, sys, shlex
try:
    data = json.loads(sys.stdin.read())
except Exception:
    data = {}
model = data.get("model") or {}
cw    = data.get("context_window") or {}
cu    = cw.get("current_usage") or {}
rl    = data.get("rate_limits") or {}
cost  = data.get("cost") or {}
ws    = data.get("workspace") or {}
cur_in = sum([
    cu.get("input_tokens") or 0,
    cu.get("cache_creation_input_tokens") or 0,
    cu.get("cache_read_input_tokens") or 0,
])
pairs = [
    ("J_model_id",   str(model.get("id") or "")),
    ("J_model_name", str(model.get("display_name") or "")),
    ("J_total_in",   str(cw.get("total_input_tokens") or 0)),
    ("J_total_out",  str(cw.get("total_output_tokens") or 0)),
    ("J_ctx_size",   str(cw.get("context_window_size") or 0)),
    ("J_used_pct",   str(cw.get("used_percentage") or "")),
    ("J_cur_in",     str(cur_in)),
    ("J_cur_out",    str(cu.get("output_tokens") or 0)),
    ("J_five_pct",   str((rl.get("five_hour") or {}).get("used_percentage") or "")),
    ("J_seven_pct",  str((rl.get("seven_day") or {}).get("used_percentage") or "")),
    ("J_cost",       "%.2f" % cost["total_cost_usd"] if cost.get("total_cost_usd") is not None else ""),
    ("J_dur_ms",     str(int(cost.get("total_duration_ms") or 0))),
    ("J_cwd",        str(ws.get("current_dir") or data.get("cwd") or "")),
]
for k, v in pairs:
    print(k + "=" + shlex.quote(v))
')"
# 1. Model
model_str=""
if [ -n "$J_model_id" ]; then
  model_short="${J_model_id#claude-}"
  model_str="model:${model_short}"
elif [ -n "$J_model_name" ]; then
  model_str="model:${J_model_name}"
fi
# 2. Session / context-window usage
if [ -z "$J_used_pct" ] && [ "$J_total_in" -gt 0 ] 2>/dev/null && [ "$J_ctx_size" -gt 0 ] 2>/dev/null; then
  J_used_pct=$(awk "BEGIN { printf \"%.1f\", $J_total_in * 100 / $J_ctx_size }")
fi
sess_str=""
if [ "$J_ctx_size" -gt 0 ] 2>/dev/null; then
  if [ -n "$J_used_pct" ]; then
    pct_label=$(printf "%.0f%%" "$J_used_pct")
    tok_label="tok:$(fmt_tok "$J_total_in")/$(fmt_tok "$J_ctx_size")"
    sess_str="${tok_label} ${pct_label}"
    [ "$J_cur_out" -gt 0 ] 2>/dev/null && sess_str="${sess_str} out:$(fmt_tok "$J_cur_out")"
  else
    sess_str="ctx:$(fmt_tok "$J_ctx_size")"
  fi
elif [ "$J_total_in" -gt 0 ] 2>/dev/null || [ "$J_total_out" -gt 0 ] 2>/dev/null; then
  sess_str="in:$(fmt_tok "$J_total_in") out:$(fmt_tok "$J_total_out")"
fi
# 3a. Session cost - Bedrock only. On a claude.ai subscription the session is not billed
# per token, so a dollar figure there would be notional and misread as spend.
cost_str=""
case "${CLAUDE_CODE_USE_BEDROCK:-}" in
  ''|0|false) ;;
  *) [ -n "$J_cost" ] && cost_str="cost:\$${J_cost}" ;;
esac
# 3b. Rate limits (subscription logins only; the field is absent on Bedrock)
rate_str=""
if [ -n "$J_five_pct" ]; then
  rate_str=$(printf "5h:%.0f%%" "$J_five_pct")
fi
if [ -n "$J_seven_pct" ]; then
  seven_str=$(printf "7d:%.0f%%" "$J_seven_pct")
  [ -n "$rate_str" ] && rate_str="${rate_str} ${seven_str}" || rate_str="$seven_str"
fi
# 4. Session duration - wall clock since the session started, from the JSON. (The
# transcript's mtime is the time of the last write, which is "now" on every render.)
up_str=""
if [ "$J_dur_ms" -gt 0 ] 2>/dev/null; then
  elapsed=$(( J_dur_ms / 1000 ))
  if   [ "$elapsed" -ge 3600 ]; then up_str=$(printf "up:%dh%dm" $(( elapsed/3600 )) $(( (elapsed%3600)/60 )))
  elif [ "$elapsed" -ge 60   ]; then up_str=$(printf "up:%dm"    $(( elapsed/60  )))
  else                               up_str=$(printf "up:%ds"    "$elapsed")
  fi
fi
# 5. Git
cwd="$J_cwd"
git_str=""
g() { git --no-optional-locks -C "$cwd" "$@"; }
if [ -n "$cwd" ] && g rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  branch=$(g symbolic-ref --short HEAD 2>/dev/null || g rev-parse --short HEAD 2>/dev/null)
  dirty=""
  # diff --quiet exits 1 for "changes", >1 for an error - only 1 means dirty.
  g diff --quiet 2>/dev/null;          [ $? -eq 1 ] && dirty="*"
  [ -z "$dirty" ] && { g diff --cached --quiet 2>/dev/null; [ $? -eq 1 ] && dirty="*"; }
  untracked=$(g ls-files --others --exclude-standard 2>/dev/null | head -1)
  [ -n "$untracked" ] && dirty="${dirty}?"
  ahead=$(g rev-list --count "HEAD@{u}..HEAD" 2>/dev/null || echo "")
  behind=$(g rev-list --count "HEAD..HEAD@{u}" 2>/dev/null || echo "")
  git_str="git:${branch}${dirty}"
  [ -n "$ahead"  ] && [ "$ahead"  -gt 0 ] 2>/dev/null && git_str="${git_str} +${ahead}"
  [ -n "$behind" ] && [ "$behind" -gt 0 ] 2>/dev/null && git_str="${git_str} -${behind}"
fi
# 6. Python
py_str=""
if [ -n "$cwd" ] && [ -x "${cwd}/.venv/bin/python" ]; then
  py_ver=$("${cwd}/.venv/bin/python" --version 2>/dev/null | awk '{print $2}' | cut -d. -f1,2)
  [ -n "$py_ver" ] && py_str="py:${py_ver}(venv)"
elif [ -n "$cwd" ] && [ -f "${cwd}/.python-version" ]; then
  pinned=$(head -1 "${cwd}/.python-version" | tr -d '[:space:]')
  [ -n "$pinned" ] && py_str="py:${pinned}(pin)"
elif [ -n "$VIRTUAL_ENV" ]; then
  py_ver=$("${VIRTUAL_ENV}/bin/python" --version 2>/dev/null | awk '{print $2}' | cut -d. -f1,2)
  [ -n "$py_ver" ] && py_str="py:${py_ver}" || py_str="venv:$(basename "$VIRTUAL_ENV")"
else
  py_ver=$(/usr/bin/python3 --version 2>/dev/null | awk '{print $2}' | cut -d. -f1,2)
  [ -n "$py_ver" ] && py_str="py:${py_ver}"
fi
# 7. Docker
docker_str=""
if [ -f "/.dockerenv" ]; then
  docker_str="docker"
elif grep -qE '(docker|containerd|kubepods)' /proc/1/cgroup 2>/dev/null; then
  docker_str="docker"
fi
# 8. Pytest
pytest_str=""
result_file="${CC_PYTEST_RESULT:-$HOME/.claude/pytest-result}"
if [ -f "$result_file" ]; then
  pytest_line=$(cat "$result_file" 2>/dev/null)
  [ -n "$pytest_line" ] && pytest_str="tests:${pytest_line}"
elif [ -n "$cwd" ]; then
  nodeids_file="${cwd}/.pytest_cache/v/cache/nodeids"
  lastfailed_file="${cwd}/.pytest_cache/v/cache/lastfailed"
  if [ -f "$nodeids_file" ]; then
    total=$(/usr/bin/python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))))' "$nodeids_file" 2>/dev/null)
    failed=0
    [ -f "$lastfailed_file" ] && failed=$(/usr/bin/python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))))' "$lastfailed_file" 2>/dev/null || echo 0)
    if [ -n "$total" ] && [ "$total" -gt 0 ] 2>/dev/null; then
      passed=$(( total - failed )); pytest_str="tests:${passed}/${total}"
    fi
  fi
fi
# Assemble
parts=()
[ -n "$model_str"  ] && parts+=("$(printf '\e[35m%s\e[0m' "$model_str")")
[ -n "$sess_str"   ] && parts+=("$(printf '\e[32m%s\e[0m' "$sess_str")")
[ -n "$cost_str"   ] && parts+=("$(printf '\e[32m%s\e[0m' "$cost_str")")
[ -n "$rate_str"   ] && parts+=("$(printf '\e[33m%s\e[0m' "$rate_str")")
[ -n "$up_str"     ] && parts+=("$(printf '\e[36m%s\e[0m' "$up_str")")
[ -n "$git_str"    ] && parts+=("$(printf '\e[33m%s\e[0m' "$git_str")")
[ -n "$py_str"     ] && parts+=("$(printf '\e[34m%s\e[0m' "$py_str")")
[ -n "$docker_str" ] && parts+=("$(printf '\e[34m%s\e[0m' "$docker_str")")
[ -n "$pytest_str" ] && parts+=("$(printf '\e[33m%s\e[0m' "$pytest_str")")
sep=" | "; result=""
for part in "${parts[@]}"; do
  [ -z "$result" ] && result="$part" || result="${result}${sep}${part}"
done
printf '%s' "$result"
