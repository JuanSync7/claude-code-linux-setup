# House style — how these documents are written

| | |
| --- | --- |
| **What** | The rules every document in this repository follows: the doc-type taxonomy, the front-matter table, voice, the one-canonical-home rule, command blocks, and how history is marked. Read it before editing any doc here |
| **Who** | Anyone adding or editing documentation in this repository. No prior knowledge of the deployment is assumed |
| **When** | Before any edit to a document here. It describes the document set as it stands in this repository |
| **Where** | `GOAL.md`, `README.md`, everything under `docs/` and `internal/`. A superseded file archived under `internal/` is exempt from all rules except the archive banner (§6.3) |
| **Why** | Documentation fails in four repeating ways — changelog voice, contradictions, stale references, duplication. Each one is a style failure with a mechanical rule that prevents it. This page is those rules |
| **Status** | In force |
| **Owner** | The maintainer |

---

## 0. The one sentence that governs everything else

These documents exist so that a junior engineer can build, verify, fix and upgrade a governed Claude Code host **without asking anyone** — which means every doc must be precise about commands *and* considerations, and must be cheap for IT to keep true. Every rule below is that sentence made mechanical. When a rule and that sentence conflict, the sentence wins.

Two shapes are fixed. Copy them; do not improvise:

- **A decision record** takes the shape of `docs/SANDBOX-DECISION.md`.
- **A lesson** has three parts, in this order: *what happened → the rule that generalises → where else it applies*. A correction is written the same way: the mistake is named as the mistake, with the check that would have caught it (§6).

## 1. The taxonomy — know what kind of document you are editing

Every file here is one of five types. The type determines what you owe the reader, so identify it before you edit — most defects come from writing one type in the voice of another (procedure steps drifting into a reference, history accreting in a register).

| Type | The reader's contract | What every instance owes |
| --- | --- | --- |
| **Runsheet** | "I will execute this top to bottom" | An order proven to work; one action per step; a pass condition per step; a failure branch; the entry state assumed and the exit state produced; who runs it, on which host, as which user |
| **Reference** | "I arrive with a question, land on any section" | Every sentence true standing alone, at read time; lookup structure (tables, key-by-key); verified vs designed clearly graded; no hidden step ordering |
| **Decision record** | "What was decided, and does it still bind?" | The decision in the first lines; date, decider, status, what it supersedes; reasons each sufficient alone; the conditions that would reverse it |
| **Register** | "Show me the live list" | Maintained in place after every change; every row has owner, status and date; denominators stated ("every account audited, of how many", never a bare "healthy"); rows are closed, never silently deleted |
| **Record** | "What actually happened?" | Frozen. Date and scope in the header; corrections annotate the record, they never retell it; a superseded record moves to an archive directory under `internal/` with the banner (§6.3) |

Every document, the directory maps and the skills, classified:

