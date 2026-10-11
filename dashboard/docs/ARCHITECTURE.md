# Architecture

## What it is for

IT needs one place to see how a Claude Code fleet is used and where the policy
bites: who uses how much, what that would cost at API prices against what the
seats cost, what was blocked and by which layer, how much chat history people
keep, which hosts are behind, and what the policy says. It reads what the
hosts already write. The one thing it can change is to start a command from a
short list the site's config names (the Update page); nothing else is writable.

## How data flows

```
 each person, on any host                     the dashboard host, as its own account
 ─────────────────────────                    ──────────────────────────────────────
 own transcripts ─┐                           spool/ ─┐
 own hook logs   ─┴─ feed ─▶ batch file ────▶         ├─ ingest (timer) ─▶ SQLite store ─▶ serve ─▶ browser
                     (private store,          logs ───┘        │                            │
                      outbox)                 it can read   prune (timer)             token, loopback
```

There are two ways in. A site can use both, but each host's files should come
in by one of them: an event that arrives both ways is counted twice, because a
fed event is keyed with the person who sent it and a directly read one by its
place in the file. Token and chat-storage rows are keyed by what they
describe and count once either way.

- **Direct**: `ingest` reads the hook logs under `hook_log_dir` and the
  transcripts matched by `transcript_glob`. That needs an account that can read
  them, which for home directories means root or the person themself.
- **Feed** (`spool` set): each person runs `feed`, which reads only their own
  files and leaves a batch in the spool; `ingest` collects the batches. The
  dashboard's account then needs no reach into any home, and one store can
  take batches from many hosts when the spool is on storage they share.

What every path has in common:

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

### The feed

`feed` runs as the person, from a session-end hook or by hand:

1. It takes a lock in `feed.state_dir`, so two sessions ending together do not
   both send. The one that does not get the lock exits 0: the other is sending.
2. It ingests the person's own transcripts and hook log into a private store
   in `feed.state_dir`, by the same code and rules as the collector.
3. A trigger in that private store notes every inserted row in an outbox. The
   rows the outbox names are written to one file in the spool, under a
   temporary name created exclusively and owner-only, then renamed to
   `<time>-<pid>-<random>.jsonl`. The collector reads only finished names.
4. The outbox is emptied after the rename. A crash in between sends the same
   rows again, and the collector's keys make a row sent twice count once.

A batch starts with a header (`host`, `user`, time, the Claude Code version
and the SHA-256 of the policy file that host holds) followed by one line per
row. A batch with a header and no rows is still sent: it is the host's
check-in, and what the Hosts page is built from. A batch may be at most
1 GiB; `feed` refuses to send a larger one and keeps its rows.

The collector (`spool.py`) removes a batch once its rows are committed, and
keeps its checkpoint until the removal succeeds, so a batch it could not
remove is not counted again.

### Check-ins, and what "behind" means

Every `ingest` and every batch records, per host label: when it was last
heard from, the version `claude_bin --version` printed, and the hash of
`policy.deployed`. A value that could not be read is stored as unknown, never
as a guess. The Hosts page then says:

- **quiet**: not heard from for `host_stale_hours`. Its figures stay as they
  were; a quiet host is not a host with no use.
- **older version**: any version other than the newest one a host reported.
- **policy differs**: the hash is not that of `policy.source`, the file the
  config says the fleet should hold. With no source configured, or no hash
  reported, the answer is unknown.

The comparison is of file bytes, so it assumes the control plane's installer
copies the policy file unchanged.

A check-in that arrives in a batch is the sender's word, like everything else
in a batch: anyone who can write to the spool can check in under any host
label, with any version and hash. The Hosts page names who reported each row.
A time ahead of the collector's clock is stored as the collector's time, so a
forged check-in cannot outrank the ones the host itself sends later; a forged
host or version can still make a real host read as older, until someone looks
at who reported it.

## Severities and categories

Closed sets in `fleetdash/vocab.py`. Retention is per severity, so short-lived
noise (`pass`) can go in two weeks while `deny`, `redact` and `quota` are kept
for a year: `prune` applies an age limit and a row cap to each.

A transcript denial the person caused (`user-rejected`, `interrupted`) is
`info`, not a block. Any other kind, including one never seen before, is `deny`.

## Who can see it, and who can start a command

