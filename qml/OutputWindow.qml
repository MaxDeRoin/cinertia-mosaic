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
    // Which display fullscreen uses. screenKey (a saved display identity,
    // JSON — see Displays.keyFor) wins; screenIndex is the fallback for
    // sessions saved before keys existed.
    property int screenIndex: 0
    property string screenKey: ""
    // The shared Displays object (display identity + change notices).
    property var displays: null
    // True while fullscreen is waiting for its display to be connected —
    // the window stays hidden instead of covering some other display.
    property bool displayMissing: false
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
    // A monitor was picked in the ⋯ menu (a QScreen from Displays.screens).
    signal screenPicked(var screen)
    signal targetRequested()
    signal tilesMutated()

    // Set while the whole app quits: closing then must NOT delete this
    // output from the session that was just saved.
    property bool appQuitting: false
    onClosing: close => {
        // Closing the temporary "Show" window just hides it again (like the
        // sidebar's Hide) — it must not delete the canvas.
        if (showHere && !appQuitting) {
            close.accepted = false
            showHere = false
            return
        }
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
    // Temporary "show it here anyway" while its fullscreen display is
    // missing (sidebar ⚠ button): a normal window on another display, never
    // saved, and cleared automatically when the display comes back.
    property bool showHere: false
    onShowHereChanged: {
        if (!showHere)
            showHerePlaced = false
        Qt.callLater(applyMode)
    }
    // The temporary window has been put on a free display (once — re-applies
    // while it is shown leave it where the user drags it).
    property bool showHerePlaced: false
    // The display the fullscreen cover was last put on — to hide at once if
    // exactly that display disappears.
    property var coverScreen: null

    // The windowed geometry worth saving in the session, even while the
    // output is currently fullscreen.
    function windowedRect() {
        return ((fsActive || displayMissing) && savedGeom.width > 200)
            ? savedGeom : Qt.rect(x, y, width, height)
    }

    onWindowModeChanged: Qt.callLater(applyMode)
    onScreenIndexChanged: {
        if (windowMode === 1)
            Qt.callLater(applyMode)
    }
    onScreenKeyChanged: {
        if (windowMode === 1)
            Qt.callLater(applyMode)
    }
    Component.onCompleted: {
        if (windowMode !== 0)
            Qt.callLater(applyMode)
    }

    // Where this window sits when not fullscreen (display + offset), so it
    // comes back on the same display after a restart or reconnect.
    WindowPlacement {
        id: placement
        win: out
        displays: out.displays
        // Only real, user-made positions: not fullscreen, not hidden, not
        // the temporary "show here" spot.
        canRecord: !out.fsActive && !out.displayMissing && !out.showHere
                   && out.visible
    }
    function noteMoved() {
        if (!applying)
            placement.noteMoved()
    }
    onXChanged: noteMoved()
    onYChanged: noteMoved()
    onWidthChanged: noteMoved()
    onHeightChanged: noteMoved()

    // Re-apply (idempotent) once the window is actually visible, whenever the
    // display layout settles after a change (a display added, removed, woken,
    // rotated or resized — including at login, when displays come up after
    // the app starts), and once more a moment after startup.
    onVisibleChanged: {
        if (visible && windowMode === 1)
            Qt.callLater(applyMode)
    }
    Connections {
        target: out.displays
        function onLayoutChanged() {
            out.healAttempts = 0
            if (out.windowMode === 1)
                out.applyMode()
            else
                placement.onLayout() // e.g. its display came back: return to it
        }
        // The cover's display just disappeared: hide now, before the OS
        // slides the cover onto another display (the debounced re-apply
        // follows and keeps it hidden until the display returns).
        function onScreenGone(screen) {
            // (Only where a missing display can be told apart — on Windows
            // the settled re-apply handles it, as before.)
            if (out.displays.canReportMissing
                    && out.windowMode === 1 && out.fsActive && !out.showHere
                    && out.coverScreen === screen)
                out.park()
        }
    }
    Timer {
        interval: 1500
        running: out.windowMode === 1
        repeat: false
        onTriggered: out.applyMode()
    }

    // Self-check for unattended use: if a fullscreen output ever stops
    // covering its display exactly (a display change the OS reported late
    // or not at all), re-apply. Three quick tries, then once a minute — it
    // can never fight the OS in a tight loop.
    property int healAttempts: 0
    property int healTicks: 0
    Timer {
        interval: 3000
        repeat: true
        running: out.windowMode === 1
        onTriggered: {
            if (!out.displays || out.displays.settling || out.showHere
                    || out.visibility === Window.Minimized)
                return
            if (out.healAttempts >= 3 && (++out.healTicks % 20) !== 0)
                return
            if (out.needsHeal()) {
                out.healAttempts++
                console.log("Output '" + out.outputName
                            + "': fullscreen re-applied (self-check)")
                out.applyMode()
            } else {
                out.healAttempts = 0
            }
        }
    }
    function needsHeal() {
        const r = displays.resolve(screenKey, screenIndex)
        if (r.state === "uncertain")
            return false
        if (!r.screen)
            return visible // should be hidden while its display is missing
        return !visible || !coveringCorrectly(r.screen)
    }
    // Already fullscreen on exactly this display? (Then re-applying would
    // only flicker — Windows drops out of fullscreen to switch.)
    function coveringCorrectly(t) {
        if (!fsActive || !visible)
            return false
        if (Qt.platform.os === "windows")
            return visibility === Window.FullScreen
                && displays.screenOf(out) === t
        const g = t.geometry
        return Math.abs(x - g.x) <= 2 && Math.abs(y - g.y) <= 2
            && Math.abs(width - g.width) <= 2 && Math.abs(height - g.height) <= 2
            && macWindow.isCovering(out, Qt.rect(g.x, g.y, g.width, g.height))
    }

    // Which display fullscreen should use, for display only (pickers):
    // null when that display isn't connected.
    function targetScreen() {
        if (!displays)
            return null
        const r = displays.resolve(screenKey, screenIndex)
        return r.screen || null
    }

    // True while applyMode itself moves the window (not a user move).
    property bool applying: false

    // Hide while the fullscreen display is missing — never cover another
    // display. Leaves fsActive and the saved windowed geometry untouched.
    function park() {
        displayMissing = true
        if (Qt.platform.os !== "windows")
            macWindow.setCoversMenuBar(out, false)
        // hide() rather than visible = false: once a window's visibility
        // mode has been set, Qt warns about the property route.
        out.hide()
    }

    function applyMode() {
        if (!displays)
            return
        // Remember the current windowed rectangle unless we're already
        // showing fullscreen (whose geometry is the screen cover) or the
        // window sits at a temporary spot.
        if (!fsActive && visible && !showHere && !displayMissing && width > 200) {
            savedGeom = Qt.rect(x, y, width, height)
            placement.flush() // a just-made move counts before fullscreen
        } else if (showHere || displayMissing) {
            placement.discard() // moves at a temporary spot never count
        }
        // Leaving fullscreen or a waiting/temporary state puts the window
        // back at its home; a plain windowed <-> windowless switch leaves it
        // where it is.
        const wasSpecial = fsActive || displayMissing || showHere || !visible
        applying = true

        if (windowMode === 1) {
            const r = displays.resolve(screenKey, screenIndex)
            if (r.state === "uncertain") {
                applying = false
                return // displays mid-change: the settled layout decides
            }
            if (r.screen) {
                displayMissing = false
                showHere = false
                coverOn(r.screen)
                applying = false
                return
            }
            // Display not connected (unplugged, powered off, not up yet).
            if (!showHere) {
                park()
                applying = false
                return
            }
            // ...but the user asked to see it anyway: a normal window for now.
            displayMissing = true
        } else {
            displayMissing = false
            showHere = false // only meaningful while fullscreen waits
        }
        windowedOn(wasSpecial)
        applying = false
    }

    function coverOn(t) {
        coverScreen = t
        displays.markUsed(t) // never a stand-in for another missing display
        if (coveringCorrectly(t))
            return // already right: touch nothing (no flicker)
        fsActive = true
        const g = t.geometry
        if (Qt.platform.os === "windows") {
            // Native fullscreen; dip through windowed when the display or
            // the window flags change (Windows applies a framed style over
            // fullscreen otherwise), so a monitor change really moves.
            if (visibility === Window.FullScreen
                    && (displays.screenOf(out) !== t || flags !== Qt.Window))
                visibility = Window.Windowed
            flags = Qt.Window
            displays.assignScreen(out, t)
            visibility = Window.FullScreen
        } else {
            // macOS: cover the target screen with a borderless window
            // instead of Qt's native fullscreen. Native fullscreen puts
            // each window in its own Space, whose async transition lands
            // on the wrong monitor and loses the window on exit. Uses the
            // display's CURRENT geometry, so a display that came back at a
            // different resolution or rotation is covered exactly.
            displays.assignScreen(out, t)
            flags = Qt.Window | Qt.FramelessWindowHint
            out.x = g.x
            out.y = g.y
            out.width = g.width
            out.height = g.height
            // visible before visibility: setting a mode on a window still
            // marked hidden (it was waiting for its display) makes Qt warn.
            visible = true
            visibility = Window.Windowed
            out.raise()
            macWindow.setCoversMenuBar(out, true, Qt.rect(g.x, g.y, g.width, g.height))
        }
    }

    function windowedOn(wasSpecial) {
        fsActive = false
        coverScreen = null
        // (A hidden window becomes windowed when shown below; setting the
        // mode while it is hidden only makes Qt warn.)
        if (visible)
            visibility = Window.Windowed
        flags = windowMode === 2
            ? Qt.Window | Qt.FramelessWindowHint
            : Qt.Window
        const r = savedGeom.width > 200 ? savedGeom : Qt.rect(x, y, width, height)
        if (showHere) {
            // The temporary spot: on a display no fullscreen window covers
            // (its home might be under one, where it would be invisible).
            if (!showHerePlaced) {
                placement.apply(showHereRect(r))
                showHerePlaced = true
            }
        } else if (wasSpecial) {
            // Back to its remembered spot (on its own display when that's
            // connected), else to where it was before, kept on a display
            // that exists now.
            if (!placement.place())
                placement.apply(placement.fitRect(r, null))
        } else if (savedGeom.width > 200) {
            // Same spot (Windows can reset the size when flags change).
            placement.apply(savedGeom)
        }
        visible = true
        if (Qt.platform.os !== "windows") {
            macWindow.setCoversMenuBar(out, false)
            out.raise()
        }
    }

    // Where the temporary "show here" window goes: centred on a display no
    // fullscreen window covers (Main's fitHelper), shrunk to fit.
    function showHereRect(r) {
        const s = (fitHelper ? fitHelper(out) : null) || displays.primary()
        return s ? placement.centredOn(s, r) : r
    }
    // Set by Main: picks a display not covered by any fullscreen window.
    property var fitHelper: null

    // Session save/restore of the windowed position (display-relative).
    function capturePlacement() {
        // While fullscreen, the pre-fullscreen rectangle stands in (the
        // current size is the cover).
        return placement.capture((fsActive || displayMissing) ? savedGeom : null)
    }
    function restorePlacement(o, doPlace) {
        return placement.restore(o, doPlace)
    }
    function restoreLegacyRect(r) {
        placement.restoreLegacy(r)
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
                visible: monitorRep.count > 1
                text: "MONITOR"
                color: "#5a5a60"
                font.pixelSize: 9
            }
            Flow {
                visible: monitorRep.count > 1
                width: menuCol.width
                spacing: 4

                Repeater {
                    id: monitorRep
                    model: out.displays ? out.displays.screens : []

                    OutBtn {
                        required property int index
                        required property var modelData
                        label: String(index + 1)
                        // Highlight by identity, so the right button stays
                        // lit even when the OS reorders the displays.
                        active: {
                            out.displays && out.displays.revision
                            return out.targetScreen() === modelData
                        }
                        // Not while displays are changing: the pick would
                        // be locked to whatever display sits there mid-change.
                        opacity: out.displays && out.displays.settling ? 0.4 : 1
                        onActivated: {
                            if (!out.displays.settling)
                                out.screenPicked(modelData)
                        }
                    }
                }
            }
            Text {
                visible: monitorRep.count > 1
                width: menuCol.width
                wrapMode: Text.WordWrap
                text: {
                    out.displays && out.displays.revision
                    const t = out.targetScreen()
                    return t ? out.displays.describe(t) : ""
                }
                color: "#8a8a90"
                font.pixelSize: 10
            }

            OutBtn {
                width: menuCol.width
                label: "Close this canvas"
                onActivated: out.closeRequested()
            }
        }
    }
}
