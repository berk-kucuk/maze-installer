"""
Tests for the Calamares job module that drives deploy-to-target.sh
(usr/lib/calamares/modules/mazedeploy/main.py).

Calamares is not needed: a stand-in `libcalamares` records what the module
reports (progress, status text, log lines), and the module runs the REAL
deploy-to-target.sh against a fake target with a few fake steps — so what is
checked is the whole path from a step's output to what the user sees.

    python -m unittest discover -s tests -v
"""
import importlib.util
import os
import shutil
import sys
import tempfile
import types
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MODULE = ROOT / "maze-installer" / "usr" / "lib" / "calamares" / "modules" / "mazedeploy" / "main.py"
DRIVER = ROOT / "maze-installer" / "usr" / "share" / "maze" / "install" / "deploy-to-target.sh"


def fake_libcalamares(root, languages=("en",)):
    lc = types.ModuleType("libcalamares")
    lc.progress, lc.statuses, lc.debug, lc.warnings, lc.gs = [], [], [], [], {"rootMountPoint": root}
    mod = None

    def setprogress(p):
        lc.progress.append(p)
        lc.statuses.append(mod.pretty_status_message())

    lc.job = types.SimpleNamespace(setprogress=setprogress, configuration={"script": str(DRIVER)})
    lc.utils = types.SimpleNamespace(debug=lc.debug.append, warning=lc.warnings.append,
                                     gettext_languages=lambda: list(languages))
    lc.globalstorage = types.SimpleNamespace(value=lc.gs.get, insert=lc.gs.__setitem__)

    def load():
        nonlocal mod
        sys.modules["libcalamares"] = lc
        sys.dont_write_bytecode = True   # keep __pycache__ out of the package tree
        spec = importlib.util.spec_from_file_location("mazedeploy_main", MODULE)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        return mod
    return lc, load


