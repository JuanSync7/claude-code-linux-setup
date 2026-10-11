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
};

async function get(path) {
  const r = await fetch(path, { credentials: "same-origin" });
  const body = await r.json().catch(() => ({}));
  if (!r.ok) throw new Error(body.error || ("HTTP " + r.status));
  return body;
}

const main = document.getElementById("main");
const state = { days: 30, logs: { user: "", severity: "", category: "", rows: [], total: 0 }, sessUser: "" };

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
     ["", fmt.bytes(o.storage.bytes), "chat storage"]]
      .map(([cls, v, l]) => h("div", { class: "fig " + cls }, h("b", { text: v }), h("span", { text: l }))));

  const provTotal = o.by_provider.reduce((a, p) => a + p.tokens, 0) || 1;
  const split = h("div", { class: "split" }, o.by_provider.map(p => {
    const i = h("i", { class: p.provider }); i.style.width = (100 * p.tokens / provTotal) + "%"; return i; }));

  main.replaceChildren(
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
        bars(o.blocks, "source", "count", r => fmt.n(r.count), "deny"))));
  document.getElementById("host").textContent = o.host_label;
  document.getElementById("fresh").textContent = o.last_ingest ? "Data as of " + fmt.ts(o.last_ingest) + " UTC" : "Never ingested";
}

// Logs -----------------------------------------------------------------------
const CAT_LABEL = { "tool-call": "Tool calls", denial: "Blocked", redaction: "Hidden credentials",
  "api-error": "API errors", "rate-limit": "Limit hits", "slash-command": "Slash commands",
  skill: "Skills", plugin: "Plugins", "log-integrity": "Log integrity" };

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
  const table = L.rows.length ? h("div", { class: "scroll" }, h("table", {},
    h("thead", {}, h("tr", {}, ["When (UTC)", "Person", "Result", "Kind", "Decided by", "Tool", "Detail"]
      .map(t => h("th", { text: t })))),
    h("tbody", {}, L.rows.map(e => h("tr", {},
      h("td", { class: "ts", text: fmt.ts(e.ts) }), h("td", { text: e.user }),
      h("td", {}, h("span", { class: "sev " + e.severity, text: e.severity })),
      h("td", { text: CAT_LABEL[e.category] || e.category }), h("td", { text: e.source }),
      h("td", { text: e.tool }), h("td", { class: "detail", text: e.detail }))))))
    : h("p", { class: "empty", text: "No events match these filters." });
  main.replaceChildren(
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
  main.replaceChildren(
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
        h("td", { class: "n", text: fmt.days(x.age_days) + (x.age_days > 1 ? " ago" : "") }))))))
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
      h("th", { class: "n", text: "Tokens" }), h("th", { class: "n", text: "Active days" }),
      h("th", { class: "n", text: "Last used" }), h("th", { class: "n", text: "5-hour" }),
      h("th", { class: "n", text: "Weekly" }), h("th", { text: "Last limit (UTC)" }), h("th", { text: "Under-use" }))),
    h("tbody", {}, rows.map(r => h("tr", {}, h("td", { text: r.user }), h("td", { class: r.tier ? "" : "muted", text: r.tier || "none" }),
      h("td", { class: "n", text: fmt.tok(r.tokens) }), h("td", { class: "n", text: fmt.n(r.active_days) }),
      h("td", { class: "n", text: r.last_active ? fmt.days(daysSince(r.last_active)) + (daysSince(r.last_active) > 1 ? " ago" : "") : "never" }),
      h("td", { class: "n" + (r.five_hour ? " hit" : ""), text: fmt.n(r.five_hour) }),
      h("td", { class: "n" + (r.seven_day ? " hit" : ""), text: fmt.n(r.seven_day) }),
      h("td", { class: "ts", text: fmt.ts(r.last_limit) }),
      h("td", {}, r.under_use.map(w => h("span", { class: "flag", text: w }))))))))
    : h("p", { class: "empty", text: "Nobody has used Claude Code or holds a seat yet." });
  main.replaceChildren(
    head("People", "Last " + p.days + " days", seg([[7, "7d"], [30, "30d"], [90, "90d"]], state.days,
      d => { state.days = d; render(); })),
    figs,
    h("section", {}, h("h2", { text: "Limits hit, by person" }),
      bars(limited.map(r => ({ user: r.user, n: r.five_hour + r.seven_day + r.other_limit, r })), "user", "n",
        x => fmt.n(x.r.five_hour) + " five-hour, " + fmt.n(x.r.seven_day) + " weekly", "quota")),
    h("section", {}, h("h2", { text: "Everyone" }), h("p", { class: "muted", text: rule }), table));
}
function daysSince(ts) {
  return Math.floor((Date.now() - Date.parse(ts.slice(0, 19) + "Z")) / 864e5);
}

// Routing --------------------------------------------------------------------
// <main> carries data-page and data-state (loading, ready, error) so a test,
// or a person with the inspector, can tell a page that finished from one that failed.
const PAGES = { overview, logs: () => logs(false), sessions, people };
function fail(e) {
  main.dataset.state = "error";
  main.replaceChildren(h("p", { class: "err", text: "Could not load this page: " + e.message +
    ". If the server restarted, open the address it printed again." }));
}
function render() {
  let page = location.hash.replace("#/", "") || "overview";
  if (!PAGES[page]) page = "overview";
  for (const a of document.querySelectorAll(".side a"))
    a.toggleAttribute("aria-current", a.dataset.page === page) && a.setAttribute("aria-current", "page");
  main.dataset.page = page;
  main.dataset.state = "loading";
  PAGES[page]().then(() => { if (main.dataset.page === page) main.dataset.state = "ready"; }, fail);
}
window.addEventListener("hashchange", () => { render(); main.focus(); });
render();
