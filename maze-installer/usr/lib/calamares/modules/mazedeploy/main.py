#!/usr/bin/env python3
#
# Maze Linux — Calamares job: finalise the installed system, one step at a time.
#
# Drives /usr/share/maze/install/deploy-to-target.sh:
#
#   --list                     which steps exist (name, timeout, weight, titles)
#   --begin   ROOT SECURITY    check the target, clear any earlier run's state
#   --step    NAME ROOT SEC    once per step, each in its own process
#   --summary ROOT             summary; non-zero when the install is not safe
#
# so that, instead of one opaque "Shell Processes Job" that sat there for half
# an hour, the user sees which step is running, what it is doing right now,
# how many warnings it raised, and — when something goes wrong — which step
# it was and where its log is. Every output line also goes to the Calamares
# log (the debug window, and ~/.cache/calamares/session.log).
#
# A step that crashes or hangs does not stop the others (deploy-to-target.sh
# records it and moves on); the install is reported FAILED at the end if any
# step failed or reported a critical problem, exactly as before.

import os
import queue
import shlex
import signal
import subprocess
import threading
import time

import libcalamares

DEFAULT_SCRIPT = "/usr/share/maze/install/deploy-to-target.sh"
# On top of each step's own timeout (enforced by deploy-to-target.sh): only if
# that one fails to fire does this module kill the step itself.
WATCHDOG_GRACE = 300

_status = ""


def _turkish():
    try:
        langs = libcalamares.utils.gettext_languages() or []
    except Exception:
        langs = []
    return any(str(l).lower().startswith("tr") for l in langs)


def T(en, tr):
    return tr if _turkish() else en


def pretty_name():
    return T("Configuring Maze Linux", "Maze Linux yapılandırılıyor")


def pretty_status_message():
    return _status or pretty_name()


def _set_status(text, progress):
    global _status
    _status = text
    # Calamares re-reads pretty_status_message() when the progress is set.
    libcalamares.job.setprogress(max(0.0, min(1.0, progress)))


def _debug(line):
    libcalamares.utils.debug(line)


def _call(argv, env=None):
    """Run a short driver command; log its output; return (rc, output)."""
    try:
        p = subprocess.run(argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                           stderr=subprocess.STDOUT, text=True, errors="replace",
                           timeout=600, env=env)
    except (OSError, subprocess.SubprocessError) as e:
        return 127, str(e)
    for line in p.stdout.splitlines():
        _debug("[maze] " + line)
    return p.returncode, p.stdout


def _list_steps(script):
    rc, out = _call([script, "--list"])
    if rc != 0:
        return None, out
    steps = []
    for line in out.splitlines():
        f = line.split("\t")
        if len(f) < 5 or not f[0]:
            continue
        name, timeout, weight, title, title_tr = f[:5]
        steps.append({
            "name": name,
            "timeout": int(timeout) if timeout.isdigit() else 1800,
            "weight": max(1, int(weight)) if weight.isdigit() else 1,
            "title": (title_tr if _turkish() else title) or title or name,
        })
    return steps, out


SECURITY_FEATURES = ("apparmor", "firewalld", "auditd", "clamav")


def _options(source):
    """The opt-* ids ticked on the Options page (netinstall@mazeoptions), or None
    when the page was not part of this install. netinstall writes the ticked
    "packages" of each instance to Global Storage packageOperations; the hidden,
    always-ticked opt-page-seen tells "unticked everything" from "never shown"."""
    ops = libcalamares.globalstorage.value("packageOperations") or []
    names = set()
    for op in ops:
        if not isinstance(op, dict) or op.get("source") != source:
            continue
        for key in ("install", "try_install"):
            for p in op.get(key) or []:
                name = p.get("package") if isinstance(p, dict) else p
                if isinstance(name, str) and name.startswith("opt-"):
                    names.add(name)
    if "opt-page-seen" not in names:
        return None
    names.discard("opt-page-seen")
    return names


