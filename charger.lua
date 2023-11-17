-- Charger.lua

local Switch = require("switch")
local AntBMS = require("antbms")


local Charger = {
    switch_host = "",
    bms_host = "",

    -- will get initialized by new
    Switch = nil,
    BMS = nil,
}

function Charger:new(o)
    o = o or {}   -- create object if user does not provide one
    setmetatable(o, self)
    self.__index = self

    if o.switch_host and o.switch_host ~= "" then
        o.Switch = Switch:new{host = o.switch_host}
    end
    if o.bms_host and o.bms_host ~= "" then
        o.BMS = AntBMS:new{host = o.bms_host}
    end
    return o
end

function Charger:getCurrentPower()
   return self.Switch:getPower()
end

function Charger:getMaxPower()
   return self.Switch:getMaxPower()
end

function Charger:getPowerState()
   return self.Switch:getPowerState()
end

function Charger:stopCharge()
    self.Switch:toggle("off")
end

function Charger:startCharge()
    self.Switch:toggle("on")
end

function Charger:readyToCharge()
    if self.BMS:readyToCharge() then
        return true
    else
        self:stopCharge()
        return false
    end
end

return Charger