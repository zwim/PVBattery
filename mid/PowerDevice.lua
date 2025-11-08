-- Masterclass for Batteries

local BaseClass = require("mid/BaseClass")

local state = {
    fail = "fail", -- unknown state
    idle = "idle",
    take = "take",
    give = "give",
    can_take = "can_take",
    can_give = "can_give",
}

local PowerDevice = BaseClass:extend{
    __name = "PowerDevice",
    max_charge_power = 0,
    max_discharge_power = 0,
    SOC = nil,

    state = state,
    _state = nil,
}

function PowerDevice:extend(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    return o
end

function PowerDevice:new(o)
    o = self:extend(o)
    if o.host then
        o.host = o.host:lower()
    end
    if o.init then
        o:init()
    end
    return o
end

function PowerDevice:init()
    if BaseClass.init then BaseClass.init(self) end
    return self
end

--------------------------------------------------------------------------
function PowerDevice:take(req_power)
end

function PowerDevice:give(req_power)
end

function PowerDevice:getSOC()
end

-- returns "charge", "discharge", "idle", "chargeable", "dischargeable", "balance"
function PowerDevice:getState()
end

-- returns positive if chargeing, negative if dischargeing
-- if internal is set, get internal power, else AC-power
function PowerDevice:getPower(internal)
end

-- if modus can be {auto = true} or {manual = true}
function PowerDevice:setMode(modus)
end

-- turns on balancing
function PowerDevice:balance()
end

-- if internal is set, get internal Voltage, else AC-Voltage
function PowerDevice:getVoltage(internal)
end

-- returns positive if chargeing, negative if dischargeing
-- if internal is set, get internal current, else AC-current
function PowerDevice:getCurrent(internal)
end

-- always AC
function PowerDevice:setMaxDischargePower(max_power)
end

-- always AC
function PowerDevice:getMaxDischargePower()
end

-- always AC
function PowerDevice:setMaxChargePower(max_power)
end

-- always AC
function PowerDevice:getMaxChargePower()
end

-- in percent
function PowerDevice:setChargeCutOff(percent)
end

-- in percent
function PowerDevice:getChargeCutOff()
end

-- in percent
function PowerDevice:setDischargeCutOff(percent)
end

-- in percent
function PowerDevice:getDischargeCutOff()
end

return PowerDevice
