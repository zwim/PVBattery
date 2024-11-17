-- Inverter.lua

local Switch = require("switch")
local AntBMS = require("antbms")

local util = require("util")

local Inverter = {
    skip = false,
    host = "",
    bms_host = "",
    dynamic_load = false,
    static_load = 0,

    -- will get initialized by new
    Switch = nil,
    BMS = nil,
}

function Inverter:new(o)
    o = o or {}   -- create object if user does not provide one
    setmetatable(o, self)
    self.__index = self

    if o.host and o.host ~= "" then
        o.Switch = Switch:new{host = o.host}
    end
    if o.bms_host and o.bms_host ~= "" then
        o.BMS = AntBMS:new{host = o.bms_host}
    end

    return o
end

function Inverter:clearDataAge()
    self.Switch:clearDataAge()
end

function Inverter:getCurrentPower()
   return self.Switch:getPower()
end

function Inverter:getMaxPower()
   return self.Switch:getMaxPower()
end

function Inverter:getPowerState()
   return self.Switch:getPowerState()
end

function Inverter:startDischarge(req_power)
    if self.time_controlled or self.BMS:readyToDischarge() then
        self.BMS:setPower(req_power or 10) -- if no power requested, start with minimal power
        util.sleep_time(1)
        self.Switch:toggle("on")
    end
end

function Inverter:stopDischarge()
    self.BMS:setPower(0)
    util.sleep_time(0.5)
    self.Switch:toggle("off")
end

function Inverter:readyToDischarge()
    if self.time_controlled then
        return true
    end

    local start_discharge, continue_discharge = self.BMS:readyToDischarge()
    if not continue_discharge then
        self:stopDischarge()
    end
    return start_discharge
end

return Inverter
