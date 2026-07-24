# maze-installer

Maze Linux's **Calamares-based installer**, extracted from the ISO's `airootfs`
overlay into a pacman package. This is the "Install Maze Linux" flow.

## What's inside

| Path | Contents |
| ---- | -------- |
| `usr/local/bin/maze-calamares` | Launcher (XWayland + pkexec; refuses legacy BIOS boot) |
| `etc/calamares/` | `settings.conf` + all module configs |
| `usr/share/calamares/branding/maze/` | True-black OLED Calamares branding |
| `usr/share/maze/install/deploy-to-target.sh` | **All** Maze install logic (branding, Plymouth, kernel params, Secure Boot / MOK signing, AUR apps, services) — wired in as a Calamares `shellprocess` |
| `usr/local/share/maze/uefi-warning.qss` | Styling for the UEFI-required warning dialog |
| `usr/local/share/maze/calamares-mount-api.sh` | mount-API helper used by the `shellprocess_mountapi` module |
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
./build.sh                                  # -> maze-installer-1.0.0-1-any.pkg.tar.zst
./build.sh --repo ../MazeLinux/localrepo    # build + add to the ISO's local repo
```

## Notes

- `deploy-to-target.sh` reads several source files that live on the live medium
  (os-release, skel `.zshrc`, wallpapers, service units, mac-changer units, …) and
  copies them onto the target. Those source files are supplied by the other Maze
  packages (`maze-branding`, `maze-plasma-config`, `maze-tools`) and by build
  hooks — this package owns only the installer itself.
