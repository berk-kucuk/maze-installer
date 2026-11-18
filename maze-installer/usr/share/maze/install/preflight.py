#!/usr/bin/env python3
#
# Maze Linux — installer preflight checks.
#
# Catches, BEFORE the disk is touched, the setups that otherwise only fail at
# the very end of an install — or worse, produce a system that does not boot:
#
#   * Installing next to Windows ("Install alongside" / "Replace a partition")
#     reuses the EFI system partition that is already there. Maze keeps its
#     Unified Kernel Images on the ESP — one per kernel plus the signed
#     grubx64.efi, its .maze-prev fallback and a recovery copy, ~170 MB in all
#     on a real install, more with AMD firmware — and the 100-300 MB ESP Windows
#     creates cannot hold them. Calamares does not check the ESP in those
#     modes (only in manual partitioning, and there it only warns), so the
#     install ran to the end and left a machine that does not boot.
#   * Windows' Fast Startup leaves its NTFS volumes hibernated; ntfsresize
#     refuses to shrink them, so "Install alongside" failed half-way through
#     partitioning.
#   * BitLocker asks for its recovery key after the boot order changes.
#   * A root partition too small for the system (plus its first update) fills
#     up in the middle of a pacman transaction.
#
# Used three ways:
#   preflight.py --gui         the launcher, before Calamares opens: warns
#                              (Continue / Cancel), never blocks on its own
#   preflight.py --json        print what was found (debugging)
#   import preflight           the mazepreflight Calamares job: evaluate() just
#                              before partitioning and check_target() right
#                              after the target is mounted — these BLOCK
#
# Every probe is read-only. The one mount it makes (an existing ESP, to measure
# its free space) is read-only, private and undone at once.

import json
import os
import subprocess
import sys
import tempfile

ESP_GUID = "c12a7328-f81f-11d2-ba4b-00a0c93ec93b"
ESP_MBR = {"0xef", "ef"}
MiB = 1024 * 1024
GiB = 1024 * MiB

# Free space a REUSED ESP must have for Maze's boot images: ~170 MB measured on
# a real install (two kernels: their UKIs, grubx64.efi, .maze-prev, recovery),
# up to ~150 MB more when AMD GPU firmware goes into each image, and room for
# one more UKI while a kernel update writes the new image before removing the
# old. Windows' 100-300 MB ESP is below it; Ubuntu's 512 MiB and Fedora's
# 600 MiB ones are above it.
ESP_MIN_FREE = 400 * MiB
# Free space the root partition must have before the system is copied in: the
# live system (~13-15 GiB unpacked), the first full update (1-3 GiB) and the
# AUR apps built on the target (onlyoffice-bin alone ~1.3 GiB).
ROOT_MIN_FREE = 25 * GiB
ROOT_FILESYSTEMS = {"btrfs", "ext4", "xfs", "f2fs"}

# ntfs-3g.probe exit codes (ntfs-3g's NTFS_VOLUME_* values).
NTFS_HIBERNATED = 14
NTFS_UNCLEAN = 15


def _run(argv, timeout=60):
    try:
        p = subprocess.run(argv, stdin=subprocess.DEVNULL, capture_output=True,
                           text=True, errors="replace", timeout=timeout)
        return p.returncode, p.stdout
    except (OSError, subprocess.SubprocessError):
        return 127, ""


# --- facts about this machine -------------------------------------------------

def live_medium_disk(run=_run):
    """The disk the live system booted from: its partitions are not candidates."""
    rc, out = run(["findmnt", "-no", "SOURCE", "/run/archiso/bootmnt"])
    src = out.strip() if rc == 0 else ""
    if not src:
        # copytoram unmounts the medium; find it by the label archiso booted with.
        try:
            cmdline = open("/proc/cmdline").read().split()
        except OSError:
            cmdline = []
        for arg in cmdline:
            if arg.startswith("archisolabel="):
                src = "/dev/disk/by-label/" + arg.split("=", 1)[1]
                break
    if not src:
        return ""
    rc, out = run(["lsblk", "-no", "PKNAME", os.path.realpath(src)])
    parent = out.strip().splitlines()[0] if rc == 0 and out.strip() else ""
    return "/dev/" + parent if parent else os.path.realpath(src)


