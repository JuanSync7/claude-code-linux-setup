# Coding standard — how the scripts, hooks and tests here are written

| | |
| --- | --- |
| **What** | The rules every script, hook and test in this repository follows: how code decides, what it exits with, how it fails, where its values live, what a second run does, and what a comment is for |
| **Who** | Anyone writing or reviewing code here — a person or a Claude Code session. Shell and Python are assumed; nothing about this deployment is |
| **When** | Before writing a new script, and when reviewing a change to an existing one |
| **Where** | `bin/`, `hooks/`, `githooks/`, `lib/`, `share/`, `profile.d/`, `dashboard/` and `tests/`. Documents follow [`DOC-STYLE.md`](DOC-STYLE.md) instead |
| **Why** | These scripts run as root on shared hosts and are operated by whoever is on call. A script that guesses, exits without saying why, or behaves differently on its second run costs that person the time this repository exists to save |
| **Status** | In force for new and changed code. Existing code is brought in line when it is next touched, not by a rewrite |
| **Owner** | The maintainer |

---

## 1. Decide from structure, not from text

Do not decide what happened by searching text for a word — the output of a command, an error
message, a table in a document. A reworded message then breaks the check, or worse, lets it
pass while testing nothing. Use, in this order of preference:

| Instead of matching text, use | Example here |
| --- | --- |
| The **exit code** of the command | A test asserts `cc-install.sh` exited `1`; it does not search for "REFUSED" |
| **Structured data**, parsed by a parser | The placeholder list is the keys of `template.json`, read with `json.load` — not a markdown table |
| A **differential run** — two inputs that differ by one thing | CI check [6] stages a template unfilled (must fail) and filled (must pass); the difference is the cause |
| The **filesystem or git index** | "Is this a template edition?" is `git ls-files --error-unmatch template.json` |

Pattern matching (`grep`, `sed`, `awk`, `=~`, Python `re`) is the last resort, for when none
of the four can answer. Two cases are legitimate, and each says so in a comment where it is used:

- **The job is to find text.** The secret guard and the publish deny scan search file contents
  because that is what they are for.
- **The input belongs to someone else and has no structured form** — a vendor tool that prints
  only prose.

In a test, assert the exit code on a fixture that isolates one cause. Assert message text only
when the message itself is the contract (a usage line an operator reads).

## 2. Exit codes are a documented table

| Code | Meaning in every script here |
| --- | --- |
| `0` | It did what was asked, or there was nothing to do |
| `1` | It ran, and the answer is no: the condition it exists to detect was found, or it refused to act |
| `2` | It could not run: wrong arguments, missing configuration, not the right user or place |

A script may define further codes when a caller must tell two outcomes apart. Every code a
script can exit with — these three included — is listed in a table in its header comment,
under the heading `Exit codes`, in words a junior engineer can act on, and again in the
document that owns the script. A code that is not in the table is a defect.

## 3. Every failure is handled, and fails closed

- Check every command that can fail. `cmd || refuse "what failed, and what is now true"`.
- A failure stops the script unless the code says, in a comment, why continuing is safe.
- Errors go to stderr, prefixed with the script's name. Never `2>/dev/null` an error the
  operator would need; discard output only where the exit code is the whole answer.
- When a step fails part-way, undo what this run created, or say exactly what was left behind.
- "Not known" is never reported as zero, empty, or a pass. A check that examined nothing fails.

## 4. Values live in the config, not in the code

The test: **if someone else decided it, or you could `grep` for it to change it, it is
configuration.** Paths, hosts, names, addresses, limits, intervals and retention counts go in
`config.sh`, read through `lib/cc-config.sh`; `config.example.sh` is the one place suggested
values are written down. Secrets and site values stay in that one file, which is gitignored.

Whether a value may have a fallback in the code depends on what a wrong value would do:

| Kind of value | In-code default? | When it is unset |
| --- | --- | --- |
| A **secret**, a **host**, or the **path of a live store** (logs, policy, homes, a package source) | **Never.** A default would point the program at the wrong place | The script stops with exit `2` and names the key that is not set and the file to set it in |
| A **tunable** whose wrong value is harmless (a display width, a suffix for a throwaway test value) | Allowed, as a named constant at the top of the script, with a comment saying what it is and that it is a default | The default is used |

Every key `lib/cc-config.sh` knows is of the first kind today, which is why the loader carries
no defaults and CI check [7] holds its key lists to `config.example.sh`. A script that reports
a configuration problem ends the message with where to change it — the config file's path.

Do not add a key that nothing reads.

## 5. A second run changes nothing

Every script is idempotent: run twice with the same input, the second run makes no change and
says so. Concretely: test before you write, create only what is absent, replace whole files
rather than append to them, and never leave a half-written result under the final name.
A script that cannot be made idempotent refuses to run a second time and says why.

## 6. Comments explain the code, not the change

A comment tells the next engineer what the code does and why it is this way — the constraint
it works around, the case a branch exists for. It is true for as long as the code is unchanged.
What was changed, when, and by whom is the commit message; a comment that says "moved from",
"now uses" or carries a date is history, and belongs there.

## 7. Every path ends on purpose

Each path through a script ends with an explicit `exit` and a line saying what happened —
success included. No branch falls off the end of the file, and no `case` lacks a default
that names the unexpected value. Someone reading only the last line of output must be able to
tell which path ran.

## 8. What holds these rules

| Rule | Held by |
| --- | --- |
| A script has cases in the suite | `bin/cc-ci-check.sh` [10], and the suite's own coverage verdict |
| No defaults in the config loader | `bin/cc-ci-check.sh` [7] |
| A test can fail | Discipline: break the code on purpose and watch the case fail before trusting it |
| Everything else on this page | Discipline, and review |