Loopback is shared on a multi-user host, so the server is not protected by
binding to `127.0.0.1` alone:

- every request under `/api/` needs the login token in an
  `X-Fleetdash-Token` header. The printed address carries the token after its
  `#`, the part a browser sends to no server; the page keeps it for that tab,
  takes it out of the address bar, and sends the header itself. A new tab
  needs the printed address again;
- the token is never a cookie. A browser sends a host's cookies to every port
  on that host, so a cookie set by this server would also be sent to any
  other person's listener on the same machine;
- the page's own files (`index.html`, `app.js`, `style.css`) hold no data and
  are served without the token;
- with `token_file` set the token is kept there, owner-only, across restarts,
  and `fleetdash url` prints the address again for the account or for root;
  with it empty, each start has a new token and prints it once;
- a `Host` header other than loopback is refused, against DNS rebinding;
- static files cannot leave `web/`, and a document is asked for by its place
  in the configured list, never by a path. Only a regular file is listed;
- a connection that sends nothing is closed after 30 seconds;
- the config refuses any `bind` but IPv4 loopback, because there is no TLS. A
  person on another machine reaches it through an SSH tunnel to the host, on
  any local port.

The People and Logs pages show figures per named person. The control plane's
own metrics leave per-person volume out, as employee monitoring
([REPORTING.md](../../docs/REPORTING.md)); this dashboard shows it because
seat cost is decided per person. That is a decision for the site, with its
people told, before the token is handed to anyone beyond the fleet's owners.

Everyone who holds the token sees everything and can start every listed
command: there is one role. `POST /api/run` is the only request that changes
anything, and it asks for more than a GET does:

- the login, as above;
- an `Origin` header, when the browser sends one, that is the address the
  request was sent to (its `Host` header);
- a run key in `X-Fleetdash-Run`. The key is made at each start and handed
  out only through a logged-in `GET /api/actions`, which a page on another
  site cannot read, so a forged cross-site request cannot carry it;
- a body of at most 1 KiB that is exactly `{"id": "<action id>"}`.

The request names an action and nothing else. The argument list, working
directory and time limit come from the config's `actions`, so nothing a
browser sends reaches a command line, and no shell is involved. One action
runs at a time (a second is answered 409), the page is shown at most 256 KiB
of its output, a run past its time limit is killed with its process group, and
a run is recorded with its time, exit code and duration. An
action runs as the dashboard's account, with that account's rights: a site
that lists a command there has decided that account may run it.

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
  than a regular file (a directory, a pipe) is not read. A transcript whose
  name is not UTF-8 is skipped;
- with `verify_file_owner` on, a hook log must be owned by the user it is named
  for, and a transcript by the user its path names. The log directories are
  sticky and world-writable, so anyone can create `<victim>.jsonl`;
- a file refused for any of these reasons becomes a `log-integrity` event under
  the user it claims to be for, and is listed as skipped;
