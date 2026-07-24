# Maintainer: Berk Küçük <dev.berkkucukk@gmail.com>
#
# maze-installer — Maze Linux's Calamares-based installer, extracted from the
# ISO's airootfs overlay into a pacman package. Ships the launcher, the whole
# Calamares config + Maze branding, and deploy-to-target.sh (all Maze install
# logic). Live-medium package: it is what turns "Install Maze Linux" into a
# finished install.
#
# Payload lives verbatim under ./maze-installer/ (a mirror of the target
# filesystem); package() copies it into $pkgdir. Paths are kept at their
# current locations so the package is a drop-in for the airootfs files.

pkgname=maze-installer
pkgver=2.0.0
pkgrel=2
pkgdesc="Maze Linux Calamares installer — launcher, config, branding and deploy-to-target logic"
arch=('any')
url="https://mazelinux.berkkucukk.com.tr"
license=('GPL3')
depends=(
  'calamares'
  'polkit'
  'xorg-xhost'
)
optdepends=(
  'maze-branding: Plymouth/SDDM theming applied to the installed system'
)
# Settings are tightly coupled to the package version (new pages/modules
# require a matching config) — this is NOT a user-editable backup.
backup=()
source=()

package() {
  # Copy the payload tree (./maze-installer/{etc,usr}/...) into the package root.
  cp -a "${startdir}/maze-installer/etc" "${pkgdir}/etc"
  cp -a "${startdir}/maze-installer/usr" "${pkgdir}/usr"
  chmod 755 "${pkgdir}/usr/local/bin/maze-calamares"
  chmod 755 "${pkgdir}/usr/share/maze/install/deploy-to-target.sh"
  chmod 755 "${pkgdir}/usr/local/share/maze/calamares-mount-api.sh"
}
