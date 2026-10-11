#!/usr/bin/env bash
# cc-publish.sh — build the public template edition of this repository.
#
# The contract is docs/PUBLISHING.md; this header is only the shape of it.
# The committed tree at HEAD is exported without internal/, the overlay in
# publish/overlay/ is laid on top, the site map's `replace` pairs swap the
# site's real values for placeholders, and nothing is committed until:
#   - no file, file name, author or message carries a `deny` term,
#   - no document names a path under internal/ that the output does not hold,
#   - the secret guard (githooks/pre-commit, whole tree) passes, and
#   - the output's own bin/cc-ci-check.sh and tests/test-cc-scripts.sh pass.
#
# The site map is the one private input. It lives outside every clone, must
# be 0600-or-tighter, and is never printed: a hit names the file and the line,
# never the term. Read from the map, a hit also names the deny ENTRY NUMBER;
# read from CC_PUBLISH_DENY it does not, because the public CI logs that run.
#
#   cc-publish.sh --out DIR --author "Name <email>" [--map FILE] [--remote URL]
#                 [--message TEXT] [--push]
#   cc-publish.sh --scan [--map FILE]     scan this clone's tracked files; with
#                                         no --map, terms come from CC_PUBLISH_DENY
#                                         (one per line - the CI secret)
#
# There is no fallback to the machine's git identity for --author: on a site
# host that identity is the site's, and it would sign the public commit.
#
# Exit codes
#   0  published; or the tree was unchanged and nothing needed committing; or
#      (--scan) no denied term was found
#   1  refused: a denied term, a secret, a document naming a record that is
#      not published, a failed verification, or nothing to publish - nothing
#      was committed; or --push failed, and the commit stays in DIR unpushed
#   2  could not run: wrong arguments, not inside a git clone, or a site map
#      that is missing, readable by others, not JSON, or has no deny terms

set -uo pipefail

# The directory that holds a site's own records. It is never exported; the
# overlay supplies blank registers in its place. A product convention, not a
# site value.
PRIVATE_DIR="internal"

usage() {
  cat >&2 <<'USAGE'
usage: cc-publish.sh --out DIR --author "Name <email>" [--map FILE] [--remote URL]
                     [--message TEXT] [--push]
       cc-publish.sh --scan [--map FILE]
         --scan checks this clone's tracked files; with no --map, the terms
         come from CC_PUBLISH_DENY (one per line - the CI secret)
USAGE
  exit 2
}
die()    { printf 'cc-publish: %s\n' "$*" >&2; exit 2; }
refuse() { printf 'cc-publish: REFUSED - %s\n' "$*" >&2; exit 1; }

MODE=publish OUT="" MAP="" REMOTE="" AUTHOR="" MESSAGE="" PUSH=0 MAP_GIVEN=0
[ $# -gt 0 ] || usage
while [ $# -gt 0 ]; do
  case "$1" in
    --scan)    MODE=scan ;;
    --out)     [ $# -ge 2 ] || usage; OUT=$2; shift ;;
    --map)     [ $# -ge 2 ] || usage; MAP=$2; MAP_GIVEN=1; shift ;;
    --remote)  [ $# -ge 2 ] || usage; REMOTE=$2; shift ;;
    --author)  [ $# -ge 2 ] || usage; AUTHOR=$2; shift ;;
    --message) [ $# -ge 2 ] || usage; MESSAGE=$2; shift ;;
    --push)    PUSH=1 ;;
    -h|--help) usage ;;
    *) die "unknown argument: $1" ;;
  esac
  shift
done
# Default: where the site map is kept when --map is not given. It is a place,
# not a value from the map - a missing or loose file there is refused below.
DEFAULT_MAP="$HOME/.config/cc-publish/site.json"
[ -n "$MAP" ] || MAP=$DEFAULT_MAP

SRC=$(git rev-parse --show-toplevel 2>/dev/null) || die "not inside a git clone"

