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
  dur(s) {
    if (s === null || s === undefined) return "–";
    if (s < 60) return s + " s";
    const m = Math.round(s / 60);
    return m < 60 ? m + " min" : Math.floor(m / 60) + " h " + (m % 60) + " min";
  },
  ago: d => d === null || d === undefined ? "–" : d <= 0 ? "today" : d === 1 ? "yesterday" : d + " days ago",
};

// Login --------------------------------------------------------------------
// The token arrives after the # of the address the server printed
// (#token=..., then the page if one was asked for: #token=...#/people). A
// browser sends that part nowhere. It is kept for this tab, taken out of the
// address, and sent as a header on every call. It is never a cookie: a
// browser sends a host's cookies to every port on that host.
// The address can arrive again in a tab that already has the page, so it is
// looked for on every change of address, not only on load.
const TOKEN = "fleetdash-token";
function arrive() {
  const arrived = /^#token=([^#]*)(#.*)?$/.exec(location.hash);
  if (!arrived) return;
  sessionStorage.setItem(TOKEN, arrived[1]);
  history.replaceState(null, "", location.pathname + (arrived[2] || "#/overview"));
}
arrive();
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
  hand(await r.blob(), name);
}
function hand(blob, name) {
  const a = h("a", { href: URL.createObjectURL(blob), download: name });
  a.click();
  URL.revokeObjectURL(a.href);
}

const main = document.getElementById("main");
const state = { days: 30, logs: { user: "", severity: "", category: "", source: "", tool: "", rows: [], total: 0 }, sessUser: "",
                update: { gen: 0, error: null } };

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
  const seats = o.seats.window_usd;

  // seats pay for the subscription's tokens only: Bedrock is billed by AWS for each one
  const [sub, bedrock] = ["anthropic", "bedrock"].map(k => o.providers.find(p => p.provider === k));
  const api = sub.priced_usd, unpriced = sub.unpriced_models;
  const aside = bedrock.tokens ? h("p", { class: "muted", text: "Bedrock is not in this comparison: AWS bills it per token, about " +
    fmt.usd(bedrock.priced_usd) + " at the configured prices" + (bedrock.unpriced_models.length ? ", and more for the unpriced models." : ".") }) : null;

  let hero;
  if (!api && unpriced.length) {
    hero = h("div", { class: "hero" }, h("p", { class: "line" }, "Cost unknown", h("span", { text: ", " + fmt.tok(sub.tokens) + " tokens on the subscription" })),
             h("p", { class: "muted", text: "No price is configured for " + unpriced.join(", ") +
               ". Add them to prices_per_mtok in the config to compare against seats." }), aside);
  } else if (!o.seats.count) {
    hero = h("div", { class: "hero" }, h("p", { class: "line" }, fmt.usd(api), h("span", { text: " of subscription use at API prices" })),
             h("p", { class: "muted", text: "No seats are configured, so there is nothing to compare against." }), aside);
  } else {
    const top = Math.max(api, seats) || 1;
    const fill = h("i"); fill.style.width = (100 * api / top).toFixed(1) + "%";
    const mark = h("b", { title: "Seat cost" }); mark.style.left = (100 * seats / top).toFixed(1) + "%";
    const ratio = seats ? (api / seats) : 0;
    hero = h("div", { class: "hero" },
      h("p", { class: "line" }, fmt.usd(api), h("span", { text: " of subscription use at API prices, against " }), fmt.usd(seats),
        h("span", { text: " of seats" })),
      h("p", { class: "muted", text: (unpriced.length ? "At least " : "") +
        ratio.toFixed(1) + "× what the seats cost over " + o.days + " days" +
        (unpriced.length ? ". Not priced: " + unpriced.join(", ") : ".") }),
      h("div", { class: "ratio", role: "img", "aria-label": "API-equivalent cost against seat cost" }, fill, mark),
      h("div", { class: "legend" }, h("span", { text: "API-equivalent" }), h("span", { class: "r", text: "Line: seats, " +
        o.seats.count + " " + (o.seats.count === 1 ? "person" : "people") })), aside);
  }

  const figs = h("div", { class: "figs" },
    [["", fmt.tok(tokens), "tokens"], ["", fmt.n(o.by_user.length), "active people"],
     ["deny", fmt.n(c.deny), "blocked"], ["redact", fmt.n(c.redact), "credentials hidden"],
     ["error", fmt.n(c.error), "API errors"], ["quota", fmt.n(c.quota), "limit hits"],
     ["", fmt.bytes(o.storage.bytes), "chat storage"],
     [o.hosts.stale ? "error" : "", fmt.n(o.hosts.count), o.hosts.stale ? "hosts, " + fmt.n(o.hosts.stale) + " quiet" : "hosts"]]
      .map(([cls, v, l]) => h("div", { class: "fig " + cls }, h("b", { text: v }), h("span", { text: l }))));

  const provTotal = (sub.tokens + bedrock.tokens) || 1;
  const split = h("div", { class: "split" }, o.providers.map(p => {
    const i = h("i", { class: p.provider }); i.style.width = (100 * p.tokens / provTotal) + "%"; return i; }));
  const KINDS = [["input", "Input"], ["output", "Output"], ["cache_read", "Cache read"], ["cache_write", "Cache write"]];
  const provider = (p, title, about, dollars) => h("section", { class: "provider " + p.provider },
    h("h2", {}, h("span", { class: "key " + p.provider }), title,
      h("small", { text: fmt.tok(p.tokens) + " tokens, " + (100 * p.tokens / provTotal).toFixed(p.tokens ? 1 : 0) + "% of all" })),
    h("p", { class: "muted", text: about }),
    p.models.length ? h("div", { class: "scroll" }, h("table", {},
      h("thead", {}, h("tr", {}, h("th", { text: "Model" }), KINDS.map(([, l]) => h("th", { class: "n", text: l })),
        h("th", { class: "n", text: "All tokens" }), h("th", { class: "n", text: dollars }))),
      h("tbody", {}, p.models.map(m => h("tr", {}, h("td", { text: m.model }),
        KINDS.map(([k]) => h("td", { class: "n", title: fmt.n(m[k]), text: fmt.tok(m[k]) })),
        h("td", { class: "n", title: fmt.n(m.tokens), text: fmt.tok(m.tokens) }),
        h("td", { class: "n" + (m.usd === null ? " muted" : ""), text: fmt.usd(m.usd) })))),
      h("tfoot", {}, h("tr", {}, h("td", { text: "Total" }),
        KINDS.map(([k]) => h("td", { class: "n", title: fmt.n(p[k]), text: fmt.tok(p[k]) })),
        h("td", { class: "n", title: fmt.n(p.tokens), text: fmt.tok(p.tokens) }),
        h("td", { class: "n", text: p.usd === null ? "at least " + fmt.usd(p.priced_usd) : fmt.usd(p.usd) })))))
      : h("p", { class: "empty", text: "No calls in this window." }));

  show(
    head("Overview", "Last " + o.days + " days", seg([[7, "7d"], [30, "30d"], [90, "90d"]], state.days,
      d => { state.days = d; render(); })),
    hero, figs,
    h("section", { class: "cols" },
      h("div", {}, h("h2", { text: "Tokens by person" }), bars(o.by_user.slice(0, 12), "user", "tokens", r => fmt.tok(r.tokens))),
      h("div", {}, h("h2", { text: "Tokens per day" }), spark(o.daily))),
    h("section", {}, h("h2", { text: "Where the tokens went" }), split,
      h("p", { class: "muted", text: "Two bills, so two tables. A call is counted under Bedrock when its message id is one of Bedrock's." })),
    provider(sub, "Claude subscription, through Anthropic",
      "Paid for by seats, whatever the use. The last column is what the same tokens would cost at the configured API prices.",
      "At API prices"),
    provider(bedrock, "Amazon Bedrock",
      "Billed by AWS for every token. The last column is an estimate from the configured prices; the AWS bill is the figure to trust.",
      "Estimated bill"),
    h("section", {}, h("h2", { text: "Blocked, by who decided" }),
      bars(o.blocks.map(b => ({ source: decidedBy(b.source), count: b.count })), "source", "count",
        r => fmt.n(r.count), "deny")));
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

