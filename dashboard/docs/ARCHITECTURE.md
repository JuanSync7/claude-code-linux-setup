# Architecture

## What it is for

IT needs one place to see how a Claude Code fleet is used and where the policy
bites: who uses how much, what that would cost at API prices against what the
seats cost, what was blocked and by which layer, and how much chat history
people keep. The dashboard reads what the hosts already write; it changes nothing.

## How data flows

```
 hook logs (activity/, denied/)  ─┐
                                   ├─ ingest (cron) ─▶ SQLite store ─▶ server ─▶ browser
 ~/.claude/projects/**.jsonl     ─┘        │                             │
                                     prune (cron)                   GET only, token
```

- **ingest** reads each file past its checkpoint (inode, generation, byte offset)
  and commits the rows and the new offset together, so a crash or a second run
  never counts twice. Only complete lines are read: a line still being written
  waits for its newline. A file that shrank or changed inode was rotated and is
  read again from the start under a new generation.
- **What is kept is shape, never content**: token counts and model per API
  message, and the names of slash commands, skills and plugins. Prompt text,
  replies and command arguments are never stored; a test plants a canary in
  each and checks the store file does not contain it. The audit hook's logged
  commands are stored, as they are in the logs, so the store is created `0600`.
- **Tokens** are one row per user and API message id: streaming writes a
  message more than once and the last line wins. The user is part of the key
  because the id is whatever the transcript says, and one person copying
  another's id must not overwrite that person's row.
- **The store carries a schema version** (`SCHEMA_VERSION` in `store.py`),
  raised whenever a key or what a row means changes. A store written under any
  other version is refused by every command (exit 2, untouched) with a message
  to move it aside and ingest again: the logs are the source, the store is
  rebuilt from them.
- **A limit hit is one per window, not one per record.** Claude Code retries
  against a limit and each retry logs a rejection; the event key is the person,
  the limit kind and the window's reset time, so a burst of retries counts once.
- **Cost** comes from `prices_per_mtok` in the config, matched by the longest
  model-family prefix. A model with no price makes the total *unpriced*,
  never a smaller number that looks complete.
- **Bedrock** is recognised by `bedrock_model_pattern` on the model id. That is
  an inference from the id, not a billing record. An inference-profile ARN
  carries an AWS account id, so it is reduced to a fixed label at ingest.
- **Seats** come from the config and are prorated to the window (30-day month).

## Severities and categories

Closed sets in `fleetdash/vocab.py`. Retention is per severity, so short-lived
noise (`pass`) can go in two weeks while `deny`, `redact` and `quota` are kept
for a year: `prune` applies an age limit and a row cap to each.

A transcript denial the person caused (`user-rejected`, `interrupted`) is
`info`, not a block. Any other kind, including one never seen before, is `deny`.

## Who can see it

Loopback is shared on a multi-user host, so the server is not protected by
binding to `127.0.0.1` alone:

- every request needs the token printed at start-up (`?token=` once, then an
  `HttpOnly`, `SameSite=Strict` cookie, or an `X-Fleetdash-Token` header);
- a `Host` header other than loopback is refused, against DNS rebinding;
- only GET is served, and static files cannot leave `web/`;
- the config refuses a non-loopback `bind`, because there is no TLS.

## What the figures can be trusted for

Every file ingest reads was written by the person it describes: their own
transcripts, and hook logs the hooks append as that person. So the figures are
**self-reported**. Someone can edit their own files to show less use, and
nothing here can tell. Logs that people cannot edit need the hooks to write
off-host, which is work for the control plane and its IT owners.

What ingest does stop is one person's file changing another person's figures,
or stopping the run for everyone:

- each file is opened once without following a symlink, and checked and read
  through that one descriptor, so it cannot be swapped between the check and
  the read. A symlink, a hard link (link count above one) or anything other
  than a regular file is not read;
- with `verify_file_owner` on, a hook log must be owned by the user it is named
  for, and a transcript by the user its path names. The log directories are
  sticky and world-writable, so anyone can create `<victim>.jsonl`;
- a file refused for any of these reasons becomes a `log-integrity` event under
  the user it claims to be for, and is listed as skipped;
- a record that cannot be read writes nothing, is counted in `bad_lines`, and
  ingest goes on. A field of the wrong JSON type is stored as text; a token
  count that is not a whole number, a slash command with no name, or a line
  longer than `LINE_MAX` makes the record bad. A line that has no end is not
  held in memory while it grows.