| File | Type | Note |
| --- | --- | --- |
| `GOAL.md` | Decision record | The top of the set: the goal and the ranked rules. Holds **no** mechanism, path, key or number — a detail change never edits it, so a diff to it is always a change of direction |
| `docs/QUICKSTART.md` | Runsheet | The model runsheet — shortest path to a governed host |
| `docs/OPERATIONS.md` | Runsheet | The full procedures: build, upgrade, run, recover, decommission |
| `docs/IDE-INTEGRATION.md` | Runsheet | Its **Status** row says whether the method has been executed or is only proposed, which is what keeps it honest |
| `README.md` | Reference | The repository front door: install, layout, repo practice. The document map is `docs/README.md` |
| `docs/README.md` | Reference | The index: what each doc is (type per §1), when to read it, and the reading orders |
| `*/README.md` — the directory maps (`bin/`, `hooks/`, `githooks/`, `lib/`, `settings/`, `share/`, `systemd/`, `profile.d/`, `tests/`, `aws/`, `dashboard/`, `publish/`, `internal/`, `.claude/`, `.claude/skills/`) | Reference | One line per file plus the link to its canonical doc — **never a second home for any fact**. Update in the same commit that changes the directory's contents |
| `docs/REPORTING.md` | Reference | The reporting and metrics contract: the weekly report's rules and verdicts, the version watch, and what a monitoring system may read. The reports themselves are group-only and live on the host, not in `docs/` |
| `docs/REPO-MAP.md` | Reference | The coupling map: what else must change when you change something, and which couplings CI holds vs discipline |
| `docs/CODING-STANDARD.md` | Reference | The rules for code, as this page is the rules for documents: deciding from structure rather than text, the exit-code table, failure handling, configuration, idempotency, comments |
| `.claude/skills/*/SKILL.md` — the maintenance skills | Runsheet (pointer form) | Frontmatter is the vendor contract (`name`, `description` for semantic matching). The body either executes a named `OPERATIONS.md` Part 7 section step by step (`version-bump`) or is itself the one home of its own run steps under a §7.2 contract row (the standing audits) — either way, **no fact lives both in a skill and in a document**; a copied step is a second home and rots like one |
| `docs/RUNBOOK.md` | Reference | The *why* and the product behaviour. A hybrid that also holds pre-charter decisions; **new decisions do not go here** — they get their own record in the `SANDBOX-DECISION.md` shape |
| `docs/SETTINGS-REFERENCE.md` | Reference | The policy, key by key: what each key does and whether changing it is a preference or a dismantled control |
| `docs/ADMIN-SESSION.md` | Reference | The `claude-admin` mechanism and its use |
| `docs/ENGINEER-GUIDE.md` | Reference | The one document written for the engineers the policy governs, not for IT. Layered: Part 1 assumes nothing, Parts 2–3 are for when they want more. Installed on every host because engineers cannot read this repository; its blocked-command table is drift-tested against the policy |
| `docs/SANDBOX-DECISION.md` | Decision record | The model. Decision first; reasons each sufficient alone; re-enable conditions. The template's record is generic; a site's own adds its date, its decider and what it supersedes |
| `docs/UPGRADES.md` | Record | One frozen entry per version transition, newest first; the entry contract is at its top, and CI check [9] refuses a policy pin with no matching entry |
| `internal/CURRENT-STATE.md` | Register | The state register. **The single authority for what is true now**; where any doc disagrees with it about state, this file wins and the other is stale — fix the other |
| `internal/LIMITATIONS-AND-RISKS.md` | Register | The risk register. A risk with no named acceptor, compensating control and review date is not accepted, it is unowned |
| `internal/README.md` | Reference | The map of the group-only record. A site may keep more there than the two registers — its evidence, its lessons, its superseded documents — and each such file declares its type in its own front matter |
| `docs/LOCAL-VS-AWS.md` | Register | Site-difference and transition register, graded `[HOST]` / `[PLANNED]` / `[UNVERIFIED]` |

This charter is itself a reference. New files declare their type in the front matter and take the obligations of that type.

## 2. The 5W front-matter table

**Required on every new document, and added to any existing document on its next substantive edit.** It is the first thing in the file after the title, before any prose. Pattern files: `docs/QUICKSTART.md`, `docs/IDE-INTEGRATION.md`.

The rows, and what each must actually answer:

| | |
| --- | --- |
| **What** | The thing this doc delivers, in one sentence — not its topic, its deliverable |
| **Who** | Who executes or reads it, and what they are assumed to know ("No prior knowledge of this repository is assumed" is a valid and useful answer) |
| **When** | What the document is verified against — normally "the pinned build", pointing at `requiredMinimumVersion` rather than repeating a number (see the version-literal rule below). **Never a calendar date in a Reference or Runsheet**: they state current truth, currency anchors to the pin, git history holds time, and `internal/` holds the dated record. Decision records, records and registers are the exception wherever they live — a date is part of their type contract (§1), so `SANDBOX-DECISION.md`, `UPGRADES.md` and `LOCAL-VS-AWS.md` carry dates by design. A file name, a log line or a key fingerprint that happens to contain a date is data, not a dating |
| **Where** | Which hosts or sites it applies to, and which it does not |
| **Why** | Why this is its own document rather than a section of another — this row is the duplication guard |
| **Status** | **Executed/verified vs. proposed/designed, and on which hosts.** The single most load-bearing row: "Verified on one host; not yet executed on a second" and "Method proposed, not yet executed" are the honest shapes |
| **Owner** | Who answers for the document: a role, never a person's name ("The maintainer") |

**Version literals belong in two places, and nowhere else.** A reference or procedure document
states **whether a thing is there**, not which build introduced it: "the object form is not
accepted", "this key is not available at the pin", "the floor stops any binary below it". The two
exceptions are [`UPGRADES.md`](UPGRADES.md), whose whole job is when-something-changed, and
the **policy file**, where the literal is the thing itself. A command someone copies does not spell
the pin either: it reads it from the policy at run time (`PIN=$(python3 -c …)`, as `QUICKSTART.md`
does), so a bump edits one file. The suite fails any shipped Reference or Runsheet that spells the
current pin. Records under `internal/`, and anything archived there, are frozen and keep
whatever numbers they were written with.

The reason is maintenance, not taste: a number in prose is a fact with no owner. It goes stale
silently at the next bump, it goes stale in *every* document that repeated it, and the reader
cannot tell whether "at build X" means "still true" or "was true then". A sentence that says what
is true needs no re-anchoring; a sentence that says *since when* needs re-anchoring forever. Where
the reader genuinely needs the build number, the pin is one file away and `UPGRADES.md` has the
history.

