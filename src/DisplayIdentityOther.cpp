#include "DisplayIdentity.h"

#include <QScreen>

// Non-macOS builds: no OS-level display UUID, so identity comes from what Qt
// reads out of each monitor's EDID (on Windows: manufacturer, model and
// serial number) plus the screen name. DisplayManager falls back to the old
// index-based choice whenever these don't single out one display, so Windows
// never hides an output it would have shown before.

bool platformHasDisplayIds()
{
    return false;
}

DisplayIdentity platformDisplayIdentity(QScreen *screen)
{
    DisplayIdentity d;
    if (!screen)
        return d;
    d.vendor = screen->manufacturer();
    d.model = screen->model();
    // TVs and converters often report no serial, or 0 — useless for matching.
    const QString serial = screen->serialNumber().trimmed();
    if (!serial.isEmpty() && serial != QLatin1String("0"))
        d.serial = serial;
    return d;
}

bool platformDisplayFrame(const QRectF &, QRectF *)
{
    return false;
}
