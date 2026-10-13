"""The documents the Docs page shows: Markdown files under the directories the
config lists, served as text for the page to render.

A document is addressed by where it sits in that listing, never by a path from
the request, so nothing outside the configured directories can be asked for.
"""
import os
import stat

DOC_MAX = 1 << 20
SUFFIX = ".md"
# A directory's own map, listed first: it is where a reader of that directory starts.
MAP = "README.md"
# A title written "Name — what it is" is listed by its name; the rest is said under it.
DASH = " — "


def _files(entry):
    """(relative name, full path) for each document an entry holds: the file
    itself, or every Markdown file under the directory. Only a regular file
    counts: a link is not followed and a pipe is never opened."""
    path = entry["path"]
    if os.path.isfile(path):
        return [(os.path.basename(path), path)] if path.endswith(SUFFIX) else []
    found = []
    for dirpath, dirs, files in os.walk(path):
        dirs.sort()
        for name in sorted(files):
            full = os.path.join(dirpath, name)
            if name.endswith(SUFFIX) and _regular(full):
                found.append((os.path.relpath(full, path), full))
    return sorted(found, key=lambda f: f[0] != MAP)


def _regular(full):
    try:
        return stat.S_ISREG(os.lstat(full).st_mode)
    except OSError:
        return False


def _title(full, fallback):
    """The first level-one heading, as the document names itself."""
    try:
        with open(full, encoding="utf-8", errors="replace") as fh:
            for line in fh.read(DOC_MAX).splitlines():
                if line.startswith("# "):
                    return line[2:].strip()
    except OSError:
        pass
    return fallback


def split_title(title):
    """(name, what it is): a title cut at its first spaced em dash."""
    name, _, about = title.partition(DASH)
    return name.strip(), about.strip()


def _named(full, fallback):
    title, about = split_title(_title(full, fallback))
    return {"title": title, "about": about}


def index(cfg):
    groups = []
    for i, entry in enumerate(cfg["docs"]):
        # path: where a link written in one document points, so the page can
        # tell when that is another listed document
        docs = [dict(_named(full, rel), id="%d:%s" % (i, rel), name=rel, path=os.path.abspath(full))
                for rel, full in _files(entry)]
        # a directory that is not there is said so, not shown as an empty group
        groups.append({"label": entry["label"], "found": os.path.exists(entry["path"]), "docs": docs})
    return {"groups": groups}


def read(cfg, doc_id):
    """The text of one listed document. ValueError when the id names none."""
    for i, entry in enumerate(cfg["docs"]):
        for rel, full in _files(entry):
            if "%d:%s" % (i, rel) != doc_id:
                continue
            # a listed name can still be a link out of the directory
            base = os.path.realpath(entry["path"])
            real = os.path.realpath(full)
            if real != base and not real.startswith(base + os.sep):
                raise ValueError("that document is a link to somewhere else")
            if os.path.getsize(real) > DOC_MAX:
                raise ValueError("that document is over %d bytes" % DOC_MAX)
            with open(real, encoding="utf-8", errors="replace") as fh:
                return dict(_named(real, rel), id=doc_id, name=rel, group=entry["label"],
                            path=os.path.abspath(full), markdown=fh.read())
    raise ValueError("no such document")
