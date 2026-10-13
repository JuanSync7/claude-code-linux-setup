"""Read-only queries behind the JSON API. Each returns plain dicts and lists.

Unknown stays distinct from zero: a model with no row in the price table makes
the total cost None ("unpriced"), never a smaller number that looks complete.
"""
import csv
import datetime
import io
import json
import re

from fleetdash import ingest, store
from fleetdash.vocab import ADMIN_KINDS, ADMIN_LOG_STATES, CATEGORIES, NOT_A_MODEL, PERSON_STATES, PROVIDERS, SEVERITIES

MONTH_DAYS = 30.0
TOKEN_KINDS = ("input", "output", "cache_read", "cache_write")


def _now(now):
    return now or datetime.datetime.utcnow()


def _since(now, days):
    return store.iso(_now(now) - datetime.timedelta(days=days))


def _price(cfg, model):
    """Longest model-family prefix wins, after dropping a Bedrock region
    prefix (anthropic. or eu.anthropic.) and a version or context suffix."""
    name = re.sub(r"^(?:[a-z]{2,4}\.)?anthropic\.", "", model)
    name = re.sub(r"(-v\d+(:\d+)?|\[[^\]]*\])$", "", name)
    best = None
    for family in cfg["prices_per_mtok"]:
        if name.startswith(family) and (best is None or len(family) > len(best)):
            best = family
    return cfg["prices_per_mtok"][best] if best else None


def status(cfg):
    """What the frame around every page shows: which site, and how fresh."""
    con = store.connect(cfg)
    try:
        last = con.execute("select v from meta where k='last_ingest'").fetchone()
    finally:
        con.close()
    return {"host_label": cfg["host_label"], "last_ingest": last["v"] if last else None}


def _usd(p, m):
    return (m["input"] * p["input"] + m["output"] * p["output"] + m["cache_read"] * p["cache_read"]
            + m["cache_write"] * p["cache_write"]) / 1e6


def _providers(cfg, rows):
    """One table per provider: its models, each with its token counts and
    what they cost at the configured prices. A call is Bedrock's when its
    message id starts the way Bedrock's do, or its model is named the Bedrock
    way. Bedrock answers with the plain model name, so the name alone misses
    most of them. A provider with an unpriced model has no total."""
    named = re.compile(cfg["bedrock_model_pattern"])
    models = {}
    for r in rows:
        prov = "bedrock" if r["by_id"] or named.search(r["model"]) else "anthropic"
        m = models.setdefault((prov, r["model"]), dict.fromkeys(TOKEN_KINDS, 0))
        for k in TOKEN_KINDS:
            m[k] += r[k]
    out = []
    for prov in PROVIDERS:
        table = {"provider": prov, "tokens": 0, "priced_usd": 0.0, "unpriced_models": [], "models": []}
        table.update(dict.fromkeys(TOKEN_KINDS, 0))
        for (p, model), m in sorted(models.items()):
            if p != prov:
                continue
            tokens = sum(m[k] for k in TOKEN_KINDS)
            price = _price(cfg, model)
            usd = None if price is None else _usd(price, m)
            if usd is not None:
                table["priced_usd"] += usd
            elif tokens:
                table["unpriced_models"].append(model)
            for k in TOKEN_KINDS:
                table[k] += m[k]
            table["tokens"] += tokens
            table["models"].append(dict(m, model=model, tokens=tokens, usd=usd))
        table["usd"] = None if table["unpriced_models"] else table["priced_usd"]
        out.append(table)
    return out


