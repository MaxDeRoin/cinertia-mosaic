import QtQuick

// Remembers where a window sits when it is NOT fullscreen — which display it
// is on (by identity, see Displays) and where on that display — and puts it
// back there after a restart or when that display reconnects.
//
// Only real, user-made positions are remembered. The owning window says
// when its position is one (canRecord: not fullscreen, not hidden, not a
// temporary spot), and a move only counts once it has stayed put for two
// seconds with the display layout calm. A move made while displays are
// changing is kept pending and recorded once they settle, if the window is
// still where the user left it. A deliberate drag onto another display
// re-homes the window there.
QtObject {
    id: placement

    property var win: null      // the Window being placed
    property var displays: null // the shared Displays object
    // Set by the owner: true while the window's current spot is a real,
    // user-chosen windowed position.
    property bool canRecord: true

    // "Home": the display (saved key, JSON string) plus the window's offset
    // from that display's top-left corner and its size.
    property string homeKey: ""
    property real homeRx: 0
    property real homeRy: 0
    property real homeW: 0
    property real homeH: 0
    // True while home's display is not connected — so its return (and only
    // that) moves the window back.
    property bool homeMissing: false
    // The rectangle last applied by this code, and where place() meant to
    // put the window before fitting it onto the display as it was then — to
    // re-fit it once the display reaches its final mode (TVs pass through
    // temporary ones).
    property rect lastPlaced: Qt.rect(0, 0, 0, 0)
    property rect lastIntended: Qt.rect(0, 0, 0, 0)
    // An old-style absolute rectangle (sessions from 0.7.0) waiting for the
    // displays to settle before it is fitted onto one.
    property rect pendingRect: Qt.rect(0, 0, 0, 0)

    // Set while place() moves the window, so the move isn't re-recorded.
    property bool placing: false

    function hasHome() {
        return homeKey !== "" && homeW > 200 && homeH > 150
    }
    function recordable() {
        return canRecord && pendingRect.width === 0 && win && win.width >= 200
    }

    // Record a rectangle (default: the window's current one) as home, on
    // the display holding most of it.
    function record(r) {
        if (!displays)
            return
        if (!r) {
            if (!recordable())
                return
            r = Qt.rect(win.x, win.y, win.width, win.height)
        }
        const s = displays.screenContaining(r.x + r.width / 2, r.y + r.height / 2)
                  || displays.screenForRect(r)
        if (!s)
            return
        const key = displays.keyFor(s)
        if (!key || !key.name)
            return // display can't be identified right now: keep the old home
        homeKey = JSON.stringify(key)
        homeRx = r.x - s.geometry.x
        homeRy = r.y - s.geometry.y
        homeW = r.width
        homeH = r.height
        homeMissing = false
    }

    // Called whenever the window moves or resizes.
    function noteMoved() {
        if (placing || !win)
            return
        // The platform may report our own move a moment later (Windows
        // queues it): landing exactly where we put the window isn't a move.
        if (sameRect(Qt.rect(win.x, win.y, win.width, win.height), lastPlaced))
            return
        // A move that happens while displays change is the OS's first
        // suspect (e.g. pushing the window off a display that vanished).
        movedDuringChange = !!(displays && displays.settling)
        commitTimer.restart()
    }
    property bool movedDuringChange: false
    function sameRect(a, b) {
        return Math.abs(a.x - b.x) < 2 && Math.abs(a.y - b.y) < 2
            && Math.abs(a.width - b.width) < 2 && Math.abs(a.height - b.height) < 2
    }
    // A move made around a display change while home's display is missing
    // is the OS evacuating the window — never a new home. (A deliberate
    // drag later, with the layout calm, still re-homes the window.)
    function osEvacuation(heldAcrossChange) {
        return homeMissing && (movedDuringChange || heldAcrossChange)
    }
    // Forget a pending move (it was made at a temporary spot).
    function discard() {
        commitTimer.stop()
        pendingCommit = false
        movedDuringChange = false
    }
    property bool pendingCommit: false
    property rect pendingCommitRect: Qt.rect(0, 0, 0, 0)
    property Timer commitTimer: Timer {
        interval: 2000
        onTriggered: {
            if (!placement.win)
                return
            if (placement.displays && placement.displays.settling) {
                // Displays are changing: decide once they've settled.
                placement.pendingCommit = true
                placement.pendingCommitRect = Qt.rect(placement.win.x, placement.win.y,
                                                      placement.win.width, placement.win.height)
                return
            }
            if (!placement.osEvacuation(false))
                placement.record()
            placement.movedDuringChange = false
        }
    }
    property Connections settlingWatch: Connections {
        target: placement.displays
        function onSettlingChanged() {
            const w = placement.win
            if (!w)
                return
            if (placement.displays.settling) {
                // A move still waiting to count may be the OS's: hold it.
                if (placement.commitTimer.running) {
                    placement.commitTimer.stop()
                    placement.pendingCommit = true
                    placement.pendingCommitRect = Qt.rect(w.x, w.y, w.width, w.height)
                }
                return
            }
            // Settled: if the window is still where it was left, that was
            // the user's move — record it.
            if (placement.pendingCommit) {
                placement.pendingCommit = false
                if (placement.sameRect(Qt.rect(w.x, w.y, w.width, w.height),
                                       placement.pendingCommitRect)
                        && !placement.osEvacuation(true))
                    placement.record()
                placement.movedDuringChange = false
            }
        }
    }
    // Record a move still waiting to count right now — the user is
    // changing the window's mode this moment (going fullscreen would
    // otherwise make the cover what gets recorded).
    function flush() {
        const held = pendingCommit
        if (commitTimer.running || held) {
            commitTimer.stop()
            pendingCommit = false
            if (!osEvacuation(held))
                record()
            movedDuringChange = false
        }
    }

    // Home's display when it is connected (only a real identity match —
    // a key from another machine places nothing).
    function homeScreen() {
        if (!displays || homeKey === "")
            return null
        const r = displays.resolve(homeKey, 0)
        return r.state === "found" ? r.screen : null
    }

    // Keep a rectangle visible: unchanged if its centre is on a display
    // (so a window spanning two displays, or one sized to a whole display
    // under the taskbar, keeps its size); otherwise moved and, only if it
    // must be, shrunk onto `s` (or the display it overlaps most).
    // With a target display `s`, only a rectangle centred on THAT display
    // is left alone.
    function fitRect(r, s) {
        if (!displays)
            return r
        const on = displays.screenContaining(r.x + r.width / 2, r.y + r.height / 2)
        if (on && (!s || on === s))
            return r
        s = s || displays.screenForRect(r) || displays.primary()
        if (!s)
            return r
        const a = usableArea(s)
        const w = Math.min(r.width, a.width)
        const h = Math.min(r.height, a.height)
        const x = Math.max(a.x, Math.min(r.x, a.x + a.width - w))
        const y = Math.max(a.y, Math.min(r.y, a.y + a.height - h))
        return Qt.rect(x, y, w, h)
    }
    // Where a window's content may go on a display: a frameless window may
    // use all of it; a framed one keeps room for its title bar (Qt's x/y
    // are the content's, below the title bar), so it stays draggable.
    function usableArea(s) {
        const frameless = win && (win.flags & Qt.FramelessWindowHint)
        if (frameless)
            return s.geometry
        const a = s.availableGeometry
        const tb = 32
        return Qt.rect(a.x, a.y + tb, a.width, Math.max(150, a.height - tb))
    }
    // A rectangle centred on a display's usable area, shrunk to fit.
    function centredOn(s, r) {
        const a = usableArea(s)
        const w = Math.min(r.width, a.width)
        const h = Math.min(r.height, a.height)
        return Qt.rect(a.x + (a.width - w) / 2, a.y + (a.height - h) / 2, w, h)
    }

    // Size first, then position: setting the position while the window is
    // still large (e.g. fullscreen-sized) lets macOS push it back on screen
    // before the size shrinks, so it would land in the wrong spot.
    function apply(r) {
        placing = true
        win.width = r.width
        win.height = r.height
        win.x = r.x
        win.y = r.y
        lastPlaced = r
        placing = false
    }

    // Put the window at home if its display is connected. Returns false
    // when there is no home or its display is missing (window left alone).
    function place() {
        if (!win || !displays || !hasHome())
            return false
        const s = homeScreen()
        if (!s) {
            homeMissing = true
            return false
        }
        homeMissing = false
        lastIntended = Qt.rect(s.geometry.x + homeRx, s.geometry.y + homeRy,
                               homeW, homeH)
        apply(fitRect(lastIntended, s))
        return true
    }

    // After the display layout settles: move the window back if its home
    // display just came back, re-fit it if it was squeezed onto a display
    // that has since reached its final size, and fit an old-style saved
    // rectangle now that the displays are up. Never touches a window the
    // user has moved since it was placed.
    function onLayout() {
        if (!win || !displays)
            return
        if (pendingRect.width > 0) {
            // A real copy: reading a rect property gives a live reference,
            // which the reset below would blank.
            const r = Qt.rect(pendingRect.x, pendingRect.y,
                              pendingRect.width, pendingRect.height)
            pendingRect = Qt.rect(0, 0, 0, 0)
            if (!place())
                apply(fitRect(r, null))
            return
        }
        if (!hasHome())
            return
        const wasMissing = homeMissing
        const s = homeScreen()
        homeMissing = !s
        if (!s)
            return
        const untouched = sameRect(Qt.rect(win.x, win.y, win.width, win.height),
                                   lastPlaced)
        // Fitted onto a temporary mode: moved and/or shrunk from where home
        // says it belongs.
        const compromised = !sameRect(lastPlaced, lastIntended)
        if (wasMissing || (untouched && compromised))
            place()
    }

    // Session save/restore: { wkey, wrx, wry, ww, wh }. `fallback` is the
    // owner's pre-fullscreen rectangle, used when there is no home yet and
    // the window is fullscreen right now (its current size is the cover).
    function capture(fallback) {
        if (!hasHome() && !(displays && displays.settling)) {
            if (recordable())
                record()
            else if (fallback && fallback.width > 200)
                record(fallback)
        }
        return hasHome()
            ? { wkey: homeKey, wrx: homeRx, wry: homeRy, ww: homeW, wh: homeH }
            : null
    }
    function clearHome() {
        homeKey = ""
        homeW = 0
        homeH = 0
        homeMissing = false
        lastPlaced = Qt.rect(0, 0, 0, 0)
        lastIntended = Qt.rect(0, 0, 0, 0)
    }
    // Returns "placed" (or "home" with doPlace = false: home set, a
    // fullscreen window keeps it for when it leaves fullscreen), "missing"
    // (this machine's display, not connected: home kept for its return),
    // "foreign" (a display from another machine — home cleared; use the
    // saved absolute rectangle) or "none" (nothing saved this way).
    function restore(o, doPlace) {
        if (!o || !o.wkey || !displays)
            return "none"
        const state = displays.resolve(o.wkey, 0).state
        if (state === "fallback") {
            clearHome()
            return "foreign"
        }
        homeKey = o.wkey
        homeRx = o.wrx || 0
        homeRy = o.wry || 0
        homeW = o.ww || 0
        homeH = o.wh || 0
        lastPlaced = Qt.rect(0, 0, 0, 0)
        lastIntended = Qt.rect(0, 0, 0, 0)
        homeMissing = state !== "found"
        if (doPlace === false)
            return "home"
        return place() ? "placed" : "missing"
    }
    // An old-style absolute rectangle: fit it now, or — while the displays
    // are still coming up — once they've settled (its display may not exist
    // yet), without recording the interim spot as home.
    function restoreLegacy(r) {
        if (!win || r.width <= 200)
            return
        clearHome() // the spot given here wins over any earlier home
        if (displays && displays.settling) {
            pendingRect = r
            apply(r)
        } else {
            apply(fitRect(r, null))
        }
    }
}
