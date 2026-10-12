"use strict";
// Builds every element with textContent: log details are commands people
// typed, so nothing from the API is ever parsed as HTML.

function h(tag, attrs) {
  const el = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs || {})) {
    if (v === null || v === undefined || v === false) continue;
    if (k === "class") el.className = v;
    else if (k === "text") el.textContent = v;
    else if (k.startsWith("on")) el.addEventListener(k.slice(2), v);
    else el.setAttribute(k, v);
  }
  for (const c of Array.prototype.slice.call(arguments, 2).flat(Infinity)) {
    if (c === null || c === undefined || c === false) continue;
    el.append(c instanceof Node ? c : document.createTextNode(String(c)));
  }
  return el;
}
const SVG = "http://www.w3.org/2000/svg";
function s(tag, attrs) {
  const el = document.createElementNS(SVG, tag);
  for (const [k, v] of Object.entries(attrs || {})) {
    if (k === "text") el.textContent = v; else el.setAttribute(k, v);
  }
  return el;
}

const fmt = {
  n: v => v === null || v === undefined ? "–" : Number(v).toLocaleString("en-US"),
  tok(v) {
    if (v === null || v === undefined) return "–";
    for (const [d, u] of [[1e9, "B"], [1e6, "M"], [1e3, "k"]]) if (v >= d) return (v / d).toFixed(v >= 10 * d ? 0 : 1) + u;
    return String(v);
  },
  usd: v => v === null || v === undefined ? "unpriced" : "$" + Math.round(v).toLocaleString("en-US"),
  bytes(v) {
    for (const [d, u] of [[1 << 30, "GiB"], [1 << 20, "MiB"], [1 << 10, "KiB"]]) if (v >= d) return (v / d).toFixed(v >= 10 * d ? 0 : 1) + " " + u;
    return v + " B";
  },
  ts: t => t ? t.replace("T", " ").slice(0, 16) : "–",
  days: d => d === null || d === undefined ? "–" : d === 0 ? "today" : d === 1 ? "1 day" : d + " days",
  // a clock a little ahead of this one puts a moment in the future: that is still today
  ago: d => d === null || d === undefined ? "–" : d <= 0 ? "today" : d === 1 ? "yesterday" : d + " days ago",
};

// Login --------------------------------------------------------------------
// The token arrives after the # of the address the server printed
// (#token=..., then the page if one was asked for: #token=...#/people). A
// browser sends that part nowhere. It is kept for this tab, taken out of the
// address, and sent as a header on every call. It is never a cookie: a
// browser sends a host's cookies to every port on that host.
const TOKEN = "fleetdash-token";
const arrived = /^#token=([^#]*)(#.*)?$/.exec(location.hash);
if (arrived) {
  sessionStorage.setItem(TOKEN, arrived[1]);
  history.replaceState(null, "", location.pathname + (arrived[2] || "#/overview"));
}
const login = () => ({ "X-Fleetdash-Token": encodeURIComponent(sessionStorage.getItem(TOKEN) || "") });
class Locked extends Error {}

async function call(path, options) {
  const r = await fetch(path, Object.assign({ credentials: "omit" }, options,
    { headers: Object.assign(login(), (options || {}).headers) }));
  if (r.status === 403 && !options) throw new Locked();
  return r;
}
async function get(path) {
  const r = await call(path);
  const body = await r.json().catch(() => ({}));
  if (!r.ok) throw new Error(body.error || ("HTTP " + r.status));
  return body;
}
// A link cannot carry the header, so a file is fetched and then handed to the browser to save.
async function save(path, name) {
  const r = await call(path);
  if (!r.ok) throw new Error("HTTP " + r.status);
  const a = h("a", { href: URL.createObjectURL(await r.blob()), download: name });
  a.click();
  URL.revokeObjectURL(a.href);
}

const main = document.getElementById("main");
const state = { days: 30, logs: { user: "", severity: "", category: "", rows: [], total: 0 }, sessUser: "",
                update: { started: null, error: null } };

