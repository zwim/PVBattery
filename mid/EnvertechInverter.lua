-- Masterclass for Batteries

local mqtt_reader = require("base/mqtt_reader")

local InverterClass = require("base/inverter")
local PowerDevice = require("mid/PowerDevice")
local SunTime = require("suntime/suntime")

local EnvertechInverter = PowerDevice:extend{
    __name = "EnvertechInverter",
    Inverter = nil,
    internal_state = "",
}

function EnvertechInverter:init()
    if PowerDevice.init then PowerDevice.init(self) end

    local Device = self.Device
    if Device.inverter_switch then
        self.Inverter = InverterClass:new{
            host = Device.inverter_switch,
            min_power = Device.inverter_min_power,
            time_controlled = Device.inverter_time_controlled,
        }
    end
    self:log(3, "Initializing '" .. tostring(Device.name) .. "' and waiting for mqtt sync")
    self:log(3,"got messages #" , mqtt_reader:sleepAndCallMQTT(2))
end

--------------------------------------------------------------------------

-- returns "give", "take", "idle", "can_take", "can_give"
function EnvertechInverter:getState()
    local result = {}
    if self.Device.inverter_time_controlled then
        local current_power = self:getPower()
        if current_power > 0 then
            result.give = true
        end
        if current_power < 0 then
            self:log(0, "ERROR can not take energy")
            result.take = true
        end
        if SunTime:isDayTime() then
            result.can_give = true
        end
        if not result.give and not result.take then
            result.idle = true
        end
    else
        result.give = true
    end
    return result
end

-- turns on balancing
function EnvertechInverter:balance()
end

-- if internal is set, get internal Voltage, else AC-Voltage
function EnvertechInverter:getVoltage(internal)
end

-- returns positive if chargeing, negative if dischargeing
-- if internal is set, get internal current, else AC-current
function EnvertechInverter:getCurrent(internal)
end

-- always AC
function EnvertechInverter:getEnergyTotal()
    return self.Inverter:getEnergyTotal()
end

-- always AC
function EnvertechInverter:setMaxDischargePower(max_power)
end

-- always AC
function EnvertechInverter:getMaxDischargePower()
end

-- returns positive if giving
-- if internal is set, get internal power, else AC-power
function EnvertechInverter:getPower(internal)
    local discharging_power = self.Inverter:getPower()
    return discharging_power
end

-- always AC
function EnvertechInverter:getMaxChargePower()
    return -self.Inverter:getMaxPower()
end

return EnvertechInverter