def overview(cfg, days=30, now=None):
    since = _since(now, days)
    prefix = cfg["bedrock_id_prefix"]
    con = store.connect(cfg)
    try:
        models = con.execute(
            "select length(?)>0 and substr(id,1,length(?))=? by_id, model, sum(input) input, "
            "sum(output) output, sum(cache_read) cache_read, sum(cache_write) cache_write "
            "from usage where ts>=? and model!=? group by by_id, model",
            (prefix, prefix, prefix, since, NOT_A_MODEL)).fetchall()
        by_user = con.execute(
            "select user, sum(input+output+cache_read+cache_write) tokens, sum(input) input, "
            "sum(output) output, sum(cache_read) cache_read, sum(cache_write) cache_write, "
            "count(distinct session) sessions from usage where ts>=? group by user order by tokens desc",
            (since,)).fetchall()
        daily = con.execute(
            "select substr(ts,1,10) day, sum(input+output+cache_read+cache_write) tokens "
            "from usage where ts>=? group by day order by day", (since,)).fetchall()
        sev = con.execute("select severity, count(*) n from events where ts>=? group by severity",
                          (since,)).fetchall()
        blocks = con.execute(
            "select source, count(*) n from events where ts>=? and severity='deny' "
            "group by source order by n desc, source", (since,)).fetchall()
        storage = con.execute("select count(*) n, coalesce(sum(bytes),0) b, count(distinct user) u "
                              "from sessions").fetchone()
        last = con.execute("select v from meta where k='last_ingest'").fetchone()
        heard = [r[0] for r in con.execute("select last_seen from hosts")]
    finally:
        con.close()
    stale_before = _stale_before(cfg, now)
    providers = _providers(cfg, models)
    priced = sum(p["priced_usd"] for p in providers)
    unpriced = sorted({m for p in providers for m in p["unpriced_models"]})

    seat_users = sorted({u for s in cfg["seats"] for u in s["users"]})
    seat_usd = sum(s["monthly_usd"] * len(s["users"]) for s in cfg["seats"]) * days / MONTH_DAYS
    counts = {s["severity"]: s["n"] for s in sev}
    return {
        "host_label": cfg["host_label"],
        "days": days,
        "last_ingest": last["v"] if last else None,
        "by_user": [dict(r) for r in by_user],
        "providers": providers,
        "daily": [dict(r) for r in daily],
        "cost": {"priced_usd": priced, "unpriced_models": unpriced,
                 "total_usd": None if unpriced else priced},
        "seats": {"window_usd": seat_usd, "count": len(seat_users),
                  "tiers": [{"tier": s["tier"], "monthly_usd": s["monthly_usd"], "users": len(s["users"])}
                            for s in cfg["seats"]]},
        "severity_counts": {s: counts.get(s, 0) for s in SEVERITIES},
        "blocks": [{"source": r["source"] or "(unnamed)", "count": r["n"]} for r in blocks],
        "storage": {"sessions": storage["n"], "bytes": storage["b"], "users": storage["u"]},
        "hosts": {"count": len(heard), "stale": len([t for t in heard if t[:19] < stale_before])},
    }


# what a stopped call's record holds beyond its event: store.py says what each is
INCIDENT = ("input", "input_kind", "input_len", "fields", "said", "cwd", "branch", "client", "call_id")


def events(cfg, user=None, severity=None, category=None, source=None, tool=None, limit=200, offset=0):
    if severity is not None and severity not in SEVERITIES:
        raise ValueError("unknown severity %r" % severity)
    if category is not None and category not in CATEGORIES:
        raise ValueError("unknown category %r" % category)
    given = [(col, val) for col, val in (("user", user), ("severity", severity), ("category", category),
                                         ("source", source), ("tool", tool)) if val is not None]

    def where(filters):
        clause = " where " + " and ".join(col + "=?" for col, _ in filters) if filters else ""
        return clause, [val for _, val in filters]

    clause, args = where(given)
    # the tab counts ignore the category filter, so every tab stays visible
    tab_clause, tab_args = where([f for f in given if f[0] != "category"])
    con = store.connect(cfg)
    try:
        total = con.execute("select count(*) from events" + clause, args).fetchone()[0]
        rows = con.execute("select e.key, ts, user, session, severity, category, source, tool, detail, host, "
                           + ", ".join(INCIDENT) + ", i.key incident from events e left join incidents i "
                           "on i.key=e.key" + clause + " order by ts desc, e.key limit ? offset ?",
                           args + [limit, offset]).fetchall()
        by_cat = con.execute("select category, count(*) n from events" + tab_clause + " group by category",
                             tab_args).fetchall()
        # what is stored, so a filter never offers a value that matches nothing at all
        distinct = {col: [r[0] for r in con.execute(
            "select distinct %s from events where %s!='' order by 1" % (col, col))] for col in ("user", "source", "tool")}
    finally:
        con.close()
    present = {r["category"]: r["n"] for r in by_cat}
    shown = []
    for r in rows:
        r = dict(r)
        del r["key"]
        # the fuller record of a stopped call, where one was kept: None is "not recorded", not "nothing asked"
        kept = {col: r.pop(col) for col in INCIDENT}
        kept["fields"] = None if kept["fields"] is None else json.loads(kept["fields"])
        r["incident"] = kept if r["incident"] is not None else None
        shown.append(r)
    return {"total": total, "rows": shown,
            "by_category": [{"category": c, "count": present.get(c, 0)} for c in CATEGORIES],
            "facets": {"users": distinct["user"], "sources": distinct["source"], "tools": distinct["tool"],
                       "severities": list(SEVERITIES), "categories": list(CATEGORIES)}}


