#include "AlertNarrator.h"

#include "AlertEngine.h"
#include "AssistantClient.h"

#include <QtCore/QDateTime>
#include <QtCore/QJsonArray>
#include <QtCore/QJsonDocument>
#include <QtCore/QJsonObject>
#include <QtCore/QJsonParseError>

#include <algorithm>

AlertNarrator::AlertNarrator(AlertEngine *engine, AssistantClient *client, QObject *parent)
    : QObject(parent)
    , _engine(engine)
    , _client(client)
{
    _mergeTimer.setSingleShot(true);
    _mergeTimer.setInterval(_mergeMs);
    (void) connect(&_mergeTimer, &QTimer::timeout, this, &AlertNarrator::_flush);

    _timeoutTimer.setSingleShot(true);
    _timeoutTimer.setInterval(60000);
    (void) connect(&_timeoutTimer, &QTimer::timeout, this, [this]() {
        if (_status == QStringLiteral("requesting")) {
            if (_client) {
                _client->cancelChat();
            }
            _lastError = QStringLiteral("narrator-timeout");
            _setStatus(QStringLiteral("error"));
        }
    });

    if (_engine) {
        (void) connect(_engine, &AlertEngine::alertRaised, this, &AlertNarrator::_onAlertRaised);
    }
    if (_client) {
        (void) connect(_client, &AssistantClient::chatTokenDelta, this, &AlertNarrator::_onDelta);
        (void) connect(_client, &AssistantClient::chatDone, this, &AlertNarrator::_onDone);
        (void) connect(_client, &AssistantClient::chatError, this, &AlertNarrator::_onError);
    }
}

void AlertNarrator::setEnabled(bool enabled)
{
    if (_enabled == enabled) {
        return;
    }
    _enabled = enabled;
    if (!enabled) {
        dismiss();
        _setStatus(QStringLiteral("disabled"));
    } else {
        _setStatus(QStringLiteral("idle"));
    }
    emit enabledChanged();
}

void AlertNarrator::refresh()
{
    if (_lastAlert.isEmpty()) {
        return;
    }
    _lastRequestMs.clear();
    _pending.clear();
    _onAlertRaised(_lastAlert);
}

void AlertNarrator::dismiss()
{
    _pending.clear();
    _mergeTimer.stop();
    _timeoutTimer.stop();
    if (_status == QStringLiteral("requesting") && _client) {
        _client->cancelChat();
    }
    if (_status != QStringLiteral("disabled")) {
        _setStatus(QStringLiteral("idle"));
    }
    _narrative.clear();
    _lastAlert.clear();
    _reply.clear();
    _lastError.clear();
    emit narrativeChanged();
}

void AlertNarrator::_onAlertRaised(const QVariantMap &alert)
{
    if (!_enabled) {
        return;
    }
    // Level 0 is purely informational (mode changed, no home yet) - narrating
    // every green notice would bury the real guidance.
    if (alert.value(QStringLiteral("level")).toInt() < 1) {
        return;
    }

    const QString ruleId = alert.value(QStringLiteral("ruleId")).toString();
    const QString code   = alert.value(QStringLiteral("code")).toString();
    const QString key    = ruleId + QLatin1Char('/') + code;
    const qint64 nowMs   = QDateTime::currentMSecsSinceEpoch();

    // Acceptance C4: no repeated request for the same rule/code inside the
    // cooldown window, even if the UI re-raises it.
    if (_lastRequestMs.contains(key) && nowMs - _lastRequestMs.value(key) < _dedupMs) {
        return;
    }
    _lastRequestMs.insert(key, nowMs);

    _lastAlert = alert;
    _pending.append(alert);

    // Burst merge: hold briefly so several rules arriving together share one
    // turn instead of one request each.
    if (!_mergeTimer.isActive()) {
        _mergeTimer.start(_mergeMs);
    }
}