// A stopped call's record: what was asked for in full, what Claude was told,
// and where it happened. It opens as a row of its own beneath the call's row,
// and says nothing that row already says.
const ASKED = { command: "Command", file_path: "File", url: "URL", path: "Path", "": "Asked for" };
function preview(e) {
  return e.incident.input !== null ? e.incident.input : e.detail || "What was asked for was not recorded";
}
function record(e) {
  const i = e.incident;
  const fact = (label, value) => value ? [h("dt", { text: label }), h("dd", { text: value })] : null;
  const part = (title, note, body) => h("div", { class: "part" },
    h("h3", {}, title, note ? h("span", { class: "muted", text: note }) : null), body);
  const asked = i.input !== null
    ? part(ASKED[i.input_kind], i.input_len > i.input.length
        ? fmt.n(i.input_len) + " characters in all. The middle was left out." : "", h("pre", { class: "asked", text: i.input }))
    : part("Asked for", "", h("p", { class: "muted", text: i.fields === null
      ? "Not recorded. The call was not in the part of the chat read with this block."
      : "Not recorded. Only a command, file, URL or path is kept"
        + (i.fields.length ? "; this call had " + i.fields.join(", ") + "." : "; this call had none.") }));
  return h("div", { class: "record-body" },
    h("div", { class: "said" }, asked, i.said ? part("Claude was told", "", h("pre", { class: "asked", text: i.said })) : null),
    h("dl", { class: "facts" },
      fact("Reason code", i.input !== null && e.detail !== i.input ? e.detail : ""),
      fact("Directory", i.cwd), fact("Git branch", i.branch), fact("Claude Code", i.client),
      fact("Chat", e.session), fact("Call", i.call_id),
      fact("Also in the call", i.input !== null && i.fields ? i.fields.filter(f => f !== i.input_kind).join(", ") : "")));
}
// One event as table rows: its own, and beneath it the record of a stopped
// call, closed until the row is clicked.
function logRows(e, n, hosted, columns, open) {
  const cells = [
    h("td", { class: "ts", text: fmt.ts(e.ts) }), h("td", { text: e.user }),
    hosted ? h("td", { class: e.host ? "" : "muted", text: e.host || "–" }) : null,
    h("td", {}, h("span", { class: "sev " + e.severity, text: e.severity })),
    h("td", { text: CAT_LABEL[e.category] || e.category }), h("td", { title: e.source, text: decidedBy(e.source) }),
    h("td", { text: e.tool })];
  if (!e.incident) return h("tr", {}, cells, h("td", { class: "detail", text: e.detail }));
  const name = "record-" + n;
  const button = h("button", { class: "opener", type: "button", "aria-label": "The record of this stopped call",
    "aria-expanded": String(open.has(n)), "aria-controls": name });
  const beneath = h("tr", { class: "record", id: name, hidden: open.has(n) ? null : "" },
    h("td", { colspan: columns }, record(e)));
  const row = h("tr", { class: "has-record" + (open.has(n) ? " opened" : ""), onclick: () => {
    if (String(getSelection())) return;  // the click that ends a selection is not a request to close
    const now = beneath.hidden;
    now ? open.add(n) : open.delete(n);
    beneath.hidden = !now;
    row.classList.toggle("opened", now);
    button.setAttribute("aria-expanded", String(now));
  } }, cells, h("td", { class: "detail" }, button, h("span", { class: "preview", text: preview(e) })));
  return [row, beneath];
}