def _age_days(now, ts):
    if not ts:
        return None
    then = datetime.datetime.strptime(ts[:19], store.ISO)
    return (_now(now) - then).days


def sessions(cfg, user=None, now=None, limit=500):
    clause, args = ("", []) if user is None else (" where user=?", [user])
    con = store.connect(cfg)
    try:
        rows = con.execute("select user, project, session, bytes, first_ts, last_ts, records "
                           "from sessions" + clause + " order by bytes desc limit ?",
                           args + [limit]).fetchall()
        per_user = con.execute("select user, count(*) sessions, sum(bytes) bytes, min(last_ts) oldest "
                               "from sessions" + clause + " group by user order by bytes desc",
                               args).fetchall()
        total = con.execute("select count(*), coalesce(sum(bytes),0) from sessions" + clause, args).fetchone()
        users = [r[0] for r in con.execute("select distinct user from sessions order by user")]
    finally:
        con.close()
    out = []
    for r in rows:
        d = dict(r)
        d["age_days"] = _age_days(now, r["last_ts"])
        out.append(d)
    return {"rows": out, "total": {"sessions": total[0], "bytes": total[1]},
            "by_user": [{"user": r["user"], "sessions": r["sessions"], "bytes": r["bytes"],
                         "oldest_days": _age_days(now, r["oldest"])} for r in per_user],
            "facets": {"users": users}}


def _median(values):
    v = sorted(values)
    if not v:
        return None
    mid = len(v) // 2
    return v[mid] if len(v) % 2 else (v[mid - 1] + v[mid]) / 2.0


