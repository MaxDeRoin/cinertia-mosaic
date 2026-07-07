import QtQuick

// One extra output canvas in its own window (multi-monitor mode). The
// chrome bar appears only when the mouse is near the top edge, so a
// fullscreen output looks like a clean multiviewer feed. All state that
// must persist (name, monitor, fullscreen) lives in the main window's
// output model — the buttons here only emit signals, and the model
// writes flow back in through the properties.
Window {
    id: out
    width: 960
    height: 540
    minimumWidth: 480
    minimumHeight: 270
    color: "#0e0e10"
    visible: true
    title: outputName + " — Mosaic"

    property string outputName: "Output"
    property bool fullscreenOn: false
    property int screenIndex: 0
    // True while sidebar source clicks land on this canvas.
    property bool isTarget: false

    // Shared app settings, passed straight through to the canvas.
    property bool snapOn: false
    property bool wheelRotateOn: true
    property bool showTileNames: true
    property int tileGap: 8
    property var availableSources: []

    readonly property alias canvas: tc

    signal closeRequested()
    signal fullscreenToggled(bool on)
    signal screenPicked(int index)
    signal targetRequested()
    signal tilesMutated()

    // Set while the whole app quits: closing then must NOT delete this
    // output from the session that was just saved.
    property bool appQuitting: false
    onClosing: {
        if (!appQuitting)
            closeRequested()
    }

    // Fullscreen dance mirrors the main window: dip through windowed when
    // moving between monitors, restore the windowed geometry afterwards.
    property rect savedGeom: Qt.rect(0, 0, 0, 0)

    // The windowed geometry worth saving in the session, even while the
    // output is currently fullscreen.
    function windowedRect() {
        return (visibility === Window.FullScreen && savedGeom.width > 200)
            ? savedGeom : Qt.rect(x, y, width, height)
    }

    onFullscreenOnChanged: Qt.callLater(applyMode)
    onScreenIndexChanged: {
        if (fullscreenOn)
            Qt.callLater(applyMode)
    }
    Component.onCompleted: {
        if (fullscreenOn)
            Qt.callLater(applyMode)
    }

    function applyMode() {
        if (visibility !== Window.FullScreen && width > 200)
            savedGeom = Qt.rect(x, y, width, height)
        if (fullscreenOn) {
            if (visibility === Window.FullScreen)
                visibility = Window.Windowed
            const screens = Qt.application.screens
            out.screen = screens[Math.min(screenIndex, screens.length - 1)]
            visibility = Window.FullScreen
        } else {
            visibility = Window.Windowed
            if (savedGeom.width > 200) {
                x = savedGeom.x
                y = savedGeom.y
                width = savedGeom.width
                height = savedGeom.height
            }
        }
    }

    // Each output window handles its own keys: Esc cancels tile overlays
    // first, then leaves fullscreen; F11 toggles fullscreen.
    Item {
        id: outKeys
        focus: true
        Keys.onEscapePressed: {
            if (out.menuOpen) {
                out.menuOpen = false
                return
            }
            if (!tc.cancelOverlays() && out.fullscreenOn)
                out.fullscreenToggled(false)
        }
        Keys.onPressed: event => {
            if (event.key === Qt.Key_F11) {
                out.fullscreenToggled(!out.fullscreenOn)
                event.accepted = true
            }
        }
    }

    TileCanvas {
        id: tc
        anchors.fill: parent
        snapEnabled: out.snapOn
        wheelRotate: out.wheelRotateOn
        globalShowName: out.showTileNames
        tileGap: out.tileGap
        availableSources: out.availableSources
        focusTarget: outKeys
        emptyHint: out.isTarget
            ? "This canvas is receiving — click sources in the main window to add them here"
            : "Empty canvas — pick it under CANVASES in the main window (or hover the top edge and open the ⋯ menu), then click sources"
        onTilesMutated: out.tilesMutated()
    }

    // -------------------------------------------------- ⋯ dropdown menu
    // All output controls live in a dropdown so nothing overlays the
    // tiles: hovering the top edge reveals only a small ⋯ button in the
    // corner, and the menu itself stacks above the tile layer with a
    // full-window click-catcher underneath — no click, press or drag
    // can leak through to a tile while it is open.
    property bool menuOpen: false

    // Top-edge hover zone reveals the ⋯ button (hover only, never
    // intercepts clicks aimed at tiles).
    Item {
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        height: 44
        HoverHandler { id: topZone }
    }

    component OutBtn: Rectangle {
        property string label
        property bool active: false
        signal activated()
        width: Math.max(obText.width + 14, 24)
        height: 24
        radius: 3
        color: active ? "#22303e" : obHover.hovered ? "#2a2a30" : "transparent"
        border.width: active ? 1 : 0
        border.color: "#3d7eff"

        Text {
            id: obText
            anchors.centerIn: parent
            text: parent.label
            color: "#d8d8dc"
            font.pixelSize: 11
        }
        HoverHandler { id: obHover }
        TapHandler { gesturePolicy: TapHandler.ReleaseWithinBounds; onTapped: parent.activated() }
    }

    Rectangle {
        id: menuBtn
        anchors.top: parent.top
        anchors.right: parent.right
        anchors.margins: 8
        width: 32
        height: 26
        radius: 3
        color: out.menuOpen ? "#22303e"
             : menuBtnHover.hovered ? "#2a2a30" : "#141417ee"
        border.width: 1
        border.color: out.menuOpen ? "#3d7eff" : "#2a2a2e"
        visible: opacity > 0
        opacity: (topZone.hovered || menuBtnHover.hovered || out.menuOpen)
                 ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 150 } }

        Text {
            anchors.centerIn: parent
            text: "⋯"
            color: "#d8d8dc"
            font.pixelSize: 15
        }
        HoverHandler { id: menuBtnHover }
        // Exclusive grab (ReleaseWithinBounds): the press must never
        // fall through to a tile sitting under the button.
        TapHandler {
            gesturePolicy: TapHandler.ReleaseWithinBounds
            onTapped: out.menuOpen = !out.menuOpen
        }
    }

    // Click-away catcher: while the menu is open it owns every click
    // outside the panel, so tiles can't be hit by accident.
    MouseArea {
        anchors.fill: parent
        visible: out.menuOpen
        onClicked: out.menuOpen = false
    }

    Rectangle {
        visible: out.menuOpen
        anchors.top: menuBtn.bottom
        anchors.topMargin: 4
        anchors.right: parent.right
        anchors.rightMargin: 8
        width: 200
        height: menuCol.height + 20
        radius: 6
        color: "#1a1a1e"
        border.width: 1
        border.color: "#2a2a2e"

        // Swallow every press on the panel body so nothing reaches the
        // tiles underneath (same guard as the settings panel).
        MouseArea { anchors.fill: parent }

        Column {
            id: menuCol
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.margins: 10
            spacing: 6

            Text {
                text: out.outputName
                color: "#e8e8ea"
                font.pixelSize: 13
                font.weight: Font.DemiBold
            }

            OutBtn {
                width: menuCol.width
                label: out.isTarget ? "● Receiving sources"
                                    : "Send sources here"
                active: out.isTarget
                onActivated: out.targetRequested()
            }

            Text {
                visible: Qt.application.screens.length > 1
                text: "MONITOR"
                color: "#5a5a60"
                font.pixelSize: 9
            }
            Flow {
                visible: Qt.application.screens.length > 1
                width: menuCol.width
                spacing: 4

                Repeater {
                    model: Qt.application.screens.length > 1
                           ? Qt.application.screens.length : 0

                    OutBtn {
                        required property int index
                        label: String(index + 1)
                        active: out.screenIndex === index
                        onActivated: out.screenPicked(index)
                    }
                }
            }

            OutBtn {
                width: menuCol.width
                label: out.fullscreenOn ? "Exit fullscreen" : "Fullscreen"
                onActivated: {
                    out.menuOpen = false
                    out.fullscreenToggled(!out.fullscreenOn)
                }
            }
            OutBtn {
                width: menuCol.width
                label: "Close this canvas"
                onActivated: out.closeRequested()
            }
        }
    }
}