void AlertNarrator::_flush()
{
    if (_pending.isEmpty()) {
        return;
    }
    if (_client && _client->busy()) {
        // The dedicated narrator client is single-flight; retry shortly.
        _mergeTimer.start(1500);
        return;
    }

    const QString health = _client ? _client->healthState() : QStringLiteral("unknown");
    const bool usable = _client && _client->tokenFound()
                        && (health == QStringLiteral("ok") || health == QStringLiteral("warn"));
    if (!usable) {
        // Offline degrade: hand the raw fields to QML, which renders the local
        // template for this rule/code.
        _setOffline(_pending.last().toMap());
        _pending.clear();
        return;
    }

    const QVariantList batch = _pending;
    _pending.clear();
    _request(batch);
}

void AlertNarrator::_request(const QVariantList &alerts)
{
    _reply.clear();
    _lastError.clear();

    QVariantMap pending = alerts.last().toMap();
    pending[QStringLiteral("source")] = QStringLiteral("pending");
    _narrative = pending;
    _setStatus(QStringLiteral("requesting"));

    QVariantMap context;
    context[QStringLiteral("qgc")] = QStringLiteral("5.1.5");
    context[QStringLiteral("channel")] = QStringLiteral("alert-narrator");
    context[QStringLiteral("alertCount")] = alerts.size();

    _client->sendChat(_buildPrompt(alerts), context);
    _timeoutTimer.start();
}

void AlertNarrator::_setOffline(const QVariantMap &alert)
{
    QVariantMap out = _alertSummary(alert);
    out[QStringLiteral("source")] = QStringLiteral("template");
    _narrative = out;
    _lastError = _client ? QStringLiteral("offline") : QStringLiteral("no-client");
    _setStatus(QStringLiteral("offline"));
}

void AlertNarrator::_onDelta(const QString &text)
{
    if (_status == QStringLiteral("requesting")) {
        _reply += text;
    }
}

void AlertNarrator::_onDone(const QString &outcome)
{
    Q_UNUSED(outcome)
    if (_status != QStringLiteral("requesting")) {
        return;
    }
    _timeoutTimer.stop();
    _applyReply();

    // Alerts that arrived while this turn was in flight go out next.
    if (!_pending.isEmpty()) {
        _mergeTimer.start(200);
    }
}

void AlertNarrator::_onError(const QString &code, const QString &message)
{
    if (_status != QStringLiteral("requesting")) {
        return;
    }
    _timeoutTimer.stop();
    _lastError = message.isEmpty() ? code : code + QLatin1Char(' ') + message;
    _setStatus(QStringLiteral("error"));

    if (!_pending.isEmpty()) {
        _mergeTimer.start(200);
    }
}

void AlertNarrator::_applyReply()
{
    const QString text = _reply.trimmed();
    if (text.isEmpty()) {
        _lastError = QStringLiteral("empty-reply");
        _setStatus(QStringLiteral("error"));
        return;
    }

    // The model is asked for bare JSON, but fences happen: strip them and take
    // the outermost object.
    QString body = text;
    const int first = body.indexOf(QLatin1Char('{'));
    const int last  = body.lastIndexOf(QLatin1Char('}'));
    if (first >= 0 && last > first) {
        const QByteArray candidate = body.mid(first, last - first + 1).toUtf8();
        QJsonParseError err;
        const QJsonDocument doc = QJsonDocument::fromJson(candidate, &err);
        if (err.error == QJsonParseError::NoError && doc.isObject()) {
            const QJsonObject obj = doc.object();
            QVariantMap out = _alertSummary(_lastAlert);
            out[QStringLiteral("source")] = QStringLiteral("auto");

            const QString conclusion = obj.value(QStringLiteral("conclusion")).toString().trimmed();
            if (!conclusion.isEmpty()) {
                out[QStringLiteral("conclusion")] = conclusion;
            } else if (obj.contains(QStringLiteral("summary"))) {
                out[QStringLiteral("conclusion")] = obj.value(QStringLiteral("summary")).toString();
            }

            QStringList steps;
            const QJsonArray stepArray = obj.value(QStringLiteral("steps")).toArray();
            for (const QJsonValue &v : stepArray) {
                const QString step = v.toString().trimmed();
                if (!step.isEmpty() && steps.size() < 6) {
                    steps.append(step);
                }
            }
            out[QStringLiteral("steps")] = steps;
            out[QStringLiteral("risk")] = obj.value(QStringLiteral("risk")).toString();
            out[QStringLiteral("targetId")] = obj.value(QStringLiteral("targetId")).toString();

            if (!out.contains(QStringLiteral("conclusion"))
                    || out.value(QStringLiteral("conclusion")).toString().isEmpty()) {
                // JSON was syntactically fine but carried no usable conclusion:
                // fall back to the raw text so the panel is never blank.
                out[QStringLiteral("conclusion")] = text.left(600);
                out[QStringLiteral("source")] = QStringLiteral("plain");
            }
            _narrative = out;
            _setStatus(QStringLiteral("ready"));
            return;
        }
    }

    // Contract violation: keep the answer as a plain conclusion.
    QVariantMap out = _alertSummary(_lastAlert);
    out[QStringLiteral("source")] = QStringLiteral("plain");
    out[QStringLiteral("conclusion")] = text.left(600);
    out[QStringLiteral("steps")] = QStringList();
    out[QStringLiteral("risk")] = QString();
    out[QStringLiteral("targetId")] = QString();
    _narrative = out;
    _setStatus(QStringLiteral("ready"));
}