async function loadLogs(append) {
  const L = state.logs;
  const q = new URLSearchParams({ limit: 200, offset: append ? L.rows.length : 0 });
  for (const k of ["user", "severity", "category", "source", "tool"]) if (L[k]) q.set(k, L[k]);
  const r = await get("/api/events?" + q);
  L.rows = append ? L.rows.concat(r.rows) : r.rows;
  if (!append) L.open = new Set();  // which records are open, by row; rows only ever get added to
  L.total = r.total; L.facets = r.facets; L.byCat = r.by_category;
}

async function logs(append) {
  await loadLogs(append);
  const L = state.logs;
  const pick = (k, v) => { L[k] = v; render(); };
  const select = (k, label, opts, name) => h("label", {}, h("span", { class: "muted", text: label + " " }),
    h("select", { onchange: e => pick(k, e.target.value) },
      h("option", { value: "", text: "All" }),
      opts.map(o => h("option", { value: o, text: name ? name(o) : o, selected: o === L[k] }))));
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
    h("tbody", {}, L.rows.map((e, n) => logRows(e, n, hosted, hosted ? 8 : 7, L.open)))))
    : h("p", { class: "empty", text: "No events match these filters." });
  show(
    head("Logs", fmt.n(L.total) + " events"),
    h("div", { class: "filters" }, select("user", "Person", L.facets.users), select("severity", "Result", L.facets.severities),
      select("source", "Decided by", L.facets.sources, decidedBy), select("tool", "Tool", L.facets.tools)),
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
  const rule = "A host is a machine Claude Code runs on. It is listed once it has checked in. A host is quiet after " + r.stale_hours + " hours without a check-in. Its row is what it last sent, not zero." +
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

// Admin ----------------------------------------------------------------------
const PERSON_STATE = { sending: ["pass", "sending"], quiet: ["error", "quiet"], never: ["info", "never sent"] };
// What each kind of log line is, for someone who has not read the Logs page.
const KEPT_AS = { pass: "Tool calls that were let through", info: "Slash commands, skills and plugins",
  deny: "Blocked tool calls", redact: "Hidden credentials", quota: "Limit hits", error: "Errors and refused files" };
const REFUSED_FOR = { unauthorised: "not in the admin group", uid0: "started as root", impersonation: "started for another account",
  die: "the launcher stopped before starting" };
function sessionLog(log) {
  const at = fmt.ts(log.at) + " UTC";
  if (log.state === "not-configured") return "No session log is set: admin_log in the config file is empty, so this section has nothing to read.";
  if (log.state === "not-read-yet") return "The log at " + log.path + " has not been read yet. It is read each time logs are collected.";
  if (log.state === "absent") return "There was no file at " + log.path + " at " + at + ": the privileged session has not been started on this host, or its log is elsewhere.";
  if (log.state === "unreadable") return log.path + " could not be read at " + at + ": " + log.error + ". What is below is what was read before.";
  return "Read from " + log.path + ", last at " + at + ".";
}
function privileged(a) {
  const who = s => s.invoker === s.target ? s.invoker : s.invoker + " as " + s.target;
  const more = (shown, total, what) => total > shown
    ? h("p", { class: "muted", text: "The newest " + fmt.n(shown) + " of " + fmt.n(total) + " " + what + "." }) : null;
  const ran = s => s.ran === null ? h("span", { class: "muted", text: !s.started || !s.ended ? "unknown without both ends" : "no longer kept" })
    : !s.ran.length ? h("span", { class: "muted", text: "nothing logged" })
    : h("details", {}, h("summary", { text: fmt.n(s.calls) + (s.calls === 1 ? " tool call, " : " tool calls, ") + fmt.n(s.blocked) + " blocked" }),
        h("ul", { class: "ran" }, s.ran.map(x => h("li", {}, h("span", { class: "ts", text: fmt.ts(x.ts).slice(11) }),
          h("span", { class: "sev " + x.severity, text: x.severity }), h("b", { text: x.tool || "–" }), h("span", { class: "cmd", text: x.detail || "" })))),
        s.calls + s.blocked > s.ran.length ? h("p", { class: "muted", text: "The first " + fmt.n(s.ran.length) + "; the Logs page has the rest." }) : null);
  const sessions = a.sessions.length ? [h("div", { class: "scroll" }, h("table", {},
    h("thead", {}, h("tr", {}, h("th", { text: "Started (UTC)" }), h("th", { text: "Who" }), h("th", { text: "Host" }), h("th", { text: "Terminal" }),
      h("th", { class: "n", text: "Lasted" }), h("th", { text: "Ended" }), h("th", { text: "What ran in that time" }))),
    h("tbody", {}, a.sessions.map(s => h("tr", {}, h("td", { class: "ts" + (s.started ? "" : " muted"), text: s.started ? fmt.ts(s.started) : "not recorded" }),
      h("td", { text: who(s) }), h("td", { text: s.host }), h("td", { text: s.tty }), h("td", { class: "n", text: fmt.dur(s.seconds) }),
      h("td", {}, s.ended ? [fmt.ts(s.ended) + " ", h("span", { class: "sev " + (s.rc === 0 ? "pass" : "error"), text: "exit code " + s.rc })]
        : h("span", { class: "flag", text: "no end recorded" })),
      h("td", {}, ran(s))))))), more(a.sessions.length, a.sessions_total, "sessions")]
    : h("p", { class: "empty", text: "No privileged session is on record." });
  const refusals = a.refusals.length ? [h("div", { class: "scroll" }, h("table", {},
    h("thead", {}, h("tr", {}, h("th", { text: "When (UTC)" }), h("th", { text: "Who" }), h("th", { text: "Host" }), h("th", { text: "Terminal" }),
      h("th", { text: "Refused because" }), h("th", { text: "As logged" }))),
    h("tbody", {}, a.refusals.map(s => h("tr", {}, h("td", { class: "ts", text: fmt.ts(s.ts) }), h("td", { text: who(s) }), h("td", { text: s.host }),
      h("td", { text: s.tty }), h("td", { text: REFUSED_FOR[s.reason] || s.reason }),
      h("td", { class: "detail" + (s.detail ? "" : " muted"), text: s.detail || "–" })))))), more(a.refusals.length, a.refusals_total, "refusals")]
    : h("p", { class: "empty", text: "Nobody has been refused the privileged session." });
  return h("section", {}, h("h2", { text: "Privileged sessions" }),
    h("p", { class: "muted", text: sessionLog(a.log) + " Only this host's log is read." }),
    sessions,
    h("p", { class: "muted", text: "The session's log says who started it and when, not what it did. What ran is every tool call and block logged for " +
      "that account on that host between the start and the end, so an ordinary session the same person had open then is counted too. " +
      "Tool calls are kept " + fmt.days(a.calls_kept_days) + "; an older session shows none." }),
    h("h3", { text: "Refused" }), refusals);
}
async function admin() {
  const [e, r, a] = await Promise.all([get("/api/enrolment"), get("/api/retention"), get("/api/admin-sessions")]);
  const count = st => e.people.filter(p => p.state === st).length;
  const refused = e.people.reduce((a, p) => a + p.refused, 0);
  const due = r.rows.reduce((a, x) => a + x.would_remove, 0);
  const figs = h("div", { class: "figs" },
    [["", a.sessions_total, "privileged sessions"], ["error", a.refusals_total, "refused"], ["", count("sending"), "people sending"], ["error", count("quiet"), "gone quiet"], ["", count("never"), "never sent"],
     ["error", e.hosts.filter(x => x.stale).length, "hosts quiet"], ["error", refused, "files refused"]]
      .map(([cls, v, l]) => h("div", { class: "fig " + (v ? cls : "") }, h("b", { text: fmt.n(v) }), h("span", { text: l }))));
  const people = e.people.length ? h("div", { class: "scroll" }, h("table", {},
    h("thead", {}, h("tr", {}, h("th", { text: "Person" }), h("th", { text: "Seat" }), h("th", { text: "Data" }),
      h("th", { text: "Newest (UTC)" }), h("th", { text: "From hosts" }), h("th", { class: "n", text: "Files refused" }),
      h("th", { text: "Last refusal" }))),
    h("tbody", {}, e.people.map(p => h("tr", {}, h("td", { text: p.user }),
      h("td", { class: p.seat ? "" : "muted", text: p.seat || "none" }),
      h("td", {}, h("span", { class: "sev " + PERSON_STATE[p.state][0], text: PERSON_STATE[p.state][1] })),
      h("td", { class: "ts", text: fmt.ts(p.last_data) }),
      h("td", { class: p.hosts.length ? "" : "muted", text: p.hosts.join(", ") || "not said" }),
      h("td", { class: "n" + (p.refused ? " hit" : ""), text: fmt.n(p.refused) }),
      h("td", { class: p.last_refused ? "" : "muted", text: p.last_refused
        ? fmt.ts(p.last_refused.ts) + ", " + p.last_refused.why : "–" }))))))
    : h("p", { class: "empty", text: "Nobody has sent anything and no seat is listed in the config." });
  const hosts = e.hosts.length ? h("div", { class: "scroll" }, h("table", {},
    h("thead", {}, h("tr", {}, h("th", { text: "Host" }), h("th", { text: "Last heard (UTC)" }),
      h("th", { class: "n", text: "People with events from it" }), h("th", { text: "Reported by" }))),
    h("tbody", {}, e.hosts.map(x => h("tr", {}, h("td", { text: x.host }),
      h("td", { class: "ts" }, fmt.ts(x.last_seen), x.stale ? h("span", { class: "flag bad", text: "quiet" }) : null),
      h("td", { class: "n", text: fmt.n(x.people) }), h("td", { text: x.reported_by }))))))
    : h("p", { class: "empty", text: "No host has checked in yet." });
  const kept = h("div", { class: "scroll" }, h("table", {},
    h("thead", {}, h("tr", {}, h("th", { text: "Kind" }), h("th", { text: "What it is" }), h("th", { class: "n", text: "Kept for" }),
      h("th", { class: "n", text: "At most" }), h("th", { class: "n", text: "Stored" }), h("th", { text: "Oldest (UTC)" }),
      h("th", { class: "n", text: "Next clean-up removes" }))),
    h("tbody", {}, r.rows.map(x => h("tr", {}, h("td", {}, h("span", { class: "sev " + x.severity, text: x.severity })),
      h("td", { text: KEPT_AS[x.severity] }), h("td", { class: "n", text: fmt.days(x.days) }),
      h("td", { class: "n", text: fmt.n(x.max_rows) + " rows" }), h("td", { class: "n", text: fmt.n(x.stored) }),
      h("td", { class: "ts", text: fmt.ts(x.oldest) }),
      h("td", { class: "n" + (x.would_remove ? " hit" : ""), text: fmt.n(x.would_remove) }))))));
  show(
    head("Admin", "Who used the privileged session, who is sending data, and how long it is kept. Read-only."),
    figs,
    privileged(a),
    h("section", {}, h("h2", { text: "People" }),
      h("p", { class: "muted", text: "Quiet means nothing newer than " + e.idle_days + " days is stored. Never sent means nothing is stored at all: " +
        "the seat is unused, or that person's data does not reach this dashboard. The page cannot tell which. " +
        "A refused file was not read because it is not what its name says; the Logs page lists each one under Log integrity." }),
      people),
    h("section", {}, h("h2", { text: "Hosts" }),
      h("p", { class: "muted", text: "A host is quiet after " + e.stale_hours + " hours without a check-in." }), hosts),
    h("section", {}, h("h2", { text: "How long logs are kept" }),
      h("p", { class: "muted", text: (due ? "The next clean-up removes " + fmt.n(due) + (due === 1 ? " row" : " rows") + "."
        : "The next clean-up removes nothing.") + " A row goes when it is older than its kind is kept for, or when its kind holds more rows than it may. " +
        "These rules are set in the config file under retention; this page does not change them." }),
      kept,
      h("p", { class: "muted", text: "Token counts are never removed: " + fmt.n(r.usage.stored) + " calls are stored" +
        (r.usage.oldest ? ", the oldest from " + fmt.ts(r.usage.oldest).slice(0, 10) : "") + ". The Update page keeps its newest " +
        fmt.n(r.runs.keep) + " runs and holds " + fmt.n(r.runs.stored) + ". The privileged session's log is kept whole: " +
        fmt.n(r.admin_log.stored) + (r.admin_log.stored === 1 ? " line." : " lines.") })));
}

// Policy ---------------------------------------------------------------------
const FILE_STATE = { "not-configured": "Not configured", missing: "No file at this path", unreadable: "Cannot be read as JSON" };
function chips(items, none) {
  return items.length ? h("p", { class: "chips" }, items.map(t => h("code", { text: t }))) : h("p", { class: "muted", text: none });
}
const RULE_LIST = { deny: "Always blocked", ask: "Ask first", allow: "Allowed without asking" };
const PATCH_NAME = "policy-change.patch";
// A draft lives in the address, so it survives a reload and can be sent to someone:
// #/policy/<the changes as JSON>. The server checks every one of them.
function draftRoute(edits) {
  return "#/policy" + (edits.length ? "/" + encodeURIComponent(JSON.stringify(edits)) : "");
}
async function drafting(p, arg) {
  let edits = [];
  try {
    const given = JSON.parse(arg || "[]");
    if (Array.isArray(given)) edits = given.filter(e => e && typeof e === "object")
      .map(e => ({ op: String(e.op), list: String(e.list), rule: String(e.rule) }));
  } catch (e) { /* not a draft: the server says so below */ }
  let made = null, refused = "";
  if (arg) {
    try { made = await get("/api/policy-draft?edits=" + encodeURIComponent(arg)); } catch (e) {
      if (e instanceof Locked) throw e;
      refused = e.message;
    }
  }
  const go = more => { location.hash = draftRoute(edits.concat(more)); };
  const lists = Object.keys(RULE_LIST);
  const addTo = h("select", { "aria-label": "List" }, lists.map(k => h("option", { value: k, text: RULE_LIST[k] })));
  const rule = h("input", { type: "text", required: "", maxlength: "500", size: "32", placeholder: "Bash(dd:*)", "aria-label": "Rule" });
  const has = lists.filter(k => p.source.rules[k].length);
  const taken = h("select", { "aria-label": "Rule to remove" }, has.map(k => h("optgroup", { label: RULE_LIST[k] },
    p.source.rules[k].map(r => h("option", { value: JSON.stringify([k, r]), text: r })))));
  return h("section", { class: "draft" }, h("h2", { text: "Draft a change" }),
    h("p", { class: "muted", text: "Say which rules to add or remove and the page writes a patch for a merge request. "
      + "Nothing is applied from this page: the policy changes when the patch is reviewed, merged and installed." }),
    h("form", { onsubmit: e => { e.preventDefault(); go({ op: "add", list: addTo.value, rule: rule.value.trim() }); } },
      h("span", { class: "muted", text: "Add to" }), addTo, rule, h("button", { class: "btn", type: "submit", text: "Add to draft" })),
    has.length ? h("form", { onsubmit: e => { e.preventDefault(); const [k, r] = JSON.parse(taken.value); go({ op: "remove", list: k, rule: r }); } },
      h("span", { class: "muted", text: "Remove" }), taken, h("button", { class: "btn", type: "submit", text: "Remove in draft" })) : null,
    edits.length ? h("ul", { class: "rules" }, edits.map((e, n) => h("li", {},
      (e.op === "remove" ? "Remove from " : "Add to ") + (RULE_LIST[e.list] || e.list) + ": ", h("code", { text: e.rule }), " ",
      h("a", { href: draftRoute(edits.filter((_, m) => m !== n)), text: "Take out" })))) : null,
    refused ? h("p", { class: "err", text: "No patch: " + refused + "." }) : null,
    made ? [
      h("p", {}, "The patch for ", h("code", { text: made.file }), ", against the file with SHA-256 ",
        h("code", { title: made.base_sha256, text: made.base_sha256.slice(0, 16) }), "."),
      h("pre", { class: "patch", text: made.patch }),
      h("p", {}, h("button", { class: "btn primary", type: "button", text: "Download the patch",
        onclick: () => hand(new Blob([made.patch], { type: "text/x-diff" }), PATCH_NAME) })),
      h("p", { class: "muted" }, "In a checkout of the repository, on a new branch: ",
        h("code", { text: made.apply.concat(PATCH_NAME).join(" ") }), ". Then commit it and open the merge request.",
        made.in_repository ? "" : " The policy file here is not inside a git checkout, so the patch names it by its file name alone.")] : null);
}
async function policy(arg) {
  const p = await get("/api/policy");
  const draft = p.source.state === "ok" ? await drafting(p, arg) : null;
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
      : h("section", {}, h("p", { class: "empty", text: "No policy file could be read, so there is nothing to show. Check policy.deployed and policy.source in the config." })),
    draft);
}