// A page's content: nested lists are flattened and an absent part is left out,
// as h() does for an element's children.
function show() {
  main.replaceChildren(...Array.prototype.slice.call(arguments).flat(Infinity)
    .filter(c => c !== null && c !== undefined && c !== false));
}
function head(title, sub, ctl) {
  return h("div", { class: "head" }, h("h1", { text: title }), sub ? h("p", { text: sub }) : null,
           ctl ? h("div", { class: "ctl" }, ctl) : null);
}
function seg(options, current, onpick) {
  return h("div", { class: "seg", role: "group" }, options.map(([v, label]) =>
    h("button", { type: "button", "aria-pressed": String(v === current), onclick: () => onpick(v) }, label)));
}
function bars(rows, key, val, label, cls) {
  if (!rows.length) return h("p", { class: "empty", text: "Nothing in this window." });
  const max = Math.max(...rows.map(r => r[val])) || 1;
  return h("div", { class: "bars" }, rows.map(r => {
    const i = h("i", { class: cls || "" });
    i.style.width = (100 * r[val] / max).toFixed(1) + "%";
    return [h("span", { class: "k", title: r[key], text: r[key] }), h("span", { class: "t" }, i),
            h("span", { class: "v", text: label(r) })];
  }));
}
function spark(daily) {
  if (daily.length < 2) return h("p", { class: "empty", text: "Need two days of data to draw a trend." });
  const W = 520, H = 140, P = 18, max = Math.max(...daily.map(d => d.tokens)) || 1;
  const x = i => P + i * (W - 2 * P) / (daily.length - 1), y = v => H - P - v * (H - 2 * P) / max;
  const pts = daily.map((d, i) => x(i).toFixed(1) + "," + y(d.tokens).toFixed(1));
  const svg = s("svg", { class: "spark", viewBox: `0 0 ${W} ${H}`, preserveAspectRatio: "none", role: "img",
                         "aria-label": "Tokens per day" });
  svg.append(s("line", { class: "base", x1: P, x2: W - P, y1: H - P, y2: H - P }),
             s("polygon", { class: "area", points: `${x(0)},${H - P} ${pts.join(" ")} ${x(daily.length - 1)},${H - P}` }),
             s("polyline", { class: "ln", points: pts.join(" ") }),
             s("text", { x: P, y: H - 3, text: daily[0].day.slice(5) }),
             s("text", { x: W - P, y: H - 3, "text-anchor": "end", text: daily[daily.length - 1].day.slice(5) }),
             s("text", { x: P, y: 11, text: fmt.tok(max) + " peak" }));
  return svg;
}

// Overview -------------------------------------------------------------------
async function overview() {
  const o = await get("/api/overview?days=" + state.days);
  const c = o.severity_counts;
  const tokens = o.by_user.reduce((a, u) => a + u.tokens, 0);
  const api = o.cost.priced_usd, seats = o.seats.window_usd;

  let hero;
  if (!api && o.cost.unpriced_models.length) {
    hero = h("div", { class: "hero" }, h("p", { class: "line" }, "Cost unknown", h("span", { text: ", " + fmt.tok(tokens) + " tokens" })),
             h("p", { class: "muted", text: "No price is configured for " + o.cost.unpriced_models.join(", ") +
               ". Add them to prices_per_mtok in the config to compare against seats." }));
  } else if (!o.seats.count) {
    hero = h("div", { class: "hero" }, h("p", { class: "line" }, fmt.usd(api), h("span", { text: " at API prices" })),
             h("p", { class: "muted", text: "No seats are configured, so there is nothing to compare against." }));
  } else {
    const top = Math.max(api, seats) || 1;
    const fill = h("i"); fill.style.width = (100 * api / top).toFixed(1) + "%";
    const mark = h("b", { title: "Seat cost" }); mark.style.left = (100 * seats / top).toFixed(1) + "%";
    const ratio = seats ? (api / seats) : 0;
    hero = h("div", { class: "hero" },
      h("p", { class: "line" }, fmt.usd(api), h("span", { text: " at API prices, against " }), fmt.usd(seats),
        h("span", { text: " of seats" })),
      h("p", { class: "muted", text: (o.cost.unpriced_models.length ? "At least " : "") +
        ratio.toFixed(1) + "× what the seats cost over " + o.days + " days" +
        (o.cost.unpriced_models.length ? ". Not priced: " + o.cost.unpriced_models.join(", ") : ".") }),
      h("div", { class: "ratio", role: "img", "aria-label": "API-equivalent cost against seat cost" }, fill, mark),
      h("div", { class: "legend" }, h("span", { text: "API-equivalent" }), h("span", { class: "r", text: "Line: seats, " +
        o.seats.count + " " + (o.seats.count === 1 ? "person" : "people") })));
  }

  const figs = h("div", { class: "figs" },
    [["", fmt.tok(tokens), "tokens"], ["", fmt.n(o.by_user.length), "active people"],
     ["deny", fmt.n(c.deny), "blocked"], ["redact", fmt.n(c.redact), "credentials hidden"],
     ["error", fmt.n(c.error), "API errors"], ["quota", fmt.n(c.quota), "limit hits"],
     ["", fmt.bytes(o.storage.bytes), "chat storage"],
     [o.hosts.stale ? "error" : "", fmt.n(o.hosts.count), o.hosts.stale ? "hosts, " + fmt.n(o.hosts.stale) + " quiet" : "hosts"]]
      .map(([cls, v, l]) => h("div", { class: "fig " + cls }, h("b", { text: v }), h("span", { text: l }))));

  const provTotal = o.by_provider.reduce((a, p) => a + p.tokens, 0) || 1;
  const split = h("div", { class: "split" }, o.by_provider.map(p => {
    const i = h("i", { class: p.provider }); i.style.width = (100 * p.tokens / provTotal) + "%"; return i; }));

  show(
    head("Overview", "Last " + o.days + " days", seg([[7, "7d"], [30, "30d"], [90, "90d"]], state.days,
      d => { state.days = d; render(); })),
    hero, figs,
    h("section", { class: "cols" },
      h("div", {}, h("h2", { text: "Tokens by person" }), bars(o.by_user.slice(0, 12), "user", "tokens", r => fmt.tok(r.tokens))),
      h("div", {}, h("h2", { text: "Tokens per day" }), spark(o.daily))),
    h("section", { class: "cols" },
      h("div", {}, h("h2", { text: "Where the tokens went" }), split,
        o.by_provider.map(p => h("span", { class: "key " + p.provider }, h("span", { text:
          (p.provider === "bedrock" ? "Bedrock " : "Anthropic API ") + fmt.tok(p.tokens) }))),
        h("table", {}, h("thead", {}, h("tr", {}, h("th", { text: "Model" }), h("th", { class: "n", text: "Tokens" }),
          h("th", { class: "n", text: "At API prices" }))),
          h("tbody", {}, o.by_model.map(m => h("tr", {}, h("td", { text: m.model }),
            h("td", { class: "n", text: fmt.tok(m.tokens) }), h("td", { class: "n", text: fmt.usd(m.usd) })))))),
      h("div", {}, h("h2", { text: "Blocked, by who decided" }),
        bars(o.blocks.map(b => ({ source: decidedBy(b.source), count: b.count })), "source", "count",
          r => fmt.n(r.count), "deny"))));
}