# The map, the substitution and the scan. Subcommands:
#   terms                    print nothing; exit 2 with the reason if the map is unusable
#   substitute <dir>         apply `replace` to every file under <dir>
#   scan <dir>               scan the NUL-separated relative paths on stdin, plus
#                            the strings in CC_PUBLISH_EXTRA ("label=value" lines)
# Terms come from the map at $CC_PUBLISH_MAP, or, when that is empty, from
# CC_PUBLISH_DENY. An unusable map is exit 2; a hit is exit 1.
PY='
import json, os, re, stat, sys

def fail(msg, code=2):
    print("cc-publish: " + msg, file=sys.stderr); sys.exit(code)

def load():
    path = os.environ.get("CC_PUBLISH_MAP", "")
    if not path:
        terms = [t.strip() for t in os.environ.get("CC_PUBLISH_DENY", "").splitlines() if t.strip()]
        if not terms:
            fail("no deny terms: give --map, or set CC_PUBLISH_DENY (one term per line)")
        return [], terms
    try:
        st = os.stat(path)
    except OSError as e:
        fail("cannot read the site map %s: %s" % (path, e.strerror))
    if st.st_mode & (stat.S_IRWXG | stat.S_IRWXO):
        fail("the site map %s is readable by group or others - chmod 600 it" % path)
    try:
        with open(path, encoding="utf-8") as f:
            m = json.load(f)
    except ValueError as e:
        fail("the site map %s is not valid JSON: %s" % (path, e))
    rep, deny = m.get("replace", []), m.get("deny", [])
    if not (isinstance(rep, list) and all(isinstance(r, list) and len(r) == 2 and all(isinstance(x, str) and x for x in r) for r in rep)):
        fail("the site map: replace must be a list of [from, to] string pairs")
    if not (isinstance(deny, list) and deny and all(isinstance(t, str) and t.strip() for t in deny)):
        fail("the site map: deny must be a non-empty list of terms - a scan against nothing passes everything")
    rep = sorted(rep, key=lambda r: -len(r[0]))
    return rep, deny + [r[0] for r in rep]

def pattern(term):
    pre = r"(?<![A-Za-z0-9])" if term[0].isalnum() else ""
    post = r"(?![A-Za-z0-9])" if term[-1].isalnum() else ""
    return re.compile(pre + re.escape(term) + post, re.IGNORECASE)

def read(path):
    with open(path, "rb") as f:
        return f.read().decode("utf-8", "surrogateescape")

rep, terms = load()
cmd = sys.argv[1]
if cmd == "terms":
    sys.exit(0)
if cmd == "substitute":
    root = sys.argv[2]
    for d, dirs, files in os.walk(root):
        dirs[:] = [x for x in dirs if not (d == root and x == ".git")]
        for name in files:
            p = os.path.join(d, name)
            if os.path.islink(p):
                continue
            text = read(p); new = text
            for a, b in rep:
                if p.endswith(".json"):
                    ja, jb = json.dumps(a, ensure_ascii=False)[1:-1], json.dumps(b, ensure_ascii=False)[1:-1]
                    new = new.replace(ja, jb)
                    ja, jb = json.dumps(a)[1:-1], json.dumps(b)[1:-1]
                    new = new.replace(ja, jb)
                new = new.replace(a, b)
            if new != text:
                with open(p, "wb") as f:
                    f.write(new.encode("utf-8", "surrogateescape"))
    sys.exit(0)
if cmd == "scan":
    root = sys.argv[2]
    pats = [pattern(t) for t in terms]
    paths = [p for p in sys.stdin.buffer.read().decode("utf-8", "surrogateescape").split("\0") if p]
    if not paths:
        fail("REFUSED - there are no files to scan, and a scan of nothing is not a pass", 1)
    hits = 0
    # Which entry matched, and how many there are, describe the list. With a
    # map that is the publisher reading their own file; with CC_PUBLISH_DENY
    # the list is a CI secret and this output is a public log, so neither is
    # printed.
    from_map = bool(os.environ.get("CC_PUBLISH_MAP", ""))
    def entry(i):
        return "  deny entry #%d" % i if from_map else ""
    def mask(s):
        for p in pats:
            s = p.sub("***", s)
        return s
    for rel in paths:
        for i, p in enumerate(pats, 1):
            if p.search(rel):
                print("  HIT    %s (file name)%s" % (mask(rel), entry(i))); hits += 1
        full = os.path.join(root, rel)
        if os.path.islink(full) or not os.path.isfile(full):
            continue
        text = read(full)
        for i, p in enumerate(pats, 1):
            for m in p.finditer(text):
                print("  HIT    %s:%d%s" % (mask(rel), text.count("\n", 0, m.start()) + 1, entry(i))); hits += 1
    for line in os.environ.get("CC_PUBLISH_EXTRA", "").splitlines():
        label, _, value = line.partition("=")
        for i, p in enumerate(pats, 1):
            if p.search(value):
                print("  HIT    the %s%s" % (label, entry(i))); hits += 1
    against = "%d deny entries" % len(pats) if from_map else "the deny list"
    print("cc-publish: %d file(s) scanned against %s, %d hit(s)" % (len(paths), against, hits))
    sys.exit(1 if hits else 0)
