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
    if self.bms_host and self.bms_host ~= "" then
        self.BMS = AntBMS:new{host = o.bms_host}
    end
    return self
end

function Charger:startCharge()
    self:toggle("on")
end

function Charger:stopCharge()
    self:toggle("off")
end

function Charger:readyToCharge()
    local start_charge, continue_charge = self.BMS:readyToCharge()
    if not continue_charge then
        self:stopCharge()
    end
    return start_charge
end

return Charger
