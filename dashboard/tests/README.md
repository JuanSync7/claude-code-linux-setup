# tests/

| File | What it covers |
| --- | --- |
| `__init__.py` | Marks the package, so `-m unittest discover` imports `tests.fixtures`; empty |
| `fixtures.py` | `Fleet`: a temporary host tree (homes, transcripts, hook logs) and its config |
| `test_ingest.py` | Mapping of every record kind, idempotency, checkpoints, rotation, one limit hit per window, store schema version, no content stored, and refusal of hostile files: symlinks, hard links, wrong owner, poisoned records, endless lines, copied message ids |
| `test_api.py` | Config refusals, cost and seat maths, filters, retention, People (limit windows, under-use rules), the server's access rules |
| `e2e/` | The CLI and server as processes, and every page in a headless browser: see [e2e/README.md](e2e/README.md) |

No test reads a real home directory, a real log or a real store.
