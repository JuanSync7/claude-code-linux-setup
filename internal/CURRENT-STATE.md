# Current state — Claude Code on this fleet

| | |
| --- | --- |
| **What** | What is deployed on which host, what has been verified, and what is open |
| **Who** | The operators of this deployment |
| **When** | Updated in the same change as anything that alters a host |
| **Where** | Group-only; never in a release |
| **Why** | A claim about the fleet needs one home, with its evidence beside it |
| **Status** | Blank — nothing has been recorded for this site yet |
| **Owner** | The maintainer of this deployment |

---

## 1. Fleet coverage

Not recorded. List each host, whether it is governed, and the evidence (a healthcheck run,
with its date). State the total on a line of its own as `Coverage: N of M`: the weekly report
(`bin/cc-report.sh`) quotes that line.

## 2. Policy identity

Not recorded. The installed policy's checksum per host, and the commit it was installed from.

## 3. Verified working

Not recorded. Each control, how it was verified, and on which host.

## 4. Open findings

None recorded. An empty register means nothing has been looked for yet, not that nothing
is wrong.

## 5. Staged, not applied

Not recorded.
