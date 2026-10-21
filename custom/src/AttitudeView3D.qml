import QtQuick
import QtQuick.Window
import QtPositioning
import QtQuick3D
import QtQuick3D.Helpers

import QGroundControl
import QGroundControl.Controls
import QGroundControl.Viewer3D

import "TelemetrySnapshot.js" as Telemetry
import "AlertText.js" as AlertText

/// Floating 3D attitude viewer (read-only). Shows the active vehicle as a live
/// 3D model driven by its telemetry: roll/pitch/yaw, position over the takeoff
/// point, spinning propellers while armed/flying, plus a HUD text block.
///
/// Route A (in-QGC): Vehicle facts -> Telemetry.snapshot() -> HUD + direct
/// fact binding inside DroneModelDjiF450. Process-in, zero network cost.
/// Route B (Unity external, approved): same TelemetrySnapshot schema v1
/// consumed over WebSocket. See coord/unity-route-b/ for the C# package.
/// The Route-B loopback WS endpoint (ws://127.0.0.1:19390) is implemented
/// here + in TelemetryWsRelay.cc; the non-loopback external bridge is still a
/// separate work item pending an owner ruling.
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
    property var _sceneItem: null

    // Placement. Until the title bar is dragged the panel follows the fly view
    // declaratively. Once the user drags it, their own position wins - but it is
    // still computed through a clamp against the current parent size, so
    // maximizing or shrinking the window can never leave the title bar stranded
    // at (or past) the bottom edge with the body clipped off-screen.
    property bool _userPlaced: false
    property real _userX:     0
    property real _userY:     0

    function _clamp(v, lo, hi) {
        return Math.max(lo, Math.min(v, hi))
    }

    function _defaultX() {
        return (parentToolInsets ? parentToolInsets.leftEdgeTopInset : 0) + _margin * 2
    }

    function _defaultY() {
        return parent.height - height - (parentToolInsets ? parentToolInsets.bottomEdgeLeftInset : 0) - _margin * 2
    }

    width:  _openWidth
    height: (open && !detached) ? _openHeight : _titleHeight

    x: _userPlaced ? _clamp(_userX, _margin * 2, Math.max(_margin * 2, (parent ? parent.width : 0) - width - _margin * 2))
                   : _defaultX()
    y: _userPlaced ? _clamp(_userY, _margin * 2, Math.max(_margin * 2, (parent ? parent.height : 0) - height - _margin * 2))
                   : _defaultY()

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

    // The registry publishes a stable ASCII code and the QML side owns the
    // wording, which keeps every C++ literal ASCII (MSVC code page 936).
    function _noticeText() {
        var code = customModelRegistry.noticeCode
        if (!code) {
            return ""
        }
        var detail = customModelRegistry.noticeDetail
        switch (code) {
        case "file-missing":
            return qsTr("找不到该文件或文件夹：") + detail
        case "unsupported-format":
            return qsTr("不支持的格式，仅支持 .glb / .gltf / .obj：") + detail
        case "folder-no-model":
            return qsTr("该文件夹内未找到 .glb / .gltf / .obj 模型文件：") + detail
        case "load-failed":
            // "empty-mesh" is an ASCII token from the QML loader probe, not a
            // user-facing string, so it gets its own wording here.
            return qsTr("模型加载失败：")
                   + (detail === "empty-mesh" ? qsTr("该文件中没有可显示的几何体") : detail)
        case "obj-approximate":
            return qsTr("OBJ 已加载，但未找到其材质库（.mtl），已降级为无贴图显示")
        default:
            return code
        }
    }

    // Route-B relay is only useful while the viewer is actually on screen, so
    // start/stop it with (visible && open) instead of running it unconditionally.
    function _updateRelay() {
        if (root.visible && root.open) {
            px4WsRelay.startServer(19390)
        } else {
            px4WsRelay.stopServer()
        }
    }

    // Qt Quick 3D does not support reparenting a View3D between windows, so the
    // scene is (re)created inside whichever host is active: the embedded panel,
    // or the detached top-level window.
    function _rehostScene() {
        if (_sceneItem) {
            _sceneItem.destroy()
            _sceneItem = null
        }
        var host = root.detached ? detachedWindow.contentItem : embeddedSceneHost
        _sceneItem = sceneComponent.createObject(host)
        if (!_sceneItem) {
            // A silent null here leaves a black panel with no clue why.
            console.warn("AttitudeView3D: could not instantiate the 3D scene in "
                         + (root.detached ? "the detached window" : "the embedded host"))
        }
    }

    onOpenChanged:      _updateRelay()
    onVisibleChanged:   _updateRelay()
    onDetachedChanged: {
        _rehostScene()
        _updateRelay()
    }

    Component.onCompleted: {
        _snapTimer.triggered()
        _rehostScene()
        _updateRelay()
    }

    Component.onDestruction: px4WsRelay.stopServer()

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
    //-- ws://127.0.0.1:19390/telemetry  - read-only feed for the Unity viewer.
    //-- Lives here (not in FlyViewCustomLayer.qml) because TelemetrySnapshot.js
    //-- resolves inside this module's resource directory.
    //-- Server start/stop is driven by _updateRelay() above.
    Timer {
        id: _wsBroadcastTimer
        interval: 100
        repeat: true
        running: root.visible && root.open
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
            id: titleDrag
            anchors.fill: parent

            property real _grabX:  0
            property real _grabY:  0
            property real _startX: 0
            property real _startY: 0

            onPressed: (mouse) => {
                _grabX  = mouse.x
                _grabY  = mouse.y
                _startX = root._userPlaced ? root._userX : root.x
                _startY = root._userPlaced ? root._userY : root.y
            }
            onPositionChanged: (mouse) => {
                if (!pressed) {
                    return
                }
                // Keep the bindings alive: write the raw position, let root.x/y
                // clamp it to the current fly view on every layout change.
                root._userPlaced = true
                root._userX = _startX + mouse.x - _grabX
                root._userY = _startY + mouse.y - _grabY
            }
        }

        QGCLabel {
            id: titleLabel
            anchors.left: parent.left
            anchors.leftMargin: root._margin
            anchors.right: paramButton.left
            anchors.rightMargin: root._margin
            anchors.verticalCenter: parent.verticalCenter
            elide: Text.ElideRight
            text: qsTr("3D 模型 · %1").arg(customModelRegistry.displayName)
            color: qgcPal.text
        }

        QGCLabel {
            id: modelButton
            anchors.right: resetButton.left
            anchors.rightMargin: root._margin
            anchors.verticalCenter: parent.verticalCenter
            text: qsTr("模型")
            color: qgcPal.text

            MouseArea {
                anchors.fill: parent
                onClicked: modelFileDialog.openForLoad()
            }
        }

        QGCLabel {
            id: resetButton
            anchors.right: yawButton.left
            anchors.rightMargin: root._margin
            anchors.verticalCenter: parent.verticalCenter
            text: qsTr("恢复内置")
            color: customModelRegistry.isExternal ? qgcPal.colorOrange : qgcPal.text
            opacity: customModelRegistry.isExternal ? 1.0 : 0.55

            MouseArea {
                anchors.fill: parent
                onClicked: customModelRegistry.resetToBuiltin()
            }
        }

        QGCLabel {
            id: yawButton
            anchors.right: detachButton.left
            anchors.rightMargin: root._margin
            anchors.verticalCenter: parent.verticalCenter
            text: qsTr("旋转90°")
            color: qgcPal.text
            opacity: customModelRegistry.isExternal ? 1.0 : 0.55

            MouseArea {
                anchors.fill: parent
                enabled: customModelRegistry.isExternal
                onClicked: customModelRegistry.setExternalYawDeg(customModelRegistry.externalYawDeg + 90)
            }
        }

        QGCLabel {
            id: paramButton
            anchors.right: modelButton.left
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
    // Standalone top-level window. The scene is instantiated here (not reparented)
    // while root.detached is true; see _rehostScene() above.
    Window {
        id:                     detachedWindow
        visible:                root.detached
        title:                  qsTr("3D 姿态视图 · %1").arg(root.modelId)
        width:                  root._openWidth * 1.8
        height:                 root._openWidth * 1.3
        color:                  "#16191f"
        onClosing:              root.detached = false
    }

    // Embedded host: holds the scene while the panel is not detached.
    Item {
        id: embeddedSceneHost
        visible: root.open && !root.detached
        anchors.left:   parent.left
        anchors.right:  parent.right
        anchors.top:    titleBar.bottom
        anchors.bottom: parent.bottom
        anchors.margins: root._margin
    }

    //-------------------------------------------------------------------------
    // Model pickers. QGCFileDialog returns absolute local paths for both files
    // and folders, which is exactly what ModelRegistry takes.
    QGCFileDialog {
        id: modelFileDialog
        title: qsTr("选择 3D 模型文件（.glb / .gltf / .obj）")
        nameFilters: [ qsTr("3D 模型 (*.glb *.gltf *.obj)") ]

        onAcceptedForLoad: function (file) {
            customModelRegistry.selectFile(file)
        }
    }

    // Fallback route for .gltf assets that reference sibling .bin / textures.
    QGCFileDialog {
        id: modelFolderDialog
        title: qsTr("选择模型资源文件夹（内含 .glb / .gltf / .obj）")
        selectFolder: true

        onAcceptedForLoad: function (folder) {
            customModelRegistry.selectFolder(folder)
        }
    }

    //-------------------------------------------------------------------------
    // Scene (View3D + camera + HUD + overlays). Instantiated by _rehostScene().
    Component {
        id: sceneComponent

        Item {
            id: sceneArea
            anchors.fill: parent

            // Airframe scale, matching the main Viewer3D vehicle (0.05). The raw
            // mesh spans 1280 model units, so without this the model was drawn
            // ~100 m across and sank through the ground plane at low altitude -
            // the original bug. True-size rendering (0.35 m across) was tried
            // and is sub-pixel from any usable camera distance; altitude is
            // conveyed by the Z axis, plumb line and HUD instead.
            readonly property real airframeScale: 0.05

            // World Z axis height, rounded up to the next 5 m so the pole always
            // reaches past the current altitude (5 m minimum when on the ground).
            readonly property real axisTopM: Math.max(5, Math.ceil((root._snap ? Math.max(0, root._snap.position.altitude_rel_m) : 0) / 5) * 5)

            Viewer3DCameraController {
                id: _cam
                viewportSize: Qt.size(view3d.width, view3d.height)
                fieldOfView: standAloneScene.cameraOne.fieldOfView
            }

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
                        // Just below z=0 so the floor can never z-fight with the
                        // grid lines or the ground marker drawn at ground level.
                        position.z: -0.05
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

                    //---------------------------------------------------------
                    // World Z axis at the ENU origin (home / take-off point).
                    // The grid only spans X/Y, so height had no visual reference.
                    // One tick per metre, a longer tick every 5 m; the numbers are
                    // projected to 2D by axisLabels below (Qt Quick 3D has no
                    // billboard text here).
                    //---------------------------------------------------------
                    Node {
                        id: altitudeAxis

                        // Pole. The built-in #Cylinder is Y-up (height 100, radius
                        // 50), so x=90 stands its axis up in this z-up scene.
                        Model {
                            source: "#Cylinder"
                            eulerRotation.x: 90
                            position: Qt.vector3d(0, 0, sceneArea.axisTopM * 5)
                            scale: Qt.vector3d(0.004, sceneArea.axisTopM / 10, 0.004)
                            materials: DefaultMaterial {
                                lighting: DefaultMaterial.NoLighting
                                diffuseColor: "#6fb4ff"
                            }
                        }

                        Repeater3D {
                            model: Math.round(sceneArea.axisTopM)

                            delegate: Model {
                                readonly property int  _metre: index + 1
                                readonly property bool _major: (_metre % 5) === 0

                                source: "#Cylinder"
                                eulerRotation.z: 90
                                position: Qt.vector3d(0, 0, _metre * 10)
                                scale: Qt.vector3d(0.003, (_major ? 2.0 : 0.8) / 100, 0.003)
                                materials: DefaultMaterial {
                                    lighting: DefaultMaterial.NoLighting
                                    diffuseColor: _major ? "#9fd0ff" : "#4f6f93"
                                }
                            }
                        }
                    }

                    //---------------------------------------------------------
                    // Plumb line from the airframe down to its own ground point,
                    // plus a ground disc. The camera follows the drone, so this
                    // keeps the altitude readable even when the world Z axis is
                    // out of frame.
                    //---------------------------------------------------------
                    Node {
                        id: altitudeDrop

                        readonly property real _x: djiF450.position.x
                        readonly property real _y: djiF450.position.y
                        readonly property real _z: djiF450.position.z

                        visible: _z > 0.1

                        Model {
                            source: "#Cylinder"
                            eulerRotation.x: 90
                            position: Qt.vector3d(altitudeDrop._x, altitudeDrop._y, altitudeDrop._z / 2)
                            scale: Qt.vector3d(0.002, altitudeDrop._z / 100, 0.002)
                            materials: DefaultMaterial {
                                lighting: DefaultMaterial.NoLighting
                                diffuseColor: "#7fe07f"
                            }
                        }

                        Model {
                            // Thin disc marking the ground point under the drone.
                            source: "#Cylinder"
                            position: Qt.vector3d(altitudeDrop._x, altitudeDrop._y, 0.02)
                            scale: Qt.vector3d(0.04, 0.0004, 0.04)
                            materials: DefaultMaterial {
                                lighting: DefaultMaterial.NoLighting
                                diffuseColor: "#3f7a4f"
                            }
                        }
                    }

                    // Airframe - pick model by registry id. Rendered at the real
                    // aircraft size (0.35 m across, ~0.2 m tall) so the altitude
                    // axis and the ground plane share one metric scale.
                    Node {
                        id: airframe

                        DroneModelDjiF450 {
                            id: djiF450
                            vehicle: root.vehicle
                            gpsRef: root._gpsRef ? root._gpsRef
                                                      : QtPositioning.coordinate(0, 0, 0)
                            modelScale: Qt.vector3d(sceneArea.airframeScale, sceneArea.airframeScale, sceneArea.airframeScale)
                            // Keep the 3D id label proportional to the airframe instead
                            // of leaving it 25 units (2.5 m) tall next to a 0.2 m drone.
                            labelScale: sceneArea.airframeScale / 0.05
                            visible: root.modelId === "dji_f450"
                        }
                    }
                }
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

            //-----------------------------------------------------------------
            // Model-import notice. Declared after the camera MouseArea so it
            // stays clickable, and inside the re-created scene so it shows in
            // both the embedded panel and the detached window.
            Rectangle {
                id: noticeStrip

                readonly property bool shown: root._noticeText().length > 0

                anchors.top: parent.top
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.margins: root._margin
                height: shown ? noticeText.implicitHeight + root._margin * 2 : 0
                visible: shown
                radius: 3
                clip: true
                color: customModelRegistry.noticeLevel === "error" ? "#5c1b1b"
                     : (customModelRegistry.noticeLevel === "warn" ? "#5c4a1b" : "#1b3a5c")

                QGCLabel {
                    id: noticeText
                    anchors.left: parent.left
                    anchors.right: (noticeAction.visible ? noticeAction.left : noticeDismiss.left)
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.leftMargin: root._margin
                    anchors.rightMargin: root._margin
                    wrapMode: Text.WordWrap
                    text: root._noticeText()
                    color: "white"
                    font.pointSize: ScreenTools.smallFontPointSize
                }

                QGCLabel {
                    id: noticeAction
                    anchors.right: noticeDismiss.left
                    anchors.rightMargin: root._margin * 3
                    anchors.verticalCenter: parent.verticalCenter
                    // A .gltf whose textures/.bin live next to it cannot be
                    // loaded from a single-file pick, so offer the folder route
                    // right where the failure is reported.
                    visible: customModelRegistry.noticeCode === "load-failed"
                    text: qsTr("改选文件夹")
                    color: "#ffd479"

                    MouseArea {
                        anchors.fill: parent
                        onClicked: modelFolderDialog.openForLoad()
                    }
                }

                QGCLabel {
                    id: noticeDismiss
                    anchors.right: parent.right
                    anchors.rightMargin: root._margin
                    anchors.verticalCenter: parent.verticalCenter
                    text: qsTr("✕")
                    color: "white"

                    MouseArea {
                        anchors.fill: parent
                        onClicked: customModelRegistry.dismissNotice()
                    }
                }
            }

            //-----------------------------------------------------------------
            // HUD (left-top, complementary to on-model labels)
            //   line 1 : flight mode · arm state · attitude   (primary)
            //   row 2  : altitude / groundspeed / climb / battery / GPS in
            //            separate columns so labels can never overlap   (readout)
            Rectangle {
                anchors.left: parent.left
                anchors.top: noticeStrip.visible ? noticeStrip.bottom : parent.top
                anchors.margins: root._margin
                width: hudColumn.width + root._margin * 2
                height: hudColumn.height + root._margin * 2
                color: Qt.rgba(0, 0, 0, 0.5)
                radius: 3

                Column {
                    id: hudColumn
                    anchors.centerIn: parent
                    spacing: root._margin

                    QGCLabel {
                        text: {
                            var s = root._snap
                            if (!s) return qsTr("等待载具…")
                            var mode = s.status.flight_mode || qsTr("未知模式")
                            var arm = s.status.armed ? qsTr("已解锁") : qsTr("未解锁")
                            var att = qsTr("姿态 ") +
                                      "R" + root._fmt(s.attitude_deg.roll, 1, qsTr("°")) +
                                      " P" + root._fmt(s.attitude_deg.pitch, 1, qsTr("°")) +
                                      " Y" + root._fmt(s.attitude_deg.yaw, 1, qsTr("°"))
                            return mode + " · " + arm + "    " + att
                        }
                        color: (root._snap && root._snap.status.armed) ? "#ff6666" : "#7fe07f"
                        font.pointSize: ScreenTools.mediumFontPointSize
                    }

                    Row {
                        spacing: root._margin * 3

                        Column {
                            spacing: 1
                            QGCLabel {
                                text: qsTr("高度")
                                color: "#9aa3b2"
                                font.pointSize: ScreenTools.smallFontPointSize
                            }
                            QGCLabel {
                                text: root._snap ? root._fmt(root._snap.position.altitude_rel_m, 1, " m") : "--"
                                color: "white"
                                font.pointSize: ScreenTools.defaultFontPointSize
                            }
                        }

                        Column {
                            spacing: 1
                            QGCLabel {
                                text: qsTr("地速")
                                color: "#9aa3b2"
                                font.pointSize: ScreenTools.smallFontPointSize
                            }
                            QGCLabel {
                                text: root._snap ? root._fmt(root._snap.speed.ground_m_s, 1, " m/s") : "--"
                                color: "white"
                                font.pointSize: ScreenTools.defaultFontPointSize
                            }
                        }

                        Column {
                            spacing: 1
                            QGCLabel {
                                text: qsTr("爬升")
                                color: "#9aa3b2"
                                font.pointSize: ScreenTools.smallFontPointSize
                            }
                            QGCLabel {
                                text: root._snap ? root._fmt(root._snap.speed.climb_m_s, 1, " m/s") : "--"
                                color: "white"
                                font.pointSize: ScreenTools.defaultFontPointSize
                            }
                        }

                        Column {
                            spacing: 1
                            QGCLabel {
                                text: qsTr("电量")
                                color: "#9aa3b2"
                                font.pointSize: ScreenTools.smallFontPointSize
                            }
                            QGCLabel {
                                text: root._snap ? root._fmt(root._snap.status.battery_pct, 0, " %") : "--"
                                color: "white"
                                font.pointSize: ScreenTools.defaultFontPointSize
                            }
                        }

                        Column {
                            spacing: 1
                            QGCLabel {
                                text: qsTr("GPS")
                                color: "#9aa3b2"
                                font.pointSize: ScreenTools.smallFontPointSize
                            }
                            QGCLabel {
                                text: root._snap ? root._fmt(root._snap.status.gps_sats, 0, qsTr(" 星")) : "--"
                                color: "white"
                                font.pointSize: ScreenTools.defaultFontPointSize
                            }
                        }
                    }

                    //---------------------------------------------------------
                    // Inline alerts (nearest-to-flight presentation, Q4): up to
                    // three highest-level active alerts from the local rule
                    // engine, same wording as the panel banner (B1).
                    //---------------------------------------------------------
                    Column {
                        id: hudAlerts
                        spacing: 2

                        readonly property bool _engineOk: customAlertEngine.state === "ok"
                        readonly property var  _list: customAlertEngine.activeAlerts

                        QGCLabel {
                            visible: !hudAlerts._engineOk
                            text: qsTr("告警引擎已停用")
                            color: "#9aa3b2"
                            font.pointSize: ScreenTools.smallFontPointSize
                        }

                        Repeater {
                            model: {
                                var list = []
                                if (hudAlerts._engineOk) {
                                    for (var i = 0; i < Math.min(hudAlerts._list.length, 3); i++) {
                                        list.push(hudAlerts._list[i])
                                    }
                                }
                                return list
                            }

                            delegate: QGCLabel {
                                required property var modelData
                                text: "[" + AlertText.ruleName(modelData.ruleId) + "] " + AlertText.text(modelData)
                                color: AlertText.levelColor(modelData.level)
                                font.pointSize: ScreenTools.smallFontPointSize
                            }
                        }
                    }
                }
            }

            //-----------------------------------------------------------------
            // Z-axis metre labels: project the major ticks of the world Z axis
            // to screen. Qt Quick 3D 6.11 has no billboard text, and this is the
            // same View3D.mapFrom3DScene() route used for the on-model labels.
            Item {
                id: axisLabels
                anchors.fill: view3d
                visible: root.open

                // Projection is derived from the camera controller state rather
                // than View3D.mapFrom3DScene(). The latter queries the live scene
                // camera, which CameraLightModel is still repositioning when this
                // binding first runs, so it can latch a stale point that is never
                // refreshed. The controller state is the same input the camera
                // rig consumes, so the result is always in sync.
                readonly property string _cameraKey: _cam.heading + "," + _cam.tilt + "," + _cam.distance + ","
                                                   + _cam.orbitCenter.x + "," + _cam.orbitCenter.y + ","
                                                   + _cam.orbitCenter.z + "," + width + "," + height

                readonly property var _marks: {
                    // Keep the binding live: the camera key is the only observable
                    // input that affects the result.
                    var unused = _cameraKey
                    var out = []
                    var lastPy = 1e9
                    // One label per metre, then drop any that would land closer
                    // than ~16 px to the previous one so distant views stay legible.
                    for (var m = 1; m <= Math.round(sceneArea.axisTopM); m++) {
                        var p = axisLabels._project(0, 0, m * 10)
                        if (!p || p.x < 0 || p.y < 0 || p.x > width || p.y > height) {
                            continue
                        }
                        if (lastPy - p.y < 16) {
                            continue
                        }
                        lastPy = p.y
                        out.push({ metre: m, px: p.x, py: p.y, major: (m % 5) === 0 })
                    }
                    return out
                }

                /// Scene position (ENU, z-up) -> item pixel position, or null
                /// when the point is behind the camera. Mirrors the orbit rig in
                /// CameraLightModel: yaw about z, then pitch, camera at distance
                /// along the orbit direction looking back at the orbit center.
                function _project(sceneX, sceneY, sceneZ) {
                    if (width <= 0 || height <= 0 || _cam.distance <= 0) {
                        return null
                    }
                    var d2r = Math.PI / 180
                    var sinH = Math.sin(_cam.heading * d2r)
                    var cosH = Math.cos(_cam.heading * d2r)
                    var sinT = Math.sin(_cam.tilt * d2r)
                    var cosT = Math.cos(_cam.tilt * d2r)
                    var c = _cam.orbitCenter
                    var cx = c.x + sinT * sinH * _cam.distance
                    var cy = c.y - sinT * cosH * _cam.distance
                    var cz = c.z + cosT * _cam.distance
                    var vx = sceneX - cx
                    var vy = sceneY - cy
                    var vz = sceneZ - cz
                    // Depth along the view direction (-orbit direction).
                    var depth = -(vx * sinT * sinH - vy * sinT * cosH + vz * cosT)
                    if (depth <= 0.01) {
                        return null
                    }
                    var right = vx * cosH + vy * sinH
                    var up = -vx * cosT * sinH + vy * cosT * cosH + vz * sinT
                    var tanHalf = Math.tan(standAloneScene.cameraOne.fieldOfView * d2r / 2)
                    var aspect = width / Math.max(1, height)
                    var ndcX = right / (depth * tanHalf * aspect)
                    var ndcY = up / (depth * tanHalf)
                    if (!isFinite(ndcX) || !isFinite(ndcY)) {
                        return null
                    }
                    return Qt.point(width * 0.5 * (1 + ndcX), height * 0.5 * (1 - ndcY))
                }

                Repeater {
                    model: axisLabels._marks

                    delegate: QGCLabel {
                        required property var modelData

                        x: modelData.px + 6
                        // Keep the label inside the view even when the tick sits
                        // right at the top or bottom edge of the frame.
                        y: Math.max(0, Math.min(axisLabels.height - height, modelData.py - height / 2))
                        text: modelData.metre + " m"
                        color: modelData.major ? "#9fd0ff" : "#6f8dab"
                        font.pointSize: modelData.major ? ScreenTools.smallFontPointSize
                                                        : ScreenTools.smallFontPointSize * 0.85
                    }
                }
            }

            //-----------------------------------------------------------------
            // On-model labels: project drone 3D position to screen via
            // View3D.mapFrom3DScene(). Qt 6.11 native, no Text3D dependency.
            Item {
                id: labelsOverlay
                anchors.fill: view3d
                visible: root.showModelLabels && root.open && root.vehicle !== null && _projValid

                // Vehicle model -> screen projection. Re-evaluated on every 10 Hz
                // telemetry tick (root._snap) and on View3D resize, so it never
                // keeps a stale point captured before the camera was resolvable.
                readonly property point _droneScreen: {
                    if (!root._snap || view3d.width <= 0 || view3d.height <= 0) {
                        return Qt.point(-100000, -100000)
                    }
                    var p = view3d.mapFrom3DScene(djiF450.position)
                    if (!p || isNaN(p.x) || isNaN(p.y)) {
                        return Qt.point(-100000, -100000)
                    }
                    return p
                }
                readonly property bool _projValid: _droneScreen.x > -50000

                Rectangle {
                    id: rpyLabel
                    x: labelsOverlay._droneScreen.x - width / 2
                    y: labelsOverlay._droneScreen.y - height - 10
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
                        font.pointSize: ScreenTools.defaultFontPointSize
                    }
                }

                Rectangle {
                    id: speedLabel
                    x: labelsOverlay._droneScreen.x - width / 2
                    y: labelsOverlay._droneScreen.y + 10
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
                        font.pointSize: ScreenTools.defaultFontPointSize
                    }
                }

                Rectangle {
                    id: statusLabel
                    x: labelsOverlay._droneScreen.x - width / 2
                    y: labelsOverlay._droneScreen.y + height + 14
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
                        font.pointSize: ScreenTools.defaultFontPointSize
                    }
                }
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

            Component.onCompleted: {
                // Small near plane so the airframe is never clipped when the
                // user zooms all the way in.
                standAloneScene.cameraOne.clipNear = 0.2
                // Frame the airframe itself, not the ENU origin: the panel can be
                // opened while the vehicle is already airborne. 15 m keeps the
                // 64-unit airframe comfortably framed (at 2 m the camera sat
                // inside its bounding sphere and nothing was visible).
                _cam.lookAt(djiF450.position, 35, 55, 150)
            }
        }
    }
}
