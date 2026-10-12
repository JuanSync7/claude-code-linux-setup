# tests/

| File | What it covers |
| --- | --- |
| `__init__.py` | Marks the package, so `-m unittest discover` imports `tests.fixtures`; empty |
| `fixtures.py` | `Fleet`: a temporary host tree (homes, transcripts, hook logs) and its config |
| `test_ingest.py` | Mapping of every record kind, idempotency, checkpoints, rotation, one limit hit per window, store schema version, no content stored, the record of a stopped call (what was asked for, both ends of a long command, what is left out and said to be unknown), and refusal of hostile files: symlinks, hard links, wrong owner, poisoned records, endless lines, copied message ids |
| `test_api.py` | Config refusals, cost and seat maths, filters, retention, People (limit windows, under-use rules), the server's access rules |
| `test_feed.py` | The feed end to end in-process: a person's batch reaches the collector once, a crash between writing and clearing re-sends without double counting, the record of a stopped call beside its event and held to its limits, check-ins, and a spool file that lies about its owner, names another person's row, or is a link |
| `test_pages.py` | Hosts (quiet, older, policy differs, unknown), Policy comparison, Docs listing and its refusals, the People report and CSV, the Admin page's privileged sessions (a start paired with its end, a missing end or start, refusals, lines of the wrong shape, what ran in a session's time and when that is unknown, a log that is absent, unreadable or not configured), its enrolment (sending, quiet, never sent, refused files) and retention (what a prune would remove is what it then removes), the action runner (a run recorded from its start, its output read while it runs, its limits, the runs kept) and every request that must not start one, the login token file, nested config tables |
| `test_draft.py` | A drafted policy change: the patch applies with git and gives exactly the document asked for, the file's layout is kept, no line outside the rule lists is shown, every refusal, and the endpoint behind the login |
| `test_hostile.py` | What one person can leave for the collector, or a client send the server, to stop it for everyone else: a directory, an oversized count, unstorable text or deep nesting in the spool and the logs; a cookie offered as a login, a request through a tunnel, an idle connection, a store that cannot answer; links where the installer writes and values that would add a line to a unit |
| `test_install.py` | The installer against a staged tree: check mode, apply, a second run that changes nothing, modes, drift, refusals by key name, the launcher, and the units through `systemd-analyze verify` |
| `e2e/` | The CLI and server as processes, and every page in a headless browser: see [e2e/README.md](e2e/README.md) |

No test reads a real home directory, a real log or a real store.
