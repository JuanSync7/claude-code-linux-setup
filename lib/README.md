# lib/ — the configuration loader and its cross-check

*Directory map — the loader is documented in full at
[`docs/QUICKSTART.md`](../docs/QUICKSTART.md) §9.*

| File | What it is |
| --- | --- |
| `cc-config.sh` | The loader every script and the Makefile **source** (never execute — 0644 in git is deliberate, CI check [3] enforces it). No defaults of its own: it loads the first file found (one file only) — `$CC_CONFIG` → `/etc/claude-code/config.sh` (wins on a deployed host) → the repo's `config.sh` → the repo's `config.example.sh` (labelled *sample values*) — and refuses, naming the keys, a file that does not set every key. It **parses** that file as data and never sources it (root loads it from a group-writable checkout): any line but a comment or a plain `CC_KEY=value` assignment, or an unknown key, is refused by line number. An exported `CC_*` wins for that run and is listed in `CC_CONFIG_OVERRIDES` |
| `cc-coupling.py` | Holds the files that cannot read config — both policies, the systemd units (the AWS posture unit too), the logrotate stanza, the sudoers drop-in — to config.sh: their paths must sit under `CC_SBIN` / `CC_SHARE` / `CC_LOGDIR`, sudoers must name `%CC_ADMIN_GROUP`, the banner must name `CC_SUPPORT_CONTACT`, and a value the site moved away from the template must not still be spelled at the template's value. Run by CI check [12] (on the template), `make quickstart` and `cc-install.sh` gate 4c (on the site's config). Never installed |

Site values themselves live in `config.sh` at the repo root (gitignored;
created from `config.example.sh` by `make config` or `bin/cc-repo-setup.sh`).
The key lists here (`CC_REQUIRED_KEYS`, `CC_OPTIONAL_KEYS`) and the keys set in
`config.example.sh` must match in both directions — CI check [7] fails the day
one is added without the other, or a default creeps back into the loader.
