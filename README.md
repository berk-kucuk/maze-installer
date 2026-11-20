# maze-installer

Maze Linux's **Calamares-based installer**, extracted from the ISO's `airootfs`
overlay into a pacman package. This is the "Install Maze Linux" flow.

## What's inside

| Path | Contents |
| ---- | -------- |
| `usr/local/bin/maze-calamares` | Launcher (XWayland + pkexec; refuses legacy BIOS boot; runs the preflight warning before Calamares opens) |
| `etc/calamares/` | `settings.conf` + all module configs |
| `usr/share/calamares/branding/maze/` | True-black OLED Calamares branding; the installation slideshow in English (`slide-NN.png`) and Turkish (`slide-NN.tr.png`), picked by the installer's language — regenerate both with `design/calamares-slides/gen.py BRANDING_DIR en|tr` + `rsvg-convert` |
| `usr/share/calamares/branding/maze/calamares-{sidebar,navigation}.qml` | QML panels: numbered stepper with check marks and overall progress on the left; Cancel / Back / Next (Next is the one primary button) at the bottom. "Show log" opens the live debug log |
| `usr/lib/calamares/modules/mazedeploy/` | Calamares job module that runs `deploy-to-target.sh` **one step at a time**: the progress bar shows `[n/N] step title · warnings — what it is doing now`, every output line goes to the Calamares log, and a failure names the step and where its log is |
| `etc/calamares/modules/netinstall_mazeoptions.conf` | The **Options** page (after Users): security features (AppArmor, firewalld, auditd, ClamAV), services (Ollama, Tor, CUPS, Bluetooth, SSH server), the AUR apps (ONLYOFFICE, Joplin, Upscayl, Session), fastest mirrors (reflector) and verbose boot. Calamares' netinstall tree is used for its check boxes only — nothing is installed from it; `mazedeploy` hands the choices to the steps as `MAZE_OPTIONS` (`maze_option NAME on|off` in the steps). Defaults equal the behaviour from before the page: an untouched page changes nothing. Unticked services and security features are disabled, unticked apps removed |
| `usr/share/maze/install/steps/97-install-report.sh` | Writes a one-time first-login notification onto the target: when the install had warnings or problems, the first login says so and "Show" opens `/var/log/maze-install-summary.txt` |
| `usr/share/maze/install/preflight.py` + `usr/lib/calamares/modules/mazepreflight/` | Checks that stop an install that cannot work **before the disk is touched**: a reused EFI partition with less than 400 MiB free (Windows' ESP under "Install alongside"/"Replace" — Calamares does not check it there, and the result did not boot), Windows left hibernated by Fast Startup (cannot be resized), and — once the partitions are mounted, before anything is copied — the ESP at `/boot` (FAT32, ESP type, free space) and a root partition of at least 25 GiB on btrfs/ext4/xfs/f2fs. The launcher shows the same findings (plus BitLocker) as a warning before Calamares opens. `preflight.py --json` prints what it found |
| `usr/share/maze/install/deploy-to-target.sh` | The step driver (`--list`, `--begin`, `--step NAME`, `--summary`; or `deploy-to-target.sh TARGET` for a whole run). Each step runs in its **own bash process under its own timeout** (`# @timeout`), with its own log; a step that crashes or hangs is recorded and the next one still runs. Writes `/var/log/maze-installer/` on the target (`steps/NN-name.log`, `steps.tsv`, `warnings.txt`, `critical.txt`, `summary.txt`, plus Calamares' `calamares-session.log`) and **fails the install** if a step failed or found a critical problem (will not boot, disk unlocks without passphrase, passwordless root, leftover NOPASSWD sudo) |
| `usr/share/maze/install/steps/` | The install logic, one file per stage. A header says what the progress bar shows and how the step runs: `# @title`/`# @title.tr`, `# @timeout`, `# @weight`, and `# @exports VAR…` — the only values handed on to later steps. `# @library` files (00-setup, 10-helpers, `*-functions`) only define things and load before every step. Re-run chosen stages on a mounted target with `MAZE_DEPLOY_STEPS="70-cmdline-uki 96-verify-boot" deploy-to-target.sh /mnt` |
| `tests/` | `test_deploy.py`: the steps run against a fake target with stubbed `arch-chroot`/`findmnt`/`cryptsetup`/`objcopy`/…; `test_mazedeploy_module.py`: the Calamares module against a stand-in `libcalamares`; `test_preflight.py`: the preflight on fake machines (Windows ESP, hibernated NTFS, BitLocker, live USB, mounted targets). `python -m unittest discover -s tests`. Run by `publish.sh` before every build |
| `usr/local/share/maze/calamares-mount-api.sh` | mount-API helper used by the `shellprocess_mountapi` module |
| `usr/local/share/maze/calamares-strip-keyfile.sh` | keeps the LUKS keyfile out of the initramfs/UKI (`shellprocess_stripkeyfile`) |
| `usr/share/applications/maze-calamares.desktop` | Panel/dock launcher entry |
| `usr/share/icons/hicolor/*/apps/maze-installer.*` (+ `usr/share/pixmaps/maze-installer.png`) | Installer icon — the Maze mark, whole and centred, its core square lit (OLED, in the Maze app-icon family) and carrying an install sign; every size plus scalable SVG; also Calamares' window icon. Source: `design/installer-icon/gen.py` |

Live-medium package: install it on the ISO. Not needed on an installed system.

## Installation

> **Live ISO only.** maze-installer is the installer of the Maze Linux live
> ISO. It is deliberately *not* part of `maze-meta` and must not be installed
> on an installed system: it carries the live session's Calamares setup.

### From the Maze repository

The Maze Linux ISO profile lists `maze-installer` in `packages.x86_64`, and
mkarchiso pulls it from `[mazelinux]` like any other package. An ISO profile of
your own gets it the same way once its `pacman.conf` has the repository:

```ini
[mazelinux]
SigLevel = Required DatabaseOptional
Server = https://mazerepo.berkkucukk.com.tr/packages
```

The build host must trust the Maze signing key (`7C4D515A6B930CB04794CEF6147C8159B3E2EE5F`):

```bash
curl -O https://mazerepo.berkkucukk.com.tr/packages/mazelinux.gpg
sudo pacman-key --add mazelinux.gpg
sudo pacman-key --lsign-key 7C4D515A6B930CB04794CEF6147C8159B3E2EE5F
```

### Build from source

```bash
sudo pacman -S --needed base-devel git
git clone https://github.com/berk-kucuk/maze-installer.git
cd maze-installer
./build.sh --repo ../MazeLinux/localrepo   # build + add to the ISO's local repo
```

## Layout & building

```
maze-installer/
├── PKGBUILD          # build script
├── build.sh          # wrapper: build [+ --install / + --repo DIR]
├── README.md
└── maze-installer/   # payload — verbatim mirror of the target filesystem
    ├── etc/calamares/...
    └── usr/...
```

```sh
./build.sh                                  # -> maze-installer-<pkgver>-<pkgrel>-any.pkg.tar.zst
./build.sh --repo ../MazeLinux/localrepo    # build + add to the ISO's local repo
```

## Notes

- `deploy-to-target.sh` reads several source files that live on the live medium
  (os-release, skel `.zshrc`, wallpapers, service units, mac-changer units, …) and
  copies them onto the target. Those source files are supplied by the other Maze
  packages (`maze-branding`, `maze-plasma-config`, `maze-tools`) and by build
  hooks — this package owns only the installer itself.

### TRIM on an encrypted disk (on by default)

On an encrypted install the disk passes TRIM (discard) through the LUKS
layer: `allow-discards` on the kernel command line (`cryptdevice=…:…:allow-discards`),
`discard` in `/etc/crypttab`, and — when the passphrase allows it — the LUKS2
header flag. Without it, cheap DRAM-less/QLC SSDs never get their free blocks
back and large writes stall the whole system for seconds at a time.

What it costs: someone holding the disk can see **which blocks are free** —
from that, roughly how full the disk is, the file-system type and how it is
used over time. Not a single byte of any file. Ubuntu and Fedora ship the same
default (cryptsetup FAQ 5.19 describes the trade-off).

To turn it off on an installed system:

1. remove `:allow-discards` (or `,allow-discards`) from the `cryptdevice=` entry
   in `/etc/kernel/cmdline`, and `discard` from the options in `/etc/crypttab`;
2. clear the header flag (asks for the passphrase):
   `sudo cryptsetup --persistent refresh <name>` (the name is the `/dev/mapper/…`
   one: `lsblk -o NAME,TYPE | grep crypt`);
3. rebuild and re-sign the boot image: `sudo maze-boot-check --repair`;
4. reboot, then check: `sudo cryptsetup luksDump <device> | grep -i flags`
   shows no `allow-discards`, and `lsblk --discard` shows 0 in DISC-GRAN for the
   crypt device.

## License

Copyright © 2026 Berk Küçük

Released under the GNU General Public License v3.0 — see [LICENSE](LICENSE).
