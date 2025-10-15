
local Modbus = require("modbus")

local Marstek = {
    client = nil,
    host = nil,
    ip = nil, -- IP-Adresse des ELFIN WL11A
    port = nil, -- Modbus TCP Port
    slaveId = nil, -- Slave ID
    ACPower = 0,
    MIN_DISCHARGE_LIMIT = 800,
    MAX_DISCHARGE_LIMIT = 2500,
}

function Marstek:new(o)
    o = o or {}
    setmetatable(o, self)  -- __index inside new()self.__index = self
    self.__index = self
    if o.host then
        o.host = o.host:lower()
    end
    if o.init then
        o:init()
    end
    return o
end

local registers = {}
-- registers.         = {adr = , typ = "", gain = , unit = ""}

registers.readBatteryVoltage     = {adr = 32100, typ = "u16", gain = 0.01, unit = "V"}
registers.readBatteryCurrent     = {adr = 32101, typ = "s16", gain = 0.01, unit = "A"}
registers.readBatteryPower       = {adr = 32102, typ = "s32", gain = 1, unit = "W"}
registers.readBatterySOC         = {adr = 32104, typ = "u16", gain = 1, unit = "%"}
registers.readBatteryTotalEnergy = {adr = 32105, typ = "u16", gain = 0.001, unit = "kWh"}

registers.readACVoltage   = {adr = 32200, typ = "u16", gain = 0.1, unit = "V"}
registers.readACCurrent   = {adr = 32201, typ = "u16", gain = 0.01, unit = "A"}
registers.readACPower     = {adr = 32202, typ = "s32", gain = 1, unit = "W"}

registers.readACOffgridVoltage  = {adr = 32300, typ = "u16", gain = 0.1, unit = "V"}
registers.readACOffgridCurrent  = {adr = 32301, typ = "u16", gain = 0.01, unit = "A"}
registers.readACOffgridPower    = {adr = 32302, typ = "s32", gain = 1, unit = "W"}

registers.readInternalTemperature = {adr = 35000, typ = "s16", gain = 0.1, unit = "°C"}
registers.readMaxCellTemperature  = {adr = 35010, typ = "s16", gain = 0.1, unit = "°C"}
registers.readMinCellTemperature  = {adr = 35011, typ = "s16", gain = 0.1, unit = "°C"}

registers.backupFunction          = {adr = 41200, typ = "u16", gain = 1, unit = ""}

registers.rs485ControlMode = {adr = 42000, typ = "u16", gain = 1, unit = ""}

registers.forcibleChargeDischarge = {adr = 42010, typ = "u16", gain = 1, unit = ""}
registers.forcibleChargePower     = {adr = 42020, typ = "u16", gain = 1, unit = "W"}
registers.forcibleDischargePower  = {adr = 42021, typ = "u16", gain = 1, unit = "W"}

registers.userWorkMode            = {adr = 43000, typ = "u16", gain = 1, unit = ""}

registers.ChargingCutoff         = {adr = 44000, typ = "u16", gain = 0.1, unit = "%"}
registers.DischargingCutoff      = {adr = 44001, typ = "u16", gain = 0.1, unit = "%"}

registers.maxChargePower         = {adr = 44002, typ = "u16", gain = 1 , unit = "W"}
registers.maxDischargePower      = {adr = 44003, typ = "u16", gain = 1, unit = "W"}

registers.GridStandards      = {adr = 44100, typ = "u16", gain = 1, unit = ""}


function Marstek:readBatteryVoltage()
    return Modbus:readHoldingRegisters(self.ip, self.port, self.slaveId, 1, registers.readBatteryVoltage),
        "Battery Voltage", registers.readBatteryVoltage.unit
end
function Marstek:readBatteryCurrent()
    return Modbus:readHoldingRegisters(self.ip, self.port, self.slaveId, 1, registers.readBatteryCurrent),
        "Battery Current", registers.readBatteryCurrent.unit
end
-- negative meanse that the battery is discharching
function Marstek:readBatteryPower()
    return Modbus:readHoldingRegisters(self.ip, self.port, self.slaveId, 1, registers.readBatteryPower),
        "Battery Power", registers.readBatteryPower.unit
end
function Marstek:readBatterySOC()
    return Modbus:readHoldingRegisters(self.ip, self.port, self.slaveId, 1, registers.readBatterySOC),
        "Battery SOC", registers.readBatterySOC.unit
end
function Marstek:readBatteryTotalEnergy()
    return Modbus:readHoldingRegisters(self.ip, self.port, self.slaveId, 1, registers.readBatteryTotalEnergy),
        "Battery TotalEnergy", registers.readBatteryTotalEnergy.unit
end

function Marstek:readACVoltage()
    return Modbus:readHoldingRegisters(self.ip, self.port, self.slaveId, 1, registers.readACVoltage),
        "Battery Voltage", registers.readACVoltage.unit
end
function Marstek:readACCurrent()
    return Modbus:readHoldingRegisters(self.ip, self.port, self.slaveId, 1, registers.readACCurrent),
        "Battery Current", registers.readACCurrent.unit
end
-- negative means that the battery is discharching
function Marstek:readACPower()
    self.ACPower = Modbus:readHoldingRegisters(self.ip, self.port, self.slaveId, 1, registers.readACPower)
    return self.ACPower, "Battery Power", registers.readACPower.unit
end

function Marstek:readMaxChargePower()
    self.maxChargePower = Modbus:readHoldingRegisters(self.ip, self.port, self.slaveId, 1,
        registers.maxChargePower)

    return self.maxChargePower, "Max Charge Power", registers.maxChargePower.unit
end

