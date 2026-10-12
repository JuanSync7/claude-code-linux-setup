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
- **What is kept is shape, not content**: token counts and model per API
  message, and the names of slash commands, skills and plugins. Prompt text,
  replies and the arguments of a slash command are never stored; a test plants
  a canary in each and checks the store file does not contain it. There are
  two exceptions, both commands: the audit hook's logged commands are stored,
  as they are in the logs, and a tool call that was stopped is stored as an
  incident (below). So the store is created `0600`.
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
- **Bedrock** is recognised by the message id: a call's id starts with
  `bedrock_id_prefix` when Bedrock answered it. The model name alone misses
  most of them, because Bedrock usually answers with the same name the
  subscription uses; `bedrock_model_pattern` catches the rest, the names
  written the Bedrock way. Both are inferences from a transcript, not a
  billing record, and the cost beside them is the configured prices times the
  tokens: the AWS bill is the figure to trust. An inference-profile ARN
  carries an AWS account id, so it is reduced to a fixed label at ingest.
- **The two providers are never added into one bill.** The Overview gives
  each its own table of models, and sets only the subscription's tokens
  against the seats: seats do not pay for Bedrock.
- **`<synthetic>` is not a model.** Claude Code writes some messages itself
  (an API error shown in the chat, for one) and records them under that name
  with no tokens. They are stored, and left out of every model table.
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

### What a block says, and who decided it

A block read from a transcript carries the kind Claude Code gives it (shown as
"Decided by"), the name of the tool it stopped, and, where the transcript has
one, the reason code (`classifier`, `safetyCheck`, `rule`). A name or a code
is kept only when it is short and made of the characters names are made of,
so a sentence written into either field is not stored. An API error carries
its status and the vendor's error code.

### The record of a stopped call

A block is an incident, and a line that says only "Bash, blocked" cannot be
acted on: nobody can tell what was stopped, whether the rule was right, or
try it again. So every block has a second row, in `incidents`, that the Logs
page opens beneath it:

| Kept | Where it comes from |
| --- | --- |
| What was asked for: the command, file, URL or path | The call the block answers, in the transcript; or the `detail` the `PermissionDenied` hook logged |
| Its full length, when it was shortened | A text over the limit keeps both ends and a note of how much was left out, so padding cannot push the part that matters out of the record |
| The names of the call's other fields | The transcript; names only |
| What Claude was told when it was stopped | The transcript's result for that call: the rule's or the classifier's own words. The hook's log does not hold it, so a record made from that log has none |
| The directory, git branch, Claude Code version and the call's id | The transcript's record of the block |
| Who, when, on which host, in which chat, which tool, who decided | The block's event |

What a call would have written is not kept: an edit's old and new text, a
file's content, a prompt, the input of a tool that takes none of the four
fields above. For those the record gives the field names and says the rest was
not recorded. Nor are a person's words when they refused a call themselves:
the call is kept, their message is not. The call a block answers is found by
its id among the calls read in the same run; when it was read in an earlier
run the record says so, and does not show an empty command. A record is
removed when `prune` removes its event.

Who decided is told apart this far:

| Decided by | What it is |
| --- | --- |
| `automode-blocked`, `automode-unavailable` | Claude Code's own safety check, or that check not answering |
| `permission-rule` | A `permissions` rule or a built-in safety check. The transcript does not say which settings file held the rule, so a managed-policy rule is not told apart from a person's own |
| `user-rejected`, `interrupted` | The person; not counted as a block |
| any other text | What the site's `PermissionDenied` hook was told, on a host that runs it |

A call refused by a `PreToolUse` hook is in neither source: a hook that
refuses writes no log of its own, and no transcript record has been seen for
one. On a host that runs the `PermissionDenied` hook and whose transcripts
are also read, one refusal is counted from both.

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
runs at a time (a second is answered 409), and a run past its time limit is
killed with its process group. An action runs as the dashboard's account,
with that account's rights: a site that lists a command there has decided
that account may run it.

