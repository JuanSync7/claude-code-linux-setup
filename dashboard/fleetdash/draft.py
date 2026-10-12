"""A policy change as a patch for a merge request.

The page names rules to add to or remove from the repository's policy file;
this answers with a patch a person applies in a checkout and puts up for
review. Nothing here writes a file: the policy changes in the repository, by
review, and reaches a host when it is installed there.

The policy file is laid out by hand, so it is not written back from parsed
JSON, which would change every line. The lists are found in the text by
position, only those the draft changes are rewritten, and the result must
parse to exactly the document the draft describes or it is refused.

A patch shows the lines around a change. Here those lines are kept inside the
lists being changed: the Policy page shows rules and never an environment
value or a path, and a patch must not show more than the page does.
"""
import difflib
import hashlib
import json
import os

from fleetdash import ingest
from fleetdash.api import RULE_KINDS
from fleetdash.vocab import DRAFT_OPS

EDITS_MAX = 50     # changes in one draft
RULE_MAX = 500     # characters in one rule
CONTEXT_MAX = 3    # lines shown either side of a change, when the list has them
WS = " \t\n\r"
BY_HAND = "make this change by hand in the repository"
_decoder = json.JSONDecoder()


class Refused(ValueError):
    """The draft cannot be made; the message says why, for the page."""


def parse(given):
    """The edits a page sent, from the JSON text of its query."""
    try:
        return json.loads(given or "")
    except (ValueError, RecursionError):
        raise Refused("edits must be a JSON list of changes")


def _checked(edits):
    """The edits as (op, list, rule), or Refused: each whole, of a known kind,
    one printable line, and none said twice or against another."""
    if not isinstance(edits, list) or not 0 < len(edits) <= EDITS_MAX:
        raise Refused("a draft is a list of 1 to %d changes" % EDITS_MAX)
    out, seen = [], set()
    for e in edits:
        if not isinstance(e, dict) or sorted(e) != ["list", "op", "rule"]:
            raise Refused('each change is {"op": ..., "list": ..., "rule": ...}')
        op, kind, rule = e["op"], e["list"], e["rule"]
        if op not in DRAFT_OPS or kind not in RULE_KINDS:
            raise Refused("a change is one of %s, to one of %s" % (", ".join(DRAFT_OPS), ", ".join(RULE_KINDS)))
        if (not isinstance(rule, str) or not 0 < len(rule) <= RULE_MAX or not ingest.storable(rule)
                or not rule.isprintable() or rule != rule.strip()):
            raise Refused("a rule is one line of 1 to %d printable characters, with no space at either end" % RULE_MAX)
        if (kind, rule) in seen:
            raise Refused("%s is changed twice in the %s list" % (rule, kind))
        seen.add((kind, rule))
        out.append((op, kind, rule))
    return out


def _skip(text, i):
    while text[i] in WS:
        i += 1
    return i


def _span(text, i):
    """Where the JSON value at text[i:] lies: (start, end, members). members
    is {key: (key start, value span)} for an object, a list of spans for an
    array, and None for anything else. The text has already parsed, so its
    grammar is not checked again."""
    i = _skip(text, i)
    if text[i] not in "{[":
        return (i, _decoder.raw_decode(text, i)[1], None)
    obj = text[i] == "{"
    members = {} if obj else []
    j = _skip(text, i + 1)
    while text[j] not in "}]":
        if obj:
            key, after = _decoder.raw_decode(text, j)
            child = _span(text, _skip(text, after) + 1)
            members[key] = (j, child)  # a key written twice: the last one, as the parser takes it
        else:
            child = _span(text, j)
            members.append(child)
        j = _skip(text, child[1])
        if text[j] == ",":
            j = _skip(text, j + 1)
    return (i, j + 1, members)


def _line(text, at):
    return text.count("\n", 0, at)


def _own_lines(text, start, end):
    """Whether text[start:end] has its lines to itself, but for a comma after it."""
    before = text[text.rfind("\n", 0, start) + 1:start]
    after = text[end:text.find("\n", end) if "\n" in text[end:] else len(text)]
    return not before.strip(WS) and after.strip(WS) in ("", ",")


def _source(cfg):
    path = cfg["policy"]["source"]
    try:
        if not path:
            raise OSError("not set")
        with open(path, "rb") as fh:
            raw = fh.read()
        text = raw.decode("utf-8")
        doc = json.loads(text)
        perms = doc["permissions"] if isinstance(doc, dict) else None
        if not isinstance(perms, dict) or not perms or not all(isinstance(perms.get(k, []), list) for k in RULE_KINDS):
            raise ValueError("no lists of rules")
    except (OSError, ValueError, KeyError, RecursionError):
        raise Refused("there is no policy file with lists of rules to draft against: "
                      "policy.source in the config must name the repository's")
    if not text.endswith("\n"):
        raise Refused("the policy file does not end with a newline: %s" % BY_HAND)
    return path, raw, text, doc


