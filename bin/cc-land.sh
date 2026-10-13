#!/usr/bin/env bash
# cc-land.sh — move a GitHub repository's main to this clone's HEAD, once the
# checks main requires have passed on that exact commit.
#
# main is guarded by the ruleset in .github/rulesets/main.json: it cannot be
# deleted or force-pushed, and a commit reaches it only after the status
# checks the ruleset names have passed on that commit. This script is how a
# commit gets there without changing its hash:
#   1. read the remote's main; HEAD must be it, or descend from it
#   2. push HEAD to the branch land/<12 hex> and open a pull request for it
#      (or reuse the open one), so CI runs on HEAD
#   3. wait until every check main requires has passed: a failed, cancelled or
#      skipped one refuses, and one that never reports is not a pass
#   4. fast-forward the remote's main to HEAD and delete the branch; GitHub
#      marks the pull request merged when main reaches its head
# GitHub's merge buttons would write a new commit (squash, rebase or merge
# commit). The published clone and each host's install record name commits
# by hash, so main moves only by fast-forward, to the commit the checks ran on.
#
# The checks waited for are the ones GitHub enforces on main now, read from
# the remote - not from the file, which may not have been applied. A main that
# requires no checks is refused: nothing would gate the landing. --rules
# applies the file to the remote, creating the ruleset or updating it in place.
#
#   cc-land.sh [--repo DIR] [--remote NAME] [--timeout SECONDS] [--interval SECONDS]
#   cc-land.sh --rules [--repo DIR] [--remote NAME]
#
# Needs git, python3, and gh signed in to an account that may push to the
# repository (and, for --rules, administer it).
#
# Exit codes
#   0  main is at HEAD: landed now, or already was; (--rules) the remote's
#      ruleset was created or updated from the file
#   1  refused: a required check failed, was cancelled or was skipped; HEAD
#      is not a fast-forward of the remote's main; the remote has no main;
#      main requires no checks; a push, the pull request or the branch delete
#      failed; (--rules) more than one ruleset has the file's name, or the API
#      refused the ruleset
#   2  could not run: wrong arguments, not a git clone, gh or python3 missing,
#      the remote is not a GitHub repository, or (--rules) the ruleset file is
#      missing or not JSON with a name
#   3  cannot tell: the checks did not all finish within --timeout, or the
#      remote's main, its rules or its pull requests could not be read

set -uo pipefail

# Where the ruleset lives in a clone, and the branch it guards. Product
# conventions, not site values.
RULESET_FILE=".github/rulesets/main.json"
MAIN="main"
# How long to wait for CI, and how often to ask. A full run of the gating
# jobs takes minutes; an hour without a verdict means something is stuck.
TIMEOUT=3600
INTERVAL=30

usage() {
  cat >&2 <<'USAGE'
usage: cc-land.sh [--repo DIR] [--remote NAME] [--timeout SECONDS] [--interval SECONDS]
       cc-land.sh --rules [--repo DIR] [--remote NAME]
         --repo      the clone whose HEAD lands (default: the current directory)
         --remote    the GitHub remote (default: origin)
         --timeout   how long to wait for the required checks (default: 3600)
         --interval  seconds between asking for them (default: 30)
         --rules     apply .github/rulesets/main.json to the remote instead
USAGE
  exit 2
}
die()     { printf 'cc-land: %s\n' "$*" >&2; exit 2; }
refuse()  { printf 'cc-land: REFUSED - %s\n' "$*" >&2; exit 1; }
cannot()  { printf 'cc-land: CANNOT TELL - %s\n' "$*" >&2; exit 3; }
seconds() { [[ "$2" =~ ^[0-9]+$ ]] || { printf 'cc-land: %s takes a whole number of seconds, not: %s\n' "$1" "$2" >&2; usage; }; }

MODE=land REPO=. REMOTE=origin
while [ $# -gt 0 ]; do
  case "$1" in
    --rules)    MODE=rules ;;
    --repo)     [ $# -ge 2 ] || usage; REPO=$2; shift ;;
    --remote)   [ $# -ge 2 ] || usage; REMOTE=$2; shift ;;
    --timeout)  [ $# -ge 2 ] || usage; seconds "$1" "$2"; TIMEOUT=$2; shift ;;
    --interval) [ $# -ge 2 ] || usage; seconds "$1" "$2"; INTERVAL=$2; shift ;;
    *) usage ;;
  esac
  shift
done

command -v git >/dev/null 2>&1     || die "git is not on PATH"
command -v python3 >/dev/null 2>&1 || die "python3 is not on PATH"
command -v gh >/dev/null 2>&1      || die "gh is not on PATH - it opens the pull request and reads the checks"
TOP=$(git -C "$REPO" rev-parse --show-toplevel 2>/dev/null) || die "$REPO is not inside a git clone"

