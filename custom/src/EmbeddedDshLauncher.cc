#include "EmbeddedDshLauncher.h"

#include "QGCLoggingCategory.h"

#include <QtCore/QCoreApplication>
#include <QtCore/QDateTime>
#include <QtCore/QDir>
#include <QtCore/QDirIterator>
#include <QtCore/QFile>
#include <QtCore/QFileInfo>
#include <QtCore/QJsonDocument>
#include <QtCore/QJsonObject>
#include <QtCore/QProcess>
#include <QtCore/QProcessEnvironment>
#include <QtCore/QSettings>
#include <QtCore/QStandardPaths>
#include <QtCore/QUrl>
#include <QtNetwork/QNetworkAccessManager>
#include <QtNetwork/QNetworkReply>
#include <QtNetwork/QNetworkRequest>
#include <QtNetwork/QHostAddress>
#include <QtNetwork/QTcpServer>

#ifdef Q_OS_WIN
#include <windows.h>
#endif

QGC_LOGGING_CATEGORY(EmbeddedDshLog, "Custom.EmbeddedDsh")

namespace {

constexpr int kHealthIntervalMs = 1000;
constexpr int kHealthMaxAttempts = 30;      // 30 s readiness budget
constexpr int kMaxRestarts = 3;
constexpr int kStableRunMs = 60000;

QString markerVersion(const QString &homeDir)
{
    QFile file(QDir(homeDir).filePath(QStringLiteral("VERSION")));
    if (!file.open(QIODevice::ReadOnly)) {
        return QString();
    }
    return QString::fromUtf8(file.readAll()).trimmed();
}

void removeTree(const QString &path)
{
    QDir dir(path);
    if (dir.exists()) {
        dir.removeRecursively();
    }
}

bool copyTree(const QString &source, const QString &target, QString &error)
{
    QDir src(source);
    if (!src.exists()) {
        error = QStringLiteral("template missing: %1").arg(source);
        return false;
    }
    if (!QDir().mkpath(target)) {
        error = QStringLiteral("cannot create %1").arg(target);
        return false;
    }
    QDirIterator it(source, QDir::Files | QDir::Hidden, QDirIterator::Subdirectories);
    while (it.hasNext()) {
        const QString from = it.next();
        const QString relative = src.relativeFilePath(from);
        const QString to = QDir(target).filePath(relative);
        if (!QDir().mkpath(QFileInfo(to).absolutePath())) {
            error = QStringLiteral("cannot create %1").arg(QFileInfo(to).absolutePath());
            return false;
        }
        if (!QFile::copy(from, to)) {
            error = QStringLiteral("cannot copy %1").arg(relative);
            return false;
        }
    }
    return true;
}

} // namespace

/*===========================================================================*/

EmbeddedDshLauncher::EmbeddedDshLauncher(QObject *parent)
    : QObject(parent)
    , _process(new QProcess(this))
    , _healthTimer(new QTimer(this))
    , _nam(new QNetworkAccessManager(this))
{
    const QString externalBase = qEnvironmentVariable("PX4_AGENT_BASE_URL").trimmed();
    const bool disabledByEnv = qEnvironmentVariable("PX4_EMBEDDED_DSH") == QLatin1String("0");
    _enabled = externalBase.isEmpty() && !disabledByEnv;

    // DeepSeek API key (Q-D1 option a). Stored per-user in QSettings and injected
    // into the child environment. If empty, the child falls back to whatever
    // DEEPSEEK_API_KEY exists in the inherited (system) environment.
    _apiKey = QSettings().value(QStringLiteral("EmbeddedDsh/ApiKey")).toString().trimmed();

    if (!_enabled) {
        _setState(QStringLiteral("disabled"),
                  externalBase.isEmpty() ? QStringLiteral("disabled by PX4_EMBEDDED_DSH")
                                         : QStringLiteral("external DSH base url in use"));
        return;
    }

    _resolvePaths();
    if (!QFileInfo::exists(_exePath)) {
        _enabled = false;
        _setState(QStringLiteral("disabled"),
                  QStringLiteral("embedded runtime not installed: %1").arg(_exePath));
        return;
    }

    _healthTimer->setInterval(kHealthIntervalMs);
    (void) connect(_healthTimer, &QTimer::timeout, this, &EmbeddedDshLauncher::_pollHealth);

    (void) connect(_process, &QProcess::readyReadStandardOutput, this, &EmbeddedDshLauncher::_readProcessOutput);
    (void) connect(_process, &QProcess::readyReadStandardError, this, &EmbeddedDshLauncher::_readProcessOutput);
    (void) connect(_process, &QProcess::errorOccurred, this, [this](QProcess::ProcessError error) {
        if (error == QProcess::FailedToStart) {
            _setState(QStringLiteral("failed"),
                      QStringLiteral("embedded DSH failed to start: %1").arg(_process->errorString()));
        }
    });
    (void) connect(_process, QOverload<int, QProcess::ExitStatus>::of(&QProcess::finished),
                   this, &EmbeddedDshLauncher::_onProcessFinished);

    if (QCoreApplication *app = QCoreApplication::instance()) {
        (void) connect(app, &QCoreApplication::aboutToQuit, this, &EmbeddedDshLauncher::stop);
    }

    qCDebug(EmbeddedDshLog) << "exe:" << _exePath << "template:" << _homeTemplate << "data:" << _dataHome;
}

