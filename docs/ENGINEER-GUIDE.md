# Claude Code on managed workstations — the engineer's guide

| | |
| --- | --- |
| **What** | How to use Claude Code on a managed workstation: start a session, get useful work out of it, understand what is blocked and why, and — for those who want it — how to customise it within the rules |
| **Who** | Every engineer who runs `claude` on a managed host. **Part 1 assumes nothing** — not Claude Code, not this deployment. Parts 2 and 3 are for when you want more |
| **When** | Against the pinned build — `requiredMinimumVersion` in the managed policy |
| **Where** | Every host built from this repository. On the host, this guide is at `/usr/local/share/claude-code/ENGINEER-GUIDE.md` |
| **Why** | Every other document in this repository is written for IT. This is the only one written for the person typing into Claude |
| **Status** | In force on every governed host |
| **Owner** | The maintainer |

Read it in a terminal with:

```bash
less /usr/local/share/claude-code/ENGINEER-GUIDE.md
```

**Official material from Anthropic** — read these too, they cover the product itself:

- Claude Code documentation, start here: <https://code.claude.com/docs/en/quickstart>
- Using Claude Code with a Team or Enterprise plan: <https://support.claude.com/en/articles/11845131-using-claude-code-with-your-team-or-enterprise-plan>

---

## Part 1 — The basics (10 minutes)

### 1.1 What Claude Code is

Claude Code is an AI assistant that works **inside your terminal, in your project directory**. You
describe a task in plain English; Claude reads files, runs commands and edits code to do it, and
shows you each step. Think of it as a capable colleague sitting at your keyboard — one who asks
before doing anything risky.

Good first uses:

- *"Read `build.log` and tell me why the run failed."*
- *"Explain what this Makefile target does."*
- *"Find every place the `parse_config` function is called."*
- *"Write a test skeleton for `queue.c`."*

### 1.2 Start your first session

```bash
cd <your-project-directory>
claude
```

1. **Always start Claude in the directory you are working on.** It works on the files around it.
2. **The first time**, Claude asks you to log in. A browser window opens. **Sign in with your
   work account** — not a personal Claude account. Work on the company's projects goes through the company
   account. You log in once; it remembers you.
3. You will see a short **welcome banner** from IT, then a prompt. Type your request and press Enter.

To leave, type `/exit` or press `Ctrl+D` twice.

### 1.3 Working with Claude — the five things to know

| Do this | How | Why |
| --- | --- | --- |
| **Be specific** | *"fix the failing `test_parse_empty` case in `tests/test_config.c`"*, not *"fix the bug"* | Claude can only act on what you tell it |
| **Read before you approve** | When Claude asks *"Do you want to run this?"*, read the command, then pick Yes or No | You are responsible for what runs under your account |
| **Interrupt freely** | Press `Esc` | Stops Claude mid-step; nothing is lost, you can redirect it |
| **Start fresh for a new task** | Type `/clear` | Old context from an unrelated task makes answers worse |
| **Ask Claude about Claude** | *"how do I resume yesterday's session?"*, or type `/help` | It knows its own commands |

### 1.4 What is blocked, and why

This is a **shared machine, and it may hold data that belongs to a customer**. IT sets a policy that you
cannot change, and that Claude cannot change either. When Claude hits a block it tells you —
that is the policy working, not a fault.

| Blocked | Examples | Why |
| --- | --- | --- |
| Becoming root or another user | `sudo`, `su` | Claude acts as you, never as an administrator |
| Installing or changing system software | `dnf`, `yum`, `rpm`, `systemctl`, `firewall-cmd` | The host is built by IT; a change here affects everyone |
| Managing accounts | `useradd`, `usermod`, `passwd` | Same reason |
| Moving data on or off the machine | `curl`, `wget`, `nc`, `ncat`, `ssh`, `scp`, `rsync`, `aws` | Project data — a customer's above all — must not leave by a path nobody approved |
| Reading credentials | `~/.ssh`, `~/.aws`, `~/.gnupg`, `.env` files, `*.pem`, `id_rsa*`, `id_ed25519*` | A leaked key is worse than any bug |
| Editing system files and your login scripts | anything under `/etc`, `/usr`, `/opt`; `~/.bashrc`, `~/.cshrc` and friends | Prevents changes that outlive the session |
| Making a file writable by everyone | `chmod 777` | Exposes project data to every user |
| MCP servers and claude.ai connectors | — | Each one is a new route for data to leave |
| Upgrading Claude itself | `claude update`, `npm install` of Claude | IT tests each version first; the version is pinned |

Some commands are **not blocked but always ask you first**, even in auto mode: `git push`,
`git remote`, `docker`, `podman`.

**Credentials in output are hidden from Claude.** If a command or a file Claude reads prints
something shaped like a key or token, Claude sees `[REDACTED by IT policy: <kind>]` in its place
and is told why. The file or program itself is unchanged. If Claude rewrites a file it read
this way, the marker, not the secret, ends up in the file, so check the diff. A false match (a long
hash that looks like an encoded key) goes to IT support like any other block.

**Blocked by something you genuinely need?** Email IT support (the address is in the welcome
banner) with what you were trying to do. **Do not try to work around a block** — a workaround is
logged too, and it is the thing that turns a support ticket into an incident.

### 1.5 What is recorded

- **Every action Claude takes** — the command it ran, or the file path it edited — is written to a
  log on the host. The *shape* is recorded (which command, which file), **not the contents** of your
  files.
- Each user's log is **private to that user and IT**: your colleagues cannot read it.
- Your conversations are kept for 90 days in your own `~/.claude/` directory, so you can resume
  them. What you type is sent to Claude to be answered, as with any AI service, but the saved
  conversation files are not uploaded or synced anywhere.
