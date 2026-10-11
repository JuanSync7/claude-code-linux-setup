#!/bin/bash -p
# cc-audit-hook.sh - PreToolUse activity logger for the Claude Code evidence layer.
#
# Registered in managed-settings.json as a PreToolUse hook matching
# Bash|Edit|Write|WebFetch. Runs AS the engineer (mode 0755), once per matching
# tool call. Appends ONE JSON line to $CC_LOGDIR/activity/<user>.jsonl.
#
# Three load-bearing properties (see runbook 11.7 - do not break these):
#   1. Records the SHAPE of a call only: tool, and the command / file path / URL.
#      NEVER the file contents or prompt. tool_input.file_text, .content,
#      .new_string, .old_string are deliberately never read. This is the line
#      between an audit trail and employee monitoring. Suite cases AH2/AH2b/AH3
#      assert it with a canary: content fields are supplied alongside the path
#      and must not appear in the log. If you widen the field whitelist below,
#      the canary is what stops a new elif leaking file text into the log.
#   2. ALWAYS exits 0. A PreToolUse exit of 2 BLOCKS the tool, and any other
#      non-zero exit surfaces a warning on every call — so a logging failure
#      must never leak out as either. Every failure path below ends in exit 0.
#   3. Depends only on bash + python3 + coreutils (jq is not assumed present).

# The engineer's environment must not steer what runs this hook: it is a
# control against that same engineer. `-p` above makes bash ignore BASH_ENV and
# ENV (which run before line 1) and exported functions; the absolute
# interpreter path skips a `bash` planted first on PATH; PATH is reset before
# the first command; python runs isolated (-I: no PYTHONPATH, no user site).
# A preloaded library (LD_PRELOAD) is not stopped here - nothing inside a
# script can stop it. That is the residual limit of a hook as a control.
PATH=/usr/bin:/bin; export PATH

# Site config, read only from the installed copy: this runs as the engineer, so
# every CC_* in their environment is cleared first and none can steer it.
# The test suite rewrites the one path below to a fixture loader.
for _v in ${!CC_@}; do unset "$_v"; done
# No usable config: log nothing and still exit 0 (rule 2) - the daily health
# check reports the broken config; a hook must never turn it into a block.
. /etc/claude-code/cc-config.sh >/dev/null 2>&1 || exit 0
LOGDIR="$CC_ACTIVITY_LOG_DIR"
USER_NAME="$(id -un 2>/dev/null || echo unknown)"
LOGFILE="${LOGDIR}/${USER_NAME}.jsonl"

# The directory's 1733 stops others LISTING or deleting files, but reading is
# governed by the FILE mode, and the names are guessable (<user>.jsonl). 0600
# on creation keeps one engineer's history out of another's reach.
umask 077

# Everything is wrapped so that ANY failure (no python3, bad JSON, unwritable
# log dir, full disk) still exits 0. Read stdin once; hand it to python3, which
# whitelists fields and prints a single compact JSON line, which we append.
INPUT="$(cat 2>/dev/null)"

{
  printf '%s' "$INPUT" | /usr/bin/python3 -I -c '
import sys, json, datetime

# Append to the log only if it is a regular file this user owns. The directory
# is 1733, so anyone may create <victim>.jsonl first: as a symlink (O_NOFOLLOW
# refuses it), a FIFO (O_NONBLOCK makes the open fail or the type check skip
# it, never hang the call), or a file they own and can read (the uid check).
# Anything else is left alone, silently - a hook never fails a call over its
# own logging; the weekly report names a planted file (LOG-07).
def append(path, line):
    import os, stat
    try:
        fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600)
    except OSError:
        return
    try:
        st = os.fstat(fd)
        if stat.S_ISREG(st.st_mode) and st.st_uid == os.getuid():
            os.write(fd, line.encode("utf-8", "replace"))
    finally:
        os.close(fd)

# Cap the shape at 2000 characters by keeping both ENDS: a cap that keeps only
# the head lets padding push the part that matters out of the record.
def cap(v, n=2000):
    v = str(v)
    if len(v) <= n:
        return v
    return v[: n // 2] + "...[%d chars cut]..." % (len(v) - n) + v[-(n // 2):]
try:
    d = json.loads(sys.stdin.read() or "{}")
except Exception:
    d = {}
ti = d.get("tool_input") or {}
tool = d.get("tool_name", "")

# Whitelist ONLY shape fields. Never touch file_text/content/new_string/old_string.
detail = None
if isinstance(ti, dict):
    if "command" in ti:      detail = ti.get("command")        # Bash
    elif "file_path" in ti:  detail = ti.get("file_path")      # Edit / Write / Read
    elif "url" in ti:        detail = ti.get("url")            # WebFetch
    elif "path" in ti:       detail = ti.get("path")           # misc file tools

rec = {
    "ts": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    "user": sys.argv[2],
    "session": d.get("session_id", ""),
    "cwd": d.get("cwd", ""),
    "mode": d.get("permission_mode", ""),
    "tool": tool,
    "detail": detail,
}
# Coerce detail to a string and cap it so a pathological argument cannot bloat
# the log; still shape, never content. detail_len is the real length.
if rec["detail"] is not None:
    rec["detail_len"] = len(str(rec["detail"]))
    rec["detail"] = cap(rec["detail"])
append(sys.argv[1], json.dumps(rec, separators=(",", ":")) + "\n")
' "$LOGFILE" "$USER_NAME"
} 2>/dev/null

exit 0
