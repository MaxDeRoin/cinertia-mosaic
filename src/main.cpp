#include <QGuiApplication>
#include <QQmlApplicationEngine>

#include <Processing.NDI.Lib.h>

#include <cstdio>

int main(int argc, char *argv[])
{
#ifdef Q_OS_MACOS
    // On macOS, Qt's window raise() also brings the whole app to the front.
    // Mosaic re-raises its fullscreen covers whenever displays change (TVs
    // waking etc.), which would keep stealing focus from the operator. With
    // this off, raise() only orders the window; MacWindow activates the app
    // itself the one time a cover first appears.
    qputenv("QT_MAC_SET_RAISE_PROCESS", "0");
#endif
    QGuiApplication app(argc, argv);
    QGuiApplication::setApplicationName("Mosaic");
    QGuiApplication::setOrganizationName("Cinertia Systems");

    if (!NDIlib_initialize()) {
        std::fprintf(stderr, "NDI runtime failed to initialize.\n");
        return 1;
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