// Logs -----------------------------------------------------------------------
const CAT_LABEL = { "tool-call": "Tool calls", denial: "Blocked", redaction: "Hidden credentials",
  "api-error": "API errors", "rate-limit": "Limit hits", "slash-command": "Slash commands",
  skill: "Skills", plugin: "Plugins", "log-integrity": "Log integrity" };

// Who decided, in a transcript's own words for it. A name that is not here is
// what the site's denial hook was told, and is shown as it was written.
const DECIDED_BY = { "automode-blocked": "Claude Code safety check", "automode-unavailable": "Safety check unavailable",
  "permission-rule": "Permission rule", "user-rejected": "The person said no", interrupted: "The person interrupted" };
const decidedBy = s => DECIDED_BY[s] || s;

async function loadLogs(append) {
  const L = state.logs;
  const q = new URLSearchParams({ limit: 200, offset: append ? L.rows.length : 0 });
  for (const k of ["user", "severity", "category"]) if (L[k]) q.set(k, L[k]);
  const r = await get("/api/events?" + q);
  L.rows = append ? L.rows.concat(r.rows) : r.rows;
  L.total = r.total; L.facets = r.facets; L.byCat = r.by_category;
}

async function logs(append) {
  await loadLogs(append);
  const L = state.logs;
  const pick = (k, v) => { L[k] = v; render(); };
  const select = (k, label, opts) => h("label", {}, h("span", { class: "muted", text: label + " " }),
    h("select", { onchange: e => pick(k, e.target.value) },
      h("option", { value: "", text: "All" }), opts.map(o => h("option", { value: o, text: o, selected: o === L[k] }))));
  const allCount = L.byCat.reduce((a, c) => a + c.count, 0);
  const tabs = h("div", { class: "tabs", role: "tablist" },
    [["", "All", allCount]].concat(L.byCat.map(c => [c.category, CAT_LABEL[c.category], c.count]))
      .filter(([v, , n]) => n || v === "" || v === L.category)
      .map(([v, label, n]) => h("button", { type: "button", role: "tab", "aria-selected": String(v === L.category),
        onclick: () => pick("category", v) }, label, h("small", { text: fmt.n(n) }))));
  // only a hook log names its host; a transcript on a shared home does not
  const hosted = L.rows.some(e => e.host);
  const table = L.rows.length ? h("div", { class: "scroll" }, h("table", {},
    h("thead", {}, h("tr", {}, ["When (UTC)", "Person", hosted && "Host", "Result", "Kind", "Decided by", "Tool", "Detail"]
      .filter(Boolean).map(t => h("th", { text: t })))),
    h("tbody", {}, L.rows.map(e => h("tr", {},
      h("td", { class: "ts", text: fmt.ts(e.ts) }), h("td", { text: e.user }),
      hosted ? h("td", { class: e.host ? "" : "muted", text: e.host || "–" }) : null,
      h("td", {}, h("span", { class: "sev " + e.severity, text: e.severity })),
      h("td", { text: CAT_LABEL[e.category] || e.category }), h("td", { title: e.source, text: decidedBy(e.source) }),
      h("td", { text: e.tool }), h("td", { class: "detail", text: e.detail }))))))
    : h("p", { class: "empty", text: "No events match these filters." });
  show(
    head("Logs", fmt.n(L.total) + " events"),
    h("div", { class: "filters" }, select("user", "Person", L.facets.users), select("severity", "Result", L.facets.severities)),
    tabs, table,
    L.rows.length < L.total ? h("button", { class: "more", type: "button", onclick: () => logs(true).catch(fail) },
      "Show 200 more of " + fmt.n(L.total - L.rows.length)) : null);
}