- Usage telemetry, error reporting and the `/feedback` command are switched off.

---

## Part 2 — Everyday use (when you are comfortable)

### 2.1 Commands worth knowing

| In your shell | What it does |
| --- | --- |
| `claude` | Start a session here |
| `claude "check the build report"` | Start with a first request already typed |
| `claude -c` | Continue the most recent conversation in this directory |
| `claude -r` | Pick an older conversation to resume |
| `claude -p "summarise build.log"` | One answer, no conversation — handy in scripts |

| Inside a session | What it does |
| --- | --- |
| `/help` | List every command |
| `/clear` | Start a fresh conversation |
| `/compact` | Shrink a long conversation so Claude stays sharp |
| `/model` | See or change the model |
| `/resume` | Switch to an earlier conversation |
| `/init` | Write a `CLAUDE.md` for this project (see 2.3) |
| `Shift+Tab` | Cycle permission modes (see 2.2) |
| `!` then a command | Run a shell command yourself, and let Claude see the output |
| `@` then a file name | Point Claude at a specific file |
| `↑` | Previous prompts |

### 2.2 Permission modes — how much Claude asks

`Shift+Tab` cycles through them; the current mode shows at the bottom of the screen.

| Mode | Behaviour | Use it when |
| --- | --- | --- |
| **Default** | Asks before each command and each edit | You are learning, or the work is sensitive |
| **Accept edits** | Edits files without asking; still asks before commands | You trust the plan and want speed |
| **Plan** | Reads and proposes, changes nothing | You want a plan before anything moves |
| **Auto** | A safety classifier approves routine steps for you | Long tasks you will review afterwards |

Every mode still obeys the blocked list in 1.4 — **no mode lifts a block**. The "bypass
permissions" mode is switched off on these hosts.

### 2.3 Teach Claude about your project — `CLAUDE.md`

A `CLAUDE.md` file in your project directory is read at the start of every session. Put in it what
you would tell a new team member: how to run the flow, where the logs land, naming conventions,
what not to touch. Run `/init` to have Claude draft one, then edit it.

Example:

```markdown
# Project notes for Claude
- Build with `make all`; the report is in `out/report.txt`.
- Source lives in `src/`, tests in `tests/`. Never edit anything under `vendor/`.
- Run `make test` before proposing a change as finished.
```

### 2.4 Customer data — the rule that matters most

Where your projects belong to different customers, work on **one customer project per
session**, started in that project's directory. Do not ask Claude to copy, summarise or compare
material **between** customer projects, and do not paste customer material into any tool other
than this one.

### 2.5 The status line

The line at the bottom of the screen shows, left to right: the model, how full Claude's memory of
this conversation is (`tok:… %`), how much of your usage allowance is used (`5h:` / `7d:`), how long
the session has run (`up:`), your git branch (`*` = uncommitted changes, `?` = untracked files),
your Python environment, and your last pytest result. When the `tok` percentage gets high, use
`/compact` or `/clear`.

---

## Part 3 — Advanced (customising within the rules)

### 3.1 Your own status line

The status line is a shipped default, and you can replace it. Create `~/.claude/statusline.sh`; it
receives a JSON description of the session on standard input, and whatever it prints is shown. The
shipped script is a good starting point:

```bash
cp /usr/local/share/claude-code/statusline.sh ~/.claude/statusline.sh
chmod 600 ~/.claude/statusline.sh
```

It is used only if **you own it and nobody else can write to it** — otherwise a colleague who could
edit it could run commands as you. An empty file hides the status line. Deleting the file brings the
default back. A `statusLine` entry in your own `settings.json` has **no effect** here: the IT policy
sets that key and always wins, which is why the override is a file instead.

### 3.2 What you can and cannot customise

| You can | You cannot |
| --- | --- |
| Your own `~/.claude/settings.json` for preferences: theme, model, editor mode | Add permission rules — only IT's rules load |
| Personal skills in `~/.claude/skills/` and agents in `~/.claude/agents/` | Add hooks — only IT's hooks run |
| A `CLAUDE.md` in each project, and one in `~/.claude/` for yourself | Add MCP servers or claude.ai connectors |
| Your own status line (3.1) | Use bypass-permissions mode, or change the Claude version |

Skills and agents are **instructions**, not privileges: a skill cannot unlock anything the policy
blocks. Treat a skill from someone else like a script from someone else — read it before you use it.

### 3.3 Headless and scripted use

`claude -p "<request>"` answers once and exits, so you can use it in a script or pipe a log into
it:

```bash
tail -200 build.log | claude -p "what is the first real error here?"
```

The same policy, blocks and logging apply. Do not run Claude unattended against a customer project
in a loop you are not watching.

### 3.4 Why your version is pinned

IT tests every Claude Code release against this policy before moving the hosts to it, so
`claude update` is refused and points you at IT. A private install in your home directory still has
to meet the minimum version IT sets; if yours falls below it, it will refuse to start and tell you
so. Use the system `claude`.

### 3.5 Editor (IDE) integration

Use Claude in a terminal next to your editor, unless IT has told you the editor integration is
installed on your host.

### 3.6 Troubleshooting

| Symptom | What to do |
| --- | --- |
| Login: no browser window appears | Check you are in a desktop session (not plain SSH), then ask IT — the browser is set per host |
| *"Permission denied"* or *"blocked by policy"* | That is section 1.4 working. If you need it, email IT support |
| *"This version is below the minimum required"* | You are running a private copy; use the system `claude` (3.4) |
| Answers getting worse in a long session | `/compact`, or `/clear` and restate the task |
| The status line shows nothing | Check `~/.claude/statusline.sh` — an empty or broken one replaces the default |
| Anything else | Ask Claude itself, `/help`, the Anthropic links at the top, then IT support |