def people(cfg, days=30, now=None):
    """One row per person who has used Claude Code or holds a seat: their use
    in the window, the limit windows they hit, and why they look under-used.

    A limit hit is one event per limit window (ingest keys it by reset time),
    so retries while blocked are not counted again. Under-use is a prompt to
    look, not a verdict: the rules come from the config and are returned with
    the figures."""
    since = _since(now, days)
    rules = cfg["under_use"]
    con = store.connect(cfg)
    try:
        used = {r["user"]: r for r in con.execute(
            "select user, sum(input+output+cache_read+cache_write) tokens, count(distinct session) sessions, "
            "count(distinct substr(ts,1,10)) active_days from usage where ts>=? group by user", (since,))}
        last = {r[0]: r[1] for r in con.execute("select user, max(ts) from usage group by user")}
        limits = con.execute(
            "select user, detail, count(*) n, max(ts) last from events "
            "where category='rate-limit' and ts>=? group by user, detail", (since,)).fetchall()
        by_model = con.execute(
            "select user, model, sum(input) i, sum(output) o, sum(cache_read) cr, sum(cache_write) cw "
            "from usage where ts>=? group by user, model", (since,)).fetchall()
    finally:
        con.close()
    # a person's cost is unknown (None) as soon as one model they used has no price
    usd = {}
    for m in by_model:
        p = _price(cfg, m["model"])
        if p is None:
            if m["i"] + m["o"] + m["cr"] + m["cw"]:
                usd[m["user"]] = None
        elif usd.get(m["user"], 0.0) is not None:
            usd[m["user"]] = usd.get(m["user"], 0.0) + (
                m["i"] * p["input"] + m["o"] * p["output"] + m["cr"] * p["cache_read"]
                + m["cw"] * p["cache_write"]) / 1e6
    tier, seat_usd = {}, {}
    for seat in cfg["seats"]:
        for u in seat["users"]:
            if u not in tier:
                tier[u], seat_usd[u] = seat["tier"], seat["monthly_usd"] * days / MONTH_DAYS
    hits = {}
    for r in limits:
        h = hits.setdefault(r["user"], {"five_hour": 0, "seven_day": 0, "other_limit": 0, "last_limit": None})
        kind = r["detail"].split(" ")[0]
        h[kind if kind in ("five_hour", "seven_day") else "other_limit"] += r["n"]
        h["last_limit"] = max(x for x in (h["last_limit"], r["last"]) if x)
    median = _median([r["tokens"] for r in used.values() if r["tokens"]])
    rows = []
    for user in sorted(set(used) | set(last) | set(tier)):
        u = used.get(user)
        row = {"user": user, "tier": tier.get(user),
               "tokens": u["tokens"] if u else 0, "sessions": u["sessions"] if u else 0,
               "active_days": u["active_days"] if u else 0, "last_active": last.get(user),
               "usd": usd.get(user, 0.0), "seat_usd": seat_usd.get(user),
               "five_hour": 0, "seven_day": 0, "other_limit": 0, "last_limit": None}
        row.update(hits.get(user, {}))
        age = _age_days(now, row["last_active"])
        why = []
        if age is None:
            why.append("never used")
        elif age >= rules["idle_days"]:
            why.append("no use in %d days" % age)
        elif row["tokens"] and median and row["tokens"] < rules["median_fraction"] * median:
            why.append("under %d%% of the median" % round(100 * rules["median_fraction"]))
        row["under_use"] = why
        rows.append(row)
    rows.sort(key=lambda r: (-r["tokens"], r["user"]))
    return {"days": days, "rules": dict(rules), "median_tokens": median, "rows": rows}


REPORT_COLUMNS = ("user", "tier", "tokens", "usd", "seat_usd", "sessions", "active_days", "last_active",
                  "five_hour", "seven_day", "other_limit", "last_limit", "under_use")


def people_csv(cfg, days=30, now=None):
    """The People table as CSV, for a report. An unknown value is an empty
    cell, never 0."""
    out = io.StringIO()
    w = csv.writer(out, lineterminator="\n")
    w.writerow(REPORT_COLUMNS)
    for r in people(cfg, days=days, now=now)["rows"]:
        r = dict(r, under_use="; ".join(r["under_use"]))
        w.writerow([_cell(r[c]) for c in REPORT_COLUMNS])
    return out.getvalue()


def _cell(v):
    if v is None:
        return ""
    if isinstance(v, float):
        return "%.2f" % v
    v = str(v)
    # a spreadsheet runs a cell that starts like a formula; a name is whatever a log says
    return "'" + v if v[:1] in ("=", "+", "-", "@", "\t", "\r") else v


def _stale_before(cfg, now):
    return store.iso(_now(now) - datetime.timedelta(hours=cfg["host_stale_hours"]))


def _version_key(v):
    return tuple(int(x) for x in v.split("."))


