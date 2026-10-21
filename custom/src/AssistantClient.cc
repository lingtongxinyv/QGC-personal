#include "AssistantClient.h"

#include "QGCLoggingCategory.h"

#include <QtCore/QDir>
#include <QtCore/QFile>
#include <QtCore/QJsonDocument>
#include <QtCore/QJsonObject>
#include <QtCore/QProcessEnvironment>
#include <QtCore/QStandardPaths>
#include <QtCore/QTimer>
#include <QtCore/QUrl>
#include <QtNetwork/QNetworkAccessManager>
#include <QtNetwork/QNetworkReply>
#include <QtNetwork/QNetworkRequest>

QGC_LOGGING_CATEGORY(AssistantClientLog, "Custom.AssistantClient")

namespace {

constexpr int kHealthIntervalMs = 15000;

QString normalizedBaseUrl()
{
    QString url = qEnvironmentVariable("PX4_AGENT_BASE_URL");
    if (url.isEmpty()) {
        // Headless DSH web profile is pinned to 19389 (see coord/design/px4-chat-http.md).
        url = QStringLiteral("http://127.0.0.1:19389");
    }
    while (url.endsWith(QLatin1Char('/'))) {
        url.chop(1);
    }
    return url;
}

QStringList tokenFileCandidates(const QString &instanceOverride)
{
    QStringList candidates;

    // Endpoint-specific token (embedded launcher) always wins: it belongs to the
    // instance the panel actually talks to.
    if (!instanceOverride.isEmpty()) {
        candidates << instanceOverride;
    }

    // Explicit override next.
    const QString explicitFile = qEnvironmentVariable("PX4_AGENT_TOKEN_FILE");
    if (!explicitFile.isEmpty()) {
        candidates << explicitFile;
    }

    // Each DSH instance mints its own panel-token (randomBytes per DSH_HOME), so the
    // token must come from the instance the panel talks to. The default base url is the
    // headless instance on port 19389 whose DSH_HOME is dsh-px4-home (see
    // coord/design/px4-chat-http.md), so that path is probed BEFORE the inherited
    // DSH_HOME / %USERPROFILE%\.dsh ones -- a shell exporting the *desktop* DSH_HOME
    // (C:\Users\16650\.dsh) would otherwise feed the desktop token to 19389 and get a
    // 401 on every chat. Pointing the panel elsewhere (PX4_AGENT_BASE_URL)? Then also
    // set PX4_AGENT_TOKEN_FILE to that instance's token.
    candidates << QStringLiteral("D:/Apps/dsh-px4-home/px4-agent/panel-token");

    const QString dshHome = qEnvironmentVariable("DSH_HOME");
    if (!dshHome.isEmpty()) {
        candidates << QDir(dshHome).filePath(QStringLiteral("px4-agent/panel-token"));
    }

    const QString userProfile = qEnvironmentVariable("USERPROFILE");
    if (!userProfile.isEmpty()) {
        candidates << QDir(userProfile).filePath(QStringLiteral(".dsh/px4-agent/panel-token"));
    }

    return candidates;
}

} // namespace

/*===========================================================================*/

AssistantClient::AssistantClient(QObject *parent)
    : QObject(parent)
    , _nam(new QNetworkAccessManager(this))
    , _baseUrl(normalizedBaseUrl())
{
    qCDebug(AssistantClientLog) << "base url:" << _baseUrl;

    _loadToken();

    _healthTimer = new QTimer(this);
    _healthTimer->setInterval(kHealthIntervalMs);
    connect(_healthTimer, &QTimer::timeout, this, &AssistantClient::probeHealth);
    _healthTimer->start();

    probeHealth();
}

void AssistantClient::reloadToken()
{
    _loadToken();
    probeHealth();
}

void AssistantClient::setEndpoint(const QString &baseUrl, const QString &tokenFile)
{
    QString url = baseUrl.trimmed();
    while (url.endsWith(QLatin1Char('/'))) {
        url.chop(1);
    }
    if (url.isEmpty()) {
        url = _baseUrl;
    }

    bool changed = false;
    if (url != _baseUrl) {
        _baseUrl = url;
        changed = true;
    }
    if (tokenFile.trimmed() != _tokenFileOverride) {
        _tokenFileOverride = tokenFile.trimmed();
        changed = true;
    }
    if (!changed) {
        return;
    }

    qCDebug(AssistantClientLog) << "endpoint set to" << _baseUrl
                                << "token file:" << (_tokenFileOverride.isEmpty()
                                                     ? QStringLiteral("<defaults>")
                                                     : _tokenFileOverride);

    // In-flight requests belong to the previous instance: drop them.
    if (_chatReply) {
        _chatReply->abort();
    }
    if (_healthReply) {
        _healthReply->abort();
        _healthReply = nullptr;
    }
    _sessionId.clear();
    _setHealth(QStringLiteral("unknown"), QString());

    emit baseUrlChanged();

    _loadToken();
    probeHealth();
}

