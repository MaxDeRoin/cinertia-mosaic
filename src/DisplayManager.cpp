#include "DisplayManager.h"

#include "DisplayIdentity.h"

#include <QDateTime>
#include <QElapsedTimer>
#include <QDir>
#include <QFile>
#include <QGuiApplication>
#include <QJsonDocument>
#include <QQmlEngine>
#include <QQuickWindow>
#include <QSettings>
#include <QStandardPaths>
#include <QTimer>

#include <algorithm>
#include <limits>

namespace {
// Quiet time after the last raw display event before the layout counts as
// settled. Boot and standby-wake deliver several changes ~100-500 ms apart.
constexpr int kDebounceMs = 800;
// How long after settling OS-driven window moves are still ignored.
constexpr int kGraceMs = 1500;
// While some display can't be identified yet (mid-change), keep waiting —
// but never longer than this many extra debounce rounds.
constexpr int kMaxUnresolvedRetries = 10;

const QString kKnownIdsSetting = QStringLiteral("displays/knownIds");
const QString kReplacedSetting = QStringLiteral("displays/replacedBy");
const QString kKnownSignaturesSetting = QStringLiteral("displays/knownSignatures");
// A known display must be gone this long (with the layout calm) before an
// identical never-used display may stand in for it — so a TV in HDMI
// standby, or one that is slow to come up at boot, is never replaced.
constexpr qint64 kAdoptAfterMs = 2 * 60 * 1000;

QVariantMap toMap(const QVariant &key)
{
    if (key.metaType().id() == QMetaType::QVariantMap)
        return key.toMap();
    // QML hands over the JSON string stored in the ListModel/session.
    const QString text = key.toString();
    if (text.isEmpty())
        return {};
    return QJsonDocument::fromJson(text.toUtf8()).toVariant().toMap();
}

qint64 distance2(QScreen *s, const QPoint &p)
{
    const QPoint d = s->geometry().topLeft() - p;
    return qint64(d.x()) * d.x() + qint64(d.y()) * d.y();
}

// The OS's display list sorted left to right, then top to bottom — the
// order people number their displays in, and stable across reboots.
QList<QScreen *> sortedScreens()
{
    QList<QScreen *> list = QGuiApplication::screens();
    std::stable_sort(list.begin(), list.end(), [](QScreen *a, QScreen *b) {
        const QRect ga = a->geometry();
        const QRect gb = b->geometry();
        return ga.x() != gb.x() ? ga.x() < gb.x() : ga.y() < gb.y();
    });
    return list;
}

// Platforms without ids: what a key says about its display, as strings to
// remember — the EDID make/model/serial when there is a serial, and the
// display's name. Not Windows' generic device names ("\\.\DISPLAY2", used
// when a display reports no name of its own): Windows renumbers those, so
// a saved one may never come back even with the display connected — such
// keys stay "from elsewhere" and keep the old absolute-rectangle restore.
QStringList signaturesOf(const QString &vendor, const QString &model,
                         const QString &serial, const QString &name)
{
    QStringList out;
    if (!serial.isEmpty())
        out.append(QStringLiteral("edid:%1|%2|%3").arg(vendor, model, serial));
    if (!name.isEmpty() && !name.startsWith(QLatin1String("\\\\.\\")))
        out.append(QStringLiteral("name:") + name);
    return out;
}

QVariantMap result(const char *state, QScreen *screen = nullptr)
{
    QVariantMap r{{QStringLiteral("state"), QString::fromLatin1(state)}};
    if (screen)
        r.insert(QStringLiteral("screen"), QVariant::fromValue(screen));
    return r;
}
} // namespace