def _reader(stream, q):
    for line in stream:
        q.put(line.rstrip("\n"))
    q.put(None)


def _run_step(script, step, root, security, label, base, span, env=None):
    """Run one step; stream its output. Returns (result, seconds, warnings)."""
    name = step["name"]
    argv = [script, "--step", name, root, security]
    try:
        proc = subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, text=True, errors="replace",
                                start_new_session=True, env=env)
    except OSError as e:
        libcalamares.utils.warning("mazedeploy: cannot start {}: {}".format(name, e))
        return "failed", 0, 0

    q = queue.Queue()
    threading.Thread(target=_reader, args=(proc.stdout, q), daemon=True).start()

    t0 = time.monotonic()
    deadline = t0 + step["timeout"] + WATCHDOG_GRACE
    result, seconds, warnings = None, 0, 0
    detail, last_shown = "", 0.0
    while True:
        try:
            line = q.get(timeout=1.0)
        except queue.Empty:
            line = ""
            if time.monotonic() > deadline:
                libcalamares.utils.warning("mazedeploy: {} outlived its timeout; killing it".format(name))
                try:
                    os.killpg(proc.pid, signal.SIGKILL)
                except OSError:
                    pass
                result = "timeout"
                break
        if line is None:
            break
        if line.startswith("@@maze-step "):
            f = line.split()
            if len(f) >= 5 and f[1] == name:
                result = f[2]
                seconds = int(f[3]) if f[3].isdigit() else 0
                warnings = int(f[4]) if f[4].isdigit() else 0
            continue
        if line:
            _debug("[maze:{}] {}".format(name, line))
            if "WARNING:" in line or "CRITICAL:" in line:
                warnings += 1
            # What the step says it is doing — its own log() lines, not the
            # raw output of pacman or makepkg — goes under the progress bar.
            if line.startswith("[maze-deploy] ") and not line.startswith("[maze-deploy] ===="):
                detail = line[len("[maze-deploy] "):].strip()
        now = time.monotonic()
        if now - last_shown >= 0.5:
            last_shown = now
            text = label
            if warnings:
                text += " · " + T("{} warning(s)", "{} uyarı").format(warnings)
            if detail:
                text += " — " + (detail if len(detail) <= 90 else detail[:87] + "…")
            elapsed = now - t0
            # Inside a step, creep towards (never reach) its share of the bar,
            # so a long step still visibly moves.
            frac = elapsed / (elapsed + 120.0)
            _set_status(text, base + span * 0.9 * frac)

    try:
        proc.wait(timeout=30)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except OSError:
            pass
    if result is None:
        result = "failed"
    return result, seconds, warnings


