-- Masterclass for Batteries

local Battery = require("mid/Battery")

local Marstek = require("base/marstek")
local util = require("base/util")

local MarstekBattery = Battery:extend{
    __name = "MarstekBattery",
    VenusE = nil,
}

function MarstekBattery:extend(o)
    local o = o or {}
    setmetatable(o, self)
    self.__index = self
    return o
end

function MarstekBattery:new(o)
    o = self:extend(o)
    if o.host then
        o.host = o.host:lower()
    end
    if o.init then
        o:init()
    end
    return o
end

function MarstekBattery:init()
    local Device = self.Device
    Device.ip = util.getIPfromURL(Device.host)
    self.VenusE = Marstek:new{ip = Device.ip or Device.host, port = Device.port, slaveId = Device.slaveId}

    self:setMode({auto = true})
    print("set mode to auto")

    self.charge_max_power = Device.charge_max_power or 2500
    self.discharge_max_power = Device.discharge_max_power or 2500
    self.power = 0
    if self:getMaxChargePower() ~= self.charge_max_power then
        self:setMaxChargePower(self.charge_max_power)
    end
    if self:getMaxDischargePower() ~= self.discharge_max_power then
        self:setMaxDischargePower(self.discharge_max_power)
    end

    print("SOC: " .. self:getSOC() .. "%")

    print(self.VenusE:readChargingCutoff())
    print(self.VenusE:readDischargingCutoff())
    if self.VenusE:readChargingCutoff() ~= self.Device.SOC_max then
        self.VenusE:writeChargingCutoff(self.Device.SOC_max or 100)
    end
    if self.VenusE:readDischargingCutoff() ~= self.Device.SOC_min then
        self.VenusE:writeDischargingCutoff(self.Device.SOC_min or 15)
    end
end

--------------------------------------------------------------------------

-- req_power < 0 push energy to the battery
-- req_power > 0 get power from the battery
-- req_power == 0 set battery to idle
-- req_power == nil automatic mode
function MarstekBattery:setPower(req_power)
    if not req_power then
        self.VenusE:writeRs485ControlMode(false) -- back to auto mode
    elseif req_power == 0 then
        self:take(0)
        self:give(0)
    elseif req_power < 0 then
        self:take(-req_power)
    else
        self:give(req_power)
    end
end

-- charge Battery
function MarstekBattery:take(req_power)
    if req_power >= 0 then
        local factor = self.VenusE:calculateTempFactor()
        if factor < 1 then
            self:log(3, "Temperature factor", factor)
        end
        req_power = req_power * factor
        req_power = math.clamp(req_power, 0, self.charge_max_power)
        self.VenusE:writeRs485ControlMode(true)
        self.VenusE:writeForcibleChargeDischarge(1) -- charge
        self.VenusE:writeForcibleChargePower(req_power)
        return req_power
    end
end

-- dischargeBattery
function MarstekBattery:give(req_power)
    if req_power >= 0 then
        local factor = self.VenusE:calculateTempFactor()
        self:log(3, "Temperature factor", factor)
        req_power = req_power * factor
        req_power = math.clamp(req_power, 0, self.discharge_max_power)
        self.VenusE:writeRs485ControlMode(true)
        self.VenusE:writeForcibleChargeDischarge(2) -- discharge
        self.VenusE:writeForcibleDischargePower(req_power)
        return req_power
    end
end

function MarstekBattery:getSOC()
    return self.VenusE:readBatterySOC() or 0
end

-- returns "take", "give", "idle", "can_take", "can_give"
function MarstekBattery:getState()
    local curr_power = self.VenusE:readACPower()
    curr_power = curr_power or self.VenusE:readACPower()

    if not curr_power then
        print("Error in MarstekBattery:getState()")
    end

    local result = {}

    -- todo add can_give can_take
    if curr_power < 0 then
        result.take = true
    elseif curr_power > 0 then
        result.give = true
    elseif curr_power == 0 then
        result.idle = true
    end

    local SOC = self:getSOC()
    if SOC < self.Device.SOC_max then
        result.can_take = true
    elseif SOC > self.Device.SOC_min then
        result.can_give = true
    end

    return result