function Marstek:writeMaxChargePower(value)
    return Modbus:writeHoldingRegisters(self.ip, self.port, self.slaveId, 1, registers.maxChargePower, value)
end

function Marstek:readMaxDischargePower()
    self.maxDischargePower = Modbus:readHoldingRegisters(self.ip, self.port, self.slaveId, 1,
        registers.maxDischargePower)
    return self.maxDischargePower, "Max Discharge Power", registers.maxDischargePower.unit
end

function Marstek:writeMaxDischargePower(value)
    if self.maxDischargePower == self.MIN_DISCHARGE_LIMIT then
        print("Marstek: Power was fixed at "..self.MIN_DISCHARGE_LIMIT.."W, change it in Marstek-App before!")
    end
    return Modbus:writeHoldingRegisters(self.ip, self.port, self.slaveId, 1, registers.maxDischargePower, value)
end

function Marstek:readChargingCutoff()
    return Modbus:readHoldingRegisters(self.ip, self.port, self.slaveId, 1, registers.ChargingCutoff),
        "Charge Cutoff", registers.ChargingCutoff.unit
end

function Marstek:writeChargingCutoff(value)
    return Modbus:writeHoldingRegisters(self.ip, self.port, self.slaveId, 1, registers.ChargingCutoff, value)
end

function Marstek:readDischargingCutoff()
    return Modbus:readHoldingRegisters(self.ip, self.port, self.slaveId, 1, registers.DischargingCutoff),
        "Discharge Cutoff", registers.DischargingCutoff.unit
end

function Marstek:writeDischargingCutoff(value)
    return Modbus:writeHoldingRegisters(self.ip, self.port, self.slaveId, 1, registers.DischargingCutoff, value)
end

function Marstek:readGridStandards()
    local gridStd = Modbus:readHoldingRegisters(self.ip, self.port, self.slaveId, 1, registers.GridStandards)
    local country = {
            [0] = "Auto 50/60",
            "EN50549",
            "nl-Netherlands",
            "de-Germany",
            "at-Austria",
            "uk-England",
            "es-Spain",
            "pl-Poland",
            "it-Italy",
            "cn-China",
        }
    return gridStd, "Grid Standards: " ..country[gridStd], registers.GridStandards.unit
end

function Marstek:writeGridStandards(value)
    return Modbus:writeHoldingRegisters(self.ip, self.port, self.slaveId, 1, registers.GridStandards, value)
end

-- 0:manual, 1:anti-feed, 2:trade
function Marstek:writeUserWorkMode(value)
    return Modbus:writeHoldingRegisters(self.ip, self.port, self.slaveId, 1, registers.userWorkMode, value)
end

-- 0:stop, 1:charge, 2:discharge
function Marstek:writeForcibleChargeDischarge(value)
    return Modbus:writeHoldingRegisters(self.ip, self.port, self.slaveId, 1, registers.forcibleChargeDischarge, value)
end

function Marstek:writeForcibleChargePower(value)
    return Modbus:writeHoldingRegisters(self.ip, self.port, self.slaveId, 1, registers.forcibleChargePower, value)
end

function Marstek:writeForcibleDischargePower(value)
    return Modbus:writeHoldingRegisters(self.ip, self.port, self.slaveId, 1, registers.forcibleDischargePower, value)
end

function Marstek:writeRs485ControlMode(enable)
    local value
    if enable == 1 or enable == true then
        value = 0x55aa
    else
        value = 0x55bb
    end
    return Modbus:writeHoldingRegisters(self.ip, self.port, self.slaveId, 1, registers.rs485ControlMode, value)
end


------------- higher order methods

-- luacheck: ignore self
function Marstek:isDischargingMoreThan(limit)
    limit = limit or 0
    return self.ACPower and (self.ACPower > limit)
end

-- luacheck: ignore self
function Marstek:isChargingMoreThan(limit)
    limit = limit or 0
    return self.ACPower and (-self.ACPower > limit)
end

function Marstek:isIdle()
    return self.ACPower == 0
end

-----------------------------------------------------------------------------------------------------------


local function printValue(value, name, unit)
    if value then
        print(string.format("%s: %s %s", name or "", tostring(value), unit or ""))
    end
end

local function init()
    -- Beispielaufruf
    local ip = "192.168.0.208" -- IP-Adresse des ELFIN WL11A
    local port = 502 -- Modbus TCP Port
    local slaveId = 1 -- Slave ID


    local VenusE = Marstek:new({ip = ip, port=port, slaveId = slaveId})

    printValue(VenusE:readBatterySOC())
    printValue(VenusE:readBatteryVoltage())
    printValue(VenusE:readBatteryCurrent())
    printValue(VenusE:readBatteryPower())
    printValue(VenusE:readBatteryTotalEnergy())

    printValue(VenusE:readMaxDischargePower())
    printValue(VenusE:readMaxChargePower())

    printValue(VenusE:writeMaxDischargePower(2500))
    printValue(VenusE:writeMaxChargePower(2500))

    printValue(VenusE:readMaxDischargePower())
    printValue(VenusE:readMaxChargePower())


    printValue(VenusE:readChargingCutoff())
    printValue(VenusE:readDischargingCutoff())

    printValue(VenusE:writeChargingCutoff(100))
    printValue(VenusE:writeDischargingCutoff(15))

    printValue(VenusE:readChargingCutoff())
    printValue(VenusE:readDischargingCutoff())

    printValue(VenusE:readGridStandards())
    printValue(VenusE:writeGridStandards(4))
    printValue(VenusE:readGridStandards())
end
if arg[0]:find("marstek.lua") then
    init()
end


return Marstek