class TestMazeDeployModule(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="maze-module-test-"))
        self.target = self.tmp / "target"
        (self.target / "var/log").mkdir(parents=True)
        self.steps = self.tmp / "steps"
        self.steps.mkdir()
        # Only the libraries' bare minimum: the real 00-setup/10-helpers pull
        # in arch-chroot; these tests are about the module, not the steps.
        (self.steps / "00-setup.sh").write_text(
            "# @library\nTARGET=\"${1%/}\"\nSECURITY_CSV=\"${2:-}\"\n")
        (self.steps / "10-helpers.sh").write_text(
            "# @library\n"
            "log()  { printf '[maze-deploy] %s\\n' \"$*\"; }\n"
            "warn() { printf '[maze-deploy] WARNING: %s\\n' \"$*\" >&2;"
            " printf '[%s] %s\\n' \"$MAZE_STEP\" \"$*\" >> \"${MAZE_WARN_FILE:-/dev/null}\"; }\n"
            "critical() { printf '[maze-deploy] CRITICAL: %s\\n' \"$*\" >&2;"
            " printf '[%s] %s\\n' \"$MAZE_STEP\" \"$*\" >> \"${MAZE_CRITICAL_FILE:-/dev/null}\"; }\n")
        os.environ["MAZE_STEP_DIR"] = str(self.steps)

    def tearDown(self):
        os.environ.pop("MAZE_STEP_DIR", None)
        sys.modules.pop("libcalamares", None)
        shutil.rmtree(self.tmp, ignore_errors=True)

    def step(self, name, body, title="Step", title_tr="Adım", weight=1, timeout=60):
        (self.steps / f"{name}.sh").write_text(
            f"# @title {title}\n# @title.tr {title_tr}\n# @timeout {timeout}\n# @weight {weight}\n{body}")

    def test_success_reports_every_step_and_ends_full(self):
        self.step("20-one", 'log "doing the first thing"\n', title="First thing")
        self.step("30-two", 'warn "a small problem"\n', title="Second thing", weight=3)
        lc, load = fake_libcalamares(str(self.target))
        self.assertIsNone(load().run())
        self.assertEqual(lc.progress[-1], 1.0)
        self.assertEqual(lc.progress, sorted(lc.progress), "progress went backwards")
        self.assertTrue(any(s.startswith("[1/2] First thing") for s in lc.statuses), lc.statuses)
        self.assertTrue(any(s.startswith("[2/2] Second thing") for s in lc.statuses), lc.statuses)
        self.assertTrue(any("[maze:20-one] [maze-deploy] doing the first thing" in d for d in lc.debug))
        self.assertIn("a small problem", lc.gs["mazeDeploySummary"])
        self.assertTrue((self.target / "var/log/maze-installer/steps/20-one.log").exists())

    def test_failed_step_names_the_step_and_fails_the_job(self):
        self.step("20-bad", 'echo "$NOT_SET"\n', title="Broken thing", title_tr="Bozuk iş")
        self.step("30-good", 'log "still ran"\n', title="Good thing")
        lc, load = fake_libcalamares(str(self.target), languages=("tr_TR", "tr"))
        res = load().run()
        self.assertIsInstance(res, tuple)
        self.assertIn("KULLANILAMAZ", res[0])
        self.assertIn("• Bozuk iş — hata vererek durdu", res[1])
        self.assertIn("/var/log/maze-installer/", res[1])
        self.assertIn("sudo env MAZE_DEPLOY_STEPS=20-bad ", res[1])
        self.assertIn(str(self.target), res[1])
        self.assertTrue(any("still ran" in d for d in lc.debug))

    def test_critical_problem_fails_the_job(self):
        self.step("20-crit", 'critical "root can log in without a password"\n', title="Root lock")
        lc, load = fake_libcalamares(str(self.target))
        res = load().run()
        self.assertIsInstance(res, tuple)
        self.assertIn("Root lock — found a critical problem", res[1])
        self.assertIn("root can log in without a password", res[1])

    def test_status_shows_what_the_step_says_it_is_doing(self):
        self.step("20-slow", 'log "Installing AUR packages: paru"\nsleep 1.2\nlog "done"\n',
                  title="AUR applications")
        lc, load = fake_libcalamares(str(self.target))
        self.assertIsNone(load().run())
        self.assertTrue(any("AUR applications — Installing AUR packages: paru" in s for s in lc.statuses),
                        lc.statuses)

    PROBE = 'log "options=[${MAZE_OPTIONS-unset}] security=[$2]"\n'

    def ops(self, *names, source="netinstall@mazeoptions"):
        return [{"source": source, "try_install": list(names)},
                {"source": "netinstall@other", "try_install": ["opt-sshd", "firefox"]}]

    def test_options_page_reaches_the_steps(self):
        self.step("20-probe", self.PROBE)
        lc, load = fake_libcalamares(str(self.target))
        lc.gs["packageOperations"] = self.ops("opt-page-seen", "opt-tor", "opt-apparmor", "opt-clamav")
        self.assertIsNone(load().run())
        self.assertTrue(any("options=[opt-apparmor opt-clamav opt-tor] security=[apparmor,clamav]" in d
                            for d in lc.debug), lc.debug)

    def test_everything_unticked_is_not_mistaken_for_no_page(self):
        self.step("20-probe", self.PROBE)
        lc, load = fake_libcalamares(str(self.target))
        lc.gs["packageOperations"] = self.ops("opt-page-seen")
        self.assertIsNone(load().run())
        self.assertTrue(any("options=[] security=[none]" in d for d in lc.debug), lc.debug)

    def test_no_options_page_keeps_the_defaults(self):
        self.step("20-probe", self.PROBE)
        lc, load = fake_libcalamares(str(self.target))
        self.assertIsNone(load().run())
        self.assertTrue(any("options=[unset] security=[all]" in d for d in lc.debug), lc.debug)

    def test_missing_target_is_refused_without_running_anything(self):
        self.step("20-one", 'touch "${TARGET}/ran"\n')
        lc, load = fake_libcalamares(str(self.tmp / "nope"))
        res = load().run()
        self.assertIsInstance(res, tuple)
        self.assertFalse((self.tmp / "nope").exists())


if __name__ == "__main__":
    unittest.main()
