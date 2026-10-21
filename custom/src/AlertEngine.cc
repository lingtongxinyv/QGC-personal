#include "AlertEngine.h"

#include "MultiVehicleManager.h"
#include "QGCLoggingCategory.h"
#include "QGCMAVLink.h"
#include "Vehicle.h"

#include <QtCore/QDateTime>
#include <QtCore/QMetaObject>
#include <algorithm>
#include <cmath>
#include <limits>

QGC_LOGGING_CATEGORY(AlertLog, "Custom.AlertEngine")

namespace {

constexpr double kNaN = std::numeric_limits<double>::quiet_NaN();

// Facts are reached through QObject properties so the engine does not need the
// FactSystem types: property(name) on a Vehicle/FactGroup yields a Fact*, and
// property("rawValue") on a Fact yields the current value. This stays correct
// across QGC fact-group refactors as long as the QML property names hold.
QVariant _rawValue(QObject *host, const char *name)
{
    if (!host) {
        return QVariant();
    }
    const QVariant factVariant = host->property(name);
    if (!factVariant.isValid()) {
        return QVariant();
    }
    QObject *fact = factVariant.value<QObject *>();
    if (!fact) {
        return QVariant();
    }
    const QVariant value = fact->property("rawValue");
    return value.isValid() ? value : QVariant();
}

double _factNum(QObject *host, const char *name)
{
    const QVariant value = _rawValue(host, name);
    if (!value.isValid()) {
        return kNaN;
    }
    bool ok = false;
    const double number = value.toDouble(&ok);
    return ok ? number : kNaN;
}

bool _factBool(QObject *host, const char *name)
{
    const QVariant value = _rawValue(host, name);
    return value.isValid() ? value.toBool() : false;
}

QObject *_childObject(QObject *host, const char *name)
{
    if (!host) {
        return nullptr;
    }
    return host->property(name).value<QObject *>();
}

} // namespace

const AlertEngine::ThresholdDef AlertEngine::_thresholdDefs[] = {
    // key                    def    min     max
    { "battery-warn-pct",      30,     0,    100 },
    { "battery-crit-pct",      15,     0,    100 },
    { "preflight-battery-pct", 60,     0,    100 },
    { "rssi-warn",             40,     0,    100 },
    { "rssi-crit",             25,     0,    100 },
    { "radio-rssi-warn-dbm",  -95,  -120,    -30 },
    { "radio-rssi-crit-dbm", -105,  -120,    -30 },
    { "gps-warn-sats",          8,     0,     32 },
    { "gps-min-sats",           6,     0,     32 },
    { "hdop-warn",            1.8,   0.5,     10 },
    { "hdop-crit",            2.5,   0.5,     10 },
    { "attitude-soft-deg",     45,    10,     90 },
    { "attitude-hard-deg",     60,    10,     90 },
    { "max-altitude-m",       500,    10,  10000 },
    { "descent-warn-m-s",     5.0,   0.5,     30 },
    { "descent-crit-m-s",     8.0,   0.5,     60 },
    { "data-stale-warn-s",    3.0,   1.0,     60 },
    { "data-stale-crit-s",   10.0,   1.0,    120 },
    { "loss-pct-warn",         30,     0,    100 },
    { "cooldown-sec",          10,     0,    120 },
};

const char *AlertEngine::_ruleIds[] = {
    "R1", "R2", "R3", "R4", "R5", "R6", "R7", "R8", "R9", "R10"
};

AlertEngine::AlertEngine(QObject *parent)
    : QObject(parent)
{
    _settings.beginGroup(QStringLiteral("CustomAlerts"));
    _enabled = _settings.value(QStringLiteral("enabled"), true).toBool();

    auto *manager = MultiVehicleManager::instance();
    if (manager) {
        _multiVehicleManager = manager;
        (void) connect(manager, &MultiVehicleManager::activeVehicleChanged,
                       this, &AlertEngine::_activeVehicleChanged);
        _activeVehicleChanged(manager->activeVehicle());
    }

    _timer.setInterval(100);
    (void) connect(&_timer, &QTimer::timeout, this, &AlertEngine::_tick);
    _timer.start();
}

AlertEngine::~AlertEngine()
{
    _timer.stop();
}