// Chat storage ---------------------------------------------------------------
async function sessions() {
  const q = state.sessUser ? "?user=" + encodeURIComponent(state.sessUser) : "";
  const r = await get("/api/sessions" + q);
  const buckets = [[0, 7, "this week"], [8, 30, "8 to 30 days"], [31, 90, "31 to 90 days"], [91, 1e9, "over 90 days"]]
    .map(([lo, hi, label]) => {
      const rows = r.rows.filter(x => x.age_days !== null && x.age_days >= lo && x.age_days <= hi);
      return h("div", {}, h("b", { text: fmt.bytes(rows.reduce((a, x) => a + x.bytes, 0)) }),
        h("span", { text: fmt.n(rows.length) + " chats last used " + label }));
    });
  show(
    head("Chat storage", fmt.n(r.total.sessions) + " chats, " + fmt.bytes(r.total.bytes),
      h("label", {}, h("span", { class: "muted", text: "Person " }),
        h("select", { onchange: e => { state.sessUser = e.target.value; render(); } },
          h("option", { value: "", text: "All" }),
          r.facets.users.map(u => h("option", { value: u, text: u, selected: u === state.sessUser }))))),
    h("div", { class: "ages" }, buckets),
    h("section", {}, h("h2", { text: "By person" }),
      bars(r.by_user, "user", "bytes", x => fmt.bytes(x.bytes) + ", " + fmt.n(x.sessions) + " chats, oldest " + fmt.days(x.oldest_days))),
    h("section", {}, h("h2", { text: "Largest chats" }), r.rows.length ? h("div", { class: "scroll" }, h("table", {},
      h("thead", {}, h("tr", {}, h("th", { text: "Person" }), h("th", { text: "Project" }),
        h("th", { class: "n", text: "Size" }), h("th", { class: "n", text: "Records" }),
        h("th", { text: "Started" }), h("th", { class: "n", text: "Last used" }))),
      h("tbody", {}, r.rows.slice(0, 100).map(x => h("tr", {}, h("td", { text: x.user }),
        h("td", { class: "detail", text: x.project }), h("td", { class: "n", text: fmt.bytes(x.bytes) }),
        h("td", { class: "n", text: fmt.n(x.records) }), h("td", { class: "ts", text: fmt.ts(x.first_ts) }),
        h("td", { class: "n", text: fmt.ago(x.age_days) }))))))
      : h("p", { class: "empty", text: "No chats found." })));
}

// People ---------------------------------------------------------------------
async function people() {
  const p = await get("/api/people?days=" + state.days);
  const R = p.rules, rows = p.rows;
  const limited = rows.filter(r => r.five_hour || r.seven_day || r.other_limit);
  const under = rows.filter(r => r.under_use.length);
  const figs = h("div", { class: "figs" },
    [["", fmt.n(rows.length), "people"], ["quota", fmt.n(limited.length), "hit a limit"],
     ["quota", fmt.n(rows.reduce((a, r) => a + r.five_hour, 0)), "5-hour limits"],
     ["quota", fmt.n(rows.reduce((a, r) => a + r.seven_day, 0)), "weekly limits"],
     ["", fmt.n(under.length), "look under-used"]]
      .map(([cls, v, l]) => h("div", { class: "fig " + cls }, h("b", { text: v }), h("span", { text: l }))));
  const rule = "Flagged when unused for " + R.idle_days + " days, or under " + Math.round(100 * R.median_fraction) +
    "% of the median (" + (p.median_tokens === null ? "no use yet" : fmt.tok(p.median_tokens) + " tokens") +
    "). A prompt to look, not a verdict.";
  const table = rows.length ? h("div", { class: "scroll" }, h("table", {},
    h("thead", {}, h("tr", {}, h("th", { text: "Person" }), h("th", { text: "Seat" }),
      h("th", { class: "n", text: "Tokens" }), h("th", { class: "n", text: "At API prices" }),
      h("th", { class: "n", text: "Seat cost" }), h("th", { class: "n", text: "Active days" }),
      h("th", { class: "n", text: "Last used" }), h("th", { class: "n", text: "5-hour" }),
      h("th", { class: "n", text: "Weekly" }), h("th", { text: "Last limit (UTC)" }), h("th", { text: "Under-use" }))),
    h("tbody", {}, rows.map(r => h("tr", {}, h("td", { text: r.user }), h("td", { class: r.tier ? "" : "muted", text: r.tier || "none" }),
      h("td", { class: "n", text: fmt.tok(r.tokens) }),
      h("td", { class: "n" + (r.usd === null ? " muted" : ""), text: fmt.usd(r.usd) }),
      h("td", { class: "n" + (r.seat_usd === null ? " muted" : ""), text: r.seat_usd === null ? "–" : fmt.usd(r.seat_usd) }),
      h("td", { class: "n", text: fmt.n(r.active_days) }),
      h("td", { class: "n", text: r.last_active ? fmt.ago(daysSince(r.last_active)) : "never" }),
      h("td", { class: "n" + (r.five_hour ? " hit" : ""), text: fmt.n(r.five_hour) }),
      h("td", { class: "n" + (r.seven_day ? " hit" : ""), text: fmt.n(r.seven_day) }),
      h("td", { class: "ts", text: fmt.ts(r.last_limit) }),
      h("td", {}, r.under_use.map(w => h("span", { class: "flag", text: w }))))))))
    : h("p", { class: "empty", text: "Nobody has used Claude Code or holds a seat yet." });
  show(
    head("People", "Last " + p.days + " days", [
      h("button", { class: "btn", type: "button",
        onclick: () => save("/api/people.csv?days=" + p.days, "people-" + p.days + "d.csv").catch(fail) }, "Download CSV"),
      seg([[7, "7d"], [30, "30d"], [90, "90d"]], state.days, d => { state.days = d; render(); })]),
    figs,
    h("section", {}, h("h2", { text: "Limits hit, by person" }),
      bars(limited.map(r => ({ user: r.user, n: r.five_hour + r.seven_day + r.other_limit, r })), "user", "n",
        x => fmt.n(x.r.five_hour) + " five-hour, " + fmt.n(x.r.seven_day) + " weekly", "quota")),
    h("section", {}, h("h2", { text: "Everyone" }), h("p", { class: "muted", text: rule }), table));
}
function daysSince(ts) {
  return Math.floor((Date.now() - Date.parse(ts.slice(0, 19) + "Z")) / 864e5);
}

