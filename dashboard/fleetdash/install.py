"""`install`: puts the dashboard on a host as a service that runs under its
own account.

    python3 -m fleetdash -c CONFIG install            # list what would change
    python3 -m fleetdash -c CONFIG install --apply    # as root: make the changes
    python3 -m fleetdash -c CONFIG install --apply --root DIR   # the same tree under DIR, to look at

It places the code, the config, the launcher, the store and spool directories
and the systemd units, then enables them. Every path and the account come from
the config's `install` table and have no default here. A second run finds
nothing to change. Under --root nothing outside DIR is touched: ownership is
not set and systemd is not asked to do anything.

| Exit | Meaning |
| --- | --- |
| 0 | Nothing to change; or, with --apply, the host now matches |
| 1 | Refused, nothing written: a value the config leaves empty or relative, or that would add a word or a line to a unit; an account that does not exist; something in a place that is not the file or directory that belongs there. Or, without --apply, there are changes to make (they are listed) |
| 2 | Could not run: --apply without the rights to write, or systemd refused a unit |
"""
import json
import os
import pwd
import stat
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
WEB = os.path.join(os.path.dirname(HERE), "web")
UNITS = ("fleetdash-serve.service", "fleetdash-ingest.service", "fleetdash-ingest.timer",
         "fleetdash-prune.service", "fleetdash-prune.timer")
ENABLE = ("fleetdash-serve.service", "fleetdash-ingest.timer", "fleetdash-prune.timer")
# the spool: its owner (the account) lists and removes; everyone else may only
# add a file. Sticky, so nobody removes another person's batch; setgid, so a
# batch is born in the account's group and the account can read it.
SPOOL_MODE = 0o3733


class Refused(Exception):
    pass


def launcher(cfg):
    i = cfg["install"]
    return os.path.join(i["code_dir"], "bin", "fleetdash")


def _launcher_text(cfg):
    i = cfg["install"]
    # json.dumps writes a string a Python source file reads back as the same string
    return ("#!%s\n# Runs the installed dashboard with the installed config: fleetdash {ingest,feed,prune,serve,url}\n"
            "import sys\nsys.path.insert(0, %s)\nfrom fleetdash.__main__ import main\n"
            "sys.exit(main([\"-c\", %s] + sys.argv[1:]))\n"
            % (i["python"], json.dumps(i["code_dir"]), json.dumps(i["config_file"])))


def _service(cfg, about, command, writable, kind="oneshot"):
    i = cfg["install"]
    lines = ["[Unit]", "Description=Claude Code fleet dashboard: %s" % about, "",
             "[Service]", "Type=%s" % kind, "User=%s" % i["account"],
             "ExecStart=%s %s" % (launcher(cfg), command),
             "NoNewPrivileges=yes", "PrivateTmp=yes", "ProtectSystem=strict", "ProtectHome=read-only"]
    lines += ["ReadWritePaths=%s" % p for p in writable]
    if kind == "simple":
        lines += ["Restart=on-failure", "", "[Install]", "WantedBy=multi-user.target"]
    return "\n".join(lines) + "\n"


def _timer(about, when):
    return "\n".join(["[Unit]", "Description=Claude Code fleet dashboard: %s" % about, "",
                      "[Timer]", when, "", "[Install]", "WantedBy=timers.target"]) + "\n"


def units(cfg):
    i = cfg["install"]
    store_dir = os.path.dirname(cfg["store"])
    data = [store_dir] + ([cfg["spool"]] if cfg["spool"] else [])
    # the server writes the store (the record of each run) and, on its first start, the token
    served = sorted({store_dir, os.path.dirname(cfg["token_file"])})
    return {
        "fleetdash-serve.service": _service(cfg, "web page", "serve", served, kind="simple"),
        # exit 1 is a run that stored everything it could and has something to report
        "fleetdash-ingest.service": _service(cfg, "read new logs and batches", "ingest", data)
        + "SuccessExitStatus=1\n",
        "fleetdash-ingest.timer": _timer("read new logs and batches",
                                         "OnBootSec=%s\nOnUnitActiveSec=%s" % (i["ingest_interval"], i["ingest_interval"])),
        "fleetdash-prune.service": _service(cfg, "apply retention", "prune", [store_dir]),
        "fleetdash-prune.timer": _timer("apply retention", "OnCalendar=%s\nPersistent=yes" % i["prune_calendar"]),
    }


