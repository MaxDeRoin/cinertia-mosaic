#include <QGuiApplication>
#include <QQmlApplicationEngine>
#include <QDir>
#include <QNetworkInterface>
#include <QProcess>

#include <Processing.NDI.Lib.h>

#include <cstdio>

#include "DiagLog.h"

#ifndef MOSAIC_VERSION
#define MOSAIC_VERSION "?"
#endif

// Redirect stderr to a log file so the NDI runtime's own diagnostics (normally
// discarded in a GUI app) are captured alongside ours, then log the startup
// environment — NDI version and every network interface with its addresses.
static void initDiagLog()
{
    QDir().mkpath(QDir::homePath() + QStringLiteral("/Library/Logs/Mosaic"));
    freopen(diagLogPath().toUtf8().constData(), "a", stderr);
    setvbuf(stderr, nullptr, _IOLBF, 0); // line-buffered: flush each line

    diagLog(QStringLiteral("========== Mosaic %1 NDI diagnostic start ==========")
                .arg(QStringLiteral(MOSAIC_VERSION)));
    diagLog(QStringLiteral("NDI runtime version: %1")
                .arg(QString::fromUtf8(NDIlib_version())));
    for (const QNetworkInterface &ni : QNetworkInterface::allInterfaces()) {
        if (!ni.flags().testFlag(QNetworkInterface::IsUp)
            || ni.flags().testFlag(QNetworkInterface::IsLoopBack))
            continue;
        QStringList addrs;
        for (const QNetworkAddressEntry &e : ni.addressEntries())
            addrs << e.ip().toString();
        diagLog(QStringLiteral("IFACE %1 [%2]: %3")
                    .arg(ni.name(), ni.hardwareAddress(),
                         addrs.isEmpty() ? QStringLiteral("(no addr)")
                                         : addrs.join(QLatin1Char(','))));
    }
}

int main(int argc, char *argv[])
{
    QGuiApplication app(argc, argv);
    QGuiApplication::setApplicationName("Mosaic");
    QGuiApplication::setOrganizationName("Cinertia Systems");

    initDiagLog();

    if (!NDIlib_initialize()) {
        diagLog(QStringLiteral("NDI runtime FAILED to initialize."));
        return 1;
    }
    diagLog(QStringLiteral("NDI runtime initialized OK."));

    // Independent system-mDNS monitor: dns-sd talks straight to macOS's
    // mDNSResponder (Bonjour), separate from NDI's own runtime. If launching
    // Mosaic wedges discovery machine-wide, these MDNS lines show sources
    // being removed even while Mosaic's own finder still lists them.
    {
        QProcess *mdns = new QProcess(&app);
        mdns->setProcessChannelMode(QProcess::MergedChannels);
        QObject::connect(mdns, &QProcess::readyReadStandardOutput, mdns, [mdns]() {
            const QList<QByteArray> lines = mdns->readAllStandardOutput().split('\n');
            for (const QByteArray &ln : lines) {
                if (ln.trimmed().isEmpty())
                    continue;
                diagLog(QStringLiteral("MDNS %1").arg(QString::fromUtf8(ln)));
            }
        });
        mdns->start(QStringLiteral("/usr/bin/dns-sd"),
                    {QStringLiteral("-B"), QStringLiteral("_ndi._tcp"),
                     QStringLiteral("local.")});
        QObject::connect(&app, &QCoreApplication::aboutToQuit, mdns, [mdns]() {
            mdns->kill();
            mdns->waitForFinished(500);
        });
    }

    int result = 1;
    {
        QQmlApplicationEngine engine;
        QObject::connect(
            &engine, &QQmlApplicationEngine::objectCreationFailed,
            &app, []() { QCoreApplication::exit(1); },
            Qt::QueuedConnection);
        engine.loadFromModule("Mosaic", "Main");

        result = app.exec();
    } // engine (and all NDI objects) destroyed before the library shuts down

    NDIlib_destroy();
    return result;
}
