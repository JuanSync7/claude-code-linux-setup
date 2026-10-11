# The document map — what each document is, and when to read it

| | |
| --- | --- |
| **What** | The map of the document set: each document's type (per [`DOC-STYLE.md`](DOC-STYLE.md) §1), what it delivers, and when to reach for it — plus the reading orders |
| **Who** | Anyone arriving at this repository. No prior knowledge assumed. Editors read [`DOC-STYLE.md`](DOC-STYLE.md) before touching any document here |
| **When** | Against the **pinned build** — the pin is `requiredMinimumVersion` in `settings/managed-settings.json`, and [`UPGRADES.md`](UPGRADES.md) records every move of it. Re-verified at each bump (`OPERATIONS.md` Part 7) |
| **Where** | The whole set: `docs/` (ships with the deployment) and `internal/` (the group-only record) |
| **Why** | The map of the set cannot live inside any one member, and the repository `README.md` fronts the code and the install, not the documents |
| **Status** | Live index — update the tables in the same commit that adds, renames or retires a document |
| **Owner** | The maintainer |

## The working loop

Above the loop sits [`GOAL.md`](../GOAL.md) — the one goal and the ranked rules every document and script serves. Read it before your first change; it holds no detail, so it rarely changes.

Four verbs cover every visit:

- **To do** — [`QUICKSTART.md`](QUICKSTART.md) for one governed host today; [`OPERATIONS.md`](OPERATIONS.md) for the full build and everything after it.
- **To understand** — [`RUNBOOK.md`](RUNBOOK.md) for why things are shaped this way and how the product behaves; [`SETTINGS-REFERENCE.md`](SETTINGS-REFERENCE.md) for any policy key; [`ADMIN-SESSION.md`](ADMIN-SESSION.md) and [`IDE-INTEGRATION.md`](IDE-INTEGRATION.md) for their mechanisms.
- **To know what is actually true, and what was knowingly accepted** — [`internal/CURRENT-STATE.md`](../internal/CURRENT-STATE.md) and [`internal/LIMITATIONS-AND-RISKS.md`](../internal/LIMITATIONS-AND-RISKS.md). Read both before claiming a control to a customer or an auditor.
- **To read what the estate reports about itself** — [`REPORTING.md`](REPORTING.md): what the weekly report and the version watch contain, every rule that can raise an alert, and what a verdict does and does not entitle you to conclude.

## `docs/` — ships with the deployment

| Document | Type | Read it when |
| --- | --- | --- |
| [`ENGINEER-GUIDE.md`](ENGINEER-GUIDE.md) | Reference | You **use** Claude Code rather than run it — or you are onboarding someone who does. How to start, what is blocked and why, what is logged, how to customise within the rules. Installed on every host at `/usr/local/share/claude-code/`, where the welcome banner points |
| [`QUICKSTART.md`](QUICKSTART.md) | Runsheet | **Start here.** You want one host governed today: the file manifest, what may move and what may not, both install methods and their tradeoff, the Makefile |
| [`OPERATIONS.md`](OPERATIONS.md) | Runsheet | You are about to do something. Build a host, move versions, joiner/leaver, incident, decommission |
| [`UPGRADES.md`](UPGRADES.md) | Record | You are moving the Claude Code version, or asking why the hosts run the version they do. One entry per pin; CI check [9] ties it to the policy |
| [`PUBLISHING.md`](PUBLISHING.md) | Reference | You are publishing the public template edition, or asking what keeps a site's names out of it. The site map, what `bin/cc-publish.sh` refuses, and the CI scan of the public repository |
| [`SETTINGS-REFERENCE.md`](SETTINGS-REFERENCE.md) | Reference | You are about to change a setting. Every key, why it is set, and what breaks if you change it |
| [`SANDBOX-DECISION.md`](SANDBOX-DECISION.md) | Decision record | Before touching any `sandbox.*` key. **Authoritative** |
| [`ADMIN-SESSION.md`](ADMIN-SESSION.md) | Reference | You need a session that can run administrative commands, or you are adding an admin |
| [`IDE-INTEGRATION.md`](IDE-INTEGRATION.md) | Runsheet | Deploying VSCodium with the Claude extension, and pointing it at the pinned CLI rather than the copy the extension bundles |
| [`RUNBOOK.md`](RUNBOOK.md) | Reference | You need to know *why*, or you need the product reference |
| [`LOCAL-VS-AWS.md`](LOCAL-VS-AWS.md) | Register | Planning the move to per-user AWS VDIs |
| [`DOC-STYLE.md`](DOC-STYLE.md) | Reference | You are about to edit any document here — the house rules: taxonomy, front matter, voice, history |
| [`CODING-STANDARD.md`](CODING-STANDARD.md) | Reference | You are about to write or review a script, hook or test — how code here decides, exits, fails, reads its values, and is commented |
| [`REPORTING.md`](REPORTING.md) | Reference | You are reading a weekly report, wiring the metrics file into monitoring, or asking what the version watch does — every rule that can raise an alert, what each verdict means, and what none of them may do |
| [`REPO-MAP.md`](REPO-MAP.md) | Reference | You are about to change the repository itself — the coupling map: what else must change with your change, and whether CI or only discipline holds it |

