import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

import QGroundControl
import QGroundControl.Controls
import Custom.Widgets

Item {
    id: customLayer

    property var parentToolInsets                       // These insets tell you what screen real estate is available for positioning the controls in your overlay
    property var totalToolInsets:   _totalToolInsets    // The insets updated for the custom overlay additions
    property var mapControl

    readonly property string noGPS:         qsTr("NO GPS")
    readonly property real   indicatorValueWidth:   ScreenTools.defaultFontPixelWidth * 7

    property var    _activeVehicle:         QGroundControl.multiVehicleManager.activeVehicle
    property real   _indicatorDiameter:     ScreenTools.defaultFontPixelWidth * 18
    property real   _indicatorsHeight:      ScreenTools.defaultFontPixelHeight
    property var    _sepColor:              qgcPal.globalTheme === QGCPalette.Light ? Qt.rgba(0,0,0,0.5) : Qt.rgba(1,1,1,0.5)
    property color  _indicatorsColor:       qgcPal.text
    property bool   _isVehicleGps:          _activeVehicle ? _activeVehicle.gps.count.rawValue > 1 && _activeVehicle.gps.hdop.rawValue < 1.4 : false
    property string _altitude:              _activeVehicle ? (isNaN(_activeVehicle.altitudeRelative.value) ? "0.0" : _activeVehicle.altitudeRelative.value.toFixed(1)) + ' ' + _activeVehicle.altitudeRelative.units : "0.0"
    property string _distanceStr:           isNaN(_distance) ? "0" : _distance.toFixed(0) + ' ' + QGroundControl.unitsConversion.appSettingsHorizontalDistanceUnitsString
    property real   _heading:               _activeVehicle   ? _activeVehicle.heading.rawValue : 0
    property real   _distance:              _activeVehicle ? _activeVehicle.distanceToHome.rawValue : 0
    property string _messageTitle:          ""
    property string _messageText:           ""
    property real   _toolsMargin:           ScreenTools.defaultFontPixelWidth * 0.75

    function secondsToHHMMSS(timeS) {
        var sec_num = parseInt(timeS, 10);
        var hours   = Math.floor(sec_num / 3600);
        var minutes = Math.floor((sec_num - (hours * 3600)) / 60);
        var seconds = sec_num - (hours * 3600) - (minutes * 60);
        if (hours   < 10) {hours   = "0"+hours;}
        if (minutes < 10) {minutes = "0"+minutes;}
        if (seconds < 10) {seconds = "0"+seconds;}
        return hours+':'+minutes+':'+seconds;
    }

    // parentToolInsets is assigned by FlyView after the layer is created, so at
    // startup it is undefined. `undefined + number` yields NaN, which makes any
    // anchored item silently disappear (T7). Always read through this helper so
    // the binding stays live and recovers as soon as the insets arrive.
    function _inset(name) {
        return parentToolInsets ? parentToolInsets[name] : 0
    }

    QGCToolInsets {
        id:                     _totalToolInsets
        leftEdgeTopInset:       _inset("leftEdgeTopInset")
        leftEdgeCenterInset:    exampleRectangle.leftEdgeCenterInset
        leftEdgeBottomInset:    _inset("leftEdgeBottomInset")
        rightEdgeTopInset:      _inset("rightEdgeTopInset")
        rightEdgeCenterInset:   assistantPanel.rightEdgeCenterInset
        rightEdgeBottomInset:   parent.width - compassBackground.x
        topEdgeLeftInset:       _inset("topEdgeLeftInset")
        topEdgeCenterInset:     compassArrowIndicator.y + compassArrowIndicator.height
        topEdgeRightInset:      _inset("topEdgeRightInset")
        bottomEdgeLeftInset:    _inset("bottomEdgeLeftInset")
        bottomEdgeCenterInset:  _inset("bottomEdgeCenterInset")
        bottomEdgeRightInset:   parent.height - attitudeIndicator.y
    }

    // This is an example of how you can use parent tool insets to position an element on the custom fly view layer
    // - we use parent topEdgeLeftInset to position the widget below the toolstrip
    // - we use parent bottomEdgeLeftInset to dodge the virtual joystick if enabled
    // - we use the parent leftEdgeTopInset to size our element to the same width as the ToolStripAction
    // - we export the width of this element as the leftEdgeCenterInset so that the map will recenter if the vehicle flys behind this element
    Rectangle {
        id: exampleRectangle
        visible: false // to see this example, set this to true. To view insets, enable the insets viewer FlyView.qml
        anchors.left: parent.left
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        anchors.topMargin: parentToolInsets.topEdgeLeftInset + _toolsMargin
        anchors.bottomMargin: parentToolInsets.bottomEdgeLeftInset + _toolsMargin
        anchors.leftMargin: _toolsMargin
        width: parentToolInsets.leftEdgeTopInset - _toolsMargin
        color: 'red'

        property real leftEdgeCenterInset: visible ? x + width : 0
    }

    //-------------------------------------------------------------------------
    //-- Heading Indicator
    Rectangle {
        id:                         compassBar
        height:                     ScreenTools.defaultFontPixelHeight * 1.5
        width:                      ScreenTools.defaultFontPixelWidth  * 50
        anchors.bottom:             parent.bottom
        anchors.bottomMargin:       _toolsMargin
        color:                      "#DEDEDE"
        radius:                     2
        clip:                       true
        anchors.horizontalCenter:   parent.horizontalCenter
        Repeater {
            model: 720
            QGCLabel {
                function _normalize(degrees) {
                    var a = degrees % 360
                    if (a < 0) a += 360
                    return a
                }
                property int _startAngle: modelData + 180 + _heading
                property int _angle: _normalize(_startAngle)
                anchors.verticalCenter: parent.verticalCenter
                x:              visible ? ((modelData * (compassBar.width / 360)) - (width * 0.5)) : 0
                visible:        _angle % 45 == 0
                color:          "#75505565"
                font.pointSize: ScreenTools.smallFontPointSize
                text: {
                    switch(_angle) {
                    case 0:     return "N"
                    case 45:    return "NE"
                    case 90:    return "E"
                    case 135:   return "SE"
                    case 180:   return "S"
                    case 225:   return "SW"
                    case 270:   return "W"
                    case 315:   return "NW"
                    }
                    return ""
                }
            }
        }
    }
    Rectangle {
        id:                         headingIndicator
        height:                     ScreenTools.defaultFontPixelHeight
        width:                      ScreenTools.defaultFontPixelWidth * 4
        color:                      qgcPal.windowShadeDark
        anchors.top:                compassBar.top
        anchors.topMargin:          -headingIndicator.height / 2
        anchors.horizontalCenter:   parent.horizontalCenter
        QGCLabel {
            text:                   _heading
            color:                  qgcPal.text
            font.pointSize:         ScreenTools.smallFontPointSize
            anchors.centerIn:       parent
        }
    }
    Image {
        id:                         compassArrowIndicator
        height:                     _indicatorsHeight
        width:                      height
        source:                     "/custom/img/compass_pointer.svg"
        fillMode:                   Image.PreserveAspectFit
        sourceSize.height:          height
        anchors.top:                compassBar.bottom
        anchors.topMargin:          -height / 2
        anchors.horizontalCenter:   parent.horizontalCenter
    }

    Rectangle {
        id:                     compassBackground
        anchors.bottom:         attitudeIndicator.bottom
        anchors.right:          attitudeIndicator.left
        anchors.rightMargin:    -attitudeIndicator.width / 2
        width:                  -anchors.rightMargin + compassBezel.width + (_toolsMargin * 2)
        height:                 attitudeIndicator.height * 0.75
        radius:                 2
        color:                  qgcPal.window

        Rectangle {
            id:                     compassBezel
            anchors.verticalCenter: parent.verticalCenter
            anchors.leftMargin:     _toolsMargin
            anchors.left:           parent.left
            width:                  height
            height:                 parent.height - (northLabelBackground.height / 2) - (headingLabelBackground.height / 2)
            radius:                 height / 2
            border.color:           qgcPal.text
            border.width:           1
            color:                  Qt.rgba(0,0,0,0)
        }

        Rectangle {
            id:                         northLabelBackground
            anchors.top:                compassBezel.top
            anchors.topMargin:          -height / 2
            anchors.horizontalCenter:   compassBezel.horizontalCenter
            width:                      northLabel.contentWidth * 1.5
            height:                     northLabel.contentHeight * 1.5
            radius:                     ScreenTools.defaultFontPixelWidth  * 0.25
            color:                      qgcPal.windowShade

            QGCLabel {
                id:                 northLabel
                anchors.centerIn:   parent
                text:               "N"
                color:              qgcPal.text
                font.pointSize:     ScreenTools.smallFontPointSize
            }
        }

        Image {
            id:                 headingNeedle
            anchors.centerIn:   compassBezel
            height:             compassBezel.height * 0.75
            width:              height
            source:             "/custom/img/compass_needle.svg"
            fillMode:           Image.PreserveAspectFit
            sourceSize.height:  height
            transform: [
                Rotation {
                    origin.x:   headingNeedle.width  / 2
                    origin.y:   headingNeedle.height / 2
                    angle:      _heading
                }]
        }

        Rectangle {
            id:                         headingLabelBackground
            anchors.top:                compassBezel.bottom
            anchors.topMargin:          -height / 2
            anchors.horizontalCenter:   compassBezel.horizontalCenter
            width:                      headingLabel.contentWidth * 1.5
            height:                     headingLabel.contentHeight * 1.5
            radius:                     ScreenTools.defaultFontPixelWidth  * 0.25
            color:                      qgcPal.windowShade

            QGCLabel {
                id:                 headingLabel
                anchors.centerIn:   parent
                text:               _heading
                color:              qgcPal.text
                font.pointSize:     ScreenTools.smallFontPointSize
            }
        }
    }

    Rectangle {
        id:                     attitudeIndicator
        anchors.bottomMargin:   _toolsMargin + _inset("bottomEdgeRightInset")
        anchors.rightMargin:    _toolsMargin
        anchors.bottom:         parent.bottom
        anchors.right:          parent.right
        height:                 ScreenTools.defaultFontPixelHeight * 6
        width:                  height
        radius:                 height * 0.5
        color:                  qgcPal.windowShade

        CustomAttitudeWidget {
            size:               parent.height * 0.95
            vehicle:            _activeVehicle
            showHeading:        false
            anchors.centerIn:   parent
        }
    }

    //-------------------------------------------------------------------------
    //-- DSH assistant panel (read-only Q&A, right dock)
    AssistantPanel {
        id:                     assistantPanel
        visible:                !QGroundControl.videoManager.fullScreen
        anchors.top:            parent.top
        anchors.bottom:         attitudeIndicator.top
        anchors.right:          parent.right
        anchors.topMargin:      _inset("topEdgeRightInset") + _toolsMargin
        anchors.bottomMargin:   _toolsMargin
        anchors.rightMargin:    _toolsMargin
        parentToolInsets:       parentToolInsets
        mapControl:             mapControl
        guidanceLayer:          customLayer
    }

    //-------------------------------------------------------------------------
    //-- 3D 姿态视图（内嵌浮窗，Ctrl+Shift+3 唤起/收起）
    AttitudeView3D {
        id:                     attitudeView3D
        visible:                !QGroundControl.videoManager.fullScreen
        vehicle:                _activeVehicle
        parentToolInsets:       parentToolInsets

        Shortcut {
            sequence:           "Ctrl+Shift+3"
            context:            Qt.ApplicationShortcut
            onActivated:        attitudeView3D.open = !attitudeView3D.open
        }
    }

    //-------------------------------------------------------------------------
    //-- 智能指示 · 跳转 + 全域高亮（B5 三期，只读）
    //
    // targetId 白名单 → (页面导航 + 控件定位 + 呼吸描边 ~4.5s 自动消退)。
    // 硬边界：零 MAVLink 写 / 零参数写 / 零模式切换；导航只调 mainWindow 既有
    // 视图切换接口，高亮层是纯视觉 overlay，不改目标控件行为、不注入数据。
    // 未知 targetId 一律静默不跳（验收 D1）。

    /// Whitelist registry. page: fly | plan | analyze | setup | settings |
    /// "settings:<nameKey>". resolve: objectName under mainWindow.contentItem,
    /// or a local id ("attitudeIndicator" / "attitudeView3D").
    readonly property var _guidanceTargets: ({
        "fly.toolbar.battery":      { page: "fly",       objectName: "toolbar_batteryIndicator",        label: qsTr("电池状态") },
        "fly.toolbar.gps":          { page: "fly",       objectName: "toolbar_gpsIndicator",            label: qsTr("GPS 状态") },
        "fly.toolbar.radio":        { page: "fly",       objectName: "toolbar_telemetryRSSIIndicator",  label: qsTr("数传信号") },
        "fly.toolbar.mode":         { page: "fly",       objectName: "toolbar_flightModeIndicator",     label: qsTr("飞行模式") },
        "fly.toolbar.status":       { page: "fly",       objectName: "toolbar_mainStatusIndicator",     label: qsTr("载具状态") },
        "fly.attitude":             { page: "fly",       localItem:  "attitudeIndicator",               label: qsTr("姿态仪") },
        "fly.view3d":               { page: "fly",       localItem:  "attitudeView3D", open3d: true,    label: qsTr("3D 姿态视图") },
        "panel.chat":               { page: "fly",       objectName: "guidance_panelChat",         panelOpen: true,  label: qsTr("助手对话") },
        "panel.alertSettings":      { page: "fly",       objectName: "guidance_panelAlertSettings", panelSettings: true, label: qsTr("告警设置") },
        "panel.alertHistory":       { page: "fly",       objectName: "guidance_panelAlertHistory",  panelHistory: true,  label: qsTr("告警历史") },
        "view.plan":                { page: "plan",      objectName: "mainView_plan",                   label: qsTr("计划视图") },
        "view.analyze":             { page: "analyze",   objectName: "mainView_toolDrawer",             label: qsTr("分析工具") },
        "view.setup":               { page: "setup",     objectName: "mainView_toolDrawer",             label: qsTr("载具设置") },
        "view.settings":            { page: "settings",  objectName: "mainView_toolDrawer",             label: qsTr("应用设置") },
        "view.settings.commLinks":  { page: "settings:Comm Links", objectName: "settingsButton_Comm Links", label: qsTr("链路设置") }
    })

    property var _guidancePending: null
    property int _guidanceAttempts: 0

    function guidanceKnown(targetId) {
        return typeof targetId === "string" && _guidanceTargets[targetId] !== undefined
    }

    /// Jump to the page owning targetId and flash the control. Returns false for
    /// unknown ids or when navigation is currently blocked (validation errors,
    /// calibration lock) - in both cases nothing happens at all.
    function guidanceJump(targetId) {
        var t = _guidanceTargets[targetId]
        if (!t) {
            return false
        }
        if (!mainWindow.allowViewSwitch()) {
            return false
        }
        if (t.page === "fly") {
            mainWindow.showFlyView()
        } else if (t.page === "plan") {
            mainWindow.showPlanView()
        } else if (t.page === "analyze") {
            mainWindow.showAnalyzeTool()
        } else if (t.page === "setup") {
            mainWindow.showVehicleConfig()
        } else if (t.page === "settings") {
            mainWindow.showSettingsTool()
        } else if (t.page.indexOf("settings:") === 0) {
            mainWindow.showSettingsTool(t.page.substring(9))
        }
        if (t.panelOpen || t.panelSettings || t.panelHistory) {
            assistantPanel.open = true
        }
        if (t.panelSettings) {
            assistantPanel.alertSettingsOpen = true
        }
        if (t.panelHistory) {
            assistantPanel.alertHistoryOpen = true
        }
        if (t.open3d) {
            attitudeView3D.open = true
        }
        _guidancePending = t
        _guidanceAttempts = 0
        guidanceLocateTimer.restart()
        return true
    }

    function _findByObjectName(item, name) {
        if (!item) {
            return null
        }
        if (item.objectName === name) {
            return item
        }
        var kids = item.children
        for (var i = 0; i < kids.length; ++i) {
            var hit = _findByObjectName(kids[i], name)
            if (hit) {
                return hit
            }
        }
        return null
    }

    function _resolveGuidanceItem(t) {
        if (t.localItem === "attitudeIndicator") {
            return attitudeIndicator
        }
        if (t.localItem === "attitudeView3D") {
            return attitudeView3D
        }
        return _findByObjectName(mainWindow.contentItem, t.objectName)
    }

    // Async pages (tool drawer / settings) load after the navigation call, so
    // resolution retries briefly instead of flashing nothing.
    Timer {
        id: guidanceLocateTimer
        interval: 120
        repeat: true
        onTriggered: {
            var t = customLayer._guidancePending
            if (!t) {
                stop()
                return
            }
            var item = customLayer._resolveGuidanceItem(t)
            if (item) {
                var ok = false
                try { ok = item.visible && item.width > 0 && item.height > 0 } catch (e) { ok = false }
                if (ok) {
                    customLayer._guidancePending = null
                    stop()
                    guidanceOverlay.flash(item, t.label)
                    return
                }
            }
            customLayer._guidanceAttempts += 1
            if (customLayer._guidanceAttempts > 15) {
                customLayer._guidancePending = null
                stop()
            }
        }
    }

    // Highlight overlay: lives on top of mainWindow.contentItem so every page
    // (fly / plan / tool drawer) can be outlined. Purely visual - no MouseArea,
    // never intercepts input, never touches the target control.
    Item {
        id: guidanceOverlay
        anchors.fill: parent
        visible: false
        z: 10000

        property var _targetItem: null

        function flash(item, label) {
            _targetItem = item
            _reposition()
            guidanceLabel.text = label || ""
            guidanceLabelBg.visible = label !== undefined && label !== ""
            fadeOut.stop()
            opacity = 1.0
            highlightFrame.opacity = 1.0
            visible = true
            breathe.restart()
            hideTimer.restart()
            guardTimer.restart()
        }

        function dismiss() {
            breathe.stop()
            fadeOut.stop()
            hideTimer.stop()
            guardTimer.stop()
            _targetItem = null
            opacity = 1.0
            highlightFrame.opacity = 1.0
            visible = false
        }

        function _reposition() {
            if (!_targetItem) {
                return
            }
            var pad = ScreenTools.defaultFontPixelWidth * 0.4
            var p = _targetItem.mapToItem(guidanceOverlay, 0, 0)
            highlightFrame.x = Math.max(0, p.x - pad)
            highlightFrame.y = Math.max(0, p.y - pad)
            highlightFrame.width = Math.min(guidanceOverlay.width - highlightFrame.x, _targetItem.width + pad * 2)
            highlightFrame.height = Math.min(guidanceOverlay.height - highlightFrame.y, _targetItem.height + pad * 2)
        }

        Rectangle {
            id: highlightFrame
            color: "transparent"
            border.color: qgcPal.colorOrange
            border.width: 3
            radius: ScreenTools.defaultBorderRadius * 2
        }

        Rectangle {
            id: guidanceLabelBg
            anchors.top: highlightFrame.bottom
            anchors.topMargin: 2
            anchors.left: highlightFrame.left
            width: guidanceLabel.implicitWidth + ScreenTools.defaultFontPixelWidth
            height: guidanceLabel.implicitHeight + ScreenTools.defaultFontPixelHeight * 0.4
            radius: ScreenTools.defaultBorderRadius
            color: qgcPal.windowShadeDark
            border.color: qgcPal.colorOrange
            border.width: 1

            QGCLabel {
                id: guidanceLabel
                anchors.centerIn: parent
                font.pointSize: ScreenTools.smallFontPointSize
                color: qgcPal.text
            }
        }

        SequentialAnimation {
            id: breathe
            loops: Animation.Infinite
            NumberAnimation { target: highlightFrame; property: "opacity"; from: 1.0; to: 0.3; duration: 650; easing.type: Easing.InOutSine }
            NumberAnimation { target: highlightFrame; property: "opacity"; from: 0.3; to: 1.0; duration: 650; easing.type: Easing.InOutSine }
        }

        NumberAnimation {
            id: fadeOut
            target: guidanceOverlay
            property: "opacity"
            from: 1.0
            to: 0.0
            duration: 400
            onStopped: guidanceOverlay.dismiss()
        }

        Timer {
            id: hideTimer
            interval: 4500
            onTriggered: {
                breathe.stop()
                fadeOut.restart()
            }
        }

        // Follow layout shifts; drop the highlight if the target went away
        // (page switch, unloaded drawer) instead of drawing a stale frame.
        Timer {
            id: guardTimer
            interval: 400
            repeat: true
            onTriggered: {
                var item = guidanceOverlay._targetItem
                if (!item) {
                    guidanceOverlay.dismiss()
                    return
                }
                var alive = false
                try { alive = item.visible } catch (e) { alive = false }
                if (!alive) {
                    guidanceOverlay.dismiss()
                    return
                }
                guidanceOverlay._reposition()
            }
        }
    }

    Component.onCompleted: {
        // Reparent the highlight overlay to the top-level content item so it can
        // outline controls on any page, not just the fly view layer.
        guidanceOverlay.parent = mainWindow.contentItem
    }

}
