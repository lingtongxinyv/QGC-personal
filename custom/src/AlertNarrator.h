#pragma once

#include <QtCore/QHash>
#include <QtCore/QObject>
#include <QtCore/QString>
#include <QtCore/QTimer>
#include <QtCore/QVariantList>
#include <QtCore/QVariantMap>

class AlertEngine;
class AssistantClient;

/**
 * AlertNarrator
 *
 * Batch B5 phase 2: turns a deterministic alert (AlertEngine, R1-R10) into a
 * read-only explanation from the local DSH assistant (persona: Xiaoyun).
 *
 * Chain: AlertEngine::alertRaised -> throttle/merge -> one chat turn -> parse
 * the structured reply -> `narrative` consumed by the panel.
 *
 * Guarantees:
 *   - Read-only. It only talks to the local DSH HTTP endpoint; it never writes
 *     to MAVLink, parameters, flight modes or missions. The prompt explicitly
 *     forbids command proposals.
 *   - No duplicate request per rule/code inside the cooldown window.
 *   - Alerts raised inside the merge window are sent as ONE turn (multiple
 *     rules share one context), so a burst does not spam the model.
 *   - Offline degrade: when the panel token is missing or DSH is unhealthy the
 *     status becomes "offline" and QML renders the local template
 *     (AlertTemplates.js) from the alert fields in `narrative`.
 *   - Contract violation (no JSON) still yields a usable `conclusion` built
 *     from the plain text (source = "plain").
 *
 * Narrative keys: ruleId, level, code, detail, raisedMs, source
 * ("auto" | "plain" | "template" | "pending"), conclusion, steps, risk,
 * targetId.
 *
 * C++ stays ASCII-only (MSVC code page 936); all Chinese wording lives in QML
 * and AlertTemplates.js.
 */
class AlertNarrator : public QObject
{
    Q_OBJECT
    Q_PROPERTY(QString     status    READ status    NOTIFY narrativeChanged)
    Q_PROPERTY(QVariantMap narrative READ narrative NOTIFY narrativeChanged)
    Q_PROPERTY(bool        enabled   READ enabled   WRITE setEnabled NOTIFY enabledChanged)
    Q_PROPERTY(QString     lastError READ lastError NOTIFY narrativeChanged)

public:
    AlertNarrator(AlertEngine *engine, AssistantClient *client, QObject *parent = nullptr);

    QString     status() const     { return _status; }
    QVariantMap narrative() const  { return _narrative; }
    bool        enabled() const    { return _enabled; }
    QString     lastError() const  { return _lastError; }

    void setEnabled(bool enabled);

    /// Re-request the current alert, bypassing the dedup window.
    Q_INVOKABLE void refresh();
    /// Drop the current narrative (and abort an in-flight turn).
    Q_INVOKABLE void dismiss();

signals:
    void narrativeChanged();
    void enabledChanged();

private:
    void _onAlertRaised(const QVariantMap &alert);
    void _flush();
    void _onDelta(const QString &text);
    void _onDone(const QString &outcome);
    void _onError(const QString &code, const QString &message);

    void _request(const QVariantList &alerts);
    void _setOffline(const QVariantMap &alert);
    void _applyReply();
    void _setStatus(const QString &status);

    QString _buildPrompt(const QVariantList &alerts) const;
    QVariantMap _alertSummary(const QVariantMap &alert) const;

    AlertEngine     *_engine = nullptr;
    AssistantClient *_client = nullptr;

    QTimer _mergeTimer;
    QTimer _timeoutTimer;

    QVariantList _pending;      // alerts waiting for the merge window
    QVariantMap  _lastAlert;    // newest alert, for refresh()/template fallback
    QHash<QString, qint64> _lastRequestMs;

    QVariantMap _narrative;
    QString     _status = QStringLiteral("idle");
    QString     _lastError;
    QString     _reply;
    bool        _enabled = true;

    int  _dedupMs = 10000;      // per rule/code, matches the engine cooldown
    int  _mergeMs = 800;        // burst merge window
};
