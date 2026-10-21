#pragma once

#include <QtCore/QObject>
#include <QtCore/QString>
#include <QtCore/QTimer>
#include <QtCore/QVariantMap>

class QNetworkAccessManager;
class QNetworkReply;
class QProcess;

/**
 * EmbeddedDshLauncher
 *
 * Owns the bundled DeepSeek Harness child process that ships beside QGC:
 *
 *   <app dir>/dsh/dsh-px4.exe     single-file Node SEA runtime
 *   <app dir>/dsh/home/           DSH_HOME template (px4-embedded profile)
 *
 * At first run the template is copied to the per-user data location, a free
 * loopback port is selected, and the child is started with
 * `--profile px4-embedded --host 127.0.0.1 --port <p> --no-open`. Readiness is
 * `GET /px4-agent/health` returning ok=true (30 s budget). The Windows Job
 * Object is configured with KILL_ON_JOB_CLOSE so the child cannot outlive QGC.
 *
 * External-DSH development mode stays available: when PX4_AGENT_BASE_URL is
 * set (or PX4_EMBEDDED_DSH=0) the launcher reports disabled and does nothing.
 *
 * Read-only boundary: this class never talks to the flight controller.
 */
class EmbeddedDshLauncher : public QObject
{
    Q_OBJECT
    Q_PROPERTY(QString state READ state NOTIFY stateChanged)      // disabled|stopped|starting|ready|failed
    Q_PROPERTY(QString detail READ detail NOTIFY stateChanged)
    Q_PROPERTY(QString baseUrl READ baseUrl NOTIFY endpointChanged)
    Q_PROPERTY(QString tokenFile READ tokenFile NOTIFY endpointChanged)
    Q_PROPERTY(bool enabled READ enabled CONSTANT)
    Q_PROPERTY(int restartCount READ restartCount NOTIFY stateChanged)
    Q_PROPERTY(bool apiKeySet READ apiKeySet NOTIFY apiKeySetChanged)

public:
    explicit EmbeddedDshLauncher(QObject *parent = nullptr);
    ~EmbeddedDshLauncher() override;

    bool enabled() const { return _enabled; }
    QString state() const { return _state; }
    QString detail() const { return _detail; }
    QString baseUrl() const { return _baseUrl; }
    QString tokenFile() const { return _tokenFile; }
    int restartCount() const { return _restarts; }

    /// Start the child if enabled. Safe to call more than once.
    Q_INVOKABLE void start();
    /// Restart after a failure (panel retry button).
    Q_INVOKABLE void retry();
    /// Terminate the child without scheduling a restart.
    void stop();

    /// Persist the DeepSeek API key used by the bundled DSH (Q-D1 option a).
    /// An empty key clears the stored value. The child is restarted so the new
    /// environment takes effect. Stored in QSettings (plaintext, per user).
    Q_INVOKABLE void setApiKey(const QString &key);
    bool apiKeySet() const { return !_apiKey.isEmpty(); }

signals:
    void stateChanged();
    void endpointChanged();
    /// Emitted once per successful readiness transition; consumers reload the token here.
    void ready();
    void apiKeySetChanged();

private:
    void _setState(const QString &state, const QString &detail = QString());
    void _resolvePaths();
    bool _prepareHome(QString &error);
    quint16 _pickFreePort();
    void _startProcess();
    void _pollHealth();
    void _setEndpoint(quint16 port);
    void _attachJobObject();
    void _onProcessFinished(int exitCode, int status);
    void _scheduleRestart(const QString &why);
    void _readProcessOutput();

    QProcess             *_process = nullptr;
    QTimer               *_healthTimer = nullptr;
    QNetworkAccessManager *_nam = nullptr;
    QNetworkReply         *_healthReply = nullptr;

    bool    _enabled = false;
    bool    _stopping = false;
    QString _state = QStringLiteral("stopped");
    QString _detail;
    QString _baseUrl;
    QString _tokenFile;
    QString _exePath;
    QString _homeTemplate;
    QString _dataHome;

    quint16 _port = 0;
    int     _healthAttempts = 0;
    int     _restarts = 0;
    qint64  _childStartedMs = 0;
    QString _apiKey;

    void *_jobHandle = nullptr;
};
