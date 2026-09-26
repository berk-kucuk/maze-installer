"""
Tests for the installer's deploy script (usr/share/maze/install/).

The deploy steps run against a FAKE target directory. The programs they call
are replaced by small stand-ins on PATH:

  arch-chroot   runs awk/sed on the target's files for real (paths rewritten
                into the fake target), emulates `passwd -l`, answers pacman
                queries from a config, and logs every call;
  findmnt, cryptsetup, objcopy, lsinitcpio, sbverify, lsblk
                answer from the same config.

So what is checked is what the steps really do to a target tree — files
removed, files written, commands issued — not that the code looks right.

    python -m unittest discover -s tests -v
"""
import json
import os
import shutil
import stat
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
INSTALL = ROOT / "maze-installer" / "usr" / "share" / "maze" / "install"
DRIVER = INSTALL / "deploy-to-target.sh"
STEPS = INSTALL / "steps"

ARCH_CHROOT = r'''#!/usr/bin/env python3
import json, os, re, subprocess, sys
target, argv = sys.argv[1], sys.argv[2:]
if argv[:1] == ["env"]:
    argv = argv[1:]
    while argv and "=" in argv[0] and not argv[0].startswith("/"):
        argv = argv[1:]
with open(os.environ["STUB_LOG"], "a") as f:
    f.write(" ".join(argv) + "\n")
cfg = json.loads(os.environ.get("STUB_CFG", "{}"))
installed = set(cfg.get("installed", []))
cmd = argv[0] if argv else ""
rcmap = cfg.get("rc", {})

def T(p):
    """Rewrite an absolute path argument into the fake target if it exists there."""
    if p.startswith("/") and os.path.lexists(target + p):
        return target + p
    return p

if cmd == "pacman":
    op = argv[1]
    names = argv[2:]
    if op == "-Qq":
        for n in names:
            if n in installed:
                print(n)
        sys.exit(0 if names and all(n in installed for n in names) else 1)
    if op == "-Q":
        for n in names:
            if n in installed:
                print(n, "1.0-1")
        sys.exit(0 if all(n in installed for n in names) else 1)
    if op == "-Qqu":
        sys.exit(0 if names and names[0] in cfg.get("newer", []) else 1)
    if op == "-Sy":
        sys.exit(cfg.get("sy_rc", 0))
    sys.exit(rcmap.get("pacman" + op, 0))
if cmd == "passwd" and argv[1:] == ["-l", "root"]:
    if cfg.get("passwd_fail"):
        sys.exit(1)
    sh = target + "/etc/shadow"
    s = open(sh).read()
    open(sh, "w").write(re.sub(r"^root:([^:]*):", lambda m: "root:!" + m.group(1) + ":", s, flags=re.M))
    sys.exit(0)
if cmd == "passwd" and argv[1:] == ["-S", "root"]:
    f = [l for l in open(target + "/etc/shadow") if l.startswith("root:")][0].split(":")[1]
    print("root", "L" if f.startswith("!") else "P")
    sys.exit(0)
if cmd in ("awk", "sed"):
    sys.exit(subprocess.run([cmd] + [T(a) for a in argv[1:]]).returncode)
if cmd == "sh" and argv[1] == "-c":
    script = argv[2]
    if "command -v maze-enable-rollback" in script:
        sys.exit(0 if os.path.exists(target + "/usr/bin/maze-enable-rollback") else 1)
    if "/usr/lib/modules" in script:
        base = target + "/usr/lib/modules"
        for d in sorted(os.listdir(base)) if os.path.isdir(base) else []:
            if os.path.exists(f"{base}/{d}/pkgbase") and os.path.exists(f"{base}/{d}/vmlinuz"):
                print(d)
        sys.exit(0)
    sys.exit(0)
if cmd == "getent":
    if argv[1] == "group":
        sys.exit(0 if argv[2] in cfg.get("groups", ["maze", "wheel"]) else 2)
    if argv[1] == "passwd":
        print(f"{argv[2]}:x:1000:1000::/home/{argv[2]}:/usr/bin/zsh")
        sys.exit(0)
sys.exit(rcmap.get(cmd, 0))
'''