# owner/repo, from the URL as configured: insteadOf rewrites only where git
# connects, so a clone that fetches through a mirror still names its GitHub repo
URL=$(git -C "$TOP" config --get "remote.$REMOTE.url") || die "$TOP has no remote named $REMOTE"
SLUG=$(python3 - "$URL" <<'PY'
import re, sys
m = re.fullmatch(r"(?:https://github\.com/|ssh://git@github\.com/|git@github\.com:)([\w.-]+)/([\w.-]+?)(?:\.git)?/?", sys.argv[1])
if not m:
    sys.exit(1)
print(m.group(1) + "/" + m.group(2))
PY
) || die "remote $REMOTE is not a GitHub repository: $URL"

# ---- --rules: the file is the ruleset; the remote is made to match it
if [ "$MODE" = rules ]; then
  FILE="$TOP/$RULESET_FILE"
  [ -f "$FILE" ] || die "no $RULESET_FILE in $TOP"
  NAME=$(python3 -c 'import json, sys; n = json.load(open(sys.argv[1]))["name"]; assert isinstance(n, str) and n; print(n)' "$FILE" 2>/dev/null) \
    || die "$RULESET_FILE is not JSON with a name"
  LIST=$(gh api "repos/$SLUG/rulesets") || cannot "the rulesets of $SLUG could not be read"
  # the repository's own rulesets with this name; an organisation's are not ours to edit
  IDS=$(python3 -c '
import json, sys
for r in json.loads(sys.stdin.read()):
    if r.get("name") == sys.argv[1] and r.get("source_type", "Repository") == "Repository":
        print(r["id"])' "$NAME" <<< "$LIST") || cannot "the rulesets of $SLUG are not the list the API returns"
  case $(printf '%s' "$IDS" | grep -c .) in
    0) gh api "repos/$SLUG/rulesets" -X POST --input "$FILE" >/dev/null || refuse "GitHub refused the new ruleset $NAME"
       printf 'cc-land: created ruleset %s on %s\n' "$NAME" "$SLUG" ;;
    1) gh api "repos/$SLUG/rulesets/$IDS" -X PUT --input "$FILE" >/dev/null || refuse "GitHub refused the update to ruleset $NAME ($IDS)"
       printf 'cc-land: updated ruleset %s (%s) on %s\n' "$NAME" "$IDS" "$SLUG" ;;
    *) refuse "$SLUG has more than one ruleset named $NAME - remove the extra by hand" ;;
  esac
  exit 0
fi

# ---- 1. the remote's main, and HEAD's place relative to it
HEAD_SHA=$(git -C "$TOP" rev-parse --verify -q 'HEAD^{commit}') || die "$TOP has no commit at HEAD"
BRANCH="land/${HEAD_SHA:0:12}"
git -C "$TOP" ls-remote --exit-code "$REMOTE" "refs/heads/$MAIN" >/dev/null 2>&1
case $? in
  0) ;;
  2) refuse "$SLUG has no $MAIN to land on - its first commit is pushed by hand, before the ruleset" ;;
  *) cannot "$SLUG could not be reached" ;;
esac
git -C "$TOP" fetch -q "$REMOTE" "refs/heads/$MAIN" 2>/dev/null || cannot "$SLUG's $MAIN could not be fetched"
REMOTE_MAIN=$(git -C "$TOP" rev-parse --verify -q 'FETCH_HEAD^{commit}') || cannot "the fetched $MAIN is not a commit"

drop_branch() {  # the land branch, once main holds its commit
  git -C "$TOP" ls-remote --exit-code "$REMOTE" "refs/heads/$BRANCH" >/dev/null 2>&1
  case $? in
    0) git -C "$TOP" push -q "$REMOTE" ":refs/heads/$BRANCH" || refuse "$MAIN is at ${HEAD_SHA:0:12}, but the branch $BRANCH could not be deleted" ;;
    2) ;;
    *) cannot "$MAIN is at ${HEAD_SHA:0:12}, but whether $BRANCH is left could not be read" ;;
  esac
}
if [ "$REMOTE_MAIN" = "$HEAD_SHA" ]; then
  drop_branch
  printf 'cc-land: %s on %s is already %s\n' "$MAIN" "$SLUG" "${HEAD_SHA:0:12}"
  exit 0
fi
git -C "$TOP" merge-base --is-ancestor "$REMOTE_MAIN" "$HEAD_SHA"
case $? in
  0) ;;
  1) refuse "HEAD ${HEAD_SHA:0:12} does not descend from $SLUG's $MAIN ${REMOTE_MAIN:0:12} - rebase onto it first" ;;
  *) cannot "the ancestry of HEAD and $MAIN could not be read" ;;
