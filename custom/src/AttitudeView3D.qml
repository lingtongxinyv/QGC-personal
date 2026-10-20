import QtQuick
import QtQuick.Window
import QtPositioning
import QtQuick3D
import QtQuick3D.Helpers

import QGroundControl
import QGroundControl.Controls
import QGroundControl.Viewer3D

import "TelemetrySnapshot.js" as Telemetry

/// Floating 3D attitude viewer (read-only). Shows the active vehicle as a live
/// 3D model driven by its telemetry: roll/pitch/yaw, position over the takeoff
/// point, spinning propellers while armed/flying, plus a HUD text block.
///
/// Route A (in-QGC): Vehicle facts -> Telemetry.snapshot() -> HUD + direct
/// fact binding inside DroneModelDjiF450. Process-in, zero network cost.
/// Route B (Unity external, approved): same TelemetrySnapshot schema v1
/// consumed over WebSocket. See coord/unity-route-b/ for the C# package.
/// The WS broadcast endpoint is NOT yet implemented (separate work item).
///
/// All three display routes (this floating window, QGC fullscreen Viewer3D,
/// Unity window) are pure read-only consumers of the same Vehicle facts.
/// No MAVLink writes, no parameter access, no mode changes.
///
/// Camera: Gazebo-style (Viewer3DCameraController). Left drag = orbit,
/// right/middle drag = pan, wheel = zoom.
///
/// Model switching: set modelId property to switch airframe components.
/// Current: "dji_f450" only. Future: expand ModelRegistry.js entries.
Rectangle {
    id: root

    property var  vehicle:           null
    property var  parentToolInsets
    property bool open:              true
    property bool detached:          false
    property bool followCamera:      true
    property string modelId:         "dji_f450"
    property bool showModelLabels:   true

    readonly property real _margin:      ScreenTools.defaultFontPixelWidth * 0.5
    readonly property real _titleHeight: ScreenTools.defaultFontPixelHeight * 1.7
    readonly property real _openWidth:   ScreenTools.defaultFontPixelWidth * 72
    readonly property real _openHeight:  _titleHeight + _openWidth * 0.75 + _margin * 2

    property var _gpsRef: null
    property var _snap:   null

    width:  _openWidth
    height: (open && !detached) ? _openHeight : _titleHeight

    // Default placement: bottom-left corner of the fly view, clear of the tool
    // insets. Declarative rather than a one-shot assignment so the panel
    // re-positions itself once ScreenTools font metrics and parentToolInsets
    // resolve. Dragging the title bar assigns x/y directly, which replaces
    // these bindings - i.e. the user takes over the placement.
    x: (parentToolInsets ? parentToolInsets.leftEdgeTopInset : 0) + _margin * 2
    y: parent.height - height - (parentToolInsets ? parentToolInsets.bottomEdgeLeftInset : 0) - _margin * 2

    color:  qgcPal.windowShade
    radius: ScreenTools.defaultFontPixelWidth * 0.4
    border.color: qgcPal.text
    border.width: 1
    clip: true

    Behavior on height { NumberAnimation { duration: 150 } }

    QGCPalette { id: qgcPal }

    function _fmt(v, digits, suffix) {
        return (v === null || v === undefined) ? "--" : Number(v).toFixed(digits) + (suffix || "")
    }

    Component.onCompleted: {
        _cam.lookAt(Qt.vector3d(0, 0, 0), 35, 55, 240)
        _snapTimer.triggered()
        px4WsRelay.startServer(19390)
    }

    Connections {
        target: root.vehicle
        enabled: target !== null
        function onCoordinateChanged() {
            if (root._gpsRef === null && root.vehicle.coordinate.isValid) {
                root._gpsRef = root.vehicle.coordinate
            }
        }
    }

    Timer {
        id: _snapTimer
        interval: 100
        repeat: true
        running: root.visible && root.open
        onTriggered: root._snap = Telemetry.snapshot(root.vehicle)
    }

    //-------------------------------------------------------------------------
    //-- Route-B WebSocket broadcaster (schema v1, 10 Hz)
    //-- ws://127.0.0.1:19390/telemetry  — read-only feed for the Unity viewer.
    //-- Lives here (not in FlyViewCustomLayer.qml) because TelemetrySnapshot.js
    //-- resolves inside this module's resource directory.
    //-- Server is started from the root Component.onCompleted above.
    Timer {
        id: _wsBroadcastTimer
        interval: 100
        repeat: true
        running: true
        onTriggered: px4WsRelay.broadcast(JSON.stringify(Telemetry.snapshot(root.vehicle)))
    }

    //-------------------------------------------------------------------------
    // Title bar: model switcher + follow toggle + collapse button
    Rectangle {
        id: titleBar
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        height: root._titleHeight
        color: qgcPal.windowShadeDark
        radius: root.radius

        MouseArea {
            anchors.fill: parent
            drag.target: root
            drag.axis: Drag.XAndYAxis
            drag.minimumX: 0
            drag.maximumX: root.parent ? root.parent.width - root.width : 0
            drag.minimumY: 0
            drag.maximumY: root.parent ? root.parent.height - root.height : 0
        }

        QGCLabel {
            anchors.left: parent.left
            anchors.leftMargin: root._margin
            anchors.verticalCenter: parent.verticalCenter
            text: qsTr("3D 姿态视图 · %1").arg(root.modelId)
            color: qgcPal.text
        }

        QGCLabel {
            anchors.right: detachButton.left
            anchors.rightMargin: root._margin
            anchors.verticalCenter: parent.verticalCenter
            text: qsTr("参数")
            color: root.showModelLabels ? qgcPal.colorGreen : qgcPal.text
            opacity: root.showModelLabels ? 1.0 : 0.55

            MouseArea {
                anchors.fill: parent
                onClicked: root.showModelLabels = !root.showModelLabels
            }
        }

        QGCLabel {
            id: detachButton
            anchors.right: followButton.left
            anchors.rightMargin: root._margin
            anchors.verticalCenter: parent.verticalCenter
            text: root.detached ? qsTr("收回") : qsTr("弹出")
            color: root.detached ? qgcPal.colorGreen : qgcPal.text

            MouseArea {
                anchors.fill: parent
                onClicked: root.detached = !root.detached
            }
        }

        QGCLabel {
            id: followButton
            anchors.right: collapseButton.left
            anchors.rightMargin: root._margin
            anchors.verticalCenter: parent.verticalCenter
            text: qsTr("跟随")
            color: root.followCamera ? qgcPal.colorGreen : qgcPal.text
            opacity: root.followCamera ? 1.0 : 0.55

            MouseArea {
                anchors.fill: parent
                onClicked: root.followCamera = !root.followCamera
            }
        }

        QGCLabel {
            id: collapseButton
            anchors.right: parent.right
            anchors.rightMargin: root._margin
            anchors.verticalCenter: parent.verticalCenter
            text: root.open ? qsTr("—") : qsTr("＋")
            color: qgcPal.text

            MouseArea {
                anchors.fill: parent
                onClicked: root.open = !root.open
            }
        }
    }

    //-------------------------------------------------------------------------
    // Standalone window (QGC PipView pattern): sceneArea is reparented into
    // detachedWindow.contentItem while root.detached is true, and restored to
    // the embedded panel when it returns to false.
    Window {
        id:                     detachedWindow
        visible:                root.detached
        title:                  qsTr("3D 姿态视图 · %1").arg(root.modelId)
        width:                  root._openWidth * 1.8
        height:                 root._openWidth * 1.3
        onClosing:              root.detached = false
    }

    //-------------------------------------------------------------------------
    // 3D scene
    Item {
        id: sceneArea
        visible: root.open
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: titleBar.bottom
        anchors.bottom: parent.bottom
        anchors.margins: root._margin

        states: [
            State {
                name: "detached"
                when: root.detached

                AnchorChanges {
                    target:         sceneArea
                    anchors.top:    detachedWindow.contentItem.top
                    anchors.bottom: detachedWindow.contentItem.bottom
                    anchors.left:   detachedWindow.contentItem.left
                    anchors.right:  detachedWindow.contentItem.right
                }

                ParentChange {
                    target: sceneArea
                    parent: detachedWindow.contentItem
                }
            }
        ]

        View3D {
            id: view3d
            anchors.fill: parent

            camera: standAloneScene.cameraOne

            environment: SceneEnvironment {
                antialiasingMode: SceneEnvironment.MSAA
                antialiasingQuality: SceneEnvironment.Medium
                backgroundMode: SceneEnvironment.Color
                clearColor: "#16191f"
            }

            importScene: Node {
                CameraLightModel {
                    id: standAloneScene
                    cameraHeading: _cam.heading
                    cameraTilt: _cam.tilt
                    cameraZoom: _cam.distance
                    orbitCenter: _cam.orbitCenter
                    viewDistance: 8000
                }

                Model {
                    source: "#Rectangle"
                    scale: Qt.vector3d(600, 600, 1)
                    materials: PrincipledMaterial {
                        baseColor: "#232833"
                        roughness: 1.0
                    }
                }

                AxisHelper {
                    enableXZGrid: false
                    enableXYGrid: true
                    enableYZGrid: false
                    enableAxisLines: false
                    gridOpacity: 0.25
                    gridColor: "#8a93a6"
                }

                // Airframe - pick model by registry id
                // Direct binding (DroneModelDjiF450 already has modelScale)
                Node {
                    id: airframe

                    DroneModelDjiF450 {
                        id: djiF450
                        vehicle: root.vehicle
                        gpsRef: root._gpsRef ? root._gpsRef
                                                  : QtPositioning.coordinate(0, 0, 0)
                        visible: root.modelId === "dji_f450"
                    }
                }
            }
        }

        Viewer3DCameraController {
            id: _cam
            viewportSize: Qt.size(view3d.width, view3d.height)
            fieldOfView: standAloneScene.cameraOne.fieldOfView
        }

        Connections {
            target: djiF450
            enabled: root.followCamera && root.open && root.visible
            function onPositionChanged() {
                _cam.orbitCenter = djiF450.position
            }
        }

        MouseArea {
            anchors.fill: view3d
            acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
            onPressed: function(mouse) {
                if (mouse.button === Qt.LeftButton) {
                    _cam.beginOrbit(Qt.point(mouse.x, mouse.y))
                } else {
                    _cam.beginPan(Qt.point(mouse.x, mouse.y))
                }
            }
            onPositionChanged: function(mouse) {
                if (pressedButtons & Qt.LeftButton) {
                    _cam.orbitTo(Qt.point(mouse.x, mouse.y))
                } else if (pressedButtons & (Qt.RightButton | Qt.MiddleButton)) {
                    _cam.panTo(Qt.point(mouse.x, mouse.y))
                }
            }
            onWheel: function(wheel) {
                _cam.zoom(wheel.angleDelta.y, Qt.point(wheel.x, wheel.y))
            }
        }

        //---------------------------------------------------------------------
        // HUD (left-top, complementary to on-model labels)
        Rectangle {
            anchors.left: parent.left
            anchors.top: parent.top
            anchors.margins: root._margin
            width: hudColumn.width + root._margin * 2
            height: hudColumn.height + root._margin * 2
            color: Qt.rgba(0, 0, 0, 0.45)
            radius: 3

            Column {
                id: hudColumn
                anchors.centerIn: parent
                spacing: 1

                QGCLabel {
                    text: {
                        if (!root._snap) return qsTr("等待载具…")
                        var mode = root._snap.status.flight_mode || qsTr("未知模式")
                        var armed = root._snap.status.armed
                        return mode + " · " + (armed ? qsTr("已解锁") : qsTr("未解锁"))
                    }
                    color: (root._snap && root._snap.status.armed) ? "#ff6666" : "#7fe07f"
                    font.pointSize: ScreenTools.smallFontPointSize
                }
                QGCLabel {
                    text: root._snap ?
                        qsTr("高度 ") + root._fmt(root._snap.position.altitude_rel_m, 1, " m") +
                        qsTr("  地速 ") + root._fmt(root._snap.speed.ground_m_s, 1, " m/s") +
                        qsTr("  爬升 ") + root._fmt(root._snap.speed.climb_m_s, 1, " m/s") : "--"
                    color: "white"
                    font.pointSize: ScreenTools.smallFontPointSize
                }
                QGCLabel {
                    text: root._snap ?
                        qsTr("电量 ") + root._fmt(root._snap.status.battery_pct, 0, " %") +
                        qsTr("  GPS ") + root._fmt(root._snap.status.gps_sats, 0, qsTr(" 星")) : "--"
                    color: "white"
                    font.pointSize: ScreenTools.smallFontPointSize
                }
            }
        }

        //---------------------------------------------------------------------
        // On-model labels: project drone 3D position to screen via
        // View3D.mapFrom3DScene(). Qt 6.11 native, no Text3D dependency.
        Item {
            id: labelsOverlay
            anchors.fill: view3d
            visible: root.showModelLabels && root._snap && root.open

            readonly property point _droneScreen: view3d.mapFrom3DScene(djiF450.position)

            Connections {
                target: djiF450
                function onPositionChanged() {
                    rpyLabel.x = labelsOverlay._droneScreen.x - rpyLabel.width / 2
                    rpyLabel.y = labelsOverlay._droneScreen.y - rpyLabel.height - 10
                    speedLabel.x = labelsOverlay._droneScreen.x - speedLabel.width / 2
                    speedLabel.y = labelsOverlay._droneScreen.y + 10
                    statusLabel.x = labelsOverlay._droneScreen.x - statusLabel.width / 2
                    statusLabel.y = labelsOverlay._droneScreen.y + statusLabel.height + 14
                }
            }

            Rectangle {
                id: rpyLabel
                radius: 3
                color: Qt.rgba(0, 0, 0, 0.55)
                border.color: "#7fe07f"
                border.width: 1
                antialiasing: true

                QGCLabel {
                    anchors.fill: parent
                    anchors.margins: 6
                    text: {
                        var s = root._snap; if (!s) return ""
                        return "R" + root._fmt(s.attitude_deg.roll, 1, qsTr("°")) +
                               " P" + root._fmt(s.attitude_deg.pitch, 1, qsTr("°")) +
                               " Y" + root._fmt(s.attitude_deg.yaw, 1, qsTr("°"))
                    }
                    color: "#7fe07f"
                    font.pointSize: ScreenTools.smallFontPointSize
                }
            }

            Rectangle {
                id: speedLabel
                radius: 3
                color: Qt.rgba(0, 0, 0, 0.55)
                border.color: "#ffffff"
                border.width: 1
                antialiasing: true

                QGCLabel {
                    anchors.fill: parent
                    anchors.margins: 6
                    text: {
                        var s = root._snap; if (!s) return ""
                        return root._fmt(s.speed.ground_m_s, 1, qsTr("m/s")) +
                               "  " + qsTr("高度") + " " +
                               root._fmt(s.position.altitude_rel_m, 1, qsTr("m"))
                    }
                    color: "white"
                    font.pointSize: ScreenTools.smallFontPointSize
                }
            }

            Rectangle {
                id: statusLabel
                radius: 3
                color: Qt.rgba(0, 0, 0, 0.55)
                border.color: {
                    var s = root._snap
                    return (s && s.status.armed) ? "#ff6666" : "#8a93a6"
                }
                border.width: 1
                antialiasing: true

                QGCLabel {
                    anchors.fill: parent
                    anchors.margins: 6
                    text: {
                        var s = root._snap; if (!s) return ""
                        var mode = s.status.flight_mode || "--"
                        return mode + "  " + (s.status.armed ? qsTr("ARMED") : qsTr("DISARMED"))
                    }
                    color: {
                        var s = root._snap
                        return (s && s.status.armed) ? "#ff6666" : "#8a93a6"
                    }
                    font.pointSize: ScreenTools.smallFontPointSize
                }
            }

            // Initial positioning, deferred because the View3D camera is not
            // resolvable until the scene graph has had a chance to init.
            Component.onCompleted: Qt.callLater(function() {
                rpyLabel.x = labelsOverlay._droneScreen.x - rpyLabel.width / 2
                rpyLabel.y = labelsOverlay._droneScreen.y - rpyLabel.height - 10
                speedLabel.x = labelsOverlay._droneScreen.x - speedLabel.width / 2
                speedLabel.y = labelsOverlay._droneScreen.y + 10
                statusLabel.x = labelsOverlay._droneScreen.x - statusLabel.width / 2
                statusLabel.y = labelsOverlay._droneScreen.y + statusLabel.height + 14
            })
        }

        QGCLabel {
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            anchors.margins: root._margin
            text: qsTr("左键环绕 · 右键平移 · 滚轮缩放")
            color: "white"
            opacity: 0.5
            font.pointSize: ScreenTools.smallFontPointSize
        }
    }
}
