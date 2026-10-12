# tests/e2e/

The dashboard run the way an operator runs it: nothing here calls the code
under test in-process. A fixture fleet is built on disk, `python3 -m fleetdash`
ingests it as a separate process, `serve` prints its login URL, and the tests
talk to that process over HTTP or through a real browser.

| File | What it covers |
| --- | --- |
| `__init__.py` | Marks the package; empty |
| `harness.py` | `cli()`, the `Server` process (GET and POST), `populated_fleet()`, `full_config()` with documents, two policies and one action, and `render()`: headless Chrome's DOM after the page's own fetches |
| `test_cli.py` | Exit codes (0 clean, 1 bad or skipped input, 2 bad config, old store or a held port), idempotent re-runs, owner-only store, `url`, a feed collected by an ingest, the installer's check mode, the login token as a header and never a cookie, every asset and API the page uses, an action run and its refusals, security headers |
| `test_browser.py` | Every page in the navigation reaches `data-state="ready"` with the right headline, the fleet's own data and no unformatted value; the sidebar's site and freshness on each; document links; the Admin page on a fleet of its own with a privileged session that ended, one with no end and a refusal, a seat nobody uses, a refused file and a row past its age; the Logs page on a fleet with stopped calls, each opening onto what was asked for, shown as text, with what is not kept said to be not recorded; unknown routes; no figure without the token, and the token gone from the address once the page has it |

```bash
make e2e                                   # these tests alone
FLEETDASH_BROWSER=chromium make e2e        # a named browser, by name or path
FLEETDASH_BROWSER=none make e2e            # skip the browser tests on purpose
```

With no browser found and `FLEETDASH_BROWSER` unset, the browser tests **fail**:
a suite that silently ran nothing would read as a pass. Chrome runs with
`--password-store=basic` (otherwise it waits about 25 s per page on a desktop
keyring) and with `--no-sandbox` only as root, as in the CI container.
