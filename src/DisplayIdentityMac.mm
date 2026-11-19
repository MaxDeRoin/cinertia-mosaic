#include "DisplayIdentity.h"

#include <QRect>
#include <QScreen>

#import <AppKit/AppKit.h>
#import <ColorSync/ColorSync.h>
#import <CoreGraphics/CoreGraphics.h>

// macOS: identify a display by its CoreGraphics UUID — the identity macOS
// itself uses to remember the display arrangement, so it stays the same
// across reboots and reconnects even when two identical displays (e.g. two
// Blackmagic HDMI outputs) are listed in a different order.
//
// Qt builds each QScreen from an NSScreen: the name is
// NSScreen.localizedName and the geometry is NSScreen.frame flipped to a
// top-left origin. So the QScreen <-> display match is made against
// [NSScreen screens] the same way (name AND frame), which keeps both sides in
// step even while displays are reconfiguring. Anything but exactly one match
// is reported as unresolved — never guessed.

namespace {

// NSScreen frame (bottom-left origin) -> Qt global coordinates (top-left
// origin of the primary display), in points.
QRectF toQtRect(NSScreen *screen)
{
    NSArray<NSScreen *> *all = [NSScreen screens];
    if (all.count == 0)
        return {};
    const CGFloat primaryHeight = all[0].frame.size.height;
    const NSRect f = screen.frame;
    return QRectF(f.origin.x, primaryHeight - (f.origin.y + f.size.height),
                  f.size.width, f.size.height);
}

bool sameRect(const QRectF &a, const QRectF &b)
{
    return qAbs(a.x() - b.x()) <= 1.0 && qAbs(a.y() - b.y()) <= 1.0
        && qAbs(a.width() - b.width()) <= 1.0
        && qAbs(a.height() - b.height()) <= 1.0;
}

QString nameOf(NSScreen *s)
{
    if (@available(macOS 10.15, *))
        return QString::fromNSString(s.localizedName);
    return {};
}

CGDirectDisplayID idOf(NSScreen *s)
{
    NSNumber *num = s.deviceDescription[@"NSScreenNumber"];
    return num ? num.unsignedIntValue : kCGNullDirectDisplay;
}

} // namespace

bool platformHasDisplayIds()
{
    return true;
}

DisplayIdentity platformDisplayIdentity(QScreen *screen)
{
    DisplayIdentity d;
    d.resolved = false;
    if (!screen)
        return d;

    const QRectF g = screen->geometry();
    const QString name = screen->name();
    CGDirectDisplayID match = kCGNullDirectDisplay;
    int matches = 0;
    @autoreleasepool {
        for (NSScreen *s in [NSScreen screens]) {
            if (nameOf(s) == name && sameRect(toQtRect(s), g)) {
                match = idOf(s);
                ++matches;
            }
        }
    }
    if (matches != 1 || match == kCGNullDirectDisplay)
        return d; // mid-change or ambiguous: unresolved

    if (CFUUIDRef uuid = CGDisplayCreateUUIDFromDisplayID(match)) {
        if (CFStringRef str = CFUUIDCreateString(kCFAllocatorDefault, uuid)) {
            d.id = QString::fromCFString(str);
            CFRelease(str);
        }
        CFRelease(uuid);
    }
    if (d.id.isEmpty())
        return d;
    d.resolved = true;
    // EDID numbers (0 = the display doesn't report them).
    if (const uint32_t v = CGDisplayVendorNumber(match))
        d.vendor = QString::number(v);
    if (const uint32_t m = CGDisplayModelNumber(match))
        d.model = QString::number(m);
    if (const uint32_t s = CGDisplaySerialNumber(match))
        d.serial = QString::number(s);
    return d;
}

bool platformDisplayFrame(const QRectF &qtRect, QRectF *platformFrame)
{
    int matches = 0;
    @autoreleasepool {
        for (NSScreen *s in [NSScreen screens]) {
            if (sameRect(toQtRect(s), qtRect)) {
                const NSRect f = s.frame;
                *platformFrame = QRectF(f.origin.x, f.origin.y,
                                        f.size.width, f.size.height);
                ++matches;
            }
        }
    }
    return matches == 1;
}
