# profile.d/ — login-shell drop-ins

*Directory map — one line per file and where it is documented in full.*

Installed to `/etc/profile.d/`. **Every drop-in ships in both shell variants**
because a login shell may be `tcsh`: a `.sh` file alone reaches nobody
who logs in with it. Changes need a fresh login to take effect — a running shell keeps the
environment it started with.

| File | What it is |
| --- | --- |
| `claude-code-home.sh` / `.csh` | Resolves `HOME` to a real path while the directory publishes a symlink. Only the sandbox needs it (bubblewrap cannot mount through a symlinked parent), and the sandbox is disabled (`docs/SANDBOX-DECISION.md`), so it is inert insurance. [`docs/OPERATIONS.md`](../docs/OPERATIONS.md) §1.6 |
| `claude-code-browser.sh` / `.csh` | Sets `BROWSER` host-wide so OAuth login can open on interactive desktops. [`docs/OPERATIONS.md`](../docs/OPERATIONS.md) §1.7 |
