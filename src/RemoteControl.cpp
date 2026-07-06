#include "RemoteControl.h"

#include <QTcpServer>
#include <QTcpSocket>

RemoteControl::RemoteControl(QObject *parent)
    : QObject(parent)
    , m_server(new QTcpServer(this))
{
    connect(m_server, &QTcpServer::newConnection,
            this, &RemoteControl::onNewConnection);
}

void RemoteControl::setEnabled(bool enabled)
{
    if (enabled == m_enabled)
        return;
    m_enabled = enabled;
    emit enabledChanged();
    applyState();
}

void RemoteControl::setPort(int port)
{
    port = qBound(1, port, 65535);
    if (port == m_port)
        return;
    m_port = port;
    emit portChanged();
    applyState();
}

void RemoteControl::applyState()
{
    if (m_server->isListening())
        m_server->close();
    for (auto it = m_buffers.keyBegin(); it != m_buffers.keyEnd(); ++it)
        (*it)->disconnectFromHost();
    m_buffers.clear();

    const bool nowListening =
        m_enabled && m_server->listen(QHostAddress::Any, quint16(m_port));
    if (nowListening != m_listening) {
        m_listening = nowListening;
        emit listeningChanged();
    } else {
        m_listening = nowListening;
    }
}

void RemoteControl::onNewConnection()
{
    while (QTcpSocket *socket = m_server->nextPendingConnection()) {
        m_buffers.insert(socket, QByteArray());
        connect(socket, &QTcpSocket::readyRead,
                this, [this, socket] { onReadyRead(socket); });
        connect(socket, &QTcpSocket::disconnected, this, [this, socket] {
            m_buffers.remove(socket);
            socket->deleteLater();
        });
    }
}

void RemoteControl::onReadyRead(QTcpSocket *socket)
{
    QByteArray &buffer = m_buffers[socket];
    buffer += socket->readAll();
    if (buffer.size() > 64 * 1024) { // garbage guard
        buffer.clear();
        return;
    }

    int newline = -1;
    while ((newline = buffer.indexOf('\n')) >= 0) {
        const QString line =
            QString::fromUtf8(buffer.left(newline)).trimmed();
        buffer.remove(0, newline + 1);
        if (line.isEmpty())
            continue;

        const int space = line.indexOf(QLatin1Char(' '));
        const QString command =
            (space < 0 ? line : line.left(space)).toLower();
        const QString argument =
            space < 0 ? QString() : line.mid(space + 1).trimmed();

        m_lastClient = socket;
        emit commandReceived(command, argument);
    }
}

void RemoteControl::reply(const QString &line)
{
    if (m_lastClient && m_lastClient->state() == QTcpSocket::ConnectedState)
        m_lastClient->write(line.toUtf8() + '\n');
}
