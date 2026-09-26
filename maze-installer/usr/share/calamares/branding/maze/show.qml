/* Maze Linux — Calamares installation slideshow (slideshowAPI 2).
 *
 * Seven 1600x960 slides, drawn by maze-installer/design/calamares-slides/gen.py
 * (edit the text there and re-render; never edit the PNGs by hand). They are
 * scaled down to the slideshow area (about 800x480 in the 980x640 window) and
 * letterboxed on the slides' own background colour, so no bars show at other
 * window sizes. mipmap keeps the 2x artwork sharp when it is scaled down.
 */
import QtQuick 2.15
import calamares.slideshow 1.0

Presentation {
    id: presentation

    // slideshowAPI 2: Calamares calls these when the install page is shown
    // and left. The first slide stays up until then.
    function onActivate() { timer.running = true; }
    function onLeave()    { timer.running = false; }

    Timer {
        id: timer
        interval: 12000
        running: false
        repeat: true
        onTriggered: presentation.goToNextSlide()
    }

    component MazeSlide: Slide {
        property alias source: image.source
        anchors.fill: parent

        Rectangle {
            anchors.fill: parent
            color: "#0a0a0b"
        }
        Image {
            id: image
            anchors.fill: parent
            fillMode: Image.PreserveAspectFit
            smooth: true
            mipmap: true
        }
    }

    MazeSlide { source: "slide-01.png" }   // welcome
    MazeSlide { source: "slide-02.png" }   // Secure Boot, LUKS, AppArmor
    MazeSlide { source: "slide-03.png" }   // Maze Guard, Maze Cloak, kill switches
    MazeSlide { source: "slide-04.png" }   // Haze, HazeDrop, Entropy Shield
    MazeSlide { source: "slide-05.png" }   // Maze AI, local models
    MazeSlide { source: "slide-06.png" }   // snapshots and rollback
    MazeSlide { source: "slide-07.png" }   // updates and tools
}
