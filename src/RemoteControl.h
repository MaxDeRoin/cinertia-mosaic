#pragma once

#include <QHash>
#include <QObject>
#include <QPointer>
#include <QtQml/qqmlregistration.h>

class QTcpServer;
class QTcpSocket;

// Line-based TCP remote control for Bitfocus Companion / Stream Deck.
// Companion's "Generic TCP" module sends plain text commands, one per
// line, e.g.:  PROFILE Show A\n   LAYOUT 2x2\n   MODE fullscreen\n
// Parsing/validation of what the commands *do* lives in QML; this class
// only accepts connections, splits lines, and reports commands.
class RemoteControl : public QObject
{
    Q_OBJECT
    QML_ELEMENT
    Q_PROPERTY(bool enabled READ enabled WRITE setEnabled NOTIFY enabledChanged)
    Q_PROPERTY(int port READ port WRITE setPort NOTIFY portChanged)
    Q_PROPERTY(bool listening READ listening NOTIFY listeningChanged)

public:
    explicit RemoteControl(QObject *parent = nullptr);

    bool enabled() const { return m_enabled; }
    void setEnabled(bool enabled);
    int port() const { return m_port; }
    void setPort(int port);
    bool listening() const { return m_listening; }

    // Send a response line to the client that issued the last command.
    Q_INVOKABLE void reply(const QString &line);
    // Push a line to every connected client — used for EVENT messages so
    // controllers (Companion) can track state they didn't change.
    Q_INVOKABLE void broadcast(const QString &line);

signals:
    void enabledChanged();
    void portChanged();
    void listeningChanged();
    void commandReceived(const QString &command, const QString &argument);

private:
    void applyState();
    void onNewConnection();
    void onReadyRead(QTcpSocket *socket);

    QTcpServer *m_server = nullptr;
    QHash<QTcpSocket *, QByteArray> m_buffers;
    QPointer<QTcpSocket> m_lastClient;
    bool m_enabled = false;
    int m_port = 9955;
    bool m_listening = false;
};
