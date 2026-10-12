# fleetdash/

| File | What it does |
| --- | --- |
| `__init__.py` | Marks the package; empty |
| `config.py` | Loads the config: every key required, no unknown key at any level, loopback-only bind, under-use rules in range |
| `vocab.py` | The closed sets of severities and categories |
| `store.py` | SQLite schema and its version, owner-only creation, refusal of a store written under another version, per-severity retention (`prune`) |
| `ingest.py` | Reads hook logs and transcripts past their checkpoint; keeps shape, never content; refuses files that are not what their path claims; reads the privileged session's log; records the host's check-in |
| `feed.py` | `feed`: one person's own rows, from a private store, written as one batch file into the spool |
| `spool.py` | The collector's side of the feed: reads each batch as its file's owner, checks every row, removes the batch once stored |
| `api.py` | The queries behind the pages: overview, events, sessions, people (and its CSV), hosts, policy, status, and the Admin page's privileged sessions, enrolment and retention |
| `docs.py` | The Markdown documents under the configured directories, addressed by their place in the list, never by a path |
| `actions.py` | The commands the Update page can start: only the config's list, one at a time, time-limited, each run recorded |
| `server.py` | The HTTP server: login token, Host check, static files from `web/`, and the one POST with its extra checks |
| `install.py` | `install`: places the code, config, launcher, directories and systemd units; lists what would change unless `--apply` |
| `__main__.py` | `python3 -m fleetdash -c CONFIG {ingest,feed,prune,serve,url,install}` and its exit codes |