HOST_STUBS = {
    "findmnt": r'''#!/usr/bin/env python3
import json, os, sys
cfg = json.loads(os.environ.get("STUB_CFG", "{}"))
a = sys.argv[1:]
if "FSTYPE" in a:   print(cfg.get("fstype", "btrfs"))
elif "SOURCE" in a:
    tgt = a[-1]
    print(cfg.get("esp_src", "/dev/nvme0n1p1") if tgt.endswith(("/boot", "/efi")) else cfg.get("root_src", "/dev/mapper/luks-x[/@]"))
''',
    "cryptsetup": r'''#!/usr/bin/env python3
import json, os, sys
cfg = json.loads(os.environ.get("STUB_CFG", "{}"))
if sys.argv[1] == "status": sys.exit(0 if cfg.get("luks", True) else 4)
sys.exit(1)   # refresh needs the passphrase — as on a real install
''',
    "objcopy": r'''#!/usr/bin/env python3
import json, os, sys
cfg = json.loads(os.environ.get("STUB_CFG", "{}"))
out = sys.argv[-1]
data = cfg.get("uname", "7.0.0-arch1-1") if "--only-section=.uname" in sys.argv else "INITRD"
open(out, "w").write(data)
''',
    "lsinitcpio": r'''#!/usr/bin/env python3
import json, os
cfg = json.loads(os.environ.get("STUB_CFG", "{}"))
print("\n".join(cfg.get("initrd_list", ["init", "usr/bin/cryptsetup"])))
''',
    "sbverify": "#!/bin/sh\nexit 0\n",
    "lsblk": "#!/bin/sh\nexit 0\n",
}


class DeployHarness(unittest.TestCase):
    """A fake target, stubbed tools, and a way to run chosen steps."""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="maze-deploy-test-"))
        self.target = self.tmp / "target"
        self.bin = self.tmp / "bin"
        self.bin.mkdir()
        self.log = self.tmp / "chroot.log"
        self.log.touch()
        (self.bin / "arch-chroot").write_text(ARCH_CHROOT)
        for name, body in HOST_STUBS.items():
            (self.bin / name).write_text(body)
        for p in self.bin.iterdir():
            p.chmod(0o755)
        for d in ("etc", "var/log", "home", "usr/bin", "boot/EFI"):
            (self.target / d).mkdir(parents=True, exist_ok=True)
        self.cfg = {"installed": [], "groups": ["maze", "wheel"]}

    def tearDown(self):
        # Directories a test made read-only must be writable again to delete.
        for p in self.tmp.rglob("*"):
            if p.is_dir():
                p.chmod(0o755)
        shutil.rmtree(self.tmp, ignore_errors=True)

    def write(self, rel, text, mode=None):
        p = self.target / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(textwrap.dedent(text).lstrip("\n"))
        if mode is not None:
            p.chmod(mode)
        return p

    def read(self, rel):
        return (self.target / rel).read_text()

    def run_steps(self, *steps, extra_steps=None, env=None):
        """Run the driver with only these steps (00-setup and 10-helpers always
        run). extra_steps: {name: bash} added as additional step files."""
        stepdir = self.tmp / "steps"
        if stepdir.exists():
            shutil.rmtree(stepdir)
        stepdir.mkdir()
        wanted = {"00-setup", "10-helpers", *steps}
        for f in STEPS.glob("*.sh"):
            if f.stem in wanted:
                shutil.copy(f, stepdir / f.name)
        for name, body in (extra_steps or {}).items():
            (stepdir / f"{name}.sh").write_text(body)
        e = dict(os.environ,
                 PATH=f"{self.bin}:{os.environ['PATH']}",
                 STUB_LOG=str(self.log),
                 STUB_CFG=json.dumps(self.cfg),
                 MAZE_STEP_DIR=str(stepdir))
        e.update(env or {})
        r = subprocess.run(["bash", str(DRIVER), str(self.target), "all", ""],
                           env=e, capture_output=True, text=True, timeout=120)
        self.out = r.stdout + r.stderr
        return r

    def chroot_calls(self):
        return self.log.read_text().splitlines()


