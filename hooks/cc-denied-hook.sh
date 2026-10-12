#!/bin/bash -p
# cc-denied-hook.sh - PermissionDenied logger for the Claude Code evidence layer.
#
# Registered in managed-settings.json as a PermissionDenied hook (matcher
# "Bash|Edit|Write|WebFetch"). Runs AS the engineer (mode 0755) whenever the
# permission system refuses a matching tool call. Appends ONE JSON line to $CC_LOGDIR/denied/<user>.jsonl.
#
# This is the ONLY source for the quarterly "review the allow list against what
# engineers actually needed" task: the telemetry metric code_edit_tool.decision
# covers the code-editing tools only, and a denial is as often a Bash call.
# A destination or command appearing repeatedly here is usually a missing
# autoMode.environment or permissions.allow entry, not misbehaviour.
#
# Same three rules as cc-audit-hook.sh: record SHAPE only (never file contents),
# always exit 0, depend only on bash + python3 + coreutils.

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
LOGDIR="$CC_DENIED_LOG_DIR"
USER_NAME="$(id -un 2>/dev/null || echo unknown)"
LOGFILE="${LOGDIR}/${USER_NAME}.jsonl"

# Same reasoning as cc-audit-hook.sh: 1733 prevents listing, not reading —
# the file mode does that. New logs are created 0600.
umask 077

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

detail = None
if isinstance(ti, dict):
    if "command" in ti:      detail = ti.get("command")
    elif "file_path" in ti:  detail = ti.get("file_path")
    elif "url" in ti:        detail = ti.get("url")
    elif "path" in ti:       detail = ti.get("path")

rec = {
    "ts": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    "user": sys.argv[2],
    "session": d.get("session_id", ""),
    # Where it happened and which call it was, named as cc-audit-hook.sh names
    # them: without these a refusal cannot be matched to its chat or retried
    # in place. A payload without them records them empty.
    "cwd": d.get("cwd", ""),
    "mode": d.get("permission_mode", ""),
    "call_id": d.get("tool_use_id", ""),
    "tool": tool,
    "detail": (cap(detail) if detail is not None else None),
    "detail_len": (len(str(detail)) if detail is not None else None),
    # Why it was refused, where Claude Code supplies it. Field names vary across
    # versions, so fall back gracefully rather than assume any single one.
    "denied_by": d.get("denied_by") or d.get("reason") or "",
    # THE REASON FIELD IS NOT STABLE ACROSS VERSIONS. Some builds put the
    # classifier rationale in it, usually category-prefixed
    # ("[Security Weaken] ..."); others put only the placeholder "Blocked by
    # classifier" there and carry the category in a sibling field. So capture
    # that field too, and capture the key NAMES of the payload: names only,
    # never values, so the content boundary this hook exists to hold is
    # untouched. When the vendor moves a field, the log says which keys arrived
    # instead of going quietly blind. Probe M14 of cc-bump-audit.sh asks this
    # at each version move.
    "category": d.get("category") or d.get("denied_category") or "",
    "payload_keys": sorted(d.keys()),
    "verdict": d.get("classifier_verdict") or d.get("verdict") or "",
}
append(sys.argv[1], json.dumps(rec, separators=(",", ":")) + "\n")
' "$LOGFILE" "$USER_NAME"
} 2>/dev/null

exit 0
