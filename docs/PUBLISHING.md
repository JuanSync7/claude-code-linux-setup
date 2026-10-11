# Publishing — the public template edition of this repository

| | |
| --- | --- |
| **What** | How this repository becomes a public, site-neutral template: what `bin/cc-publish.sh` exports, what it substitutes, what it refuses, and the CI scan that keeps a published tree clean after the fact |
| **Who** | The maintainer who publishes. No prior knowledge of the tool is assumed; knowledge of git is |
| **When** | Each time the public edition should catch up with this repository. The tool is idempotent: an unchanged source publishes nothing |
| **Where** | Any clone, unprivileged. The site map lives outside every clone, in the publisher's home |
| **Why** | The repository is written to describe any host ([`GOAL.md`](../GOAL.md) rule 5), so the public edition needs no rewrite — only the few values a deployed policy must spell for real, swapped for placeholders, and a scan that proves nothing identifying is left |
| **Status** | Implemented. The suite section `cc-publish.sh` covers every refusal below |
| **Owner** | The maintainer |

---

## 1. The two editions

| | A site edition — a site's own repository | The public template edition |
| --- | --- | --- |
| Policy and `config.example.sh` | Concrete: the site's real values. CI check [2] refuses any placeholder | `REPLACE-WITH-*` placeholders where a site value goes, each listed in `template.json` |
| `internal/` | The site's registers and evidence | Three blank registers from `publish/overlay/internal/` |
| `template.json` | Absent | Present: `{"placeholders": {"<name>": {"meaning": "<what a site puts there>", "example": "<a neutral value of the same form>"}}}`. Its presence is what makes CI accept the listed placeholders |
| `TEMPLATE.md` | Absent | Present: the instructions for filling the template |
| `LICENSE` | Absent | Present: the MIT licence the public edition is released under |
| `docs/SANDBOX-DECISION.md` | The site's own decision record, with its investigation | A generic record of the same decision, in the same sections, from `publish/overlay/docs/` |

The installer's placeholder gate is the same in both: `cc-install.sh` and `make quickstart`
refuse a policy that still carries a `REPLACE-WITH-*` marker. A template cannot be installed
half-filled; an adopter fills every placeholder, deletes `template.json` and `TEMPLATE.md`, and CI is strict again.

While `template.json` is present, two CI checks and the test suite change what they run on:

- **[2]** accepts the placeholders `template.json` lists and no others, and fails on a listed
  placeholder that no file uses. The list cannot drift from the tree in either direction.
  A placeholder is read whole, so a listed name does not excuse a longer unlisted one that
  begins with it.
- **[6]** stages the tree twice: as it stands, which the installer must refuse, and as a copy
  with every listed placeholder filled, which must stage whole. The two trees differ only by
  the placeholders, so together they show the placeholders are what was refused.
- **`tests/test-cc-scripts.sh`** runs on a filled copy and reports that run's result. Its
  cases install the policy, and the installer would refuse the unfilled one in every case.

The filled copy comes from `bin/cc-template-fill.sh DEST`: every tracked file except
`template.json` and `TEMPLATE.md`, with each listed placeholder replaced by its `example`.
The example has the form the real value will have — an address where an address goes — so a
check that reads the value behaves as it will on a real site. The script is for tests only,
and it never changes the clone it reads.

`bin/cc-template-fill.sh --list` prints the listed names. It is the one reader of
`template.json`: check [2] takes its names from it, so what CI accepts and what gets filled
cannot be two readings of the same file. A name must be `REPLACE-WITH-` followed by capitals,
digits and hyphens; each entry must carry a `meaning` and an `example`.

| Exit code | Meaning |
| --- | --- |
| `0` | The filled copy was written to `DEST`; or, with `--list`, the names were printed |
| `1` | Refused, and `DEST` is as it was: no tracked `template.json`; a list that cannot be read, is empty, names something that is not a placeholder, or has an entry without a `meaning` and an `example`; a `DEST` that already holds files; or a copy that failed part-way |
| `2` | Could not run: not exactly one argument, an unknown option, or not run from inside a git clone |

## 2. The site map — the one private input

A JSON file **outside every clone**, mode `0600`, default `~/.config/cc-publish/site.json`:

```json
{
  "replace": [["<real string>", "<placeholder or neutral value>"]],
  "deny":    ["<term>"]
}
```

- **`replace`** — exact, case-sensitive strings, applied longest first. In a `.json` file the
  string is also matched in its JSON-escaped form, so a value inside a policy string is found.
