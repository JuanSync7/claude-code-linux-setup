"""`install` staged under a scratch root: what it places, what it refuses,
and that a second run finds nothing to do. Nothing here needs root or touches
a system directory."""
import io
import json
import os
import pwd
import shutil
import subprocess
import sys
import unittest

from fleetdash import config as cfgmod
from fleetdash import install
from tests.fixtures import Fleet

ME = pwd.getpwuid(os.getuid()).pw_name


class Staged(unittest.TestCase):
    def setUp(self):
        self.f = Fleet()
        self.t = self.f.root
        self.stage = os.path.join(self.t, "stage")
        self.calls = []

    def tearDown(self):
        self.f.close()

    def config(self, install_over=None, **over):
        t = self.t
        table = {"account": ME, "python": sys.executable, "code_dir": t + "/code",
                 "config_file": t + "/etc/config.json", "units_dir": t + "/units",
                 "ingest_interval": "5min", "prune_calendar": "daily"}
        table.update(install_over or {})
        base = {"port": 8765, "token_file": t + "/var/token", "store": t + "/var/store.db",
                "spool": t + "/spool", "install": table}
        base.update(over)
        return self.f.config(**base)

    def run_install(self, path, apply=False, root=None):
        out, err = io.StringIO(), io.StringIO()
        rc = install.main(cfgmod.load(path), path, apply=apply, root=self.stage if root is None else root,
                          systemctl=lambda *a: self.calls.append(a) or 0, out=out, err=err)
        return rc, out.getvalue(), err.getvalue()

    def staged(self, path):
        return self.stage + path

    def tree(self):
        seen = {}
        for d, dirs, files in os.walk(self.stage):
            for n in dirs + files:
                st = os.lstat(os.path.join(d, n))
                seen[os.path.join(d, n)] = (st.st_mode, st.st_mtime_ns, st.st_ino)
        return seen

    def test_without_apply_the_changes_are_listed_and_nothing_is_written(self):
        rc, out, _ = self.run_install(self.config())
        self.assertEqual(rc, 1)
        self.assertIn("would place %s/code/bin/fleetdash: missing" % self.t, out)
        self.assertFalse(os.path.exists(self.stage))

    def test_apply_places_everything_and_a_second_run_changes_nothing(self):
        path = self.config()
        rc, out, err = self.run_install(path, apply=True)
        self.assertEqual((rc, err), (0, ""))
        before = self.tree()
        self.assertGreater(len(before), 20)
        self.assertEqual(self.run_install(path)[0], 0)
        rc, out, _ = self.run_install(path, apply=True)
        self.assertEqual((rc, out), (0, "0 changed\n"))
        self.assertEqual(self.tree(), before)

    def test_the_modes_are_the_ones_each_path_needs(self):
        self.run_install(self.config(), apply=True)
        mode = lambda p: os.stat(self.staged(self.t + p)).st_mode & 0o7777
        self.assertEqual(mode("/spool"), 0o3733)      # add-only for everyone, read by the account
        self.assertEqual(mode("/var"), 0o700)         # the store and the token
        self.assertEqual(mode("/etc/config.json"), 0o644)
        self.assertEqual(mode("/code/bin/fleetdash"), 0o755)

    def test_every_unit_is_placed_and_names_the_account_and_the_launcher(self):
        self.run_install(self.config(), apply=True)
        placed = sorted(os.listdir(self.staged(self.t + "/units")))
        self.assertEqual(placed, sorted(install.UNITS))
        for name in placed:
            if name.endswith(".service"):
                with open(self.staged(self.t + "/units/" + name)) as fh:
                    lines = fh.read().splitlines()
                self.assertIn("User=%s" % ME, lines, name)
                self.assertEqual([l for l in lines if l.startswith("ExecStart=")][0].split()[0],
                                 "ExecStart=%s/code/bin/fleetdash" % self.t, name)

    def test_a_file_that_drifted_is_named_and_put_back(self):
        path = self.config()
        self.run_install(path, apply=True)
        target = self.staged(self.t + "/code/web/app.js")
        with open(target, "a") as fh:
            fh.write("// edited on the host\n")
        os.chmod(self.staged(self.t + "/spool"), 0o700)
        rc, out, _ = self.run_install(path)
        self.assertEqual(rc, 1)
        self.assertEqual(out.splitlines(), ["would place %s/code/web/app.js: content differs" % self.t,
                                            "would place %s/spool: mode 700, should be 3733" % self.t,
                                            "2 to change"])
        self.assertEqual(self.run_install(path, apply=True)[0], 0)
        self.assertEqual(self.run_install(path)[0], 0)

    def test_under_a_root_systemd_is_not_asked_anything(self):
        self.run_install(self.config(), apply=True)
        self.assertEqual(self.calls, [])

    def test_on_the_real_tree_apply_needs_root_and_writes_nothing(self):
        if os.geteuid() == 0:
            self.skipTest("this run is root, which may write: the refusal cannot be shown")
        rc, _, err = self.run_install(self.config(), apply=True, root="")
        self.assertEqual(rc, 2)
        self.assertIn("must run as root", err)
        self.assertFalse(os.path.exists(self.t + "/code"))
        self.assertEqual(self.calls, [])

    def test_an_empty_install_value_is_refused_by_name(self):
        for key in ("account", "python", "code_dir", "config_file", "units_dir", "ingest_interval", "prune_calendar"):
            with self.subTest(key=key):
                rc, out, err = self.run_install(self.config({key: ""}), apply=True)
                self.assertEqual((rc, out), (1, ""))
                self.assertIn("install.%s is not set" % key, err)
        self.assertFalse(os.path.exists(self.stage))

    def test_a_relative_path_an_unknown_account_or_no_fixed_address_is_refused(self):
        for over, word in ((dict(install_over={"code_dir": "code"}), "install.code_dir"),
                           (dict(store="store.db"), "store"),
                           (dict(install_over={"account": "no-such-account-zz"}), "no-such-account-zz"),
                           (dict(port=0), "fixed port"),
                           (dict(token_file=""), "token_file")):
            with self.subTest(over=over):
                rc, _, err = self.run_install(self.config(**over), apply=True)
                self.assertEqual(rc, 1)
                self.assertIn(word, err)
        self.assertFalse(os.path.exists(self.stage))

    def installed(self):
        """The staged tree moved to the paths it was built for, as it sits on a host."""
        path = self.config()
        self.run_install(path, apply=True)
        for name in ("code", "etc", "units", "var", "spool"):
            shutil.copytree(self.staged(self.t + "/" + name), self.t + "/" + name)
        return self.t + "/code/bin/fleetdash"

    def test_the_installed_launcher_runs_the_installed_code_with_the_installed_config(self):
        launcher = self.installed()
        p = subprocess.run([launcher, "ingest"], stdout=subprocess.PIPE, stderr=subprocess.PIPE, cwd="/")
        self.assertEqual(p.returncode, 0, p.stderr.decode())
        self.assertEqual(json.loads(p.stdout.decode())["skipped"], [])
        self.assertTrue(os.path.exists(self.t + "/var/store.db"))

    def test_systemd_accepts_the_units(self):
        exe = shutil.which("systemd-analyze")
        if not exe:
            self.skipTest("no systemd-analyze on this machine: the units were not checked")
        self.installed()
        p = subprocess.run([exe, "verify"] + sorted(install.UNITS), cwd=self.t + "/units",
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.assertEqual(p.returncode, 0, p.stderr.decode())


if __name__ == "__main__":
    unittest.main()
