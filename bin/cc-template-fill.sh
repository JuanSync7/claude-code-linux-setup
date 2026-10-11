#!/usr/bin/env bash
# cc-template-fill.sh - write a filled copy of a template edition, for testing.
#
# A template edition (docs/PUBLISHING.md) carries placeholders where a site's
# values go, and the installer refuses it until they are filled. That refusal
# is correct, and it also means nothing that installs - CI check [6], the test
# suite - can run on the template as it stands. This script produces what they
# run on instead: a copy of the clone it is run in, with every placeholder
# replaced by its example value.
#
# template.json, at the root of the clone, is the list:
#   {"placeholders": {"REPLACE-WITH-NAME": {"meaning": "...", "example": "..."}}}
# "meaning" tells a site what to put there; "example" is the neutral value the
# copy carries, in the form the real one will have (an address where an address
# goes), so checks that read the value behave as they will on a real site. The
# copy holds every tracked file except template.json and TEMPLATE.md, so it is
# a site edition and the checks treat it strictly.
#
# This script is also the one reader of template.json. CI check [2] takes the
# names from --list, so what the check accepts and what gets filled cannot be
# two different readings of the same file. A name is REPLACE-WITH- followed by
# capitals, digits and hyphens, ending on a capital or digit; anything else in
# the list is refused, because the check removes listed names from the policy
# text before it looks for markers, and a looser name would remove more.
#
# It never changes the clone it reads. It is for tests: a real site fills the
# placeholders with its own values, by hand (TEMPLATE.md).
#
#   cc-template-fill.sh DEST      DEST must not exist, or be an empty directory
#   cc-template-fill.sh --list    print the listed placeholder names, one per line
#
# Exit codes
#   0  the filled copy was written to DEST; or (--list) the names were printed
#   1  refused, and DEST is as it was: the clone has no tracked template.json,
#      template.json cannot be read, lists no placeholder, lists a name that
#      is not a placeholder or an entry without a meaning and an example, DEST
#      already holds files, or the copy failed part-way (a DEST this run
#      created is removed)
#   2  could not run: not exactly one argument, an unknown option, or not run
#      from inside a git clone

set -uo pipefail

# What every placeholder name begins with. The installer's gate and CI check
# [2] look for the same marker; it is the product's convention, not a site value.
PLACEHOLDER_PREFIX="REPLACE-WITH-"

usage()  { printf 'usage: cc-template-fill.sh DEST     (DEST must not exist, or be an empty directory)\n       cc-template-fill.sh --list   (print the placeholder names template.json lists)\n' >&2; exit 2; }
die()    { printf 'cc-template-fill: %s\n' "$*" >&2; exit 2; }
refuse() { printf 'cc-template-fill: REFUSED - %s\n' "$*" >&2; exit 1; }

[ $# -eq 1 ] || usage
LIST=0 DEST=""
case "$1" in
  --list) LIST=1 ;;
  -*)     usage ;;
  *)      DEST=$1 ;;
esac
SRC=$(git rev-parse --show-toplevel 2>/dev/null) || die "not inside a git clone - run it from the clone to fill"

git -C "$SRC" ls-files --error-unmatch template.json >/dev/null 2>&1 \
  || refuse "$SRC has no tracked template.json - it is not a template edition, and needs no filling"

# The list is checked before anything is created, so a refusal leaves no trace.
NAMES=$(python3 - "$SRC/template.json" "$PLACEHOLDER_PREFIX" <<'PY'
import json, string, sys
path, prefix = sys.argv[1], sys.argv[2]
try:
    listed = json.load(open(path, encoding="utf-8"))["placeholders"]
except (OSError, ValueError, KeyError, TypeError) as e:
    sys.exit("template.json cannot be read as {\"placeholders\": {...}}: %s" % e)
if not isinstance(listed, dict) or not listed:
    sys.exit("template.json lists no placeholder")
ALLOWED = set(string.ascii_uppercase + string.digits + "-")
def is_placeholder(name):
    rest = name[len(prefix):]
    return name.startswith(prefix) and rest != "" and set(rest) <= ALLOWED and rest[-1] != "-"
wrong = sorted(n for n in listed if not is_placeholder(n))
if wrong:
    sys.exit("template.json lists a name that is not %sNAME (capitals, digits, hyphens): %s" % (prefix, ", ".join(repr(n) for n in wrong)))
def is_text(v):
    return isinstance(v, str) and v != ""
def is_entry(e):
    return (isinstance(e, dict) and is_text(e.get("meaning")) and is_text(e.get("example"))
            and prefix.rstrip("-") not in e["example"])
wrong = sorted(n for n in listed if not is_entry(listed[n]))
if wrong:
    sys.exit("template.json: each entry needs a \"meaning\" and an \"example\" that is not itself a placeholder: %s" % ", ".join(wrong))
print("\n".join(sorted(listed)))
PY
) || refuse "the placeholder list is unusable (reason above)"

if [ "$LIST" -eq 1 ]; then
  printf '%s\n' "$NAMES"
  exit 0
fi

CREATED=0
if [ -e "$DEST" ]; then
  [ -d "$DEST" ] || refuse "$DEST exists and is not a directory"
  [ -z "$(find "$DEST" -mindepth 1 -print -quit)" ] || refuse "$DEST already holds files - give a new or empty directory"
else
  mkdir -p "$DEST" || refuse "could not create $DEST"
  CREATED=1
fi
# A copy that fails part-way must not be mistaken for a filled tree.
undo() { [ "$CREATED" -eq 1 ] && rm -rf "$DEST"; }

git -C "$SRC" ls-files -z -- . ':!template.json' ':!TEMPLATE.md' \
  | tar -C "$SRC" --null -T - -cf - | tar -xf - -C "$DEST" \
  || { undo; refuse "could not copy the tracked files into $DEST"; }

# Longest name first: a placeholder that begins with another's whole name
# would otherwise be cut in two.
COUNT=$(python3 - "$DEST" "$SRC/template.json" <<'PY'
import json, os, sys
dest, path = sys.argv[1:3]
listed = json.load(open(path, encoding="utf-8"))["placeholders"]
fills = [(n.encode(), listed[n]["example"].encode()) for n in sorted(listed, key=len, reverse=True)]
changed = 0
for root, _dirs, files in os.walk(dest):
    for name in files:
        path = os.path.join(root, name)
        if os.path.islink(path):
            continue
        with open(path, "rb") as f:
            data = f.read()
        filled = data
        for placeholder, value in fills:
            filled = filled.replace(placeholder, value)
        if filled != data:
            with open(path, "wb") as f:
                f.write(filled)
            changed += 1
print(changed)
PY
) || { undo; refuse "could not fill the placeholders under $DEST"; }

printf 'cc-template-fill: %s placeholder(s) filled in %s file(s) under %s\n' "$(printf '%s\n' "$NAMES" | wc -l)" "$COUNT" "$DEST"
exit 0
