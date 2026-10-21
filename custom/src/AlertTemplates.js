// ============================================================================
// AlertTemplates.js - local (offline) narration templates for batch B5 phase 2
//
// Used when the local DSH is unreachable (status "offline") or the model reply
// cannot be used. One template per AlertEngine rule code; every text is
// read-only advice and never contains a vehicle-write instruction.
//
// Import as a plain JS library:
//   import "AlertTemplates.js" as AlertTemplates
//
// API:
//   template(ruleId, code, detail) -> { conclusion, steps, risk, targetId }
// ============================================================================

.pragma library

function _fmt(v, digits) {
    if (v === null || v === undefined || isNaN(v)) {
        return "?"
    }
    return Number(v).toFixed(digits === undefined ? 0 : digits)
}

var TABLE = {
    "battery-critical": {
        conclusion: "电池电量仅 %1%，已低于严重阈值。",
        steps: ["立即规划最短返航路线", "避免大油门爬升与急机动", "到达起降点后尽快降落"],
        risk: "电量继续下降可能触发飞控失控保护，导致强制降落。",
        targetId: "panel.alertSettings"
    },
    "battery-low": {
        conclusion: "电池电量 %1%，已低于告警阈值。",
        steps: ["缩短剩余航程，尽早返航", "降低高度与机动幅度以节省电量"],
        risk: "若继续消耗，可能提前触发低电返航。",
        targetId: "panel.alertSettings"
    },
    "link-lost": {
        conclusion: "与飞控的通信当前已中断。",
        steps: ["检查数传/USB 连接与天线是否松动", "确认串口或网络端口未被其他程序占用", "等待链路恢复，不要反复插拔"],
        risk: "失联期间载具按飞控自身的失控保护策略动作。",
        targetId: "page.settings.link"
    },
    "rc-signal-critical": {
        conclusion: "遥控信号强度仅 %1%，已接近丢失。",
        steps: ["拉近与载具的距离", "抬高遥控器天线并避开遮挡", "准备让飞控进入自动返航"],
        risk: "遥控完全丢失会触发飞控失控保护。",
        targetId: "panel.alertSettings"
    },
    "rc-signal-low": {
        conclusion: "遥控信号偏弱（%1%）。",
        steps: ["检查天线朝向与遮挡", "保持视距内飞行"],
        risk: "距离继续增加可能失去遥控。",
        targetId: "panel.alertSettings"
    },
    "radio-link-critical": {
        conclusion: "数传信号 %1 dBm，链路处于临界状态。",
        steps: ["缩短距离或改用高增益天线", "避免地形与建筑遮挡"],
        risk: "遥测中断后地面站将失去实时状态。",
        targetId: "panel.alertSettings"
    },
    "radio-link-low": {
        conclusion: "数传信号偏弱（%1 dBm）。",
        steps: ["检查天线连接", "保持视距飞行"],
        risk: "继续远离可能丢失遥测。",
        targetId: "panel.alertSettings"
    },
    "gps-sats-low": {
        conclusion: "可见卫星仅 %1 颗，定位质量不足。",
        steps: ["等待卫星数回升后再起飞", "已起飞则降低机动幅度", "避开遮挡与室内环境"],
        risk: "定位漂移会影响定高与定点保持。",
        targetId: "page.settings.gps"
    },
    "gps-hdop-critical": {
        conclusion: "HDOP %1，水平定位精度很差。",
        steps: ["暂停依赖定位的飞行模式", "等待 HDOP 回落", "必要时切换目视手动控制"],
        risk: "定位误差扩大可能导致位置漂移。",
        targetId: "page.settings.gps"
    },
    "gps-hdop-low": {
        conclusion: "HDOP %1，水平定位精度下降。",
        steps: ["降低机动幅度", "观察卫星数变化"],
        risk: "精度继续变差会影响定点与返航。",
        targetId: "page.settings.gps"
    },
    "estimator-pos-lost": {
        conclusion: "位置估计已失效。",
        steps: ["切换目视手动控制并保持悬停", "检查 GPS 与光流状态", "准备就近降落"],
        risk: "位置估计丢失会导致载具漂移。",
        targetId: "page.settings.ekf"
    },
    "estimator-attitude": {
        conclusion: "姿态估计质量下降。",
        steps: ["减小机动幅度", "观察姿态是否抖动", "准备降落检查"],
        risk: "姿态估计异常可能导致控制发散。",
        targetId: "page.settings.ekf"
    },
    "estimator-vel-horiz": {
        conclusion: "水平速度估计异常。",
        steps: ["降低水平速度", "避免急转弯"],
        risk: "速度估计异常会影响刹车与定点。",
        targetId: "page.settings.ekf"
    },
    "estimator-vel-vert": {
        conclusion: "垂直速度估计异常。",
        steps: ["保持定高，避免快速升降", "观察高度是否漂移"],
        risk: "垂直速度异常会影响定高与降落。",
        targetId: "page.settings.ekf"
    },
    "gps-glitch": {
        conclusion: "检测到 GPS 信号跳变。",
        steps: ["降低对 GPS 定位的依赖", "观察卫星数与 HDOP 是否恢复"],
        risk: "跳变可能引起位置突跳。",
        targetId: "page.settings.gps"
    },
    "accel-error": {
        conclusion: "加速度计报告异常。",
        steps: ["减小机动", "尽快降落并进行传感器检查"],
        risk: "加速度计异常会影响姿态控制。",
        targetId: "page.settings.sensors"
    },
    "attitude-exceed-critical": {
        conclusion: "姿态角超限：横滚 %1°，俯仰 %2°。",
        steps: ["立即减小坡度与俯仰", "恢复平稳姿态", "检查是否遭遇强风"],
        risk: "持续大姿态可能导致失控或失速。",
        targetId: "view.fly"
    },
    "attitude-exceed": {
        conclusion: "姿态角偏大：横滚 %1°，俯仰 %2°。",
        steps: ["减小机动幅度", "观察风况"],
        risk: "姿态继续增大可能进入危险区。",
        targetId: "view.fly"
    },
    "altitude-exceed": {
        conclusion: "相对高度 %1 m 已超过设定上限。",
        steps: ["降低高度回到限制内", "确认高度上限设置是否符合预期"],
        risk: "超高飞行可能违反空域限制。",
        targetId: "panel.alertSettings"
    },
    "descent-critical": {
        conclusion: "下降率 %1 m/s，下降过快。",
        steps: ["立即减小下降速度", "检查是否误操作或动力异常"],
        risk: "过快下降可能导致硬着陆。",
        targetId: "view.fly"
    },
    "descent-exceed": {
        conclusion: "下降率偏大（%1 m/s）。",
        steps: ["适当减小下降速度", "保留改出高度"],
        risk: "持续快速下降会压缩改出余量。",
        targetId: "view.fly"
    },
    "disarm-in-flight": {
        conclusion: "飞行中检测到未解锁状态，状态异常。",
        steps: ["核实载具是否真的在空中", "必要时接管手动控制", "检查解锁状态与遥控通道"],
        risk: "状态不一致时飞控可能拒绝控制输入。",
        targetId: "view.fly"
    },
    "fence-breach": {
        conclusion: "载具已触发地理围栏边界。",
        steps: ["操控载具返回围栏内", "确认围栏半径与返航点设置"],
        risk: "围栏触发后飞控可能执行自动返航或降落。",
        targetId: "page.plan.fence"
    },
    "preflight-not-ready": {
        conclusion: "起飞前检查未通过。",
        steps: ["查看飞控自检项并逐条排除", "确认无未解除的告警后再起飞"],
        risk: "带故障起飞风险很高。",
        targetId: "page.settings"
    },
    "preflight-sensors": {
        conclusion: "传感器健康检查未通过。",
        steps: ["检查各传感器状态", "必要时重新校准", "未恢复前不要起飞"],
        risk: "传感器异常会直接影响姿态与位置控制。",
        targetId: "page.settings.sensors"
    },
    "preflight-battery": {
        conclusion: "起飞前电量仅 %1%，低于建议值。",
        steps: ["更换或充满电池", "确认电池健康度"],
        risk: "低电量起飞会显著缩短可用航时。",
        targetId: "panel.alertSettings"
    },
    "preflight-gps": {
        conclusion: "起飞前卫星数不足（%1 颗）。",
        steps: ["等待卫星锁定", "到开阔处再起飞"],
        risk: "定位不足时无法可靠执行定点与返航。",
        targetId: "page.settings.gps"
    },
    "preflight-no-home": {
        conclusion: "尚未设置返航点。",
        steps: ["确认返航点位置", "起飞前完成返航点设置"],
        risk: "无返航点时失控保护无法执行返航。",
        targetId: "view.fly"
    },
    "data-stale-critical": {
        conclusion: "遥测已停滞 %1 秒，数据不再实时。",
        steps: ["检查链路与地面站进程", "不要依据旧数据判断载具状态"],
        risk: "界面数值可能已严重滞后。",
        targetId: "panel.alertSettings"
    },
    "data-stale": {
        conclusion: "遥测更新缓慢（%1 秒未更新）。",
        steps: ["检查链路质量", "观察是否恢复"],
        risk: "数据滞后会误导判断。",
        targetId: "panel.alertSettings"
    },
    "link-loss-rate": {
        conclusion: "遥测丢包率 %1%。",
        steps: ["检查链路干扰与距离", "必要时降低数据速率"],
        risk: "持续丢包会演变为链路中断。",
        targetId: "panel.alertSettings"
    }
}