void AlertNarrator::_setStatus(const QString &status)
{
    _status = status;
    emit narrativeChanged();
}

QVariantMap AlertNarrator::_alertSummary(const QVariantMap &alert) const
{
    QVariantMap out;
    out[QStringLiteral("ruleId")]   = alert.value(QStringLiteral("ruleId"));
    out[QStringLiteral("level")]    = alert.value(QStringLiteral("level"));
    out[QStringLiteral("code")]     = alert.value(QStringLiteral("code"));
    out[QStringLiteral("detail")]   = alert.value(QStringLiteral("detail"));
    out[QStringLiteral("raisedMs")] = QDateTime::currentMSecsSinceEpoch();
    return out;
}

QString AlertNarrator::_buildPrompt(const QVariantList &alerts) const
{
    QJsonArray arr;
    for (const QVariant &v : alerts) {
        arr.append(QJsonObject::fromVariantMap(v.toMap()));
    }
    QJsonObject root;
    root[QStringLiteral("alerts")] = arr;

    // Recent history is context, not instructions: cap it to the newest 5 rows.
    QJsonArray recent;
    if (_engine) {
        const QVariantList history = _engine->history();
        const int from = qMax(0, history.size() - 5);
        for (int i = from; i < history.size(); ++i) {
            recent.append(QJsonObject::fromVariantMap(history.at(i).toMap()));
        }
    }
    root[QStringLiteral("recentHistory")] = recent;

    const QString payload = QString::fromUtf8(QJsonDocument(root).toJson(QJsonDocument::Compact));

    QString prompt;
    prompt += QStringLiteral("You are the read-only flight-alert narrator of a PX4 ground station.\n");
    prompt += QStringLiteral("Hard rules: never propose writing to the vehicle - no arm/disarm, no mode change, no parameter writes, no mission uploads, no calibration or motor-test commands. Your guidance is informational and read-only.\n");
    prompt += QStringLiteral("Answer in Simplified Chinese.\n");
    prompt += QStringLiteral("Return ONLY one JSON object, no markdown fences, with these keys: conclusion (one short sentence), steps (array of at most 5 short imperative strings), risk (one short sentence, may be empty), targetId (short ui target id, or empty string if none).\n");
    prompt += QStringLiteral("Allowed targetId values (pick the closest match, or empty string): fly.toolbar.battery, fly.toolbar.gps, fly.toolbar.radio, fly.toolbar.mode, fly.toolbar.status, fly.attitude, panel.alertSettings, panel.alertHistory, panel.chat, view.plan, view.analyze, view.setup, view.settings, view.settings.commLinks.\n");
    prompt += QStringLiteral("Level 1 = warning, level 2 = critical, level 3 = most severe.\n");
    prompt += QStringLiteral("Facts: ");
    prompt += payload;
    return prompt;
}
