#include "StartupLauncher.h"

#include <QCoreApplication>
#include <QDir>

#ifdef Q_OS_WIN
#include <QSettings>

namespace {
const QString kRunKey = QStringLiteral(
    "HKEY_CURRENT_USER\\Software\\Microsoft\\Windows\\CurrentVersion\\Run");
const QString kAppName = QStringLiteral("Mosaic");

QString launchCommand()
{
    // Quoted absolute path of the running executable, so the entry
    // follows wherever the user installed (or moved) the app.
    return QLatin1Char('"')
        + QDir::toNativeSeparators(QCoreApplication::applicationFilePath())
        + QLatin1Char('"');
}
}
#endif

StartupLauncher::StartupLauncher(QObject *parent)
    : QObject(parent)
{
}

bool StartupLauncher::enabled() const
{
#ifdef Q_OS_WIN
    QSettings run(kRunKey, QSettings::NativeFormat);
    return run.contains(kAppName);
#else
    return false;
#endif
}

void StartupLauncher::setEnabled(bool enabled)
{
#ifdef Q_OS_WIN
    if (enabled == this->enabled())
        return;
    QSettings run(kRunKey, QSettings::NativeFormat);
    if (enabled)
        run.setValue(kAppName, launchCommand());
    else
        run.remove(kAppName);
    emit enabledChanged();
#else
    Q_UNUSED(enabled);
#endif
}