- a record that cannot be read writes nothing, is counted in `bad_lines`, and
  ingest goes on. A field of the wrong JSON type is stored as text. What
  makes a record bad: a token count that is not a whole number from 0 to a
  billion (so that no sum of them can leave the store's 64-bit integers),
  text that is not UTF-8, JSON nested deeper than the parser reads, a slash
  command with no name, or a line longer than `LINE_MAX`. A line that has no
  end is not held in memory while it grows.
- a timestamp must be UTC ISO 8601, as Claude Code and the hooks write it, and
  no more than a day ahead. Times are compared as text, so `zzz` or year 9999
  would sit inside every window and make its writer look active for ever; such
  a record is bad. A missing timestamp is unknown, not wrong, and is kept.

`ingest` exits 1 when anything was skipped or bad, and the count is in its
output; the installed unit treats that exit as a completed run.

A batch in the spool gets the same treatment, because the spool is a
directory everyone can write to:

- the person a batch describes is the **owner of the file**, never the name
  written inside it (with `verify_file_owner` on). A batch that is a symlink,
  has a second hard link or is not a regular file is not read;
- every row is stored under that person and passes the same checks a log line
  does: closed severity and category sets, bounded token counts, a
  plausible timestamp, bounded lengths;
- an event's key is combined with the person, so nobody can name, and so
  replace, another person's event;
- a refused batch becomes a `log-integrity` event and is removed. That
  covers a batch over the size limit, which is refused by its size without
  being read, one that grows past the limit while it is read, of which no
  row is kept, and one closed to the collector. A directory that is not empty
  cannot be removed by the collector: it is refused and listed on every run
  until its owner or root removes it, and the batches after it are still read.

What this does not bound is how long a run takes: a person can leave many
large batches, each read to its end. The units set no time limit on a run.

The spool is mode `3733`: anyone may add a file, only the account may list
or remove, nobody may remove another person's file, and a new file is born in
the account's group so the account can read it.

## Installing it

`python3 -m fleetdash -c CONFIG install` lists what a host lacks and exits 1
when there is anything; `--apply`, as root, makes the changes; `--root DIR`
builds the same tree under `DIR` without touching ownership or systemd, to
look at first. A second run changes nothing. Everything comes from the
config's `install` table, and a value left empty is refused by its key name.
So is a path with a space, or any value that would add a line to a unit.

Where a link, or anything else that is not the file or directory that belongs
there, sits in a place the installer writes, it refuses and writes nothing:
making it right would send the write, and the ownership, to wherever the link
points. The check and the write are separate steps, so this holds against
what is there when the installer starts, not against an account that swaps a
directory it owns while root is installing.

| It places | Owner, mode |
| --- | --- |
| The code and page under `install.code_dir`, and the launcher `bin/fleetdash` | root, read-only to everyone |
| The config at `install.config_file` | root, `0644`: `feed` runs as each person and must read it. It holds seat lists and prices, and no secret |
| The directory of `store`, and of `token_file` | the account, `0700` |
| `spool`, when set | the account, `3733` |
| `fleetdash-serve.service`; `fleetdash-ingest` and `fleetdash-prune` services with their timers | root, in `install.units_dir` |

The account must exist first, with no login shell; the installer does not
create accounts. The units run as it with `NoNewPrivileges`,
`ProtectSystem=strict` and `ProtectHome=read-only`, and may write only the
store, token and spool directories.

To feed the collector, each person's session must end by running the
launcher's `feed` in the background, for example from a `SessionEnd` hook
whose command is `<install.code_dir>/bin/fleetdash feed`. Adding that hook to
the managed policy is a policy change for the control plane's owners; the
dashboard does not make it.

## Implemented

| Page | Shows |
| --- | --- |
| Overview | API-price equivalent against seats; tokens, people, blocks, hidden credentials, API errors, limit hits, chat storage, hosts; tokens by person and per day; Anthropic against Bedrock; blocks by the layer that decided |
| Logs | Every event, filtered by person and result, one tab per category, with the host when the rows carry one |
| Chat storage | Size by age band, by person, and the largest chats |
| People | Everyone with use or a seat: tokens, API-price equivalent against the seat's cost, active days, last use, five-hour and weekly limit hits, and why someone looks under-used (never used, unused for `idle_days`, under `median_fraction` of the median). The table downloads as CSV, for a report |
| Hosts | Every host heard from: when, which Claude Code, whether its policy is the fleet's, and its events by result |
| Policy | The policy this host holds against the repository's: whether they are the same file, which settings differ, the deny, ask and allow rules, the hooks, the sandbox switch, the minimum version, and the names (never the values) of the environment it sets |
| Update | The commands the config lists, each with a Run button, the last result and its output |
| Docs | The Markdown documents under the directories the config lists, rendered in the page. A link to another listed document opens it; any other relative link stays text |

Docs are rendered by a small reader in `web/app.js` that covers headings,
lists, tables, code, quotes, links and emphasis. It builds elements and sets
text; no document can put markup or script into the page.

## Planned, not built

The dashboard has been run on generated data (`tools/demo.py`), on test
fixtures, and by one person over their own transcripts. It has not been
installed as a service: the installer's output was checked with
`systemd-analyze verify` and by building the tree under `--root`, and its
units have never been started. That, and the feed running from real sessions
on more than one host, are the next two steps, in this order:

| Step | Delivers | Done when |
| --- | --- | --- |
| 1. Install on one host | The account created, `install --apply` run as root, prices and seats filled with what the site pays | The page is served by the unit after a reboot, a second install changes nothing, and one person's total for one day is reconciled by hand against their logs |
| 2. Feed from sessions | The `feed` hook in the managed policy, and the spool on storage every host mounts | Two hosts feed one store, a re-sent batch counts once, and a host that stops feeding shows as quiet, not as zero |

Pages that are not built, and what each needs first:

| Page | Needs first |
| --- | --- |
| Admin | The `claude-admin` privileged session: who holds it, when it was used, what it changed. Needs that session's audit log to reach the collector |
| Skills and connectors | A shared catalogue people can install from, and a way to offer a set by role. Needs a decision on where the catalogue lives and who approves an entry; connectors are disabled by the policy today |
| Editing the policy | The Policy page only reads. A change stays a merge request and a deploy until a review decides who may make one from a page |
| Telemetry | Claude Code's OpenTelemetry export needs a collector, and its interaction with `DISABLE_TELEMETRY` measured first |
| More than one role | Everyone with the token is an administrator. A read-only viewer needs the server to know who is asking |

## How it is tested

`make verify` runs every layer on Python 3.6, the oldest it supports; `make e2e` runs the
last two alone.

- **Unit** (`tests/test_*.py`): ingest, feed and spool, store, config,
  queries, the installer against a staged tree, the action runner and the
  server's access rules, called in-process against a fixture fleet on disk.
  `test_hostile.py` holds what one person can leave for the collector, or a
  client send the server, to stop it for everyone else.
- **Process** (`tests/e2e/test_cli.py`): `python3 -m fleetdash` as a separate
  process — exit codes, idempotent re-runs, refusal of an old store, a feed
  collected by an ingest, an action started over HTTP and the requests that
  must not start one, and every asset and API the page uses.
- **Browser** (`tests/e2e/test_browser.py`): every page in the navigation,
  rendered by headless Chrome through the printed login URL, under the real
  Content-Security-Policy. `<main>` carries `data-page` and `data-state`
  (`loading`, `ready`, `error`, `locked`) as the contract the tests wait on. With no
  browser installed these tests fail, so an empty run cannot read as a pass;
  `FLEETDASH_BROWSER=none` skips them on purpose.

The tests are themselves checked by fault injection: each guard is broken on
purpose and a test must go red.

## Known limits

- The figures are self-reported, by direct ingest and by feed alike: see
  "What the figures can be trusted for".
- Put `store` on local disk. Ingest commits once per file, and each commit
  waits for the disk: a first run over some thirteen thousand transcripts took
  under two minutes to a local disk and had not finished after eighteen to a
  store on NFS. Later runs read only what is new.
- `feed` keeps a SQLite store and a lock file under `feed.state_dir`, which is
  in the person's home; where homes are on NFS, a heavy user's first feed is
  slow in the same way (it runs in the background, and later ones are short). On a
  home directory served over NFS, SQLite's locking depends on the filer; the
  lock file is what keeps two runs apart, and it has the same dependency.
- The spool relies on a new file taking the directory's group. That holds on
  local filesystems and has not been confirmed on a filer.
- A click on Run, and on Download CSV, is not covered by an automated
  browser test: the browser tests read a rendered page and cannot click. The
  requests the buttons send are covered at process level, and the page's
  display of a result in the browser.
- The token is in the address a person opens, so it is in that browser's
  history until the entry is removed, and in the tab's storage until the tab
  closes. Someone who takes over the port after the server stops is a
  different server at the same address; with `token_file` set the token
  outlives a restart, so stop sharing the address when the service moves.
- Each connection is a thread and nothing caps how many are open at once; an
  idle one is closed after 30 seconds.
- A run is recorded after it ends. If the store cannot be written then, the
  request fails and that run has no record.
- A command that starts its own session outlives its time limit: only the
  process group the run began is killed. A command's output goes to a
  temporary file with no size limit until the time limit stops it.
- The page's Markdown reader is written for the repository's own documents;
  a document built to be slow to read can stall the tab that opens it.
- With direct ingest, one collector reads one host's files, and lines appended
  to a log after the last ingest and before a rotation are lost with the
  rotated file: rotated copies are not read.
- `tokens` includes cache reads, which dominate real usage; the per-model table
  is where to compare input and output.
- Chat storage counts transcript files only, not the rest of `~/.claude`.
- The Markdown reader is a subset. Emphasis markers in running text outside
  code (two `*` on one line) are read as emphasis.