// Hosts ----------------------------------------------------------------------
const POLICY_SEV = { current: "pass", differs: "error", unknown: "info" };
async function hosts() {
  const r = await get("/api/hosts?days=" + state.days);
  const rows = r.rows;
  const figs = h("div", { class: "figs" },
    [["", rows.length, "hosts"], ["error", rows.filter(x => x.stale).length, "quiet"],
     ["deny", rows.filter(x => x.version_behind).length, "on an older Claude Code"],
     ["error", rows.filter(x => x.policy === "differs").length, "hold another policy"]]
      .map(([cls, v, l]) => h("div", { class: "fig " + (v ? cls : "") }, h("b", { text: fmt.n(v) }), h("span", { text: l }))));
  const rule = "A host is quiet after " + r.stale_hours + " hours without a check-in. Its row is what it last sent, not zero." +
    (r.expected_policy_sha256 ? "" : " No repository policy is configured (policy.source), so no host can be compared against one.");
  const table = rows.length ? h("div", { class: "scroll" }, h("table", {},
    h("thead", {}, h("tr", {}, h("th", { text: "Host" }), h("th", { text: "Last heard (UTC)" }),
      h("th", { text: "Claude Code" }), h("th", { text: "Policy" }), h("th", { class: "n", text: "Blocked" }),
      h("th", { class: "n", text: "Errors" }), h("th", { text: "Reported by" }))),
    h("tbody", {}, rows.map(x => h("tr", {}, h("td", { text: x.host }),
      h("td", { class: "ts" }, fmt.ts(x.last_seen), x.stale ? h("span", { class: "flag bad", text: "quiet" }) : null),
      h("td", { class: x.claude_version ? "" : "muted" }, x.claude_version || "unknown",
        x.version_behind ? h("span", { class: "flag", text: "newest is " + r.newest_version }) : null),
      h("td", {}, h("span", { class: "sev " + POLICY_SEV[x.policy], title: x.policy_sha256 || "", text: x.policy })),
      h("td", { class: "n", text: fmt.n(x.events.deny) }), h("td", { class: "n", text: fmt.n(x.events.error) }),
      h("td", { text: x.reported_by }))))))
    : h("p", { class: "empty", text: "No host has checked in yet. A host checks in when it runs ingest, or when a person's session there sends its usage." });
  show(
    head("Hosts", "Blocked and errors over the last " + r.days + " days", seg([[7, "7d"], [30, "30d"], [90, "90d"]], state.days,
      d => { state.days = d; render(); })),
    figs, h("section", {}, h("p", { class: "muted", text: rule }), table));
}