class TestDriver(DeployHarness):
    def test_refuses_the_live_root_as_target(self):
        r = subprocess.run(["bash", str(DRIVER), "/", "all", ""],
                           capture_output=True, text=True, timeout=30)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("refusing to operate on '/'", r.stderr)

    def test_summary_is_written_and_lists_warnings_by_step(self):
        r = self.run_steps(extra_steps={"50-probe": 'warn "probe warning"\n'})
        self.assertEqual(r.returncode, 0, self.out)
        summary = self.read("var/log/maze-install-summary.txt")
        self.assertIn("[50-probe] probe warning", summary)
        self.assertRegex(summary, r"50-probe\s+\d+s\s+1")

    def test_a_critical_problem_fails_the_install(self):
        r = self.run_steps(extra_steps={"50-probe": 'critical "probe critical"\n',
                                        "60-after": 'log "later step still ran"\n'})
        self.assertEqual(r.returncode, 1)
        self.assertIn("later step still ran", self.out)
        self.assertIn("probe critical", self.read("var/log/maze-install-summary.txt"))

    def test_no_step_ends_the_shell_early(self):
        # A step is sourced into the driver's shell: an `exit` in one skips the
        # summary AND the critical-problem exit code (the old monolith ended in
        # `exit 0`, which landed in the last step when it was split).
        import re
        for f in STEPS.glob("*.sh"):
            if f.stem == "00-setup":
                continue      # refuses a bad target before anything runs
            body = re.sub(r"<<'?(\w+)'?.*?^\1$", "", f.read_text(), flags=re.S | re.M)
            for n, line in enumerate(body.splitlines(), 1):
                code = re.sub(r"'[^']*'", "''", line.split("#", 1)[0])   # awk/sed programs
                self.assertNotRegex(code, r"(^|[;&|]\s*)\s*exit\b",
                                    f"{f.name}:{n} ends the driver's shell: {line.strip()}")

    def test_paru_is_built_first(self):
        r = self.run_steps(extra_steps={"50-probe": 'log "AUR=${CURATED_AUR[*]}"\n'})
        self.assertIn("AUR=paru onlyoffice-bin", self.out)


class TestLiveResidue(DeployHarness):
    LIVE_ONLY = [
        "etc/sudoers.d/10-maze",
        "etc/polkit-1/rules.d/49-maze-calamares.rules",
        "etc/systemd/system/getty@tty1.service.d/autologin.conf",
        "etc/sddm.conf.d/10-maze-autologin.conf",
        "etc/firefox/policies/policies.json",
        "usr/local/bin/maze-calamares",
        "usr/share/applications/maze-calamares.desktop",
        "etc/ssh/sshd_config.d/10-archiso.conf",
        "etc/systemd/logind.conf.d/do-not-suspend.conf",
        "etc/systemd/journald.conf.d/volatile-storage.conf",
        "etc/systemd/resolved.conf.d/archiso.conf",
        "usr/local/bin/choose-mirror",
        "root/.automated_script.sh",
    ]

    def test_live_only_files_are_removed_and_safe_defaults_written(self):
        for f in self.LIVE_ONLY:
            self.write(f, "live\n")
        self.write("etc/motd", "live and install medium\n")
        self.cfg["installed"] = ["maze-installer", "calamares", "xorg-xhost"]
        r = self.run_steps("40-live-residue")
        self.assertEqual(r.returncode, 0, self.out)
        for f in self.LIVE_ONLY:
            self.assertFalse((self.target / f).exists(), f"{f} survived")
        self.assertIn("paru -Syu", self.read("etc/motd"))
        wheel = self.target / "etc/sudoers.d/10-maze-wheel"
        self.assertEqual(stat.S_IMODE(wheel.stat().st_mode), 0o440)
        self.assertIn("%wheel ALL=(ALL:ALL) ALL", wheel.read_text())
        self.assertNotIn("NOPASSWD", wheel.read_text())
        self.assertIn("pacman -Rns --noconfirm maze-installer calamares xorg-xhost", self.chroot_calls())


    def test_packaged_wheel_rule_is_not_duplicated(self):
        rule = "# packaged\n%wheel ALL=(ALL:ALL) ALL\n"
        self.write("etc/sudoers.d/00-maze-wheel", rule)
        r = self.run_steps("40-live-residue")
        self.assertEqual(r.returncode, 0, self.out)
        self.assertFalse((self.target / "etc/sudoers.d/10-maze-wheel").exists())
        self.assertEqual(self.read("etc/sudoers.d/00-maze-wheel"), rule)


