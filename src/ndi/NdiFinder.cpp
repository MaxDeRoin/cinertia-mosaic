#include "NdiFinder.h"

#include <Processing.NDI.Lib.h>

#include "../DiagLog.h"

NdiFinder::NdiFinder(QObject *parent)
    : QObject(parent)
{
    NDIlib_find_create_t desc;
    desc.show_local_sources = true;
    desc.p_groups = nullptr;
    desc.p_extra_ips = nullptr;
    m_finder = NDIlib_find_create_v2(&desc);
    diagLog(m_finder ? QStringLiteral("FINDER created (show_local_sources=true)")
                     : QStringLiteral("FINDER create FAILED"));

    connect(&m_timer, &QTimer::timeout, this, &NdiFinder::poll);
    m_timer.start(1000);
    poll();
}

NdiFinder::~NdiFinder()
{
    if (m_finder)
        NDIlib_find_destroy(static_cast<NDIlib_find_instance_t>(m_finder));
}

void NdiFinder::poll()
{
    if (!m_finder)
        return;

    uint32_t count = 0;
    const NDIlib_source_t *found = NDIlib_find_get_current_sources(
        static_cast<NDIlib_find_instance_t>(m_finder), &count);

    QStringList names;
    names.reserve(count);
    for (uint32_t i = 0; i < count; ++i)
        names.append(QString::fromUtf8(found[i].p_ndi_name));
    names.sort(Qt::CaseInsensitive);

    if (names != m_sources) {
        // Log the full source list (with URL/IP:port) on every change — this
        // is where a network source appearing or, on the fault, vanishing
        // shows up.
        diagLog(QStringLiteral("FINDER now sees %1 source(s):").arg(count));
        for (uint32_t i = 0; i < count; ++i)
            diagLog(QStringLiteral("    - %1  @ %2")
                        .arg(QString::fromUtf8(found[i].p_ndi_name),
                             QString::fromUtf8(found[i].p_url_address
                                                   ? found[i].p_url_address : "?")));
        m_sources = names;
        emit sourcesChanged();
    } else if (++m_pollCount % 10 == 0) {
        // Heartbeat every ~10s so the log has a timeline even when steady.
        diagLog(QStringLiteral("FINDER heartbeat: %1 source(s)").arg(count));
    }
}
