
local Switch = require("switch")

local BatteryCharge1Switch = Switch:new()
local BatteryCharge2Switch = Switch:new()
local BatteryInverterSwitch = Switch:new()
local GarageInverterSwitch = Switch:new()

BatteryCharge1Switch:init("battery-charger.lan")
BatteryCharge1Switch:getEnergy()
print("Charger energy today", BatteryCharge1Switch.Energy.Today, "kWh")
print("Charger power", BatteryCharge1Switch:getPower(), "W")


BatteryCharge2Switch:init("battery-charger2.lan")
BatteryCharge2Switch:getEnergy()
print("Charger2 energy today", BatteryCharge2Switch.Energy.Today, "kWh")
print("Charger2 power", BatteryCharge2Switch:getPower(), "W")

BatteryInverterSwitch:init("battery-inverter.lan")
--util:log("toggle", BatteryInverterSwitch:toggle("off"))
BatteryInverterSwitch:getEnergy()
print("Discharger energy today", BatteryInverterSwitch.Energy.Today, "kWh")
print("Discharger power", BatteryInverterSwitch:getPower(), "W")

GarageInverterSwitch:init("192.168.1.30")
GarageInverterSwitch:getEnergy()
print("Garage inverter energy today", GarageInverterSwitch.Energy.Today, "kWh")
print("Garage inverter power", GarageInverterSwitch:getPower(), "W")