def hosts(cfg, days=30, now=None):
    """One row per host that has checked in: when, which Claude Code, and
    whether the policy it holds is the one the config says the fleet should,
    and whether what is installed on it is what was installed (its drift
    report, None when it never sent one). A host that stopped checking in is
    stale; its figures are not zero. A drift report older than the drift rule
    is stale too: it says what was true when the health check last ran."""
    since, stale_before = _since(now, days), _stale_before(cfg, now)
    drift_before = store.iso(_now(now) - datetime.timedelta(hours=cfg["drift"]["max_age_hours"]))
    expected = ingest.file_sha256(cfg["policy"]["source"])
    con = store.connect(cfg)
    try:
        rows = con.execute("select * from hosts order by host").fetchall()
        drift = {r["host"]: ingest.stored_drift(r) for r in con.execute("select * from drift")}
        counts = {}
        for r in con.execute("select host, severity, count(*) n from events where ts>=? and host!='' "
                             "group by host, severity", (since,)):
            counts.setdefault(r["host"], {})[r["severity"]] = r["n"]
    finally:
        con.close()
    versions = [r["claude_version"] for r in rows if r["claude_version"]]
    newest = max(versions, key=_version_key) if versions else None
    out = []
    for r in rows:
        if r["policy_sha256"] is None or expected is None:
            policy = "unknown"
        else:
            policy = "current" if r["policy_sha256"] == expected else "differs"
        c = counts.get(r["host"], {})
        out.append({"host": r["host"], "last_seen": r["last_seen"],
                    "stale": r["last_seen"][:19] < stale_before,
                    "claude_version": r["claude_version"],
                    "version_behind": bool(r["claude_version"]) and r["claude_version"] != newest,
                    "policy_sha256": r["policy_sha256"], "policy": policy, "reported_by": r["reported_by"],
                    "events": {s: c.get(s, 0) for s in SEVERITIES},
                    "drift": _drift_row(drift.get(r["host"]), drift_before)})
    return {"days": days, "stale_hours": cfg["host_stale_hours"], "drift_max_age_hours": cfg["drift"]["max_age_hours"],
            "expected_policy_sha256": expected,
            "newest_version": newest, "rows": out}


def _drift_row(d, before):
    if d is None:
        return None
    return dict(d, stale=d["ts"][:19] < before)


def enrolment(cfg, now=None):
    """Who is sending data and who has stopped. A host is quiet on the Hosts
    page's rule. A person is quiet when their newest stored use or event is
    older than the People page's idle rule, and has never sent when there is
    none: a seat nobody uses and a feed that is not set up look the same from
    here. A file that was refused is counted against the person it names and
    is not data from them."""
    stale_before = _stale_before(cfg, now)
    idle_before = store.iso(_now(now) - datetime.timedelta(days=cfg["under_use"]["idle_days"]))
    con = store.connect(cfg)
    try:
        hosts = con.execute("select host, last_seen, reported_by from hosts order by host").fetchall()
        last = {}
        for r in con.execute("select user, max(ts) t from usage group by user union all "
                             "select user, max(ts) t from events where category!='log-integrity' group by user"):
            last[r["user"]] = max(last.get(r["user"], ""), r["t"])
        seen = {}
        for r in con.execute("select distinct user, host from events where host!='' and category!='log-integrity' "
                             "order by host"):
            seen.setdefault(r["user"], []).append(r["host"])
        refused = {}
        # newest first, so the first row kept for a person is their latest
        for r in con.execute("select user, ts, detail from events where category='log-integrity' "
                             "order by ts desc, key"):
            p = refused.setdefault(r["user"], {"n": 0, "last": {"ts": r["ts"], "why": r["detail"]}})
            p["n"] += 1
    finally:
        con.close()
    seat = {}
    for row in cfg["seats"]:
        for u in row["users"]:
            seat.setdefault(u, row["tier"])
    heard = {}
    for hs in seen.values():
        for host in hs:
            heard[host] = heard.get(host, 0) + 1
    people = []
    for user in sorted(set(last) | set(refused) | set(seat)):
        t = last.get(user)
        sending, quiet, never = PERSON_STATES
        state = never if t is None else quiet if t[:19] < idle_before else sending
        people.append({"user": user, "seat": seat.get(user), "state": state, "last_data": t,
                       "hosts": seen.get(user, []), "refused": refused.get(user, {"n": 0})["n"],
                       "last_refused": refused[user]["last"] if user in refused else None})
    return {"stale_hours": cfg["host_stale_hours"], "idle_days": cfg["under_use"]["idle_days"],
            "hosts": [{"host": r["host"], "last_seen": r["last_seen"], "stale": r["last_seen"][:19] < stale_before,
                       "reported_by": r["reported_by"], "people": heard.get(r["host"], 0)} for r in hosts],
            "people": people}


