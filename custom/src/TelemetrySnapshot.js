// ============================================================================
// Telemetry snapshot schema v1 (FROZEN field names / units / semantics)
//
// Single source of truth for the attitude/telemetry payload consumed by:
//   A) AttitudeView3D.qml  - in-QGC 3D attitude viewer (reads it today)
//   B) external game-style viewers (e.g. a Unity window fed over WS) - future
//      extension point. The WS broadcast endpoint itself is NOT approved yet
//      (separate sign-off required, same class as batch-B work); this file only
//      freezes the payload schema so that future endpoint needs no redesign.
//
// Rules for external consumers:
//   - All angles are degrees, all distances meters, all speeds m/s.
//   - altitude_rel_m is relative to takeoff (matches HUD), altitude_amsl_m is AMSL.
//   - Fields may be null when the vehicle has not reported them yet; consumers
//     must treat null as "unknown", not as 0.
//   - schema_version is bumped only on breaking changes.
//   - attitude_deg.yaw and heading_deg are the SAME source (vehicle.heading);
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
            "status": { "armed": false, "flying": false, "flight_mode": "", "battery_pct": null, "gps_sats": null }
        }
    }

    var coord = vehicle.coordinate
    var coordValid = coord && coord.isValid

    return {
        "schema_version": SCHEMA_VERSION,
        "timestamp_ms": Date.now(),
        "vehicle_id": vehicle.id,
        "link_active": true,
        "attitude_deg": {
                "roll":  _num(vehicle.roll.rawValue),
                "pitch": _num(vehicle.pitch.rawValue),
                "yaw":   _num(vehicle.heading.rawValue)
            },
            "heading_deg": _num(vehicle.heading.rawValue),
        "position": {
            "lat_deg":        coordValid ? coord.latitude  : null,
            "lon_deg":        coordValid ? coord.longitude : null,
            "altitude_rel_m":  _num(vehicle.altitudeRelative.rawValue),
            "altitude_amsl_m": _num(vehicle.altitudeAMSL.rawValue)
        },
        "speed": {
            "ground_m_s": _num(vehicle.groundSpeed.rawValue),
            "air_m_s":    _num(vehicle.airSpeed.rawValue),
            "climb_m_s":  _num(vehicle.climbRate.rawValue)
        },
        "status": {
            "armed":       vehicle.armed === true,
            "flying":      vehicle.flying === true,
            "flight_mode": vehicle.flightMode ? vehicle.flightMode : "",
            "battery_pct": _num(vehicle.battery.percentRemaining.rawValue),
            "gps_sats":    _num(vehicle.gps.count.rawValue)
        }
    }
}
