#pragma once

#include <QObject>
#include <QStringList>
#include <QtQml/qqmlregistration.h>

class QProcess;

// QML type "LocalNetworkAccess": the Settings switch "Always allow the NDI
// network" (macOS 15.5+, off by default — only machines where someone turns
// it on are affected).
//
// Why: after a restart macOS can wrongly keep blocking Mosaic's connections
// to NDI sources (a known macOS Local Network privacy issue; see the NDI
// watchdog in Main.qml). Apple's Technote TN3179 documents a system setting
// that exempts address ranges from that per-app check for every program.
// This switch adds the networks the Mac is connected to (wired Ethernet and
// Wi-Fi, detected automatically) to that setting, or removes them again.
// Changing it needs an administrator password (macOS asks) and takes effect
// after the Mac restarts.
//
// The setting is stored in root's preferences (check it with
// `sudo defaults read com.apple.network.local-network`), which Mosaic can't
// read back without the password — so Mosaic remembers what it did:
// ranges it ADDED (removed again when switched off) and ranges that were
// already allowed before (counted as covered, never removed). Other entries
// in the setting are never touched. Work is done by
// resources/localnetwork.sh.
class LocalNetworkAccess : public QObject
{
    Q_OBJECT
    QML_ELEMENT
    // macOS 15.5 or later (where the setting exists).
    Q_PROPERTY(bool supported READ supported CONSTANT)
    // Some network is allowed (by Mosaic, or already before).
    Q_PROPERTY(bool enabled READ enabled NOTIFY changed)
    // Changed since the Mac last started: needs a restart.
    Q_PROPERTY(bool restartPending READ restartPending NOTIFY changed)
    // The administrator prompt is open / the change is running.
    Q_PROPERTY(bool busy READ busy NOTIFY changed)
    // Allowed now when on, what would be allowed when off, e.g.
    // "192.168.10.0/24 (Ethernet)".
    Q_PROPERTY(QStringList networks READ networks NOTIFY changed)
    // Connected now but not allowed (e.g. after moving to another venue).
    Q_PROPERTY(QStringList uncovered READ uncovered NOTIFY changed)
    // Problem with the last attempt (empty when fine or cancelled).
    Q_PROPERTY(QString lastError READ lastError NOTIFY changed)

public:
    explicit LocalNetworkAccess(QObject *parent = nullptr);

    bool supported() const;
    bool enabled() const;
    bool restartPending() const;
    bool busy() const { return m_busy; }
    QStringList networks() const;
    QStringList uncovered() const;
    QString lastError() const { return m_lastError; }

    // Turn the setting on or off (asks for an administrator password).
    Q_INVOKABLE void setEnabled(bool on);
    // While on: also allow the networks connected now that aren't yet.
    Q_INVOKABLE void addCurrent();
    // Re-detect the connected networks (e.g. when Settings opens).
    Q_INVOKABLE void refresh();

signals:
    void changed();

private:
    void detect();
    void run(bool add, const QStringList &eth, const QStringList &wifi);
    void finished(QProcess *process, int exitCode, bool add,
                  const QStringList &eth, const QStringList &wifi);
    void fail(const QString &message);
    void save();

    QStringList m_ethernet;        // detected now
    QStringList m_wifi;
    QStringList m_addedEthernet;   // added by Mosaic (removed when off)
    QStringList m_addedWifi;
    QStringList m_hadEthernet;     // already allowed before (never removed)
    QStringList m_hadWifi;
    QString m_changedBoot;         // boot session of the last change
    bool m_busy = false;
    QString m_lastError;
};
