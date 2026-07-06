#include "PowerGuard.h"

#ifdef Q_OS_WIN
#include <windows.h>
#endif

PowerGuard::PowerGuard(QObject *parent)
    : QObject(parent)
{
}

PowerGuard::~PowerGuard()
{
    if (m_keepAwake) {
        m_keepAwake = false;
        apply();
    }
}

void PowerGuard::setKeepAwake(bool enabled)
{
    if (enabled == m_keepAwake)
        return;
    m_keepAwake = enabled;
    apply();
    emit keepAwakeChanged();
}

void PowerGuard::apply()
{
#ifdef Q_OS_WIN
    if (m_keepAwake) {
        SetThreadExecutionState(ES_CONTINUOUS | ES_SYSTEM_REQUIRED
                                | ES_DISPLAY_REQUIRED);
    } else {
        SetThreadExecutionState(ES_CONTINUOUS);
    }
#endif
}
