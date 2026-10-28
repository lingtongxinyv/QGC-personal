#include "CustomAutoPilotPlugin.h"
#include "Vehicle.h"

CustomAutoPilotPlugin::CustomAutoPilotPlugin(Vehicle *vehicle, QObject *parent)
    : PX4AutoPilotPlugin(vehicle, parent)
{
}

const QVariantList &CustomAutoPilotPlugin::vehicleComponents()
{
    // Full PX4 component list (Actuator/Motor switch, FlightBehavior,
    // Joystick, ESP8266, Syslink, sorted order) — delegate unchanged.
    return PX4AutoPilotPlugin::vehicleComponents();
}