EmbeddedDshLauncher::~EmbeddedDshLauncher()
{
    stop();
#ifdef Q_OS_WIN
    if (_jobHandle) {
        CloseHandle(static_cast<HANDLE>(_jobHandle));
        _jobHandle = nullptr;
    }
#endif
}

/*===========================================================================*/

void EmbeddedDshLauncher::_resolvePaths()
{
    const QString overrideExe = qEnvironmentVariable("PX4_EMBEDDED_DSH_EXE").trimmed();
    const QString appDir = QCoreApplication::applicationDirPath();

    _exePath = overrideExe.isEmpty()
        ? QDir(appDir).filePath(QStringLiteral("dsh/dsh-px4.exe"))
        : overrideExe;
    _homeTemplate = QDir(appDir).filePath(QStringLiteral("dsh/home"));

    QString dataRoot = QStandardPaths::writableLocation(QStandardPaths::AppLocalDataLocation);
    if (dataRoot.isEmpty()) {
        dataRoot = QDir(appDir).filePath(QStringLiteral("dsh-data"));
    }
    _dataHome = QDir(dataRoot).filePath(QStringLiteral("dsh-home"));
    _tokenFile = QDir(_dataHome).filePath(QStringLiteral("px4-agent/panel-token"));
}

bool EmbeddedDshLauncher::_prepareHome(QString &error)
{
    if (!QDir().mkpath(_dataHome)) {
        error = QStringLiteral("cannot create %1").arg(_dataHome);
        return false;
    }

    const QString wanted = markerVersion(_homeTemplate);
    const QString current = markerVersion(_dataHome);
    if (wanted.isEmpty() || current != wanted) {
        // Refresh the profile template on first run and after every QGC update.
        removeTree(QDir(_dataHome).filePath(QStringLiteral("profiles")));
        if (!copyTree(_homeTemplate, _dataHome, error)) {
            return false;
        }
        qCDebug(EmbeddedDshLog) << "home template deployed:" << wanted;
    }

    QDir().mkpath(QDir(_dataHome).filePath(QStringLiteral("px4-agent")));
    return true;
}

quint16 EmbeddedDshLauncher::_pickFreePort()
{
    QTcpServer probe;
    if (probe.listen(QHostAddress::LocalHost, 0)) {
        const quint16 port = probe.serverPort();
        probe.close();
        return port;
    }
    return 0;
}

void EmbeddedDshLauncher::_setEndpoint(quint16 port)
{
    const QString url = QStringLiteral("http://127.0.0.1:%1").arg(port);
    if (_baseUrl != url) {
        _baseUrl = url;
        emit endpointChanged();
    }
}

void EmbeddedDshLauncher::start()
{
    if (!_enabled) {
        return;
    }
    if (_state == QLatin1String("starting") || _state == QLatin1String("ready")) {
        return;
    }
    if (_process->state() != QProcess::NotRunning) {
        return;
    }

    _stopping = false;
    QString error;
    if (!_prepareHome(error)) {
        _setState(QStringLiteral("failed"), error);
        return;
    }

    _port = _pickFreePort();
    if (_port == 0) {
        _setState(QStringLiteral("failed"), QStringLiteral("no free loopback port"));
        return;
    }
    _setEndpoint(_port);
    _startProcess();
}

