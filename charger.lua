-- charger.lua: Charger control abstraction for PVBattery

local Switch = require("switch")
local AntBMS = require("antbms")

-- Charger class, based on Switch, with BMS integration
local Charger = Switch:extend{
    bms_host = "",
    max_power = 0,
    BMS = nil,
}

-- Initialize Charger, attach BMS if bms_host is set
function Charger:init()
    if self.bms_host ~= "" then
        self.BMS = AntBMS:new{host = self.bms_host}
    end
    return self
end

-- Start charging, enabling BMS discharge relay if present
function Charger:startCharge()
    if self.BMS then
        self.BMS:enableDischarge()
    end
    self:toggle("on")
end

-- Start charging only if not already on
function Charger:safeStartCharge()
    if self:getPowerState() ~= "on" then
        self:startCharge()
    end
end

-- Stop charging
function Charger:stopCharge()
    self:toggle("off")
end

-- Stop charging only if not already off
function Charger:safeStopCharge()
    if self:getPowerState() ~= "off" then
        self:stopCharge()
    end
end

-- Check if BMS allows charging, stop if not allowed
function Charger:readyToCharge()
    local start_charge, continue_charge = self.BMS:readyToCharge()
    if not continue_charge then
        self:stopCharge()
    end
    return start_charge
end

return Charger
