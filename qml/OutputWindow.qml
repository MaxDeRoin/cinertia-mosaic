import QtQuick
import Mosaic

// One extra output canvas in its own window (multi-monitor mode). The
// only chrome is a small ⋯ button that appears when the mouse is near
// the BOTTOM edge — tiles keep their menus at the top, so the two can
// never collide. All state that must persist (name, monitor, window
// mode) lives in the main window's output model — the buttons here only
// emit signals, and the model writes flow back in through the
// properties.
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
    // 0 = windowed, 1 = fullscreen, 2 = windowless (frameless)
    property int windowMode: 0
    property int screenIndex: 0
    // True while sidebar source clicks land on this canvas.
    property bool isTarget: false

    // Shared app settings, passed straight through to the canvas.
    property bool snapOn: false
    property bool wheelRotateOn: true
    property bool showTileNames: true
    property int tileGap: 8
    property bool autoLowBw: true
    property bool statusDots: true
    property bool tileBorders: true
    property bool tileControls: true
    property var cursorGuard: null
    property var availableSources: []

    readonly property alias canvas: tc

    // macOS only: lifts a fullscreen window above the menu bar (no-op elsewhere).
    MacWindow { id: macWindow }

    signal closeRequested()
    signal renameRequested(string name)
    signal modeChangeRequested(int mode)
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
    // (Changing window flags rebuilds the native window on Windows and
    // can reset the size, so geometry is re-applied after every switch.)
    property rect savedGeom: Qt.rect(0, 0, 0, 0)
    // True while the output is showing fullscreen (native on Windows, a
    // borderless screen-cover on macOS). Tracked explicitly because macOS
    // fullscreen no longer sets Window.FullScreen visibility.
    property bool fsActive: false

    // The windowed geometry worth saving in the session, even while the
    // output is currently fullscreen.
    function windowedRect() {
        return (fsActive && savedGeom.width > 200)
            ? savedGeom : Qt.rect(x, y, width, height)
    }

    onWindowModeChanged: Qt.callLater(applyMode)
    onScreenIndexChanged: {
        if (windowMode === 1)
            Qt.callLater(applyMode)
    }
    Component.onCompleted: {
        if (windowMode !== 0)
            Qt.callLater(applyMode)
    }

    // Startup re-assert: at login/session restore, applyMode's first run can
    // happen before the window is mapped or before macOS has brought up all
    // displays — the OS then places the window on the wrong screen and the
    // menu-bar cover never engages. Re-apply (idempotent) once the window is
    // actually visible, whenever the display list changes, and once more a
    // moment after startup.
    onVisibleChanged: {
        if (visible && windowMode === 1)
            Qt.callLater(applyMode)
    }
    Connections {
        target: Qt.application
        function onScreensChanged() {
            if (out.windowMode === 1)
                Qt.callLater(out.applyMode)
        }
    }
    Timer {
        interval: 1500
        running: out.windowMode === 1
        repeat: false
        onTriggered: out.applyMode()
    }

    function applyMode() {
        // Remember the current windowed rectangle unless we're already
        // showing fullscreen (whose geometry is the screen cover).
        if (!fsActive && width > 200)
            savedGeom = Qt.rect(x, y, width, height)
        if (windowMode === 1) {
            const screens = Qt.application.screens
            const target = screens[Math.min(screenIndex, screens.length - 1)]
            fsActive = true
            if (Qt.platform.os === "windows") {
                // Native fullscreen; dip through windowed so a monitor
                // change actually moves displays.
                if (visibility === Window.FullScreen)
                    visibility = Window.Windowed
                flags = Qt.Window
                out.screen = target
                visibility = Window.FullScreen
            } else {
                // macOS: cover the target screen with a borderless window
                // instead of Qt's native fullscreen. Native fullscreen puts
                // each window in its own Space, whose async transition lands
                // on the wrong monitor and loses the window on exit.
                out.screen = target
                flags = Qt.Window | Qt.FramelessWindowHint
                out.x = target.virtualX
                out.y = target.virtualY
                out.width = target.width
                out.height = target.height
                visibility = Window.Windowed
                visible = true
                out.raise()
                macWindow.setCoversMenuBar(out, true)
            }
        } else {
            fsActive = false
            visibility = Window.Windowed
            flags = windowMode === 2
                ? Qt.Window | Qt.FramelessWindowHint
                : Qt.Window
            if (savedGeom.width > 200) {
                x = savedGeom.x
                y = savedGeom.y
                width = savedGeom.width
                height = savedGeom.height
            }
            visible = true
            if (Qt.platform.os !== "windows") {
                macWindow.setCoversMenuBar(out, false)
                out.raise()
            }
        }
    }

    // Each output window handles its own keys: Esc cancels tile overlays
    // first, then returns to a normal window; F11 toggles fullscreen.
    Item {
        id: outKeys
        focus: true
        Keys.onEscapePressed: {
            if (out.menuOpen) {
                out.menuOpen = false
                return
            }
            if (!tc.cancelOverlays() && out.windowMode !== 0)
                out.modeChangeRequested(0)
        }
        Keys.onPressed: event => {
            if (event.key === Qt.Key_F11) {
                out.modeChangeRequested(out.windowMode === 1 ? 0 : 1)
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
        autoLowBw: out.autoLowBw
        statusDots: out.statusDots
        tileBorders: out.tileBorders
        tileControls: out.tileControls
        cursorGuard: out.cursorGuard
        availableSources: out.availableSources
        // Windowless has no title bar — dragging the canvas background
        // moves the window, same as the main window.
        moveWindowOnDrag: out.windowMode === 2
        focusTarget: outKeys
        emptyHint: out.isTarget
            ? "This canvas is receiving — click sources in the main window to add them here"
            : "Empty canvas — pick it under CANVASES in the main window (or hover the bottom edge and open the ⋯ menu), then click sources"
        onTilesMutated: out.tilesMutated()
    }

    // Frameless windows have no OS resize borders — provide our own edges
    // and corners in windowless mode via startSystemResize.
    component ResizeEdge: MouseArea {
        property int edges
        z: 200
        onPressed: out.startSystemResize(edges)
    }

    Item {
        anchors.fill: parent
        visible: out.windowMode === 2
        z: 200

        ResizeEdge { x: 0; y: 10; width: 7; height: parent.height - 20; edges: Qt.LeftEdge; cursorShape: Qt.SizeHorCursor }
        ResizeEdge { x: parent.width - 7; y: 10; width: 7; height: parent.height - 20; edges: Qt.RightEdge; cursorShape: Qt.SizeHorCursor }
        ResizeEdge { x: 10; y: 0; width: parent.width - 20; height: 7; edges: Qt.TopEdge; cursorShape: Qt.SizeVerCursor }
        ResizeEdge { x: 10; y: parent.height - 7; width: parent.width - 20; height: 7; edges: Qt.BottomEdge; cursorShape: Qt.SizeVerCursor }
        ResizeEdge { x: 0; y: 0; width: 12; height: 12; edges: Qt.LeftEdge | Qt.TopEdge; cursorShape: Qt.SizeFDiagCursor }
        ResizeEdge { x: parent.width - 12; y: 0; width: 12; height: 12; edges: Qt.RightEdge | Qt.TopEdge; cursorShape: Qt.SizeBDiagCursor }
        ResizeEdge { x: 0; y: parent.height - 12; width: 12; height: 12; edges: Qt.LeftEdge | Qt.BottomEdge; cursorShape: Qt.SizeBDiagCursor }
        ResizeEdge { x: parent.width - 12; y: parent.height - 12; width: 12; height: 12; edges: Qt.RightEdge | Qt.BottomEdge; cursorShape: Qt.SizeFDiagCursor }
    }

    // -------------------------------------------------- ⋯ dropdown menu
    // All output controls live in a dropdown at the BOTTOM of the canvas:
    // tile headers and their ⋯ menus sit at the top of every tile, so a
    // bottom-edge button can never block them (Max's spec). Hovering the
    // bottom edge reveals the small ⋯ button; the menu opens upward and
    // stacks above the tile layer with a full-window click-catcher
    // underneath — no click, press or drag can leak through to a tile
    // while it is open.
    property bool menuOpen: false
    // Reclaim keyboard focus when the menu closes (e.g. after typing in
    // a size box) so Esc and F11 keep working in this window. Opening
    // resyncs the name box — typing in it breaks its binding, so a
    // fresh open must show the current name again.
    onMenuOpenChanged: {
        if (menuOpen)
            nameInput.text = outputName
        else
            outKeys.forceActiveFocus()
    }

    // Bottom-edge hover zone reveals the ⋯ button (hover only, never
    // intercepts clicks aimed at tiles).
    Item {
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        height: 44
        HoverHandler { id: bottomZone }
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
        anchors.bottom: parent.bottom
        anchors.right: parent.right
        anchors.margins: 8
        z: 300
        width: 32
        height: 26
        radius: 3
        color: out.menuOpen ? "#22303e"
             : menuBtnHover.hovered ? "#2a2a30" : "#141417ee"
        border.width: 1
        border.color: out.menuOpen ? "#3d7eff" : "#2a2a2e"
        visible: opacity > 0
        opacity: (bottomZone.hovered || menuBtnHover.hovered || out.menuOpen)
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
        z: 300
        onClicked: out.menuOpen = false
    }

    Rectangle {
        visible: out.menuOpen
        anchors.bottom: menuBtn.top
        anchors.bottomMargin: 4
        anchors.right: parent.right
        anchors.rightMargin: 8
        z: 300
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

            // Editable canvas name (same live-edit style as tile rename):
            // every keystroke renames — the window title, the sidebar's
            // Canvases button and saved profiles all follow the model.
            Text {
                text: "NAME"
                color: "#5a5a60"
                font.pixelSize: 9
            }
            Rectangle {
                width: menuCol.width
                height: 24
                radius: 2
                color: "#101013"
                border.width: 1
                border.color: nameInput.activeFocus ? "#3d7eff" : "#2a2a2e"

                TextInput {
                    id: nameInput
                    anchors.fill: parent
                    anchors.margins: 4
                    color: "#e8e8ea"
                    font.pixelSize: 12
                    selectByMouse: true
                    clip: true
                    text: out.outputName
                    // Blank names are never committed — the model keeps
                    // the last real name until something is typed.
                    onTextEdited: {
                        if (text.trim() !== "")
                            out.renameRequested(text.trim())
                    }
                    onAccepted: out.menuOpen = false
                }
            }

            OutBtn {
                width: menuCol.width
                label: out.isTarget ? "● Receiving sources"
                                    : "Send sources here"
                active: out.isTarget
                onActivated: out.targetRequested()
            }

            Text {
                text: "WINDOW"
                color: "#5a5a60"
                font.pixelSize: 9
            }
            Flow {
                width: menuCol.width
                spacing: 4

                OutBtn {
                    label: "Windowed"
                    active: out.windowMode === 0
                    onActivated: out.modeChangeRequested(0)
                }
                OutBtn {
                    label: "Fullscreen"
                    active: out.windowMode === 1
                    onActivated: out.modeChangeRequested(1)
                }
                OutBtn {
                    label: "Windowless"
                    active: out.windowMode === 2
                    onActivated: out.modeChangeRequested(2)
                }
            }

            // Exact canvas size, same as the main window's settings
            // panel — hidden in fullscreen where the monitor decides.
            Text {
                visible: out.windowMode !== 1
                text: "SIZE"
                color: "#5a5a60"
                font.pixelSize: 9
            }
            Row {
                visible: out.windowMode !== 1
                spacing: 6

                component NumBox: Rectangle {
                    property alias text: numInput.text
                    property int value: 0
                    width: 56
                    height: 24
                    radius: 2
                    color: "#101013"
                    border.width: 1
                    border.color: numInput.activeFocus ? "#3d7eff" : "#2a2a2e"
                    onValueChanged: numInput.text = value

                    TextInput {
                        id: numInput
                        anchors.fill: parent
                        anchors.margins: 3
                        color: "#d8d8dc"
                        font.pixelSize: 12
                        horizontalAlignment: TextInput.AlignHCenter
                        validator: IntValidator { bottom: 1; top: 16384 }
                        selectByMouse: true
                        text: parent.value
                    }
                }

                NumBox { id: szW; value: out.width }
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: "×"
                    color: "#8a8a90"
                    font.pixelSize: 12
                }
                NumBox { id: szH; value: out.height }
                OutBtn {
                    label: "Set"
                    onActivated: {
                        out.width = Math.max(out.minimumWidth,
                                             parseInt(szW.text) || out.width)
                        out.height = Math.max(out.minimumHeight,
                                              parseInt(szH.text) || out.height)
                    }
                }
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
                label: "Close this canvas"
                onActivated: out.closeRequested()
            }
        }
    }
}
