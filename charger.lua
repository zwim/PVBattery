-- Charger.lua

local Switch = require("switch")
local AntBMS = require("antbms")

local Charger = Switch:extend{
    bms_host = "",
    max_power = 0,
    -- will get initialized by new
    BMS = nil,
}

function Charger:init()
    if self.bms_host ~= "" then
        self.BMS = AntBMS:new{host = self.bms_host}
    end
    return self
end

function Charger:startCharge()
    if self.BMS then
        self.BMS:enableDischarge()
    end
    self:toggle("on")
end

function Charger:safeStartCharge()
    if self:getPowerState() ~= "on" then self:startCharge() end
end

function Charger:stopCharge()
    self:toggle("off")
end

function Charger:safeStopCharge()
    if self:getPowerState() ~= "off" then self:stopCharge() end
end

function Charger:readyToCharge()
    local start_charge, continue_charge = self.BMS:readyToCharge()
    if not continue_charge then
        self:stopCharge()
    end
    return start_charge
end

return Charger
