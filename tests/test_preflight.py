"""
Tests for the installer preflight (usr/share/maze/install/preflight.py) and the
Calamares job that runs it (usr/lib/calamares/modules/mazepreflight).

No disk is touched: lsblk / findmnt / ntfs-3g.probe / mount answer from a
description of a fake machine, so each test reads as "on a machine like this,
with this choice on the partition page, the installer says ...".

    python -m unittest discover -s tests -v
"""
import importlib.util
import json
import os
import sys
import types
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
INSTALL = ROOT / "maze-installer" / "usr" / "share" / "maze" / "install"
MODULE = ROOT / "maze-installer" / "usr" / "lib" / "calamares" / "modules" / "mazepreflight" / "main.py"
sys.dont_write_bytecode = True
sys.path.insert(0, str(INSTALL))
import preflight  # noqa: E402

MiB, GiB = preflight.MiB, preflight.GiB
ESP = preflight.ESP_GUID
LINUX = "0fc63daf-8483-4772-8e79-3d69c47d8e4f"
MSDATA = "ebd0a0a2-b9e5-4433-87c0-68b6b72699c7"


def part(path, parttype, fstype, size, pkname, label=""):
    return {"path": path, "type": "part", "parttype": parttype, "fstype": fstype,
            "size": size, "pkname": pkname, "label": label}


class Machine:
    """A fake machine: disks for lsblk, free space per ESP, NTFS states."""

    def __init__(self, disks, free=None, ntfs=None, live=""):
        self.disks, self.free, self.ntfs, self.live = disks, free or {}, ntfs or {}, live
        self.calls = []

    def run(self, argv, timeout=60):
        self.calls.append(argv)
        if argv[:2] == ["lsblk", "-J"]:
            return 0, json.dumps({"blockdevices": [
                {"path": "/dev/" + name, "type": "disk", "children": parts}
                for name, parts in self.disks.items()]})
        if argv[:3] == ["findmnt", "-no", "SOURCE"] and argv[3] == "/run/archiso/bootmnt":
            return (0, self.live + "1\n") if self.live else (1, "")
        if argv[:3] == ["lsblk", "-no", "PKNAME"]:
            return 0, self.live.rsplit("/", 1)[-1] + "\n"
        if argv[0] == "ntfs-3g.probe":
            return {"ok": 0, "hibernated": 14, "unclean": 15}[self.ntfs.get(argv[-1], "ok")], ""
        return 1, ""


def scan(machine):
    orig = preflight._free_bytes
    preflight._free_bytes = lambda path, run=None: machine.free.get(path)
    try:
        return preflight.scan(run=machine.run)
    finally:
        preflight._free_bytes = orig


WINDOWS = {"nvme0n1": [
    part("/dev/nvme0n1p1", ESP, "vfat", 100 * MiB, "nvme0n1"),
    part("/dev/nvme0n1p2", "e3c9e316-0b5c-4db8-817d-f92df00215ae", "", 16 * MiB, "nvme0n1"),
    part("/dev/nvme0n1p3", MSDATA, "ntfs", 400 * GiB, "nvme0n1", "Windows"),
]}


def codes(issues, level=None):
    return [i["code"] for i in issues if level is None or i["level"] == level]


