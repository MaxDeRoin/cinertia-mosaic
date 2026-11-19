#include "LocalNetworkAccess.h"

#include <QFile>
#include <QHostAddress>
#include <QNetworkInterface>
#include <QOperatingSystemVersion>
#include <QProcess>
#include <QRegularExpression>
#include <QSettings>

#ifdef Q_OS_MACOS
#include <SystemConfiguration/SystemConfiguration.h>
#include <sys/sysctl.h>
#endif

namespace {
const QString kDomain = QStringLiteral("com.apple.network.local-network");
const QString kKeyEthernet = QStringLiteral("localNetwork/addedEthernet");
const QString kKeyWifi = QStringLiteral("localNetwork/addedWifi");
const QString kKeyHadEthernet = QStringLiteral("localNetwork/hadEthernet");
const QString kKeyHadWifi = QStringLiteral("localNetwork/hadWifi");
const QString kKeyBoot = QStringLiteral("localNetwork/changedBoot");
const QString kEthernetKey = QStringLiteral("AllowedEthernetLocalNetworkAddresses");
const QString kWifiKey = QStringLiteral("AllowedWiFiLocalNetworkAddresses");

// Identifies this run of the Mac (changes only when it restarts; unlike the
// boot time, it isn't shifted by clock adjustments). Empty where unknown.
QString bootSession()
{
#ifdef Q_OS_MACOS
    char buf[64] = {};
    size_t size = sizeof(buf);
    if (sysctlbyname("kern.bootsessionuuid", buf, &size, nullptr, 0) == 0)
        return QString::fromLatin1(buf);
#endif
    return {};
}

#ifdef Q_OS_MACOS
// Whether a BSD interface (en0, en1, …) is Wi-Fi, per macOS's own list.
bool isWifi(const QString &bsdName)
{
    bool wifi = false;
    CFArrayRef all = SCNetworkInterfaceCopyAll();
    if (!all)
        return false;
    for (CFIndex i = 0; i < CFArrayGetCount(all); ++i) {
        auto iface = static_cast<SCNetworkInterfaceRef>(
            const_cast<void *>(CFArrayGetValueAtIndex(all, i)));
        CFStringRef name = SCNetworkInterfaceGetBSDName(iface);
        if (name && QString::fromCFString(name) == bsdName) {
            CFStringRef type = SCNetworkInterfaceGetInterfaceType(iface);
            wifi = type && CFEqual(type, kSCNetworkInterfaceTypeIEEE80211);
            break;
        }
    }
    CFRelease(all);
    return wifi;
}
#endif

// Only plain IPv4 CIDR text ever reaches the script.
bool validCidr(const QString &s)
{
    static const QRegularExpression re(
        QStringLiteral("^\\d{1,3}\\.\\d{1,3}\\.\\d{1,3}\\.\\d{1,3}/\\d{1,2}$"));
    return re.match(s).hasMatch();
}

QStringList validOnly(const QStringList &list)
{
    QStringList out;
    for (const QString &c : list)
        if (validCidr(c))
            out << c;
    return out;
}

// An AppleScript string literal.
QString appleScriptString(QString s)
{
    s.replace(QLatin1Char('\\'), QStringLiteral("\\\\"));
    s.replace(QLatin1Char('"'), QStringLiteral("\\\""));
    return QLatin1Char('"') + s + QLatin1Char('"');
}

void addUnique(QStringList &list, const QString &value)
{
    if (!list.contains(value))
        list << value;
}
} // namespace

LocalNetworkAccess::LocalNetworkAccess(QObject *parent)
    : QObject(parent)
{
    QSettings settings;
    m_addedEthernet = validOnly(settings.value(kKeyEthernet).toStringList());
    m_addedWifi = validOnly(settings.value(kKeyWifi).toStringList());
    m_hadEthernet = validOnly(settings.value(kKeyHadEthernet).toStringList());
    m_hadWifi = validOnly(settings.value(kKeyHadWifi).toStringList());
    m_changedBoot = settings.value(kKeyBoot).toString();
    detect();
}

bool LocalNetworkAccess::supported() const
{
#ifdef Q_OS_MACOS
    return QOperatingSystemVersion::current()
        >= QOperatingSystemVersion(QOperatingSystemVersion::MacOS, 15, 5);
#else
    return false;
#endif
}

bool LocalNetworkAccess::enabled() const
{
    return !m_addedEthernet.isEmpty() || !m_addedWifi.isEmpty()
        || !m_hadEthernet.isEmpty() || !m_hadWifi.isEmpty();
}

bool LocalNetworkAccess::restartPending() const
{
    // Changed during this run of the Mac: not active until it restarts.
    return !m_changedBoot.isEmpty() && m_changedBoot == bootSession();
}