def _walk(devices):
    for d in devices or []:
        yield d
        yield from _walk(d.get("children"))


def _free_bytes(path, run=_run):
    """Free bytes on a FAT partition: from its mountpoint, or a private ro mount."""
    rc, out = run(["findmnt", "-no", "TARGET", "--source", path])
    mounted = [l for l in out.splitlines() if l.strip()] if rc == 0 else []
    if mounted:
        try:
            st = os.statvfs(mounted[0])
            return st.f_bavail * st.f_frsize
        except OSError:
            return None
    tmp = tempfile.mkdtemp(prefix="maze-preflight-", dir="/run" if os.access("/run", os.W_OK) else None)
    try:
        rc, _ = run(["mount", "-o", "ro,nosuid,nodev,noexec", "-t", "vfat", path, tmp], timeout=30)
        if rc != 0:
            return None
        try:
            st = os.statvfs(tmp)
            return st.f_bavail * st.f_frsize
        finally:
            run(["umount", tmp], timeout=30)
    finally:
        try:
            os.rmdir(tmp)
        except OSError:
            pass


def scan(run=_run):
    """Read-only survey of the disks. Returns plain data (see evaluate())."""
    facts = {"esps": [], "ntfs": [], "bitlocker": [], "live_disk": live_medium_disk(run)}
    rc, out = run(["lsblk", "-J", "-b", "-o", "PATH,TYPE,PARTTYPE,FSTYPE,SIZE,PKNAME,LABEL"])
    if rc != 0:
        facts["error"] = "lsblk failed"
        return facts
    try:
        devices = json.loads(out).get("blockdevices", [])
    except ValueError:
        facts["error"] = "lsblk output unreadable"
        return facts
    live = facts["live_disk"]
    for d in _walk(devices):
        if d.get("type") != "part":
            continue
        path = d.get("path") or ""
        if live and ("/dev/" + (d.get("pkname") or "")) == live:
            continue
        ptype = (d.get("parttype") or "").lower()
        fstype = (d.get("fstype") or "").lower()
        size = int(d.get("size") or 0)
        if ptype == ESP_GUID or ptype in ESP_MBR:
            facts["esps"].append({"path": path, "size": size,
                                  "free": _free_bytes(path, run) if fstype == "vfat" else None,
                                  "fstype": fstype})
        elif fstype == "ntfs":
            rc, _ = run(["ntfs-3g.probe", "--readwrite", path], timeout=30)
            state = {0: "ok", NTFS_HIBERNATED: "hibernated", NTFS_UNCLEAN: "unclean"}.get(rc, "unknown")
            facts["ntfs"].append({"path": path, "size": size, "state": state,
                                  "label": d.get("label") or ""})
        elif fstype == "bitlocker":
            facts["bitlocker"].append({"path": path, "size": size})
    return facts


# --- what to tell the user ------------------------------------------------------

