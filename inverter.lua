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
    BMS = nil,
}


local Inverter = Switch:extend{
    bms_host = "",
    max_power = 0,
    min_power = 0,
    -- will get initialized by new
    BMS = nil,
}

function Inverter:init()
    if self.bms_host and self.bms_host ~= "" then
        self.BMS = AntBMS:new{host = o.bms_host}
    end

    return self
end


function Inverter:startDischarge(req_power)
    if self.time_controlled or self.BMS:readyToDischarge() then
        self.BMS:setPower(req_power or 10) -- if no power requested, start with minimal power
        util.sleep_time(1)
        self:toggle("on")
    end
end

function Inverter:stopDischarge()
    self.BMS:setPower(0)
    util.sleep_time(0.5)
    self:toggle("off")
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
