#pragma once

#include <QElapsedTimer>
#include <QHash>
#include <QObject>
#include <QPointer>
#include <QRectF>
#include <QScreen>
#include <QSet>
#include <QVariant>
#include <QtQml/qqmlregistration.h>

class QQuickWindow;
class QTimer;

// QML type "Displays": recognises displays by identity instead of by their
// position in the OS's display list, and reports when the display layout has
// settled after a change. One instance lives in Main.qml and is shared with
// every output window.
//
// Why: macOS (and Windows) can list displays in a different order after a
// reboot, so "screen 2" is not always the same TV. Windows remember a
// display "key" instead (see keyFor) and look it up again with resolve().
//
// Change reporting: displays coming up at boot, waking from standby, being
// plugged in, rotated or changing resolution all arrive as a burst of raw
// events. layoutChanged() fires once, shortly after the burst ends, so
// windows re-place themselves against the final layout instead of a
// transient one.
class DisplayManager : public QObject
{
    Q_OBJECT
    QML_NAMED_ELEMENT(Displays)
    // Every connected display (QScreen objects), numbered left to right
    // (then top to bottom) by where they sit in the display arrangement —
    // stable across reboots, unlike the OS's own list order.
    Q_PROPERTY(QVariantList screens READ screens NOTIFY layoutChanged)
    // Bumps on every layoutChanged — handy for re-evaluating QML bindings.
    Q_PROPERTY(int revision READ revision NOTIFY layoutChanged)
    // True while displays are changing, briefly after, and for the first
    // few seconds after launch: window moves the OS makes during this time
    // are not the user's and must not be saved.
    Q_PROPERTY(bool settling READ settling NOTIFY settlingChanged)
    // Whether this platform can tell a display is missing (macOS: yes, by
    // id). Where it can't (Windows), windows keep the old index behavior and
    // never hide.
    Q_PROPERTY(bool canReportMissing READ canReportMissing CONSTANT)

public:
    explicit DisplayManager(QObject *parent = nullptr);

    QVariantList screens() const;
    int revision() const { return m_revision; }
    bool settling() const { return m_settling; }
    bool canReportMissing() const;

    // A JSON-friendly identity for a display, to save when the user picks it
    // and match later: { id, vendor, model, serial, name, x, y, w, h }.
    // Empty while the display can't be identified (displays mid-change).
    Q_INVOKABLE QVariantMap keyFor(QScreen *screen) const;
    // Record that a window uses this display (a covered display is never
    // taken as a stand-in for another missing one).
    Q_INVOKABLE void markUsed(QScreen *screen);

    // Which connected display a saved key means. Returns
    //   { state: "found",     screen }  the display is connected
    //   { state: "fallback",  screen }  no usable key (older save, or a key
    //                                   from another machine): the saved OS
    //                                   index, as before keys existed
    //                                   (also: its display was replaced by
    //                                   an identical unit — see resolve())
    //   { state: "missing" }            this machine's display, not connected
    //   { state: "uncertain" }          displays mid-change; leave windows be
    // `key` may be a map or its JSON string; `fallbackIndex` is the saved
    // index into the OS's display order.
    Q_INVOKABLE QVariantMap resolve(const QVariant &key, int fallbackIndex) const;

    // Moves a window onto a display at the platform level (QML's
    // Window.screen only accepts its own Screen wrappers, not QScreen).
    Q_INVOKABLE void assignScreen(QQuickWindow *window, QScreen *screen) const;
    // The display a window is on right now.
    Q_INVOKABLE QScreen *screenOf(QQuickWindow *window) const;
    // Index of a display in the OS's own order (what older saves stored).
    Q_INVOKABLE int osIndexOf(QScreen *screen) const;
    // Display at position n of `screens` (left to right), or null.
    Q_INVOKABLE QScreen *screenAt(int index) const;
    // Display containing a global point (null if none).
    Q_INVOKABLE QScreen *screenContaining(qreal x, qreal y) const;
    Q_INVOKABLE QScreen *primary() const;
    // Display with the most overlap with a rectangle (null if none).
    Q_INVOKABLE QScreen *screenForRect(const QRectF &rect) const;
    // Human-readable label: "BMD HDMI (1) · 2160×3840 portrait".
    Q_INVOKABLE QString describe(QScreen *screen) const;
    // Add a timestamped line to the same rolling log (displays.log) — for
    // other show-day events worth diagnosing later (e.g. NDI blocked).
    Q_INVOKABLE void logEvent(const QString &text) const;

signals:
    void layoutChanged();
    void settlingChanged();
    // Fires immediately (no debounce) when a display disappears, so a
    // fullscreen cover can hide before the OS slides it onto another display.
    void screenGone(QScreen *screen);

private:
    void watch(QScreen *screen);
    void rawChange();
    void settle();
    void setSettling(bool on);
    void rememberIds();
    QVariantMap makeKey(QScreen *screen) const; // keyFor without side effects
    void logLayout(const QString &why) const;

    QList<QPointer<QScreen>> m_watched;
    QTimer *m_debounce = nullptr; // burst end -> layoutChanged
    QTimer *m_grace = nullptr;    // layoutChanged -> settling off
    int m_revision = 0;
    bool m_settling = true;       // calm only after the startup settle
    // Display ids this machine has assigned a window to (persisted). A saved
    // key whose id is in here but not connected is "missing"; an id never
    // used here (a layout from another machine) falls back to the index.
    // Also guards the replaced-unit rule: only never-assigned displays can
    // be adopted in place of a missing one.
    QSet<QString> m_seenIds;
    // Replaced displays (persisted): old id -> the identical unit that
    // stood in for it after it stayed missing.
    QHash<QString, QString> m_replacedBy;
    // When each known-but-missing id was first found missing (this run).
    mutable QHash<QString, qint64> m_missingSince;
    QElapsedTimer m_clock;
};
