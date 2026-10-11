#!/bin/bash -p
# cc-redact-hook.sh - PostToolUse redaction of credential-shaped text.
#
# WHY THIS EXISTS
# The permission rules and cc-secret-guard-hook.sh judge what Claude ASKS for: a
# command line, a file path. Neither sees what a program the command starts does,
# so `python3 report.py` that prints a private key puts that key in front of the
# model. The OS sandbox would have covered it and is off
# (docs/SANDBOX-DECISION.md). This hook judges what comes BACK: it runs after
# every tool call and, where the result holds credential-shaped text, replaces
# that text before the model sees it, via hookSpecificOutput.updatedToolOutput.
#
# WHAT IT DOES NOT DO - state this plainly when reporting coverage:
#   * A program that sends a secret somewhere itself never routes it through a
#     tool result; that path is the network layer's, and a site records how
#     it is covered in internal/LIMITATIONS-AND-RISKS.md.
#   * It matches SHAPES: private keys (PEM or PGP, whole or cut short, or a
#     bare OpenSSH or DER body read without its BEGIN line), cloud and SaaS
#     tokens with a fixed prefix, JWTs, a password inside a URL, and base64 or
#     hex copies of any of those, wrapped or not. A password with no shape, a
#     fragment from the middle of a key body, or another encoding (xxd's
#     grouped hex and its ASCII column, url-safe base64) passes.
#   * Text the model reads is gone for the model too: a file it rewrites from a
#     redacted read would carry the marker, not the secret. Edit fails instead
#     (its old_string no longer matches), which is the safe direction.
#
# SAFETY RULES, load-bearing - do not break these:
#   * The rewrite keeps the tool's output SHAPE exactly - same keys, same types.
#     Measured on the pinned build: an updatedToolOutput of another shape is
#     dropped and the ORIGINAL output reaches the model. Only string values change.
#   * Fail closed where it can: if the scan raises, every string longer than
#     WITHHOLD_MIN is withheld rather than passed. Input that is not JSON has no
#     shape to rebuild, so it alone passes unchanged (suite RD8).
#   * Always exit 0. A PostToolUse exit cannot un-run the tool; a non-zero one
#     only adds noise to every call.
#   * Log the event, never the text: tool, kinds and count to the activity log.
#   * A missing or broken site config never stops redaction - only the log line
#     and the support contact depend on it.
#
# Registered in managed-settings.json PostToolUse, matcher "*" (every tool,
# MCP tools included). Install: /usr/local/sbin/cc-redact-hook.sh, 0755
# root:root (runs as the engineer).

# The engineer's environment must not steer what runs this hook: it is a
# control against that same engineer. `-p` above makes bash ignore BASH_ENV and
# ENV (which run before line 1) and exported functions; the absolute
# interpreter path skips a `bash` planted first on PATH; PATH is reset before
# the first command; python runs isolated (-I: no PYTHONPATH, no user site).
# A preloaded library (LD_PRELOAD) is not stopped here - nothing inside a
# script can stop it. That is the residual limit of a hook as a control.
PATH=/usr/bin:/bin; export PATH

# Site config, read only from the installed copy, with every CC_* in the
# engineer's environment cleared first. The suite rewrites the one path below.
for _v in ${!CC_@}; do unset "$_v"; done
LOGFILE=""
CONTACT='IT support (contact not configured: CC_SUPPORT_CONTACT)'
if . /etc/claude-code/cc-config.sh >/dev/null 2>&1; then
  [ -n "${CC_ACTIVITY_LOG_DIR:-}" ] && LOGFILE="$CC_ACTIVITY_LOG_DIR/$(id -un 2>/dev/null || echo unknown).jsonl"
  [ -n "${CC_SUPPORT_CONTACT:-}" ] && CONTACT="$CC_SUPPORT_CONTACT"
fi
umask 077

INPUT="$(cat 2>/dev/null)"
printf '%s' "$INPUT" | /usr/bin/python3 -I -c '
import base64, binascii, datetime, json, os, re, stat, sys

logfile, user, contact = sys.argv[1], sys.argv[2], sys.argv[3]
WITHHOLD_MIN = 64

KEY = r"-----BEGIN [A-Z0-9 ]*PRIVATE KEY(?: BLOCK)?-----"
KINDS = [
    # A whole key, or one cut short (head -c, a truncated read): to the END line
    # if there is one, else to the end of the text.
    ("private-key", re.compile(KEY + r"[\s\S]*?(?:-----END [A-Z0-9 ]*PRIVATE KEY(?: BLOCK)?-----|\Z)")),
    # The OpenSSH key body without its BEGIN line: base64 of "openssh-key-v1".
    ("private-key", re.compile(r"b3BlbnNzaC1rZXktdjE[A-Za-z0-9+/=\r\n]*")),
    ("aws-key-id", re.compile(r"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b")),
    ("aws-secret", re.compile(r"(?i)(?<=aws_secret_access_key)\s*[=:]\s*\S+")),
    ("anthropic-key", re.compile(r"sk-ant-[A-Za-z0-9_-]{20,}")),
    ("api-key", re.compile(r"\bsk-(?:proj-)?[A-Za-z0-9_-]{32,}")),
    ("github-token", re.compile(r"\b(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{40,})")),
    ("gitlab-token", re.compile(r"\bglpat-[A-Za-z0-9_-]{20,}")),
    ("slack-token", re.compile(r"\bxox[abprs]-[A-Za-z0-9-]{10,}")),
    ("google-api-key", re.compile(r"\bAIza[0-9A-Za-z_-]{35}")),
    ("jwt", re.compile(r"\beyJ[A-Za-z0-9_-]{8,}\.eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}")),
    ("url-password", re.compile(r"(?<=://)[^/\s:@]+:[^/\s@]+(?=@)")),
]
# A run continues over separators: `base64` wraps at 76 and a PEM body at 64,
# and one line alone decodes to a fragment no pattern recognises. A separator is
# whitespace (line breaks, YAML indentation, spaces) or a JSON-escaped \n or \r,
# none of which is in either alphabet. No word boundaries: a run glued to a word
# ("payload<b64>", "0x<hex>") is still a run; the decoder tries each alignment.
SEP = r"(?:\s|\\[nr])+"
B64 = re.compile(r"[A-Za-z0-9+/]{40,}(?:" + SEP + r"[A-Za-z0-9+/]+)*={0,2}")
HEX = re.compile(r"[0-9a-fA-F]{48,}(?:" + SEP + r"[0-9a-fA-F]+)*")

