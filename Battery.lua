-- Masterclass for Batteries

local PowerDevice = require("PowerDevice")
local SunTime = require("suntime/suntime")

local Battery = PowerDevice:extend{
    __name = "Battery",
    internal_state = "",
}

function Battery:new(o)
    o = self:extend(o)
    if o.host then
        o.host = o.host:lower()
    end
    if o.init then
        o:init()
    end
    return o
end

function Battery:init()
    if not self.max_power then
        self.max_power = 0
    end
end

--------------------------------------------------------------------------
-- req_power < 0 push energy to the battery
-- req_power > 0 get power from the battery
-- req_power = 0 set battery to idle
function Battery:setPower(req_power)
end

function Battery:take(req_power)
end

function Battery:getDesiredMaxSOC()
    local current_time_h = SunTime:getTimeInHours()
    if current_time_h < SunTime.noon - 0.25 then    -- 15 minutes before high noon
        return math.min(60, self.Device.SOC_max)
    elseif current_time_h > SunTime.set - 2.5 then  -- 2:30 hours befor sunset
        return self.Device.SOC_max
    else
        return 60 + math.clamp(self.Device.SOC_max - 60, 0, 100)
            * (current_time_h - SunTime.noon) / (SunTime.set - SunTime.noon)
    end
end


function Battery:give(req_power)
end

function Battery:getSOC()
end

-- returns "give", "take", "idle", "chargeable", "can_give", "can_take"
function Battery:getState()
end

-- returns positive if chargeing, negative if dischargeing
-- if internal is set, get internal power, else AC-power
function Battery:getPower(internal)
end

-- turns on balancing
function Battery:balance()
end

-- if internal is set, get internal Voltage, else AC-Voltage
function Battery:getVoltage(internal)
end

-- returns positive if chargeing, negative if dischargeing
-- if internal is set, get internal current, else AC-current
function Battery:getCurrent(internal)
end

-- always AC
function Battery:getEnergyStored()
end

-- always AC
function Battery:setMaxDischargePower(max_power)
end

-- always AC
function Battery:getMaxDischargePower()
end

-- always AC
function Battery:setMaxChargePower(max_power)
end

-- always AC
function Battery:getMaxChargePower()
end

-- in percent
function Battery:setChargeCutOff(percent)
end

-- in percent
function Battery:getChargeCutOff()
end

-- in percent
function Battery:setDischargeCutOff(percent)
end

-- in percent
function Battery:getDischargeCutOff()
end

return Battery