void EmbeddedDshLauncher::retry()
{
    if (!_enabled) {
        return;
    }
    if (_process->state() != QProcess::NotRunning) {
        stop();
    }
    _restarts = 0;
    _setState(QStringLiteral("stopped"), QStringLiteral("retry requested"));
    start();
}

void EmbeddedDshLauncher::setApiKey(const QString &key)
{
    const QString trimmed = key.trimmed();
    if (trimmed == _apiKey) {
        return;
    }

    _apiKey = trimmed;
    QSettings settings;
    if (_apiKey.isEmpty()) {
        settings.remove(QStringLiteral("EmbeddedDsh/ApiKey"));
    } else {
        settings.setValue(QStringLiteral("EmbeddedDsh/ApiKey"), _apiKey);
    }
    emit apiKeySetChanged();
    qCDebug(EmbeddedDshLog) << "api key updated; stored:" << !_apiKey.isEmpty();

    // Restart so the new credential reaches the child's environment.
    if (_enabled && _process->state() != QProcess::NotRunning) {
        stop();
        _restarts = 0;
        start();
    }
}

void EmbeddedDshLauncher::_startProcess()
{
    if (!_enabled || _stopping) {
        return;
    }

    QProcessEnvironment env = QProcessEnvironment::systemEnvironment();
    env.insert(QStringLiteral("DSH_HOME"), _dataHome);
    env.insert(QStringLiteral("DSH_TELEMETRY_DISABLED"), QStringLiteral("1"));
    if (!_apiKey.isEmpty()) {
        env.insert(QStringLiteral("DEEPSEEK_API_KEY"), _apiKey);
    }
    _process->setProcessEnvironment(env);
    _process->setWorkingDirectory(_dataHome);

    const QStringList args{
        QStringLiteral("--profile"), QStringLiteral("px4-embedded"),
        QStringLiteral("--host"), QStringLiteral("127.0.0.1"),
        QStringLiteral("--port"), QString::number(_port),
        QStringLiteral("--no-open"),
    };

    _healthAttempts = 0;
    _setState(QStringLiteral("starting"), QStringLiteral("%1 (port %2)").arg(QFileInfo(_exePath).fileName()).arg(_port));
    _process->start(_exePath, args);
    if (!_process->waitForStarted(10000)) {
        _setState(QStringLiteral("failed"),
                  QStringLiteral("cannot start embedded DSH: %1").arg(_process->errorString()));
        _scheduleRestart(QStringLiteral("start timeout"));
        return;
    }

    _childStartedMs = QDateTime::currentMSecsSinceEpoch();
    _attachJobObject();
    _healthTimer->start();
}

void EmbeddedDshLauncher::_attachJobObject()
{
#ifdef Q_OS_WIN
    if (!_jobHandle) {
        _jobHandle = CreateJobObjectW(nullptr, nullptr);
        if (!_jobHandle) {
            return;
        }
        JOBOBJECT_EXTENDED_LIMIT_INFORMATION info{};
        info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        (void) SetInformationJobObject(static_cast<HANDLE>(_jobHandle),
                                       JobObjectExtendedLimitInformation, &info, sizeof(info));
    }
    HANDLE child = OpenProcess(PROCESS_SET_QUOTA | PROCESS_TERMINATE, FALSE,
                               static_cast<DWORD>(_process->processId()));
    if (child) {
        if (!AssignProcessToJobObject(static_cast<HANDLE>(_jobHandle), child)) {
            qCWarning(EmbeddedDshLog) << "AssignProcessToJobObject failed:" << GetLastError();
        }
        CloseHandle(child);
    }
#endif
}