if cmd == "refs":
    # A document that names a path under the private directory is checked
    # against the tree itself: the path is there, or the reference is dead.
    # Finding the name in prose needs a text search; the verdict does not.
    root, private = sys.argv[2], sys.argv[3]
    paths = [p for p in sys.stdin.read().split("\0") if p]
    named = re.compile(r"(?<![A-Za-z0-9_-])" + re.escape(private) + r"/[A-Za-z0-9_./-]*")
    docs = [p for p in paths if p.endswith(".md")]
    dead = 0
    for rel in docs:
        full = os.path.join(root, rel)
        if os.path.islink(full) or not os.path.isfile(full):
            continue
        text = read(full)
        for m in named.finditer(text):
            target = m.group(0).rstrip(".")
            if not os.path.exists(os.path.join(root, target)):
                print("  DEAD   %s:%d  names %s, which the published tree does not hold" % (rel, text.count("\n", 0, m.start()) + 1, target)); dead += 1
    print("cc-publish: %d document(s) checked for references into %s/, %d dead" % (len(docs), private, dead))
    sys.exit(1 if dead else 0)
fail("internal: unknown subcommand " + cmd)
'
py() {
  if [ "$MODE" = scan ] && [ "$MAP_GIVEN" -eq 0 ]; then
    CC_PUBLISH_MAP="" python3 -c "$PY" "$@"
  else
    CC_PUBLISH_MAP="$MAP" python3 -c "$PY" "$@"
  fi
}

# ---- --scan: the public repository's CI entry point ---------------------------
if [ "$MODE" = scan ]; then
  py terms || exit 2
  git -C "$SRC" ls-files -z | py scan "$SRC"
  exit $?
fi

# ---- publish: every usage check before anything is written ---------------------
[ -n "$OUT" ] || die "--out DIR is required"
[ -n "$AUTHOR" ] || die "--author \"Name <email>\" is required: the machine's git identity is never used"
[[ "$AUTHOR" =~ ^([^\<\>]+)\ \<([^\<\>@\ ]+@[^\<\>\ ]+)\>$ ]] || die "--author must be \"Name <email>\", got: $AUTHOR"
A_NAME=${BASH_REMATCH[1]} A_MAIL=${BASH_REMATCH[2]}
py terms || exit 2
if [ -e "$OUT" ]; then
  git -C "$OUT" rev-parse --git-dir >/dev/null 2>&1 || die "--out $OUT exists and is not a git clone"
  [ -z "$(git -C "$OUT" status --porcelain)" ] || die "--out $OUT has uncommitted changes - commit or discard them first"
fi
git -C "$SRC" rev-parse --verify --quiet HEAD >/dev/null || die "the source has no commit to publish"
[ -n "$MESSAGE" ] || MESSAGE="Publish the template edition"

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

# 1. export the committed tree, without internal/
git -C "$SRC" archive HEAD | tar -x -C "$STAGE" || refuse "git archive of HEAD failed"
rm -rf "${STAGE:?}/$PRIVATE_DIR"
[ -n "$(find "$STAGE" -type f -print -quit)" ] || refuse "the source has no file to publish outside internal/"

# 2. the overlay, as committed
[ -d "$STAGE/publish/overlay" ] && cp -a "$STAGE/publish/overlay/." "$STAGE/"