QString AlertEngine::state() const
{
    return _enabled ? QStringLiteral("ok") : QStringLiteral("disabled");
}

void AlertEngine::setEnabled(bool enabled)
{
    if (_enabled == enabled) {
        return;
    }
    _enabled = enabled;
    _settings.setValue(QStringLiteral("enabled"), enabled);
    emit enabledChanged();
    emit stateChanged();
    if (!_enabled) {
        // The disabled state must be explicit (acceptance B4): drop the live
        // list so nothing stale is shown as if it were current. History is kept.
        _resetRuleStates(false);
        _activeAlerts.clear();
        emit activeAlertsChanged();
    }
}

double AlertEngine::threshold(const QString &key) const
{
    for (const ThresholdDef &def : _thresholdDefs) {
        if (key == QLatin1String(def.key)) {
            return _settings.value(QStringLiteral("thresholds/%1").arg(key), def.def).toDouble();
        }
    }
    qCWarning(AlertLog) << "unknown threshold" << key;
    return 0.0;
}

void AlertEngine::setThreshold(const QString &key, double value)
{
    for (const ThresholdDef &def : _thresholdDefs) {
        if (key == QLatin1String(def.key)) {
            const double clamped = qBound(def.min, value, def.max);
            _settings.setValue(QStringLiteral("thresholds/%1").arg(key), clamped);
            return;
        }
    }
    qCWarning(AlertLog) << "cannot set unknown threshold" << key;
}

QVariantList AlertEngine::thresholdDefaults() const
{
    QVariantList list;
    for (const ThresholdDef &def : _thresholdDefs) {
        QVariantMap entry;
        entry["key"] = QString(def.key);
        entry["def"] = def.def;
        entry["min"] = def.min;
        entry["max"] = def.max;
        list.append(entry);
    }
    return list;
}

bool AlertEngine::ruleEnabled(const QString &ruleId) const
{
    return _settings.value(QStringLiteral("rules/%1").arg(ruleId), true).toBool();
}

void AlertEngine::setRuleEnabled(const QString &ruleId, bool on)
{
    _settings.setValue(QStringLiteral("rules/%1").arg(ruleId), on);
}

void AlertEngine::resetAll()
{
    _settings.remove(QStringLiteral("thresholds"));
    _settings.remove(QStringLiteral("rules"));
    if (!_enabled) {
        setEnabled(true);
    }
}

void AlertEngine::injectMockFact(const QString &name, const QVariant &value)
{
    _mockFacts.insert(name, value);
}

void AlertEngine::clearMockFacts()
{
    _mockFacts.clear();
}

QVariantMap AlertEngine::_eventPayload(const QString &ruleId, int level,
                                       const QString &code, const QVariantMap &detail) const
{
    QVariantMap payload;
    payload["ruleId"] = ruleId;
    payload["level"]  = level;
    payload["code"]   = code;
    payload["detail"] = detail;
    return payload;
}

void AlertEngine::_closeHistoryEntry(const QVariantMap &entry, qint64 nowMs)
{
    for (int i = 0; i < _history.size(); ++i) {
        QVariantMap stored = _history.at(i).toMap();
        if (stored["ruleId"] == entry["ruleId"] && stored["raisedMs"] == entry["raisedMs"]
                && stored["active"].toBool()) {
            stored["recoveredMs"] = nowMs;
            stored["active"] = false;
            stored["levelPeak"] = qMax(stored["levelPeak"].toInt(), entry["levelPeak"].toInt());
            _history[i] = stored;
            emit historyChanged();
            return;
        }
    }
}

void AlertEngine::_announce(RuleState &state, const QString &ruleId, qint64 nowMs)
{
    state.announced = true;
    state.lastAnnounceMs = nowMs;

    if (state.historyEntry.isEmpty()) {
        QVariantMap entry;
        entry["ruleId"]      = ruleId;
        entry["code"]        = state.code;
        entry["level"]       = state.level;
        entry["levelPeak"]   = state.peakLevel;
        entry["detail"]      = state.detail;
        entry["raisedMs"]    = nowMs;
        entry["recoveredMs"] = QVariant();
        entry["active"]      = true;
        state.historyEntry = entry;
        _history.prepend(entry);
        while (_history.size() > _historyCap) {
            _history.removeLast();
        }
        emit historyChanged();
    }
    emit alertRaised(_eventPayload(ruleId, state.level, state.code, state.detail));
}

