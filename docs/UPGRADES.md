# Version upgrade log — every pin, and what it changed

| | |
| --- | --- |
| **What** | One entry per Claude Code version transition of the pin this repository ships: what the vendor shipped, what the settings surface gained or lost, what changed in the policy and scripts in response, and what the re-verification probes are for |
| **Who** | Whoever runs a version bump (IT), and anyone auditing why the policy pins the version it pins. No prior knowledge assumed |
| **When** | Current through the pin named by `requiredMinimumVersion` in `settings/managed-settings.json` — CI check [9] refuses a pin that has no entry here |
| **Where** | Every governed host — the pin is fleet-wide policy. What a site's own probe run found on its hosts is recorded in `internal/CURRENT-STATE.md`, not here |
| **Why** | Commit subjects are the changelog for repository edits, but a vendor version transition has no other home: the vendor's changelog does not know this policy, and the policy does not record why it moved |
| **Status** | Live log — newest entry first; an entry freezes once its bump is verified |
| **Owner** | The maintainer |

## The entry contract

Every entry heads with `## <version> — <one-line reason>` — that heading is what CI check [9]
matches against the policy's `requiredMinimumVersion`, so the record cannot be skipped and cannot
silently rot. Below the heading, four parts, in order:

1. **Vendor changes** — what shipped between the previous pin and this one, with a link to the
   official changelog (<https://code.claude.com/docs/en/changelog.md>). Classify what matters
   here: security-relevant / new settings keys / behaviour changes. "Nothing affects this
   deployment" is a valid and useful finding — state it rather than omitting the part.
2. **Settings-surface delta** — keys added, retired, or with changed defaults, against the
   [`SETTINGS-REFERENCE.md`](SETTINGS-REFERENCE.md) §6 inventory. The §6 rows change in the same
   commit as the entry; keys losing their ▲ (postdates-the-pin) flag need a decided position.
3. **Our response** — policy edits made (or "none needed"), scripts touched, documents re-anchored
   to the new version.
4. **Probes** — what `bin/cc-bump-audit.sh` asks: which standing questions re-verify unchanged at
   this version, and which changed their answer (each changed answer is itself work, in this or a
   follow-up commit). The entry records what holds of the build; what the run found on a site's
   own hosts — counts, accounts, dates — goes in `internal/CURRENT-STATE.md`.

The procedure that produces an entry — including the agent-assisted analysis lanes — is
[`OPERATIONS.md`](OPERATIONS.md) Part 7. Entries are version-anchored, never calendar-dated
([`DOC-STYLE.md`](DOC-STYLE.md) §2); the dated record is `internal/` and git history.

---

## 2.1.236 — permission-layer fixes, and classifier defaults restored with telemetry off

**Vendor changes.** Eight builds separate the pins.

> **How to read the vendor changelog.** <https://code.claude.com/docs/en/changelog.md> is **MDX**,
> with entries in `<Update label="2.1.231" …>` blocks, so a `^## <version>` parse finds none of
> them and every version looks undocumented. Read properly, entries exist for 2.1.229 and 2.1.231;
> **only 2.1.230 has none** — the string does not occur on the page at all.
> The rule is reusable: **parse the format the vendor actually publishes, and report the
> denominator** — a count of entries parsed exposes a parser that matched nothing, where "no
> entries found" reads as a fact about the vendor.
> `cc-version-watch.sh` deliberately does not touch the changelog at all — it answers
> "is anything published above the pin", and classification is the bump procedure's job
> (`OPERATIONS.md` §7.4).

The case for moving rests on four fixes, none of them a feature:

- *Session-scoped permission answers, including denies, were dropped when answering a background
  subagent's permission prompt* (2.1.234) — a deny that did not stick. 2.1.232 made background
  subagents the default in the same window, so the exposure was growing.
- *The managed-settings approval prompt could fail to appear while still taking the first keypress
  as approval* (2.1.236). The prompt in question gates the managed policy.
- *Shift+Tab inside a permission prompt's comment field approved the edit and granted session-wide
  edit permission* (2.1.235) — an accidental keystroke widening a session on a shared host.
- *Auto mode now uses the same classifier defaults, including severity scoring, when telemetry is
  disabled* (2.1.236). The policy disables telemetry, so `classifyAllShell` had been running on
  degraded defaults **because of the policy's own hardening**.

Security-relevant elsewhere in range: GitLab token redaction (2.1.232), skill/command argument
values no longer re-expanded as template markers (2.1.233), MCP diagnostics no longer printing
resolved secrets (2.1.234), git-status checks no longer defeated by `status.showUntrackedFiles=no`
(2.1.236). Behaviour changes worth announcing: subagent forking on by default and cross-session
messaging between local sessions (2.1.232), the Task/Todo tools withdrawn on current models
(2.1.233), nested git repositories no longer inheriting trust from a parent (2.1.232) — that last
one produces new trust prompts where repositories nest on shared storage. Windows-only and
sandbox-only items are irrelevant here; the Linux sandbox is untouched in this range, so
`SANDBOX-DECISION.md` stands.

**Settings-surface delta.** Verified by diffing the settings schema embedded in the 2.1.228 binary
against the one in a newer build, not by reading the documentation:

- **No key the policy enforces changed name, shape or default**, and none was retired. The policy
  needed no re-authoring for this bump — only the floor moved.
- New and settable at this pin: `disableCommandPluginSources`, `syncClaudeAiSkills`,
  `autoContinueAtUsageLimit`, and the marketplace aliases `allowedMarketplaces` /
  `additionalMarketplaces`; plus the environment variables `CLAUDE_CODE_TOOL_MEMORY_LIMIT`,
  `CLAUDE_CODE_WEBFETCH_CACHE_TTL_MS`, `CLAUDE_CODE_ENABLE_TODO_TOOLS`,
  `CLAUDE_CODE_PROJECT_DIR_NAME`, `CLAUDE_CODE_GOAL_CHECKIN_MINUTES`, `ANTHROPIC_DEFAULT_MODEL`.
  Each has a §6 row and a position; three carry an open **decide**, called out below.
- **`syncClaudeAiSkills` is the one that changes a fact about a deployment**: the §6 position is
  "keep skill distribution local", but the key does not exist at 2.1.228 — so below this pin
  claude.ai skill sync is *on* whatever the policy says. The position only becomes real when the
  key is settable and set.
- **The object form of `strictPluginOnlyCustomization` does not become usable here.** Both builds
  accept `boolean | array` only, with the same `claude doctor` rejection text, so the array
  `["hooks", "mcp"]` stays.
- **None of §6's ▲ keys resolves at this pin.** The flags are adjudicated against the shipped
  schema, not the documentation: `managedSourcesBehavior` and `modelPicker` are gated at a version
  well beyond this one, and `sshHostAllowlist` is not a settings key in either build, so it has no
  row to flag. When recording a delta like this, **count the thing, and say what you counted** —
  read the rows, do not estimate them.

**Our response.** The floor moved in both policies; no other policy key changed. Four defects in
the repository's own machinery were found *by running the procedure* and fixed before the pin
moved: the upgrade guard blocked the read-only `dnf check-update` that step 1 of this procedure
runs (and missed `localinstall` / `distro-sync`); the bump audit and health check reported a
privileged session's bind-mounted admin policy as fleet drift, failing the gate for a non-reason;
`cc-update.sh rollback` had no floor guard, left the package unlocked after a failed transaction,
ran no smoke test, and neither blocked nor reported live sessions; and the count of private
installs below the floor was written into documents by hand. That count is computed by probe A5
and is not written into any document.

**Probes.** What the bump audit established about this build, run after the package and policy
landed.

*Automatic.* A1 (compiled policy path), A2 (2 files, no scriptlets, no `.rpmnew`/`.rpmsave`), A4
(binary 2.1.236 = `approved-version` = floor) are unchanged. A6 (sandbox-helper strings) is
report-only: the number of matching lines differs from the 2.1.228 binary, which is a reason to
diff the lines at the next bump, not a behaviour change on its own. A3 (deployed policy matches
its baseline) and A7 (every filename deny rule present in the deployed policy) pass when the audit is
pointed at the fleet policy — inside a `claude-admin` session they skip, because the policy path
there is the bind-mounted admin file. A5 answers differently as root than as a user: an
unprivileged sweep cannot see a home whose `~/.local` is `0700`, so run it as root. The floor
bites — a below-floor binary run directly refuses the session with *"Claude Code <version> is
older than the minimum version required by your organization (2.1.236)"*.

*Manual.* **M3** the status line renders every segment (model, tok/ctx%, 5h/7d, git, python) from
a synthetic payload. **M4** project-level skills load in a session at this build, hooks and MCP
still locked; the user-level half (`~/.claude/skills/`) is a separate smoke test. **M9**
`$defaults` still *extends* the `autoMode` built-ins — 27 environment entries, 2 `hard_deny`, no
literal `$defaults` left in the expansion. **M11** a `PreToolUse` hook exiting 2 **still blocks**:
a `Read` of a scratch `.env` is refused with the guard's own message, so the hook that stands in
for the unenforced filename-glob deny rules holds at this build. **M12** command wrappers are
still stripped before permission matching — `timeout 5 chmod 777 …` and `nice -n 5 chmod 777 …`
are both denied — which is the assumption every Bash rule in the policy rests on. **M5 is
unchanged and still negative**: a permission-rule denial inside `claude -p` writes nothing to the
denial log, so the `PermissionDenied` hook remains silent in headless runs. **M6** reason 1 holds
wherever a private comparison install newer than the pin is kept (a ceiling at the pin would stop
it); reason 2 and **M7** need a host with an editor and the Claude extension installed.

*Deferred, each with a reason.* **M1** needs the sandbox temporarily enabled in a window. **M2**
needs a policy re-apply to observe the session break. **M8** needs a deliberately malformed key in
the *managed* policy — a scratch `CLAUDE_CONFIG_DIR` with a bogus user-level key produced no schema
warning, so the question cannot be answered from user settings. **M10** and **M13** need an
interactive `/doctor` and the claude.ai console respectively.

*One coverage question raised by the probing, not a defect.* The secret guard matches `.env` and
`.env.*` exactly, mirroring the deny rules it substitutes for — so a file named `prod.env` is not
covered. Whether that shape should be added is a settings-review decision, not a bump one.

The residual risk this bump surfaced was **claims nobody had written a probe for**, so the manifest
grew rather than the finding being noted and forgotten: **M11** (does a PreToolUse exit 2 still
block? — the enforcement half of both guards), **M12** (are command wrappers still stripped before
permission matching the way every Bash rule assumes?), **M13** (is the organisation console still
empty, so the local policy is still authoritative?). A fourth gap was a claim with no *document*
home — the CLI `claude doctor` carrying no permission diagnostics, which is why A7 is presence-only
and M10 is manual; its home is [`SETTINGS-REFERENCE.md`](SETTINGS-REFERENCE.md) §2.1.
**A8** exists for a different reason: the operator experience. It asks, during the audit, who is
running the managed binary — because the apply step refuses while anything is, and the session that
blocks you is typically your own, which no tab list shows.

## 2.1.228 — the initial pin

The baseline entry: 2.1.228 is the version the policy, hooks and scripts in this repository were
first built and verified against, not a transition from an earlier governed state.

**Vendor changes** — not applicable; there is no previous pin. For reference, 2.1.228 itself was a
fix release (session redraw hang, `/tui` model reversion, cross-session messaging, settings-merge
precedence for marketplace entries) whose one security-relevant item was hardening of skills synced
from claude.ai: descriptions sanitised, bodies barred from running `!` commands or expanding `@`
files. Vendor changelog: <https://code.claude.com/docs/en/changelog.md>.

**Settings-surface delta** — the full inventory as verified at this version is
[`SETTINGS-REFERENCE.md`](SETTINGS-REFERENCE.md) §6, including the ▲ flags on keys the vendor
documents only for later versions. One skew is reported by `claude doctor` itself: this version
rejects the vendor-documented *object* form of `strictPluginOnlyCustomization`
("expected true or an array, got object — silently ignored"), and its native granular syntax is
the **array of restricted types**. Both policies — fleet and admin — therefore carry
`["hooks", "mcp"]`. A policy carrying the object form has the key dropped, and the effective
posture is still the intended one — `allowManagedHooksOnly`, `allowManagedMcpServersOnly` with
`allowedMcpServers: []`, and `disableSideloadFlags` hold hooks and MCP closed independently
([`SETTINGS-REFERENCE.md`](SETTINGS-REFERENCE.md) §3.4) — which is the sibling-lock design doing
its job. Project-level skills load; the user-level (`~/.claude/skills/`) smoke test is probe M4.

**Our response** — the deployment this repository ships *is* the response: the policy, the hooks,
the RPM pin, and the probe manifest in `bin/cc-bump-audit.sh` that turns this version's verified
claims into questions the next version must answer again.

**Probes** — the standing questions and their at-this-version answers live as the probe manifest
(`bin/cc-bump-audit.sh --list-probes`); the product behaviours behind them are
[`SANDBOX-DECISION.md`](SANDBOX-DECISION.md) (the sandbox, and why it is disabled) and
[`RUNBOOK.md`](RUNBOOK.md): filename-glob deny rules that not every build enforces on Linux, the `PermissionDenied` hook
silent in headless runs, and the version floor refusing private installs below it.