// Policy ---------------------------------------------------------------------
const FILE_STATE = { "not-configured": "Not configured", missing: "No file at this path", unreadable: "Cannot be read as JSON" };
function chips(items, none) {
  return items.length ? h("p", { class: "chips" }, items.map(t => h("code", { text: t }))) : h("p", { class: "muted", text: none });
}
async function policy() {
  const p = await get("/api/policy");
  const side = (title, f) => h("div", {}, h("h2", { text: title }),
    h("p", { class: "path", text: f.path || "–" }),
    h("p", { class: f.state === "ok" ? "" : "muted" }, f.state === "ok"
      ? ["SHA-256 ", h("code", { title: f.sha256, text: f.sha256.slice(0, 16) })] : FILE_STATE[f.state]));
  let verdict, why;
  if (p.same === true) [verdict, why] = ["This host holds the repository's policy", "The two files are identical."];
  else if (p.same === false) [verdict, why] = ["This host's policy differs from the repository",
    p.differs.length ? "They differ in: " + p.differs.join(", ") + "." : "The same settings, written differently."];
  else [verdict, why] = ["Nothing to compare", "A comparison needs both files readable: the one on this host and the one in the repository."];
  const shown = p.deployed.state === "ok" ? p.deployed : p.source.state === "ok" ? p.source : null;
  const rules = k => shown.rules[k].length ? h("ul", { class: "rules" }, shown.rules[k].map(r => h("li", { text: r })))
    : h("p", { class: "muted", text: "None." });
  show(
    head("Policy", "Read-only. A policy changes in the repository and reaches a host when it is installed there."),
    h("div", { class: "hero" }, h("p", { class: "line " + (p.same === false ? "bad" : ""), text: verdict }), h("p", { class: "muted", text: why })),
    h("section", { class: "cols" }, side("On this host", p.deployed), side("In the repository", p.source)),
    shown ? [
      h("section", {}, h("h2", { text: "What " + (shown === p.deployed ? "this host's" : "the repository's") + " policy says" }),
        h("div", { class: "figs" }, [[shown.sandbox === null ? "not set" : shown.sandbox ? "on" : "off", "sandbox"],
          [shown.minimum_version || "not set", "minimum Claude Code"], [fmt.n(shown.rules.deny.length), "always blocked"],
          [fmt.n(shown.rules.ask.length), "ask first"], [fmt.n(shown.rules.allow.length), "allowed without asking"],
          [fmt.n(shown.hooks.length), "hooks"]]
          .map(([v, l]) => h("div", { class: "fig" }, h("b", { text: v }), h("span", { text: l }))))),
      h("section", { class: "cols three" },
        h("div", {}, h("h2", { text: "Always blocked" }), rules("deny")),
        h("div", {}, h("h2", { text: "Ask first" }), rules("ask")),
        h("div", {}, h("h2", { text: "Allowed without asking" }), rules("allow"))),
      h("section", {}, h("h2", { text: "Hooks" }), shown.hooks.length ? h("div", { class: "scroll" }, h("table", {},
        h("thead", {}, h("tr", {}, h("th", { text: "When" }), h("th", { text: "For" }), h("th", { text: "Runs" }))),
        h("tbody", {}, shown.hooks.map(k => h("tr", {}, h("td", { text: k.event }), h("td", { text: k.matcher || "everything" }),
          h("td", { class: "detail", text: k.command }))))))
        : h("p", { class: "muted", text: "None." })),
      h("section", { class: "cols" },
        h("div", {}, h("h2", { text: "Environment variables it sets" }), chips(shown.env, "None."),
          h("p", { class: "muted", text: "Names only. The values stay on the host." })),
        h("div", {}, h("h2", { text: "Every setting it carries" }), chips(shown.keys, "None.")))]
      : h("section", {}, h("p", { class: "empty", text: "No policy file could be read, so there is nothing to show. Check policy.deployed and policy.source in the config." })));
}