A run is recorded before it starts, not after it ends: its number, when, the
argument list and directory it was started with, and a file under `runs.dir`
(owner-only) that the command's output and errors are written straight into.
If the row or the file cannot be made, nothing is started: a command whose
output would be lost is not run. The request answers with the run's number at
once, and `GET /api/run?id=&offset=` reads what the run has printed from
that offset on, at most 64 KiB a time, so the page shows the output while the
command is still printing it. When it ends the row gets its state (`done`
with an exit code, `timed-out`, or `not-started` with the reason in the
output), its duration and how much it printed. The page reads the first
1 MiB of a run's output and names the file for the rest. The newest
`runs.keep` runs are kept, rows and files; an older one is answered 404. A
run still marked as running that the server is not running was left by a
server that stopped: it is shown as interrupted, with no result.

### Drafting a policy change

The Policy page takes rules to add to or remove from the deny, ask and allow
lists and answers with a patch against `policy.source`, the repository's
policy file. It is a `GET` and writes nothing: no file, no row, no host. The
policy changes only when a person applies the patch in a checkout, it is
reviewed and merged, and a host installs it. Anyone with the login can draft,
because a draft has no effect until that review.

The draft is in the page's address (`#/policy/` and the changes as JSON), so
it survives a reload and can be sent to a colleague; the server checks every
change again each time: at most 50, each a rule of one printable line of at
most 500 characters, none already made, none naming a rule that is not there
to remove. The policy file is laid out by hand, so only the lists a draft
changes are rewritten in its text, and the result must parse to exactly the
document the draft describes or no patch is given. The lines a patch shows
around a change never leave the lists being changed: it shows rules, as the
page does, and never an environment value. Its first lines say what it does
and the SHA-256 of the file it was drafted against.

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
- the privileged session's log (`admin_log`) is read under the same rules and,
  with `verify_file_owner` on, must be root's. Each line is split by position
  into its time, the four named fields and one of the three messages the
  launcher writes; a line of any other shape is a bad line. Whether the file
  was read, was not there, or could not be read is stored beside the lines, so
  the page can tell no sessions from a log it never saw;
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
| Overview | API-price equivalent against seats; tokens, people, blocks, hidden credentials, API errors, limit hits, chat storage, hosts; tokens by person and per day; a table of models for the subscription and another for Bedrock, each with input, output, cache-read and cache-write tokens and their cost at the configured prices; blocks by the layer that decided |
| Logs | Every event, filtered by person, result, who decided and tool, one tab per category, with the host when the rows carry one. A stopped call opens onto its record: what was asked for, what Claude was told, who decided, and where it happened |
| Chat storage | Size by age band, by person, and the largest chats |
| People | Everyone with use or a seat: tokens, API-price equivalent against the seat's cost, active days, last use, five-hour and weekly limit hits, and why someone looks under-used (never used, unused for `idle_days`, under `median_fraction` of the median). The table downloads as CSV, for a report |
| Hosts | Every host heard from: when, which Claude Code, whether its policy is the fleet's, and its events by result |
| Policy | The policy this host holds against the repository's: whether they are the same file, which settings differ, the deny, ask and allow rules, the hooks, the sandbox switch, the minimum version, and the names (never the values) of the environment it sets. Rules to add or remove are drafted there as a patch for a merge request; the page applies nothing |
| Update | The commands the config lists, each with the command line it will run, its directory, time limit and last result; beside them the chosen run: the command line it was started with, when, how long, its result, and everything it printed, followed while it runs; below, the runs kept, each of which opens the same way |
| Admin | Who used the privileged session: each start with its end, how long it lasted and its exit code, each refusal with its reason, and the tool calls and blocks logged for that account on that host between the start and the end. Who is sending data: each person as sending, quiet (nothing newer than `idle_days`) or never sent, the hosts their events came from, and the files of theirs that were refused; each host and when it was last heard. How long logs are kept: each result's age limit and row cap, how many rows it holds, and how many the next `prune` would remove. Read-only |
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
| Admin: the privileged session on other hosts | The page reads the session log of the host the dashboard runs on. Another host's log would have to reach the collector, and `feed` cannot carry it: it runs as each person, and the log is root's |
| Admin: changing retention | The page shows the rules and does not change them: they are in the config file, which the server only reads |
| Skills and connectors | A shared catalogue people can install from, and a way to offer a set by role. Needs a decision on where the catalogue lives and who approves an entry; connectors are disabled by the policy today |
| Applying a policy change | The Policy page drafts a patch and stops there. Applying one from a page stays out until a review decides who may |
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

