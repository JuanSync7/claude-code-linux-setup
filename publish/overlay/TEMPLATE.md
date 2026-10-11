# This is a template — fill it before you install it

This repository is the public, site-neutral edition. It deploys a governed Claude Code
fleet on Linux, and a handful of values in it can only come from your site. Each one is a
`REPLACE-WITH-*` placeholder. Nothing else needs to change to get a first host governed.

**The installer refuses this tree as it stands.** `make quickstart` and
`bin/cc-install.sh` stop at the first placeholder they find in the policy, so a half-filled
template cannot reach a host.

## The placeholders

`template.json`, beside this file, is the list: each name under `placeholders`, with its
`meaning` — what to replace it with — and an `example` of the form the value takes. It is the one place they are listed — CI reads the
same file, so the list you read is the list that is enforced.

## Filling it

1. Find every use: `git grep -n REPLACE-WITH-`
2. Replace each placeholder with your value, in every file that carries it.
3. Create your site config: `make config`, then edit `config.sh` (it is gitignored).
4. Delete `template.json` and this file, and commit.
5. Run `bash bin/cc-ci-check.sh`. With `template.json` gone the checks are strict: no
   placeholder may remain in the policy.

Until step 4, CI accepts the placeholders `template.json` lists and no others, and it fails
if the file lists one that no other file uses — so the list stays true while you work
through it. CI and the test suite do not run on this tree directly: they run on a copy that
`bin/cc-template-fill.sh` fills with the examples, because the installer would refuse
anything else.

## What else is yours to write

`internal/` holds three blank registers: the state of your deployment, your limitations and
accepted risks, and a map of the directory. They are the record this tooling expects you to
keep; restrict the directory (`bin/cc-repo-perms.sh --apply`) before you write a weakness
into it.