# how many sessions and refusals the page is given, newest first, and how many
# of one session's tool calls
ADMIN_ROWS_SHOWN = 100
ADMIN_RAN_SHOWN = 50


def _admin_log_state(cfg, con):
    not_configured, not_read_yet = ADMIN_LOG_STATES[:2]
    found = {"state": not_configured if not cfg["admin_log"] else not_read_yet, "at": None, "error": None}
    if cfg["admin_log"]:
        row = con.execute("select v from meta where k='admin_log'").fetchone()
        if row:
            found = json.loads(row["v"])
    return dict(found, path=cfg["admin_log"])


def admin_sessions(cfg, now=None):
    """The privileged session's log as sessions: each start with the end
    that shares its host and process number, and each refusal. A start with
    no end is still open or its end was never written, and the log cannot say
    which; an end with no start was started before the log was first read.

    What a session ran is not in that log. It is counted from the tool calls
    and blocks the hooks logged for that account on that host between the
    start and the end, so an ordinary session the same person had open then
    is counted too. It is unknown (None), not zero, without both ends, or
    once tool calls that old are past their retention."""
    start, end, refused = ADMIN_KINDS
    kept_since = _since(now, cfg["retention"]["pass"]["days"])
    con = store.connect(cfg)
    try:
        log = _admin_log_state(cfg, con)
        sessions, refusals, open_ = [], [], {}
        for r in con.execute("select * from admin_log order by ts, rowid"):
            who = {"host": r["host"], "invoker": r["invoker"], "target": r["target"], "tty": r["tty"]}
            at = (r["host"], r["pid"])
            if r["kind"] == refused:
                refusals.append(dict(who, ts=r["ts"], reason=r["reason"], detail=r["detail"]))
            elif r["kind"] == start:
                # the same process number starting again: the one before never wrote its end
                open_[at] = dict(who, started=r["ts"], ended=None, seconds=None, rc=None)
                sessions.append(open_[at])
            elif r["kind"] == end:
                s = open_.pop(at, None)
                if s is None:
                    s = dict(who, started=None, seconds=None)
                    sessions.append(s)
                else:
                    s["seconds"] = int((datetime.datetime.strptime(r["ts"][:19], store.ISO)
                                        - datetime.datetime.strptime(s["started"][:19], store.ISO)).total_seconds())
                s.update(ended=r["ts"], rc=r["rc"])
        sessions.sort(key=lambda s: (s["started"] or s["ended"])[:19], reverse=True)
        refusals.reverse()
        shown = sessions[:ADMIN_ROWS_SHOWN]
        for s in shown:
            s.update(calls=None, blocked=None, ran=None)
            if s["started"] is None or s["ended"] is None or s["ended"][:19] < kept_since:
                continue
            window = (s["target"], s["host"], s["started"][:19], s["ended"][:19])
            where = ("from events where user=? and host=? and ts>=? and substr(ts,1,19)<=? "
                     "and category in ('tool-call','denial')")
            n = {r["category"]: r["n"] for r in con.execute(
                "select category, count(*) n %s group by category" % where, window)}
            s.update(calls=n.get("tool-call", 0), blocked=n.get("denial", 0), ran=[
                {"ts": r["ts"], "severity": r["severity"], "tool": r["tool"], "detail": r["detail"]}
                for r in con.execute("select ts, severity, tool, detail %s order by ts, key limit ?" % where,
                                     window + (ADMIN_RAN_SHOWN,))])
    finally:
        con.close()
    return {"log": log, "sessions": shown, "sessions_total": len(sessions),
            "refusals": refusals[:ADMIN_ROWS_SHOWN], "refusals_total": len(refusals),
            "ran_shown": ADMIN_RAN_SHOWN, "calls_kept_days": cfg["retention"]["pass"]["days"]}