DisplayManager::DisplayManager(QObject *parent)
    : QObject(parent)
{
    m_debounce = new QTimer(this);
    m_debounce->setSingleShot(true);
    m_debounce->setInterval(kDebounceMs);
    connect(m_debounce, &QTimer::timeout, this, &DisplayManager::settle);

    m_grace = new QTimer(this);
    m_grace->setSingleShot(true);
    m_grace->setInterval(kGraceMs);
    connect(m_grace, &QTimer::timeout, this, [this] { setSettling(false); });

    auto *app = qGuiApp;
    connect(app, &QGuiApplication::screenAdded, this, [this](QScreen *s) {
        watch(s);
        rawChange();
    });
    connect(app, &QGuiApplication::screenRemoved, this, [this](QScreen *s) {
        emit screenGone(s); // immediately — see the signal's comment
        rawChange();
    });
    connect(app, &QGuiApplication::primaryScreenChanged, this,
            &DisplayManager::rawChange);
    for (QScreen *s : QGuiApplication::screens())
        watch(s);

    if (platformHasDisplayIds()) {
        const QStringList known =
            QSettings().value(kKnownIdsSetting).toStringList();
        m_seenIds = QSet<QString>(known.begin(), known.end());
        const QVariantMap replaced = QSettings().value(kReplacedSetting).toMap();
        for (auto it = replaced.cbegin(); it != replaced.cend(); ++it)
            m_replacedBy.insert(it.key(), it.value().toString());
    } else {
        const QStringList known =
            QSettings().value(kKnownSignaturesSetting).toStringList();
        m_seenSignatures = QSet<QString>(known.begin(), known.end());
    }
    m_clock.start();

    // Start "settling": at login the app can launch in the middle of the
    // displays coming up, with no further event to tell it when they're
    // done. One layoutChanged fires shortly after launch regardless, so
    // every window places itself against the settled layout.
    m_debounce->start();
}

void DisplayManager::watch(QScreen *screen)
{
    if (!screen)
        return;
    // QScreen has no QObject parent, so the first time QML receives one from
    // a Q_INVOKABLE (screenAt, primary, ...) the engine would take ownership
    // and its garbage collector would later DELETE the live QScreen — a
    // crash hours into a show. Pin every screen to C++ ownership before QML
    // can ever see it.
    QQmlEngine::setObjectOwnership(screen, QQmlEngine::CppOwnership);
    m_watched.removeIf([](const QPointer<QScreen> &p) { return p.isNull(); });
    for (const auto &w : std::as_const(m_watched))
        if (w == screen)
            return;
    m_watched.append(screen);
    // A display that changes resolution or rotation keeps the same QScreen
    // and only reports geometryChanged — the event the old
    // screens-added/removed-only logic missed, leaving fullscreen covers at
    // the wrong size. (availableGeometryChanged is deliberately NOT watched:
    // hiding the menu bar for a fullscreen cover changes it, which would
    // turn every fullscreen switch into a display change.)
    connect(screen, &QScreen::geometryChanged, this, &DisplayManager::rawChange);
    connect(screen, &QScreen::orientationChanged, this, &DisplayManager::rawChange);
}

void DisplayManager::rawChange()
{
    setSettling(true);
    m_grace->stop();
    m_debounce->start(); // restart: wait for the burst to end
}

void DisplayManager::settle()
{
    // On macOS every display must be identifiable before windows act on the
    // layout; right after a change one may briefly not be. Wait a little
    // longer (bounded) rather than decide on half a picture.
    static int unresolvedRounds = 0;
    if (platformHasDisplayIds()) {
        bool allResolved = true;
        for (QScreen *s : QGuiApplication::screens())
            allResolved = allResolved && platformDisplayIdentity(s).resolved;
        if (!allResolved && unresolvedRounds < kMaxUnresolvedRetries) {
            ++unresolvedRounds;
            m_debounce->start();
            return;
        }
    }
    unresolvedRounds = 0;
    // The "missing for a while" clock restarts with every layout change:
    // a display plugged in just now is never adopted at once because some
    // other display has been gone for hours.
    m_missingSince.clear();

    ++m_revision;
    logLayout(m_revision == 1 ? QStringLiteral("startup")
                              : QStringLiteral("display change"));
    emit layoutChanged();
    m_grace->start();
}

void DisplayManager::setSettling(bool on)
{
    if (on == m_settling)
        return;
    m_settling = on;
    emit settlingChanged();
}

bool DisplayManager::canReportMissing() const
{
    return platformHasDisplayIds();
}

QVariantList DisplayManager::screens() const
{
    QVariantList list;
    for (QScreen *s : sortedScreens())
        list.append(QVariant::fromValue(s));
    return list;
}

QScreen *DisplayManager::screenAt(int index) const
{
    const auto all = sortedScreens();
    return (index >= 0 && index < all.size()) ? all.at(index) : nullptr;
}

int DisplayManager::osIndexOf(QScreen *screen) const
{
    return QGuiApplication::screens().indexOf(screen);
}

QScreen *DisplayManager::screenContaining(qreal x, qreal y) const
{
    const QPointF p(x, y);
    for (QScreen *s : QGuiApplication::screens())
        if (QRectF(s->geometry()).contains(p))
            return s;
    return nullptr;
}