class TestDefaultBrowser(DeployHarness):
    PACKAGED = ("[Default Applications]\n"
                "x-scheme-handler/http=firefox.desktop\n"
                "x-scheme-handler/https=firefox.desktop\n"
                "text/html=firefox.desktop\n"
                "application/xhtml+xml=firefox.desktop\n"
                "x-scheme-handler/mailto=org.mozilla.Thunderbird.desktop\n"
                "\n[Added Associations]\n"
                "text/html=firefox.desktop;\n")

    def test_packaged_files_that_are_already_right_are_left_alone(self):
        for f in ("etc/xdg/mimeapps.list", "etc/skel/.config/mimeapps.list"):
            self.write(f, self.PACKAGED)
        self.write("etc/skel/.config/kdeglobals", "[General]\nBrowserApplication=firefox.desktop\n")
        r = self.run_steps("30-panel-browser")
        self.assertEqual(r.returncode, 0, self.out)
        for f in ("etc/xdg/mimeapps.list", "etc/skel/.config/mimeapps.list"):
            self.assertEqual(self.read(f), self.PACKAGED, f"{f} was rewritten")

    def test_a_wrong_default_is_still_corrected_and_mail_kept(self):
        self.write("etc/skel/.config/mimeapps.list",
                   "[Default Applications]\ntext/html=chromium.desktop\n"
                   "x-scheme-handler/mailto=org.mozilla.Thunderbird.desktop\n")
        r = self.run_steps("30-panel-browser")
        self.assertEqual(r.returncode, 0, self.out)
        m = self.read("etc/skel/.config/mimeapps.list")
        self.assertIn("text/html=firefox.desktop", m)
        self.assertNotIn("chromium", m)
        self.assertIn("x-scheme-handler/mailto=org.mozilla.Thunderbird.desktop", m)
        self.assertIn("x-scheme-handler/http=firefox.desktop", self.read("etc/xdg/mimeapps.list"))


class TestFullRun(DeployHarness):
    """Every step, in order, on a minimal target: the steps share variables, so
    a stage that stops defining one (or a removed helper still called somewhere)
    only shows up when they run together."""

    def test_all_steps_run_clean_on_a_minimal_target(self):
        self.write("etc/passwd", "root:x:0:0::/root:/bin/bash\ntest:x:1000:1000::/home/test:/bin/bash\n")
        self.write("etc/shadow", "root::19000::::::\ntest:$6$x:19000::::::\n")
        self.write("etc/hostname", "maze-test\n")
        self.write("etc/locale.conf", "LANG=en_US.UTF-8\nLC_TIME=tr_TR.UTF-8\n")
        self.write("etc/kernel/cmdline", "quiet rw rootflags=subvol=/@ cryptdevice=UUID=abc:luks-abc root=/dev/mapper/luks-abc\n")
        self.write("etc/mkinitcpio.conf", "MODULES=()\nFILES=()\nHOOKS=(base udev autodetect modconf keyboard block encrypt filesystems)\n")
        self.write("etc/pacman.conf", "[options]\n#Color\n\n[core]\nInclude = /etc/pacman.d/mirrorlist\n")
        self.write("boot/loader/loader.conf", "timeout 3\n")
        self.write("home/test/.config/kdeglobals", "[General]\nBrowserApplication=chromium.desktop\n")
        self.write("etc/sudoers.d/10-maze", "%wheel ALL=(ALL) NOPASSWD: ALL\n")
        r = self.run_steps(*[f.stem for f in STEPS.glob("*.sh")],
                           env={"MAZE_BOOT_GPU_DRV": "i915"})
        self.assertNotIn("unbound variable", self.out)
        self.assertNotIn("command not found", self.out)
        self.assertEqual(r.returncode, 0, self.out[-4000:])
        summary = self.read("var/log/maze-install-summary.txt")
        for step in ("40-live-residue", "70-cmdline-uki", "98-keyring-final"):
            self.assertIn(step, summary)
        self.assertTrue(self.read("etc/shadow").startswith("root:!"))
        self.assertFalse((self.target / "etc/sudoers.d/10-maze").exists())
        self.assertNotIn("LC_TIME", self.read("etc/locale.conf"))
        self.assertIn("maze-test", self.read("etc/hosts"))
        self.assertIn("BrowserApplication=firefox.desktop", self.read("home/test/.config/kdeglobals"))