- A drafted patch is written against the policy file as the dashboard's host
  holds it. Where the lists are too short to show lines around a change, the
  patch is placed by line number alone (`git apply --unidiff-zero`), so on a
  file that has since changed an added rule can land in the wrong place. The
  SHA-256 in the patch's first lines says which file it was for; reading the
  merge request is the check.
- A stopped call's command is stored and shown as it was written, so a
  credential typed into a command that was then stopped is in the store, in a
  feed batch on its way there, and on the Logs page for everyone with the
  login. Nothing hides it: the redaction hook works on what a tool prints, not
  on what it was asked. The same is true of the commands the audit hook logs.
- The record of a stopped call does not say which rule matched, which
  permission mode the session was in, or which policy the host held at that
  moment: no transcript record has been seen to carry them. The Hosts page
  gives the policy a host holds now. It does not say what Claude did next
  either: whether it tried the same thing another way.
- A block whose call was written to the transcript before an ingest and
  answered after it has no command in its record. An ingest that starts
  between the two is rare, and the record says the call was not read.
- Blocks stored before this record existed have none, and the Logs page shows
  them as before. Reading the transcripts again fills them in: remove the
  store's checkpoints for those files, or move the store aside, and ingest.
- The Admin page goes by what is stored, not by when it arrived: the store
  keeps no record of a feed's last delivery. A person shown as never sent
  holds an unused seat or has no working feed, and the page cannot tell which;
  a person on leave and a feed that broke both show as quiet. It does not
  record when `prune` last ran either, only what the next run would remove.
- The privileged session's log is written root-only, because it says who held
  privilege. The dashboard's account can read it only if the site gives that
  account access, which is a change to the control plane and not something
  the installer does; until then the Admin page says the log could not be
  read. Everyone who has the login token sees what the page shows.
- The session's log does not say what a session did. The page shows the tool
  calls and blocks logged for that account on that host between the start and
  the end, which includes any ordinary session the same person had open then,
  and shows nothing once those rows are past their retention. A start whose
  end was never written cannot be told from a session still open.
- Lines of the session's log are never pruned. A line written after the last
  ingest and before the log is rotated is not read.
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
  display of a finished run in the browser; following a run while it prints
  is covered at the API, not in the browser.
- The token is in the address a person opens, so it is in that browser's
  history until the entry is removed, and in the tab's storage until the tab
  closes. Someone who takes over the port after the server stops is a
  different server at the same address; with `token_file` set the token
  outlives a restart, so stop sharing the address when the service moves.
- Each connection is a thread and nothing caps how many are open at once; an
  idle one is closed after 30 seconds.
- If the store cannot be written when a run ends, the run keeps its output
  file and its row stays as it was at the start; after the next server start
  it is shown as interrupted, although it finished.
- A command that starts its own session outlives its time limit: only the
  process group the run began is killed. A command's output goes to its file
  under `runs.dir` with no size limit until the time limit stops it.
- A command line is shown as it is configured and as it was started. An
  argument that holds a secret would be shown too: keep secrets out of
  `actions`, in a file the command reads.
- The Overview and People queries read every usage row in the window. On one
  person's history (some three hundred thousand rows) they answer in about
  half a second; a fleet's history needs a per-day summary table first.
- The People page's cost is one figure per person, subscription and Bedrock
  together; only the Overview separates them.
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