## `internal/` — the group-only record

Group-only (`2770`), and **not part of the release**. It holds the state register and the
accepted-risk register. It is restricted because an honest register names what is still open on
a site, and a shared checkout is readable by more people than should read that.

The two registers below exist on every site. What else a site keeps there — plans, evidence,
frozen records — is mapped in [`internal/README.md`](../internal/README.md).

| Document | Type | Read it when |
| --- | --- | --- |
| [`CURRENT-STATE.md`](../internal/CURRENT-STATE.md) | Register | **The single authority for live state.** Fleet coverage, host file inventory, the findings register. Read this first, and after any change |
| [`LIMITATIONS-AND-RISKS.md`](../internal/LIMITATIONS-AND-RISKS.md) | Register | What this does not do, and the accepted-risk register |

## Two kinds of background document — do not confuse them

**Decision records** ([`SANDBOX-DECISION.md`](SANDBOX-DECISION.md), the pre-charter decisions held
in [`RUNBOOK.md`](RUNBOOK.md)) are frozen: they tell you what was decided, by whom, and what would
reverse it. **Registers** ([`internal/CURRENT-STATE.md`](../internal/CURRENT-STATE.md),
[`internal/LIMITATIONS-AND-RISKS.md`](../internal/LIMITATIONS-AND-RISKS.md),
[`LOCAL-VS-AWS.md`](LOCAL-VS-AWS.md)) are live: they are maintained in place and are only worth
reading because they are current. A register that has drifted is a defect; a decision record that
has "drifted" is history working as intended.

## Reading orders

- **Day one as the new maintainer:** the repository `README.md` → [`QUICKSTART.md`](QUICKSTART.md) →
  [`internal/CURRENT-STATE.md`](../internal/CURRENT-STATE.md) →
  [`internal/LIMITATIONS-AND-RISKS.md`](../internal/LIMITATIONS-AND-RISKS.md) →
  [`REPORTING.md`](REPORTING.md). The last one belongs in the joining path rather than in
  *on demand*: a governed host reports on itself weekly and unprompted, and someone who has not read
  the contract cannot tell an alert that means "a person owes something" from one that means
  "a check broke" — the two arrive looking identical.
- **Before an audit or a customer claim:** [`internal/CURRENT-STATE.md`](../internal/CURRENT-STATE.md)
  and [`internal/LIMITATIONS-AND-RISKS.md`](../internal/LIMITATIONS-AND-RISKS.md), nothing else first.
- **When a report or an alert arrives:** [`REPORTING.md`](REPORTING.md) for what the rule and the
  verdict mean, then the register the finding cites. Never re-derive the state by hand to check a
  report — that is what the `estate-status` skill reads the *stored* report for.
- **Before changing the policy:** [`SETTINGS-REFERENCE.md`](SETTINGS-REFERENCE.md) for the key;
  [`SANDBOX-DECISION.md`](SANDBOX-DECISION.md) if the key is `sandbox.*`.
- **Before changing the repository itself:** [`REPO-MAP.md`](REPO-MAP.md) for what else must change
  with your change, then [`DOC-STYLE.md`](DOC-STYLE.md) before any document edit.
- **Before editing any document:** [`DOC-STYLE.md`](DOC-STYLE.md).
