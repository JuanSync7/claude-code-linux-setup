"""Every page rendered in a real headless browser, through the same login a
person uses: the printed URL, the token the page takes from it, the hash
route, the page's own fetches under its Content-Security-Policy."""
import unittest

from tests.e2e.harness import Server, browser, cli, full_config, populated_fleet, render


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
        self.assertGreaterEqual(len(self.home.nav), 8, self.home.nav)  # a pass over no pages is a failure
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
             "hosts": "test-host", "policy": "Bash(sudo:*)", "docs": "Operator guide", "update": "Say hello"}

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

    def test_a_document_is_rendered_as_elements_and_its_markup_stays_text(self):
        p = render(self.srv.url + "#/docs")
        self.assertIn("<h2>Operator guide</h2>", p.dom)
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
        self.assertIn("<h2>The other page</h2>", other.dom)
        self.assertIn('<a href="#/docs/0%3AGuide.md">the guide</a>', other.dom)
        # a document in another group of the list, reached by its place on disk
        self.assertIn('<a href="#/docs/1%3AGOAL.md">the goal</a>', other.dom)

    def test_update_lists_the_configured_command_and_shows_a_runs_output(self):
        p = render(self.srv.url + "#/update")
        self.assertIn("Prints one line and changes nothing.", p.main_text)
        key = self.srv.json("/api/actions")["run_key"]
        self.assertEqual(self.srv.post("/api/run", {"id": "say-hello"}, {"X-Fleetdash-Run": key})[0], 200)
        p = render(self.srv.url + "#/update")
        self.assertIn("hello from the action", p.main_text)
        self.assertIn('<span class="sev pass">exit code 0</span>', p.dom)

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


if __name__ == "__main__":
    unittest.main()