void AssistantClient::_loadToken()
{
    const QString oldToken = _token;
    _token.clear();

    for (const QString &path : tokenFileCandidates(_tokenFileOverride)) {
        QFile file(path);
        if (!file.exists() || !file.open(QIODevice::ReadOnly)) {
            continue;
        }
        const QString value = QString::fromUtf8(file.readAll()).trimmed();
        file.close();
        if (!value.isEmpty()) {
            _token = value;
            qCDebug(AssistantClientLog) << "panel-token loaded from" << path;
            break;
        }
    }

    if (_token.isEmpty()) {
        qCWarning(AssistantClientLog) << "panel-token not found; chat disabled";
    }

    if (_token != oldToken) {
        emit tokenChanged();
    }
}

void AssistantClient::_setHealth(const QString &state, const QString &detail)
{
    if (_healthState == state && _healthDetail == detail) {
        return;
    }
    _healthState = state;
    _healthDetail = detail;
    emit healthChanged();
}

void AssistantClient::_setBusy(bool busy)
{
    if (_busy == busy) {
        return;
    }
    _busy = busy;
    emit busyChanged();
}

void AssistantClient::probeHealth()
{
    if (_healthReply) {
        return;
    }

    QNetworkRequest request{QUrl(_baseUrl + QStringLiteral("/px4-agent/health"))};
    request.setAttribute(QNetworkRequest::RedirectPolicyAttribute, QNetworkRequest::NoLessSafeRedirectPolicy);
    request.setTransferTimeout(5000);   // 5s: if DSH is silently gone (blackhole), don't block for the default 30s. (review pass2 P2)

    _healthReply = _nam->get(request);
    connect(_healthReply, &QNetworkReply::finished, this, [this] {
        QNetworkReply *reply = _healthReply;
        _healthReply = nullptr;

        const int status = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
        const QNetworkReply::NetworkError error = reply->error();
        const QByteArray body = reply->readAll();
        reply->deleteLater();

        if (error != QNetworkReply::NoError || status != 200) {
            // 404 = the /px4-agent route is missing (older DSH build, or the px4-panel
            // bundle is not loaded yet) -- distinct from "no server at all".
            QString detail;
            if (status == 404) {
                detail = QStringLiteral("no /px4-agent route (older DSH build or panel not loaded)");
            } else if (status > 0) {
                detail = QStringLiteral("HTTP %1").arg(status);
            } else {
                detail = reply->errorString();
            }
            _setHealth(QStringLiteral("fail"), detail);
            return;
        }

        QJsonParseError parseError{};
        const QJsonDocument doc = QJsonDocument::fromJson(body, &parseError);
        if (parseError.error != QJsonParseError::NoError || !doc.isObject()) {
            _setHealth(QStringLiteral("fail"), QStringLiteral("non-JSON response"));
            return;
        }

        const QJsonObject obj = doc.object();
        if (!obj.value(QStringLiteral("ok")).toBool()) {
            _setHealth(QStringLiteral("fail"), QStringLiteral("ok=false"));
            return;
        }

        const QString preset = obj.value(QStringLiteral("preset")).toString();
        if (preset != QStringLiteral("px4-ta")) {
            // The server never validates the preset itself -- index.js:45 fills the field
            // with a constant -- so a mismatch is a *diagnostic*, not a gate: keep the panel
            // usable and let a genuine failure surface as 500 px4/preset-missing on POST /chat.
            _setHealth(QStringLiteral("warn"), QStringLiteral("preset=%1 (expected px4-ta)").arg(preset));
            return;
        }

        _setHealth(QStringLiteral("ok"), QStringLiteral("preset=px4-ta"));
    });
}