def run():
    root = libcalamares.globalstorage.value("rootMountPoint")
    if not root or not os.path.isdir(root):
        return (T("No target system to configure", "Yapılandırılacak hedef sistem yok"),
                T("The installer did not mount the new system (rootMountPoint is '{}').",
                  "Kurulum programı yeni sistemi bağlamadı (rootMountPoint: '{}').").format(root))

    conf = libcalamares.job.configuration or {}
    script = str(conf.get("script", DEFAULT_SCRIPT))
    security = str(conf.get("security", "all")) or "all"
    env = None
    options = _options(str(conf.get("optionsSource", "netinstall@mazeoptions")))
    if options is not None:
        # The Options page decides. Security features travel the way they always
        # did (the driver's security argument, "none" when all are off — empty
        # would mean "all"); everything else as MAZE_OPTIONS for the steps.
        picked = [f for f in SECURITY_FEATURES if "opt-" + f in options]
        security = ",".join(picked) or "none"
        env = dict(os.environ, MAZE_OPTIONS=" ".join(sorted(options)))
        libcalamares.utils.debug("mazedeploy: options {} / security {}".format(sorted(options), security))
    else:
        libcalamares.utils.debug("mazedeploy: no Options page in this install; defaults apply")
    if not os.access(script, os.X_OK):
        return (T("Maze configuration script is missing", "Maze yapılandırma betiği bulunamadı"), script)

    steps, out = _list_steps(script)
    if not steps:
        return (T("Maze configuration could not start", "Maze yapılandırması başlatılamadı"),
                out[-3000:] if out else script)

    _set_status(T("Checking the new system", "Yeni sistem kontrol ediliyor"), 0.0)
    rc, out = _call([script, "--begin", root, security], env)
    if rc != 0:
        return (T("Maze configuration could not start", "Maze yapılandırması başlatılamadı"),
                out[-3000:])

    total = float(sum(s["weight"] for s in steps))
    done = 0.0
    failed = []
    for i, step in enumerate(steps, 1):
        label = "[{}/{}] {}".format(i, len(steps), step["title"])
        base, span = done / total, step["weight"] / total
        _set_status(label, base)
        libcalamares.utils.debug("mazedeploy: === {} ({}) ===".format(step["name"], step["title"]))
        result, seconds, warnings = _run_step(script, step, root, security, label, base, span, env)
        libcalamares.utils.debug("mazedeploy: {} -> {} in {}s, {} warning(s)".format(
            step["name"], result, seconds, warnings))
        if result in ("failed", "timeout", "critical"):
            failed.append((step, result))
            libcalamares.utils.warning("mazedeploy: step {} {}".format(step["name"], result))
        done += step["weight"]
        _set_status(label, done / total)

    _set_status(T("Writing the installation summary", "Kurulum özeti yazılıyor"), 1.0)
    rc, summary = _call([script, "--summary", root], env)
    summary = "\n".join(l[len("[maze-deploy] "):] if l.startswith("[maze-deploy] ") else l
                        for l in summary.splitlines()).strip()
    try:
        libcalamares.globalstorage.insert("mazeDeploySummary", summary)
    except Exception:
        pass

    if rc != 0:
        words = {"failed": T("stopped with an error", "hata vererek durdu"),
                 "timeout": T("did not finish in time", "zamanında bitmedi"),
                 "critical": T("found a critical problem", "kritik bir sorun buldu")}
        head = "\n".join("• {} — {}".format(s["title"], words[r]) for s, r in failed)
        # The failed job stops Calamares before `umount`, so the new system is
        # still mounted: the steps that went wrong (and the final boot check)
        # can be run again right here, in a terminal of the live session, with
        # the same choices.
        rerun = [s["name"] for s, _ in failed]
        if any(s["name"] == "96-verify-boot" for s in steps) and "96-verify-boot" not in rerun:
            rerun.append("96-verify-boot")
        envs = ["MAZE_DEPLOY_STEPS=" + shlex.quote(" ".join(rerun))]
        if env and "MAZE_OPTIONS" in env:
            envs.append("MAZE_OPTIONS=" + shlex.quote(env["MAZE_OPTIONS"]))
        repair = "sudo env {} {} {} {}".format(" ".join(envs), shlex.quote(script),
                                              shlex.quote(root), shlex.quote(security))
        head += "\n\n" + T("To try those steps again (open a terminal, keep the installer open):",
                           "Bu adımları yeniden denemek için (bir terminal açın, kurulum programını kapatmayın):") \
            + "\n    " + repair
        return (T("Maze Linux was installed, but it is NOT safe to use yet",
                  "Maze Linux kuruldu, ancak henüz güvenle KULLANILAMAZ"),
                (head + "\n\n" if head else "")
                + T("Do not boot the new system as it is. Every step's log is in "
                    "/var/log/maze-installer/ on the new system; the installer's own log "
                    "is ~/.cache/calamares/session.log.",
                    "Yeni sistemi bu haliyle başlatmayın. Her adımın logu yeni sistemde "
                    "/var/log/maze-installer/ altında; kurulum programının kendi logu "
                    "~/.cache/calamares/session.log dosyasında.")
                + "\n\n" + summary[-6000:])
    return None
