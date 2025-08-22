
local Switch = require("switch")
local AntBMS = require("antbms")

local util = require("util")

local Inverter = Switch:extend{
    bms_host = "",
    max_power = 0,
    min_power = 0,
    BMS = nil, -- will get initialized by new
}

function Inverter:init()
    if self.bms_host ~= "" then
        self.BMS = AntBMS:new{host = self.bms_host}
    end
    return self
end

function Inverter:startDischarge(req_power)
    if not self.BMS then return end

    if self.time_controlled then
        self.BMS:setPower(req_power or 10) -- if no power requested, start with minimal power
        util.sleep_time(1)
        self:toggle("on")
        return
    end
    local start_discharge, continue_discharge = self.BMS:readyToDischarge()
    if start_discharge or continue_discharge then
        self.BMS:setPower(req_power or 10) -- if no power requested, start with minimal power
        util.sleep_time(1)
        self:toggle("on")
        return
    end
end

function Inverter:safeStartDischarge(req_power)
    if self:getPowerState() ~= "on" then self:startDischarge(req_power) end
end

function Inverter:stopDischarge()
    if self.BMS then
        self.BMS:setPower(0)
        self.BMS:disableDischarge()
        util.sleep_time(0.5)
    end
    self:toggle("off")
end

function Inverter:safeStopDischarge()
    if self:getPowerState() ~= "off" then self:stopDischarge() end
end

function Inverter:readyToDischarge()
    if self.time_controlled then
        return true
    end

    local start_discharge, continue_discharge
    if self.BMS then
        start_discharge, continue_discharge = self.BMS:readyToDischarge()
    end

    if not continue_discharge then
        self:stopDischarge()
    end
    return start_discharge
end

return Inverter
