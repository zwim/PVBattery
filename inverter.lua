-- Inverter.lua

local Switch = require("switch")
local AntBMS = require("antbms")

local Inverter = {
    inverter_host == "",
    skip = false,
    bms_host = "",
    Switch = nil,
    dynamic_load = false,
    static_load = 0,
    BMS = nil,
}

function Inverter:new(o)
    o = o or {}   -- create object if user does not provide one
    setmetatable(o, self)
    self.__index = self

    if o.inverter_host and o.inverter_host ~= "" then
        o.Switch = Switch:new{host = o.inverter_host}
    end
    if o.bms_host and o.bms_host ~= "" then
        o.BMS = AntBMS:new{host = o.bms_host}
    end

    return o
end

function Inverter:startDischarge(req_power)
    if self.BMS:readyToDischarge() then
        self.Switch:toggle("on")
        -- todo xxxx add rs485 here
    end
end

function Inverter:stopDischarge()
    if not self.skip then
        self.Switch:toggle("off")
    end
end

function Inverter:getCurrentPower()
   return self.Switch:getPower()
end

function Inverter:getPowerState()
   return self.Switch:getPowerState()
end

function Inverter:readyToDischarge()
    if self.skip then
        return true
    end
    local ready = self.BMS:readyToDischarge()
    if ready == false then
        self:stopDischarge()
    end
    return ready
end

return Inverter