Registers and records may keep their existing compact variants (`Document type / Scope / …`, as in `OPERATIONS.md`; two compact tables need not share row names) — the test is never the exact row names but that a reader knows, before line 20, what this is, whether it is current and verified, and who answers for it. A compact table missing a version anchor gains one on its next substantive edit. Archived files take the archive banner (§6.3) instead.

## 3. Voice — tell the truth, do not narrate the change

**A document tells the current truth. The story of how the text got that way belongs in the changelog — and this repository's changelog is `git log`.** There is no `CHANGELOG.md`, deliberately: a hand-maintained history file is a second copy of what git already records, and a second copy of anything is how contradictions start. Write commit subjects so that `git log --oneline -- docs/` reads as a changelog ("Correct two test messages that asserted the opposite of the truth"). The `make dist` tarball carries no history — it is a deployment artefact, not an archive; the record lives in the repository.

The test for changelog voice: **would the sentence lose anything a reader needs *in order to act* if they had never seen any earlier version of the doc?** If not, the historical clause goes to the commit message.

An example, from a network allowlist section:

> **Before:** "This is the complete documented allowlist. The earlier version of this guide listed only three of these, which is enough for install and inference but not for login — OAuth token exchange goes to platform.claude.com, and sign-in redirects through claude.com. Omitting either breaks authentication while appearing to leave the install working."
>
> **After:** "This is the complete documented allowlist. Three of these hosts are enough for install and inference but **not for login**: OAuth token exchange goes to `platform.claude.com`, and sign-in redirects through `claude.com`. Omitting either breaks authentication while leaving the install looking healthy."
>
> **Commit message:** "Allowlist: add platform.claude.com and claude.com to the allowlist — the three-host list broke login."

Note what the rewrite keeps: the *trap* (a partial allowlist looks like a working install) survives, because that is a consideration the reader needs. Only the document's autobiography ("the earlier version of this guide…") is removed.

Greppable tells — each hit is either inside a record (where history *is* the content) or a rewrite candidate: `previously`, `used to be`, `the earlier version`, `has been fixed/updated`, headings ending `— fixed`, and `is now` / `no longer` when they describe the *document* rather than the world. ("There is no longer a sandbox layer" is telling voice — it states a current absence the reader must design around. "This section previously said X" is not.)

## 4. One canonical home per fact

**Every fact lives in exactly one document. Every other document states the conclusion and points.** Two live copies of the same fact is a contradiction on a delay timer: one copy is updated, the other is not.

The authority map. A new fact goes in its row's home; if no row fits, extend this map in the same commit:

| Subject | Canonical home |
| --- | --- |
| What is true right now — hosts, deployed files, open findings | `internal/CURRENT-STATE.md` |
| The sandbox: its status and the reasons | `docs/SANDBOX-DECISION.md` |
| Procedures: build, upgrade, recover, decommission | `docs/OPERATIONS.md` |
| Each policy key: meaning, value, whether it is safe to change | `docs/SETTINGS-REFERENCE.md` |
| Why decisions were made; product behaviour | `docs/RUNBOOK.md` |
| On-prem vs AWS differences | `docs/LOCAL-VS-AWS.md` |
| Limits and accepted risks | `internal/LIMITATIONS-AND-RISKS.md` |
| Site state and site risk, seen from a document outside `internal/` | Named as the place a site records it — "a site records X in `internal/…`" — never as what the register holds. The registers differ per site and ship blank in the public template edition, so a sentence that says what one contains is false for every other reader |
| The two editions: where a site value is concrete and where it is a listed placeholder | `docs/PUBLISHING.md` §1 |
| The admin session | `docs/ADMIN-SESSION.md` |
| The IDE method | `docs/IDE-INTEGRATION.md` |
| The shortest build path; the file manifest | `docs/QUICKSTART.md` |
| The `make` interface — every target, what it needs root for, what may be overridden | `docs/QUICKSTART.md` §7 |
| Each operator script: what it does, when it runs, and its exit-code and message contract | `docs/RUNBOOK.md` §12 |
| Which script has which test cases, and which have none and why | Nothing written: `tests/test-cc-scripts.sh --coverage` derives it. `tests/README.md` holds the contract a case owes, never the map |

The pointer pattern — conclusion plus link, never a restatement:

> **Right:** "The sandbox is disabled fleet-wide (`SANDBOX-DECISION.md`); design as if no layer holds against subprocess escape."
> **Wrong:** copying the three reasons, or the policy's rule counts, into a second document — the counts change, one copy goes stale, and the reader cannot tell which copy is the stale one.

Precedence when you *find* a disagreement: on its own subject the canonical home wins; on state, `CURRENT-STATE.md` wins over everything. Then **fix the losing document in the same commit** — a noted contradiction is still a contradiction.

