// ============================================================================
// Telemetry snapshot schema v2 (v1 FROZEN field names / units / semantics kept)
//
// Single source of truth for the attitude/telemetry payload consumed by:
//   A) AttitudeView3D.qml  - in-QGC 3D attitude viewer (reads it today)
//   B) external game-style viewers (e.g. a Unity window fed over WS) - Route-B
//      loopback endpoint ws://127.0.0.1:19390/telemetry (implemented here and
//      in TelemetryWsRelay.cc). The non-loopback external bridge is still a
//      separate work item pending an owner ruling.
//
// v2 fields (batch B5 phase 1, append-only - E3 acceptance):
//   - NEW top-level section "gcs": ground-station-side facts (link lost flag,
//     RC RSSI, MAVLink loss rate, message counters). Read-only facts, NOT
//     alerts - alert data must never enter the relay or Unity (E2).
//   - NEW top-level section "derived": values computed from other fields.
//   - Fact resolution is now tolerant of the QGC 5.1.5 fact-group API shape
//     (vehicle.vehicle.* / vehicle.batteries.get(0)) while still supporting
//     the legacy direct-property shape (vehicle.roll / vehicle.battery).
//
// Version policy (xiaoling v9 receipt, E3): additive fields do NOT bump
// schema_version. The route-B Unity client hard-drops any frame whose
// schema_version differs from its expectedSchemaVersion (=1), so the bump
// to 2 broke exactly the consumers E3 promised to keep working.
// schema_version is bumped ONLY on breaking changes (field removed, renamed,
// or semantics changed), coordinated with a Unity client update in the same
// batch.
//
// link_active semantics: false when no vehicle object exists; with a vehicle
// it reflects the real link state (gcs.link_lost), defaulting to true while
// the link state is still unknown.
//
// Rules for external consumers:
//   - All angles are degrees, all distances meters, all speeds m/s.
//   - altitude_rel_m is relative to takeoff (matches HUD), altitude_amsl_m is AMSL.
//   - Fields may be null when the vehicle has not reported them yet; consumers
//     must treat null as "unknown", not as 0.
//   - schema_version is bumped only on breaking changes (see policy above).
//   - attitude_deg.yaw and heading_deg are the SAME source (vehicle heading);
//     both are emitted so consumers can pick either shape. (review 051224Z-3a)
//   - timestamp_ms comes from Date.now(): wall clock, may jump backwards on
//     clock sync. Consumers must NOT use it for ordering; treat it as a
//     freshness hint only. (review 051224Z-3b)
// ============================================================================

.pragma library

var SCHEMA_VERSION = 1

function _num(v) {
    return (typeof v === "number" && isFinite(v)) ? v : null
}

// QGC >= 5.1 moved the attitude/speed facts into the "vehicle" fact group and
// batteries into a list model; older builds exposed them directly on Vehicle.
// Resolve both shapes once per snapshot.
function _factHost(vehicle) {
    return (vehicle && vehicle.vehicle && vehicle.vehicle.roll !== undefined)
            ? vehicle.vehicle   // fact-group shape: FactGroup* "vehicle"
            : vehicle           // legacy shape: Fact* directly on Vehicle
}

function _batteryHost(vehicle) {
    if (!vehicle) {
        return null
    }
    if (vehicle.batteries && vehicle.batteries.count > 0) {
        return vehicle.batteries.get(0)
    }
    return vehicle.battery || null
}

function _factValue(host, name) {
    if (!host) {
        return null
    }
    var f = host[name]
    return (f && f.rawValue !== undefined) ? _num(f.rawValue) : null
}

function snapshot(vehicle) {
    if (!vehicle) {
        return {
            "schema_version": SCHEMA_VERSION,
            "timestamp_ms": Date.now(),
            "vehicle_id": null,
            "link_active": false,
            "attitude_deg": { "roll": null, "pitch": null, "yaw": null },
            "heading_deg": null,
            "position": { "lat_deg": null, "lon_deg": null, "altitude_rel_m": null, "altitude_amsl_m": null },
            "speed": { "ground_m_s": null, "air_m_s": null, "climb_m_s": null },
            "status": { "armed": false, "flying": false, "flight_mode": "", "battery_pct": null, "gps_sats": null },
            "gcs": { "link_lost": null, "rc_rssi": null, "loss_pct": null, "messages_received": null },
            "derived": { "battery_voltage_v": null, "distance_to_home_m": null, "throttle_pct": null }
        }
    }

    var coord = vehicle.coordinate
    var coordValid = coord && coord.isValid

    var veh      = _factHost(vehicle)
    var battery  = _batteryHost(vehicle)
    var gps      = vehicle.gps || null

    var roll  = _factValue(veh, "roll")
    var pitch = _factValue(veh, "pitch")
    var yaw   = _factValue(veh, "heading")

    var altRel = _factValue(veh, "altitudeRelative")
    var dHome  = _factValue(veh, "distanceToHome")

    var linkMgr = vehicle.vehicleLinkManager || null
    var linkLost = (linkMgr && linkMgr.communicationLost !== undefined) ? (linkMgr.communicationLost === true) : null

    return {
        "schema_version": SCHEMA_VERSION,
        "timestamp_ms": Date.now(),
        "vehicle_id": vehicle.id,
        "link_active": (linkLost === null) ? true : !linkLost,
        "attitude_deg": {
            "roll":  roll,
            "pitch": pitch,
            "yaw":   yaw
        },
        "heading_deg": yaw,
        "position": {
            "lat_deg":        coordValid ? coord.latitude  : null,
            "lon_deg":        coordValid ? coord.longitude : null,
            "altitude_rel_m":  altRel,
            "altitude_amsl_m": _factValue(veh, "altitudeAMSL")
        },
        "speed": {
            "ground_m_s": _factValue(veh, "groundSpeed"),
            "air_m_s":    _factValue(veh, "airSpeed"),
            "climb_m_s":  _factValue(veh, "climbRate")
        },
        "status": {
            "armed":       vehicle.armed === true,
            "flying":      vehicle.flying === true,
            "flight_mode": vehicle.flightMode ? vehicle.flightMode : "",
            "battery_pct": _factValue(battery, "percentRemaining"),
            "gps_sats":    _factValue(gps, "count")
        },
        "gcs": {
            "link_lost":          linkLost,
            "rc_rssi":            _factValue(veh, "rcRSSI") === 255.0 ? null : _factValue(veh, "rcRSSI"),
            "loss_pct":           (typeof vehicle.mavlinkLossPercent === "number") ? vehicle.mavlinkLossPercent : null,
            "messages_received":  (typeof vehicle.mavlinkReceivedCount === "number") ? vehicle.mavlinkReceivedCount : null
        },
        "derived": {
            "battery_voltage_v":  _factValue(battery, "voltage"),
            "distance_to_home_m": dHome,
            "throttle_pct":       _factValue(veh, "throttlePct")
        }
    }
}
