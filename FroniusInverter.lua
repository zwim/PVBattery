-- Masterclass for Batteries

local PowerDevice = require("PowerDevice")

local Fronius = require("fronius")

local FroniusInverter = PowerDevice:extend{
    __name = "FroniusInverter",
    Inverter = nil,
    internal_state = "",
}

function FroniusInverter:init()
    local Device = self.Device
    if Device.inverter_switch then
        self.Inverter = Fronius:new{host = Device.inverter_switch}
    end
end

--------------------------------------------------------------------------

-- returns "give", "take", "idle", "chargeable", "can_take", "can_give"
function FroniusInverter:getState()
    local P_AC = Fronius:getACPower()
    local result = {}
    if P_AC > 0 then
        result.give = true
    else
        result.idle = true
    end
    return result
end

-- if internal is set, get internal Voltage, else AC-Voltage
function FroniusInverter:getVoltage(internal)
end

-- returns positive if chargeing, negative if dischargeing
-- if internal is set, get internal current, else AC-current
function FroniusInverter:getCurrent(internal)
end

-- returns positive if chargeing, negative if dischargeing
function FroniusInverter:getPower(internal)
    local P_Grid, P_Load, P_PV, P_AC = Fronius:getGridLoadPV()

    if internal then
        return P_PV, P_Grid, P_Load, P_PV, P_AC
    else
        return P_AC, P_Grid, P_Load, P_PV, P_AC
    end
end

return FroniusInverter