## 5. Command blocks — copy-pasteable, pass-conditioned, junior-executable

Every command block a reader is meant to run must satisfy all of:

1. **Copy-paste clean.** No `$` prompts, no output interleaved in the block. Evidence transcripts are a different thing: label them as output and keep them in separate blocks.
2. **Context stated.** Which host, which user, and real terminal vs. inside a Claude session — in a leading `#` comment or the sentence before.
3. **A pass condition,** stated as something observable: an exact string, an exit code, a value with its expected range. "Verify it worked" is not a pass condition.
4. **A failure branch:** what a failure means and where to go — a section, not "investigate".
5. **Placeholders in `<angle-brackets>`,** named before the block. Prefer the `make` targets where they exist; they carry the guards a raw command skips.

The test for junior-executable: *someone who has read only this section can run the block and know, from its output alone, whether it worked.*

The shape, with a real command:

> On the target host, as root, from a real terminal:
>
> ```bash
> make quickstart
> ```
>
> **Pass:** exits 0. Re-running on a built host is a harmless no-op.
> **Fail:** it refuses when the hook paths named inside the policy and the files on disk disagree — that mismatch would *look* configured and enforce nothing. Fix the paths per `QUICKSTART.md` §2; never hand-edit the deployed file (`OPERATIONS.md`).

Considerations travel *with* the command, in one or two sentences, exactly as the fail line above does — a command without its consideration is how a health check comes to report `healthy` after auditing one account out of many.

## 6. Marking history — three mechanisms, one decision

When something stops being true, choose by scope:

**6.1 A single value changed, and readers may still arrive holding the old one** (it circulated in other docs, old bundles, or people's heads): strikethrough the old value once, at its canonical home, with the replacement and the date (in a Reference or Runsheet, the date goes in the commit message instead — §2 **When**) — the shape is `~~strictAllowlist~~ **gone with the sandbox**`. This is the *only* form in which a dead value may appear in a living document.

**6.2 The change has no reader-facing residue:** rewrite the text to the current truth and put the narrative in the commit message (§3). This is the default; use it unless you can say who still holds the old value.

**6.3 A whole artefact is superseded:** move it to an archive directory under `internal/` and give it a banner at line 1 that makes it self-describing: the date, what superseded it, and what must not be replayed. A superseded runsheet's banner names the supersession *and* the specific step that would damage a host if replayed. An archived file with no banner is a trap, not an archive.

**The `⌦` correction block** (`> **⌦ CORRECTION YYYY-MM-DD.**`) is reserved for corrections whose *reasoning* is load-bearing — where knowing why the wrong belief was plausible, and which one-command check would have caught it, protects the next editor. A ⌦ block sits **below already-corrected body text and never carries the only statement of the truth.** When you touch a section whose ⌦ block has become settled fact, fold it into the body and delete the marker.

**Exception:** in a record, the mistake *is* the subject matter and may be quoted — always framed as the mistake, never left readable as a live claim.

## 7. Never leave a wrong value next to its correction

A skimming reader takes the first value they see; a grep hits both. Text that states the wrong value and then corrects it is ambiguous under exactly the partial reading every operator does at 2 a.m.

> **Banned shape:** "`socat` requires EPEL. *Correction: it does not — it is in appstream.*"
> **Required shape:** "`socat` is in Rocky 8's `appstream` repository; EPEL is not required. `dnf provides socat` on the host is the check."

The rule: **delete or rewrite the wrong sentence itself.** The correction's story goes to the commit message, or to a ⌦ block below the *corrected* text when the reasoning earns it (§6). Acceptance test after any correction: `grep -rn '<old value>' README.md docs/ internal/ --include='*.md'` returns zero live hits — only strikethroughs, archive files, or records quoting it as a mistake.

## 8. The editor's checklist — run before committing

1. New or substantially edited doc → 5W table present, **Status** row honest about executed vs. proposed (§2).
2. `grep -nE 'previously|used to be|the earlier version|has been (fixed|updated|changed)|— fixed'` on your file → every hit justified by §3 or rewritten.
3. Changed a value? → grep the whole doc set for the old one (§7), fix every live hit in this commit.
4. New fact? → it is in its canonical home per §4's map, and everywhere else is a pointer.
5. Every command block you touched has a pass condition and a failure branch (§5).
6. Every file path and doc name you cite exists in the tree; every `§n` cite resolves.
7. Superseding something whole? → the archive under `internal/`, with the banner, in the same commit (§6.3).
8. Commit message written as the changelog entry it is (§3).
9. If your change alters what is true on a host: update `internal/CURRENT-STATE.md` in the same commit — it is the register that makes every other doc checkable.