/* Maze Linux — Calamares navigation bar (branding.desc: navigation: qml).
 *
 * Cancel on the left, Back / Next on the right: Next is the one primary
 * (filled) button on the screen, Back is outlined, Cancel is a quiet text
 * button — so the next action is always obvious, and the destructive one
 * is never where the eye goes first.
 *
 * Everything — labels, enabled/visible state, the actions — comes from
 * Calamares' ViewManager, exactly as in its own navigation.qml (3.4.2):
 * Next turns into "Install" on the summary page and into "Done" at the end,
 * and the bar hides Back/Next while the installation runs
 * (hide-back-and-next-during-exec in settings.conf).
 */
import io.calamares.ui 1.0
import io.calamares.core 1.0

import QtQuick 2.15
import QtQuick.Controls 2.15
import QtQuick.Layouts 1.15

Rectangle {
    id: navigationBar
    implicitHeight: 68
    height: 68
    color: "#0e0e10"

    Rectangle {
        anchors { left: parent.left; right: parent.right; top: parent.top }
        height: 1
        color: "#1d1d21"
    }

    // A button drawn by hand rather than a QtQuick.Controls Button: Calamares
    // runs as root with whatever Controls style that environment resolves to,
    // and several of those ignore a custom background.
    component NavButton: Rectangle {
        id: button
        property string label: ""
        property string kind: "secondary"     // primary | secondary | quiet
        property string tip: ""
        signal activated()

        readonly property bool hovered: area.containsMouse
        // Calamares' labels carry widget mnemonics ("&Next"); drop the marker.
        readonly property string shown: label.replace(/&(.)/g, "$1")

        implicitWidth: Math.max(kind === "quiet" ? 0 : 116, caption.implicitWidth + 44)
        implicitHeight: 40
        radius: 10
        opacity: enabled ? 1.0 : 0.35
        activeFocusOnTab: true

        color: kind === "primary"
               ? (area.pressed ? "#c9c9cf" : hovered ? "#f5f5f7" : "#e6e6ea")
               : kind === "secondary"
                 ? (area.pressed ? "#26262b" : hovered ? "#1f1f24" : "#161619")
                 : (area.pressed ? "#1f1f24" : hovered ? "#161619" : "transparent")
        border.width: kind === "secondary" ? 1 : 0
        border.color: hovered ? "#4a4a52" : "#303036"
        Behavior on color { ColorAnimation { duration: 110 } }

        Accessible.role: Accessible.Button
        Accessible.name: shown
        Keys.onReturnPressed: if (enabled) activated()
        Keys.onEnterPressed:  if (enabled) activated()
        Keys.onSpacePressed:  if (enabled) activated()

        // Keyboard focus ring.
        Rectangle {
            anchors.fill: parent
            anchors.margins: -3
            radius: parent.radius + 3
            color: "transparent"
            border.width: 2
            border.color: "#8a8a94"
            visible: button.activeFocus
        }

        Text {
            id: caption
            anchors.centerIn: parent
            text: button.shown
            color: button.kind === "primary" ? "#0b0b0c"
                 : button.kind === "quiet" ? (button.hovered ? "#f2f2f4" : "#9a9aa2") : "#ececf0"
            font.pixelSize: 13
            font.weight: Font.DemiBold
        }

        MouseArea {
            id: area
            anchors.fill: parent
            hoverEnabled: true
            enabled: button.enabled
            cursorShape: Qt.PointingHandCursor
            onClicked: button.activated()
        }

        ToolTip.visible: tip !== "" && hovered
        ToolTip.delay: 800
        ToolTip.timeout: 6000
        ToolTip.text: tip
    }

    RowLayout {
        anchors.fill: parent
        anchors.leftMargin: 20
        anchors.rightMargin: 24
        spacing: 10

        NavButton {
            kind: "quiet"
            label: ViewManager.quitLabel
            tip: ViewManager.quitTooltip
            enabled: ViewManager.quitEnabled
            visible: ViewManager.quitVisible
            onActivated: ViewManager.quit()
        }

        Item { Layout.fillWidth: true }

        NavButton {
            kind: "secondary"
            label: ViewManager.backLabel
            enabled: ViewManager.backEnabled
            visible: ViewManager.backAndNextVisible
            onActivated: ViewManager.back()
        }
        NavButton {
            kind: "primary"
            label: ViewManager.nextLabel
            enabled: ViewManager.nextEnabled
            visible: ViewManager.backAndNextVisible
            onActivated: ViewManager.next()
        }
    }
}