QStringList LocalNetworkAccess::networks() const
{
    // Shown in Settings: what is allowed now when on, what would be when off.
    QStringList eth, wifi;
    if (enabled()) {
        eth = m_addedEthernet + m_hadEthernet;
        wifi = m_addedWifi + m_hadWifi;
    } else {
        eth = m_ethernet;
        wifi = m_wifi;
    }
    QStringList out;
    for (const QString &c : eth)
        addUnique(out, c + QStringLiteral(" (Ethernet)"));
    for (const QString &c : wifi)
        addUnique(out, c + QStringLiteral(" (Wi-Fi)"));
    return out;
}

QStringList LocalNetworkAccess::uncovered() const
{
    QStringList out;
    if (!enabled())
        return out;
    for (const QString &c : m_ethernet)
        if (!m_addedEthernet.contains(c) && !m_hadEthernet.contains(c))
            out << c + QStringLiteral(" (Ethernet)");
    for (const QString &c : m_wifi)
        if (!m_addedWifi.contains(c) && !m_hadWifi.contains(c))
            out << c + QStringLiteral(" (Wi-Fi)");
    return out;
}

void LocalNetworkAccess::refresh()
{
    if (m_busy)
        return; // the running change uses the lists it was started with
    m_lastError.clear();
    detect();
    emit changed();
}

void LocalNetworkAccess::detect()
{
    m_ethernet.clear();
    m_wifi.clear();
    const auto ifaces = QNetworkInterface::allInterfaces();
    for (const QNetworkInterface &iface : ifaces) {
        const auto flags = iface.flags();
        // Real network ports only (en0, en1, …): up, running, not loopback,
        // not tunnels or the Mac's own virtual interfaces.
        if (!(flags & QNetworkInterface::IsUp) || !(flags & QNetworkInterface::IsRunning)
                || (flags & QNetworkInterface::IsLoopBack)
                || (flags & QNetworkInterface::IsPointToPoint)
                || !iface.name().startsWith(QLatin1String("en")))
            continue;
        for (const QNetworkAddressEntry &entry : iface.addressEntries()) {
            const QHostAddress ip = entry.ip();
            if (ip.protocol() != QAbstractSocket::IPv4Protocol)
                continue;
            const int prefix = entry.prefixLength();
            if (prefix < 8 || prefix > 30)
                continue;
            const quint32 addr = ip.toIPv4Address();
            if ((addr >> 16) == 0xA9FE) // 169.254/16 self-assigned
                continue;
            const quint32 mask = 0xFFFFFFFFu << (32 - prefix);
            const QString cidr = QHostAddress(addr & mask).toString()
                + QLatin1Char('/') + QString::number(prefix);
            if (!validCidr(cidr))
                continue;
#ifdef Q_OS_MACOS
            addUnique(isWifi(iface.name()) ? m_wifi : m_ethernet, cidr);
#else
            addUnique(m_ethernet, cidr);
#endif
        }
    }
}

void LocalNetworkAccess::setEnabled(bool on)
{
    if (!supported() || m_busy || on == enabled())
        return;
    m_lastError.clear();
    if (on) {
        // Allow the networks connected now.
        detect();
        if (m_ethernet.isEmpty() && m_wifi.isEmpty()) {
            fail(tr("No wired or Wi-Fi network with an address found — connect to the NDI network first."));
            return;
        }
        run(true, m_ethernet, m_wifi);
        return;
    }
    // Off: remove exactly what Mosaic added. Ranges that were allowed before
    // Mosaic are left in place; Mosaic just stops counting them.
    if (m_addedEthernet.isEmpty() && m_addedWifi.isEmpty()) {
        m_hadEthernet.clear();
        m_hadWifi.clear();
        save();
        emit changed();
        return;
    }
    run(false, m_addedEthernet, m_addedWifi);
}

void LocalNetworkAccess::addCurrent()
{
    if (!supported() || m_busy || !enabled())
        return;
    m_lastError.clear();
    detect();
    QStringList eth, wifi;
    for (const QString &c : m_ethernet)
        if (!m_addedEthernet.contains(c) && !m_hadEthernet.contains(c))
            eth << c;
    for (const QString &c : m_wifi)
        if (!m_addedWifi.contains(c) && !m_hadWifi.contains(c))
            wifi << c;
    if (eth.isEmpty() && wifi.isEmpty()) {
        emit changed();
        return;
    }
    run(true, eth, wifi);
}

