#pragma once

#include <QObject>
#include <QtQml/qqmlregistration.h>

// Tiny file helper so QML can persist JSON (profiles, last session).
// Files live in the per-user app data folder, e.g.
// C:/Users/<user>/AppData/Roaming/Cinertia Systems/Mosaic/
class Storage : public QObject
{
    Q_OBJECT
    QML_ELEMENT

public:
    explicit Storage(QObject *parent = nullptr);

    Q_INVOKABLE QString load(const QString &fileName) const;
    Q_INVOKABLE bool save(const QString &fileName, const QString &contents) const;
};