def plan(cfg, config_path):
    """Everything the host should hold, as (kind, path, mode, owned, content):
    kind is dir or file, owned says whether it belongs to the account (else
    root), content is bytes for a file."""
    i = cfg["install"]
    for key in ("account", "python", "code_dir", "config_file", "units_dir", "ingest_interval", "prune_calendar"):
        if not i[key]:
            raise Refused("install.%s is not set in the config" % key)
    for name, value in (("install.python", i["python"]), ("install.code_dir", i["code_dir"]),
                        ("install.config_file", i["config_file"]), ("install.units_dir", i["units_dir"]),
                        ("store", cfg["store"])) + ((("spool", cfg["spool"]),) if cfg["spool"] else ()) + (
                            (("token_file", cfg["token_file"]),) if cfg["token_file"] else ()):
        if not os.path.isabs(value):
            raise Refused("%s must be an absolute path, not %r" % (name, value))
        # a unit file splits a line into words at a space
        if any(c.isspace() or not c.isprintable() for c in value):
            raise Refused("%s must not hold a space or a control character: %r" % (name, value))
    for key in ("account", "ingest_interval", "prune_calendar"):
        # each is written into a unit as the rest of one line
        if not i[key].isprintable() or (key == "account" and any(c.isspace() for c in i[key])):
            raise Refused("install.%s must be one line%s: %r" % (key, " with no space" if key == "account" else "", i[key]))
    if not cfg["port"] or not cfg["token_file"]:
        raise Refused("a service needs a fixed port and a token_file in the config: nobody sees what it prints")
    try:
        pwd.getpwnam(i["account"])
    except KeyError:
        raise Refused("install.account names %r, which is not an account on this host: create it first, "
                      "with no login shell" % i["account"])
    items = [("dir", i["code_dir"], 0o755, False, None),
             ("dir", os.path.join(i["code_dir"], "fleetdash"), 0o755, False, None),
             ("dir", os.path.join(i["code_dir"], "web"), 0o755, False, None),
             ("dir", os.path.join(i["code_dir"], "bin"), 0o755, False, None)]
    for src, dst in ((HERE, "fleetdash"), (WEB, "web")):
        for name in sorted(os.listdir(src)):
            full = os.path.join(src, name)
            if os.path.isfile(full) and name != "README.md":
                with open(full, "rb") as fh:
                    items.append(("file", os.path.join(i["code_dir"], dst, name), 0o644, False, fh.read()))
    items.append(("file", launcher(cfg), 0o755, False, _launcher_text(cfg).encode()))
    with open(config_path, "rb") as fh:
        # read by everyone: `feed` runs as each person. It holds no secret.
        items += [("dir", os.path.dirname(i["config_file"]), 0o755, False, None),
                  ("file", i["config_file"], 0o644, False, fh.read())]
    items.append(("dir", os.path.dirname(cfg["store"]), 0o700, True, None))
    if os.path.dirname(cfg["token_file"]) != os.path.dirname(cfg["store"]):
        items.append(("dir", os.path.dirname(cfg["token_file"]), 0o700, True, None))
    if cfg["spool"]:
        items.append(("dir", cfg["spool"], SPOOL_MODE, True, None))
    for name, text in sorted(units(cfg).items()):
        items.append(("file", os.path.join(i["units_dir"], name), 0o644, False, text.encode()))
    return items