void AlertEngine::_applyDesired(const QString &ruleId, bool active, int level,
                                const QString &code, const QVariantMap &detail,
                                qint64 nowMs, qint64 cooldownMs, bool &dirty)
{
    RuleState &state = _ruleStates[ruleId];

    if (!active) {
        if (state.active) {
            state.active = false;
            if (!state.historyEntry.isEmpty()) {
                _closeHistoryEntry(state.historyEntry, nowMs);
                state.historyEntry = QVariantMap();
            } else if (state.suppressedCount > 0) {
                // Cooldown-throttled activation (xiaoling v9 P3-2): the alert
                // was live but never announced, so without this row a short
                // alert would vanish from the history entirely.
                QVariantMap entry;
                entry["ruleId"]      = ruleId;
                entry["code"]        = state.code;
                entry["level"]       = state.level;
                entry["levelPeak"]   = state.peakLevel;
                QVariantMap detail = state.detail;
                detail["suppressed"] = state.suppressedCount;
                entry["detail"]      = detail;
                entry["raisedMs"]    = state.sinceMs;
                entry["recoveredMs"] = nowMs;
                entry["active"]      = false;
                _history.prepend(entry);
                while (_history.size() > _historyCap) {
                    _history.removeLast();
                }
                emit historyChanged();
            }
            if (state.announced) {
                emit alertCleared(_eventPayload(ruleId, state.level, state.code, state.detail));
            }
            state.announced = false;
            state.level = 0;
            state.peakLevel = 0;
            state.suppressedCount = 0;
            state.code.clear();
            state.detail.clear();
            dirty = true;
        }
        return;
    }

    if (!state.active) {
        state.active = true;
        state.sinceMs = nowMs;
        state.level = level;
        state.peakLevel = level;
        state.code = code;
        state.detail = detail;
        if (state.lastAnnounceMs == 0 || nowMs - state.lastAnnounceMs >= cooldownMs) {
            _announce(state, ruleId, nowMs);
        } else {
            // Re-trigger inside the cooldown window: the state becomes active
            // but the event is throttled (acceptance A2), so no history row
            // yet - the count is recorded and flushed on clear instead.
            state.announced = false;
            state.historyEntry = QVariantMap();
            state.suppressedCount++;
        }
        dirty = true;
        return;
    }

    if (level > state.level) {
        // Escalation pierces the cooldown (acceptance A3): close the current
        // history row and announce a new one at the higher level immediately.
        state.level = level;
        state.peakLevel = qMax(state.peakLevel, level);
        state.code = code;
        state.detail = detail;
        // Close the row being escalated before starting a new one: without
        // this the previous history entry keeps active=true forever and the
        // same rule shows two live rows (local-dsh v11 P3).
        if (!state.historyEntry.isEmpty()) {
            _closeHistoryEntry(state.historyEntry, nowMs);
        }
        state.historyEntry = QVariantMap();
        _announce(state, ruleId, nowMs);
        dirty = true;
    } else if (level < state.level) {
        state.level = level;
        state.code = code;
        state.detail = detail;
        if (state.lastAnnounceMs == 0 || nowMs - state.lastAnnounceMs >= cooldownMs) {
            state.historyEntry = QVariantMap();
            _announce(state, ruleId, nowMs);
        }
        dirty = true;
    } else {
        state.code = code;
        state.detail = detail;
    }
}

void AlertEngine::_resetRuleStates(bool closeHistory)
{
    const qint64 nowMs = QDateTime::currentMSecsSinceEpoch();
    bool historyDirty = false;

    for (auto it = _ruleStates.begin(); it != _ruleStates.end(); ++it) {
        RuleState &state = it.value();
        if (state.active) {
            if (closeHistory && !state.historyEntry.isEmpty()) {
                _closeHistoryEntry(state.historyEntry, nowMs);
                historyDirty = true;
            }
            if (state.announced) {
                emit alertCleared(_eventPayload(it.key(), state.level, state.code, state.detail));
            }
        }
        state = RuleState();
    }
    _fenceBreachLatched = false;
    _fenceBreachType = 0;
    _modeChangeFlashUntilMs = 0;

    if (historyDirty) {
        // historyChanged was already emitted per closed entry; nothing extra.
    }
}

