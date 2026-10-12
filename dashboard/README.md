# Claude Code fleet dashboard

A web dashboard over a Claude Code fleet governed by this repository's control plane:
token use and its API-price equivalent against seat cost, what the policy blocked,
the hook logs by person and severity, how much chat history each person keeps,
who hits limits or looks under-used, which hosts are behind, what the policy says,
this repository's documents, and buttons for the commands a site chooses to list.

```bash
make demo                         # a synthetic fleet with every page filled; open the URL it prints
make verify                       # every test, on Python 3.6, the oldest it supports (needs Chrome)
make e2e                          # only the process and browser tests
```

## Running it on a host

```bash
cp config.example.json config.json           # then edit: paths, prices, seats, retention
python3 -m fleetdash -c config.json ingest   # read what is new: logs, transcripts, batches in the spool
python3 -m fleetdash -c config.json serve    # prints the address to open, with its login token
python3 -m fleetdash -c config.json url      # prints that address again (needs token_file set)
python3 -m fleetdash -c config.json prune    # apply the per-severity retention
python3 -m fleetdash -c config.json feed     # as any person: send the shape of your own use to the spool
```

The server listens on loopback only. From another machine, tunnel to it:
`ssh -L <port>:127.0.0.1:<port> <host>`, then open the printed address. The
login token is the part of that address after the `#`; the page keeps it for
that tab only, so a new tab needs the printed address again.

Without root, a person can run `ingest` and `serve` as themself over the files
they can read, which is their own. To run it as a service under its own account:

```bash
python3 -m fleetdash -c config.json install                    # lists what the host lacks; changes nothing
python3 -m fleetdash -c config.json install --apply --root /tmp/look   # builds the tree there, to read first
sudo python3 -m fleetdash -c config.json install --apply       # as root; a second run changes nothing
```

The account named in `install.account` must exist first, with no login shell.
After that the installed launcher is the command: `<install.code_dir>/bin/fleetdash url`.
What the installer places, how each person's sessions feed it and what that
trusts: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Config

Keep `store` on local disk, not NFS: a first ingest that takes two minutes
locally takes far longer there.

Every key is required and an unknown key is refused; `config.example.json`
lists them, and `fleetdash/config.py` says what each is for.

`seats` is one entry per plan tier: `{"tier": "Standard", "monthly_usd": <what the site pays per
seat per month>, "users": ["<login>", ...]}`. The example file ships it empty, and
`prices_per_mtok` too, because a price is a site value: the vendor's list price changes and a
site on annual billing or a negotiated rate pays something else. With no seats the seat cost
the Overview sets usage against is zero.

`admin_log` is the path of the privileged session's log on this host
(`admin.log` in the log directory the hooks write to), or empty to read none. That
file is written for root only, so the account the dashboard runs as must be
given read access to it before the Admin page can show who used the session;
`docs/ARCHITECTURE.md` says what the page can and cannot tell from it.

`actions` is the whole list of commands the Update page can start, each with a
fixed argument list, working directory and time limit. It ships empty: with
no entry, the page can start nothing. `runs` is where each run's output is kept
(`dir`, on local disk, made owner-only) and how many runs back (`keep`). `docs` lists the directories or single
files of Markdown the Docs page shows, and `policy.source` is the policy file
the fleet should hold, which the Policy and Hosts pages compare against and a
drafted policy change is written for.

How it works, what it trusts and what is still planned: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

| Path | What it is |
| --- | --- |
| `fleetdash/` | The collector, feed, store, queries, installer and HTTP server (Python standard library only) |
| `web/` | The page: one HTML file, one stylesheet, one script, no build step |
| `tests/` | The test suite and the fake-fleet fixtures it builds |
| `tools/` | `demo.py` writes a synthetic fleet for trying the UI and taking screenshots |
| `docs/` | Architecture, trust model, installation and the planned pages |
| `config.example.json` | Every config key; copy to `config.json` (gitignored) |
| `Makefile` | `verify`, `e2e`, `demo` |
| `.gitignore` | Keeps `config.json`, the demo tree and bytecode out of git |
