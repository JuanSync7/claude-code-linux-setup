# fleetdash/

| File | What it does |
| --- | --- |
| `__init__.py` | Marks the package; empty |
| `config.py` | Loads the config: every key required, no unknown key, loopback-only bind, under-use rules in range |
| `vocab.py` | The closed sets of severities and categories |
| `store.py` | SQLite schema and its version, owner-only creation, refusal of a store written under another version, per-severity retention (`prune`) |
| `ingest.py` | Reads hook logs and transcripts past their checkpoint; keeps shape, never content; refuses files that are not what their path claims |
| `api.py` | The read-only queries behind `/api/overview`, `/api/events`, `/api/sessions`, `/api/people` |
| `server.py` | The HTTP server: token, Host check, GET only, static files from `web/` |
| `__main__.py` | `python3 -m fleetdash -c CONFIG {ingest,prune,serve}` |