def plain(text, found):
    for kind, rx in KINDS:
        def cut(m, kind=kind):
            found.append(kind)
            return "[REDACTED by IT policy: %s]" % kind
        text = rx.sub(cut, text)
    return text

def der_private(raw):
    # A DER private key: SEQUENCE, then INTEGER version 0 or 1 (PKCS#1, PKCS#8,
    # SEC1). A certificate or a public key opens with a nested SEQUENCE instead.
    if len(raw) < 8 or raw[0] != 0x30:
        return False
    i = 2 if raw[1] < 0x80 else 2 + (raw[1] & 0x7F)
    return raw[i:i + 3] in (b"\x02\x01\x00", b"\x02\x01\x01")

def secret_in(raw):
    if der_private(raw) or raw.startswith(b"openssh-key-v1"):
        return "private-key"
    inner = []
    plain(raw.decode("latin-1"), inner)
    return inner[0] if inner else None

def encoded(rx, decodes, kind, text, found):
    def cut(m):
        run = m.group(0)
        compact = re.sub(SEP, "", run)
        # The whole run first, then each piece alone (pieces from unrelated
        # sources joined into one run can misalign each other).
        for piece in [compact] + re.split(SEP, run):
            for raw in decodes(piece):
                what = secret_in(raw)
                if what:
                    found.append(kind + ":" + what)
                    return "[REDACTED by IT policy: %s %s]" % (kind, what)
        return run
    return rx.sub(cut, text)

def b64(s):
    # Each alignment: a run glued to a word starts up to 3 characters early.
    for off in range(4):
        t = s[off:].rstrip("=")
        t = t[:len(t) - len(t) % 4] if len(t) % 4 == 1 else t
        try:
            yield base64.b64decode(t + "=" * (-len(t) % 4), validate=True)
        except Exception:
            pass

def hexes(s):
    for off in range(2):
        t = s[off:]
        try:
            yield binascii.unhexlify(t[:len(t) - len(t) % 2])
        except Exception:
            pass

def scan(text):
    found = []
    text = plain(text, found)
    text = encoded(B64, b64, "base64", text, found)
    text = encoded(HEX, hexes, "hex", text, found)
    return text, found

def walk(x, fn):
    # Rebuild the same structure: only str leaves change, so the shape the
    # binary checks is the shape it sent.
    if isinstance(x, str):
        return fn(x)
    if isinstance(x, dict):
        return {k: walk(v, fn) for k, v in x.items()}
    if isinstance(x, list):
        return [walk(v, fn) for v in x]
    return x

def log(tool, kinds):
    if not logfile:
        return
    rec = {"ts": datetime.datetime.now(datetime.timezone.utc).isoformat(), "user": user,
           "session": d.get("session_id", ""), "cwd": d.get("cwd", ""), "event": "redaction",
           "tool": tool, "kinds": sorted(set(kinds)), "count": len(kinds)}
    try:
        fd = os.open(logfile, os.O_WRONLY | os.O_APPEND | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600)
    except OSError:
        return
    try:
        st = os.fstat(fd)
        if stat.S_ISREG(st.st_mode) and st.st_uid == os.getuid():
            os.write(fd, (json.dumps(rec, separators=(",", ":")) + "\n").encode())
    finally:
        os.close(fd)

try:
    d = json.loads(sys.stdin.read())
    resp = d["tool_response"]
except Exception:
    raise SystemExit(0)
tool = str(d.get("tool_name", ""))

kinds = []
def fn(s):
    new, found = scan(s)
    kinds.extend(found)
    return new
try:
    new = walk(resp, fn)
    note = ("Part of this tool output was replaced by IT policy because it looked like a "
            "credential (%s). Do not try to retrieve it another way. If it is not a "
            "secret, raise it with %s." % (", ".join(sorted(set(kinds))), contact))
except Exception:
    new = walk(resp, lambda s: s if len(s) < WITHHOLD_MIN else "[withheld by IT policy: redaction check failed]")
    kinds = ["check-failed"]
    note = ("This tool output was withheld because the IT redaction check failed. "
            "Report it to %s." % contact)
if not kinds:
    raise SystemExit(0)
try:
    log(tool, kinds)
except Exception:
    pass
print(json.dumps({"hookSpecificOutput": {"hookEventName": "PostToolUse",
                                         "additionalContext": note,
                                         "updatedToolOutput": new}}))
' "$LOGFILE" "$(id -un 2>/dev/null || echo unknown)" "$CONTACT" 2>/dev/null
exit 0
