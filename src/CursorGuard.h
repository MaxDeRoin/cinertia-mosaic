#pragma once

#include <QObject>
#include <QtQml/qqmlregistration.h>

class QTimer;

// Hides the mouse cursor over the app's windows after a few seconds of
// inactivity so it never sits on top of video. QML calls poke() on every
// mouse movement; the cursor reappears instantly on the next move.
// Controlled by the "Hide mouse when idle" setting.
class CursorGuard : public QObject
{
    Q_OBJECT
    QML_ELEMENT
    Q_PROPERTY(bool enabled READ enabled WRITE setEnabled NOTIFY enabledChanged)

public:
    explicit CursorGuard(QObject *parent = nullptr);
    ~CursorGuard() override;

    bool enabled() const { return m_enabled; }
    void setEnabled(bool enabled);

    Q_INVOKABLE void poke();

signals:
    void enabledChanged();

private:
    void hideCursor();
    void showCursor();

    bool m_enabled = false;
    bool m_hidden = false;
    QTimer *m_timer = nullptr;
};
