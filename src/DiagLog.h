#pragma once

// Lightweight NDI diagnostic logging (0.6.x macOS discovery investigation).
// Everything is written to stderr, which main() redirects to a log file, so the
// NDI runtime's own stderr messages land in the same file interleaved with ours.

#include <cstdio>
#include <QDir>
#include <QDateTime>
#include <QString>

inline QString diagLogPath()
{
    return QDir::homePath() + QStringLiteral("/Library/Logs/Mosaic/ndi-diagnostic.log");
}

inline void diagLog(const QString &msg)
{
    fprintf(stderr, "[%s] %s\n",
            QDateTime::currentDateTime().toString(QStringLiteral("HH:mm:ss.zzz"))
                .toUtf8().constData(),
            msg.toUtf8().constData());
    fflush(stderr);
}
