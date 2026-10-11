# Claude Code fleet dashboard

A read-only web dashboard over a Claude Code fleet governed by this repository's control plane:
token use and its API-price equivalent against seat cost, what the policy blocked,
the hook logs by person and severity, how much chat history each person keeps, and
who hits limits or looks under-used.

```bash
make verify                       # every test, on Python 3.6, the oldest it supports (needs Chrome)
make e2e                          # only the process and browser tests
make demo                         # synthetic fleet; open the URL it prints
cp config.example.json config.json   # then edit: paths, prices, seats, retention
python3 -m fleetdash -c config.json ingest   # from cron; reads only what is new
python3 -m fleetdash -c config.json prune    # from cron; per-severity retention
python3 -m fleetdash -c config.json serve    # prints a one-time URL with a token
```

`seats` is one entry per plan tier: `{"tier": "Standard", "monthly_usd": <what the site pays per
seat per month>, "users": ["<login>", ...]}`. The example file ships it empty, and
`prices_per_mtok` too, because a price is a site value: the vendor's list price changes and a
site on annual billing or a negotiated rate pays something else. With no seats the seat cost
the Overview sets usage against is zero.

How it works, what it trusts and what is still planned: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

| Path | What it is |
| --- | --- |
| `fleetdash/` | The collector, store, queries and HTTP server (Python standard library only) |
| `web/` | The page: one HTML file, one stylesheet, one script, no build step |
| `tests/` | The test suite and the fake-fleet fixtures it builds |
| `tools/demo.py` | Writes a synthetic fleet for trying the UI and taking screenshots |
| `docs/` | Architecture, data model and the planned pages |
| `config.example.json` | Every config key; copy to `config.json` (gitignored) |
| `Makefile` | `verify`, `e2e`, `demo` |
| `.gitignore` | Keeps `config.json`, the demo tree and bytecode out of git |
