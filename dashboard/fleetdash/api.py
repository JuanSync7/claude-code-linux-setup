"""Read-only queries behind the JSON API. Each returns plain dicts and lists.

Unknown stays distinct from zero: a model with no row in the price table makes
the total cost None ("unpriced"), never a smaller number that looks complete.
"""
import datetime
import re

from fleetdash import store
from fleetdash.vocab import CATEGORIES, SEVERITIES

MONTH_DAYS = 30.0


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


def overview(cfg, days=30, now=None):
    since = _since(now, days)
    bedrock = re.compile(cfg["bedrock_model_pattern"])
    con = store.connect(cfg)
    try:
        models = con.execute(
            "select model, sum(input) i, sum(output) o, sum(cache_read) cr, sum(cache_write) cw "
            "from usage where ts>=? group by model order by model", (since,)).fetchall()
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
    finally:
        con.close()

    providers, priced, unpriced = {}, 0.0, []
    model_rows = []
    for m in models:
        tokens = m["i"] + m["o"] + m["cr"] + m["cw"]
        prov = "bedrock" if bedrock.search(m["model"]) else "anthropic"
        providers[prov] = providers.get(prov, 0) + tokens
        p = _price(cfg, m["model"])
        usd = None
        if p is not None:
            usd = (m["i"] * p["input"] + m["o"] * p["output"] + m["cr"] * p["cache_read"]
                   + m["cw"] * p["cache_write"]) / 1e6
            priced += usd
        elif tokens:
            unpriced.append(m["model"])
        model_rows.append({"model": m["model"], "provider": prov, "tokens": tokens, "usd": usd})

    seat_users = sorted({u for s in cfg["seats"] for u in s["users"]})
    seat_usd = sum(s["monthly_usd"] * len(s["users"]) for s in cfg["seats"]) * days / MONTH_DAYS
    counts = {s["severity"]: s["n"] for s in sev}
    return {
        "host_label": cfg["host_label"],
        "days": days,
        "last_ingest": last["v"] if last else None,
        "by_user": [dict(r) for r in by_user],
        "by_provider": [{"provider": k, "tokens": v} for k, v in sorted(providers.items())],
        "by_model": model_rows,
        "daily": [dict(r) for r in daily],
        "cost": {"priced_usd": priced, "unpriced_models": unpriced,
                 "total_usd": None if unpriced else priced},
        "seats": {"window_usd": seat_usd, "count": len(seat_users),
                  "tiers": [{"tier": s["tier"], "monthly_usd": s["monthly_usd"], "users": len(s["users"])}
                            for s in cfg["seats"]]},
        "severity_counts": {s: counts.get(s, 0) for s in SEVERITIES},
        "blocks": [{"source": r["source"] or "(unnamed)", "count": r["n"]} for r in blocks],
        "storage": {"sessions": storage["n"], "bytes": storage["b"], "users": storage["u"]},
    }


def events(cfg, user=None, severity=None, category=None, limit=200, offset=0):
    if severity is not None and severity not in SEVERITIES:
        raise ValueError("unknown severity %r" % severity)
    if category is not None and category not in CATEGORIES:
        raise ValueError("unknown category %r" % category)
    where, args = [], []
    for col, val in (("user", user), ("severity", severity), ("category", category)):
        if val is not None:
            where.append(col + "=?")
            args.append(val)
    clause = (" where " + " and ".join(where)) if where else ""
    con = store.connect(cfg)
    try:
        total = con.execute("select count(*) from events" + clause, args).fetchone()[0]
        rows = con.execute("select ts, user, session, severity, category, source, tool, detail "
                           "from events" + clause + " order by ts desc, key limit ? offset ?",
                           args + [limit, offset]).fetchall()
        # the tab counts ignore the category filter, so every tab stays visible
        tab_where = [w for w in where if not w.startswith("category")]
        tab_args = [a for a, w in zip(args, where) if not w.startswith("category")]
        tab_clause = (" where " + " and ".join(tab_where)) if tab_where else ""
        by_cat = con.execute("select category, count(*) n from events" + tab_clause + " group by category",
                             tab_args).fetchall()
        users = [r[0] for r in con.execute("select distinct user from events order by user")]
    finally:
        con.close()
    present = {r["category"]: r["n"] for r in by_cat}
    return {"total": total, "rows": [dict(r) for r in rows],
            "by_category": [{"category": c, "count": present.get(c, 0)} for c in CATEGORIES],
            "facets": {"users": users, "severities": list(SEVERITIES), "categories": list(CATEGORIES)}}


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
    finally:
        con.close()
    tier = {}
    for seat in cfg["seats"]:
        for u in seat["users"]:
            tier.setdefault(u, seat["tier"])
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
