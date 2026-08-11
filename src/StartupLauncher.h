#pragma once

#include <QObject>
#include <QtQml/qqmlregistration.h>

// Registers Mosaic to start when the user logs in. The session restore
// already brings every canvas back on its assigned display in its saved
// window mode, so autostart plus restore equals a self-starting video
// wall. Platform code is isolated in the .cpp: Windows uses the
// per-user registry Run key (no admin rights needed); on macOS this is
// currently a no-op (Login Items are the equivalent there). The
// registry is the source of truth — the setting is read back from it,
// not stored in the session file.
class StartupLauncher : public QObject
{
    Q_OBJECT
    QML_ELEMENT
    Q_PROPERTY(bool enabled READ enabled WRITE setEnabled NOTIFY enabledChanged)

public:
    explicit StartupLauncher(QObject *parent = nullptr);

    bool enabled() const;
    void setEnabled(bool enabled);

signals:
    void enabledChanged();
};
