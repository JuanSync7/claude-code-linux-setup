---
name: settings-review
description: Run the quarterly Claude Code settings review for this deployment. Use when the user asks to review settings, check for new settings keys, refresh the settings inventory, or asks what settings exist or changed since the pin.
---

You are executing the settings review. The contract is `docs/OPERATIONS.md`
**Part 7, §7.2** (the `settings-review` row); the document you maintain is
`docs/SETTINGS-REFERENCE.md` — §6 is the full-inventory section whose rows you
are refreshing, §5 is the review cadence that sends you here.

Do exactly this:

1. Read `SETTINGS-REFERENCE.md` §6 so you know the current inventory and its
   positions (`SET` / `default` / `decide`) and ▲ flags.
2. Spawn a research subagent against the official Claude Code settings
   documentation for the **pinned** version (the pin is
   `requiredMinimumVersion` in `settings/managed-settings.json`): every key
   that exists, its default, anything newly documented.
3. **Then check the documentation against the binary, because §6 requires it and
   the documentation describes builds ahead of ours.** The vendor documents keys
   that the pinned build silently ignores — the object form of
   `strictPluginOnlyCustomization` is the worked example: documented, and
   rejected by the schema. Read the schema out of the
   installed binary and compare:

   ```bash
   strings -a "$(command -v claude)" | grep -o '<key>[^"]*' | head
   claude doctor            # its schema warnings are the vendor telling you it stripped something
   ```

   A ▲ flag resolved on documentation alone is resolved on the wrong evidence.
   Record which source answered for each key.
4. Diff that against §6. For each delta, edit §6: new keys get a row and a
   *suggested* position with one line of reasoning; retired keys' rows are
   removed; changed defaults are corrected in place (never left beside the old
   value — `docs/DOC-STYLE.md` §7).
5. Keys flagged **decide** are surfaced to the user with your recommendation —
   you never change the policy itself; a decided key graduates to §3 only
   through the §2.1 change procedure, run by a human.
6. `bash bin/cc-ci-check.sh` green, then commit with a subject that reads as
   the changelog entry it is.

Report back with: rows added/removed/corrected, and the `decide` list with
recommendations.