void AssistantClient::sendChat(const QString &text, const QVariantMap &context)
{
    if (_busy) {
        return;
    }

    const QString prompt = text.trimmed();
    if (prompt.isEmpty()) {
        return;
    }

    if (!tokenFound()) {
        reloadToken();
    }
    if (!tokenFound()) {
        emit chatError(QStringLiteral("px4/no-token"),
                       QStringLiteral("panel-token not found"));
        return;
    }

    QJsonObject payload;
    if (!_sessionId.isEmpty()) {
        payload.insert(QStringLiteral("sessionId"), _sessionId);
    }
    payload.insert(QStringLiteral("text"), prompt);
    if (!context.isEmpty()) {
        payload.insert(QStringLiteral("context"), QJsonObject::fromVariantMap(context));
    }

    QNetworkRequest request{QUrl(_baseUrl + QStringLiteral("/px4-agent/chat"))};
    request.setHeader(QNetworkRequest::ContentTypeHeader, QStringLiteral("application/json"));
    request.setRawHeader("Accept", "text/event-stream");
    request.setRawHeader("X-PX4-Agent-Token", _token.toUtf8());

    _sseBuffer.clear();
    _pendingEvent.clear();
    _pendingData.clear();
    _eventCount = 0;

    _chatReply = _nam->post(request, QJsonDocument(payload).toJson(QJsonDocument::Compact));
    connect(_chatReply, &QNetworkReply::readyRead, this, &AssistantClient::_processSse);
    connect(_chatReply, &QNetworkReply::finished, this, [this] {
        QNetworkReply *reply = _chatReply;
        _chatReply = nullptr;

        const QByteArray body = reply->readAll();
        _sseBuffer += body;
        _parseSseBuffer();

        // Flush a trailing event that was not terminated by a blank line.
        if (!_pendingData.isEmpty()) {
            _dispatchEvent(QString::fromUtf8(_pendingEvent), _pendingData);
            _pendingEvent.clear();
            _pendingData.clear();
        }

        const int status = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
        const QNetworkReply::NetworkError error = reply->error();
        const QString errorString = reply->errorString();
        reply->deleteLater();

        _setBusy(false);

        if (error == QNetworkReply::OperationCanceledError) {
            emit chatDone(QStringLiteral("aborted"));
            return;
        }

        if (_eventCount > 0 && error != QNetworkReply::NoError) {
            // SSE stream was interrupted mid-flight after delivering some events: the UI
            // was left dangling with no "round finished" marker. Emit a done/notice so
            // consumers can close the busy state cleanly. (review pass2 P2)
            emit chatNotice(QStringLiteral("warn"),
                            QStringLiteral("stream interrupted after %1 event(s): %2")
                                    .arg(_eventCount).arg(errorString));
            emit chatDone(QStringLiteral("interrupted"));
            return;
        }

        if (_eventCount == 0 && (error != QNetworkReply::NoError || status >= 400)) {
            // Non-SSE JSON error body: {"ok":false,"error":{"code":"...","message":"..."}}
            const QJsonDocument errorDoc = QJsonDocument::fromJson(body);
            const QJsonObject errorObj = errorDoc.isObject()
                    ? errorDoc.object().value(QStringLiteral("error")).toObject()
                    : QJsonObject();
            if (!errorObj.isEmpty()) {
                emit chatError(errorObj.value(QStringLiteral("code")).toString(),
                               errorObj.value(QStringLiteral("message")).toString());
            } else {
                emit chatError(status > 0 ? QStringLiteral("px4/http-%1").arg(status)
                                          : QStringLiteral("px4/network"),
                               status > 0 ? QStringLiteral("request rejected") : errorString);
            }
        }
    });

    _setBusy(true);
}

void AssistantClient::cancelChat()
{
    if (_chatReply) {
        _chatReply->abort();
    }
}

void AssistantClient::_processSse()
{
    if (!_chatReply) {
        return;
    }
    _sseBuffer += _chatReply->readAll();
    _parseSseBuffer();
}

void AssistantClient::_parseSseBuffer()
{
    int newlineIndex = -1;
    while ((newlineIndex = _sseBuffer.indexOf('\n')) >= 0) {
        QByteArray line = _sseBuffer.left(newlineIndex);
        _sseBuffer.remove(0, newlineIndex + 1);

        if (line.endsWith('\r')) {
            line.chop(1);
        }

        if (line.isEmpty()) {
            if (!_pendingEvent.isEmpty() || !_pendingData.isEmpty()) {
                _dispatchEvent(QString::fromUtf8(_pendingEvent), _pendingData);
                _pendingEvent.clear();
                _pendingData.clear();
            }
            continue;
        }

        if (line.startsWith(':')) {
            continue; // keep-alive comment
        }

        if (line.startsWith("event:")) {
            _pendingEvent = line.mid(6).trimmed();
        } else if (line.startsWith("data:")) {
            QByteArray data = line.mid(5);
            if (data.startsWith(' ')) {
                data = data.mid(1);
            }
            if (!_pendingData.isEmpty()) {
                _pendingData += '\n';
            }
            _pendingData += data;
        }
    }
}

void AssistantClient::_dispatchEvent(const QString &eventName, const QByteArray &data)
{
    ++_eventCount;

    QJsonParseError parseError{};
    const QJsonDocument doc = QJsonDocument::fromJson(data, &parseError);
    const QJsonObject obj = doc.isObject() ? doc.object() : QJsonObject();

    if (eventName == QLatin1String("meta")) {
        _sessionId = obj.value(QStringLiteral("sessionId")).toString();
        emit chatMeta(_sessionId,
                      obj.value(QStringLiteral("preset")).toString(),
                      obj.value(QStringLiteral("newSession")).toBool());
    } else if (eventName == QLatin1String("token")) {
        emit chatTokenDelta(obj.value(QStringLiteral("text")).toString());
    } else if (eventName == QLatin1String("thinking")) {
        emit chatThinkingDelta(obj.value(QStringLiteral("text")).toString());
    } else if (eventName == QLatin1String("tool")) {
        emit chatToolEvent(obj.toVariantMap());
    } else if (eventName == QLatin1String("notice")) {
        emit chatNotice(obj.value(QStringLiteral("level")).toString(),
                        obj.value(QStringLiteral("text")).toString());
    } else if (eventName == QLatin1String("done")) {
        emit chatDone(obj.value(QStringLiteral("outcome")).toString());
    } else if (eventName == QLatin1String("error")) {
        emit chatError(obj.value(QStringLiteral("code")).toString(),
                       obj.value(QStringLiteral("message")).toString());
    }
}
