# Rules for Claude Code sessions working in this repository

This checkout is **shared** (its path is `CC_REPO` in `config.sh`; mode `2770`,
group-only, owned by the repository group, `CC_REPO_GROUP` in `config.sh`)
and it is also **the deployed tree** — a deploy is `git pull` then
`bin/cc-install.sh --apply`. Treat every change as production-adjacent.

**Read `GOAL.md` first.** It is the goal every change serves and the ranked
rules that settle a conflict between two good things — the higher rule wins,
and the cost goes in `internal/LIMITATIONS-AND-RISKS.md`. The rules below are
how this checkout is worked; `GOAL.md` is why.

## Permissions — git does not record them

- **After creating any file, and after any pull that adds files, run
  `bin/cc-repo-perms.sh --apply`.** New files are born with your umask — too
  open (a world-readable `internal/` on shared storage) or too closed
  (a colleague cannot edit what you added). The convention it asserts:
  directories `2770`, scripts `770`, other files `660`, group the repository
  group (`CC_REPO_GROUP` in `config.sh`).
  You can only fix files you own; that is why each session runs it for its own.
- **A new script's executable bit must be put into git by hand**:
  `git update-index --chmod=+x <file>`. Whether a `chmod` reaches the index
  depends on each clone's `core.fileMode`, which differs between clones, so
  record the bit explicitly; without it a fresh clone
  gets a script it cannot run. CI check [3] fails until this is done.
- Run `bin/cc-repo-setup.sh` once per clone — it enables the git hooks
  (pre-commit secret guard, post-merge/post-checkout perms). Git installs
  nothing on clone, and nothing enforces this step.

## Writing code

- Read `docs/CODING-STANDARD.md` first. In short: decide from exit codes and
  parsed data, never by matching text; every exit code is in a table in the
  script's header; every failure is handled and fails closed; values live in
  `config.sh`, and a secret, host or live path never has a default; a second
  run changes nothing; comments explain the code, not the change.

## Before committing

- **`bash bin/cc-ci-check.sh` must exit 0.** CI runs the identical script on
  every GitLab push and, on GitHub, on pushes to `main` and on pull requests;
  a red `main` is a stop-the-line defect.
- **`bash tests/test-cc-scripts.sh` must exit 0** when a change touches a
  script, a hook or the suite: CI runs it as a gating job too, as root in a
  Rocky 8 container, so a case that only fails as root still turns `main` red.
- Never commit `config.sh` (gitignored site values), any credential-shaped
  value, or a `*.jsonl` transcript. The pre-commit guard blocks these by value
  shape — if it blocks you wrongly, fix the guard, do not bypass it.
- `internal/` is the group-only record: never world-readable, never in
  `make dist`, and its state and risk registers are the state authority.

## Editing documents

- Read `docs/DOC-STYLE.md` first — five document types, 5W front matter, and
  **one canonical home per fact**. `docs/README.md` is the map of the set.
- `docs/REPO-MAP.md` is the coupling map: before changing any file, its table
  says what else must change with it and whether CI or only discipline holds
  the coupling. Missed couplings are this repo's main defect class.
- Every directory has a `README.md` map: update it **in the same commit** that
  adds, renames or removes a file in that directory.
- Corrections replace wrong text; never leave a wrong value next to its
  correction. No CHANGELOG.md — commit subjects are the changelog for repo
  edits. The one exception is a **vendor version transition**, which gets an
  entry in `docs/UPGRADES.md` — CI check [9] blocks a `requiredMinimumVersion`
  change that has no entry there.

## Deployment boundaries

- Sessions never read this checkout at runtime — hosts run the installed
  copies under `/etc` and `/usr/local`. Changing a file here changes no host
  until `cc-install.sh --apply` (or `make quickstart`) runs on that host.
- Never run `cc-install.sh --apply` from inside a privileged (`claude-admin`)
  session — the write goes through the bind mount and destroys the admin
  policy. The installer refuses; do not work around it.
- The policy files in `settings/` are never generated: a site's values are
  written in the files themselves. In a site's own repository they are
  concrete and CI refuses any placeholder; the public template edition carries
  only the placeholders its `template.json` lists (`docs/PUBLISHING.md` §1).
  Do not add a placeholder, and do not add a third policy variant.
