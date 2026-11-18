/* Maze Linux — Calamares installation slideshow (slideshowAPI 2).
 *
 * Seven 1600x960 slides in two languages (slide-NN.png English,
 * slide-NN.tr.png Turkish), drawn by maze-installer/design/calamares-slides/gen.py
 * (edit the text there and re-render; never edit the PNGs by hand). They are
 * scaled down to the slideshow area (about 880x530 in the 1100x720 window) and
 * letterboxed on the slides' own background colour, so no bars show at other
 * window sizes. mipmap keeps the 2x artwork sharp when it is scaled down.
 */
import QtQuick 2.15
import calamares.slideshow 1.0

Presentation {
    id: presentation

    // slideshowAPI 2: Calamares calls these when the install page is shown
    // and left. The first slide stays up until then.
    // The language is read when the install page appears — by then the user
    // has picked it on the welcome page (Calamares sets the default QLocale).
    property string suffix: ""
    function onActivate() {
        suffix = Qt.locale().name.indexOf("tr") === 0 ? ".tr" : "";
        timer.running = true;
    }
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

    MazeSlide { source: "slide-01" + presentation.suffix + ".png" }   // welcome
    MazeSlide { source: "slide-02" + presentation.suffix + ".png" }   // Secure Boot, LUKS, AppArmor
    MazeSlide { source: "slide-03" + presentation.suffix + ".png" }   // Maze Guard, Maze Cloak, kill switches
    MazeSlide { source: "slide-04" + presentation.suffix + ".png" }   // Haze, HazeDrop, Entropy Shield
    MazeSlide { source: "slide-05" + presentation.suffix + ".png" }   // Maze AI, local models
    MazeSlide { source: "slide-06" + presentation.suffix + ".png" }   // snapshots and rollback
    MazeSlide { source: "slide-07" + presentation.suffix + ".png" }   // updates and tools
}