void LocalNetworkAccess::run(bool add, const QStringList &eth, const QStringList &wifi)
{
    QFile file(QStringLiteral(":/qt/qml/Mosaic/resources/localnetwork.sh"));
    if (!file.open(QIODevice::ReadOnly)) {
        fail(tr("Internal error: the setting script is missing."));
        return;
    }
    const QString script = QStringLiteral("D=%1\nMODE=%2\nETH=\"%3\"\nWIFI=\"%4\"\n")
                               .arg(kDomain, add ? QStringLiteral("1") : QStringLiteral("0"),
                                    validOnly(eth).join(QLatin1Char(' ')),
                                    validOnly(wifi).join(QLatin1Char(' ')))
        + QString::fromUtf8(file.readAll());

    // macOS's own administrator prompt runs it as root.
    const QString prompt = add
        ? tr("Mosaic wants to always allow its NDI network (macOS Local Network setting).")
        : tr("Mosaic wants to remove its NDI network from the macOS Local Network setting.");
    const QString apple =
        QStringLiteral("do shell script %1 with prompt %2 with administrator privileges")
            .arg(appleScriptString(script), appleScriptString(prompt));

    auto *process = new QProcess(this);
    // The lists are captured: what is recorded is exactly what was sent,
    // even if the networks change while the password prompt is open.
    connect(process, &QProcess::finished, this,
            [this, process, add, eth, wifi](int code, QProcess::ExitStatus) {
                finished(process, code, add, eth, wifi);
            });
    connect(process, &QProcess::errorOccurred, this, [this, process](QProcess::ProcessError e) {
        if (e != QProcess::FailedToStart)
            return; // other errors still end in finished()
        process->deleteLater();
        m_busy = false;
        fail(tr("Couldn't ask macOS for the administrator password."));
    });
    m_busy = true;
    emit changed();
    process->start(QStringLiteral("/usr/bin/osascript"), { QStringLiteral("-e"), apple });
}

void LocalNetworkAccess::finished(QProcess *process, int exitCode, bool add,
                                  const QStringList &eth, const QStringList &wifi)
{
    const QString out = QString::fromUtf8(process->readAllStandardOutput());
    const QString err = QString::fromUtf8(process->readAllStandardError()).trimmed();
    process->deleteLater();
    m_busy = false;

    if (exitCode != 0) {
        if (err.contains(QLatin1String("(-128)"))) { // cancelled at the prompt
            emit changed();
            return;
        }
        // Plain words for the operator; the error number at the end of
        // osascript's message, e.g. "... (1)", is the useful part.
        static const QRegularExpression code(QStringLiteral("\\((-?\\d+)\\)\\s*$"));
        const auto m = code.match(err);
        fail(m.hasMatch() ? tr("macOS didn't accept the change (error %1).").arg(m.captured(1))
                          : tr("macOS didn't accept the change."));
        return;
    }

    bool systemChanged = !add; // removing always changed the setting
    if (add) {
        // Record only what the script reports: ADDED (Mosaic's, removed
        // again when off) or HAD (already allowed, never removed).
        const QStringList lines = out.split(QRegularExpression(QStringLiteral("[\r\n]+")),
                                            Qt::SkipEmptyParts);
        for (const QString &line : lines) {
            const QStringList f = line.trimmed().split(QLatin1Char(' '));
            if (f.size() != 3 || !validCidr(f[2]))
                continue;
            const bool wifiKey = f[1] == kWifiKey;
            if (!wifiKey && f[1] != kEthernetKey)
                continue;
            if (f[0] == QLatin1String("ADDED")) {
                addUnique(wifiKey ? m_addedWifi : m_addedEthernet, f[2]);
                systemChanged = true;
            }
            else if (f[0] == QLatin1String("HAD"))
                addUnique(wifiKey ? m_hadWifi : m_hadEthernet, f[2]);
        }
    } else {
        for (const QString &c : eth)
            m_addedEthernet.removeAll(c);
        for (const QString &c : wifi)
            m_addedWifi.removeAll(c);
        m_hadEthernet.clear();
        m_hadWifi.clear();
    }
    // Only an actual change to the setting needs a restart.
    if (systemChanged)
        m_changedBoot = bootSession();
    save();
    emit changed();
}

void LocalNetworkAccess::fail(const QString &message)
{
    m_lastError = message;
    emit changed();
}

void LocalNetworkAccess::save()
{
    QSettings settings;
    settings.setValue(kKeyEthernet, m_addedEthernet);
    settings.setValue(kKeyWifi, m_addedWifi);
    settings.setValue(kKeyHadEthernet, m_hadEthernet);
    settings.setValue(kKeyHadWifi, m_hadWifi);
    settings.setValue(kKeyBoot, m_changedBoot);
}
