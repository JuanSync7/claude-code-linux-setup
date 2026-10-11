"""python3 -m fleetdash -c CONFIG {ingest,feed,prune,serve,url,install}

| Exit | Meaning |
| --- | --- |
| 0 | Done, or nothing to do. `install` without --apply: nothing would change |
| 1 | Done with something to look at, or refused: `ingest` and `feed` met a line or a file they could not read (the rest is stored); `feed` could not deliver its batch (it is kept and sent next time); `url` has no token to print; `install` was refused, or without --apply found changes to make |
| 2 | Could not run: a config that is missing, misspelt or incomplete; a store written under another schema; a token file that cannot be used; `serve` on an address something else holds; `install --apply` without the rights to write |
"""
import argparse
import json
import sys

from fleetdash import config, feed, ingest, install, server, store


def main(argv=None):
    p = argparse.ArgumentParser(prog="fleetdash")
    p.add_argument("-c", "--config", required=True)
    p.add_argument("command", choices=("ingest", "feed", "prune", "serve", "url", "install"))
    p.add_argument("--apply", action="store_true", help="install: make the changes instead of listing them")
    p.add_argument("--root", default="", help="install: write under this directory instead of /, to look at the result")
    a = p.parse_args(argv)
    try:
        cfg = config.load(a.config)
        if a.command == "install":
            return install.main(cfg, a.config, apply=a.apply, root=a.root)
        if a.command == "feed":
            return _feed(cfg)
        if a.command == "url":
            return _url(cfg)
        store.connect(cfg).close()
        if a.command == "serve":
            try:
                httpd = server.make_server(cfg)
            except OSError as e:
                print("fleetdash: cannot listen on %s port %d: %s" % (cfg["bind"], cfg["port"], e.strerror),
                      file=sys.stderr)
                return 2
    except (config.ConfigError, store.StoreError, server.TokenError) as e:
        print("fleetdash: %s" % e, file=sys.stderr)
        return 2
    if a.command == "ingest":
        stats = ingest.run(cfg)
        print(json.dumps(stats, indent=1))
        # a line that could not be read is data lost: say so in the exit status
        return 1 if stats["bad_lines"] or stats["skipped"] else 0
    if a.command == "prune":
        print(json.dumps(store.prune(cfg)))
        return 0
    print("fleetdash on %s" % _address(httpd.server_address, httpd.token), file=sys.stderr, flush=True)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


def _address(addr, token):
    # after the #: a browser keeps that part to itself, so the token reaches
    # the page and no server, log or proxy
    return "http://%s:%d/#token=%s" % (addr[0], addr[1], token)


def _feed(cfg):
    try:
        stats = feed.run(cfg)
    except feed.FeedError as e:
        print("fleetdash: %s" % e, file=sys.stderr)
        return 1
    print(json.dumps(stats, indent=1))
    return 1 if stats.get("bad_lines") or stats.get("skipped") else 0


def _url(cfg):
    """Print the address to open, for a server started by a unit, whose own
    output nobody sees."""
    if not cfg["token_file"] or not cfg["port"]:
        print("fleetdash: url needs token_file and a fixed port in the config; without them the address "
              "is the one serve printed when it started", file=sys.stderr)
        return 1
    print(_address((cfg["bind"], cfg["port"]), server.read_token(cfg)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
