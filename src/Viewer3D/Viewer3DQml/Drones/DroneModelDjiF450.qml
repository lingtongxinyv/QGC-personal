import QtPositioning
import QtQuick3D
import QtQuick3D.AssetUtils

import QGroundControl
import QGroundControl.Controls
import QGroundControl.Viewer3D

Node {
    id: body

    function finiteOr(value, fallback) {
        return Number.isFinite(value) ? value : fallback;
    }

    // Two model sources live behind this component: the built-in dji_f450
    // airframe, or a user-imported asset picked in the floating 3D window.
    // `customModelRegistry` is a root-context property of the custom build
    // (CustomPlugin::createQmlApplicationEngine) and is the single source of
    // truth for the selection. This component is instantiated by BOTH the
    // floating 3D window and the built-in Viewer3D, so switching here covers
    // both views while each view still owns its own scene instance.
    readonly property bool   externalModel:  customModelRegistry.isExternal
    readonly property string externalSource: customModelRegistry.externalUrl

    property int _angleAnimationDuration: 100
    property int _poseAnimationDuration: 200
    property double altitudeBias: 0
    property var gpsRef: QtPositioning.coordinate(0, 0, 0)
    property double heading: vehicle ? finiteOr(vehicle.heading.value, 0) : 0
    property vector3d modelScale: Qt.vector3d(1, 1, 1)
    property double pitch: vehicle ? finiteOr(vehicle.pitch.value, 0) : 0
    property double pose_x: finiteOr(geo2Enu.localCoordinate.x, 0) * 10
    property double pose_y: finiteOr(geo2Enu.localCoordinate.y, 0) * 10
    // Scene coordinates are meters - use rawValue since cooked value follows the user's units setting.
    // Altitude 0 is ground level: groundClearance lifts the airframe so its lowest
    // point rests on the ground plane, and negative relative altitude is clamped
    // to it so the model can never sink through the ground (the numeric readout
    // still shows the true value).
    property double pose_z: Math.max(0, finiteOr((vehicle ? vehicle.altitudeRelative.rawValue : 0), 0) + altitudeBias) * 10 + groundClearance
    property double roll: vehicle ? finiteOr(vehicle.roll.value, 0) : 0
    property real externalTargetExtent: 1000
    property var vehicle

    // Optional scaling for the 3D vehicle-id label. A view that renders the
    // airframe at a small physical scale (the floating attitude window frames a
    // 0.35 m airframe) sets this below 1, otherwise the label ends up several
    // times taller than the model itself.
    property real labelScale: 1

    // Vertical distance from the model origin down to its lowest point, in scene
    // units. Altitude 0 means "on the home/ground level", so without this the
    // airframe is drawn half-way through the ground plane - the model origin is
    // its geometric centre, not its landing gear. Built-in mesh: 720 units tall
    // in model space (rotation x=90 maps model +Y onto scene +Z), so half of it
    // is 360 * modelScale. Imported assets are centred on their bounds and keep
    // the same x=90 correction, so half of their scaled Y extent is used.
    readonly property real groundClearance: externalModel
        ? externalLoader._sizeY * externalLoader._scale * 0.5
        : 360 * modelScale.y

    rotation: Quaternion.fromEulerAngles(Qt.vector3d(0, 0, (90 - body.heading)))

    Behavior on rotation {
        QuaternionAnimation {
            duration: _angleAnimationDuration
            easing.amplitude: 3.0
            easing.period: 2.0
            easing.type: Easing.Linear
        }
    }

    Viewer3DGeoCoordinateType {
        id: geo2Enu

        coordinate: vehicle ? vehicle.coordinate : QtPositioning.coordinate(0, 0, 0)
        gpsRef: body.gpsRef
    }

    Node {
        id: labelText

        eulerRotation.x: 90
        position.x: -10
        position.z: 30
        scale: Qt.vector3d(body.labelScale, body.labelScale, body.labelScale)

        // Plain Text instead of QGCLabel: QGCLabel sets font.pointSize, which
        // conflicts with the explicit pixelSize needed for 3D scene scaling.
        Text {
            color: "red"
            font.family: ScreenTools.normalFontFamily
            font.pixelSize: 25
            text: vehicle ? Number(vehicle.id) : ""
        }
    }

    position: Qt.vector3d(body.pose_x, body.pose_y, body.pose_z)

    Behavior on position {
        Vector3dAnimation {
            duration: _poseAnimationDuration
            easing.type: Easing.Linear
        }
    }

    Node {
        id: rollPitchRotationNode

        rotation: Quaternion.fromEulerAngles(Qt.vector3d(body.roll, -body.pitch, 0))

        Behavior on rotation {
            QuaternionAnimation {
                duration: _angleAnimationDuration
                easing.amplitude: 3.0
                easing.period: 2.0
                easing.type: Easing.Linear
            }
        }

        //---------------------------------------------------------------------
        // Built-in airframe (dji_f450). Rotations below are tuned for the
        // shipped mesh set; do not reuse them for imported assets.
        Node {
            eulerRotation {
                x: 90
            }

            visible: !body.externalModel

            Node {
                id: innerNode

                eulerRotation: Qt.vector3d(0, 90, 0)
                scale: body.modelScale

                Node {
                    eulerRotation: Qt.vector3d(0, 45, 0)
                    position: Qt.vector3d(-640, -360, -155)

                    // Arms
                    DronePart { meshSource: "Djif450/DroneModel_arm_1/node.mesh"; baseColor: "white"; metalness: 0.2 }
                    DronePart { meshSource: "Djif450/DroneModel_arm_2/node.mesh"; baseColor: "red"; metalness: 0.2 }
                    DronePart { meshSource: "Djif450/DroneModel_arm_3/node.mesh"; baseColor: "red"; metalness: 0.2 }
                    DronePart { meshSource: "Djif450/DroneModel_arm_4/node.mesh"; baseColor: "red"; metalness: 0.2 }

                    // Motors
                    DronePart { meshSource: "Djif450/DroneModel_BLDC_1/node.mesh"; baseColor: "black"; indexOfRefraction: 2.0; metalness: 0.9 }
                    DronePart { meshSource: "Djif450/DroneModel_BLDC_2/node.mesh"; baseColor: "black"; indexOfRefraction: 2.0; metalness: 0.9 }
                    DronePart { meshSource: "Djif450/DroneModel_BLDC_3/node.mesh"; baseColor: "black"; indexOfRefraction: 2.0; metalness: 0.9 }
                    DronePart { meshSource: "Djif450/DroneModel_BLDC_4/node.mesh"; baseColor: "black"; indexOfRefraction: 2.0; metalness: 0.9 }

                    // Frame
                    DronePart { meshSource: "Djif450/DroneModel_Base_Top_1/node.mesh"; baseColor: "black"; indexOfRefraction: 2.0; metalness: 0.9 }
                    DronePart { meshSource: "Djif450/DroneModel_Base_bottom_1/node.mesh"; baseColor: "gray"; indexOfRefraction: 2.0; metalness: 0.9 }

                    // Propellers — counter-rotating pairs
                    AnimatedPropeller { meshSource: "Djif450/DroneModel_propeller22_1/node.mesh"; pivotPoint: Qt.vector3d(343.50, 404.07, 783.00); rotationTarget: -360; flightMode: vehicle ? (vehicle.armed + vehicle.flying) : 0 }
                    AnimatedPropeller { meshSource: "Djif450/DroneModel_propeller22_2/node.mesh"; pivotPoint: Qt.vector3d(343.42, 404.16, 333.06); rotationTarget: -360; flightMode: vehicle ? (vehicle.armed + vehicle.flying) : 0 }
                    AnimatedPropeller { meshSource: "Djif450/DroneModel_propeller2_2/node.mesh"; pivotPoint: Qt.vector3d(119.51, 402.66, 557.75); rotationTarget: 360; flightMode: vehicle ? (vehicle.armed + vehicle.flying) : 0 }
                    AnimatedPropeller { meshSource: "Djif450/DroneModel_propeller2_7/node.mesh"; pivotPoint: Qt.vector3d(567.97, 404.00, 558.26); rotationTarget: 360; flightMode: vehicle ? (vehicle.armed + vehicle.flying) : 0 }
                }
            }
        }

        //---------------------------------------------------------------------
        // User-imported asset (.glb / self-contained .gltf / .obj, or the
        // .gltf picked from a resource folder). RuntimeLoader does no
        // automatic scaling, centering or re-orientation, so it is all done
        // here from the reported bounds.
        Node {
            id: externalRoot

            visible: body.externalModel
            // Vertical trim for assets whose nose does not sit on the usual
            // glTF forward axis. Applied about the scene up axis, outside the
            // Y-up -> Z-up correction below.
            eulerRotation.z: customModelRegistry.externalYawDeg

            Node {
                eulerRotation {
                    x: 90
                }

                RuntimeLoader {
                    id: externalLoader

                    // Read-only consumer: nothing here is ever fed back to the
                    // relay, the vehicle or any other view.
                    source: body.externalSource

                    readonly property real _sizeX: bounds.maximum.x - bounds.minimum.x
                    readonly property real _sizeY: bounds.maximum.y - bounds.minimum.y
                    readonly property real _sizeZ: bounds.maximum.z - bounds.minimum.z
                    readonly property real _extent: Math.max(_sizeX, Math.max(_sizeY, _sizeZ))
                    // Bounds are not valid until the asset is loaded, so fall
                    // back to the raw size for that first instant instead of
                    // collapsing the node to zero.
                    readonly property real _normalize: (_extent > 0.001)
                                                        ? (body.externalTargetExtent / _extent) : 1.0
                    readonly property real _scale: _normalize * body.modelScale.x

                    scale: Qt.vector3d(_scale, _scale, _scale)
                    // Bounds are in the asset's own frame, so the scale is not
                    // part of the offset used to bring its center to the origin.
                    position: Qt.vector3d(
                        -(bounds.minimum.x + bounds.maximum.x) * 0.5 * _scale,
                        -(bounds.minimum.y + bounds.maximum.y) * 0.5 * _scale,
                        -(bounds.minimum.z + bounds.maximum.z) * 0.5 * _scale)

                    onStatusChanged: _report()
                    onBoundsChanged: _report()

                    // Some importers report Success for a file they parsed
                    // into an empty scene (a damaged .obj is the common case),
                    // so status alone cannot be trusted. Bounds are not
                    // available on the same tick as the status change, hence
                    // the short grace period before declaring the asset empty.
                    Timer {
                        id: emptyCheckTimer

                        interval: 1500
                        repeat: false
                        onTriggered: {
                            if (externalLoader.status === RuntimeLoader.Success
                                    && externalLoader._extent <= 0.001) {
                                customModelRegistry.reportLoadResult(false, "empty-mesh", String(externalLoader.source))
                            }
                        }
                    }

                    function _report() {
                        if (status === RuntimeLoader.Error) {
                            emptyCheckTimer.stop()
                            customModelRegistry.reportLoadResult(false, errorString, String(externalLoader.source))
                            return
                        }
                        if (status !== RuntimeLoader.Success) {
                            return
                        }
                        if (_extent > 0.001) {
                            emptyCheckTimer.stop()
                            customModelRegistry.reportLoadResult(true, "", String(externalLoader.source))
                        } else if (!emptyCheckTimer.running) {
                            emptyCheckTimer.start()
                        }
                    }
                }
            }
        }
    }
}