QScreen *DisplayManager::screenForRect(const QRectF &rect) const
{
    QScreen *best = nullptr;
    qreal bestArea = 0;
    for (QScreen *s : QGuiApplication::screens()) {
        const QRectF overlap = QRectF(s->geometry()).intersected(rect);
        const qreal area = overlap.width() * overlap.height();
        if (area > bestArea) {
            bestArea = area;
            best = s;
        }
    }
    return best;
}

QScreen *DisplayManager::primary() const
{
    return QGuiApplication::primaryScreen();
}

QScreen *DisplayManager::screenOf(QQuickWindow *window) const
{
    return window ? window->screen() : nullptr;
}

void DisplayManager::assignScreen(QQuickWindow *window, QScreen *screen) const
{
    if (window && screen && window->screen() != screen)
        window->setScreen(screen);
}

QString DisplayManager::describe(QScreen *screen) const
{
    if (!screen)
        return {};
    const QRect g = screen->geometry();
    return QStringLiteral("%1 · %2×%3 %4")
        .arg(screen->name().isEmpty() ? QStringLiteral("Display") : screen->name())
        .arg(g.width())
        .arg(g.height())
        .arg(g.height() > g.width() ? QStringLiteral("portrait")
                                    : QStringLiteral("landscape"));
}

QVariantMap DisplayManager::keyFor(QScreen *screen) const
{
    if (!screen)
        return {};
    const DisplayIdentity d = platformDisplayIdentity(screen);
    // On a platform with ids, a display that can't be identified right now
    // gets no key at all — a key without an id would silently mean "the OS's
    // list order" forever, the very thing keys exist to avoid. Callers keep
    // what they had.
    if (platformHasDisplayIds() && !d.resolved)
        return {};
    const_cast<DisplayManager *>(this)->markUsed(screen);
    return makeKey(screen);
}

void DisplayManager::markUsed(QScreen *screen)
{
    if (!screen)
        return;
    const DisplayIdentity d = platformDisplayIdentity(screen);
    // Remember that this machine has used this display, so a later absence
    // means "disconnected", not "a layout from elsewhere" — and so it is
    // never taken as a stand-in for some other missing display.
    if (d.resolved && !d.id.isEmpty() && !m_seenIds.contains(d.id)) {
        m_seenIds.insert(d.id);
        rememberIds();
    }
    if (!platformHasDisplayIds()) {
        bool added = false;
        const QStringList sigs =
            signaturesOf(d.vendor, d.model, d.serial, screen->name());
        for (const QString &sig : sigs) {
            if (!m_seenSignatures.contains(sig)) {
                m_seenSignatures.insert(sig);
                added = true;
            }
        }
        if (added) {
            QStringList list(m_seenSignatures.begin(), m_seenSignatures.end());
            list.sort();
            QSettings().setValue(kKnownSignaturesSetting, list);
        }
    }
}

bool DisplayManager::usedHere(const QVariant &keyVariant) const
{
    const QVariantMap key = toMap(keyVariant);
    if (platformHasDisplayIds()) {
        const QString id = key.value(QStringLiteral("id")).toString();
        return !id.isEmpty() && m_seenIds.contains(id);
    }
    const QStringList sigs = signaturesOf(key.value(QStringLiteral("vendor")).toString(),
                                          key.value(QStringLiteral("model")).toString(),
                                          key.value(QStringLiteral("serial")).toString(),
                                          key.value(QStringLiteral("name")).toString());
    for (const QString &sig : sigs)
        if (m_seenSignatures.contains(sig))
            return true;
    return false;
}

QVariantMap DisplayManager::makeKey(QScreen *screen) const
{
    const DisplayIdentity d = platformDisplayIdentity(screen);
    const QRect g = screen->geometry();
    return {
        { QStringLiteral("id"), d.id },
        { QStringLiteral("vendor"), d.vendor },
        { QStringLiteral("model"), d.model },
        { QStringLiteral("serial"), d.serial },
        { QStringLiteral("name"), screen->name() },
        { QStringLiteral("x"), g.x() },
        { QStringLiteral("y"), g.y() },
        { QStringLiteral("w"), g.width() },
        { QStringLiteral("h"), g.height() },
    };
}