- a timestamp must be UTC ISO 8601, as Claude Code and the hooks write it, and
  no more than a day ahead. Times are compared as text, so `zzz` or year 9999
  would sit inside every window and make its writer look active for ever; such
  a record is bad. A missing timestamp is unknown, not wrong, and is kept.

`ingest` exits 1 when anything was skipped or bad, so cron mail shows it.

## Implemented

| Page | Shows |
| --- | --- |
| Overview | API-price equivalent against seats; tokens, people, blocks, hidden credentials, API errors, limit hits, chat storage; tokens by person and per day; Anthropic against Bedrock; blocks by the layer that decided |
| Logs | Every event, filtered by person and result, one tab per category |
| Chat storage | Size by age band, by person, and the largest chats |
| People | Everyone with use or a seat: tokens, active days, last use, five-hour and weekly limit hits, and why someone looks under-used (never used, unused for `idle_days`, under `median_fraction` of the median) |

## Planned, not built

What is built has only been run on generated data (`tools/demo.py`) and test
fixtures. Nothing installs the dashboard, no host feeds it, and the example
config carries no prices and no seats, so no figure on it is a live one yet.
The work that changes that comes first, in this order; each slice is one
change with its own tests, and a later slice does not start before the one
above it is verified on a real host.

| Slice | Delivers | Done when |
| --- | --- | --- |
| 1. Install | An installer target, a service account that owns the store, and units for `ingest`, `prune` and `serve`; the store path and the listen address come from config with no default | A second install changes nothing, and a host with a missing value refuses with the name of the key |
| 2. Live values | Prices and seats filled for a site; a first ingest of real logs on one host, rehearsed on a copy of them | Totals on the page are reconciled by hand against the logs for one day and one person |
| 3. Fleet feed | Each host pushes its own shape rows to the collector as the service account, so the collector needs no reach into any home; a row carries the host it came from | Two hosts feed one store, a re-sent batch counts once, and a host that stops feeding shows as stale, not as zero |
| 4. Hosts page | The check-in the feed already carries: version, policy hash, last ingest | A host behind on the policy is shown as behind |
| 5. Docs page | This repository's documents, rendered read-only | Every document in `docs/README.md` opens |
| 6. Policy and Update pages | The first pages that change anything, so they come after a review of who may use them | Decided at that review |

The pages, and what each needs first:

| Page | Needs first |
| --- | --- |
| Policy | Edit `managed-settings.json` as a merge request; hosts pull; each host reports the hash it holds |
| Update | Buttons for the `make` targets, with dry run; a terminal pane; an assistant that drafts changes for a person to merge |
| Hosts | A check-in from each host: version, policy hash, last ingest |
| Docs | This repository's documents, rendered |
| Admin | The `claude-admin` privileged session: who holds it, when it was used, what it changed |
| Telemetry | Claude Code's OpenTelemetry export needs a collector, and its interaction with `DISABLE_TELEMETRY` measured first |

## How it is tested

`make verify` runs every layer on Python 3.6, the oldest it supports; `make e2e` runs the
last two alone.

- **Unit** (`tests/test_*.py`): ingest, store, config, queries and the
  server's access rules, called in-process against a fixture fleet on disk.
- **Process** (`tests/e2e/test_cli.py`): `python3 -m fleetdash` as a separate
  process — exit codes, idempotent re-runs, refusal of an old store, and every
  asset and API the page uses, fetched over HTTP from a running `serve`.
- **Browser** (`tests/e2e/test_browser.py`): every page in the navigation,
  rendered by headless Chrome through the printed login URL, under the real
  Content-Security-Policy. `<main>` carries `data-page` and `data-state`
  (`loading`, `ready`, `error`) as the contract the tests wait on. With no
  browser installed these tests fail, so an empty run cannot read as a pass;
  `FLEETDASH_BROWSER=none` skips them on purpose.

The tests are themselves checked by fault injection: each guard is broken on
purpose and a test must go red.

## Known limits

- The collector must run on a host where the homes and hook logs are
  reachable; where it runs is to become a config value, not a fixed place.
- One collector reads one host's files. A fleet needs each host's logs and
  homes reachable from the collector, or a collector per host.
- Lines appended to a log after the last ingest and before a rotation are lost
  with the rotated file: rotated copies are not read.
- `tokens` includes cache reads, which dominate real usage; the per-model table
  is where to compare input and output.
- Chat storage counts transcript files only, not the rest of `~/.claude`.