class TestDesktopFiles(DeployHarness):
    def test_build_hosts_screen_layout_never_reaches_new_users(self):
        self.write("etc/skel/.config/kwinoutputconfig.json", "{}\n")
        self.write("etc/skel/.local/share/kscreen/abc", "x\n")
        self.write("etc/skel/.config/kwinrc", """
            [Compositing]
            Backend=OpenGL

            [Tiling][1][2]
            padding=4
            """)
        self.write("etc/skel/.config/plasma-org.kde.plasma.desktop-appletsrc", """
            [Containments][1]
            ItemGeometries-1920x1080=Applet-1:0,0,10,10
            screenMapping=desktop:/x,0,host-DP-1
            """)
        r = self.run_steps("20-desktop-files")
        self.assertEqual(r.returncode, 0, self.out)
        self.assertFalse((self.target / "etc/skel/.config/kwinoutputconfig.json").exists())
        self.assertFalse((self.target / "etc/skel/.local/share/kscreen").exists())
        kwinrc = self.read("etc/skel/.config/kwinrc")
        self.assertIn("[Compositing]", kwinrc)
        self.assertNotIn("[Tiling]", kwinrc)
        applets = self.read("etc/skel/.config/plasma-org.kde.plasma.desktop-appletsrc")
        self.assertNotIn("ItemGeometries-1920x1080", applets)
        self.assertIn("screenMapping=\n", applets)


class TestRootLock(DeployHarness):
    def test_an_empty_root_password_is_locked(self):
        self.write("etc/shadow", "root::19000::::::\nbin:!*:19000::::::\n")
        r = self.run_steps("55-root-lock")
        self.assertEqual(r.returncode, 0, self.out)
        self.assertTrue(self.read("etc/shadow").startswith("root:!:"))

    def test_root_that_cannot_be_locked_fails_the_install(self):
        self.write("etc/shadow", "root::19000::::::\n")
        self.cfg["passwd_fail"] = True
        (self.target / "etc").chmod(0o555)       # the sed fallback cannot write either
        r = self.run_steps("55-root-lock")
        self.assertEqual(r.returncode, 1, self.out)
        self.assertIn("could not lock root", self.out)


