#pragma once

#include <QRectF>
#include <QString>

class QScreen;

// Platform identity for one display — what lets Mosaic recognise "the left
// TV" again after a reboot, when the OS may list the displays in a different
// order. Implemented per platform (DisplayIdentityMac.mm on macOS,
// DisplayIdentityOther.cpp elsewhere); the portable logic is DisplayManager.
struct DisplayIdentity
{
    // Stable unique id that survives reboots and reconnects. macOS: the
    // display's UUID (CGDisplayCreateUUIDFromDisplayID — the same identity
    // macOS uses to remember the display arrangement). Empty where the
    // platform has no such id.
    QString id;
    // Hardware hints (EDID vendor/model/serial), used for matching only when
    // no stable id is available or to recognise a replaced identical unit.
    // Empty when unknown.
    QString vendor;
    QString model;
    QString serial;
    // False when this platform HAS ids but this screen could not be matched
    // to one right now (displays mid-change). Callers must then wait for the
    // layout to settle instead of deciding anything.
    bool resolved = true;
};

// Whether this platform provides stable display ids at all.
bool platformHasDisplayIds();

DisplayIdentity platformDisplayIdentity(QScreen *screen);

// macOS menu-bar cover support (no-ops elsewhere): find the display a
// rectangle in Qt's global coordinates refers to, as the platform sees it.
// Returns true and the platform frame when exactly one display matches.
bool platformDisplayFrame(const QRectF &qtRect, QRectF *platformFrame);
