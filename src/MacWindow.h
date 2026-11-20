#pragma once

#include <QObject>
#include <QQuickWindow>
#include <QRectF>
#include <QtQml/qqmlregistration.h>

// Raises a window above the macOS menu bar so a borderless fullscreen output
// covers the whole display — Qt's window flags top out below the menu bar's
// window level, so this needs AppKit. All platform code is isolated in the
// .mm; on non-macOS every method is a compiled no-op.
class MacWindow : public QObject
{
    Q_OBJECT
    QML_ELEMENT

public:
    explicit MacWindow(QObject *parent = nullptr);

    // on = true: lift the window above the menu bar and fit it exactly to
    // the display at `target` (Qt global coordinates — the display the
    // caller chose; the cover is never stretched over any other display).
    // on = false: return it to the normal window level.
    Q_INVOKABLE void setCoversMenuBar(QQuickWindow *window, bool on,
                                      const QRectF &target = QRectF());
    // True when the window really is covering `target` above the menu bar
    // (frame and level) — for the fullscreen self-check. Always true on
    // non-macOS builds.
    Q_INVOKABLE bool isCovering(QQuickWindow *window, const QRectF &target) const;
};