def _mb(n):
    return "{} MB".format(int(n // MiB))


def _esp_problem(facts):
    """None if some existing ESP can take Maze's boot images, else a description."""
    esps = facts.get("esps") or []
    if not esps:
        return None
    usable = [e for e in esps if e.get("fstype") == "vfat"
              and (e["free"] if e.get("free") is not None else e["size"]) >= ESP_MIN_FREE]
    if usable:
        return None
    return ", ".join("{} ({} free of {})".format(
        e["path"], _mb(e["free"]) if e.get("free") is not None else "?", _mb(e["size"])) for e in esps)


def evaluate(facts, choice=None):
    """Problems for this machine. choice: Calamares' install choice ("alongside",
    "replace", "erase", "manual") once the user has picked one, or None (launcher).
    Returns [{"level": "block"|"warn", "code", "en", "tr"}]."""
    issues = []

    def add(level, code, en, tr):
        issues.append({"level": level, "code": code, "en": en, "tr": tr})

    keeps_other_os = choice in (None, "alongside", "replace", "manual")
    esp = _esp_problem(facts)
    if esp and choice in (None, "alongside", "replace"):
        add("block" if choice else "warn", "esp-too-small",
            "The existing EFI system partition is too small for Maze Linux: {}. Maze needs "
            "at least {} free there for its boot images, so \"Install alongside\" and "
            "\"Replace a partition\" would leave a system that does not start. Use \"Erase "
            "disk\", or \"Manual partitioning\": make a new FAT32 partition of 1 GiB or "
            "more, mount it at /boot and give it the boot flag (Windows keeps its own; "
            "pick the system in the firmware boot menu).".format(esp, _mb(ESP_MIN_FREE)),
            "Mevcut EFI sistem bölümü Maze Linux için çok küçük: {}. Maze'in önyükleme "
            "imajları için orada en az {} boş alan gerekiyor; \"Yanına kur\" ve \"Bir "
            "bölümü değiştir\" açılmayan bir sistem bırakır. \"Diski sil\"i ya da \"Elle "
            "bölümlendirme\"yi kullanın: 1 GiB veya daha büyük yeni bir FAT32 bölümü "
            "oluşturun, /boot'a bağlayın ve boot bayrağını verin (Windows kendi bölümünü "
            "korur; sistemi firmware önyükleme menüsünden seçersiniz).".format(esp, _mb(ESP_MIN_FREE)))

    asleep = [n["path"] for n in facts.get("ntfs") or [] if n["state"] in ("hibernated", "unclean")]
    if asleep and choice in (None, "alongside", "manual"):
        add("block" if choice == "alongside" else "warn", "windows-not-shut-down",
            "Windows was not fully shut down ({}): Fast Startup or hibernation left its "
            "partitions in use, and they cannot be resized safely. Start Windows, turn off "
            "Fast Startup (Control Panel > Power Options > Choose what the power buttons do), "
            "then shut down while holding Shift.".format(", ".join(asleep)),
            "Windows tam kapatılmamış ({}): Hızlı Başlangıç ya da hazırda bekletme "
            "bölümlerini kullanımda bıraktı; güvenle küçültülemezler. Windows'u açın, Hızlı "
            "Başlangıç'ı kapatın (Denetim Masası > Güç Seçenekleri > Güç düğmelerinin "
            "yapacaklarını seçin), sonra Shift'e basılı tutarak Kapat'a tıklayın.".format(", ".join(asleep)))

    if facts.get("bitlocker") and keeps_other_os and choice != "erase":
        add("warn", "bitlocker",
            "BitLocker is on ({}). After Maze is installed, Windows may ask for its "
            "BitLocker recovery key once. Make sure you have it (aka.ms/myrecoverykey), "
            "or suspend BitLocker in Windows first.".format(
                ", ".join(b["path"] for b in facts["bitlocker"])),
            "BitLocker açık ({}). Maze kurulduktan sonra Windows bir kez BitLocker kurtarma "
            "anahtarını isteyebilir. Anahtarın sizde olduğundan emin olun "
            "(aka.ms/myrecoverykey) ya da önce Windows'ta BitLocker'ı askıya alın.".format(
                ", ".join(b["path"] for b in facts["bitlocker"])))
    return issues


# --- the mounted target (after partitioning, before anything is copied) ---------

def _part_type(source, run=_run):
    rc, out = run(["lsblk", "-no", "PARTTYPE", source])
    return out.strip().splitlines()[0].lower() if rc == 0 and out.strip() else ""


def _mount_of(path, run=_run):
    """(source, fstype) of the filesystem mounted exactly at path, or (None, None)."""
    rc, out = run(["findmnt", "-no", "SOURCE,FSTYPE", "--mountpoint", path])
    if rc != 0 or not out.strip():
        return None, None
    src, _, fs = out.strip().splitlines()[0].rpartition(" ")
    return src.strip().split("[")[0], fs.strip()


def check_target(root, run=_run, statvfs=os.statvfs):
    """Blocking problems with the partitions Calamares just mounted under root."""
    issues = []

    def add(code, en, tr):
        issues.append({"level": "block", "code": code, "en": en, "tr": tr})

    root = root.rstrip("/") or "/"
    _, rootfs = _mount_of(root, run)
    if rootfs and rootfs not in ROOT_FILESYSTEMS:
        add("root-fs", "The root file system is {}; Maze supports {}.".format(
                rootfs, ", ".join(sorted(ROOT_FILESYSTEMS))),
            "Kök dosya sistemi {}; Maze {} destekler.".format(rootfs, ", ".join(sorted(ROOT_FILESYSTEMS))))
    try:
        st = statvfs(root)
        free = st.f_bavail * st.f_frsize
        if free < ROOT_MIN_FREE:
            add("root-small",
                "The root partition has {:.1f} GiB free; Maze needs at least {} GiB (the "
                "system, its first update and the apps built during the install).".format(
                    free / GiB, ROOT_MIN_FREE // GiB),
                "Kök bölümde {:.1f} GiB boş alan var; Maze en az {} GiB gerektirir (sistem, ilk "
                "güncellemesi ve kurulumda derlenen uygulamalar).".format(free / GiB, ROOT_MIN_FREE // GiB))
    except OSError:
        pass

    boot = root + "/boot"
    src, fs = _mount_of(boot, run)
    if not src:
        add("esp-missing",
            "No EFI system partition is mounted at /boot. Maze boots from the ESP mounted "
            "at /boot: in manual partitioning, mount a FAT32 partition there and give it "
            "the boot flag.",
            "/boot'a bağlı bir EFI sistem bölümü yok. Maze, /boot'a bağlı ESP'den açılır: "
            "elle bölümlendirmede oraya bir FAT32 bölüm bağlayın ve boot bayrağını verin.")
        return issues
    if fs != "vfat":
        add("esp-fs", "/boot is {} ({}); it must be the FAT32 EFI system partition.".format(fs, src),
            "/boot {} ({}); FAT32 EFI sistem bölümü olmalı.".format(fs, src))
    ptype = _part_type(src, run)
    if ptype and ptype != ESP_GUID and ptype not in ESP_MBR:
        add("esp-type",
            "/boot ({}) is not marked as an EFI system partition, so the firmware will not "
            "boot from it and the boot loader cannot be installed. Give it the boot flag "
            "in manual partitioning.".format(src),
            "/boot ({}) EFI sistem bölümü olarak işaretli değil; firmware oradan açmaz ve "
            "önyükleyici kurulamaz. Elle bölümlendirmede boot bayrağını verin.".format(src))
    try:
        st = statvfs(boot)
        free = st.f_bavail * st.f_frsize
        if free < ESP_MIN_FREE:
            add("esp-full",
                "The EFI system partition ({}) has {} free; Maze needs at least {} there "
                "for its boot images.".format(src, _mb(free), _mb(ESP_MIN_FREE)),
                "EFI sistem bölümünde ({}) {} boş alan var; Maze'in önyükleme imajları için en "
                "az {} gerekiyor.".format(src, _mb(free), _mb(ESP_MIN_FREE)))
    except OSError:
        pass
    return issues


# --- launcher front end -----------------------------------------------------------

def _turkish():
    for var in ("LANGUAGE", "LC_ALL", "LC_MESSAGES", "LANG"):
        v = os.environ.get(var, "")
        if v:
            return v.lower().startswith("tr")
    return False


def gui(issues):
    """Show the launcher warning. Returns True to go on, False if the user cancelled."""
    if not issues:
        return True
    tr = _turkish()
    title = "Maze Linux — kurulumdan önce" if tr else "Maze Linux — before you install"
    head = ("Kurulumu başlatmadan önce şunlara bakın:" if tr
            else "Please read this before starting the installation:")
    body = "\n\n".join("• " + (i["tr"] if tr else i["en"]) for i in issues)
    text = head + "\n\n" + body
    try:
        rc = subprocess.run(["kdialog", "--title", title, "--warningcontinuecancel", text],
                            stdin=subprocess.DEVNULL, timeout=3600).returncode
    except (OSError, subprocess.SubprocessError):
        print(text, file=sys.stderr)
        return True
    return rc != 2      # kdialog: 0 continue, 2 cancel


def main(argv):
    facts = scan()
    issues = evaluate(facts)
    if "--json" in argv:
        print(json.dumps({"facts": facts, "issues": issues}, indent=2, ensure_ascii=False))
        return 0
    if "--gui" in argv:
        return 0 if gui(issues) else 10
    for i in issues:
        print("[{}] {}".format(i["level"], i["tr"] if _turkish() else i["en"]))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