class TestEvaluate(unittest.TestCase):
    def test_windows_esp_blocks_alongside_and_replace(self):
        facts = scan(Machine(WINDOWS, free={"/dev/nvme0n1p1": 70 * MiB}))
        for choice in ("alongside", "replace"):
            issues = preflight.evaluate(facts, choice)
            self.assertEqual(codes(issues, "block"), ["esp-too-small"], choice)
            self.assertIn("/dev/nvme0n1p1 (70 MB free of 100 MB)", issues[0]["en"])
            self.assertIn("Elle bölümlendirme", issues[0]["tr"])

    def test_windows_esp_is_only_a_warning_in_the_launcher(self):
        facts = scan(Machine(WINDOWS, free={"/dev/nvme0n1p1": 70 * MiB}))
        self.assertEqual([(i["code"], i["level"]) for i in preflight.evaluate(facts)],
                         [("esp-too-small", "warn")])

    def test_erase_and_manual_do_not_care_about_the_old_esp(self):
        facts = scan(Machine(WINDOWS, free={"/dev/nvme0n1p1": 70 * MiB}))
        self.assertEqual(preflight.evaluate(facts, "erase"), [])
        self.assertEqual(codes(preflight.evaluate(facts, "manual"), "block"), [])

    def test_a_roomy_esp_is_fine(self):
        disks = {"sda": [part("/dev/sda1", ESP, "vfat", 512 * MiB, "sda"),
                         part("/dev/sda2", LINUX, "ext4", 200 * GiB, "sda")]}
        facts = scan(Machine(disks, free={"/dev/sda1": 500 * MiB}))
        self.assertEqual(preflight.evaluate(facts, "alongside"), [])

    def test_one_big_enough_esp_among_several_is_enough(self):
        disks = dict(WINDOWS, sda=[part("/dev/sda1", ESP, "vfat", 2 * GiB, "sda")])
        facts = scan(Machine(disks, free={"/dev/nvme0n1p1": 70 * MiB, "/dev/sda1": 2 * GiB}))
        self.assertEqual(codes(preflight.evaluate(facts, "replace")), [])

    def test_the_live_usb_esp_is_not_counted(self):
        disks = {"sdb": [part("/dev/sdb2", ESP, "vfat", 200 * MiB, "sdb")]}
        facts = scan(Machine(disks, free={"/dev/sdb2": 1 * MiB}, live="/dev/sdb"))
        self.assertEqual(facts["esps"], [])
        self.assertEqual(preflight.evaluate(facts, "alongside"), [])

    def test_free_space_unknown_falls_back_to_the_size(self):
        facts = scan(Machine(WINDOWS))          # the ESP could not be mounted
        self.assertEqual(codes(preflight.evaluate(facts, "alongside"), "block"), ["esp-too-small"])

    def test_hibernated_windows_blocks_alongside_only(self):
        disks = dict(WINDOWS)
        disks["nvme0n1"] = [p for p in WINDOWS["nvme0n1"] if p["fstype"] == "ntfs"] + \
                           [part("/dev/nvme0n1p1", ESP, "vfat", 1 * GiB, "nvme0n1")]
        m = Machine(disks, free={"/dev/nvme0n1p1": 900 * MiB}, ntfs={"/dev/nvme0n1p3": "hibernated"})
        facts = scan(m)
        self.assertEqual(codes(preflight.evaluate(facts, "alongside"), "block"), ["windows-not-shut-down"])
        self.assertEqual(codes(preflight.evaluate(facts, "manual")), ["windows-not-shut-down"])
        self.assertEqual(codes(preflight.evaluate(facts, "manual"), "block"), [])
        self.assertEqual(preflight.evaluate(facts, "erase"), [])
        self.assertIn(["ntfs-3g.probe", "--readwrite", "/dev/nvme0n1p3"], m.calls)

    def test_bitlocker_is_a_warning_unless_the_disk_is_erased(self):
        disks = {"nvme0n1": [part("/dev/nvme0n1p1", ESP, "vfat", 2 * GiB, "nvme0n1"),
                             part("/dev/nvme0n1p3", MSDATA, "BitLocker", 400 * GiB, "nvme0n1")]}
        facts = scan(Machine(disks, free={"/dev/nvme0n1p1": 2 * GiB}))
        self.assertEqual([(i["code"], i["level"]) for i in preflight.evaluate(facts, "alongside")],
                         [("bitlocker", "warn")])
        self.assertEqual(preflight.evaluate(facts, "erase"), [])

    def test_lsblk_failure_reports_nothing_rather_than_guessing(self):
        m = Machine({})
        m.run = lambda argv, timeout=60: (1, "")
        facts = preflight.scan(run=m.run)
        self.assertEqual(preflight.evaluate(facts, "alongside"), [])


class FakeStat:
    def __init__(self, free):
        self.f_bavail, self.f_frsize = free, 1


def target(mounts, parttypes, free):
    """check_target() on a fake mounted target: mounts {path: (source, fs)}."""
    def run(argv, timeout=60):
        if argv[:3] == ["findmnt", "-no", "SOURCE,FSTYPE"]:
            m = mounts.get(argv[-1])
            return (0, "{} {}\n".format(*m)) if m else (1, "")
        if argv[:3] == ["lsblk", "-no", "PARTTYPE"]:
            return 0, parttypes.get(argv[-1], "") + "\n"
        return 1, ""

    def statvfs(path):
        if path not in free:
            raise OSError
        return FakeStat(free[path])
    return preflight.check_target("/tmp/root", run=run, statvfs=statvfs)


GOOD_MOUNTS = {"/tmp/root": ("/dev/mapper/luks-1[/@]", "btrfs"),
               "/tmp/root/boot": ("/dev/nvme0n1p1", "vfat")}
