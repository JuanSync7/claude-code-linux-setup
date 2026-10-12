"""A policy change drafted on the page: a patch against the repository's
policy file that git applies, that says nothing the Policy page does not
already show, and that the server itself never applies."""
import hashlib
import json
import os
import shutil
import subprocess
import threading
import unittest
import unittest.mock
import urllib.error
import urllib.parse
import urllib.request

from fleetdash import draft, server
from fleetdash import config as cfgmod
from tests.fixtures import Fleet

# laid out by hand, as the real file is: writing it back from parsed JSON would change every line
POLICY = """{
  "_comment": "spaced   by hand",
  "env": {"HTTPS_PROXY": "http://proxy.invalid:1"},
  "permissions": {
    "deny": [
      "Bash(sudo:*)",
      "Bash(curl:*)",
      "Bash(wget:*)",
      "Bash(nc:*)",
      "Bash(ssh:*)"
    ],
    "ask": [
      "Bash(git push:*)"
    ],
    "additionalDirectories": ["/site/secret-dir"]
  },
  "sandbox": {"enabled": true}
}
"""
# what the Policy page never shows, so a patch must not either
HIDDEN = ("proxy.invalid", "secret-dir")
REL = os.path.join("settings", "managed-settings.json")


def edit(op, kind, rule):
    return {"op": op, "list": kind, "rule": rule}