esac

# ---- the checks main requires, as GitHub enforces them now
RULES=$(gh api "repos/$SLUG/rules/branches/$MAIN") || cannot "the rules on $SLUG's $MAIN could not be read"
REQUIRED=$(python3 -c '
import json, sys
names = set()
for r in json.loads(sys.stdin.read()):
    if r.get("type") == "required_status_checks":
        for c in r["parameters"]["required_status_checks"]:
            names.add(c["context"])
print("\n".join(sorted(names)))' <<< "$RULES") || cannot "the rules on $SLUG's $MAIN are not the list the API returns"
[ -n "$REQUIRED" ] || refuse "$SLUG's $MAIN requires no status checks, so nothing would gate this - apply the ruleset first (cc-land.sh --rules)"

# ---- 2. the branch and its pull request
git -C "$TOP" push -q "$REMOTE" "$HEAD_SHA:refs/heads/$BRANCH" || refuse "the push of $BRANCH failed"
pr_number() {  # the open pull request whose head is this commit
  local list
  list=$(gh pr list -R "$SLUG" --head "$BRANCH" --state open --json number,headRefOid) || return 3
  python3 -c '
import json, sys
n = [p["number"] for p in json.loads(sys.stdin.read()) if p["headRefOid"] == sys.argv[1]]
print(n[0] if len(n) == 1 else "")' "$HEAD_SHA" <<< "$list"
}
PR=$(pr_number) || cannot "the pull requests of $SLUG could not be read"
if [ -z "$PR" ]; then
  gh pr create -R "$SLUG" --base "$MAIN" --head "$BRANCH" \
     --title "$(git -C "$TOP" log -1 --format=%s "$HEAD_SHA")" \
     --body "Opened by bin/cc-land.sh so CI runs on this commit. $MAIN fast-forwards to it once the checks $MAIN requires have passed." \
     >/dev/null || refuse "the pull request for $BRANCH could not be opened"
  PR=$(pr_number) || cannot "the pull requests of $SLUG could not be read"
  [ -n "$PR" ] || cannot "the pull request for $BRANCH was opened but cannot be found"
fi
printf 'cc-land: pull request #%s (%s) waits for the required checks: %s\n' "$PR" "${HEAD_SHA:0:12}" "$(printf '%s' "$REQUIRED" | paste -sd, | sed 's/,/, /g')"

# ---- 3. wait for every required check to pass
# gh's exit status here mixes "failed" with "nothing reported yet", so the
# verdict is read from the JSON alone; output that is not a JSON list means no
# check has reported yet.
verdict() {
  python3 -c '
import json, sys
required = sys.argv[1].split("\n")
try:
    runs = json.loads(sys.stdin.read())
    assert isinstance(runs, list)
except (ValueError, AssertionError):
    print("wait"); sys.exit()
waiting = False
for name in required:
    buckets = [r.get("bucket") for r in runs if r.get("name") == name]
    for bad in ("fail", "cancel", "skipping"):
        if bad in buckets:
            print("refuse " + name + " " + bad); sys.exit()
    if not buckets or any(b != "pass" for b in buckets):
        waiting = True
print("wait" if waiting else "pass")' "$REQUIRED"
}
START=$SECONDS
while :; do
  CHECKS=$(gh pr checks "$PR" -R "$SLUG" --json name,bucket 2>/dev/null)
  V=$(verdict <<< "$CHECKS") || cannot "the checks on #$PR could not be judged"
  case "$V" in
    pass) break ;;
    refuse\ *) set -- $V
               refuse "the required check $2 on #$PR is $3 - $MAIN stays at ${REMOTE_MAIN:0:12}" ;;
    wait) [ $((SECONDS - START)) -lt "$TIMEOUT" ] \
            || cannot "the required checks on #$PR had not all passed after ${TIMEOUT}s - $MAIN stays at ${REMOTE_MAIN:0:12}; run again to keep waiting" ;;
    *) cannot "the checks on #$PR gave no verdict" ;;
  esac
  sleep "$INTERVAL"
done

# ---- 4. fast-forward main, then drop the branch
git -C "$TOP" push -q "$REMOTE" "$HEAD_SHA:refs/heads/$MAIN" || refuse "$SLUG refused the fast-forward of $MAIN to ${HEAD_SHA:0:12}"
drop_branch
printf 'cc-land: %s on %s is now %s (pull request #%s)\n' "$MAIN" "$SLUG" "${HEAD_SHA:0:12}" "$PR"
exit 0
