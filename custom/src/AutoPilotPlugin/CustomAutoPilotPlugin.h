#pragma once

#include "PX4AutoPilotPlugin.h"

class Vehicle;

/// Thin PX4AutoPilotPlugin subclass kept for the custom build's factory chain
/// (CustomFirmwarePlugin → new CustomAutoPilotPlugin). It used to trim the
/// config component list behind an advanced-mode gate — that caused the vehicle
/// setup page to show only Safety (and sometimes none) because the override
/// also omitted ActuatorComponent/JoystickComponent/FlightBehavior/ESP8266/
/// Syslink that the parent adds. We now delegate straight to the parent so
/// the user gets the full PX4 config surface like the stock app.
class CustomAutoPilotPlugin : public PX4AutoPilotPlugin
{
    Q_OBJECT

public:
    explicit CustomAutoPilotPlugin(Vehicle *vehicle, QObject *parent = nullptr);

    const QVariantList &vehicleComponents() override;
};
