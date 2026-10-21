import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

import QGroundControl
import QGroundControl.Controls

import "AlertText.js" as AlertText
import "AlertTemplates.js" as AlertTemplates

/// Right side dock of the Fly view: read-only Chinese chat with the local DSH
/// PX4 assistant (persona 小云, preset px4-ta). Backed by the `px4Assistant`
/// context property injected in CustomPlugin::createQmlApplicationEngine.
///
/// Channel contract: coord/design/px4-chat-http.md
Rectangle {
    id: root

    property var parentToolInsets
    property var mapControl

    /// Open (full chat) vs collapsed (vertical tab on the right edge).
    property bool open: true

    readonly property real _margin: ScreenTools.defaultFontPixelWidth * 0.5
    readonly property real _openWidth: ScreenTools.defaultFontPixelWidth * 34
    readonly property real _closedWidth: ScreenTools.defaultFontPixelHeight * 1.6

    /// Distance from the right edge occupied by this panel (map recentering inset).
    readonly property real rightEdgeCenterInset: visible ? parent.width - x : 0

    width: open ? _openWidth : _closedWidth
    color: qgcPal.windowShade

    /// Chat is usable unless the health probe hard-failed. A preset mismatch is only a
    /// warning: the server never validates the preset itself (local-dsh, 20261020T034816Z).
    readonly property bool _ready: px4Assistant.healthState === "ok" || px4Assistant.healthState === "warn"

    readonly property string healthSummary: {
        switch (px4Assistant.healthState) {
        case "ok":   return qsTr("本机 DSH 在线 · %1").arg(_healthDetailText)
        case "warn": return qsTr("本机 DSH 在线 · 警告：%1").arg(_healthDetailText)
        case "fail": return qsTr("本机 DSH 未就绪 · %1").arg(_healthDetailText)
        default:     return qsTr("正在探测本机 DSH…")
        }
    }

    // C++ side keeps messages ASCII (MSVC 936 code page); map them to Chinese here.
    readonly property string _healthDetailText: {
        var detail = px4Assistant.healthDetail
        switch (detail) {
        case "non-JSON response": return qsTr("健康检查返回了非 JSON 内容")
        case "ok=false":          return qsTr("健康检查报告 ok=false")
        case "no /px4-agent route (older DSH build or panel not loaded)":
            return qsTr("/px4-agent 路由不存在（DSH 版本过旧或 panel 未加载），重启 DSH 后生效")
        }
        if (detail.indexOf("preset=") === 0) {
            return qsTr("preset 异常（%1）").arg(detail)
        }
        return detail
    }

    function _errorText(code, message) {
        switch (code) {
        case "px4/no-token":              return qsTr("未找到 panel-token，请确认本机 DSH 已启动")
        case "px4/unauthorized":          return qsTr("面板 token 无效：拿到的可能是另一个 DSH 实例的 token（见 PX4_AGENT_TOKEN_FILE）")
        case "px4/method":                return qsTr("请求方法不被接受")
        case "px4/bad-origin":            return qsTr("请求来源被拒绝（Origin 非回环）")
        case "px4/content-type":          return qsTr("请求 Content-Type 不被接受")
        case "px4/body-too-large":        return qsTr("提问过长，超过 64 KB 上限")
        case "px4/bad-json":              return qsTr("请求体不是合法 JSON")
        case "px4/bad-text":              return qsTr("提问长度需在 1~8000 字符之间")
        case "px4/session-busy":          return qsTr("该会话已有请求在处理中")
        case "px4/preset-missing":        return qsTr("本机 DSH 未注册 px4-ta preset")
        case "px4/no-session-controller": return qsTr("当前 DSH profile 没有会话能力")
        case "px4/timeout":               return qsTr("本轮对话超时（超过 10 分钟）")
        case "px4/upstream":              return qsTr("DSH 上游出错：%1").arg(message)
        default:                          return message !== "" ? qsTr("%1 [%2]").arg(message).arg(code) : code
        }
    }

    // ------------------------------------------------------------------
    // Alert rule engine (local, read-only). The C++ engine emits ASCII codes;
    // the shared AlertText.js library owns all Chinese wording so the banner,
    // the history list and the 3D HUD stay word-for-word identical (B1).
    // ------------------------------------------------------------------
    readonly property color _alertGreen:  AlertText.GREEN
    readonly property color _alertYellow: AlertText.YELLOW
    readonly property color _alertRed:    AlertText.RED
    readonly property color _alertGrey:   qgcPal.colorGrey

    property bool alertHistoryOpen: false
    property bool alertSettingsOpen: false

    readonly property var _alertLevelColor: AlertText.LEVEL_COLORS

    function _alertText(alert)     { return AlertText.text(alert) }
    function _ruleName(ruleId)     { return AlertText.ruleName(ruleId) }
    function _alertTimeString(ms)  { return AlertText.timeString(ms) }

    // Threshold settings UI descriptors (key -> Chinese label + unit).
    readonly property var _thresholdDescriptors: [
        { key: "battery-warn-pct",        label: qsTr("电量警告"),          unit: "%",    dec: 0 },
        { key: "battery-crit-pct",        label: qsTr("电量严重"),          unit: "%",    dec: 0 },
        { key: "preflight-battery-pct",   label: qsTr("起飞电量下限"),      unit: "%",    dec: 0 },
        { key: "rssi-warn",               label: qsTr("遥控信号警告"),      unit: "%",    dec: 0 },
        { key: "rssi-crit",               label: qsTr("遥控信号临界"),      unit: "%",    dec: 0 },
        { key: "radio-rssi-warn-dbm",     label: qsTr("电台信号警告"),      unit: "dBm",  dec: 0 },
        { key: "radio-rssi-crit-dbm",     label: qsTr("电台信号临界"),      unit: "dBm",  dec: 0 },
        { key: "gps-warn-sats",           label: qsTr("卫星数警告"),        unit: qsTr("颗"), dec: 0 },
        { key: "gps-min-sats",            label: qsTr("最少卫星数"),        unit: qsTr("颗"), dec: 0 },
        { key: "hdop-warn",               label: qsTr("HDOP 警告"),         unit: "",     dec: 1 },
        { key: "hdop-crit",               label: qsTr("HDOP 临界"),         unit: "",     dec: 1 },
        { key: "attitude-soft-deg",       label: qsTr("姿态警告角"),        unit: "°",    dec: 0 },
        { key: "attitude-hard-deg",       label: qsTr("姿态临界角"),        unit: "°",    dec: 0 },
        { key: "max-altitude-m",          label: qsTr("最大高度"),          unit: "m",    dec: 0 },
        { key: "descent-warn-m-s",        label: qsTr("下降率警告"),        unit: "m/s",  dec: 1 },
        { key: "descent-crit-m-s",        label: qsTr("下降率临界"),        unit: "m/s",  dec: 1 },
        { key: "data-stale-warn-s",       label: qsTr("数据延迟警告"),      unit: "s",    dec: 1 },
        { key: "data-stale-crit-s",       label: qsTr("数据中断临界"),      unit: "s",    dec: 1 },
        { key: "loss-pct-warn",           label: qsTr("丢包率警告"),        unit: "%",    dec: 0 },
        { key: "cooldown-sec",            label: qsTr("告警冷却窗口"),      unit: "s",    dec: 0 }
    ]

    readonly property var _ruleIds: [ "R1", "R2", "R3", "R4", "R5", "R6", "R7", "R8", "R9", "R10" ]

    // Banner state: engine off -> grey explicit; no vehicle -> grey idle;
    // otherwise the highest-level active alert drives the color.
    readonly property var    _activeAlerts:  customAlertEngine.activeAlerts
    readonly property string _alertEngineState: customAlertEngine.state
    readonly property bool   _hasVehicle: QGroundControl.multiVehicleManager.activeVehicle !== null
    readonly property var    _topAlert: _alertEngineState === "ok" && _activeAlerts.length > 0 ? _activeAlerts[0] : null
    readonly property color  _bannerColor: !_hasVehicle || _alertEngineState !== "ok" ? _alertGrey
                                         : _alertLevelColor[_topAlert.level]

    // ------------------------------------------------------------------
    // Phase-2 auto narration (read-only). The C++ AlertNarrator sends one
    // turn per alert burst and returns a structured narrative; when the
    // local DSH is unreachable the same card renders AlertTemplates.js.
    // ------------------------------------------------------------------
    readonly property var    _narration:        px4AlertNarrator.narrative
    readonly property string _narrationStatus:  px4AlertNarrator.status
    readonly property bool   _narrationVisible: px4AlertNarrator.enabled
                                                && _narrationStatus !== "idle"
                                                && _narrationStatus !== "disabled"
                                                && _narration.ruleId !== undefined
    readonly property var    _narrationView: {
        if (!_narrationVisible || !_narration.ruleId) {
            return null
        }
        if (_narrationStatus === "ready" && _narration.source !== "template") {
            return {
                conclusion: _narration.conclusion || "",
                steps:      _narration.steps || [],
                risk:       _narration.risk || "",
                level:      _narration.level,
                source:     _narration.source
            }
        }
        var tpl = AlertTemplates.template(_narration.ruleId, _narration.code, _narration.detail)
        return {
            conclusion: tpl.conclusion,
            steps:      tpl.steps,
            risk:       tpl.risk,
            level:      _narration.level,
            source:     "template"
        }
    }
    readonly property string _narrationStatusText: {
        switch (_narrationStatus) {
        case "requesting": return qsTr("正在解读…")
        case "ready":      return _narration.source === "auto"
                                  ? qsTr("来自本机 DSH")
                                  : qsTr("非结构化回复，已按原文显示")
        case "offline":    return qsTr("DSH 不在线 · 使用本地建议")
        case "error":      return qsTr("解读失败 · 使用本地建议")
        default:           return ""
        }
    }

    ListModel { id: _messages }

    function _contextHint() {
        var hint = { qgc: "5.1.5" }
        var vehicle = QGroundControl.multiVehicleManager.activeVehicle
        if (vehicle) {
            hint.vehicle = { sysid: vehicle.id }
        }
        return hint
    }

    function _append(kind, text) {
        _messages.append({ kind: kind, text: text })
    }

    /// Appends a streaming chunk to the trailing message when it has the same kind.
    function _appendDelta(kind, text) {
        if (_messages.count > 0 && _messages.get(_messages.count - 1).kind === kind) {
            var last = _messages.get(_messages.count - 1)
            _messages.setProperty(_messages.count - 1, "text", last.text + text)
        } else {
            _append(kind, text)
        }
    }

    function _send() {
        var text = inputField.text.trim()
        if (text === "" || px4Assistant.busy) {
            return
        }
        _append("user", text)
        inputField.text = ""
        px4Assistant.sendChat(text, _contextHint())
    }

    Shortcut {
        sequence: "Ctrl+Shift+A"
        context: Qt.ApplicationShortcut
        onActivated: root.open = !root.open
    }

    // ------------------------------------------------------------------
    // Collapsed tab
    // ------------------------------------------------------------------
    Rectangle {
        anchors.fill: parent
        visible: !root.open
        color: qgcPal.windowShadeDark

        QGCLabel {
            anchors.centerIn: parent
            rotation: -90
            text: qsTr("小云 · PX4 助教")
            color: qgcPal.text
        }

        QGCMouseArea {
            anchors.fill: parent
            onClicked: root.open = true
        }
    }

    // ------------------------------------------------------------------
    // Expanded chat
    // ------------------------------------------------------------------
    ColumnLayout {
        anchors.fill: parent
        anchors.margins: _margin
        spacing: _margin
        visible: root.open

        RowLayout {
            Layout.fillWidth: true
            spacing: _margin

            Rectangle {
                Layout.preferredWidth:  ScreenTools.defaultFontPixelHeight * 0.6
                Layout.preferredHeight: Layout.preferredWidth
                radius:                 width * 0.5
                color:                  px4Assistant.healthState === "ok"   ? qgcPal.colorGreen
                                      : px4Assistant.healthState === "warn" ? qgcPal.colorOrange
                                      : qgcPal.colorRed
            }

            ColumnLayout {
                Layout.fillWidth: true
                spacing: 0

                QGCLabel {
                    Layout.fillWidth: true
                    text:       qsTr("小云 · PX4 助教")
                    font.bold:  true
                    color:      qgcPal.text
                }

                QGCLabel {
                    Layout.fillWidth: true
                    text:           root.healthSummary
                    font.pointSize: ScreenTools.smallFontPointSize
                    color:          qgcPal.colorGrey
                    elide:          Text.ElideRight
                }
            }

            QGCButton {
                text:       qsTr("收起")
                onClicked:  root.open = false
            }
        }

        // ------------------------------------------------------------------
        // Alert banner (local rule engine, read-only). Highest-level active
        // alert first; grey = engine disabled or no vehicle (explicit states,
        // never a stale alert). Click toggles the history list.
        // ------------------------------------------------------------------
        Rectangle {
            Layout.fillWidth: true
            implicitHeight: alertBannerText.implicitHeight + root._margin * 1.6
            radius: ScreenTools.defaultBorderRadius
            color: root._bannerColor
            opacity: root._alertEngineState === "ok" ? 1.0 : 0.45

            QGCLabel {
                id: alertBannerText
                anchors.left: parent.left
                anchors.top: parent.top
                anchors.bottom: parent.bottom
                anchors.right: alertToggles.left
                anchors.margins: root._margin * 0.8
                wrapMode: Text.WordWrap
                font.pointSize: ScreenTools.smallFontPointSize
                color: root._alertEngineState === "ok" && root._topAlert ? "#1a1a1a" : qgcPal.text
                text: {
                    if (root._alertEngineState !== "ok") {
                        return qsTr("告警引擎已停用")
                    }
                    if (!root._hasVehicle) {
                        return qsTr("未连接载具 · 告警引擎待机")
                    }
                    if (!root._topAlert) {
                        return qsTr("系统正常 · 无告警")
                    }
                    var text = qsTr("[%1] %2").arg(root._ruleName(root._topAlert.ruleId))
                                               .arg(root._alertText(root._topAlert))
                    if (root._activeAlerts.length > 1) {
                        text += qsTr("　（另有 %1 条）").arg(root._activeAlerts.length - 1)
                    }
                    return text
                }
            }

            RowLayout {
                id: alertToggles
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.rightMargin: root._margin * 0.8
                spacing: root._margin

                QGCLabel {
                    text: qsTr("历史")
                    font.pointSize: ScreenTools.smallFontPointSize
                    color: root.alertHistoryOpen ? "#1a1a1a" : qgcPal.text

                    QGCMouseArea {
                        anchors.fill: parent
                        onClicked: root.alertHistoryOpen = !root.alertHistoryOpen
                    }
                }

                QGCLabel {
                    text: qsTr("设置")
                    font.pointSize: ScreenTools.smallFontPointSize
                    color: root.alertSettingsOpen ? "#1a1a1a" : qgcPal.text

                    QGCMouseArea {
                        anchors.fill: parent
                        onClicked: root.alertSettingsOpen = !root.alertSettingsOpen
                    }
                }
            }
        }

        // ------------------------------------------------------------------
        // Phase-2 narration card: conclusion + steps + risk, all read-only.
        // Rendered from the DSH reply when available, otherwise from the
        // matching local template so guidance never disappears offline.
        // ------------------------------------------------------------------
        Rectangle {
            Layout.fillWidth: true
            visible: root._narrationVisible
            implicitHeight: narrationColumn.implicitHeight + root._margin * 1.6
            radius: ScreenTools.defaultBorderRadius
            color: qgcPal.windowShadeDark
            border.width: 1
            border.color: {
                if (!root._narrationView) return qgcPal.text
                if (root._narrationView.level >= 2) return root._alertRed
                if (root._narrationView.level === 1) return root._alertYellow
                return qgcPal.text
            }

            ColumnLayout {
                id: narrationColumn
                anchors.fill: parent
                anchors.margins: root._margin * 0.8
                spacing: root._margin * 0.5

                RowLayout {
                    Layout.fillWidth: true
                    spacing: root._margin

                    QGCLabel {
                        text: qsTr("小云解读")
                        font.bold: true
                        font.pointSize: ScreenTools.smallFontPointSize
                        color: qgcPal.text
                    }

                    QGCLabel {
                        Layout.fillWidth: true
                        text: root._narrationStatusText
                        font.pointSize: ScreenTools.smallFontPointSize
                        color: qgcPal.colorGrey
                        elide: Text.ElideRight
                    }

                    QGCLabel {
                        text: qsTr("重解")
                        font.pointSize: ScreenTools.smallFontPointSize
                        color: qgcPal.text
                        visible: root._narrationStatus === "ready"
                                 || root._narrationStatus === "offline"
                                 || root._narrationStatus === "error"

                        QGCMouseArea {
                            anchors.fill: parent
                            onClicked: px4AlertNarrator.refresh()
                        }
                    }

                    QGCLabel {
                        text: qsTr("收起")
                        font.pointSize: ScreenTools.smallFontPointSize
                        color: qgcPal.text

                        QGCMouseArea {
                            anchors.fill: parent
                            onClicked: px4AlertNarrator.dismiss()
                        }
                    }
                }

                QGCLabel {
                    Layout.fillWidth: true
                    wrapMode: Text.WordWrap
                    text: root._narrationView ? root._narrationView.conclusion : ""
                    font.bold: true
                    color: qgcPal.text
                }

                Column {
                    Layout.fillWidth: true
                    spacing: root._margin * 0.3
                    visible: root._narrationView && root._narrationView.steps.length > 0

                    Repeater {
                        model: root._narrationView ? root._narrationView.steps : []

                        QGCLabel {
                            width: narrationColumn.width
                            wrapMode: Text.WordWrap
                            font.pointSize: ScreenTools.smallFontPointSize
                            color: qgcPal.text
                            text: (index + 1) + ". " + modelData
                        }
                    }
                }

                QGCLabel {
                    Layout.fillWidth: true
                    wrapMode: Text.WordWrap
                    visible: root._narrationView && root._narrationView.risk !== ""
                    text: root._narrationView ? qsTr("风险：%1").arg(root._narrationView.risk) : ""
                    font.pointSize: ScreenTools.smallFontPointSize
                    color: root._alertYellow
                }
            }
        }

        // Alert history: newest first, capped by the engine (200 entries).
        Rectangle {
            Layout.fillWidth: true
            implicitHeight: root.alertHistoryOpen ? ScreenTools.defaultFontPixelHeight * 10 : 0
            visible: root.alertHistoryOpen
            clip: true
            color: qgcPal.windowShadeDark
            radius: ScreenTools.defaultBorderRadius

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: root._margin * 0.5
                spacing: root._margin * 0.3

                RowLayout {
                    Layout.fillWidth: true
                    QGCLabel {
                        Layout.fillWidth: true
                        text: qsTr("告警历史（最近在前，最多 200 条）")
                        font.pointSize: ScreenTools.smallFontPointSize
                        color: qgcPal.colorGrey
                    }
                    QGCLabel {
                        text: root.alertHistoryOpen ? qsTr("收起▲") : qsTr("展开▼")
                        font.pointSize: ScreenTools.smallFontPointSize
                        color: qgcPal.colorGrey
                    }
                }

                QGCListView {
                    id: alertHistoryList
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    model: customAlertEngine.history
                    spacing: 2
                    clip: true

                    delegate: Item {
                        width: alertHistoryList.width
                        height: historyLabel.implicitHeight + 2

                        readonly property var _entry: model.modelData

                        Rectangle {
                            anchors.left: parent.left
                            anchors.top: parent.top
                            anchors.bottom: parent.bottom
                            width: 3
                            radius: 1
                            color: root._alertLevelColor[root._entry ? root._entry.levelPeak : 0]
                        }

                        QGCLabel {
                            id: historyLabel
                            anchors.left: parent.left
                            anchors.leftMargin: root._margin * 0.5
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            elide: Text.ElideRight
                            font.pointSize: ScreenTools.smallFontPointSize
                            color: qgcPal.text
                            text: {
                                var e = root._entry
                                if (!e) {
                                    return ""
                                }
                                var period = root._alertTimeString(e.raisedMs)
                                         + (e.active ? qsTr(" 起 · 进行中")
                                                     : qsTr(" ~ %1 恢复").arg(root._alertTimeString(e.recoveredMs)))
                                return qsTr("%1 [%2·%3] %4").arg(period)
                                    .arg(root._ruleName(e.ruleId))
                                    .arg(e.levelPeak === 2 ? qsTr("严重") : e.levelPeak === 1 ? qsTr("警告") : qsTr("提示"))
                                    .arg(root._alertText(e))
                            }
                        }
                    }
                }
            }

            QGCMouseArea {
                anchors.top: parent.top
                anchors.left: parent.left
                anchors.right: parent.right
                height: ScreenTools.defaultFontPixelHeight
                onClicked: root.alertHistoryOpen = false
            }
        }

        // Alert settings: master switch, per-rule switches, thresholds.
        Rectangle {
            Layout.fillWidth: true
            implicitHeight: root.alertSettingsOpen ? alertSettingsColumn.implicitHeight + root._margin : 0
            visible: root.alertSettingsOpen
            clip: true
            color: qgcPal.windowShadeDark
            radius: ScreenTools.defaultBorderRadius

            ColumnLayout {
                id: alertSettingsColumn
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.margins: root._margin * 0.5
                spacing: root._margin * 0.3

                QGCCheckBox {
                    text: qsTr("启用告警引擎")
                    checked: customAlertEngine.enabled
                    onClicked: customAlertEngine.enabled = checked
                }

                Flow {
                    Layout.fillWidth: true
                    spacing: root._margin

                    Repeater {
                        model: root._ruleIds
                        delegate: QGCCheckBox {
                            required property string modelData
                            text: root._ruleName(modelData)
                            font.pointSize: ScreenTools.smallFontPointSize
                            checked: customAlertEngine.ruleEnabled(modelData)
                            onClicked: customAlertEngine.setRuleEnabled(modelData, checked)
                        }
                    }
                }

                Repeater {
                    model: root._thresholdDescriptors

                    delegate: RowLayout {
                        required property var modelData
                        Layout.fillWidth: true

                        QGCLabel {
                            Layout.preferredWidth: ScreenTools.defaultFontPixelWidth * 11
                            text: modelData.label
                            font.pointSize: ScreenTools.smallFontPointSize
                            color: qgcPal.text
                        }

                        QGCTextField {
                            id: thresholdField
                            Layout.preferredWidth: ScreenTools.defaultFontPixelWidth * 5
                            font.pointSize: ScreenTools.smallFontPointSize
                            text: Number(customAlertEngine.threshold(modelData.key)).toFixed(modelData.dec)
                            onEditingFinished: {
                                var value = Number(text)
                                if (!isNaN(value)) {
                                    customAlertEngine.setThreshold(modelData.key, value)
                                }
                                text = Number(customAlertEngine.threshold(modelData.key)).toFixed(modelData.dec)
                            }
                        }

                        QGCLabel {
                            text: modelData.unit
                            font.pointSize: ScreenTools.smallFontPointSize
                            color: qgcPal.colorGrey
                        }
                    }
                }

                QGCButton {
                    text: qsTr("恢复默认阈值与规则开关")
                    font.pointSize: ScreenTools.smallFontPointSize
                    onClicked: customAlertEngine.resetAll()
                }
            }
        }

        RowLayout {
            Layout.fillWidth: true
            spacing:      _margin
            visible:      px4Assistant.healthState === "fail"

            Rectangle {
                Layout.fillWidth:   true
                implicitHeight:     bannerLabel.implicitHeight + _margin * 2
                color:              qgcPal.alertBackground
                radius:             ScreenTools.defaultBorderRadius

                QGCLabel {
                    id:                 bannerLabel
                    anchors.fill:       parent
                    anchors.margins:    _margin
                    wrapMode:           Text.WordWrap
                    color:              qgcPal.alertText
                    text: px4Assistant.tokenFound
                          ? qsTr("本机 DSH 未就绪：%1").arg(root._healthDetailText)
                          : qsTr("未找到 panel-token。请启动本机 DSH 后再点『重试』。")
                }
            }

            QGCButton {
                text: qsTr("重试")
                onClicked: {
                    px4Assistant.reloadToken()
                    px4Assistant.probeHealth()
                }
            }
        }

        QGCListView {
            id:                 messageList
            Layout.fillWidth:   true
            Layout.fillHeight:  true
            model:              _messages
            spacing:            _margin
            onCountChanged:     positionViewAtEnd()

            delegate: Item {
                width:  messageList.width
                height: bubble.height

                readonly property string _kind: model.kind
                readonly property string _text: model.text

                Rectangle {
                    id: bubble

                    readonly property real _maxWidth: parent.width * 0.85

                    width:  _kind === "user"
                            ? Math.min(_label.implicitWidth + _margin * 2, _maxWidth)
                            : parent.width
                    height: _label.implicitHeight + _margin * 1.6
                    x:      _kind === "user" ? parent.width - width : 0
                    radius: ScreenTools.defaultBorderRadius

                    color:  _kind === "user"  ? qgcPal.buttonHighlight
                          : _kind === "tool"  ? qgcPal.windowShadeDark
                          : _kind === "error" ? qgcPal.alertBackground
                          : "transparent"
                    border.width: _kind === "tool" ? 1 : 0
                    border.color: qgcPal.text

                    QGCLabel {
                        id:                 _label
                        anchors.fill:       parent
                        anchors.margins:    _margin * 0.8
                        wrapMode:           Text.WordWrap
                        textFormat:         Text.PlainText
                        font.pointSize:     _kind === "thinking" ? ScreenTools.smallFontPointSize
                                                               : ScreenTools.defaultFontPointSize
                        font.italic:        _kind === "thinking"
                        color:  _kind === "user"     ? qgcPal.buttonHighlightText
                              : _kind === "error"    ? qgcPal.alertText
                              : _kind === "thinking" ? qgcPal.colorGrey
                              : _kind === "tool"     ? qgcPal.colorGrey
                              : qgcPal.text
                        text:   _text
                    }
                }
            }
        }

        RowLayout {
            Layout.fillWidth: true
            spacing:          _margin

            QGCTextField {
                id:                 inputField
                Layout.fillWidth:   true
                enabled:            root._ready
                placeholderText:    root._ready
                                    ? qsTr("问点什么…（Ctrl+Shift+A 唤起/收起）")
                                    : qsTr("本机 DSH 未就绪")
                onAccepted:         root._send()
            }

            QGCButton {
                text:    px4Assistant.busy ? qsTr("停止") : qsTr("发送")
                enabled: px4Assistant.busy
                         || (root._ready && inputField.text.trim() !== "")
                onClicked: {
                    if (px4Assistant.busy) {
                        px4Assistant.cancelChat()
                    } else {
                        root._send()
                    }
                }
            }
        }
    }

    Connections {
        target: px4Assistant

        function onChatTokenDelta(text)    { root._appendDelta("assistant", text) }
        function onChatThinkingDelta(text) { root._appendDelta("thinking", text) }

        function onChatToolEvent(data) {
            if (data.state === "start") {
                var args = data.args !== undefined ? JSON.stringify(data.args) : ""
                root._append("tool", qsTr("[工具] %1 %2").arg(data.name).arg(args))
            } else {
                root._append("tool", qsTr("[工具] %1 %2")
                             .arg(data.ok ? qsTr("完成") : qsTr("失败"))
                             .arg(data.summary !== undefined ? data.summary : ""))
            }
        }

        function onChatNotice(level, text) { root._append(level === "warn" ? "error" : "notice", text) }
        function onChatDone(outcome)       { root._append("notice", qsTr("— 本轮结束（%1）—").arg(outcome)) }
        function onChatError(code, message) { root._append("error", root._errorText(code, message)) }
    }
}
