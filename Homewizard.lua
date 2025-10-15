-- Masterclass for Batteries

local PowerDevice = require("PowerDevice")

local P1meter = require("p1meter")

local mqtt_reader = require("mqtt_reader")
local util = require("util")

local Homewizard = PowerDevice:extend{
    __name = "Homewizard",
    Inverter = nil,
    internal_state = "",
}

function Homewizard:init()
    local Device = self.Device
    Device.ip = util.getIPfromURL(Device.host)
    if Device.host then
        self.P1meter = P1meter:new{host = Device.ip}
    end
end

--------------------------------------------------------------------------

-- returns "give", "take", "idle", "can_take", "can_give"
function Homewizard:getState()
    return ""
end

-- if internal is set, get internal Voltage, else AC-Voltage
function Homewizard:getVoltage(internal)
end

-- returns positive if chargeing, negative if dischargeing
-- if internal is set, get internal current, else AC-current
function Homewizard:getCurrent(internal)
end

-- always AC
function Homewizard:setMaxDischargePower(max_power)
end

-- always AC
function Homewizard:getMaxDischargePower()
end

-- returns positive if buying, negative if selling energy
-- second argument is true if old data
function Homewizard:getPower(internal)
    return self.P1meter:getCurrentPower(), not self.P1meter:is_data_new()
end

-- always AC
function Homewizard:getMaxChargePower()
end

return Homewizard
