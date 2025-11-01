
local Modbus = require("base/modbus")

local Marstek = {
    client = nil,
    host = nil,
    ip = nil, -- IP-Adresse des ELFIN WL11A
    port = nil, -- Modbus TCP Port
    slave_id = nil, -- Slave ID
    ACPower = 0,
    MIN_DISCHARGE_LIMIT = 800,
    MAX_DISCHARGE_LIMIT = 2500,
    GOOD_INT_TEMP = 45,
    MAX_INT_TEMP = 50,
    GOOD_MOS_TEMP = 60,
    MAX_MOS_TEMP = 70,
    GOOD_CELL_TEMP = 30,
    MAX_CELL_TEMP = 37,
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

function Marstek:init()
    if not self.slave_id then
        self.slave_id = 1 -- the marstek venusE Gen2.0 id
    end
   self.ModbusInstance = Modbus:new{ip = self.ip, port = self.port, slave_id = self.slave_id}
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
registers.readMOS1Temperature     = {adr = 35001, typ = "s16", gain = 0.1, unit = "°C"}
registers.readMOS2Temperature     = {adr = 35002, typ = "s16", gain = 0.1, unit = "°C"}
registers.readMaxCellTemperature  = {adr = 35010, typ = "s16", gain = 1, unit = "°C"}
registers.readMinCellTemperature  = {adr = 35011, typ = "s16", gain = 1, unit = "°C"}

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
    return self.ModbusInstance:readHoldingRegisters(1, registers.readBatteryVoltage),
        "Battery Voltage", registers.readBatteryVoltage.unit
end
function Marstek:readBatteryCurrent()
    return self.ModbusInstance:readHoldingRegisters(1, registers.readBatteryCurrent),
        "Battery Current", registers.readBatteryCurrent.unit
end
-- negative meanse that the battery is discharching
function Marstek:readBatteryPower()
    return self.ModbusInstance:readHoldingRegisters(1, registers.readBatteryPower),
        "Battery Power", registers.readBatteryPower.unit
end
function Marstek:readBatterySOC()
    return self.ModbusInstance:readHoldingRegisters(1, registers.readBatterySOC),
        "Battery SOC", registers.readBatterySOC.unit
end
function Marstek:readBatteryTotalEnergy()
    return self.ModbusInstance:readHoldingRegisters(1, registers.readBatteryTotalEnergy),
        "Battery TotalEnergy", registers.readBatteryTotalEnergy.unit
end

function Marstek:readACVoltage()
    return self.ModbusInstance:readHoldingRegisters(1, registers.readACVoltage),
        "Battery Voltage", registers.readACVoltage.unit
end
function Marstek:readACCurrent()
    return self.ModbusInstance:readHoldingRegisters(1, registers.readACCurrent),
        "Battery Current", registers.readACCurrent.unit
end
-- negative means that the battery is discharching
function Marstek:readACPower()
    self.ACPower = self.ModbusInstance:readHoldingRegisters(1, registers.readACPower)
    return self.ACPower, "Battery Power", registers.readACPower.unit
end

function Marstek:readMaxChargePower()
    self.maxChargePower = self.ModbusInstance:readHoldingRegisters(1,
        registers.maxChargePower)

    return self.maxChargePower, "Max Charge Power", registers.maxChargePower.unit
end

function Marstek:writeMaxChargePower(value)
    return self.ModbusInstance:writeHoldingRegisters(1, registers.maxChargePower, value)
end

function Marstek:readMaxDischargePower()
    self.maxDischargePower = self.ModbusInstance:readHoldingRegisters(1,
        registers.maxDischargePower)
    return self.maxDischargePower, "Max Discharge Power", registers.maxDischargePower.unit
end

function Marstek:writeMaxDischargePower(value)
    if self.maxDischargePower == self.MIN_DISCHARGE_LIMIT then
        print("Marstek: Power was fixed at "..self.MIN_DISCHARGE_LIMIT.."W, change it in Marstek-App before!")
    end
    return self.ModbusInstance:writeHoldingRegisters(1, registers.maxDischargePower, value)
end

function Marstek:readChargingCutoff()
    return self.ModbusInstance:readHoldingRegisters(1, registers.ChargingCutoff),
        "Charge Cutoff", registers.ChargingCutoff.unit
end

function Marstek:writeChargingCutoff(value)
    return self.ModbusInstance:writeHoldingRegisters(1, registers.ChargingCutoff, value)
end

function Marstek:readDischargingCutoff()
    return self.ModbusInstance:readHoldingRegisters(1, registers.DischargingCutoff),
        "Discharge Cutoff", registers.DischargingCutoff.unit
end

function Marstek:writeDischargingCutoff(value)
    return self.ModbusInstance:writeHoldingRegisters(1, registers.DischargingCutoff, value)
end

function Marstek:readGridStandards()
    local gridStd = self.ModbusInstance:readHoldingRegisters(1, registers.GridStandards)
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
    return self.ModbusInstance:writeHoldingRegisters(1, registers.GridStandards, value)
end

-- 0:manual, 1:anti-feed, 2:trade
function Marstek:writeUserWorkMode(value)
    return self.ModbusInstance:writeHoldingRegisters(1, registers.userWorkMode, value)
end

-- 0:stop, 1:charge, 2:discharge
function Marstek:writeForcibleChargeDischarge(value)
    return self.ModbusInstance:writeHoldingRegisters(1, registers.forcibleChargeDischarge, value)
end

function Marstek:writeForcibleChargePower(value)
    return self.ModbusInstance:writeHoldingRegisters(1, registers.forcibleChargePower, value)
end

function Marstek:writeForcibleDischargePower(value)
    return self.ModbusInstance:writeHoldingRegisters(1, registers.forcibleDischargePower, value)
end

function Marstek:writeRs485ControlMode(enable)
    local value
    if enable == 1 or enable == true then
        value = 0x55aa
    else
        value = 0x55bb
    end
    return self.ModbusInstance:writeHoldingRegisters(1, registers.rs485ControlMode, value)
end

function Marstek:readInternalTemperature()
    return self.ModbusInstance:readHoldingRegisters(1, registers.readInternalTemperature),
        "Internal Temperature", registers.readInternalTemperature.unit
end
function Marstek:readMOS1Temperature()
    return self.ModbusInstance:readHoldingRegisters(1, registers.readMOS1Temperature),
        "MOS1 Temperature", registers.readMOS1Temperature.unit
end
function Marstek:readMOS2Temperature()
    return self.ModbusInstance:readHoldingRegisters(1, registers.readMOS2Temperature),
        "MOS2 Temperature", registers.readMOS2Temperature.unit
end
function Marstek:readMaxCellTemperature()
    return self.ModbusInstance:readHoldingRegisters(1, registers.readMaxCellTemperature),
        "Max Cell Temperature", registers.readMaxCellTemperature.unit
end
function Marstek:readMinCellTemperature()
    return self.ModbusInstance:readHoldingRegisters(1, registers.readMinCellTemperature),
        "Min Cell Temperature", registers.readMinCellTemperature.unit
end


------------- higher order methods

function Marstek:getTemperature()
    local internalTemp = self:readInternalTemperature()
    local MOS1Temp = self:readMOS1Temperature()
    local MOS2Temp = self:readMOS2Temperature()
    local MINcTemp = self:readMinCellTemperature()
    local MAXcTemp = self:readMaxCellTemperature()
    local MOSTemp = math.max(MOS1Temp, MOS2Temp)
    local CellTemp = math.max(MINcTemp, MAXcTemp)

    print("Temperatures:", internalTemp, MOS1Temp, MOS2Temp, MINcTemp, MAXcTemp)
    return {internalTemp, MOSTemp, CellTemp}
end

function Marstek:calculateTempFactor()
    local function calcFact(value, min, max)
        if value <= min then
            return 1
        elseif value >= max then
            return 0
        else
            return math.clamp(1 - (value - min) / (max-min), 0, 1)
        end
    end

    local val = self:getTemperature()
    local int_factor = calcFact(val[1], self.GOOD_INT_TEMP, self.MAX_INT_TEMP)
    local MOS_factor = calcFact(val[2], self.GOOD_MOS_TEMP, self.MAX_MOS_TEMP)
    local cell_factor = calcFact(val[3], self.GOOD_CELL_TEMP, self.MAX_CELL_TEMP)

    local factor = math.min(int_factor, MOS_factor, cell_factor)
    return factor
end


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

local function example()
    -- Beispielaufruf
    local ip = "192.168.0.161" -- IP-Adresse des ELFIN WL11A
    local port = 502 -- Modbus TCP Port
    local slave_id = 1 -- Slave ID


    local VenusE = Marstek:new{ip = ip, port=port, slave_id = slave_id}

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

    printValue(VenusE:readInternalTemperature())
    printValue(VenusE:readMOS1Temperature())
    printValue(VenusE:readMOS2Temperature())
    printValue(VenusE:readMaxCellTemperature())
    printValue(VenusE:readMinCellTemperature())

    print("temperature factor:", VenusE:calculateTempFactor())

end

if arg[0]:find("marstek.lua") then
    example()
end

return Marstek