// Update ---------------------------------------------------------------------
// The one page that changes anything: it starts a command the config lists.
// The request carries the action's id and nothing else. A run answers with its
// number at once; what it prints is read a piece at a time while it runs, and
// is kept, so #/update/<run> shows any run that is still kept.
const POLL_MS = 700;
const RUN_WORD = { running: ["info", "running"], "timed-out": ["error", "stopped at its time limit"],
  "not-started": ["error", "could not start"], interrupted: ["error", "no result: the server stopped while it ran"] };
function ran(r) {
  if (r.state !== "done") return RUN_WORD[r.state];
  return [r.exit_code === 0 ? "pass" : r.exit_code === 1 ? "deny" : "error", "exit code " + r.exit_code];
}
const result = r => { const [cls, word] = ran(r); return h("span", { class: "sev " + cls, text: word }); };
// the command as it could be typed: an argument with a space in it stays one argument
const PLAIN_ARG = /^[A-Za-z0-9_\/.:=,@%+-]+$/;
const typed = argv => argv.map(a => PLAIN_ARG.test(a) ? a : "'" + a.replace(/'/g, "'\\''") + "'").join(" ");
const took = r => r.seconds === null ? "–" : r.seconds + " s";
const printed = r => r.bytes === null ? "–" : fmt.bytes(r.bytes);

async function update(want) {
  const U = state.update, gen = ++U.gen;
  const r = await get("/api/actions");
  const label = new Map(r.actions.map(a => [a.id, a.label]));
  const name = x => label.get(x.action) || x.action;
  const wanted = /^[0-9]+$/.test(want) ? Number(want) : null;
  const sel = r.runs.find(x => x.run === wanted) || r.runs.find(x => x.run === r.run) || r.runs[0] || null;
  const first = sel ? await get("/api/run?id=" + sel.run + "&offset=0") : null;

  const start = async id => {
    U.error = null;
    try {
      const res = await call("/api/run", { method: "POST",
        headers: { "Content-Type": "application/json", "X-Fleetdash-Run": r.run_key }, body: JSON.stringify({ id }) });
      const body = await res.json().catch(() => ({}));
      if (res.ok) { location.hash = "#/update/" + body.run; return; }
      U.error = { id, text: body.error || ("HTTP " + res.status) };
    } catch (e) {
      U.error = { id, text: e.message };
    }
    render();
  };
  const command = a => h("article", { class: "command" },
    h("h3", { text: a.label }), a.about ? h("p", { text: a.about }) : null,
    h("p", { class: "cmd", text: typed(a.command) }),
    h("p", { class: "muted", text: (a.cwd ? "In " + a.cwd + ". " : "") + "Stops after " + a.timeout_s + " s." }),
    h("div", { class: "go" },
      h("button", { class: "btn primary", type: "button", disabled: r.busy ? "" : null, onclick: () => start(a.id) },
        r.running === a.id ? "Running…" : "Run"),
      a.last ? h("a", { href: "#/update/" + a.last.run }, result(a.last), h("span", { class: "muted", text: " " + fmt.ts(a.last.ts) })) :
        h("span", { class: "muted", text: "Never run" })),
    U.error && U.error.id === a.id ? h("p", { class: "err", text: "Not started: " + U.error.text + "." }) : null);

  let consolePane;
  if (!first) {
    consolePane = h("div", { class: "console" }, h("h2", { text: "Output" }),
      h("p", { class: "empty", text: "Nothing has been run yet. Run a command and everything it prints appears here as it prints it." }));
  } else {
    const out = h("pre", { class: "out", tabindex: "0", "aria-label": "Output of run " + sel.run });
    const note = h("p", { class: "muted" });
    const facts = h("dl", { class: "facts" });
    const draw = c => {
      const x = c.run;
      facts.replaceChildren(
        h("dt", { text: "Command" }), h("dd", { class: "cmd", text: typed(x.command) }),
        h("dt", { text: "Directory" }), h("dd", { class: x.cwd ? "cmd" : "muted", text: x.cwd || "the server's own" }),
        h("dt", { text: "Started" }), h("dd", { text: fmt.ts(x.ts) + " UTC" }),
        h("dt", { text: "Took" }), h("dd", { text: took(x) }),
        h("dt", { text: "Printed" }), h("dd", { text: fmt.bytes(c.size) }),
        h("dt", { text: "Result" }), h("dd", { "aria-live": "polite" }, result(x)));
      note.textContent = c.cut ? "This is the first " + fmt.bytes(c.next) + ". All of it is in " + c.file + "."
        : c.more ? "" : c.size ? "All of it, also kept in " + c.file + "." : "It printed nothing.";
    };
    out.textContent = first.output;
    draw(first);
    consolePane = h("div", { class: "console" },
      h("h2", { text: "Run " + sel.run + ", " + name(sel) }), facts, out, note);
    const follow = async c => {
      while (c.more) {
        if (c.run.state === "running") await new Promise(done => setTimeout(done, POLL_MS));
        if (U.gen !== gen || main.dataset.page !== "update") return;
        const was = c.run.state;
        c = await get("/api/run?id=" + sel.run + "&offset=" + c.next);
        if (U.gen !== gen) return;
        // keep the newest line in view, unless the reader has scrolled back
        const atEnd = out.scrollHeight - out.scrollTop - out.clientHeight < 24;
        out.append(c.output);
        if (atEnd) out.scrollTop = out.scrollHeight;
        draw(c);
        // it ended: the commands and the list of runs have a new result to show
        if (c.run.state !== was) return render();
      }
    };
    follow(first).catch(e => { if (U.gen === gen) fail(e); });
  }

  show(
    head("Update", "Commands this dashboard is configured to run. Nothing else can be started from here."),
    r.actions.length ? h("div", { class: "bench" },
      h("div", { class: "commands" }, h("h2", { text: "Commands" }), r.actions.map(command)), consolePane)
      : h("p", { class: "empty", text: "No commands are configured. List them under actions in the config, each with its fixed arguments." }),
    r.runs.length ? h("section", {}, h("h2", { text: "Runs kept" }),
      h("p", { class: "muted", text: "The newest runs, each with the command line it was started with and everything it printed." }),
      h("div", { class: "scroll" }, h("table", {},
        h("thead", {}, h("tr", {}, h("th", { text: "Run" }), h("th", { text: "Started (UTC)" }), h("th", { text: "Command" }),
          h("th", { text: "Result" }), h("th", { class: "n", text: "Took" }), h("th", { class: "n", text: "Printed" }))),
        h("tbody", {}, r.runs.map(x => h("tr", { class: sel && x.run === sel.run ? "on" : null },
          h("td", {}, h("a", { href: "#/update/" + x.run, "aria-current": sel && x.run === sel.run ? "true" : null }, "Run " + x.run)),
          h("td", { class: "ts", text: fmt.ts(x.ts) }),
          h("td", {}, name(x), h("div", { class: "cmd", text: typed(x.command) })),
          h("td", {}, result(x)), h("td", { class: "n", text: took(x) }), h("td", { class: "n", text: printed(x) }))))))) : null);
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
function markdown(src, link, section) {
  const lines = src.replace(/\r/g, "").split("\n"), out = [], inl = t => inline(t, link);
  for (let i = 0, m; i < lines.length;) {
    const line = lines[i];
    if (!line.trim()) i++;
    else if ((m = /^(```+|~~~+)/.exec(line))) {
      const body = [];
      for (i++; i < lines.length && !lines[i].startsWith(m[1]); i++) body.push(lines[i]);
      i++;
      out.push(codeBlock(body.join("\n")));
    } else if ((m = /^(#{1,6})\s+(.*?)\s*#*$/.exec(line))) {
      // the page's own headline is the h1, so a document's headings start one level down
      const el = h("h" + Math.min(m[1].length + 1, 6), {}, inl(m[2]));
      if (section) el.id = SECTION + section(el.textContent, m[1].length);
      out.push(el); i++;
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
// A block of code, with a button that puts its text on the clipboard and says
// whether that worked: a browser can refuse, and then the reader selects it by hand.
function codeBlock(text) {
  const button = h("button", { type: "button", class: "copy", "aria-live": "polite", text: "Copy" });
  button.addEventListener("click", () => navigator.clipboard.writeText(text).then(
    () => { button.textContent = "Copied"; }, () => { button.textContent = "Could not copy"; }));
  return h("div", { class: "code" }, h("pre", {}, h("code", { text })), button);
}
// The list of documents keeps the entries whose name, file or description
// holds every word typed, and a group with none left goes with them.
function filterDocs(sets, none, words) {
  const want = words.toLowerCase().split(/\s+/).filter(Boolean);
  let any = false;
  for (const { heads, links } of sets) {
    for (const [a, find] of links) a.hidden = !want.every(w => find.includes(w));
    const shown = links.some(([a]) => !a.hidden);
    for (const p of heads) p.hidden = !shown;
    any = any || shown;
  }
  none.hidden = any;
}
// A heading's address is its words the way GitHub writes them, so a link
// written for the repository's own view lands on the same heading here.
const SECTION = "section-";
const READING_LINE = 120;  // px from the top of the window: a heading above it has been reached
function slug(text) {
  return text.toLowerCase().replace(/[^\p{L}\p{N}\s_-]/gu, "").trim().replace(/\s/g, "-");
}
function docLink(doc, byPath) {
  // a link to another listed document opens it here; a web link opens a new tab;
  // anything else stays text, since the server would not serve it
  return (label, href) => {
    if (/^https?:\/\//.test(href)) return h("a", { href, target: "_blank", rel: "noopener noreferrer" }, label);
    const [file, heading] = href.split("#");
    const at = doc.path.split("/").slice(0, -1);
    for (const part of file.split("/")) {
      if (part === "..") at.pop();
      else if (part && part !== ".") at.push(part);
    }
    const id = file ? byPath.get(at.join("/")) : doc.id;
    return id ? h("a", { href: docRoute(id, heading ? slug(heading) : "") }, label)
      : h("span", { class: "nolink", title: href + " is not in this list" }, label);
  };
}
function docRoute(id, section) {
  return "#/docs/" + encodeURIComponent(id) + (section ? "/" + encodeURIComponent(section) : "");
}
// Which entry of "On this page" is marked: the section the address names, and
// after that whichever heading the reader has scrolled to.
let onPage = [];  // [section, its entry in the list] for the document shown
function mark(section) {
  for (const [name, a] of onPage) {
    if (name !== section) { a.removeAttribute("aria-current"); continue; }
    a.setAttribute("aria-current", "location");
    // a long list scrolls by itself, so it keeps the marked entry in sight
    const list = a.parentElement, at = a.getBoundingClientRect(), box = list.getBoundingClientRect();
    if (at.top < box.top || at.bottom > box.bottom)
      list.scrollTop += at.top - box.top - list.clientHeight / 3;
  }
}
// Where the window was put for the section an address names. Near the end of
// a document that section cannot reach the top, so until the reader moves
// from there it stays the marked one.
let scrolled = 0, put = null;
document.addEventListener("scroll", () => {
  cancelAnimationFrame(scrolled);
  scrolled = requestAnimationFrame(() => {
    if (scrollY === put) return;
    put = null;
    const passed = onPage.map(([name]) => [name, document.getElementById(SECTION + name)])
      .filter(([, el]) => el && el.getBoundingClientRect().top <= READING_LINE);
    if (passed.length) mark(passed[passed.length - 1][0]);
  });
}, { passive: true, capture: true });
async function docs(want) {
  const idx = await get("/api/docs");
  const all = idx.groups.flatMap(g => g.docs);
  const byPath = new Map(all.map(d => [d.path, d.id]));
  const listed = v => all.some(d => d.id === v);
  // #/docs/<id>/<section>: an id can hold a slash and a section cannot
  const cut = want.lastIndexOf("/");
  const [id, section] = listed(want) ? [want, ""] : cut > 0 && listed(want.slice(0, cut)) ? [want.slice(0, cut), want.slice(cut + 1)]
    : [all.length ? all[0].id : null, ""];
  const go = () => {
    mark(section);
    const el = section && document.getElementById(SECTION + section);
    el ? el.scrollIntoView() : scrollTo(0, 0);
    put = scrollY;
  };
  // another section of the document already on the page: it is not fetched and drawn again
  const shown = main.querySelector("article.doc");
  if (shown && shown.dataset.doc === id) return go();
  const doc = id ? await get("/api/doc?id=" + encodeURIComponent(id)) : null;
  const filter = h("input", { type: "search", class: "filter", placeholder: "Filter documents", "aria-label": "Filter documents" });
  const none = h("p", { class: "muted nomatch", text: "No document matches." });
  none.hidden = true;
  const sets = idx.groups.map(g => ({
    heads: [h("p", { class: "group", text: g.label }), g.found ? null : h("p", { class: "muted", text: "Not found on this host." })].filter(Boolean),
    links: g.docs.map(d => [h("a", { href: docRoute(d.id, ""), title: d.name, "aria-current": d.id === id ? "page" : null },
      inline(d.title, label => label)), [d.title, d.about, d.name].join(" ").toLowerCase()])}));
  const list = h("nav", { class: "doclist", "aria-label": "Documents" }, filter, sets.map(g => [g.heads, g.links.map(([a]) => a)]), none);
  filter.addEventListener("input", () => filterDocs(sets, none, filter.value));
  if (!doc) return show(head("Docs", "No documents"),
    h("p", { class: "empty", text: "No documents are configured. List Markdown directories under docs in the config." }));
  // the sections under the document's title, two levels deep, and each part of a
  // document written in parts (a top heading after its title); a heading said
  // twice gets a number, as GitHub gives it
  const sections = [], taken = new Map();
  let tops = 0;
  const body = markdown(doc.markdown, docLink(doc, byPath), (text, level) => {
    const base = slug(text), n = taken.get(base) || 0;
    taken.set(base, n + 1);
    const name = n ? base + "-" + n : base;
    if (level === 1 && tops++ === 0) return name;
    if (level <= 3)
      sections.push({ name, entry: h("a", { href: docRoute(id, name), class: { 1: "part", 3: "sub" }[level] || null, text }) });
    return name;
  });
  // the document's own title is its name, with what follows the dash said under it
  const top = body.findIndex(el => el.tagName === "H2");
  if (top >= 0 && doc.about) {
    body[top].replaceChildren(...inline(doc.title, t => t));
    body.splice(top + 1, 0, h("p", { class: "lead" }, inline(doc.about, t => t)));
  }
  const toc = sections.length ? h("nav", { class: "toc", "aria-label": "On this page" },
    h("p", { class: "group", text: "On this page" }),
    sections.map(s => s.entry)) : null;
  onPage = sections.map(s => [s.name, s.entry]);
  const at = all.findIndex(d => d.id === id);
  const beside = (d, cls, label) => d ? h("a", { class: cls, href: docRoute(d.id, "") },
    h("span", { class: "muted", text: label }), inline(d.title, t => t)) : null;
  show(
    head("Docs", doc.group + ", " + doc.name),
    h("div", { class: "docs" }, list,
      h("article", { class: "doc", "data-doc": id }, body,
        h("nav", { class: "pager", "aria-label": "More documents" },
          beside(all[at - 1], "prev", "Previous"), beside(all[at + 1], "next", "Next"))),
      toc));
  go();
}

// Routing --------------------------------------------------------------------
// <main> carries data-page, data-state (loading, ready, error, locked) and
// data-at (the address it was drawn for) so a test, or a person with the
// inspector, can tell a page that finished from one that failed.
const PAGES = { overview, logs: () => logs(false), sessions, people, hosts, update, admin, policy, docs };
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
window.addEventListener("hashchange", () => { arrive(); render(); main.focus(); });
render();