class Drafting(unittest.TestCase):
    def setUp(self):
        self.f = Fleet()
        self.repo = os.path.join(self.f.root, "repo")
        self.path = os.path.join(self.repo, REL)
        os.makedirs(os.path.dirname(self.path))
        os.mkdir(os.path.join(self.repo, ".git"))  # what marks the top of a checkout
        self.write(POLICY)
        self.cfg = self.config(self.path)

    def tearDown(self):
        self.f.close()

    def config(self, source):
        return cfgmod.load(self.f.config(policy={"deployed": "", "source": source}))

    def write(self, text, path=None):
        with open(path or self.path, "w", newline="") as fh:
            fh.write(text)

    def applied(self, out, text=POLICY):
        """What the file holds after git applies the patch to a checkout of its
        own, with the command the page tells the reader to run."""
        git = shutil.which("git")
        self.assertIsNotNone(git, "git is needed to prove a drafted patch applies")
        work = os.path.join(self.f.root, "apply-%d" % len(os.listdir(self.f.root)))
        os.makedirs(os.path.join(work, os.path.dirname(out["file"])))
        subprocess.run([git, "init", "-q", work], check=True, stdout=subprocess.DEVNULL)
        self.write(text, os.path.join(work, out["file"]))
        self.write(out["patch"], os.path.join(work, "change.patch"))
        self.assertEqual(out["apply"][0], "git")
        p = subprocess.run([git] + out["apply"][1:] + ["change.patch"], cwd=work,
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        self.assertEqual(p.returncode, 0, p.stdout.decode() + out["patch"])
        with open(os.path.join(work, out["file"]), newline="") as fh:
            return fh.read()

    def rules(self, text, kind):
        return json.loads(text)["permissions"].get(kind)

    def draft(self, *edits, **kw):
        out = draft.patch(kw.get("cfg", self.cfg), list(edits))
        for word in HIDDEN:
            self.assertNotIn(word, out["patch"])
        return out

    def test_an_added_rule_goes_last_in_its_list_and_no_other_line_changes(self):
        out = self.draft(edit("add", "deny", "Bash(dd:*)"))
        self.assertEqual((out["file"], out["in_repository"]), (REL, True))
        new = self.applied(out)
        self.assertEqual(new, POLICY.replace('      "Bash(ssh:*)"\n', '      "Bash(ssh:*)",\n      "Bash(dd:*)"\n'))

    def test_a_removed_rule_leaves_valid_json_wherever_it_stood(self):
        for rule, left in (("Bash(sudo:*)", 4), ("Bash(wget:*)", 4), ("Bash(ssh:*)", 4)):
            with self.subTest(rule=rule):
                new = self.applied(self.draft(edit("remove", "deny", rule)))
                self.assertNotIn(rule, self.rules(new, "deny"))
                self.assertEqual(len(self.rules(new, "deny")), left)
                self.assertEqual(len(new.splitlines()), len(POLICY.splitlines()) - 1)

    def test_removing_every_rule_leaves_an_empty_list(self):
        new = self.applied(self.draft(edit("remove", "ask", "Bash(git push:*)")))
        self.assertEqual(self.rules(new, "ask"), [])

    def test_a_rule_for_a_list_the_file_does_not_have_adds_that_list(self):
        new = self.applied(self.draft(edit("add", "allow", "Read")))
        self.assertEqual((self.rules(new, "allow"), self.rules(new, "deny")),
                         (["Read"], self.rules(POLICY, "deny")))
        # every line that was there is still there, as it was
        self.assertEqual([l for l in new.splitlines() if l in POLICY.splitlines()], POLICY.splitlines())

    def test_several_changes_in_one_draft_all_land(self):
        new = self.applied(self.draft(edit("remove", "deny", "Bash(nc:*)"), edit("remove", "deny", "Bash(ssh:*)"),
                                      edit("add", "deny", "Bash(dd:*)"), edit("add", "ask", "Bash(rm:*)"),
                                      edit("add", "allow", "Read"), edit("add", "allow", "Glob")))
        self.assertEqual((self.rules(new, "deny"), self.rules(new, "ask"), self.rules(new, "allow")),
                         (["Bash(sudo:*)", "Bash(curl:*)", "Bash(wget:*)", "Bash(dd:*)"],
                          ["Bash(git push:*)", "Bash(rm:*)"], ["Read", "Glob"]))
        self.assertEqual({k: v for k, v in json.loads(new).items() if k != "permissions"},
                         {k: v for k, v in json.loads(POLICY).items() if k != "permissions"})

    def test_a_rule_with_quotes_a_backslash_or_another_alphabet_is_written_as_json(self):
        for rule in ('Bash(echo "x":*)', "Bash(a\\b)", "Bash(café ✓)"):
            with self.subTest(rule=rule):
                self.assertEqual(self.rules(self.applied(self.draft(edit("add", "ask", rule))), "ask")[-1], rule)

    def test_a_patch_shows_lines_of_the_lists_it_changes_and_of_nothing_else(self):
        # the ask list ends one line above a setting the Policy page does not show
        out = self.draft(edit("remove", "ask", "Bash(git push:*)"))
        self.assertNotIn("additionalDirectories", out["patch"])
        self.assertNotIn("Bash(ssh:*)", out["patch"])
        # in the middle of a long list there is room for the usual three lines either side
        mid = self.draft(edit("remove", "deny", "Bash(wget:*)"))
        self.assertEqual((mid["context"], mid["apply"]), (3, ["git", "apply"]))
        self.assertIn(' "Bash(sudo:*)",', mid["patch"].replace("      ", ""))

    def test_a_patch_with_no_line_of_context_says_how_to_apply_it(self):
        out = self.draft(edit("add", "allow", "Read"))
        self.assertEqual((out["context"], out["apply"]), (0, ["git", "apply", "--unidiff-zero"]))

    def test_the_patch_says_what_it_was_drafted_from_and_what_it_changes(self):
        out = self.draft(edit("add", "deny", "Bash(dd:*)"), edit("remove", "ask", "Bash(git push:*)"))
        base = hashlib.sha256(POLICY.encode()).hexdigest()
        self.assertEqual(out["base_sha256"], base)
        head = out["patch"][:out["patch"].index("--- a/")]
        self.assertIn(base, head)
        self.assertIn("add to deny: Bash(dd:*)", head)
        self.assertIn("remove from ask: Bash(git push:*)", head)

    def test_drafting_writes_nothing_and_the_same_draft_is_the_same_patch(self):
        before = sorted(os.listdir(os.path.dirname(self.path)))
        first = self.draft(edit("add", "deny", "Bash(dd:*)"))
        self.assertEqual(self.draft(edit("add", "deny", "Bash(dd:*)")), first)
        with open(self.path) as fh:
            self.assertEqual(fh.read(), POLICY)
        self.assertEqual(sorted(os.listdir(os.path.dirname(self.path))), before)

    def test_a_file_outside_a_checkout_is_named_by_its_file_name(self):
        loose = os.path.join(self.f.root, "loose", "managed-settings.json")
        os.makedirs(os.path.dirname(loose))
        self.write(POLICY, loose)
        out = self.draft(edit("add", "deny", "Bash(dd:*)"), cfg=self.config(loose))
        self.assertEqual((out["file"], out["in_repository"]), ("managed-settings.json", False))
        self.assertIn("Bash(dd:*)", self.rules(self.applied(out), "deny"))

    def refused(self, edits, cfg=None):
        with self.assertRaises(draft.Refused) as caught:
            draft.patch(cfg or self.cfg, edits)
        return str(caught.exception)

    def test_a_draft_that_is_not_a_list_of_whole_changes_is_refused(self):
        good = edit("add", "deny", "Bash(dd:*)")
        for bad in (None, {}, "add", [], [None], [["add", "deny", "x"]], [dict(good, extra=1)], [{"op": "add", "list": "deny"}],
                    [dict(good, op="replace")], [dict(good, list="hooks")], [dict(good, list="additionalDirectories")],
                    [dict(good, rule="")], [dict(good, rule=7)], [dict(good, rule="two\nlines")], [dict(good, rule="tab\there")],
                    [dict(good, rule="\x1b[31m")], [dict(good, rule=" padded ")], [dict(good, rule="x" * (draft.RULE_MAX + 1))],
                    [dict(good, rule="\ud800")], [edit("add", "deny", "r%d" % i) for i in range(draft.EDITS_MAX + 1)]):
            with self.subTest(bad=repr(bad)[:60]):
                self.refused(bad)
        # the limits themselves are allowed
        draft.patch(self.cfg, [dict(good, rule="x" * draft.RULE_MAX)])
        draft.patch(self.cfg, [edit("add", "deny", "r%d" % i) for i in range(draft.EDITS_MAX)])

    def test_a_change_that_would_change_nothing_or_contradicts_another_is_refused(self):
        self.assertIn("already", self.refused([edit("add", "deny", "Bash(sudo:*)")]))
        self.assertIn("not in", self.refused([edit("remove", "deny", "Bash(dd:*)")]))
        self.assertIn("not in", self.refused([edit("remove", "allow", "Read")]))
        # in another list is not in this one
        self.assertIn("not in", self.refused([edit("remove", "ask", "Bash(sudo:*)")]))
        self.refused([edit("add", "deny", "Bash(dd:*)")] * 2)
        self.refused([edit("add", "deny", "Bash(dd:*)"), edit("remove", "deny", "Bash(dd:*)")])
        self.refused([edit("remove", "deny", "Bash(sudo:*)")] * 2)

    def test_a_change_of_an_unknown_kind_is_refused_as_that_whatever_rule_it_names(self):
        # one that names a rule that is there must not be taken for a removal
        self.assertIn("a change is one of", self.refused([edit("replace", "deny", "Bash(sudo:*)")]))
        self.assertIn("a change is one of", self.refused([edit("add", "hooks", "Bash(dd:*)")]))

    def test_a_rule_that_stays_is_left_as_it_is_written(self):
        text = POLICY.replace('"Bash(curl:*)"', '"Read(~\\/.ssh\\/**)"')
        self.assertIn('"Read(~\\/.ssh\\/**)"', text)
        self.write(text)
        out = self.draft(edit("remove", "deny", "Bash(sudo:*)"), edit("add", "deny", "Bash(dd:*)"))
        self.assertIn('      "Read(~\\/.ssh\\/**)",\n', self.applied(out, text))

    def test_a_result_that_is_not_the_document_asked_for_gives_no_patch(self):
        # the text is written into the wrong list, as a fault in finding the lists would
        found = draft._span

        def swapped(text, i):
            start, end, members = found(text, i)
            if isinstance(members, dict) and "deny" in members:
                members = dict(members, deny=members["ask"], ask=members["deny"])
            return start, end, members
        with unittest.mock.patch.object(draft, "_span", swapped):
            self.assertIn("could not be written", self.refused([edit("add", "deny", "Bash(dd:*)")]))

    def test_with_no_repository_policy_to_draft_against_it_says_so(self):
        self.assertIn("policy.source", self.refused([edit("add", "deny", "x")], self.config("")))
        self.assertIn("policy.source", self.refused([edit("add", "deny", "x")],
                                                    self.config(os.path.join(self.f.root, "nowhere.json"))))
        for text in ("not json", "[]", '{"permissions": {}}\n', '{"permissions": []}\n', '{"permissions": {"deny": "all"}}\n', '{"sandbox": {}}\n'):
            with self.subTest(text=text):
                self.write(text)
                self.refused([edit("add", "deny", "x")])

    def test_a_layout_that_puts_another_setting_on_a_rules_line_is_refused_not_shown(self):
        one_line = json.dumps(json.loads(POLICY)) + "\n"
        shared = POLICY.replace('    "ask": [\n      "Bash(git push:*)"\n    ],\n    "additionalDirectories"',
                                '    "ask": ["Bash(git push:*)"], "additionalDirectories"')
        self.assertEqual(json.loads(shared), json.loads(POLICY))
        for text in (one_line, shared):
            with self.subTest(text=text[:40]):
                self.write(text)
                self.assertIn("by hand", self.refused([edit("remove", "ask", "Bash(git push:*)")]))
        # a list untouched by the draft may be laid out however it is
        self.write(shared)
        self.assertIn("Bash(dd:*)", self.rules(self.applied(self.draft(edit("add", "deny", "Bash(dd:*)")), shared), "deny"))

    def test_a_file_that_does_not_end_with_a_newline_is_refused(self):
        self.write(POLICY.rstrip("\n"))
        self.refused([edit("add", "deny", "Bash(dd:*)")])

    def test_rules_written_several_to_a_line_still_give_a_patch_that_applies(self):
        text = POLICY.replace('      "Bash(sudo:*)",\n      "Bash(curl:*)",\n', '      "Bash(sudo:*)", "Bash(curl:*)",\n')
        self.write(text)
        new = self.applied(self.draft(edit("remove", "deny", "Bash(curl:*)"), edit("add", "deny", "Bash(dd:*)")), text)
        self.assertEqual(self.rules(new, "deny"), ["Bash(sudo:*)", "Bash(wget:*)", "Bash(nc:*)", "Bash(ssh:*)", "Bash(dd:*)"])

    def test_an_empty_list_takes_its_first_rule(self):
        text = POLICY.replace('    "ask": [\n      "Bash(git push:*)"\n    ],\n', '    "ask": [],\n')
        self.write(text)
        self.assertEqual(self.rules(self.applied(self.draft(edit("add", "ask", "Bash(rm:*)")), text), "ask"), ["Bash(rm:*)"])


class DraftEndpoint(unittest.TestCase):
    def setUp(self):
        self.f = Fleet()
        path = os.path.join(self.f.root, "managed-settings.json")
        with open(path, "w") as fh:
            fh.write(POLICY)
        self.httpd = server.make_server(cfgmod.load(self.f.config(policy={"deployed": "", "source": path})))
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()

    def tearDown(self):
        self.httpd.shutdown()
        self.httpd.server_close()
        self.f.close()

    def get(self, query, token=None):
        req = urllib.request.Request("http://127.0.0.1:%d/api/policy-draft%s" % (self.httpd.server_address[1], query),
                                     headers={"X-Fleetdash-Token": self.httpd.token if token is None else token})
        try:
            with urllib.request.urlopen(req, timeout=10) as r:
                return r.status, json.loads(r.read().decode())
        except urllib.error.HTTPError as e:
            return e.code, json.loads(e.read().decode())

    def edits(self, *edits):
        return "?edits=" + urllib.parse.quote(json.dumps(list(edits)))

    def test_a_logged_in_page_gets_the_patch(self):
        status, out = self.get(self.edits(edit("add", "deny", "Bash(dd:*)")))
        self.assertEqual((status, sorted(out)), (200, ["apply", "base_sha256", "context", "edits", "file", "in_repository", "patch"]))
        self.assertIn('+      "Bash(dd:*)"\n', out["patch"])

    def test_a_draft_it_cannot_make_is_a_400_that_says_why(self):
        for query in ("", "?edits=", "?edits=nonsense", self.edits(), self.edits(edit("add", "deny", "Bash(sudo:*)")),
                      "?edits=" + "[" * 5000):
            with self.subTest(query=query[:30]):
                status, out = self.get(query)
                self.assertEqual((status, sorted(out)), (400, ["error"]))
        self.assertIn("already", self.get(self.edits(edit("add", "deny", "Bash(sudo:*)")))[1]["error"])

    def test_it_is_not_served_without_the_token(self):
        self.assertEqual(self.get(self.edits(edit("add", "deny", "Bash(dd:*)")), token="wrong")[0], 403)


if __name__ == "__main__":
    unittest.main()
