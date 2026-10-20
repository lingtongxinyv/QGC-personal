import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

import QGroundControl
import QGroundControl.Controls

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
