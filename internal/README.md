# internal/ — the restricted record

This directory is restricted to the maintaining group and is **not part of any release**
(`make dist` excludes it). It is where a site records what is true of its own deployment,
including weaknesses not yet remediated — which is why it is restricted. Run
`bin/cc-repo-perms.sh --apply` after any pull that adds files here.

| File | What it is |
| --- | --- |
| `CURRENT-STATE.md` | What is deployed, where, and what is verified — the state authority |
| `LIMITATIONS-AND-RISKS.md` | Known limitations, the accepted-risk register, and the product behaviours the design depends on |

In this template edition both registers are blank. Add evidence, plans and superseded
documents here as your deployment produces them, and list each one in the table above.