void DisplayManager::rememberIds()
{
    QStringList list(m_seenIds.begin(), m_seenIds.end());
    list.sort();
    QSettings settings;
    settings.setValue(kKnownIdsSetting, list);
    QVariantMap replaced;
    for (auto it = m_replacedBy.cbegin(); it != m_replacedBy.cend(); ++it)
        replaced.insert(it.key(), it.value());
    settings.setValue(kReplacedSetting, replaced);
}

QVariantMap DisplayManager::resolve(const QVariant &keyVariant,
                                    int fallbackIndex) const
{
    const auto all = QGuiApplication::screens();
    if (all.isEmpty())
        return result("missing");
    // The old behavior: an index into the OS's list, clamped.
    const auto fallback = [&] {
        return result("fallback",
                      all.at(qBound(0, fallbackIndex, int(all.size()) - 1)));
    };

    const QVariantMap key = toMap(keyVariant);
    const QString id = key.value(QStringLiteral("id")).toString();
    const QString vendor = key.value(QStringLiteral("vendor")).toString();
    const QString model = key.value(QStringLiteral("model")).toString();
    const QString serial = key.value(QStringLiteral("serial")).toString();
    const QString name = key.value(QStringLiteral("name")).toString();
    const QPoint savedPos(key.value(QStringLiteral("x")).toInt(),
                          key.value(QStringLiteral("y")).toInt());
    if (id.isEmpty() && serial.isEmpty() && name.isEmpty())
        return fallback(); // no key (saved before keys existed)

    QList<DisplayIdentity> ids;
    ids.reserve(all.size());
    for (QScreen *s : all)
        ids.append(platformDisplayIdentity(s));

    if (platformHasDisplayIds()) {
        // A key without an id came from a platform without ids.
        if (id.isEmpty())
            return fallback();

        // 1. The stable OS id is authoritative. Several screens with the
        //    same id (shouldn't happen) -> nearest to the saved position.
        QScreen *hit = nullptr;
        for (int i = 0; i < all.size(); ++i) {
            if (ids.at(i).resolved && ids.at(i).id == id
                    && (!hit || distance2(all.at(i), savedPos)
                                    < distance2(hit, savedPos)))
                hit = all.at(i);
        }
        if (hit) {
            m_missingSince.remove(id);
            // The original unit is back: retire any replacement recorded
            // for it, so a later absence never jumps straight onto the
            // (possibly since re-used) stand-in.
            if (m_replacedBy.contains(id)) {
                auto *self = const_cast<DisplayManager *>(this);
                self->m_replacedBy.remove(id);
                self->rememberIds();
            }
            return result("found", hit);
        }

        // 1b. Its display was replaced earlier (see 3): follow to the
        //     replacement. A direct match above always wins, so the original
        //     unit coming back takes its windows back.
        QString cur = id;
        for (int hop = 0; hop < 8 && m_replacedBy.contains(cur); ++hop) {
            cur = m_replacedBy.value(cur);
            for (int i = 0; i < all.size(); ++i)
                if (ids.at(i).resolved && ids.at(i).id == cur)
                    return result("found", all.at(i));
        }

        // Not matched — but if some display can't be identified right now,
        // it might be this one: decide nothing until the layout settles.
        for (const DisplayIdentity &d : std::as_const(ids))
            if (!d.resolved)
                return result("uncertain");

        // 2. An id this machine never used: a layout exported from another
        //    machine (or copied profiles) — use the saved index, as before.
        if (!m_seenIds.contains(id))
            return fallback();

        // 3. This machine's display, not connected. One exception, so a
        //    replaced converter or TV heals itself: after it has been gone
        //    for a while with the layout calm, exactly one connected display
        //    of the same make and model that NO window has ever used (so
        //    unplugging the left TV can never send its picture to the right
        //    TV, whose id is known) stands in for it. Recorded as a
        //    replacement, so every profile and layout keyed to the old
        //    display follows.
        if (!m_settling && !vendor.isEmpty() && !model.isEmpty()) {
            const qint64 now = m_clock.elapsed();
            const qint64 since = m_missingSince.value(id, -1);
            if (since < 0)
                m_missingSince.insert(id, now);
            if (since >= 0 && now - since >= kAdoptAfterMs) {
                QScreen *candidate = nullptr;
                QString candidateId;
                int count = 0;
                for (int i = 0; i < all.size(); ++i) {
                    const DisplayIdentity &d = ids.at(i);
                    if (d.resolved && d.vendor == vendor && d.model == model
                            && !m_seenIds.contains(d.id)) {
                        candidate = all.at(i);
                        candidateId = d.id;
                        ++count;
                    }
                }
                if (count == 1) {
                    auto *self = const_cast<DisplayManager *>(this);
                    // Extend the chain at its end, so keys saved for an
                    // earlier stand-in follow too.
                    self->m_replacedBy.insert(cur, candidateId);
                    self->m_seenIds.insert(candidateId);
                    self->rememberIds();
                    m_missingSince.remove(id);
                    logLayout(
                        QStringLiteral("display %1 replaced by %2").arg(id, candidateId));
                    return result("found", candidate);
                }
            }
        }
        // (Never a name fallback: macOS renumbers identical displays, e.g.
        // "BMD HDMI (1)/(3)", when one of them is unplugged.)
        return result("missing");
    }

    // Platforms without stable ids (Windows): EDID serial, then name — and
    // if neither singles out a display, the saved index exactly as before,
    // so nothing that used to show is ever hidden here.
    if (!serial.isEmpty()) {
        QScreen *hit = nullptr;
        int hits = 0;
        for (int i = 0; i < all.size(); ++i) {
            const DisplayIdentity &d = ids.at(i);
            if (d.serial == serial && d.model == model && d.vendor == vendor) {
                hit = all.at(i);
                ++hits;
            }
        }
        if (hits == 1)
            return result("found", hit);
    }
    if (!name.isEmpty()) {
        QScreen *best = nullptr;
        int hits = 0;
        for (QScreen *s : all) {
            if (s->name() != name)
                continue;
            ++hits;
            if (!best || distance2(s, savedPos) < distance2(best, savedPos))
                best = s;
        }
        if (hits == 1)
            return result("found", best);
        if (hits > 1)
            return result("found", best); // identical names: nearest spot
    }
    return fallback();
}

