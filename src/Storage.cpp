#include "Storage.h"

#include <QDir>
#include <QFile>
#include <QStandardPaths>

namespace {
QString storageDir()
{
    return QStandardPaths::writableLocation(QStandardPaths::AppDataLocation);
}
}

Storage::Storage(QObject *parent)
    : QObject(parent)
{
}

QString Storage::load(const QString &fileName) const
{
    QFile file(storageDir() + QLatin1Char('/') + fileName);
    if (!file.open(QIODevice::ReadOnly | QIODevice::Text))
        return {};
    return QString::fromUtf8(file.readAll());
}

bool Storage::save(const QString &fileName, const QString &contents) const
{
    const QString dir = storageDir();
    QDir().mkpath(dir);
    QFile file(dir + QLatin1Char('/') + fileName);
    if (!file.open(QIODevice::WriteOnly | QIODevice::Text))
        return false;
    file.write(contents.toUtf8());
    return true;
}