void EmbeddedDshLauncher::_pollHealth()
{
    if (_process->state() == QProcess::NotRunning || _healthReply) {
        return;
    }
    if (++_healthAttempts > kHealthMaxAttempts) {
        _healthTimer->stop();
        _setState(QStringLiteral("failed"), QStringLiteral("no /px4-agent/health within 30 s"));
        return;
    }

    QNetworkRequest request{QUrl(_baseUrl + QStringLiteral("/px4-agent/health"))};
    request.setTransferTimeout(2000);
    _healthReply = _nam->get(request);
    (void) connect(_healthReply, &QNetworkReply::finished, this, [this]() {
        QNetworkReply *reply = _healthReply;
        _healthReply = nullptr;
        if (!reply) {
            return;
        }
        const QByteArray body = reply->readAll();
        const bool httpOk = reply->error() == QNetworkReply::NoError
                            && reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt() == 200;
        reply->deleteLater();

        bool ok = false;
        if (httpOk) {
            const QJsonObject obj = QJsonDocument::fromJson(body).object();
            ok = obj.value(QStringLiteral("ok")).toBool(false);
        }
        if (!ok) {
            return;   // next timer tick retries
        }
        _healthTimer->stop();
        _setState(QStringLiteral("ready"), QStringLiteral("port %1").arg(_port));
        emit ready();
    });
}

void EmbeddedDshLauncher::_onProcessFinished(int exitCode, int status)
{
    Q_UNUSED(status);
    _healthTimer->stop();

    if (_healthReply) {
        _healthReply->abort();
        _healthReply->deleteLater();
        _healthReply = nullptr;
    }

    if (_stopping) {
        _setState(QStringLiteral("stopped"));
        return;
    }

    const bool wasReady = _state == QLatin1String("ready");
    const qint64 ranMs = _childStartedMs > 0
        ? QDateTime::currentMSecsSinceEpoch() - _childStartedMs
        : 0;
    if (wasReady && ranMs >= kStableRunMs) {
        _restarts = 0;
    }

    _setState(QStringLiteral("failed"), QStringLiteral("embedded DSH exited (code %1)").arg(exitCode));
    _scheduleRestart(QStringLiteral("child exit"));
}

void EmbeddedDshLauncher::_scheduleRestart(const QString &why)
{
    if (_stopping || !_enabled) {
        return;
    }
    if (_restarts >= kMaxRestarts) {
        _setState(QStringLiteral("failed"),
                  QStringLiteral("%1; restart limit reached (%2)").arg(why).arg(kMaxRestarts));
        return;
    }

    ++_restarts;
    const int delayMs = 1000 << (_restarts - 1);   // 1 s, 2 s, 4 s
    qCDebug(EmbeddedDshLog) << "restart" << _restarts << "in" << delayMs << "ms:" << why;
    _setState(QStringLiteral("starting"), QStringLiteral("restart %1/%2").arg(_restarts).arg(kMaxRestarts));
    QTimer::singleShot(delayMs, this, [this]() {
        if (!_stopping && _process->state() == QProcess::NotRunning) {
            _startProcess();
        }
    });
}

void EmbeddedDshLauncher::_readProcessOutput()
{
    const QByteArray out = _process->readAllStandardOutput();
    if (!out.isEmpty()) {
        for (const QByteArray &line : out.split('\n')) {
            const QByteArray trimmed = line.trimmed();
            if (!trimmed.isEmpty()) {
                qCDebug(EmbeddedDshLog) << "stdout:" << trimmed;
            }
        }
    }
    const QByteArray err = _process->readAllStandardError();
    if (!err.isEmpty()) {
        for (const QByteArray &line : err.split('\n')) {
            const QByteArray trimmed = line.trimmed();
            if (!trimmed.isEmpty()) {
                qCDebug(EmbeddedDshLog) << "stderr:" << trimmed;
            }
        }
    }
}

void EmbeddedDshLauncher::stop()
{
    if (!_enabled) {
        return;
    }
    _stopping = true;
    _healthTimer->stop();

    if (_healthReply) {
        _healthReply->abort();
        _healthReply->deleteLater();
        _healthReply = nullptr;
    }

    if (_process->state() != QProcess::NotRunning) {
        _process->terminate();
        if (!_process->waitForFinished(3000)) {
            _process->kill();
            (void) _process->waitForFinished(2000);
        }
    }
    _setState(QStringLiteral("stopped"));
}

void EmbeddedDshLauncher::_setState(const QString &state, const QString &detail)
{
    const bool detailChanged = _detail != detail;
    _state = state;
    _detail = detail;
    emit stateChanged();
    if (detailChanged) {
        qCDebug(EmbeddedDshLog) << "state:" << state << detail;
    }
}