end

-- returns positive if chargeing, negative if dischargeing
-- if internal is set, get internal power, else AC-power
function MarstekBattery:getPower(internal)
    if internal then
        return self.VenusE:readBatteryPower() or 0
    else
        return self.VenusE:readACPower()  or 0
    end
end

-- turns on balancing
function MarstekBattery:balance()
end

-- if internal is set, get internal Voltage, else AC-Voltage
function MarstekBattery:getVoltage(internal)
end

-- returns positive if chargeing, negative if dischargeing
-- if internal is set, get internal current, else AC-current
function MarstekBattery:getCurrent(internal)
end

-- always AC
function MarstekBattery:getEnergyStored()
end

-- always AC
function MarstekBattery:setMaxDischargePower(max_power)
    max_power = math.clamp(max_power, 100, 2500)
    self.VenusE:writeMaxDischargePower(max_power)
end

-- always AC
function MarstekBattery:getMaxDischargePower()
    return self.VenusE:readMaxDischargePower()
end

-- always AC
function MarstekBattery:setMaxChargePower(max_power)
    max_power = math.clamp(max_power, 100, 2500)
    self.VenusE:writeMaxChargePower(max_power)
end

-- always AC
function MarstekBattery:getMaxChargePower()
    return self.VenusE:readMaxChargePower()
end

-- in percent
function MarstekBattery:setChargeCutOff(percent)
    percent = math.clamp(percent, 80, 100)
    self.VenusE:writeChargingCutoff(percent)
end

-- in percent
function MarstekBattery:getChargeCutOff()
    return self.VenusE:readChargingCutoff()
end

-- in percent
function MarstekBattery:setDischargeCutOff(percent)
    percent = math.clamp(percent, 10, 30)
    self.VenusE:writeDischargingCutoff(percent)
end

-- in percent
function MarstekBattery:getDischargeCutOff()
    return self.VenusE:readDischargingCutoff()
end

function MarstekBattery:setMode(modus)
    if modus.auto then
        self.VenusE:writeUserWorkMode(1)
    elseif modus.manual then
        self.VenusE:writeUserWorkMode(0)
    end
end


if arg[0]:find("MarstekBattery.lua") then
    -- Beispielaufruf
    local ip = "192.168.0.161" -- IP-Adresse des ELFIN WL11A
    local host = "192.168.0.161" -- IP-Adresse des ELFIN WL11A
    local port = 502 -- Modbus TCP Port
    local slaveId = 1 -- Slave ID

    local VenusE = MarstekBattery:new{Device = {host = host, port = port, slaveId = slaveId}}

    local register     = {adr = 35000, typ = "u16", gain = 1, unit = ""}

--[[    for i=1, 100 do
        print(register.adr, VenusE.VenusE:readHoldingRegisters(register))
        register.adr = register.adr + 1
        os.execute("sleep 1")
    end

    os.exit(1)
]]

    VenusE.Device.SOC_max = 100

    local function printValue(value, name, unit)
        if value then
            print(string.format("%s: %s %s", name or "", tostring(value), unit or ""))
        end
    end

    print(VenusE:getMaxChargePower())
    print(VenusE:getMaxDischargePower())
    printValue(VenusE:getSOC())
    printValue(VenusE:getPower())
    printValue(VenusE:setMode({auto = true}))


    local n=1
    print(n) n=n+1

--[[
    local power = 50
    print("power=" .. power)
    VenusE:take(power)
    VenusE2:take(power)
    os.execute("sleep 4")
    print("take")
    printValue(VenusE:getPower())
    printValue(VenusE2:getPower())


    os.execute("sleep 4")
    power = power
    print("power=" .. power)
    VenusE:give(power)
    VenusE2:give(power)
    os.execute("sleep 4")
    print("give")
    printValue(VenusE:getPower())
    printValue(VenusE2:getPower())
]]

--    VenusE:take(2020)
--    VenusE:give(30)


   local VenusE2 = MarstekBattery:new{Device = {host = "192.168.0.208", port = port, slaveId = slaveId}}
    printValue(VenusE2:setMode({auto = true}))

--    VenusE2:give(50)

end

return MarstekBattery
