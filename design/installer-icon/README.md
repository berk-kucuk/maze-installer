# Installer icon

`gen.py` writes `maze-installer.svg`: the Maze mark (same tile and paths as
maze-branding's `maze-linux-mark.svg`), centred and whole, with its core
square filled and carrying an install sign. Re-render the
package's copies after changing it:

```sh
python3 gen.py
P=../../maze-installer
for s in 16 22 24 32 48 64 128 256 512; do
    rsvg-convert -w $s -h $s maze-installer.svg -o $P/usr/share/icons/hicolor/${s}x${s}/apps/maze-installer.png
done
cp maze-installer.svg $P/usr/share/icons/hicolor/scalable/apps/
rsvg-convert -w 512 -h 512 maze-installer.svg -o $P/usr/share/pixmaps/maze-installer.png
rsvg-convert -w 256 -h 256 maze-installer.svg -o $P/usr/share/calamares/branding/maze/maze-installer-icon.png
```