# 3. substitute
py substitute "$STAGE" || refuse "substitution failed"

# 4. scan: contents, names, author, message; then the secret guard
git -C "$STAGE" init -q && git -C "$STAGE" add -A || refuse "could not index the staged tree"
say_scan=$(git -C "$STAGE" ls-files -z | CC_PUBLISH_EXTRA=$(printf 'author=%s\ncommit message=%s\n' "$AUTHOR" "$MESSAGE") py scan "$STAGE")
rc=$?
printf '%s\n' "$say_scan"
[ "$rc" -eq 0 ] || refuse "denied terms in the published tree - nothing committed"
[ -f "$STAGE/githooks/pre-commit" ] || refuse "the tree has no githooks/pre-commit, so no secret guard can run"
( cd "$STAGE" && CC_SCAN_ALL=1 bash githooks/pre-commit ) || refuse "the secret guard blocked the published tree - nothing committed"

# 4b. a document must not point at a record that stayed behind
git -C "$STAGE" ls-files -z | py refs "$STAGE" "$PRIVATE_DIR" \
  || refuse "a document names a path under $PRIVATE_DIR/ that the published tree does not hold - reword it, or add the file to publish/overlay/. Nothing committed"

# 5. verify with the output's own checks, as a commit, the way CI sees it
git -C "$STAGE" -c user.name="$A_NAME" -c user.email="$A_MAIL" commit -qm "$MESSAGE" \
  || refuse "could not commit the staged tree for verification"
for v in bin/cc-ci-check.sh tests/test-cc-scripts.sh; do
  [ -f "$STAGE/$v" ] || refuse "the tree has no $v - an unverified tree is not published"
  printf 'cc-publish: verifying with %s\n' "$v"
  # The staged tree is removed on exit, so a failed verifier's whole output is
  # kept beside it: the last lines alone rarely hold the failing case.
  if ! ( cd "$STAGE" && bash "$v" ) > "$STAGE/.git/verify.out" 2>&1; then
    VLOG=$(mktemp "${TMPDIR:-/tmp}/cc-publish-verify.XXXXXX") && cp "$STAGE/.git/verify.out" "$VLOG" \
      || refuse "$v failed in the published tree, and its output could not be saved - nothing committed"
    tail -n 40 "$VLOG" >&2
    refuse "$v failed in the published tree - nothing committed. Full output: $VLOG"
  fi
done

# 6. commit into the output clone
if [ ! -e "$OUT" ]; then
  if [ -n "$REMOTE" ]; then
    git clone -q "$REMOTE" "$OUT" 2>/dev/null || die "could not clone --remote $REMOTE"
  else
    git init -q "$OUT" || die "could not create $OUT"
  fi
  git -C "$OUT" rev-parse -q --verify HEAD >/dev/null || git -C "$OUT" symbolic-ref HEAD refs/heads/main
fi
find "$OUT" -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf {} +
( cd "$STAGE" && git ls-files -z | xargs -0 -r cp --parents -P -t "$OUT" ) || refuse "could not copy the tree into $OUT"
git -C "$OUT" add -A
if git -C "$OUT" rev-parse -q --verify HEAD >/dev/null && git -C "$OUT" diff --cached --quiet; then
  printf 'cc-publish: unchanged - %s already holds this tree\n' "$OUT"
else
  GIT_COMMITTER_NAME="$A_NAME" GIT_COMMITTER_EMAIL="$A_MAIL" \
    git -C "$OUT" -c user.name="$A_NAME" -c user.email="$A_MAIL" commit -qm "$MESSAGE" \
    || refuse "the commit in $OUT failed"
  printf 'cc-publish: committed %s in %s\n' "$(git -C "$OUT" rev-parse --short HEAD)" "$OUT"
fi

# 7. push, only when asked
if [ "$PUSH" -eq 1 ]; then
  git -C "$OUT" remote get-url origin >/dev/null 2>&1 || die "--push: $OUT has no origin remote (give --remote when creating it)"
  git -C "$OUT" push -q origin HEAD:refs/heads/main || refuse "the push to origin failed"
  printf 'cc-publish: pushed to origin main\n'
fi
exit 0
