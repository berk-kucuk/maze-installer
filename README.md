# maze-installer

Maze Linux's **Calamares-based installer**, extracted from the ISO's `airootfs`
overlay into a pacman package. This is the "Install Maze Linux" flow.

## What's inside

| Path | Contents |
| ---- | -------- |
| `usr/local/bin/maze-calamares` | Launcher (XWayland + pkexec; refuses legacy BIOS boot) |
| `etc/calamares/` | `settings.conf` + all module configs |
| `usr/share/calamares/branding/maze/` | True-black OLED Calamares branding |
| `usr/share/maze/install/deploy-to-target.sh` | Driver wired in as a Calamares `shellprocess`: runs `steps/NN-*.sh` in order, times each, collects every warning, writes `/var/log/maze-install-summary.txt` on the target, and **fails the install** on a critical problem (will not boot, disk unlocks without passphrase, passwordless root, leftover NOPASSWD sudo) |
| `usr/share/maze/install/steps/` | The install logic, one file per stage (live-residue removal, user homes, root lock, initramfs, cmdline/UKI/rollback, Secure Boot, services, pacman, apps, AUR, final boot-chain verification, keyring). Re-run chosen stages on a mounted target with `MAZE_DEPLOY_STEPS="70-cmdline-uki 96-verify-boot" deploy-to-target.sh /mnt` |
| `tests/test_deploy.py` | The steps run against a fake target with stubbed `arch-chroot`/`findmnt`/`cryptsetup`/`objcopy`/… — `python -m unittest discover -s tests`. Run by `publish.sh` before every build |
| `usr/local/share/maze/calamares-mount-api.sh` | mount-API helper used by the `shellprocess_mountapi` module |
| `usr/local/share/maze/calamares-strip-keyfile.sh` | keeps the LUKS keyfile out of the initramfs/UKI (`shellprocess_stripkeyfile`) |
| `usr/share/applications/maze-calamares.desktop` | Panel/dock launcher entry |
| `usr/share/pixmaps/maze-installer.png` | Installer icon |

Live-medium package: install it on the ISO. Not needed on an installed system.

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
