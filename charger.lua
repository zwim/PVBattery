-- charger.lua: Charger control abstraction for PVBattery

local Switch = require("switch")

-- Charger class, based on Switch, with BMS integration
local Charger = Switch:extend{
    bms_host = "",
    max_power = 0,
}

-- Initialize Charger, attach BMS if bms_host is set
function Charger:init()
    return self
end

-- Start charging, enabling BMS discharge relay if present
function Charger:startCharge()
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

return Charger