- **`deny`** — terms that must appear nowhere in the published tree: contents, file names,
  the commit message, the author. Matched case-insensitively, as a whole word wherever a term
  begins or ends with a letter or digit. Every `replace` source string is denied as well.

The map is refused when it is readable by group or others, is not valid JSON, or has an empty
`deny` list: a scan against nothing would pass everything. It is never committed and never
printed — a hit names the file and the line, never the term. Read from the map, a hit also
names the **entry number**, so the publisher can find the term in their own file; read from
`CC_PUBLISH_DENY` (§4) it names neither the entry nor the size of the list, because that run's
output is a public CI log.

## 3. What `bin/cc-publish.sh` does, in order

```
bin/cc-publish.sh --out DIR --author "Name <email>" [--map FILE] [--message TEXT] [--remote URL] [--push]
bin/cc-publish.sh --scan [--map FILE]          # scan the tracked files of the current clone
```

1. **Export** the committed tree at `HEAD` (`git archive`), without `internal/`. Uncommitted
   edits and untracked files never reach the output.
2. **Overlay** `publish/overlay/` on top — `template.json`, `TEMPLATE.md`, `LICENSE`, the blank registers
   and the generic `docs/SANDBOX-DECISION.md`. A file in the overlay replaces the exported file at the same path.
3. **Substitute** the map's `replace` pairs.
4. **Scan** every file, every path, the commit message and the author against the deny list,
   then run the secret guard (`githooks/pre-commit`, whole-tree mode) over the result.
   A tree with no files is a failure, not a pass.
5. **Check references**: a document (`.md`) may name a path under `internal/` only when the
   published tree holds that path — the directory itself, or a file the overlay supplies. A
   reference to a record that stayed behind is refused with its file and line.
6. **Verify** by running the output's own `bin/cc-ci-check.sh` and `tests/test-cc-scripts.sh`
   inside it. Both must exist and exit 0.
7. **Commit** into `DIR` (cloned from `--remote` when absent, else `git init`) as `--author`.
   There is no fallback to the git identity of the machine: that identity is the site's.
   An unchanged tree makes no commit.
8. **Push** to `origin main` only when `--push` is given.

Any refusal stops before the commit. When step 6 fails, the last lines of the failing run are
printed and the whole output is kept in a file the refusal names.

| Exit code | Meaning |
| --- | --- |
| `0` | Published; or the tree was unchanged and nothing needed committing; or, with `--scan`, no denied term was found |
| `1` | Refused: a deny hit, a secret, a document naming an unpublished record, a failed verification, or nothing to publish — nothing was committed. Or `--push` failed: the commit stays in `DIR`, unpushed, and the same command pushes it |
| `2` | Could not run: wrong arguments, not inside a git clone, or a site map that is missing, readable by others, not JSON, or has no deny terms |

## 4. The CI scan of the public repository

Each push to the public repository runs `bin/cc-publish.sh --scan` in CI (the `deny-scan` job of
`.github/workflows/ci.yml`) with the deny list held as the repository secret
**`PUBLISH_DENYLIST`** (one term per line, handed to the script as `CC_PUBLISH_DENY`), so a change made directly on
the public side is scanned too. The publishing repository also sets the
repository variable **`PUBLISH_SCAN`** to `required`: with it, a missing secret fails the job. Without
it — a fork that is filling the template and has no deny list of its own — the job says there is
nothing to scan against and passes. In the site edition, which may name its own site, the job does nothing. Pull requests
from forks receive no secrets, so the job skips there and the scan runs again on the merge push.

```
python3 -c 'import json,os; print("\n".join(json.load(open(os.path.expanduser("~/.config/cc-publish/site.json")))["deny"]))' \
  | gh secret set PUBLISH_DENYLIST -R <owner>/<public-repo>
gh variable set PUBLISH_SCAN --body required -R <owner>/<public-repo>
```

A repository secret, not an environment secret: environments add approval gates around a
deployment, and this job deploys nothing.

## 5. Republishing

```
bin/cc-publish.sh --out ~/pub/<public-repo> --author "Name <email>"          # build, scan, verify, commit
git -C ~/pub/<public-repo> show --stat HEAD                                  # review
bin/cc-publish.sh --out ~/pub/<public-repo> --author "Name <email>" --push   # same tree, now pushed
```

The second run finds the tree unchanged, commits nothing, and pushes the reviewed commit.