void AlertEngine::_activeVehicleChanged(Vehicle *vehicle)
{
    if (_vehicleMsgConnection) {
        (void) disconnect(_vehicleMsgConnection);
        _vehicleMsgConnection = QMetaObject::Connection();
    }

    _vehicle = vehicle;
    _resetRuleStates(true);
    _lastReceivedCount = vehicle ? vehicle->mavlinkReceivedCount() : 0;
    _lastDataMs = QDateTime::currentMSecsSinceEpoch();
    _lastFlightMode = vehicle ? vehicle->flightMode() : QString();
    _activeAlerts.clear();
    emit activeAlertsChanged();

    if (vehicle) {
        // Read-only tap for geofence breach notifications (acceptance E1: this
        // only consumes an incoming MAVLink message, nothing is ever sent).
        _vehicleMsgConnection = connect(vehicle, &Vehicle::mavlinkMessageReceived, this,
                                        [this](const mavlink_message_t &message) {
            // FENCE_STATUS is emitted by the vehicle on breach events; this is
            // the same message Vehicle::_handleFenceStatus consumes upstream.
            if (message.msgid == MAVLINK_MSG_ID_FENCE_STATUS) {
                mavlink_fence_status_t fenceStatus;
                mavlink_msg_fence_status_decode(&message, &fenceStatus);
                _fenceBreachType = fenceStatus.breach_type;
                _fenceBreachLatched = fenceStatus.breach_status == 1
                                      && fenceStatus.breach_type != FENCE_BREACH_NONE;
            }
        });
    }
}

void AlertEngine::_rebuildActiveAlerts()
{
    QVariantList list;
    for (auto it = _ruleStates.constBegin(); it != _ruleStates.constEnd(); ++it) {
        const RuleState &state = it.value();
        if (!state.active) {
            continue;
        }
        QVariantMap alert;
        alert["ruleId"]  = it.key();
        alert["level"]   = state.level;
        alert["code"]    = state.code;
        alert["detail"]  = state.detail;
        alert["sinceMs"] = state.sinceMs;
        list.append(alert);
    }
    // Highest level first so the banner can simply take the first entry.
    std::sort(list.begin(), list.end(), [](const QVariant &a, const QVariant &b) {
        return a.toMap()["level"].toInt() > b.toMap()["level"].toInt();
    });
    if (list != _activeAlerts) {
        _activeAlerts = list;
        emit activeAlertsChanged();
    }
}