def _named(path):
    """The file as a patch names it: from the top of the checkout it is in,
    which is the nearest directory above it holding .git, or by its file name
    alone when there is none."""
    path = os.path.abspath(path)
    top = os.path.dirname(path)
    while not os.path.lexists(os.path.join(top, ".git")):
        if os.path.dirname(top) == top:
            return os.path.basename(path), False
        top = os.path.dirname(top)
    return os.path.relpath(path, top), True


def patch(cfg, edits):
    """The patch that makes these edits to the repository's policy file, with
    the file it is for and the command that applies it. Raises Refused."""
    edits = _checked(edits)
    path, raw, text, doc = _source(cfg)
    want = json.loads(text)
    perms = want["permissions"]
    for op, kind, rule in edits:
        have = perms.get(kind, [])
        if op == DRAFT_OPS[0]:
            if rule in have:
                raise Refused("%s is already in the %s list" % (rule, kind))
            perms[kind] = have + [rule]
        else:
            if rule not in have:
                raise Refused("%s is not in the %s list" % (rule, kind))
            perms[kind] = [r for r in have if r != rule]

    try:
        _start, _end, top = _span(text, 0)
        obj_start, _obj_end, lists = top["permissions"][1]
    except RecursionError:
        raise Refused("the policy file is nested too deeply: %s" % BY_HAND)
    crowded = Refused("the policy file has another setting on the same line as the rules to change: %s" % BY_HAND)
    changes, shown, fresh = [], set(), []
    for kind in RULE_KINDS:
        if perms.get(kind) == doc["permissions"].get(kind):
            continue
        if kind not in lists:
            fresh.append("%s: [%s]," % (json.dumps(kind), ", ".join(json.dumps(r, ensure_ascii=False) for r in perms[kind])))
            continue
        key_at, (start, end, items) = lists[kind]
        if not _own_lines(text, key_at, end):
            raise crowded
        shown.update(range(_line(text, key_at), _line(text, end - 1) + 1))
        # each rule that stays is kept as it is written; a new one is written as JSON
        kept = [text[a:b] for a, b, _ in items if json.loads(text[a:b]) in perms[kind]]
        kept += [json.dumps(r, ensure_ascii=False) for r in perms[kind] if r not in doc["permissions"][kind]]
        if not kept:
            body = ""
        elif items:
            lead = text[start + 1:items[0][0]]
            body = lead + ("," + (lead or " ")).join(kept) + text[items[-1][1]:end - 1]
        else:
            body = ", ".join(kept)
        changes.append((start, end, "[" + body + "]"))
    if fresh:
        # a list the file does not have yet goes first, on lines of its own
        first = min(key_at for key_at, _ in lists.values())
        lead = text[obj_start + 1:first]
        if "\n" not in lead:
            raise crowded
        changes.append((first, first, lead.join(fresh) + lead))
    new = text
    for start, end, to in sorted(changes, reverse=True):
        new = new[:start] + to + new[end:]
    try:
        if json.loads(new) != want:
            raise ValueError("not the document asked for")
    except ValueError:
        raise Refused("this change could not be written into the policy file as it is laid out: %s" % BY_HAND)

    old_lines, new_lines = text.splitlines(True), new.splitlines(True)
    matcher = difflib.SequenceMatcher(None, old_lines, new_lines)
    for context in range(CONTEXT_MAX, -1, -1):
        if all(i in shown for group in matcher.get_grouped_opcodes(context)
               for _tag, i1, i2, _j1, _j2 in group for i in range(i1, i2)):
            break
    else:
        raise crowded
    name, in_repository = _named(path)
    base = hashlib.sha256(raw).hexdigest()
    head = ["Policy change drafted on the fleet dashboard. Not applied anywhere: for a merge request.\n",
            "Drafted against %s with SHA-256 %s\n" % (name, base)]
    head += ["  %s %s: %s\n" % ("add to" if op == DRAFT_OPS[0] else "remove from", kind, rule) for op, kind, rule in edits]
    body = difflib.unified_diff(old_lines, new_lines, "a/" + name, "b/" + name, n=context)
    return {"file": name, "in_repository": in_repository, "base_sha256": base, "context": context,
            # git reads a patch with no context only when told that is meant
            "apply": ["git", "apply"] + ([] if context else ["--unidiff-zero"]),
            "edits": [{"op": op, "list": kind, "rule": rule} for op, kind, rule in edits],
            "patch": "".join(head) + "\n" + "".join(body)}