// Update ---------------------------------------------------------------------
// The one page that changes anything: it starts a command the config lists.
// The request carries the action's id and nothing else.
function ran(code, timedOut) {
  if (timedOut) return ["error", "stopped at its time limit"];
  if (code === null) return ["error", "no exit code: it was stopped or did not start"];
  return [code === 0 ? "pass" : code === 1 ? "deny" : "error", "exit code " + code];
}
async function update() {
  const U = state.update;
  const r = await get("/api/actions");
  const busy = r.running || U.started;
  const start = async id => {
    U.started = id; U.error = null;
    render();
    try {
      const res = await call("/api/run", { method: "POST",
        headers: { "Content-Type": "application/json", "X-Fleetdash-Run": r.run_key }, body: JSON.stringify({ id }) });
      const body = await res.json().catch(() => ({}));
      if (!res.ok) U.error = { id, text: body.error || ("HTTP " + res.status) };
    } catch (e) {
      U.error = { id, text: e.message };
    }
    U.started = null;
    render();
  };
  const one = a => {
    const mine = busy === a.id, o = a.output;
    const [cls, word] = o ? ran(o.exit_code, o.timed_out) : a.last ? ran(a.last.exit_code, false) : ["info", "never run"];
    const when = o || a.last;
    return h("section", { class: "action" },
      h("div", { class: "what" }, h("h2", { text: a.label }), a.about ? h("p", { text: a.about }) : null,
        h("p", { class: "cmd", text: a.command.join(" ") })),
      h("div", { class: "go" },
        h("button", { class: "btn primary", type: "button", disabled: busy ? "" : null, onclick: () => start(a.id) },
          mine ? "Running…" : "Run"),
        h("p", { class: "muted", text: "Stops after " + a.timeout_s + " s" })),
      h("p", { class: "last", "aria-live": "polite" }, h("span", { class: "sev " + cls, text: mine ? "running" : word }),
        when && !mine ? h("span", { class: "muted", text: " " + fmt.ts(when.ts) + " UTC, took " + when.seconds + " s" }) : null,
        U.error && U.error.id === a.id ? h("span", { class: "err", text: " Not started: " + U.error.text + "." }) : null),
      o && !mine ? [h("pre", { class: "out", tabindex: "0", text: o.output || "(no output)" }),
        o.truncated ? h("p", { class: "muted", text: "The output was longer; this is its first part." }) : null] : null);
  };
  show(
    head("Update", "Commands this dashboard is configured to run. Nothing else can be started from here."),
    r.actions.length ? r.actions.map(one)
      : h("p", { class: "empty", text: "No commands are configured. List them under actions in the config, each with its fixed arguments." }));
}

