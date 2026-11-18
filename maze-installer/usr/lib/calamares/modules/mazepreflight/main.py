#!/usr/bin/env python3
#
# Maze Linux — Calamares job: refuse an installation that cannot work, as early
# as it can be known. The checks themselves live in
# /usr/share/maze/install/preflight.py (shared with the launcher's warning).
#
# Two instances in settings.conf, by `phase` in the job configuration:
#   system  FIRST job of the exec phase, before `partition`: nothing has been
#           written yet. Uses the install choice (Global Storage
#           partitionChoices.install) and the disks as they are now — e.g. a
#           Windows ESP too small for Maze's boot images under "Install
#           alongside", or Windows hibernated by Fast Startup.
#   target  right after `mount`, before `unpackfs`: the partitions now exist
#           and are mounted, so the exact layout is checked (ESP at /boot,
#           its type and free space, the root file system and its size).
#           Partitioning has happened by then, but nothing has been copied and
#           no existing partition's data was touched beyond what the user
#           chose on the partition page.
# A problem fails the job with a message saying what is wrong and what to do.

import os
import sys

import libcalamares

LIBRARY = "/usr/share/maze/install"


def _turkish():
    try:
        langs = libcalamares.utils.gettext_languages() or []
    except Exception:
        langs = []
    return any(str(l).lower().startswith("tr") for l in langs)


def T(en, tr):
    return tr if _turkish() else en


def pretty_name():
    return T("Checking the disk layout", "Disk düzeni kontrol ediliyor")


def _load():
    path = str((libcalamares.job.configuration or {}).get("library", LIBRARY))
    if path not in sys.path:
        sys.path.insert(0, path)
    import preflight
    return preflight


def run():
    conf = libcalamares.job.configuration or {}
    phase = str(conf.get("phase", "system"))
    try:
        pf = _load()
    except Exception as e:
        # The checks are a safety net, not part of the install itself: if they
        # cannot even be loaded, say so in the log and let the install go on.
        libcalamares.utils.warning("mazepreflight: checks unavailable ({}); continuing".format(e))
        return None

    if phase == "target":
        root = libcalamares.globalstorage.value("rootMountPoint")
        if not root or not os.path.isdir(root):
            return None
        issues = pf.check_target(root)
    else:
        choices = libcalamares.globalstorage.value("partitionChoices") or {}
        choice = str(choices.get("install", "") or "") or None
        facts = pf.scan()
        libcalamares.utils.debug("mazepreflight: install choice {!r}; found {!r}".format(choice, facts))
        issues = pf.evaluate(facts, choice)

    blocks = [i for i in issues if i["level"] == "block"]
    for i in issues:
        log = libcalamares.utils.warning if i["level"] == "block" else libcalamares.utils.debug
        log("mazepreflight [{}] {}: {}".format(phase, i["code"], i["en"]))
    if not blocks:
        return None

    tr = _turkish()
    title = (T("Maze Linux cannot be installed with this disk layout",
               "Maze Linux bu disk düzeniyle kurulamaz"))
    if phase == "target":
        note = T("The partitions were created, but nothing was copied yet. Start the installer "
                 "again and change the layout on the partition page.",
                 "Bölümler oluşturuldu ama henüz hiçbir şey kopyalanmadı. Kurulum programını yeniden "
                 "başlatın ve bölümlendirme sayfasında düzeni değiştirin.")
    else:
        note = T("Nothing on the disk has been changed. Start the installer again and choose "
                 "differently on the partition page.",
                 "Diskte hiçbir şey değiştirilmedi. Kurulum programını yeniden başlatın ve "
                 "bölümlendirme sayfasında farklı bir seçim yapın.")
    body = "\n\n".join("• " + (i["tr"] if tr else i["en"]) for i in blocks)
    return (title, body + "\n\n" + note)
