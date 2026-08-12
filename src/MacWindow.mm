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

    NSView *view = reinterpret_cast<NSView *>(window->winId());
    NSWindow *nsWindow = view ? [view window] : nil;

    // Presentation options are application-wide, so hide the menu bar and dock
    // while any output is fullscreen and restore them when none is. (Hiding the
    // menu bar requires also hiding the dock.)
    NSApplicationPresentationOptions options = s_covering.isEmpty()
        ? NSApplicationPresentationDefault
        : (NSApplicationPresentationHideMenuBar | NSApplicationPresentationHideDock);
    NSApp.presentationOptions = options;

    if (on && nsWindow) {
        // AppKit "constrains" a borderless window that spans the whole screen
        // (it reserves room for the menu bar/dock), leaving a ~20px gap around
        // the cover. Once the menu bar is hidden, force the frame to the full
        // screen at the AppKit level — after a spin of the main queue so the
        // presentation-options change has settled.
        nsWindow.collectionBehavior |= NSWindowCollectionBehaviorFullScreenAuxiliary;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (nsWindow.screen)
                [nsWindow setFrame:nsWindow.screen.frame display:YES];
        });
    }
}
