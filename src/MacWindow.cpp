#include "MacWindow.h"

// Non-macOS builds: the menu-bar cover has no meaning, so every method is a
// no-op. The real implementation lives in MacWindow.mm (compiled on Apple).

MacWindow::MacWindow(QObject *parent)
    : QObject(parent)
{
}

void MacWindow::setCoversMenuBar(QQuickWindow *, bool, const QRectF &)
{
}

bool MacWindow::isCovering(QQuickWindow *, const QRectF &) const
{
    return true;
}