class TestCmdlineAndInitramfs(DeployHarness):
    CALAMARES_CMDLINE = ("quiet rw rootflags=subvol=/@ "
                         "cryptdevice=UUID=abc:luks-abc root=/dev/mapper/luks-abc\n")

    def prepare(self, hooks="base udev autodetect microcode modconf keyboard block encrypt filesystems"):
        self.write("etc/kernel/cmdline", self.CALAMARES_CMDLINE)
        self.write("etc/mkinitcpio.conf", f"""
            MODULES=()
            FILES=(/crypto_keyfile.bin)
            HOOKS=({hooks})
            #COMPRESSION="xz"
            """)
        self.write("boot/loader/loader.conf", "timeout 5\nconsole-mode max\n")
        self.write("usr/bin/maze-enable-rollback", "#!/bin/sh\n", mode=0o755)

    def test_cmdline_gets_maze_params_once_and_trim_on_luks(self):
        self.prepare()
        r = self.run_steps("60-gpu-keyboard", "65-initramfs", "70-cmdline-uki", env={"MAZE_BOOT_GPU_DRV": "i915"})
        self.assertEqual(r.returncode, 0, self.out)
        toks = self.read("etc/kernel/cmdline").split()
        for p in ("apparmor=1", "security=apparmor", "splash",
                  "lsm=landlock,lockdown,yama,integrity,apparmor,bpf"):
            self.assertEqual(toks.count(p), 1, p)
        self.assertEqual(toks.count("quiet"), 1)
        self.assertIn("root=/dev/mapper/luks-abc", toks)
        self.assertIn("cryptdevice=UUID=abc:luks-abc:allow-discards", toks)

    def test_rollback_mode_is_requested_on_btrfs(self):
        self.prepare()
        self.run_steps("60-gpu-keyboard", "65-initramfs", "70-cmdline-uki", env={"MAZE_BOOT_GPU_DRV": "i915"})
        self.assertIn("maze-enable-rollback --apply --no-rebuild", self.chroot_calls())

    def test_rollback_is_not_requested_off_btrfs(self):
        self.prepare()
        self.cfg["fstype"] = "ext4"
        self.run_steps("60-gpu-keyboard", "65-initramfs", "70-cmdline-uki", env={"MAZE_BOOT_GPU_DRV": "i915"})
        self.assertNotIn("maze-enable-rollback --apply --no-rebuild", self.chroot_calls())

    def test_keyfile_is_never_packed_and_boot_is_immediate(self):
        self.prepare()
        self.run_steps("60-gpu-keyboard", "65-initramfs", "70-cmdline-uki", env={"MAZE_BOOT_GPU_DRV": "i915"})
        mk = self.read("etc/mkinitcpio.conf")
        self.assertNotIn("crypto_keyfile.bin", mk)
        self.assertEqual(mk.count('COMPRESSION="zstd"'), 1)
        loader = self.read("boot/loader/loader.conf")
        self.assertIn("timeout 0", loader)
        self.assertIn("console-mode keep", loader)

    def test_igpu_panel_drops_kms_and_pins_its_driver(self):
        self.prepare(hooks="base udev autodetect microcode kms modconf keyboard block encrypt filesystems")
        self.run_steps("65-initramfs", env={"MAZE_BOOT_GPU_DRV": "i915"})
        mk = self.read("etc/mkinitcpio.conf")
        self.assertIn("MODULES=(i915)", mk)
        self.assertNotRegex(mk, r"HOOKS=\([^)]*\bkms\b")

    def test_a_missing_encrypt_hook_is_forced_in(self):
        self.prepare(hooks="base udev autodetect microcode modconf keyboard block filesystems")
        r = self.run_steps("60-gpu-keyboard", "65-initramfs", "70-cmdline-uki", env={"MAZE_BOOT_GPU_DRV": "i915"})
        self.assertEqual(r.returncode, 0, self.out)
        self.assertRegex(self.read("etc/mkinitcpio.conf"), r"HOOKS=\([^)]*\bencrypt filesystems\b")

    def test_luks_root_without_encrypt_hook_fails_the_install(self):
        # 70 alone (no 65 to repair HOOKS) — the last line of defence.
        self.prepare(hooks="base udev autodetect modconf block filesystems")
        r = self.run_steps("60-gpu-keyboard", "70-cmdline-uki",
                           extra_steps={"61-luks": "ROOT_IS_LUKS=1\nmkconf=\"${TARGET}/etc/mkinitcpio.conf\"\n"})
        self.assertEqual(r.returncode, 1, self.out)
        self.assertIn("'encrypt' hook MISSING", self.out)


class TestPacmanConf(DeployHarness):
    def test_pacman_conf_is_tuned_and_build_repos_removed(self):
        self.write("etc/pacman.conf", """
            [options]
            #ParallelDownloads = 5
            #Color
            #VerbosePkgLists

            [maze-aur]
            SigLevel = Optional TrustAll
            Server = file:///home/builder/MazeLinux/localrepo

            [core]
            Include = /etc/pacman.d/mirrorlist

            [blackarch]
            Include = /etc/pacman.d/blackarch-mirrorlist

            [extra]
            Include = /etc/pacman.d/mirrorlist
            """)
        r = self.run_steps("90-pacman")
        self.assertEqual(r.returncode, 0, self.out)
        conf = self.read("etc/pacman.conf")
        self.assertIn("ParallelDownloads = 15", conf)
        self.assertRegex(conf, r"(?m)^Color$")
        self.assertRegex(conf, r"(?m)^ILoveCandy$")
        self.assertNotIn("[maze-aur]", conf)
        self.assertNotIn("localrepo", conf)
        self.assertNotIn("[blackarch]", conf)
        # The sections after the removed ones must survive intact.
        self.assertIn("[core]", conf)
        self.assertIn("[extra]", conf)
        self.assertLess(conf.index("[mazelinux]"), conf.index("[core]"))


