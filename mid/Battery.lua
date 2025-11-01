-- Masterclass for Batteries

local PowerDevice = require("mid/PowerDevice")
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

-- An absolutely straightforward battery charging optimization strategy:
-- The maximum allowed SOC (state of charge) is adjusted to the time (depending of the sun position)
--
-- 1. From sunrise until shortly after the solar zenith (peak sun), change the maximum SOC to 60%.
-- 2. Starting from the end of step 1, up to 2.5 hours before sunset, the maximum SOC
--    is linearly increased to 80%.
-- 3. From that point on, change the maximum SOC to 100%.
--
-- There you have it. Optimizing your battery's life, one strategic percentage at a time.
--
-- ajustable parameters:
local OFFSET_TO_HIGH_NOON = -1/4 -- in hours
local OFFSET_TO_SUNSET = -2.5 -- in hours
local FIRST_MAX_SOC_LEVEL = 60 -- Percent
local SECOND_MAX_SOC_LEVEL = 80 -- Percent
function Battery:getDesiredMaxSOC(current_time_h)
    current_time_h = current_time_h or SunTime:getTimeInHours()

    local time_1_h = SunTime.noon + OFFSET_TO_HIGH_NOON
    if current_time_h < time_1_h then
        return math.min(FIRST_MAX_SOC_LEVEL, self.Device.SOC_max)
    end

    local time_2_h = SunTime.set + OFFSET_TO_SUNSET
    if time_2_h < time_1_h then
        time_2_h = time_1_h + 0.5
    end
    if current_time_h > time_2_h then
        return self.Device.SOC_max
    end

    local y = SECOND_MAX_SOC_LEVEL - FIRST_MAX_SOC_LEVEL
    local x = time_2_h - time_1_h
    local k = y / x

    local t = current_time_h - time_1_h

    local max_SOC = FIRST_MAX_SOC_LEVEL + t * k
    return max_SOC
--        return SECOND_MAX_SOC_LEVEL
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
function Battery:getEnergyTotal()
    error("not impl")
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

local function example()
    local Device = {
        name = "VenusE 1",
        typ = "battery",
        brand = "marstek",
        host = "Venus-E1-modbus",
        -- ip = "192.168.0.208",
        port = 502,
        slaveId = 1,
        charge_max_power = 2492,
        discharge_max_power = 2492,
        SOC_min = 15,
        SOC_max = 100,
        leave_mode = "auto",
    }
    SunTime.noon = 11.6666
    SunTime.set = 17.9333

    local M = Battery:new{Device = Device}
    print("check getDesiredMaxSOC:", M:getDesiredMaxSOC( SunTime:getTimeInHours() ))
end

if arg[0]:find("Battery.lua") then
    example()
end


return Battery