def retention(cfg, now=None):
    """What the store keeps and for how long: each severity's rule, how many
    events it holds, and how many the next prune would remove. Usage rows and
    the privileged session's log are never pruned; the Update page's runs are
    kept by count."""
    con = store.connect(cfg)
    try:
        held = {r["severity"]: r for r in con.execute(
            "select severity, count(*) n, min(ts) oldest from events group by severity")}
        would = store.prunable(con, cfg, now=_now(now))
        usage = con.execute("select count(*) n, min(ts) oldest from usage").fetchone()
        runs = con.execute("select count(*) from runs").fetchone()[0]
        admin = con.execute("select count(*) n, min(ts) oldest from admin_log").fetchone()
    finally:
        con.close()
    return {"rows": [{"severity": s, "days": cfg["retention"][s]["days"], "max_rows": cfg["retention"][s]["max_rows"],
                      "stored": held[s]["n"] if s in held else 0, "oldest": held[s]["oldest"] if s in held else None,
                      "would_remove": would[s]} for s in SEVERITIES],
            "usage": {"stored": usage["n"], "oldest": usage["oldest"]},
            "admin_log": {"stored": admin["n"], "oldest": admin["oldest"]},
            "runs": {"keep": cfg["runs"]["keep"], "stored": runs}}


RULE_KINDS = ("deny", "ask", "allow")


def _policy_file(path):
    """What one policy file says, reduced to what the page shows. state is
    not-configured, missing, unreadable or ok."""
    if not path:
        return {"path": "", "state": "not-configured"}
    try:
        with open(path, "rb") as fh:
            raw = fh.read()
    except FileNotFoundError:
        return {"path": path, "state": "missing"}
    except OSError:
        return {"path": path, "state": "unreadable"}
    try:
        doc = json.loads(raw.decode("utf-8"))
        if not isinstance(doc, dict):
            raise ValueError("not an object")
        perms = doc.get("permissions", {})
        # rules in a shape this cannot read are not "no rules"
        if not isinstance(perms, dict) or not all(isinstance(perms.get(k, []), list) for k in RULE_KINDS):
            raise ValueError("permissions is not lists of rules")
    except (ValueError, RecursionError):
        return {"path": path, "state": "unreadable"}
    hooks = []
    for event_name, groups in sorted((doc.get("hooks") if isinstance(doc.get("hooks"), dict) else {}).items()):
        for g in groups if isinstance(groups, list) else []:
            for hk in (g.get("hooks") if isinstance(g, dict) and isinstance(g.get("hooks"), list) else []):
                if isinstance(hk, dict):
                    hooks.append({"event": event_name, "matcher": ingest.text(g.get("matcher")),
                                  "command": ingest.text(hk.get("command"))})
    sandbox = doc.get("sandbox") if isinstance(doc.get("sandbox"), dict) else {}
    enabled = sandbox.get("enabled")
    return {"path": path, "state": "ok", "sha256": ingest.file_sha256(path),
            "rules": {k: [ingest.text(x) for x in perms.get(k, [])] for k in RULE_KINDS},
            "hooks": hooks,
            "sandbox": enabled if isinstance(enabled, bool) else None,
            # names only: a value here can be a proxy or a host
            "env": sorted(doc["env"]) if isinstance(doc.get("env"), dict) else [],
            "minimum_version": doc.get("requiredMinimumVersion") if isinstance(
                doc.get("requiredMinimumVersion"), str) else None,
            "keys": sorted(doc), "_doc": doc}


def policy(cfg):
    """The policy this host holds against the one the config says the fleet
    should hold. Read-only: changing a policy is a merge request and a deploy."""
    deployed, source = _policy_file(cfg["policy"]["deployed"]), _policy_file(cfg["policy"]["source"])
    same, differs = None, []
    if deployed["state"] == "ok" and source["state"] == "ok":
        a, b = deployed["_doc"], source["_doc"]
        differs = sorted(k for k in set(a) | set(b) if a.get(k) != b.get(k))
        same = deployed["sha256"] == source["sha256"]
    for f in (deployed, source):
        f.pop("_doc", None)
    return {"deployed": deployed, "source": source, "same": same, "differs": differs}