var RULE_FALLBACK = {
    "R1": "电池状态异常，请核对电量并规划返航。",
    "R2": "链路状态异常，请检查数传与遥控。",
    "R3": "定位状态异常，请核对卫星数与 HDOP。",
    "R4": "状态估计异常，请减小机动并准备降落。",
    "R5": "姿态异常，请减小机动幅度。",
    "R6": "高度/升降异常，请核对当前高度与下降率。",
    "R7": "飞行模式状态异常，请核对当前模式。",
    "R8": "地理围栏状态异常，请返回围栏内。",
    "R9": "起飞前检查未通过，请逐项排除。",
    "R10": "地面站数据链路异常，请检查连接。"
}

function template(ruleId, code, detail) {
    var d = detail || {}
    var t = TABLE[code]
    if (!t) {
        return {
            conclusion: RULE_FALLBACK[ruleId] || "检测到异常，请核对当前状态。",
            steps: ["检查相关状态与设置", "状态恢复前保持谨慎操作"],
            risk: "",
            targetId: ""
        }
    }

    // Per-code argument order used by the table above.
    var args
    switch (code) {
    case "attitude-exceed-critical":
    case "attitude-exceed":
        args = [_fmt(d.roll, 0), _fmt(d.pitch, 0)]
        break
    case "rc-signal-critical":
    case "rc-signal-low":
        args = [_fmt(d.rcRssi, 0)]
        break
    case "radio-link-critical":
    case "radio-link-low":
        args = [_fmt(d.radioRssiDbm, 0)]
        break
    case "gps-sats-low":
    case "preflight-gps":
        args = [_fmt(d.sats, 0)]
        break
    case "gps-hdop-critical":
    case "gps-hdop-low":
        args = [_fmt(d.hdop, 1)]
        break
    case "altitude-exceed":
        args = [_fmt(d.altRel, 0)]
        break
    case "descent-critical":
    case "descent-exceed":
        args = [_fmt(d.climbRate, 1)]
        break
    case "battery-critical":
    case "battery-low":
    case "preflight-battery":
        args = [_fmt(d.pct, 0)]
        break
    case "data-stale-critical":
    case "data-stale":
        args = [_fmt(d.staleSec, 0)]
        break
    case "link-loss-rate":
        args = [_fmt(d.lossPct, 1)]
        break
    default:
        args = []
    }

    var conclusion = t.conclusion
    for (var i = 0; i < args.length; ++i) {
        conclusion = conclusion.replace("%" + (i + 1), args[i])
    }
    return {
        conclusion: conclusion,
        steps: t.steps.slice(0),
        risk: t.risk,
        targetId: t.targetId || ""
    }
}
