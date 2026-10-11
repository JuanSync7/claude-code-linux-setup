# The goal — what this repository is for, and the rules that rank everything else

| | |
| --- | --- |
| **What** | The top of the repository: the one goal every file here serves, and the ranked rules that decide between two good things when they conflict. It holds no mechanism, command, key, path or number — those have their own homes, and a change to them never touches this file |
| **Who** | Everyone who changes this repository, human or Claude session — read it before the first change. Owners read it when deciding direction |
| **When** | Independent of the pinned build: it changes only when the direction changes |
| **Where** | Every host this repository governs, and the repository itself |
| **Why** | Without a stated top, each document and script optimises its own corner, and conflicts get settled by whoever edits last. This file settles them once, in advance |
| **Status** | **Proposed — awaiting owner sign-off.** The goal is drawn from what the repository already does; the *ranking* of the rules is the open decision |
| **Owner** | The maintainer |

---

## The goal

**Every engineer on a governed host gets a Claude Code that does real work — and IT can show, at
any moment, that customer data and credentials stayed inside the boundaries the company set.**

Both halves bind. A Claude that cannot run a command is not an assistant, so blocking everything
fails the goal. A control nobody can show working is not a control, so trusting it fails the goal
too.

## The rules, in rank order

When two rules pull in different directions, **the higher one wins**, and the trade-off is written
down in `internal/LIMITATIONS-AND-RISKS.md` — never settled silently.

1. **Customer separation and credentials come first.** One customer's material never reaches
   another, and nothing leaves by a path nobody approved. Convenience never outranks this.
2. **Controls live outside the model.** What must hold is enforced by the policy, hooks, file
   permissions and the kernel — never by asking Claude to behave. Assume Claude is sometimes wrong.
3. **Fail closed, and say so.** An unknown is reported as unknown, never as fine. A check that
   examined nothing has failed. No error is swallowed.
4. **Usefulness is a requirement, not a concession.** Every block has a reason an engineer can read
   and a route to ask for an exception. A block with neither gets worked around.
5. **Generic, and deployed per host.** The repository describes any host, never a particular one.
   Site values live in configuration; what is true of each host lives in the state register. Each
   host is governed by its own deliberate install — nothing is pushed to a host behind its back.
6. **The repository is the truth, and a machine checks it.** "Done" means CI is green and the claim
   is verified against the real system. Documents are grounded in code and drift-tested; registers
   say what is true *now*.
7. **Change is deliberate, small and reversible.** The Claude Code version moves only after it is
   tested and recorded. Every change can be rolled back, and one change is one reviewable step.
8. **A junior engineer can run it without asking anyone.** If a procedure needs its author present,
   it is unfinished (`docs/DOC-STYLE.md` §0 makes this mechanical for the documents).

## How to use this file

- **Before a change:** name the rule it serves. If it serves none, ask why it is being made. If it
  bends one, the higher rule wins and the cost goes in the risk register.
- **When a detail is wrong**, fix the detail where it lives. This file changes only when the goal
  or the ranking changes, and that is an owner decision recorded in this file's history.
- **What the deployment deliberately does not do** is in `README.md`, *What it deliberately does
  not do* — not repeated here.

## What would change it

- The company's obligations to customers change (new contract terms, a certification) — rule 1 is
  re-read first.
- The fleet moves to one machine per engineer (`docs/LOCAL-VS-AWS.md`) — rule 5's "per host"
  becomes "per image", and rule 1 gains a boundary from the hardware itself.
- The vendor ships enforcement that makes a hook or a script redundant — rule 2 still holds; only
  where the enforcement lives changes.
