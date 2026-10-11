"""python3 -m fleetdash -c CONFIG {ingest,prune,serve}"""
import argparse
import json
import sys

from fleetdash import config, ingest, server, store


def main(argv=None):
    p = argparse.ArgumentParser(prog="fleetdash")
    p.add_argument("-c", "--config", required=True)
    p.add_argument("command", choices=("ingest", "prune", "serve"))
    a = p.parse_args(argv)
    try:
        cfg = config.load(a.config)
        store.connect(cfg).close()
    except (config.ConfigError, store.StoreError) as e:
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
    httpd = server.make_server(cfg)
    host, port = httpd.server_address[:2]
    print("fleetdash on http://%s:%d/?token=%s" % (host, port, httpd.token), file=sys.stderr, flush=True)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
