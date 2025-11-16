-- Masterclass for Batteries

local util = require("base/util")

local PowerDevice = require("mid/PowerDevice")

local Fronius = require("base/fronius")

local FroniusInverter = PowerDevice:extend{
    __name = "FroniusInverter",
    Inverter = nil,
    internal_state = "",
}

function FroniusInverter:new(o)
    o = self:extend(o)
    if o.host then
        o.host = o.host:lower()
    end
    if o.init then
        o:init()
    end
    return o
end

function FroniusInverter:init()
    if PowerDevice.init then PowerDevice.init(self) end

    local Device = self.Device
    if Device.inverter_switch then
        self.ip = util.getIPfromURL(Device.inverter_switch)
        self.Inverter = Fronius:new{ip = self.ip}
    end
end

--------------------------------------------------------------------------

-- returns "give", "take", "idle", "chargeable", "can_take", "can_give"
function FroniusInverter:getState()
    local P_AC = self:getPower()
    local result = {}
    if P_AC > 0 then
        result.give = true
    else
        result.idle = true
    end
    return result
end

function FroniusInverter:getPower()
    return self.Inverter:getPowerModbus()
end
-- returns positive if chargeing, negative if dischargeing
-- poor update rate; ca. every 10 secs
function FroniusInverter:getAllPower()
    return Fronius:getGridLoadPV()
end

local function example()
    local Device = {
        name = "PV-Dach",
        typ = "inverter",
        brand = "Fronius",
        inverter_switch = "192.168.0.49",
    }

    local Inverter = FroniusInverter:new{Device = Device}
    Inverter:log(0, "Now do some reading, to show how values change")
    for _ = 1, tonumber(arg[1] or 40) do
        local power_modbus = Inverter:getPower()
        local P_Grid_slow, P_Load, P_PV, P_AC = Inverter:getAllPower()
        Inverter:log(0, string.format("fast Power: %5.1f, slow Power: %5.1f; %d %d",
                power_modbus, P_Grid_slow, P_Load, P_PV, P_AC))
        os.execute("sleep 1")
    end
end

if arg[0]:find("FroniusInverter.lua") then
    example()
end

return FroniusInverter