def pending(items, account, root):
    """The items the host does not hold yet, each with why. Refused when
    something else sits where one belongs."""
    want = pwd.getpwnam(account)
    out = []
    for kind, path, mode, owned, content in items:
        real = root + path if root else path
        try:
            st = os.lstat(real)
        except FileNotFoundError:
            out.append(((kind, path, mode, owned, content), "missing"))
            continue
        if kind == "dir" and not stat.S_ISDIR(st.st_mode) or kind == "file" and not stat.S_ISREG(st.st_mode):
            # never made right by writing: a link here would send the write,
            # and the ownership, somewhere else
            raise Refused("%s is there and is not a %s: move it away first"
                          % (real, "directory" if kind == "dir" else "regular file"))
        why = []
        if kind == "file":
            with open(real, "rb") as fh:
                if fh.read() != content:
                    why.append("content differs")
        if stat.S_IMODE(st.st_mode) != mode:
            why.append("mode %o, should be %o" % (stat.S_IMODE(st.st_mode), mode))
        if not root:
            uid, gid = (want.pw_uid, want.pw_gid) if owned else (0, 0)
            if (st.st_uid, st.st_gid) != (uid, gid):
                why.append("owner %d:%d, should be %d:%d" % (st.st_uid, st.st_gid, uid, gid))
        if why:
            out.append(((kind, path, mode, owned, content), ", ".join(why)))
    return out


def _place(item, account, root):
    kind, path, mode, owned, content = item
    real = root + path if root else path
    if kind == "dir":
        os.makedirs(real, exist_ok=True)
    else:
        # a system directory such as units_dir is already there; under --root it is not
        os.makedirs(os.path.dirname(real), exist_ok=True)
        # written beside the target and renamed over it: a reader sees the old file or the new
        tmp = real + ".new"
        try:
            os.unlink(tmp)  # whatever an earlier run, or anyone else, left under that name
        except FileNotFoundError:
            pass
        with os.fdopen(os.open(tmp, os.O_CREAT | os.O_EXCL | os.O_WRONLY | os.O_NOFOLLOW, 0o600), "wb") as fh:
            fh.write(content)
        os.rename(tmp, real)
    if not root:
        want = pwd.getpwnam(account)
        os.chown(real, *((want.pw_uid, want.pw_gid) if owned else (0, 0)), follow_symlinks=False)
    if stat.S_ISLNK(os.lstat(real).st_mode):
        raise OSError("%s became a link while it was being placed" % real)
    os.chmod(real, mode)  # after chown, which clears setgid


def _systemctl(*args):
    return subprocess.run(("systemctl",) + args, stdin=subprocess.DEVNULL).returncode


def main(cfg, config_path, apply=False, root="", systemctl=_systemctl, out=sys.stdout, err=sys.stderr):
    account = cfg["install"]["account"]
    try:
        todo = pending(plan(cfg, config_path), account, root)
    except Refused as e:
        print("fleetdash install: refused: %s" % e, file=err)
        return 1
    for item, why in todo:
        print("%s %s: %s" % ("place" if apply else "would place", item[1], why), file=out)
    if not apply:
        print("%d to change" % len(todo), file=out)
        return 1 if todo else 0
    if not root and os.geteuid() != 0:
        print("fleetdash install: --apply writes system directories and must run as root "
              "(or with --root DIR to build the tree somewhere else)", file=err)
        return 2
    try:
        for item, _why in todo:
            _place(item, account, root)
    except OSError as e:
        print("fleetdash install: stopped at %s; run it again once that is fixed" % e, file=err)
        return 2
    if not root:
        # asked every time: both are no-ops on a host that already matches
        if systemctl("daemon-reload") != 0 or systemctl("enable", "--now", *ENABLE) != 0:
            print("fleetdash install: the files are in place but systemd refused the units", file=err)
            return 2
        if any(item[1].startswith(cfg["install"]["code_dir"]) or item[1] == cfg["install"]["config_file"]
               for item, _why in todo) and systemctl("try-restart", "fleetdash-serve.service") != 0:
            print("fleetdash install: the files are in place but the server did not restart", file=err)
            return 2
    print("%d changed" % len(todo), file=out)
    return 0