void DisplayManager::logEvent(const QString &text) const
{
    const QString dir =
        QStandardPaths::writableLocation(QStandardPaths::AppDataLocation);
    QDir().mkpath(dir);
    QFile file(dir + QStringLiteral("/displays.log"));
    if (!file.open(QIODevice::Append | QIODevice::Text))
        return;
    file.write(QDateTime::currentDateTime().toString(Qt::ISODate).toUtf8()
               + " " + text.toUtf8() + "\n");
}

void DisplayManager::logLayout(const QString &why) const
{
    // A small rolling log of every settled display layout with each
    // display's identity — so a wrong assignment on the show machine can be
    // diagnosed after the fact (and the ids' stability verified).
    const QString dir =
        QStandardPaths::writableLocation(QStandardPaths::AppDataLocation);
    QDir().mkpath(dir);
    const QString path = dir + QStringLiteral("/displays.log");
    QFile file(path);
    if (file.size() > 256 * 1024) {
        // Keep the newer half.
        if (file.open(QIODevice::ReadOnly)) {
            const QByteArray all = file.readAll();
            file.close();
            if (file.open(QIODevice::WriteOnly | QIODevice::Truncate))
                file.write(all.mid(all.size() / 2));
            file.close();
        }
    }
    if (!file.open(QIODevice::Append | QIODevice::Text))
        return;
    QByteArray out;
    out += QDateTime::currentDateTime().toString(Qt::ISODate).toUtf8()
        + " layout #" + QByteArray::number(m_revision) + " (" + why.toUtf8()
        + ")\n";
    const auto all = QGuiApplication::screens();
    for (int i = 0; i < all.size(); ++i) {
        QScreen *s = all.at(i);
        const DisplayIdentity d = platformDisplayIdentity(s);
        const QRect g = s->geometry();
        out += QStringLiteral("  [%1] \"%2\" %3,%4 %5x%6%7 id=%8 vendor=%9 "
                              "model=%10 serial=%11%12\n")
                   .arg(i)
                   .arg(s->name())
                   .arg(g.x()).arg(g.y()).arg(g.width()).arg(g.height())
                   .arg(s == QGuiApplication::primaryScreen()
                            ? QStringLiteral(" primary") : QString())
                   .arg(d.id.isEmpty() ? QStringLiteral("-") : d.id)
                   .arg(d.vendor.isEmpty() ? QStringLiteral("-") : d.vendor)
                   .arg(d.model.isEmpty() ? QStringLiteral("-") : d.model)
                   .arg(d.serial.isEmpty() ? QStringLiteral("-") : d.serial)
                   .arg(d.resolved ? QString() : QStringLiteral(" UNRESOLVED"))
                   .toUtf8();
    }
    file.write(out);
}