// Docs -----------------------------------------------------------------------
// Markdown is turned into elements, never into HTML: markup inside a document is shown as the text it is.
const ITEM = /^(\s*)([-*+]|\d+[.)])\s+(.*)$/;
const BLOCK = /^(#{1,6}\s|```|~~~|>|\s*([-*+]|\d+[.)])\s|\s*\|)/;
const RULE = /^\s*(-{3,}|\*{3,}|_{3,})\s*$/;
const INLINE = /(`+)(.+?)\1|\*\*(.+?)\*\*|(?<![\w*])\*(?=\S)(.+?)(?<=\S)\*(?![\w*])|\[([^\]]+)\]\(([^)\s]+)\)/;
function inline(text, link) {
  const out = [];
  for (let m; (m = INLINE.exec(text)); text = text.slice(m.index + m[0].length)) {
    if (m.index) out.push(text.slice(0, m.index));
    if (m[1]) out.push(h("code", { text: m[2] }));
    else if (m[3] !== undefined) out.push(h("strong", {}, inline(m[3], link)));
    else if (m[4] !== undefined) out.push(h("em", {}, inline(m[4], link)));
    else out.push(link(inline(m[5], () => m[5]), m[6]));
  }
  if (text) out.push(text);
  return out;
}
function cells(line) {
  return line.trim().replace(/^\|/, "").replace(/\|$/, "").split(/(?<!\\)\|/).map(c => c.trim().replace(/\\\|/g, "|"));
}
function listAt(lines, i, inl) {
  const first = ITEM.exec(lines[i]), indent = first[1].length, ordered = /\d/.test(first[2]);
  const el = h(ordered ? "ol" : "ul", { start: ordered && parseInt(first[2], 10) !== 1 ? parseInt(first[2], 10) : null });
  let li = null;
  while (i < lines.length) {
    const m = ITEM.exec(lines[i]);
    if (m && li && m[1].length > indent) { const [sub, j] = listAt(lines, i, inl); li.append(sub); i = j; }
    else if (m && m[1].length === indent) { li = h("li", {}, inl(m[3])); el.append(li); i++; }
    else if (!m && li && lines[i].trim() && /^\s/.test(lines[i])) { li.append(" ", ...inl(lines[i].trim())); i++; }
    else if (!lines[i].trim() && i + 1 < lines.length && ITEM.test(lines[i + 1]) && ITEM.exec(lines[i + 1])[1].length >= indent) i++;
    else break;
  }
  return [el, i];
}
function markdown(src, link) {
  const lines = src.replace(/\r/g, "").split("\n"), out = [], inl = t => inline(t, link);
  for (let i = 0, m; i < lines.length;) {
    const line = lines[i];
    if (!line.trim()) i++;
    else if ((m = /^(```+|~~~+)/.exec(line))) {
      const body = [];
      for (i++; i < lines.length && !lines[i].startsWith(m[1]); i++) body.push(lines[i]);
      i++;
      out.push(h("pre", {}, h("code", { text: body.join("\n") })));
    } else if ((m = /^(#{1,6})\s+(.*?)\s*#*$/.exec(line))) {
      // the page's own headline is the h1, so a document's headings start one level down
      out.push(h("h" + Math.min(m[1].length + 1, 6), {}, inl(m[2]))); i++;
    } else if (RULE.test(line)) { out.push(h("hr")); i++; }
    else if (line.startsWith(">")) {
      const body = [];
      for (; i < lines.length && lines[i].startsWith(">"); i++) body.push(lines[i].replace(/^>\s?/, ""));
      out.push(h("blockquote", {}, markdown(body.join("\n"), link)));
    } else if (ITEM.test(line)) { const [el, j] = listAt(lines, i, inl); out.push(el); i = j; }
    else if (/^\s*\|/.test(line) && i + 1 < lines.length && /^\s*\|?\s*:?-+:?\s*(\|\s*:?-*:?\s*)*$/.test(lines[i + 1])) {
      const headRow = cells(line), body = [];
      for (i += 2; i < lines.length && /^\s*\|/.test(lines[i]); i++) body.push(cells(lines[i]));
      out.push(h("div", { class: "scroll" }, h("table", {},
        headRow.some(Boolean) ? h("thead", {}, h("tr", {}, headRow.map(c => h("th", {}, inl(c))))) : null,
        h("tbody", {}, body.map(r => h("tr", {}, r.map(c => h("td", {}, inl(c)))))))));
    } else {
      const body = [];
      for (; i < lines.length && lines[i].trim() && !(body.length && (BLOCK.test(lines[i]) || RULE.test(lines[i]))); i++) body.push(lines[i].trim());
      out.push(h("p", {}, inl(body.join(" "))));
    }
  }
  return out;
}
function docLink(doc, byPath) {
  // a link to another listed document opens it here; a web link opens a new tab;
  // anything else stays text, since the server would not serve it
  return (label, href) => {
    if (/^https?:\/\//.test(href)) return h("a", { href, target: "_blank", rel: "noopener noreferrer" }, label);
    const at = doc.path.split("/").slice(0, -1);
    for (const part of href.split("#")[0].split("/")) {
      if (part === "..") at.pop();
      else if (part && part !== ".") at.push(part);
    }
    const id = byPath.get(at.join("/"));
    return id ? h("a", { href: "#/docs/" + encodeURIComponent(id) }, label)
      : h("span", { class: "nolink", title: href + " is not in this list" }, label);
  };
}
async function docs(want) {
  const idx = await get("/api/docs");
  const all = idx.groups.flatMap(g => g.docs);
  const byPath = new Map(all.map(d => [d.path, d.id]));
  const id = all.some(d => d.id === want) ? want : all.length ? all[0].id : null;
  const doc = id ? await get("/api/doc?id=" + encodeURIComponent(id)) : null;
  const list = h("nav", { class: "doclist", "aria-label": "Documents" }, idx.groups.map(g => [
    h("p", { class: "group", text: g.label }),
    g.found ? null : h("p", { class: "muted", text: "Not found on this host." }),
    g.docs.map(d => h("a", { href: "#/docs/" + encodeURIComponent(d.id), title: d.name,
      "aria-current": d.id === id ? "page" : null }, inline(d.title, label => label)))]));
  show(
    head("Docs", doc ? doc.group + ", " + doc.name : "No documents"),
    all.length ? h("div", { class: "docs" }, list, h("article", { class: "doc" }, markdown(doc.markdown, docLink(doc, byPath))))
      : h("p", { class: "empty", text: "No documents are configured. List Markdown directories under docs in the config." }));
}

// Routing --------------------------------------------------------------------
// <main> carries data-page, data-state (loading, ready, error, locked) and
// data-at (the address it was drawn for) so a test, or a person with the
// inspector, can tell a page that finished from one that failed.
const PAGES = { overview, logs: () => logs(false), sessions, people, hosts, update, policy, docs };
function fail(e) {
  if (e instanceof Locked) {
    main.dataset.state = "locked";
    return main.replaceChildren(h("h1", { text: "Not logged in" }), h("p", { class: "err", text:
      "Open the address the server printed when it started. Whoever runs it can print it again with the url command." }));
  }
  main.dataset.state = "error";
  main.replaceChildren(h("p", { class: "err", text: "Could not load this page: " + e.message +
    ". If the server restarted, open the address it printed again." }));
}
async function frame() {
  const s = await get("/api/status");
  document.getElementById("host").textContent = s.host_label;
  document.getElementById("fresh").textContent = s.last_ingest ? "Data as of " + fmt.ts(s.last_ingest) + " UTC" : "Never ingested";
}
function render() {
  // #/docs/<id>: what follows the page name is that page's own argument
  const [name, ...rest] = location.hash.replace("#/", "").split("/");
  const page = PAGES[name] ? name : "overview";
  for (const a of document.querySelectorAll(".side a"))
    a.toggleAttribute("aria-current", a.dataset.page === page) && a.setAttribute("aria-current", "page");
  main.dataset.page = page;
  main.dataset.at = location.hash;
  main.dataset.state = "loading";
  Promise.all([PAGES[page](decodeURIComponent(rest.join("/"))), frame()]).then(() => { if (main.dataset.page === page) main.dataset.state = "ready"; }, fail);
}
window.addEventListener("hashchange", () => { render(); main.focus(); });
render();
