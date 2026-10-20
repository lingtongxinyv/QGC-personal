#pragma once

#include <QtCore/QByteArray>
#include <QtCore/QObject>
#include <QtCore/QString>
#include <QtCore/QVariantMap>

class QNetworkAccessManager;
class QNetworkReply;
class QTimer;

/**
 * AssistantClient
 *
 * Read-only HTTP/SSE client for the local DSH `px4-panel` plugin
 * (see coord/design/px4-chat-http.md). Exposed to QML as the context
 * property `px4Assistant` from CustomPlugin::createQmlApplicationEngine.
 *
 * Endpoints:
 *   GET  /px4-agent/health           -> liveness + preset probe (no token)
 *   POST /px4-agent/chat             -> one turn, text/event-stream (token)
 *
 * No flight-controller write commands. Token is read from disk and never logged.
 */
class AssistantClient : public QObject
{
    Q_OBJECT
    Q_PROPERTY(QString baseUrl     READ baseUrl     CONSTANT)
    Q_PROPERTY(QString token       READ token       NOTIFY tokenChanged)
    Q_PROPERTY(bool    tokenFound  READ tokenFound  NOTIFY tokenChanged)
    Q_PROPERTY(QString healthState READ healthState NOTIFY healthChanged)  // unknown|ok|fail
    Q_PROPERTY(QString healthDetail READ healthDetail NOTIFY healthChanged)
    Q_PROPERTY(bool    busy        READ busy        NOTIFY busyChanged)

public:
    explicit AssistantClient(QObject *parent = nullptr);

    QString baseUrl() const { return _baseUrl; }
    QString token() const { return _token; }
    bool tokenFound() const { return !_token.isEmpty(); }
    QString healthState() const { return _healthState; }
    QString healthDetail() const { return _healthDetail; }
    bool busy() const { return _busy; }

    /// Probe GET /px4-agent/health. Safe to call repeatedly.
    Q_INVOKABLE void probeHealth();
    /// Re-read the panel-token from disk (after a DSH restart / rotation).
    Q_INVOKABLE void reloadToken();
    /// Send one turn. `text` is the user prompt, `context` optional QGC-field hint.
    Q_INVOKABLE void sendChat(const QString &text, const QVariantMap &context = QVariantMap());
    /// Abort the in-flight turn (closes the SSE stream).
    Q_INVOKABLE void cancelChat();

signals:
    void tokenChanged();
    void healthChanged();
    void busyChanged();

    void chatMeta(const QString &sessionId, const QString &preset, bool newSession);
    void chatTokenDelta(const QString &text);
    void chatThinkingDelta(const QString &text);
    void chatToolEvent(const QVariantMap &data);
    void chatNotice(const QString &level, const QString &text);
    void chatDone(const QString &outcome);
    void chatError(const QString &code, const QString &message);

private:
    void _loadToken();
    void _setHealth(const QString &state, const QString &detail);
    void _setBusy(bool busy);
    void _processSse();
    void _parseSseBuffer();
    void _dispatchEvent(const QString &eventName, const QByteArray &data);

    QNetworkAccessManager *_nam = nullptr;
    QTimer                *_healthTimer = nullptr;
    QNetworkReply         *_healthReply = nullptr;
    QNetworkReply         *_chatReply = nullptr;

    QString    _baseUrl;
    QString    _token;
    QString    _healthState = QStringLiteral("unknown");
    QString    _healthDetail;
    QString    _sessionId;

    QByteArray _sseBuffer;
    QByteArray _pendingEvent;
    QByteArray _pendingData;
    int        _eventCount = 0;
    bool       _busy = false;
};
