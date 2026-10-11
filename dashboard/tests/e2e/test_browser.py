"""Every page rendered in a real headless browser, through the same login a
person uses: the printed URL, the cookie, the hash route, the page's own
fetches under its Content-Security-Policy."""
import unittest

from tests.e2e.harness import Server, browser, cli, populated_fleet, render


class EveryPageRenders(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        browser()  # fail (or skip on purpose) before building anything
        cls.f = populated_fleet()
        config = cls.f.config()
        cli(config, "ingest")
        cls.srv = Server(config)
        cls.home = render(cls.srv.url)

    @classmethod
    def tearDownClass(cls):
        cls.srv.stop()
        cls.f.close()

    def pages(self):
        self.assertGreaterEqual(len(self.home.nav), 4, self.home.nav)  # a pass over no pages is a failure
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

    def test_each_page_shows_the_fleets_people(self):
        for page, _ in self.pages():
            with self.subTest(page=page):
                text = render(self.srv.url + "#/" + page).main_text
                self.assertIn("alice", text)

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

    def test_without_the_token_the_browser_gets_no_app(self):
        p = render(self.srv.base + "/")
        self.assertEqual(p.main, {})
        self.assertIn("Open the URL printed", p.dom)


if __name__ == "__main__":
    unittest.main()
