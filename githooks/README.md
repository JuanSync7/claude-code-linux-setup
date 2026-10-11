# githooks/ — this repository's own guards

*Directory map — one line per file and where it is documented in full:
the repository [`README.md`](../README.md), "Working on this repository".*

**Opt-in by design.** Git installs nothing from a clone (a repo that executed
code on clone would be an attack), so `bin/cc-repo-setup.sh` must point
`core.hooksPath` here in **every** clone. A clone that skips it has no guard —
which is why CI re-runs the pre-commit scan tree-wide.

| File | When | What it does |
| --- | --- | --- |
| `pre-commit` | every commit | Blocks credential-shaped values, key/transcript filenames, >512 KB files. Matches values, not vocabulary. `CC_SCAN_ALL=1` scans all tracked files — the CI entry point |
| `post-merge` | after every pull | Re-runs `bin/cc-repo-perms.sh`: git records only owner-execute, so group modes and setgid need re-asserting on the shared filer. Advisory — never fails a merge |
| `post-checkout` | after checkout/branch switch | Same re-assertion, same reasoning |