class TestSystemSync(DeployHarness):
    PROBE = 'sync_upgrade_target; log "sync rc=$?"\n'

    def test_keyring_upgraded_only_when_the_repo_is_newer(self):
        self.cfg["newer"] = ["archlinux-keyring"]
        self.run_steps(extra_steps={"50-probe": self.PROBE})
        calls = self.chroot_calls()
        self.assertIn("pacman -S --noconfirm --needed archlinux-keyring", calls)
        self.assertFalse(any("mazelinux-keyring" in c and c.startswith("pacman -S ") for c in calls),
                         "a keyring the repo does not have newer must not be (re)installed — that downgrades it")
        self.assertIn("sync rc=0", self.out)

    def test_offline_gives_up_without_installing(self):
        self.cfg["sy_rc"] = 1
        self.run_steps(extra_steps={"50-probe": self.PROBE},
                       env={"PATH": f"{self.bin}:{os.environ['PATH']}"})
        self.assertIn("sync rc=1", self.out)
        self.assertFalse(any(c.startswith("pacman -Su") for c in self.chroot_calls()))


class TestBootVerification(DeployHarness):
    def esp_image(self, rel="boot/EFI/Linux/abc-7.0.0-arch1-1.efi"):
        p = self.target / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_bytes(b"MZ" + b"\0" * 64)
        return p

    LUKS = {"61-luks": "ROOT_IS_LUKS=1\n"}

    def test_a_keyfile_inside_a_boot_image_fails_the_install(self):
        self.esp_image()
        self.cfg["initrd_list"] = ["init", "crypto_keyfile.bin"]
        r = self.run_steps("26-secureboot-function", "96-verify-boot", extra_steps=self.LUKS)
        self.assertEqual(r.returncode, 1, self.out)
        self.assertIn("LUKS keyfile is inside a boot image", self.out)

    def test_clean_boot_images_pass(self):
        self.esp_image()
        (self.target / "boot/EFI/BOOT").mkdir(parents=True)
        (self.target / "boot/EFI/BOOT/grubx64.efi.maze-kver").write_text("7.0.0-arch1-1\n")
        r = self.run_steps("26-secureboot-function", "96-verify-boot", extra_steps=self.LUKS)
        self.assertEqual(r.returncode, 0, self.out)
        self.assertIn("no keyfile inside the 1 boot image(s)", self.out)
        self.assertNotIn("could not be inspected", self.out)

    def test_boot_image_for_a_missing_kernel_fails_the_install(self):
        grub = self.esp_image("boot/EFI/BOOT/grubx64.efi")
        mods = self.target / "usr/lib/modules/7.1.0-arch1-1"
        mods.mkdir(parents=True)
        (mods / "vmlinuz").write_text("k")
        self.write("var/lib/maze-secureboot/MOK.crt", "crt\n")
        self.write("boot/EFI/BOOT/BOOTX64.EFI", "shim\n")
        self.cfg["uname"] = "7.0.0-arch1-1"          # the image boots a kernel that is gone
        r = self.run_steps("26-secureboot-function", "96-verify-boot",
                           extra_steps={"61-sb": 'MAZE_SB_ESP="/boot"\n'})
        self.assertEqual(r.returncode, 1, self.out)
        self.assertIn("this install will NOT boot", self.out)
        self.assertTrue((self.target / "var/lib/maze-secureboot/BOOT-STATUS.txt").exists())
        self.assertTrue(grub.exists())


if __name__ == "__main__":
    unittest.main()
