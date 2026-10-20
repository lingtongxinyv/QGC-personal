// ============================================================================
// AlertText.js - shared Chinese wording layer for the local alert engine.
//
// The C++ AlertEngine emits ASCII codes only (MSVC code page 936); this library
// maps {ruleId, level, code, detail} payloads to user-facing text. Imported by
// both AssistantPanel.qml (banner / history / settings) and AttitudeView3D.qml
// (HUD inline alerts) so the wording lives in exactly one place (acceptance B1:
// identical text in HUD, banner and history).
//
// Levels: 0 = info(green) 1 = warn(yellow) 2 = critical(red).
// ============================================================================

.pragma library

var GREEN  = "#4caf50"
var YELLOW = "#ffd479"
var RED    = "#ff5252"

var LEVEL_COLORS = [GREEN, YELLOW, RED]

function levelColor(level) {
    return (level >= 0 && level < LEVEL_COLORS.length) ? LEVEL_COLORS[level] : GREEN
}

function levelLabel(level) {
    if (level === 2) return "严重"
    if (level === 1) return "警告"
    return "提示"
}

function dnum(detail, key, digits) {
    var v = detail ? detail[key] : undefined
    return (typeof v === "number" && isFinite(v)) ? Number(v).toFixed(digits === undefined ? 1 : digits) : "?"
}

function text(alert) {
    if (!alert) {
        return ""
    }
    var code = alert.code
    var d = alert.detail
    switch (code) {
    case "battery-low":             return "电量低（" + dnum(d, "pct", 0) + "%）"
    case "battery-critical":        return "电量严重不足（" + dnum(d, "pct", 0) + "%）"
    case "link-lost":               return "数传链路丢失"
    case "rc-signal-low":           return "遥控信号弱（" + dnum(d, "rcRssi", 0) + "%）"
    case "rc-signal-critical":      return "遥控信号临界（" + dnum(d, "rcRssi", 0) + "%）"
    case "radio-link-low":          return "数传电台信号弱（" + dnum(d, "radioRssiDbm", 0) + " dBm）"
    case "radio-link-critical":     return "数传电台信号临界（" + dnum(d, "radioRssiDbm", 0) + " dBm）"
    case "gps-sats-low":            return "卫星数不足（" + dnum(d, "sats", 0) + " 颗）"
    case "gps-hdop-low":            return "定位精度下降（HDOP " + dnum(d, "hdop") + "）"
    case "gps-hdop-critical":       return "定位精度临界（HDOP " + dnum(d, "hdop") + "）"
    case "estimator-attitude":      return "姿态估计置信度下降"
    case "estimator-vel-horiz":     return "水平速度估计置信度下降"
    case "estimator-vel-vert":      return "垂直速度估计置信度下降"
    case "estimator-pos-lost":      return "位置估计丢失"
    case "gps-glitch":              return "GPS 信号异常"
    case "accel-error":             return "加速度计异常"
    case "attitude-exceed":         return "姿态超限（横滚 " + dnum(d, "roll") + "° 俯仰 " + dnum(d, "pitch") + "°）"
    case "attitude-exceed-critical":return "姿态严重超限（横滚 " + dnum(d, "roll") + "° 俯仰 " + dnum(d, "pitch") + "°）"
    case "altitude-exceed":         return "高度超过上限（" + dnum(d, "altRel") + " m）"
    case "descent-exceed":          return "下降率过大（" + dnum(d, "climbRate") + " m/s）"
    case "descent-critical":        return "下降率严重过大（" + dnum(d, "climbRate") + " m/s）"
    case "disarm-in-flight":        return "飞行中检测到上锁状态"
    case "mode-changed":            return "飞行模式已切换：" + (d && d.mode ? d.mode : "?")
    case "fence-breach":            return "围栏越界（类型 " + (d && d.breachType !== undefined ? d.breachType : "?") + "）"
    case "preflight-not-ready":     return "飞行前检查未通过"
    case "preflight-sensors":       return "存在不健康传感器"
    case "preflight-battery":       return "电量低于起飞阈值（" + dnum(d, "pct", 0) + "%）"
    case "preflight-gps":           return "卫星数不足起飞条件（" + dnum(d, "sats", 0) + " 颗）"
    case "preflight-no-home":       return "尚未记录 Home 点"
    case "data-stale":              return "遥测数据延迟（" + dnum(d, "staleSec") + " 秒）"
    case "data-stale-critical":     return "遥测数据中断（" + dnum(d, "staleSec") + " 秒）"
    case "link-loss-rate":          return "链路丢包率过高（" + dnum(d, "lossPct", 0) + "%）"
    default:                        return code ? String(code) : ""
    }
}

function ruleName(ruleId) {
    switch (ruleId) {
    case "R1":  return "电池"
    case "R2":  return "链路"
    case "R3":  return "定位"
    case "R4":  return "估计器"
    case "R5":  return "姿态"
    case "R6":  return "高度"
    case "R7":  return "模式"
    case "R8":  return "围栏"
    case "R9":  return "起飞前"
    case "R10": return "地面站"
    default:    return ruleId ? String(ruleId) : ""
    }
}

function timeString(ms) {
    if (typeof ms !== "number" || ms <= 0) {
        return "--:--:--"
    }
    return new Date(ms).toLocaleTimeString(Qt.locale(), "HH:mm:ss")
}
