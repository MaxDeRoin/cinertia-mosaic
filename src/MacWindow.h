#pragma once

#include <QObject>
#include <QQuickWindow>
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

    // on = true: lift the window above the menu bar (fullscreen cover).
    // on = false: return it to the normal window level.
    Q_INVOKABLE void setCoversMenuBar(QQuickWindow *window, bool on);
};
