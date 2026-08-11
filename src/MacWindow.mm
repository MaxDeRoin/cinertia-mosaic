#include "MacWindow.h"

#include <QSet>

#import <AppKit/AppKit.h>

// Windows currently asking for a menu-bar-free display. Shared across every
// MacWindow instance (one per window) so the menu bar/dock only come back once
// the LAST fullscreen output leaves — and so repeated calls (a monitor switch
// re-applies fullscreen) stay idempotent.
static QSet<QQuickWindow *> s_covering;

MacWindow::MacWindow(QObject *parent)
    : QObject(parent)
{
}

void MacWindow::setCoversMenuBar(QQuickWindow *window, bool on)
{
    if (!window)
        return;
    if (on)
        s_covering.insert(window);
    else
        s_covering.remove(window);

    // Presentation options are application-wide, so hide the menu bar and dock
    // while any output is fullscreen and restore them when none is. (Hiding the
    // menu bar requires also hiding the dock.)
    NSApplicationPresentationOptions options = s_covering.isEmpty()
        ? NSApplicationPresentationDefault
        : (NSApplicationPresentationHideMenuBar | NSApplicationPresentationHideDock);
    NSApp.presentationOptions = options;
}
