#include "MacWindow.h"

#include "DisplayIdentity.h"

#include <QElapsedTimer>
#include <QPointer>
#include <QSet>

#import <AppKit/AppKit.h>

// Windows currently asking for a menu-bar-free display. Shared across every
// MacWindow instance (one per window) so the menu bar/dock only come back once
// the LAST fullscreen output leaves — and so repeated calls (a monitor switch
// re-applies fullscreen) stay idempotent.
static QSet<QQuickWindow *> s_covering;
// Windows that have ever covered a display (for the destroyed-window
// cleanup below).
static QSet<QQuickWindow *> s_everCovered;
// Bringing Mosaic to the front happens at most once, and only right after
// launch (the login-start case it exists for). Never later — a TV waking
// hours into a show, or a profile switch opening a new fullscreen canvas,
// must not steal focus from whatever the operator is doing.
static bool s_activatedOnce = false;
static QElapsedTimer s_sinceLaunch;
constexpr qint64 kActivateWindowMs = 30000;

MacWindow::MacWindow(QObject *parent)
    : QObject(parent)
{
    if (!s_sinceLaunch.isValid())
        s_sinceLaunch.start();
}

// The presentation options we want right now, from the covering set.
static NSApplicationPresentationOptions desiredOptions()
{
    return s_covering.isEmpty()
        ? NSApplicationPresentationDefault
        : (NSApplicationPresentationHideMenuBar | NSApplicationPresentationHideDock);
}

static NSWindow *nsWindowOf(QQuickWindow *window)
{
    NSView *view = reinterpret_cast<NSView *>(window->winId());
    return view ? [view window] : nil;
}

void MacWindow::setCoversMenuBar(QQuickWindow *window, bool on,
                                 const QRectF &target)
{
    if (!window)
        return;
    const bool firstEver = on && !s_everCovered.contains(window);
    if (firstEver) {
        s_everCovered.insert(window);
        // A covering window that is destroyed (canvas closed, profile
        // switch) must not keep the menu bar and Dock hidden.
        QObject::connect(window, &QObject::destroyed, [window] {
            s_covering.remove(window);
            s_everCovered.remove(window);
            NSApp.presentationOptions = desiredOptions();
        });
    }
    if (on)
        s_covering.insert(window);
    else
        s_covering.remove(window);

    NSWindow *nsWindow = nsWindowOf(window);

    // Presentation options only take effect for the ACTIVE application. When
    // Mosaic is launched at login, another app holds focus, so the menu bar
    // stayed visible over the fullscreen cover. Re-assert the options every
    // time the app becomes active — and, once, right after launch, bring
    // Mosaic to the front (a fullscreen multiviewer started at login should
    // own the display it covers). Never later: display changes, a TV waking,
    // the self check never steal focus from whatever the operator is doing.
    static bool observerInstalled = false;
    if (!observerInstalled) {
        observerInstalled = true;
        [[NSNotificationCenter defaultCenter]
            addObserverForName:NSApplicationDidBecomeActiveNotification
                        object:NSApp
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification *) {
                        NSApp.presentationOptions = desiredOptions();
                    }];
    }
    if (on && !s_activatedOnce && s_sinceLaunch.isValid()
            && s_sinceLaunch.elapsed() < kActivateWindowMs) {
        s_activatedOnce = true;
        if (![NSApp isActive])
            [NSApp activateIgnoringOtherApps:YES];
    }

    // Presentation options are application-wide, so hide the menu bar and dock
    // while any output is fullscreen and restore them when none is. (Hiding the
    // menu bar requires also hiding the dock.)
    NSApp.presentationOptions = desiredOptions();

    if (nsWindow) {
        // Presentation options only work while the app is active, and a
        // login-launched app cannot activate itself on modern macOS — so the
        // menu bar stayed visible over covers created at startup. Drawing
        // above the menu bar's window level covers it regardless of focus
        // (the right behavior for a dedicated output display anyway).
        nsWindow.level = on ? NSMainMenuWindowLevel + 1 : NSNormalWindowLevel;
        // A normal window again: stop following the operator onto every
        // Space (set below while covering).
        if (!on)
            nsWindow.collectionBehavior &= ~(NSWindowCollectionBehaviorCanJoinAllSpaces
                                             | NSWindowCollectionBehaviorStationary);
    }
    if (on && nsWindow) {
        // Stay put on its display across Spaces ("Displays have separate
        // Spaces" switches would otherwise leave the cover behind).
        nsWindow.collectionBehavior |= NSWindowCollectionBehaviorFullScreenAuxiliary
            | NSWindowCollectionBehaviorCanJoinAllSpaces
            | NSWindowCollectionBehaviorStationary;

        // AppKit "constrains" a borderless window that spans the whole screen
        // (it reserves room for the menu bar/dock), leaving a ~20px gap around
        // the cover. Once the menu bar is hidden, force the frame to the full
        // display at the AppKit level — after a spin of the main queue so the
        // presentation-options change has settled. The display is the one the
        // caller chose (`target`), looked up fresh when the block runs; if it
        // can't be found unambiguously (it just went away, or displays are
        // mid-change) nothing is moved, so a cover can never be stretched
        // over some other display such as the operator's.
        QPointer<QQuickWindow> guard(window);
        const QRectF targetRect = target;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!guard || !s_covering.contains(guard.data()))
                return; // no longer covering: leave it alone
            NSWindow *w = nsWindowOf(guard.data());
            QRectF frame;
            if (!w || targetRect.isEmpty()
                    || !platformDisplayFrame(targetRect, &frame))
                return;
            [w setFrame:NSMakeRect(frame.x(), frame.y(), frame.width(),
                                   frame.height())
                display:YES];
        });
    }
}

bool MacWindow::isCovering(QQuickWindow *window, const QRectF &target) const
{
    if (!window || !s_covering.contains(window))
        return false;
    NSWindow *nsWindow = nsWindowOf(window);
    if (!nsWindow || !nsWindow.visible)
        return false;
    // Qt can rebuild the native window (flag or visibility changes), which
    // silently drops the raised level — so check the level, not just size.
    if (nsWindow.level <= NSMainMenuWindowLevel)
        return false;
    QRectF frame;
    if (!platformDisplayFrame(target, &frame))
        return true; // can't tell right now: don't force a re-apply
    const NSRect f = nsWindow.frame;
    return qAbs(f.origin.x - frame.x()) <= 2 && qAbs(f.origin.y - frame.y()) <= 2
        && qAbs(f.size.width - frame.width()) <= 2
        && qAbs(f.size.height - frame.height()) <= 2;
}
