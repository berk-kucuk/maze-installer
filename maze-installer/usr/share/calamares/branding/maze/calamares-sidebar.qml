/* Maze Linux — Calamares sidebar (branding.desc: sidebar: qml).
 *
 * A vertical stepper: every page of the installer is a numbered step, the
 * finished ones get a check mark, the current one is highlighted, and the
 * line between two steps fills in as the user moves on. Below the steps a
 * thin bar shows how far along the whole installation is.
 *
 * Uses only what Calamares exposes to branding QML (checked against 3.4.2):
 *   ViewManager      the list of steps (role `display`), currentStepIndex
 *   Branding         styleString(), imagePath(), string()
 *   debug            enabled, toggle(), about()  (the -d debug window)
 * Colours come from the `style:` block of branding.desc so the two cannot
 * drift apart; the rest of the palette is the OLED theme of stylesheet.qss.
 */
import io.calamares.ui 1.0
import io.calamares.core 1.0

import QtQuick 2.15
import QtQuick.Layouts 1.15

Rectangle {
    id: sideBar
    anchors.fill: parent
    implicitWidth: 236
    color: Branding.styleString(Branding.SidebarBackground)

    readonly property color textColor:    Branding.styleString(Branding.SidebarText)
    readonly property color currentColor: Branding.styleString(Branding.SidebarTextCurrent)
    readonly property color pillColor:    Branding.styleString(Branding.SidebarBackgroundCurrent)
    readonly property color lineColor:    "#26262b"
    readonly property color doneColor:    "#d6d6db"
    readonly property color inkColor:     "#0b0b0c"
    readonly property int   current:      ViewManager.currentStepIndex

    // The branding QML has no translation catalogue of its own; follow the
    // language Calamares runs in for the few words it shows.
    //
    // Calamares does not retranslate the sidebar's QML engine when the user
    // picks a language, and Qt.locale() is not a notifying property: poll it,
    // so these words follow the language like the step names do.
    property string lang: Qt.locale().name
    Timer {
        interval: 1000
        running: true
        repeat: true
        onTriggered: sideBar.lang = Qt.locale().name
    }
    function tr(en, turkish) { return sideBar.lang.indexOf("tr") === 0 ? turkish : en }

    // Small text link for the sidebar footer.
    component FooterLink: Text {
        id: link
        signal activated()
        color: area.containsMouse ? sideBar.currentColor : sideBar.textColor
        font.pixelSize: 11
        font.underline: area.containsMouse
        MouseArea {
            id: area
            anchors.fill: parent
            anchors.margins: -4
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: link.activated()
        }
    }

    // Hairline between the sidebar and the page.
    Rectangle {
        anchors { top: parent.top; bottom: parent.bottom; right: parent.right }
        width: 1
        color: "#17171a"
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        // --- product ------------------------------------------------------
        RowLayout {
            Layout.fillWidth: true
            Layout.topMargin: 24
            Layout.leftMargin: 20
            Layout.rightMargin: 16
            Layout.bottomMargin: 20
            spacing: 12

            Image {
                Layout.preferredWidth: 40
                Layout.preferredHeight: 40
                source: "file:/" + Branding.imagePath(Branding.ProductLogo)
                sourceSize.width: 80
                sourceSize.height: 80
                fillMode: Image.PreserveAspectFit
                smooth: true
                mipmap: true
            }
            ColumnLayout {
                Layout.fillWidth: true
                spacing: 2
                Text {
                    Layout.fillWidth: true
                    text: Branding.string(Branding.ProductName)
                    color: sideBar.currentColor
                    font.pixelSize: 15
                    font.weight: Font.DemiBold
                    elide: Text.ElideRight
                }
                Text {
                    Layout.fillWidth: true
                    text: sideBar.tr("Installer", "Kurulum") + " · " + Branding.string(Branding.Version)
                    color: sideBar.textColor
                    font.pixelSize: 11
                    elide: Text.ElideRight
                }
            }
        }

        Rectangle {
            Layout.fillWidth: true
            Layout.leftMargin: 20
            Layout.rightMargin: 20
            Layout.bottomMargin: 12
            Layout.preferredHeight: 1
            color: sideBar.lineColor
        }

        // --- steps --------------------------------------------------------
        Column {
            Layout.fillWidth: true

            Repeater {
                id: steps
                model: ViewManager

                delegate: Item {
                    id: row
                    width: parent ? parent.width : 0
                    height: 44

                    readonly property bool isCurrent: index === sideBar.current
                    readonly property bool isDone:    index <  sideBar.current

                    Rectangle {
                        anchors.fill: parent
                        anchors.leftMargin: 10
                        anchors.rightMargin: 10
                        radius: 8
                        color: row.isCurrent ? sideBar.pillColor : "transparent"
                        Behavior on color { ColorAnimation { duration: 160 } }
                    }

                    // Connector down to the next step's marker.
                    Rectangle {
                        visible: index < steps.count - 1
                        x: dot.x + dot.width / 2 - 1
                        y: dot.y + dot.height + 4
                        width: 2
                        height: row.height - dot.height - 8
                        radius: 1
                        color: row.isDone ? sideBar.doneColor : sideBar.lineColor
                        Behavior on color { ColorAnimation { duration: 220 } }
                    }

                    Rectangle {
                        id: dot
                        x: 22
                        anchors.verticalCenter: parent.verticalCenter
                        width: 22
                        height: 22
                        radius: 11
                        color: row.isDone ? sideBar.doneColor
                             : row.isCurrent ? sideBar.currentColor : "transparent"
                        border.width: (row.isDone || row.isCurrent) ? 0 : 1.5
                        border.color: "#4a4a52"
                        Behavior on color { ColorAnimation { duration: 160 } }

                        Image {
                            anchors.centerIn: parent
                            visible: row.isDone
                            width: 14
                            height: 14
                            source: "checkmark.svg"
                            sourceSize.width: 28
                            sourceSize.height: 28
                        }
                        Text {
                            anchors.centerIn: parent
                            visible: !row.isDone
                            text: index + 1
                            color: row.isCurrent ? sideBar.inkColor : sideBar.textColor
                            font.pixelSize: 11
                            font.weight: Font.Bold
                        }
                    }

                    Text {
                        anchors.left: dot.right
                        anchors.leftMargin: 12
                        anchors.right: parent.right
                        anchors.rightMargin: 18
                        anchors.verticalCenter: parent.verticalCenter
                        text: display
                        color: row.isCurrent ? sideBar.currentColor
                             : row.isDone ? sideBar.doneColor : sideBar.textColor
                        font.pixelSize: 13
                        font.weight: row.isCurrent ? Font.DemiBold : Font.Normal
                        elide: Text.ElideRight
                    }
                }
            }
        }

        Item { Layout.fillHeight: true }

        // --- overall progress + about / log -------------------------------
        ColumnLayout {
            Layout.fillWidth: true
            Layout.leftMargin: 20
            Layout.rightMargin: 20
            Layout.bottomMargin: 18
            spacing: 10

            RowLayout {
                Layout.fillWidth: true
                Text {
                    text: sideBar.tr("Progress", "İlerleme")
                    color: sideBar.textColor
                    font.pixelSize: 11
                }
                Item { Layout.fillWidth: true }
                Text {
                    text: Math.min(sideBar.current + 1, steps.count) + " / " + steps.count
                    color: sideBar.textColor
                    font.pixelSize: 11
                    font.weight: Font.DemiBold
                }
            }
            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: 4
                radius: 2
                color: sideBar.lineColor
                Rectangle {
                    height: parent.height
                    radius: 2
                    color: sideBar.currentColor
                    width: parent.width * (steps.count > 1 ? sideBar.current / (steps.count - 1) : 0)
                    Behavior on width { NumberAnimation { duration: 280; easing.type: Easing.OutCubic } }
                }
            }

            RowLayout {
                Layout.fillWidth: true
                Layout.topMargin: 4
                spacing: 16

                FooterLink {
                    text: sideBar.tr("About", "Hakkında")
                    onActivated: debug.about()
                }
                // The launcher always starts Calamares with -d, so the debug
                // window — the live log of every step — is one click away.
                FooterLink {
                    visible: debug.enabled
                    text: sideBar.tr("Show log", "Logu göster")
                    onActivated: debug.toggle()
                }
                Item { Layout.fillWidth: true }
            }
        }
    }
}