GOOD_FREE = {"/tmp/root": 100 * GiB, "/tmp/root/boot": 3 * GiB}


class TestTarget(unittest.TestCase):
    def test_a_normal_layout_passes(self):
        self.assertEqual(target(GOOD_MOUNTS, {"/dev/nvme0n1p1": ESP}, GOOD_FREE), [])

    def test_no_esp_at_boot(self):
        mounts = {k: v for k, v in GOOD_MOUNTS.items() if not k.endswith("/boot")}
        self.assertEqual(codes(target(mounts, {}, GOOD_FREE)), ["esp-missing"])

    def test_boot_that_is_not_an_esp(self):
        mounts = dict(GOOD_MOUNTS, **{"/tmp/root/boot": ("/dev/nvme0n1p2", "ext4")})
        self.assertEqual(codes(target(mounts, {"/dev/nvme0n1p2": LINUX}, GOOD_FREE)),
                         ["esp-fs", "esp-type"])

    def test_esp_without_room(self):
        free = dict(GOOD_FREE, **{"/tmp/root/boot": 60 * MiB})
        self.assertEqual(codes(target(GOOD_MOUNTS, {"/dev/nvme0n1p1": ESP}, free)), ["esp-full"])

    def test_small_root_and_unsupported_root_fs(self):
        mounts = dict(GOOD_MOUNTS, **{"/tmp/root": ("/dev/sda3", "ntfs")})
        free = dict(GOOD_FREE, **{"/tmp/root": 18 * GiB})
        self.assertEqual(codes(target(mounts, {"/dev/nvme0n1p1": ESP}, free)), ["root-fs", "root-small"])

    def test_mbr_esp_is_accepted(self):
        self.assertEqual(target(GOOD_MOUNTS, {"/dev/nvme0n1p1": "0xef"}, GOOD_FREE), [])


class TestCalamaresJob(unittest.TestCase):
    def load(self, gs, conf, languages=("en",)):
        lc = types.ModuleType("libcalamares")
        lc.logged = []
        lc.job = types.SimpleNamespace(configuration=dict(conf, library=str(INSTALL)))
        lc.utils = types.SimpleNamespace(debug=lc.logged.append, warning=lc.logged.append,
                                         gettext_languages=lambda: list(languages))
        lc.globalstorage = types.SimpleNamespace(value=gs.get)
        sys.modules["libcalamares"] = lc
        spec = importlib.util.spec_from_file_location("mazepreflight_main", MODULE)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        return mod

    def tearDown(self):
        sys.modules.pop("libcalamares", None)

    def test_system_phase_stops_alongside_next_to_a_windows_esp(self):
        facts = scan(Machine(WINDOWS, free={"/dev/nvme0n1p1": 70 * MiB}))
        orig = preflight.scan
        preflight.scan = lambda run=None: facts
        try:
            mod = self.load({"partitionChoices": {"install": "alongside", "swap": "none"}},
                            {"phase": "system"}, languages=("tr",))
            res = mod.run()
        finally:
            preflight.scan = orig
        self.assertIsInstance(res, tuple)
        self.assertIn("kurulamaz", res[0])
        self.assertIn("Diskte hiçbir şey değiştirilmedi", res[1])

    def test_system_phase_lets_erase_through(self):
        facts = scan(Machine(WINDOWS, free={"/dev/nvme0n1p1": 70 * MiB}))
        orig = preflight.scan
        preflight.scan = lambda run=None: facts
        try:
            mod = self.load({"partitionChoices": {"install": "erase"}}, {"phase": "system"})
            self.assertIsNone(mod.run())
        finally:
            preflight.scan = orig

    def test_target_phase_reports_a_full_esp(self):
        orig = preflight.check_target
        preflight.check_target = lambda root: [{"level": "block", "code": "esp-full", "en": "ESP full", "tr": "ESP dolu"}]
        try:
            mod = self.load({"rootMountPoint": "/"}, {"phase": "target"})
            res = mod.run()
        finally:
            preflight.check_target = orig
        self.assertIn("ESP full", res[1])
        self.assertIn("nothing was copied", res[1])

    def test_broken_library_never_blocks_the_install(self):
        mod = self.load({"partitionChoices": {"install": "alongside"}},
                        {"phase": "system", "library": "/nonexistent"})
        mod._load = lambda: (_ for _ in ()).throw(ImportError("gone"))
        self.assertIsNone(mod.run())


if __name__ == "__main__":
    unittest.main()
