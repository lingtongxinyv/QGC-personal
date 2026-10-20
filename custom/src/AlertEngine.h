#pragma once

#include <QtCore/QHash>
#include <QtCore/QObject>
#include <QtCore/QSettings>
#include <QtCore/QTimer>
#include <QtCore/QVariantList>
#include <QtCore/QVariantMap>

class MultiVehicleManager;
class Vehicle;

/// Local deterministic alert rule engine (batch B5 phase 1).
///
/// Read-only by contract (acceptance E1): evaluates rules R1-R10 against the
/// active Vehicle facts at 10 Hz. It performs zero MAVLink writes, zero
/// parameter writes, zero mode changes and zero mission writes; it only reads
/// facts and listens to FENCE_BREACH notifications. Alert data stays inside
/// this process (QML bindings only) - it never enters the 19390 relay or the
/// Unity feed (acceptance E2).
///
/// Output contract (design section 3): every alert is
///   { ruleId, level, code, detail }  with level 0=info 1=warn 2=critical.
/// All literal strings here are ASCII codes; the Chinese wording lives in the
/// QML layer because MSVC compiles this file with code page 936.
///
/// Deduplication (acceptance A2/A3): state-edge triggering (one raise per
/// activation, one recovery per deactivation), escalation pierces the
/// cooldown window immediately, downgrades follow the edge. The activeAlerts
/// list always mirrors the desired state; the cooldown only throttles the
/// event stream (history + alertRaised signal).
class AlertEngine : public QObject
{
    Q_OBJECT

    Q_PROPERTY(bool         enabled      READ enabled      WRITE setEnabled NOTIFY enabledChanged)
    Q_PROPERTY(QVariantList activeAlerts READ activeAlerts NOTIFY activeAlertsChanged)
    Q_PROPERTY(QVariantList history      READ history      NOTIFY historyChanged)
    Q_PROPERTY(QString      state        READ state        NOTIFY stateChanged)

public:
    explicit AlertEngine(QObject *parent = nullptr);
    ~AlertEngine() override;

    bool        enabled() const       { return _enabled; }
    void        setEnabled(bool enabled);
    QVariantList activeAlerts() const { return _activeAlerts; }
    QVariantList history() const      { return _history; }
    QString     state() const;

    /// Threshold access is key-based so the QML settings UI can be built from
    /// thresholdDefaults() without one C++ property per threshold. Values are
    /// clamped to [min, max] and persisted under CustomAlerts/thresholds.
    Q_INVOKABLE double  threshold(const QString &key) const;
    Q_INVOKABLE void    setThreshold(const QString &key, double value);
    Q_INVOKABLE bool    ruleEnabled(const QString &ruleId) const;
    Q_INVOKABLE void    setRuleEnabled(const QString &ruleId, bool on);
    Q_INVOKABLE void    resetAll();
    /// [{key, def, min, max}] descriptors for the QML settings UI.
    Q_INVOKABLE QVariantList thresholdDefaults() const;

    /// Debug/acceptance hook (A1): inject a mock fact by name
    /// ("batteryPct", "armed", "sats", "commLost", ...) to override the live
    /// value at the next evaluation tick. The map persists until cleared, so
    /// every rule R1-R10 can be exercised without a SITL scenario. Requires an
    /// active vehicle; an empty map is a pure passthrough.
    Q_INVOKABLE void injectMockFact(const QString &name, const QVariant &value);
    Q_INVOKABLE void clearMockFacts();

signals:
    void enabledChanged();
    void activeAlertsChanged();
    void historyChanged();
    void stateChanged();
    /// Phase-2 hook: fired once per announced activation/escalation.
    void alertRaised(const QVariantMap &alert);
    /// Fired once per deactivation (state edge, never throttled).
    void alertCleared(const QVariantMap &alert);

private slots:
    void _tick();
    void _activeVehicleChanged(Vehicle *vehicle);

private:
    struct RuleState {
        bool       active     = false;
        bool       announced  = false;
        int        level      = 0;
        int        peakLevel  = 0;
        int        suppressedCount = 0;
        QString    code;
        QVariantMap detail;
        qint64     sinceMs    = 0;
        qint64     lastAnnounceMs = 0;
        QVariantMap historyEntry;
    };

    struct ThresholdDef {
        const char *key;
        double      def;
        double      min;
        double      max;
    };

    void    _connectVehicle(Vehicle *vehicle);
    void    _resetRuleStates(bool closeHistory);
    void    _applyDesired(const QString &ruleId, bool active, int level,
                          const QString &code, const QVariantMap &detail,
                          qint64 nowMs, qint64 cooldownMs, bool &dirty);
    void    _rebuildActiveAlerts();
    void    _announce(RuleState &state, const QString &ruleId, qint64 nowMs);
    void    _closeHistoryEntry(const QVariantMap &entry, qint64 nowMs);
    QVariantMap _eventPayload(const QString &ruleId, int level,
                              const QString &code, const QVariantMap &detail) const;

    static const ThresholdDef _thresholdDefs[];
    static const char        *_ruleIds[];
    static const int          _historyCap = 200;

    QTimer               _timer;
    MultiVehicleManager *_multiVehicleManager   = nullptr;
    Vehicle             *_vehicle               = nullptr;
    QMetaObject::Connection _vehicleMsgConnection;

    QSettings            _settings;
    QVariantList         _activeAlerts;
    QVariantList         _history;
    bool                 _enabled            = true;
    qint64               _lastDataMs         = 0;
    quint64              _lastReceivedCount  = 0;
    QString              _lastFlightMode;
    bool                 _fenceBreachLatched = false;
    int                  _fenceBreachType    = 0;
    qint64               _modeChangeFlashUntilMs = 0;
    QHash<QString, QVariant>   _mockFacts;
    QHash<QString, RuleState> _ruleStates;
};