void AlertEngine::_tick()
{
    if (!_enabled) {
        return;
    }

    Vehicle *vehicle = _vehicle;
    if (!vehicle) {
        _resetRuleStates(true);
        _rebuildActiveAlerts();
        return;
    }

    const qint64 nowMs = QDateTime::currentMSecsSinceEpoch();
    const qint64 cooldownMs = static_cast<qint64>(threshold("cooldown-sec") * 1000.0);
    bool dirty = false;

    auto apply = [&](const char *ruleId, bool active, int level,
                     const QString &code, const QVariantMap &detail) {
        const QString id = QString::fromLatin1(ruleId);
        _applyDesired(id, active && ruleEnabled(id), level, code, detail,
                      nowMs, cooldownMs, dirty);
    };

    // ---------------------------------------------------------------- facts
    QObject *veh   = _childObject(vehicle, "vehicle");           // VehicleFactGroup
    QObject *gps   = _childObject(vehicle, "gps");
    QObject *est   = _childObject(vehicle, "estimatorStatus");
    QObject *radio = _childObject(vehicle, "radioStatus");
    QObject *links = _childObject(vehicle, "vehicleLinkManager");

    bool armed   = vehicle->armed();
    bool flying  = vehicle->flying();
    const QString mode = vehicle->flightMode();

    double batteryPct = kNaN;
    QObject *batteriesList = _childObject(vehicle, "batteries");
    if (batteriesList && batteriesList->property("count").toInt() > 0) {
        QObject *battery = nullptr;
        if (QMetaObject::invokeMethod(batteriesList, "get",
                                      Q_RETURN_ARG(QObject *, battery),
                                      Q_ARG(int, 0)) && battery) {
            batteryPct = _factNum(battery, "percentRemaining");
        }
    }

    double roll      = _factNum(veh, "roll");
    double pitch     = _factNum(veh, "pitch");
    double altRel    = _factNum(veh, "altitudeRelative");
    double climbRate = _factNum(veh, "climbRate");
    double rcRssi    = _factNum(veh, "rcRSSI");            // 0-100, 255 = invalid
    double sats      = _factNum(gps, "count");
    double hdop      = _factNum(gps, "hdop");
    double lossPct   = static_cast<double>(vehicle->mavlinkLossPercent());

    // Data freshness: the received-message counter acts as the change epoch.
    const quint64 receivedCount = vehicle->mavlinkReceivedCount();
    if (receivedCount != _lastReceivedCount) {
        _lastReceivedCount = receivedCount;
        _lastDataMs = nowMs;
    }
    const double staleSecRaw = static_cast<double>(nowMs - _lastDataMs) / 1000.0;
    double staleSec = staleSecRaw;

    // Flight mode tracking for the informational mode-change notice (R7).
    if (mode != _lastFlightMode) {
        if (flying && !_lastFlightMode.isEmpty()) {
            _modeChangeFlashUntilMs = nowMs + 10000;
        }
        _lastFlightMode = mode;
    }
    if (_fenceBreachLatched && !armed) {
        _fenceBreachLatched = false;    // breach state resets on disarm
    }

    // Prepared locals for the rules - also the mock-override surface (A1).
    bool commLost        = links ? links->property("communicationLost").toBool() : false;
    double radioRssiDbm  = (radio && radio->property("telemetryAvailable").toBool())
                           ? _factNum(radio, "rrssi") : kNaN;
    bool estGoodHorizPos = est ? _factBool(est, "goodHorizPosRelEstimate") : true;
    bool estGoodAttitude = est ? _factBool(est, "goodAttitudeEstimate") : true;
    bool estGoodHorizVel = est ? _factBool(est, "goodHorizVelEstimate") : true;
    bool estGoodVertVel  = est ? _factBool(est, "goodVertVelEstimate") : true;
    bool estGpsGlitch    = est ? _factBool(est, "gpsGlitch") : false;
    bool estAccelError   = est ? _factBool(est, "accelError") : false;
    bool preflightReady  = !(vehicle->readyToFlyAvailable() && !vehicle->readyToFly());
    bool sensorsHealthy  = vehicle->allSensorsHealthy();
    bool homeValid       = vehicle->homePosition().isValid();
    bool fenceBreach     = _fenceBreachLatched;
    const int fenceType  = _fenceBreachType;

    // Debug/acceptance hook (A1): injected mock facts override live values so
    // every rule can be exercised without a SITL scenario. Empty = passthrough.
    if (!_mockFacts.isEmpty()) {
        auto md = [this](const char *key, double cur) {
            const auto k = QLatin1String(key);
            return _mockFacts.contains(k) ? _mockFacts.value(k).toDouble() : cur;
        };
        auto mb = [this](const char *key, bool cur) {
            const auto k = QLatin1String(key);
            return _mockFacts.contains(k) ? _mockFacts.value(k).toBool() : cur;
        };
        batteryPct      = md("batteryPct", batteryPct);
        roll            = md("roll", roll);
        pitch           = md("pitch", pitch);
        altRel          = md("altRel", altRel);
        climbRate       = md("climbRate", climbRate);
        rcRssi          = md("rcRssi", rcRssi);
        sats            = md("sats", sats);
        hdop            = md("hdop", hdop);
        lossPct         = md("lossPct", lossPct);
        staleSec        = md("staleSec", staleSec);
        radioRssiDbm    = md("radioRssiDbm", radioRssiDbm);
        armed           = mb("armed", armed);
        flying          = mb("flying", flying);
        commLost        = mb("commLost", commLost);
        estGoodHorizPos = mb("goodHorizPosRel", estGoodHorizPos);
        estGoodAttitude = mb("goodAttitude", estGoodAttitude);
        estGoodHorizVel = mb("goodHorizVel", estGoodHorizVel);
        estGoodVertVel  = mb("goodVertVel", estGoodVertVel);
        estGpsGlitch    = mb("gpsGlitch", estGpsGlitch);
        estAccelError   = mb("accelError", estAccelError);
        preflightReady  = mb("preflightReady", preflightReady);
        sensorsHealthy  = mb("sensorsHealthy", sensorsHealthy);
        homeValid       = mb("homeValid", homeValid);
        fenceBreach     = mb("fenceBreach", fenceBreach);
    }

    // ------------------------------------------------------------ R1 battery
    {
        QVariantMap detail;
        if (!std::isnan(batteryPct) && batteryPct >= 0.0) {
            detail["pct"] = batteryPct;
            const double crit = threshold("battery-crit-pct");
            const double warn = threshold("battery-warn-pct");
            if (batteryPct <= crit) {
                apply("R1", true, 2, "battery-critical", detail);
            } else if (batteryPct <= warn) {
                apply("R1", true, 1, "battery-low", detail);
            } else {
                apply("R1", false, 0, QString(), detail);
            }
        } else {
            apply("R1", false, 0, QString(), detail);
        }
    }

    // ---------------------------------------------------------------- R2 link
    {
        QVariantMap detail;
        bool active = false;
        int level = 0;
        QString code;
        detail["commLost"] = commLost;
        if (commLost) {
            active = true; level = 2; code = "link-lost";
        } else {
            if (!std::isnan(rcRssi) && rcRssi >= 0.0 && rcRssi < 255.0) {
                detail["rcRssi"] = rcRssi;
                if (rcRssi <= threshold("rssi-crit")) {
                    active = true; level = 2; code = "rc-signal-critical";
                } else if (rcRssi <= threshold("rssi-warn") && !active) {
                    active = true; level = 1; code = "rc-signal-low";
                }
            }
            if (!std::isnan(radioRssiDbm) && radioRssiDbm < 0.0) {
                detail["radioRssiDbm"] = radioRssiDbm;
                if (radioRssiDbm <= threshold("radio-rssi-crit-dbm")) {
                    active = true; level = 2; code = "radio-link-critical";
                } else if (radioRssiDbm <= threshold("radio-rssi-warn-dbm") && !active) {
                    active = true; level = 1; code = "radio-link-low";
                }
            }
        }
        apply("R2", active, level, code, detail);
    }

    // ------------------------------------------------------------ R3 position
    {
        QVariantMap detail;
        bool active = false;
        int level = 0;
        QString code;
        detail["sats"] = sats;
        detail["hdop"] = hdop;
        const bool fixKnown = !std::isnan(sats) && sats > 0.0;
        if (fixKnown) {
            const double minSats = threshold("gps-min-sats");
            const double warnSats = threshold("gps-warn-sats");
            if (sats < minSats) {
                // Red while flying, yellow on the ground.
                active = true; level = (flying || armed) ? 2 : 1; code = "gps-sats-low";
            } else if (sats < warnSats) {
                active = true; level = 1; code = "gps-sats-low";
            }
            if (!std::isnan(hdop) && hdop > 0.0) {
                if (hdop >= threshold("hdop-crit")) {
                    active = true; level = 2; code = "gps-hdop-critical";
                } else if (hdop >= threshold("hdop-warn") && level < 1) {
                    active = true; level = 1; code = "gps-hdop-low";
                }
            }
        }
        apply("R3", active, level, code, detail);
    }

    // ------------------------------------------------------------ R4 estimator
    {
        QVariantMap detail;
        bool active = false;
        int level = 0;
        QString code;
        const bool inAir = flying || armed;
        if (inAir) {
            detail["gpsGlitch"]  = estGpsGlitch;
            detail["accelError"] = estAccelError;
            if (!estGoodHorizPos) {
                active = true; level = 2; code = "estimator-pos-lost";
            } else if (!estGoodAttitude) {
                active = true; level = 1; code = "estimator-attitude";
            } else if (!estGoodHorizVel) {
                active = true; level = 1; code = "estimator-vel-horiz";
            } else if (!estGoodVertVel) {
                active = true; level = 1; code = "estimator-vel-vert";
            } else if (estGpsGlitch) {
                active = true; level = 1; code = "gps-glitch";
            } else if (estAccelError) {
                active = true; level = 1; code = "accel-error";
            }
        }
        apply("R4", active, level, code, detail);
    }

    // ------------------------------------------------------------ R5 attitude
    {
        QVariantMap detail;
        bool active = false;
        int level = 0;
        QString code;
        if (flying) {
            detail["roll"]  = roll;
            detail["pitch"] = pitch;
            const double absRoll  = std::isnan(roll)  ? 0.0 : std::fabs(roll);
            const double absPitch = std::isnan(pitch) ? 0.0 : std::fabs(pitch);
            if (absRoll >= threshold("attitude-hard-deg") || absPitch >= threshold("attitude-hard-deg")) {
                active = true; level = 2; code = "attitude-exceed-critical";
            } else if (absRoll >= threshold("attitude-soft-deg") || absPitch >= threshold("attitude-soft-deg")) {
                active = true; level = 1; code = "attitude-exceed";
            }
        }
        apply("R5", active, level, code, detail);
    }

    // ------------------------------------------------------------ R6 altitude
    {
        QVariantMap detail;
        bool active = false;
        int level = 0;
        QString code;
        if (flying) {
            detail["altRel"]    = altRel;
            detail["climbRate"] = climbRate;
            if (!std::isnan(altRel) && altRel >= threshold("max-altitude-m")) {
                active = true; level = 1; code = "altitude-exceed";
            }
            if (!std::isnan(climbRate)) {
                if (climbRate <= -threshold("descent-crit-m-s")) {
                    active = true; level = 2; code = "descent-critical";
                } else if (climbRate <= -threshold("descent-warn-m-s") && level < 1) {
                    active = true; level = 1; code = "descent-exceed";
                }
            }
        }
        apply("R6", active, level, code, detail);
    }

    // -------------------------------------------------------- R7 mode/failsafe
    {
        QVariantMap detail;
        bool active = false;
        int level = 0;
        QString code;
        detail["mode"] = mode;
        if (flying && !armed) {
            active = true; level = 2; code = "disarm-in-flight";
        } else if (flying && nowMs < _modeChangeFlashUntilMs) {
            active = true; level = 0; code = "mode-changed"; // informational (green)
        }
        apply("R7", active, level, code, detail);
    }

    // ------------------------------------------------------------ R8 geofence
    {
        QVariantMap detail;
        bool active = false;
        int level = 0;
        QString code;
        if (fenceBreach) {
            detail["breachType"] = fenceType;
            active = true; level = 2; code = "fence-breach";
        }
        apply("R8", active, level, code, detail);
    }

    // ---------------------------------------------------------- R9 preflight
    {
        QVariantMap detail;
        bool active = false;
        int level = 0;
        QString code;
        if (!armed) {
            if (!preflightReady) {
                active = true; level = 1; code = "preflight-not-ready";
            }
            if (!sensorsHealthy && level < 1) {
                active = true; level = 1; code = "preflight-sensors";
            }
            if (!std::isnan(batteryPct) && batteryPct > 0.0
                    && batteryPct < threshold("preflight-battery-pct") && level < 1) {
                detail["pct"] = batteryPct;
                active = true; level = 1; code = "preflight-battery";
            }
            if (!std::isnan(sats) && sats > 0.0 && sats < threshold("gps-min-sats") && level < 1) {
                detail["sats"] = sats;
                active = true; level = 1; code = "preflight-gps";
            }
            if (!homeValid && level < 1) {
                active = true; level = 0; code = "preflight-no-home"; // informational
            }
        }
        apply("R9", active, level, code, detail);
    }

    // -------------------------------------------------------------- R10 GCS
    {
        QVariantMap detail;
        bool active = false;
        int level = 0;
        QString code;
        detail["staleSec"] = staleSec;
        detail["lossPct"]  = lossPct;
        if (staleSec >= threshold("data-stale-crit-s")) {
            active = true; level = 2; code = "data-stale-critical";
        } else if (staleSec >= threshold("data-stale-warn-s")) {
            active = true; level = 1; code = "data-stale";
        }
        if (!std::isnan(lossPct) && lossPct >= threshold("loss-pct-warn") && level < 1) {
            active = true; level = 1; code = "link-loss-rate";
        }
        apply("R10", active, level, code, detail);
    }

    if (dirty) {
        _rebuildActiveAlerts();
    } else {
        _rebuildActiveAlerts(); // comparison is cheap and keeps detail fresh
    }
}
